import SwiftUI
import ScreenpunkApple
import ScreenpunkCore
import CryptoKit
import ScreenpunkLocalAuthoring
import ScreenpunkLocalTransport

@MainActor final class DeviceModel: ObservableObject {
    @Published var choosingSignInProvider = false
    @Published var accountCreationEmail: String?
    private var accountCreationContinuation: CheckedContinuation<Bool, Never>?
    func resolveAccountCreation(_ create: Bool) {
        let continuation = accountCreationContinuation
        accountCreationContinuation = nil
        accountCreationEmail = nil
        continuation?.resume(returning: create)
    }
    private func confirmAccountCreation(email: String) async -> Bool {
        accountStatusCaption = "Confirm account creation"
        let create = await withCheckedContinuation { continuation in
            accountCreationContinuation = continuation
            accountCreationEmail = email
        }
        accountStatusCaption = create ? "Creating your account…" : "Cancelling sign-in…"
        return create
    }
    @Published var deletedAccountAppleHelpURL: URL?
    @Published private(set) var accountDeletionInProgress = false
    @Published private(set) var accountDeletionStatus: String? {
        didSet { updateInlineMessage(.deletionStatus, text: accountDeletionStatus) }
    }
    @Published private(set) var accountDeletionError: String? {
        didSet { updateInlineMessage(.deletionError, text: accountDeletionError) }
    }
    enum InlineMessage: Hashable { case deletionStatus, deletionError, backup, preview }
    @Published private var inlineMessages: [InlineMessage: StatusMessagePresentationState] = [:]
    private func updateInlineMessage(_ key: InlineMessage, text: String?) {
        var state = inlineMessages[key] ?? StatusMessagePresentationState()
        state.updateIfChanged(text)
        inlineMessages[key] = state
    }
    func presentedInlineMessage(_ key: InlineMessage) -> StatusMessagePresentationState.Message? {
        inlineMessages[key]?.presentedMessage
    }
    func dismissInlineMessage(_ key: InlineMessage, id: UUID) {
        inlineMessages[key]?.dismiss(id: id, busy: false, requestPending: false,
                                    routeChangeBlocked: false, canRetry: false, canCancelRequest: false)
    }
    @Published private var accountDeletionIntent: DeviceAccountDeletionIntent?
    var accountDeletionTargetID: String? { accountDeletionIntent?.accountID ?? cloud.localAccountID }
    var accountDeletionNeedsRetry: Bool { accountDeletionIntent != nil }
    var accountDeletionDiagnosticCode: String? { accountDeletionIntent?.lastFailure?.supportCode }
    var accountDeletionRequiresConfirmation: Bool {
        guard let intent = accountDeletionIntent else { return true }
        return !intent.serverConfirmed && intent.appleRevocationConsent != "REVOKE"
    }
    var accountDeletionRetryTitle: String {
        accountDeletionIntent?.serverConfirmed == true ? "Finish Removing Local Data" : "Retry Account Deletion"
    }

    @Published var email: String?
    @Published private(set) var displayName = "Screenpunk"
    @Published private(set) var deviceNameSyncStatus: String?
    @Published var agentReady = false
    @Published var busy = false
    @Published var accountOperationInProgress = false
    @Published private(set) var accountStatusCaption: String?
    @Published var message: String? {
        didSet { statusMessagePresentation.updateIfChanged(message) }
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
    @Published private var agentWorkingRequestID: String?
    var showsAgentWorking: Bool {
        guard let id = agentWorkingRequestID else { return false }
        return id == pendingID && requestPending && busy && !canRetry && !accountOperationInProgress
    }
    @Published var canRetry = false
    @Published var preferenceRecords: [PreferenceRecordV1] = []
    @Published var inactiveDevicePreferences: [PreferenceRecordV1] = []
    @Published var preferenceConflicts: [AuthoringPreferenceConflict] = []
    @Published var preferenceSyncStatus: String?
    @Published private(set) var catalogBackupStatus: String? {
        didSet { updateInlineMessage(.backup, text: catalogBackupStatus) }
    }
    @Published private(set) var catalogCanResume = false
    private let catalogPump = CatalogWorkPump()
    private let linkedCatalogPump = CatalogWorkPump()
    @Published private(set) var catalogPickerFollowsUpdates = false
    @Published private var linkedCatalogDeviceCounts: [String: Int] = [:]
    private var catalogCatchUpNeeded = false
    private var catalogCapabilityRetry: Date?
    @Published private(set) var catalogPreviewStatus: String? {
        didSet { updateInlineMessage(.preview, text: catalogPreviewStatus) }
    }
    private let previewPump = CatalogWorkPump()
    private var previewDiscoveryNeeded = false
    private var previewDiscoveryRetry: Date?
    private var pendingPreviewCaptures: [String] = []
    private var previewCaptureTasks: [String: Task<Void, Never>] = [:]
    private var previewCaptureFlight: CatalogFlight?
    private var previewCandidates: [CatalogPreviewCandidate] = []
    private var previewCursor: String?
    private var previewByteLimit = CatalogContract.previewBytes
    private var previewDimensionLimit = CatalogContract.previewDimension
    @Published private(set) var activeProfile: LocalProfileDescriptor?
    @Published private(set) var selectedRoute: AuthoringRoute = .local
    @Published private(set) var routePreference: AuthoringRoutePreference = .automatic
    @Published private(set) var cloudAgentReady = false
    @Published private var cloudListenerObservations = CloudListenerObservations()
    private var cloudListenerObservation: CloudListenerObservation? { cloudListenerObservations.observation }
    private var listenerStatusRead: UInt64 = 0
    private func nextListenerStatusRead() -> UInt64 {
        listenerStatusRead += 1
        return listenerStatusRead
    }
    var cloudListenerStatus: CloudListenerObservation.Status {
        if cloudAuthorizationRejected, cloud.session != nil { return .unavailable }
        return CloudListenerObservation.status(cloudListenerObservation, accountID: cloud.localAccountID,
            deviceID: cloud.session?.deviceId, profileID: cloud.session?.profileID)
    }
    /// Read Cloud status when Settings opens, even before the socket connects.
    func checkListenerStatusOnSettingsEntry() {
        refreshCloudSetupStatus(reconcileProfile: shouldCheckCloudSetup)
    }
    private func refreshCloudSetupStatus(reconcileProfile: Bool) {
        cloudSetupStatusTask?.cancel()
        cloudSetupStatusTask = nil
        guard !accountOperationInProgress, !cloudAuthorizationRejected, let session = cloud.session,
              let accountID = cloud.localAccountID else { return }
        let profileID = activeProfile?.id
        let binding = activeProfile?.cloudBinding
        let read = nextListenerStatusRead()

        cloudSetupStatusTask = Task { [weak self, cloud] in
            guard !Task.isCancelled else { return }
            let observation: CloudListenerObservation
            do {
                let status: AgentStatus = try await cloud.call("api/device/status", authorizationToken: session.accessToken)
                observation = .init(accountID: accountID, deviceID: session.deviceId,
                    profileID: status.profileID, ready: status.agentReady, pluginConnected: status.pluginConnected)
            } catch {
                observation = .init(accountID: accountID, deviceID: session.deviceId,
                    profileID: session.profileID, ready: nil)
            }

            guard !Task.isCancelled, let self else { return }
            self.cloudSetupStatusTask = nil
            guard !self.accountOperationInProgress, !self.cloudAuthorizationRejected,
                  self.activeProfile?.id == profileID, self.activeProfile?.cloudBinding == binding,
                  cloud.localAccountID == accountID,
                  cloud.session?.accessToken == session.accessToken,
                  cloud.session?.deviceId == session.deviceId,
                  cloud.session?.profileID == session.profileID else { return }
            let published = self.cloudListenerObservations.publish(observation, source: .direct, read: read)
            if published, reconcileProfile, observation.ready != nil, !self.routeChangeBlocked,
               observation.matches(accountID: accountID, deviceID: session.deviceId,
                                   profileID: session.profileID ?? binding?.profileID) {
                try? self.reconcileCloudProfile(observation.profileID)
            }
        }
    }
    /// A status invalidation while Local is selected only reads listener state.
    /// It never discovers Cloud authoring requests or consumes Cloud commands.
    private func requestCloudListenerStatus() {
        guard let epoch = cloudSocketEpoch, let session = cloud.session else { return }
        listenerStatusPump.wake { [weak self] in
            guard let self, self.cloudSocketEpoch == epoch,
                  self.cloud.session?.accessToken == session.accessToken else { return true }
            let read = self.nextListenerStatusRead()
            do {
                let status: AgentStatus = try await self.cloud.call("api/device/status", authorizationToken: session.accessToken)
                guard !Task.isCancelled, self.cloudSocketEpoch == epoch,
                      self.cloud.session?.accessToken == session.accessToken else { return true }
                self.observeCloudListener(status, read: read)
                if !self.routeChangeBlocked { try self.reconcileCloudProfile(status.profileID) }
                return true
            } catch {
                guard !Task.isCancelled, self.cloudSocketEpoch == epoch,
                      self.cloud.session?.accessToken == session.accessToken else { return true }
                if (error as? DeviceError)?.authorizationRejected == true {
                    self.rejectCloudAuthorization()
                    return true
                }
                if let accountID = self.cloud.localAccountID {
                    self.cloudListenerObservations.publish(.init(accountID: accountID, deviceID: session.deviceId,
                        profileID: session.profileID, ready: nil), source: .socket, read: read)
                }
                return false
            }
        }
    }
    private func observeCloudListener(_ status: AgentStatus, read: UInt64) {
        guard cloudSocketEpoch != nil, let session = cloud.session, let accountID = cloud.localAccountID else { return }
        cloudListenerObservations.publish(.init(accountID: accountID, deviceID: session.deviceId,
            profileID: status.profileID, ready: status.agentReady, pluginConnected: status.pluginConnected), source: .socket, read: read)
    }
    #if DEBUG
    private var shouldRestartGuideForTesting = ProcessInfo.processInfo.arguments.contains("--screenpunk-test-restart-guide")
    #endif
    @Published private(set) var onboarding: ScreenLibrary.Onboarding?
    var requiresAccountOnboarding: Bool {
        ScreenLibrary.Onboarding.requiresAccountSignIn(hasCloudSession: cloud.session != nil, localAgent: localAgent)
    }
    var needsAgentSetup: Bool { requiresAccountOnboarding || onboarding == .connectAgent }
    private var onboardingCloudListenerReady: Bool {
        cloudBindingMatches && cloudListenerStatus == .connected &&
            cloudListenerObservation?.canCompleteCloudSetup == true &&
            cloudListenerObservation?.profileID == activeProfile?.cloudBinding?.profileID
    }
    private var shouldCheckCloudSetup: Bool {
        needsAgentSetup && cloudAccountMatches &&
            (routePreference == .cloud || (routePreference == .automatic && localAgent?.lastSuccessfulConnectionAt == nil))
    }
    var onboardingCloudPluginConnected: Bool? {
        guard shouldCheckCloudSetup, !accountOperationInProgress, !cloudAuthorizationRejected,
              activeProfile?.cloudBinding == nil || cloudBindingMatches,
              let session = cloud.session else { return nil }
        return cloudListenerObservation?.pluginConnection(accountID: cloud.localAccountID, deviceID: session.deviceId,
            profileID: session.profileID ?? activeProfile?.cloudBinding?.profileID)
    }
    var showsCloudPluginConnection: Bool {
        shouldCheckCloudSetup && !onboardingCloudListenerReady && onboardingCloudPluginConnected != true
    }
    var showsCloudListenerSetup: Bool {
        shouldCheckCloudSetup && !onboardingCloudListenerReady && onboardingCloudPluginConnected == true
    }
    var canFinishAgentSetup: Bool {
        guard needsAgentSetup, !accountOperationInProgress, library?.hasTemporaryScreen == false else { return false }
        return ScreenLibrary.Onboarding.agentIsReady(
            route: routePreference,
            verifiedLocal: localAgent?.lastSuccessfulConnectionAt != nil,
            cloudListenerConnected: onboardingCloudListenerReady
        )
    }
    var galleryIntroOwner: String? {
        guard onboarding == .gallery, !accountOperationInProgress, library?.hasTemporaryScreen == false else { return nil }
        return activeProfile?.libraryOwner
    }
    var canHideInstructions: Bool {
        !needsAgentSetup && installedScreens.contains { !hiddenScreenIDs.contains($0.id) }
    }
    func finishAgentSetup() {
        guard !settingsOpen, canFinishAgentSetup, let library else { return }
        do { try library.finishAgentSetup() }
        catch { message = error.localizedDescription }
        onboarding = library.state.onboarding
    }
    func dismissGalleryIntro(owner: String) {
        guard !accountOperationInProgress, activeProfile?.libraryOwner == owner, let library else { return }
        do { try library.dismissGalleryIntro() }
        catch { message = error.localizedDescription }
        onboarding = library.state.onboarding
    }

    @Published private(set) var resolvedAgentName: String?
    private var cloudSupportsV2 = false
    private var cloudSupportsConnectionPrefill = false
    private var cloudSupportsCustomHTTP = false
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
    var routeChangeBlocked: Bool { accountDeletionIntent != nil || busy || pendingID != nil || library?.state.submissionKey != nil || linkedEditPrompt != nil }
    private var currentRequestRoute: AuthoringRoute {
        if let id = pendingID ?? library?.state.submissionKey {
            if let route = library?.authoringRequestV2(id: id)?.delivery.route { return AuthoringRoute(rawValue: route) ?? selectedRoute }
            if let route = library?.authoringRequest(id: id)?.delivery.route { return AuthoringRoute(rawValue: route) ?? selectedRoute }
            if let record = try? localLedger?.record(requestID: id), record.profileID == activeProfile?.id { return .local }
        }
        return selectedRoute
    }
    private var cloudAccountMatches: Bool {
        guard let profile = activeProfile, let accountID = cloud.localAccountID else { return false }
        return profile.libraryOwner == accountID || profile.cloudBinding?.accountID == accountID
    }
    private var cloudBindingMatches: Bool {
        guard let binding = activeProfile?.cloudBinding, let session = cloud.session else { return false }
        return binding.accountID == cloud.localAccountID && binding.deviceID == session.deviceId && (session.profileID == nil || binding.profileID == session.profileID)
    }
    private var progressTiming = RequestProgressTiming()
    private var cancelledLocally = Set<String>()
    @Published var assets: PackageAssetStore?
    @Published var settingsOpen = false {
        didSet {
            guard !settingsOpen else { return }
            if let revision = screen?.revision { captureExactCatalogPreview(revision: revision) }
            enqueuePreviewCaptures(previewCandidates)
        }
    }
    @Published var settingsPage: DeviceSettingsPage = .account
    // Drafts belong to an account and target screen, never a sign-in provider's
    // display email. Closing an error or editor must not discard typed work.
    private var keyboardDrafts: [String: String] = [:]
    var keyboardRequestScope: String { permissionOwner + "\n" + (activeProfile?.id ?? "") + "\n" + (activeProfile?.libraryOwner ?? "") }
    private func keyboardDraftKey(owner: String, screenID: String?) -> String {
        owner + "\n" + (screenID ?? "new")
    }
    func keyboardDraft(owner: String, screenID: String?) -> String {
        keyboardDrafts[keyboardDraftKey(owner: owner, screenID: screenID)]
            ?? (owner == keyboardRequestScope ? library?.keyboardDraft(screenID: screenID) : nil) ?? ""
    }
    func saveKeyboardDraft(_ text: String, owner: String, screenID: String?) {
        keyboardDrafts[keyboardDraftKey(owner: owner, screenID: screenID)] = text
    }
    func persistKeyboardDraft(_ text: String, owner: String, screenID: String?) {
        saveKeyboardDraft(text, owner: owner, screenID: screenID)
        guard owner == keyboardRequestScope else { return }
        do { try library?.saveKeyboardDraft(text, screenID: screenID) }
        catch { message = "Your draft is kept for this session, but could not be saved: " + error.localizedDescription }
    }
    struct LinkedEditOptions {
        let screenID: String
        let revision: String
        let owner: String
        let screenName: String
        let forkName: String
        let deviceCount: Int?
        let version: Int
        let pendingPublication: Bool
        let hasConflict: Bool

        var blocksEditing: Bool { pendingPublication || hasConflict }

        var updateAllTitle: String {
            if let deviceCount { return "Update all linked iPads (\(deviceCount))" }
            return "Update all linked iPads"
        }
    }

    struct LinkedEditPrompt: Identifiable {
        let id = UUID()
        let text: String
        let options: LinkedEditOptions
    }

    @Published private(set) var linkedEditPrompt: LinkedEditPrompt?
    private var retryLinkedEdit: (options: LinkedEditOptions, scope: ScreenLibrary.LinkedCatalogEditScope, text: String)?

    func linkedEditOptions(for screenID: String?) -> LinkedEditOptions? {
        guard let screenID, let saved = installedScreens.first(where: { $0.id == screenID }),
              let link = library?.linkedCatalogScreen(id: screenID) else { return nil }
        func bounded(_ value: String, limit: Int) -> String {
            var remaining = limit
            return String(value.prefix(while: { character in
                remaining -= String(character).utf16.count
                return remaining >= 0
            }))
        }
        let deviceName = bounded(displayName.trimmingCharacters(in: .whitespacesAndNewlines), limit: 50)
        let suffix = " — " + (deviceName.isEmpty ? "This iPad" : deviceName)
        let title = bounded(saved.displayName, limit: 100 - suffix.utf16.count) + suffix
        return .init(screenID: screenID, revision: saved.revision, owner: keyboardRequestScope,
                     screenName: saved.displayName, forkName: title, deviceCount: linkedCatalogDeviceCount(for: screenID),
                     version: link.displayVersion, pendingPublication: link.pendingRevision != nil, hasConflict: link.conflict)
    }

    func cancelLinkedEditPrompt() { linkedEditPrompt = nil }

    func confirmLinkedEdit(_ prompt: LinkedEditPrompt, scope: ScreenLibrary.LinkedCatalogEditScope) {
        if let current = linkedEditPrompt, current.id != prompt.id { return }
        linkedEditPrompt = nil
        guard linkedEditIsCurrent(prompt.options) else {
            message = "This screen changed. Reopen it before sending your instructions."
            return
        }
        Task { await send(prompt.text, linkedEdit: scope, expectedLinkedEdit: prompt.options) }
    }

    func resolveLinkedEditConflict(_ options: LinkedEditOptions, keepOnThisIPad: Bool) throws {
        guard let library, !routeChangeBlocked, !accountOperationInProgress,
              options.owner == keyboardRequestScope,
              library.linkedCatalogScreen(id: options.screenID)?.conflict == true,
              installedScreens.first(where: { $0.id == options.screenID })?.revision == options.revision else {
            throw DeviceError.message("This shared edit changed. Reopen the screen’s settings.")
        }
        if keepOnThisIPad {
            try library.resolveLinkedCatalogConflictAsFork(id: options.screenID, name: options.forkName)
        } else {
            try library.discardLinkedCatalogConflict(id: options.screenID)
        }
        guard library.linkedCatalogScreen(id: options.screenID)?.conflict != true else {
            throw DeviceError.message("This shared edit could not be resolved.")
        }
        refreshScreen()
        requestLinkedCatalogSync()
    }

    private func linkedEditIsCurrent(_ options: LinkedEditOptions) -> Bool {
        guard let link = library?.linkedCatalogScreen(id: options.screenID), link.pendingRevision == nil, !link.conflict else { return false }
        return options.owner == keyboardRequestScope && screen?.id == options.screenID && screen?.revision == options.revision
    }

    @discardableResult
    func submitKeyboardRequest(_ text: String, owner: String, screenID: String?, revision: String?, creatingNew: Bool,
                               linkedEdit: ScreenLibrary.LinkedCatalogEditScope? = nil) -> Bool {
        guard let normalized = KeyboardRequestText.normalized(text) else {
            message = "Enter instructions that fit the request limit. Your draft is kept."; return false
        }
        guard owner == keyboardRequestScope, hasProfile, let library, !needsAgentSetup,
              !accountOperationInProgress, !busy, !requestPending, !routeChangeBlocked else {
            message = "The request context changed. Your draft is kept; reopen it when the device is ready."; return false
        }
        guard creatingNew || (screen?.id == screenID && screen?.revision == revision) else {
            message = "The selected screen changed. Your draft is kept; reopen the intended screen before sending."; return false
        }
        let options = creatingNew ? nil : linkedEditOptions(for: screenID)
        guard options?.blocksEditing != true else {
            message = "Finish reviewing this screen’s shared update first. Your draft is kept."
            return false
        }
        guard (options == nil) == (linkedEdit == nil) else {
            message = "Choose which iPads this edit should update. Your draft is kept."
            return false
        }
        saveKeyboardDraft(text, owner: owner, screenID: creatingNew ? nil : screenID)
        do {
            try library.saveKeyboardDraft(text, screenID: creatingNew ? nil : screenID)
            if creatingNew {
                try library.newScreen()
                guard library.state.selectedID == nil else { throw DeviceError.message("A separate screen could not be prepared. Your existing screen is unchanged.") }
                refreshScreen()
            }
            // The same sealed-snapshot, route and recovery flow as speech.
            settingsOpen = false
            Task {
                guard self.keyboardRequestScope == owner,
                      (creatingNew ? self.screen == nil : (self.screen?.id == screenID && self.screen?.revision == revision)) else { return }
                await self.send(normalized, linkedEdit: linkedEdit, expectedLinkedEdit: options)
            }
            return true
        } catch { message = error.localizedDescription; return false }
    }
    @Published var canRollback = false
    @Published var manifestIssues: [String: String] = [:]
    @Published private var acknowledgedManifestIssues: [String: String] = [:]
    private func manifestIssueKey(_ saved: ScreenLibrary.Saved) -> String {
        keyboardRequestScope + "\n" + saved.id + "\n" + saved.revision
    }
    func presentedManifestIssue(_ saved: ScreenLibrary.Saved) -> String? {
        guard let issue = manifestIssues[saved.id], acknowledgedManifestIssues[manifestIssueKey(saved)] != issue else { return nil }
        return issue
    }
    func dismissManifestIssue(_ issue: String, saved: ScreenLibrary.Saved) {
        guard installedScreens.contains(where: { $0.id == saved.id && $0.revision == saved.revision }), manifestIssues[saved.id] == issue else { return }
        acknowledgedManifestIssues[manifestIssueKey(saved)] = issue
    }
    @Published var installedManifests: [DashboardManifest] = []
    @Published var installedScreens: [ScreenLibrary.Saved] = []
    @Published private(set) var hiddenScreenIDs: Set<String> = []
    @Published var manifest: DashboardManifest?
    @Published var homeAssistant: HomeAssistantDeviceRuntime?
    @Published var publicReads: PublicReadSession?
    @Published var publicReadSessionKey = ""
    let cloud = CloudClient()
    let billing = DeviceBillingStore(backend: DeviceBillingBackend())
    private var library: ScreenLibrary?
    private var pendingID: String?
    private var pendingScreenID: String?
    private var consumedID: String?
    private var inventorySignature: String?
    private let connection = DeviceConnection()
    private var cloudSocketToken: String?
    private var cloudAuthorizationRejected = false
    private var cloudSocketEpoch: UUID?
    private let listenerStatusPump = PreferenceSyncPump()
    private var cloudSetupStatusTask: Task<Void, Never>?
    private var foreground = false
    private struct TemporaryHomeAssistantTarget: Equatable {
        var library: ObjectIdentifier
        var screenID: String
        var scope: HomeAssistantDeviceRuntime.Scope
    }
    private var temporaryHomeAssistantTargets: [String: TemporaryHomeAssistantTarget] = [:]
    private var temporaryHomeAssistantTasks: [String: Task<Void, Never>] = [:]
    private var connectionActive = false
    @Published private var connectionGeneration = UUID()
    @Published private var screenDataRendererEpoch = UUID()
    @Published private(set) var screenDataPrompt: DeviceScreenDataPrompt?
    @Published private(set) var screenDataPermissions: [DeviceScreenDataPermission] = []
    private var screenDataSocketID: String?
    private var screenDataInventorySignature: Data?
    private var screenDataInventorySequence = 0
    private var screenDataInventorySelectedID: String?
    private var screenDataInventoryGenerations: [String: String] = [:]
    private var screenDataInventoryDirty = false
    private var screenDataInventoryTask: Task<Void, Never>?
    private var screenDataQueryTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var screenDataPrompts: [DeviceScreenDataPrompt] = []
    private var screenDataRate: [String: [TimeInterval]] = [:]
    private let refreshPump = CatalogWorkPump()
    private var refreshFailures = 0
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
        guard foreground, connectionActive, !cloudAuthorizationRejected,
              CloudPreferenceSyncEligibility.matches(profile: activeProfile, accountID: cloud.localAccountID, deviceID: cloud.session?.deviceId, profileID: cloud.session?.profileID),
              let profile = activeProfile, let binding = profile.cloudBinding,
              let library, let session = cloud.session else { return nil }
        return .init(generation: connectionGeneration, library: ObjectIdentifier(library), profileID: profile.id, libraryOwner: profile.libraryOwner, cloud: binding, credential: session.accessToken, sessionProfileID: session.profileID)
    }
    init() {
        RequestTimeline.record(.launch)
        cloud.sessionRevoked = { [weak self] in self?.finishCloudDeviceRevocation() }
        cloud.deviceNameChanged = { [weak self] name, status in self?.displayName = name; self?.deviceNameSyncStatus = status }
        email = cloud.session?.user.email
        billing.observeAccount(self)
        do {
            profileRepository = try LocalProfileRepository()
            configurationRepository = try LocalAgentConfigurationRepository()
            localLedger = try LocalDeliveryLedger()
            if let configurationRepository, let localLedger {
                do { localSettings = try LocalAgentSettingsModel(configurationRepository: configurationRepository, ledger: localLedger, vault: localVault, profileID: { [weak self] in self?.activeProfile?.id }, changed: { [weak self] in self?.reloadLocalAgent() }) }
                catch { message = "Local setup could not open: " + error.localizedDescription }
            }
            accountDeletionIntent = try cloud.pendingAccountDeletion()
            if let intent = accountDeletionIntent {
                accountOperationInProgress = true
                accountDeletionStatus = intent.serverConfirmed ? "Your account was deleted. Finish removing its data from this iPad." : "Account deletion is incomplete. Your recovery information is saved on this iPad."
                if intent.lastFailure != nil { accountDeletionError = "Account deletion is incomplete. The last server report is saved below." }
                message = accountDeletionStatus
                settingsPage = .account
                settingsOpen = true
            } else {
                try openLibrary()
            }
        } catch { message = "Could not open saved screens: \(error.localizedDescription)" }
    }
    func signIn(provider: CloudSignInProvider? = nil, fromCloudOnboarding: Bool = false) async {
        guard !accountOperationInProgress, accountDeletionIntent == nil else { return }
        guard let provider else { choosingSignInProvider = true; return }
        guard !routeChangeBlocked else { message = "Finish or cancel the current request before changing accounts."; return }
        accountStatusCaption = provider == .apple ? "Signing in with Apple…" : "Signing in with Google…"
        accountOperationInProgress = true
        defer { accountOperationInProgress = false; accountStatusCaption = nil; startConnection() }
        stopConnection()
        library?.setCatalogBackupScope(nil)
        var signedIn = false
        busy = true
        defer {
            busy = pendingID != nil
            if signedIn, fromCloudOnboarding, needsAgentSetup, routePreference == .local {
                selectRoutePreference(.cloud)
            }
        }
        do {
            let authenticated = try await cloud.signIn(provider: provider) { [weak self] email in
                guard let self else { return false }
                return await self.confirmAccountCreation(email: email)
            }
            accountStatusCaption = "Finishing sign-in…"
            detachAccountLibrary()
            _ = try profileRepository?.activateAccountProfile(accountID: CloudClient.originScope.localAccountID(serverUserID: authenticated.user.id), deviceID: authenticated.deviceId)
            email = authenticated.user.email; message = nil
            try openLibrary()
            if let profile = activeProfile, let account = cloud.localAccountID {
                try library?.resumeCatalogAuthentication(binding: .init(origin: CloudClient.origin.absoluteString, accountID: account, userID: authenticated.user.id, deviceID: authenticated.deviceId, libraryID: profile.libraryOwner))
            }
            signedIn = true
        }
        catch is CancellationError { message = nil }
        catch { message = error.localizedDescription }
    }
    func signOut(accountID: String, deleteScreens: Bool) async {
        guard !accountOperationInProgress, accountDeletionIntent == nil, cloud.localAccountID == accountID else { return }
        guard !routeChangeBlocked else { message = "Finish or cancel the current request before changing accounts."; return }
        var deletionProfile: LocalProfileDescriptor?
        if deleteScreens {
            do {
                guard let profileRepository else { throw DeviceError.message("Local identity storage is unavailable.") }
                deletionProfile = try profileRepository.accountProfile(accountID: accountID)
            } catch {
                message = "Couldn’t check this account’s saved screens. Try signing out again."
                return
            }
        }
        accountStatusCaption = "Signing out…"
        accountOperationInProgress = true
        defer { accountOperationInProgress = false; accountStatusCaption = nil; startConnection() }
        stopConnection()
        library?.setCatalogBackupScope(nil)
        detachAccountLibrary()
        var notices: [String] = []
        do { try await cloud.signOut() }
        catch CloudSignOutError.secureCredentialsNotCleared {
            notices.append("This iPad couldn’t clear its saved sign-in. Unlock and restart the app, then sign out again.")
        }
        catch { notices.append("Cloud sign-out couldn’t be confirmed. You can disconnect this iPad from your account when online.") }
        email = nil
        if deleteScreens {
            do {
                if let deletionProfile {
                    guard let localLedger else { throw DeviceError.message("Local delivery storage is unavailable.") }
                    try localLedger.discardScreenResults(profileID: deletionProfile.id)
                }
                try ScreenLibrary.deleteAccountScreens(accountID: accountID, profile: deletionProfile)
                notices.append("Account screens deleted from this iPad.")
            } catch { notices.append("Couldn’t finish deleting the saved screens. Sign in again to retry.") }
        } else {
            notices.append("Your screens are still saved on this iPad. Sign in to this account again to see them.")
        }
        do { try openLibrary() }
        catch { notices.append("Couldn’t open the local library: \(error.localizedDescription)") }
        message = notices.joined(separator: "\n")
        settingsOpen = false
    }
    func deleteAccount(accountID: String, approvedAppleRevocation: Bool = false) async {
        guard !accountDeletionInProgress, !accountOperationInProgress || accountDeletionIntent != nil else { return }
        guard accountDeletionIntent != nil || !routeChangeBlocked else {
            accountDeletionError = "Finish or cancel the current screen request before deleting your account."
            return
        }
        accountDeletionError = nil
        do {
            var intent: DeviceAccountDeletionIntent
            if let pending = accountDeletionIntent {
                guard pending.accountID == accountID else { throw DeviceError.message("A different account deletion is pending.") }
                intent = pending
            } else {
                guard let session = cloud.session, cloud.localAccountID == accountID, let profileRepository else {
                    throw DeviceError.message("The signed-in account changed. Open Account settings again.")
                }
                let allProfiles = try profileRepository.snapshot().profiles
                let profiles = allProfiles.filter { $0.cloudAccountID == accountID }
                let ownDashboards = try profiles.reduce(into: Set<String>()) { $0.formUnion(try ScreenLibrary.dashboardIDs(profile: $1)) }
                let retainedDashboards = try allProfiles.filter { $0.cloudAccountID != accountID }.reduce(into: Set<String>()) {
                    $0.formUnion(try ScreenLibrary.dashboardIDs(profile: $1))
                }
                let owners = Set(profiles.map(\.permissionOwner))
                var keys = UserDefaults.standard.dictionaryRepresentation().keys.filter { key in
                    owners.contains { key.hasPrefix("screenpunk.publicReads." + $0 + ".") }
                }
                for profile in profiles {
                    if let binding = profile.cloudBinding {
                        let catalog = ScreenLibrary.CatalogBinding(origin: CloudClient.origin.absoluteString,
                            accountID: accountID, userID: session.user.id, deviceID: binding.deviceID, libraryID: profile.libraryOwner)
                        keys.append(catalog.preferenceKey)
                    }
                }
                var prepared = DeviceAccountDeletionIntent(origin: CloudClient.origin.absoluteString, accountID: accountID,
                    serverAccountID: session.user.id, operationID: UUID().uuidString, profiles: profiles,
                    preferenceKeys: keys, billingJournalOwner: billing.deletionJournalOwner(for: cloud))
                prepared.preferenceDashboardIDs = ownDashboards.subtracting(retainedDashboards)
                intent = prepared
                try cloud.saveAccountDeletion(intent)
                accountDeletionIntent = intent
            }
            if approvedAppleRevocation {
                intent.appleRevocationConsent = "REVOKE"
                try cloud.saveAccountDeletion(intent)
                accountDeletionIntent = intent
            }
            accountDeletionInProgress = true
            accountOperationInProgress = true
            accountStatusCaption = intent.serverConfirmed ? "Removing deleted account data…" : "Deleting your account…"
            accountDeletionStatus = accountStatusCaption
            defer {
                accountDeletionInProgress = false
                accountOperationInProgress = accountDeletionIntent != nil
                accountStatusCaption = nil
            }
            stopConnection()
            library?.setCatalogBackupScope(nil)
            let confirmed = try await cloud.requestAccountDeletion(intent)
            accountDeletionIntent = confirmed
            accountDeletionStatus = "Your account was deleted. Removing its data from this iPad…"
            try removeDeletedAccountData(confirmed)
            if confirmed.manualAppleRevocationRequired {
                deletedAccountAppleHelpURL = URL(string: "https://support.apple.com/en-us/102571")
            }
            accountDeletionIntent = nil
            accountDeletionStatus = nil
            message = "Your Screenpunk account has been deleted."
            settingsOpen = false
        } catch {
            // Reload the durable prepare/completion receipt after an interrupted request.
            if let saved = try? cloud.pendingAccountDeletion() { accountDeletionIntent = saved }
            accountDeletionStatus = accountDeletionIntent?.serverConfirmed == true
                ? "Your account was deleted. Some data still needs to be removed from this iPad."
                : "Account deletion is incomplete. Your recovery information is saved on this iPad."
            if accountDeletionIntent == nil {
                accountDeletionError = "Could not prepare deletion on this iPad. No deletion request was sent. Unlock the iPad and try again."
            } else if let failure = error as? DeviceAccountDeletionFailure {
                accountDeletionError = failure.errorDescription
            } else {
                accountDeletionError = "Could not finish account deletion. Your recovery information is saved on this iPad. Try again when it is unlocked and online."
            }
            message = accountDeletionStatus
        }
    }

    private func removeDeletedAccountData(_ intent: DeviceAccountDeletionIntent) throws {
        guard intent.serverConfirmed else { throw DeviceError.message("The server has not confirmed account deletion.") }
        guard intent.origin == CloudClient.origin.absoluteString else { throw DeviceError.message("The deletion receipt belongs to a different server.") }
        guard let profileRepository, let localLedger else { throw DeviceError.message("The account was deleted, but local storage is unavailable. Reopen Screenpunk to finish removing its data.") }
        detachAccountLibrary()
        billing.removeDeletedAccount(origin: intent.origin, accountID: intent.accountID, activeJournalOwner: intent.billingJournalOwner)
        for profile in intent.profiles {
            guard profile.cloudAccountID == intent.accountID else { throw DeviceError.message("A saved profile belongs to another account.") }
            keyboardDrafts = keyboardDrafts.filter { !$0.key.hasPrefix(profile.permissionOwner + "\n") }
            try localLedger.removeProfile(profileID: profile.id)
            try HomeAssistantDeviceVault().removeOwner(profile.permissionOwner)
            try GenericConnectionDeviceVault().removeOwner(profile.permissionOwner)
            try customHTTPVault.removeOwner(profile.permissionOwner)
            try ScreenLibrary.deleteAccountScreens(accountID: intent.accountID, profile: profile)
        }
        if intent.profiles.isEmpty { try ScreenLibrary.deleteAccountScreens(accountID: intent.accountID, profile: nil) }
        try ScreenPreferenceStore.shared.remove(dashboardIDs: intent.preferenceDashboardIDs)
        for key in intent.preferenceKeys { UserDefaults.standard.removeObject(forKey: key) }
        try profileRepository.removeAccountProfiles(accountID: intent.accountID)
        try cloud.clearDeletedAccountSession(accountID: intent.accountID)
        email = nil
        try openLibrary()
        try cloud.finishAccountDeletion()
        accountDeletionIntent = nil
        startConnection()
    }

    /// Runs independently of Cloud I/O, including when outbound requests are stalled.
    func reconcileTemporary() {
        _ = settleAcknowledgedPending()
        takingLonger = requestPending && progressTiming.isTakingLonger(at: Date())
        do { try library?.reconcileTemporary(); if screen?.id != library?.selected?.id { refreshScreen() } }
        catch { message = error.localizedDescription }
    }
    /// Observe installed trigger declarations independently of the selected renderer.
    private func updateTemporaryHomeAssistant() {
        let next = currentTemporaryHomeAssistantTargets()
        for (id, previous) in temporaryHomeAssistantTargets where next[id] != previous {
            temporaryHomeAssistantTasks.removeValue(forKey: id)?.cancel()
        }
        temporaryHomeAssistantTargets = next
        for (id, target) in next where temporaryHomeAssistantTasks[id] == nil {
            startTemporaryHomeAssistant(target)
        }
    }

    private func startTemporaryHomeAssistant(_ target: TemporaryHomeAssistantTarget) {
        guard let configuration = target.scope.temporaryActivation else { return }
        let scope = target.scope
        let runtime = HomeAssistantDeviceRuntime(vault: HomeAssistantDeviceVault(), scope: { scope })
        temporaryHomeAssistantTasks[target.screenID] = Task { [weak self] in
            var retry = 2
            while !Task.isCancelled {
                guard self?.isCurrentTemporaryHomeAssistantTarget(target) == true else { break }
                do {
                    let bytes = try await runtime.readTemporaryActivationState(revision: scope.revision)
                    try Task.checkCancellation()
                    guard let self, self.isCurrentTemporaryHomeAssistantTarget(target), let library = self.library else { break }
                    let priorSelection = library.state.selectedID
                    let priorActivation = library.temporaryActivationID
                    try library.receiveTemporaryHomeAssistantState(bytes, screenID: target.screenID, revision: scope.revision,
                                                                   configuration: configuration)
                    if priorSelection != library.state.selectedID || priorActivation != library.temporaryActivationID {
                        self.refreshScreen()
                    }
                    retry = 2
                } catch is CancellationError { break }
                catch { retry = min(retry * 2, 30) }
                do { try await Task.sleep(for: .seconds(retry)) } catch { break }
            }
            guard !Task.isCancelled, let self, self.temporaryHomeAssistantTargets[target.screenID] == target else { return }
            self.temporaryHomeAssistantTasks.removeValue(forKey: target.screenID)
        }
    }

    private func isCurrentTemporaryHomeAssistantTarget(_ target: TemporaryHomeAssistantTarget) -> Bool {
        guard foreground, connectionActive, !accountOperationInProgress,
              activeProfile?.permissionOwner == target.scope.owner, let library, ObjectIdentifier(library) == target.library,
              temporaryHomeAssistantTargets[target.screenID] == target else { return false }
        return true
    }

    private func currentTemporaryHomeAssistantTargets() -> [String: TemporaryHomeAssistantTarget] {
        guard foreground, connectionActive, !accountOperationInProgress, let library,
              let owner = activeProfile?.permissionOwner else { return [:] }
        let byDashboard = Dictionary(grouping: installedManifests, by: \.dashboardId)
        let vault = HomeAssistantDeviceVault()
        var targets: [String: TemporaryHomeAssistantTarget] = [:]
        for manifest in installedManifests {
            guard byDashboard[manifest.dashboardId]?.count == 1, let configuration = manifest.deviceBehavior?.temporaryActivation,
                  let target = library.state.screens.first(where: { $0.revision == manifest.revision }),
                  manifest.connections.contains(where: { connection in
                      connection.alias == "home" && (connection.operations?.contains(where: { $0.name == "getStates" && $0.kind == "http" }) ?? true)
                  }),
                  vault.isConfigured(owner: owner, dashboardID: manifest.dashboardId, revision: target.revision) else { continue }
            targets[target.id] = .init(library: ObjectIdentifier(library), screenID: target.id,
                scope: .init(owner: owner, revision: target.revision, dashboardId: manifest.dashboardId, temporaryActivation: configuration))
        }
        return targets
    }

    private func stopTemporaryHomeAssistant() {
        for task in temporaryHomeAssistantTasks.values { task.cancel() }
        temporaryHomeAssistantTasks.removeAll()
        temporaryHomeAssistantTargets.removeAll()
    }

    private var pollsLocalAuthoring: Bool {
        currentRequestRoute == .local && (pendingID != nil || routePreference == .local || !cloudAccountMatches)
    }
    private func reconcileCloudProfile(_ profileID: String?) throws {
        guard let profileID, cloudAccountMatches, let session = cloud.session,
              let profile = activeProfile, let library, let accountID = cloud.localAccountID else { return }
        let binding = LocalCloudBinding(accountID: accountID, profileID: profileID, deviceID: session.deviceId)
        guard profile.cloudBinding != binding || session.profileID != profileID else { return }
        if profile.cloudBinding == nil {
            try profileRepository?.validateLink(profileID: profile.id, binding: binding)
            let linked = try library.linkLocalProfile(profile, to: binding)
            try profileRepository?.adoptLinkedProfile(linked); activeProfile = linked
        } else if profile.cloudBinding != binding {
            activeProfile = try profileRepository?.activateCloudProfile(accountID: accountID, profileID: profileID, deviceID: session.deviceId)
        }
        try cloud.rememberProfile(profileID)
        screenDataRendererEpoch = UUID()
        resetScreenDataWork(disconnectSocket: false)
        refreshScreenDataPermissions()
        requestScreenDataInventory()
        refreshCatalogScope()
        refreshPreferences()
        requestPreferenceSync()
        requestCatalogCatchUp()
    }
    private func poll(generation: UUID) async -> Bool {
        if settleAcknowledgedPending() { return true }
        if pollsLocalAuthoring { return await pollLocal(generation: generation) }
        guard !cloudAuthorizationRejected, cloudAccountMatches, let token = cloud.session?.accessToken,
              email != nil, foreground, generation == connectionGeneration else { return true }
        guard library != nil, authoring != nil else { agentReady = false; return true }
        do {
            try await cloud.enrollInstallation()
            guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
            try await flushCancellations()
            guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
            try await syncInventory()
            guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
            let socketEpoch = cloudSocketEpoch
            let read = nextListenerStatusRead()
            let status: AgentStatus = try await cloud.call("api/device/status")
            guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
            if cloudSocketEpoch == socketEpoch { observeCloudListener(status, read: read) }
            try reconcileCloudProfile(status.profileID)
            if cloudBindingMatches {
                try await syncInventory()
                guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
            }
            cloudAgentReady = status.agentReady && cloudBindingMatches
            cloudSupportsV2 = status.authoringCapabilities?.supportsV2 == true
            agentReady = routePreference == .automatic ? (localAgent != nil || cloudAgentReady) : cloudAgentReady
            if let command = status.command { await applyCommand(command) }
            guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
            if pendingID == nil, !busy, !requestPending, let profileID = cloud.session?.profileID, let deviceID = cloud.session?.deviceId,
               let recovered = library?.recoverableCloudCompletion(status.awaitingApplicationRequestIDs ?? [], profileID: profileID, deviceID: deviceID) {
                pendingID = recovered
                try persistPending()
                busy = true; requestPending = true; canCancelRequest = true
            }
            var discoveredRequest: AgentRequest?
            if pendingID == nil, !busy, !requestPending, library?.state.submissionKey == nil, let latest = status.latestRequest {
                discoveredRequest = try await CloudRequestRecovery.discoverPending(id: latest.id, status: latest.status,
                    consumedID: consumedID, lastAppliedRequestID: library?.state.lastRequest) { id in
                    try await self.cloud.call("api/device/requests/\(id)", authoringVersion: 2)
                }
                guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
                guard pendingID == nil, !busy, !requestPending, library?.state.submissionKey == nil else { return true }
                if let discoveredRequest {
                    pendingID = discoveredRequest.id
                    try persistPending()
                }
            }
            if let id = pendingID {
                if library?.authoringRequestV2(id: id) != nil { return await pollAuthoringV2(generation: generation) }
                guard let authoring else { throw DeviceError.message("Local authoring storage is unavailable.") }
                if library?.authoringRequest(id: id) == nil {
                    let restored: AgentRequest
                    if let discoveredRequest { restored = discoveredRequest }
                    else { restored = try await cloud.call("api/device/requests/\(id)", authoringVersion: 2) }
                    guard pendingID == id, cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
                    if let snapshot = restored.snapshotV2 {
                        guard snapshot.delivery.route == "cloud", snapshot.context.profileID == cloud.session?.profileID, snapshot.context.deviceID == cloud.session?.deviceId else { throw DeviceError.message("This request belongs to a different connection.") }
                        try library?.saveAuthoringRequest(snapshot)
                        return await pollAuthoringV2(generation: generation)
                    }
                    if let unsupported = restored.canonicalUnsupported {
                        try finishRequest(id, status: unsupported.code, failure: unsupported.message)
                        return true
                    }
                    guard let snapshot = restored.snapshot, snapshot.delivery.route == "cloud", snapshot.context.profileID == cloud.session?.profileID, snapshot.context.deviceID == cloud.session?.deviceId else {
                        throw DeviceError.message("This request has no matching authoring snapshot. Your screen is unchanged.")
                    }
                    try library?.saveAuthoringRequest(snapshot)
                }
                let delivery = try await authoring.reconcile(requestID: id)
                guard pendingID == id, cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
                if cancelledLocally.contains(id) { cancelKnownRequest(id); return false }
                switch delivery {
                case .completed(let result):
                    agentWorkingRequestID = nil
                    let receipt: ApplicationReceiptV1
                    if library?.authoringRequest(id: id)?.context.screenID == "legacy" {
                        guard let library else { throw DeviceError.message("Local authoring storage is unavailable.") }
                        receipt = try library.rejectAuthoringResult(result, reason: "This request started before verified screen revisions were available. Please send your instructions again to edit the current screen.")
                    } else {
                        receipt = try measureRequestApply(id) { try authoring.apply(result) }
                    }
                    requestPreferenceSync() // Native commit precedes any transport acknowledgement.
                    refreshScreen(); refreshPreferences()
                    message = receipt.status == "applied" ? (result.preferenceMutations?.isEmpty == false ? "Preference saved" : result.answer) : (receipt.message ?? "This result conflicts with a newer change. Your screen is unchanged.")
                    consumedID = id; pendingID = nil; busy = false; requestPending = false; canCancelRequest = false; takingLonger = false; canRetry = false
                    try persistPending()
                    try await syncInventory()
                    guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
                case .deliveryUncertain(let failure), .needsAttention(let failure):
                    agentWorkingRequestID = nil
                    busy = true; requestPending = true; canCancelRequest = true; canRetry = false; progressCaption = "Delivery needs attention"; message = failure
                case .ended(let status, let failure):
                    try finishRequest(id, status: status, failure: failure)
                case .pending(let progress):
                    agentWorkingRequestID = id
                    try library?.submissionAccepted(deadline: progress.deadlineAt)
                    busy = true; requestPending = true; canCancelRequest = true; canRetry = false
                    progressCaption = progress.caption ?? "Your agent is working…"
                    progressTiming.lastProgressAt = Date(timeIntervalSince1970: (progress.updatedAt ?? Date().timeIntervalSince1970 * 1000) / 1000)
                }
            }
            return true
        } catch {
            guard cloud.session?.accessToken == token, foreground, generation == connectionGeneration, !Task.isCancelled else { return true }
            agentWorkingRequestID = nil
            if (error as? DeviceError)?.authorizationRejected == true { rejectCloudAuthorization() }
            agentReady = routePreference == .automatic && localAgent != nil
            if pendingID != nil { busy = true }
            message = (library?.state.cancelIntents?.isEmpty == false)
                ? "Result cancelled on this device. Cloud confirmation will retry when connected; the agent may still be running."
                : error.localizedDescription
            return cloudAuthorizationRejected
        }
    }
    /// Resolve a new request before sealing source or preparing delivery. A prepared
    /// request never enters this resolver again, including after a send failure.
    func send(_ text: String, linkedEdit: ScreenLibrary.LinkedCatalogEditScope? = nil,
              expectedLinkedEdit: LinkedEditOptions? = nil) async {
        guard accountDeletionIntent == nil, !accountOperationInProgress, linkedEditPrompt == nil else { return }
        // First Cloud linking can change the wire profile while keeping the same
        // native descriptor. Rebind idle adapters before capturing any new request.
        if !busy, pendingID == nil, library?.state.submissionKey == nil, localAgent != nil,
           localTransportAuthoringProfileID != activeProfile?.authoringProfileID { reloadLocalAgent() }
        guard !busy, let library, let profile = activeProfile,
              !needsAgentSetup || library.state.submissionKey != nil else { return }
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
        guard pendingID == nil else { return }
        if let expectedLinkedEdit, !linkedEditIsCurrent(expectedLinkedEdit) {
            message = "This screen changed. Reopen it before sending your instructions."
            return
        }
        let options = expectedLinkedEdit ?? linkedEditOptions(for: screen?.id)
        guard options?.blocksEditing != true else {
            message = "Finish reviewing this screen’s shared update in Settings first."
            return
        }
        guard linkedEdit == nil || options != nil else {
            message = "This screen is no longer linked. Reopen it before sending your instructions."
            return
        }
        if let options, linkedEdit == nil {
            linkedEditPrompt = .init(text: text, options: options)
            return
        }
        if let options, let linkedEdit { retryLinkedEdit = (options, linkedEdit, text) }
        else { retryLinkedEdit = nil }
        let generation = connectionGeneration
        let endpoint = try? configurationRepository?.load()
        let token = cloud.session?.accessToken
        let selectedScreen = screen?.revision
        agentWorkingRequestID = nil
        // Preflight is already visible pending work. Reset the prior request's warning
        // before publishing that state or awaiting either agent's readiness.
        progressTiming.begin(at: Date())
        takingLonger = false; canRetry = false
        busy = true; requestPending = true; canCancelRequest = false; message = nil; progressCaption = "Checking available agents…"
        do {
            try library.saveInstruction(text)
            let resolved = try await resolveNewRequest(requiresV2: screen != nil, requiresPackageAssets: screen?.hasNativeAssets == true)
            guard self.library === library, activeProfile?.id == profile.id,
                  activeProfile?.authoringProfileID == profile.authoringProfileID,
                  activeProfile?.authoringDeviceID == profile.authoringDeviceID,
                  connectionGeneration == generation, cloud.session?.accessToken == token,
                  screen?.revision == selectedScreen,
                  options.map(linkedEditIsCurrent) ?? true, !Task.isCancelled else { throw CancellationError() }
            if resolved.route == .local {
                guard try localLedger?.unresolvedRecord() == nil else { throw DeviceError.message("An earlier local delivery is unresolved. Finish or cancel it before sending another request.") }
                guard let current = try configurationRepository?.load(), current.id == endpoint?.id,
                      current.hostKeySHA256 == endpoint?.hostKeySHA256,
                      current.credentialReference == endpoint?.credentialReference else { throw DeviceError.message("The computer connection changed. Send your saved instructions again after checking Account.") }
            }
            selectedRoute = resolved.route
            resolvedAgentName = resolved.route == .local ? (localAgent?.name ?? "Local agent") : "Cloud agent"
            if resolved.version == 1 {
                busy = false; await sendV1(text); return
            }
            let base = try makeAuthoringRequest(text: text, library: library, route: resolved.route, preparingV2: true)
            let snapshot = try library.makeAuthoringRequestV2(from: base)
            // Pin + snapshot durability precede delivery state and any network turn.
            try library.prepareAuthoringRequest(snapshot, text: text, screen: nil,
                                                linkedEdit: linkedEdit, forkName: linkedEdit == .thisDevice ? options?.forkName : nil)
            retryLinkedEdit = nil
            pendingID = snapshot.requestID; pendingScreenID = snapshot.context.screenID
            busy = false
            await submitPreparedV2(snapshot, library: library)
        } catch {
            guard self.library === library, activeProfile?.id == profile.id else { return }
            agentWorkingRequestID = nil
            busy = false; requestPending = false
            // No delivery exists when listener preflight fails. Keep the saved
            // instruction, but let the existing Dismiss action close this notice.
            canRetry = !(error is CloudListenerSetupRequired)
            canCancelRequest = library.state.submissionKey != nil
            message = error is CancellationError ? "The connection changed while checking agents. Your instructions are saved here; send them again when ready." : "Your instructions are saved here. " + error.localizedDescription
        }
    }
    private struct CloudListenerSetupRequired: LocalizedError {
        var errorDescription: String? { "Ask your Cloud agent to listen for requests." }
    }
    private struct ResolvedRoute { let route: AuthoringRoute; let version: Int }
    private func resolveNewRequest(requiresV2: Bool, requiresPackageAssets: Bool) async throws -> ResolvedRoute {
        RequestTimeline.record(.preflightStart)
        defer { RequestTimeline.record(.preflightEnd) }
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
            repairMessage = "The paired computer needs sign-in or credential repair. Open Account to reconnect before sending this request."
        }
        let initial = NewRequestRoutePolicy.resolve(preference: routePreference, local: local, cloud: cloudBindingMatches ? .unchecked : .notConfigured, requiresV2: requiresV2)
        func resolved(_ decision: NewRequestRoutePolicy.Decision) throws -> ResolvedRoute {
            switch decision {
            case .use(let route, let version): return .init(route: route, version: version)
            case .needsComputer: throw DeviceError.message("Your computer is unavailable. " + LocalAgentSettingsModel.unavailableGuidance(for: localAgent))
            case .repairComputer: throw DeviceError.message(repairMessage)
            case .connectCloud: throw DeviceError.message(routePreference == .cloud ? "Connect your Cloud agent in Account." : "The computer is unavailable and no matching Cloud agent is configured. Reconnect the computer in Account, or sign in to use Cloud.")
            case .listenCloud: throw CloudListenerSetupRequired()
            case .updateCloud: throw DeviceError.message("Your Cloud agent needs the asset-preserving update before it can edit this screen. Refresh its Screenpunk tools or reconnect your computer.")
            case .checkCloud: throw DeviceError.message("Cloud readiness could not be checked. Retry shortly.")
            }
        }
        guard initial == .checkCloud else { return try resolved(initial) }
        let status: AgentStatus = try await cloud.call("api/device/status", authoringVersion: 2)
        guard status.profileID == activeProfile?.cloudBinding?.profileID else { throw DeviceError.message("The Cloud connection changed. Review your account connection.") }
        cloudAgentReady = status.agentReady; cloudSupportsV2 = status.authoringCapabilities?.supportsV2 == true
        cloudSupportsConnectionPrefill = status.authoringCapabilities?.features.contains(AuthoringContract.connectionPrefillFeature) == true
        cloudSupportsCustomHTTP = status.authoringCapabilities?.features.contains("custom-http-v1") == true
        if cloudAgentReady { agentReady = true }
        let supportsSelectedPackage = cloudSupportsV2 && (!requiresPackageAssets || status.authoringCapabilities?.supportsPackageAssets == true)
        return try resolved(NewRequestRoutePolicy.resolve(preference: routePreference, local: local, cloud: status.agentReady ? .ready(supportsV2: supportsSelectedPackage) : .notReady, requiresV2: requiresV2))
    }
    private func localRepairMessage(_ reason: LocalAgentRepairReason) -> String {
        switch reason {
        case .hostIdentityChanged: return "The computer’s SSH identity changed. Review its fingerprint in Account → Advanced before reconnecting."
        case .wrongBinding: return "This computer connection changed. Review the paired agent before continuing."
        case .unsupportedVersion: return "Codex on the Mac is no longer a supported version. Review Mac setup in Account."
        case .invalidCredentials: return "The Mac rejected this iPad’s connection credential. Pair again in Account."
        case .missingConversationHistory: return "This conversation’s saved history is unavailable. Reconnect to reconcile it; Screenpunk has not resubmitted the request."
        case .unsafeConfiguration, .unsupportedProtocol: return "The Mac’s secure connection settings need review. Open Mac setup in Account before continuing."
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
    private func localReceiptRecovery(_ receipt: ApplicationReceiptV1, record: LocalDeliveryRecord?) -> PreparedRequestRecoveryPolicy.LocalReceiptRecovery {
        guard let record, record.profileID == activeProfile?.id else { return .preserve }
        let adapterAvailable = record.contractVersion == 2 ? localAuthoringV2 != nil : localAuthoring != nil
        return PreparedRequestRecoveryPolicy.localReceiptRecovery(receipt, record: record, adapterAvailable: adapterAvailable)
    }
    private func releaseLocalReceiptPending(_ id: String, settled: Bool, library: ScreenLibrary) throws {
        guard pendingID == id else { return }
        let consumed = settled ? id : consumedID
        try library.savePending(id: nil, screenID: nil, consumedID: consumed)
        pendingID = nil; pendingScreenID = nil; consumedID = consumed
        agentWorkingRequestID = nil
        busy = false; requestPending = false; canCancelRequest = false; canRetry = false; takingLonger = false
    }
    private func recoveryAction(_ snapshot: AuthoringRequestV2, library: ScreenLibrary) -> PreparedRequestRecoveryPolicy.Action {
        PreparedRequestRecoveryPolicy.action(requestID: snapshot.requestID,
            route: AuthoringRoute(rawValue: snapshot.delivery.route) ?? .cloud,
            deadlineAt: snapshot.deadlineAt, now: Int64(Date().timeIntervalSince1970 * 1000),
            hasReceipt: library.state.authoring?.receipts.values.contains(where: { $0.requestID == snapshot.requestID }) == true,
            submissionKey: library.state.submissionKey, cancelled: cancelledLocally.contains(snapshot.requestID))
    }
    private func ownsSubmission(_ id: String, library: ScreenLibrary) -> Bool {
        self.library === library && PreparedRequestRecoveryPolicy.ownsSubmission(requestID: id,
            pendingID: pendingID, submissionKey: library.state.submissionKey, cancelled: cancelledLocally.contains(id))
    }
    private func submitPreparedV2(_ snapshot: AuthoringRequestV2, library: ScreenLibrary) async {
        if snapshot.delivery.route == "local" {
            let generation = connectionGeneration
            await localConnectionLifecycle.wait()
            guard foreground, self.library === library, generation == connectionGeneration, !Task.isCancelled else { return }
        }
        guard ownsSubmission(snapshot.requestID, library: library) else { return }
        if pendingID == snapshot.requestID, settleAcknowledgedPending() { return }
        let route = AuthoringRoute(rawValue: snapshot.delivery.route) ?? .cloud
        guard let coordinator = route == .local ? localAuthoringV2 : cloudAuthoringV2 else { message = "Reconnect this request’s agent in Settings. Your instructions are saved."; return }
        switch recoveryAction(snapshot, library: library) {
        case .cancelled: message = "This request was cancelled. Its delivery will not be retried."; return
        case .acknowledgeReceipt, .reconcile:
            pendingID = snapshot.requestID
            _ = await pollAuthoringV2(generation: connectionGeneration)
            return
        case .retrySameRequest: break
        }
        let generation = connectionGeneration
        selectedRoute = route; resolvedAgentName = route == .local ? (localAgent?.name ?? "Local agent") : "Cloud agent"
        agentWorkingRequestID = nil
        busy = true; requestPending = true; canCancelRequest = true; canRetry = false; takingLonger = false
        progressTiming.begin(at: Date())
        pendingID = snapshot.requestID; pendingScreenID = snapshot.context.screenID
        progressCaption = "Sending to \(resolvedAgentName ?? "your agent")…"
        do {
            try persistPending()
            let accepted = try await coordinator.submit(snapshot)
            guard ownsSubmission(snapshot.requestID, library: library), generation == connectionGeneration else { return }
            try library.submissionAccepted(deadline: Double(accepted.deadlineAt))
            agentWorkingRequestID = accepted.requestID
            progressCaption = "\(resolvedAgentName ?? "Your agent") is working on this screen…"
        } catch {
            guard ownsSubmission(snapshot.requestID, library: library), generation == connectionGeneration else { return }
            agentWorkingRequestID = nil
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
                agentWorkingRequestID = nil
                canCancelRequest = false
                try await coordinator.acknowledge(receipt)
                guard self.library === library, pendingID == id, generation == connectionGeneration else { return true }
                consumedID = id; pendingID = nil; busy = false; requestPending = false; canCancelRequest = false; canRetry = false; takingLonger = false
                try persistPending(); refreshScreen(); refreshPreferences(); return true
            }
            let delivery = try await coordinator.reconcile(requestID: id)
            guard self.library === library, pendingID == id, generation == connectionGeneration, !Task.isCancelled else { return true }
            if cancelledLocally.contains(id) { return true }
            switch delivery {
            case .completed(let result):
                agentWorkingRequestID = nil
                let receipt = try measureRequestApply(id) { try coordinator.apply(result) }
                if snapshot.delivery.route == "cloud" || (receipt.status == "applied" && result.preferenceMutations?.isEmpty == false) {
                    requestPreferenceSync() // A stalled acknowledgement must not delay a committed preference.
                }
                refreshScreen(); refreshPreferences()
                if receipt.status == "applied", result.screen != nil,
                   library.linkedCatalogScreen(id: snapshot.context.screenID)?.pendingRevision != nil {
                    message = "Saved on this iPad. Waiting to update the linked iPads."
                } else {
                    message = receipt.status == "applied" ? (result.preferenceMutations?.isEmpty == false ? "Preference saved" : result.answer) : (receipt.message ?? "Your screen is unchanged.")
                }
                // Keep pending identity until acknowledgement; restart can finish the exact receipt.
                agentWorkingRequestID = nil
                canCancelRequest = false
                try await coordinator.acknowledge(receipt)
                guard self.library === library, pendingID == id, generation == connectionGeneration else { return true }
                consumedID = id; pendingID = nil; busy = false; requestPending = false; canCancelRequest = false; canRetry = false; takingLonger = false
                try persistPending()
            case .ended(let status, let failure): try finishRequest(id, status: status, failure: failure)
            case .pending(let progress):
                agentWorkingRequestID = id
                try library.submissionAccepted(deadline: progress.deadlineAt)
                busy = true; requestPending = true; canCancelRequest = true; canRetry = false
                progressCaption = progress.caption ?? "\(resolvedAgentName ?? "Your agent") is working…"
                if let updated = progress.updatedAt { progressTiming.lastProgressAt = Date(timeIntervalSince1970: updated / 1000) }
            case .deliveryUncertain(let failure), .needsAttention(let failure):
                agentWorkingRequestID = nil
                busy = true; requestPending = true; canCancelRequest = true; canRetry = false; progressCaption = "Delivery needs attention"; message = failure
            }
            return AuthoringRefreshPolicy.reconciliationSucceeded(delivery, route: snapshot.delivery.route)
        } catch {
            guard self.library === library, pendingID == id, generation == connectionGeneration else { return true }
            agentWorkingRequestID = nil
            progressCaption = error.localizedDescription; canCancelRequest = !library.hasApplicationReceipt(requestID: id)
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
            refreshAuthoringRoute()
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
        agentWorkingRequestID = nil
        busy = true; requestPending = true; canCancelRequest = false; takingLonger = false; canRetry = false
        progressTiming.begin(at: Date())
        progressCaption = "Sending your instructions…"; message = nil
        var attemptID: String?
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
            attemptID = snapshot.requestID
            let accepted = try await authoring.submit(snapshot)
            guard cloud.session?.accessToken == session.accessToken, self.library === library, generation == connectionGeneration else { return }
            guard ownsSubmission(snapshot.requestID, library: library) else { return }
            try library.submissionAccepted(deadline: Double(accepted.deadlineAt))
            agentWorkingRequestID = accepted.requestID
            pendingID = accepted.requestID; try persistPending()
            canCancelRequest = true; progressCaption = "Your agent is working on this screen…"; requestRefresh()
        } catch {
            if let attemptID { guard ownsSubmission(attemptID, library: library) else { return } }
            else { guard pendingID == nil, library.state.submissionKey == nil else { return } }
            guard cloud.session?.accessToken == session.accessToken, self.library === library, generation == connectionGeneration else { return }
            agentWorkingRequestID = nil
            busy = false; requestPending = false; canRetry = true; canCancelRequest = library.state.submissionKey != nil; message = error.localizedDescription; requestRefresh()
        }
    }
    private func makeAuthoringRequest(text: String, session: DeviceSession? = nil, library: ScreenLibrary, route: AuthoringRoute? = nil, preparingV2: Bool = false) throws -> AuthoringRequestV1 {
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
        guard preparingV2 || screen?.hasNativeAssets != true else { throw DeviceError.message("This screen requires an agent that supports package assets.") }
        let source = preparingV2 ? nil : screen.map { AuthoringScreen(title: $0.artifact.title, entry: $0.artifact.entry, files: $0.artifact.files.map { .init(path: $0.path, content: $0.content) }) }
        let supportsScreenData = route == .local || screenDataSocketID != nil
        let supportsCustomHTTP = preparingV2 && (route == .local || cloudSupportsCustomHTTP)
        let supportsConnectionPrefill = supportsCustomHTTP && route == .cloud && cloudSupportsConnectionPrefill
        let request = AuthoringRequestV1(requestID: UUID().uuidString, createdAt: now, deadlineAt: now + 10 * 60 * 1000, designGuidance: AuthoringContract.designGuidance(supportsScreenData: supportsScreenData, supportsCustomHTTP: supportsCustomHTTP, supportsConnectionPrefill: supportsConnectionPrefill), runtime: AuthoringContract.runtime(supportsScreenData: supportsScreenData, supportsCustomHTTP: supportsCustomHTTP, supportsConnectionPrefill: supportsConnectionPrefill), services: services, preferences: library.preferences(profileID: profileID, deviceID: deviceID, screenID: screenID), context: .init(profileID: profileID, deviceID: deviceID, screenID: screenID, baseRevision: screen?.revision, userRequest: text, currentScreen: source, viewport: .init(width: size.width, height: size.height, scale: scale, orientation: size.width > size.height ? "landscape" : "portrait")), delivery: .init(route: route.rawValue))
        return preparingV2 ? request : try AuthoringContract.seal(request)
    }
    private func measureRequestApply(_ requestID: String, _ apply: () throws -> ApplicationReceiptV1) rethrows -> ApplicationReceiptV1 {
        RequestTimeline.record(.applyStart, requestID: requestID)
        defer { RequestTimeline.record(.applyEnd, requestID: requestID) }
        return try apply()
    }
    func keepWaiting() {
        progressTiming.warningDismissedAt = Date(); takingLonger = false
        // Explicit user recovery reads the same durable request; it never resubmits
        // agent work or starts periodic checks while Cloud is idle.
        requestRefresh()
    }
    private func finishRequest(_ id: String, status: String, failure: String?) throws {
        if agentWorkingRequestID == id { agentWorkingRequestID = nil }
        try library?.retireAuthoringRequest(id: id)
        let alreadyApplied = status == CloudRequestRecovery.alreadyAppliedStatus
        message = alreadyApplied ? nil : (status == "timed_out" ? "This request timed out. Your screen is unchanged." : (failure ?? "Request ended. Your screen is unchanged."))
        canRetry = !alreadyApplied && status != "cancelled" && status != "legacy_payload_unsupported"
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
        if let retry = retryLinkedEdit {
            guard linkedEditIsCurrent(retry.options) else {
                retryLinkedEdit = nil
                canRetry = false
                message = "This screen changed. Reopen it before retrying your instructions."
                return
            }
            Task { await send(retry.text, linkedEdit: retry.scope, expectedLinkedEdit: retry.options) }
            return
        }
        guard let text = library.state.lastInstruction else { return }
        Task { await send(text) }
    }
    func cancelRequest() {
        guard canCancelRequest, let id = pendingID ?? library?.state.submissionKey else { return }
        guard library?.hasApplicationReceipt(requestID: id) != true else {
            canCancelRequest = false; requestRefresh(); return
        }
        cancelKnownRequest(id)
    }
    private func cancelKnownRequest(_ id: String, timedOut: Bool = false) {
        if agentWorkingRequestID == id { agentWorkingRequestID = nil }
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
                catch DeviceError.http(let status, let text) where status != 401 && (400..<500).contains(status) { deferredFailure = DeviceError.http(status, text) }
                try requireCurrent()
            }
        }
        guard let profileID = session.profileID else { return }
        let conflictsAwaitingReview = Set(library.preferenceConflicts.map(\.id))
        var receivedCurrentRecords = false
        for entry in library.preferenceOutbox where !conflictsAwaitingReview.contains(entry.record.id) && (entry.record.scope != "device" || entry.record.targetID == session.deviceId) {
            try requireCurrent()
            let response: PreferenceSyncResponse
            do {
                response = try await cloud.call("api/device/preferences/sync", method: "POST", body: ["operationID": entry.id, "profileID": profileID, "mutations": try CloudAuthoringTransport.object([entry.mutation]), "origins": [entry.record.id: entry.record.originRequestID]])
            } catch DeviceError.http(let status, let text) where status != 401 && (400..<500).contains(status) {
                try requireCurrent(); deferredFailure = DeviceError.http(status, text); continue
            }
            try requireCurrent()
            guard response.operationID == entry.id else { throw DeviceError.message("Cloud did not confirm preference synchronization.") }
            try library.applyPreferenceSync(records: response.records, accepted: try response.acceptedMap(), sent: [entry], conflicts: try response.conflictMap(), profileID: profileID, deviceID: session.deviceId)
            receivedCurrentRecords = true
        }
        if !receivedCurrentRecords {
            let operationID = UUID().uuidString
            let response: PreferenceSyncResponse = try await cloud.call("api/device/preferences/sync", method: "POST", body: ["operationID": operationID, "profileID": profileID, "mutations": []])
            try requireCurrent()
            guard response.operationID == operationID else { throw DeviceError.message("Cloud did not confirm preference synchronization.") }
            try library.applyPreferenceSync(records: response.records, accepted: [:], sent: [], conflicts: try response.conflictMap(), profileID: profileID, deviceID: session.deviceId)
        }
        refreshPreferences()
        if let deferredFailure { throw deferredFailure }
    }
    /// Foreground recovery, committed edits and matching preference notices wake
    /// the same account sync. Only failed work retries while the account is idle.
    private func requestPreferenceSync() {
        guard preferenceSyncBinding != nil else { preferenceSyncPump.cancel(); return }
        preferenceSyncPump.wake { [weak self] in
            guard let self else { return true }
            return await self.syncPreferencesWhenAvailable()
        }
    }
    /// Explicit Cloud submission and the account pump share one scoped sync flight.
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
            guard !Task.isCancelled, connectionGeneration == binding.generation,
                  cloud.session?.accessToken == token else { return true }
            guard preferenceSyncBinding == binding else {
                // Enrollment can fill a previously nil profile ID; only wake
                // the same active library and Cloud binding under its new identity.
                if let next = preferenceSyncBinding, next.library == binding.library,
                   next.profileID == binding.profileID, next.cloud == binding.cloud {
                    requestPreferenceSync()
                }
                return true
            }
            var deviceNameSynced = true
            do {
                try await cloud.syncDeviceName()
                guard preferenceSyncBinding == binding, cloud.session?.accessToken == token, !Task.isCancelled else { return true }
                deviceNameSyncStatus = cloud.deviceNameSyncNotice
            } catch {
                guard preferenceSyncBinding == binding, cloud.session?.accessToken == token, !Task.isCancelled else { return true }
                if (error as? DeviceError)?.authorizationRejected == true { throw error }
                deviceNameSyncStatus = "Saved on this iPad. Cloud will retry the device name when connected."
                deviceNameSynced = false
            }
            guard preferenceSyncBinding == binding, cloud.session?.accessToken == token, !Task.isCancelled else { return true }
            try await syncPreferencesAndReceipts()
            guard preferenceSyncBinding == binding, cloud.session?.accessToken == token, !Task.isCancelled else { return true }
            preferenceSyncStatus = nil
            return deviceNameSynced
        } catch {
            guard preferenceSyncBinding == binding, cloud.session?.accessToken == token, !Task.isCancelled else { return true }
            if (error as? DeviceError)?.authorizationRejected == true {
                rejectCloudAuthorization()
                return true
            }
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
    var allInstalledScreensHidden: Bool {
        onboarding != .connectAgent && onboarding != .gallery &&
            hiddenScreenIDs.contains(ScreenLibrary.instructionsID) && installedScreens.allSatisfy { hiddenScreenIDs.contains($0.id) }
    }

    func setScreenShown(_ shown: Bool, id: String, owner: String) {
        guard !needsAgentSetup, !accountOperationInProgress, !owner.isEmpty, permissionOwner == owner, let library,
              shown || id != ScreenLibrary.instructionsID || canHideInstructions else { return }
        do {
            let oldSelection = library.state.selectedID
            try library.setScreenShown(shown, id: id)
            if oldSelection != library.state.selectedID { refreshScreen() }
            else { hiddenScreenIDs = library.state.hiddenScreenIDs ?? [] }
        } catch { message = error.localizedDescription }
    }

    func renameScreen(_ id: String, to name: String, owner: String) throws {
        guard !needsAgentSetup, !accountOperationInProgress, let library,
              !owner.isEmpty, owner == permissionOwner else {
            throw DeviceError.message("This screen’s library is unavailable.")
        }
        try library.renameScreen(id, to: name)
        installedScreens = library.state.screens
        if screen?.id == id { screen = installedScreens.first(where: { $0.id == id }) }
    }

    func selectScreen(_ id: String) {
        guard !needsAgentSetup, !accountOperationInProgress, let library, library.isScreenShown(id),
              library.containsRotationScreen(id) else { return }
        do { try library.selectVisible(id); refreshScreen(); settingsOpen = false }
        catch { message = error.localizedDescription }
    }
    func removeScreen(_ id: String) {
        guard !busy else { return }
        do { try library?.remove(id); refreshScreen() }
        catch { message = error.localizedDescription }
    }
    struct CustomConnectionUse: Identifiable {
        let screen: ScreenLibrary.Saved
        let manifest: DashboardManifest
        var id: String { screen.id + "/" + alias }
        let alias: String
        let declaration: CustomHTTPDeclaration
    }
    struct CustomConnectionPrompt: Identifiable {
        let id = UUID()
        let owner: String
        let use: CustomConnectionUse
        let status: CustomHTTPDeviceVault.Status?
    }
    @Published var customConnectionPrompt: CustomConnectionPrompt?

    private func offerCustomConnectionAccess(alias: String, owner: String, revision: String) {
        guard !settingsOpen, !accountOperationInProgress, permissionOwner == owner, screen?.revision == revision,
              customConnectionPrompt == nil,
              let use = customConnectionUses().first(where: { $0.alias == alias && $0.screen.revision == revision }),
              !customConnectionApproved(use),
              customHTTPVault.shouldOfferAccess(owner: owner, screenID: use.screen.id, alias: alias, declaration: use.declaration) else { return }
        customConnectionPrompt = .init(owner: owner, use: use, status: customConnectionStatus(use.declaration))
    }

    func approveCustomConnectionPrompt(_ prompt: CustomConnectionPrompt) {
        guard customConnectionPrompt?.id == prompt.id, screen?.id == prompt.use.screen.id,
              screen?.revision == prompt.use.screen.revision, let status = prompt.status else { return }
        defer { customConnectionPrompt = nil }
        do {
            try requireCurrentCustomConnection(prompt.use, owner: prompt.owner)
            try customHTTPVault.approve(owner: prompt.owner, screenID: prompt.use.screen.id,
                                        manifest: prompt.use.manifest, alias: prompt.use.alias,
                                        expectedGeneration: status.generation)
            refreshCustomConnections()
        } catch { message = "Connection access could not be approved. Review the current connection in Settings." }
    }

    private let customHTTPVault = CustomHTTPDeviceVault()
    private(set) var customHTTP: CustomHTTPDeviceRuntime?
    @Published private(set) var customHTTPRendererKey = ""

    func customConnectionUses(serviceID: String? = nil) -> [CustomConnectionUse] {
        installedScreens.flatMap { screen -> [CustomConnectionUse] in
            guard let manifest = installedManifests.first(where: { $0.revision == screen.revision }) else { return [] }
            return manifest.connections.compactMap { connection in
                guard let declaration = connection.customHTTP,
                      serviceID == nil || declaration.id == serviceID else { return nil }
                return .init(screen: screen, manifest: manifest, alias: connection.alias, declaration: declaration)
            }
        }
    }

    var savedCustomConnections: [CustomHTTPDeviceVault.SavedService] {
        guard !permissionOwner.isEmpty else { return [] }
        return customHTTPVault.savedServices(owner: permissionOwner)
    }

    func customConnectionProposal(_ use: CustomConnectionUse) -> CustomHTTPSetupProposal? {
        library?.connectionSetupProposal(screenID: use.screen.id, revision: use.screen.revision,
                                         alias: use.alias, declaration: use.declaration)
    }

    func customConnectionStatus(_ declaration: CustomHTTPDeclaration) -> CustomHTTPDeviceVault.Status? {
        guard !permissionOwner.isEmpty else { return nil }
        return customHTTPVault.status(owner: permissionOwner, declaration: declaration)
    }

    func customConnectionApproved(_ use: CustomConnectionUse) -> Bool {
        guard !permissionOwner.isEmpty else { return false }
        return customHTTPVault.isApproved(owner: permissionOwner, screenID: use.screen.id, manifest: use.manifest, alias: use.alias)
    }

    func saveCustomConnection(_ use: CustomConnectionUse, owner: String, fields: [String: String],
                              secret: String?, allowInsecureHTTP: Bool) throws {
        try requireCurrentCustomConnection(use, owner: owner)
        try customHTTPVault.save(owner: owner, declaration: use.declaration, fields: fields, secret: secret,
                                 allowInsecureHTTP: allowInsecureHTTP)
        refreshCustomConnections()
    }

    func setCustomConnectionApproved(_ approved: Bool, use: CustomConnectionUse, owner: String) throws {
        try requireCurrentCustomConnection(use, owner: owner)
        if approved {
            try customHTTPVault.approve(owner: owner, screenID: use.screen.id, manifest: use.manifest, alias: use.alias)
        } else {
            try customHTTPVault.deny(owner: owner, screenID: use.screen.id, alias: use.alias, declaration: use.declaration)
        }
        refreshCustomConnections()
    }

    func testCustomConnection(_ use: CustomConnectionUse, owner: String) async throws {
        try requireCurrentCustomConnection(use, owner: owner)
        guard let operation = use.declaration.operations.first(where: { $0.parameters.isEmpty }) else {
            throw DeviceError.message("This connection does not have a simple read to test.")
        }
        let runtime = CustomHTTPDeviceRuntime(owner: owner, screenID: use.screen.id, manifest: use.manifest, vault: customHTTPVault)
        _ = try await runtime.request(alias: use.alias, operation: operation.name, parameters: [:])
        try requireCurrentCustomConnection(use, owner: owner)
    }

    func removeCustomConnection(_ serviceID: String, owner: String) throws {
        guard !accountOperationInProgress, !owner.isEmpty, owner == permissionOwner else {
            throw DeviceError.message("This connection belongs to another library.")
        }
        try customHTTPVault.remove(owner: owner, serviceID: serviceID)
        refreshCustomConnections()
    }

    func requireCurrentCustomConnection(_ use: CustomConnectionUse, owner: String) throws {
        guard !accountOperationInProgress, !owner.isEmpty, owner == permissionOwner,
              customConnectionUses(serviceID: use.declaration.id).contains(where: {
                  $0.screen.id == use.screen.id && $0.screen.revision == use.screen.revision && $0.alias == use.alias
              }) else { throw DeviceError.message("This screen changed. Reopen its connection settings.") }
    }

    private func refreshCustomConnections() {
        refreshScreen()
        customHTTPRendererKey = UUID().uuidString
    }

    struct SetupRequirement {
        let name: String
        enum Kind { case screens, publicData, home, television, calendar, custom }
        let kind: Kind
        var unsupportedAlias: String? = nil
        var customAlias: String? = nil
    }
    var missingConnections: [SetupRequirement] {
        guard let screen else { return [] }
        if manifestIssues[screen.id] != nil { return [.init(name: "Screen connection configuration", kind: .screens)] }
        guard let manifest else { return [] }
        return manifest.connections.filter(\.required).compactMap { connection in
            if connection.publicHTTP != nil {
                return publicDataAllowed(manifest) ? nil : .init(name: connection.alias, kind: .publicData)
            }
            if let declaration = connection.customHTTP {
                // A configured connection asks for this screen’s permission on first use.
                return customConnectionStatus(declaration) == nil
                    ? .init(name: declaration.label, kind: .custom, customAlias: connection.alias) : nil
            }
            switch connection.alias {
            case "home":
                let configured = HomeAssistantDeviceVault().isConfigured(owner: permissionOwner, dashboardID: manifest.dashboardId, revision: manifest.revision)
                return configured ? nil : .init(name: "Home Assistant", kind: .home)
            case "googleTV":
                return DeviceConnectionReadiness.television(dashboardID: manifest.dashboardId) ? nil : .init(name: "Google TV", kind: .television)
            case "googleCalendar", "google-calendar":
                return DeviceConnectionReadiness.calendar(dashboardID: manifest.dashboardId) ? nil : .init(name: "Google Calendar", kind: .calendar)
            case "appleMaps": return nil // Native built-in provider, no account setup.
            default: return .init(name: connection.alias, kind: .screens, unsupportedAlias: connection.alias)
            }
        }
    }
    var canAllowCurrentPublicData: Bool {
        !missingConnections.isEmpty && missingConnections.allSatisfy { $0.kind == .publicData }
    }
    var currentPublicDataOrigins: [String] {
        Array(Set(manifest?.connections.compactMap { $0.publicHTTP?.origin } ?? [])).sorted()
    }
    func allowCurrentPublicData() {
        guard canAllowCurrentPublicData, let manifest else { return }
        setPublicDataAllowed(true, for: manifest)
    }
    var settingsScreenID: String?
    var settingsCustomConnectionAlias: String?
    func openSettings() {
        settingsScreenID = nil
        settingsCustomConnectionAlias = nil
        settingsPage = .account
        settingsOpen = true
    }
    func openConnectionSettings() {
        openConnectionSettings(customAlias: nil)
    }
    func openConnectionSettings(customAlias: String?) {
        settingsPage = .screens
        settingsScreenID = screen?.id
        settingsCustomConnectionAlias = customAlias
        settingsOpen = true
    }
    private func weatherOfferKey(_ screenID: String) -> String {
        "screenpunk.weatherLocationOffer.\(permissionOwner).\(screenID)"
    }
    var weatherLocationOfferScreen: ScreenLibrary.Saved? {
        guard !accountOperationInProgress, !needsAgentSetup, !busy, !requestPending,
              !permissionOwner.isEmpty, let screen, screen.id == "starter-weather",
              StarterWeather.location(in: screen.artifact) == .annArbor,
              !UserDefaults.standard.bool(forKey: weatherOfferKey(screen.id)) else { return nil }
        return screen
    }
    func acknowledgeWeatherLocationOffer(screenID: String, owner: String) {
        guard !owner.isEmpty, owner == permissionOwner else { return }
        objectWillChange.send()
        UserDefaults.standard.set(true, forKey: weatherOfferKey(screenID))
    }

    func applyWeatherLocation(_ location: WeatherLocation, screenID: String, revision: String, owner: String) throws {
        guard !owner.isEmpty, owner == permissionOwner, !accountOperationInProgress,
              !busy, !requestPending, !routeChangeBlocked, let library,
              let saved = library.state.screens.first(where: { $0.id == screenID && $0.revision == revision }) else {
            throw DeviceError.message("This screen or account changed. Reopen Weather settings and try again.")
        }
        let artifact = try StarterWeather.configuredArtifact(saved.artifact, location: location)
        try library.install(artifact, requestID: "weather-location-" + UUID().uuidString, replacing: screenID, selectInstalled: false, preserveRequestHistory: true)
        acknowledgeWeatherLocationOffer(screenID: screenID, owner: owner)
        refreshScreen()
    }

    private func publicApprovalKey(_ manifest: DashboardManifest) -> String? {
        guard let owner = activeProfile?.permissionOwner else { return nil }
        return PublicDataApprovalStore.key(owner: owner, dashboardID: manifest.dashboardId, connections: manifest.connections)
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
    var temporaryActivationID: String? { library?.temporaryActivationID }
    var canSwipeScreens: Bool {
        guard let library else { return false }
        let visible = library.rotationIDs.filter(library.isScreenShown)
        return visible.count > 1 || (!visible.isEmpty && (library.state.selectedID != visible.first || library.hasTemporaryScreen))
    }
    func swipe(_ offset: Int) { guard !needsAgentSetup else { return }; do { try library?.select(offset: offset); refreshScreen() } catch { message = error.localizedDescription } }
    func newScreen() { guard !needsAgentSetup else { return }; do { try library?.newScreen(); refreshScreen(); settingsOpen = false } catch { message = error.localizedDescription } }
    var rollbackScreenID: String? { library?.state.previous?.id }
    func rollback() { guard !needsAgentSetup else { return }; do { try library?.rollback(); refreshScreen(); settingsOpen = false } catch { message = error.localizedDescription } }
    private func syncInventory() async throws {
        guard cloudBindingMatches, let library, let token = cloud.session?.accessToken else { return }
        if screenDataSocketID != nil {
            requestScreenDataInventory()
            await screenDataInventoryTask?.value
            return
        }
        let generation = connectionGeneration
        let includeCatalogIDs = await cloud.catalogInventorySupported(token: token)
        guard cloudBindingMatches, self.library === library, connectionGeneration == generation,
              cloud.session?.accessToken == token, screenDataSocketID == nil, !Task.isCancelled else { return }
        var body: [String: Any] = ["screens": library.state.screens.map { library.catalogInventoryRow(for: $0, includeCatalogIDs: includeCatalogIDs) }]
        if let id = library.selected?.id { body["selectedID"] = id }
        let signature = String(data: try JSONSerialization.data(withJSONObject: body, options: .sortedKeys), encoding: .utf8)!
        guard signature != inventorySignature else { return }
        let _: EmptyResponse = try await cloud.call("api/device/screens", method: "POST", body: body, authorizationToken: token)
        guard self.library === library, connectionGeneration == generation, cloud.session?.accessToken == token,
              screenDataSocketID == nil, !Task.isCancelled else { return }
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
        guard accountDeletionIntent == nil else { return }
        guard foreground, !connectionActive, !accountOperationInProgress else { return }
        connectionActive = true
        updateTemporaryHomeAssistant()
        refreshCatalogScope()
        requestLinkedCatalogSync()
        if let token = cloud.session?.accessToken {
            Task { [weak self] in
                guard let self, self.foreground, self.cloud.session?.accessToken == token else { return }
                await self.billing.refreshBackupAccess(cloud: self.cloud)
            }
        }
        if pollsLocalAuthoring { agentReady = localAgent != nil; requestRefresh() }
        guard let session = cloud.session else { return }
        if shouldCheckCloudSetup { refreshCloudSetupStatus(reconcileProfile: true) }
        if cloudSocketToken == session.accessToken {
            // A Local adapter rebuild retained this socket; the new library
            // scope still needs catch-up, even without a new handshake.
            requestPreferenceSync()
            requestCatalogCatchUp()
            requestCloudStatusReconciliation()
            requestScreenDataInventory()
            return
        }
        cloudSocketToken = session.accessToken
        connection.start(token: session.accessToken, received: { [weak self] notice, initial in
            guard let self, self.foreground, self.cloudSocketToken == session.accessToken,
                  self.cloud.session?.accessToken == session.accessToken else { return }
            if initial {
                // These notices carry no request ID. Pending identity is local context only.
                RequestTimeline.record(.socketInitial, requestID: self.pendingID)
                self.cloudSocketEpoch = UUID()
                self.requestPreferenceSync()
                self.requestCatalogCatchUp()
                self.requestCloudStatusReconciliation()
            }
            switch notice {
            case .deviceNameUpdated(let snapshot):
                do {
                    if try !self.cloud.observeDeviceName(snapshot, token: session.accessToken) { self.requestCloudStatusReconciliation() }
                } catch { self.deviceNameSyncStatus = "Cloud could not save this device name on the iPad. It will retry when connected." }
            case .deviceRevoked(let deviceID):
                self.cloud.acceptRevocation(token: session.accessToken, deviceID: deviceID)
            case .statusChanged:
                if !initial {
                    RequestTimeline.record(.socketStatusChanged, requestID: self.pendingID)
                    self.requestCloudStatusReconciliation()
                }
            case .preferenceUpdated(let profileID):
                if self.preferenceSyncBinding?.cloud.profileID == profileID, !initial { self.requestPreferenceSync() }
            case .catalogUpdated:
                if !initial {
                    self.requestCatalogPreviewSync(discoverCandidates: true)
                    self.requestLinkedCatalogSync()
                }
            case .screenDataConnected(let socketID):
                guard initial else { return }
                self.screenDataSocketID = socketID
                self.requestScreenDataInventory()
            case .screenDataQuery(let query):
                if !initial { self.handleScreenDataQuery(query) }
            }
        }, disconnected: { [weak self] authorizationRejected in
            guard let self, self.foreground, self.cloudSocketToken == session.accessToken,
                  self.cloud.session?.accessToken == session.accessToken else { return }
            RequestTimeline.record(.socketDisconnected, requestID: self.pendingID)
            if authorizationRejected { self.rejectCloudAuthorization() }
            else { self.clearCloudSocketObservation() }
        }, billingUpdated: { [weak self] notice in
            guard let self, self.foreground, self.cloudSocketToken == session.accessToken,
                  self.cloud.session?.accessToken == session.accessToken else { return }
            Task { [weak self] in
                guard let self, self.cloud.session?.accessToken == session.accessToken else { return }
                await self.billing.billingUpdated(operationID: notice.operation_id, eventID: notice.event_id, cloud: self.cloud)
            }
        })
        // Foreground recovery must not depend on a successful socket handshake.
        // A missed completion is reconciled by ID even while the socket reconnects.
        requestCloudStatusReconciliation()
    }
    private func rejectCloudAuthorization() {
        guard cloud.session != nil else { return }
        if currentRequestRoute == .cloud { agentWorkingRequestID = nil }
        cloudAuthorizationRejected = true
        clearCloudStatusReads()
        connection.stop()
        clearCloudSocketObservation()
        if !pollsLocalAuthoring {
            refreshPump.cancel(); refreshFailures = 0
        }
        preferenceSyncPump.cancel()
        preferenceSyncFlight.cancel()
        cancelCatalogWork()
        preferenceSyncStatus = "Sign in again to synchronize with Cloud. Preferences saved on this iPad are still available."
    }
    private func finishCloudDeviceRevocation() {
        stopConnection()
        // Account deletion has its own durable recovery transaction. A revoked
        // enrollment must never erase or masquerade as completion of that flow.
        if accountDeletionIntent != nil { email = nil; return }
        library?.setCatalogBackupScope(nil)
        detachAccountLibrary()
        email = nil
        busy = false
        choosingSignInProvider = false
        settingsOpen = false
        do { try openLibrary() }
        catch { message = "This device was removed from Cloud. Could not open the local library: \(error.localizedDescription)"; return }
        message = cloud.revocationPersistenceFailed
            ? "This device was removed from Cloud. Unlock this iPad and reopen Screenpunk to finish clearing its saved sign-in. Your saved screens are preserved."
            : "This device was removed from your Cloud account. Your saved screens and Cloud backups are preserved."
        startConnection()
    }
    private func requestCloudStatusReconciliation() {
        if shouldCheckCloudSetup {
            refreshCloudSetupStatus(reconcileProfile: true)
        } else if pollsLocalAuthoring || !cloudAccountMatches || library == nil {
            requestCloudListenerStatus()
        } else {
            requestRefresh()
        }
    }
    private func clearCloudStatusReads() {
        cloudSetupStatusTask?.cancel()
        cloudSetupStatusTask = nil
        cloudListenerObservations.clear()
    }
    private func clearCloudSocketObservation() {
        resetScreenDataWork(disconnectSocket: true)
        inventorySignature = nil
        cloudSocketEpoch = nil
        listenerStatusPump.cancel()
        cloudListenerObservations.clearSocket()
        cloudAgentReady = false; cloudSupportsV2 = false
        if !pollsLocalAuthoring { agentReady = routePreference == .automatic && localAgent != nil }
    }
    private func refreshAuthoringRoute() {
        // Discard old route work without changing Cloud account or socket identity.
        refreshPump.cancel(); refreshFailures = 0
        listenerStatusPump.cancel()
        if pollsLocalAuthoring {
            agentReady = localAgent != nil
            if cloudSocketEpoch != nil, cloudListenerObservation == nil { requestCloudListenerStatus() }
        }
        requestRefresh()
    }
    private func stopConnection(releaseCloudSocket: Bool = true) {
        agentWorkingRequestID = nil
        connectionActive = false
        stopTemporaryHomeAssistant()
        connectionGeneration = UUID()
        resetScreenDataWork(disconnectSocket: false)
        if releaseCloudSocket {
            clearCloudStatusReads()
            cloudSocketToken = nil
            cloudAuthorizationRejected = false
            connection.stop()
            clearCloudSocketObservation()
        } else {
            listenerStatusPump.cancel()
        }
        let previousV1 = localTransport, previousV2 = localTransportV2
        if previousV1 != nil || previousV2 != nil {
            localConnectionLifecycle.enqueue {
                await previousV2?.disconnect()
                await previousV1?.disconnect()
            }
        }
        refreshPump.cancel(); refreshFailures = 0
        preferenceSyncPump.cancel()
        preferenceSyncFlight.cancel()
        cancelCatalogWork()
    }
    /// One in-flight reconciliation plus one trailing refresh, regardless of notice volume.
    /// A new notice cancels only a retry timer, never an in-flight reconciliation.
    private func requestRefresh() {
        guard foreground, connectionActive else { return }
        let generation = connectionGeneration
        refreshPump.request { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return .idle }
            guard let self, self.foreground, self.connectionActive,
                  self.connectionGeneration == generation, !Task.isCancelled else { return .idle }
            let success = await self.poll(generation: generation)
            guard self.connectionGeneration == generation, !Task.isCancelled else { return .idle }
            if success { self.refreshFailures = 0; return .idle }
            let submittedCloud = self.library?.hasCloudSubmission == true
            let hasWork = self.pendingID != nil || submittedCloud || !(self.library?.state.cancelIntents ?? []).isEmpty
            guard AuthoringRefreshPolicy.retryFailedRead(hasPendingWork: hasWork, hasCloudSocket: self.cloudSocketEpoch != nil) else { return .idle }
            self.refreshFailures = min(self.refreshFailures + 1, 6)
            let delay = min(60, pow(2, Double(self.refreshFailures)) * Double.random(in: 0.75...1.25))
            return .retry(Date().addingTimeInterval(delay))
        }
    }
    private func openLibrary() throws {
        guard let profileRepository else { throw DeviceError.message("Local identity storage is unavailable.") }
        var profile: LocalProfileDescriptor
        let selected = try profileRepository.snapshot().activeProfile
        if let session = cloud.session {
            if let selected, !CloudClient.originScope.shouldRestoreAccountProfile(activeProfile: selected, serverUserID: session.user.id) {
                profile = selected
            } else {
                profile = try profileRepository.activateAccountProfile(accountID: CloudClient.originScope.localAccountID(serverUserID: session.user.id), deviceID: session.deviceId)
            }
        } else {
            profile = try profileRepository.activateLocalProfile()
        }
        var opened = try ScreenLibrary(profile: profile, onboardNewLibrary: true)
        while var linked = opened.linkedProfile {
            guard linked.id == profile.id, linked.libraryOwner == profile.libraryOwner, linked.permissionOwner == profile.permissionOwner else { throw DeviceError.message("This saved library belongs to another profile.") }
            // Recover an interrupted binding commit, preserving a newer route choice or device enrollment.
            guard profile.cloudBinding == nil else { break }
            if cloud.session != nil, linked.cloudAccountID != cloud.localAccountID { throw DeviceError.message("This saved library belongs to another account.") }
            linked.preferredRoute = profile.preferredRoute
            linked.routePreference = profile.routePreference
            try profileRepository.adoptLinkedProfile(linked); profile = linked
            guard cloud.session == nil else { break }
            profile = try profileRepository.activateLocalProfile()
            opened = try ScreenLibrary(profile: profile, onboardNewLibrary: true)
        }
        if let session = cloud.session, let profileID = session.profileID,
           profile.libraryOwner == cloud.localAccountID || profile.cloudBinding?.accountID == cloud.localAccountID {
            if profile.cloudBinding == nil {
                let binding = LocalCloudBinding(accountID: CloudClient.originScope.localAccountID(serverUserID: session.user.id), profileID: profileID, deviceID: session.deviceId)
                try profileRepository.validateLink(profileID: profile.id, binding: binding)
                profile = try opened.linkLocalProfile(profile, to: binding)
                try profileRepository.adoptLinkedProfile(profile)
            } else {
                profile = try profileRepository.activateCloudProfile(accountID: CloudClient.originScope.localAccountID(serverUserID: session.user.id), profileID: profileID, deviceID: session.deviceId)
            }
        }
        activeProfile = profile
        refreshDeviceName()
        selectedRoute = profile.preferredRoute; routePreference = profile.routePreference
        let previousPending = opened.state.pendingID ?? opened.state.submissionKey
        try opened.activateAuthoringDevice(deviceID: profile.authoringDeviceID)
        if previousPending != nil, opened.state.pendingID == nil, opened.state.submissionKey == nil {
            message = "An earlier request belongs to a previous device connection. Your screens are unchanged. Send your instructions again to continue."
        }
        #if DEBUG
        if shouldRestartGuideForTesting {
            shouldRestartGuideForTesting = false
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try opened.restartGuideForTesting(receiptURL: documents.appendingPathComponent("ScreenpunkOnboardingTestReceipt.json"))
        }
        #endif
        try opened.installStarterScreensIfNeeded(StarterScreens.templates())
        try opened.migratePristineWeatherIfNeeded()
        library = opened
        opened.onCatalogRevisionCommitted = { [weak self, weak opened] in
            guard let self, let opened, self.library === opened else { return }
            self.requestCatalogSync()
        }
        opened.onCatalogLinksChanged = { [weak self, weak opened] in
            guard let self, let opened, self.library === opened else { return }
            self.requestLinkedCatalogSync()
        }
        refreshCatalogScope()
        CatalogPreviewCaptureRegistry.shared.onReady = { [weak self] revision in self?.captureExactCatalogPreview(revision: revision) }
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
        // A committed receipt may still occupy the interactive slot after a crash.
        // Recover its exact delivery or release the slot while retaining the receipt.
        let localReceiptIDs = opened.unacknowledgedLocalReceiptIDs
        if let id = pendingID, localReceiptIDs.contains(id),
           let receipt = opened.state.authoring?.receipts.values.first(where: { $0.requestID == id }) {
            switch localReceiptRecovery(receipt, record: try localLedger?.record(requestID: id)) {
            case .settleNative:
                try opened.acknowledgeReceipt(receipt)
                try releaseLocalReceiptPending(id, settled: true, library: opened)
            case .acknowledgeTransport: break
            case .preserve: try releaseLocalReceiptPending(id, settled: false, library: opened)
            }
        }
        if let outstanding = try localLedger?.unresolvedRecord(), outstanding.profileID == profile.id,
           !opened.hasApplicationReceipt(requestID: outstanding.requestID) {
            if cancelledLocally.contains(outstanding.requestID) { try localLedger?.cancel(requestID: outstanding.requestID) }
            else if pendingID == nil { pendingID = outstanding.requestID; try persistPending() }
        }
        // Route recoverable acknowledgements to Local even when Automatic would
        // otherwise select Cloud. Preserved receipts remain in the native journal.
        if pendingID == nil, opened.state.submissionKey == nil {
            for id in localReceiptIDs {
                guard let state = opened.state.authoring,
                      let receipt = state.receipts.values.first(where: { $0.requestID == id }),
                      !state.acknowledgedReceiptIDs.contains(receipt.operationID) else { continue }
                switch localReceiptRecovery(receipt, record: try localLedger?.record(requestID: id)) {
                case .settleNative: try opened.acknowledgeReceipt(receipt)
                case .acknowledgeTransport: pendingID = id; try persistPending()
                case .preserve: continue
                }
                if pendingID != nil { break }
            }
        }
        var retryUnsentLocal = false
        if let key = opened.state.submissionKey, let localLedger,
           opened.isUnsentLocalRequest(key, ledgerRecordExists: try localLedger.record(requestID: key) != nil) {
            // A crash before transport preparation proves no turn was dispatched.
            // Offer an explicit retry of the sealed request, never auto-start a turn.
            pendingID = nil; try persistPending(); retryUnsentLocal = true
        }
        inventorySignature = nil; busy = pendingID != nil; requestPending = busy
        canCancelRequest = (busy || opened.state.submissionKey != nil) && !(pendingID.map { opened.hasApplicationReceipt(requestID: $0) } ?? false)
        canRetry = retryUnsentLocal || (opened.state.submissionKey != nil && currentRequestRoute == .cloud)
        if canRetry, message == nil { message = "Your previous instructions are saved. Retry to confirm delivery." }
        refreshScreen()
    }
    func selectAuthoringRoute(_ route: AuthoringRoute) {
        guard !routeChangeBlocked, let profile = activeProfile else { return }
        do {
            if route == .cloud, !cloudAccountMatches { throw DeviceError.message("Sign in to this profile’s Cloud account first.") }
            try profileRepository?.setPreferredRoute(route, profileID: profile.id)
            activeProfile?.preferredRoute = route; activeProfile?.routePreference = route == .local ? .local : .cloud; routePreference = route == .local ? .local : .cloud; selectedRoute = route; agentReady = false
            refreshAuthoringRoute()
        } catch { message = error.localizedDescription }
    }
    private func reloadLocalAgent() {
        guard !accountOperationInProgress else { return }
        stopConnection(releaseCloudSocket: false)
        do { try openLibrary(); startConnection() } catch { message = error.localizedDescription }
    }
    private func sendLocal(_ text: String) async {
        let generation = connectionGeneration
        await localConnectionLifecycle.wait()
        guard foreground, generation == connectionGeneration, !Task.isCancelled,
              agentReady, !busy, let library, let authoring = localAuthoring else { return }
        do {
            if try localLedger?.unresolvedRecord() != nil { message = "An earlier local request is still pending. Sign in to its account to finish or cancel it."; return }
        } catch { message = error.localizedDescription; return }
        agentWorkingRequestID = nil
        busy = true; requestPending = true; canCancelRequest = false; canRetry = false; takingLonger = false
        progressTiming.begin(at: Date()); message = nil; progressCaption = "Sending to your Mac…"
        var attemptID: String?
        do {
            let snapshot: AuthoringRequestV1
            if let key = library.state.submissionKey, let saved = library.authoringRequest(id: key) {
                guard saved.delivery.route == "local", library.state.submissionText == text, !cancelledLocally.contains(key) else { throw DeviceError.message("The saved Local request changed.") }
                snapshot = saved
            } else { snapshot = try makeAuthoringRequest(text: text, library: library, route: .local) }
            attemptID = snapshot.requestID
            pendingID = snapshot.requestID; pendingScreenID = snapshot.context.screenID
            try library.saveSubmission(key: snapshot.requestID, text: text, screen: screen?.artifact)
            try library.saveAuthoringRequest(snapshot); try persistPending()
            canCancelRequest = true
            let accepted = try await authoring.submit(snapshot)
            guard ownsSubmission(snapshot.requestID, library: library), generation == connectionGeneration else { return }
            try library.submissionAccepted(deadline: Double(accepted.deadlineAt))
            agentWorkingRequestID = accepted.requestID
            progressCaption = "Your Mac is working on this screen…"; requestRefresh()
        } catch {
            if let attemptID { guard ownsSubmission(attemptID, library: library) else { return } }
            else { guard pendingID == nil, library.state.submissionKey == nil else { return } }
            guard self.library === library, generation == connectionGeneration else { return }
            agentWorkingRequestID = nil
            let submissionError = error
            // The adapter commits its ledger before network submission. A successful absent read proves no turn was sent.
            do {
                guard let ledger = localLedger else { throw DeviceError.message("Local delivery storage is unavailable.") }
                if let id = pendingID, try ledger.record(requestID: id) == nil {
                    pendingID = nil; pendingScreenID = nil; try persistPending()
                    busy = false; requestPending = false; canCancelRequest = true; canRetry = true; message = submissionError.localizedDescription
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
            // A preserved receipt must not block another request’s reconciliation.
            if let state = library.state.authoring {
                let localReceiptIDs = Set(library.unacknowledgedLocalReceiptIDs)
                for receipt in state.receipts.values where localReceiptIDs.contains(receipt.requestID) && !state.acknowledgedReceiptIDs.contains(receipt.operationID) {
                    let record = try localLedger?.record(requestID: receipt.requestID)
                    switch localReceiptRecovery(receipt, record: record) {
                    case .preserve:
                        try releaseLocalReceiptPending(receipt.requestID, settled: false, library: library)
                        continue
                    case .settleNative: try library.acknowledgeReceipt(receipt)
                    case .acknowledgeTransport:
                        if record?.contractVersion == 2, let localAuthoringV2 { try await localAuthoringV2.acknowledge(receipt) }
                        else { try await authoring.acknowledge(receipt) }
                        guard self.library === library, generation == connectionGeneration, !Task.isCancelled else { return true }
                    }
                    if pendingID == receipt.requestID {
                        try releaseLocalReceiptPending(receipt.requestID, settled: true, library: library)
                        refreshScreen(); refreshPreferences()
                        message = receipt.status == "applied" ? "Your previous result is saved on this device." : (receipt.message ?? "Your screen is unchanged.")
                    }
                }
            }
        } catch {
            guard self.library === library, generation == connectionGeneration, !Task.isCancelled else { return true }
            agentWorkingRequestID = nil
            message = "Your result is saved here. Local receipt confirmation will retry."
            return false
        }
        guard let id = pendingID else { return true }
        do {
            let delivery = try await authoring.reconcile(requestID: id)
            guard self.library === library, pendingID == id, generation == connectionGeneration, !Task.isCancelled else { return true }
            if cancelledLocally.contains(id) { return true }
            switch delivery {
            case .completed(let result):
                agentWorkingRequestID = nil
                let receipt = try measureRequestApply(id) { try authoring.apply(result) }
                if receipt.status == "applied", result.preferenceMutations?.isEmpty == false {
                    requestPreferenceSync() // A stalled Mac acknowledgement must not stall preferences.
                }
                // The application receipt is committed before the Mac delivery is acknowledged.
                agentWorkingRequestID = nil
                canCancelRequest = false
                try await authoring.acknowledge(receipt)
                guard self.library === library, pendingID == id, generation == connectionGeneration else { return true }
                refreshScreen(); refreshPreferences()
                message = receipt.status == "applied" ? (result.preferenceMutations?.isEmpty == false ? "Preference saved" : result.answer) : (receipt.message ?? "Your screen is unchanged.")
                consumedID = id; pendingID = nil; busy = false; requestPending = false; canCancelRequest = false; takingLonger = false; canRetry = false
                try persistPending()
            case .ended(let status, let failure): try finishRequest(id, status: status, failure: failure)
            case .pending(let progress):
                agentWorkingRequestID = id
                try library.submissionAccepted(deadline: progress.deadlineAt)
                busy = true; requestPending = true; canCancelRequest = true; canRetry = false
                progressCaption = progress.caption ?? "Your Mac is working…"
                if let updated = progress.updatedAt { progressTiming.lastProgressAt = Date(timeIntervalSince1970: updated / 1000) }
            case .deliveryUncertain(let message), .needsAttention(let message):
                agentWorkingRequestID = nil
                busy = true; requestPending = true; canCancelRequest = true; canRetry = false; progressCaption = message
            }
            return pendingID == nil
        } catch {
            guard self.library === library, pendingID == id, generation == connectionGeneration, !Task.isCancelled else { return true }
            agentWorkingRequestID = nil
            progressCaption = error.localizedDescription; busy = true; requestPending = true; canCancelRequest = !library.hasApplicationReceipt(requestID: id)
            return false
        }
    }
    /// A failed open after authentication must leave no previous account's inventory
    /// attached to the new session. Durable account directories remain untouched.
    private func detachAccountLibrary() {
        linkedEditPrompt = nil
        retryLinkedEdit = nil
        resetScreenDataWork(disconnectSocket: true)
        screenDataPermissions = []
        publicReads?.cancel(); publicReads = nil; publicReadSessionKey = ""
        if let previous = homeAssistant { Task { await previous.cancelPending() } }
        homeAssistant = nil; customHTTP = nil; customHTTPRendererKey = ""; manifest = nil; assets = nil; screen = nil; activeProfile = nil
        cloudSupportsConnectionPrefill = false
        cloudSupportsCustomHTTP = false
        library = nil; cloudAuthoring = nil; localAuthoring = nil; localTransport = nil; cloudAuthoringV2 = nil; localAuthoringV2 = nil; localTransportV2 = nil; localTransportAuthoringProfileID = nil; cloudAgentReady = false; cloudSupportsV2 = false; pendingID = nil; pendingScreenID = nil; consumedID = nil
        cancelledLocally = []; inventorySignature = nil
        installedManifests = []; installedScreens = []; hiddenScreenIDs = []; manifestIssues = [:]; onboarding = nil
        preferenceRecords = []; inactiveDevicePreferences = []; preferenceConflicts = []; preferenceSyncStatus = nil
        catalogBackupStatus = nil; catalogCanResume = false; catalogPreviewStatus = nil
        agentReady = false; requestPending = false; canCancelRequest = false; canRetry = false; takingLonger = false
    }
    private func persistPending() throws { try library?.savePending(id: pendingID, screenID: pendingScreenID, consumedID: consumedID) }
    func refreshConnections() { refreshScreen() }
    private func refreshScreen() {
        defer {
            if let prompt = customConnectionPrompt,
               prompt.owner != permissionOwner || prompt.use.screen.revision != screen?.revision {
                customConnectionPrompt = nil
            }
            updateTemporaryHomeAssistant()
            refreshPublicReads()
            refreshScreenDataPermissions()
            refreshScreenDataPrompts()
            requestScreenDataInventory()
            requestRefresh()
        }
        if let previous = homeAssistant { Task { await previous.cancelPending() } }
        homeAssistant = nil; customHTTP = nil; manifest = nil
        onboarding = library?.state.onboarding
        installedScreens = library?.state.screens ?? []
        hiddenScreenIDs = library?.state.hiddenScreenIDs ?? []
        manifestIssues = [:]
        installedManifests = installedScreens.compactMap { saved in
            guard let file = saved.artifact.files.first(where: { $0.path == "manifest.json" }) else { return nil }
            do {
                var parsed = try JSONDecoder().decode(DashboardManifest.self, from: Data(file.content.utf8))
                try PackageValidator.validate(parsed, maximumExpandedBytes: saved.catalogAssetPaths == nil ? PackageLimits.expandedBytes : nil)
                parsed.revision = saved.revision
                let declaredDigest = parsed.files.first(where: { $0.path == "app.js" })?.sha256
                let enriched = LegacyGeneratorConnection.enrich(parsed, appDigest: declaredDigest)
                if enriched != parsed, let source = try? library?.store(for: saved).assets["app.js"] {
                    return LegacyGeneratorConnection.enrich(parsed, appDigest: CatalogContract.digest(source.data))
                }
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
        screen = library?.selectedForPresentation(hasCloudSession: cloud.session != nil, localAgent: localAgent); canRollback = library?.state.previous != nil
        do {
            assets = try screen.flatMap { try library?.store(for: $0) }
            if let data = assets?.assets["manifest.json"]?.data,
               var parsed = try? JSONDecoder().decode(DashboardManifest.self, from: data),
               let screen, let owner = activeProfile?.permissionOwner,
               (try? PackageValidator.validate(parsed, maximumExpandedBytes: screen.catalogAssetPaths == nil ? PackageLimits.expandedBytes : nil)) != nil {
                // Local immutable revision is the authority for device-approved credentials.
                parsed.revision = screen.revision
                let declaredDigest = parsed.files.first(where: { $0.path == "app.js" })?.sha256
                if LegacyGeneratorConnection.enrich(parsed, appDigest: declaredDigest) != parsed,
                   let source = assets?.assets["app.js"] {
                    parsed = LegacyGeneratorConnection.enrich(parsed, appDigest: CatalogContract.digest(source.data))
                }
                manifest = parsed
                let scope = HomeAssistantDeviceRuntime.Scope(owner: owner, revision: screen.revision, dashboardId: parsed.dashboardId)
                homeAssistant = HomeAssistantDeviceRuntime(vault: HomeAssistantDeviceVault(), scope: { scope })
                if parsed.connections.contains(where: { $0.customHTTP != nil }) {
                    customHTTP = CustomHTTPDeviceRuntime(owner: owner, screenID: screen.id, manifest: parsed, vault: customHTTPVault,
                        accessRequired: { [weak self] alias in
                            await self?.offerCustomConnectionAccess(alias: alias, owner: owner, revision: screen.revision)
                        })
                }
            }
        } catch { assets = nil; message = "Could not load this screen. Use Settings to restore its previous version." }
    }
}


extension DeviceModel {
    private struct ScreenDataScope: Equatable {
        let library: ObjectIdentifier
        let generation: UUID
        let profileID: String
        let owner: String
        let deviceID: String
        let token: String?
    }

    private struct ScreenDataCloudScope: Equatable {
        let scope: ScreenDataScope
        let socketID: String
        let token: String
    }

    private var screenDataScope: ScreenDataScope? {
        guard let library, let profile = activeProfile else { return nil }
        return .init(library: ObjectIdentifier(library), generation: connectionGeneration,
                     profileID: profile.id, owner: profile.cloudBinding?.accountID ?? profile.libraryOwner,
                     deviceID: profile.authoringDeviceID, token: cloud.session?.accessToken)
    }

    private var screenDataCloudScope: ScreenDataCloudScope? {
        guard foreground, connectionActive, !accountOperationInProgress, !cloudAuthorizationRejected,
              cloudBindingMatches, let profile = activeProfile?.cloudBinding,
              cloud.session?.profileID == profile.profileID,
              let scope = screenDataScope, let token = scope.token, let socketID = screenDataSocketID,
              cloudSocketToken == token else { return nil }
        return .init(scope: scope, socketID: socketID, token: token)
    }

    var screenDataRendererKey: String {
        guard manifest?.screenData != nil, let screen,
              let installation = library?.screenDataInstallation(screen.id) else { return "" }
        return connectionGeneration.uuidString + screenDataRendererEpoch.uuidString + installation.generation
    }

    var screenDataProvider: (any ScreenDataProvider)? {
        guard let scope = screenDataScope, let screen,
              let library, let installed = library.screenDataInstallation(screen.id),
              installed.screen.revision == screen.revision else { return nil }
        let requireCurrent: () throws -> (DeviceModel, ScreenLibrary) = { [weak self, weak library] in
            guard let self, let library, self.screenDataScope == scope, self.foreground, self.connectionActive,
                  !self.accountOperationInProgress, library.selected?.id == installed.screen.id,
                  library.selected?.revision == installed.screen.revision,
                  library.state.screenDataGenerations?[installed.screen.id] == installed.generation,
                  !Task.isCancelled else { throw ScreenDataError.unavailable }
            return (self, library)
        }
        return DeviceScreenDataProvider(publishValue: { name, value in
            let (_, library) = try requireCurrent()
            try library.publishScreenData(owner: scope.owner, target: installed.target(exportName: name), value: value)
        }, readValue: { alias in
            let (model, library) = try requireCurrent()
            guard let declaration = installed.declarations.queries.first(where: { $0.alias == alias }) else {
                throw ScreenDataError.permissionRequired
            }
            try model.consumeScreenDataQuery(for: installed.generation)
            if declaration.deviceId == nil || declaration.deviceId == scope.deviceID {
                guard let target = library.screenDataInstallation(declaration.screenId) else { throw ScreenDataError.notFound }
                let reader = DeviceScreenDataReader(kind: .screen, deviceId: scope.deviceID, screenId: installed.screen.id,
                    revision: installed.screen.revision, generation: installed.generation, grantId: nil,
                    title: installed.screen.artifact.title, deviceTitle: model.displayName)
                let permission = try library.screenDataPermission(owner: scope.owner,
                    target: target.target(exportName: declaration.exportName), reader: reader)
                let decision = try library.screenDataArchive.decision(for: permission.key)
                if decision == nil { model.enqueueScreenDataPrompt(permission, remote: false) }
                return try library.screenDataArchive.query(permission.key)
            }

            guard let cloudScope = model.screenDataCloudScope, cloudScope.scope == scope else { throw ScreenDataError.unavailable }
            guard model.screenDataInventorySelectedID == installed.screen.id,
                  model.screenDataInventoryGenerations[installed.screen.id] == installed.generation else {
                model.requestScreenDataInventory()
                throw ScreenDataError.unavailable
            }
            let result = try await model.cloud.queryScreenData(readerID: installed.screen.id, revision: installed.screen.revision,
                generation: installed.generation, alias: alias, socketID: cloudScope.socketID, token: cloudScope.token)
            _ = try requireCurrent()
            guard model.screenDataCloudScope == cloudScope else { throw ScreenDataError.unavailable }
            return result
        })
    }

    private func consumeScreenDataQuery(for reader: String) throws {
        let now = ProcessInfo.processInfo.systemUptime
        for id in Array(screenDataRate.keys) {
            let current = screenDataRate[id, default: []].filter { now - $0 < 60 }
            screenDataRate[id] = current.isEmpty ? nil : current
        }
        guard screenDataRate[reader, default: []].count < 60, screenDataRate.count < 128 || screenDataRate[reader] != nil else {
            throw ScreenDataError.rateLimited
        }
        screenDataRate[reader, default: []].append(now)
    }

    private func requestScreenDataInventory() {
        guard let scope = screenDataCloudScope else { return }
        screenDataInventoryDirty = true
        guard screenDataInventoryTask == nil else { return }
        screenDataInventoryTask = Task { [weak self] in
            guard let self else { return }
            while self.screenDataInventoryDirty, self.screenDataCloudScope == scope, !Task.isCancelled {
                self.screenDataInventoryDirty = false
                try? await self.sendScreenDataInventory(scope: scope)
            }
            if self.screenDataCloudScope == scope, !Task.isCancelled { self.screenDataInventoryTask = nil }
        }
    }

    private func sendScreenDataInventory(scope: ScreenDataCloudScope) async throws {
        guard screenDataCloudScope == scope, let library else { return }
        let includeCatalogIDs = await cloud.catalogInventorySupported(token: scope.token)
        guard screenDataCloudScope == scope, self.library === library, !Task.isCancelled else { return }
        let encoder = JSONEncoder()
        var screens: [[String: Any]] = []
        var generations: [String: String] = [:]
        for screen in library.state.screens {
            var record = library.catalogInventoryRow(for: screen, includeCatalogIDs: includeCatalogIDs)
            if let installed = library.screenDataInstallation(screen.id) {
                record["revision"] = screen.revision
                record["screenDataGeneration"] = installed.generation
                generations[screen.id] = installed.generation
                record["screenData"] = try JSONSerialization.jsonObject(with: encoder.encode(installed.declarations))
            }
            screens.append(record)
        }
        var body: [String: Any] = ["screens": screens, "screenDataProtocol": 1, "screenDataSocketId": scope.socketID]
        let selectedID = library.selected?.id
        if let selectedID { body["selectedID"] = selectedID }
        let signature = Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)))
        guard signature != screenDataInventorySignature else { return }
        guard screenDataInventorySequence < ScreenDataContract.maxVersion else { throw ScreenDataError.unavailable }
        screenDataInventorySequence += 1
        body["screenDataInventorySequence"] = screenDataInventorySequence
        let _: EmptyResponse = try await cloud.call("api/device/screens", method: "POST", body: body,
            authorizationToken: scope.token, screenDataProtocol: true)
        guard screenDataCloudScope == scope, !Task.isCancelled else { return }
        screenDataInventorySignature = signature
        screenDataInventorySelectedID = selectedID
        screenDataInventoryGenerations = generations
    }

    private func handleScreenDataQuery(_ query: DeviceScreenDataNotice) {
        guard let scope = screenDataCloudScope, screenDataQueryTasks.count < 16,
              screenDataQueryTasks[query.queryId] == nil, let library else { return }
        let deadline = Date(timeIntervalSince1970: Double(query.deadlineAt) / 1000)
        guard deadline > Date() else { return }
        let taskID = UUID()
        screenDataQueryTasks[query.queryId] = (taskID, Task { [weak self, weak library] in
            guard let self, let library else { return }
            defer {
                if self.screenDataQueryTasks[query.queryId]?.id == taskID {
                    self.screenDataQueryTasks[query.queryId] = nil
                }
            }
            guard self.screenDataCloudScope == scope, deadline > Date(), !Task.isCancelled else { return }
            let reply: DeviceScreenDataWire.Reply
            var candidate: DeviceScreenDataPermission?
            do {
                let permission = try library.screenDataPermission(owner: scope.scope.owner, target: query.target, reader: query.reader)
                if try library.screenDataArchive.decision(for: permission.key) == nil { candidate = permission }
                reply = .init(try library.screenDataArchive.query(permission.key))
            } catch { reply = .init(error as? ScreenDataError ?? .unavailable) }
            guard self.screenDataCloudScope == scope, deadline > Date(), !Task.isCancelled,
                  (try? await self.cloud.replyToScreenDataQuery(id: query.queryId, reply: reply, token: scope.token)) == true,
                  self.screenDataCloudScope == scope, deadline > Date(), !Task.isCancelled,
                  let candidate, self.currentScreenDataPermission(candidate, remote: true),
                  (try? library.screenDataArchive.decision(for: candidate.key)) == nil else { return }
            self.enqueueScreenDataPrompt(candidate, remote: true)
        })
    }

    private func currentScreenDataPermission(_ permission: DeviceScreenDataPermission, remote: Bool) -> Bool {
        let key = permission.key
        guard foreground, connectionActive, !accountOperationInProgress,
              let scope = screenDataScope, key.owner == scope.owner, let library,
              let target = library.screenDataInstallation(key.target.screenId),
              target.target(exportName: key.target.exportName) == key.target,
              target.declarations.exports.contains(where: { $0.name == key.target.exportName }) else { return false }
        if remote { return screenDataCloudScope != nil }
        guard key.reader.deviceId == scope.deviceID, let readerID = key.reader.screenId,
              let reader = library.screenDataInstallation(readerID), reader.screen.revision == key.reader.revision,
              reader.generation == key.reader.generation else { return false }
        return reader.declarations.queries.contains {
            ($0.deviceId == nil || $0.deviceId == scope.deviceID) &&
                $0.screenId == key.target.screenId && $0.exportName == key.target.exportName
        }
    }

    private func enqueueScreenDataPrompt(_ permission: DeviceScreenDataPermission, remote: Bool) {
        refreshScreenDataPrompts()
        guard currentScreenDataPermission(permission, remote: remote), screenDataPrompts.count < 4,
              !screenDataPrompts.contains(where: { $0.permission.key == permission.key }) else { return }
        screenDataPrompts.append(.init(permission: permission, expiresAt: Date().addingTimeInterval(120), remote: remote))
        refreshScreenDataPrompts()
    }

    private func refreshScreenDataPrompts() {
        let now = Date()
        screenDataPrompts = screenDataPrompts.filter { $0.expiresAt > now && currentScreenDataPermission($0.permission, remote: $0.remote) }
        if screenDataPrompt?.id != screenDataPrompts.first?.id { screenDataPrompt = screenDataPrompts.first }
    }

    func respondToScreenDataPrompt(_ prompt: DeviceScreenDataPrompt, allow: Bool) {
        guard screenDataPrompt?.id == prompt.id else { return }
        screenDataPrompts.removeAll { $0.id == prompt.id }
        screenDataPrompt = nil
        if prompt.expiresAt > Date(), currentScreenDataPermission(prompt.permission, remote: prompt.remote), let library {
            do {
                if try library.screenDataArchive.decision(for: prompt.permission.key) == nil {
                    var permission = prompt.permission
                    permission.decision = allow ? .allowed : .denied
                    try library.screenDataArchive.set(permission)
                }
            } catch { message = "Couldn’t save this screen data permission. Review permissions in Settings." }
        }
        refreshScreenDataPermissions()
        Task { @MainActor [weak self] in self?.refreshScreenDataPrompts() }
    }

    private func refreshScreenDataPermissions() {
        guard let scope = screenDataScope, let library else { screenDataPermissions = []; return }
        screenDataPermissions = ((try? library.screenDataArchive.permissions(owner: scope.owner)) ?? []).filter { permission in
            let target = permission.key.target
            return library.state.screenDataGenerations?[target.screenId] == target.generation
        }
    }

    func revokeScreenDataPermission(_ permission: DeviceScreenDataPermission) {
        updateScreenDataPermission(permission, forget: false)
    }

    func forgetScreenDataDecision(_ permission: DeviceScreenDataPermission) {
        updateScreenDataPermission(permission, forget: true)
    }

    private func updateScreenDataPermission(_ permission: DeviceScreenDataPermission, forget: Bool) {
        guard !accountOperationInProgress, let scope = screenDataScope, permission.key.owner == scope.owner,
              screenDataPermissions.contains(where: { $0.key == permission.key }), let library else { return }
        do {
            if forget { try library.screenDataArchive.forget(permission.key) }
            else {
                var revoked = permission
                revoked.decision = .revoked
                try library.screenDataArchive.set(revoked)
            }
            refreshScreenDataPermissions()
        } catch { message = "Couldn’t update this screen data permission." }
    }

    private func resetScreenDataWork(disconnectSocket: Bool) {
        screenDataInventoryTask?.cancel()
        screenDataInventoryTask = nil
        screenDataInventoryDirty = false
        screenDataInventorySignature = nil
        screenDataInventorySelectedID = nil
        screenDataInventoryGenerations.removeAll()
        for request in screenDataQueryTasks.values { request.task.cancel() }
        screenDataQueryTasks.removeAll()
        if disconnectSocket {
            screenDataSocketID = nil
            screenDataInventorySequence = 0
            screenDataPrompts.removeAll { $0.remote }
        } else {
            screenDataPrompts.removeAll()
            screenDataRate.removeAll()
        }
        refreshScreenDataPrompts()
    }
}

extension DeviceModel {
    private struct CatalogFlight: Equatable {
        var generation: UUID
        var authorization: UUID
        var library: ObjectIdentifier
        var profileID: String
        var binding: ScreenLibrary.CatalogBinding
        var token: String // Memory only; never persisted or logged.
    }
    private var catalogBinding: ScreenLibrary.CatalogBinding? {
        guard cloudBindingMatches, let profile = activeProfile,
              let session = cloud.session, let account = cloud.localAccountID else { return nil }
        return .init(origin: CloudClient.origin.absoluteString, accountID: account, userID: session.user.id,
            deviceID: session.deviceId, libraryID: profile.libraryOwner)
    }
    var catalogBackupAccess: DeviceBackupAccess { billing.backupAccess(for: cloud) }

    var canAddCatalogScreen: Bool {
        catalogBackupsCanConfigure && catalogBackupAccess.allowsBackups && !busy && !requestPending && !routeChangeBlocked
    }

    func availableCatalogScreens() async throws -> [CatalogScreen] {
        guard canAddCatalogScreen, let binding = catalogBinding, let library, let token = cloud.session?.accessToken else {
            throw DeviceError.message("Connect this device to your Screenpunk Pro account to open your catalog.")
        }
        let generation = connectionGeneration
        var screens: [CatalogScreen] = [], cursor: String?, seen = Set<String>()
        repeat {
            var path = URLComponents(); path.path = "/api/catalog/device-screens"
            if let cursor { path.queryItems = [.init(name: "cursor", value: cursor)] }
            let page: CatalogList = try await cloud.catalogRequest(path.string!, token: token)
            try Task.checkCancellation()
            guard canAddCatalogScreen, catalogBinding == binding, self.library === library, connectionGeneration == generation else {
                throw DeviceError.message("The account or device connection changed. Reopen your catalog.")
            }
            guard page.schemaVersion == 1, page.entitlement.backupEnabled else { throw DeviceError.message("Screenpunk Pro is required to add catalog screens.") }
            screens.append(contentsOf: page.screens)
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw DeviceError.message("The catalog changed. Please try again.") }
        } while cursor != nil
        var ids = Set<String>()
        return screens.filter { ids.insert($0.catalogScreenID).inserted && !library.containsCatalogScreen($0) }
    }

    func addCatalogScreen(_ item: CatalogScreen) async throws {
        guard canAddCatalogScreen, let binding = catalogBinding, let library, let token = cloud.session?.accessToken else {
            throw DeviceError.message("Connect this device to your Screenpunk Pro account to add a screen.")
        }
        let generation = connectionGeneration
        func current() throws {
            try Task.checkCancellation()
            guard canAddCatalogScreen, catalogBinding == binding, self.library === library,
                  cloud.session?.accessToken == token, connectionGeneration == generation else {
                throw DeviceError.message("The account or device connection changed. Reopen your catalog.")
            }
        }
        let capability = try await cloud.catalogCapability(token: token)
        try current()
        let linked = capability?.linkedInstallVersion == "1"
        _ = try await restoreCatalogScreen(item, library: library, binding: binding, token: token,
                                           linkedInstall: linked, current: current)
        refreshScreen()
        if linked { requestLinkedCatalogSync() }
    }

    private func restoreCatalogScreen(_ item: CatalogScreen, library: ScreenLibrary, binding: ScreenLibrary.CatalogBinding,
                                      token: String, linkedInstall: Bool = false,
                                      expecting link: ScreenLibrary.LinkedCatalogInstall? = nil,
                                      current: () throws -> Void) async throws -> Bool {
        let version = item.latest
        guard version.catalogScreenID == item.catalogScreenID,
              [item.catalogScreenID, version.versionID, version.sourceRevisionID].allSatisfy(CloudClient.validCatalogIdentifier),
              version.packageDigest.range(of: #"^[a-f0-9]{64}\z"#, options: .regularExpression) != nil,
              version.sizeBytes > 0 else {
            throw DeviceError.message("The catalog returned an invalid screen.")
        }
        var path = URLComponents()
        path.path = "/api/catalog/screens/\(item.catalogScreenID)/versions/\(version.versionID)"
        path.queryItems = [.init(name: "sourceRevisionID", value: version.sourceRevisionID), .init(name: "packageDigest", value: version.packageDigest)]
        let declaration = CatalogObjectDeclaration(byteLength: version.sizeBytes, digest: version.packageDigest)
        if version.packageStorage == "assets" {
            let manifest = try await cloud.catalogVersionManifest(path, token: token, declaration: declaration)
            try current()
            let directory = try library.openCatalogRestoreDirectory(binding: binding, version: version)
            defer { library.closeCatalogRestoreDirectory(directory) }
            try await cloud.catalogRestoreAssets(path, manifest: manifest, directory: directory, token: token, current: current)
            try current()
            if let link { return try library.updateLinkedCatalogAssets(item, manifest: manifest, staged: directory, expecting: link) }
            try library.installCatalogAssets(item, manifest: manifest, staged: directory, linkedBinding: linkedInstall ? binding : nil)
        } else if version.packageStorage == nil {
            path.path += "/import-package"
            let package = try await cloud.catalogPackage(path.string!, token: token, declaration: declaration)
            try current()
            if let link { return try library.updateLinkedCatalogScreen(item, package: package, expecting: link) }
            try library.installCatalogScreen(item, package: package, linkedBinding: linkedInstall ? binding : nil)
        } else {
            throw DeviceError.message("Update the app to restore this catalog format.")
        }
        return true
    }

    private struct LinkedCatalogFlight: Equatable {
        let generation: UUID
        let library: ObjectIdentifier
        let binding: ScreenLibrary.CatalogBinding
        let token: String
    }

    private var linkedCatalogFlight: LinkedCatalogFlight? {
        guard foreground, connectionActive, !accountOperationInProgress, !cloudAuthorizationRejected,
              catalogBackupAccess.allowsBackups, let library, let binding = catalogBinding,
              let token = cloud.session?.accessToken else { return nil }
        return .init(generation: connectionGeneration, library: ObjectIdentifier(library), binding: binding, token: token)
    }

    func linkedCatalogDeviceCount(for screenID: String) -> Int? {
        guard linkedCatalogFlight != nil else { return nil }
        return linkedCatalogDeviceCounts[screenID]
    }

    func requestLinkedCatalogSync() {
        guard linkedCatalogFlight != nil else { return }
        linkedCatalogPump.request { [weak self] in
            guard let self, let flight = self.linkedCatalogFlight else { return .idle }
            return await self.syncLinkedCatalog(flight)
        }
    }

    private func syncLinkedCatalog(_ flight: LinkedCatalogFlight) async -> CatalogWorkPump.Next {
        guard let library, linkedCatalogFlight == flight else { return .idle }
        func current() throws {
            try Task.checkCancellation()
            guard linkedCatalogFlight == flight, self.library === library else { throw CancellationError() }
        }
        let links = library.linkedCatalogScreens.filter { $0.binding == flight.binding }
        let unlinks = library.pendingCatalogUnlinks.filter { $0.binding == flight.binding }
        guard !links.isEmpty || !unlinks.isEmpty || library.hasDiscoverableCatalogProducerCopies(binding: flight.binding)
                || library.pendingCatalogForks.contains(where: { $0.binding == flight.binding }) else {
            linkedCatalogDeviceCounts = [:]
            return .idle
        }
        do {
            let capability = try await cloud.catalogCapability(token: flight.token)
            try current()
            guard capability?.linkedInstallVersion == "1", capability?.entitlement.backupEnabled == true else { return .idle }

            for link in unlinks {
                guard let copyID = link.copyID else { continue }
                do { try await unlinkCatalogScreen(link, copyID: copyID, token: flight.token, current: current) }
                catch {
                    try current()
                    if let failure = error as? CloudClient.CatalogHTTPError, failure.status == 401 { throw failure }
                }
            }
            for link in links where !link.registered {
                guard library.linkedCatalogScreen(id: link.screenID) == link else { continue }
                do {
                    let registration = try await cloud.registerCatalogLink(.init(catalogScreenID: link.catalogScreenID,
                        versionID: link.versionID, sourceRevisionID: link.sourceRevisionID, packageDigest: link.packageDigest,
                        libraryID: link.libraryID, localScreenID: link.localScreenID,
                        localRevisionID: link.localRevision, commitCounter: link.commitCounter), token: flight.token)
                    try current()
                    try library.markLinkedCatalogRegistered(expecting: link, copyID: registration.copyID)
                } catch {
                    try current()
                    if let failure = error as? CloudClient.CatalogHTTPError, failure.status == 401 { throw failure }
                }
            }

            for link in library.linkedCatalogScreens where link.binding == flight.binding &&
                link.registered && link.pendingRevision != nil && !link.conflict {
                do { try await syncLinkedCatalogPublication(link, library: library, token: flight.token, current: current) }
                catch {
                    try current()
                    if let failure = error as? CloudClient.CatalogHTTPError, failure.status == 401 { throw failure }
                }
            }

            for fork in library.pendingCatalogForks where fork.binding == flight.binding && fork.blockedReason == nil {
                do { try await syncCatalogFork(fork, library: library, token: flight.token, current: current) }
                catch {
                    try current()
                    if let failure = error as? CloudClient.CatalogHTTPError, failure.status == 401 { throw failure }
                }
            }

            var cursor: String?
            var seen = Set<String>()
            var counts: [String: Int] = [:]
            var unconfirmedUnlinks = unlinks.filter { $0.copyID == nil }
            var didUpdate = false
            repeat {
                let page = try await cloud.catalogLinkUpdates(cursor: cursor, token: flight.token)
                try current()
                for entry in page.subscriptions {
                    if let tombstone = unconfirmedUnlinks.first(where: {
                        $0.libraryID == entry.libraryID && $0.localScreenID == entry.localScreenID && $0.catalogScreenID == entry.catalogScreenID
                    }) {
                        do { try await unlinkCatalogScreen(tombstone, copyID: entry.copyID, token: flight.token, current: current) }
                        catch {
                            try current()
                            if let failure = error as? CloudClient.CatalogHTTPError, failure.status == 401 { throw failure }
                        }
                        unconfirmedUnlinks.removeAll { $0.screenID == tombstone.screenID }
                        continue
                    }
                    let existing = library.linkedCatalogScreens.first { $0.localScreenID == entry.localScreenID && $0.libraryID == entry.libraryID }
                    let link = existing ?? (try? library.adoptCatalogProducerLink(catalogScreenID: entry.catalogScreenID,
                        libraryID: entry.libraryID, localScreenID: entry.localScreenID, localRevisionID: entry.localRevisionID,
                        commitCounter: entry.commitCounter, copyID: entry.copyID, versionID: entry.installedVersionID,
                        sourceRevisionID: entry.installedSourceRevisionID, displayVersion: entry.installedDisplayVersion,
                        packageDigest: entry.installedPackageDigest, binding: flight.binding))
                    guard let link, link.binding == flight.binding, link.libraryID == entry.libraryID,
                          link.catalogScreenID == entry.catalogScreenID, link.copyID == entry.copyID else { continue }
                    counts[link.screenID] = entry.linkedDeviceCount
                    let discarding = link.discardAfterRefresh == true
                    guard entry.matches(link), (link.pendingRevision == nil && !link.conflict) || discarding,
                          let version = entry.current, version.versionID != link.versionID || discarding,
                          !requestPending, pendingID == nil, !busy, !routeChangeBlocked else { continue }
                    let item = CatalogScreen(catalogScreenID: link.catalogScreenID, latest: version, history: [])
                    do {
                        let installed = try await restoreCatalogScreen(item, library: library, binding: flight.binding,
                            token: flight.token, expecting: link, current: {
                                try current()
                                guard library.linkedCatalogScreen(id: link.screenID) == link,
                                      !self.requestPending, self.pendingID == nil, !self.busy, !self.routeChangeBlocked else {
                                    throw CancellationError()
                                }
                            })
                        if installed {
                            refreshScreen()
                            didUpdate = true
                        }
                    } catch {
                        try current()
                        // This screen keeps its installed version if another operation changes it or its download fails.
                        if let failure = error as? CloudClient.CatalogHTTPError, failure.status == 401 { throw failure }
                    }
                }
                cursor = page.nextCursor
                if let cursor, (!seen.insert(cursor).inserted || seen.count >= 32) {
                    throw DeviceError.message("Cloud returned an invalid linked screen cursor.")
                }
            } while cursor != nil
            for link in unconfirmedUnlinks {
                try library.acknowledgeCatalogUnlink(link)
            }
            if linkedCatalogDeviceCounts != counts { linkedCatalogDeviceCounts = counts }
            if didUpdate { return .ready }
            return .retry(Date().addingTimeInterval(60))
        } catch let error as CloudClient.CatalogHTTPError where error.status == 401 {
            if linkedCatalogFlight == flight, !Task.isCancelled { rejectCloudAuthorization() }
            return .idle
        } catch {
            guard linkedCatalogFlight == flight, !Task.isCancelled else { return .idle }
            return .retry(Date().addingTimeInterval(60))
        }
    }

    private func syncLinkedCatalogPublication(_ link: ScreenLibrary.LinkedCatalogInstall, library: ScreenLibrary, token: String,
                                               current: () throws -> Void) async throws {
        func checkPublication() throws {
            try current()
            guard library.linkedCatalogScreen(id: link.screenID) == link else { throw CancellationError() }
        }
        try checkPublication()
        let exported = try await library.exportLinkedCatalogEdit(link)
        try checkPublication()
        let begin = try library.linkedCatalogBegin(link, declaration: exported.declaration)
        let beginBytes = try CatalogContract.canonical(CatalogAssetBeginRequest(backup: begin, manifest: exported.manifest,
            link: .init(catalogScreenID: link.catalogScreenID, baseVersionID: link.versionID)))

        func applied(_ status: CatalogBackupStatus) throws -> Bool {
            guard status.schemaVersion == 1, status.operationID == begin.operationID, status.catalogScreenID == link.catalogScreenID else {
                throw DeviceError.message("Cloud returned a different shared publication.")
            }
            try CatalogContract.validateStatus(status)
            switch status.state {
            case "completed", "duplicate":
                guard let versionID = status.versionID, CloudClient.validCatalogIdentifier(versionID),
                      let displayVersion = status.displayVersion, displayVersion > link.displayVersion else {
                    throw DeviceError.message("Cloud did not confirm the new shared version.")
                }
                try library.acknowledgeLinkedCatalogPublication(link, versionID: versionID, displayVersion: displayVersion,
                                                               packageDigest: exported.declaration.digest)
                refreshScreen()
                return true
            case "superseded", "deleted":
                try library.recordLinkedCatalogConflict(link)
                refreshScreen()
                return true
            case "failed":
                if status.error?.code == "conflict" {
                    try library.recordLinkedCatalogConflict(link)
                    refreshScreen()
                    return true
                }
                if status.error?.code == "retry_later", status.error?.restartOperation == true {
                    try library.restartLinkedCatalogPublication(link)
                    return true
                }
                throw CloudClient.CatalogHTTPError(status: status.error?.code == "unauthorized" ? 401 : 400,
                                                  code: status.error?.code ?? "retry_later",
                                                  retryAfterSeconds: status.error?.retryAfterSeconds)
            default:
                return false
            }
        }

        do {
            let initial = try await openCatalogAssetOperation(begin.operationID, bytes: beginBytes, token: token, current: checkPublication)
            try checkPublication()
            _ = try await uploadCatalogAssets(initial, exported: exported, operationID: begin.operationID, token: token,
                                              current: checkPublication, applied: applied)
        } catch let error as CloudClient.CatalogHTTPError where error.code == "conflict" {
            try checkPublication()
            try library.recordLinkedCatalogConflict(link)
            refreshScreen()
        }
    }

    private func syncCatalogFork(_ fork: ScreenLibrary.CatalogForkPublication, library: ScreenLibrary, token: String,
                                 current: () throws -> Void) async throws {
        func checkFork() throws {
            try current()
            guard library.pendingCatalogForks.contains(fork) else { throw CancellationError() }
        }
        let exported: CatalogPackageExporter.AssetExport
        do {
            exported = try await library.exportCatalogFork(fork)
        } catch {
            try checkFork()
            try library.failCatalogFork(fork, reason: "Could not back up this copy. A saved file is missing, unsafe, or contains credential markers.")
            objectWillChange.send()
            return
        }
        try checkFork()
        let begin = try library.catalogForkBegin(fork, declaration: exported.declaration)
        let bytes = try CatalogContract.canonical(CatalogAssetBeginRequest(backup: begin, manifest: exported.manifest))
        let initial = try await openCatalogAssetOperation(begin.operationID, bytes: bytes, token: token, current: checkFork)
        try checkFork()
        _ = try await uploadCatalogAssets(initial, exported: exported, operationID: begin.operationID, token: token, current: checkFork) { status in
            guard status.schemaVersion == 1, status.operationID == begin.operationID,
                  CloudClient.validCatalogIdentifier(status.catalogScreenID) else {
                throw DeviceError.message("Cloud returned a different backup operation.")
            }
            try CatalogContract.validateStatus(status)
            switch status.state {
            case "completed", "duplicate":
                guard let versionID = status.versionID, CloudClient.validCatalogIdentifier(versionID) else {
                    throw DeviceError.message("Cloud did not confirm the backup of this copy.")
                }
                try library.acknowledgeCatalogFork(fork, catalogScreenID: status.catalogScreenID)
                requestScreenDataInventory()
                objectWillChange.send()
                return true
            case "superseded", "deleted":
                try library.failCatalogFork(fork, reason: "Cloud could not finish this backup. Your copy remains installed.")
                objectWillChange.send()
                return true
            case "failed":
                if status.error?.code == "retry_later", status.error?.restartOperation == true {
                    try library.restartCatalogFork(fork)
                    return true
                }
                throw CloudClient.CatalogHTTPError(status: status.error?.code == "unauthorized" ? 401 : 400,
                                                   code: status.error?.code ?? "retry_later",
                                                   retryAfterSeconds: status.error?.retryAfterSeconds)
            default:
                return false
            }
        }
    }

    private func openCatalogAssetOperation(_ operationID: String, bytes: Data, token: String,
                                           current: () throws -> Void) async throws -> CloudClient.CatalogAssetProgress {
        do {
            return try await cloud.catalogAssetProgress(CloudClient.assetOperationsPath + operationID, token: token)
        } catch let error as CloudClient.CatalogHTTPError where error.status == 404 {
            try current()
            return try await cloud.catalogAssetProgress(CloudClient.assetBackupsPath, method: "POST", bytes: bytes, token: token)
        }
    }

    private func unlinkCatalogScreen(_ link: ScreenLibrary.LinkedCatalogInstall, copyID: String, token: String,
                                     current: () throws -> Void) async throws {
        do {
            try await cloud.deleteCatalogLink(catalogScreenID: link.catalogScreenID, copyID: copyID, token: token)
        } catch let error as CloudClient.CatalogHTTPError where error.status == 404 {}
        try current()
        try library?.acknowledgeCatalogUnlink(link)
    }

    var catalogBackupsEnabled: Bool {
        guard catalogBackupAccess != .inactive, let binding = catalogBinding else { return false }
        return library?.catalogBackupsPreference(binding: binding) == true
    }
    var catalogBackupsCanConfigure: Bool { !accountOperationInProgress && library != nil && catalogBinding != nil }

    func setCatalogBackupsEnabled(_ enabled: Bool) {
        guard catalogBackupsCanConfigure, let binding = catalogBinding, let library, enabled != catalogBackupsEnabled else { return }
        if enabled, !catalogBackupAccess.allowsBackups {
            if catalogBackupAccess == .unknown {
                Task { await billing.refreshBackupAccess(cloud: cloud) }
            }
            return
        }
        do {
            objectWillChange.send()
            if enabled {
                try library.setCatalogBackupsEnabled(true, binding: binding)
                billing.backupsWereEnabled()
            } else {
                library.disableCatalogBackups(binding: binding)
            }
            cancelCatalogWork()
            catalogCanResume = false
            catalogBackupStatus = enabled ? "Checking backup availability…" : nil
            catalogPreviewStatus = nil
            if enabled { requestCatalogCatchUp() }
        } catch { catalogBackupStatus = error.localizedDescription }
    }

    func billingBackupAccessChanged() {
        objectWillChange.send()
        refreshCatalogScope()
        if catalogBackupAccess.allowsBackups { requestCatalogCatchUp() }
    }

    private func refreshCatalogScope() {
        let access = catalogBackupAccess
        let binding = catalogBinding
        let deadline: Date?
        if case .active(let until) = access { deadline = until } else { deadline = nil }
        if library?.setCatalogBackupScope(binding, validUntil: deadline) == true {
            cancelCatalogWork()
            catalogCanResume = false
            catalogBackupStatus = nil
            catalogPreviewStatus = nil
        }
        if access == .inactive, let binding { library?.disableCatalogBackups(binding: binding) }
    }
    private func cancelCatalogWork() {
        catalogPump.cancel()
        linkedCatalogPump.cancel()
        linkedCatalogDeviceCounts = [:]
        catalogPickerFollowsUpdates = false
        previewPump.cancel()
        catalogCatchUpNeeded = false
        catalogCapabilityRetry = nil
        previewDiscoveryNeeded = false
        previewDiscoveryRetry = nil
        previewCaptureTasks.values.forEach { $0.cancel() }
        previewCaptureTasks = [:]
        pendingPreviewCaptures = []
        previewCaptureFlight = nil
        previewCandidates = []
        previewCursor = nil
    }
    private var catalogFlight: CatalogFlight? {
        guard foreground, connectionActive, !cloudAuthorizationRejected, catalogBackupAccess.allowsBackups, let binding = catalogBinding, let library,
              let authorization = library.catalogAuthorization(binding: binding),
              let profile = activeProfile, let session = cloud.session else { return nil }
        return CatalogFlight(generation: connectionGeneration, authorization: authorization, library: ObjectIdentifier(library),
            profileID: profile.id, binding: binding, token: session.accessToken)
    }
    private func requestCatalogCatchUp() {
        // Keep the intent while billing or the connection is not ready. A verified
        // grant must perform capability catch-up even when no revision is queued.
        catalogCatchUpNeeded = true
        requestCatalogSync()
        requestLinkedCatalogSync()
    }
    private func requestCatalogSync() {
        guard catalogFlight != nil else { return }
        catalogPump.request { [weak self] in
            guard let self, let flight = self.catalogFlight else { return .idle }
            return await self.syncCatalog(flight: flight)
        }
    }
    func resumeCatalogBackups() {
        guard catalogCanResume, let flight = catalogFlight, let library else { return }
        do {
            try library.resumeCatalog(binding: flight.binding)
            catalogBackupStatus = library.catalogQueue?.status
            catalogCanResume = false
            requestCatalogSync()
        } catch { catalogBackupStatus = error.localizedDescription }
    }
    private func syncCatalog(flight: CatalogFlight) async -> CatalogWorkPump.Next {
        guard catalogFlight == flight, let library else { return .idle }
        func current() throws {
            guard self.catalogFlight == flight, library.catalogQueue?.authPaused != true, !Task.isCancelled else { throw CancellationError() }
        }
        func refreshStatus() {
            guard self.catalogFlight == flight else { return }
            let queue = library.catalogQueue
            self.catalogCanResume = queue?.captureAllowed == true && queue?.paused == true && queue?.entries.isEmpty == true
            self.catalogBackupStatus = queue?.status ?? queue.map { $0.entries.isEmpty ? "Backup queue is up to date. Catalog shows completed backups; previews may be unavailable." : "\($0.entries.count) screen backups queued. Current screens are saved on this device." }
        }
        var activeIntent: ScreenLibrary.CatalogIntent?
        if let queue = library.catalogQueue, queue.binding != flight.binding {
            catalogBackupStatus = "Backups for this library need their original account and device connection."
            return .idle
        }
        if library.catalogQueue?.authPaused == true {
            catalogBackupStatus = "Backups paused. Sign in again to the original account to continue."
            catalogCanResume = false
            return .idle
        }
        let catchUp = catalogCatchUpNeeded
        let head = library.catalogQueue?.entries.first
        let now = Date()
        if let retry = catalogCapabilityRetry, retry > now { return .retry(retry) }
        if !catchUp {
            guard let head else { refreshStatus(); return .idle }
            if let reason = head.blockedReason { catalogBackupStatus = reason; return .idle }
            if head.retryAt > now.timeIntervalSince1970 { return .retry(Date(timeIntervalSince1970: head.retryAt)) }
        }
        catalogCatchUpNeeded = false
        catalogCapabilityRetry = nil
        do {
            try await cloud.enrollInstallation()
            try current()
            guard let capability = try await cloud.catalogCapability(token: flight.token) else {
                try current()
                try library.setCatalogEntitlement(false, binding: flight.binding)
                previewCaptureFlight = nil; catalogCanResume = false
                catalogBackupStatus = "Cloud backups are unavailable on this server."; return .idle
            }
            try current()
            if DeviceBackupAccess.isVerifiedDenial(enabled: capability.entitlement.backupEnabled, reason: capability.entitlement.reason) {
                billing.recordBackupDenial(cloud: cloud)
                return .idle
            }
            if capability.entitlement.backupEnabled {
                try library.activateCatalog(binding: flight.binding, assetBackups: capability.assetBackupVersion == CatalogContract.assetBackupVersion)
                if capability.previewBackfillVersion == "1", capability.previewMediaTypes.contains("image/png") {
                    previewCaptureFlight = flight
                    previewByteLimit = min(CatalogContract.previewBytes, capability.entitlement.previewBytes)
                    previewDimensionLimit = min(CatalogContract.previewDimension, capability.entitlement.previewDimension)
                    if let revision = screen?.revision { captureExactCatalogPreview(revision: revision) }
                    if catchUp { requestCatalogPreviewSync(discoverCandidates: true) }
                } else { previewCaptureFlight = nil }
            } else { previewCaptureFlight = nil }
            guard library.catalogQueue?.binding == flight.binding else {
                catalogBackupStatus = capability.entitlement.backupEnabled ? "Backups for this library need their original account and device connection." : "Cloud backups are not enabled for this account."
                return .idle
            }
            try library.setCatalogEntitlement(capability.entitlement.backupEnabled, binding: flight.binding)
            refreshStatus()
            guard var intent = library.catalogQueue?.entries.first else {
                if !capability.entitlement.backupEnabled { catalogBackupStatus = "Cloud backups are not enabled for this account. Existing completed backups are retained." }
                return .idle
            }
            activeIntent = intent
            if intent.retryAt > Date().timeIntervalSince1970 { return .retry(Date(timeIntervalSince1970: intent.retryAt)) }
            if intent.packageStorage == "assets" {
                if try await syncCatalogAssetBackup(intent: &intent, flight: flight, library: library, capability: capability, current: current, update: { activeIntent = $0 }) {
                    refreshStatus()
                    return .ready
                }
                return .idle
            }
            // Recover a terminal acknowledgement even after entitlement is disabled.
            if intent.packageDigest != nil {
                do {
                    let known: CatalogBackupStatus = try await cloud.catalogRequest(CatalogContract.operationsPath + intent.operationID, token: flight.token)
                    try current()
                    if try handleCatalogStatus(known, intent: intent, binding: flight.binding, library: library) { refreshStatus(); return .ready }
                } catch let error as CloudClient.CatalogHTTPError where error.status == 404 { try current() }
            }
            guard capability.entitlement.backupEnabled else {
                catalogBackupStatus = "Cloud backups are paused for this account. Existing queued screens stay saved on this device."; return .idle
            }
            if let reason = intent.blockedReason { catalogBackupStatus = reason; return .idle }
            let exported: CatalogPackageExporter.Export
            do { exported = try library.exportCatalogIntent(intent, binding: flight.binding) }
            catch {
                intent.blockedReason = "Backups paused: this committed package is missing, unsafe, or contains credential markers. Keep the screen on this device and contact support to reconcile its backup; later revisions cannot bypass it."
                try library.updateCatalogIntent(intent, binding: flight.binding)
                catalogBackupStatus = intent.blockedReason; return .idle
            }
            guard exported.bytes.count <= capability.entitlement.packageBytes else {
                intent.blockedReason = "Backups paused: this complete screen package exceeds the account limit. Its installed screen is unchanged."
                try library.updateCatalogIntent(intent, binding: flight.binding); catalogBackupStatus = intent.blockedReason; return .idle
            }
            let begin = try library.catalogBegin(intent, declaration: exported.declaration, binding: flight.binding)
            let beginBytes = try CatalogContract.canonical(begin)
            let beginDigest = CatalogContract.digest(beginBytes)
            guard intent.beginDigest == nil || intent.beginDigest == beginDigest else { throw DeviceError.message("The saved backup request changed. Review this screen’s backup connection.") }
            intent.packageDigest = exported.declaration.digest; intent.beginDigest = beginDigest
            try library.updateCatalogIntent(intent, binding: flight.binding); activeIntent = intent
            let started: CatalogBackupStatus = try await cloud.catalogRequest(CatalogContract.beginPath, method: "POST", bytes: beginBytes, token: flight.token)
            try current()
            if try handleCatalogStatus(started, intent: intent, binding: flight.binding, library: library) { refreshStatus(); return .ready }
            guard started.operationID == intent.operationID, let upload = started.uploadID,
                  upload.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$", options: .regularExpression) != nil else { throw DeviceError.message("Cloud did not confirm this backup operation.") }
            intent.uploadID = upload; try library.updateCatalogIntent(intent, binding: flight.binding); activeIntent = intent
            let _: EmptyResponse = try await cloud.catalogRequest(CatalogContract.uploadsPath + upload + "/package", method: "PUT", bytes: exported.bytes, token: flight.token, package: true)
            try current()
            let completed: CatalogBackupStatus = try await cloud.catalogRequest(CatalogContract.uploadsPath + upload + "/complete", method: "POST", bytes: CatalogContract.canonical(CatalogCompleteBackup(operationID: intent.operationID)), token: flight.token)
            try current()
            guard try handleCatalogStatus(completed, intent: intent, binding: flight.binding, library: library) else { throw DeviceError.message("The backup has not completed yet.") }
            refreshStatus(); return .ready
        } catch is CancellationError { return .idle }
        catch DeviceError.http(let status, _) where status == 401 {
            guard catalogFlight == flight, !Task.isCancelled else { return .idle }
            try? library.pauseCatalogAuthentication(binding: flight.binding)
            catalogBackupStatus = "Backups paused. Sign in again to the original account to continue."
            catalogCanResume = false
            return .idle
        }
        catch {
            guard catalogFlight == flight, !Task.isCancelled else { return .idle }
            if let detail = error as? CloudClient.CatalogHTTPError, DeviceBackupAccess.isVerifiedDenial(status: detail.status, code: detail.code) {
                billing.recordBackupDenial(cloud: cloud)
                return .idle
            }
            if let detail = error as? CloudClient.CatalogHTTPError, detail.status == 401 || detail.code == "unauthorized" {
                try? library.pauseCatalogAuthentication(binding: flight.binding)
                catalogBackupStatus = "Backups paused. Sign in again to the original account to continue."
                catalogCanResume = false
                return .idle
            }
            if var intent = activeIntent, library.catalogQueue?.entries.first?.id == intent.id {
                intent.attempts = min(16, intent.attempts + 1)
                let detail = error as? CloudClient.CatalogHTTPError
                let delay = max(detail?.retryAfterSeconds ?? 0, Int(min(3600, pow(2, Double(min(12, intent.attempts)))) * Double.random(in: 0.75...1.25)))
                intent.retryAt = Date().timeIntervalSince1970 + Double(max(2, delay))
                if ["invalid_package", "conflict"].contains(detail?.code ?? "") {
                    intent.blockedReason = "Backups paused: Cloud rejected this saved package or its history. Keep the installed screen and contact support to reconcile the pending backup."
                }
                do { try library.updateCatalogIntent(intent, binding: flight.binding) }
                catch { catalogCapabilityRetry = Date(timeIntervalSince1970: intent.retryAt) }
                if detail?.code == "quota_exceeded" {
                    catalogBackupStatus = "Cloud backup storage is full. Free account storage to continue. Queued screens stay on this device."
                } else {
                    catalogBackupStatus = intent.blockedReason ?? "Screen backups will retry when Cloud is available. Queued revisions stay on this device."
                }
                return intent.blockedReason == nil ? .retry(Date(timeIntervalSince1970: intent.retryAt)) : .idle
            }
            catalogBackupStatus = "Cloud backups will retry. Your installed screens are saved on this device."
            catalogCatchUpNeeded = catalogCatchUpNeeded || catchUp
            let delay = max(5, (error as? CloudClient.CatalogHTTPError)?.retryAfterSeconds ?? 0)
            let retry = Date().addingTimeInterval(Double(delay))
            catalogCapabilityRetry = retry
            return .retry(retry)
        }
    }
    private func syncCatalogAssetBackup(
        intent: inout ScreenLibrary.CatalogIntent,
        flight: CatalogFlight,
        library: ScreenLibrary,
        capability: CatalogCapability,
        current: () throws -> Void,
        update: (ScreenLibrary.CatalogIntent) -> Void
    ) async throws -> Bool {
        guard capability.assetBackupVersion == CatalogContract.assetBackupVersion else {
            catalogBackupStatus = "This server does not support the queued catalog backup format."
            return false
        }
        var progress: CloudClient.CatalogAssetProgress?
        if intent.beginDigest != nil {
            do {
                let known = try await cloud.catalogAssetProgress(CloudClient.assetOperationsPath + intent.operationID, token: flight.token)
                try current()
                if try handleCatalogStatus(known.status, intent: intent, binding: flight.binding, library: library) { return true }
                progress = known
            } catch let error as CloudClient.CatalogHTTPError where error.status == 404 { try current() }
        }
        guard capability.entitlement.backupEnabled else {
            catalogBackupStatus = "Cloud backups are paused for this account. Queued screens stay saved on this device."
            return false
        }
        if let reason = intent.blockedReason { catalogBackupStatus = reason; return false }
        let exported: CatalogPackageExporter.AssetExport
        do {
            exported = try await library.exportCatalogAssetIntent(intent, binding: flight.binding)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try current()
            intent.blockedReason = "Backups paused: a saved file is missing, unsafe, or contains credential markers. Review the screen before continuing."
            try library.updateCatalogIntent(intent, binding: flight.binding)
            update(intent)
            catalogBackupStatus = intent.blockedReason
            return false
        }
        try current()
        let begin = try library.catalogBegin(intent, declaration: exported.declaration, binding: flight.binding)
        let beginBytes = try CatalogContract.canonical(CatalogAssetBeginRequest(backup: begin, manifest: exported.manifest))
        let beginDigest = CatalogContract.digest(beginBytes)
        guard intent.beginDigest == nil || intent.beginDigest == beginDigest else {
            throw DeviceError.message("The saved backup request changed.")
        }
        intent.packageDigest = exported.declaration.digest
        intent.packageBytes = exported.declaration.byteLength
        intent.beginDigest = beginDigest
        try library.updateCatalogIntent(intent, binding: flight.binding)
        update(intent)
        if progress == nil {
            progress = try await cloud.catalogAssetProgress(CloudClient.assetBackupsPath, method: "POST", bytes: beginBytes, token: flight.token)
            try current()
        }
        guard let progress else { throw DeviceError.message("Cloud did not confirm this backup operation.") }
        return try await uploadCatalogAssets(progress, exported: exported, operationID: intent.operationID, token: flight.token,
            current: current, applied: { status in
                try handleCatalogStatus(status, intent: intent, binding: flight.binding, library: library)
            }, rememberUpload: { upload in
                intent.uploadID = upload
                try library.updateCatalogIntent(intent, binding: flight.binding)
                update(intent)
            })
    }

    private func uploadCatalogAssets(_ initial: CloudClient.CatalogAssetProgress, exported: CatalogPackageExporter.AssetExport,
                                    operationID: String, token: String, current: () throws -> Void,
                                    applied: (CatalogBackupStatus) throws -> Bool,
                                    rememberUpload: (String) throws -> Void = { _ in }) async throws -> Bool {
        var started = initial
        if try applied(started.status) { return true }
        guard let upload = started.status.uploadID, CloudClient.validCatalogIdentifier(upload) else {
            throw DeviceError.message("Cloud did not confirm this upload.")
        }
        try rememberUpload(upload)
        let uploadPath = CloudClient.assetUploadsPath + upload
        let files = Dictionary(exported.manifest.files.map { ($0.digest, $0) }, uniquingKeysWith: { first, _ in first })
        while let missing = started.missingFiles.first {
            guard started.missingFiles.count <= files.count, let file = files[missing.digest] else {
                throw DeviceError.message("Cloud requested an unknown backup asset.")
            }
            let chunk = try exported.chunk(file: file, offset: missing.offset)
            let path = uploadPath + "/assets/" + missing.digest + "?offset=" + String(missing.offset)
            started = try await cloud.catalogAssetProgress(path, method: "PUT", bytes: chunk, token: token, chunk: true)
            try current()
            if try applied(started.status) { return true }
            guard started.status.uploadID == upload,
                  started.missingFiles.allSatisfy({ $0.digest != missing.digest || $0.offset >= missing.offset + chunk.count }) else {
                throw DeviceError.message("Cloud did not advance this backup asset.")
            }
        }
        let complete = try CatalogContract.canonical(CatalogCompleteBackup(operationID: operationID))
        let completed = try await cloud.catalogAssetProgress(uploadPath + "/complete", method: "POST", bytes: complete, token: token)
        try current()
        guard try applied(completed.status) else {
            throw DeviceError.message("The backup has not completed yet.")
        }
        return true
    }

    private struct CatalogAssetBeginRequest: Encodable {
        var backup: CatalogBeginBackup
        var manifest: CatalogAssetManifest
        var link: CatalogLinkedPublication? = nil
    }

    private func handleCatalogStatus(_ status: CatalogBackupStatus, intent: ScreenLibrary.CatalogIntent, binding: ScreenLibrary.CatalogBinding, library: ScreenLibrary) throws -> Bool {
        guard status.schemaVersion == 1, status.operationID == intent.operationID else { throw DeviceError.message("Cloud returned a different backup operation.") }
        try CatalogContract.validateStatus(status)
        if status.state == "failed", status.error?.code == "retry_later", status.error?.restartOperation == true {
            try library.restartExpiredCatalogOperation(intentID: intent.id, operationID: intent.operationID, binding: binding)
            return true
        }
        if status.state == "failed", let error = status.error {
            throw CloudClient.CatalogHTTPError(status: error.code == "unauthorized" ? 401 : error.code == "not_entitled" ? 403 : 400, code: error.code, retryAfterSeconds: error.retryAfterSeconds)
        }
        guard ["completed", "duplicate", "superseded", "deleted"].contains(status.state) else { return false }
        if ["completed", "duplicate"].contains(status.state), let version = status.versionID, let queue = library.catalogQueue, let copy = queue.copies[intent.screenID], let digest = intent.packageDigest {
            let candidate = CatalogPreviewCandidate(catalogScreenID: status.catalogScreenID, versionID: version, libraryID: queue.libraryID, localScreenID: copy.localScreenID, sourceRevisionID: intent.revision, packageDigest: digest, packageBytes: intent.packageBytes, packageStorage: intent.packageStorage)
            try? library.bindCatalogPreview(candidate, binding: binding)
            if previewCaptureFlight == catalogFlight {
                rememberPreviewCandidate(candidate)
                enqueuePreviewCaptures([candidate])
                requestCatalogPreviewSync()
            }
        } else if ["deleted", "superseded"].contains(status.state), let preview = library.catalogQueue?.previews?.first(where: { $0.revision == intent.revision }) {
            try? library.acknowledgeCatalogPreview(preview, binding: binding)
        }
        if ["completed", "duplicate"].contains(status.state) {
            try library.recordCatalogIdentity(status.catalogScreenID, screenID: intent.screenID)
            requestScreenDataInventory()
        }
        try library.acknowledgeCatalogIntent(id: intent.id, binding: binding)
        if ["completed", "duplicate"].contains(status.state) { requestLinkedCatalogSync() }
        return true
    }
}


extension DeviceModel {
    private var deviceNameStorageKey: String? { CloudClient.installationDeviceNameKey }
    private func refreshDeviceName() {
        let fallback = (try? DeviceNameStore.normalized(UIDevice.current.name)) ?? "Screenpunk"
        displayName = deviceNameStorageKey.map { DeviceNameStore().name(for: $0, fallback: fallback) } ?? fallback
        deviceNameSyncStatus = nil
    }
    func updateDeviceName(_ name: String) {
        guard let key = deviceNameStorageKey else { message = "Device identity is not ready. Try again shortly."; return }
        do {
            try cloud.queueDeviceName(name)
            displayName = try DeviceNameStore().save(name, for: key)
            deviceNameSyncStatus = cloudBindingMatches ? "Saved on this iPad. Updating Cloud…" : "Saved on this iPad. Cloud will update when this account is connected."
            requestPreferenceSync()
        } catch { message = error.localizedDescription }
    }
}


extension DeviceModel {
    var catalogPreviewContext: CatalogPreviewContext? {
        guard catalogBackupsEnabled, catalogBackupAccess.allowsBackups, let profile = activeProfile, let binding = profile.cloudBinding else { return nil }
        return .init(origin: CloudClient.origin.absoluteString, accountID: binding.accountID, profileID: profile.id, libraryID: profile.libraryOwner, deviceID: binding.deviceID)
    }
    private func requestCatalogPreviewSync(discoverCandidates: Bool = false) {
        guard catalogFlight != nil else { return }
        if discoverCandidates { previewDiscoveryNeeded = true }
        previewPump.request { [weak self] in
            guard let self, let flight = self.catalogFlight else { return .idle }
            return await self.syncCatalogPreviews(flight: flight)
        }
    }
    private func rememberPreviewCandidate(_ candidate: CatalogPreviewCandidate) {
        if let index = previewCandidates.firstIndex(where: { $0.sourceRevisionID == candidate.sourceRevisionID }) {
            previewCandidates[index] = candidate
        } else if previewCandidates.count < 100 {
            previewCandidates.append(candidate)
        }
    }
    private func enqueuePreviewCaptures(_ candidates: [CatalogPreviewCandidate]) {
        for candidate in candidates where pendingPreviewCaptures.count < 100 && !pendingPreviewCaptures.contains(candidate.sourceRevisionID) {
            pendingPreviewCaptures.append(candidate.sourceRevisionID)
        }
        drainPreviewCaptures()
    }
    private func drainPreviewCaptures() {
        guard !settingsOpen, previewCaptureFlight != nil else { return }
        while previewCaptureTasks.count < 2, !pendingPreviewCaptures.isEmpty {
            captureExactCatalogPreview(revision: pendingPreviewCaptures.removeFirst())
        }
    }
    private func captureExactCatalogPreview(revision: String) {
        guard let flight = catalogFlight, previewCaptureFlight == flight, !settingsOpen,
              let context = catalogPreviewContext, let library, library.catalogCaptureAllowed(binding: flight.binding),
              previewCaptureTasks[revision] == nil, previewCaptureTasks.count < 2 else { return }
        let candidate = previewCandidates.first { $0.sourceRevisionID == revision }
        let digest = library.catalogQueue?.entries.first(where: { $0.revision == revision })?.packageDigest ?? candidate?.packageDigest
        guard let digest, library.catalogQueue?.previewFinishedSources?.contains(revision + ":" + digest) != true,
              library.catalogQueue?.previews?.contains(where: { $0.revision == revision && $0.packageDigest == digest }) != true else { return }
        previewCaptureTasks[revision] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.connectionGeneration == flight.generation, library.catalogAuthorization(binding: flight.binding) == flight.authorization {
                    self.previewCaptureTasks[revision] = nil
                    self.drainPreviewCaptures()
                }
            }
            @MainActor func captureAllowed() -> Bool {
                self.catalogFlight == flight && self.previewCaptureFlight == flight && library.catalogCaptureAllowed(binding: flight.binding) &&
                    self.catalogPreviewContext == context && !self.settingsOpen && !Task.isCancelled
            }
            guard captureAllowed() else { return }
            do {
                let snapshot: CatalogPreviewRenderer.Snapshot
                if let candidate, candidate.packageStorage == "assets" {
                    var path = URLComponents()
                    path.path = "/api/catalog/screens/\(candidate.catalogScreenID)/versions/\(candidate.versionID)"
                    path.queryItems = [.init(name: "sourceRevisionID", value: revision), .init(name: "packageDigest", value: digest)]
                    let manifest = try await self.cloud.catalogVersionManifest(path, token: flight.token, declaration: .init(byteLength: candidate.packageBytes, digest: digest))
                    guard captureAllowed() else { return }
                    snapshot = try await CatalogPreviewCaptureRegistry.shared.capture(context: context, revision: revision, manifest: manifest, packageDigest: digest, byteLimit: self.previewByteLimit, dimensionLimit: self.previewDimensionLimit)
                } else {
                    let package: CatalogPackage
                    if let recovered = try? library.catalogPackage(revision: revision, digest: digest, binding: flight.binding) { package = recovered.package }
                    else if let candidate {
                        var path = URLComponents(); path.path = "/api/catalog/screens/\(candidate.catalogScreenID)/versions/\(candidate.versionID)/package"
                        path.queryItems = [.init(name: "sourceRevisionID", value: revision), .init(name: "packageDigest", value: digest)]
                        package = try await self.cloud.catalogPackage(path.string!, token: flight.token, declaration: .init(byteLength: candidate.packageBytes, digest: digest))
                    } else { return }
                    guard captureAllowed() else { return }
                    do { snapshot = try await CatalogPreviewCaptureRegistry.shared.capture(context: context, revision: revision, package: package, packageDigest: digest, byteLimit: self.previewByteLimit, dimensionLimit: self.previewDimensionLimit) }
                    catch {
                        guard captureAllowed() else { return }
                        snapshot = try await CatalogPreviewRenderer().capture(package: package, packageDigest: digest, byteLimit: self.previewByteLimit, dimensionLimit: self.previewDimensionLimit)
                    }
                }
                guard captureAllowed(), snapshot.packageDigest == digest else { return }
                let d = snapshot.declaration
                try library.captureCatalogPreview(bytes: snapshot.bytes, declaration: .init(byteLength: d.byteLength, digest: d.digest, width: d.width, height: d.height), revision: revision, packageDigest: digest, capturedAt: CatalogContract.timestamp(Date()), binding: flight.binding, candidate: candidate)
                if let candidate { try library.bindCatalogPreview(candidate, binding: flight.binding) }
                self.catalogPreviewStatus = "Screenshot captured for this exact version. Its upload will retry independently."
                self.requestCatalogPreviewSync()
            } catch {
                guard self.catalogFlight == flight, !Task.isCancelled else { return }
                self.catalogPreviewStatus = "A preview needs this exact version displayed and fully loaded. Completed backups remain available."
            }
        }
    }
    private func syncCatalogPreviews(flight: CatalogFlight) async -> CatalogWorkPump.Next {
        guard catalogFlight == flight, let library, library.catalogCaptureAllowed(binding: flight.binding) else { return .idle }
        func current() throws {
            guard self.catalogFlight == flight, library.catalogCaptureAllowed(binding: flight.binding),
                  !Task.isCancelled else { throw CancellationError() }
        }
        var attempted: ScreenLibrary.CatalogCapturedPreview?
        let now = Date()
        let discover = (previewDiscoveryNeeded || previewCursor != nil) &&
            (previewDiscoveryRetry.map { $0 <= now } ?? true)
        do {
            if discover {
                if previewDiscoveryNeeded { previewCursor = nil }
                previewDiscoveryNeeded = false
                guard let capability = try await cloud.catalogCapability(token: flight.token) else {
                    try current()
                    previewCaptureFlight = nil; previewCursor = nil
                    return .idle
                }
                try current()
                if DeviceBackupAccess.isVerifiedDenial(enabled: capability.entitlement.backupEnabled, reason: capability.entitlement.reason) {
                    billing.recordBackupDenial(cloud: cloud)
                    return .idle
                }
                guard capability.previewBackfillVersion == "1", capability.previewMediaTypes.contains("image/png"), capability.entitlement.backupEnabled else {
                    previewCaptureFlight = nil; previewCursor = nil
                    return .idle
                }
                previewByteLimit = min(CatalogContract.previewBytes, capability.entitlement.previewBytes)
                previewDimensionLimit = min(CatalogContract.previewDimension, capability.entitlement.previewDimension)
                previewCaptureFlight = flight
                var path = URLComponents(); path.path = CatalogContract.previewCandidatesPath
                if let cursor = previewCursor { path.queryItems = [.init(name: "cursor", value: cursor)] }
                let page: CatalogPreviewCandidates = try await cloud.catalogRequest(path.string!, token: flight.token)
                try current()
                guard page.schemaVersion == 1, page.candidates.count <= 20,
                      page.nextCursor == nil || page.nextCursor != previewCursor else {
                    throw DeviceError.message("Invalid preview candidates.")
                }
                if previewCursor == nil { previewCandidates = [] }
                let candidates = page.candidates.filter { candidate in
                    candidate.libraryID == library.catalogQueue?.libraryID &&
                        library.catalogQueue?.copies.values.contains(where: { $0.localScreenID == candidate.localScreenID }) == true &&
                        [candidate.catalogScreenID, candidate.versionID, candidate.sourceRevisionID].allSatisfy {
                            $0.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$", options: .regularExpression) != nil
                        }
                }
                for candidate in candidates {
                    rememberPreviewCandidate(candidate)
                    try library.bindCatalogPreview(candidate, binding: flight.binding)
                }
                previewDiscoveryRetry = nil
                previewCursor = page.nextCursor
                if let revision = screen?.revision { captureExactCatalogPreview(revision: revision) }
                enqueuePreviewCaptures(candidates)
            }
            guard previewCaptureFlight == flight else {
                return previewDiscoveryRetry.map(CatalogWorkPump.Next.retry) ?? .idle
            }
            let jobs = (library.catalogQueue?.previews ?? []).filter { $0.candidate != nil }
            guard var preview = jobs.first(where: { $0.retryAt <= now.timeIntervalSince1970 }) else {
                if previewDiscoveryRetry == nil, previewCursor != nil || previewDiscoveryNeeded { return .ready }
                let uploadRetry = jobs.map { Date(timeIntervalSince1970: $0.retryAt) }.min()
                return [uploadRetry, previewDiscoveryRetry].compactMap { $0 }.min().map(CatalogWorkPump.Next.retry) ?? .idle
            }
            attempted = preview
            let candidate = preview.candidate!
            let begin = CatalogPreviewBegin(operationID: preview.operationID, catalogScreenID: candidate.catalogScreenID, versionID: candidate.versionID, libraryID: candidate.libraryID, localScreenID: candidate.localScreenID, sourceRevisionID: preview.revision, packageDigest: preview.packageDigest, capturedAt: preview.capturedAt, preview: preview.declaration)
            let digest = try CatalogContract.previewBeginDigest(begin)
            guard preview.beginDigest == nil || preview.beginDigest == digest else { throw DeviceError.message("The immutable screenshot intent changed.") }
            if preview.beginDigest != nil {
                do {
                    let status: CatalogPreviewStatus = try await cloud.catalogRequest(CatalogContract.previewOperationsPath + preview.operationID, token: flight.token)
                    try current()
                    if try handlePreviewStatus(status, preview: preview, binding: flight.binding, library: library) { return .ready }
                } catch let error as CloudClient.CatalogHTTPError where error.status == 404 { try current() }
            }
            let bytes = try library.readCatalogPreview(preview, binding: flight.binding)
            preview.beginDigest = digest; try library.updateCatalogPreview(preview, binding: flight.binding); attempted = preview
            let begun: CatalogPreviewStatus = try await cloud.catalogRequest(CatalogContract.previewBeginPath, method: "POST", bytes: CatalogContract.canonical(begin), token: flight.token)
            try current()
            if try handlePreviewStatus(begun, preview: preview, binding: flight.binding, library: library) { return .ready }
            guard let upload = begun.uploadID, upload.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$", options: .regularExpression) != nil else { throw DeviceError.message("Cloud did not confirm the screenshot upload.") }
            let uploaded: CatalogPreviewStatus = try await cloud.catalogRequest(CatalogContract.previewUploadsPath + upload + "/image", method: "PUT", bytes: bytes, token: flight.token, image: true)
            try current()
            if try handlePreviewStatus(uploaded, preview: preview, binding: flight.binding, library: library) { return .ready }
            let completed: CatalogPreviewStatus = try await cloud.catalogRequest(CatalogContract.previewUploadsPath + upload + "/complete", method: "POST", bytes: CatalogContract.canonical(CatalogCompleteBackup(operationID: preview.operationID)), token: flight.token)
            try current()
            guard try handlePreviewStatus(completed, preview: preview, binding: flight.binding, library: library) else { throw DeviceError.message("Screenshot publication will retry.") }
            catalogPreviewStatus = nil; return .ready
        } catch is CancellationError { return .idle }
        catch {
            guard catalogFlight == flight, !Task.isCancelled else { return .idle }
            if let detail = error as? CloudClient.CatalogHTTPError,
               DeviceBackupAccess.isVerifiedDenial(status: detail.status, code: detail.code) {
                billing.recordBackupDenial(cloud: cloud)
                return .idle
            }
            if let detail = error as? CloudClient.CatalogHTTPError, detail.status == 401 || detail.code == "unauthorized" {
                try? library.pauseCatalogAuthentication(binding: flight.binding)
                previewCaptureFlight = nil
                return .idle
            }
            if let preview = attempted, let detail = error as? CloudClient.CatalogHTTPError, detail.code == "deleted" {
                try? library.acknowledgeCatalogPreview(preview, binding: flight.binding)
                return .ready
            }
            if var preview = attempted {
                preview.attempts = min(16, preview.attempts + 1)
                let delay = max((error as? CloudClient.CatalogHTTPError)?.retryAfterSeconds ?? 0, Int(min(3600, pow(2, Double(min(12, preview.attempts)))) * Double.random(in: 0.75...1.25)))
                preview.retryAt = Date().timeIntervalSince1970 + Double(max(2, delay))
                do { try library.updateCatalogPreview(preview, binding: flight.binding) }
                catch { return .retry(Date().addingTimeInterval(Double(max(2, delay)))) }
            } else if discover {
                if previewCursor == nil { previewDiscoveryNeeded = true }
                let delay = max(30, (error as? CloudClient.CatalogHTTPError)?.retryAfterSeconds ?? 0)
                previewDiscoveryRetry = Date().addingTimeInterval(Double(delay))
            }
            catalogPreviewStatus = "Screenshot upload will retry. Completed screen backups are unaffected."
            return .ready
        }
    }
    private func handlePreviewStatus(_ status: CatalogPreviewStatus, preview: ScreenLibrary.CatalogCapturedPreview, binding: ScreenLibrary.CatalogBinding, library: ScreenLibrary) throws -> Bool {
        guard status.schemaVersion == 1, status.operationID == preview.operationID, status.versionID == preview.candidate?.versionID, status.catalogScreenID == preview.candidate?.catalogScreenID else { throw DeviceError.message("Cloud returned a different screenshot operation.") }
        try CatalogContract.validateStatus(status)
        if status.state == "failed", status.error?.code == "retry_later", status.error?.restartOperation == true {
            var next = preview; next.operationID = UUID().uuidString; next.beginDigest = nil; next.retryAt = 0; next.attempts = 0
            try library.updateCatalogPreview(next, binding: binding); return true
        }
        if ["completed", "duplicate", "deleted"].contains(status.state) { try library.acknowledgeCatalogPreview(preview, binding: binding); return true }
        if status.state == "failed", let error = status.error { throw CloudClient.CatalogHTTPError(status: error.code == "unauthorized" ? 401 : error.code == "not_entitled" ? 403 : 400, code: error.code, retryAfterSeconds: error.retryAfterSeconds) }
        return false
    }
}
