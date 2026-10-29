#if os(iOS)
import SwiftUI
import AVFoundation
import ScreenpunkCore

/// One device/account connection with separately approved screen declarations.
public struct DeviceHomeAssistantSettings: View {
    private let owner: String
    private let manifests: [DashboardManifest]
    private let onChange: () -> Void
    @State private var origin = ""
    @State private var token = ""
    @State private var allowHTTP = false
    @State private var message: String?
    @State private var scanning = false
    @State private var connected = false
    @State private var approvedScreens: Set<String> = []
    public init(owner: String, manifests: [DashboardManifest], onChange: @escaping () -> Void = {}) {
        self.owner = owner; self.manifests = manifests; self.onChange = onChange
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
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            Section("Screens using Home Assistant") {
                ForEach(manifests, id: \.dashboardId) { manifest in
                    HStack {
                        Text(manifest.name)
                        Spacer()
                        if approvedScreens.contains(manifest.dashboardId) {
                            Text("Connected").foregroundStyle(.secondary)
                        } else if connected {
                            Button("Allow screen") { approve(manifest) }
                        } else {
                            Text("Not connected").foregroundStyle(.secondary)
                        }
                    }
                }
                if manifests.isEmpty { Text("No installed screens use Home Assistant.").foregroundStyle(.secondary) }
            }
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
        approvedScreens = Set(manifests.filter { vault.synchronize(manifest: $0, owner: owner) }.map(\.dashboardId))
    }
    private func connect() {
        do {
            let vault = HomeAssistantDeviceVault()
            try vault.saveCredential(owner: owner, origin: origin.trimmingCharacters(in: .whitespacesAndNewlines), token: token, allowInsecureHTTP: allowHTTP)
            for manifest in manifests { try vault.approve(manifest: manifest, owner: owner) }
            token = ""; message = "Connected on this device"; reload(); onChange()
        } catch { message = "Check the server address and token." }
    }
    private func approve(_ manifest: DashboardManifest) {
        do {
            try HomeAssistantDeviceVault().approve(manifest: manifest, owner: owner)
            message = "Screen connected"; reload(); onChange()
        } catch { message = "Could not approve this screen." }
    }
}
#endif
