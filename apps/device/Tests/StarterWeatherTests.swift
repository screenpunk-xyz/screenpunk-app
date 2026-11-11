import Foundation
import ScreenpunkCore
import XCTest
@testable import DeviceAuthoring

final class StarterWeatherTests: XCTestCase {
    private let boulder = WeatherLocation(name: "Boulder & <Foothills>", latitude: 40.015, longitude: -105.2705,
                                          timeZone: "America/Denver", office: "BOU", gridX: 54, gridY: 76,
                                          stationID: "KBDU")

    func testOriginalPackageCanBeUpgradedWithAnnArborFallback() throws {
        let original = try StarterScreens.bundledArtifact(named: "weather")
        XCTAssertEqual(original.title, "Ann Arbor Weather")
        XCTAssertEqual(StarterWeather.location(in: original), .annArbor)
        let migrated = try XCTUnwrap(StarterWeather.migrateOriginalIfNeeded(original))
        XCTAssertEqual(migrated.title, "Weather")
        XCTAssertEqual(StarterWeather.location(in: migrated), .annArbor)
        XCTAssertNil(try StarterWeather.migrateOriginalIfNeeded(migrated))
        XCTAssertTrue(try content("config.js", in: migrated).contains("-9462228.12,5103135.17,-9182228.12,5303135.17"))
    }

    @MainActor func testConfiguredWeatherUsesConsistentLocationAndBoundedConnections() throws {
        let original = try StarterWeather.defaultArtifact()
        let configured = try StarterWeather.configuredArtifact(original, location: boulder)
        try ScreenLibrary.validate(configured)
        XCTAssertEqual(StarterWeather.location(in: configured), boulder)
        XCTAssertEqual(try StarterWeather.configuredArtifact(configured, location: .annArbor), original)
        let manifest = try JSONDecoder().decode(DashboardManifest.self, from: Data(try content("manifest.json", in: configured).utf8))
        let operations = try XCTUnwrap(manifest.connections.first { $0.alias == "weather" }?.publicHTTP)
        XCTAssertEqual(manifest.name, "Weather")
        XCTAssertEqual(operations.origin, "https://api.weather.gov")
        XCTAssertEqual(operations.operations.map(\.path), [
            "/gridpoints/BOU/54,76/forecast/hourly",
            "/gridpoints/BOU/54,76/forecast",
            "/stations/KBDU/observations/latest"
        ])
        let radar = try XCTUnwrap(manifest.connections.first { $0.alias == "radar" }?.publicHTTP)
        let basemap = try XCTUnwrap(manifest.connections.first { $0.alias == "basemap" }?.publicHTTP)
        let bounds = try XCTUnwrap(radar.operations.first?.parameters["geometry"]?.values?.first)
        XCTAssertEqual(radar.operations.last?.parameters["bbox"]?.values, [bounds])
        XCTAssertEqual(basemap.operations.first?.parameters["bbox"]?.values, [bounds])
        let coordinates = bounds.split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(coordinates.count, 4)
        if coordinates.count == 4 {
            XCTAssertEqual(coordinates[2] - coordinates[0], 280_000, accuracy: 0.02)
            XCTAssertEqual(coordinates[3] - coordinates[1], 200_000, accuracy: 0.02)
            XCTAssertEqual((coordinates[0] + coordinates[2]) / 2, -11_718_658.46, accuracy: 1)
        }
        let config = try content("config.js", in: configured)
        XCTAssertTrue(config.contains(bounds))
        XCTAssertTrue(config.contains("America/Denver"))
        let html = try content("index.html", in: configured)
        XCTAssertTrue(html.contains("<h1>Boulder &amp; &lt;Foothills&gt;</h1>"))
        XCTAssertTrue(html.contains("<b>Boulder &amp; &lt;Foothills&gt;</b>"))
        XCTAssertTrue(html.contains("BOULDER &amp; &lt;FOOTHILLS&gt;"))
        XCTAssertFalse(html.contains("Ann Arbor"))
    }

    func testAuthoredAndMalformedPackagesAreRejected() throws {
        var original = try StarterScreens.bundledArtifact(named: "weather")
        original.title = "Personal weather"
        XCTAssertNil(try StarterWeather.migrateOriginalIfNeeded(original))
        XCTAssertFalse(StarterWeather.isSupported(original))

        let configured = try StarterWeather.defaultArtifact()
        for path in ["index.html", "manifest.json", "weather-location.json"] {
            var edited = configured
            let index = try XCTUnwrap(edited.files.firstIndex { $0.path == path })
            edited.files[index].content += "\n"
            XCTAssertFalse(StarterWeather.isSupported(edited), path)
            XCTAssertThrowsError(try StarterWeather.configuredArtifact(edited, location: boulder), path)
        }

        let malicious = WeatherLocation(name: "Somewhere", latitude: 40, longitude: -105,
                                        timeZone: "America/Denver", office: "../", gridX: 1, gridY: 2,
                                        stationID: "KBDU")
        XCTAssertThrowsError(try StarterWeather.configuredArtifact(configured, location: malicious))
    }

    @MainActor func testPristineMigrationKeepsShowSelectionPreferencesAndApprovals() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try StarterScreens.bundledArtifact(named: "weather")
        let library = try ScreenLibrary(accountID: "weather", rootDirectory: root)
        try library.installStarterScreensIfNeeded([.init(id: "starter-weather", artifact: original)])
        let previousRevision = try XCTUnwrap(library.selected?.revision)
        let nasa = try StarterScreens.bundledArtifact(named: "nasa")
        try library.install(nasa, requestID: "last-request", replacing: "starter-nasa")
        try library.setScreenShown(false, id: "starter-weather")
        let preference = PreferenceRecordV1(id: "theme", scope: "profile", targetID: "profile",
            category: "appearance", value: .string("blue"), revision: 1, originRequestID: "last-request")
        try library.applyPreferenceSync(records: [preference], accepted: [:], sent: [], conflicts: [:],
                                        profileID: "profile", deviceID: "device")

        try library.migratePristineWeatherIfNeeded()
        let upgraded = try XCTUnwrap(library.state.screens.first { $0.id == "starter-weather" })
        XCTAssertNotEqual(upgraded.revision, previousRevision)
        XCTAssertEqual(StarterWeather.location(in: upgraded.artifact), .annArbor)
        XCTAssertEqual(library.selected?.id, "starter-nasa")
        XCTAssertFalse(library.isScreenShown("starter-weather"))
        XCTAssertEqual(library.state.lastRequest, "last-request")
        XCTAssertEqual(library.preferences(profileID: "profile", deviceID: "device", screenID: "starter-weather"),
                       [preference])
        let decoder = JSONDecoder()
        let before = try decoder.decode(DashboardManifest.self, from: Data(try content("manifest.json", in: original).utf8))
        let after = try decoder.decode(DashboardManifest.self, from: Data(try content("manifest.json", in: upgraded.artifact).utf8))
        XCTAssertEqual(after.dashboardId, before.dashboardId)
        XCTAssertEqual(after.connections, before.connections)

        let reopened = try ScreenLibrary(accountID: "weather", rootDirectory: root)
        try reopened.migratePristineWeatherIfNeeded()
        XCTAssertEqual(reopened.state.screens.first { $0.id == "starter-weather" }?.revision, upgraded.revision)
    }

    @MainActor func testMigrationSkipsEditedConfiguredAndDeletedPackages() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try StarterScreens.bundledArtifact(named: "weather")
        let library = try ScreenLibrary(accountID: "weather", rootDirectory: root)
        try library.installStarterScreensIfNeeded([.init(id: "starter-weather", artifact: original)])
        var edited = original
        edited.title = "Personal weather"
        try library.install(edited, requestID: "edited", replacing: "starter-weather")
        let editedRevision = library.selected?.revision
        try library.migratePristineWeatherIfNeeded()
        XCTAssertEqual(library.selected?.revision, editedRevision)

        let configured = try StarterWeather.configuredArtifact(original, location: boulder)
        try library.install(configured, requestID: "configured", replacing: "starter-weather")
        let configuredRevision = library.selected?.revision
        try library.migratePristineWeatherIfNeeded()
        XCTAssertEqual(library.selected?.revision, configuredRevision)
        XCTAssertEqual(library.selected.flatMap { StarterWeather.location(in: $0.artifact) }, boulder)

        try library.remove("starter-weather")
        try library.installStarterScreensIfNeeded(StarterScreens.templates())
        try library.migratePristineWeatherIfNeeded()
        XCTAssertEqual(library.state.screens.map(\.id), ["starter-nasa"])
    }

    @MainActor func testInterruptedMigrationRecoversForEveryJournalCut() throws {
        enum Interrupted: Error { case crash }
        let original = try StarterScreens.bundledArtifact(named: "weather")
        for cut in AuthoringJournal.Cut.allCases {
            let root = directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let library = try ScreenLibrary(accountID: "weather", rootDirectory: root)
            try library.installStarterScreensIfNeeded([.init(id: "starter-weather", artifact: original)])
            let interrupted = try ScreenLibrary(accountID: "weather", rootDirectory: root, journalFault: { point in
                if point == cut { throw Interrupted.crash }
            })
            XCTAssertThrowsError(try interrupted.migratePristineWeatherIfNeeded(), cut.rawValue)
            let recovered = try ScreenLibrary(accountID: "weather", rootDirectory: root)
            try recovered.migratePristineWeatherIfNeeded()
            XCTAssertEqual(recovered.state.screens.map(\.id), ["starter-weather"], cut.rawValue)
            let selected = try XCTUnwrap(recovered.selected, cut.rawValue)
            XCTAssertEqual(selected.artifact.title, "Weather", cut.rawValue)
            XCTAssertNotNil(try recovered.store(for: selected).assets["index.html"], cut.rawValue)
        }
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-weather-\(UUID().uuidString)")
    }

    private func content(_ path: String, in artifact: ScreenArtifact) throws -> String {
        try XCTUnwrap(artifact.files.first { $0.path == path }?.content)
    }
}
