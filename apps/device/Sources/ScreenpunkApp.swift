import SwiftUI
import MetalKit
#if DEBUG
import os
#endif
import ScreenpunkApple
import ScreenpunkCore

@main struct ScreenpunkApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if #available(iOS 17, *), ProcessInfo.processInfo.arguments.contains("--screenpunk-test-ripple76") {
                RecordingRippleSelfTest(useWebKit: ProcessInfo.processInfo.arguments.contains("--screenpunk-test-ripple76-webkit"))
            } else {
                DeviceRootView()
            }
            #else
            DeviceRootView()
            #endif
        }
    }
}
private struct GalleryIntroHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct GalleryIntroSheet: View {
    let confirm: () -> Void
    @State private var contentHeight: CGFloat = 300

    var body: some View {
        if #available(iOS 18, *) {
            content.presentationSizing(.form.fitted(horizontal: false, vertical: true))
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Explore the Gallery").font(.largeTitle.bold())
                Text("Weather and NASA Gallery are ready to explore. Swipe left or right with two fingers to switch screens.")
                    .font(.title3).foregroundStyle(.secondary)
                Button("Got it", action: confirm)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 16)
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: GalleryIntroHeight.self, value: geometry.size.height)
            })
        }
        .frame(idealHeight: contentHeight)
        .onPreferenceChange(GalleryIntroHeight.self) { height in
            if height > 0 { contentHeight = ceil(height) }
        }
        .presentationDetents([.height(contentHeight)])
        .interactiveDismissDisabled()
    }
}

struct DeviceRootView: View {
    @StateObject private var model = DeviceModel()
    @StateObject private var speech = SpeechCapture()
    @StateObject private var display = DeviceDisplayPreferences()
    @State private var settingsCoverPresented = false
    @State private var galleryIntro: GalleryIntro?
    @State private var weatherDestination: WeatherDestination?
    private struct WeatherDestination: Identifiable {
        let id: String
        let owner: String
        let revision: String
        let useCurrentLocation: Bool
    }
    private var weatherOffer: WeatherDestination? {
        model.weatherLocationOfferScreen.map { WeatherDestination(id: $0.id, owner: model.permissionOwner,
            revision: $0.revision, useCurrentLocation: false) }
    }
    @State private var onboardingHelp: OnboardingHelp?
    // The item becomes nil when dismissal starts. Wait for onDismiss before presenting again.
    @State private var onboardingHelpInFlight = false
    @State private var recordingBackdropScope: RecordingBackdropScope?
    @State private var dashboardSnapshot = DashboardSnapshotSource()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swipeID: UUID?
    @State private var swipeStartContext: SwipeContext?
    @State private var swipeWidth: CGFloat = 0
    @State private var swipeOffset: CGFloat = 0
    @State private var swipeSettling = false
    @State private var swipeCoverOpacity = 0.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            screenLayer
                .blur(radius: speech.recording ? 5 : 0)
                .overlay { recordingRipple }
                .overlay {
                    if speech.recording {
                        Color.black.opacity(0.22).ignoresSafeArea()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .offset(x: swipeOffset)
            Color.black.ignoresSafeArea()
                .opacity(swipeCoverOpacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if scenePhase == .active && !model.settingsOpen && galleryIntro == nil &&
                !showsCloudOnboarding && !speech.recording && speech.error == nil && model.showsAgentWorking {
                AgentWorkingEdge()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if speech.recording {
                VStack(spacing: 20) {
                    Image(systemName: "mic.fill").font(.system(size: 52)).foregroundStyle(.orange)
                    Text("Listening…").font(.largeTitle.bold())
                    Text("Keep holding while you talk. Lift your fingers to send.")
                    Text(speech.transcript).font(.title3).multilineTextAlignment(.center)
                }.padding(40).frame(maxWidth: 650).allowsHitTesting(false)
            } else if !showsCloudOnboarding && !model.settingsOpen && !model.accountOperationInProgress && (model.busy || model.requestPending || model.routeChangeBlocked || model.canRetry || model.canCancelRequest || speech.error != nil || model.presentedStatusMessage != nil) {
                GeometryReader { geometry in
                    VStack {
                        Spacer()
                        RequestStatusPill(model: model, speechError: speech.error, maximumTextHeight: max(80, geometry.size.height * 0.45))
                            .padding(24)
                    }.frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundStyle(.white)
        .background(DeviceGestures(
            began: beginSpeech, ended: speech.end, cancelled: speech.cancel,
            canSwipe: canSwipe && swipeID == nil, pagePan: handlePagePan,
            settings: { if galleryIntro == nil && weatherDestination == nil && !onboardingHelpInFlight { model.openSettings() } }
        ))
        .statusBarHidden()
        .onChange(of: swipeContext) { _ in cancelPagePan() }
        #if DEBUG
        .onChange(of: speech.recording) { recording in
            RecordingRippleDiagnostics.event(recording ? rippleEligibilityPhase : "recording ended")
        }
        #endif
        .onChange(of: currentRecordingBackdropScope) { _ in recordingBackdropScope = nil }
        .onChange(of: model.accountOperationInProgress) { active in
            if active { recordingBackdropScope = nil }
        }
        .onChange(of: canSwipe) { enabled in if !enabled { cancelPagePan() } }
        .onDisappear {
            cancelPagePan()
            if !model.settingsOpen { model.setForeground(false) }
            speech.cancel()
        }
        .fullScreenCover(isPresented: $model.settingsOpen, onDismiss: {
            settingsCoverPresented = false
            advanceOnboarding()
        }) {
            DeviceSettingsView(model: model, display: display)
                .onAppear { settingsCoverPresented = true }
        }
        .sheet(item: $onboardingHelp, onDismiss: {
            onboardingHelpInFlight = false
            advanceOnboarding()
        }) { help in
            CloudListenerSetupSheet(scope: help.scope, email: help.email, stage: help.id.stage)
        }
        .sheet(item: $galleryIntro) { intro in
            GalleryIntroSheet {
                model.dismissGalleryIntro(owner: intro.id)
                galleryIntro = nil
            }
        }
        .sheet(item: $weatherDestination) { destination in
            NavigationStack {
                DevicePublicDataDetails(model: model, screenID: destination.id, owner: destination.owner,
                                        initialUseCurrentLocation: destination.useCurrentLocation, initialRevision: destination.revision)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { weatherDestination = nil } } }
            }
        }
        .modifier(ScreenDataConsentAlert(model: model, isHost: scenePhase == .active && !model.settingsOpen &&
            galleryIntro == nil && weatherDestination == nil && !onboardingHelpInFlight && !settingsCoverPresented && !speech.recording))
        .alert("Weather location", isPresented: Binding(
            get: { model.screenDataPrompt == nil && scenePhase == .active && !model.settingsOpen && galleryIntro == nil && weatherDestination == nil && !onboardingHelpInFlight &&
                !settingsCoverPresented && !speech.recording && model.weatherLocationOfferScreen != nil },
            set: { _ in }
        ), presenting: weatherOffer) { offer in
            Button("Use my location") { openWeatherLocation(offer, useCurrentLocation: true) }
            Button("Enter city or ZIP") { openWeatherLocation(offer, useCurrentLocation: false) }
            Button("Keep Ann Arbor", role: .cancel) {
                guard offer.owner == model.permissionOwner, model.screen?.id == offer.id,
                      model.screen?.revision == offer.revision else { return }
                model.acknowledgeWeatherLocationOffer(screenID: offer.id, owner: offer.owner)
            }
        } message: { _ in
            Text("Weather starts in Ann Arbor. Choose a U.S. location, or keep it for now. Use my location asks permission for a single lookup; it does not track you.")
        }
        .onAppear(perform: advanceOnboarding)
        .onChange(of: onboardingHelpContext) { _ in advanceOnboarding() }
        .onChange(of: model.canFinishAgentSetup) { _ in advanceOnboarding() }
        .onChange(of: model.galleryIntroOwner) { _ in advanceOnboarding() }
        .modifier(BackupUpgradeAlert(model: model, billing: model.billing,
                                     isHost: !model.settingsOpen && !settingsCoverPresented && galleryIntro == nil && weatherDestination == nil && model.weatherLocationOfferScreen == nil && !onboardingHelpInFlight))
        .onChange(of: model.settingsOpen) { presented in
            if !presented { model.refreshConnections() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                model.reconcileTemporary()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
        .task(id: BillingRecoveryKey(active: scenePhase == .active, accountID: model.cloud.localAccountID,
                                     changingAccount: model.accountOperationInProgress)) {
            if scenePhase == .active && !model.accountOperationInProgress {
                await model.billing.recover(cloud: model.cloud)
            }
        }
        .task(id: scenePhase) {
            UIApplication.shared.isIdleTimerDisabled = scenePhase == .active
            display.setActive(scenePhase == .active)
            model.setForeground(scenePhase == .active)
            if scenePhase != .active { speech.cancel() }
        }
    }
    private func openWeatherLocation(_ offer: WeatherDestination, useCurrentLocation: Bool) {
        guard offer.owner == model.permissionOwner, !model.accountOperationInProgress,
              model.screen?.id == offer.id, model.screen?.revision == offer.revision else { return }
        model.acknowledgeWeatherLocationOffer(screenID: offer.id, owner: offer.owner)
        weatherDestination = WeatherDestination(id: offer.id, owner: offer.owner, revision: offer.revision,
                                                useCurrentLocation: useCurrentLocation)
    }

    private struct GalleryIntro: Identifiable {
        let id: String
    }

    private struct OnboardingHelpContext: Hashable {
        let identity: AgentPluginIdentity
        let stage: CloudSetupStage
    }

    private struct OnboardingHelp: Identifiable {
        let id: OnboardingHelpContext
        let scope: CloudOriginScope
        let email: String?
    }

    private var onboardingHelpContext: OnboardingHelpContext? {
        guard showsCloudOnboarding, !model.accountOperationInProgress else { return nil }
        let stage: CloudSetupStage = model.showsCloudPluginConnection ? .plugin : .listener
        return OnboardingHelpContext(
            identity: AgentPluginIdentity(origin: CloudClient.originScope.canonicalOrigin,
                                          account: model.cloud.localAccountID, owner: model.permissionOwner),
            stage: stage
        )
    }

    private func openOnboardingHelp(_ stage: CloudSetupStage) {
        guard let context = onboardingHelpContext, context.stage == stage,
              !onboardingHelpInFlight, galleryIntro == nil, !model.settingsOpen, !settingsCoverPresented else { return }
        onboardingHelpInFlight = true
        onboardingHelp = OnboardingHelp(id: context, scope: CloudClient.originScope, email: model.email)
    }

    private func advanceOnboarding() {
        if onboardingHelpInFlight {
            if let onboardingHelp, onboardingHelp.id != onboardingHelpContext || model.canFinishAgentSetup {
                self.onboardingHelp = nil
            }
            return
        }
        guard !model.settingsOpen, !settingsCoverPresented else { return }
        model.finishAgentSetup()
        if let owner = model.galleryIntroOwner, galleryIntro == nil {
            galleryIntro = GalleryIntro(id: owner)
        }
    }

    private struct BillingRecoveryKey: Equatable {
        let active: Bool
        let accountID: String?
        let changingAccount: Bool
    }

    private var canSwipe: Bool {
        scenePhase == .active && !model.permissionOwner.isEmpty &&
            !model.settingsOpen && !settingsCoverPresented && !model.busy &&
            !model.accountOperationInProgress && !speech.recording &&
            !model.needsAgentSetup && !onboardingHelpInFlight && model.canSwipeScreens &&
            model.galleryIntroOwner == nil && galleryIntro == nil &&
            model.billing.backupUpgradePrompt(for: model.cloud) == nil
    }

    private struct SwipeContext: Equatable {
        let owner: String
        let screenRevision: String?
        let temporaryActivationID: String?
        let hiddenIDs: Set<String>
        let screenIDs: [String]
    }

    private var swipeContext: SwipeContext {
        SwipeContext(owner: model.permissionOwner, screenRevision: model.screen?.revision,
                     temporaryActivationID: model.temporaryActivationID,
                     hiddenIDs: model.hiddenScreenIDs, screenIDs: model.installedScreens.map(\.id))
    }

    private func handlePagePan(_ event: DeviceGestures.PagePan) {
        switch event {
        case let .began(width):
            guard canSwipe, swipeID == nil, width > 0 else { return }
            swipeStartContext = swipeContext
            swipeWidth = width
            swipeID = UUID()
        case let .changed(translation):
            guard canSwipe, swipeID != nil, !swipeSettling else { return }
            swipeOffset = min(swipeWidth, max(-swipeWidth, translation))
        case let .ended(translation, velocity):
            guard let id = swipeID, !swipeSettling else { return }
            guard canSwipe, let context = swipeStartContext, swipeContext == context else {
                cancelPagePan()
                return
            }
            guard let direction = DeviceSwipeTransition.direction(
                translation: translation, velocity: velocity, width: swipeWidth
            ) else {
                cancelPagePan()
                return
            }
            let duration = reduceMotion ? 0.12 : 0.22
            swipeSettling = true
            withAnimation(.easeOut(duration: duration)) {
                swipeOffset = CGFloat(-direction) * swipeWidth
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard swipeID == id else { return }
                guard canSwipe, swipeContext == context else { cancelPagePan(); return }

                // Cover the recentering transaction as the new live page takes
                // over. The carousel keeps exactly one dashboard mounted.
                swipeCoverOpacity = 1
                swipeOffset = 0
                swipeID = nil
                swipeStartContext = nil
                swipeSettling = false
                model.swipe(direction)
                try? await Task.sleep(nanoseconds: 32_000_000)
                withAnimation(.easeOut(duration: 0.18)) {
                    swipeCoverOpacity = 0
                }
            }
        case .cancelled:
            cancelPagePan()
        }
    }

    private func cancelPagePan() {
        guard swipeID != nil else { return }
        swipeID = nil
        swipeStartContext = nil
        swipeSettling = false
        withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.22)) { swipeOffset = 0 }
    }

    private struct RecordingBackdropScope: Equatable {
        let owner: String
        let accountID: String?
        let rendererID: String?
        let temporaryActivationID: String?
    }

    private var currentRecordingBackdropScope: RecordingBackdropScope {
        RecordingBackdropScope(owner: model.permissionOwner, accountID: model.cloud.localAccountID,
                               rendererID: model.screen.map { $0.revision + model.publicReadSessionKey + model.screenDataRendererKey },
                               temporaryActivationID: model.temporaryActivationID)
    }

    #if DEBUG
    private var rippleEligibilityPhase: String {
        guard #available(iOS 17, *) else { return "recording static: iOS compatibility" }
        guard scenePhase == .active else { return "recording static: scene inactive" }
        guard !reduceMotion else { return "recording static: Reduce Motion" }
        guard !model.settingsOpen, galleryIntro == nil, weatherDestination == nil else { return "recording static: overlay active" }
        guard !model.accountOperationInProgress else { return "recording static: account operation" }
        guard recordingBackdropScope == currentRecordingBackdropScope else { return "recording static: screen scope changed" }
        return "recording eligible"
    }
    #endif

    @ViewBuilder private var recordingRipple: some View {
        if #available(iOS 17, *), speech.recording, scenePhase == .active, !reduceMotion,
           !model.settingsOpen, galleryIntro == nil, !model.accountOperationInProgress,
           recordingBackdropScope == currentRecordingBackdropScope {
            RecordingRippleCapture(rendererID: currentRecordingBackdropScope.rendererID,
                                   dashboardSnapshot: dashboardSnapshot, placeholder: screenContent)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var screenLayer: some View {
        ZStack {
            screenContent
            if !model.missingConnections.isEmpty && !model.settingsOpen && !speech.recording {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "link.badge.plus").font(.largeTitle)
                    if model.canAllowCurrentPublicData {
                        Text("Allow public data?").font(.title2.bold())
                        Text("This screen reads from these public sources. No account or credentials are sent.")
                            .multilineTextAlignment(.center)
                        Text(model.currentPublicDataOrigins.joined(separator: "\n"))
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Allow public data", action: model.allowCurrentPublicData).buttonStyle(.borderedProminent)
                        Button("Review sources", action: model.openConnectionSettings)
                    } else {
                        Text("Finish setting up this screen").font(.title2.bold())
                        Text("Configure \(model.missingConnections.map(\.name).joined(separator: ", ")) in Settings to use this screen.")
                            .multilineTextAlignment(.center)
                        Button("Open Settings", action: model.openConnectionSettings).buttonStyle(.borderedProminent)
                    }
                    Text("Swipe with two fingers to switch screens.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(28).frame(maxWidth: 440)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                .padding(24)
                .accessibilityAddTraits(.isModal)
            }
        }
    }
    private var showsCloudOnboarding: Bool {
        model.screen == nil && !model.allInstalledScreensHidden &&
            (model.showsCloudPluginConnection || model.showsCloudListenerSetup)
    }

    @ViewBuilder private var screenContent: some View {
        if let screen = model.screen, let assets = model.assets {
            // The isolated WebView coordinator owns an immutable package and bridge scope.
            // A new local revision must create a new renderer, including on rollback/swipe.
            let rendererID = screen.revision + model.publicReadSessionKey + model.screenDataRendererKey
            DashboardRuntimeView(store: assets, homeAssistant: model.homeAssistant, publicReads: model.publicReads, screenData: model.screenDataProvider, revision: screen.revision, catalogContext: model.catalogPreviewContext, connectionCount: 1, screenName: screen.artifact.title,
                                 onMenu: { if swipeID == nil { model.openSettings() } })
                .environment(\.dashboardSnapshotRegistration, DashboardSnapshotRegistration(
                    source: dashboardSnapshot, rendererID: rendererID
                ))
                .id(rendererID)
                .ignoresSafeArea()
        } else if model.allInstalledScreensHidden {
            Color.clear
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("No screens shown")
                .accessibilityAction(named: Text("Open screen settings")) {
                    model.settingsPage = .screens
                    model.settingsOpen = true
                }
        } else if model.showsCloudPluginConnection {
            let scope = CloudClient.originScope
            OnboardingAgentPlugin { openOnboardingHelp(.plugin) }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !speech.recording && !model.settingsOpen && !model.accountOperationInProgress {
                        Group {
                            if speech.error != nil || model.presentedStatusMessage != nil {
                                RequestStatusPill(model: model, speechError: speech.error, maximumTextHeight: 160)
                            } else {
                                PluginConnectionStatusPill(connected: model.onboardingCloudPluginConnected)
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                    }
                }
                .id(AgentPluginIdentity(origin: scope.canonicalOrigin, account: model.cloud.localAccountID, owner: model.permissionOwner))
        } else if model.showsCloudListenerSetup {
            let scope = CloudClient.originScope
            CloudListenerSetupView(scope: scope, email: model.email, isPlaceholder: true)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !speech.recording && !model.settingsOpen && !model.accountOperationInProgress {
                        Group {
                            if speech.error != nil || model.presentedStatusMessage != nil {
                                RequestStatusPill(model: model, speechError: speech.error, maximumTextHeight: 160)
                            } else {
                                ListenerConnectionStatusPill(status: model.cloudListenerStatus)
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                    }
                }
                .id(AgentPluginIdentity(origin: scope.canonicalOrigin, account: model.cloud.localAccountID, owner: model.permissionOwner))
        } else if model.needsAgentSetup {
            OnboardingAgentConnection(isSigningIn: model.accountOperationInProgress) {
                Task { await model.signIn(fromCloudOnboarding: true) }
            } openSettings: {
                model.settingsPage = .account
                model.settingsOpen = true
            }
        } else {
            CreationPlaceholder(
                canHide: model.canHideInstructions && !model.hiddenScreenIDs.contains(ScreenLibrary.instructionsID),
                hideDisabled: model.permissionOwner.isEmpty || model.accountOperationInProgress,
                openSettings: { model.openSettings() },
                hide: {
                    model.setScreenShown(false, id: ScreenLibrary.instructionsID, owner: model.permissionOwner)
                }
            )
        }
    }
    private func beginSpeech() {
        guard !model.settingsOpen, galleryIntro == nil, weatherDestination == nil, !onboardingHelpInFlight else { return }
        guard model.hasProfile, !model.needsAgentSetup, !model.busy else { model.message = model.busy ? "Your agent is still working." : "Connect your agent before speaking."; return }
        recordingBackdropScope = currentRecordingBackdropScope
        #if DEBUG
        if !speech.recording { RecordingRippleDiagnostics.reset("recording gesture began") }
        #endif
        speech.begin { text in Task { await model.send(text) } }
    }
}

private enum OnboardingTypography {
    static let brand = Font.caption.bold()
    static let title = Font.largeTitle.bold()
    static let compactTitle = Font.title2.bold()
    static let condensedTitle = Font.headline
    static let caption = Font.body
    static let supporting = Font.footnote

    static var wordmark: some View {
        Text("SCREENPUNK").font(brand).tracking(4).foregroundStyle(.orange)
    }
}

private struct CenteredOnboardingPage<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: 680)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OnboardingAgentConnection: View {
    let isSigningIn: Bool
    let signIn: () -> Void
    let openSettings: () -> Void
    @State private var showsDetails = false

    private let title = "Connect an agent"
    private let caption = "Screenpunk works with your AI agent to create screens."
    private let detail = "Sign in to connect a cloud agent, or configure a local agent in settings."

    var body: some View {
        CenteredOnboardingPage {
            ViewThatFits(in: .vertical) {
                VStack(spacing: 16) {
                    OnboardingTypography.wordmark
                    Text(title).font(OnboardingTypography.title).accessibilityAddTraits(.isHeader)
                    descriptions
                    VStack(spacing: 24) {
                        signInButton
                        settingsButton
                    }
                    .padding(.top, 16)
                }
                VStack(spacing: 6) {
                    Text(title).font(OnboardingTypography.compactTitle).accessibilityAddTraits(.isHeader)
                    descriptions
                    VStack(spacing: 16) {
                        signInButton
                        settingsButton
                    }
                    .padding(.top, 8)
                }
                VStack(spacing: 4) {
                    Text(title).font(OnboardingTypography.condensedTitle).accessibilityAddTraits(.isHeader)
                    signInButton
                        .padding(.bottom, 8)
                    HStack {
                        settingsButton
                        Button("How to") { showsDetails = true }.buttonStyle(.bordered)
                    }
                }
            }
            .multilineTextAlignment(.center)
        }
        .alert(title, isPresented: $showsDetails) {
            Button("Done", role: .cancel) {}
        } message: {
            Text(caption + "\n\n" + detail)
        }
    }

    private var descriptions: some View {
        VStack(spacing: 4) {
            Text(caption)
            Text(detail)
        }
        .font(OnboardingTypography.caption)
        .foregroundStyle(.secondary)
    }

    private var signInButton: some View {
        Button("Continue with Screenpunk Cloud", action: signIn)
            .buttonStyle(.borderedProminent)
            .disabled(isSigningIn)
    }

    private var settingsButton: some View {
        Button("Open Settings", action: openSettings)
            .buttonStyle(.bordered)
    }
}

private struct AgentPluginIdentity: Hashable {
    let origin: String
    let account: String?
    let owner: String
}

private struct OnboardingAgentPlugin: View {
    let openInstructions: () -> Void

    private let title = "Install the agent plugin"
    private let caption = "Connect Screenpunk to your agent to link this device."

    var body: some View {
        CenteredOnboardingPage {
            ViewThatFits(in: .vertical) {
                VStack(spacing: 16) {
                    OnboardingTypography.wordmark
                    heading(OnboardingTypography.title)
                    Text(caption).font(OnboardingTypography.caption).foregroundStyle(.secondary)
                    VStack(spacing: 24) {
                        chatGPTButton
                        grokbotButton
                    }
                    .padding(.top, 16)
                }
                VStack(spacing: 8) {
                    heading(OnboardingTypography.compactTitle)
                    Text(caption).font(OnboardingTypography.caption).foregroundStyle(.secondary)
                    VStack(spacing: 16) {
                        chatGPTButton
                        grokbotButton
                    }
                    .padding(.top, 8)
                }
                VStack(spacing: 6) {
                    heading(OnboardingTypography.condensedTitle)
                    VStack(spacing: 8) {
                        chatGPTButton
                        grokbotButton
                    }
                }
            }
            .multilineTextAlignment(.center)
        }

    }

    private func heading(_ font: Font) -> some View {
        Text(title).font(font).accessibilityAddTraits(.isHeader)
    }

    private var chatGPTButton: some View {
        Button("ChatGPT instructions", action: openInstructions)
            .buttonStyle(.borderedProminent)
    }

    private var grokbotButton: some View {
        Button("Grokbot — Coming soon") {}
            .buttonStyle(.bordered)
            .disabled(true)
    }
}

private struct CreationPlaceholder: View {
    let canHide: Bool
    let hideDisabled: Bool
    let openSettings: () -> Void
    let hide: () -> Void
    @State private var showsGestures = false

    var body: some View {
        CenteredOnboardingPage {
            ViewThatFits(in: .vertical) {
                VStack(spacing: 40) {
                    heading(compact: false)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) { panels(compact: false) }
                        VStack(spacing: 10) { panels(compact: false) }
                    }
                }
                VStack(spacing: 18) {
                    heading(compact: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 8) { panels(compact: true) }
                        VStack(spacing: 6) { panels(compact: true) }
                    }
                }
                VStack(spacing: 8) {
                    Text("Create a screen")
                        .font(OnboardingTypography.condensedTitle)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 8) {
                        Button("Settings", action: openSettings).buttonStyle(.bordered)
                        Button("Gestures") { showsGestures = true }.buttonStyle(.bordered)
                        if canHide {
                            Button("Hide", action: hide).buttonStyle(.bordered)
                                .accessibilityLabel("Hide this screen")
                                .disabled(hideDisabled)
                        }
                    }
                }
            }
            .multilineTextAlignment(.center)
        }
        .alert("Screen gestures", isPresented: $showsGestures) {
            Button("Done", role: .cancel) {}
        } message: {
            Text("Hold three fingers, say what you’d like, then lift to send. Hold two fingers for 3 seconds to open Settings. Swipe left or right with two fingers to switch screens.")
        }
    }

    private func heading(compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 12) {
            OnboardingTypography.wordmark
            Text("Create a new screen here")
                .font(compact ? OnboardingTypography.compactTitle : OnboardingTypography.title)
                .accessibilityAddTraits(.isHeader)
            Text("Hold three fingers, say what you’d like, then lift to send.")
                .font(OnboardingTypography.caption)
            Image(systemName: "hand.raised.fingers.spread.fill")
                .font(.system(size: compact ? 24 : 40))
                .padding(.top, compact ? 2 : 6)
                .accessibilityHidden(true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func panels(compact: Bool) -> some View {
        panel("Settings", instruction: "Hold two fingers for 3 seconds.", compact: compact) {
            Button("Open Settings", action: openSettings).buttonStyle(.bordered)
        }
        panel("Switch screens", instruction: "Swipe left or right with two fingers.", compact: compact) {
            if canHide {
                Button("Hide this screen", action: hide)
                    .buttonStyle(.bordered)
                    .disabled(hideDisabled)
            }
        }
    }

    private func panel<Action: View>(_ title: String, instruction: String, compact: Bool,
                                     @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: compact ? 4 : 8) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(instruction).font(OnboardingTypography.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            action().font(OnboardingTypography.supporting)
                .padding(.top, compact ? 6 : 12)
                .padding(.bottom, compact ? 4 : 8)
        }
        .padding(.horizontal, compact ? 12 : 20)
        .padding(.vertical, compact ? 12 : 20)
        .frame(minWidth: 162, maxWidth: .infinity)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
}

enum CloudSetupStage: Hashable {
    case plugin, listener, completeGuide

    var sheetTitle: String {
        switch self {
        case .plugin: return "Connect in ChatGPT"
        case .listener: return "Activate the listener"
        case .completeGuide: return "Cloud setup"
        }
    }
}

/// The native onboarding placeholder and the detailed guide use the same plugin
/// destination and listener request.
struct CloudListenerSetupView: View {
    let scope: CloudOriginScope
    let email: String?
    var isPlaceholder = false
    var stage: CloudSetupStage = .completeGuide
    @State private var copied = false

    private let listenerTitle = "Activate the listener"
    private let listenerCaption = "Open a new task in ChatGPT or your Dot, and send this prompt to activate its Screenpunk listener."

    private var pluginName: String { scope.permitsLegacyMigration ? "Screenpunk Staging" : "Screenpunk Production" }

    private var pluginURL: URL? {
        switch scope.canonicalOrigin {
        case "https://staging.screenpunk.xyz": return URL(string: "https://chatgpt.com/plugins/plugin_asdk_app_6ad8cebcf03481918fa9078644568bee")
        case "https://api.screenpunk.xyz": return URL(string: "https://chatgpt.com/plugins/plugin_asdk_app_6ae3926704588191b0eee33944373ddc")
        default: return nil
        }
    }

    private var setupRequest: String {
        let account = email.map { "Confirm you’re connected as \($0). Stop if the account differs." }
            ?? "Confirm your Screenpunk account matches my iPad."
        return "Use @\(pluginName). \(account) Subscribe to screenpunk.request.created, keep listening, and handle my device requests. Confirm when the subscription is active. If subscriptions aren’t available, tell me to use Work + Cloud or a dot."
    }

    var body: some View {
        Group {
            if isPlaceholder {
                placeholder
            } else {
                guide
            }
        }
        .background(isPlaceholder ? Color.black : Color.clear)
        .foregroundStyle(.white)
        .onChange(of: email) { _ in copied = false }
    }

    private var placeholder: some View {
        CenteredOnboardingPage {
            ViewThatFits(in: .vertical) {
                VStack(spacing: 16) {
                    OnboardingTypography.wordmark
                    heading(OnboardingTypography.title)
                    listenerDescription
                    promptPanel(scrolls: false)
                        .padding(.top, 16)
                }
                VStack(spacing: 8) {
                    heading(OnboardingTypography.compactTitle)
                    listenerDescription
                    promptPanel(scrolls: true)
                        .padding(.top, 16)
                }
            }
            .multilineTextAlignment(.center)
        }
    }

    private var listenerDescription: some View {
        Text(listenerCaption)
            .font(OnboardingTypography.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var promptText: some View {
        Text(setupRequest)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private func promptPanel(scrolls: Bool) -> some View {
        VStack(spacing: 16) {
            if scrolls {
                ScrollView(.vertical) { promptText }
                    .frame(minHeight: 44)
            } else {
                promptText
            }
            copyButton
        }
        .padding(32)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
    }

    private var guide: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                OnboardingTypography.wordmark
                Text(stage.sheetTitle).font(OnboardingTypography.title).accessibilityAddTraits(.isHeader)
                if stage != .listener {
                    step(1, "Open the plugin in ChatGPT", "Open the Screenpunk plugin using your invited ChatGPT account.")
                    pluginButton
                    step(2, "Connect your Screenpunk account", email.map { "Choose Connect, then sign in as \($0) using the same sign-in option you used on this device." } ?? "Choose Connect, then use the same account and sign-in option as this device.")
                }
                if stage == .plugin {
                    step(3, "Return to Screenpunk", "The app will advance to listener setup once it sees the connection.")
                } else {
                    step(stage == .listener ? 1 : 3, "Open a persistent ChatGPT session", "Open Work → Cloud or your dot and select @\(pluginName).")
                    step(stage == .listener ? 2 : 4, "Send the listener request", "Copy the request below, paste it into the session, and send it.")
                    copyButton
                    step(stage == .listener ? 3 : 5, "Return to Screenpunk", "Keep the session listening. When the listener is active, this device can accept your screen requests.")
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func heading(_ font: Font) -> some View {
        Text(listenerTitle).font(font).accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var pluginButton: some View {
        if let pluginURL {
            Link("Open \(pluginName) in ChatGPT", destination: pluginURL)
                .buttonStyle(.borderedProminent)
        } else {
            Text("Use the plugin link from your Screenpunk provider.").font(.callout)
        }
    }

    private var copyButton: some View {
        Button(copied ? "Copied" : "Copy listener request") {
            UIPasteboard.general.string = setupRequest
            copied = true
        }
        .buttonStyle(.borderedProminent)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(String(number)).font(.headline).foregroundStyle(.orange)
                .padding(8).background(.orange.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Text(detail).font(OnboardingTypography.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One presentation surface shared by the current and future agent guides.
/// Standard iOS 26 sheets supply Liquid Glass; do not stack another glass card inside.
private struct AgentInstructionsSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            if reduceTransparency || contrast == .increased {
                content.presentationBackground(Color(uiColor: .secondarySystemBackground))
            } else if #available(iOS 26, *) {
                content
            } else {
                content.presentationBackground(.regularMaterial)
            }
        } else {
            // iOS 16.0–16.3 has no public presentation-background override.
            // Keep the system sheet backing and a legible material fallback.
            if reduceTransparency || contrast == .increased {
                content.background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea())
            } else {
                content.background(.regularMaterial)
            }
        }
    }
}

struct CloudListenerSetupSheet: View {
    let scope: CloudOriginScope
    let email: String?
    var stage: CloudSetupStage = .completeGuide
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CloudListenerSetupView(scope: scope, email: email, stage: stage)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .modifier(AgentInstructionsSurface())
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
struct CloudListenerSetupView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            CloudListenerSetupView(scope: CloudOriginScope(origin: "https://api.screenpunk.xyz")!, email: "preview@example.com", isPlaceholder: true)
                .previewLayout(.fixed(width: 1024, height: 768))
                .previewDisplayName("Production · signed in")
            CloudListenerSetupView(scope: CloudOriginScope(origin: "https://staging.screenpunk.xyz")!, email: nil, isPlaceholder: true)
                .previewLayout(.fixed(width: 834, height: 1112))
                .previewDisplayName("Staging · before sign-in")
            CloudListenerSetupView(scope: CloudOriginScope(origin: "https://api.screenpunk.xyz")!, email: nil, isPlaceholder: true)
                .previewLayout(.fixed(width: 393, height: 852))
                .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
                .previewDisplayName("iPhone · large text")
        }
    }
}
#endif

enum DeviceSettingsPage: String, Hashable {
    case overview = "Overview", guidedAccess = "Guided Access", display = "General", account = "Account", screens = "Screens"
    case home = "Home Assistant", television = "Google TV", calendar = "Google Calendar", publicData = "Public Data"
    case screenData = "Screen Data Access"
    var symbol: String {
        switch self {
        case .overview: return "hand.draw"
        case .guidedAccess: return "lock.rectangle"
        case .display: return "gearshape"
        case .account: return "person.crop.circle"
        case .screens: return "rectangle.stack"
        case .home: return "house"
        case .television: return "tv"
        case .calendar: return "calendar"
        case .publicData: return "network"
        case .screenData: return "lock.shield"
        }
    }
}
private struct ScreenDataConsentAlert: ViewModifier {
    @ObservedObject var model: DeviceModel
    let isHost: Bool

    func body(content: Content) -> some View {
        content.alert("Allow screen data access?", isPresented: Binding(
            get: { isHost && model.screenDataPrompt.map { $0.expiresAt > Date() } == true },
            set: { _ in }
        ), presenting: model.screenDataPrompt) { prompt in
            Button("Allow") { model.respondToScreenDataPrompt(prompt, allow: true) }
            Button("Don’t Allow", role: .cancel) { model.respondToScreenDataPrompt(prompt, allow: false) }
        } message: { prompt in
            let permission = prompt.permission
            Text("\(permission.readerLabel) wants to read “\(permission.key.target.exportName)” from \(permission.targetTitle). \(permission.exportDescription) If you allow access, the reader can try again.")
        }
    }
}

private struct ScreenDataAccessSettings: View {
    @ObservedObject var model: DeviceModel

    var body: some View {
        Form {
            Section {
                if model.screenDataPermissions.isEmpty {
                    Text("No screen data access decisions yet.").foregroundStyle(.secondary)
                }
                ForEach(model.screenDataPermissions) { permission in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(permission.readerLabel).font(.headline)
                        Text("\(permission.targetTitle) · \(permission.key.target.exportName)")
                        Text(permission.exportDescription).font(.subheadline).foregroundStyle(.secondary)
                        if permission.decision == .allowed {
                            Button("Revoke Access", role: .destructive) { model.revokeScreenDataPermission(permission) }
                                .accessibilityLabel("Revoke \(permission.readerLabel)’s access to \(permission.key.target.exportName)")
                        } else {
                            Text(permission.decision == .revoked ? "Revoked" : "Denied")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("Forget Decision") { model.forgetScreenDataDecision(permission) }
                                .accessibilityHint("A future request can ask for permission again.")
                        }
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("Only data a screen explicitly publishes can be shared. Access applies to the reader and screen version you approved. Forgetting a denied or revoked decision lets the reader ask again.")
            }
        }
    }
}

struct DeviceSettingsView: View {
    @ObservedObject var model: DeviceModel
    @ObservedObject var display: DeviceDisplayPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var selection: DeviceSettingsPage? = .account
    @State private var showBilling = false
    @State private var screenToRemove: ScreenLibrary.Saved?
    @State private var sheet: SettingsSheet?
    private enum SettingsSheet: String, Identifiable {
        case cloudListener
        var id: String { rawValue }
    }
    @State private var columns: NavigationSplitViewVisibility = .all
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var providers: [DeviceSettingsPage] {
        var values: [DeviceSettingsPage] = []
        if !model.manifests(requiring: ["home"]).isEmpty { values.append(.home) }
        if !model.manifests(requiring: ["googleTV"]).isEmpty { values.append(.television) }
        if !model.manifests(requiring: ["googleCalendar", "google-calendar"]).isEmpty { values.append(.calendar) }
        if model.installedManifests.contains(where: { $0.connections.contains(where: { $0.publicHTTP != nil }) }) { values.append(.publicData) }
        return values
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selection) {
                Section {
                    row(.account)
                }
                Section("Device") { row(.display); row(.screens); row(.screenData) }
                if !providers.isEmpty {
                    Section("Connections") { ForEach(providers, id: \.self) { row($0) } }
                }
                Section("Help") { row(.overview); row(.guidedAccess) }
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .toolbar { if sizeClass == .compact { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            NavigationStack {
                detail
                    .navigationTitle((selection ?? .overview).rawValue)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                    .navigationDestination(isPresented: $showBilling) {
                        DeviceBillingSettings(device: model, billing: model.billing)
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .modifier(ScreenDataConsentAlert(model: model, isHost: model.settingsOpen && sheet == nil && screenToRemove == nil))
        .modifier(BackupUpgradeAlert(model: model, billing: model.billing,
                                     isHost: model.settingsOpen && sheet == nil && screenToRemove == nil))
        // Present from Settings itself, not a Form Section/row whose hosting
        // controller can resolve the presentation against the outer cover.
        .sheet(item: $sheet) { destination in
            switch destination {
            case .cloudListener: CloudListenerSetupSheet(scope: CloudClient.originScope, email: model.email)
            }
        }
        .onAppear {
            selection = model.settingsPage
            model.checkListenerStatusOnSettingsEntry()
        }
        .onChange(of: selection) {
            if let page = $0 { model.settingsPage = page }
            if $0 != .account { showBilling = false }
        }
        .alert("Remove screen?", isPresented: Binding(get: { screenToRemove != nil }, set: { if !$0 { screenToRemove = nil } })) {
            Button("Cancel", role: .cancel) { screenToRemove = nil }
            Button("Remove", role: .destructive) {
                if let screen = screenToRemove { model.removeScreen(screen.id) }
                screenToRemove = nil
            }
        } message: {
            Text("Remove \(screenToRemove?.artifact.title ?? "this screen") from this iPad? This also removes its saved previous version.")
        }
        .onChange(of: providers) { available in
            if let selection, [.home, .television, .calendar, .publicData].contains(selection), !available.contains(selection) { self.selection = .overview }
        }
    }
    private func row(_ page: DeviceSettingsPage) -> some View {
        NavigationLink(value: page) { Label(page.rawValue, systemImage: page.symbol) }
    }
    @ViewBuilder private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            Form {
                Section("Talk to your agent") {
                    Label("Hold three fingers while speaking", systemImage: "mic")
                    Text("Keep all three fingers on the screen as you describe what you want to create or change. Lift them to send your instructions.")
                }
                Section("Change screens") {
                    Label("Swipe left or right with two fingers", systemImage: "hand.draw")
                    Text("Move between the screens saved on this device.")
                }
                Section("Open Settings") {
                    Label("Hold two fingers for three seconds", systemImage: "gearshape")
                    Text("Settings opens directly. Your current screen stays saved while you adjust this device.")
                }
            }
        case .guidedAccess:
            Form {
                Section("Keep Screenpunk on screen") {
                    Text("Guided Access can restrict this device to Screenpunk. You configure and end it using Apple’s system controls.")
                }
                Section("Set up") {
                    Text("1. Open the device’s Settings → Accessibility → Guided Access. Turn it on and choose a Guided Access passcode.")
                    Text("2. Return to Screenpunk. Triple-click the Home button if your device has one. Otherwise, triple-click the top button on iPad or the side button on iPhone.")
                    Text("3. Choose Guided Access if a shortcut menu appears. Keep Touch enabled so Screenpunk’s gestures work, then tap Start.")
                }
                Section("End a session") {
                    Text("Triple-click the same button, enter your Guided Access passcode, and tap End. Available biometric shortcuts depend on the device and your Guided Access settings.")
                    Link("Apple’s Guided Access instructions", destination: URL(string: "https://support.apple.com/111795")!)
                }
            }
        case .display:
            DeviceDisplaySettings(preferences: display, device: model)
        case .account:
            if let localSettings = model.localSettings {
                DeviceAccountSettings(device: model, model: localSettings, showCloudSetup: { sheet = .cloudListener })
            } else {
                Form {
                    DeviceCloudAccountSection(device: model, showListenerSetup: { sheet = .cloudListener })
                    DeviceBillingSection(device: model)
                    Section("Local agent") { Text("Local agent storage could not be opened.") }
                }
            }
        case .screenData:
            ScreenDataAccessSettings(model: model)
        case .screens:
            Form {
                Section {
                    Button("Create another screen", action: model.newScreen).disabled(model.needsAgentSetup)
                    Button("Restore previous version", action: model.rollback).disabled(model.needsAgentSetup || !model.canRollback)
                }
                DeviceCloudBackupsSection(model: model) {
                    selection = .account
                    showBilling = true
                }
                Section("On this device") {
                    let instructionOwner = model.permissionOwner
                    HStack {
                        Button(model.needsAgentSetup ? "Connect an agent" : "Add a screen") { model.selectScreen(ScreenLibrary.instructionsID) }
                            .buttonStyle(.borderless)
                            .disabled(model.needsAgentSetup || model.hiddenScreenIDs.contains(ScreenLibrary.instructionsID) || model.accountOperationInProgress)
                        Spacer()
                        Color.clear.frame(width: 44, height: 44)
                            .padding(.trailing, 12)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                        Toggle("Show", isOn: Binding(
                            get: { !model.hiddenScreenIDs.contains(ScreenLibrary.instructionsID) },
                            set: { model.setScreenShown($0, id: ScreenLibrary.instructionsID, owner: instructionOwner) }
                        ))
                        .fixedSize().accessibilityLabel("Show Add a screen")
                        .disabled(instructionOwner.isEmpty || model.accountOperationInProgress || model.needsAgentSetup ||
                                  (!model.hiddenScreenIDs.contains(ScreenLibrary.instructionsID) && !model.canHideInstructions))
                    }
                    ForEach(model.needsAgentSetup ? [] : model.installedScreens) { saved in
                        let owner = model.permissionOwner
                        let shown = !model.hiddenScreenIDs.contains(saved.id)
                        HStack {
                            Button { model.selectScreen(saved.id) } label: {
                                HStack { Text(saved.artifact.title); if saved.id == model.screen?.id { Image(systemName: "checkmark") } }
                            }.buttonStyle(.borderless)
                                .disabled(!shown || model.accountOperationInProgress)
                            Spacer()
                            Button(role: .destructive) { screenToRemove = saved } label: {
                                Image(systemName: "trash")
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .padding(.trailing, 12)
                            .accessibilityLabel("Remove \(saved.artifact.title)")
                            .disabled(model.busy)
                            Toggle("Show", isOn: Binding(
                                get: { !model.hiddenScreenIDs.contains(saved.id) },
                                set: { model.setScreenShown($0, id: saved.id, owner: owner) }
                            ))
                            .fixedSize()
                            .accessibilityLabel("Show \(saved.artifact.title)")
                            .disabled(owner.isEmpty || model.accountOperationInProgress)
                        }
                        if let issue = model.manifestIssues[saved.id] {
                            Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
        case .publicData:
            Form {
                Section {
                    ForEach(model.installedScreens) { saved in
                        if let manifest = model.installedManifests.first(where: { $0.revision == saved.revision }),
                           manifest.connections.contains(where: { $0.publicHTTP != nil }) {
                            let owner = model.permissionOwner
                            NavigationLink {
                                DevicePublicDataDetails(model: model, screenID: saved.id, owner: owner)
                            } label: {
                                Label(StarterWeather.isSupported(saved.artifact) ? "Weather" : manifest.name, systemImage: "network")
                            }
                        }
                    }
                }
            }
        case .home:
            DeviceHomeAssistantSettings(owner: model.permissionOwner, manifests: model.manifests(requiring: ["home"]), onChange: model.refreshConnections)
        case .television:
            DeviceGoogleTVSettings(onChange: model.refreshConnections)
        case .calendar:
            DeviceGoogleCalendarSettings(manifests: model.installedManifests, onChange: model.refreshConnections)
        }
    }

}

private struct BackupUpgradeAlert: ViewModifier {
    @ObservedObject var model: DeviceModel
    @ObservedObject var billing: DeviceBillingStore
    @Environment(\.scenePhase) private var scenePhase
    let isHost: Bool

    func body(content: Content) -> some View {
        let prompt = isHost && scenePhase == .active ? billing.backupUpgradePrompt(for: model.cloud) : nil
        content.alert("Enable backups for this device?", isPresented: Binding(
            get: { prompt != nil },
            // Only an explicit answer consumes the prompt. The Settings cover can change hosts.
            set: { _ in }
        ), presenting: prompt) { id in
            Button("Enable Backups") {
                Task { await billing.answerBackupUpgrade(id, enable: true, cloud: model.cloud) }
            }
            Button("Not Now", role: .cancel) {
                Task { await billing.answerBackupUpgrade(id, enable: false, cloud: model.cloud) }
            }
        } message: { _ in
            Text("Screenpunk Pro includes Cloud backups. Enable them to save this device’s screens and future edits.")
        }
    }
}

private struct DeviceCloudBackupsSection: View {
    @ObservedObject var model: DeviceModel
    let openBilling: () -> Void
    @State private var confirmResume = false
    @State private var showUpgrade = false

    var body: some View {
        Section {
            Toggle("Back up this device", isOn: Binding(
                get: { model.catalogBackupsEnabled },
                set: { enabled in
                    if enabled, model.catalogBackupAccess == .inactive { showUpgrade = true }
                    else { model.setCatalogBackupsEnabled(enabled) }
                }
            ))
            .disabled(!model.catalogBackupsCanConfigure)

            if model.catalogBackupsEnabled {
                if let status = model.catalogBackupStatus {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                if let status = model.catalogPreviewStatus {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                if model.catalogCanResume {
                    Button("Resume backups with current screens") { confirmResume = true }
                }
            }
        } header: {
            Text("Cloud Backups")
        } footer: {
            if model.catalogBackupsCanConfigure, model.catalogBackupAccess == .unknown {
                Text("Backups are paused until Screenpunk can verify your plan.")
            } else if model.catalogBackupsCanConfigure {
                Text("Save current screens, screenshots, and future edits to your Screenpunk account. Turning this off keeps existing backups.")
            } else if model.email != nil {
                Text("Backups require a connected Cloud library.")
            } else {
                Text("Sign in to Screenpunk Cloud in Account to set up backups.")
            }
        }
        .alert("Resume current-screen backups?", isPresented: $confirmResume) {
            Button("Cancel", role: .cancel) {}
            Button("Resume backups") { model.resumeCatalogBackups() }
        } message: {
            Text("Resume starts from your current screens. Edits made while paused aren’t added as history.")
        }
        .alert("Upgrade to Screenpunk Pro", isPresented: $showUpgrade) {
            Button("Upgrade now", action: openBilling)
            Button("Cancel", role: .cancel) {}
        } message: {
            let price = model.billing.offer(.proAnnual, for: model.cloud)?.product.displayPrice ?? "US$19.95"
            Text("Back up this device with Screenpunk Pro for \(price)/year. You can upgrade anytime in Account → Billing.")
        }
    }
}

private struct StatusPillAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 22).padding(.vertical, 14)
            .frame(maxWidth: 540)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct ListenerConnectionStatusPill: View {
    let status: CloudListenerObservation.Status
    private var caption: String {
        switch status {
        case .waiting: return "Waiting for listener to be activated…"
        case .unchecked: return "Checking listener connection…"
        case .unavailable: return "Listener status unavailable"
        case .notSignedIn: return "Sign in to check the listener"
        case .connected: return "Listener connected"
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            if status == .waiting || status == .unchecked {
                ProgressView().tint(.secondary).accessibilityHidden(true)
            }
            Text(caption).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .modifier(StatusPillAppearance())
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
    }
}

private struct PluginConnectionStatusPill: View {
    let connected: Bool?
    private var caption: String {
        connected == false ? "Waiting for plugin connection…" : "Checking plugin connection…"
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().tint(.secondary).accessibilityHidden(true)
            Text(caption).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .modifier(StatusPillAppearance())
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
    }
}

private struct RequestStatusPill: View {
    @ObservedObject var model: DeviceModel
    let speechError: String?
    let maximumTextHeight: CGFloat
    var body: some View {
        let message = model.presentedStatusMessage
        let dismissible = speechError == nil && model.canDismissStatusMessage
        VStack(spacing: 12) {
            if !model.accountOperationInProgress && (model.requestPending || model.busy) {
                if let agent = model.resolvedAgentName { Text(agent).font(.caption).foregroundStyle(.secondary) }
                ShimmeringStatusCaption(caption: model.takingLonger ? "Taking longer than expected" : model.progressCaption)
                HStack(spacing: 20) {
                    if model.takingLonger { Button("Keep waiting", action: model.keepWaiting) }
                    if model.canCancelRequest { Button("Cancel", role: .cancel, action: model.cancelRequest) }
                }.buttonStyle(.bordered)
            } else {
                statusText(speechError ?? message?.text ?? "")
                if model.canRetry { Button("Retry", action: model.retryRequest).buttonStyle(.bordered).disabled(model.busy) }
                if model.canCancelRequest { Button("Cancel saved request", role: .cancel, action: model.cancelRequest).buttonStyle(.bordered) }
                if dismissible, let id = message?.id {
                    Button { model.dismissStatusMessage(id: id) } label: {
                        Label("Dismiss", systemImage: "xmark").frame(minWidth: 80, minHeight: 44)
                    }
                        .id(id)
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Dismiss message")
                        .accessibilityHint("Hides this message. Your screen stays unchanged.")
                }
            }
        }
        .modifier(StatusPillAppearance())
        // Consume card taps without dismissing. Touches never pass through to
        // the screen below; only a deliberate swipe or Dismiss action hides it.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { })
        .background(DeviceStatusInteractionRegion(presentationID: message?.id, dismissalEnabled: dismissible, onDismiss: model.dismissStatusMessage))
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) {
            if dismissible, let id = message?.id { model.dismissStatusMessage(id: id) }
        }
    }
    private func statusText(_ value: String) -> some View {
        ViewThatFits(in: .vertical) {
            Text(value).fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) {
                Text(value).frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout).multilineTextAlignment(.center)
        .frame(maxHeight: maximumTextHeight)
    }
}
@available(iOS 17, *)
private struct RecordingRippleCapture<Placeholder: View>: View {
    let rendererID: String?
    let dashboardSnapshot: DashboardSnapshotSource
    let placeholder: Placeholder
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    RecordingRippleSurface(image: image)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .task { await capture(size: geometry.size) }
        }
        .ignoresSafeArea()
    }

    @MainActor private func capture(size: CGSize) async {
        guard !Task.isCancelled else { return }
        guard size.width > 0, size.height > 0 else {
            RecordingRippleDiagnostics.event("capture skipped: empty viewport")
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let image: UIImage?
        if let rendererID {
            RecordingRippleDiagnostics.event("capture started: dashboard")
            image = await dashboardSnapshot.snapshot(rendererID: rendererID)
        } else {
            RecordingRippleDiagnostics.event("capture started: native placeholder")
            let renderer = ImageRenderer(content: placeholder
                .frame(width: size.width, height: size.height)
                .foregroundStyle(.white)
                .environment(\.colorScheme, colorScheme))
            renderer.scale = min(1, 1400 / max(size.width, size.height))
            image = renderer.uiImage
        }
        guard !Task.isCancelled else { return }
        guard let image else {
            RecordingRippleDiagnostics.event("capture unavailable: no image", since: started)
            return
        }
        RecordingRippleDiagnostics.event("capture succeeded", since: started)
        self.image = image
    }
}

private enum RecordingRippleDiagnostics {
    #if DEBUG
    private struct Entry: Encodable {
        let phase: String
        let milliseconds: Int
        let bounds: [Int]?
        let drawable: [Int]?
    }

    private static let logger = Logger(subsystem: "xyz.screenpunk.ios", category: "RecordingRipple")
    private static let lock = NSLock()
    private static var entries: [Entry] = []
    private static var session: UUID?
    private static var start = 0.0

    static var token: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    static func reset(_ phase: String) {
        lock.lock()
        defer { lock.unlock() }
        session = UUID()
        start = ProcessInfo.processInfo.systemUptime
        entries = [Entry(phase: phase, milliseconds: 0, bounds: nil, drawable: nil)]
        saveReceipt()
    }

    private static func saveReceipt() {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: directory.appendingPathComponent("RecordingRippleDiagnostics.json"), options: .atomic)
    }
    #endif

    static func event(_ phase: String, since start: TimeInterval? = nil, token: UUID? = nil,
                      bounds: CGSize? = nil, drawable: CGSize? = nil) {
        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard session != nil, token == nil || token == session, entries.count < 24 else { return }
        let milliseconds = max(0, Int((now - Self.start) * 1_000))
        entries.append(Entry(phase: phase, milliseconds: milliseconds,
                             bounds: bounds.map { [Int($0.width), Int($0.height)] },
                             drawable: drawable.map { [Int($0.width), Int($0.height)] }))
        saveReceipt()
        let elapsed = start.map { Int((now - $0) * 1_000) } ?? milliseconds
        logger.debug("\(phase, privacy: .public) after \(elapsed, privacy: .public) ms")
        #endif
    }
}

#if DEBUG
@available(iOS 17, *)
private struct RecordingRippleSelfTest: View {
    let useWebKit: Bool
    @State private var source = DashboardSnapshotSource()
    @State private var started = false

    var body: some View {
        ZStack {
            if useWebKit {
                if let fixture = try? DashboardRuntimeView.offlineFixture() {
                    fixture.environment(\.dashboardSnapshotRegistration, DashboardSnapshotRegistration(
                        source: source, rendererID: "synthetic"
                    ))
                } else {
                    Text("Offline fixture unavailable")
                }
            } else {
                fixtureGrid
            }
            if started {
                RecordingRippleCapture(rendererID: useWebKit ? "synthetic" : nil,
                                       dashboardSnapshot: source, placeholder: fixtureGrid)
            }
        }
        .ignoresSafeArea()
        .task {
            RecordingRippleDiagnostics.reset(useWebKit ? "self-test: offline WebKit fixture" : "self-test: native grid")
            do { try await Task.sleep(for: .seconds(useWebKit ? 2 : 0.4)) } catch { return }
            started = true
        }
    }

    private var fixtureGrid: some View {
        ZStack {
            Color.black
            Canvas { context, size in
                var lines = Path()
                for x in stride(from: 0.0, through: size.width, by: 32) {
                    lines.move(to: CGPoint(x: x, y: 0))
                    lines.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: 0.0, through: size.height, by: 32) {
                    lines.move(to: CGPoint(x: 0, y: y))
                    lines.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(lines, with: .color(.orange.opacity(0.8)), lineWidth: 2)
            }
            Text("Screenpunk ripple test").font(.largeTitle.bold()).foregroundStyle(.white)
        }
    }
}
#endif

/// The view and its texture are scoped to a single foreground recording.
private struct RecordingRippleSurface: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Renderer { Renderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = RippleMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.isPaused = true
        view.autoResizeDrawable = false
        view.preferredFramesPerSecond = 24
        view.delegate = context.coordinator
        context.coordinator.prepare(view: view, image: image)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}

    static func dismantleUIView(_ view: MTKView, coordinator: Renderer) {
        view.isPaused = true
        view.delegate = nil
        coordinator.stop()
    }

    private final class RippleMetalView: MTKView {
        override func layoutSubviews() {
            super.layoutSubviews()
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let scale = min(1, 1024 / max(size.width, size.height))
            let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            if drawableSize != target { drawableSize = target }
        }
    }

    final class Renderer: NSObject, MTKViewDelegate {
        private var preparation: Task<Void, Never>?
        private var pipeline: MTLRenderPipelineState?
        private var queue: MTLCommandQueue?
        private var texture: MTLTexture?
        private var start: TimeInterval = 0
        #if DEBUG
        private var reportedDrawableWait = false
        private var reportedFirstDraw = false
        private var reportedFirstFrame = false
        private let receiptToken = RecordingRippleDiagnostics.token
        #endif

        @MainActor func prepare(view: MTKView, image: UIImage) {
            guard let device = view.device else {
                RecordingRippleDiagnostics.event("render unavailable: no Metal device")
                return
            }
            guard let bitmap = image.cgImage else {
                RecordingRippleDiagnostics.event("render unavailable: image has no bitmap")
                return
            }
            let started = ProcessInfo.processInfo.systemUptime
            preparation = Task { @MainActor [weak self, weak view] in
                let library = try? await device.makeLibrary(source: Self.shader, options: nil)
                guard !Task.isCancelled, let self, let view else { return }
                guard let library else {
                    RecordingRippleDiagnostics.event("render unavailable: shader compile", since: started)
                    return
                }
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "rippleVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "rippleFragment")
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                let pipeline = try? await device.makeRenderPipelineState(descriptor: descriptor)
                guard !Task.isCancelled else { return }
                guard let pipeline else {
                    RecordingRippleDiagnostics.event("render unavailable: pipeline creation", since: started)
                    return
                }
                guard let queue = device.makeCommandQueue() else {
                    RecordingRippleDiagnostics.event("render unavailable: command queue creation", since: started)
                    return
                }
                guard let texture = Self.makeTexture(device: device, bitmap: bitmap, started: started) else { return }
                RecordingRippleDiagnostics.event("renderer ready", since: started)
                self.pipeline = pipeline
                self.texture = texture
                self.queue = queue
                self.start = ProcessInfo.processInfo.systemUptime
                view.isPaused = false
            }
        }

        private static func makeTexture(device: MTLDevice, bitmap: CGImage, started: TimeInterval) -> MTLTexture? {
            // Normalize renderer-dependent bitmap formats to one bounded Metal-compatible layout.
            let longestSide = max(bitmap.width, bitmap.height)
            guard longestSide > 0 else {
                RecordingRippleDiagnostics.event("render unavailable: empty image bitmap", since: started)
                return nil
            }
            let scale = min(1, 1400.0 / Double(longestSide))
            let width = max(1, Int(Double(bitmap.width) * scale))
            let height = max(1, Int(Double(bitmap.height) * scale))
            let bytesPerRow = width * 4
            let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: format),
                  let pixels = context.data else {
                RecordingRippleDiagnostics.event("render unavailable: RGBA conversion", since: started)
                return nil
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                RecordingRippleDiagnostics.event("render unavailable: RGBA texture allocation", since: started)
                return nil
            }
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: pixels, bytesPerRow: context.bytesPerRow)
            return texture
        }

        @MainActor func stop() {
            preparation?.cancel()
            preparation = nil
            pipeline = nil
            texture = nil
            queue = nil
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipeline, let queue, let texture,
                  view.bounds.width > 0, view.bounds.height > 0 else { return }
            let size = view.bounds.size
            #if DEBUG
            if !reportedFirstDraw {
                reportedFirstDraw = true
                let phase = view.window == nil ? "first draw: detached" : "first draw: attached with nonempty bounds"
                RecordingRippleDiagnostics.event(phase, since: start, token: receiptToken,
                                                bounds: size, drawable: view.drawableSize)
            }
            #endif
            guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
                  let command = queue.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                #if DEBUG
                if !reportedDrawableWait {
                    reportedDrawableWait = true
                    RecordingRippleDiagnostics.event("waiting for a drawable or encoder", since: start)
                }
                #endif
                return
            }
            var params = SIMD4(Float(size.width), Float(size.height),
                               Float(ProcessInfo.processInfo.systemUptime - start),
                               Float(texture.width) / Float(texture.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBytes(&params, length: MemoryLayout.size(ofValue: params), index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            #if DEBUG
            if !reportedFirstFrame {
                reportedFirstFrame = true
                let started = start
                let token = receiptToken
                RecordingRippleDiagnostics.event("first frame submitted", since: started, token: token)
                command.addCompletedHandler { completed in
                    let phase = completed.status == .completed ? "first frame completed" : "first frame failed"
                    RecordingRippleDiagnostics.event(phase, since: started, token: token)
                }
                #if !targetEnvironment(simulator)
                drawable.addPresentedHandler { _ in
                    RecordingRippleDiagnostics.event("first frame presented", since: started, token: token)
                }
                #endif
            }
            #endif
            command.present(drawable)
            command.commit()
        }

        // Runtime compilation avoids an optional build-time Metal toolchain.
        private static let shader = """
        #include <metal_stdlib>
        using namespace metal;

        struct RippleVertex {
            float4 position [[position]];
            float2 uv;
        };

        vertex RippleVertex rippleVertex(uint index [[vertex_id]]) {
            float2 uv = float2(index & 1u, index >> 1u);
            return {float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0), uv};
        }

        fragment half4 rippleFragment(RippleVertex in [[stage_in]],
                                     texture2d<half> still [[texture(0)]],
                                     constant float4& params [[buffer(0)]]) {
            constexpr sampler sampleFilter(address::clamp_to_edge, filter::linear);
            float2 size = params.xy;
            float time = params.z;
            float strength = smoothstep(0.0, 0.20, time);
            // A traveling curtain: each row moves sideways by a different amount.
            // Fixed side edges plus amplitude*pi < 1 keep every row fold-free.
            float phase = 6.2831853 * (1.15 * in.uv.y - time / 2.8);
            float2 warped = in.uv;
            warped.x += 0.12 * strength * sin(phase) * sin(3.14159265 * in.uv.x);
            float aspect = (size.x / size.y) / params.w;
            float2 fill = min(float2(aspect, 1.0 / aspect), float2(1.0));
            float2 uv = (warped - 0.5) * fill + 0.5;
            float2 blur = 2.5 * fill / size;
            half3 color = still.sample(sampleFilter, uv).rgb * 0.4h;
            color += still.sample(sampleFilter, uv + float2(blur.x, 0)).rgb * 0.15h;
            color += still.sample(sampleFilter, uv - float2(blur.x, 0)).rgb * 0.15h;
            color += still.sample(sampleFilter, uv + float2(0, blur.y)).rgb * 0.15h;
            color += still.sample(sampleFilter, uv - float2(0, blur.y)).rgb * 0.15h;
            return half4(color * half(strength), half(strength));
        }
        """
    }
}

private struct AgentWorkingEdge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10) / 10
            let highlight = AngularGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .orange.opacity(0.22), location: 0.07),
                    .init(color: .orange.opacity(0.75), location: 0.16),
                    .init(color: .orange.opacity(0.28), location: 0.25),
                    .init(color: .clear, location: 0.34),
                    .init(color: .clear, location: 1)
                ],
                center: .center,
                angle: .degrees(phase * 360)
            )
            let edge = RoundedRectangle(cornerRadius: 24, style: .continuous).inset(by: 3)
            if reduceMotion {
                edge.stroke(.orange.opacity(0.25), lineWidth: 2)
            } else {
                edge.stroke(highlight, lineWidth: 7).blur(radius: 5)
                    .overlay { edge.stroke(highlight, lineWidth: 2) }
            }
        }
        .ignoresSafeArea()
    }
}

private struct ShimmeringStatusCaption: View {
    let caption: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if reduceMotion {
            Text(caption).font(.callout).multilineTextAlignment(.center)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.5) / 2.5
                Text(caption).font(.callout).multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.65))
                    .overlay {
                        GeometryReader { geometry in
                            LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: geometry.size.width * 0.45)
                                .offset(x: geometry.size.width * (phase * 1.9 - 0.45))
                        }
                    }
                    .mask(Text(caption).font(.callout).multilineTextAlignment(.center))
            }.accessibilityLabel(caption)
        }
    }
}
