import Foundation
import XCTest
import ScreenpunkCore
@testable import DeviceAuthoring

final class AuthoringRefreshTests: XCTestCase {
    func testPendingCloudReadSucceededButLocalFallbackAndRecoveryRemain() {
        let pending = AuthoringDeliveryStateV2.pending(.init(status: "pending"))
        XCTAssertTrue(AuthoringRefreshPolicy.reconciliationSucceeded(pending, route: "cloud"))
        XCTAssertFalse(AuthoringRefreshPolicy.reconciliationSucceeded(pending, route: "local"))
        XCTAssertFalse(AuthoringRefreshPolicy.reconciliationSucceeded(.deliveryUncertain(message: "retry"), route: "cloud"))
        XCTAssertFalse(AuthoringRefreshPolicy.reconciliationSucceeded(.needsAttention(message: "input"), route: "local"))
        XCTAssertTrue(AuthoringRefreshPolicy.reconciliationSucceeded(.ended(status: "cancelled", message: nil), route: "cloud"))
    }

    @MainActor func testPendingCloudDoesNotScheduleRepeatedReads() async throws {
        let pump = CatalogWorkPump()
        let read = expectation(description: "pending read")
        var reads = 0
        pump.request {
            reads += 1
            read.fulfill()
            let success = AuthoringRefreshPolicy.reconciliationSucceeded(.pending(.init(status: "pending")), route: "cloud")
            return success ? .idle : .retry(Date().addingTimeInterval(0.01))
        }
        await fulfillment(of: [read], timeout: 2)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(reads, 1)
        pump.cancel()
    }

    @MainActor func testPushWakesLongRetryWithoutWaitingForDeadline() async throws {
        let pump = CatalogWorkPump()
        let first = expectation(description: "failed transport")
        let pushed = expectation(description: "completion push")
        var calls = 0
        let step: @MainActor () async -> CatalogWorkPump.Next = {
            calls += 1
            if calls == 1 { first.fulfill(); return .retry(Date().addingTimeInterval(60)) }
            pushed.fulfill()
            return .idle
        }
        pump.request(step)
        await fulfillment(of: [first], timeout: 2)
        // The first pass has returned before sending the new notification.
        await Task.yield()
        pump.request(step)
        await fulfillment(of: [pushed], timeout: 1)
        XCTAssertEqual(calls, 2)
        pump.cancel()
    }

    @MainActor func testPushDuringFailedReadSurvivesAndDoesNotCancelRead() async throws {
        let pump = CatalogWorkPump()
        let started = expectation(description: "in flight")
        let trailing = expectation(description: "trailing push")
        var continuation: CheckedContinuation<Void, Never>?
        var calls = 0
        let step: @MainActor () async -> CatalogWorkPump.Next = {
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { continuation = $0; started.fulfill() }
                XCTAssertFalse(Task.isCancelled)
                return .retry(Date().addingTimeInterval(60))
            }
            trailing.fulfill()
            return .idle
        }
        pump.request(step)
        await fulfillment(of: [started], timeout: 2)
        for _ in 0..<5 { pump.request(step) }
        continuation?.resume()
        await fulfillment(of: [trailing], timeout: 1)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(calls, 2)
        pump.cancel()
    }

    @MainActor func testCancelledGenerationCannotClobberNewWorker() async throws {
        let pump = CatalogWorkPump()
        let oldStarted = expectation(description: "old pass")
        let newFinished = expectation(description: "new pass")
        let nextFinished = expectation(description: "next pass")
        var old: CheckedContinuation<Void, Never>?
        pump.request {
            await withCheckedContinuation { old = $0; oldStarted.fulfill() }
            return .retry(Date().addingTimeInterval(0.01))
        }
        await fulfillment(of: [oldStarted], timeout: 2)
        pump.cancel()
        pump.request { newFinished.fulfill(); return .idle }
        await fulfillment(of: [newFinished], timeout: 2)
        old?.resume()
        await Task.yield()
        pump.request { nextFinished.fulfill(); return .idle }
        await fulfillment(of: [nextFinished], timeout: 2)
        pump.cancel()
    }
}
