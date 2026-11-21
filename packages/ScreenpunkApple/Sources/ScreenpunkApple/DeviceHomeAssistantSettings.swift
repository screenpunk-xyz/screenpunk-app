#if os(iOS)
import SwiftUI
import AVFoundation
import ScreenpunkCore

/// One device/account connection with separately approved screen declarations.
public struct DeviceHomeAssistantSettings<ScreenLinks: View>: View {
    private let owner: String
    private let screenLinks: ScreenLinks
    private let onChange: () -> Void
    @State private var origin = ""
    @State private var token = ""
    @State private var allowHTTP = false
    @State private var message: String?
    @State private var scanning = false
    @State private var connected = false
    public init(owner: String, onChange: @escaping () -> Void = {}, @ViewBuilder screenLinks: () -> ScreenLinks) {
        self.owner = owner
        self.onChange = onChange
        self.screenLinks = screenLinks()
    }
    public var body: some View {
        Form {
            Section("Home Assistant") {
                Text(connected ? "Connected on this device" : "Connect once for the screens on this device.")
                TextField("Server address", text: $origin)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField(connected ? "Saved token — leave blank to keep" : "Long-lived access token", text: $token)
                Button { startScanning() } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                Text("Scan a token or a JSON connection containing a server address and token. Review the fields before allowing the connection.").font(.footnote).foregroundStyle(.secondary)
                Toggle("Allow HTTP on my local network", isOn: $allowHTTP)
                Button(connected ? "Save connection" : "Connect") { connect() }.disabled(origin.isEmpty || (!connected && token.isEmpty))
                    .buttonStyle(.borderedProminent)
                Button("Disconnect", role: .destructive) {
                    do { try HomeAssistantDeviceVault().revokeCredential(owner: owner); token = ""; message = "Disconnected"; reload(); onChange() }
                    catch { message = "Could not remove the connection." }
                }.disabled(!connected)
                if let message { ConnectionFeedback(message) { self.message = nil } }
            }
            Section("Screens using Home Assistant") { screenLinks }
        }.navigationTitle("Home Assistant")
        .onAppear { reload() }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                HomeAssistantQRScanner(onResult: acceptScan, onFailure: {
                    scanning = false; message = "Camera unavailable. You can enter the connection manually."
                }).ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan Home Assistant")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
            }
        }
    }
    private func startScanning() {
        AVCaptureDevice.requestAccess(for: .video) { allowed in
            DispatchQueue.main.async {
                if allowed { scanning = true }
                else { message = "Allow camera access in iPad Settings to scan, or enter the connection manually." }
            }
        }
    }
    private func acceptScan(_ text: String) {
        scanning = false
        guard let connection = HomeAssistantQRPayload.parse(text) else {
            message = "This QR code does not contain a supported Home Assistant connection or token."; return
        }
        if let server = connection.origin { origin = server }
        token = connection.token
        message = "Scanned. Review the server address and local HTTP choice, then tap Connect."
    }
    private func reload() {
        let vault = HomeAssistantDeviceVault()
        if let status = vault.credentialStatus(owner: owner) {
            connected = true; origin = status.origin; allowHTTP = status.allowInsecureHTTP
        } else { connected = false }
    }
    private func connect() {
        do {
            let vault = HomeAssistantDeviceVault()
            try vault.saveCredential(owner: owner, origin: origin.trimmingCharacters(in: .whitespacesAndNewlines), token: token, allowInsecureHTTP: allowHTTP)
            token = ""; message = "Connected on this device"; reload(); onChange()
        } catch { message = "Check the server address and token." }
    }
}

public struct DeviceHomeAssistantScreenSettings: View {
    private let owner: String
    private let manifest: DashboardManifest
    private let onChange: () -> Void
    @State private var connected = false
    @State private var approved = false
    @State private var message: String?

    public init(owner: String, manifest: DashboardManifest, onChange: @escaping () -> Void = {}) {
        self.owner = owner
        self.manifest = manifest
        self.onChange = onChange
    }

    public var body: some View {
        Section("Home Assistant") {
            if !connected {
                Text("Connect Home Assistant in Connections to allow access for this screen.")
                    .foregroundStyle(.secondary)
            } else if approved {
                Label("Access allowed", systemImage: "checkmark.circle")
                Button("Revoke access", role: .destructive) { changeApproval(allowed: false) }
            } else {
                Button("Allow Home Assistant access") { changeApproval(allowed: true) }
            }
            if let message { ConnectionFeedback(message) { self.message = nil } }
        }
        .onAppear(perform: reload)
        .onChange(of: owner) { _ in reload() }
        .onChange(of: manifest) { _ in reload() }
    }

    private func reload() {
        let vault = HomeAssistantDeviceVault()
        connected = vault.credentialStatus(owner: owner) != nil
        approved = connected && vault.synchronize(manifest: manifest, owner: owner)
    }

    private func changeApproval(allowed: Bool) {
        do {
            let vault = HomeAssistantDeviceVault()
            if allowed {
                try vault.approve(manifest: manifest, owner: owner)
            } else {
                try vault.revokeScreen(owner: owner, dashboardID: manifest.dashboardId)
            }
            message = nil
            reload()
            onChange()
        } catch {
            message = "Could not update Home Assistant access for this screen."
        }
    }
}
#endif
