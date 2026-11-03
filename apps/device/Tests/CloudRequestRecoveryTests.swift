import Foundation
import XCTest
import ScreenpunkCore
@testable import DeviceAuthoring

final class CloudRequestRecoveryTests: XCTestCase {
    private let expiredNow: Double = 602_000

    private func response(version: Int = 2, status: String = "completed", receiptStatus: String? = nil,
                          receiptPatch: [String: Any] = [:]) throws -> Data {
        let v1 = try AuthoringContract.seal(.init(requestID: "old-request", createdAt: 1_000, deadlineAt: 601_000,
            designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime, services: [],
            context: .init(profileID: "profile", deviceID: "device", screenID: "screen", baseRevision: nil,
                userRequest: "Hello", viewport: .init(width: 1024, height: 768, orientation: "landscape")), delivery: .init(route: "cloud")))
        let v2 = try AuthoringV2Contract.makeRequest(from: v1, libraryID: "library")
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        let digest = version == 2 ? v2.delivery.snapshotDigest : v1.delivery.snapshotDigest
        var data: [String: Any] = ["id": "old-request", "status": status, "createdAt": 1_000, "deadlineAt": 601_000,
            "snapshot": try version == 2 ? object(v2) : object(v1)]
        if status == "completed" {
            if version == 2 {
                data["authoringResult"] = try object(AuthoringResultV2(requestID: "old-request", inputDigest: digest, baseRevision: nil,
                    preferenceRevisions: [:], operationID: "operation", answer: "Already finished"))
            } else {
                data["authoringResult"] = try object(AuthoringResultV1(requestID: "old-request", inputDigest: digest, baseRevision: nil,
                    preferenceRevisions: [:], operationID: "operation", answer: "Already finished"))
            }
        }
        if let receiptStatus {
            var receipt = try XCTUnwrap(try object(ApplicationReceiptV1(requestID: "old-request", operationID: "operation",
                inputDigest: digest, status: receiptStatus, appliedAt: 2_000)) as? [String: Any])
            receipt.merge(receiptPatch) { _, new in new }; data["applicationReceipt"] = receipt
        }
        return try JSONSerialization.data(withJSONObject: data)
    }

    func testAlreadyAppliedExpiredV1AndV2ResultsAreSettledWithoutReapplication() throws {
        let v1 = try JSONDecoder().decode(AgentRequest.self, from: response(version: 1, receiptStatus: "applied"))
        let v2 = try JSONDecoder().decode(AgentRequestV2.self, from: response(receiptStatus: "applied"))
        XCTAssertEqual(try v1.deliveryState(requestID: "old-request", now: expiredNow), .ended(status: CloudRequestRecovery.alreadyAppliedStatus, message: nil))
        XCTAssertEqual(try v2.deliveryState(requestID: "old-request", now: expiredNow), .ended(status: CloudRequestRecovery.alreadyAppliedStatus, message: nil))
    }

    func testLocallyPendingCompletedResultsWinOverExpiredDeadlineWithoutReceipt() throws {
        let v1 = try JSONDecoder().decode(AgentRequest.self, from: response(version: 1))
        let v2 = try JSONDecoder().decode(AgentRequestV2.self, from: response())
        XCTAssertEqual(try v1.deliveryState(requestID: "old-request", now: expiredNow), .completed(try XCTUnwrap(v1.authoringResult)))
        XCTAssertEqual(try v2.deliveryState(requestID: "old-request", now: expiredNow), .completed(try XCTUnwrap(v2.authoringResult)))
    }

    func testAuthoritativelyPendingExpiredRequestsStillTimeOutForV1AndV2() throws {
        let v1 = try JSONDecoder().decode(AgentRequest.self, from: response(version: 1, status: "pending"))
        let v2 = try JSONDecoder().decode(AgentRequestV2.self, from: response(status: "pending"))
        XCTAssertEqual(try v1.deliveryState(requestID: "old-request", now: expiredNow), .ended(status: "timed_out", message: nil))
        XCTAssertEqual(try v2.deliveryState(requestID: "old-request", now: expiredNow), .ended(status: "timed_out", message: nil))
    }

    @MainActor func testFreshLibraryWithRestoredIdentityDoesNotAdoptTerminalCloudHistory() async throws {
        // A new container has neither consumed IDs nor local receipts, even when
        // its retained Cloud identity points to the account's previous request.
        for status in ["completed", "failed", "timed_out", "cancelled", "unknown"] {
            var reads = 0
            let restored = try await CloudRequestRecovery.discoverPending(id: "old-request", status: status,
                consumedID: nil, lastAppliedRequestID: nil, now: expiredNow) { _ in
                reads += 1; return try JSONDecoder().decode(AgentRequest.self, from: self.response(status: status))
            }
            XCTAssertNil(restored); XCTAssertEqual(reads, 0)
        }
    }

    @MainActor func testPendingSummaryThatCompletesBeforeFetchIsNotReplayed() async throws {
        for receipt in [nil, "applied"] as [String?] {
            let restored = try await CloudRequestRecovery.discoverPending(id: "old-request", status: "pending",
                consumedID: nil, lastAppliedRequestID: nil, now: 3_000) { _ in
                try JSONDecoder().decode(AgentRequest.self, from: self.response(receiptStatus: receipt))
            }
            XCTAssertNil(restored)
        }
    }

    @MainActor func testRestoresOnlyUnexpiredInFlightWorkAndNeverConsumedWork() async throws {
        for (consumed, applied, now, expectedReads, expectedRequest) in [
            (nil, nil, 3_000.0, 1, true), ("old-request", nil, 3_000.0, 0, false),
            (nil, "old-request", 3_000.0, 0, false), (nil, nil, expiredNow, 1, false),
        ] as [(String?, String?, Double, Int, Bool)] {
            var reads = 0
            let restored = try await CloudRequestRecovery.discoverPending(id: "old-request", status: "pending",
                consumedID: consumed, lastAppliedRequestID: applied, now: now) { id in
                XCTAssertEqual(id, "old-request"); reads += 1
                return try JSONDecoder().decode(AgentRequest.self, from: self.response(status: "pending"))
            }
            XCTAssertEqual(restored != nil, expectedRequest); XCTAssertEqual(reads, expectedReads)
        }
    }

    @MainActor func testOfflineDiscoveryCannotReturnWorkOrClassifyItAsTimedOut() async throws {
        do {
            _ = try await CloudRequestRecovery.discoverPending(id: "old-request", status: "pending",
                consumedID: nil, lastAppliedRequestID: nil, now: expiredNow) { _ in throw URLError(.notConnectedToInternet) }
            XCTFail("An unavailable authoritative read must remain unconfirmed")
        } catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
    }

    func testReceiptBindingAndCurrentFailuresRemainEnforced() throws {
        for patch in [["requestID": "different"], ["inputDigest": "different"], ["operationID": "different"]] {
            let v2 = try JSONDecoder().decode(AgentRequestV2.self, from: response(receiptStatus: "applied", receiptPatch: patch))
            XCTAssertThrowsError(try v2.deliveryState(requestID: "old-request", now: expiredNow))
        }
        let applied = try JSONDecoder().decode(AgentRequestV2.self, from: response(receiptStatus: "applied"))
        XCTAssertThrowsError(try applied.deliveryState(requestID: "different", now: expiredNow))
        var missingSnapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: response(receiptStatus: "applied")) as? [String: Any])
        missingSnapshot.removeValue(forKey: "snapshot")
        let unbound = try JSONDecoder().decode(AgentRequestV2.self, from: JSONSerialization.data(withJSONObject: missingSnapshot))
        XCTAssertThrowsError(try unbound.deliveryState(requestID: "old-request", now: expiredNow))
        for status in ["failed", "cancelled", "timed_out"] {
            let v2 = try JSONDecoder().decode(AgentRequestV2.self, from: response(status: status))
            XCTAssertEqual(try v2.deliveryState(requestID: "old-request", now: expiredNow), .ended(status: status, message: nil))
        }
        let conflict = try JSONDecoder().decode(AgentRequestV2.self, from: response(receiptStatus: "conflict"))
        guard case .ended(status: "conflict", message: .some) = try conflict.deliveryState(requestID: "old-request", now: expiredNow) else {
            return XCTFail("A current application conflict must remain visible")
        }
    }
}
