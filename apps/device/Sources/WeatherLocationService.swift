import Combine
import CoreLocation
import Foundation

@MainActor
final class WeatherLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Candidate: Identifiable {
        let id = UUID()
        let name: String
        let latitude: Double
        let longitude: Double
        let timeZone: String
    }

    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?

    private var generation = UUID()
    private var geocoder: CLGeocoder?
    private var manager: CLLocationManager?
    private var requestedFix = false
    private var reverseLookup: Task<Void, Never>?
    private var resolution: Task<WeatherLocation, Error>?

    func cancel() {
        generation = UUID()
        releaseManager()
        geocoder?.cancelGeocode()
        geocoder = nil
        reverseLookup?.cancel()
        reverseLookup = nil
        resolution?.cancel()
        resolution = nil
        candidates = []
        busy = false
        error = nil
    }

    func search(_ query: String) async {
        guard !Task.isCancelled else { return }
        cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 200 else {
            error = "Enter a city and state or a ZIP code."
            return
        }

        busy = true
        let generation = self.generation
        let geocoder = CLGeocoder()
        self.geocoder = geocoder
        do {
            let places = try await geocoder.geocodeAddressString(query)
            guard self.generation == generation else { return }
            if !Task.isCancelled {
                publishCandidates(places)
            }
        } catch {
            guard self.generation == generation else { return }
            if !Task.isCancelled {
                self.error = (error as? CLError)?.code == .geocodeFoundNoResult
                    ? "No matches found. Try a city and state or a ZIP code."
                    : "City lookup failed. Try again."
            }
        }
        geocoder.cancelGeocode()
        self.geocoder = nil
        busy = false
    }

    func useCurrentLocation() {
        cancel()
        busy = true
        let manager = CLLocationManager()
        self.manager = manager
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.delegate = self
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            handleAuthorization(manager)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.handleAuthorization(manager)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard self.manager === manager, self.requestedFix else { return }
            self.releaseManager()
            guard let location = locations.last, location.horizontalAccuracy >= 0,
                  CLLocationCoordinate2DIsValid(location.coordinate) else {
                self.finishLocationFailure("Current location is unavailable. Search by city or ZIP code.")
                return
            }
            self.lookupCurrentPlace(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.manager === manager else { return }
            if (error as? CLError)?.code == .denied {
                self.handleAuthorization(manager)
                if self.manager !== manager { return }
            }
            self.finishLocationFailure("Current location is unavailable. Search by city or ZIP code.")
        }
    }

    func resolve(_ candidate: Candidate) async throws -> WeatherLocation {
        try Task.checkCancellation()
        guard !busy, candidates.contains(where: { $0.id == candidate.id }) else {
            throw CancellationError()
        }
        busy = true
        error = nil
        let generation = self.generation
        let resolution = Task { try await Self.resolveNWS(candidate) }
        self.resolution = resolution
        defer {
            if self.generation == generation {
                self.resolution = nil
                busy = false
            }
        }
        do {
            let location = try await withTaskCancellationHandler {
                try await resolution.value
            } onCancel: {
                resolution.cancel()
            }
            guard self.generation == generation else { throw CancellationError() }
            try Task.checkCancellation()
            return location
        } catch {
            guard self.generation == generation, !Task.isCancelled, !resolution.isCancelled else {
                throw CancellationError()
            }
            self.error = (error as? LookupError)?.errorDescription
                ?? "Weather lookup failed. Try again."
            throw error
        }
    }

    private func handleAuthorization(_ manager: CLLocationManager) {
        guard self.manager === manager else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            break
        case .authorizedAlways, .authorizedWhenInUse:
            guard !requestedFix else { return }
            requestedFix = true
            manager.requestLocation()
        case .denied, .restricted:
            finishLocationFailure("Location access is unavailable. Search by city or ZIP code.")
        @unknown default:
            finishLocationFailure("Current location is unavailable. Search by city or ZIP code.")
        }
    }

    private func releaseManager() {
        manager?.delegate = nil
        manager?.stopUpdatingLocation()
        manager = nil
        requestedFix = false
    }

    private func finishLocationFailure(_ message: String) {
        releaseManager()
        error = message
        busy = false
    }

    private func lookupCurrentPlace(_ location: CLLocation) {
        let generation = self.generation
        let geocoder = CLGeocoder()
        self.geocoder = geocoder
        reverseLookup = Task {
            defer {
                if self.generation == generation {
                    self.geocoder = nil
                    reverseLookup = nil
                    busy = false
                }
            }
            do {
                let places = try await geocoder.reverseGeocodeLocation(location)
                guard self.generation == generation, !Task.isCancelled else { return }
                publishCandidates(places, coordinate: location.coordinate)
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                self.error = "Couldn't identify your current city. Search by city or ZIP code."
            }
        }
    }

    private func publishCandidates(_ places: [CLPlacemark], coordinate: CLLocationCoordinate2D? = nil) {
        var seen: Set<String> = []
        candidates = places.compactMap { place in
            guard place.isoCountryCode == "US",
                  let coordinate = coordinate ?? place.location?.coordinate,
                  CLLocationCoordinate2DIsValid(coordinate),
                  let timeZone = place.timeZone?.identifier,
                  let state = place.administrativeArea,
                  let city = place.locality ?? place.subAdministrativeArea ?? place.name else {
                return nil
            }
            let name = "\(city), \(state)" + (place.postalCode.map { " \($0)" } ?? "")
            let coordinates = Self.point(coordinate.latitude, coordinate.longitude)
            guard seen.insert("\(name)|\(coordinates)").inserted else { return nil }
            return Candidate(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude, timeZone: timeZone)
        }
        if candidates.isEmpty {
            error = "No supported U.S. location found. Try a city and state or a ZIP code."
        }
    }

    private enum LookupError: LocalizedError {
        case unsupported
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unsupported: "The National Weather Service has no coverage for this location."
            case .unavailable: "The National Weather Service lookup failed. Try again."
            }
        }
    }

    private struct PointResponse: Decodable {
        struct Properties: Decodable {
            let gridId: String
            let gridX: Int
            let gridY: Int
            let forecast: URL?
            let forecastHourly: URL?
            let observationStations: URL
        }

        let properties: Properties
    }

    private struct StationResponse: Decodable {
        struct Station: Decodable {
            struct Properties: Decodable {
                let stationIdentifier: String
            }

            struct Geometry: Decodable {
                let type: String
                let coordinates: [Double]
            }

            let id: URL
            let properties: Properties
            let geometry: Geometry?
        }

        let features: [Station]
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static func point(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.4f,%.4f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }

    private static func resolveNWS(_ candidate: Candidate) async throws -> WeatherLocation {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let coordinates = point(candidate.latitude, candidate.longitude)
        let pointURL = URL(string: "https://api.weather.gov/points/\(coordinates)")!
        let grid = try await fetch(PointResponse.self, from: pointURL, using: session).properties
        guard grid.gridId.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil,
              (0...999).contains(grid.gridX), (0...999).contains(grid.gridY) else {
            throw LookupError.unavailable
        }
        let gridPath = "/gridpoints/\(grid.gridId)/\(grid.gridX),\(grid.gridY)"
        guard let forecast = grid.forecast, let hourly = grid.forecastHourly else {
            throw LookupError.unsupported
        }
        guard matches(forecast, path: "\(gridPath)/forecast"),
              matches(hourly, path: "\(gridPath)/forecast/hourly"),
              matches(grid.observationStations, path: "\(gridPath)/stations") else {
            throw LookupError.unavailable
        }

        let stationsURL = URL(string: "https://api.weather.gov\(gridPath)/stations")!
        let stations = try await fetch(StationResponse.self, from: stationsURL, using: session).features
        let origin = CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)
        let nearest = stations.compactMap { station -> (id: String, distance: CLLocationDistance)? in
            let id = station.properties.stationIdentifier
            guard id.range(of: "^[A-Z0-9]{3,8}$", options: .regularExpression) != nil,
                  matches(station.id, path: "/stations/\(id)"),
                  let geometry = station.geometry, geometry.type == "Point",
                  geometry.coordinates.count >= 2 else {
                return nil
            }
            let longitude = geometry.coordinates[0]
            let latitude = geometry.coordinates[1]
            guard CLLocationCoordinate2DIsValid(.init(latitude: latitude, longitude: longitude)) else {
                return nil
            }
            return (id, origin.distance(from: CLLocation(latitude: latitude, longitude: longitude)))
        }.min { $0.distance < $1.distance }
        guard let nearest else { throw LookupError.unsupported }

        return WeatherLocation(
            name: candidate.name,
            latitude: candidate.latitude,
            longitude: candidate.longitude,
            timeZone: candidate.timeZone,
            office: grid.gridId,
            gridX: grid.gridX,
            gridY: grid.gridY,
            stationID: nearest.id
        )
    }

    private static func matches(_ url: URL, path: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "https" && components.host == "api.weather.gov"
            && components.port == nil && components.user == nil && components.password == nil
            && components.query == nil && components.fragment == nil && components.percentEncodedPath == path
    }

    private static func fetch<T: Decodable>(_ type: T.Type, from url: URL, using session: URLSession) async throws -> T {
        let limit = 1_048_576
        var request = URLRequest(url: url)
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        request.setValue("ScreenpunkWeather/1.0 (https://screenpunk.xyz)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LookupError.unavailable }
        if http.statusCode == 404 { throw LookupError.unsupported }
        guard http.statusCode == 200, response.expectedContentLength <= limit else {
            throw LookupError.unavailable
        }

        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw LookupError.unavailable }
            data.append(byte)
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
