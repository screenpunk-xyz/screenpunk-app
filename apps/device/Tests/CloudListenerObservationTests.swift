import XCTest
@testable import DeviceAuthoring

final class CloudListenerObservationTests: XCTestCase {
    private func observation(ready: Bool? = true, account: String = "account-a", device: String = "ipad", profile: String? = "profile-a", pluginConnected: Bool? = nil) -> CloudListenerObservation {
        .init(accountID: account, deviceID: device, profileID: profile, ready: ready, pluginConnected: pluginConnected)
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
    func testSettingsReadSurvivesSocketFailureAndDisconnect() {
        var reads = CloudListenerObservations()
        reads.publish(observation(ready: false), source: .direct, read: 1)
        reads.publish(observation(ready: nil), source: .socket, read: 2)
        reads.clearSocket()
        XCTAssertEqual(status(reads.observation), .waiting)
        reads.clear()
        XCTAssertEqual(status(reads.observation), .unchecked)
    }

    func testNewerSocketStatusFencesDelayedSettingsReadEvenAfterDisconnect() {
        var reads = CloudListenerObservations()
        reads.publish(observation(), source: .socket, read: 2)
        reads.publish(observation(ready: false), source: .direct, read: 1)
        XCTAssertEqual(status(reads.observation), .connected)
        reads.clearSocket()
        reads.publish(observation(), source: .direct, read: 1)
        XCTAssertEqual(status(reads.observation), .unchecked)
        reads.publish(observation(ready: false), source: .direct, read: 3)
        XCTAssertEqual(status(reads.observation), .waiting)
    }

    func testGrantCanBePresentBeforeListenerAndRequiresMatchingScope() {
        let granted = observation(ready: false, pluginConnected: true)
        XCTAssertEqual(status(granted), .waiting)
        XCTAssertFalse(granted.canCompleteCloudSetup)
        XCTAssertEqual(granted.pluginConnection(accountID: "account-a", deviceID: "ipad", profileID: "profile-a"), true)
        XCTAssertNil(granted.pluginConnection(accountID: "account-b", deviceID: "ipad", profileID: "profile-a"))
        XCTAssertNil(granted.pluginConnection(accountID: "account-a", deviceID: "other-ipad", profileID: "profile-a"))
        XCTAssertNil(granted.pluginConnection(accountID: "account-a", deviceID: "ipad", profileID: "profile-b"))
    }

    func testRevocationAndUnavailabilityReplaceGrantWithoutInferringFromListener() {
        var reads = CloudListenerObservations()
        reads.publish(observation(pluginConnected: true), source: .direct, read: 1)
        reads.publish(observation(pluginConnected: false), source: .direct, read: 2)
        reads.publish(observation(pluginConnected: true), source: .direct, read: 1)
        XCTAssertEqual(reads.observation?.pluginConnected, false)
        XCTAssertEqual(status(reads.observation), .connected)
        XCTAssertEqual(reads.observation?.canCompleteCloudSetup, false)
        XCTAssertTrue(observation().canCompleteCloudSetup)
        XCTAssertTrue(observation(pluginConnected: true).canCompleteCloudSetup)

        reads.publish(observation(ready: nil), source: .direct, read: 3)
        XCTAssertNil(reads.observation?.pluginConnected)
        XCTAssertEqual(status(reads.observation), .unavailable)
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
