import SwiftUI
import UniformTypeIdentifiers
import ScreenpunkApple
import ScreenpunkCore

struct DeviceAgentsSettings: View {
    @ObservedObject var device: DeviceModel
    @ObservedObject var model: LocalAgentSettingsModel
    @State private var setup: SetupSheet?
    @State private var forgetting = false
    private enum SetupSheet: String, Identifiable { case pairing, address, cloud; var id: String { rawValue } }
    var body: some View {
        Form {
            Section("Cloud agent") {
                Label(device.email ?? "Sign in to connect", systemImage: "cloud")
                Text(device.cloudAgentReady ? "Ready" : (device.email == nil ? "Not connected" : "Connection saved; checked before sending")).foregroundStyle(.secondary)
                if device.email == nil {
                    Button("Sign in to Screenpunk Cloud") { Task { await device.signIn() } }.disabled(device.routeChangeBlocked || device.accountOperationInProgress)
                }
                Button("Set up Cloud listener") { setup = .cloud }
            }
            Section("Local agent") {
                if let config = model.configuration {
                    Label(config.name, systemImage: "desktopcomputer")
                    Text(model.connectionStatusLabel).foregroundStyle(.secondary)
                    Button(model.testing ? "Checking…" : "Test connection") { Task { await model.testConnection(isSetup: false) } }.disabled(model.testing || device.routeChangeBlocked)
                    Text("The test uses a small amount of your Codex allowance and checks a structured response after reconnecting. No screen is created.").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Connection details") {
                        LabeledContent("Address", value: config.host)
                        LabeledContent("Last successful test", value: model.lastSuccess?.formatted() ?? "Not tested")
                        if let details = model.details { Text(details).font(.caption) }
                        LabeledContent("Server startup", value: LocalAgentSettingsModel.startupLabel(for: config))
                        Text(LocalAgentSettingsModel.lifecycleGuidance(for: config)).font(.caption)
                        if config.serverLifecycle == .foreground {
                            Link("Enable background startup on the Mac", destination: LocalAgentMacSetup.setupURL(baseURL: CloudClient.origin))
                        }
                        DisclosureGroup("Advanced") {
                            Text(config.hostKeySHA256).font(.caption.monospaced()).textSelection(.enabled)
                            LabeledContent("Account", value: config.username)
                            LabeledContent("Workspace", value: config.macWorkspace)
                            LabeledContent("Codex", value: config.pinnedCodexVersion)
                            Button("Find or enter a new address") { setup = .address }.disabled(model.testing || device.routeChangeBlocked)
                            Button("Pair again") { model.beginSetup(); setup = .pairing }.disabled(model.testing || device.routeChangeBlocked)
                            Button("Forget local agent", role: .destructive) { forgetting = true }.disabled(model.testing || device.routeChangeBlocked)
                        }
                    }
                } else {
                    Text("Use Codex on your computer. A Screenpunk Cloud account is optional.")
                    Button("Add agent") { model.beginSetup(); setup = .pairing }.disabled(device.routeChangeBlocked)
                }
                Text("Mac supported in this prototype.").font(.caption).foregroundStyle(.secondary)
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }
            Section("Use for new requests") {
                Picker("Agent", selection: Binding(get: { device.routePreference }, set: device.selectRoutePreference)) {
                    Text("Automatic").tag(AuthoringRoutePreference.automatic)
                    Text("Local").tag(AuthoringRoutePreference.local)
                    Text("Cloud").tag(AuthoringRoutePreference.cloud).disabled(!device.canSelectCloudRoute)
                }.disabled(device.routeChangeBlocked || model.testing)
                Text(device.routeChangeBlocked ? "Finish or cancel the current request before changing agents." : "Automatic checks the paired computer first. If it is unavailable, a new request may go to your configured Cloud agent. A request keeps its chosen agent after delivery is prepared.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $setup) { sheet in
            switch sheet {
            case .pairing: LocalAgentSetupView(model: model, device: device)
            case .address: LocalAgentAddressRecoveryView(model: model)
            case .cloud: CloudListenerSetupSheet(scope: CloudClient.originScope, email: device.email)
            }
        }
        .alert("Forget local agent?", isPresented: $forgetting) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) { model.forget() }
        } message: {
            Text("This removes this iPad’s saved connection and blocks outstanding local deliveries. To revoke access on the Mac, use its setup receipt to remove this iPad’s exact public key. Changing the App Server token can affect other iPads.")
        }
    }
}

struct LocalAgentSetupView: View {
    @ObservedObject var model: LocalAgentSettingsModel
    @ObservedObject var device: DeviceModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = LocalComputerDiscovery()
    @State private var step = 0
    @State private var sheet: SetupModal?
    @State private var importingFile = false
    @State private var cameraError: String?
    @State private var advanced = false
    private enum SetupModal: Identifiable {
        case share(URL), scan
        var id: String { switch self { case .share: return "share"; case .scan: return "scan" } }
    }
    private var titles: [String] { ["Prepare your computer", "Scan connection code", "Connected"] }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("Step \(step + 1) of 3").font(.caption).foregroundStyle(.secondary) }
                if step == 0 { prepare }
                else if step == 1 { scan }
                else { connected }
                if let error = model.error ?? cameraError { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle(titles[step])
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(step == 2 ? "Done" : "Close") { dismiss() }.disabled(model.testing) }
                ToolbarItem(placement: .confirmationAction) {
                    if step == 0 { Button("Next") { step = 1 }.disabled(model.pendingRequest == nil) }
                }
                ToolbarItem(placement: .bottomBar) { if step == 1 { Button("Back") { step = 0 }.disabled(model.testing) } }
            }
            .interactiveDismissDisabled(model.testing)
        }
        .sheet(item: $sheet) { modal in
            switch modal {
            case .share(let url):
                PublicSetupRequestShareSheet(url: url)
            case .scan:
                PairingCodeScanner { text in model.importReply(Data(text.utf8), source: .qr) } onFailure: {
                    cameraError = "Camera access is unavailable. Allow Camera in Settings or import the private connection file."
                }
            }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.importPrivateFile(url) }
            case .failure: cameraError = "The file picker could not open a connection file. Try again."
            }
        }
        .onAppear { step = model.tested ? 2 : (model.candidate == nil ? 0 : 1) }
        .onChange(of: model.tested) { if $0 { step = 2 } }
        .onChange(of: model.fingerprint) { _ in model.verifiedFingerprint = false }
        .onDisappear { discovery.stop(); model.cancelSetup() }
    }
    private var prepare: some View {
        Group {
            Section("Prepare a Mac") {
                Text("Mac supported in this prototype. Your Mac runs Codex; keep it awake and reachable. No separate Screenpunk computer app is installed.")
                Text("Mac setup offers background startup with your approval. When enabled, the agent starts after Mac sign-in and you can close the setup Terminal.").font(.caption).foregroundStyle(.secondary)
                Link("Open Mac setup instructions", destination: LocalAgentMacSetup.setupURL(baseURL: CloudClient.origin))
                Text(LocalAgentMacSetup.setupURL(baseURL: CloudClient.origin).absoluteString).font(.caption).textSelection(.enabled)
                Text("On the Mac, open this address, review the versioned setup script, then follow its short command. Select the public setup request sent from this iPad when asked.")
            }
            Section("Send this iPad’s setup request") {
                Button("Send setup request to computer") { if let url = model.shareURL { sheet = .share(url) } }.disabled(model.shareURL == nil)
                Text("Choose AirDrop for the Mac, or save the file and transfer it locally. It contains a public key, a one-time request and its expiry. The private SSH key stays in this iPad’s Keychain.").font(.caption).foregroundStyle(.secondary)
                if let request = model.pendingRequest {
                    LabeledContent("Request valid until", value: date(request.expiresAt).formatted(date: .omitted, time: .shortened))
                }
                Button("Prepare a new request") { model.refreshSetupRequest() }
            }
        }
    }
    private var scan: some View {
        Group {
            Section("Return from your Mac") {
                Text("After setup, scan the connection code displayed locally on your Mac. The private code contains its connection credential. Keep it on your devices.")
                Button("Scan connection code") { cameraError = nil; sheet = .scan }.disabled(model.testing)
                Button("Import private connection file") { importingFile = true }.disabled(model.testing)
                Text("If the QR is too dense or the camera is unavailable, choose the private reply file saved by Mac setup. Never upload this file to the setup website.").font(.caption).foregroundStyle(.secondary)
            }
            if let candidate = model.candidate {
                Section("Review connection") {
                    Label(candidate.configuration.name, systemImage: "desktopcomputer")
                    LabeledContent("Server startup", value: LocalAgentSettingsModel.startupLabel(for: candidate.configuration))
                    Text(LocalAgentSettingsModel.lifecycleGuidance(for: candidate.configuration)).font(.caption)
                    Label("Matches this iPad’s request and public key", systemImage: "checkmark.shield")
                    LabeledContent("Code valid until", value: date(candidate.expiresAt).formatted(date: .omitted, time: .shortened))
                    Text("Connect verifies the live SSH host against this code, checks Codex sign-in, then uses one small structured-response test and reconnect check from your Codex allowance. No screen is created.").font(.caption)
                    Button(model.testing ? "Connecting…" : "Connect") { Task { await model.testConnection(isSetup: true) } }.disabled(model.testing)
                    if model.testing { ProgressView() }
                    Text(model.connectionStatusLabel).foregroundStyle(.secondary)
                    DisclosureGroup("Advanced") {
                        LabeledContent("Address", value: candidate.configuration.host)
                        Text(candidate.configuration.hostKeySHA256).font(.caption.monospaced()).textSelection(.enabled)
                        LabeledContent("Codex", value: candidate.configuration.pinnedCodexVersion)
                    }
                }
            }
            DisclosureGroup("Advanced recovery", isExpanded: $advanced) {
                Text("Use manual details only when recovering an existing Mac setup. The request’s public key must already be authorized there.").font(.caption)
                Text("Manual entry keeps foreground startup. To confirm background startup, import its connection code from Mac setup.").font(.caption).foregroundStyle(.secondary)
                TextField("Computer name", text: $model.name)
                TextField("Mac address", text: $model.host).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(discovery.searching ? "Search again" : "Find nearby computers") { discovery.start() }
                if let message = discovery.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                ForEach(discovery.computers) { computer in
                    Button { model.host = computer.host; model.sshPort = String(computer.port); discovery.stop() } label: {
                        VStack(alignment: .leading) { Text(computer.name); Text(computer.host).font(.caption) }
                    }
                }
                Text("Discovery suggests addresses only. Screenpunk still verifies the Mac’s pinned SSH identity.").font(.caption)
                TextField("SSH port", text: $model.sshPort).keyboardType(.numberPad)
                TextField("Mac account short name", text: $model.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Absolute Mac workspace", text: $model.workspace).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Paste the SHA256 value from this Mac here; Screenpunk checks it against the live SSH server when connecting.").font(.caption)
                TextField("SHA256:…", text: $model.fingerprint).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("This value came from my Mac", isOn: $model.verifiedFingerprint)
                SecureField("App Server bearer token", text: $model.bearerToken).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Review manual connection") { model.stageManual() }.disabled(model.testing)
                if let request = model.pendingRequest {
                    Text("iPad public key").font(.caption)
                    Text(request.publicKeyOpenSSH).font(.caption.monospaced()).textSelection(.enabled)
                }
            }.disabled(model.testing)
        }
    }
    private var connected: some View {
        Section {
            Label("Connected to \(model.configuration?.name ?? "your computer")", systemImage: "checkmark.circle.fill")
            Text("Ready").foregroundStyle(.secondary)
            Text(LocalAgentSettingsModel.lifecycleGuidance(for: model.configuration))
            Text("Choose when to use it in Agents → Use for new requests.")
            if model.configuration?.serverLifecycle == .foreground {
                Link("Enable background startup on the Mac", destination: LocalAgentMacSetup.setupURL(baseURL: CloudClient.origin))
            }
            DisclosureGroup("Connection details") { Text(model.details ?? "Secure connection and reconnect verified.").font(.caption) }
            Button("Done") { dismiss() }
        }
    }
    private func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
}

private struct PublicSetupRequestShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
private struct PairingCodeScanner: View {
    let onResult: (String) -> Void
    let onFailure: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ConnectionQRScanner { text in onResult(text); dismiss() } onFailure: { onFailure(); dismiss() }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan connection code")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct LocalAgentAddressRecoveryView: View {
    @ObservedObject var model: LocalAgentSettingsModel
    @StateObject private var discovery = LocalComputerDiscovery()
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "22"
    @State private var completed = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Computer address") {
                    Text("Use this if the paired Mac moved to another address. The saved SSH identity and connection credential stay the same.")
                    Button(discovery.searching ? "Search again" : "Find nearby computers") { discovery.start() }.disabled(model.testing)
                    if let message = discovery.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    ForEach(discovery.computers) { computer in
                        Button { host = computer.host; port = String(computer.port); discovery.stop() } label: {
                            VStack(alignment: .leading) { Text(computer.name); Text(computer.host).font(.caption) }
                        }.disabled(model.testing)
                    }
                    TextField("Mac address", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.testing)
                    TextField("SSH port", text: $port).keyboardType(.numberPad).disabled(model.testing)
                    Text("A nearby name is only an address suggestion. Screenpunk verifies the live SSH host against your saved pin.").font(.caption)
                }
                Section {
                    Text("Verify uses a small structured-response test and reconnect check from your Codex allowance. No screen is created. The current endpoint stays saved if verification fails.").font(.caption)
                    Button(model.testing ? "Verifying…" : "Verify address and reconnect") {
                        guard let number = Int(port) else { return }
                        Task { await model.repairAddress(host: host, port: number); if model.tested { completed = true } }
                    }.disabled(model.testing || host.isEmpty || Int(port) == nil)
                    if model.testing { ProgressView() }
                    Text(model.connectionStatusLabel).foregroundStyle(.secondary)
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                    if completed { Button("Done") { dismiss() } }
                }
                DisclosureGroup("Advanced") {
                    Text(model.configuration?.hostKeySHA256 ?? "").font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .navigationTitle("Recover computer address")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(model.testing) } }
        }
        .interactiveDismissDisabled(model.testing)
        .onAppear { host = model.configuration?.host ?? ""; port = String(model.configuration?.sshPort ?? 22) }
        .onDisappear { discovery.stop() }
    }
}
