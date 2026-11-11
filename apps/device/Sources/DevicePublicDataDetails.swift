import SwiftUI
import ScreenpunkCore

struct DevicePublicDataDetails: View {
    @ObservedObject var model: DeviceModel
    let screenID: String
    let owner: String
    var initialUseCurrentLocation = false
    var initialRevision: String? = nil
    @State private var initialActionHandled = false
    @StateObject private var locationService = WeatherLocationService()
    @State private var query = ""
    @State private var status: String?
    @State private var operation: Task<Void, Never>?

    private var saved: ScreenLibrary.Saved? {
        guard !owner.isEmpty, model.permissionOwner == owner, !model.accountOperationInProgress else { return nil }
        return model.installedScreens.first { $0.id == screenID }
    }
    private var manifest: DashboardManifest? {
        guard let saved else { return nil }
        return model.installedManifests.first { $0.revision == saved.revision }
    }
    private var weather: WeatherLocation? { saved.flatMap { StarterWeather.location(in: $0.artifact) } }

    var body: some View {
        Form {
            if let manifest {
                permissionSection(manifest)
                if let weather { weatherSection(weather) }
                sourceSections(manifest)
            } else {
                Text("Public data settings are unavailable. Go back and reopen this screen’s settings.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(weather == nil ? (manifest?.name ?? "Public Data") : "Weather")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !initialActionHandled else { return }
            initialActionHandled = true
            if initialUseCurrentLocation, let initialRevision, saved?.revision == initialRevision, weather != nil, !Task.isCancelled { locationService.useCurrentLocation() }
        }
        .onDisappear(perform: cancel)
        .onChange(of: model.permissionOwner) { _ in cancel() }
        .onChange(of: model.accountOperationInProgress) { changing in if changing { cancel() } }
        .onChange(of: saved?.revision) { _ in cancel() }
    }

    private func permissionSection(_ manifest: DashboardManifest) -> some View {
                Section {
                    Toggle("Allow public data", isOn: Binding(
                        get: { self.manifest == manifest && model.publicDataAllowed(manifest) },
                        set: { allowed in
                            guard self.manifest == manifest else { return }
                            model.setPublicDataAllowed(allowed, for: manifest)
                        }
                    ))
                } footer: {
                    Text("Read-only HTTPS requests to these declared sources. No credentials or cookies are sent. Changes to the declared sources require approval again.")
                }
    }

    private func weatherSection(_ weather: WeatherLocation) -> some View {
                    Section {
                        LabeledContent("Current", value: weather.name)
                        TextField("City and state or ZIP code", text: $query)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit(search)
                        Button("Find location", action: search)
                            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || locationService.busy)
                        Button("Use my location") {
                            guard saved != nil else { return }
                            operation?.cancel(); status = nil
                            locationService.useCurrentLocation()
                        }.disabled(locationService.busy)
                        if locationService.busy { ProgressView("Finding location…") }
                        ForEach(locationService.candidates) { candidate in
                            Button { choose(candidate) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.name)
                                    Text("Use this location").font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(locationService.busy)
                        }
                        if let error = locationService.error { Text(error).foregroundStyle(.secondary) }
                        if let status { Text(status).foregroundStyle(.secondary) }
                    } header: {
                        Text("Location")
                    } footer: {
                        Text("Search uses Apple. Choosing a location sends coordinates to NWS for U.S. forecasts. Use my location asks permission for a single lookup and uses Apple to find its name. Public data approval is separate; no background tracking.")
                    }
    }

    private func sourceSections(_ manifest: DashboardManifest) -> some View {
                ForEach(manifest.connections.filter { $0.publicHTTP != nil }, id: \.alias) { connection in
                    if let declaration = connection.publicHTTP {
                        Section {
                            Text(declaration.origin).font(.headline).textSelection(.enabled)
                            ForEach(declaration.operations, id: \.name) { operation in
                                LabeledContent(operation.name, value: operation.path).font(.caption)
                            }
                        }
                    }
                }
    }

    private func cancel() {
        operation?.cancel(); operation = nil
        locationService.cancel()
    }
    private func search() {
        guard saved != nil, !locationService.busy else { return }
        operation?.cancel(); status = nil
        operation = Task { await locationService.search(query) }
    }
    private func choose(_ candidate: WeatherLocationService.Candidate) {
        guard let saved, !locationService.busy else { return }
        let revision = saved.revision
        operation?.cancel(); status = nil
        operation = Task {
            do {
                let location = try await locationService.resolve(candidate)
                try Task.checkCancellation()
                try model.applyWeatherLocation(location, screenID: screenID, revision: revision, owner: owner)
                locationService.cancel()
                status = "Location saved. Review Allow public data to load its forecast."
            } catch is CancellationError { }
            catch { status = error.localizedDescription }
        }
    }
}
