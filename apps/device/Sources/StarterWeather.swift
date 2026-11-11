import Foundation
import ScreenpunkCore

struct WeatherLocation: Codable, Equatable, Sendable {
    let name: String
    let latitude: Double
    let longitude: Double
    let timeZone: String
    let office: String
    let gridX: Int
    let gridY: Int
    let stationID: String

    static let annArbor = Self(name: "Ann Arbor", latitude: 42.2808, longitude: -83.7430,
                               timeZone: "America/Detroit", office: "DTX", gridX: 42, gridY: 30,
                               stationID: "KYIP")

    var isValid: Bool {
        let uppercase: ClosedRange<UInt8> = 65...90
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.utf8.count <= 120
            && name.rangeOfCharacter(from: .controlCharacters) == nil
            && (-85...85).contains(latitude) && (-180...180).contains(longitude)
            && TimeZone.knownTimeZoneIdentifiers.contains(timeZone)
            && office.utf8.count == 3 && office.utf8.allSatisfy(uppercase.contains)
            && (0...999).contains(gridX) && (0...999).contains(gridY)
            && (3...8).contains(stationID.utf8.count)
            && stationID.utf8.allSatisfy { uppercase.contains($0) || (48...57).contains($0) }
    }
}

/// Rebuilds the complete expected package to distinguish native configuration from authored edits.
enum StarterWeather {
    private static let locationPath = "weather-location.json"
    private static let originalBounds = "-9462228.12,5103135.17,-9182228.12,5303135.17"
    private static let originalManifestDigest = "55f749da77a486512a2b52203714d4f0ac7a276a50c698679c5ee5064f7bb8bd"

    private static let original = Result {
        let artifact = try StarterScreens.bundledArtifact(named: "weather")
        guard let manifest = artifact.files.first(where: { $0.path == "manifest.json" }),
              AuthoringContract.contentDigest(Data(manifest.content.utf8)) == originalManifestDigest else {
            throw DeviceError.message("The bundled Weather template is unavailable.")
        }
        return artifact
    }

    static func isSupported(_ artifact: ScreenArtifact) -> Bool {
        location(in: artifact) != nil
    }

    static func location(in artifact: ScreenArtifact) -> WeatherLocation? {
        guard let template = try? original.get() else { return nil }
        if matches(artifact, template) { return .annArbor }
        guard artifact.title == "Weather", artifact.files.count == template.files.count + 1,
              let config = artifact.files.first(where: { $0.path == locationPath }),
              let location = try? JSONDecoder().decode(WeatherLocation.self, from: Data(config.content.utf8)),
              let expected = try? makeArtifact(location: location),
              matches(artifact, expected) else { return nil }
        return location
    }

    static func configuredArtifact(_ artifact: ScreenArtifact, location: WeatherLocation) throws -> ScreenArtifact {
        guard isSupported(artifact) else {
            throw DeviceError.message("This Weather screen has been customized.")
        }
        return try makeArtifact(location: location)
    }

    static func migrateOriginalIfNeeded(_ artifact: ScreenArtifact) throws -> ScreenArtifact? {
        guard matches(artifact, try original.get()) else { return nil }
        return try defaultArtifact()
    }

    static func defaultArtifact() throws -> ScreenArtifact {
        try makeArtifact(location: .annArbor)
    }

    private static func matches(_ artifact: ScreenArtifact, _ expected: ScreenArtifact) -> Bool {
        artifact.title.utf8.elementsEqual(expected.title.utf8)
            && artifact.entry == expected.entry
            && artifact.files.count == expected.files.count
            && zip(artifact.files.sorted { $0.path < $1.path }, expected.files.sorted { $0.path < $1.path })
                .allSatisfy { actual, reference in
                    actual.path == reference.path && actual.content.utf8.elementsEqual(reference.content.utf8)
                }
    }

    private static func makeArtifact(location: WeatherLocation) throws -> ScreenArtifact {
        guard location.isValid else { throw DeviceError.message("The Weather location is invalid.") }
        var artifact = try original.get()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let configuration = try encoder.encode(location)
        let bounds = mapBounds(for: location)
        let name = escapedHTML(location.name)
        artifact.title = "Weather"

        // Replace exact placeholders from the bundled package in a single pass per field.
        for index in artifact.files.indices {
            switch artifact.files[index].path {
            case "index.html":
                artifact.files[index].content = artifact.files[index].content
                    .replacingOccurrences(of: "<title>Ann Arbor · Today</title>", with: "<title>Weather · \(name)</title>")
                    .replacingOccurrences(of: "<h1>Ann Arbor</h1>", with: "<h1>\(name)</h1>")
                    .replacingOccurrences(of: ">ANN ARBOR</p>", with: ">\(escapedHTML(location.name.uppercased()))</p>")
                    .replacingOccurrences(of: "<b>Ann Arbor</b>", with: "<b>\(name)</b>")
                    .replacingOccurrences(of: "USGS map of southeast Michigan", with: "USGS map around \(name)")
            case "config.js":
                artifact.files[index].content = artifact.files[index].content
                    .replacingOccurrences(of: originalBounds, with: bounds)
                    .replacingOccurrences(of: "America/Detroit", with: location.timeZone)
            default: break
            }
        }
        artifact.files.append(.init(path: locationPath, content: String(decoding: configuration, as: UTF8.self)))

        guard let manifestIndex = artifact.files.firstIndex(where: { $0.path == "manifest.json" }) else {
            throw DeviceError.message("The Weather manifest is unavailable.")
        }
        var manifest = try JSONDecoder().decode(DashboardManifest.self, from: Data(artifact.files[manifestIndex].content.utf8))
        manifest.name = artifact.title
        manifest.files = artifact.files.filter { $0.path != "manifest.json" }.sorted { $0.path < $1.path }.map { file in
            let bytes = Data(file.content.utf8)
            return ManifestFile(path: file.path, bytes: bytes.count, sha256: AuthoringContract.contentDigest(bytes))
        }
        let grid = "/gridpoints/\(location.office)/\(location.gridX),\(location.gridY)/forecast"
        for index in manifest.connections.indices {
            guard var http = manifest.connections[index].publicHTTP else { continue }
            for operation in http.operations.indices {
                switch (manifest.connections[index].alias, http.operations[operation].name) {
                case ("weather", "hourly"): http.operations[operation].path = grid + "/hourly"
                case ("weather", "forecast"): http.operations[operation].path = grid
                case ("weather", "observation"):
                    http.operations[operation].path = "/stations/\(location.stationID)/observations/latest"
                case ("radar", "timeline"): http.operations[operation].parameters["geometry"]?.values = [bounds]
                case ("radar", "frame"), ("basemap", "map"):
                    http.operations[operation].parameters["bbox"]?.values = [bounds]
                default: break
                }
            }
            manifest.connections[index].publicHTTP = http
        }
        let digest = AuthoringContract.contentDigest(try encoder.encode(manifest.files))
        manifest.digest = digest
        manifest.revision = "weather-location-v1-\(digest)"
        artifact.files[manifestIndex].content = String(decoding: try encoder.encode(manifest), as: UTF8.self)
        return artifact
    }

    private static func escapedHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func mapBounds(for location: WeatherLocation) -> String {
        if location.latitude == WeatherLocation.annArbor.latitude,
           location.longitude == WeatherLocation.annArbor.longitude { return originalBounds }
        let radius = 6_378_137.0
        let x = radius * location.longitude * .pi / 180
        let y = radius * log(tan(.pi / 4 + location.latitude * .pi / 360))
        return [x - 140_000, y - 100_000, x + 140_000, y + 100_000]
            .map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0) }
            .joined(separator: ",")
    }
}
