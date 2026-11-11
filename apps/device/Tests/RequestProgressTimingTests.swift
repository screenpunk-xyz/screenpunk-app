import XCTest
@testable import DeviceAuthoring

final class RequestProgressTimingTests: XCTestCase {
    func testNewPreflightDoesNotInheritAnOldRequestWarning() {
        var timer = RequestProgressTiming()
        let now = Date(timeIntervalSince1970: 1000)
        timer.lastProgressAt = now.addingTimeInterval(-300)
        timer.warningDismissedAt = now.addingTimeInterval(-200)
        XCTAssertTrue(timer.isTakingLonger(at: now))
        timer.begin(at: now)
        XCTAssertFalse(timer.isTakingLonger(at: now))
        XCTAssertFalse(timer.isTakingLonger(at: now.addingTimeInterval(59)))
        XCTAssertTrue(timer.isTakingLonger(at: now.addingTimeInterval(60)))
        XCTAssertEqual(timer.warningDismissedAt, .distantPast)
    }
    func testProgressAndKeepWaitingEachRestartSilenceWindow() {
        var timer = RequestProgressTiming()
        let start = Date(timeIntervalSince1970: 1000)
        timer.begin(at: start)
        timer.lastProgressAt = start.addingTimeInterval(70)
        XCTAssertFalse(timer.isTakingLonger(at: start.addingTimeInterval(129)))
        XCTAssertTrue(timer.isTakingLonger(at: start.addingTimeInterval(130)))
        timer.warningDismissedAt = start.addingTimeInterval(140)
        XCTAssertFalse(timer.isTakingLonger(at: start.addingTimeInterval(199)))
        XCTAssertTrue(timer.isTakingLonger(at: start.addingTimeInterval(200)))
    }
}
