import XCTest
@testable import DeviceAuthoring

final class CloudListenerObservationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private func observation(ready: Bool? = true, account: String = "account-a", device: String = "ipad", profile: String? = "profile-a", age: TimeInterval = 0) -> CloudListenerObservation {
        .init(accountID: account, deviceID: device, profileID: profile, ready: ready, checkedAt: now.addingTimeInterval(-age))
    }
    private func status(_ observation: CloudListenerObservation?, account: String? = "account-a", device: String? = "ipad", profile: String? = "profile-a") -> CloudListenerObservation.Status {
        CloudListenerObservation.status(observation, accountID: account, deviceID: device, profileID: profile, now: now)
    }
    func testSignInAloneDoesNotImplyListenerConnected() {
        XCTAssertEqual(status(nil), .unchecked)
        XCTAssertEqual(status(observation(), account: nil), .notSignedIn)
        XCTAssertEqual(status(observation(), device: nil), .notSignedIn)
    }
    func testOnlyMatchingLiveServerObservationShowsConnected() {
        XCTAssertEqual(status(observation()), .connected)
        XCTAssertEqual(status(observation(ready: false)), .waiting)
        XCTAssertEqual(status(observation(account: "account-b")), .unchecked)
        XCTAssertEqual(status(observation(device: "another-ipad")), .unchecked)
        XCTAssertEqual(status(observation(profile: "another-profile")), .unavailable)
    }
    func testOfflineOrExpiredObservationNeverContinuesToClaimConnected() {
        XCTAssertEqual(status(observation(ready: nil)), .unavailable)
        XCTAssertEqual(status(observation(age: 29)), .connected)
        XCTAssertEqual(status(observation(age: 30)), .unchecked)
        XCTAssertEqual(status(observation(age: -1)), .unchecked)
    }
    func testMissingServerProfileCannotEstablishReadiness() {
        XCTAssertEqual(status(observation(profile: nil)), .unavailable)
        XCTAssertEqual(status(observation(profile: "")), .unavailable)
        // A legacy session without a cached profile can use the authenticated
        // server's profile; the current library/Local route does not determine it.
        XCTAssertEqual(status(observation(), profile: nil), .connected)
    }
}
