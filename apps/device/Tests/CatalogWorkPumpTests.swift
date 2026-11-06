import Foundation
import XCTest
@testable import DeviceAuthoring

final class CatalogWorkPumpTests: XCTestCase {
    @MainActor func testIdleHasNoTimerAndNextSignalStartsWork() async throws {
        let pump = CatalogWorkPump()
        let first = expectation(description: "first signal")
        let second = expectation(description: "second signal")
        var calls = 0
        let step: @MainActor () async -> CatalogWorkPump.Next = {
            calls += 1
            if calls == 1 { first.fulfill() }
            if calls == 2 { second.fulfill() }
            return .idle
        }
        pump.request(step)
        await fulfillment(of: [first], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls, 1)
        pump.request(step)
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(calls, 2)
    }

    @MainActor func testSignalsDuringWorkCoalesceIntoOneTrailingPass() async throws {
        let pump = CatalogWorkPump()
        let started = expectation(description: "started")
        let trailing = expectation(description: "trailing pass")
        var finish: CheckedContinuation<Void, Never>?
        var calls = 0
        let step: @MainActor () async -> CatalogWorkPump.Next = {
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { continuation in
                    finish = continuation
                    started.fulfill()
                }
            } else if calls == 2 { trailing.fulfill() }
            return .idle
        }
        pump.request(step)
        await fulfillment(of: [started], timeout: 2)
        for _ in 0..<10 { pump.request(step) }
        finish?.resume()
        await fulfillment(of: [trailing], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls, 2)
    }

    @MainActor func testRetryDeadlineAndCancellationFence() async throws {
        let pump = CatalogWorkPump()
        let first = expectation(description: "scheduled retry")
        let retry = expectation(description: "deadline reached")
        let deadline = Date().addingTimeInterval(0.25)
        var calls = 0
        pump.request {
            calls += 1
            if calls == 1 {
                first.fulfill()
                return .retry(deadline)
            }
            XCTAssertGreaterThanOrEqual(Date(), deadline)
            retry.fulfill()
            return .idle
        }
        await fulfillment(of: [first, retry], timeout: 2)

        let cancelled = expectation(description: "scheduled cancelled retry")
        pump.request {
            calls += 1
            cancelled.fulfill()
            return .retry(Date().addingTimeInterval(0.15))
        }
        await fulfillment(of: [cancelled], timeout: 2)
        pump.cancel()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(calls, 3)
    }
}
