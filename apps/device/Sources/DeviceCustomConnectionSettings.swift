import SwiftUI
import ScreenpunkApple
import ScreenpunkCore

struct DeviceCustomConnectionSettings: View {
    @ObservedObject var model: DeviceModel
    let use: DeviceModel.CustomConnectionUse
    let owner: String
    let focusScreen: String?
    var deletionError: String? = nil
    var deleteConnection: (() -> Void)? = nil
    @FocusState private var editingName: Bool
    @State private var connectionName = ""
    @State private var fields: [String: String] = [:]
    @State private var pinEnabled = false
    @State private var fingerprint = ""
    @State private var reviewingTrust = false
    @State private var removingProvisioning = false
    @State private var provisioning: DeviceModel.ProvisioningStatus?
    @State private var setupReview: ProvisioningReview?
    @State private var provisioningMessage: String?
    @State private var provisioningChecked = false
    @State private var provisioningTask: Task<Void, Never>?
    @State private var provisioningRetry = UUID()

    private struct ProvisioningReview: Identifiable {
        let credential: DeviceModel.ProvisioningStatus
        let fields: [String: String]
        let pin: ReviewedCertificatePin
        let previousFingerprint: String?
        let savedServer: String?
        var id: String { credential.registrationID }
    }
    @State private var secret = ""
    @State private var allowInsecureHTTP = false
    @State private var editing = false
    @State private var error: String?
    @State private var status: CustomHTTPDeviceVault.Status?
    @State private var testInProgress = false
    @State private var testResult: String?

    private var declaration: CustomHTTPDeclaration { use.declaration }
    private var credentialLabel: String? {
        declaration.fields.first(where: { $0.type == "secret" })?.label
    }
    private var server: String { fields[declaration.originField] ?? "" }
    private var formHTTPSOrigin: String? { try? CredentialRegistrationContext.canonicalHTTPSOrigin(server) }
    private var savedDisplayName: String { model.connectionName(serviceID: declaration.id, fallback: declaration.label) }
    private var canProvision: Bool { model.canProvisionConnectionCredential(use, owner: owner, server: server) }
    private var canReuseCredential: Bool {
        status?.canReuseCredential(for: server, allowInsecureHTTP: allowInsecureHTTP) == true
    }
    private var savedService: CustomHTTPDeviceVault.SavedService? {
        model.savedCustomConnections.first { $0.id == declaration.id }
    }
    private var enteringSettings: Bool { editing || status == nil }

    var body: some View {
        ScrollViewReader { scroll in
            Form {
                connectionOverview
                if enteringSettings {
                    setup
                }
                screenAccess
                if !enteringSettings, let error {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("connection.error")
                }
                if let deletionError {
                    Text(deletionError).foregroundStyle(.red)
                }
            }
            .task(id: focusScreen) {
                guard let focusScreen else { return }
                await Task.yield()
                scroll.scrollTo(focusScreen, anchor: .center)
            }
        }
        .navigationTitle(savedDisplayName)
        .disabled((try? model.requireCurrentCustomConnection(use, owner: owner)) == nil)
        .onAppear { connectionName = savedDisplayName }
        .onChange(of: savedDisplayName) { name in
            if !editingName { connectionName = name }
        }
        .onChange(of: editingName) { focused in
            if !focused { saveName() }
        }
        .task(id: use.screen.revision) { loadSettings() }
        .task(id: testInProgress) { await testConnection() }
        .onChange(of: model.customHTTPRendererKey) { _ in
            if !editing || model.customConnectionStatus(declaration)?.generation != status?.generation {
                editing = false
                loadSettings()
            }
        }
        .task(id: provisioningLookupID) { await refreshProvisioning() }
        .alert(pinEnabled || status?.certificatePin != nil ? "Review certificate trust" : "Replace saved connection?",
               isPresented: $reviewingTrust) {
            Button("Cancel", role: .cancel) {}
            Button("Save connection", action: saveManualConnection)
        } message: {
            Text(trustReview)
        }
        .alert("Cancel credential setup?", isPresented: $removingProvisioning) {
            Button("Keep setup", role: .cancel) {}
            Button("Cancel setup", role: .destructive) { cancelProvisioning() }
        } message: {
            Text("Screenpunk will ask the source to remove the pending credential. Any currently saved connection stays available.")
        }
        .sheet(item: $setupReview) { review in
            credentialReviewSheet(review)
        }
        .onChange(of: formHTTPSOrigin) { newOrigin in
            guard let savedPin = status?.certificatePin,
                  let newOrigin,
                  newOrigin == (try? CredentialRegistrationContext.canonicalHTTPSOrigin(savedPin.origin)) else {
                pinEnabled = false
                fingerprint = ""
                return
            }
            pinEnabled = true
            fingerprint = savedPin.fingerprint
        }
        .onDisappear {
            saveName()
            secret = ""
            setupReview = nil
            provisioningTask?.cancel()
        }
    }

    private var connectionOverview: some View {
        Section("Connection") {
            LabeledContent("Name") {
                TextField("Connection name", text: $connectionName)
                    .accessibilityIdentifier("custom-connection.name")
                    .multilineTextAlignment(.trailing)
                    .focused($editingName)
                    .onSubmit(saveName)
            }
            if !enteringSettings, let status {
                LabeledContent("Server", value: status.origin)
                if status.hasCredential, let credentialLabel { LabeledContent(credentialLabel, value: "Saved") }
                if status.allowInsecureHTTP { LabeledContent("Local HTTP", value: "Allowed") }
                if let pin = status.certificatePin {
                    LabeledContent("Pinned certificate SHA-256") { fingerprintRow(pin.fingerprint) }
                }
                Button("Edit connection settings") { editing = true }
            }
            if let suggested = model.customConnectionProposal(use)?.fields[declaration.originField],
               suggested != server {
                LabeledContent("Suggested server", value: suggested)
                Button("Use suggested server") {
                    fields[declaration.originField] = suggested
                    editing = true
                }
            }
        }
    }

    private func saveName() {
        guard connectionName != savedDisplayName else { return }
        do {
            try model.renameConnection(use, owner: owner, name: connectionName)
            connectionName = savedDisplayName
        } catch {
            self.error = "Couldn’t save the connection name. Try a shorter name and try again."
        }
    }

    private var setup: some View {
        Section {
            Group {
                ForEach(declaration.fields, id: \.id) { field in
                    fieldEditor(field)
                }
                manualTrustFields
            }
            .disabled(provisioningTask != nil)
            if canProvision || provisioning != nil {
                automaticCredentialSetup
            }
            if let error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("connection.error")
            }
            if savedService != nil, let deleteConnection {
                Button("Delete saved connection", role: .destructive, action: deleteConnection)
                    .disabled(provisioningTask != nil)
            }
            HStack {
                Button("Cancel", action: cancelEdits)
                Spacer(minLength: 24)
                Button("Save", action: reviewManualSave)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("custom-connection.save")
            }
            .disabled(provisioningTask != nil)
            .buttonStyle(.borderless)
        } header: {
            Text("Connection settings")
        } footer: {
            Text("Connection details are saved on this device. Each screen needs its own approval.")
        }
    }

    @ViewBuilder private var manualTrustFields: some View {
        if fields[declaration.originField]?.lowercased().hasPrefix("http://") == true {
            Toggle("Allow unencrypted access on this local network", isOn: $allowInsecureHTTP)
        }
        if #available(iOS 18, *), fields[declaration.originField]?.lowercased().hasPrefix("https://") == true {
            Toggle("Pin server certificate", isOn: $pinEnabled)
            if pinEnabled {
                TextField("Leaf certificate SHA-256 fingerprint", text: $fingerprint)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Get the fingerprint independently from the server administrator. When the certificate changes, verify its replacement here.")
                    .font(.footnote)
            }
        }
    }

    private func cancelEdits() {
        provisioningTask?.cancel()
        editing = false
        error = nil
        loadSettings()
    }

    private func reviewManualSave() {
        error = validationMessage(usingAutomaticCredential: false)
        guard error == nil else { return }
        if pinEnabled || status?.certificatePin != nil || (savedService != nil && !secret.isEmpty) {
            reviewingTrust = true
        } else {
            saveManualConnection()
        }
    }

    @ViewBuilder private var automaticCredentialSetup: some View {
        if let provisioningMessage {
            Text(provisioningMessage).font(.footnote)
        }
        if provisioningTask != nil {
            ProgressView("Updating credential setup…")
        } else if let provisioning {
            switch provisioning.state {
            case "ready":
                Button("Review automatic setup") { reviewProvisioning(provisioning) }
            case "pending":
                Text("Waiting for the connection provider to prepare a credential.")
                    .font(.footnote)
                Button("Check setup again") { provisioningRetry = UUID() }
            case "removing":
                Text("Waiting for the connection provider to remove the pending credential.")
                    .font(.footnote)
                Button("Check removal again") { provisioningRetry = UUID() }
            case "retry":
                Text("The registration request didn’t reach the provider. Resume this setup to try again.")
                    .font(.footnote)
                Button("Retry automatic setup", action: beginProvisioning)
            case "expired":
                Text("Automatic setup expired. Cancel it before starting again, or enter a token manually.")
                    .font(.footnote)
            case "failed":
                Text("Automatic setup couldn’t finish. Check that your agent has setup access at the provider, or enter a token manually.")
                    .font(.footnote)
                Button("Check setup again") { provisioningRetry = UUID() }
            case "available":
                Button("Set up credential automatically", action: beginProvisioning)
                    .accessibilityIdentifier("custom-connection.setup-credential")
            default:
                Button("Check for automatic setup") { provisioningRetry = UUID() }
            }
            if ["ready", "pending", "failed", "retry", "expired"].contains(provisioning.state) {
                Button("Cancel automatic setup", role: .destructive) { removingProvisioning = true }
            }
        } else if provisioningChecked {
            Text("Automatic setup is unavailable for this connection. Enter a token from the provider, or ask your agent to confirm it has setup access.")
                .font(.footnote)
            Button("Check for automatic setup") { provisioningRetry = UUID() }
        } else {
            ProgressView("Checking automatic setup…")
        }
    }

    private var provisioningLookupID: String? {
        guard enteringSettings && canProvision, let origin = formHTTPSOrigin else { return nil }
        return [owner, use.id, use.screen.revision, origin, provisioningRetry.uuidString].joined(separator: "\n")
    }

    private func refreshProvisioning() async {
        provisioningChecked = false
        provisioningMessage = nil
        provisioning = nil
        guard provisioningLookupID != nil else { return }
        let expectedServer = server
        let expectedOrigin = formHTTPSOrigin
        do {
            for _ in 0..<20 {
                let result = try await model.connectionCredentialProvisioningStatus(use, owner: owner, server: expectedServer)
                try Task.checkCancellation()
                guard formHTTPSOrigin == expectedOrigin, result?.origin == expectedOrigin || result == nil else { return }
                provisioningChecked = true
                provisioning = result
                guard result?.state == "pending" || result?.state == "removing" else { return }
                try await Task.sleep(for: .seconds(3))
            }
        } catch {
            if !Task.isCancelled {
                provisioningChecked = true
                provisioningMessage = "Couldn’t check credential setup. Try again or enter a token from the provider."
            }
        }
    }

    private func beginProvisioning() {
        let expectedServer = server
        let expectedOrigin = formHTTPSOrigin
        provisioningMessage = nil
        provisioningTask = Task {
            defer { provisioningTask = nil }
            do {
                let result = try await model.beginConnectionCredentialProvisioning(use, owner: owner, server: expectedServer)
                try Task.checkCancellation()
                guard formHTTPSOrigin == expectedOrigin, result.origin == expectedOrigin else { return }
                provisioning = result
                provisioningRetry = UUID()
            } catch {
                if !Task.isCancelled {
                    provisioningMessage = "Couldn’t start automatic setup. Check the connection provider and your access, or enter a token manually."
                }
            }
        }
    }

    private func cancelProvisioning() {
        let expectedServer = server
        provisioningMessage = nil
        provisioningTask = Task {
            defer { provisioningTask = nil }
            do {
                try await model.removePendingConnectionCredential(use, owner: owner, server: expectedServer)
                try Task.checkCancellation()
                provisioningRetry = UUID()
            } catch {
                if !Task.isCancelled { provisioningMessage = "Couldn’t cancel setup. Check the status and try again." }
            }
        }
    }

    private func reviewProvisioning(_ credential: DeviceModel.ProvisioningStatus) {
        error = validationMessage(usingAutomaticCredential: true)
        guard error == nil else { return }
        do {
            guard let origin = formHTTPSOrigin, origin == credential.origin,
                  let fingerprint = credential.certificateFingerprint else { throw ConnectionFailure.validationFailed }
            let pin = try ReviewedCertificatePin(origin: server, fingerprint: fingerprint)
            let oldFingerprint = status?.certificatePin?.fingerprint
            let draftFingerprint = pinEnabled ? (try? ReviewedCertificatePin(origin: server, fingerprint: self.fingerprint))?.fingerprint : nil
            let previous = oldFingerprint ?? draftFingerprint
            setupReview = .init(credential: credential, fields: fields, pin: pin,
                                previousFingerprint: previous == pin.fingerprint ? nil : previous,
                                savedServer: savedService?.origin)
        } catch {
            self.error = "This credential or certificate doesn’t match the current HTTPS server. Check setup again before saving."
        }
    }

    private func credentialReviewSheet(_ review: ProvisioningReview) -> some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Screen", value: use.screen.displayName)
                    LabeledContent("Server", value: review.credential.origin)
                    if let credentialLabel { LabeledContent("Credential", value: credentialLabel) }
                    if let savedServer = review.savedServer {
                        LabeledContent("Currently saved server", value: savedServer)
                        Text("Saving replaces the stored connection settings and credential for this connection.")
                            .font(.footnote)
                    }
                }
                Section("Requested screen access") {
                    ForEach(declaration.operations, id: \.name) { operation in
                        LabeledContent(operation.name, value: operation.method + " " + operation.path)
                    }
                    Text("Screen access requires separate approval.").font(.footnote)
                }
                Section("Certificate SHA-256 reported by the setup agent") {
                    fingerprintRow(review.pin.fingerprint)
                    if let previous = review.previousFingerprint {
                        LabeledContent("Previous certificate SHA-256") { fingerprintRow(previous) }
                    }
                    Text("The authorized setup agent reported this fingerprint after checking the source. Confirm it belongs to this server before trusting it.")
                        .font(.footnote)
                }
                Button("Trust certificate, accept credential and save") {
                    setupReview = nil
                    saveProvisioning(review)
                }
            }
            .navigationTitle("Review connection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { setupReview = nil }
                }
            }
        }
    }

    private func fingerprintRow(_ value: String) -> some View {
        let bytes = Array(value.uppercased())
        let grouped = stride(from: 0, to: bytes.count, by: 4)
            .map { String(bytes[$0..<min($0 + 4, bytes.count)]) }.joined(separator: " ")
        return Text(grouped).font(.footnote.monospaced()).textSelection(.enabled)
    }

    private var screenAccess: some View {
        Section {
            ForEach(model.customConnectionUses(serviceID: declaration.id)) { screenUse in
                let generation = model.customConnectionStatus(screenUse.declaration)?.generation
                let allowed = model.customConnectionApproved(screenUse)
                Toggle(isOn: Binding(get: { model.customConnectionApproved(screenUse) }, set: { enabled in
                    setScreenAccess(enabled, use: screenUse, generation: generation)
                })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(screenUse.screen.displayName)
                        ForEach(screenUse.declaration.operations, id: \.name) { operation in
                            Text(operation.method + " " + operation.path).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!allowed && (generation == nil || enteringSettings || provisioningTask != nil))
                .accessibilityIdentifier("custom-connection.access." + screenUse.id)
                .id(screenUse.id)
            }
            if model.customConnectionApproved(use), declaration.operations.contains(where: { $0.parameters.isEmpty }) {
                Button(testInProgress ? "Testing connection…" : "Test connection") {
                    testResult = nil
                    testInProgress = true
                }
                .disabled(testInProgress || enteringSettings)
                .accessibilityIdentifier("custom-connection.test")
                if let testResult { Text(testResult).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Screen access")
        } footer: {
            Text(enteringSettings
                 ? "Save the connection settings before allowing a screen. You can turn off existing access here."
                 : "Allowing a screen lets it read the listed operations using the connection saved on this device.")
        }
    }

    private func testConnection() async {
        guard testInProgress else { return }
        defer { testInProgress = false }
        do {
            try await model.testCustomConnection(use, owner: owner)
            if !Task.isCancelled { testResult = "Connection succeeded." }
        } catch ConnectionFailure.certificateRejected {
            testResult = "Certificate verification failed. Confirm the certificate fingerprint with the server administrator before replacing the pin."
        } catch {
            if !Task.isCancelled { testResult = "Connection failed. Check the server address, credentials, and network." }
        }
    }

    @ViewBuilder private func fieldEditor(_ field: CustomHTTPField) -> some View {
        switch field.type {
        case "secret":
            SecureField(canReuseCredential ? field.label + " (saved)" : field.label + " (required)", text: $secret)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !canReuseCredential {
                Text("Enter the bearer token for this server on this device.")
                    .font(.footnote)
            }
        case "toggle":
            Toggle(field.label, isOn: Binding(get: { fields[field.id] == "true" },
                                             set: { fields[field.id] = $0 ? "true" : "false" }))
        case "choice":
            Picker(field.label, selection: value(field.id)) {
                ForEach(field.options ?? [], id: \.self) { option in Text(option).tag(option) }
            }
        default:
            TextField(field.label, text: value(field.id))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(field.type == "url" ? .URL : field.type == "number" ? .numbersAndPunctuation : .default)
        }
    }

    private func value(_ id: String) -> Binding<String> {
        Binding(get: { fields[id] ?? "" }, set: { fields[id] = $0 })
    }

    private func loadSettings() {
        testResult = nil
        let existing = model.customConnectionStatus(declaration)
        status = existing
        fields = existing?.fields ?? model.customConnectionProposal(use)?.fields ?? [:]
        for field in declaration.fields where fields[field.id] == nil {
            if field.type == "toggle" { fields[field.id] = "false" }
            if field.type == "choice" { fields[field.id] = field.options?.first }
        }
        pinEnabled = existing?.certificatePin != nil
        fingerprint = existing?.certificatePin?.fingerprint ?? ""
        secret = ""
        allowInsecureHTTP = existing?.allowInsecureHTTP ?? false
    }

    private var trustReview: String {
        var details: [String] = []
        if pinEnabled {
            details.append("Trust the certificate with SHA-256 fingerprint \(fingerprint) for \(server)?")
        } else if status?.certificatePin != nil {
            details.append("Remove the certificate pin and use system trust for \(server)?")
        }
        if let savedService, !secret.isEmpty {
            details.append("Saving replaces the bearer token stored for \(savedService.origin).")
        }
        details.append("Changes require new screen approval.")
        return details.joined(separator: " ")
    }

    private func validationMessage(usingAutomaticCredential: Bool) -> String? {
        for field in declaration.fields {
            if field.type == "secret" && usingAutomaticCredential { continue }
            if field.type == "secret" && secret.isEmpty {
                if !canReuseCredential { return "Enter \(field.label) for this server before saving." }
                continue
            }
            let value = field.type == "secret" ? secret : fields[field.id] ?? ""
            do { try field.validate(value) } catch {
                if field.id == declaration.originField {
                    return "Enter the server address with its scheme and without an operation path."
                }
                return "Check the value for \(field.label) before saving."
            }
        }
        if !usingAutomaticCredential && pinEnabled && (try? ReviewedCertificatePin(origin: server, fingerprint: fingerprint)) == nil {
            return "Check the HTTPS server address and enter its 64-digit SHA-256 fingerprint."
        }
        return nil
    }

    private func saveProvisioning(_ review: ProvisioningReview) {
        guard provisioning?.registrationID == review.id, fields == review.fields else {
            error = "The connection changed while you reviewed setup. Review it again before saving."
            return
        }
        provisioningTask = Task {
            defer { provisioningTask = nil }
            do {
                try await model.saveProvisionedConnectionCredential(review.credential, use: use, owner: owner,
                                                                    fields: review.fields, certificatePin: review.pin)
                finishSave()
            } catch {
                if !Task.isCancelled {
                    self.error = "Credential setup changed or expired. Check the provider and try again."
                    provisioningRetry = UUID()
                }
            }
        }
    }

    private func saveManualConnection() {
        do {
            let pin = pinEnabled ? try ReviewedCertificatePin(origin: server, fingerprint: fingerprint) : nil
            try model.saveCustomConnection(use, owner: owner, fields: fields, secret: secret.isEmpty ? nil : secret,
                                           allowInsecureHTTP: allowInsecureHTTP && server.lowercased().hasPrefix("http://"),
                                           certificatePin: pin)
            finishSave()
        } catch {
            self.error = "Connection could not be saved. Check the server address and local-network setting, then try again."
        }
    }

    private func finishSave() {
        loadSettings()
        editing = false
        error = nil
    }

    private func setScreenAccess(_ allowed: Bool, use: DeviceModel.CustomConnectionUse, generation: UUID?) {
        do {
            try model.setCustomConnectionApproved(allowed, use: use, owner: owner, expectedGeneration: generation)
            error = nil
        } catch {
            self.error = "Couldn’t change access for this screen. Review the saved connection and try again."
        }
    }
}

struct OrphanedCustomConnectionSettings: View {
    let label: String
    let origin: String
    let error: String?
    let deleteConnection: () -> Void
    @State private var editing = false

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Name", value: label)
                LabeledContent("Server", value: origin)
                if editing {
                    Button("Delete saved connection", role: .destructive, action: deleteConnection)
                    Button("Cancel") { editing = false }
                } else {
                    Button("Edit connection settings") { editing = true }
                }
            }
            Section("Screen access") {
                Text("No installed screens use this connection.").foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(label)
    }
}
