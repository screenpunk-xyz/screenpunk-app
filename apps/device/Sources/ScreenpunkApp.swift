import SwiftUI
import ScreenpunkApple
import ScreenpunkCore

@main struct ScreenpunkApp: App {
    var body: some Scene { WindowGroup { DeviceRootView() } }
}
struct DeviceRootView: View {
    @StateObject private var model = DeviceModel()
    @StateObject private var speech = SpeechCapture()
    @StateObject private var display = DeviceDisplayPreferences()
    @State private var setupRequestCopied = false
    private let setupRequest = "Please use the Screenpunk Staging plugin to listen for requests from my Screenpunk devices. Subscribe to screenpunk.request.created, keep the subscription active, and handle incoming device requests. Confirm which Screenpunk account you are connected to."
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content.blur(radius: speech.recording ? 18 : 0)
            if !model.missingConnections.isEmpty && !model.settingsOpen && !speech.recording {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "link.badge.plus").font(.largeTitle)
                    Text("Finish setting up this screen").font(.title2.bold())
                    Text("Configure \(model.missingConnections.map(\.name).joined(separator: ", ")) in Settings to use this screen.")
                        .multilineTextAlignment(.center)
                    Button("Open Settings", action: model.openConnectionSettings).buttonStyle(.borderedProminent)
                    Text("Swipe with two fingers to switch screens.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(28).frame(maxWidth: 440)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                .padding(24)
                .accessibilityAddTraits(.isModal)
            }
            if speech.recording {
                VStack(spacing: 20) {
                    Image(systemName: "mic.fill").font(.system(size: 52)).foregroundStyle(.orange)
                    Text("Listening…").font(.largeTitle.bold())
                    Text("Keep holding while you talk. Lift your fingers to send.")
                    Text(speech.transcript).font(.title3).multilineTextAlignment(.center)
                }.padding(40).frame(maxWidth: 650).allowsHitTesting(false)
            } else if !model.settingsOpen && (model.busy || model.requestPending || model.routeChangeBlocked || model.canRetry || model.canCancelRequest || speech.error != nil || model.presentedStatusMessage != nil) {
                GeometryReader { geometry in
                    VStack {
                        Spacer()
                        RequestStatusPill(model: model, speechError: speech.error, maximumTextHeight: max(80, geometry.size.height * 0.45))
                            .padding(24)
                    }.frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundStyle(.white)
        .background(DeviceGestures(began: beginSpeech, ended: speech.end, cancelled: speech.cancel, swipe: { if !model.settingsOpen && !model.busy { model.swipe($0) } }, settings: { model.settingsOpen = true }))
        .statusBarHidden()
        .onDisappear { if !model.settingsOpen { model.setForeground(false) }; speech.cancel() }
        .fullScreenCover(isPresented: $model.settingsOpen) { DeviceSettingsView(model: model, display: display) }
        .onChange(of: model.settingsOpen) { presented in
            if !presented { model.refreshConnections() }
            display.setActive(scenePhase == .active, settingsPresented: presented)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                model.reconcileTemporary()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
        .task(id: scenePhase) {
            UIApplication.shared.isIdleTimerDisabled = scenePhase == .active
            display.setActive(scenePhase == .active, settingsPresented: model.settingsOpen)
            model.setForeground(scenePhase == .active)
            if scenePhase != .active { speech.cancel() }
        }
    }
    @ViewBuilder private var content: some View {
        if let screen = model.screen, let assets = model.assets {
            // The isolated WebView coordinator owns an immutable package and bridge scope.
            // A new local revision must create a new renderer, including on rollback/swipe.
            DashboardRuntimeView(store: assets, homeAssistant: model.homeAssistant, publicReads: model.publicReads, revision: screen.revision, connectionCount: 1, screenName: screen.artifact.title, onMenu: { model.settingsOpen = true })
                .id(screen.revision + model.publicReadSessionKey)
                .ignoresSafeArea()
        } else if (model.routePreference == .local || (model.routePreference == .automatic && model.email == nil)) && !model.agentReady {
            introduction(title: "Connect your local agent", detail: "Add Codex on your Mac in Settings → Agents, then test the connection.") {
                Button("Set up local agent") { model.settingsPage = .agents; model.settingsOpen = true }.buttonStyle(.borderedProminent)
                Button("Sign in to Screenpunk Cloud") { Task { await model.signIn() } }.disabled(model.accountOperationInProgress || model.routeChangeBlocked)
            }
        } else if model.email == nil && model.routePreference == .cloud {
            introduction(title: "Connect Screenpunk Cloud", detail: "Sign in to use your Cloud agent. Your saved screens stay available on this device.") {
                Button("Sign in with Google") { Task { await model.signIn() } }.buttonStyle(.borderedProminent).disabled(model.accountOperationInProgress || model.routeChangeBlocked)
                Button("Settings") { model.settingsOpen = true }
            }
        } else if !model.agentReady {
            introduction(title: "Ask your agent to listen", detail: "You’re signed in to Screenpunk. In ChatGPT, open your dot and ask it to listen for Screenpunk device requests.") {
                Text(setupRequest)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(.orange).frame(width: 3).padding(.vertical, 12) }
                Button(setupRequestCopied ? "Request copied" : "Copy setup request") {
                    UIPasteboard.general.string = setupRequest
                    setupRequestCopied = true
                }.buttonStyle(.borderedProminent)
                Link("Open ChatGPT", destination: URL(string: "https://chatgpt.com/")!)
                Text("Paste and send the request in your dot’s chat, then return here. This screen updates automatically when your agent starts listening.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            introduction(title: "What would you like on this screen?", detail: "Hold three fingers on the screen and tell your agent what you’d like to see. Lift your fingers to send.") {
                Image(systemName: "hand.raised.fingers.spread.fill").font(.system(size: 54))
                Button("Settings") { model.settingsOpen = true }
            }
        }
    }
    private func introduction<Content: View>(title: String, detail: String, @ViewBuilder actions: () -> Content) -> some View {
        VStack(spacing: 24) { Text("SCREENPUNK").font(.caption.weight(.bold)).tracking(4).foregroundStyle(.orange); Text(title).font(.largeTitle.bold()); Text(detail).font(.title3).foregroundStyle(.secondary); actions() }.multilineTextAlignment(.center).padding(32).frame(maxWidth: 660)
    }
    private func beginSpeech() {
        guard !model.settingsOpen else { return }
        guard model.hasProfile, !model.busy else { model.message = model.busy ? "Your agent is still working." : "Connect your agent before speaking."; return }
        speech.begin { text in Task { await model.send(text) } }
    }
}
enum DeviceSettingsPage: String, Hashable {
    case overview = "Overview", guidedAccess = "Guided Access", display = "Display", account = "Account", screens = "Screens"
    case preferences = "Preferences", agents = "Agents"
    case home = "Home Assistant", television = "Google TV", calendar = "Google Calendar", publicData = "Public Data"
    var symbol: String {
        switch self {
        case .overview: return "hand.draw"
        case .guidedAccess: return "lock.rectangle"
        case .display: return "sun.max"
        case .account: return "person.crop.circle"
        case .screens: return "rectangle.stack"
        case .preferences: return "slider.horizontal.3"
        case .agents: return "sparkles"
        case .home: return "house"
        case .television: return "tv"
        case .calendar: return "calendar"
        case .publicData: return "network"
        }
    }
}
struct DeviceSettingsView: View {
    @ObservedObject var model: DeviceModel
    @ObservedObject var display: DeviceDisplayPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var selection: DeviceSettingsPage? = .overview
    @State private var screenToRemove: ScreenLibrary.Saved?
    @State private var preferenceToEdit: PreferenceRecordV1?
    @State private var preferenceToDelete: PreferenceRecordV1?
    @State private var columns: NavigationSplitViewVisibility = .all
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var providers: [DeviceSettingsPage] {
        var values: [DeviceSettingsPage] = []
        if !model.manifests(requiring: ["home"]).isEmpty { values.append(.home) }
        if !model.manifests(requiring: ["googleTV"]).isEmpty { values.append(.television) }
        if !model.manifests(requiring: ["googleCalendar", "google-calendar"]).isEmpty { values.append(.calendar) }
        if model.installedManifests.contains(where: { $0.connections.contains(where: { $0.publicHTTP != nil }) }) { values.append(.publicData) }
        return values
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selection) {
                Section {
                    row(.overview)
                    row(.guidedAccess)
                }
                Section("Device") { row(.display); row(.account); row(.screens); row(.preferences); row(.agents) }
                if !providers.isEmpty {
                    Section("Connections") { ForEach(providers, id: \.self) { row($0) } }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .toolbar { if sizeClass == .compact { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            NavigationStack {
                detail
                    .navigationTitle((selection ?? .overview).rawValue)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { selection = model.settingsPage }
        .onChange(of: selection) { if let page = $0 { model.settingsPage = page } }
        .sheet(isPresented: Binding(get: { preferenceToEdit != nil }, set: { if !$0 { preferenceToEdit = nil } })) {
            if let preference = preferenceToEdit { DevicePreferenceEditor(model: model, preference: preference) }
        }
        .alert("Delete preference?", isPresented: Binding(get: { preferenceToDelete != nil }, set: { if !$0 { preferenceToDelete = nil } })) {
            Button("Cancel", role: .cancel) { preferenceToDelete = nil }
            Button("Delete", role: .destructive) {
                if let preference = preferenceToDelete { model.deletePreference(preference) }
                preferenceToDelete = nil
            }
        } message: {
            Text("Delete this \(preferenceToDelete?.scope ?? "") preference for \(preferenceToDelete?.targetID ?? "")? The deletion is saved on this device and syncs with Cloud when connected.")
        }
        .alert("Remove screen?", isPresented: Binding(get: { screenToRemove != nil }, set: { if !$0 { screenToRemove = nil } })) {
            Button("Cancel", role: .cancel) { screenToRemove = nil }
            Button("Remove", role: .destructive) {
                if let screen = screenToRemove { model.removeScreen(screen.id) }
                screenToRemove = nil
            }
        } message: {
            Text("Remove \(screenToRemove?.artifact.title ?? "this screen") from this iPad? This also removes its saved previous version.")
        }
        .onChange(of: providers) { available in
            if let selection, [.home, .television, .calendar, .publicData].contains(selection), !available.contains(selection) { self.selection = .overview }
        }
    }
    private func row(_ page: DeviceSettingsPage) -> some View {
        NavigationLink(value: page) { Label(page.rawValue, systemImage: page.symbol) }
    }
    @ViewBuilder private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            Form {
                Section("Talk to your agent") {
                    Label("Hold three fingers while speaking", systemImage: "mic")
                    Text("Keep all three fingers on the screen as you describe what you want to create or change. Lift them to send your instructions.")
                }
                Section("Change screens") {
                    Label("Swipe left or right with two fingers", systemImage: "hand.draw")
                    Text("Move between the screens saved on this device.")
                }
                Section("Open Settings") {
                    Label("Hold two fingers for five seconds", systemImage: "gearshape")
                    Text("Settings opens directly. Your current screen stays saved while you adjust this device.")
                }
            }
        case .guidedAccess:
            Form {
                Section("Keep Screenpunk on screen") {
                    Text("Guided Access can restrict this device to Screenpunk. You configure and end it using Apple’s system controls.")
                }
                Section("Set up") {
                    Text("1. Open the device’s Settings → Accessibility → Guided Access. Turn it on and choose a Guided Access passcode.")
                    Text("2. Return to Screenpunk. Triple-click the Home button if your device has one. Otherwise, triple-click the top button on iPad or the side button on iPhone.")
                    Text("3. Choose Guided Access if a shortcut menu appears. Keep Touch enabled so Screenpunk’s gestures work, then tap Start.")
                }
                Section("End a session") {
                    Text("Triple-click the same button, enter your Guided Access passcode, and tap End. Available biometric shortcuts depend on the device and your Guided Access settings.")
                    Link("Apple’s Guided Access instructions", destination: URL(string: "https://support.apple.com/111795")!)
                }
            }
        case .display:
            DeviceDisplaySettings(preferences: display)
        case .preferences:
            Form {
                Section {
                    Text("Preferences are saved only when you explicitly ask your agent to remember something or edit a saved preference here. Profile preferences apply to your profile; device and screen preferences apply to their named target.")
                    if let status = model.preferenceSyncStatus { Label(status, systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary) }
                }
                if !model.preferenceConflicts.isEmpty {
                    Section("Resolve changes") {
                        ForEach(model.preferenceConflicts, id: \.id) { conflict in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(conflict.local.category).font(.headline)
                                Text("\(conflict.local.scope) · \(conflict.local.targetID)").font(.caption).textSelection(.enabled)
                                Text("On this device: \(conflict.local.deleted ? "Deleted" : model.preferenceValueText(conflict.local))")
                                Text("Cloud: \(conflict.remote.map { $0.deleted ? "Deleted" : model.preferenceValueText($0) } ?? "Deleted")")
                                HStack {
                                    Button("Keep this device’s change") { model.resolvePreference(conflict.id, keepLocal: true) }
                                    Button("Use Cloud change") { model.resolvePreference(conflict.id, keepLocal: false) }
                                }.buttonStyle(.bordered)
                            }.padding(.vertical, 4)
                        }
                    }
                }
                ForEach(["profile", "device", "screen"], id: \.self) { scope in
                    Section(scope.capitalized) {
                        let records = model.preferenceRecords.filter { $0.scope == scope }
                        if records.isEmpty { Text("No saved preferences").foregroundStyle(.secondary) }
                        ForEach(records, id: \.id) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(record.category).font(.headline)
                                Text(model.preferenceValueText(record)).textSelection(.enabled)
                                Text("Target: \(record.targetID) · Revision \(record.revision)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                HStack {
                                    Button("Edit") { preferenceToEdit = record }
                                    Button("Delete", role: .destructive) { preferenceToDelete = record }
                                }.buttonStyle(.borderless)
                            }.padding(.vertical, 4)
                        }
                    }
                }
                if !model.inactiveDevicePreferences.isEmpty {
                    Section("Previous device connections") {
                        Text("These preferences are retained on this device and do not apply to your current connection.").foregroundStyle(.secondary)
                        ForEach(model.inactiveDevicePreferences, id: \.id) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.category).font(.headline)
                                Text(model.preferenceValueText(record))
                                Text("Device: \(record.targetID)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                if let message = model.message { Section { Text(message).foregroundStyle(.secondary) } }
            }
        case .agents:
            if let localSettings = model.localSettings { DeviceAgentsSettings(device: model, model: localSettings) }
            else { Text("Local agent storage could not be opened.") }
        case .account:
            Form {
                Section("Screenpunk") {
                    Text(model.email ?? "Not signed in")
                    Label(model.agentReady ? "Agent ready" : "Waiting for agent", systemImage: model.agentReady ? "checkmark.circle" : "clock")
                    Button("Sign in again") { Task { await model.signIn() } }.disabled(model.accountOperationInProgress || model.routeChangeBlocked)
                    Button("Sign out", role: .destructive) { Task { await model.signOut() } }.disabled(model.accountOperationInProgress || model.routeChangeBlocked)
                }
            }
        case .screens:
            Form {
                Section("On this device") {
                    if model.installedScreens.isEmpty { Text("No screens yet").foregroundStyle(.secondary) }
                    ForEach(model.installedScreens) { saved in
                        HStack {
                            Button { model.selectScreen(saved.id) } label: {
                                HStack { Text(saved.artifact.title); if saved.id == model.screen?.id { Image(systemName: "checkmark") } }
                            }.buttonStyle(.borderless)
                            Spacer()
                            Button(role: .destructive) { screenToRemove = saved } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(saved.artifact.title)")
                            .disabled(model.busy)
                        }
                        if let issue = model.manifestIssues[saved.id] {
                            Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    Button("Create another screen", action: model.newScreen)
                    Button("Restore previous version", action: model.rollback).disabled(!model.canRollback)
                }
            }
        case .publicData:
            Form {
                ForEach(model.installedManifests.filter { $0.connections.contains { $0.publicHTTP != nil } }, id: \.revision) { manifest in
                    Section(manifest.name) {
                        Toggle("Allow public data", isOn: Binding(get: { model.publicDataAllowed(manifest) }, set: { model.setPublicDataAllowed($0, for: manifest) }))
                        ForEach(manifest.connections.filter { $0.publicHTTP != nil }, id: \.alias) { connection in
                            if let declaration = connection.publicHTTP {
                                Text(declaration.origin).font(.headline).textSelection(.enabled)
                                ForEach(declaration.operations, id: \.name) { operation in
                                    LabeledContent(operation.name, value: operation.path).font(.caption)
                                }
                            }
                        }
                        Text("Read-only HTTPS requests to these declared sources. No credentials or cookies are sent. Changes to the declared sources require approval again.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .home:
            DeviceHomeAssistantSettings(owner: model.permissionOwner, manifests: model.manifests(requiring: ["home"]), onChange: model.refreshConnections)
        case .television:
            DeviceGoogleTVSettings(onChange: model.refreshConnections)
        case .calendar:
            DeviceGoogleCalendarSettings(manifests: model.installedManifests, onChange: model.refreshConnections)
        }
    }
}

private struct DevicePreferenceEditor: View {
    @ObservedObject var model: DeviceModel
    let preference: PreferenceRecordV1
    @Environment(\.dismiss) private var dismiss
    @State private var valueType = "text"
    @State private var text = ""
    @State private var yes = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Applies to") {
                    LabeledContent("Scope", value: preference.scope.capitalized)
                    LabeledContent("Target", value: preference.targetID)
                    LabeledContent("Category", value: preference.category)
                    Text("Saving explicitly changes this saved preference in the scope shown above.").font(.caption)
                }
                Section("Value") {
                    Picker("Value type", selection: $valueType) {
                        Text("Text").tag("text")
                        Text("Number").tag("number")
                        Text("Yes or no").tag("boolean")
                        Text("No value").tag("null")
                    }
                    if valueType == "text" {
                        TextField("Preference", text: $text, axis: .vertical)
                    } else if valueType == "number" {
                        TextField("Number", text: $text).keyboardType(.numbersAndPunctuation)
                    } else if valueType == "boolean" {
                        Toggle("Yes", isOn: $yes)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Edit preference")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save for \(preference.scope)") {
                        do {
                            let value: AuthoringJSONValue
                            switch valueType {
                            case "number":
                                guard let number = Double(text), number.isFinite else { throw DeviceError.message("Enter a valid number.") }
                                value = .number(number)
                            case "boolean": value = .bool(yes)
                            case "null": value = .null
                            default: value = .string(text)
                            }
                            try model.editPreference(preference, value: value); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            .onAppear {
                switch preference.value {
                case .string(let value): valueType = "text"; text = value
                case .number(let value): valueType = "number"; text = String(value)
                case .bool(let value): valueType = "boolean"; yes = value
                default: valueType = "null"
                }
            }
        }
    }
}


private struct RequestStatusPill: View {
    @ObservedObject var model: DeviceModel
    let speechError: String?
    let maximumTextHeight: CGFloat
    var body: some View {
        let message = model.presentedStatusMessage
        let dismissible = speechError == nil && model.canDismissStatusMessage
        VStack(spacing: 12) {
            if model.requestPending || model.busy {
                if let agent = model.resolvedAgentName { Text(agent).font(.caption).foregroundStyle(.secondary) }
                ShimmeringStatusCaption(caption: model.takingLonger ? "Taking longer than expected" : model.progressCaption)
                HStack(spacing: 20) {
                    if model.takingLonger { Button("Keep waiting", action: model.keepWaiting) }
                    if model.canCancelRequest { Button("Cancel", role: .cancel, action: model.cancelRequest) }
                }.buttonStyle(.bordered)
            } else {
                statusText(speechError ?? message?.text ?? "")
                if model.canRetry { Button("Retry", action: model.retryRequest).buttonStyle(.bordered).disabled(model.busy) }
                if model.canCancelRequest { Button("Cancel saved request", role: .cancel, action: model.cancelRequest).buttonStyle(.bordered) }
                if dismissible, let id = message?.id {
                    Button { model.dismissStatusMessage(id: id) } label: {
                        Label("Dismiss", systemImage: "xmark").frame(minWidth: 80, minHeight: 44)
                    }
                        .id(id)
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Dismiss message")
                        .accessibilityHint("Hides this message. Your screen stays unchanged.")
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .frame(maxWidth: 540)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        // Consume card taps without dismissing. Touches never pass through to
        // the screen below; only a deliberate swipe or Dismiss action hides it.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { })
        .background(DeviceStatusInteractionRegion(presentationID: message?.id, dismissalEnabled: dismissible, onDismiss: model.dismissStatusMessage))
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) {
            if dismissible, let id = message?.id { model.dismissStatusMessage(id: id) }
        }
    }
    private func statusText(_ value: String) -> some View {
        ViewThatFits(in: .vertical) {
            Text(value).fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) {
                Text(value).frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout).multilineTextAlignment(.center)
        .frame(maxHeight: maximumTextHeight)
    }
}
private struct ShimmeringStatusCaption: View {
    let caption: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if reduceMotion {
            Text(caption).font(.callout).multilineTextAlignment(.center)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.5) / 2.5
                Text(caption).font(.callout).multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.65))
                    .overlay {
                        GeometryReader { geometry in
                            LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: geometry.size.width * 0.45)
                                .offset(x: geometry.size.width * (phase * 1.9 - 0.45))
                        }
                    }
                    .mask(Text(caption).font(.callout).multilineTextAlignment(.center))
            }.accessibilityLabel(caption)
        }
    }
}
