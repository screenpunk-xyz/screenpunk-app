import SwiftUI
import UniformTypeIdentifiers
import ScreenpunkApple
import ScreenpunkCore

struct DeviceAccountSettings: View {
    @ObservedObject var device: DeviceModel
    @ObservedObject var model: LocalAgentSettingsModel
    let addCloudAgent: () -> Void
    let showCloudSetup: () -> Void
    let openPlan: () -> Void
    @State private var setup: SetupSheet?
    @State private var forgetting = false
    private enum SetupSheet: String, Identifiable { case pairing, address; var id: String { rawValue } }
    var body: some View {
        Form {
            DeviceCloudAccountSection(device: device, addCloudAgent: addCloudAgent, showListenerSetup: showCloudSetup, openPlan: openPlan)
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
                    Button("Add agent") { model.beginSetup(); setup = .pairing }.disabled(device.routeChangeBlocked)
                }
                if let error = model.presentedError { DismissibleMessage(error.text, color: .red, onDismiss: { model.dismissError(id: error.id) }).id(error.id) }
                Text("Advanced users can connect a local agent without a Screenpunk account using experimental support for Codex App Server on Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.configuration != nil {
                Section("Use for new requests") {
                    Picker("Agent", selection: Binding(get: { device.routePreference }, set: device.selectRoutePreference)) {
                        Text("Automatic").tag(AuthoringRoutePreference.automatic)
                        Text("Local").tag(AuthoringRoutePreference.local)
                        Text("Cloud").tag(AuthoringRoutePreference.cloud).disabled(!device.canSelectCloudRoute)
                    }.disabled(device.routeChangeBlocked || model.testing)
                    Text(device.routeChangeBlocked ? "Finish or cancel the current request before changing agents." : "Automatic checks the paired computer first. If it is unavailable, a new request may go to your configured Cloud agent. A request keeps its chosen agent after delivery is prepared.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $setup) { sheet in
            switch sheet {
            case .pairing: LocalAgentSetupView(model: model, device: device)
            case .address: LocalAgentAddressRecoveryView(model: model)
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

private enum DeletionConfirmation {
    case account(String)
    case externalCredentials(String)

    var title: String {
        switch self {
        case .account: return "Delete this Screenpunk account?"
        case .externalCredentials: return "Delete account while credential removal is unconfirmed?"
        }
    }
}

struct AccountFieldRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            AccountFieldValue(value: value)
        }
        .contentShape(Rectangle())
    }
}

private struct AccountFieldValue: View {
    let value: String

    var body: some View {
        HStack {
            Text(value).foregroundStyle(.primary).multilineTextAlignment(.trailing)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

/// Cloud identity and listener state are independent of the preferred request route.
struct DeviceCloudAccountSection: View {
    @ObservedObject var device: DeviceModel
    @State private var confirmation: DeletionConfirmation?
    @State private var confirmSignOut = false
    @State private var signOutAccountID: String?
    let addCloudAgent: () -> Void
    let showListenerSetup: () -> Void
    let openPlan: () -> Void
    private var accountActionsDisabled: Bool { device.routeChangeBlocked || device.accountOperationInProgress }
    var body: some View {
        Section("Screenpunk") {
            if let email = device.email {
                HStack {
                    Text("Account").foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    accountMenu(email: email)
                }
                if device.cloud.session != nil {
                    DeviceBillingRow(device: device, billing: device.billing, openPlan: openPlan)
                }
            } else {
                Button(screenpunkSignInTitle) { Task { await device.signIn() } }
                    .disabled(accountActionsDisabled)
                Text("You must be signed in to use Cloud agents with Screenpunk.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DeviceAccountDeletionRows(device: device, confirmation: $confirmation)
        }
        .alert("Sign out of Screenpunk Cloud?", isPresented: $confirmSignOut, presenting: signOutAccountID) { accountID in
            Button("Keep on This iPad") { Task { await device.signOut(accountID: accountID, deleteScreens: false) } }
            Button("Delete from This iPad", role: .destructive) { Task { await device.signOut(accountID: accountID, deleteScreens: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Keep your screens here to see them when you sign in to this account again. Deleting them here leaves your Cloud backups available.")
        }
        .alert(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { requested in
            switch requested {
            case .account(let capturedAccountID):
                Button("Delete", role: .destructive) {
                    confirmation = nil
                    Task { await device.deleteAccount(accountID: capturedAccountID, approvedAppleRevocation: true) }
                }
            case .externalCredentials(let capturedAccountID):
                Button("Continue Deleting Account", role: .destructive) {
                    confirmation = nil
                    Task {
                        guard device.accountDeletionTargetID == capturedAccountID,
                              device.accountDeletionRequiresExternalCredentialConfirmation else { return }
                        await device.deleteAccount(accountID: capturedAccountID, approvedExternalCredentialCleanup: true)
                    }
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { requested in
            switch requested {
            case .account:
                Text("Your account, screens and settings will be permanently deleted. This cannot be undone.\n\n\(DeviceAccountDeletionTransaction.appleAuthorizationWarning)\n\nSome security and purchase records remain to prevent old requests or purchases restoring the account. Deleting your account does not cancel an Apple subscription.")
            case .externalCredentials:
                Text("\(DeviceAccountDeletionTransaction.externalCredentialCleanupWarning)\n\nEven if a provider is offline, Screenpunk removes saved credentials and access from this iPad.")
            }
        }
        .onChange(of: device.accountDeletionTargetID) { _ in confirmation = nil }
        if device.email != nil && device.cloud.session != nil {
            Section("Cloud agent") {
                Button("Add agent", action: addCloudAgent)
                if device.cloudPluginConnected == true {
                    Button(action: showListenerSetup) {
                        HStack {
                            Text("ChatGPT plugin").foregroundStyle(.secondary)
                            Spacer(minLength: 16)
                            if device.cloudListenerStatus == .waiting {
                                ProgressView().controlSize(.small).accessibilityHidden(true)
                            }
                            Text(device.cloudListenerStatus == .connected ? "Connected" : device.cloudListenerStatus.label)
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    private func accountMenu(email: String) -> some View {
        Menu {
            signOut
            Button("Sign in again") { Task { await device.signIn() } }
                .disabled(accountActionsDisabled)
            if let accountID = device.accountDeletionTargetID,
               !device.accountDeletionNeedsRetry && !device.accountDeletionInProgress {
                Section {
                    Button(role: .destructive) { confirmation = .account(accountID) } label: {
                        Label("Delete This Account", systemImage: "trash")
                    }
                    .disabled(accountActionsDisabled)
                }
                Section {
                    Text("Deleting your Screenpunk account does not cancel an App Store subscription.")
                }
            }
        } label: {
            AccountFieldValue(value: email)
                .contentShape(Rectangle())
                .tint(.primary)
        }
        .accessibilityLabel("Account actions, " + email)
        .menuOrder(.fixed)
    }
    private var signOut: some View {
        Button {
            signOutAccountID = device.cloud.localAccountID
            confirmSignOut = signOutAccountID != nil
        } label: {
            Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
        }
        .buttonStyle(.borderless).disabled(accountActionsDisabled)
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
    private var macGuide: URL {
        let origin = CloudClient.origin
        if origin.host == "api.screenpunk.xyz" {
            return LocalAgentMacSetup.setupURL(baseURL: URL(string: "https://screenpunk.xyz")!)
        }
        return LocalAgentMacSetup.setupURL(baseURL: origin)
    }
    @State private var copiedGuide = false
    @State private var cameraError: String?
    @State private var advanced = false
    private enum SetupModal: Identifiable {
        case share(URL), scan
        var id: String { switch self { case .share: return "share"; case .scan: return "scan" } }
    }
    var body: some View {
        NavigationStack {
            Form {
                if step == 0 { prepare }
                else if step == 1 { scan }
                else { connected }
                if let error = model.presentedError {
                    Section { DismissibleMessage(error.text, color: .red, onDismiss: { model.dismissError(id: error.id) }).id(error.id) }
                }
                if let error = cameraError { Section { DismissibleMessage(error, color: .red, onDismiss: { cameraError = nil }) } }
            }
            .navigationTitle("Set up local agent (\(step + 1) of 3)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        if step == 2 {
                            Text("Done")
                        } else {
                            Image(systemName: "xmark").font(.body.weight(.semibold))
                        }
                    }
                    .accessibilityLabel(step == 2 ? "Done" : "Close")
                    .disabled(model.testing)
                }
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
            Section("On this iPad") {
                Button("Share setup request") {
                    if model.pendingRequest.map({ date($0.expiresAt) <= Date() }) ?? true {
                        model.refreshSetupRequest()
                    }
                    if let url = model.shareURL { sheet = .share(url) }
                }
                Text("AirDrop the request to your Mac, or save and transfer the file.").font(.caption).foregroundStyle(.secondary)
                if let request = model.pendingRequest {
                    LabeledContent("Request valid until", value: date(request.expiresAt).formatted(date: .omitted, time: .shortened))
                }
            }
            Section("On your Mac") {
                HStack {
                    Link(macGuide.absoluteString, destination: macGuide)
                        .buttonStyle(.borderless)
                    Spacer(minLength: 12)
                    Button {
                        UIPasteboard.general.string = macGuide.absoluteString
                        copiedGuide = true
                    } label: {
                        Image(systemName: copiedGuide ? "checkmark" : "doc.on.doc")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(copiedGuide ? "Copied" : "Copy setup address")
                }
                Text("Open this address on your Mac. Follow the instructions and select the request file when prompted. When the connection code appears, tap Next on this iPad.")
            }
        }
    }
    private var scan: some View {
        Group {
            Section("Connection code") {
                Button("Scan connection code") { cameraError = nil; sheet = .scan }.disabled(model.testing)
                Button("Import private connection file") { importingFile = true }.disabled(model.testing)
                Text("Scan the code on your Mac or import the file it saved. Both contain a private credential. Keep them on your devices.").font(.caption).foregroundStyle(.secondary)
            }
            if let candidate = model.candidate {
                Section("Review connection") {
                    Label(candidate.configuration.name, systemImage: "desktopcomputer")
                    LabeledContent("Server startup", value: LocalAgentSettingsModel.startupLabel(for: candidate.configuration))
                    Label("Matches this iPad’s setup request", systemImage: "checkmark.shield")
                    LabeledContent("Code valid until", value: date(candidate.expiresAt).formatted(date: .omitted, time: .shortened))
                    Text("Connect verifies your Mac and runs a small test using your Codex allowance.").font(.caption)
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
                Text("To recover an existing setup, use a Mac that already trusts this iPad’s public key.").font(.caption)
                Text("For background startup, import the Mac’s connection code.").font(.caption).foregroundStyle(.secondary)
                TextField("Computer name", text: $model.name)
                TextField("Mac address", text: $model.host).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(discovery.searching ? "Search again" : "Find nearby computers") { discovery.start() }
                if let message = discovery.message { DismissibleMessage(message).font(.caption) }
                ForEach(discovery.computers) { computer in
                    Button { model.host = computer.host; model.sshPort = String(computer.port); discovery.stop() } label: {
                        VStack(alignment: .leading) { Text(computer.name); Text(computer.host).font(.caption) }
                    }
                }
                TextField("SSH port", text: $model.sshPort).keyboardType(.numberPad)
                TextField("Mac account short name", text: $model.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Absolute Mac workspace", text: $model.workspace).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Enter the SSH host fingerprint shown on your Mac.").font(.caption)
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
            Text(LocalAgentSettingsModel.lifecycleGuidance(for: model.configuration))
            Text("Choose your preferred agent in Account → Use for new requests.")
            if model.configuration?.serverLifecycle == .foreground {
                Link("Enable background startup on the Mac", destination: LocalAgentMacSetup.setupURL(baseURL: CloudClient.origin))
            }
            DisclosureGroup("Connection details") { Text(model.details ?? "Secure connection and reconnect verified.").font(.caption) }
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
                    if let message = discovery.message { DismissibleMessage(message).font(.caption) }
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
                    if let error = model.presentedError { DismissibleMessage(error.text, color: .red, onDismiss: { model.dismissError(id: error.id) }).id(error.id) }
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

private struct DeviceAccountDeletionRows: View {
    @ObservedObject var device: DeviceModel
    @Binding var confirmation: DeletionConfirmation?

    var body: some View {
        if let accountID = device.accountDeletionTargetID {
            Group {
                if device.accountDeletionInProgress {
                    ProgressView(device.accountDeletionStatus ?? "Deleting account…")
                } else if device.accountDeletionNeedsRetry {
                    if let status = device.presentedInlineMessage(.deletionStatus) {
                        DismissibleMessage(status.text, onDismiss: { device.dismissInlineMessage(.deletionStatus, id: status.id) }).id(status.id)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Button(retryTitle, role: .destructive) {
                        if device.accountDeletionRequiresConfirmation {
                            confirmation = .account(accountID)
                        } else if device.accountDeletionRequiresExternalCredentialConfirmation {
                            confirmation = .externalCredentials(accountID)
                        } else {
                            Task { await device.deleteAccount(accountID: accountID) }
                        }
                    }
                }
                if let failure = device.presentedInlineMessage(.deletionError) {
                    let diagnostic = device.accountDeletionDiagnosticCode.map { "\nLast server report: \($0)" } ?? ""
                    DismissibleMessage(failure.text + diagnostic, color: .red,
                        onDismiss: { device.dismissInlineMessage(.deletionError, id: failure.id) }).id(failure.id).font(.callout)
                }
            }

        }
    }

    private var retryTitle: String {
        if device.accountDeletionRequiresExternalCredentialConfirmation && !device.accountDeletionRequiresConfirmation {
            return "Review Credential Cleanup"
        }
        return device.accountDeletionRetryTitle
    }
}
