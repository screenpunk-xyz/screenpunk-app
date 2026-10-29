import Foundation
import XCTest
import ScreenpunkCore
@testable import DeviceAuthoring

final class LocalProfileLibraryTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-local-library-" + UUID().uuidString) }
    private func profile() -> LocalProfileDescriptor { .init(id: "local-profile", libraryOwner: "local:local-profile", permissionOwner: "local:local-profile", localDeviceID: "local-device") }
    @MainActor private func request(_ library: ScreenLibrary, route: String = "local") throws -> AuthoringRequestV1 {
        try AuthoringContract.seal(.init(requestID: "request", createdAt: 1_000, deadlineAt: 601_000, designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime, services: [], context: .init(profileID: "local-profile", deviceID: "local-device", screenID: "screen", userRequest: "Remember to always use large text for my profile, device and this screen.", viewport: .init(width: 1024, height: 768, orientation: "landscape")), delivery: .init(route: route)))
    }
    private func result(_ input: AuthoringRequestV1) -> AuthoringResultV1 {
        let records = [("profile-pref", "profile", "local-profile"), ("device-pref", "device", "local-device"), ("screen-pref", "screen", "screen")]
        return .init(requestID: input.requestID, inputDigest: input.delivery.snapshotDigest, preferenceRevisions: [:], operationID: "operation", screen: .init(title: "Local screen", files: [.init(path: "index.html", content: "<html><body>Local</body></html>")]), answer: "Remembered.", preferenceMutations: records.map { id, scope, target in
            .init(kind: "upsert", id: id, expectedRevision: nil, record: .init(id: id, scope: scope, targetID: target, category: "typography", value: .string("large"), revision: 1, originRequestID: input.requestID))
        }, durablePreferenceAuthorization: .init(requestID: input.requestID, quote: input.context.userRequest))
    }
    @MainActor func testLocalCancellationNeverEntersCloudOutboxAndLateResultCannotApply() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(profile: profile(), rootDirectory: root)
        let input = try request(library); try library.saveAuthoringRequest(input)
        try library.cancelRequest(input.requestID) // saved route wins, no integration hint required
        XCTAssertTrue(library.state.cancelIntents?.isEmpty ?? true)
        let restarted = try ScreenLibrary(profile: profile(), rootDirectory: root)
        XCTAssertThrowsError(try restarted.applyAuthoringResult(result(input), now: 2_000))
        XCTAssertTrue(restarted.preferences.isEmpty); XCTAssertTrue(restarted.pendingReceipts.isEmpty)
        try restarted.retireAuthoringRequest(id: input.requestID)
        XCTAssertTrue(restarted.pendingReceipts.isEmpty) // route tombstone survives source compaction
    }
    @MainActor func testExplicitLinkCommitsAllScopedTargetsRevisionOutboxAndOwnerTogether() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let local = profile(); let library = try ScreenLibrary(profile: local, rootDirectory: root)
        let input = try request(library); try library.saveAuthoringRequest(input)
        let receipt = try library.applyAuthoringResult(result(input), now: 2_000); XCTAssertEqual(receipt.status, "applied"); try library.acknowledgeReceipt(receipt)
        let binding = LocalCloudBinding(accountID: "cloud-account", profileID: "cloud-profile", deviceID: "cloud-device")
        let linked = try library.linkLocalProfile(local, to: binding)
        XCTAssertEqual(linked.libraryOwner, local.libraryOwner); XCTAssertEqual(linked.permissionOwner, local.permissionOwner)
        let restart = try ScreenLibrary(profile: local, rootDirectory: root)
        XCTAssertEqual(restart.linkedProfile, linked)
        XCTAssertEqual(restart.preferences.first { $0.scope == "profile" }?.targetID, "cloud-profile")
        XCTAssertEqual(restart.preferences.first { $0.scope == "device" }?.targetID, "cloud-device")
        XCTAssertEqual(restart.preferences.first { $0.scope == "screen" }?.targetID, "screen")
        XCTAssertEqual(restart.preferences.first { $0.scope == "profile" }?.revision, 2)
        XCTAssertEqual(restart.preferenceOutbox.first { $0.record.scope == "device" }?.record.targetID, "cloud-device")
        XCTAssertTrue(restart.preferences(profileID: local.id, deviceID: local.localDeviceID, screenID: "other-screen").isEmpty)
        XCTAssertEqual(restart.preferences(profileID: linked.authoringProfileID, deviceID: linked.authoringDeviceID, screenID: "screen").count, 3)
        XCTAssertEqual(try restart.linkLocalProfile(local, to: binding), linked)
        XCTAssertThrowsError(try restart.linkLocalProfile(local, to: .init(accountID: "other", profileID: "other", deviceID: "other")))
    }
    @MainActor func testEveryLinkCrashCutRecoversDescriptorAndPreferencesWithoutHalfState() throws {
        enum PowerLoss: Error { case interrupted }
        for cut in AuthoringJournal.Cut.allCases {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            let local = profile(); var armed = false
            let library = try ScreenLibrary(profile: local, rootDirectory: root, journalFault: { if armed && $0 == cut { throw PowerLoss.interrupted } })
            let input = try request(library); try library.saveAuthoringRequest(input)
            let receipt = try library.applyAuthoringResult(result(input), now: 2_000); XCTAssertEqual(receipt.status, "applied"); try library.acknowledgeReceipt(receipt)
            armed = true
            XCTAssertThrowsError(try library.linkLocalProfile(local, to: .init(accountID: "account", profileID: "cloud-profile", deviceID: "cloud-device")))
            let restart = try ScreenLibrary(profile: local, rootDirectory: root)
            if cut == .assetsDurable {
                XCTAssertNil(restart.linkedProfile); XCTAssertEqual(restart.preferences.first { $0.scope == "device" }?.targetID, local.localDeviceID)
            } else {
                XCTAssertNotNil(restart.linkedProfile); XCTAssertEqual(restart.preferences.first { $0.scope == "device" }?.targetID, "cloud-device")
                XCTAssertEqual(restart.preferenceOutbox.first { $0.record.scope == "device" }?.record.targetID, "cloud-device")
            }
        }
    }
    @MainActor func testExistingAccountConfirmationPreservesExactlyBoundPendingCloudRequest() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let legacy = LocalProfileDescriptor(id: "new-local-descriptor", libraryOwner: "account", permissionOwner: "account", localDeviceID: "local-device", preferredRoute: .cloud)
        let library = try ScreenLibrary(profile: legacy, rootDirectory: root)
        let input = try request(library, route: "cloud"); try library.saveAuthoringRequest(input)
        try library.savePending(id: input.requestID, screenID: input.context.screenID, consumedID: nil)
        let binding = LocalCloudBinding(accountID: "account", profileID: input.context.profileID, deviceID: input.context.deviceID)
        XCTAssertNoThrow(try library.linkLocalProfile(legacy, to: binding))
        XCTAssertEqual(library.authoringRequest(id: input.requestID), input); XCTAssertEqual(library.state.pendingID, input.requestID)
        let receipt = try library.applyAuthoringResult(result(input), now: 2_000)
        XCTAssertEqual(receipt.status, "applied")
        XCTAssertEqual(library.selected?.id, input.context.screenID)
    }
    @MainActor func testSameAccountConfirmationKeepsCloudOwnedPreferenceRevisionsUnchanged() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let legacy = LocalProfileDescriptor(id: "new-local-descriptor", libraryOwner: "account", permissionOwner: "account", localDeviceID: "local-device", preferredRoute: .cloud)
        let library = try ScreenLibrary(profile: legacy, rootDirectory: root)
        let first = try request(library, route: "cloud"); try library.saveAuthoringRequest(first)
        let receipt = try library.applyAuthoringResult(result(first), now: 2_000); try library.acknowledgeReceipt(receipt)
        let outbox = library.preferenceOutbox
        try library.applyPreferenceSync(records: library.preferences, accepted: Dictionary(uniqueKeysWithValues: outbox.map { ($0.record.id, 1) }), sent: outbox, conflicts: [:], profileID: first.context.profileID, deviceID: first.context.deviceID)
        let original = library.preferences
        var pending = first; pending.requestID = "pending-second"; pending.context.baseRevision = library.selected?.revision; pending.preferences = original
        pending = try AuthoringContract.seal(pending); try library.saveAuthoringRequest(pending)
        try library.savePending(id: pending.requestID, screenID: pending.context.screenID, consumedID: nil)
        XCTAssertNoThrow(try library.linkLocalProfile(legacy, to: .init(accountID: "account", profileID: pending.context.profileID, deviceID: pending.context.deviceID)))
        XCTAssertEqual(library.preferences, original); XCTAssertTrue(library.preferenceOutbox.isEmpty)
        XCTAssertEqual(library.authoringRequest(id: pending.requestID), pending)
    }
    @MainActor func testExistingAccountCannotConfirmDifferentPendingCloudBinding() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let legacy = LocalProfileDescriptor(id: "new-local-descriptor", libraryOwner: "account", permissionOwner: "account", localDeviceID: "local-device", preferredRoute: .cloud)
        let library = try ScreenLibrary(profile: legacy, rootDirectory: root)
        let input = try request(library, route: "cloud"); try library.saveAuthoringRequest(input)
        try library.savePending(id: input.requestID, screenID: input.context.screenID, consumedID: nil)
        XCTAssertThrowsError(try library.linkLocalProfile(legacy, to: .init(accountID: "account", profileID: "different-profile", deviceID: input.context.deviceID)))
        XCTAssertNil(library.linkedProfile); XCTAssertEqual(library.authoringRequest(id: input.requestID), input)
    }
    @MainActor func testLocalReceiptRecoveryAfterLedgerAckBeforeLibraryAckNeverUploadsToCloud() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("library"), ledgerRoot = root.appendingPathComponent("ledger")
        let local = profile(); let library = try ScreenLibrary(profile: local, rootDirectory: libraryRoot)
        let input = try request(library); try library.saveAuthoringRequest(input)
        try library.savePending(id: input.requestID, screenID: input.context.screenID, consumedID: nil)
        let ledger = try LocalDeliveryLedger(rootDirectory: ledgerRoot)
        var delivery = LocalDeliveryRecord(requestID: input.requestID, inputDigest: input.delivery.snapshotDigest, connectionID: "connection", profileID: local.id, hostKeySHA256: "SHA256:fixture", deadlineAt: input.deadlineAt)
        try ledger.prepare(delivery); delivery.status = .submitting; try ledger.update(delivery)
        delivery.status = .completed; delivery.finalResult = result(input); try ledger.update(delivery)
        let receipt = try library.applyAuthoringResult(result(input), now: 2_000)
        delivery.status = .applied; delivery.receipt = receipt; try ledger.update(delivery)
        // Crash here: delivery is terminal and native pendingID was already cleared.
        let restart = try ScreenLibrary(profile: local, rootDirectory: libraryRoot)
        let savedLedger = try LocalDeliveryLedger(rootDirectory: ledgerRoot)
        XCTAssertNil(restart.state.pendingID); XCTAssertNil(try savedLedger.unresolvedRecord())
        XCTAssertTrue(restart.pendingReceipts.isEmpty)
        let raw = try XCTUnwrap(restart.state.authoring)
        let outstanding = raw.receipts.values.filter { !raw.acknowledgedReceiptIDs.contains($0.operationID) }
        XCTAssertEqual(Array(outstanding), [receipt]); XCTAssertEqual(try savedLedger.record(requestID: receipt.requestID)?.profileID, local.id)
        try restart.acknowledgeReceipt(receipt)
        let acknowledged = try ScreenLibrary(profile: local, rootDirectory: libraryRoot)
        XCTAssertTrue(acknowledged.state.authoring?.acknowledgedReceiptIDs.contains(receipt.operationID) == true)
        XCTAssertNil(acknowledged.authoringRequest(id: input.requestID)); XCTAssertTrue(acknowledged.pendingReceipts.isEmpty)
        XCTAssertEqual(try savedLedger.record(requestID: receipt.requestID)?.receipt, receipt)
        XCTAssertNoThrow(try acknowledged.acknowledgeReceipt(receipt))
    }
    @MainActor func testSeparateAccountLibrariesCannotExposeLocalSources() throws {
        let first = directory(), second = directory(); defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let local = try ScreenLibrary(profile: profile(), rootDirectory: first)
        try local.install(.init(title: "Private local", files: [.init(path: "index.html", content: "<html><body>Local private source</body></html>")]), requestID: "sample", replacing: "stable-screen")
        let account = try ScreenLibrary(accountID: "different-account", rootDirectory: second)
        XCTAssertTrue(account.state.screens.isEmpty); XCTAssertNil(account.selected)
        XCTAssertEqual(try ScreenLibrary(profile: profile(), rootDirectory: first).selected?.id, "stable-screen")
    }
}
