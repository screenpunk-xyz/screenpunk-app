import XCTest
@testable import DeviceAuthoring

final class CloudListenerObservationTests: XCTestCase {
    private func observation(ready: Bool? = true, account: String = "account-a", device: String = "ipad", profile: String? = "profile-a") -> CloudListenerObservation {
        .init(accountID: account, deviceID: device, profileID: profile, ready: ready)
    }
    private func status(_ observation: CloudListenerObservation?, account: String? = "account-a", device: String? = "ipad", profile: String? = "profile-a") -> CloudListenerObservation.Status {
        CloudListenerObservation.status(observation, accountID: account, deviceID: device, profileID: profile)
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
    func testOfflineObservationNeverClaimsConnected() {
        XCTAssertEqual(status(observation(ready: nil)), .unavailable)
        XCTAssertEqual(status(nil), .unchecked)
    }
    func testMissingServerProfileCannotEstablishReadiness() {
        XCTAssertEqual(status(observation(profile: nil)), .unavailable)
        XCTAssertEqual(status(observation(profile: "")), .unavailable)
        // A legacy session without a cached profile can use the authenticated
        // server's profile; the current library/Local route does not determine it.
        XCTAssertEqual(status(observation(), profile: nil), .connected)
    }
}

final class DeviceCloudNoticeTests: XCTestCase {
    private func decode(_ wire: String) -> DeviceCloudNotice? { DeviceCloudNotice.decode(Data(wire.utf8)) }

    func testLegacyStatusAndAdditiveNoticesDecodeWithoutMixingDomains() {
        XCTAssertEqual(decode(#"{"type":"status_changed"}"#), .statusChanged)
        XCTAssertEqual(decode(#"{"type":"preference.updated","profileID":"profile-a"}"#), .preferenceUpdated(profileID: "profile-a"))
        XCTAssertEqual(decode(#"{"type":"catalog.updated"}"#), .catalogUpdated)
    }
    func testUnknownOrMalformedNoticesNeverTriggerReconciliation() {
        XCTAssertNil(decode(#"{"type":"new_event"}"#))
        XCTAssertNil(decode(#"{"type":"preference.updated"}"#))
        XCTAssertNil(decode(#"{"type":"preference.updated","profileID":""}"#))
        XCTAssertNil(decode(#"{"type":"preference.updated","profileID":123}"#))
        XCTAssertNil(decode(#"{"type":"status_changed"}"# + String(repeating: " ", count: 4096)))
    }
}
