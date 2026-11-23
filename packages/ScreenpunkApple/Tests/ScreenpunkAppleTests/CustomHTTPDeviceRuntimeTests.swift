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

    func testApprovalFromOldPromptCannotGrantAccessToReplacementServer() throws {
        let (vault, manifest, declaration) = try configured()
        let old = try XCTUnwrap(vault.status(owner: owner, declaration: declaration))
        try vault.save(owner: owner, declaration: declaration, fields: ["server": "https://replacement.test", "tag": "weekly"],
                       secret: "fixture-token", allowInsecureHTTP: false)
        XCTAssertThrowsError(try vault.approve(owner: owner, screenID: screenID, manifest: manifest,
                                               alias: alias, expectedGeneration: old.generation))
        XCTAssertFalse(vault.isApproved(owner: owner, screenID: screenID, manifest: manifest, alias: alias))
    }

    func testSettingsOnlyShowsSavedBearerForItsCanonicalOrigin() throws {
        let (vault, _, declaration) = try configured(origin: "https://192.168.1.23")
        let status = try XCTUnwrap(vault.status(owner: owner, declaration: declaration))
        XCTAssertTrue(status.canReuseCredential(for: "https://192.168.1.23/", allowInsecureHTTP: false))
        for server in ["http://192.168.1.23", "https://192.168.1.23:444", "https://192.168.1.24", ""] {
            XCTAssertFalse(status.canReuseCredential(for: server, allowInsecureHTTP: true))
        }
    }

    func testDeviceBearerGenerationHashesExactWireBytes() throws {
        let one = try DeviceBearerCredential.generate()
        let two = try DeviceBearerCredential.generate()
        XCTAssertNotEqual(one.bearer, two.bearer)
        XCTAssertEqual(one.bearer.utf8.count, 43)
        XCTAssertEqual(one.verifier, AuthoringContract.contentDigest(Data(one.bearer.utf8)))
        XCTAssertEqual(one.verifier.utf8.count, 64)
        XCTAssertFalse(one.bearer.contains("="))
        XCTAssertNotEqual(one.verifier, DeviceBearerCredential.verifier(for: one.bearer + "\n"))
    }

    func testVerifierRegistrationStagesWithoutReplacingAndRequiresExactReview() throws {
        guard #available(iOS 18, macOS 15, *) else { throw XCTSkip("Certificate pin reviews unavailable") }
        let (vault, manifest, declaration) = try configured()
        let saved = try XCTUnwrap(vault.status(owner: owner, declaration: declaration))
        let context = try registrationContext(declaration: declaration, origin: "https://new.test",
                                              expectedGeneration: saved.generation)
        let fields = ["server": context.origin + ":443", "tag": "weekly"]
        let pending = try vault.prepareCredentialRegistration(owner: owner, context: context, now: 100)
        let same = try vault.prepareCredentialRegistration(owner: owner, context: context, now: 101)
        XCTAssertEqual(same, pending)
        XCTAssertEqual(vault.status(owner: owner, declaration: declaration), saved)
        XCTAssertTrue(vault.isApproved(owner: owner, screenID: screenID, manifest: manifest, alias: alias))
        let fingerprint = String(repeating: "a", count: 64)
        let pin = try ReviewedCertificatePin(origin: fields["server"]!, fingerprint: fingerprint)
        let wrongPin = try ReviewedCertificatePin(origin: fields["server"]!, fingerprint: String(repeating: "b", count: 64))
        func accept(_ reviewed: ReviewedCertificatePin, owner: String, values: [String: String], now: Int64 = 100) throws {
            try vault.acceptCredentialRegistration(owner: owner, declaration: declaration, fields: values,
                 registrationID: pending.registrationID, fingerprint: fingerprint, certificatePin: reviewed, now: now)
        }
        XCTAssertThrowsError(try accept(wrongPin, owner: owner, values: fields))
        XCTAssertThrowsError(try accept(pin, owner: "another", values: fields))
        XCTAssertThrowsError(try accept(pin, owner: owner, values: ["server": "https://wrong.test", "tag": "weekly"]))
        XCTAssertThrowsError(try accept(pin, owner: owner, values: fields, now: context.deadlineAt))
        try accept(pin, owner: owner, values: fields)
        XCTAssertEqual(vault.status(owner: owner, declaration: declaration)?.certificatePin, pin)
        XCTAssertFalse(vault.isApproved(owner: owner, screenID: screenID, manifest: manifest, alias: alias))
        XCTAssertThrowsError(try accept(pin, owner: owner, values: fields))
        XCTAssertThrowsError(try vault.save(owner: owner, declaration: declaration, fields: fields, allowInsecureHTTP: false))
        try vault.approve(owner: owner, screenID: screenID, manifest: manifest, alias: alias)
        var altered = manifest
        altered.connections[0].customHTTP?.operations[0].path = "/api/changed"
        XCTAssertThrowsError(try vault.approve(owner: owner, screenID: screenID, manifest: altered, alias: alias))
        try vault.remove(owner: owner, serviceID: declaration.id)
        XCTAssertFalse(vault.isApproved(owner: owner, screenID: screenID, manifest: manifest, alias: alias))
        XCTAssertEqual(try vault.credentialRegistrationRemovals(owner: owner, deviceID: context.deviceID).map(\.registrationID), [pending.registrationID])
        XCTAssertTrue(try vault.credentialRegistrationRemovals(owner: owner, deviceID: "different").isEmpty)
        try vault.confirmCredentialRegistrationRemoval(owner: owner, registrationID: pending.registrationID)
        XCTAssertTrue(try vault.credentialRegistrationRemovals(owner: owner, deviceID: context.deviceID).isEmpty)
    }

    func testRegistrationReceiptBindsSourceReadAndInstalledRevision() throws {
        let (vault, _, declaration) = try configured()
        let saved = try XCTUnwrap(vault.status(owner: owner, declaration: declaration))
        let context = try registrationContext(declaration: declaration, origin: saved.origin, expectedGeneration: saved.generation)
        let pending = try vault.prepareCredentialRegistration(owner: owner, context: context, now: 50)
        var wire: [String: Any] = [
            "version": 1, "registrationID": pending.registrationID, "requestID": context.requestID,
            "inputDigest": context.inputDigest, "operationID": context.operationID, "deviceID": context.deviceID,
            "screenID": context.screenID, "screenRevision": context.revision, "alias": context.alias,
            "serviceID": context.serviceID, "origin": context.origin, "readPath": context.readPath,
            "declarationDigest": context.declarationDigest, "expiresAt": context.deadlineAt
        ]
        func decode() throws -> CredentialRegistrationReceipt {
            try JSONDecoder().decode(CredentialRegistrationReceipt.self, from: JSONSerialization.data(withJSONObject: wire))
        }
        XCTAssertTrue(try decode().isCurrent(for: pending, now: 50))
        XCTAssertFalse(try decode().isCurrent(for: pending, now: context.deadlineAt))
        wire["expiresAt"] = context.deadlineAt + 1
        XCTAssertFalse(try decode().matches(pending))
        wire["expiresAt"] = context.deadlineAt
        for key in ["registrationID", "screenRevision", "readPath", "deviceID", "declarationDigest"] {
            let valid = wire[key]
            wire[key] = "different"
            XCTAssertFalse(try decode().matches(pending))
            wire[key] = valid
        }
        try vault.requestCredentialRegistrationRemoval(owner: owner, registrationID: pending.registrationID)
        XCTAssertEqual(vault.status(owner: owner, declaration: declaration), saved)
        XCTAssertEqual(try vault.credentialRegistrationRemovals(owner: owner, deviceID: context.deviceID).first?.registrationID, pending.registrationID)
        XCTAssertThrowsError(try vault.prepareCredentialRegistration(owner: owner, context: context, now: 51))
    }

    func testCancellationBeforeFirstPostRequiresExactLocalBinding() throws {
        let (vault, _, declaration) = try configured()
        let saved = try XCTUnwrap(vault.status(owner: owner, declaration: declaration))
        let context = try registrationContext(declaration: declaration, origin: saved.origin, expectedGeneration: saved.generation)
        let prepared = try vault.prepareCredentialRegistration(owner: owner, context: context, now: 100)
        try vault.requestCredentialRegistrationRemoval(owner: owner, registrationID: prepared.registrationID)
        let removal = try XCTUnwrap(vault.credentialRegistrationRemovals(owner: owner, deviceID: context.deviceID).first)
        var wire: [String: Any] = [
            "status": "removed", "cancelledBeforeStart": true, "registrationID": removal.registrationID,
            "requestID": context.requestID, "deviceID": context.deviceID, "alias": context.alias,
            "screenRevision": context.revision, "deadlineAt": context.deadlineAt
        ]
        let origin = "https://cloud.test"
        func decode() throws -> CredentialRegistrationRemovalAcknowledgement {
            try JSONDecoder().decode(CredentialRegistrationRemovalAcknowledgement.self, from: JSONSerialization.data(withJSONObject: wire))
        }
        XCTAssertTrue(try decode().confirmsRemoval(of: removal, relayOrigin: origin))
        XCTAssertFalse(try decode().confirmsRemoval(of: prepared, relayOrigin: origin))
        for key in ["registrationID", "requestID", "deviceID", "alias", "screenRevision", "deadlineAt"] {
            let value = wire.removeValue(forKey: key)
            XCTAssertFalse(try decode().confirmsRemoval(of: removal, relayOrigin: origin))
            wire[key] = value
        }
    }

    func testLocalConnectionNameIsOwnerScoped() throws {
        let store = MemoryCredentialStore()
        let vault = CustomHTTPDeviceVault(store: store)
        try vault.renameConnection(owner: owner, serviceID: "fixture", name: "  Friendly name  ")
        XCTAssertEqual(vault.connectionName(owner: owner, serviceID: "fixture"), "Friendly name")
        XCTAssertNil(vault.connectionName(owner: "other", serviceID: "fixture"))
        XCTAssertThrowsError(try vault.renameConnection(owner: owner, serviceID: "fixture", name: "invalid\nname"))
        try vault.removeOwner(owner)
        XCTAssertNil(vault.connectionName(owner: owner, serviceID: "fixture"))
    }

    private func registrationContext(declaration: CustomHTTPDeclaration, origin: String,
                                     expectedGeneration: UUID?) throws -> CredentialRegistrationContext {
        try .init(requestID: "fixture-request", inputDigest: String(repeating: "2", count: 64),
            operationID: "fixture-operation", deviceID: "fixture-device", screenID: screenID, alias: alias,
            serviceID: declaration.id, origin: origin, readPath: "/api/queue",
            declarationDigest: CredentialRegistrationContext.declarationDigest(declaration),
            deadlineAt: 900_000, revision: "fixture-revision", expectedGeneration: expectedGeneration)
    }

    func testCertificateRotationRequiresFreshApprovalAndCannotMoveToAnotherOrigin() throws {
        guard #available(macOS 15, iOS 18, *) else { throw XCTSkip("Pinning unavailable") }
        let origin = "https://192.168.1.23"
        let (vault, manifest, declaration) = try configured(origin: origin)
        let fields = ["server": origin, "tag": "weekly"]
        for digit in ["1", "2"] {
            let pin = try ReviewedCertificatePin(origin: origin, fingerprint: String(repeating: digit, count: 64))
            try vault.save(owner: owner, declaration: declaration, fields: fields, allowInsecureHTTP: false, certificatePin: pin)
            XCTAssertFalse(vault.isApproved(owner: owner, screenID: screenID, manifest: manifest, alias: alias))
            XCTAssertEqual(vault.status(owner: owner, declaration: declaration)?.certificatePin, pin)
            XCTAssertTrue(vault.status(owner: owner, declaration: declaration)?.hasCredential == true)
            try vault.approve(owner: owner, screenID: screenID, manifest: manifest, alias: alias)
            XCTAssertThrowsError(try vault.save(owner: owner, declaration: declaration,
                fields: ["server": origin + ":444", "tag": "weekly"], secret: "fixture", allowInsecureHTTP: false, certificatePin: pin))
        }
        try vault.save(owner: owner, declaration: declaration, fields: fields, allowInsecureHTTP: false)
        XCTAssertFalse(vault.isApproved(owner: owner, screenID: screenID, manifest: manifest, alias: alias))
        XCTAssertNil(vault.status(owner: owner, declaration: declaration)?.certificatePin)
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
