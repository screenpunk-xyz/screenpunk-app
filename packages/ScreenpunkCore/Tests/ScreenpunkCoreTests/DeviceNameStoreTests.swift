import Foundation
import XCTest
@testable import ScreenpunkCore

final class DeviceNameStoreTests: XCTestCase {
    func testNameSurvivesStoreRecreationAndStaysWithItsIdentity() throws {
        let suite = "DeviceNameStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DeviceNameStore(defaults: defaults)
        XCTAssertEqual(try store.save("  Kitchen iPad  ", for: "install-a"), "Kitchen iPad")
        let reopened = DeviceNameStore(defaults: defaults)
        XCTAssertEqual(reopened.name(for: "install-a"), "Kitchen iPad")
        XCTAssertEqual(reopened.name(for: "install-b"), "Screenpunk")
        XCTAssertThrowsError(try reopened.save("\n ", for: "install-a"))
        XCTAssertThrowsError(try reopened.save(String(repeating: "a", count: 81), for: "install-a"))
        XCTAssertThrowsError(try reopened.save("Kitchen\nDisplay", for: "install-a"))
        XCTAssertThrowsError(try reopened.save("Other", for: ""))
        XCTAssertEqual(reopened.name(for: "install-a"), "Kitchen iPad")
        let emojiLimit = String(repeating: "😀", count: 40)
        XCTAssertEqual(try reopened.save(emojiLimit, for: "install-a"), emojiLimit)
        XCTAssertThrowsError(try reopened.save(String(repeating: "😀", count: 41), for: "install-a"))
        XCTAssertEqual(reopened.name(for: "install-a"), emojiLimit)
    }
}
