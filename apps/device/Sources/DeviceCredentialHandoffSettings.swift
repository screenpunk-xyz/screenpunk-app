import Foundation
import ScreenpunkApple
import SwiftUI
import UniformTypeIdentifiers

/// The pairing payload stays in native Settings while the operator reviews it.
struct DeviceCredentialHandoffSettings: View {
    @ObservedObject var model: DeviceModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var scanning = false
    @State private var importingFile = false
    @State private var reviewingPair = false
    @State private var confirmingRemoval = false
    @State private var removalPairID: String?
    @State private var pendingPair: PendingPair?
    @State private var acquisition: DeviceScope?
    @State private var busy = false
    @State private var notice: String?

    private struct PendingPair {
        let code: String
        let scope: DeviceScope
        let pairID: String
    }

    private struct DeviceScope: Equatable {
        let owner: String
        let deviceID: String
    }

    private var scope: DeviceScope? {
        guard let deviceID = model.credentialHelperDeviceID else { return nil }
        return .init(owner: model.permissionOwner, deviceID: deviceID)
    }

    var body: some View {
        Form {
            Section {
                if let pairID = model.credentialHelperPairID {
                    if model.isCredentialHelperPaired {
                        Label("Credential helper paired", systemImage: "checkmark.circle")
                    } else {
                        Label("Pairing expired", systemImage: "clock.badge.exclamationmark")
                    }
                    identifier("Pair ID", value: pairID)
                    if let expiresAt = model.credentialHelperExpiresAt {
                        LabeledContent("Pairing expiry", value: expiresAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let route = model.credentialHelperAccountRoute {
                        identifier("Relay account route", value: route)
                    }
                    if let deviceID = model.credentialHelperDeviceID {
                        identifier("Device ID", value: deviceID)
                    }
                    Button("Remove helper", role: .destructive) {
                        removalPairID = pairID
                        confirmingRemoval = true
                    }
                } else if model.canPairCredentialHelper {
                    Button("Scan helper code") { acquisition = scope; scanning = true }
                        .accessibilityIdentifier("credential-helper.scan")
                    Button("Import pairing file") { acquisition = scope; importingFile = true }
                } else if model.credentialHelperDeviceID == nil {
                    Text("Sign in to Screenpunk Cloud to pair a credential helper.")
                } else {
                    Text("Credential helper pairing is currently unavailable on this Screenpunk Cloud connection.")
                }
            } footer: {
                if model.isCredentialHelperPaired {
                    Text("Use these identifiers to finish setup on your helper. Removing the helper stops future deliveries and keeps credentials already saved on this iPad.")
                } else if model.credentialHelperPairID != nil {
                    Text("Remove the expired pairing and create a new pairing on your helper. Already-saved tokens stay on this iPad.")
                } else if model.canPairCredentialHelper {
                    Text("Get the code or pairing file directly from your trusted helper. Once paired, you can review and accept individual token deliveries in connection settings.")
                }
            }
            if busy { ProgressView("Updating credential helper…") }
            if let notice { Text(notice).foregroundStyle(.secondary) }
        }
        .disabled(busy)
        .sheet(isPresented: $scanning, onDismiss: {
            acquisition = nil
            reviewingPair = pendingPair != nil
        }) {
            NavigationStack {
                ConnectionQRScanner { code in
                    stage(code)
                    scanning = false
                } onFailure: {
                    scanning = false
                    notice = "The camera is unavailable. Check camera access in Settings or import the helper’s pairing file."
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan helper code")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { scanning = false }
                    }
                }
            }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [
            UTType(filenameExtension: "screenpunk-pair") ?? .data
        ]) { result in
            defer { acquisition = nil }
            do {
                try stage(Self.readPairingFile(result.get()))
                reviewingPair = pendingPair != nil
            } catch CocoaError.userCancelled {
                return
            } catch {
                notice = "Couldn’t read this pairing file. Choose the .screenpunk-pair file from your trusted helper."
            }
        }
        .alert("Trust this credential helper?", isPresented: $reviewingPair) {
            Button("Cancel", role: .cancel) { pendingPair = nil }
            Button("Pair helper") { commitPair() }
        } message: {
            if let pendingPair {
                Text("Pair helper \(pendingPair.pairID) through \(CloudClient.originScope.canonicalOrigin)? Continue only if this matches the helper you trust. Each delivery still requires your review.")
            }
        }
        .alert("Remove credential helper?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) { removalPairID = nil }
            Button("Remove helper", role: .destructive) { removePair() }
        } message: {
            Text("This stops future deliveries from the helper. Tokens already saved in connections stay on this iPad.")
        }
        .onChange(of: scope) { _ in
            clearPendingPairing()
            notice = nil
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background, !importingFile { clearPendingPairing() }
        }
        .onDisappear { clearPendingPairing() }
    }

    private func identifier(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            Text(value).font(.footnote.monospaced()).textSelection(.enabled)
        }
    }

    private func clearPendingPairing() {
        scanning = false
        importingFile = false
        reviewingPair = false
        confirmingRemoval = false
        removalPairID = nil
        pendingPair = nil
        acquisition = nil
    }

    private func stage(_ code: String) {
        guard model.canPairCredentialHelper, model.credentialHelperPairID == nil, let acquisition, acquisition == scope,
              let pair = try? CredentialHandoffPair.parse(code, relayOrigin: CloudClient.originScope.canonicalOrigin) else {
            notice = "Couldn’t use this pairing code. Use a fresh code from your trusted helper for this Screenpunk environment."
            return
        }
        notice = nil
        pendingPair = .init(code: code, scope: acquisition, pairID: pair.pairID)
    }

    private func commitPair() {
        let selected = pendingPair
        pendingPair = nil
        guard let selected, selected.scope == scope, model.canPairCredentialHelper, model.credentialHelperPairID == nil else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            guard selected.scope == scope, model.canPairCredentialHelper, model.credentialHelperPairID == nil else { return }
            do {
                try await model.pairCredentialHelper(selected.code)
            } catch {
                if scope == selected.scope {
                    notice = "Couldn’t pair this helper. Check that the helper uses this Screenpunk environment and that the iPad is online, then try a new code."
                }
            }
        }
    }

    private func removePair() {
        let selectedPairID = removalPairID
        removalPairID = nil
        guard let selectedPairID, selectedPairID == model.credentialHelperPairID, let selectedScope = scope else { return }
        busy = true
        notice = nil
        Task { @MainActor in
            defer { busy = false }
            guard selectedScope == scope, selectedPairID == model.credentialHelperPairID else { return }
            do {
                try await model.forgetCredentialHelper()
            } catch {
                if scope == selectedScope {
                    notice = "Couldn’t remove the helper. Check the iPad’s connection to Screenpunk Cloud and try again."
                }
            }
        }
    }

    private static func readPairingFile(_ url: URL) throws -> String {
        guard url.isFileURL, url.pathExtension.lowercased() == "screenpunk-pair" else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor != -1 else { throw CocoaError(.fileReadNoPermission) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              (1...2048).contains(info.st_size),
              let bytes = try file.read(upToCount: 2049), (1...2048).contains(bytes.count),
              let code = String(data: bytes, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return code
    }
}
