import Foundation
import XCTest
import ScreenpunkCore
@testable import DeviceAuthoring

final class CloudAuthoringWireTests: XCTestCase {
    private func snapshot() throws -> AuthoringRequestV2 {
        let v1 = try AuthoringContract.seal(.init(requestID: "wire-request", createdAt: 1_000, deadlineAt: 601_000, designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime, services: [],
            context: .init(profileID: "profile-one", deviceID: "device-one", screenID: "screen-one", baseRevision: "revision-one",
                userRequest: "Make the screen calm", currentScreen: .init(title: "Photo", files: [
                    .init(path: "index.html", content: "<html><body><img src=\"photo.svg\"></body></html>"),
                    .init(path: "photo.svg", content: "<svg><image href=\"data:image/png;base64,c3ludGhldGlj\"/></svg>")]),
                viewport: .init(width: 1024, height: 768, orientation: "landscape")), delivery: .init(route: "cloud")))
        return try AuthoringV2Contract.makeRequest(from: v1, libraryID: "library-one")
    }
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    func testCapabilitiesFailClosedBeforeRetentionSelection() throws {
        XCTAssertFalse(CloudAuthoringCapabilities.unavailable.supportsV2)
        XCTAssertFalse(CloudAuthoringCapabilities(contractVersions: ["1"], features: ["asset-references-v2"]).supportsV2)
        XCTAssertFalse(CloudAuthoringCapabilities(contractVersions: ["1", "2"], features: []).supportsV2)
        XCTAssertTrue(CloudAuthoringCapabilities(contractVersions: ["1", "2"], features: ["asset-references-v2"]).supportsV2)
    }
    func testWireAcceptsLogicalV2ResponseWithoutAssetBytes() throws {
        let request = try snapshot()
        XCTAssertNil(request.context.currentScreen?.files.first(where: { $0.path == "photo.svg" })?.content)
        let files = request.context.currentScreen!.files.map { AuthoringFileMutationV2.retain(path: $0.path, sourcePath: $0.path, reference: $0.reference, digest: $0.digest) }
        let result = AuthoringResultV2(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, baseRevision: request.context.baseRevision,
            preferenceRevisions: [:], operationID: "wire-operation", screen: .init(title: "Retained photo", files: files))
        let data = try JSONSerialization.data(withJSONObject: ["snapshot": object(request), "authoringResult": object(result)])
        XCTAssertNoThrow(try DeviceAuthoringWire.validateResponse(data))
        let responseData = try JSONSerialization.data(withJSONObject: ["id": request.requestID, "status": "completed", "snapshot": object(request), "authoringResult": object(result)])
        let response = try JSONDecoder().decode(AgentRequest.self, from: responseData)
        XCTAssertEqual(response.snapshotV2, request); XCTAssertEqual(response.authoringResultV2, result)
        XCTAssertNil(response.snapshot); XCTAssertNil(response.authoringResult)
        var invalid = try XCTUnwrap(try object(result) as? [String: Any]); invalid["unexpected"] = true
        XCTAssertThrowsError(try DeviceAuthoringWire.validateResponse(JSONSerialization.data(withJSONObject: ["snapshot": object(request), "authoringResult": invalid])))
    }
    func testWireRejectsDowngradeAndCrossSnapshotResults() throws {
        let request = try snapshot()
        let legacy = AuthoringResultV1(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, baseRevision: request.context.baseRevision,
            preferenceRevisions: [:], operationID: "wire-operation", answer: "Legacy")
        XCTAssertThrowsError(try DeviceAuthoringWire.validateResponse(JSONSerialization.data(withJSONObject: ["snapshot": object(request), "authoringResult": object(legacy)])))
        let swapped = AuthoringResultV2(requestID: "other-request", inputDigest: request.delivery.snapshotDigest, baseRevision: request.context.baseRevision,
            preferenceRevisions: [:], operationID: "wire-operation", answer: "Wrong snapshot")
        XCTAssertThrowsError(try DeviceAuthoringWire.validateResponse(JSONSerialization.data(withJSONObject: ["snapshot": object(request), "authoringResult": object(swapped)])))
    }
}
