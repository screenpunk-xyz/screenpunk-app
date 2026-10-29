import Foundation
import Combine
import UIKit
import ScreenpunkCore
import ScreenpunkLocalAuthoring
import ScreenpunkLocalTransport

@MainActor final class LocalAgentSettingsModel: ObservableObject {
    @Published var name = "My computer"
    @Published var host = ""
    @Published var username = ""
    @Published var fingerprint = ""
    @Published var workspace = ""
    @Published var bearerToken = ""
    @Published var verifiedFingerprint = false
    @Published var sshPort = "22"
    @Published private(set) var configuration: LocalAgentConfiguration?
    @Published private(set) var pendingRequest: LocalPairingRequest?
    @Published private(set) var candidate: LocalPairingImport?
    @Published private(set) var shareURL: URL?
    @Published private(set) var testing = false
    @Published private(set) var status = "Not connected"
    @Published private(set) var details: String?
    @Published private(set) var error: String?
    @Published private(set) var tested = false
    @Published private(set) var lastSuccess: Date?
    private let configurations: LocalAgentConfigurationRepository
    private let ledger: LocalDeliveryLedger
    private let vault: KeychainLocalCredentialStore
    private let pairing: LocalPairingRepository
    private let profileID: () -> String?
    private let changed: () -> Void
    private static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    init(configurationRepository: LocalAgentConfigurationRepository, ledger: LocalDeliveryLedger, vault: KeychainLocalCredentialStore, profileID: @escaping () -> String?, changed: @escaping () -> Void) throws {
        configurations = configurationRepository; self.ledger = ledger; self.vault = vault; self.profileID = profileID; self.changed = changed
        pairing = try LocalPairingRepository(configurationRepository: configurationRepository)
        reload()
    }
    var connectionStatusLabel: String {
        guard status == "Ready" else { return status }
        return configuration?.serverLifecycle == .background ? "Ready · starts after Mac sign-in" : "Ready · Terminal required"
    }
    static func startupLabel(for configuration: LocalAgentConfiguration?) -> String {
        configuration?.serverLifecycle == .background ? "After Mac sign-in" : "In Terminal"
    }
    static func lifecycleGuidance(for configuration: LocalAgentConfiguration?) -> String {
        guard let configuration else { return "Connect your Mac in Agents, then keep it awake and reachable." }
        switch configuration.serverLifecycle {
        case .background:
            return "The agent starts when you sign in to your Mac and restarts if it stops. You can close the setup Terminal. Keep your Mac user signed in and the Mac awake and reachable."
        case .foreground:
            return "This connection runs in Terminal. Keep its setup Terminal open and the Mac awake and reachable. To run after Mac sign-in, enable background startup in Mac setup, then scan its new connection code."
        }
    }
    static func unavailableGuidance(for configuration: LocalAgentConfiguration?) -> String {
        guard let configuration else { return "Connect your Mac in Agents, then keep it awake and reachable." }
        switch configuration.serverLifecycle {
        case .background: return "Keep your Mac user signed in and the Mac awake and reachable. Check background startup in Mac setup if it stays unavailable, then retry."
        case .foreground: return "Keep the Mac awake and reachable and its setup Terminal open, then retry. You can enable background startup through Mac setup."
        }
    }
    func reload() {
        do {
            configuration = try configurations.load()
            lastSuccess = configuration?.lastSuccessfulConnectionAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            status = lastSuccess == nil ? "Not connected" : "Ready"
        } catch { self.error = error.localizedDescription }
    }
    func beginSetup() {
        guard !testing else { return }
        tested = false; verifiedFingerprint = false; bearerToken = ""; error = nil
        do {
            try pairing.expire(now: Self.now, credentials: vault)
            candidate = try pairing.recover(now: Self.now, credentials: vault)
            if let saved = try pairing.pendingRequest(now: Self.now) { pendingRequest = saved }
            else {
                if let reference = configuration?.credentialReference {
                    let key = try vault.publicKey(reference: .init(rawValue: reference))
                    pendingRequest = try pairing.begin(publicKeyOpenSSH: key, identityReference: reference, deviceName: UIDevice.current.name, now: Self.now)
                } else {
                    let identity = try vault.createIdentity()
                    do { pendingRequest = try pairing.begin(publicKeyOpenSSH: identity.publicKeyOpenSSH, identityReference: identity.reference.rawValue, deviceName: UIDevice.current.name, now: Self.now) }
                    catch { try? vault.forget(reference: identity.reference); throw error }
                }
            }
            try prepareShareFile()
        } catch { self.error = error.localizedDescription }
    }
    private func prepareShareFile() throws {
        guard let request = pendingRequest else { return }
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ScreenpunkLocal/public-setup-request", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Screenpunk-setup-request.json")
        try request.encoded().write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        shareURL = url
    }
    func refreshSetupRequest() {
        guard !testing else { return }
        do {
            let reference = try pairing.pendingIdentityReference() ?? configuration?.credentialReference
            let key = try reference.map { try vault.publicKey(reference: .init(rawValue: $0)) }
            try pairing.cancel(credentials: vault); candidate = nil; pendingRequest = nil; shareURL = nil
            if let reference, let key {
                pendingRequest = try pairing.begin(publicKeyOpenSSH: key, identityReference: reference, deviceName: UIDevice.current.name, now: Self.now)
            }
            beginSetup()
        }
        catch { self.error = error.localizedDescription }
    }
    /// Closing the sheet preserves the durable pending request and staged import for recovery.
    func cancelSetup() { bearerToken = "" }
    func importReply(_ data: Data, source: LocalPairingSource) {
        guard !testing else { return }
        error = nil; tested = false; details = nil
        do { candidate = try pairing.stageReply(data, source: source, now: Self.now, credentials: vault); status = "Connection code ready for review" }
        catch { self.error = error.localizedDescription }
    }
    func importPrivateFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            guard let data = try handle.read(upToCount: 8193), data.count <= 8192 else { throw DeviceError.message("This connection file is too large.") }
            importReply(data, source: .privateFile)
        } catch { self.error = "The private connection file could not be opened. Choose the file saved locally by the Mac setup page." }
    }
    func stageManual() {
        defer { bearerToken = "" }
        guard let request = pendingRequest, verifiedFingerprint, let port = Int(sshPort), (1...65535).contains(port) else {
            error = "Paste the SHA256 value from this Mac and confirm it before continuing."; return
        }
        do {
            let now = Self.now
            let object: [String: Any] = ["type": "screenpunk.pairing-reply.v1", "schemaVersion": 1, "pairingID": request.pairingID, "nonce": request.nonce, "publicKeySHA256": request.publicKeySHA256, "issuedAt": now, "expiresAt": min(now + 300_000, request.expiresAt), "computerName": name, "host": host, "sshPort": port, "username": username, "hostKeySHA256": fingerprint, "appServerPort": 4500, "macWorkspace": workspace, "codexVersion": request.codexVersion, "protocolProfile": request.protocolProfile, "appServerToken": bearerToken]
            importReply(try JSONSerialization.data(withJSONObject: object), source: .privateFile)
        } catch { self.error = "The manual connection details could not be prepared." }
    }
    func testConnection(isSetup: Bool) async {
        guard !testing else { return }
        testing = true; error = nil; tested = false; defer { testing = false }
        do {
            guard let id = profileID() else { throw DeviceError.message("The current local identity is unavailable.") }
            let transport = LocalAuthoringTransport(profileID: id, configurationRepository: configurations, ledger: ledger, credentialStore: vault, requestLookup: { _ in nil })
            status = "Computer reachable · checking secure connection…"
            let progress = Task { [weak self] in
                while !Task.isCancelled {
                    self?.status = transport.connectionStatus
                    do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                }
            }
            defer { progress.cancel() }
            let receipt: LocalAgentTestReceipt
            do {
                if isSetup {
                    guard let candidate else { throw DeviceError.message("Scan or import this Mac’s connection code first.") }
                    receipt = try await transport.testConnection(configuration: candidate.configuration)
                } else { receipt = try await transport.testConnection() }
                await transport.disconnect()
            } catch { await transport.disconnect(); throw error }
            guard profileID() == id else { throw DeviceError.message("The current connection changed. Review this setup again before connecting.") }
            if isSetup {
                guard let candidate else { throw DeviceError.message("The pending connection changed. Scan its code again.") }
                let committed = try pairing.commit(importID: candidate.id, replyDigest: candidate.replyDigest, now: Self.now, credentials: vault)
                try configurations.markSuccessfulConnection(configurationID: committed.id, at: receipt.testedAt)
                self.candidate = nil; pendingRequest = nil; removeShareFile()
            }
            tested = true; lastSuccess = Date(timeIntervalSince1970: Double(receipt.testedAt) / 1000)
            details = "\(receipt.model) · \(receipt.requestedEffort) reasoning · \(receipt.requestedServiceTier) requested · Codex \(receipt.serverVersion) · history reconnected"
            reload(); status = "Ready"; changed()
        } catch { self.error = error.localizedDescription; status = "Connection needs attention" }
    }
    /// Address-only recovery keeps the existing trusted pin and credential. The
    /// active endpoint changes only after the candidate passes the disclosed test.
    func repairAddress(host: String, port: Int) async {
        guard !testing, let previous = configuration, let id = profileID() else { return }
        testing = true; error = nil; tested = false; defer { testing = false }
        do {
            guard try ledger.unresolvedRecord() == nil else { throw DeviceError.message("Finish or cancel the current local request before changing its address.") }
            let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:%_")
            guard !address.isEmpty, address.utf8.count <= 253, !address.hasPrefix("-"), address.unicodeScalars.allSatisfy({ allowed.contains($0) }), (1...65535).contains(port) else { throw DeviceError.message("Enter a valid Mac address and SSH port.") }
            var repaired = previous
            repaired.id = UUID().uuidString; repaired.host = address; repaired.sshPort = port
            let transport = LocalAuthoringTransport(profileID: id, configurationRepository: configurations, ledger: ledger, credentialStore: vault, requestLookup: { _ in nil })
            status = "Checking the new address against the saved SSH identity…"
            let receipt: LocalAgentTestReceipt
            do { receipt = try await transport.testConnection(configuration: repaired); await transport.disconnect() }
            catch { await transport.disconnect(); throw error }
            guard profileID() == id, try configurations.load()?.id == previous.id else { throw DeviceError.message("The saved connection changed. Review its address again.") }
            repaired.lastSuccessfulConnectionAt = receipt.testedAt
            try configurations.save(repaired)
            details = "\(receipt.model) · \(receipt.requestedEffort) reasoning · \(receipt.requestedServiceTier) requested · history reconnected"
            tested = true; reload(); status = "Ready"; changed()
        } catch { self.error = error.localizedDescription; status = "Connection needs attention" }
    }
    private func removeShareFile() {
        if let shareURL { try? FileManager.default.removeItem(at: shareURL) }
        shareURL = nil
    }
    func forget() {
        guard !testing, let config = configuration else { return }
        do {
            try ledger.blockOutstanding(configurationID: config.id, reason: "The local agent was forgotten on this device.")
            try vault.forget(reference: .init(rawValue: config.credentialReference))
            _ = try configurations.remove(configurationID: config.id)
            configuration = nil; tested = false; lastSuccess = nil; bearerToken = ""; status = "Not connected"; changed()
        } catch { self.error = error.localizedDescription }
    }
}
