import Foundation
import XCTest
@testable import ScreenpunkCore

final class LocalPersistenceTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-local-store-" + UUID().uuidString) }
    private func binding() -> LocalDeliveryRecord { .init(requestID: "request", inputDigest: "digest", connectionID: "connection", profileID: "profile", hostKeySHA256: "SHA256:pin", baseRevision: "revision", deadlineAt: 10_000) }
    private func configuration() -> LocalAgentConfiguration { .init(host: "mac.local", username: "user", hostKeySHA256: "SHA256:pin", macWorkspace: "/Users/user/Screenpunk", credentialReference: "keychain-reference") }

    func testLocalIdentityCloudAccountIsolationAndRouteSurviveRestart() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LocalProfileRepository(rootDirectory: root)
        let local = try repo.createLocalProfile()
        let initial = try repo.snapshot()
        let accountA = try repo.activateCloudProfile(accountID: "A", profileID: "cloud-profile-A", deviceID: "cloud-device-A")
        XCTAssertEqual(accountA.libraryOwner, "A"); XCTAssertEqual(accountA.permissionOwner, "A")
        try repo.setPreferredRoute(.local, profileID: accountA.id)
        let accountB = try repo.activateCloudProfile(accountID: "B", profileID: "cloud-profile-B", deviceID: "cloud-device-B")
        XCTAssertNotEqual(accountA.id, accountB.id); XCTAssertNotEqual(accountA.libraryOwner, accountB.libraryOwner)
        try repo.signOut()
        let restart = try LocalProfileRepository(rootDirectory: root)
        XCTAssertEqual(try restart.snapshot().installationID, initial.installationID)
        XCTAssertEqual(try restart.snapshot().localDeviceID, initial.localDeviceID)
        XCTAssertEqual(try restart.snapshot().activeProfile?.id, accountB.id)
        XCTAssertEqual(try restart.snapshot().activeProfile?.preferredRoute, .local)
        try restart.activateProfile(id: local.id)
        XCTAssertEqual(try restart.snapshot().activeProfile, local)
        XCTAssertEqual(try restart.activateCloudProfile(accountID: "A", profileID: "cloud-profile-A", deviceID: "cloud-device-A").preferredRoute, .local)
        XCTAssertThrowsError(try restart.setPreferredRoute(.cloud, profileID: local.id))
        var illegal = local; illegal.cloudBinding = accountA.cloudBinding
        XCTAssertThrowsError(try restart.adoptLinkedProfile(illegal))
    }
    func testExplicitlyLinkedLocalOwnerReopensForItsAccountWithoutCreatingAnEmptyLibrary() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LocalProfileRepository(rootDirectory: root)
        let local = try repo.createLocalProfile(); var linked = local
        linked.cloudBinding = .init(accountID: "linked-account", profileID: "linked-profile", deviceID: "linked-device")
        try repo.adoptLinkedProfile(linked)
        let offline = try repo.activateAccountProfile(accountID: "linked-account", deviceID: "linked-device")
        XCTAssertEqual(offline, linked); XCTAssertEqual(try repo.snapshot().profiles.count, 1)
        XCTAssertEqual(offline.libraryOwner, local.libraryOwner); XCTAssertEqual(offline.permissionOwner, local.permissionOwner)
    }
    func testLegacyAccountOpensExistingOwnerOfflineAndCanBindWithoutLosingIdentity() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LocalProfileRepository(rootDirectory: root)
        let legacy = try repo.activateAccountProfile(accountID: "existing-account", deviceID: "legacy-device")
        XCTAssertEqual(legacy.libraryOwner, "existing-account"); XCTAssertEqual(legacy.permissionOwner, "existing-account")
        XCTAssertEqual(legacy.localDeviceID, "legacy-device"); XCTAssertNil(legacy.cloudBinding); XCTAssertEqual(legacy.preferredRoute, .cloud)
        let restart = try LocalProfileRepository(rootDirectory: root)
        XCTAssertEqual(try restart.activateAccountProfile(accountID: "existing-account", deviceID: "legacy-device"), legacy)
        let linked = try restart.activateCloudProfile(accountID: "existing-account", profileID: "authoritative-profile", deviceID: "legacy-device")
        XCTAssertEqual(linked.id, legacy.id); XCTAssertEqual(linked.libraryOwner, legacy.libraryOwner)
        XCTAssertEqual(try restart.snapshot().profiles.count, 1)
        XCTAssertEqual(linked.authoringProfileID, "authoritative-profile")
        let other = try restart.createLocalProfile()
        XCTAssertNotEqual(other.libraryOwner, linked.libraryOwner)
        XCTAssertThrowsError(try restart.validateLink(profileID: other.id, binding: .init(accountID: "existing-account", profileID: "authoritative-profile", deviceID: "legacy-device")))
    }
    func testConfigurationThreadsPersistPerProfileAndNoSecretsAreStored() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LocalAgentConfigurationRepository(rootDirectory: root)
        let config = configuration(); try repo.save(config)
        try repo.setThreadID("thread-A", profileID: "profile-A", configurationID: config.id)
        try repo.setThreadID("thread-B", profileID: "profile-B", configurationID: config.id)
        XCTAssertThrowsError(try repo.setThreadID("thread-A", profileID: "profile-B", configurationID: config.id))
        try repo.markSuccessfulConnection(configurationID: config.id, at: 123)
        let restart = try LocalAgentConfigurationRepository(rootDirectory: root)
        XCTAssertEqual(try restart.load()?.profileThreads, ["profile-A": "thread-A", "profile-B": "thread-B"])
        XCTAssertEqual(try restart.load()?.lastSuccessfulConnectionAt, 123)
        let json = try String(contentsOf: root.appendingPathComponent("state.json"))
        XCTAssertTrue(json.contains("keychain-reference")); XCTAssertFalse(json.contains("privateKey")); XCTAssertFalse(json.contains("appServerToken"))
        var replacement = config; replacement.host = "other.local"
        XCTAssertThrowsError(try repo.save(replacement))
        XCTAssertEqual(try restart.remove(configurationID: config.id)?.id, config.id)
        XCTAssertNil(try repo.load())
    }
    func testUnknownVersionRejectedWithoutReplacingDataAndOptionalFieldsMigrate() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LocalAgentConfigurationRepository(rootDirectory: root); try repo.save(configuration())
        let file = root.appendingPathComponent("state.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["schemaVersion"] = 99; let unsupported = try JSONSerialization.data(withJSONObject: json); try unsupported.write(to: file)
        XCTAssertThrowsError(try repo.load()); XCTAssertEqual(try Data(contentsOf: file), unsupported)
        json["schemaVersion"] = 1
        var value = try XCTUnwrap(json["value"] as? [String: Any]); var config = try XCTUnwrap(value["configuration"] as? [String: Any]); config.removeValue(forKey: "profileThreads"); value["configuration"] = config; json["value"] = value
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertEqual(try repo.load()?.profileThreads, [:])
    }
    func testResponseLossPersistsCorrelationAndNeverAllowsSecondSubmission() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try LocalDeliveryLedger(rootDirectory: root)
        var record = binding(); try ledger.prepare(record)
        record.threadID = "thread"; record.status = .submitting; try ledger.update(record)
        record.status = .deliveryUncertain; record.failure = "response lost"; try ledger.update(record)
        let restart = try LocalDeliveryLedger(rootDirectory: root)
        XCTAssertEqual(try restart.unresolvedRecord(), record)
        try restart.prepare(binding()) // replay preserves uncertainty, never rewinds
        XCTAssertEqual(try restart.record(requestID: record.requestID)?.status, .deliveryUncertain)
        var other = binding(); other.requestID = "another"; XCTAssertThrowsError(try restart.prepare(other))
        var rewind = record; rewind.status = .submitting; XCTAssertThrowsError(try restart.update(rewind))
        record.turnID = "accepted-turn"; record.status = .running; try restart.update(record)
        var changed = record; changed.turnID = "other-turn"; XCTAssertThrowsError(try restart.update(changed))
        changed = record; changed.profileID = "other-account"; XCTAssertThrowsError(try restart.update(changed))
    }
    func testCancelTimeoutAndForgottenEndpointBlockLateResultsAcrossRestart() throws {
        for terminal in [LocalDeliveryStatus.cancelled, .timedOut] {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            let ledger = try LocalDeliveryLedger(rootDirectory: root)
            var record = binding(); try ledger.prepare(record); record.status = .submitting; try ledger.update(record)
            if terminal == .cancelled { try ledger.cancel(requestID: record.requestID) }
            else { try ledger.expire(requestID: record.requestID, now: record.deadlineAt) }
            let restart = try LocalDeliveryLedger(rootDirectory: root)
            XCTAssertEqual(try restart.record(requestID: record.requestID)?.status, terminal)
            record.status = .completed; record.finalResult = .init(requestID: record.requestID, inputDigest: record.inputDigest, baseRevision: record.baseRevision, preferenceRevisions: [:], operationID: "operation", answer: "late")
            XCTAssertThrowsError(try restart.update(record)); XCTAssertNil(try restart.unresolvedRecord())
        }
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try LocalDeliveryLedger(rootDirectory: root); try ledger.prepare(binding())
        try ledger.blockOutstanding(configurationID: "connection", reason: "Forgotten")
        XCTAssertEqual(try ledger.record(requestID: "request")?.status, .cancelled)
    }
    func testCompactionBoundsResultSourcesButRetainsEveryBindingAndReceipt() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try LocalDeliveryLedger(rootDirectory: root)
        for index in 0..<34 {
            var record = binding(); record.requestID = "request-\(index)"; record.deadlineAt += Int64(index)
            try ledger.prepare(record); record.status = .submitting; try ledger.update(record)
            record.status = .completed
            record.finalResult = .init(requestID: record.requestID, inputDigest: record.inputDigest, baseRevision: record.baseRevision, preferenceRevisions: [:], operationID: "operation-\(index)", answer: "done")
            try ledger.update(record)
            record.status = .applied; record.receipt = .init(requestID: record.requestID, operationID: "operation-\(index)", inputDigest: record.inputDigest, status: "applied", appliedAt: Int64(index))
            try ledger.update(record)
        }
        try ledger.compactSources()
        let records = try LocalDeliveryLedger(rootDirectory: root).records()
        XCTAssertEqual(records.count, 34); XCTAssertEqual(records.filter { $0.finalResult != nil }.count, 32)
        XCTAssertTrue(records.allSatisfy { $0.resultDigest != nil && $0.receipt != nil && $0.status == .applied })
        var reused = binding(); reused.requestID = "request-0"; reused.inputDigest = "different"
        XCTAssertThrowsError(try ledger.prepare(reused))
    }
    func testCompletedResultAndNativeReceiptAreImmutable() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try LocalDeliveryLedger(rootDirectory: root)
        var record = binding(); try ledger.prepare(record); record.status = .submitting; try ledger.update(record)
        record.status = .completed; record.finalResult = .init(requestID: "request", inputDigest: "digest", baseRevision: "revision", preferenceRevisions: [:], operationID: "operation", answer: "done"); try ledger.update(record)
        XCTAssertNotNil(try ledger.record(requestID: "request")?.resultDigest)
        var altered = try XCTUnwrap(ledger.record(requestID: "request")); altered.finalResult?.answer = "changed"
        XCTAssertThrowsError(try ledger.update(altered))
        record.status = .applied; record.receipt = .init(requestID: "request", operationID: "operation", inputDigest: "digest", status: "applied", appliedAt: 100)
        try ledger.update(record); try ledger.compactSources()
        XCTAssertEqual(try ledger.record(requestID: "request")?.receipt, record.receipt)
        XCTAssertNil(try ledger.unresolvedRecord())
    }
}
