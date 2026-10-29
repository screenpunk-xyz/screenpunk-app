import XCTest
@testable import ScreenpunkCore

final class ManifestCompatibilityTests: XCTestCase {
    private let fixture = #"{"schemaVersion":1,"dashboardId":"weather-regression","name":"Weather regression","revision":"2026-10-21T20:51:00Z","entrypoint":"index.html","sdkVersion":1,"target":{"profileId":"ipad-landscape","width":1024,"height":768,"scale":1,"orientation":"landscape"},"connections":[{"alias":"nws","required":true,"publicHTTP":{"origin":"https://api.weather.gov","userAgent":"Screenpunk-AnnArborWeather/1.0","operations":[{"name":"latest","path":"/stations/KARB/observations/latest","response":"json","parameters":{},"maxAgeSeconds":900,"staleSeconds":3600}]}}],"files":[{"path":"index.html","bytes":1144,"sha256":"b84a04b40e9e66ca1d10d5b023c1f164a13d242355fe985ab084a119a21f540f"},{"path":"styles.css","bytes":1328,"sha256":"33e517dd6b9814c04e41ec76dcfb76784cd6fef6bddaad43189f3d60dd15c982"},{"path":"weather.js","bytes":4103,"sha256":"b1f6924003bbb04fbd0b2fc2f313d6373fb4adccdccb38516a654e1fe3118e54"}]}"#
    func testGeneratedNumericSDKManifestLoadsPublicConnection() throws {
        let manifest = try JSONDecoder().decode(DashboardManifest.self, from: Data(fixture.utf8))
        try PackageValidator.validate(manifest)
        XCTAssertEqual(manifest.sdkVersion, "1")
        XCTAssertEqual(try PublicReadProvisioning(manifest: manifest).connections.first?.alias, "nws")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
        XCTAssertEqual(encoded["sdkVersion"] as? String, "1")
    }
    func testStringSDKStillLoadsAndUnsupportedNumericVersionIsRejected() throws {
        let stringVersion = fixture.replacingOccurrences(of: "\"sdkVersion\":1", with: "\"sdkVersion\":\"1\"")
        try PackageValidator.validate(JSONDecoder().decode(DashboardManifest.self, from: Data(stringVersion.utf8)))
        let unsupported = fixture.replacingOccurrences(of: "\"sdkVersion\":1", with: "\"sdkVersion\":2")
        let manifest = try JSONDecoder().decode(DashboardManifest.self, from: Data(unsupported.utf8))
        XCTAssertThrowsError(try PackageValidator.validate(manifest))
    }
}
