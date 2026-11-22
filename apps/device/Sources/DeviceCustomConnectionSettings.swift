import SwiftUI
import ScreenpunkApple
import ScreenpunkCore

struct DeviceCustomConnectionSettings: View {
    @ObservedObject var model: DeviceModel
    let use: DeviceModel.CustomConnectionUse
    let owner: String
    let allowsApproval: Bool
    @State private var fields: [String: String] = [:]
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
                    Button("Edit connection") { editing = true }
                }
                if allowsApproval { screenApproval }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("connection.error") }
            }
        }
        .navigationTitle(declaration.label)
        .disabled((try? model.requireCurrentCustomConnection(use, owner: owner)) == nil)
        .task(id: use.screen.revision) { loadSettings() }
        .task(id: testInProgress) {
            guard testInProgress else { return }
            do {
                try await model.testCustomConnection(use, owner: owner)
                if !Task.isCancelled { testResult = "Connection succeeded." }
            } catch {
                if !Task.isCancelled { testResult = "Connection failed. Check the server address, credentials, and network." }
            }
            testInProgress = false
        }
        .onChange(of: model.customHTTPRendererKey) { _ in if !editing { loadSettings() } }
        .onDisappear { secret = "" }
    }

    private var setup: some View {
        Section {
            ForEach(declaration.fields, id: \.id) { field in
                fieldEditor(field)
            }
            if fields[declaration.originField]?.lowercased().hasPrefix("http://") == true {
                Toggle("Allow unencrypted access on this local network", isOn: $allowInsecureHTTP)
            }
            Button("Save connection", action: save).accessibilityIdentifier("custom-connection.save")
            if editing && status != nil {
                Button("Cancel") { loadSettings(); editing = false; error = nil }
            }
        } header: {
            Text("Connection settings")
        } footer: {
            Text("Connection details are saved on this device. Each screen needs its own approval.")
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
            SecureField(status?.hasCredential == true ? field.label + " (saved)" : field.label, text: $secret)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
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
        secret = ""
        allowInsecureHTTP = existing?.allowInsecureHTTP ?? false
    }

    private func save() {
        do {
            try model.saveCustomConnection(use, owner: owner, fields: fields, secret: secret.isEmpty ? nil : secret,
                                           allowInsecureHTTP: allowInsecureHTTP && fields[declaration.originField]?.lowercased().hasPrefix("http://") == true)
            loadSettings()
            editing = false
            error = nil
        } catch {
            self.error = "Check the server address and required connection fields, then try again."
        }
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
