import Foundation
import XCTest
import ScreenpunkCore
@testable import DeviceAuthoring

final class ScreenLibraryAuthoringTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-authoring-\(UUID().uuidString)") }
    private func artifact(_ title: String) -> AuthoringScreen {
        .init(title: title, files: [.init(path: "index.html", content: "<!doctype html><html><body><h1>\(title)</h1></body></html>")])
    }
    @MainActor private func request(_ library: ScreenLibrary, id: String = "fixture-request") throws -> AuthoringRequestV1 {
        try AuthoringContract.seal(.init(requestID: id, createdAt: 1_000, deadlineAt: 601_000,
            designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime, services: [],
            preferences: library.preferences(profileID: "fixture-profile", deviceID: "fixture-device", screenID: "fixture-screen"),
            context: .init(profileID: "fixture-profile", deviceID: "fixture-device", screenID: "fixture-screen", baseRevision: library.selected?.revision,
                           userRequest: "Remember to always use large text on this device, and update the screen.", currentScreen: library.selected?.artifact,
                           viewport: .init(width: 1024, height: 768, orientation: "landscape")), delivery: .init(route: "fixture")))
    }
    private func result(_ request: AuthoringRequestV1) -> AuthoringResultV1 {
        .init(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, baseRevision: request.context.baseRevision,
              preferenceRevisions: Dictionary(uniqueKeysWithValues: request.preferences.map { ($0.id, $0.revision) }), operationID: "operation-" + request.requestID,
              screen: artifact("Updated fixture"), preferenceMutations: [.init(kind: "upsert", id: "large-text", expectedRevision: nil,
                record: .init(id: "large-text", scope: "device", targetID: "fixture-device", category: "typography", value: .string("large"), revision: 1, originRequestID: request.requestID))],
              durablePreferenceAuthorization: .init(requestID: request.requestID, quote: request.context.userRequest))
    }

    @MainActor func testCombinedScreenPreferenceReceiptOutboxAndReplaySurviveRestart() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        try library.install(artifact("Original fixture"), requestID: "original", replacing: "fixture-screen")
        let input = try request(library); try library.saveAuthoringRequest(input)
        let output = result(input)
        let receipt = try library.applyAuthoringResult(output, now: 2_000)
        XCTAssertEqual(receipt.status, "applied")
        XCTAssertEqual(library.selected?.id, "fixture-screen")
        XCTAssertEqual(library.selected?.artifact.title, "Updated fixture")
        XCTAssertEqual(library.state.previous?.artifact.title, "Original fixture")
        XCTAssertEqual(library.preferences.first?.value, .string("large"))
        XCTAssertEqual(library.preferenceOutbox.count, 1)
        XCTAssertEqual(library.pendingReceipts, [receipt])
        let revision = library.selected?.revision
        let restarted = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        XCTAssertEqual(try restarted.applyAuthoringResult(output, now: 3_000), receipt)
        XCTAssertEqual(restarted.selected?.revision, revision)
        XCTAssertEqual(restarted.preferences.first?.revision, 1)
        try restarted.acknowledgeReceipt(receipt)
        let acknowledged = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        XCTAssertTrue(acknowledged.pendingReceipts.isEmpty)
        XCTAssertEqual(try acknowledged.applyAuthoringResult(output, now: 4_000), receipt)
        var reused = output; reused.answer = "different content"
        XCTAssertThrowsError(try acknowledged.applyAuthoringResult(reused, now: 4_000))
    }

    @MainActor func testEveryCrashCutRecoversEntireCombinedTransaction() throws {
        enum SimulatedCrash: Error { case powerLoss }
        for cut in AuthoringJournal.Cut.allCases {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            var armed = false
            let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root, journalFault: { current in
                if armed && current == cut { throw SimulatedCrash.powerLoss }
            })
            try library.install(artifact("Original fixture"), requestID: "original", replacing: "fixture-screen")
            let input = try request(library); try library.saveAuthoringRequest(input)
            armed = true
            XCTAssertThrowsError(try library.applyAuthoringResult(result(input), now: 2_000), cut.rawValue)
            let recovered = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
            if cut == .assetsDurable {
                XCTAssertEqual(recovered.selected?.artifact.title, "Original fixture")
                XCTAssertTrue(recovered.preferences.isEmpty)
                XCTAssertTrue(recovered.pendingReceipts.isEmpty)
            } else {
                XCTAssertEqual(recovered.selected?.artifact.title, "Updated fixture", cut.rawValue)
                XCTAssertEqual(recovered.preferences.first?.value, .string("large"), cut.rawValue)
                XCTAssertEqual(recovered.preferenceOutbox.count, 1, cut.rawValue)
                XCTAssertEqual(recovered.pendingReceipts.first?.status, "applied", cut.rawValue)
                XCTAssertNotNil(try recovered.selected.map { try recovered.store(for: $0).assets["index.html"] })
                XCTAssertEqual(try recovered.applyAuthoringResult(result(input), now: 3_000).status, "applied")
            }
        }
    }

    @MainActor func testStaleScreenConflictsWithoutSavingPreference() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        try library.install(artifact("Original fixture"), requestID: "original", replacing: "fixture-screen")
        let input = try request(library); try library.saveAuthoringRequest(input)
        try library.install(artifact("Newer fixture"), requestID: "concurrent", replacing: "fixture-screen")
        let receipt = try library.applyAuthoringResult(result(input), now: 2_000)
        XCTAssertEqual(receipt.status, "conflict")
        XCTAssertEqual(library.selected?.artifact.title, "Newer fixture")
        XCTAssertTrue(library.preferences.isEmpty)
        XCTAssertEqual(library.pendingReceipts, [receipt])
    }

    @MainActor func testCancellationAndUnboundLegacyRestoreCannotInstall() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        let input = try request(library); try library.saveAuthoringRequest(input)
        try library.cancelRequest(input.requestID)
        XCTAssertEqual(try library.applyAuthoringResult(result(input), now: 2_000).status, "rejected")
        XCTAssertNil(library.selected)
        XCTAssertTrue(library.preferences.isEmpty)
        let legacy = try request(library, id: "legacy-request"); try library.saveAuthoringRequest(legacy)
        XCTAssertEqual(try library.rejectAuthoringResult(result(legacy), reason: "Resend this request to bind its screen revision.", now: 2_000).status, "rejected")
        XCTAssertNil(library.selected)
    }

    @MainActor func testExistingLibraryMetadataMigratesAndAccountsStaySeparate() throws {
        let first = directory(), second = directory()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let library = try ScreenLibrary(accountID: "first-account", rootDirectory: first)
        try library.install(artifact("Existing fixture"), requestID: "legacy-install", replacing: "fixture-screen")
        let input = try request(library); try library.saveAuthoringRequest(input)
        _ = try library.applyAuthoringResult(result(input), now: 2_000)
        let other = try ScreenLibrary(accountID: "second-account", rootDirectory: second)
        XCTAssertTrue(other.preferences.isEmpty); XCTAssertTrue(other.state.screens.isEmpty)
        XCTAssertTrue(other.pendingReceipts.isEmpty)
        // Old indexes did not contain authoring metadata. Decode them in the same directory.
        let data = try JSONEncoder().encode(library.state)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "authoring")
        try JSONSerialization.data(withJSONObject: old).write(to: first.appendingPathComponent("library.json"), options: .atomic)
        let migrated = try ScreenLibrary(accountID: "first-account", rootDirectory: first)
        XCTAssertEqual(migrated.selected?.artifact.title, "Updated fixture")
        XCTAssertTrue(migrated.preferences.isEmpty)
        XCTAssertNotNil(try migrated.selected.map { try migrated.store(for: $0).assets["index.html"] })
    }

    @MainActor func testRawWireRejectsUnknownNestedFieldsBeforeCodableDropsThem() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        let input = try request(library)
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        var output = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result(input))) as? [String: Any])
        let valid = try JSONSerialization.data(withJSONObject: ["snapshot": snapshot, "authoringResult": output])
        XCTAssertNoThrow(try DeviceAuthoringWire.validateResponse(valid))
        output["constructor"] = "unexpected"
        let unknown = try JSONSerialization.data(withJSONObject: ["snapshot": snapshot, "authoringResult": output])
        XCTAssertThrowsError(try DeviceAuthoringWire.validateResponse(unknown))
        var preference = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result(input).preferenceMutations![0].record!)) as? [String: Any])
        preference["extra"] = true
        XCTAssertThrowsError(try DeviceAuthoringWire.validateResponse(JSONSerialization.data(withJSONObject: ["records": [preference]])))
    }

    @MainActor func testReenrollmentQuarantinesOldDeliveryAndPreservesSavedPreferences() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        let input = try request(library); try library.saveAuthoringRequest(input)
        let receipt = try library.applyAuthoringResult(result(input), now: 2_000)
        let pending = try request(library, id: "old-device-pending"); try library.saveAuthoringRequest(pending)
        try library.savePending(id: pending.requestID, screenID: pending.context.screenID, consumedID: nil)
        try library.saveSubmission(key: pending.requestID, text: pending.context.userRequest, screen: pending.context.currentScreen)
        try library.activateAuthoringDevice(deviceID: "new-fixture-device")
        XCTAssertNil(library.state.pendingID)
        XCTAssertNil(library.state.submissionKey)
        XCTAssertEqual(library.preferences.first?.value, .string("large"))
        XCTAssertTrue(library.pendingReceipts(deviceID: "new-fixture-device").isEmpty)
        XCTAssertEqual(library.pendingReceipts(deviceID: "fixture-device"), [receipt])
        XCTAssertEqual(library.selected?.artifact.title, "Updated fixture")
        let restarted = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
        XCTAssertNil(restarted.authoringRequest(id: pending.requestID))
        XCTAssertEqual(restarted.preferences.first?.value, .string("large"))
    }

    @MainActor func testLostSubmissionResponseCannotLeaveTerminalRequestBlockingNewInstructions() throws {
        for terminal in ["completed", "rejected", "ended"] {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            let library = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
            let input = try request(library)
            try library.saveSubmission(key: input.requestID, text: input.context.userRequest, screen: input.context.currentScreen)
            try library.saveAuthoringRequest(input)
            // HTTP acceptance was lost, so there was never a submissionAccepted call.
            switch terminal {
            case "completed": _ = try library.applyAuthoringResult(result(input), now: 2_000)
            case "rejected": _ = try library.rejectAuthoringResult(result(input), reason: "Explicit rejection", now: 2_000)
            default: try library.retireAuthoringRequest(id: input.requestID)
            }
            let restarted = try ScreenLibrary(accountID: "fixture-account", rootDirectory: root)
            XCTAssertNil(restarted.state.submissionKey, terminal)
            XCTAssertNil(restarted.state.submissionText, terminal)
            XCTAssertNil(restarted.state.submissionScreen, terminal)
            try restarted.saveSubmission(key: "next-request", text: "Different instructions", screen: restarted.selected?.artifact)
            XCTAssertEqual(restarted.state.submissionKey, "next-request")
        }
    }
}
