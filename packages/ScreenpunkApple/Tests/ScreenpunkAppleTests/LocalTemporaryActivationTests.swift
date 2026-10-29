import XCTest
@testable import ScreenpunkApple

final class LocalTemporaryActivationTests: XCTestCase {
    @MainActor func testOfflineRelaunchRestoresAndAccountCannotInheritState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-activation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1800000000)
        let first = try LocalTemporaryActivationController(root: root, owner: "one")
        XCTAssertEqual(try first.activate(id: "alert", target: "scores", expiresAt: now.addingTimeInterval(20), selected: "weather", startedAt: now, now: now), "scores")
        try first.acknowledgeSelection()
        let recovered = try LocalTemporaryActivationController(root: root, owner: "one")
        XCTAssertEqual(try recovered.reconcile(selected: "scores", now: now.addingTimeInterval(21)), "weather")
        let afterRestoreProposal = try LocalTemporaryActivationController(root: root, owner: "one")
        XCTAssertEqual(try afterRestoreProposal.reconcile(selected: "scores", now: now.addingTimeInterval(22)), "weather")
        let other = try LocalTemporaryActivationController(root: root, owner: "two")
        XCTAssertNil(try other.reconcile(selected: "scores", now: now.addingTimeInterval(21)))
    }
    @MainActor func testEndBeforeSelectionCancelsPendingActivation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-activation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let controller = try LocalTemporaryActivationController(root: root, owner: "one")
        _ = try controller.activate(id: "alert", target: "scores", expiresAt: now.addingTimeInterval(20), selected: "weather", startedAt: now, now: now)
        XCTAssertNil(try controller.end(id: "alert", selected: "weather"))
        XCTAssertNil(try controller.reconcile(selected: "weather", now: now))
    }
}
