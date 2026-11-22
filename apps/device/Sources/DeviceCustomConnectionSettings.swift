import SwiftUI
import ScreenpunkApple
import ScreenpunkCore

struct DeviceCustomConnectionSettings: View {
    @ObservedObject var model: DeviceModel
    let use: DeviceModel.CustomConnectionUse
    let owner: String
    let allowsApproval: Bool
    @State private var fields: [String: String] = [:]
    @State private var pinEnabled = false
    @State private var fingerprint = ""
    @State private var reviewingTrust = false
    @State private var credentialOffer: DeviceModel.ConnectionCredentialOffer?
    @State private var pendingCredentialSave: DeviceModel.ConnectionCredentialOffer?
    @State private var handoffError: String?
    @State private var dismissedDelivery: String?
    @State private var handoffRetry = UUID()
    @State private var savingCredential: Task<Void, Never>?
    @State private var secret = ""
    @State private var allowInsecureHTTP = false
    @State private var editing = false
    @State private var error: String?
    @State private var status: CustomHTTPDeviceVault.Status?
    @State private var approved = false
    @State private var testInProgress = false
    @State private var testResult: String?

    private var declaration: CustomHTTPDeclaration { use.declaration }
    private var credentialLabel: String? {
        declaration.fields.first(where: { $0.type == "secret" })?.label
    }
    private var server: String { fields[declaration.originField] ?? "" }
    private var canReuseCredential: Bool {
        status?.canReuseCredential(for: server, allowInsecureHTTP: allowInsecureHTTP) == true
    }
    private var savedService: CustomHTTPDeviceVault.SavedService? {
        model.savedCustomConnections.first { $0.id == declaration.id }
    }
    private var enteringSettings: Bool { editing || status == nil }

    var body: some View {
        Form {
            if allowsApproval && enteringSettings && model.customConnectionProposal(use) == nil {
                Section("Requested screen access") {
                    Text(use.screen.displayName)
                    ForEach(declaration.operations, id: \.name) { operation in
                        LabeledContent(operation.name, value: operation.method + " " + operation.path)
                    }
                }
            }
            if let proposal = model.customConnectionProposal(use) {
                Section("Suggested by your screen request") {
                    Text(use.screen.displayName)
                    LabeledContent("Proposed server", value: proposal.fields[declaration.originField] ?? "")
                    ForEach(declaration.operations, id: \.name) { operation in
                        LabeledContent(operation.name, value: operation.method + " " + operation.path)
                    }
                    if let savedService { LabeledContent("Currently saved server", value: savedService.origin) }
                    Text(savedService == nil ? "Review these suggested settings. Nothing is saved or connected until you choose Save connection and allow screen access." : "Your saved settings are unchanged. Review the proposed server before editing. A different server requires credentials and new screen approval.")
                        .font(.footnote)
                }
            }
            if enteringSettings {
                setup
            } else if let status {
                Section("Saved connection") {
                    LabeledContent("Server", value: status.origin)
                    if status.hasCredential, let credentialLabel { LabeledContent(credentialLabel, value: "Saved") }
                    if status.allowInsecureHTTP { LabeledContent("Local HTTP", value: "Allowed") }
                    if let pin = status.certificatePin {
                        LabeledContent("Pinned certificate SHA-256", value: pin.fingerprint)
                            .textSelection(.enabled)
                    }
                    Button("Edit connection") { editing = true }
                    if let suggested = model.suggestedCredentialOrigin(use, owner: owner) {
                        Button("Set up suggested server") {
                            fields[declaration.originField] = suggested
                            editing = true
                        }
                    }
                }
                if allowsApproval { screenApproval }
            }
            if enteringSettings && model.canLookForConnectionCredential(use, owner: owner, server: server) {
                credentialHandoffSection
            }
            if enteringSettings && declaration.auth?.mode == "bearer",
               let helperOrigin = try? CredentialHandoffScope.canonicalHTTPSOrigin(server) {
                helperSetupDetails(origin: helperOrigin)
            }
            if !enteringSettings, let error {
                Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("connection.error") }
            }
        }
        .navigationTitle(declaration.label)
        .disabled(savingCredential != nil || (try? model.requireCurrentCustomConnection(use, owner: owner)) == nil)
        .task(id: use.screen.revision) { loadSettings() }
        .task(id: testInProgress) {
            guard testInProgress else { return }
            do {
                try await model.testCustomConnection(use, owner: owner)
                if !Task.isCancelled { testResult = "Connection succeeded." }
            } catch ConnectionFailure.certificateRejected {
                testResult = "Certificate verification failed. Confirm the server address, certificate expiry and SHA-256 fingerprint with the server administrator before replacing the pin."
            } catch {
                if !Task.isCancelled { testResult = "Connection failed. Check the server address, credentials, and network." }
            }
            testInProgress = false
        }
        .onChange(of: model.customHTTPRendererKey) { _ in if !editing { loadSettings() } }
        .task(id: credentialLookupID) { await checkCredentialOffers() }
        .alert("Review certificate trust", isPresented: $reviewingTrust) {
            Button("Cancel", role: .cancel) { pendingCredentialSave = nil }
            Button("Save connection") { save(offer: pendingCredentialSave) }
        } message: {
            Text(trustReview)
        }
        .onChange(of: fields[declaration.originField]) { newOrigin in
            if newOrigin != status?.fields[declaration.originField] {
                pinEnabled = false
                fingerprint = ""
            }
        }
        .onDisappear {
            secret = ""
            pendingCredentialSave = nil
            credentialOffer = nil
            savingCredential?.cancel()
        }
    }

    private var setup: some View {
        Section {
            ForEach(declaration.fields, id: \.id) { field in
                fieldEditor(field)
            }
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
            if let error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("connection.error")
            }
            Button("Save connection") {
                error = validationMessage(usingCredentialOffer: false)
                guard error == nil else { return }
                if pinEnabled || status?.certificatePin != nil { reviewingTrust = true } else { save(offer: nil) }
            }.accessibilityIdentifier("custom-connection.save")
            if editing && status != nil {
                Button("Cancel") { loadSettings(); editing = false; error = nil }
            }
        } header: {
            Text("Connection settings")
        } footer: {
            Text("Connection details are saved on this device. Each screen needs its own approval.")
        }
    }

    private var credentialHandoffSection: some View {
        Section("Credential helper") {
            if let offer = credentialOffer, offer.scope.deliveryID != dismissedDelivery {
                LabeledContent("Credential", value: offer.scope.name)
                LabeledContent("Server", value: offer.scope.origin)
                Button("Use token on this iPad") { useCredentialOffer(offer) }
                Button("Decline", role: .destructive) {
                    savingCredential = Task {
                        defer { savingCredential = nil }
                        do {
                            try await model.declineConnectionCredential(offer, use: use, owner: owner)
                            dismissedDelivery = offer.scope.deliveryID
                            credentialOffer = nil
                            handoffError = "Token offer declined. You can still enter the token manually."
                        } catch {
                            handoffError = "Couldn’t decline this token offer. Try again."
                            self.error = handoffError
                        }
                    }
                }
            } else if let handoffError {
                Text(handoffError).font(.footnote)
                Button("Check for a token again") { handoffRetry = UUID() }
            } else {
                Text("Waiting for a token from your paired helper. You can also enter it manually.")
                    .font(.footnote)
            }
        }
    }

    private func helperSetupDetails(origin: String) -> some View {
        Section {
            DisclosureGroup("Details for helper setup") {
                LabeledContent("Connection ID", value: declaration.id)
                if let digest = try? CredentialHandoffScope.declarationDigest(declaration) {
                    LabeledContent("Declaration SHA-256", value: digest)
                }
                LabeledContent("Server", value: origin)
            }
            .textSelection(.enabled)
        }
    }

    private var credentialLookupID: String? {
        guard enteringSettings, model.canLookForConnectionCredential(use, owner: owner, server: server),
              let pairID = model.credentialHelperPairID else { return nil }
        return [owner, use.screen.revision, use.alias, pairID, server, handoffRetry.uuidString].joined(separator: "\n")
    }

    private func checkCredentialOffers() async {
        credentialOffer = nil
        handoffError = nil
        guard credentialLookupID != nil else { return }
        let expectedServer = server
        do {
            for _ in 0..<30 {
                let offer = try await model.connectionCredentialOffer(use, owner: owner, server: expectedServer)
                try Task.checkCancellation()
                if let offer, offer.scope.deliveryID != dismissedDelivery {
                    credentialOffer = offer
                    return
                }
                try await Task.sleep(for: .seconds(3))
            }
            handoffError = "No token arrived. Check that your helper is online, or enter the token manually."
        } catch {
            if !Task.isCancelled {
                handoffError = "Couldn’t verify the token offer. Check your connection and helper pairing, or enter the token manually."
            }
        }
    }

    private func useCredentialOffer(_ offer: DeviceModel.ConnectionCredentialOffer) {
        error = validationMessage(usingCredentialOffer: true)
        guard error == nil else { return }
        if pinEnabled || status?.certificatePin != nil {
            pendingCredentialSave = offer
            reviewingTrust = true
        } else {
            save(offer: offer)
        }
    }

    private var screenApproval: some View {
        Section {
            Text(use.screen.displayName)
            ForEach(declaration.operations, id: \.name) { operation in
                LabeledContent(operation.name, value: operation.method + " " + operation.path)
            }
            if approved {
                if declaration.operations.contains(where: { $0.parameters.isEmpty }) {
                    Button(testInProgress ? "Testing connection…" : "Test connection") {
                        testInProgress = true
                        testResult = nil
                    }
                    .disabled(testInProgress)
                    .accessibilityIdentifier("custom-connection.test")
                    if let testResult { Text(testResult).foregroundStyle(.secondary) }
                }
                Button("Revoke screen access", role: .destructive) { approve(false) }
            } else {
                Button("Allow this screen") { approve(true) }
                    .accessibilityIdentifier("custom-connection.approve")
            }
        } header: {
            Text("Screen access")
        } footer: {
            Text("The screen can read the listed operations. Screenpunk adds the saved API token to requests where required.")
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
        approved = model.customConnectionApproved(use)
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
        let server = fields[declaration.originField] ?? ""
        if pinEnabled { return "Trust the certificate with SHA-256 fingerprint \(fingerprint) for \(server)? Changes require new screen approval." }
        return "Remove the certificate pin and use system trust for \(server)? Changes require new screen approval."
    }

    private func validationMessage(usingCredentialOffer: Bool) -> String? {
        for field in declaration.fields {
            if field.type == "secret" && usingCredentialOffer { continue }
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
        if pinEnabled && (try? ReviewedCertificatePin(origin: server, fingerprint: fingerprint)) == nil {
            return "Check the HTTPS server address and enter its 64-digit SHA-256 fingerprint."
        }
        return nil
    }

    private func save(offer: DeviceModel.ConnectionCredentialOffer?) {
        defer { pendingCredentialSave = nil }
        do {
            let pin = pinEnabled ? try ReviewedCertificatePin(origin: server, fingerprint: fingerprint) : nil
            if let offer {
                let reviewedFields = fields
                savingCredential = Task {
                    defer { savingCredential = nil }
                    do {
                        try await model.saveConnectionCredential(offer, use: use, owner: owner, fields: reviewedFields, certificatePin: pin)
                        finishSave()
                    } catch {
                        if !Task.isCancelled {
                            self.error = "The token offer expired or the connection changed. Request a new token offer or enter the token manually."
                            credentialOffer = nil
                            handoffRetry = UUID()
                        }
                    }
                }
                return
            }
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

    private func approve(_ allowed: Bool) {
        do {
            try model.setCustomConnectionApproved(allowed, use: use, owner: owner)
            approved = model.customConnectionApproved(use)
            error = nil
        } catch {
            self.error = "Couldn’t change screen access. Reopen this screen’s connection settings and try again."
        }
    }
}
