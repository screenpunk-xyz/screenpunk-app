import XCTest
@testable import DeviceAuthoring

final class CloudPluginSetupProgressTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let scope = CloudPluginSetupProgress.Scope(origin: "https://staging.screenpunk.xyz", account: "a", device: "ipad", owner: "library")
    private func input(_ connected: Bool?, ready: Bool = false, scope: CloudPluginSetupProgress.Scope? = nil) -> CloudPluginSetupProgress.Input {
        .init(scope: scope ?? self.scope, pluginConnected: connected, listenerReady: ready)
    }

    func testOnlyAuthoritativeConnectionStartsGraceAndRepeatedReadsDoNotExtendIt() {
        var flow = CloudPluginSetupProgress()
        flow.update(input(nil), now: start)
        XCTAssertEqual(flow.phase, .plugin)
        XCTAssertNil(flow.wakeDeadline)
        flow.update(input(false), now: start)
        XCTAssertNil(flow.wakeDeadline)
        flow.update(input(true), now: start)
        XCTAssertEqual(flow.phase, .looking)
        XCTAssertEqual(flow.wakeDeadline, start.addingTimeInterval(30))
        flow.update(input(true), now: start.addingTimeInterval(29))
        XCTAssertEqual(flow.phase, .looking)
        XCTAssertEqual(flow.wakeDeadline, start.addingTimeInterval(30))
        flow.update(input(true), now: start.addingTimeInterval(30))
        XCTAssertEqual(flow.phase, .manualListener)
        XCTAssertNil(flow.wakeDeadline)
    }

    func testUnknownReadsPreserveGraceAndFallbackKeepsAcceptingLateListener() {
        var flow = CloudPluginSetupProgress()
        flow.update(input(true), now: start)
        flow.update(input(nil), now: start.addingTimeInterval(20))
        XCTAssertEqual(flow.phase, .looking)
        flow.update(input(nil), now: start.addingTimeInterval(31))
        XCTAssertEqual(flow.phase, .manualListener)
        flow.update(input(true), now: start.addingTimeInterval(35))
        XCTAssertEqual(flow.phase, .manualListener)
        flow.update(input(true, ready: true), now: start.addingTimeInterval(40))
        XCTAssertEqual(flow.phase, .ready)
        XCTAssertNil(flow.wakeDeadline)
    }

    func testHealthyListenerAdvancesImmediatelyWithoutWaitingOrStartingTimer() {
        var flow = CloudPluginSetupProgress()
        flow.update(input(true, ready: true), now: start)
        XCTAssertEqual(flow.phase, .ready)
        XCTAssertNil(flow.firstConnectionDeadline)
        flow = CloudPluginSetupProgress()
        flow.update(input(true), now: start)
        flow.update(input(true, ready: true), now: start.addingTimeInterval(1))
        XCTAssertEqual(flow.phase, .ready)
        XCTAssertNil(flow.wakeDeadline)
    }

    func testInstructionsStayVisibleAcrossConnectionFrameAndYieldToFallbackOrReadiness() {
        var flow = CloudPluginSetupProgress()
        flow.update(input(false), now: start)
        XCTAssertTrue(flow.presentsPluginInstructions(for: input(true)))
        flow.update(input(true), now: start)
        XCTAssertTrue(flow.presentsPluginInstructions(for: input(true)))
        flow.update(input(nil), now: start.addingTimeInterval(29))
        XCTAssertTrue(flow.presentsPluginInstructions(for: input(nil)))
        flow.update(input(nil), now: start.addingTimeInterval(30))
        XCTAssertFalse(flow.presentsPluginInstructions(for: input(nil)))
        XCTAssertFalse(flow.presentsPluginInstructions(for: input(true)))
        XCTAssertFalse(flow.presentsPluginInstructions(for: input(true, ready: true)))
        XCTAssertFalse(flow.presentsPluginInstructions(for: .init(scope: nil, pluginConnected: nil, listenerReady: false)))
    }

    func testAccountOriginDeviceAndLibraryChangesCannotReuseOldDeadline() {
        let scopes = [
            CloudPluginSetupProgress.Scope(origin: scope.origin, account: "b", device: scope.device, owner: scope.owner),
            .init(origin: "https://api.screenpunk.xyz", account: scope.account, device: scope.device, owner: scope.owner),
            .init(origin: scope.origin, account: scope.account, device: "other-ipad", owner: scope.owner),
            .init(origin: scope.origin, account: scope.account, device: scope.device, owner: "other-library")
        ]
        for replacement in scopes {
            var flow = CloudPluginSetupProgress()
            flow.update(input(true), now: start)
            flow.update(input(nil, scope: replacement), now: start.addingTimeInterval(10))
            XCTAssertEqual(flow.phase, .plugin)
            XCTAssertNil(flow.wakeDeadline)
            flow.update(input(true, scope: replacement), now: start.addingTimeInterval(11))
            XCTAssertEqual(flow.wakeDeadline, start.addingTimeInterval(41))
        }
    }

    func testSignOutCancelsGraceAndExplicitDisconnectStartsNewGeneration() {
        var flow = CloudPluginSetupProgress()
        flow.update(input(true), now: start)
        flow.update(.init(scope: nil, pluginConnected: nil, listenerReady: false), now: start.addingTimeInterval(1))
        XCTAssertNil(flow.wakeDeadline)
        XCTAssertNil(flow.scope)
        flow.update(input(true), now: start.addingTimeInterval(2))
        XCTAssertEqual(flow.wakeDeadline, start.addingTimeInterval(32))
        flow.update(input(false), now: start.addingTimeInterval(3))
        XCTAssertEqual(flow.phase, .plugin)
        XCTAssertNil(flow.wakeDeadline)
        flow.update(input(true), now: start.addingTimeInterval(4))
        XCTAssertEqual(flow.wakeDeadline, start.addingTimeInterval(34))
    }
}
