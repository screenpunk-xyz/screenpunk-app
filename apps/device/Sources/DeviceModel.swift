import SwiftUI
import ScreenpunkApple
import ScreenpunkCore
import CryptoKit
import ScreenpunkLocalAuthoring
import ScreenpunkLocalTransport

@MainActor final class DeviceModel: ObservableObject {
    @Published var email: String?
    @Published var agentReady = false
    @Published var busy = false
    @Published var accountOperationInProgress = false
    @Published var message: String? {
        didSet { statusMessagePresentation.update(message) }
    }
    @Published private var statusMessagePresentation = StatusMessagePresentationState()
    var presentedStatusMessage: StatusMessagePresentationState.Message? { statusMessagePresentation.presentedMessage }
    var canDismissStatusMessage: Bool {
        statusMessagePresentation.canDismiss(busy: busy, requestPending: requestPending, routeChangeBlocked: routeChangeBlocked, canRetry: canRetry, canCancelRequest: canCancelRequest)
    }
    func dismissStatusMessage(id: UUID) {
        statusMessagePresentation.dismiss(id: id, busy: busy, requestPending: requestPending, routeChangeBlocked: routeChangeBlocked, canRetry: canRetry, canCancelRequest: canCancelRequest)
    }
    @Published var screen: ScreenLibrary.Saved?
    @Published var requestPending = false
    @Published var canCancelRequest = false
    @Published var progressCaption = "Your agent is working…"
    @Published var takingLonger = false
    @Published var canRetry = false
    @Published var preferenceRecords: [PreferenceRecordV1] = []
    @Published var inactiveDevicePreferences: [PreferenceRecordV1] = []
    @Published var preferenceConflicts: [AuthoringPreferenceConflict] = []
    @Published var preferenceSyncStatus: String?
    @Published private(set) var activeProfile: LocalProfileDescriptor?
    @Published private(set) var availableProfiles: [LocalProfileDescriptor] = []
    @Published private(set) var selectedRoute: AuthoringRoute = .local
    @Published private(set) var routePreference: AuthoringRoutePreference = .automatic
    @Published private(set) var cloudAgentReady = false
    @Published private(set) var resolvedAgentName: String?
    private var cloudSupportsV2 = false
    @Published private(set) var localAgent: LocalAgentConfiguration?
    @Published private(set) var localSettings: LocalAgentSettingsModel?
    private var profileRepository: LocalProfileRepository?
    private var configurationRepository: LocalAgentConfigurationRepository?
    private var localLedger: LocalDeliveryLedger?
    private let localVault = KeychainLocalCredentialStore()
    private var localTransport: LocalAuthoringTransport?
    private var localTransportV2: LocalAuthoringTransportV2?
    private var localTransportAuthoringProfileID: String?
    private var cloudAuthoringV2: AuthoringCoordinatorV2?
    private var localAuthoringV2: AuthoringCoordinatorV2?
    private var authoringV2: AuthoringCoordinatorV2? { currentRequestRoute == .local ? localAuthoringV2 : cloudAuthoringV2 }
    private let localConnectionLifecycle = LocalConnectionLifecycleBarrier()
    private var cloudAuthoring: AuthoringCoordinator?
    private var localAuthoring: AuthoringCoordinator?
    private var authoring: AuthoringCoordinator? { currentRequestRoute == .local ? localAuthoring : cloudAuthoring }
    var permissionOwner: String { activeProfile?.permissionOwner ?? "" }
    var hasProfile: Bool { activeProfile != nil }
    var canUseCloudRoute: Bool { cloudBindingMatches }
    var canSelectCloudRoute: Bool { cloudAccountMatches }
    var routeChangeBlocked: Bool { busy || pendingID != nil || library?.state.submissionKey != nil }
    private var currentRequestRoute: AuthoringRoute {
        if let id = pendingID ?? library?.state.submissionKey {
            if let route = library?.authoringRequestV2(id: id)?.delivery.route { return AuthoringRoute(rawValue: route) ?? selectedRoute }
            if let route = library?.authoringRequest(id: id)?.delivery.route { return AuthoringRoute(rawValue: route) ?? selectedRoute }
            if let record = try? localLedger?.record(requestID: id), record.profileID == activeProfile?.id { return .local }
        }
        return selectedRoute
    }
    private var cloudAccountMatches: Bool {
        guard let profile = activeProfile, let session = cloud.session else { return false }
        return profile.libraryOwner == session.user.id || profile.cloudBinding?.accountID == session.user.id
    }
    private var cloudBindingMatches: Bool {
        guard let binding = activeProfile?.cloudBinding, let session = cloud.session else { return false }
        return binding.accountID == session.user.id && binding.deviceID == session.deviceId && (session.profileID == nil || binding.profileID == session.profileID)
    }
    private var lastProgressAt = Date()
    private var warningDismissedAt = Date.distantPast
    private var cancelledLocally = Set<String>()
    @Published var assets: PackageAssetStore?
    @Published var settingsOpen = false
    @Published var settingsPage: DeviceSettingsPage = .overview
    @Published var canRollback = false
    @Published var manifestIssues: [String: String] = [:]
    @Published var installedManifests: [DashboardManifest] = []
    @Published var installedScreens: [ScreenLibrary.Saved] = []
    @Published var manifest: DashboardManifest?
    @Published var homeAssistant: HomeAssistantDeviceRuntime?
    @Published var publicReads: PublicReadSession?
    @Published var publicReadSessionKey = ""
    let cloud = CloudClient()
    private var library: ScreenLibrary?
    private var pendingID: String?
    private var pendingScreenID: String?
    private var consumedID: String?
    private var inventorySignature: String?
    private let connection = DeviceConnection()
    private var foreground = false
    private var connectionActive = false
    private var connectionGeneration = UUID()
    private var refreshTask: Task<Void, Never>?
    private var refreshNeeded = false
    private struct PreferenceSyncBinding: Equatable {
        let generation: UUID
        let library: ObjectIdentifier
        let profileID: String
        let libraryOwner: String
        let cloud: LocalCloudBinding
        // In-memory identity only; never encoded, logged, or included in diagnostics.
        let credential: String
        let sessionProfileID: String?
    }
    private let preferenceSyncPump = PreferenceSyncPump()
    private let preferenceSyncFlight = PreferenceSyncSingleFlight<PreferenceSyncBinding>()
    private var preferenceSyncBinding: PreferenceSyncBinding? {
        guard foreground, connectionActive,
              CloudPreferenceSyncEligibility.matches(profile: activeProfile, accountID: cloud.session?.user.id, deviceID: cloud.session?.deviceId, profileID: cloud.session?.profileID),
              let profile = activeProfile, let binding = profile.cloudBinding,
              let library, let session = cloud.session else { return nil }
        return .init(generation: connectionGeneration, library: ObjectIdentifier(library), profileID: profile.id, libraryOwner: profile.libraryOwner, cloud: binding, credential: session.accessToken, sessionProfileID: session.profileID)
    }
    init() {
        email = cloud.session?.user.email
        do {
            profileRepository = try LocalProfileRepository()
            configurationRepository = try LocalAgentConfigurationRepository()
            localLedger = try LocalDeliveryLedger()
            if let configurationRepository, let localLedger {
                do { localSettings = try LocalAgentSettingsModel(configurationRepository: configurationRepository, ledger: localLedger, vault: localVault, profileID: { [weak self] in self?.activeProfile?.id }, changed: { [weak self] in self?.reloadLocalAgent() }) }
                catch { message = "Local setup could not open: " + error.localizedDescription }
            }
            try openLibrary()
        } catch { message = "Could not open saved screens: \(error.localizedDescription)" }
    }
    func signIn() async {
        guard !accountOperationInProgress else { return }
        guard !routeChangeBlocked else { message = "Finish or cancel the current request before changing accounts."; return }
        accountOperationInProgress = true; defer { accountOperationInProgress = false }
        stopConnection()
        busy = true; defer { busy = pendingID != nil }
        do {
            let authenticated = try await cloud.signIn()
            detachAccountLibrary()
            _ = try profileRepository?.activateAccountProfile(accountID: authenticated.user.id, deviceID: authenticated.deviceId)
            email = authenticated.user.email; message = nil
            try openLibrary(); startConnection()
        }
        catch { message = error.localizedDescription; startConnection() }
    }
    func signOut() async {
        guard !accountOperationInProgress else { return }
        guard !routeChangeBlocked else { message = "Finish or cancel the current request before changing accounts."; return }
        accountOperationInProgress = true; defer { accountOperationInProgress = false }
        stopConnection()
        do { try await cloud.signOut(); message = nil }
        catch { message = "Signed out on this device. Cloud revocation could not be confirmed; disconnect it from your account when online." }
        email = nil
        do { try profileRepository?.signOut(); try openLibrary(); startConnection() }
        catch { message = error.localizedDescription }
        settingsOpen = false
    }
    /// Runs independently of Cloud I/O, including when outbound requests are stalled.
    func reconcileTemporary() {
        let settled = settleAcknowledgedPending()
        takingLonger = requestPending && Date().timeIntervalSince(max(lastProgressAt, warningDismissedAt)) >= 60
        if !settled, requestPending, let id = pendingID, let library {
            if let snapshot = library.authoringRequestV2(id: id) {
                if recoveryAction(snapshot, library: library) == .cancelExpired { cancelKnownRequest(id, timedOut: true) }
            } else if let deadline = library.state.requestDeadline, Date().timeIntervalSince1970 * 1000 >= deadline {
                cancelKnownRequest(id, timedOut: true)
            }
        }
        do { try library?.reconcileTemporary(); if screen?.id != library?.selected?.id { refreshScreen() } }
        catch { message = error.localizedDescription }
    }
    private func poll(generation: UUID) async -> Bool {
        if settleAcknowledgedPending() { return true }
        if currentRequestRoute == .local, pendingID != nil || routePreference == .local || !cloudAccountMatches { return await pollLocal(generation: generation) }
        guard cloudAccountMatches, let token = cloud.session?.accessToken, email != nil, foreground, generation == connectionGeneration else { return true }
        guard library != nil, authoring != nil else { agentReady = false; return true }
        do {
            try await cloud.enrollInstallation()
            guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
            try await flushCancellations()
            guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
            try await syncInventory()
            guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
            var preferencesSynced = await syncPreferencesWhenAvailable()
            guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
            let status: AgentStatus = try await cloud.call("api/device/status")
            guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
            if let profileID = status.profileID {
                let profileChanged = cloud.session?.profileID != profileID
                try cloud.rememberProfile(profileID)
                if profileChanged {
                    preferencesSynced = await syncPreferencesWhenAvailable() && preferencesSynced
                    guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
                }
            }
            if let profileID = status.profileID, let session = cloud.session {
                if let profile = activeProfile, profile.cloudBinding == nil, let library {
                    let binding = LocalCloudBinding(accountID: session.user.id, profileID: profileID, deviceID: session.deviceId)
                    try profileRepository?.validateLink(profileID: profile.id, binding: binding)
                    let linked = try library.linkLocalProfile(profile, to: binding)
                    try profileRepository?.adoptLinkedProfile(linked); activeProfile = linked
                } else {
                    activeProfile = try profileRepository?.activateCloudProfile(accountID: session.user.id, profileID: profileID, deviceID: session.deviceId)
                }
            }
            refreshPreferences()
            if cloudBindingMatches {
                try await syncInventory()
                preferencesSynced = await syncPreferencesWhenAvailable() && preferencesSynced
                guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
            }
            cloudAgentReady = status.agentReady && cloudBindingMatches
            cloudSupportsV2 = status.authoringCapabilities?.supportsV2 == true
            agentReady = routePreference == .automatic ? (localAgent != nil || cloudAgentReady) : cloudAgentReady
            if let command = status.command { await applyCommand(command) }
            guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
            if pendingID == nil, let latest = status.latestRequest, latest.id != consumedID, latest.id != library?.state.lastRequest {
                pendingID = latest.id
                try persistPending()
                // Canonical requests retain their original screen ID and immutable base revision.
            }
            if let id = pendingID {
                if library?.authoringRequestV2(id: id) != nil { return await pollAuthoringV2(generation: generation) }
                guard let authoring else { throw DeviceError.message("Local authoring storage is unavailable.") }
                if library?.authoringRequest(id: id) == nil {
                    let restored: AgentRequest = try await cloud.call("api/device/requests/\(id)", authoringVersion: 2)
                    guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
                    if let snapshot = restored.snapshotV2 {
                        guard snapshot.delivery.route == "cloud", snapshot.context.profileID == cloud.session?.profileID, snapshot.context.deviceID == cloud.session?.deviceId else { throw DeviceError.message("This request belongs to a different connection.") }
                        try library?.saveAuthoringRequest(snapshot)
                        return await pollAuthoringV2(generation: generation)
                    }
                    if let unsupported = restored.canonicalUnsupported {
                        try finishRequest(id, status: unsupported.code, failure: unsupported.message)
                        return preferencesSynced
                    }
                    guard let snapshot = restored.snapshot, snapshot.delivery.route == "cloud", snapshot.context.profileID == cloud.session?.profileID, snapshot.context.deviceID == cloud.session?.deviceId else {
                        throw DeviceError.message("This request has no matching authoring snapshot. Your screen is unchanged.")
                    }
                    try library?.saveAuthoringRequest(snapshot)
                }
                let delivery = try await authoring.reconcile(requestID: id)
                guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
                if cancelledLocally.contains(id) { cancelKnownRequest(id); return false }
                switch delivery {
                case .completed(let result):
                    let receipt: ApplicationReceiptV1
                    if library?.authoringRequest(id: id)?.context.screenID == "legacy" {
                        guard let library else { throw DeviceError.message("Local authoring storage is unavailable.") }
                        receipt = try library.rejectAuthoringResult(result, reason: "This request started before verified screen revisions were available. Please send your instructions again to edit the current screen.")
                    } else {
                        receipt = try authoring.apply(result)
                    }
                    requestPreferenceSync() // Native commit precedes any transport acknowledgement.
                    refreshScreen(); refreshPreferences()
                    message = receipt.status == "applied" ? (result.preferenceMutations?.isEmpty == false ? "Preference saved" : result.answer) : (receipt.message ?? "This result conflicts with a newer change. Your screen is unchanged.")
                    consumedID = id; pendingID = nil; busy = false; requestPending = false; canCancelRequest = false; takingLonger = false; canRetry = false
                    try persistPending()
                    try await syncInventory()
                    guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
                    preferencesSynced = await syncPreferencesWhenAvailable() && preferencesSynced
                case .deliveryUncertain(let failure), .needsAttention(let failure):
                    busy = true; requestPending = true; canCancelRequest = true; canRetry = false; progressCaption = failure
                case .ended(let status, let failure):
                    try finishRequest(id, status: status, failure: failure)
                case .pending(let progress):
                    if let deadline = progress.deadlineAt {
                        try library?.submissionAccepted(deadline: deadline)
                        if Date().timeIntervalSince1970 * 1000 >= deadline { cancelKnownRequest(id, timedOut: true); return false }
                    }
                    busy = true; requestPending = true; canCancelRequest = true; canRetry = false
                    progressCaption = progress.caption ?? "Your agent is working…"
                    lastProgressAt = Date(timeIntervalSince1970: (progress.updatedAt ?? Date().timeIntervalSince1970 * 1000) / 1000)
                }
            }
            return preferencesSynced
        } catch {
            guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
            agentReady = false
            if pendingID != nil { busy = true }
            message = (library?.state.cancelIntents?.isEmpty == false)
                ? "Result cancelled on this device. Cloud confirmation will retry when connected; the agent may still be running."
                : error.localizedDescription
            return false
        }
    }
    /// Resolve a new request before sealing source or preparing delivery. A prepared
    /// request never enters this resolver again, including after a send failure.
    func send(_ text: String) async {
        // First Cloud linking can change the wire profile while keeping the same
        // native descriptor. Rebind idle adapters before capturing any new request.
        if !busy, pendingID == nil, library?.state.submissionKey == nil, localAgent != nil,
           localTransportAuthoringProfileID != activeProfile?.authoringProfileID { reloadLocalAgent() }
        guard !busy, let library, let profile = activeProfile else { return }
        if let key = library.state.submissionKey {
            guard !cancelledLocally.contains(key) else { message = "This saved request was cancelled. Wait for cancellation confirmation before sending again."; requestRefresh(); return }
            guard library.state.submissionText == text else { message = "Your previous delivery is unresolved. Retry or cancel it first."; return }
            if let saved = library.authoringRequestV2(id: key) { await submitPreparedV2(saved, library: library); return }
            if let saved = library.authoringRequest(id: key) {
                selectedRoute = AuthoringRoute(rawValue: saved.delivery.route) ?? selectedRoute
                await sendV1(text); return
            }
            message = "The saved delivery needs attention. Cancel it before sending new instructions."; return
        }
        let generation = connectionGeneration
        let endpoint = try? configurationRepository?.load()
        let token = cloud.session?.accessToken
        let selectedScreen = screen?.revision
        busy = true; requestPending = true; canCancelRequest = false; message = nil; progressCaption = "Checking available agents…"
        do {
            try library.saveInstruction(text)
            let resolved = try await resolveNewRequest(requiresV2: screen != nil)
            guard self.library === library, activeProfile?.id == profile.id,
                  activeProfile?.authoringProfileID == profile.authoringProfileID,
                  activeProfile?.authoringDeviceID == profile.authoringDeviceID,
                  connectionGeneration == generation, cloud.session?.accessToken == token,
                  screen?.revision == selectedScreen, !Task.isCancelled else { throw CancellationError() }
            if resolved.route == .local {
                guard try localLedger?.unresolvedRecord() == nil else { throw DeviceError.message("An earlier local delivery is unresolved. Finish or cancel it before sending another request.") }
                guard let current = try configurationRepository?.load(), current.id == endpoint?.id,
                      current.hostKeySHA256 == endpoint?.hostKeySHA256,
                      current.credentialReference == endpoint?.credentialReference else { throw DeviceError.message("The computer connection changed. Send your saved instructions again after checking Agents.") }
            }
            selectedRoute = resolved.route
            resolvedAgentName = resolved.route == .local ? (localAgent?.name ?? "Local agent") : "Cloud agent"
            if resolved.version == 1 {
                busy = false; await sendV1(text); return
            }
            let base = try makeAuthoringRequest(text: text, library: library, route: resolved.route)
            let snapshot = try library.makeAuthoringRequestV2(from: base)
            // Pin + snapshot durability precede delivery state and any network turn.
            try library.prepareAuthoringRequest(snapshot, text: text, screen: screen?.artifact)
            pendingID = snapshot.requestID; pendingScreenID = snapshot.context.screenID
            busy = false
            await submitPreparedV2(snapshot, library: library)
        } catch {
            guard self.library === library, activeProfile?.id == profile.id else { return }
            busy = false; requestPending = false
            canRetry = true; canCancelRequest = library.state.submissionKey != nil
            message = error is CancellationError ? "The connection changed while checking agents. Your instructions are saved here; send them again when ready." : "Your instructions are saved here. " + error.localizedDescription
        }
    }
    private struct ResolvedRoute { let route: AuthoringRoute; let version: Int }
    private func resolveNewRequest(requiresV2: Bool) async throws -> ResolvedRoute {
        if routePreference != .cloud {
            let generation = connectionGeneration
            await localConnectionLifecycle.wait()
            guard foreground, generation == connectionGeneration, !Task.isCancelled else { throw CancellationError() }
        }
        let readiness: LocalAgentReadiness = routePreference == .cloud ? .unavailable(.notConfigured) : (await localTransportV2?.preflight() ?? .unavailable(.notConfigured))
        let local: NewRequestRoutePolicy.LocalState
        let repairMessage: String
        switch readiness {
        case .ready: local = .ready; repairMessage = ""
        case .repairRequired(let reason): local = .repairRequired; repairMessage = localRepairMessage(reason)
        case .unavailable(let reason):
            // An expired login or lost credential needs deliberate repair. Ordinary
            // network unavailability may choose Cloud for a new Automatic request.
            local = reason == .signInRequired || reason == .credentialsUnavailable ? .repairRequired : .unavailable
            repairMessage = "The paired computer needs sign-in or credential repair. Open Agents to reconnect before sending this request."
        }
        let initial = NewRequestRoutePolicy.resolve(preference: routePreference, local: local, cloud: cloudBindingMatches ? .unchecked : .notConfigured, requiresV2: requiresV2)
        func resolved(_ decision: NewRequestRoutePolicy.Decision) throws -> ResolvedRoute {
            switch decision {
            case .use(let route, let version): return .init(route: route, version: version)
            case .needsComputer: throw DeviceError.message("Your computer is unavailable. " + LocalAgentSettingsModel.unavailableGuidance(for: localAgent))
            case .repairComputer: throw DeviceError.message(repairMessage)
            case .connectCloud: throw DeviceError.message(routePreference == .cloud ? "Connect your Cloud agent in Agents." : "The computer is unavailable and no matching Cloud agent is configured. Reconnect the computer in Agents, or sign in to use Cloud.")
            case .listenCloud: throw DeviceError.message("Ask your Cloud agent to listen for requests, then retry.")
            case .updateCloud: throw DeviceError.message("Your Cloud agent needs the asset-preserving update before it can edit this screen. Refresh its Screenpunk tools or reconnect your computer.")
            case .checkCloud: throw DeviceError.message("Cloud readiness could not be checked. Retry shortly.")
            }
        }
        guard initial == .checkCloud else { return try resolved(initial) }
        let status: AgentStatus = try await cloud.call("api/device/status", authoringVersion: 2)
        guard status.profileID == activeProfile?.cloudBinding?.profileID else { throw DeviceError.message("The Cloud connection changed. Review your account connection.") }
        cloudAgentReady = status.agentReady; cloudSupportsV2 = status.authoringCapabilities?.supportsV2 == true
        if cloudAgentReady { agentReady = true }
        return try resolved(NewRequestRoutePolicy.resolve(preference: routePreference, local: local, cloud: status.agentReady ? .ready(supportsV2: cloudSupportsV2) : .notReady, requiresV2: requiresV2))
    }
    private func localRepairMessage(_ reason: LocalAgentRepairReason) -> String {
        switch reason {
        case .hostIdentityChanged: return "The computer’s SSH identity changed. Review its fingerprint in Agents → Advanced before reconnecting."
        case .wrongBinding: return "This computer connection changed. Review the paired agent before continuing."
        case .unsupportedVersion: return "Codex on the Mac is no longer a supported version. Review Mac setup in Agents."
        case .invalidCredentials: return "The Mac rejected this iPad’s connection credential. Pair again in Agents."
        case .missingConversationHistory: return "This conversation’s saved history is unavailable. Reconnect to reconcile it; Screenpunk has not resubmitted the request."
        case .unsafeConfiguration, .unsupportedProtocol: return "The Mac’s secure connection settings need review. Open Mac setup in Agents before continuing."
        }
    }
    /// An acknowledgement journal can commit before its caller observes success.
    /// Recover only an exact, unambiguous acknowledged receipt for this pending ID.
    @discardableResult private func settleAcknowledgedPending() -> Bool {
        guard let library, let id = pendingID, let state = library.state.authoring,
              let receipt = PreparedRequestRecoveryPolicy.acknowledgedReceipt(requestID: id, receipts: state.receipts, acknowledgedReceiptIDs: state.acknowledgedReceiptIDs) else { return false }
        do {
            try library.savePending(id: nil, screenID: nil, consumedID: id)
            pendingID = nil; pendingScreenID = nil; consumedID = id
            busy = false; requestPending = false; canCancelRequest = false; canRetry = false; takingLonger = false
            if message == nil { message = receipt.status == "applied" ? "Your result is saved on this device." : (receipt.message ?? "Your screen is unchanged.") }
            refreshScreen(); refreshPreferences()
        } catch { message = "Your result is saved. Final delivery state will be recovered when local storage is available." }
        return true
    }
    private func recoveryAction(_ snapshot: AuthoringRequestV2, library: ScreenLibrary) -> PreparedRequestRecoveryPolicy.Action {
        PreparedRequestRecoveryPolicy.action(requestID: snapshot.requestID,
            route: AuthoringRoute(rawValue: snapshot.delivery.route) ?? .cloud,
            deadlineAt: snapshot.deadlineAt, now: Int64(Date().timeIntervalSince1970 * 1000),
            hasReceipt: library.state.authoring?.receipts.values.contains(where: { $0.requestID == snapshot.requestID }) == true,
            submissionKey: library.state.submissionKey, cancelled: cancelledLocally.contains(snapshot.requestID))
    }
    private func submitPreparedV2(_ snapshot: AuthoringRequestV2, library: ScreenLibrary) async {
        if snapshot.delivery.route == "local" {
            let generation = connectionGeneration
            await localConnectionLifecycle.wait()
            guard foreground, self.library === library, generation == connectionGeneration, !Task.isCancelled else { return }
        }
        if pendingID == snapshot.requestID, settleAcknowledgedPending() { return }
        let route = AuthoringRoute(rawValue: snapshot.delivery.route) ?? .cloud
        guard let coordinator = route == .local ? localAuthoringV2 : cloudAuthoringV2 else { message = "Reconnect this request’s agent in Settings. Your instructions are saved."; return }
        switch recoveryAction(snapshot, library: library) {
        case .cancelExpired: cancelKnownRequest(snapshot.requestID, timedOut: true); return
        case .cancelled: message = "This request was cancelled. Its delivery will not be retried."; return
        case .acknowledgeReceipt, .reconcile:
            pendingID = snapshot.requestID
            _ = await pollAuthoringV2(generation: connectionGeneration)
            return
        case .retrySameRequest: break
        }
        let generation = connectionGeneration
        selectedRoute = route; resolvedAgentName = route == .local ? (localAgent?.name ?? "Local agent") : "Cloud agent"
        busy = true; requestPending = true; canCancelRequest = true; canRetry = false; takingLonger = false
        lastProgressAt = Date(); warningDismissedAt = .distantPast
        pendingID = snapshot.requestID; pendingScreenID = snapshot.context.screenID
        progressCaption = "Sending to \(resolvedAgentName ?? "your agent")…"
        do {
            try persistPending()
            let accepted = try await coordinator.submit(snapshot)
            guard self.library === library, generation == connectionGeneration else { return }
            if cancelledLocally.contains(accepted.requestID) { cancelKnownRequest(accepted.requestID); return }
            try library.submissionAccepted(deadline: Double(accepted.deadlineAt))
            progressCaption = "\(resolvedAgentName ?? "Your agent") is working on this screen…"
        } catch {
            guard self.library === library, generation == connectionGeneration else { return }
            // Once prepared, even failures before/after acceptance stay on this route.
            progressCaption = error.localizedDescription
            if route == .cloud, library.state.submissionKey == snapshot.requestID {
                busy = false; requestPending = false; canRetry = true; canCancelRequest = true
                message = "Cloud delivery could not be confirmed. Retry sends this same saved request to Cloud with its original request ID."
            }
            if route == .local, let localLedger {
                do {
                    if try localLedger.record(requestID: snapshot.requestID) == nil {
                        pendingID = nil; try persistPending()
                        busy = false; requestPending = false; canRetry = true; canCancelRequest = true
                        message = "The request is saved for this computer. Reconnect it and retry; it will keep the same agent."
                    }
                } catch { progressCaption = "Local delivery storage needs attention. Reconnect to check this request’s delivery." }
            }
        }
        requestRefresh()
    }
    private func pollAuthoringV2(generation: UUID) async -> Bool {
        if settleAcknowledgedPending() { return true }
        guard let library, let id = pendingID, let snapshot = library.authoringRequestV2(id: id), let coordinator = authoringV2 else { return true }
        resolvedAgentName = snapshot.delivery.route == "local" ? (localAgent?.name ?? "Local agent") : "Cloud agent"
        do {
            // A receipt can precede network acknowledgement at any crash boundary.
            if let receipt = library.state.authoring?.receipts.values.first(where: { $0.requestID == id }) {
                try await coordinator.acknowledge(receipt)
                guard self.library === library, generation == connectionGeneration else { return true }
                consumedID = id; pendingID = nil; busy = false; requestPending = false; canCancelRequest = false; canRetry = false; takingLonger = false
                try persistPending(); refreshScreen(); refreshPreferences(); return true
            }
            if recoveryAction(snapshot, library: library) == .cancelExpired { cancelKnownRequest(id, timedOut: true); return true }
            let delivery = try await coordinator.reconcile(requestID: id)
            guard self.library === library, generation == connectionGeneration, !Task.isCancelled else { return true }
            if cancelledLocally.contains(id) { return true }
            switch delivery {
            case .completed(let result):
                let receipt = try coordinator.apply(result)
                requestPreferenceSync() // Do not wait for the Mac/Cloud acknowledgement.
                refreshScreen(); refreshPreferences()
                message = receipt.status == "applied" ? (result.preferenceMutations?.isEmpty == false ? "Preference saved" : result.answer) : (receipt.message ?? "Your screen is unchanged.")
                // Keep pending identity until acknowledgement; restart can finish the exact receipt.
                try await coordinator.acknowledge(receipt)
                guard self.library === library, generation == connectionGeneration else { return true }
                consumedID = id; pendingID = nil; busy = false; requestPending = false; canCancelRequest = false; canRetry = false; takingLonger = false
                try persistPending()
            case .ended(let status, let failure): try finishRequest(id, status: status, failure: failure)
            case .pending(let progress):
                if let deadline = progress.deadlineAt { try library.submissionAccepted(deadline: deadline) }
                busy = true; requestPending = true; canCancelRequest = true; canRetry = false
                progressCaption = progress.caption ?? "\(resolvedAgentName ?? "Your agent") is working…"
                if let updated = progress.updatedAt { lastProgressAt = Date(timeIntervalSince1970: updated / 1000) }
            case .deliveryUncertain(let failure), .needsAttention(let failure):
                busy = true; requestPending = true; canCancelRequest = true; canRetry = false; progressCaption = failure
            }
            return pendingID == nil
        } catch {
            guard self.library === library, generation == connectionGeneration else { return true }
            progressCaption = error.localizedDescription; canCancelRequest = true
            if snapshot.delivery.route == "cloud", library.state.submissionKey == id {
                busy = false; requestPending = false; canRetry = true
                message = "Cloud delivery could not be confirmed. Retry keeps this same Cloud request and request ID."
            } else { busy = true; requestPending = true }
            return false
        }
    }
    func selectRoutePreference(_ preference: AuthoringRoutePreference) {
        guard !routeChangeBlocked, let profile = activeProfile else { return }
        do {
            if preference == .cloud, !cloudAccountMatches { throw DeviceError.message("Sign in to connect your Cloud agent first.") }
            try profileRepository?.setRoutePreference(preference, profileID: profile.id)
            activeProfile?.routePreference = preference; routePreference = preference
            if preference == .local { selectedRoute = .local }
            else if preference == .cloud { selectedRoute = .cloud }
            else { selectedRoute = localAgent == nil && cloudBindingMatches ? .cloud : .local }
            availableProfiles = try profileRepository?.snapshot().profiles ?? []
            startConnection()
        } catch { message = error.localizedDescription }
    }
    private func sendV1(_ text: String) async {
        if selectedRoute == .local { await sendLocal(text); return }
        guard cloudBindingMatches, agentReady, !busy, let session = cloud.session, let library, let authoring else { return }
        if let previousText = library.state.submissionText, previousText != text {
            message = "The previous delivery is unresolved. Retry that request before sending new instructions."
            canRetry = true; requestRefresh(); return
        }
        let generation = connectionGeneration
        busy = true; requestPending = true; canCancelRequest = false; takingLonger = false; canRetry = false
        lastProgressAt = Date(); warningDismissedAt = .distantPast
        progressCaption = "Sending your instructions…"; message = nil
        do {
            let snapshot: AuthoringRequestV1
            if let key = library.state.submissionKey, let saved = library.authoringRequest(id: key) { snapshot = saved }
            else {
                try? await syncInventory()
                guard cloud.session?.accessToken == session.accessToken, self.library === library, generation == connectionGeneration else { return }
                _ = await syncPreferencesWhenAvailable()
                guard cloud.session?.accessToken == session.accessToken, self.library === library, generation == connectionGeneration else { return }
                snapshot = try makeAuthoringRequest(text: text, session: session, library: library)
                pendingScreenID = snapshot.context.screenID
                try library.saveSubmission(key: snapshot.requestID, text: text, screen: screen?.artifact)
                try persistPending()
            }
            let accepted = try await authoring.submit(snapshot)
            guard cloud.session?.accessToken == session.accessToken, self.library === library, generation == connectionGeneration else { return }
            if cancelledLocally.contains(accepted.requestID) { cancelKnownRequest(accepted.requestID); return }
            try library.submissionAccepted(deadline: Double(accepted.deadlineAt))
            pendingID = accepted.requestID; try persistPending()
            canCancelRequest = true; progressCaption = "Your agent is working on this screen…"; requestRefresh()
        } catch {
            guard cloud.session?.accessToken == session.accessToken, self.library === library, generation == connectionGeneration else { return }
            busy = false; requestPending = false; canRetry = true; canCancelRequest = library.state.submissionKey != nil; message = error.localizedDescription; requestRefresh()
        }
    }
    private func makeAuthoringRequest(text: String, session: DeviceSession? = nil, library: ScreenLibrary, route: AuthoringRoute? = nil) throws -> AuthoringRequestV1 {
        guard let profile = activeProfile else { throw DeviceError.message("Your profile is unavailable.") }
        let route = route ?? selectedRoute
        if route == .cloud, !cloudBindingMatches { throw DeviceError.message("Cloud is still confirming your profile. Try again shortly.") }
        let profileID = profile.authoringProfileID
        let deviceID = profile.authoringDeviceID
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let screenID = screen?.id ?? UUID().uuidString
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let size = window?.bounds.size ?? UIScreen.main.bounds.size
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let services = AuthoringContract.serviceCatalog.map { definition in
            let unknown = AuthoringCapabilityStateV1(state: "unknown", observedAt: now)
            var service = AuthoringServiceV1(id: definition.id, provider: definition.provider, operations: definition.operations, supported: .init(state: "yes", observedAt: now), configured: unknown, authorized: unknown, entitled: unknown, reachable: unknown)
            switch definition.provider {
            case "home":
                let vault = HomeAssistantDeviceVault()
                let configured = vault.credentialStatus(owner: permissionOwner) != nil
                let authorized = manifest.map { vault.isConfigured(owner: permissionOwner, dashboardID: $0.dashboardId, revision: $0.revision) } ?? false
                service.configured = .init(state: configured ? "yes" : "no", observedAt: now)
                service.authorized = .init(state: authorized ? "yes" : "no", observedAt: now)
            case "googleTV":
                let ready = manifest.map { DeviceConnectionReadiness.television(dashboardID: $0.dashboardId) } ?? false
                service.configured = .init(state: ready ? "yes" : "no", observedAt: now)
            case "googleCalendar":
                let ready = manifest.map { DeviceConnectionReadiness.calendar(dashboardID: $0.dashboardId) } ?? false
                service.configured = .init(state: ready ? "yes" : "no", observedAt: now)
            case "appleMaps":
                service.configured = .init(state: "yes", observedAt: now)
            case "publicHTTP":
                let allowed = manifest.map { publicDataAllowed($0) && $0.connections.contains { $0.publicHTTP != nil } } ?? false
                service.authorized = .init(state: allowed ? "yes" : "no", observedAt: now)
            default: service.supported = .init(state: "no", observedAt: now)
            }
            return service
        }
        let source = screen.map { AuthoringScreen(title: $0.artifact.title, entry: $0.artifact.entry, files: $0.artifact.files.map { .init(path: $0.path, content: $0.content) }) }
        return try AuthoringContract.seal(AuthoringRequestV1(requestID: UUID().uuidString, createdAt: now, deadlineAt: now + 10 * 60 * 1000, designGuidance: AuthoringContract.designGuidance, runtime: AuthoringContract.runtime, services: services, preferences: library.preferences(profileID: profileID, deviceID: deviceID, screenID: screenID), context: .init(profileID: profileID, deviceID: deviceID, screenID: screenID, baseRevision: screen?.revision, userRequest: text, currentScreen: source, viewport: .init(width: size.width, height: size.height, scale: scale, orientation: size.width > size.height ? "landscape" : "portrait")), delivery: .init(route: route.rawValue)))
    }
    func keepWaiting() { warningDismissedAt = Date(); takingLonger = false }
    private func finishRequest(_ id: String, status: String, failure: String?) throws {
        try library?.retireAuthoringRequest(id: id)
        message = status == "timed_out" ? "This request timed out. Your screen is unchanged." : (failure ?? "Request ended. Your screen is unchanged.")
        canRetry = status != "cancelled" && status != "legacy_payload_unsupported"
        consumedID = id; pendingID = nil; busy = false; requestPending = false; canCancelRequest = false; takingLonger = false
        try persistPending()
    }
    func retryRequest() {
        guard !busy, !requestPending, let library else { return }
        if let id = pendingID ?? library.state.submissionKey, let saved = library.authoringRequestV2(id: id) {
            guard !cancelledLocally.contains(id) else { message = "This request was cancelled. Wait for confirmation before sending again."; requestRefresh(); return }
            Task { await submitPreparedV2(saved, library: library) }
            return
        }
        guard let text = library.state.lastInstruction else { return }
        Task { await send(text) }
    }
    func cancelRequest() {
        guard canCancelRequest, let id = pendingID ?? library?.state.submissionKey else { return }
        cancelKnownRequest(id)
    }
    private func cancelKnownRequest(_ id: String, timedOut: Bool = false) {
        cancelledLocally.insert(id)
        let route = currentRequestRoute
        // Cancellation retires the native source snapshot. Capture its adapter
        // first so the ledger-bound remote interruption keeps the same version.
        let isV2 = library?.authoringRequestV2(id: id) != nil || (try? localLedger?.record(requestID: id))?.contractVersion == 2
        let cancelV2 = isV2 ? localAuthoringV2 : nil
        let cancelV1 = localAuthoring
        do {
            try library?.cancelRequest(id, route: route)
            if route == .local, try localLedger?.record(requestID: id) != nil { try localLedger?.cancel(requestID: id) }
        }
        catch { message = "Result blocked here, but cancellation could not be saved: \(error.localizedDescription)"; requestRefresh(); return }
        pendingID = nil; consumedID = id; busy = false; requestPending = false; canCancelRequest = false; takingLonger = false; canRetry = timedOut
        message = timedOut ? "This request timed out. Your screen is unchanged." : (route == .local ? "Result cancelled on this device. The Mac may still be finishing its turn." : "Result cancelled on this device. Waiting to confirm with Cloud; the agent may still be running.")
        if route == .local {
            if let cancelV2 { Task { try? await cancelV2.cancel(requestID: id) } }
            else if let cancelV1 { Task { try? await cancelV1.cancel(requestID: id) } }
        }
        requestRefresh()
    }
    private func flushCancellations() async throws {
        guard let library, let token = cloud.session?.accessToken else { return }
        guard cloudBindingMatches, let authoring = cloudAuthoring else { return }
        for id in library.state.cancelIntents ?? [] {
            if library.authoringRequestV2(id: id) != nil, let cloudAuthoringV2 { try await cloudAuthoringV2.cancel(requestID: id) }
            else { try await authoring.cancel(requestID: id) }
            guard self.library === library, cloud.session?.accessToken == token, !Task.isCancelled else { throw CancellationError() }
            try library.acknowledgeCancellation(id)
            if !requestPending && !canRetry { message = "Request cancelled here. Your screen is unchanged." }
        }
    }
    private func syncPreferencesAndReceipts() async throws {
        guard let binding = preferenceSyncBinding, let library, let session = cloud.session else { return }
        var deferredFailure: Error?
        func requireCurrent() throws {
            guard self.library === library, preferenceSyncBinding == binding,
                  cloud.session?.accessToken == session.accessToken,
                  cloud.session?.user.id == session.user.id, cloud.session?.deviceId == session.deviceId,
                  cloud.session?.profileID == session.profileID, !Task.isCancelled else { throw CancellationError() }
        }
        try requireCurrent()
        if let authoring = cloudAuthoring {
            for receipt in library.pendingReceipts(deviceID: session.deviceId) {
                guard (library.authoringRequestV2(id: receipt.requestID)?.delivery.route ?? library.authoringRequest(id: receipt.requestID)?.delivery.route) != "local" else { continue }
                try requireCurrent()
                do {
                    if library.authoringRequestV2(id: receipt.requestID) != nil, let cloudAuthoringV2 { try await cloudAuthoringV2.acknowledge(receipt) }
                    else { try await authoring.acknowledge(receipt) }
                }
                catch DeviceError.http(let status, let text) where (400..<500).contains(status) { deferredFailure = DeviceError.http(status, text) }
                try requireCurrent()
            }
        }
        guard let profileID = session.profileID else { return }
        let conflictsAwaitingReview = Set(library.preferenceConflicts.map(\.id))
        for entry in library.preferenceOutbox where !conflictsAwaitingReview.contains(entry.record.id) && (entry.record.scope != "device" || entry.record.targetID == session.deviceId) {
            try requireCurrent()
            let response: PreferenceSyncResponse
            do {
                response = try await cloud.call("api/device/preferences/sync", method: "POST", body: ["operationID": entry.id, "profileID": profileID, "mutations": try CloudAuthoringTransport.object([entry.mutation]), "origins": [entry.record.id: entry.record.originRequestID]])
            } catch DeviceError.http(let status, let text) where (400..<500).contains(status) {
                try requireCurrent(); deferredFailure = DeviceError.http(status, text); continue
            }
            try requireCurrent()
            guard response.operationID == entry.id else { throw DeviceError.message("Cloud did not confirm preference synchronization.") }
            try library.applyPreferenceSync(records: response.records, accepted: try response.acceptedMap(), sent: [entry], conflicts: try response.conflictMap(), profileID: profileID, deviceID: session.deviceId)
        }
        let operationID = UUID().uuidString
        let response: PreferenceSyncResponse = try await cloud.call("api/device/preferences/sync", method: "POST", body: ["operationID": operationID, "profileID": profileID, "mutations": []])
        try requireCurrent()
        guard response.operationID == operationID else { throw DeviceError.message("Cloud did not confirm preference synchronization.") }
        try library.applyPreferenceSync(records: response.records, accepted: [:], sent: [], conflicts: try response.conflictMap(), profileID: profileID, deviceID: session.deviceId)
        refreshPreferences()
        if let deferredFailure { throw deferredFailure }
    }
    /// Foreground idle pulls run once a minute even with Local selected. Local
    /// changes/notices wake sooner; failures retry independently with bounded backoff.
    private func requestPreferenceSync() {
        guard preferenceSyncBinding != nil else { preferenceSyncPump.cancel(); return }
        preferenceSyncPump.wake { [weak self] in
            guard let self else { return true }
            return await self.syncPreferencesWhenAvailable()
        }
    }
    /// Cloud polling and the independent pump share exactly one scoped sync flight.
    private func syncPreferencesWhenAvailable() async -> Bool {
        guard let binding = preferenceSyncBinding else { return true }
        return await preferenceSyncFlight.run(binding: binding) { [weak self] in
            guard let self, self.preferenceSyncBinding == binding else { return true }
            return await self.performPreferenceSync(binding: binding)
        }
    }
    private func performPreferenceSync(binding: PreferenceSyncBinding) async -> Bool {
        guard preferenceSyncBinding == binding, !Task.isCancelled else { return true }
        let token = cloud.session?.accessToken
        do {
            // Enrollment is account maintenance, independent of whether an agent is ready.
            try await cloud.enrollInstallation()
            guard preferenceSyncBinding == binding, cloud.session?.accessToken == token, !Task.isCancelled else {
                // Enrollment can fill a previously nil profile ID. Start a fresh
                // exact session flight immediately rather than waiting for idle cadence.
                requestPreferenceSync(); return true
            }
            try await syncPreferencesAndReceipts()
            guard preferenceSyncBinding == binding, cloud.session?.accessToken == token, !Task.isCancelled else { return true }
            preferenceSyncStatus = nil
            return true
        } catch {
            guard preferenceSyncBinding == binding, cloud.session?.accessToken == token, !Task.isCancelled else { return true }
            preferenceSyncStatus = "Cloud synchronization will retry. You can continue using preferences saved on this device."
            return false
        }
    }
    private func refreshPreferences() {
        let deviceID = activeProfile?.authoringDeviceID
        let records = library?.preferences ?? []
        inactiveDevicePreferences = records.filter { $0.scope == "device" && $0.targetID != deviceID }
        preferenceRecords = records.filter { $0.scope != "device" || $0.targetID == deviceID }
        preferenceConflicts = (library?.preferenceConflicts ?? []).filter { $0.local.scope != "device" || $0.local.targetID == deviceID }
    }
    func preferenceValueText(_ record: PreferenceRecordV1) -> String {
        switch record.value {
        case .string(let value): return value
        case .bool(let value): return value ? "Yes" : "No"
        case .number(let value): return value.formatted()
        case .null: return "No value"
        default: return "Unsupported value"
        }
    }
    func editPreference(_ record: PreferenceRecordV1, value: AuthoringJSONValue) throws {
        guard let library else { throw DeviceError.message("Local preference storage is unavailable.") }
        guard record.scope != "device" || record.targetID == activeProfile?.authoringDeviceID else { throw DeviceError.message("This preference belongs to a previous device connection.") }
        guard library.preferences.contains(record) else { throw DeviceError.message("This preference changed. Reopen it to review the current value before saving.") }
        switch value {
        case .array, .object: throw DeviceError.message("Choose text, a number, yes or no, or no value.")
        default: break
        }
        try library.editPreference(id: record.id, value: value, expectedRevision: record.revision)
        requestPreferenceSync()
        refreshPreferences(); message = "Preference saved"; requestRefresh()
    }
    func deletePreference(_ record: PreferenceRecordV1) {
        do {
            guard let library, library.preferences.contains(record) else { throw DeviceError.message("This preference changed. Review the current value before deleting it.") }
            guard record.scope != "device" || record.targetID == activeProfile?.authoringDeviceID else { throw DeviceError.message("This preference belongs to a previous device connection.") }
            try library.deletePreference(id: record.id, expectedRevision: record.revision)
            requestPreferenceSync()
            refreshPreferences(); message = "Preference deleted"; requestRefresh()
        } catch { message = error.localizedDescription }
    }
    func resolvePreference(_ id: String, keepLocal: Bool) {
        do {
            guard let library, let conflict = library.preferenceConflicts.first(where: { $0.id == id }) else { throw DeviceError.message("This conflict no longer exists. Review the current preferences.") }
            guard conflict.local.scope != "device" || conflict.local.targetID == activeProfile?.authoringDeviceID else { throw DeviceError.message("This preference belongs to a previous device connection.") }
            if keepLocal { try library.keepLocalPreference(id: id) }
            else { try library.acceptRemotePreference(id: id) }
            requestPreferenceSync()
            refreshPreferences(); requestRefresh()
        } catch { message = error.localizedDescription }
    }
    func selectScreen(_ id: String) {
        guard let library, let target = library.state.screens.firstIndex(where: { $0.id == id }) else { return }
        let current = library.state.screens.firstIndex(where: { $0.id == library.state.selectedID }) ?? 0
        do { try library.select(offset: target - current); refreshScreen(); settingsOpen = false }
        catch { message = error.localizedDescription }
    }
    func removeScreen(_ id: String) {
        guard !busy else { return }
        do { try library?.remove(id); refreshScreen() }
        catch { message = error.localizedDescription }
    }
    struct SetupRequirement {
        let name: String
        let page: DeviceSettingsPage
    }
    var missingConnections: [SetupRequirement] {
        guard let screen else { return [] }
        if manifestIssues[screen.id] != nil { return [.init(name: "Screen connection configuration", page: .screens)] }
        guard let manifest else { return [] }
        return manifest.connections.filter(\.required).compactMap { connection in
            if connection.publicHTTP != nil {
                return publicDataAllowed(manifest) ? nil : .init(name: connection.alias, page: .publicData)
            }
            switch connection.alias {
            case "home":
                let configured = HomeAssistantDeviceVault().isConfigured(owner: permissionOwner, dashboardID: manifest.dashboardId, revision: manifest.revision)
                return configured ? nil : .init(name: "Home Assistant", page: .home)
            case "googleTV":
                return DeviceConnectionReadiness.television(dashboardID: manifest.dashboardId) ? nil : .init(name: "Google TV", page: .television)
            case "googleCalendar", "google-calendar":
                return DeviceConnectionReadiness.calendar(dashboardID: manifest.dashboardId) ? nil : .init(name: "Google Calendar", page: .calendar)
            case "appleMaps": return nil // Native built-in provider, no account setup.
            default: return .init(name: "Unsupported connection: " + connection.alias, page: .screens)
            }
        }
    }
    func openConnectionSettings() {
        settingsPage = missingConnections.first?.page ?? .screens
        settingsOpen = true
    }
    private func publicApprovalKey(_ manifest: DashboardManifest) -> String? {
        guard let owner = activeProfile?.permissionOwner else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(manifest.connections.filter { $0.publicHTTP != nil }) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "screenpunk.publicReads.\(owner).\(manifest.dashboardId).\(digest)"
    }
    func publicDataAllowed(_ manifest: DashboardManifest) -> Bool {
        publicApprovalKey(manifest).map { UserDefaults.standard.bool(forKey: $0) } ?? false
    }
    func setPublicDataAllowed(_ allowed: Bool, for manifest: DashboardManifest) {
        guard let key = publicApprovalKey(manifest) else { return }
        UserDefaults.standard.set(allowed, forKey: key)
        refreshScreen()
    }
    private func refreshPublicReads() {
        let approved = manifest.flatMap { publicDataAllowed($0) && $0.connections.contains(where: { $0.publicHTTP != nil }) ? $0 : nil }
        let key = approved.map { (publicApprovalKey($0) ?? "") + ":" + $0.revision } ?? ""
        guard key != publicReadSessionKey else { return }
        publicReads?.cancel(); publicReads = nil; publicReadSessionKey = key
        if let approved {
            do { publicReads = try PublicReadSession(provisioning: PublicReadProvisioning(manifest: approved)) }
            catch { message = "This screen’s public data configuration is invalid." }
        }
    }
    func manifests(requiring aliases: Set<String>) -> [DashboardManifest] {
        installedManifests.filter { $0.connections.contains { aliases.contains($0.alias) } }
    }
    func swipe(_ offset: Int) { do { try library?.select(offset: offset); refreshScreen() } catch { message = error.localizedDescription } }
    func newScreen() { do { try library?.newScreen(); refreshScreen(); settingsOpen = false } catch { message = error.localizedDescription } }
    func rollback() { do { try library?.rollback(); refreshScreen(); settingsOpen = false } catch { message = error.localizedDescription } }
    private func syncInventory() async throws {
        guard cloudBindingMatches, let library else { return }
        var body: [String: Any] = ["screens": library.state.screens.map { ["id": $0.id, "title": $0.artifact.title] }]
        if let id = library.state.selectedID { body["selectedID"] = id }
        let signature = String(data: try JSONSerialization.data(withJSONObject: body, options: .sortedKeys), encoding: .utf8)!
        guard signature != inventorySignature else { return }
        let _: EmptyResponse = try await cloud.call("api/device/screens", method: "POST", body: body)
        guard self.library === library, !Task.isCancelled else { return }
        inventorySignature = signature
    }
    private func applyCommand(_ command: AgentStatus.Command) async {
        let token = cloud.session?.accessToken
        var acknowledgement: [String: Any] = ["status": "applied"]
        do {
            guard let library else { throw DeviceError.message("Local screen storage unavailable.") }
            guard command.expiresAt > Date().timeIntervalSince1970 * 1000 else { throw DeviceError.message("Screen command expired.") }
            if command.type == "activate", let id = command.screenID {
                try library.activateTemporarily(id: command.id, screenID: id, expiresAt: Date(timeIntervalSince1970: command.expiresAt / 1000))
            } else if command.type == "end", let id = command.activationID {
                try library.endTemporary(id: id)
            } else { throw DeviceError.message("Unsupported screen command.") }
            refreshScreen()
        } catch { acknowledgement = ["status": "failed", "error": error.localizedDescription] }
        do { let _: EmptyResponse = try await cloud.call("api/device/commands/\(command.id)/ack", method: "POST", body: acknowledgement) }
        catch { guard cloud.session?.accessToken == token, !Task.isCancelled else { return }; message = "Screen command handled locally; acknowledgement will retry when connected." }
    }
    func setForeground(_ active: Bool) {
        guard active != foreground else { return }
        foreground = active
        if active { startConnection() } else { stopConnection() }
    }
    private func startConnection() {
        guard foreground else { return }
        stopConnection()
        // This independent pump does not open a Cloud authoring channel or consume
        // commands/results when Local is selected. Its idle pulls also find remote
        // preference changes, which do not currently emit socket invalidations.
        connectionActive = true
        requestPreferenceSync()
        if currentRequestRoute == .local, pendingID != nil || routePreference == .local || !cloudAccountMatches {
            connectionActive = true; agentReady = localAgent != nil
            requestRefresh(); return
        }
        guard cloudAccountMatches, let token = cloud.session?.accessToken else { agentReady = false; return }
        connectionActive = true
        let generation = connectionGeneration
        connection.start(token: token, changed: { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }
            self.requestRefresh()
        }, disconnected: { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }
            self.agentReady = false
        })
    }
    private func stopConnection() {
        connectionActive = false
        connectionGeneration = UUID()
        connection.stop()
        let previousV1 = localTransport, previousV2 = localTransportV2
        if previousV1 != nil || previousV2 != nil {
            localConnectionLifecycle.enqueue {
                await previousV2?.disconnect()
                await previousV1?.disconnect()
            }
        }
        refreshTask?.cancel(); refreshTask = nil; refreshNeeded = false
        preferenceSyncPump.cancel()
        preferenceSyncFlight.cancel()
    }
    /// One in-flight reconciliation plus one trailing refresh, regardless of notice volume.
    /// Transient HTTP failures retry with bounded backoff even when the socket stays open.
    private func requestRefresh() {
        guard foreground, connectionActive else { return }
        requestPreferenceSync()
        refreshNeeded = true
        guard refreshTask == nil else { return }
        let generation = connectionGeneration
        refreshTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                guard let self, self.foreground, self.connectionGeneration == generation else { return }
                self.refreshNeeded = false
                let success = await self.poll(generation: generation)
                guard !Task.isCancelled, self.connectionGeneration == generation else { return }
                if !success {
                    failures = min(failures + 1, 6)
                    do { try await Task.sleep(nanoseconds: UInt64(min(60, pow(2, Double(failures)) * Double.random(in: 0.75...1.25)) * 1_000_000_000)) }
                    catch { return }
                    self.refreshNeeded = true
                } else { failures = 0 }
                if !self.refreshNeeded { self.refreshTask = nil; return }
            }
        }
    }
    private func openLibrary() throws {
        guard let profileRepository else { throw DeviceError.message("Local identity storage is unavailable.") }
        var profile: LocalProfileDescriptor
        if let selected = try profileRepository.snapshot().activeProfile { profile = selected }
        else if let session = cloud.session { profile = try profileRepository.activateAccountProfile(accountID: session.user.id, deviceID: session.deviceId) }
        else { profile = try profileRepository.createLocalProfile() }
        let opened = try ScreenLibrary(profile: profile)
        if var linked = opened.linkedProfile {
            guard linked.id == profile.id, linked.libraryOwner == profile.libraryOwner, linked.permissionOwner == profile.permissionOwner else { throw DeviceError.message("This saved library belongs to another profile.") }
            // Recover an interrupted binding commit, preserving a newer route choice or device enrollment.
            if profile.cloudBinding == nil {
                linked.preferredRoute = profile.preferredRoute
                linked.routePreference = profile.routePreference
                try profileRepository.adoptLinkedProfile(linked); profile = linked
            }
        }
        if let session = cloud.session, let profileID = session.profileID,
           profile.libraryOwner == session.user.id || profile.cloudBinding?.accountID == session.user.id {
            if profile.cloudBinding == nil {
                let binding = LocalCloudBinding(accountID: session.user.id, profileID: profileID, deviceID: session.deviceId)
                try profileRepository.validateLink(profileID: profile.id, binding: binding)
                profile = try opened.linkLocalProfile(profile, to: binding)
                try profileRepository.adoptLinkedProfile(profile)
            } else {
                profile = try profileRepository.activateCloudProfile(accountID: session.user.id, profileID: profileID, deviceID: session.deviceId)
            }
        }
        activeProfile = profile; selectedRoute = profile.preferredRoute; routePreference = profile.routePreference
        availableProfiles = try profileRepository.snapshot().profiles
        let previousPending = opened.state.pendingID ?? opened.state.submissionKey
        try opened.activateAuthoringDevice(deviceID: profile.authoringDeviceID)
        if previousPending != nil, opened.state.pendingID == nil, opened.state.submissionKey == nil {
            message = "An earlier request belongs to a previous device connection. Your screens are unchanged. Send your instructions again to continue."
        }
        library = opened
        func coordinator(_ transport: any AuthoringTransport) -> AuthoringCoordinator {
            let requireCurrent: () throws -> Void = { [weak self] in
                guard let self, self.library === opened, self.activeProfile?.id == profile.id else { throw DeviceError.message("Your active profile changed.") }
            }
            return AuthoringCoordinator(transport: transport, persistRequest: { request in
                try requireCurrent(); try opened.saveAuthoringRequest(request)
            }, applyResult: { result in
                try requireCurrent(); return try opened.applyAuthoringResult(result)
            }, persistCancellation: { id in
                try requireCurrent(); try opened.cancelRequest(id)
            }, acknowledged: { receipt in
                try requireCurrent(); try opened.acknowledgeReceipt(receipt)
            })
        }
        func coordinatorV2(_ transport: any AuthoringTransportV2) -> AuthoringCoordinatorV2 {
            let requireCurrent: () throws -> Void = { [weak self] in
                guard let self, self.library === opened, self.activeProfile?.id == profile.id else { throw DeviceError.message("Your active connection changed.") }
            }
            return AuthoringCoordinatorV2(transport: transport, persistRequest: { request in
                try requireCurrent(); try opened.saveAuthoringRequest(request)
            }, applyResult: { result in
                try requireCurrent(); return try opened.applyAuthoringResult(result)
            }, persistCancellation: { id in
                try requireCurrent(); try opened.cancelRequest(id)
            }, acknowledged: { receipt in
                try requireCurrent(); try opened.acknowledgeReceipt(receipt)
            })
        }
        cloudAuthoring = coordinator(CloudAuthoringTransport(cloud: cloud))
        cloudAuthoringV2 = coordinatorV2(CloudAuthoringTransportV2(cloud: cloud))
        localAgent = try configurationRepository?.load()
        localTransportAuthoringProfileID = profile.authoringProfileID
        if let configurationRepository, let localLedger, localAgent != nil {
            let transport = LocalAuthoringTransport(profileID: profile.id, authoringProfileID: profile.authoringProfileID, configurationRepository: configurationRepository, ledger: localLedger, credentialStore: localVault, requestLookup: { [weak opened] id in opened?.authoringRequest(id: id) })
            localTransport = transport; localAuthoring = coordinator(transport)
            let transportV2 = LocalAuthoringTransportV2(profileID: profile.id, authoringProfileID: profile.authoringProfileID, configurationRepository: configurationRepository, ledger: localLedger, credentialStore: localVault, requestLookup: { [weak opened] id in opened?.authoringRequestV2(id: id) })
            localTransportV2 = transportV2; localAuthoringV2 = coordinatorV2(transportV2)
        } else { localTransport = nil; localAuthoring = nil; localTransportV2 = nil; localAuthoringV2 = nil }
        refreshPreferences()
        pendingID = opened.state.pendingID
        if pendingID == nil, let key = opened.state.submissionKey, (opened.authoringRequestV2(id: key)?.delivery.route ?? opened.authoringRequest(id: key)?.delivery.route) == "local" { pendingID = key }
        pendingScreenID = opened.state.pendingScreenID; consumedID = opened.state.consumedID
        cancelledLocally = Set(opened.state.cancelledRequests ?? [])
        if let outstanding = try localLedger?.unresolvedRecord(), outstanding.profileID == profile.id {
            if cancelledLocally.contains(outstanding.requestID) { try localLedger?.cancel(requestID: outstanding.requestID) }
            else if pendingID == nil { pendingID = outstanding.requestID; try persistPending() }
        }
        inventorySignature = nil; busy = pendingID != nil; requestPending = busy; canCancelRequest = busy || opened.state.submissionKey != nil
        canRetry = opened.state.submissionKey != nil && currentRequestRoute == .cloud
        if canRetry, message == nil { message = "Your previous instructions are saved. Retry to confirm delivery." }
        refreshScreen()
    }
    func profileLabel(_ profile: LocalProfileDescriptor) -> String {
        let kind = profile.libraryOwner.hasPrefix("local:") ? (profile.cloudBinding == nil ? "Local library" : "Linked local library") : "Cloud account library"
        return kind + " · " + String(profile.id.prefix(6))
    }
    func selectProfile(_ id: String) {
        guard !routeChangeBlocked, id != activeProfile?.id else { return }
        do {
            guard let repository = profileRepository else { throw DeviceError.message("Local identity storage is unavailable.") }
            try repository.activateProfile(id: id)
            stopConnection(); detachAccountLibrary()
            try openLibrary(); message = nil; startConnection()
        } catch { message = error.localizedDescription }
    }
    func selectAuthoringRoute(_ route: AuthoringRoute) {
        guard !routeChangeBlocked, let profile = activeProfile else { return }
        do {
            if route == .cloud, !cloudAccountMatches { throw DeviceError.message("Sign in to this profile’s Cloud account first.") }
            try profileRepository?.setPreferredRoute(route, profileID: profile.id)
            activeProfile?.preferredRoute = route; activeProfile?.routePreference = route == .local ? .local : .cloud; routePreference = route == .local ? .local : .cloud; selectedRoute = route; agentReady = false
            availableProfiles = try profileRepository?.snapshot().profiles ?? []
            startConnection()
        } catch { message = error.localizedDescription }
    }
    private func reloadLocalAgent() {
        stopConnection()
        do { try openLibrary(); startConnection() } catch { message = error.localizedDescription }
    }
    private func sendLocal(_ text: String) async {
        let generation = connectionGeneration
        await localConnectionLifecycle.wait()
        guard foreground, generation == connectionGeneration, !Task.isCancelled,
              agentReady, !busy, let library, let authoring = localAuthoring else { return }
        do {
            if try localLedger?.unresolvedRecord() != nil { message = "An earlier local delivery is unresolved. Return to its profile and finish or cancel it before sending another request."; return }
        } catch { message = error.localizedDescription; return }
        busy = true; requestPending = true; canCancelRequest = false; canRetry = false; takingLonger = false
        lastProgressAt = Date(); warningDismissedAt = .distantPast; message = nil; progressCaption = "Sending to your Mac…"
        do {
            let snapshot = try makeAuthoringRequest(text: text, library: library)
            pendingID = snapshot.requestID; pendingScreenID = snapshot.context.screenID
            try library.saveSubmission(key: snapshot.requestID, text: text, screen: screen?.artifact)
            try library.saveAuthoringRequest(snapshot); try persistPending()
            canCancelRequest = true
            let accepted = try await authoring.submit(snapshot)
            guard self.library === library, generation == connectionGeneration else { return }
            if cancelledLocally.contains(accepted.requestID) { cancelKnownRequest(accepted.requestID); return }
            try library.submissionAccepted(deadline: Double(accepted.deadlineAt))
            progressCaption = "Your Mac is working on this screen…"; requestRefresh()
        } catch {
            guard self.library === library, generation == connectionGeneration else { return }
            let submissionError = error
            // The adapter commits its ledger before network submission. A successful absent read proves no turn was sent.
            do {
                guard let ledger = localLedger else { throw DeviceError.message("Local delivery storage is unavailable.") }
                if let id = pendingID, try ledger.record(requestID: id) == nil {
                    try library.retireAuthoringRequest(id: id)
                    pendingID = nil; pendingScreenID = nil; try persistPending()
                    busy = false; requestPending = false; canCancelRequest = false; canRetry = true; message = submissionError.localizedDescription
                } else {
                    // Acceptance can be uncertain; preserve this route and request for history reconciliation.
                    progressCaption = submissionError.localizedDescription; canCancelRequest = pendingID != nil
                    if pendingID == nil { busy = false; requestPending = false; message = submissionError.localizedDescription }
                }
            } catch { progressCaption = "Local storage needs attention. Reconnect to check this request’s delivery."; canCancelRequest = pendingID != nil }
            requestRefresh()
        }
    }
    private func pollLocal(generation: UUID) async -> Bool {
        if settleAcknowledgedPending() { return true }
        await localConnectionLifecycle.wait()
        guard foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
        guard let library, let authoring = localAuthoring else { agentReady = false; return true }
        agentReady = localAgent != nil
        if let id = pendingID, library.authoringRequestV2(id: id) != nil { return await pollAuthoringV2(generation: generation) }
        do {
            // Local delivery and native receipt acknowledgement are separate durable commits.
            // Replay exact receipts even when the transport ledger is already terminal and no request is pending.
            if let state = library.state.authoring {
                for receipt in state.receipts.values where !state.acknowledgedReceiptIDs.contains(receipt.operationID) {
                    guard let record = try localLedger?.record(requestID: receipt.requestID), record.profileID == activeProfile?.id else { continue }
                    if record.contractVersion == 2, let localAuthoringV2 { try await localAuthoringV2.acknowledge(receipt) }
                    else { try await authoring.acknowledge(receipt) }
                    guard self.library === library, generation == connectionGeneration, !Task.isCancelled else { return true }
                    if pendingID == receipt.requestID {
                        consumedID = receipt.requestID; pendingID = nil; busy = false; requestPending = false; canCancelRequest = false; takingLonger = false; canRetry = false
                        try persistPending()
                    }
                }
            }
        } catch {
            guard self.library === library, generation == connectionGeneration, !Task.isCancelled else { return true }
            message = "Your result is saved here. Local receipt confirmation will retry."
            return false
        }
        guard let id = pendingID else { return true }
        do {
            // Repair a crash between the native journal commit and local ledger acknowledgement.
            if let record = try localLedger?.record(requestID: id), let result = record.finalResult,
               let receipt = library.state.authoring?.receipts[result.operationID] {
                try await authoring.acknowledge(receipt)
                guard self.library === library, generation == connectionGeneration, !Task.isCancelled else { return true }
                consumedID = id; pendingID = nil; busy = false; requestPending = false; canCancelRequest = false; takingLonger = false; canRetry = false
                try persistPending(); refreshScreen(); refreshPreferences()
                message = receipt.status == "applied" ? "Your previous result is saved on this device." : (receipt.message ?? "Your screen is unchanged.")
                return true
            }
            let delivery = try await authoring.reconcile(requestID: id)
            guard self.library === library, generation == connectionGeneration, !Task.isCancelled else { return true }
            if cancelledLocally.contains(id) { return true }
            switch delivery {
            case .completed(let result):
                let receipt = try authoring.apply(result)
                requestPreferenceSync() // A stalled Mac acknowledgement must not stall preferences.
                // The application receipt is committed before the Mac delivery is acknowledged.
                try await authoring.acknowledge(receipt)
                guard self.library === library, generation == connectionGeneration else { return true }
                refreshScreen(); refreshPreferences()
                message = receipt.status == "applied" ? (result.preferenceMutations?.isEmpty == false ? "Preference saved" : result.answer) : (receipt.message ?? "Your screen is unchanged.")
                consumedID = id; pendingID = nil; busy = false; requestPending = false; canCancelRequest = false; takingLonger = false; canRetry = false
                try persistPending()
            case .ended(let status, let failure): try finishRequest(id, status: status, failure: failure)
            case .pending(let progress):
                if let deadline = progress.deadlineAt { try library.submissionAccepted(deadline: deadline) }
                busy = true; requestPending = true; canCancelRequest = true; canRetry = false
                progressCaption = progress.caption ?? "Your Mac is working…"
                if let updated = progress.updatedAt { lastProgressAt = Date(timeIntervalSince1970: updated / 1000) }
            case .deliveryUncertain(let message), .needsAttention(let message):
                busy = true; requestPending = true; canCancelRequest = true; canRetry = false; progressCaption = message
            }
            return pendingID == nil
        } catch {
            guard self.library === library, generation == connectionGeneration, !Task.isCancelled else { return true }
            progressCaption = error.localizedDescription; busy = true; requestPending = true; canCancelRequest = true
            return false
        }
    }
    /// A failed open after authentication must leave no previous account's inventory
    /// attached to the new session. Durable account directories remain untouched.
    private func detachAccountLibrary() {
        publicReads?.cancel(); publicReads = nil; publicReadSessionKey = ""
        if let previous = homeAssistant { Task { await previous.cancelPending() } }
        homeAssistant = nil; manifest = nil; assets = nil; screen = nil
        library = nil; cloudAuthoring = nil; localAuthoring = nil; localTransport = nil; cloudAuthoringV2 = nil; localAuthoringV2 = nil; localTransportV2 = nil; localTransportAuthoringProfileID = nil; cloudAgentReady = false; cloudSupportsV2 = false; pendingID = nil; pendingScreenID = nil; consumedID = nil
        cancelledLocally = []; inventorySignature = nil
        installedManifests = []; installedScreens = []; manifestIssues = [:]
        preferenceRecords = []; inactiveDevicePreferences = []; preferenceConflicts = []; preferenceSyncStatus = nil
        agentReady = false; requestPending = false; canCancelRequest = false; canRetry = false; takingLonger = false
    }
    private func persistPending() throws { try library?.savePending(id: pendingID, screenID: pendingScreenID, consumedID: consumedID) }
    func refreshConnections() { refreshScreen() }
    private func refreshScreen() {
        defer { refreshPublicReads(); requestRefresh() }
        if let previous = homeAssistant { Task { await previous.cancelPending() } }
        homeAssistant = nil; manifest = nil
        installedScreens = library?.state.screens ?? []
        manifestIssues = [:]
        installedManifests = installedScreens.compactMap { saved in
            guard let file = saved.artifact.files.first(where: { $0.path == "manifest.json" }) else { return nil }
            do {
                var parsed = try JSONDecoder().decode(DashboardManifest.self, from: Data(file.content.utf8))
                try PackageValidator.validate(parsed)
                parsed.revision = saved.revision
                return parsed
            } catch {
                manifestIssues[saved.id] = "Connection settings could not load. Ask your agent to repair this screen’s manifest."
                return nil
            }
        }
        if let owner = activeProfile?.permissionOwner {
            let vault = HomeAssistantDeviceVault()
            for installed in installedManifests { _ = vault.synchronize(manifest: installed, owner: owner) }
        }
        screen = library?.selected; canRollback = library?.state.previous != nil
        do {
            assets = try screen.flatMap { try library?.store(for: $0) }
            if let data = assets?.assets["manifest.json"]?.data,
               var parsed = try? JSONDecoder().decode(DashboardManifest.self, from: data),
               (try? PackageValidator.validate(parsed)) != nil, let screen, let owner = activeProfile?.permissionOwner {
                // Local immutable revision is the authority for device-approved credentials.
                parsed.revision = screen.revision; manifest = parsed
                let scope = HomeAssistantDeviceRuntime.Scope(owner: owner, revision: screen.revision, dashboardId: parsed.dashboardId)
                homeAssistant = HomeAssistantDeviceRuntime(vault: HomeAssistantDeviceVault(), scope: { scope })
            }
        } catch { assets = nil; message = "Could not load this screen. Use Settings to restore its previous version." }
    }
}
