import Foundation
import ScreenpunkCore
#if canImport(WebKit)
import WebKit
#endif

/// Native host isolation. Custom scheme serves package-local assets only.
public enum WebIsolation: Sendable {
    public static var customScheme: String { IsolationPolicy.customScheme }
    public static var contentSecurityPolicy: String { IsolationPolicy.contentSecurityPolicy }
    public static var contentRuleListJSON: String { IsolationPolicy.contentRuleListJSON }
    public static var nativeNetworkingOnly: Bool { IsolationPolicy.nativeNetworkingOnly }

    public static func evaluate(_ request: IsolationRequest) -> IsolationDecision {
        IsolationEvaluator.decide(request)
    }

    public static func recoverAfterContentProcessCrash() -> String {
        ContentProcessFailure.simulateTermination()
    }
}

#if canImport(WebKit)
public final class PackageSchemeHandler: NSObject, WKURLSchemeHandler {
    public let store: PackageAssetStore
    public let rasterResources: PublicRasterResources?
    private var transfers: [ObjectIdentifier: Task<Void, Never>] = [:]

    public init(store: PackageAssetStore, rasterResources: PublicRasterResources? = nil) {
        self.rasterResources = rasterResources
        self.store = store
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url
        let absolute = url?.absoluteString ?? ""
        do {
            let asset: PackageAsset
            if absolute.hasPrefix("screenpunk://package/__native-raster/") {
                guard let rasterResources else { throw PackageAssetError.denied }
                asset = try rasterResources.asset(url: absolute)
            } else { asset = try store.asset(forSchemeURL: absolute) }
            guard let url else { throw PackageAssetError.denied }
            let media = PackageMediaResponse(asset: asset,
                range: urlSchemeTask.request.value(forHTTPHeaderField: "Range"),
                method: urlSchemeTask.request.httpMethod ?? "GET")
            var headers = media.headers
            headers["Content-Security-Policy"] = IsolationPolicy.contentSecurityPolicy
            headers["Cache-Control"] = "no-store"
            headers["X-Content-Type-Options"] = "nosniff"
            let response = HTTPURLResponse(
                url: url,
                statusCode: media.status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            urlSchemeTask.didReceive(response)
            if media.data.count <= Self.transferChunkBytes {
                urlSchemeTask.didReceive(media.data)
                urlSchemeTask.didFinish()
                return
            }

            let id = ObjectIdentifier(urlSchemeTask)
            let body = media.data
            transfers[id] = Task { @MainActor [weak self] in
                var offset = body.startIndex
                while offset < body.endIndex {
                    guard !Task.isCancelled, self != nil else { return }
                    let end = offset + min(Self.transferChunkBytes, body.endIndex - offset)
                    autoreleasepool {
                        urlSchemeTask.didReceive(body.subdata(in: offset..<end))
                    }
                    offset = end
                    await Task.yield()
                }
                guard !Task.isCancelled, let self else { return }
                self.transfers[id] = nil
                urlSchemeTask.didFinish()
            }
        } catch {
            let code: URLError.Code = (error as? PackageAssetError) == .missingFile
                ? .fileDoesNotExist : .noPermissionsToReadFile
            urlSchemeTask.didFailWithError(URLError(code))
        }
    }

    private static let transferChunkBytes = 256 * 1024

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        transfers.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}
#endif
