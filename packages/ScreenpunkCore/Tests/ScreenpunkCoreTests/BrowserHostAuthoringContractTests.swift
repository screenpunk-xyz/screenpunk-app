import Foundation
import XCTest
@testable import ScreenpunkCore

final class BrowserHostAuthoringContractTests: XCTestCase {
    private struct ManifestCase: Decodable { var name: String; var accepted: Bool; var manifest: AuthoringJSONValue }
    private struct Vectors: Decodable {
        var request: AuthoringRequestV1
        var legacyOfflineRequest: AuthoringRequestV1
        var legacyDigests: [String]
        var filePaths: [String]
        var manifestCases: [ManifestCase]
    }
    private func resource(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "AuthoringResources")))
    }
    private func vectors() throws -> Vectors { try JSONDecoder().decode(Vectors.self, from: resource("conformance-browser-host-v1")) }
    private func nativeRequest() throws -> AuthoringRequestV1 {
        let fixture = try JSONSerialization.jsonObject(with: resource("conformance-v1")) as! [String: Any]
        return try AuthoringContract.validateRequest(JSONSerialization.data(withJSONObject: fixture["request"]!))
    }
    func testSharedHostAndLegacySealedDigestsRemainExact() throws {
        let f = try vectors()
        XCTAssertEqual(try AuthoringContract.seal(f.request), f.request)
        XCTAssertEqual(try AuthoringContract.seal(f.legacyOfflineRequest), f.legacyOfflineRequest)
        XCTAssertEqual(try AuthoringContract.seal(nativeRequest()).delivery.snapshotDigest, f.legacyDigests[0])
        XCTAssertEqual(f.request.runtime, AuthoringContract.browserHostRuntime)
        XCTAssertEqual(f.request.designGuidance, AuthoringContract.browserHostDesignGuidance)
        XCTAssertFalse(f.request.runtime.features.contains("data.query"))
    }
    func testIndependentCapabilityObservationsAndUnknownDefaults() throws {
        let services = AuthoringContract.makeBrowserHostServices(observedAt: 30, observations: [
            "configured": .init(state: "yes", observedAt: 10), "authorized": .init(state: "no", observedAt: 20)
        ])
        XCTAssertEqual(services.map(\.provider), ["publicHTTP"])
        XCTAssertEqual(services[0].configured.observedAt, 10)
        XCTAssertEqual(services[0].authorized, .init(state: "no", observedAt: 20))
        XCTAssertEqual(services[0].reachable.state, "unknown")
        XCTAssertEqual(AuthoringContract.makeBrowserHostServices(observedAt: 30)[0].authorized.state, "unknown")
        var future = try vectors().request
        future.services[0].authorized.observedAt = future.createdAt + 1
        XCTAssertThrowsError(try AuthoringContract.seal(future))
    }
    func testRejectsMixedProfilesNativeDescriptorsAndPreferences() throws {
        let original = try vectors().request
        var request = original; request.designGuidance = AuthoringContract.browserDesignGuidance
        XCTAssertThrowsError(try AuthoringContract.seal(request))
        request = original; request.runtime.features.append("data.query")
        XCTAssertThrowsError(try AuthoringContract.seal(request))
        request = original; request.services = AuthoringContract.makeServices(observedAt: request.createdAt)
        XCTAssertThrowsError(try AuthoringContract.seal(request))
        request = original; request.services[0] = try XCTUnwrap(AuthoringContract.makeServices(observedAt: request.createdAt).first { $0.provider == "publicHTTP" })
        XCTAssertThrowsError(try AuthoringContract.seal(request))
        request = original; request.services[0].id = "home"
        XCTAssertThrowsError(try AuthoringContract.seal(request))
        request = original; request.preferences = try nativeRequest().preferences
        XCTAssertThrowsError(try AuthoringContract.seal(request))
        request = try nativeRequest(); request.services = original.services
        XCTAssertThrowsError(try AuthoringContract.seal(request))
    }
    func testSharedManifestAdmissionAndPreferenceMutationRejection() throws {
        let f = try vectors()
        for item in f.manifestCases {
            let manifest = String(decoding: try JSONEncoder().encode(item.manifest), as: UTF8.self)
            if item.accepted { XCTAssertNoThrow(try AuthoringContract.validateBrowserHostManifest(manifest, filePaths: f.filePaths), item.name) }
            else { XCTAssertThrowsError(try AuthoringContract.validateBrowserHostManifest(manifest, filePaths: f.filePaths), item.name) }
        }
        var result = AuthoringResultV1(requestID: f.request.requestID, inputDigest: f.request.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "browser-host", answer: "Ready")
        result.screen = .init(title: "Weather", files: [.init(path: "index.html", content: "<h1>Weather</h1>"),
            .init(path: "manifest.json", content: String(decoding: try JSONEncoder().encode(f.manifestCases[1].manifest), as: UTF8.self))])
        XCTAssertNoThrow(try AuthoringContract.validateResult(JSONEncoder().encode(result), request: f.request))
        result.screen!.files[1].content = "{\"connections\":[{\"alias\":\"home\",\"required\":true}]}"
        XCTAssertThrowsError(try AuthoringContract.validateResult(JSONEncoder().encode(result), request: f.request))
        result.screen = nil
        result.preferenceMutations = [.init(kind: "delete", id: "old", expectedRevision: 1)]
        result.durablePreferenceAuthorization = .init(requestID: f.request.requestID, quote: "remember")
        XCTAssertThrowsError(try AuthoringContract.validateResult(JSONEncoder().encode(result), request: f.request))
    }
    private func resultV2(_ request: AuthoringRequestV2, files: [[String: String]]) throws -> AuthoringResultV2 {
        let object: [String: Any] = ["schemaVersion": 2, "requestID": request.requestID, "inputDigest": request.delivery.snapshotDigest,
            "baseRevision": request.context.baseRevision as Any? ?? NSNull(), "preferenceRevisions": [:], "operationID": "browser-v2",
            "screen": ["title": "Local", "entry": "index.html", "files": files, "deletedPaths": []]]
        return try JSONDecoder().decode(AuthoringResultV2.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testV2MaterializationCannotAdmitUnsupportedOpaqueManifest() throws {
        let f = try vectors(); let request = try AuthoringV2Contract.makeRequest(from: f.request, libraryID: "browser-library")
        let valid = try resultV2(request, files: [["kind": "write", "path": "index.html", "content": "<h1>Local</h1>"], ["kind": "write", "path": "manifest.json", "content": "{}"]])
        XCTAssertNoThrow(try AuthoringV2Contract.materialize(valid, request: request) { _ in throw AuthoringContractError("No references") })
        var base = f.request; base.context.baseRevision = "existing"
        base.context.currentScreen = .init(title: "Existing", files: [.init(path: "index.html", content: "<h1>Existing</h1>"), .init(path: "manifest.json", content: "{\"connections\":[{\"alias\":\"home\",\"required\":true}]}")])
        let retained = try AuthoringV2Contract.makeRequest(from: AuthoringContract.seal(base), libraryID: "browser-library", includeContent: { _ in false })
        let copy = try resultV2(retained, files: retained.context.currentScreen!.files.map { ["kind": "retain", "path": $0.path, "sourcePath": $0.path, "reference": $0.reference, "digest": $0.digest] })
        XCTAssertNoThrow(try AuthoringV2Contract.validateResult(JSONEncoder().encode(copy), request: retained))
        XCTAssertThrowsError(try AuthoringV2Contract.materialize(copy, request: retained) { file in
            Data(base.context.currentScreen!.files.first { $0.path == file.path }!.content.utf8)
        })
    }
}
