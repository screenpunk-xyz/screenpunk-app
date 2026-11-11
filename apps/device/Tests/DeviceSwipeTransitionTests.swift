import XCTest
@testable import DeviceAuthoring

final class DeviceSwipeTransitionTests: XCTestCase {
    func testDragCommitsOnePageInEitherDirection() {
        XCTAssertEqual(DeviceSwipeTransition.direction(translation: -160, velocity: 0, width: 1024), 1)
        XCTAssertEqual(DeviceSwipeTransition.direction(translation: 160, velocity: 0, width: 1024), -1)
    }

    func testShortFlickCommitsAndSlowDragCancels() {
        XCTAssertEqual(DeviceSwipeTransition.direction(translation: -45, velocity: -900, width: 1024), 1)
        XCTAssertNil(DeviceSwipeTransition.direction(translation: -45, velocity: -50, width: 1024))
    }

    func testReversingTowardCenterCancels() {
        XCTAssertNil(DeviceSwipeTransition.direction(translation: -180, velocity: 600, width: 1024))
        XCTAssertNil(DeviceSwipeTransition.direction(translation: 20, velocity: -1800, width: 375))
    }

    func testCompactWidthAndMinimumMovement() {
        XCTAssertEqual(DeviceSwipeTransition.direction(translation: 95, velocity: 0, width: 375), -1)
        XCTAssertNil(DeviceSwipeTransition.direction(translation: 8, velocity: 1800, width: 375))
        XCTAssertNil(DeviceSwipeTransition.direction(translation: 160, velocity: 0, width: 0))
    }
}
