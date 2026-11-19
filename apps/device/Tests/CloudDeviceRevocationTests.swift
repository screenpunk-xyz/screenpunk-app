import Foundation
import XCTest
import ScreenpunkCore
@testable import DeviceAuthoring

final class CloudDeviceRevocationTests: XCTestCase {
    func testOnlyAuthoritativeUnauthorizedResponseRevokesCapturedEnrollment() {
        let revoked = Data(#"{"error":"device_revoked","deviceId":"device-a"}"#.utf8)
        XCTAssertTrue(CloudDeviceRevocationEvidence.matches(status: 401, data: revoked, deviceID: "device-a"))
        XCTAssertFalse(CloudDeviceRevocationEvidence.matches(status: 401, data: revoked, deviceID: "device-b"))
        for status in [200, 400, 403, 404, 409, 429, 500, 502, 503] {
            XCTAssertFalse(CloudDeviceRevocationEvidence.matches(status: status, data: revoked, deviceID: "device-a"))
        }
        for response in [#"{"error":"unauthorized"}"#, #"{"error":"expired"}"#, #"{"error":"device_revoked"}"#, #"{"error":"device_revoked","deviceId":42}"#, "{}", "not-json"] {
            XCTAssertFalse(CloudDeviceRevocationEvidence.matches(status: 401, data: Data(response.utf8), deviceID: "device-a"))
        }
    }

    func testRevocationNoticesRequireEnrollmentIdentityAndRespectSizeLimit() {
        XCTAssertEqual(DeviceCloudNotice.decode(Data(#"{"type":"device_revoked","deviceId":"device-a"}"#.utf8)), .deviceRevoked(deviceID: "device-a"))
        for response in [#"{"type":"device_revoked"}"#, #"{"type":"device_revoked","deviceId":""}"#, #"{"type":"device_revoked","deviceId":42}"#] {
            XCTAssertNil(DeviceCloudNotice.decode(Data(response.utf8)))
        }
        XCTAssertNil(DeviceCloudNotice.decode(Data((#"{"type":"device_revoked","deviceId":"device-a"}"# + String(repeating: " ", count: 4096)).utf8)))
    }

    func testCanonicalNameNoticeRequiresCompleteValidRevisionedMetadata() {
        let wire = #"{"type":"device_name_updated","deviceId":"device-a","name":"Pappy's iPad","nameRevision":3,"enrollmentRevision":2}"#
        XCTAssertEqual(DeviceCloudNotice.decode(Data(wire.utf8)), .deviceNameUpdated(.init(deviceId: "device-a", name: "Pappy's iPad", nameRevision: 3, enrollmentRevision: 2)))
        for invalid in [wire.replacingOccurrences(of: ",\"enrollmentRevision\":2", with: ""), wire.replacingOccurrences(of: "\"nameRevision\":3", with: "\"nameRevision\":-1"), wire.replacingOccurrences(of: "\"deviceId\":\"device-a\"", with: "\"deviceId\":\"\"")] {
            XCTAssertNil(DeviceCloudNotice.decode(Data(invalid.utf8)))
        }
    }
}
