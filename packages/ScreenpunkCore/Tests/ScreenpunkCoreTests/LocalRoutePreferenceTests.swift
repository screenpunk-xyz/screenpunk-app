import XCTest
@testable import ScreenpunkCore

final class LocalRoutePreferenceTests: XCTestCase {
    func testLegacyManualChoiceMigrationAndNewAutomatic() throws {
        for route in ["local", "cloud"] {
            let json = Data("{\"id\":\"profile\",\"libraryOwner\":\"account\",\"permissionOwner\":\"account\",\"localDeviceID\":\"device\",\"preferredRoute\":\"\(route)\"}".utf8)
            let profile = try JSONDecoder().decode(LocalProfileDescriptor.self, from: json)
            XCTAssertEqual(profile.routePreference.rawValue, route)
            XCTAssertEqual(try JSONDecoder().decode(LocalProfileDescriptor.self, from: JSONEncoder().encode(profile)), profile)
        }
        let profile = LocalProfileDescriptor(id: "profile", libraryOwner: "local:profile", permissionOwner: "local:profile", localDeviceID: "device")
        XCTAssertEqual(profile.routePreference, .automatic)
        XCTAssertEqual(try JSONDecoder().decode(LocalProfileDescriptor.self, from: JSONEncoder().encode(profile)).routePreference, .automatic)
    }
    func testRepositoryPreferencePersistsAndCloudRequiresBinding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Screenpunk-RoutePreferenceTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LocalProfileRepository(rootDirectory: root), profile = try repo.createLocalProfile()
        XCTAssertEqual(profile.routePreference, .automatic)
        XCTAssertThrowsError(try repo.setRoutePreference(.cloud, profileID: profile.id))
        try repo.setPreferredRoute(.local, profileID: profile.id)
        XCTAssertEqual(try repo.snapshot().activeProfile?.routePreference, .local)
        try repo.setRoutePreference(.automatic, profileID: profile.id)
        XCTAssertEqual(try LocalProfileRepository(rootDirectory: root).snapshot().activeProfile?.routePreference, .automatic)
    }
}
