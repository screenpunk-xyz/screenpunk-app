import XCTest
import WebKit
import ScreenpunkCore
@testable import ScreenpunkApple

final class ScreenDataBridgeTests: XCTestCase {
    @MainActor
    private final class Provider: ScreenDataProvider {
        var values: [String: AuthoringJSONValue] = [:]
        var queried: [String] = []
        var failure: ScreenDataError?
        func publish(name: String, value: AuthoringJSONValue) throws { values[name] = value }
        func remove(name: String) throws { values.removeValue(forKey: name) }
        func query(alias: String) async throws -> ScreenDataSnapshot {
            queried.append(alias)
            if let failure { throw failure }
            return .init(value: .null, version: 7, updatedAt: "2026-11-12T12:34:00.123Z", readAt: "2026-11-12T12:34:05.123Z")
        }
    }

    @MainActor
    func testBridgeRejectsSpoofedIdentityMissingCapabilityAndInactiveRuntime() throws {
        let provider = Provider()
        let declarations = ManifestScreenData(queries: [.init(alias: "feeding", screenId: "trusted-target", exportName: "lastFeeding")])
        var body: [String: Any] = ["protocolVersion": 1, "kind": "request", "id": "request", "method": "data.query", "alias": "feeding"]
        let request = try ScreenDataBridgeRequest(body: body)
        XCTAssertTrue(try request.authorizedProvider(provider, declaration: declarations, active: true) === provider)
        XCTAssertThrowsError(try request.authorizedProvider(nil, declaration: declarations, active: true)) { XCTAssertEqual($0 as? ScreenDataError, .unavailable) }
        XCTAssertThrowsError(try request.authorizedProvider(provider, declaration: declarations, active: false)) { XCTAssertEqual($0 as? ScreenDataError, .unavailable) }
        XCTAssertThrowsError(try request.authorizedProvider(provider, declaration: nil, active: true)) { XCTAssertEqual($0 as? ScreenDataError, .permissionRequired) }
        body["screenId"] = "forged-source"
        XCTAssertThrowsError(try ScreenDataBridgeRequest(body: body)) { XCTAssertEqual($0 as? ScreenDataError, .invalidRequest) }
    }

    #if os(macOS)
    @MainActor
    func testBundledSDKUsesNativeScopedProviderAndPreviewFailsSafely() async throws {
        let provider = Provider()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferenceStore = ScreenPreferenceStore(root: root)
        let html = Data("<!doctype html><title>Feeding fixture</title>".utf8)
        let manifest = DashboardManifest(schemaVersion: 1, dashboardId: "author-label", name: "Feeding fixture", revision: "fixture-revision",
            entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "test", width: 640, height: 360, scale: 1, orientation: "landscape"),
            connections: [], files: [.init(path: "index.html", bytes: html.count, sha256: AuthoringContract.contentDigest(html))],
            screenData: .init(exports: [.init(name: "lastFeeding", description: "Last recorded feeding time")],
                queries: [.init(alias: "feeding", screenId: "installed-target", exportName: "lastFeeding")]))
        let assets = PackageAssetStore(assets: [
            "index.html": .init(path: "index.html", data: html, mime: "text/html")
        ])
        func makeView(_ provider: Provider?) async throws -> (HomeAssistantWebBridge, WKWebView) {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            config.setURLSchemeHandler(PackageSchemeHandler(store: assets), forURLScheme: "screenpunk")
            let navigation = try DashboardEventRuntime(manifest: manifest, revision: manifest.revision, settings: .init(), homeAssistant: nil, connections: nil)
            let bridge = HomeAssistantWebBridge(runtime: nil, navigation: navigation, revision: manifest.revision,
                preferenceStore: preferenceStore, stateReadOnly: provider == nil, screenData: provider, onHealth: { _ in })
            let url = try XCTUnwrap(Bundle.module.url(forResource: "runtime-sdk", withExtension: "js"))
            config.userContentController.add(bridge, name: "screenpunk")
            config.userContentController.addUserScript(WKUserScript(source: try String(contentsOf: url), injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let view = WKWebView(frame: .zero, configuration: config)
            bridge.attach(to: view)
            view.load(URLRequest(url: URL(string: "screenpunk://package/index.html")!))
            for _ in 0..<100 {
                if (try? await view.evaluateJavaScript("document.readyState === 'complete' && !!globalThis.screenpunk?.data")) as? Bool == true { return (bridge, view) }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw ScreenDataError.timeout
        }
        func call(_ view: WKWebView, _ script: String) async throws -> Any? {
            try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        }
        let (bridge, view) = try await makeView(provider)
        defer { bridge.cancel() }
        let result = try await call(view, """
            await screenpunk.data.publish('lastFeeding', { fedAt: '2026-11-12T12:34:00Z' });
            const result = await screenpunk.data.query('feeding');
            return result.value === null && result.version === 7 && result.updatedAt === '2026-11-12T12:34:00.123Z';
            """)
        XCTAssertEqual(result as? Bool, true)
        XCTAssertEqual(provider.values["lastFeeding"], .object(["fedAt": .string("2026-11-12T12:34:00Z")]))
        XCTAssertEqual(provider.queried, ["feeding"])
        _ = try await call(view, "await screenpunk.data.remove('lastFeeding'); return true;")
        XCTAssertTrue(provider.values.isEmpty)
        let undeclared = try await call(view, "try { await screenpunk.data.query('undeclared'); } catch (error) { return error.code; }")
        XCTAssertEqual(undeclared as? String, "permission_required")
        XCTAssertEqual(provider.queried, ["feeding"])
        provider.failure = .notFound
        let absent = try await call(view, "try { await screenpunk.data.query('feeding'); } catch (error) { return error.code; }")
        XCTAssertEqual(absent as? String, "not_found")
        let (previewBridge, preview) = try await makeView(nil)
        defer { previewBridge.cancel() }
        let unavailable = try await call(preview, "try { await screenpunk.data.query('feeding'); } catch (error) { return error.code; }")
        XCTAssertEqual(unavailable as? String, "unavailable")
    }
    #endif
}
