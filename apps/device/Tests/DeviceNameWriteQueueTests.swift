import XCTest
import ScreenpunkCore

final class DeviceNameWriteQueueTests: XCTestCase {
    @MainActor private final class Gate {
        var isOpen = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { if isOpen { return }; await withCheckedContinuation { continuation = $0 } }
        func open() { isOpen = true; continuation?.resume(); continuation = nil }
    }
    @MainActor func testLateRegistrationCannotOverwriteNewerOfflineRenameEvenWhenCallerCancelled() async throws {
        let queue = DeviceNameWriteQueue(), started = Gate(), release = Gate()
        var desired = "Office A", writes: [String] = []
        let first = Task { try await queue.perform {
            let captured = desired; started.open(); await release.wait(); writes.append(captured); return captured
        } }
        await started.wait()
        desired = "Office B"
        let second = Task { try await queue.perform { let latest = desired; writes.append(latest); return latest } }
        first.cancel()
        await Task.yield()
        XCTAssertTrue(writes.isEmpty, "A newer write must not overtake a still-running server mutation.")
        release.open()
        let firstAcknowledgement = try await first.value, secondAcknowledgement = try await second.value
        XCTAssertNotEqual(firstAcknowledgement, desired, "An old acknowledgement cannot clear a newer desired name.")
        XCTAssertEqual(secondAcknowledgement, desired)
        XCTAssertEqual(writes, ["Office A", "Office B"])
    }
    @MainActor func testFailedRegistrationDoesNotPoisonFollowingRename() async throws {
        enum Offline: Error { case disconnected }
        let queue = DeviceNameWriteQueue()
        do { let _: String = try await queue.perform { throw Offline.disconnected }; XCTFail("Expected the offline failure.") } catch { }
        let result = try await queue.perform { "Office latest" }
        XCTAssertEqual(result, "Office latest")
    }
}
