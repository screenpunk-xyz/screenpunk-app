import Foundation
import ScreenpunkApple
import XCTest
import ScreenpunkCore
@testable import DeviceAuthoring

final class ScreenLibraryVisibilityTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-visibility-" + UUID().uuidString)
    }

    @MainActor private func install(_ ids: [String], in library: ScreenLibrary) throws {
        for id in ids {
            try library.install(.init(title: id, files: [.init(path: "index.html", content: "<html><body>\(id)</body></html>")]),
                                requestID: UUID().uuidString, replacing: id)
        }
    }

    @MainActor func testDisplayNamePersistsThroughPackageEditsRollbackAndReopen() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var library = try ScreenLibrary(accountID: "one", rootDirectory: root)
        try install(["screen-a", "screen-b"], in: library)
        try library.selectVisible("screen-a")
        let original = try XCTUnwrap(library.selected)
        let originalURL = root.appendingPathComponent(original.revision).appendingPathComponent("index.html")
        let originalBytes = try Data(contentsOf: originalURL)
        let generation = library.state.screenDataGenerations?[original.id]

        try library.renameScreen(original.id, to: "  screen-b  ")
        XCTAssertEqual(library.state.screens.map(\.displayName), ["screen-b", "screen-b"])
        XCTAssertEqual(library.selected?.revision, original.revision)
        XCTAssertEqual(library.selected?.artifact.title, "screen-a")
        XCTAssertEqual(library.state.screenDataGenerations?[original.id], generation)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        XCTAssertThrowsError(try library.renameScreen(original.id, to: "  "))
        XCTAssertThrowsError(try library.renameScreen(original.id, to: "name\nsecond line"))
        XCTAssertThrowsError(try library.renameScreen(original.id, to: String(repeating: "a", count: 101)))
        XCTAssertThrowsError(try library.renameScreen(ScreenLibrary.instructionsID, to: "Other"))

        try library.install(.init(title: "Agent package title", files: [.init(path: "index.html", content: "<html>Updated</html>")]),
                            requestID: UUID().uuidString, replacing: original.id)
        XCTAssertEqual(library.selected?.displayName, "screen-b")
        XCTAssertEqual(library.selected?.artifact.title, "Agent package title")
        try library.renameScreen(original.id, to: "Local title")
        try library.rollback()
        XCTAssertEqual(library.selected?.revision, original.revision)
        XCTAssertEqual(library.selected?.displayName, "Local title")

        library = try ScreenLibrary(accountID: "one", rootDirectory: root)
        XCTAssertEqual(library.selected?.displayName, "Local title")
        try library.rollback()
        XCTAssertEqual(library.selected?.displayName, "Local title")
        XCTAssertEqual(library.selected?.artifact.title, "Agent package title")
        try library.remove(original.id)
        try install([original.id], in: library)
        XCTAssertEqual(library.selected?.displayName, original.id)
    }

    @MainActor func testInstructionsRotatePersistAndCannotBeDeleted() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "one", rootDirectory: root)
        XCTAssertTrue(library.instructionsSelected)
        try install(["weather"], in: library)
        try library.select(offset: 1)
        XCTAssertTrue(library.instructionsSelected)
        try library.remove(ScreenLibrary.instructionsID)
        XCTAssertTrue(library.instructionsSelected)
        try library.activateTemporarily(id: "alert", screenID: "weather", expiresAt: Date().addingTimeInterval(60))
        try library.endTemporary(id: "alert")
        XCTAssertTrue(library.instructionsSelected)
        try library.setScreenShown(false, id: ScreenLibrary.instructionsID)
        XCTAssertEqual(library.selected?.id, "weather")
        let reopened = try ScreenLibrary(accountID: "one", rootDirectory: root)
        XCTAssertFalse(reopened.isScreenShown(ScreenLibrary.instructionsID))
        try reopened.select(offset: 1)
        XCTAssertEqual(reopened.selected?.id, "weather")
        try reopened.setScreenShown(true, id: ScreenLibrary.instructionsID)
        try reopened.select(offset: 1)
        XCTAssertTrue(reopened.instructionsSelected)
    }

    @MainActor func testSameScreenActivationSupersessionChangesNavigationIdentity() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "one", rootDirectory: root)
        try install(["alert"], in: library)
        let expiry = Date().addingTimeInterval(60)
        try library.activateTemporarily(id: "first", screenID: "alert", expiresAt: expiry)
        let revision = library.selected?.revision
        XCTAssertEqual(library.temporaryActivationID, "first")
        try library.activateTemporarily(id: "second", screenID: "alert", expiresAt: expiry)
        XCTAssertEqual(library.selected?.revision, revision)
        XCTAssertEqual(library.temporaryActivationID, "second")
        try library.endTemporary(id: "first")
        XCTAssertEqual(library.temporaryActivationID, "second")
        try library.endTemporary(id: "second")
        XCTAssertNil(library.temporaryActivationID)
    }

    @MainActor func testShowDefaultsOnAndOrdinaryNavigationSkipsHiddenScreens() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "one", rootDirectory: root)
        try install(["one", "two", "three"], in: library)
        XCTAssertNil(library.state.hiddenScreenIDs)
        XCTAssertTrue(library.isScreenShown("two"))
        try library.setScreenShown(false, id: ScreenLibrary.instructionsID)

        try library.selectVisible("one")
        try library.setScreenShown(false, id: "two")
        try library.select(offset: 1)
        XCTAssertEqual(library.selected?.id, "three")
        try library.select(offset: -1)
        XCTAssertEqual(library.selected?.id, "one")
        try library.selectVisible("two")
        XCTAssertEqual(library.selected?.id, "one")
        try library.setScreenShown(false, id: "one")
        XCTAssertEqual(library.selected?.id, "three")
        try library.setScreenShown(false, id: "three")
        XCTAssertNil(library.selected)
        try library.select(offset: 1)
        XCTAssertNil(library.selected)
        XCTAssertEqual(library.state.screens.count, 3)
        try library.setScreenShown(true, id: "two")
        XCTAssertEqual(library.selected?.id, "two")
    }

    @MainActor func testVisibilityPersistsAcrossPackageUpdatesAndReopenAndCleansOnRemoval() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let other = directory(); defer { try? FileManager.default.removeItem(at: other) }
        let library = try ScreenLibrary(accountID: "one", rootDirectory: root)
        try library.setScreenShown(false, id: ScreenLibrary.instructionsID)
        try install(["one", "two"], in: library)
        try library.setScreenShown(false, id: "two")
        try install(["two"], in: library)
        XCTAssertEqual(library.selected?.id, "one")
        let reopened = try ScreenLibrary(accountID: "one", rootDirectory: root)
        XCTAssertFalse(reopened.isScreenShown("two"))
        XCTAssertEqual(reopened.selected?.id, "one")
        let otherLibrary = try ScreenLibrary(accountID: "other", rootDirectory: other)
        try install(["two"], in: otherLibrary)
        XCTAssertTrue(otherLibrary.isScreenShown("two"))
        try reopened.remove("two")
        try install(["two"], in: reopened)
        XCTAssertTrue(reopened.isScreenShown("two"))
    }

    @MainActor func testTemporaryHiddenTargetAndNestedOverrideUseVisibleFallback() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "one", rootDirectory: root)
        try install(["original", "fallback", "event", "nested"], in: library)
        try library.selectVisible("original")
        let expiry = Date().addingTimeInterval(60)
        try library.activateTemporarily(id: "event1", screenID: "event", expiresAt: expiry)
        try library.setScreenShown(false, id: "event")
        try library.setScreenShown(false, id: "original")
        try install(["fallback"], in: library)
        XCTAssertEqual(library.selected?.id, "event")
        try library.setScreenShown(false, id: "nested")
        try library.activateTemporarily(id: "event2", screenID: "nested", expiresAt: expiry)
        XCTAssertEqual(library.selected?.id, "nested")
        try library.endTemporary(id: "event1")
        XCTAssertEqual(library.selected?.id, "nested")
        try library.reconcileTemporary(now: expiry)
        XCTAssertEqual(library.selected?.id, "fallback")
    }

    @MainActor func testRedAlertHomeAssistantLeaseRespectsRevisionAndRestoresVisibleScreen() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "one", rootDirectory: root)
        try install(["dashboard", "red-alert"], in: library)
        try library.selectVisible("dashboard")
        try library.setScreenShown(false, id: "red-alert")
        let revision = try XCTUnwrap(library.state.screens.first { $0.id == "red-alert" }?.revision)
        let configuration = TemporaryActivationConfiguration(entityId: "sensor.screenpunk_red_alert", activeState: "on",
            inactiveState: "off", idAttribute: "alert_id", startedAtAttribute: "started_at", expiresAtAttribute: "expires_at",
            maxDurationSeconds: 300)
        let now = Date()
        let timestamp = ISO8601DateFormatter()
        func state(_ state: String, id: String, start: Date, entity: String = "sensor.screenpunk_red_alert") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["entity_id": entity, "state": state, "attributes": [
                "alert_id": id, "started_at": timestamp.string(from: start),
                "expires_at": timestamp.string(from: start.addingTimeInterval(60))
            ]])
        }
        func receive(_ bytes: Data, revision: String = revision, at time: Date = now) throws {
            try library.receiveTemporaryHomeAssistantState(bytes, screenID: "red-alert", revision: revision,
                                                           configuration: configuration, now: time)
        }

        let active = try state("on", id: "activation-one", start: now)
        try receive(active, revision: "retired-revision")
        try receive(state("on", id: "activation-one", start: now, entity: "sensor.other"))
        XCTAssertEqual(library.selected?.id, "dashboard")
        try receive(active)
        XCTAssertEqual(library.selected?.id, "red-alert")
        XCTAssertEqual(library.temporaryActivationID, "activation-one")
        XCTAssertFalse(library.rotationIDs.filter { library.isScreenShown($0) }.contains("red-alert"))
        try receive(state("off", id: "old", start: now))
        XCTAssertEqual(library.selected?.id, "red-alert")
        try receive(state("off", id: "activation-one", start: now))
        XCTAssertEqual(library.selected?.id, "dashboard")
        XCTAssertNil(library.temporaryActivationID)

        try receive(active, at: now.addingTimeInterval(1))
        XCTAssertEqual(library.selected?.id, "dashboard")
        let newer = now.addingTimeInterval(3)
        let repeatActive = try state("on", id: "activation-two", start: newer)
        try receive(repeatActive, at: newer)
        XCTAssertEqual(library.selected?.id, "red-alert")
        try library.selectVisible("dashboard")
        try receive(repeatActive, at: newer.addingTimeInterval(1))
        XCTAssertEqual(library.selected?.id, "dashboard")
        XCTAssertNil(library.temporaryActivationID)
    }

    @MainActor func testTwoHomeAssistantTargetsWithSameAlertIDDoNotClearEachOther() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "one", rootDirectory: root)
        try install(["dashboard", "red-alert", "other-alert"], in: library)
        try library.selectVisible("dashboard")
        try library.setScreenShown(false, id: "red-alert")
        try library.setScreenShown(false, id: "other-alert")
        let now = Date()
        let timestamp = ISO8601DateFormatter()
        func receive(_ state: String, _ target: String, at date: Date) throws {
            let entity = "sensor." + target.replacingOccurrences(of: "-", with: "_")
            let configuration = TemporaryActivationConfiguration(entityId: entity, activeState: "on", inactiveState: "off",
                idAttribute: "alert_id", startedAtAttribute: "started_at", expiresAtAttribute: "expires_at", maxDurationSeconds: 300)
            let revision = try XCTUnwrap(library.state.screens.first { $0.id == target }?.revision)
            let payload = try JSONSerialization.data(withJSONObject: ["entity_id": entity, "state": state, "attributes": [
                "alert_id": "shared-id", "started_at": timestamp.string(from: date),
                "expires_at": timestamp.string(from: date.addingTimeInterval(60))
            ]])
            try library.receiveTemporaryHomeAssistantState(payload, screenID: target, revision: revision, configuration: configuration, now: date)
        }

        try receive("on", "red-alert", at: now)
        XCTAssertEqual(library.selected?.id, "red-alert")
        try receive("on", "other-alert", at: now.addingTimeInterval(2))
        XCTAssertEqual(library.selected?.id, "other-alert")
        XCTAssertEqual(library.temporaryActivationID, "shared-id")
        try receive("off", "red-alert", at: now.addingTimeInterval(3))
        try library.endTemporary(id: "shared-id")
        XCTAssertEqual(library.selected?.id, "other-alert")
        try receive("off", "other-alert", at: now.addingTimeInterval(4))
        XCTAssertEqual(library.selected?.id, "dashboard")
        XCTAssertNil(library.temporaryActivationID)
    }

    @MainActor func testExplicitActivationFromAllHiddenRestoresNeutralAcrossRelaunch() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "one", rootDirectory: root)
        try library.setScreenShown(false, id: ScreenLibrary.instructionsID)
        try install(["event"], in: library)
        try library.setScreenShown(false, id: "event")
        XCTAssertNil(library.selected)
        try library.activateTemporarily(id: "event1", screenID: "event", expiresAt: Date().addingTimeInterval(60))
        let reopened = try ScreenLibrary(accountID: "one", rootDirectory: root)
        XCTAssertEqual(reopened.selected?.id, "event")
        try reopened.endTemporary(id: "event1")
        XCTAssertNil(reopened.selected)
        XCTAssertFalse(reopened.isScreenShown("event"))
    }

    @MainActor func testPendingNeutralFallbackSurvivesCheckpointBeforeSelectionCommit() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScreenLibrary(accountID: "one", rootDirectory: root)
        try library.setScreenShown(false, id: ScreenLibrary.instructionsID)
        try install(["event"], in: library)
        let expiry = Date().addingTimeInterval(60)
        try library.activateTemporarily(id: "event1", screenID: "event", expiresAt: expiry)
        try library.setScreenShown(false, id: "event")
        XCTAssertEqual(library.selected?.id, "event")

        // Write the expiry checkpoint without committing its selection, simulating an interruption.
        let controller = try LocalTemporaryActivationController(root: root, owner: "one")
        XCTAssertEqual(try controller.reconcile(selected: "event", now: expiry, fallbackSelection: ""), "")
        let reopened = try ScreenLibrary(accountID: "one", rootDirectory: root)
        XCTAssertNil(reopened.selected)
        XCTAssertFalse(reopened.isScreenShown("event"))
    }
}
