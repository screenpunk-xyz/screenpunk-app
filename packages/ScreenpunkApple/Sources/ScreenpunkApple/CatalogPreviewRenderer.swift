// SPDX-License-Identifier: Apache-2.0
import Foundation
import ScreenpunkCore
public typealias CatalogPreviewContext = CatalogPreviewScope
#if os(iOS)
import UIKit
import WebKit
import ImageIO
import UniformTypeIdentifiers

/// A screenshot of one verified immutable package, never the currently displayed
/// web view. No device bridge, connection settings, credentials, cookies or live
/// resource providers are installed in this ephemeral renderer.
@MainActor public final class CatalogPreviewRenderer: NSObject, WKNavigationDelegate {
    public struct Snapshot {
        public var bytes: Data
        public var declaration: CatalogPreviewDeclaration
        public var packageDigest: String
    }
    private static let scheme = "screenpunk-preview"
    private var ready: CheckedContinuation<Void, Error>?
    private var webView: WKWebView?
    private var handler: Assets?
    private var expiry: Task<Void, Never>?
    private enum Failure: Error { case unavailable, timeout, invalidPackage, oversized, cancelled }

    public func capture(package: CatalogPackage, packageDigest: String, byteLimit: Int = 512 * 1024, dimensionLimit: Int = 2048) async throws -> Snapshot {
        guard webView == nil, byteLimit > 0, byteLimit <= CatalogContract.previewBytes,
              dimensionLimit > 0, dimensionLimit <= CatalogContract.previewDimension,
              CatalogContract.digest(try CatalogContract.encodePackage(package)) == packageDigest else { throw Failure.invalidPackage }
        // Static fallback is deliberately fail-closed. Dynamic/SDK/public-service
        // screens need their exact ready live view; never screenshot placeholders.
        guard package.screen.externalDependencies.isEmpty, !package.files.contains(where: { file in
            guard let data = Data(base64Encoded: file.contentBase64), let text = String(data: data, encoding: .utf8) else { return true }
            return text.range(of: #"screenpunk|messageHandlers|fetch\s*\(|XMLHttpRequest|WebSocket|EventSource|https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
        }) else { throw Failure.unavailable }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { throw Failure.unavailable }
        let assets = Assets(package: package); handler = assets
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.processPool = WKProcessPool()
        config.setURLSchemeHandler(assets, forURLScheme: Self.scheme)
        config.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: CGRect(x: -4096, y: 0, width: 1024, height: 768), configuration: config)
        view.isUserInteractionEnabled = false
        view.navigationDelegate = self
        view.scrollView.isScrollEnabled = false
        window.addSubview(view); webView = view
        defer {
            expiry?.cancel(); expiry = nil
            view.stopLoading(); view.navigationDelegate = nil; view.removeFromSuperview()
            webView = nil; handler = nil
        }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                expiry = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
                    self?.finish(.failure(Failure.timeout))
                }
                view.load(URLRequest(url: URL(string: "\(Self.scheme)://package/index.html")!))
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(Failure.cancelled)) } })
        try Task.checkCancellation()
        // Let completed package-local loads and the first synchronous layout paint.
        // Network and native bridge calls are unavailable, so live account data
        // cannot enter this capture. This is a source preview, not a live-data dump.
        try await Task.sleep(nanoseconds: 350_000_000)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: 1024, height: 768)
        configuration.snapshotWidth = 1024
        configuration.afterScreenUpdates = true
        guard try await CatalogPreviewCaptureRegistry.isReady(view) else { throw Failure.unavailable }
        let image = try await CatalogPreviewCaptureRegistry.snapshot(view, configuration: configuration)
        try Task.checkCancellation()
        let result = try Self.encode(image: image, byteLimit: byteLimit, dimensionLimit: dimensionLimit)
        return Snapshot(bytes: result.bytes, declaration: .init(byteLength: result.bytes.count, digest: CatalogContract.digest(result.bytes), mediaType: "image/png", width: result.width, height: result.height), packageDigest: packageDigest)
    }
    private func finish(_ result: Result<Void, Error>) {
        guard let continuation = ready else { return }
        ready = nil; expiry?.cancel(); expiry = nil
        continuation.resume(with: result)
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(Failure.unavailable)) }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(Failure.unavailable)) }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(Failure.unavailable)) }
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme == Self.scheme, url.host == "package", navigationAction.targetFrame?.isMainFrame != true || url.path == "/index.html" else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    fileprivate static func encode(image: UIImage, byteLimit: Int, dimensionLimit: Int) throws -> (bytes: Data, width: Int, height: Int) {
        for desired in [1024, 768, 512, 384, 256, 192, 128] where desired <= dimensionLimit {
            let ratio = image.size.height / max(1, image.size.width)
            let width = min(desired, max(1, Int(CGFloat(dimensionLimit) / max(ratio, 0.01))))
            let height = max(1, min(dimensionLimit, Int(CGFloat(width) * ratio)))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; format.preferredRange = .standard
            let raster = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
                UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            guard let cg = raster.cgImage else { throw Failure.unavailable }
            // Convert into explicit 8-bit sRGB before removing ancillary profiles.
            guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.unavailable }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let rgb = context.makeImage() else { throw Failure.unavailable }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw Failure.unavailable }
            CGImageDestinationAddImage(destination, rgb, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGInterlaceType: 0]] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure.unavailable }
            let bytes = try strippedPNG(data as Data)
            if bytes.count <= byteLimit { return (bytes, width, height) }
        }
        throw Failure.oversized
    }
    /// ImageIO may emit color-profile metadata. Keep only the required raster
    /// chunks; preserve their original CRCs and never emit EXIF/text/APNG chunks.
    static func strippedPNG(_ source: Data) throws -> Data {
        let signature = Data([137,80,78,71,13,10,26,10])
        guard source.starts(with: signature) else { throw Failure.unavailable }
        var result = signature, offset = 8, ended = false
        let bytes = Array(source)
        while offset + 12 <= bytes.count {
            let count = Int(bytes[offset]) << 24 | Int(bytes[offset+1]) << 16 | Int(bytes[offset+2]) << 8 | Int(bytes[offset+3])
            guard count >= 0, count <= bytes.count - offset - 12 else { throw Failure.unavailable }
            let kind = String(bytes: bytes[(offset+4)..<(offset+8)], encoding: .ascii)
            if kind == "IHDR" {
                guard count == 13, bytes[offset+16] == 8, [2,6].contains(bytes[offset+17]), bytes[offset+20] == 0 else { throw Failure.unavailable }
            }
            if ["IHDR", "IDAT", "IEND"].contains(kind ?? "") { result.append(contentsOf: bytes[offset..<(offset + count + 12)]) }
            offset += count + 12
            if kind == "IEND" { ended = true; break }
        }
        guard ended, offset == bytes.count else { throw Failure.unavailable }
        return result
    }
    private final class Assets: NSObject, WKURLSchemeHandler {
        private let files: [String: CatalogPackageFile]
        init(package: CatalogPackage) { files = Dictionary(uniqueKeysWithValues: package.files.map { ($0.path, $0) }) }
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, url.scheme == CatalogPreviewRenderer.scheme, url.host == "package" else { urlSchemeTask.didFailWithError(Failure.unavailable); return }
            let path = String(url.path.dropFirst())
            guard CatalogContract.safePath(path), let file = files[path], let data = Data(base64Encoded: file.contentBase64), data.count == file.byteLength, CatalogContract.digest(data) == file.digest else { urlSchemeTask.didFailWithError(Failure.invalidPackage); return }
            let csp = "default-src 'none'; script-src screenpunk-preview: 'unsafe-inline'; style-src screenpunk-preview: 'unsafe-inline'; img-src screenpunk-preview: data:; font-src screenpunk-preview: data:; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src screenpunk-preview:; base-uri 'none'; form-action 'none'"
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": file.mediaType, "Content-Security-Policy": csp, "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"]) else { urlSchemeTask.didFailWithError(Failure.unavailable); return }
            urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { }
    }
}

/// Read-only access to an exact active dashboard render. A different revision,
/// changed assets, replaced view or navigation generation can never be labelled
/// as a requested old version.
@MainActor public final class CatalogPreviewCaptureRegistry {
    public static let shared = CatalogPreviewCaptureRegistry()
    public var onReady: ((String) -> Void)?
    private final class Entry {
        weak var view: WKWebView?
        let revision: String
        let assets: PackageAssetStore
        let context: CatalogPreviewContext?
        let generation = UUID()
        var active: Bool
        init(view: WKWebView, revision: String, assets: PackageAssetStore, context: CatalogPreviewContext?, active: Bool) { self.view = view; self.revision = revision; self.assets = assets; self.context = context; self.active = active }
    }
    private var entry: Entry?
    private var readinessTask: Task<Void, Never>?
    public func register(view: WKWebView, revision: String, assets: PackageAssetStore, context: CatalogPreviewContext?, active: Bool) {
        readinessTask?.cancel()
        entry = Entry(view: view, revision: revision, assets: assets, context: context, active: active)
    }
    public func setActive(view: WKWebView, active: Bool) { if entry?.view === view { entry?.active = active } }
    public func unregister(view: WKWebView) {
        guard entry?.view === view else { return }; readinessTask?.cancel(); readinessTask = nil; entry = nil
    }
    public func navigationStarted(view: WKWebView) {
        guard let old = entry, old.view === view else { return }
        register(view: view, revision: old.revision, assets: old.assets, context: old.context, active: old.active)
    }
    public func navigationFinished(view: WKWebView) {
        guard let current = entry, current.view === view else { return }
        let generation = current.generation
        readinessTask?.cancel()
        readinessTask = Task { [weak self, weak view] in
            for _ in 0..<30 {
                guard let self, let view, self.entry?.generation == generation, self.entry?.active == true, !Task.isCancelled else { return }
                if (try? await Self.isReady(view)) == true {
                    guard self.entry?.generation == generation, self.entry?.active == true else { return }
                    self.onReady?(current.revision); return
                }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }
    public func capture(context: CatalogPreviewContext, revision: String, package: CatalogPackage, packageDigest: String, byteLimit: Int, dimensionLimit: Int) async throws -> CatalogPreviewRenderer.Snapshot {
        guard let current = entry, current.active, current.context == context, current.revision == revision, let view = current.view, view.window != nil,
              CatalogPreviewCapturePolicy.allows(proof(current), scope: context, revision: revision, generation: current.generation, package: package, packageDigest: packageDigest),
              try await Self.isReady(view) else { throw CaptureError.notReady }
        let generation = current.generation
        guard entry?.generation == generation, entry?.context == context, entry?.revision == revision, entry?.active == true else { throw CaptureError.changed }
        let config = WKSnapshotConfiguration(); config.rect = view.bounds
        guard config.rect.width > 0, config.rect.height > 0 else { throw CaptureError.notReady }
        config.snapshotWidth = 1024; config.afterScreenUpdates = true
        let image = try await Self.snapshot(view, configuration: config)
        guard entry?.generation == generation, entry?.context == context, entry?.revision == revision, entry?.active == true, entry?.view === view, !Task.isCancelled,
              try await Self.isReady(view) else { throw CaptureError.changed }
        guard let final = entry, final.active, !Task.isCancelled,
              CatalogPreviewCapturePolicy.allows(proof(final), scope: context, revision: revision, generation: generation, package: package, packageDigest: packageDigest) else { throw CaptureError.changed }
        let encoded = try CatalogPreviewRenderer.encode(image: image, byteLimit: byteLimit, dimensionLimit: dimensionLimit)
        return .init(bytes: encoded.bytes, declaration: .init(byteLength: encoded.bytes.count, digest: CatalogContract.digest(encoded.bytes), mediaType: "image/png", width: encoded.width, height: encoded.height), packageDigest: packageDigest)
    }
    private func proof(_ entry: Entry) -> CatalogPreviewCaptureProof {
        .init(scope: entry.context, revision: entry.revision, generation: entry.generation,
              files: entry.assets.assets.mapValues { .init(byteLength: $0.data.count, digest: CatalogContract.digest($0.data)) })
    }
    static func isReady(_ view: WKWebView) async throws -> Bool {
        let script = #"""
        (() => {
          if(document.readyState!=='complete'||(document.fonts&&document.fonts.status!=='loaded'))return false;
          const visible=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none'&&r.bottom>0&&r.right>0&&r.top<innerHeight&&r.left<innerWidth};
          const text=(document.body?.innerText||'').trim();
          if(!text&&!Array.from(document.querySelectorAll('img,canvas,svg')).some(visible))return false;
          if(/\b(loading|connecting|please wait|unavailable|unable to load|failed to load|permission required)\b/i.test(text))return false;
          return Array.from(document.images).filter(visible).every(i=>i.complete&&i.naturalWidth>0);
        })()
        """#
        return try await withCheckedThrowingContinuation { continuation in
            let deadline = Completion<Bool>(continuation, seconds: 5)
            view.evaluateJavaScript(script) { value, error in
                if let error { deadline.finish(.failure(error)) }
                else { deadline.finish(.success((value as? Bool) == true)) }
            }
        }
    }
    fileprivate static func snapshot(_ view: WKWebView, configuration: WKSnapshotConfiguration) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            let deadline = Completion<UIImage>(continuation, seconds: 10)
            view.takeSnapshot(with: configuration) { image, error in
                if let image { deadline.finish(.success(image)) }
                else { deadline.finish(.failure(error ?? CaptureError.notReady)) }
            }
        }
    }
    @MainActor private final class Completion<Value> {
        private var continuation: CheckedContinuation<Value, Error>?
        private var timer: Task<Void, Never>?
        init(_ continuation: CheckedContinuation<Value, Error>, seconds: UInt64) {
            self.continuation = continuation
            timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
                self?.finish(.failure(CaptureError.notReady))
            }
        }
        func finish(_ result: Result<Value, Error>) {
            guard let value = continuation else { return }
            continuation = nil; timer?.cancel(); timer = nil; value.resume(with: result)
        }
    }
    private enum CaptureError: Error { case notReady, changed }
}

#endif
