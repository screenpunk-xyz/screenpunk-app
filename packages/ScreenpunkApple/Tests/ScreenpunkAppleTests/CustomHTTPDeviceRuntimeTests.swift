import Foundation
import XCTest
#if os(macOS)
import AppKit
import WebKit
#endif
import ScreenpunkCore
@testable import ScreenpunkApple

final class CustomHTTPDeviceRuntimeTests: XCTestCase {
    private let alias = "generator"
    private let screenID = "installed-one"
    private let owner = "owner"

    func testOwnerConfiguresReusableRecordAndScreenApprovalsStaySeparate() throws {
        let (vault, manifest, declaration) = try configured()
        XCTAssertTrue(vault.isApproved(owner: owner, screenID: screenID, manifest: manifest, alias: alias))
        XCTAssertFalse(vault.isApproved(owner: owner, screenID: "installed-two", manifest: manifest, alias: alias))
        XCTAssertFalse(vault.isApproved(owner: "other", screenID: screenID, manifest: manifest, alias: alias))
        XCTAssertEqual(vault.status(owner: owner, declaration: declaration)?.fields,
                       ["server": "https://example.test", "tag": "weekly"])
        XCTAssertTrue(vault.status(owner: owner, declaration: declaration)?.hasCredential == true)
        XCTAssertEqual(vault.savedServices(owner: owner).map(\.id), [declaration.id])
        var secondManifest = manifest
        secondManifest.connections[0].customHTTP?.operations[0].path = "/api/history"
        try vault.approve(owner: owner, screenID: "installed-two", manifest: secondManifest, alias: alias)
        XCTAssertFalse(vault.isApproved(owner: owner, screenID: screenID, manifest: secondManifest, alias: alias))

        try vault.revoke(owner: owner, screenID: screenID, alias: alias)
        XCTAssertFalse(vault.isApproved(owner: owner, screenID: screenID, manifest: manifest, alias: alias))
        XCTAssertTrue(vault.isApproved(owner: owner, screenID: "installed-two", manifest: secondManifest, alias: alias))

        try vault.save(owner: owner, declaration: declaration,
                       fields: ["server": "https://example.test", "tag": "daily"], allowInsecureHTTP: false)
        XCTAssertFalse(vault.isApproved(owner: owner, screenID: "installed-two", manifest: secondManifest, alias: alias))
        XCTAssertThrowsError(try vault.save(owner: owner, declaration: declaration,
                                           fields: ["server": "https://different.test", "tag": "daily"], allowInsecureHTTP: false))
        try vault.removeOwner(owner)
        XCTAssertTrue(vault.savedServices(owner: owner).isEmpty)
    }

    func testUnconfiguredReviewDoesNotSaveResolveOrSend() async throws {
        let (_, manifest, declaration) = try configured()
        let vault = CustomHTTPDeviceVault(store: MemoryCredentialStore())
        struct NoResolution: DestinationResolver {
            func addresses(for host: String) throws -> [String] {
                XCTFail("DNS must not run before approval")
                return []
            }
        }
        actor Prompts { var count = 0; func add() { count += 1 } }
        let prompts = Prompts()
        let transport = ProbeTransport(.init(status: 200, body: Data("{}".utf8)))
        let runtime = CustomHTTPDeviceRuntime(owner: owner, screenID: screenID, manifest: manifest,
            vault: vault, transport: transport, resolver: NoResolution(), accessRequired: { _ in await prompts.add() })
        do { _ = try await runtime.request(alias: alias, operation: "queue", parameters: ["limit":"3"]); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
        XCTAssertNil(vault.status(owner: owner, declaration: declaration))
        XCTAssertTrue(vault.savedServices(owner: owner).isEmpty)
        let sends = await transport.sends; let count = await prompts.count
        XCTAssertEqual(sends, 0); XCTAssertEqual(count, 1)
        try vault.deny(owner: owner, screenID: screenID, alias: alias, declaration: declaration)
        XCTAssertNil(vault.status(owner: owner, declaration: declaration))
        XCTAssertFalse(vault.shouldOfferAccess(owner: owner, screenID: screenID, alias: alias, declaration: declaration))
    }

    func testNativeReviewPrecedesAnyNetworkAndDenialSurvivesRuntimeRecreation() async throws {
        let (vault, manifest, declaration) = try configured()
        try vault.revoke(owner: owner, screenID: screenID, alias: alias)
        actor Prompts { var count = 0; func add() { count += 1 } }
        let prompts = Prompts()
        let transport = ProbeTransport(.init(status: 200, body: Data("{}".utf8)))
        let runtime = CustomHTTPDeviceRuntime(owner: owner, screenID: screenID, manifest: manifest,
            vault: vault, transport: transport, accessRequired: { _ in await prompts.add() })
        do { _ = try await runtime.request(alias: alias, operation: "queue", parameters: ["limit":"3"]); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
        let firstCount = await prompts.count
        let sends = await transport.sends
        XCTAssertEqual(firstCount, 1); XCTAssertEqual(sends, 0)
        try vault.deny(owner: owner, screenID: screenID, alias: alias, declaration: declaration)
        XCTAssertFalse(vault.shouldOfferAccess(owner: owner, screenID: screenID, alias: alias, declaration: declaration))
        XCTAssertTrue(vault.shouldOfferAccess(owner: "other", screenID: screenID, alias: alias, declaration: declaration))
        do { _ = try await runtime.request(alias: alias, operation: "queue", parameters: ["limit":"3"]); XCTFail() } catch {}
        let deniedCount = await prompts.count
        XCTAssertEqual(deniedCount, 1)
        XCTAssertEqual(vault.status(owner: owner, declaration: declaration)?.origin, "https://example.test")
        try vault.approve(owner: owner, screenID: screenID, manifest: manifest, alias: alias)
        XCTAssertTrue(vault.isApproved(owner: owner, screenID: screenID, manifest: manifest, alias: alias))
    }

    func testFixedGETAddsDeclaredQueryAndNativeBearerOnly() async throws {
        let (vault, manifest, _) = try configured()
        let transport = ProbeTransport(.init(status: 200, body: Data("{\"queue\":3}".utf8)))
        let runtime = broker(vault: vault, manifest: manifest, transport: transport)
        let response = try await runtime.request(alias: alias, operation: "queue", parameters: ["limit": "3"])
        XCTAssertEqual(response, Data("{\"queue\":3}".utf8))
        let last = await transport.last
        let request = try XCTUnwrap(last)
        XCTAssertEqual(request.url.absoluteString, "https://example.test/api/queue?limit=3&tag=weekly")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.headers, ["Accept": "application/json", "Authorization": "Bearer fixture-token"])
        XCTAssertNil(request.body)
        XCTAssertEqual(request.maxBytes, ConnectionBounds.httpResponseBytes)
        for parameters in [["tag": "override"], ["url": "https://elsewhere.test"], ["limit": "wrong"]] {
            do {
                _ = try await runtime.request(alias: alias, operation: "queue", parameters: parameters)
                XCTFail("An invalid parameter was accepted")
            } catch {
                XCTAssertTrue([.permissionRequired, .validationFailed].contains(error as? ConnectionFailure))
            }
        }
        let sends = await transport.sends
        XCTAssertEqual(sends, 1)
    }

    func testPlaintextRequiresExplicitPrivateLiteralAndRejectsUnsafeResolution() async throws {
        for origin in ["http://example.test", "http://127.0.0.1", "http://169.254.169.254"] {
            XCTAssertThrowsError(try configured(origin: origin, allowInsecureHTTP: true))
        }
        XCTAssertThrowsError(try configured(origin: "http://192.168.1.23:8080"))
        let (vault, manifest, _) = try configured(origin: "http://192.168.1.23:8080", allowInsecureHTTP: true, authenticated: false)
        let transport = ProbeTransport(.init(status: 200, body: Data("[]".utf8)))
        let runtime = broker(vault: vault, manifest: manifest, transport: transport, addresses: ["192.168.1.23"])
        _ = try await runtime.request(alias: alias, operation: "queue", parameters: [:])
        let request = await transport.last
        XCTAssertEqual(request?.url.absoluteString, "http://192.168.1.23:8080/api/queue?tag=weekly")
        XCTAssertNil(request?.headers["Authorization"])

        let unsafe = broker(vault: vault, manifest: manifest, transport: transport, addresses: ["192.168.1.23", "169.254.169.254"])
        do {
            _ = try await unsafe.request(alias: alias, operation: "queue", parameters: [:])
            XCTFail("A mixed unsafe destination was accepted")
        } catch { XCTAssertEqual(error as? ConnectionFailure, .deniedEgress) }
        let sends = await transport.sends
        XCTAssertEqual(sends, 1)
    }

    func testRedirectNonJSONAndEchoedBearerDoNotReachRenderer() async throws {
        let (vault, manifest, _) = try configured()
        let cases: [(HTTPTransportResponse, ConnectionFailure)] = [
            (.init(status: 302, body: Data("[]".utf8)), .deniedEgress),
            (.init(status: 200, body: Data("<html>".utf8)), .validationFailed),
            (.init(status: 200, body: Data(#"{ "echo": "fixture\u002dtoken" }"#.utf8)), .permissionRequired)
        ]
        for (response, reason) in cases {
            let runtime = broker(vault: vault, manifest: manifest, transport: ProbeTransport(response))
            do {
                _ = try await runtime.request(alias: alias, operation: "queue", parameters: [:])
                XCTFail("An unsafe response was accepted")
            } catch { XCTAssertEqual(error as? ConnectionFailure, reason) }
        }
    }

    func testRevokingAndReapprovingDuringIOInvalidatesOldRequest() async throws {
        let (vault, manifest, _) = try configured()
        let transport = ProbeTransport(.init(status: 200, body: Data("[]".utf8))) {
            try vault.revoke(owner: self.owner, screenID: self.screenID, alias: self.alias)
            try vault.approve(owner: self.owner, screenID: self.screenID, manifest: manifest, alias: self.alias)
        }
        let runtime = broker(vault: vault, manifest: manifest, transport: transport)
        do {
            _ = try await runtime.request(alias: alias, operation: "queue", parameters: [:])
            XCTFail("An old approval was accepted after being revoked")
        } catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
    }

    #if os(macOS)
    @MainActor
    func testBundledSDKRequestsGeneratorTelemetryInLiveWebKit() async throws {
        _ = NSApplication.shared
        let (vault, manifest, _) = try configured()
        let transport = ProbeTransport(.init(status: 200, body: Data(#"{"running":true,"queue":3}"#.utf8)))
        let runtime = broker(vault: vault, manifest: manifest, transport: transport)
        let html = Data("<!doctype html><title>Generator telemetry fixture</title>".utf8)
        let assets = PackageAssetStore(assets: [
            "index.html": .init(path: "index.html", data: html, mime: "text/html"),
            "manifest.json": .init(path: "manifest.json", data: try JSONEncoder().encode(manifest), mime: "application/json")
        ])
        let coordinator = DashboardWebCoordinator(store: assets, customHTTP: runtime, revision: manifest.revision, onReady: {}, onUnlinkHold: {})
        let view = coordinator.makeWebView()
        defer { coordinator.stop() }
        var loaded = false
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.readyState === 'complete' && !!globalThis.screenpunk?.connections")) as? Bool == true {
                loaded = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard loaded else {
            XCTFail("Local WebKit did not load the SDK")
            return
        }
        let result = try await view.callAsyncJavaScript("""
            const result = await screenpunk.connections.request("generator", "telemetry", {});
            return result.value.running === true && result.value.queue === 3 && result.stale === false;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
        let nativeRequest = await transport.last
        XCTAssertEqual(nativeRequest?.url.path, "/telemetry")
        XCTAssertEqual(nativeRequest?.headers["Authorization"], "Bearer fixture-token")

        try vault.revoke(owner: owner, screenID: screenID, alias: alias)
        let denied = try await view.callAsyncJavaScript("""
            try { await screenpunk.connections.request("generator", "telemetry", {}); }
            catch (error) { return error.code; }
            return "unexpected_success";
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(denied as? String, "permission_required")
        let sends = await transport.sends
        XCTAssertEqual(sends, 1)
    }
    #endif

    private func configured(origin: String = "https://example.test", allowInsecureHTTP: Bool = false,
                            authenticated: Bool = true) throws -> (CustomHTTPDeviceVault, DashboardManifest, CustomHTTPDeclaration) {
        var fields: [CustomHTTPField] = [.init(id: "server", label: "Server", type: "url"), .init(id: "tag", label: "Tag", type: "text")]
        if authenticated { fields.append(.init(id: "credential", label: "Access token", type: "secret")) }
        let declaration = CustomHTTPDeclaration(id: "test-generator", version: 1, label: "Generator", fields: fields,
            originField: "server", auth: authenticated ? .init(field: "credential") : nil,
            operations: [.init(name: "queue", path: "/api/queue",
                               parameters: ["limit": .init(type: "number"), "tag": .init(type: "text", field: "tag")]),
                         .init(name: "telemetry", path: "/telemetry")])
        let manifest = DashboardManifest(schemaVersion: 1, dashboardId: "package-label", name: "Generator", revision: "1",
            entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "test", width: 640, height: 360, scale: 1, orientation: "landscape"),
            connections: [.init(alias: alias, required: true, customHTTP: declaration)], files: [])
        let vault = CustomHTTPDeviceVault(store: MemoryCredentialStore())
        try vault.save(owner: owner, declaration: declaration, fields: ["server": origin, "tag": "weekly"],
                       secret: authenticated ? "fixture-token" : nil, allowInsecureHTTP: allowInsecureHTTP)
        try vault.approve(owner: owner, screenID: screenID, manifest: manifest, alias: alias)
        return (vault, manifest, declaration)
    }

    private func broker(vault: CustomHTTPDeviceVault, manifest: DashboardManifest, transport: any HTTPTransport,
                        addresses: [String] = ["203.0.113.1"]) -> CustomHTTPDeviceRuntime {
        .init(owner: owner, screenID: screenID, manifest: manifest, vault: vault, transport: transport,
              resolver: TestResolver(addresses: addresses))
    }

    private struct TestResolver: DestinationResolver {
        let addresses: [String]
        func addresses(for host: String) throws -> [String] { addresses }
    }

    private actor ProbeTransport: HTTPTransport {
        private let response: HTTPTransportResponse
        private let beforeResponse: @Sendable () throws -> Void
        private(set) var last: AuthorizedHTTPRequest?
        private(set) var sends = 0

        init(_ response: HTTPTransportResponse, beforeResponse: @escaping @Sendable () throws -> Void = {}) {
            self.response = response
            self.beforeResponse = beforeResponse
        }

        func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
            last = request
            sends += 1
            try beforeResponse()
            return response
        }
    }
}
