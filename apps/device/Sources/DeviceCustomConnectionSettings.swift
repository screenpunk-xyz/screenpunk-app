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
    @State private var helperReview: HelperReview?
    @State private var certificateUpdateOrigin: String?

    private struct HelperReview: Identifiable {
        let offer: DeviceModel.ConnectionCredentialOffer
        let fields: [String: String]
        let pin: ReviewedCertificatePin?
        let previousFingerprint: String?
        let replacedDraftFingerprint: String?
        let savedServer: String?
        let isCertificateUpdate: Bool
        var id: String { offer.scope.deliveryID }
    }
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
    private var formHTTPSOrigin: String? { try? CredentialHandoffScope.canonicalHTTPSOrigin(server) }
    private var isCheckingCertificateUpdate: Bool {
        certificateUpdateOrigin != nil && formHTTPSOrigin == certificateUpdateOrigin
    }
    private var canLookForCredentialOffer: Bool {
        model.canLookForConnectionCredential(use, owner: owner, server: server,
                                             allowCertificateUpdate: isCheckingCertificateUpdate)
    }
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
                    if canReuseCredential, let formHTTPSOrigin,
                       model.canLookForConnectionCredential(use, owner: owner, server: server, allowCertificateUpdate: true) {
                        Button("Check for a certificate update") {
                            certificateUpdateOrigin = formHTTPSOrigin
                            editing = true
                        }
                    }
                    if let suggested = model.suggestedCredentialOrigin(use, owner: owner) {
                        Button("Set up suggested server") {
                            fields[declaration.originField] = suggested
                            editing = true
                        }
                    }
                }
                if allowsApproval { screenApproval }
            }
            if enteringSettings && canLookForCredentialOffer {
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
        .alert(pinEnabled || status?.certificatePin != nil ? "Review certificate trust" : "Replace saved connection?",
               isPresented: $reviewingTrust) {
            Button("Cancel", role: .cancel) {}
            Button("Save connection", action: saveManualConnection)
        } message: {
            Text(trustReview)
        }
        .sheet(item: $helperReview) { review in
            helperReviewSheet(review)
        }
        .onChange(of: formHTTPSOrigin) { newOrigin in
            if newOrigin != certificateUpdateOrigin { certificateUpdateOrigin = nil }
            guard let savedPin = status?.certificatePin,
                  let newOrigin,
                  newOrigin == (try? CredentialHandoffScope.canonicalHTTPSOrigin(savedPin.origin)) else {
                pinEnabled = false
                fingerprint = ""
                return
            }
            pinEnabled = true
            fingerprint = savedPin.fingerprint
        }
        .onDisappear {
            secret = ""
            helperReview = nil
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
                if pinEnabled || status?.certificatePin != nil || (savedService != nil && !secret.isEmpty) {
                    reviewingTrust = true
                } else {
                    saveManualConnection()
                }
            }.accessibilityIdentifier("custom-connection.save")
            if editing && status != nil {
                Button("Cancel") {
                    certificateUpdateOrigin = nil
                    loadSettings()
                    editing = false
                    error = nil
                }
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
                Button(offer.certificateFingerprint == nil ? "Review token" : "Review token and certificate") {
                    reviewCredentialOffer(offer)
                }
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
        guard enteringSettings, canLookForCredentialOffer,
              let pairID = model.credentialHelperPairID else { return nil }
        return [owner, use.screen.revision, use.alias, pairID, formHTTPSOrigin ?? server,
                isCheckingCertificateUpdate ? "certificate" : "setup", handoffRetry.uuidString].joined(separator: "\n")
    }

    private func checkCredentialOffers() async {
        credentialOffer = nil
        handoffError = nil
        guard credentialLookupID != nil else { return }
        let expectedServer = server
        let allowCertificateUpdate = isCheckingCertificateUpdate
        do {
            for _ in 0..<30 {
                let offer = try await model.connectionCredentialOffer(use, owner: owner, server: expectedServer,
                                                                      allowCertificateUpdate: allowCertificateUpdate)
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

    private func reviewCredentialOffer(_ offer: DeviceModel.ConnectionCredentialOffer) {
        let offeredFingerprint = offer.certificateFingerprint
        error = validationMessage(usingCredentialOffer: true, checkManualPin: offeredFingerprint == nil)
        guard error == nil else { return }
        do {
            let origin = try CredentialHandoffScope.canonicalHTTPSOrigin(server)
            guard origin == offer.scope.origin else { throw ConnectionFailure.validationFailed }
            let existingPin = model.savedCertificatePinForCredentialOffer(use, owner: owner, origin: origin)
            let sameOriginPin = try existingPin.map { try ReviewedCertificatePin(origin: server, fingerprint: $0.fingerprint) }
            let draftPin = pinEnabled ? try? ReviewedCertificatePin(origin: server, fingerprint: fingerprint) : nil
            let pin: ReviewedCertificatePin?
            if let offeredFingerprint {
                guard #available(iOS 18, *) else {
                    error = "Reviewing a delivered certificate requires iPadOS 18 or later."
                    return
                }
                pin = try ReviewedCertificatePin(origin: server, fingerprint: offeredFingerprint)
            } else {
                pin = draftPin ?? sameOriginPin
            }
            let savedFingerprint = (existingPin ?? status?.certificatePin)?.fingerprint
            let priorDraft = draftPin?.fingerprint
            helperReview = .init(offer: offer, fields: fields, pin: pin,
                                 previousFingerprint: savedFingerprint == pin?.fingerprint ? nil : savedFingerprint,
                                 replacedDraftFingerprint: priorDraft == pin?.fingerprint || priorDraft == savedFingerprint ? nil : priorDraft,
                                 savedServer: savedService?.origin, isCertificateUpdate: isCheckingCertificateUpdate)
        } catch {
            self.error = "This offer doesn’t match the current HTTPS server. Request a new offer for this connection."
        }
    }

    private func helperReviewSheet(_ review: HelperReview) -> some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Screen", value: use.screen.displayName)
                    LabeledContent("Server", value: review.offer.scope.origin)
                    LabeledContent("Credential", value: review.offer.scope.name)
                    if let savedServer = review.savedServer {
                        LabeledContent("Currently saved server", value: savedServer)
                        Text("Saving replaces the stored connection settings and bearer token for this connection.")
                            .font(.footnote)
                    }
                }
                Section("Requested screen access") {
                    ForEach(declaration.operations, id: \.name) { operation in
                        LabeledContent(operation.name, value: operation.method + " " + operation.path)
                    }
                    Text("Screen access requires separate approval.")
                        .font(.footnote)
                }
                if let pin = review.pin {
                    Section {
                        fingerprintRow(pin.fingerprint)
                        if let previous = review.previousFingerprint {
                            Text("Saved certificate SHA-256").font(.footnote)
                            fingerprintRow(previous)
                        }
                        if let draft = review.replacedDraftFingerprint {
                            Text("Fingerprint entered in this form").font(.footnote)
                            fingerprintRow(draft)
                        }
                    } header: {
                        Text(review.offer.certificateFingerprint == nil ? "Certificate SHA-256" : "Certificate SHA-256 from your paired helper")
                    } footer: {
                        Text("Confirm this fingerprint belongs to the server you intend to use. This pin applies only to the server above.")
                    }
                } else if let previous = review.previousFingerprint {
                    Section("Previous server certificate") {
                        fingerprintRow(previous)
                        Text("The previous server’s certificate pin won’t apply to this server. The new server will use system trust.")
                            .font(.footnote)
                    }
                }
                Button(review.pin == nil ? "Accept token and save" : "Trust certificate, accept token and save") {
                    helperReview = nil
                    saveCredentialOffer(review)
                }
            }
            .navigationTitle("Review connection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { helperReview = nil }
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

    private func validationMessage(usingCredentialOffer: Bool, checkManualPin: Bool = true) -> String? {
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
        if checkManualPin && pinEnabled && (try? ReviewedCertificatePin(origin: server, fingerprint: fingerprint)) == nil {
            return "Check the HTTPS server address and enter its 64-digit SHA-256 fingerprint."
        }
        return nil
    }

    private func saveCredentialOffer(_ review: HelperReview) {
        guard credentialOffer?.scope.deliveryID == review.id, fields == review.fields,
              review.isCertificateUpdate == isCheckingCertificateUpdate else {
            error = "The connection changed while you reviewed the offer. Review it again before saving."
            return
        }
        savingCredential = Task {
            defer { savingCredential = nil }
            do {
                try await model.saveConnectionCredential(review.offer, use: use, owner: owner,
                                                         fields: review.fields, certificatePin: review.pin)
                finishSave()
            } catch {
                if !Task.isCancelled {
                    self.error = "The token offer expired or the connection changed. Request a new token offer or enter the token manually."
                    credentialOffer = nil
                    handoffRetry = UUID()
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
        certificateUpdateOrigin = nil
        loadSettings()
        editing = false
        error = nil
    }

    private func approve(_ allowed: Bool) {
        do {
            try model.setCustomConnectionApproved(allowed, use: use, owner: owner, expectedGeneration: status?.generation)
            approved = model.customConnectionApproved(use)
            error = nil
        } catch {
            self.error = "Couldn’t change screen access. Reopen this screen’s connection settings and try again."
        }
    }
}
