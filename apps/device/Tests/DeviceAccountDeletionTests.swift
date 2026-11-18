import Foundation
import XCTest
@testable import DeviceAuthoring

final class DeviceAccountDeletionTests: XCTestCase {
    private func intent() -> DeviceAccountDeletionIntent {
        var value = DeviceAccountDeletionIntent(origin: "https://staging.screenpunk.xyz", accountID: "A", serverAccountID: "A",
              operationID: "operation", profiles: [], preferenceKeys: [], billingJournalOwner: nil)
        value.appleRevocationConsent = "REVOKE"
        return value
    }
    private enum Failure: Error { case interrupted }

    @MainActor func testSafeServerDiagnosticSurvivesRestartWithoutRetryOrTokenExposure() async throws {
        var saved: DeviceAccountDeletionIntent?
        do {
            _ = try await DeviceAccountDeletionTransaction.perform(intent(), prepare: {
                .init(operationID: "operation", deletionToken: "synthetic-capability")
            }, execute: { received, _ in
                let data = try JSONSerialization.data(withJSONObject: ["deleted": false, "retryable": true,
                    "operationID": received.operationID, "deletionToken": "never-display-this-capability", "error": "deletion_incomplete",
                    "stage": "auth_cleanup", "category": "request_limit"])
                try DeviceAccountDeletionTransaction.validateHTTPResponse(data, status: 503, operationID: received.operationID)
                throw Failure.interrupted
            }, persist: { saved = $0 })
            XCTFail("Expected pending response")
        } catch let failure as DeviceAccountDeletionFailure {
            XCTAssertFalse(failure.localizedDescription.contains("never-display-this-capability"))
        }
        let restored = try JSONDecoder().decode(DeviceAccountDeletionIntent.self, from: JSONEncoder().encode(try XCTUnwrap(saved)))
        XCTAssertEqual(restored.lastFailure?.supportCode, "auth_cleanup / request_limit")
        XCTAssertFalse(restored.serverConfirmed)
        XCTAssertEqual(restored.deletionToken, "synthetic-capability")
        XCTAssertEqual(restored.appleRevocationConsent, "REVOKE")
    }

    func testUnknownOptionalDiagnosticFieldsAreDiscardedWithoutRejectingOlderContract() throws {
        for details in [[:], ["stage": "untrusted-private-detail", "category": "never-display-this-capability"]] as [[String: String]] {
            var body: [String: Any] = ["deleted": false, "retryable": true, "operationID": "operation", "error": "deletion_incomplete"]
            details.forEach { body[$0.key] = $0.value }
            XCTAssertThrowsError(try DeviceAccountDeletionTransaction.validateHTTPResponse(JSONSerialization.data(withJSONObject: body), status: 503, operationID: "operation")) {
                XCTAssertEqual($0 as? DeviceAccountDeletionFailure, .pending(.incomplete))
            }
        }
        XCTAssertEqual(DeviceAccountDeletionDiagnostic(stage: "catalog_plan", category: "storage_schema")?.supportCode, "catalog_plan / storage_schema")
        XCTAssertEqual(DeviceAccountDeletionDiagnostic(stage: "catalog_plan", category: "private-detail")?.supportCode, "catalog_plan")
    }

    @MainActor func testPartialServerResponsePreservesReceiptAndReportsOnlySafeStage() async throws {
        for stage in DeviceAccountDeletionFailure.Pending.allCases {
            var saved: DeviceAccountDeletionIntent?
            do {
                _ = try await DeviceAccountDeletionTransaction.perform(intent(), prepare: {
                    .init(operationID: "operation", deletionToken: "synthetic-capability")
                }, execute: { received, _ in
                    let data = try JSONSerialization.data(withJSONObject: ["deleted": false, "retryable": true,
                        "operationID": received.operationID, "deletionToken": "never-display-this-capability", "error": stage.rawValue])
                    try DeviceAccountDeletionTransaction.validateHTTPResponse(data, status: 503, operationID: received.operationID)
                    XCTFail("A partial response cannot complete deletion")
                    throw Failure.interrupted
                }, persist: { saved = $0 })
                XCTFail("Expected pending server deletion")
            } catch let error as DeviceAccountDeletionFailure {
                XCTAssertEqual(error, .pending(stage))
                XCTAssertFalse(error.localizedDescription.contains("never-display-this-capability"))
            }
            XCTAssertEqual(saved?.serverConfirmed, false)
            XCTAssertEqual(saved?.deletionToken, "synthetic-capability")
            XCTAssertEqual(saved?.appleRevocationConsent, "REVOKE")
        }
    }

    func testPartialHTTPResponseMustMatchOperationAndCannotClaimCompletion() throws {
        for changes in [["operationID": "different"], ["deleted": true], ["retryable": false], ["error": "untrusted-private-detail"]] as [[String: Any]] {
            var body: [String: Any] = ["deleted": false, "retryable": true, "operationID": "operation", "error": "deletion_incomplete"]
            changes.forEach { body[$0.key] = $0.value }
            let data = try JSONSerialization.data(withJSONObject: body)
            XCTAssertThrowsError(try DeviceAccountDeletionTransaction.validateHTTPResponse(data, status: 503, operationID: "operation")) {
                XCTAssertEqual($0 as? DeviceAccountDeletionFailure, .invalidResponse)
            }
        }
        XCTAssertThrowsError(try DeviceAccountDeletionTransaction.validateHTTPResponse(Data(), status: 202, operationID: "operation")) {
            XCTAssertEqual($0 as? DeviceAccountDeletionFailure, .http(202))
        }
    }

    @MainActor func testMissingOrInvalidConsentNeverStartsOrRetriesDeletion() async throws {
        for consent in [nil, "", "revoke"] as [String?] {
            for token in [nil, "existing-capability"] as [String?] {
                var pending = intent()
                pending.appleRevocationConsent = consent
                pending.deletionToken = token
                do {
                    _ = try await DeviceAccountDeletionTransaction.perform(pending, prepare: {
                        XCTFail("No prepare without explicit consent")
                        throw Failure.interrupted
                    }, execute: { _, _ in
                        XCTFail("No delete or retry without explicit consent")
                        throw Failure.interrupted
                    }, persist: { _ in XCTFail("No invented consent") })
                    XCTFail("Expected refusal")
                } catch {}
            }
        }
    }

    @MainActor func testReceiptFromBeforeConsentContractRequiresConfirmation() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(intent())) as? [String: Any])
        object.removeValue(forKey: "appleRevocationConsent")
        let recovered = try JSONDecoder().decode(DeviceAccountDeletionIntent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(recovered.appleRevocationConsent)
        XCTAssertFalse(recovered.serverConfirmed)
    }

    @MainActor func testChangedRequiredWarningPreventsDestructiveRequest() async throws {
        do {
            _ = try await DeviceAccountDeletionTransaction.perform(intent(), prepare: {
                .init(operationID: "operation", deletionToken: "capability", appleRevocationConsentRequired: true, appleAuthorizationWarning: "Changed scope")
            }, execute: { _, _ in
                XCTFail("An unseen warning must not be approved")
                throw Failure.interrupted
            }, persist: { _ in XCTFail("Do not persist an unseen warning as approved") })
            XCTFail("Expected refusal")
        } catch {}
    }

    @MainActor func testFailureToSaveRecoveryCapabilityPreventsDestructiveRequest() async throws {
        var executed = false
        do {
            _ = try await DeviceAccountDeletionTransaction.perform(intent(), prepare: {
                .init(operationID: "operation", deletionToken: "synthetic-capability")
            }, execute: { _, _ in
                executed = true
                throw Failure.interrupted
            }, persist: { _ in throw Failure.interrupted })
            XCTFail("Expected failed persistence")
        } catch {}
        XCTAssertFalse(executed)
    }

    @MainActor func testLostResponseRetainsCapabilityAndRetriesWithoutPreparingNewOperation() async throws {
        var saved: DeviceAccountDeletionIntent?
        do {
            _ = try await DeviceAccountDeletionTransaction.perform(intent(), prepare: {
                .init(operationID: "operation", deletionToken: "synthetic-capability", appleRevocationConsentRequired: true,
                      appleAuthorizationWarning: DeviceAccountDeletionTransaction.appleAuthorizationWarning)
            }, execute: { received, retrying in
                XCTAssertFalse(retrying)
                XCTAssertEqual(saved?.appleRevocationConsent, "REVOKE")
                XCTAssertEqual(saved?.deletionToken, received.deletionToken)
                throw Failure.interrupted
            }, persist: { saved = $0 })
            XCTFail("Expected a lost response")
        } catch {}
        let pending = try JSONDecoder().decode(DeviceAccountDeletionIntent.self, from: JSONEncoder().encode(try XCTUnwrap(saved)))
        XCTAssertEqual(pending.appleRevocationConsent, "REVOKE")
        XCTAssertFalse(pending.serverConfirmed)
        let completed = try await DeviceAccountDeletionTransaction.perform(pending, prepare: {
            XCTFail("A retry must preserve its original operation")
            throw Failure.interrupted
        }, execute: { received, retrying in
            XCTAssertTrue(retrying)
            XCTAssertEqual(received.appleRevocationConsent, "REVOKE")
            XCTAssertEqual(received.deletionToken, "synthetic-capability")
            return .init(deleted: true, operationID: received.operationID, manualAppleRevocationRequired: false, appleRevocationHelpURL: nil)
        }, persist: { saved = $0 })
        XCTAssertTrue(completed.serverConfirmed)
        XCTAssertEqual(saved, completed)
    }

    @MainActor func testIncompleteAndWrongOperationResponsesNeverConfirmDeletion() async throws {
        for response in [
            DeviceAccountDeletionTransaction.Result(deleted: false, operationID: "operation", manualAppleRevocationRequired: nil, appleRevocationHelpURL: nil),
            .init(deleted: true, operationID: "another-operation", manualAppleRevocationRequired: nil, appleRevocationHelpURL: nil)
        ] {
            var saved: DeviceAccountDeletionIntent?
            do {
                _ = try await DeviceAccountDeletionTransaction.perform(intent(), prepare: {
                    .init(operationID: "operation", deletionToken: "synthetic-capability")
                }, execute: { _, _ in response }, persist: { saved = $0 })
                XCTFail("Expected an unconfirmed deletion")
            } catch {}
            XCTAssertEqual(saved?.serverConfirmed, false)
        }
    }

    @MainActor func testLocalCleanupRetryMakesNoFurtherServerRequest() async throws {
        var completed = intent()
        completed.serverConfirmed = true
        let recovered = try await DeviceAccountDeletionTransaction.perform(completed, prepare: {
            XCTFail("No request after server completion")
            throw Failure.interrupted
        }, execute: { _, _ in
            XCTFail("No request after server completion")
            throw Failure.interrupted
        }, persist: { _ in XCTFail("Existing completion receipt is already durable") })
        XCTAssertEqual(recovered, completed)
    }
}
