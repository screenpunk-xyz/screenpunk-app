import Foundation
import XCTest
@testable import ScreenpunkCore

final class LocalDeliveryV2Tests: XCTestCase {
    func testLegacyRecordWithoutVersionDecodesPreservingHistoryAndReceipt() throws {
        let result = AuthoringResultV1(requestID: "existing", inputDigest: "digest", baseRevision: "base", preferenceRevisions: [:], operationID: "old-operation", answer: "Retained old result")
        let receipt = ApplicationReceiptV1(requestID: "existing", operationID: "old-operation", inputDigest: "digest", status: "applied", appliedAt: 7)
        let record = LocalDeliveryRecord(requestID: "existing", inputDigest: "digest", connectionID: "working-pair", profileID: "profile", hostKeySHA256: "SHA256:fixture", threadID: "old-thread", turnID: "old-turn", baseRevision: "base", deadlineAt: 1000, status: .applied, finalResult: result, receipt: receipt)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        json.removeValue(forKey: "contractVersion"); json.removeValue(forKey: "finalResultV2")
        let decoded = try JSONDecoder().decode(LocalDeliveryRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, record); XCTAssertEqual(decoded.contractVersion, 1)
        XCTAssertEqual(decoded.threadID, "old-thread"); XCTAssertEqual(decoded.receipt, receipt)
        json["contractVersion"] = 3
        XCTAssertThrowsError(try JSONDecoder().decode(LocalDeliveryRecord.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    func testV2LedgerPersistsExactResultAndVersionAcrossRestartAndCancellation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-v2-ledger-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try LocalDeliveryLedger(rootDirectory: root)
        var record = LocalDeliveryRecord(requestID: "v2-request", inputDigest: "digest", connectionID: "working-pair", profileID: "profile", hostKeySHA256: "SHA256:fixture", deadlineAt: 1000, contractVersion: 2)
        try ledger.prepare(record)
        var switched = record; switched.contractVersion = 1
        XCTAssertThrowsError(try ledger.prepare(switched)); XCTAssertThrowsError(try ledger.update(switched))
        record.threadID = "v2-thread"; record.status = .submitting; try ledger.update(record)
        let result = AuthoringResultV2(requestID: record.requestID, inputDigest: record.inputDigest, preferenceRevisions: [:], operationID: "v2-operation", answer: "Ready")
        record.status = .completed; record.finalResultV2 = result; try ledger.update(record)
        let reopened = try LocalDeliveryLedger(rootDirectory: root)
        let durable = try XCTUnwrap(reopened.record(requestID: record.requestID))
        XCTAssertEqual(durable.finalResultV2, result); XCTAssertNotNil(durable.resultDigest); XCTAssertNil(durable.finalResult)
        var changed = durable; changed.finalResultV2?.answer = "Changed"
        XCTAssertThrowsError(try reopened.update(changed))
        try reopened.cancel(requestID: record.requestID)
        XCTAssertNil(try reopened.record(requestID: record.requestID)?.finalResultV2)
        XCTAssertEqual(try reopened.record(requestID: record.requestID)?.status, .cancelled)
        XCTAssertThrowsError(try reopened.update(durable))
    }
}
