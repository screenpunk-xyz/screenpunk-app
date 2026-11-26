import SwiftUI
import UIKit
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
                Text("See sample screens").font(.largeTitle.bold())
                Text("Try the sample Weather and NASA screens. Swipe left or right with two fingers to switch screens. You can hide or remove them from this device in Settings.")
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
    @State private var keyboardRequestPresented = false
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
    @State private var pluginSetupProgress = CloudPluginSetupProgress()
    @State private var recordingBackdropScope: RecordingBackdropScope?
    @State private var dashboardSnapshot = DashboardSnapshotSource()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
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
            } else if !showsCloudOnboarding && !model.settingsOpen && !model.accountOperationInProgress && (model.busy || model.requestPending || model.routeChangeBlocked || model.canRetry || model.canCancelRequest || speech.error != nil || model.presentedStatusMessage != nil || model.linkedEditOptions(for: model.screen?.id)?.hasConflict == true) {
                GeometryReader { geometry in
                    VStack {
                        Spacer()
                        RequestStatusPill(model: model, speech: speech, maximumTextHeight: max(80, geometry.size.height * 0.45))
                            .padding(24)
                    }.frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundStyle(.white)
        .background(DeviceGestures(
            began: beginSpeech, ended: speech.end, cancelled: speech.cancel,
            canSwipe: canSwipe && !keyboardRequestPresented && swipeID == nil, pagePan: handlePagePan,
            settings: { if !keyboardRequestPresented && galleryIntro == nil && weatherDestination == nil && !onboardingHelpInFlight { model.openSettings() } }
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
        .alert("Screenpunk account deleted", isPresented: Binding(
            get: { model.deletedAccountAppleHelpURL != nil },
            set: { if !$0 { model.deletedAccountAppleHelpURL = nil } }
        ), presenting: model.deletedAccountAppleHelpURL) { url in
            Button("Manage Apple Access") { openURL(url); model.deletedAccountAppleHelpURL = nil }
            Button("Done", role: .cancel) { model.deletedAccountAppleHelpURL = nil }
        } message: { _ in
            Text("You can also manage Screenpunk’s Apple sign-in access in your Apple Account settings.")
        }
        .modifier(AccountCreationAlert(model: model, isHost: !model.settingsOpen))
        .alert("Which iPads should this edit update?", isPresented: Binding(
            get: { model.linkedEditPrompt != nil },
            set: { if !$0 { model.cancelLinkedEditPrompt() } }
        ), presenting: model.linkedEditPrompt) { prompt in
            Button(prompt.options.updateAllTitle) { model.confirmLinkedEdit(prompt, scope: .all) }
            Button("Only this iPad") { model.confirmLinkedEdit(prompt, scope: .thisDevice) }
            Button("Cancel", role: .cancel) { model.cancelLinkedEditPrompt() }
        } message: { prompt in
            Text("Update “\(prompt.options.screenName)” across linked iPads, or save “\(prompt.options.forkName)” on just this iPad.")
        }
        .sheet(item: $onboardingHelp, onDismiss: {
            onboardingHelpInFlight = false
            advanceOnboarding()
        }) { help in
            CloudListenerSetupSheet(scope: help.scope, email: help.email, stage: help.id.stage)
        }
        .sheet(isPresented: $keyboardRequestPresented) { KeyboardRequestEditor(model: model, creatingNew: true) }
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
        .modifier(CustomConnectionAccessModal(model: model, isHost: scenePhase == .active && !model.settingsOpen &&
            model.screenDataPrompt == nil && galleryIntro == nil && weatherDestination == nil &&
            !onboardingHelpInFlight && !settingsCoverPresented && !speech.recording))
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
        .onAppear { updatePluginSetupProgress(); advanceOnboarding() }
        .onChange(of: pluginSetupInput) { _ in updatePluginSetupProgress() }
        .task(id: pluginSetupProgress.wakeDeadline) {
            guard let deadline = pluginSetupProgress.wakeDeadline else { return }
            let scope = pluginSetupProgress.scope
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000))
            } catch { return }
            guard !Task.isCancelled, pluginSetupProgress.scope == scope,
                  pluginSetupProgress.wakeDeadline == deadline else { return }
            updatePluginSetupProgress()
        }
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
        let stage: CloudSetupStage = showsPluginInstructions ? .plugin : .listener
        return OnboardingHelpContext(
            identity: AgentPluginIdentity(origin: CloudClient.originScope.canonicalOrigin,
                                          account: model.cloud.localAccountID, owner: model.permissionOwner),
            stage: stage
        )
    }

    private var pluginSetupInput: CloudPluginSetupProgress.Input {
        let session = model.cloud.session
        let eligible = !model.accountOperationInProgress && model.needsAgentSetup &&
            (showsCloudOnboarding || model.canFinishAgentSetup)
        let scope: CloudPluginSetupProgress.Scope?
        if eligible, let account = model.cloud.localAccountID, let session {
            scope = .init(origin: CloudClient.originScope.canonicalOrigin, account: account,
                          device: session.deviceId, owner: model.permissionOwner)
        } else { scope = nil }
        return .init(scope: scope, pluginConnected: model.onboardingCloudPluginConnected,
                     listenerReady: model.canFinishAgentSetup)
    }

    private func updatePluginSetupProgress() {
        pluginSetupProgress.update(pluginSetupInput, now: Date())
        advanceOnboarding()
    }

    private var showsPluginInstructions: Bool {
        pluginSetupProgress.presentsPluginInstructions(for: pluginSetupInput)
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
                               rendererID: model.screen.map { $0.revision + model.publicReadSessionKey + model.screenDataRendererKey + model.customHTTPRendererKey },
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
        let missing = model.missingConnections.filter { $0.customAlias == nil }
        return ZStack {
            screenContent
            if !missing.isEmpty && !model.settingsOpen && !speech.recording {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "link.badge.plus").font(.largeTitle)
                    if model.canAllowCurrentPublicData {
                        Text(model.currentPublicDataIncludesPages ? "Allow public page reads?" : "Allow public data?").font(.title2.bold())
                        Text("This screen reads from these public sources. No account or credentials are sent.")
                            .multilineTextAlignment(.center)
                        ScrollView {
                            Text(model.currentPublicDataScopes.joined(separator: "\n"))
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(maxHeight: 140)
                        .fixedSize(horizontal: false, vertical: true)
                        Button(model.currentPublicDataIncludesPages ? "Allow page reads" : "Allow public data", action: model.allowCurrentPublicData).buttonStyle(.borderedProminent)
                        Button("Review sources", action: model.openConnectionSettings)
                    } else if let unsupported = missing.first(where: { $0.unsupportedAlias != nil })?.unsupportedAlias {
                        Text("Connection unavailable").font(.title2.bold())
                        Text("This screen requires the “\(unsupported)” connection, which this version of Screenpunk cannot run.")
                            .multilineTextAlignment(.center)
                    } else if missing.count == 1, missing.first?.kind == .home {
                        Text("Allow Home Assistant access").font(.title2.bold())
                        Text("Review this screen’s Home Assistant access in its settings.")
                            .multilineTextAlignment(.center)
                        Button("Screen settings", action: model.openConnectionSettings).buttonStyle(.borderedProminent)
                    } else {
                        Text("Finish setting up this screen").font(.title2.bold())
                        Text("Configure \(missing.map(\.name).joined(separator: ", ")) in Settings to use this screen.")
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
        if model.requiresAccountOnboarding {
            OnboardingAgentConnection(model: model)
        } else if let screen = model.screen, let assets = model.assets {
            // The isolated WebView coordinator owns an immutable package and bridge scope.
            // A new local revision must create a new renderer, including on rollback/swipe.
            let rendererID = screen.revision + model.publicReadSessionKey + model.screenDataRendererKey + model.customHTTPRendererKey
            DashboardRuntimeView(store: assets, homeAssistant: model.homeAssistant, customHTTP: model.customHTTP, publicReads: model.publicReads, screenData: model.screenDataProvider, revision: screen.revision, catalogContext: model.catalogPreviewContext, connectionCount: 1, screenName: screen.displayName,
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
        } else if showsCloudOnboarding && showsPluginInstructions {
            let scope = CloudClient.originScope
            OnboardingAgentPlugin { openOnboardingHelp(.plugin) }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !speech.recording && !model.settingsOpen && !model.accountOperationInProgress {
                        Group {
                            if speech.error != nil || model.presentedStatusMessage != nil {
                                RequestStatusPill(model: model, speech: speech, maximumTextHeight: 160)
                            } else {
                                PluginConnectionStatusPill(connected: model.onboardingCloudPluginConnected,
                                                          lookingForListener: pluginSetupProgress.phase == .looking)
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                    }
                }
                .id(AgentPluginIdentity(origin: scope.canonicalOrigin, account: model.cloud.localAccountID, owner: model.permissionOwner))
        } else if showsCloudOnboarding {
            let scope = CloudClient.originScope
            CloudListenerSetupView(scope: scope, email: model.email, isPlaceholder: true)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !speech.recording && !model.settingsOpen && !model.accountOperationInProgress {
                        Group {
                            if speech.error != nil || model.presentedStatusMessage != nil {
                                RequestStatusPill(model: model, speech: speech, maximumTextHeight: 160)
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
            OnboardingAgentConnection(model: model)
        } else {
            CreationPlaceholder(
                hideDisabled: model.permissionOwner.isEmpty || model.accountOperationInProgress,
                openSettings: { model.openSettings() },
                addUsingKeyboard: { keyboardRequestPresented = true },
                keyboardDisabled: model.busy || model.requestPending || model.routeChangeBlocked || model.accountOperationInProgress,
                hide: { model.hideCreationScreen(owner: model.permissionOwner) }
            )
        }
    }
    private func beginSpeech() {
        guard !model.settingsOpen, !keyboardRequestPresented, galleryIntro == nil, weatherDestination == nil, !onboardingHelpInFlight else { return }
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
    @ObservedObject var model: DeviceModel
    var body: some View { accountOnboarding }
    @ScaledMetric(relativeTo: .body) private var signInScale = 1.0

    private var accountOnboarding: some View {
        let secondaryText = Color(red: 175/255, green: 186/255, blue: 194/255)
        let signIn = VStack(spacing: 24) {
            onboardingArtwork("screenpunk-lockup.png")
                .resizable().scaledToFit().frame(maxWidth: 340)
                .accessibilityLabel("Screenpunk")
            Text("To start making your own screens on this device,\nsign in or create an account.")
                .font(.title3).foregroundStyle(secondaryText)
            VStack(spacing: 12) {
                providerButton("Continue with Apple", provider: .apple)
                providerButton("Continue with Google", provider: .google)
            }
            .frame(maxWidth: min(660, 360 * signInScale))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 660)
        .padding(32)
        .fixedSize(horizontal: false, vertical: true)

        let localSetup = VStack(spacing: 16) {
            Text("Alternatively, advanced users can use Screenpunk without an account by connecting to their agent locally using Codex server in Settings.")
                .font(.callout).foregroundStyle(secondaryText)
            Button("Open Settings") {
                model.settingsPage = .account
                model.settingsOpen = true
            }
            .buttonStyle(.bordered)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: 660)
        .background(Color(red: 32/255, green: 39/255, blue: 44/255), in: RoundedRectangle(cornerRadius: 20))
        .padding(24)
        .fixedSize(horizontal: false, vertical: true)

        return ViewThatFits(in: .vertical) {
            VStack(spacing: 0) {
                signIn.frame(maxWidth: .infinity, maxHeight: .infinity)
                localSetup
            }
            ScrollView {
                VStack(spacing: 0) {
                    signIn
                    localSetup
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(red: 21/255, green: 25/255, blue: 28/255).ignoresSafeArea())
    }

    private func onboardingArtwork(_ filename: String) -> Image {
        let path = Bundle.main.path(forResource: filename, ofType: nil, inDirectory: "OnboardingAssets")
        return Image(uiImage: path.flatMap(UIImage.init(contentsOfFile:)) ?? UIImage())
    }

    private func providerButton(_ title: String, provider: CloudSignInProvider) -> some View {
        let isApple = provider == .apple
        let height = 56 * signInScale
        let foreground = isApple ? Color.white : Color(white: 227/255)
        let fill = Color(red: 19/255, green: 19/255, blue: 20/255)
        let shape = RoundedRectangle(cornerRadius: 16)
        return Button {
            Task { await model.signIn(provider: provider, fromCloudOnboarding: true) }
        } label: {
            HStack(spacing: (isApple ? 5 : 15) * signInScale) {
                if isApple {
                    onboardingArtwork("apple-sign-in-white.png")
                        .resizable().scaledToFit().frame(width: height * 39 / 44, height: height)
                        .blendMode(.screen)
                        .accessibilityHidden(true)
                } else {
                    onboardingArtwork("google-g.png")
                        .resizable().scaledToFit().frame(width: 25.5 * signInScale, height: 25.5 * signInScale)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.custom("GoogleSans-Medium", fixedSize: 18 * signInScale))
                    .foregroundStyle(foreground)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, max(0, (signInScale - 1) * 6))
            .frame(maxWidth: .infinity, minHeight: height)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(Color(red: 99/255, green: 111/255, blue: 119/255), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(model.accountOperationInProgress || model.routeChangeBlocked)
        .accessibilityIdentifier("onboarding.signIn.\(provider.rawValue)")
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
    let hideDisabled: Bool
    let openSettings: () -> Void
    let addUsingKeyboard: () -> Void
    let keyboardDisabled: Bool
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
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            Button("Settings", action: openSettings)
                            Button("Gestures") { showsGestures = true }
                            Button("Hide this screen", action: hide).disabled(hideDisabled)
                        }
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                Button("Settings", action: openSettings)
                                Button("Gestures") { showsGestures = true }
                            }
                            Button("Hide this screen", action: hide).disabled(hideDisabled)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .multilineTextAlignment(.center)
        }
        .safeAreaInset(edge: .bottom) {
            Button("Add screen using keyboard", action: addUsingKeyboard)
                .buttonStyle(.borderless)
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.bottom, 12)
                .disabled(keyboardDisabled)
                .accessibilityIdentifier("screen.addUsingKeyboard")
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
            Button("Hide this screen", action: hide)
                .buttonStyle(.bordered)
                .disabled(hideDisabled)
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
    case plugin, listener

    var sheetTitle: String {
        switch self {
        case .plugin: return "Install Screenpunk plugin"
        case .listener: return "Activate the listener"
        }
    }
}

/// The native onboarding placeholder and the detailed guide use the same plugin
/// destination and listener request.
struct CloudListenerSetupView: View {
    let scope: CloudOriginScope
    let email: String?
    var isPlaceholder = false
    var stage: CloudSetupStage = .listener
    @State private var copied = false

    private let listenerTitle = "Activate the listener"
    private let listenerCaption = "Open a new task in ChatGPT or your Dot, and send this prompt to activate its Screenpunk listener."

    private var pluginName: String { scope.permitsLegacyMigration ? "Screenpunk Staging" : "Screenpunk" }

    private var setupRequest: String {
        let account = "Use the same Screenpunk account and sign-in option as my iPad. If it uses Apple, use the same Apple ID; relay or display email differences alone do not mean a different account. Stop if a different Screenpunk account is connected."
        return "Use @\(pluginName) in the same Screenpunk environment as my iPad. \(account) Subscribe to screenpunk.request.created, keep listening, and handle my device requests. Confirm when the subscription is active. If subscriptions aren’t available, tell me to use Work + Cloud or a dot."
    }

    var body: some View {
        Group {
            if isPlaceholder {
                placeholder.foregroundStyle(.white)
            } else {
                guide
            }
        }
        .background(isPlaceholder ? Color.black : Color.clear)
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
        VStack(alignment: .leading, spacing: 24) {
            if stage == .plugin {
                setupGuideStep(1, "Install the Screenpunk plugin in ChatGPT", "Open ChatGPT Plugins, search for Screenpunk, and install the plugin.")
                setupGuideStep(2, "Connect your Screenpunk account", "Choose Connect, then use the same sign-in option you used on this device.")
                setupGuideStep(3, "Set up the Screenpunk plugin", "After connecting your Screenpunk account, click Set up Screenpunk in ChatGPT.")
            } else {
                manualListenerSteps
            }
        }
        .padding(.horizontal, stage == .plugin ? 40 : 24)
        .padding(.vertical, stage == .plugin ? 32 : 40)
        .frame(maxWidth: 680, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var manualListenerSteps: some View {
        VStack(alignment: .leading, spacing: 24) {
            setupGuideStep(1, "Open a new ChatGPT task", "Open Work → Cloud or your dot and select @\(pluginName).")
            VStack(alignment: .leading, spacing: 10) {
                setupGuideStep(2, "Send the listener request", "Copy this request and send it in that task.")
                HStack(alignment: .top, spacing: 10) {
                    promptText
                    if #available(iOS 26, *) {
                        copyIcon.buttonStyle(.glass).buttonBorderShape(.circle)
                    } else {
                        copyIcon.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .padding(.leading, 40)
            }
            setupGuideStep(3, "Return to Screenpunk", "Leave the listener running to receive requests from this iPad.")
        }
    }

    private func heading(_ font: Font) -> some View {
        Text(listenerTitle).font(font).accessibilityAddTraits(.isHeader)
    }

    private var copyButton: some View {
        Button(copied ? "Copied" : "Copy listener request", action: copyRequest)
        .buttonStyle(.borderedProminent)
    }

    private var copyIcon: some View {
        Button(action: copyRequest) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(.primary)
        }
        .controlSize(.large)
        .accessibilityLabel(copied ? "Copied" : "Copy listener request")
    }

    private func copyRequest() {
        UIPasteboard.general.string = setupRequest
        copied = true
    }
}

private func setupGuideStep(_ number: Int, _ title: String, _ detail: String) -> some View {
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

private struct SettingsSheetHeader: View {
    let title: String
    let dismissLabel: String
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 52)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityAddTraits(.isHeader)
            if #available(iOS 26, *) {
                dismissButton.buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
            } else {
                dismissButton.buttonStyle(.plain)
                    .background(.thinMaterial, in: Circle())
            }
        }
    }

    private var dismissButton: some View {
        Button(role: .cancel) { close() } label: {
            Image(systemName: "xmark").font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel(dismissLabel)
        .keyboardShortcut(.cancelAction)
    }
}

struct CloudListenerSetupSheet: View {
    let scope: CloudOriginScope
    let email: String?
    var stage: CloudSetupStage = .listener
    var startsWithPluginPicker = false
    @State private var choseChatGPT = false
    private var choosingPlugin: Bool { startsWithPluginPicker && !choseChatGPT }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if #available(iOS 18, *) {
            content.presentationSizing(.fitted)
        } else {
            content.presentationDetents([.medium, .large])
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            SettingsSheetHeader(title: stage.sheetTitle, dismissLabel: "Close") { dismiss() }
                .padding([.horizontal, .top], 24)
            ViewThatFits(in: .vertical) {
                stepContent.fixedSize(horizontal: false, vertical: true)
                ScrollView { stepContent }
            }
        }
        .frame(idealWidth: stage == .listener ? 640 : 480, maxWidth: stage == .listener ? 640 : 480)
    }

    @ViewBuilder private var stepContent: some View {
        if choosingPlugin {
            ZStack(alignment: .top) {
                instructions.hidden().accessibilityHidden(true)
                CloudPluginPicker { choseChatGPT = true }
                    .padding(.horizontal, 24)
            }
        } else {
            instructions
        }
    }

    private var instructions: some View {
        CloudListenerSetupView(scope: scope, email: email, stage: stage)
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
    case home = "Home Assistant", television = "Google TV", calendar = "Google Calendar", customConnections = "Custom Connections"
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
        case .customConnections: return "link"
        }
    }
}
private struct CustomConnectionAccessModal: ViewModifier {
    @ObservedObject var model: DeviceModel
    let isHost: Bool
    @State private var detailsID: UUID?

    private var prompt: DeviceModel.CustomConnectionPrompt? { isHost ? model.customConnectionPrompt : nil }

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(prompt != nil)
            .allowsHitTesting(prompt == nil)
            .overlay {
                if let prompt {
                    CustomConnectionAccessCard(model: model, prompt: prompt) { detailsID = prompt.id }
                        .id(prompt.id)
                }
            }
            .sheet(isPresented: Binding(get: { prompt != nil && detailsID == prompt?.id }, set: { presented in
                if !presented { detailsID = nil }
            })) {
                if let prompt {
                    NavigationStack {
                        DeviceCustomConnectionSettings(model: model, use: prompt.use, owner: prompt.owner, focusScreen: prompt.use.id)
                            .toolbar { ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { detailsID = nil; model.dismissCustomConnectionPrompt(prompt) }
                            } }
                    }
                }
            }
    }
}

private struct CustomConnectionAccessCard: View {
    @ObservedObject var model: DeviceModel
    let prompt: DeviceModel.CustomConnectionPrompt
    let openSettings: () -> Void
    @State private var action: Action?
    @State private var registration: DeviceModel.ProvisioningStatus?
    @State private var problem: String?
    @State private var manualSetupRequired = false

    private enum Action: Equatable { case prepare, trust }

    private var origin: String? {
        prompt.status?.origin ?? prompt.setupOrigin ??
            model.customConnectionProposal(prompt.use)?.fields[prompt.use.declaration.originField]
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)
            card
        }
    }

    private var card: some View {
        ViewThatFits(in: .vertical) {
            cardContents.fixedSize(horizontal: false, vertical: true)
            ScrollView { cardContents }
        }
        .padding(24).frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24)).padding()
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { dismiss() }
        .task(id: action) {
            guard let action else { return }
            defer { self.action = nil }
            problem = nil
            do {
                switch action {
                case .prepare: try await prepare()
                case .trust:
                    guard let registration else { return }
                    try await model.finishInlineConnectionSetup(registration, prompt: prompt)
                }
            } catch {
                if !Task.isCancelled {
                    problem = "Couldn’t finish secure setup. Try again or review the connection in Settings."
                    if action == .trust { self.registration = nil; manualSetupRequired = true }
                }
            }
        }
    }

    private var cardContents: some View {
        VStack(alignment: .leading, spacing: 16) {
            if registration == nil {
                let operations = prompt.use.declaration.operations.map(\.name).joined(separator: ", ")
                let name = model.connectionName(serviceID: prompt.use.declaration.id, fallback: prompt.use.declaration.label)
                Text("Allow “\(prompt.use.screen.displayName)” to read \(operations) from \(name)?")
                    .font(.title2.bold()).accessibilityAddTraits(.isHeader)
            } else {
                Text("Review the server certificate").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            }
            if let origin {
                Text(verbatim: origin).font(.callout.monospaced()).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Connection details").font(.subheadline.weight(.semibold))
                ForEach(prompt.use.declaration.operations, id: \.name) { operation in
                    Text(verbatim: operation.method + " " + operation.path).font(.callout.monospaced())
                }
            }
            if let fingerprint = registration?.certificateFingerprint {
                Text("Your setup agent reported this SHA-256 fingerprint. Verify it belongs to this server before trusting it.")
                    .font(.callout)
                Text(verbatim: fingerprint).font(.caption.monospaced()).textSelection(.enabled)
            } else if prompt.status == nil, prompt.setupOrigin != nil, !manualSetupRequired {
                Text("Approve starts setup for a credential on this iPad. You’ll review the server certificate before the screen can read.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
            if action != nil {
                ProgressView(action == .trust ? "Saving connection…" : "Waiting for your agent to verify provider access…")
            }
            if #available(iOS 26, *) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 12) {
                        cancelButton.buttonStyle(.glass)
                        primaryButton.buttonStyle(.glassProminent)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    cancelButton.buttonStyle(.bordered)
                    primaryButton.buttonStyle(.borderedProminent)
                }
            }
        }
        .controlSize(.large)
    }

    private var cancelButton: some View {
        Button(role: .cancel, action: dismiss) { Text("Cancel").frame(maxWidth: .infinity) }
            .disabled(action == .trust)
            .accessibilityIdentifier("custom-connection.not-now")
    }

    private var primaryButton: some View {
        let hasCertificate = registration?.certificateFingerprint != nil
        let canApprove = !manualSetupRequired && (prompt.status != nil || prompt.setupOrigin != nil)
        let title = hasCertificate ? "Trust and allow" : canApprove ? "Approve" : "Connection settings"
        return Button {
            if hasCertificate { action = .trust }
            else if canApprove { allow() }
            else { openSettings() }
        } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .disabled(action != nil)
        .accessibilityIdentifier(hasCertificate ? "custom-connection.trust-and-allow" : canApprove ? "custom-connection.allow" : "custom-connection.open")
    }

    private func dismiss() {
        guard action != .trust else { return }
        model.dismissCustomConnectionPrompt(prompt)
    }

    private func allow() {
        if prompt.status == nil {
            action = .prepare
            return
        }
        do { try model.approveCustomConnectionPrompt(prompt) }
        catch {
            problem = "This connection changed. Dismiss the prompt and try again."
            manualSetupRequired = true
        }
    }

    private func prepare() async throws {
        var status = try await model.advanceInlineConnectionSetup(prompt, beginIfAvailable: true)
        for delay in [2, 3, 5, 8] + Array(repeating: 8, count: 13) {
            guard status?.state == "pending" else { break }
            try await Task.sleep(for: .seconds(delay))
            status = try await model.advanceInlineConnectionSetup(prompt, beginIfAvailable: false)
        }
        try Task.checkCancellation()
        switch status?.state {
        case "ready":
            registration = status
        case "pending":
            problem = "Your agent is still preparing the connection. You can dismiss this and try reading again later."
        case "unsupported":
            manualSetupRequired = true
            problem = "Your agent couldn’t verify setup access at this provider. You can enter its token in Connection details."
        case "retry", "available":
            problem = "Automatic setup wasn’t started. Tap Approve to try again."
        default:
            manualSetupRequired = true
            problem = "Automatic setup couldn’t finish. Review the setup in Connection details."
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
    let screenID: String

    private var permissions: [DeviceScreenDataPermission] {
        let localDeviceIDs = model.activeProfile.map { Set([$0.localDeviceID, $0.authoringDeviceID]) } ?? []
        return model.screenDataPermissions.filter { permission in
            if permission.key.target.screenId == screenID { return true }
            let reader = permission.key.reader
            guard reader.kind == .screen, reader.screenId == screenID, let readerDeviceID = reader.deviceId else { return false }
            return localDeviceIDs.contains(readerDeviceID)
        }
    }

    var body: some View {
        Section {
            let decisions = permissions
            if decisions.isEmpty {
                Text("No screen data access decisions for this screen.").foregroundStyle(.secondary)
            }
            ForEach(decisions) { permission in
                VStack(alignment: .leading, spacing: 8) {
                    if permission.key.target.screenId == screenID {
                        Text("Reader: \(permission.readerLabel)").font(.headline)
                    } else {
                        Text("Publisher: \(permission.targetTitle)").font(.headline)
                    }
                    Text(permission.key.target.exportName)
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
        } header: {
            Text("Screen Data Access")
        } footer: {
            Text("Access applies to the reader and screen version you approved. Forgetting a denied or revoked decision lets the reader ask again.")
        }
    }
}

private enum ScreenSettingsRoute: Hashable {
    case screen(String, owner: String)
    case shared(DeviceSettingsPage)
    case custom(String, alias: String, owner: String)
    case sharedCustom(String, owner: String)
}

private struct SettingsFieldStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            configuration.content.foregroundStyle(.primary)
        } label: {
            configuration.label.foregroundStyle(.secondary)
        }
        .labeledContentStyle(.automatic)
    }
}

private struct ScreenNameField: View {
    let name: String
    let save: (String) throws -> Void
    let reportError: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var editing = false

    var body: some View {
        LabeledContent("Name") {
            TextField("Screen name", text: $draft, prompt: Text("Screen name").foregroundColor(Color(uiColor: .tertiaryLabel)))
                .accessibilityIdentifier("screen.name")
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit { focused = false; commit() }
        }
        .onAppear { draft = name }
        .onChange(of: name) { if !editing { draft = $0 } }
        .onChange(of: focused) { if $0 { editing = true } else { commit() } }
        .onDisappear(perform: commit)
    }

    private func commit() {
        guard editing else { return }
        editing = false
        guard draft != name else { return }
        do {
            try save(draft)
            draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            draft = name
            reportError(error.localizedDescription)
        }
    }
}

/// Measure live UIKit row positions. Form can rehost a row during a move, so
/// an old row must only unregister its own view.
@MainActor private final class InstalledScreenRowAnchors: ObservableObject {
    private let views = NSMapTable<NSString, UIView>.strongToWeakObjects()

    func register(_ view: UIView, for screenID: String) {
        views.setObject(view, forKey: screenID as NSString)
    }

    func unregister(_ view: UIView, for screenID: String) {
        guard views.object(forKey: screenID as NSString) === view else { return }
        views.removeObject(forKey: screenID as NSString)
    }

    func frame(for screenID: String) -> CGRect? {
        guard let view = views.object(forKey: screenID as NSString),
              let window = view.window, !view.bounds.isEmpty else { return nil }
        return view.convert(view.bounds, to: window)
    }
}

private struct InstalledScreenRowAnchor: UIViewRepresentable {
    let screenID: String
    let anchors: InstalledScreenRowAnchors

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        view.bind(screenID: screenID, anchors: anchors)
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: ()) {
        view.unbind()
    }

    final class AnchorView: UIView {
        private var screenID: String?
        private weak var anchors: InstalledScreenRowAnchors?

        func bind(screenID: String, anchors: InstalledScreenRowAnchors) {
            if self.screenID != screenID || self.anchors !== anchors {
                unbind()
                self.screenID = screenID
                self.anchors = anchors
            }
            updateRegistration()
        }

        func unbind() {
            if let screenID { anchors?.unregister(self, for: screenID) }
            screenID = nil
            anchors = nil
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateRegistration()
        }

        private func updateRegistration() {
            guard let screenID else { return }
            if window != nil { anchors?.register(self, for: screenID) }
            else { anchors?.unregister(self, for: screenID) }
        }
    }
}

struct DeviceSettingsView: View {
    @State private var path: [ScreenSettingsRoute] = []
    @State private var renameError: String?
    @State private var screenDrag: InstalledScreenDrag?
    @State private var screenDropTarget: String?
    @StateObject private var screenRowAnchors = InstalledScreenRowAnchors()
    @State private var reorderError: String?

    private struct InstalledScreenDrag: Equatable {
        let screenID: String
        let owner: String
    }
    @State private var customConnectionToRemove: ScreenSettingsRoute?
    @State private var customConnectionError: String?
    @ObservedObject var model: DeviceModel
    @ObservedObject var display: DeviceDisplayPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var selection: DeviceSettingsPage? = .account
    @State private var showBilling = false
    @State private var screenToRemove: ScreenLibrary.Saved?
    @State private var linkedConflictToDiscard: DeviceModel.LinkedEditOptions?
    @State private var linkedConflictError: String?
    @State private var sheet: SettingsSheet?
    private enum SettingsSheet: String, Identifiable {
        case addCloudAgent, cloudListener, catalog, editKeyboardRequest
        var id: String { rawValue }
    }
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var promptDestination: ScreenSettingsRoute?

    init(model: DeviceModel, display: DeviceDisplayPreferences) {
        self.model = model
        self.display = display
        let destination = model.settingsScreenID.map { id -> ScreenSettingsRoute in
            if let alias = model.settingsCustomConnectionAlias {
                return .custom(id, alias: alias, owner: model.permissionOwner)
            }
            return .screen(id, owner: model.permissionOwner)
        }
        _promptDestination = State(initialValue: destination)
    }

    var body: some View {
        Group {
            if promptDestination != nil { settingsStack() }
            else { settingsBrowser }
        }
        .labeledContentStyle(SettingsFieldStyle())
        .modifier(AccountCreationAlert(model: model, isHost: model.settingsOpen))
        .modifier(ScreenDataConsentAlert(model: model, isHost: model.settingsOpen && sheet == nil && screenToRemove == nil))
        .modifier(BackupUpgradeAlert(model: model, billing: model.billing,
                                     isHost: model.settingsOpen && sheet == nil && screenToRemove == nil))
        // Present from Settings itself, not a Form Section/row whose hosting
        // controller can resolve the presentation against the outer cover.
        .sheet(item: $sheet) { destination in
            switch destination {
            case .addCloudAgent:
                CloudListenerSetupSheet(scope: CloudClient.originScope, email: model.email, stage: .plugin, startsWithPluginPicker: true)
            case .cloudListener:
                CloudListenerSetupSheet(scope: CloudClient.originScope, email: model.email, stage: .listener)
            case .catalog: CatalogScreenPicker(model: model)
            case .editKeyboardRequest: KeyboardRequestEditor(model: model, creatingNew: false)
            }
        }
        .onAppear {
            selection = model.settingsPage
            model.settingsScreenID = nil
            model.settingsCustomConnectionAlias = nil
            model.checkListenerStatusOnSettingsEntry()
        }
        .onChange(of: selection) {
            if let page = $0 { model.settingsPage = page }
            if $0 != .account { showBilling = false }
            if $0 != .screens { clearScreenDrag() }
        }
        .onChange(of: model.permissionOwner) { _ in
            clearScreenDrag()
            reorderError = nil
            path.removeAll(); screenToRemove = nil
            linkedConflictToDiscard = nil; linkedConflictError = nil
            customConnectionToRemove = nil; customConnectionError = nil
        }
        .alert("Couldn’t rename screen", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
            Button("OK") {}
        } message: { Text(renameError ?? "") }
        .confirmationDialog("Delete this saved connection?", isPresented: Binding(
            get: { customConnectionToRemove != nil },
            set: { if !$0 { customConnectionToRemove = nil } }
        ), titleVisibility: .visible, presenting: customConnectionToRemove) { target in
            Button("Delete connection", role: .destructive) {
                guard case let .sharedCustom(id, owner) = target else { return }
                do { try model.removeCustomConnection(id, owner: owner); customConnectionError = nil }
                catch { customConnectionError = "Couldn’t remove this connection. Try again." }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Every screen using this connection will need to be set up and approved again.")
        }
        .alert("Discard this iPad’s edit?", isPresented: Binding(
            get: { linkedConflictToDiscard != nil },
            set: { if !$0 { linkedConflictToDiscard = nil } }
        ), presenting: linkedConflictToDiscard) { options in
            Button("Discard edit", role: .destructive) { resolveLinkedConflict(options, keep: false) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The local edit will be removed. This iPad will keep following the shared screen.")
        }
        .alert("Remove screen?", isPresented: Binding(get: { screenToRemove != nil }, set: { if !$0 { screenToRemove = nil } })) {
            Button("Cancel", role: .cancel) { screenToRemove = nil }
            Button("Remove", role: .destructive) {
                if let screen = screenToRemove {
                    model.removeScreen(screen.id)
                    if !model.installedScreens.contains(where: { $0.id == screen.id }) {
                        if promptDestination != nil { dismiss() }
                        path.removeAll()
                    }
                }
                screenToRemove = nil
            }
        } message: {
            Text("Remove \(screenToRemove?.displayName ?? "this screen") from this iPad? This also removes its saved previous version.")
        }

    }
    private var settingsBrowser: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 700 && sizeClass != .compact {
                HStack(spacing: 0) {
                    NavigationStack { settingsMenu(isSidebar: true) }
                        .frame(width: 260)
                    Divider()
                    settingsStack()
                }
            } else {
                NavigationSplitView {
                    settingsMenu(isSidebar: false)
                } detail: {
                    settingsStack(showClose: true)
                }
                .environment(\.horizontalSizeClass, .compact)
            }
        }
    }

    private var closeSettings: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark").accessibilityLabel("Close Settings")
        }
    }

    private func settingsMenu(isSidebar: Bool) -> some View {
        List(selection: Binding(get: { selection }, set: { newPage in
            if selection != newPage { path.removeAll() }
            selection = newPage
        })) {
            Section { row(.account, isSidebar: isSidebar) }
            Section("Device") {
                row(.display, isSidebar: isSidebar)
                row(.screens, isSidebar: isSidebar)
            }
            if !usedSharedProviders.isEmpty {
                Section("Shared Connections") {
                    ForEach(usedSharedProviders, id: \.self) { row($0, isSidebar: isSidebar) }
                }
            }
            Section("Help") {
                row(.overview, isSidebar: isSidebar)
                row(.guidedAccess, isSidebar: isSidebar)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .navigationBarLeading) { closeSettings } }
    }

    private func settingsStack(showClose: Bool = false) -> some View {
        NavigationStack(path: $path) {
            Group {
                if let promptDestination { destination(promptDestination) }
                else { detail.navigationTitle((selection ?? .overview).rawValue) }
            }
                .navigationDestination(for: ScreenSettingsRoute.self) { route in
                    destination(route)
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if promptDestination != nil || (showClose && path.isEmpty && !showBilling) {
                        ToolbarItem(placement: .navigationBarLeading) { closeSettings }
                    }
                }
                .navigationDestination(isPresented: $showBilling) {
                    DeviceBillingSettings(device: model, billing: model.billing)
                }
        }
    }

    @ViewBuilder private func destination(_ route: ScreenSettingsRoute) -> some View {
        switch route {
        case let .screen(id, owner):
            if owner == model.permissionOwner, let saved = model.installedScreens.first(where: { $0.id == id }) {
                screenDetails(saved, owner: owner)
            } else { Text("Screen unavailable") }
        case let .shared(provider): sharedProvider(provider)
        case let .custom(id, alias, owner):
            if owner == model.permissionOwner,
               let use = model.customConnectionUses().first(where: { $0.screen.id == id && $0.alias == alias }) {
                sharedCustomConnection(use.declaration.id, owner: owner, focus: use)
            } else { Text("Connection unavailable") }
        case let .sharedCustom(id, owner):
            if owner == model.permissionOwner { sharedCustomConnection(id, owner: owner) }
            else { Text("Connection unavailable") }
        }
    }
    private var usedSharedProviders: [DeviceSettingsPage] {
        var pages: [DeviceSettingsPage] = []
        if !model.manifests(requiring: ["home"]).isEmpty { pages.append(.home) }
        if !model.manifests(requiring: ["googleCalendar", "google-calendar"]).isEmpty { pages.append(.calendar) }
        if !model.manifests(requiring: ["googleTV"]).isEmpty { pages.append(.television) }
        if !model.customConnectionUses().isEmpty || !model.savedCustomConnections.isEmpty { pages.append(.customConnections) }
        return pages
    }

    @ViewBuilder private func row(_ page: DeviceSettingsPage, isSidebar: Bool) -> some View {
        let label = Label(page.rawValue, systemImage: page.symbol)
        if isSidebar {
            Button {
                if selection != page { path.removeAll() }
                selection = page
            } label: {
                label.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tag(page)
        } else {
            NavigationLink(value: page) { label }
        }
    }
    @ViewBuilder private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            Form {
                Section("Ask your agent to make or update a screen") {
                    Label("Hold three fingers while speaking", systemImage: "mic")
                    Text("Keep all three fingers on the screen as you describe what you want to create or change. Lift them to send your instructions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Change screens") {
                    Label("Swipe left or right with two fingers", systemImage: "hand.draw")
                    Text("Move between the screens saved on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Open Settings") {
                    Label("Hold two fingers for three seconds", systemImage: "gearshape")
                    Text("Settings opens directly. Your current screen stays saved while you adjust this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .guidedAccess:
            Form {
                Section("Keep Screenpunk on screen") {
                    Text("Guided Access can restrict this device to Screenpunk. You configure and end it using Apple’s system controls.")
                }
                Section("Start Guided Access") {
                    VStack(alignment: .leading, spacing: 24) {
                        setupGuideStep(1, "Turn on Guided Access", "Open this device’s Settings → Accessibility → Guided Access. Turn it on and choose a passcode.")
                        setupGuideStep(2, "Return to Screenpunk", "Triple-click the Home button if your device has one. Otherwise, triple-click the top button on iPad or the side button on iPhone.")
                        setupGuideStep(3, "Start Guided Access", "Choose Guided Access if a shortcut menu appears. Keep Touch enabled so Screenpunk’s gestures work, then tap Start.")
                    }
                    .padding(.vertical, 16)
                }
                Section("Exit Guided Access") {
                    Text("Triple-click the same button, enter your Guided Access passcode, and tap End. Available biometric shortcuts depend on the device and your Guided Access settings.")
                    Link("Apple’s Guided Access instructions", destination: URL(string: "https://support.apple.com/111795")!)
                }
            }
        case .display:
            DeviceDisplaySettings(preferences: display, device: model)
        case .account:
            if let localSettings = model.localSettings {
                DeviceAccountSettings(device: model, model: localSettings, addCloudAgent: { sheet = .addCloudAgent },
                                      showCloudSetup: { sheet = .cloudListener }, openPlan: { showBilling = true })
            } else {
                Form {
                    DeviceCloudAccountSection(device: model, addCloudAgent: { sheet = .addCloudAgent },
                                              showListenerSetup: { sheet = .cloudListener }, openPlan: { showBilling = true })
                    Section("Local agent") { Text("Local agent storage could not be opened.") }
                }
            }
        case .screens:
            Form {
                Section {
                    HStack {
                        Button("Add a screen", action: model.newScreen)
                            .buttonStyle(.borderless)
                            .disabled(model.needsAgentSetup)
                        Spacer()
                        showScreenToggle("Add a screen", id: ScreenLibrary.instructionsID, owner: model.permissionOwner)
                            .disabled(model.needsAgentSetup)
                    }
                    if model.catalogBackupAccess.allowsBackups {
                        Button("Add a screen from my catalog") { sheet = .catalog }
                            .disabled(!model.canAddCatalogScreen)
                            .accessibilityIdentifier("screen.addFromCatalog")
                    }

                }
                DeviceCloudBackupsSection(model: model) {
                    selection = .account
                    showBilling = true
                }
                Section("On this device") {
                    if let reorderError {
                        Text(reorderError).foregroundStyle(.red)
                    }
                    ForEach(model.needsAgentSetup ? [] : model.installedScreens) { saved in
                        let owner = model.permissionOwner
                        screenSettingsRow(saved.displayName, id: saved.id, owner: owner,
                                          route: .screen(saved.id, owner: owner))
                        if let issue = model.presentedManifestIssue(saved) {
                            DismissibleMessage(issue, color: .orange, onDismiss: { model.dismissManifestIssue(issue, saved: saved) }).id(saved.revision).font(.caption)
                        }
                    }
                }
            }
        case .customConnections:
            customConnections
        case .home, .television, .calendar:
            sharedProvider(selection ?? .home)
        }
    }

    private func screenSettingsRow(_ title: String, id: String, owner: String, route: ScreenSettingsRoute) -> some View {
        HStack {
            screenReorderHandle(title, id: id, owner: owner)
            Button {
                path.append(route)
            } label: {
                HStack {
                    Text(title)
                    if id == model.screen?.id { Image(systemName: "checkmark") }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            showScreenToggle(title, id: id, owner: owner)
            Button { path.append(route) } label: {
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    .frame(width: 32, height: 44, alignment: .trailing).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).accessibilityHidden(true)
        }
        .background {
            InstalledScreenRowAnchor(screenID: id, anchors: screenRowAnchors)
                .allowsHitTesting(false)
        }
        .overlay(alignment: dropGoesAfter(id) ? .bottom : .top) {
            if screenDropTarget == id {
                Capsule().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private func screenReorderHandle(_ title: String, id: String, owner: String) -> some View {
        let screens = model.installedScreens
        let position = screens.firstIndex { $0.id == id }
        let handle = Image(systemName: "line.3.horizontal")
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44, alignment: .leading)
            .contentShape(Rectangle())
        if !owner.isEmpty, !model.accountOperationInProgress, screens.count > 1, let position {
            handle
                .highPriorityGesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let drag = InstalledScreenDrag(screenID: id, owner: owner)
                            if screenDrag != drag {
                                screenDrag = drag
                                reorderError = nil
                            }
                            screenDropTarget = dropTarget(near: value.location, excluding: id)
                        }
                        .onEnded { value in
                            let active = screenDrag == .init(screenID: id, owner: owner)
                            let target = dropTarget(near: value.location, excluding: id)
                            let after = target.map(dropGoesAfter) ?? false
                            clearScreenDrag()
                            if active, let target { moveInstalledScreen(id, to: target, after: after, owner: owner) }
                        }
                )
                .accessibilityElement()
                .accessibilityLabel("Reorder " + title)
                .accessibilityHint("Drag to reorder, or use the move actions.")
                .accessibilityIdentifier("screen.reorder." + id)
                .accessibilityActions {
                    if position > 0 {
                        Button("Move up") { moveInstalledScreen(id, to: screens[position - 1].id, after: false, owner: owner) }
                    }
                    if position + 1 < screens.count {
                        Button("Move down") { moveInstalledScreen(id, to: screens[position + 1].id, after: true, owner: owner) }
                    }
                }
        } else {
            handle.opacity(0.45).accessibilityHidden(true)
        }
    }

    private func clearScreenDrag() {
        screenDrag = nil
        screenDropTarget = nil
    }

    private func dropGoesAfter(_ targetID: String) -> Bool {
        guard let sourceID = screenDrag?.screenID,
              let source = model.installedScreens.firstIndex(where: { $0.id == sourceID }),
              let target = model.installedScreens.firstIndex(where: { $0.id == targetID }) else { return false }
        return source < target
    }

    private func dropTarget(near point: CGPoint, excluding source: String) -> String? {
        model.installedScreens.first { screen in
            guard screen.id != source, let frame = screenRowAnchors.frame(for: screen.id) else { return false }
            return frame.insetBy(dx: -12, dy: -4).contains(point)
        }?.id
    }

    private func moveInstalledScreen(_ id: String, to anchorID: String, after: Bool, owner: String) {
        do {
            try model.moveInstalledScreen(id, relativeTo: anchorID, after: after, owner: owner)
            reorderError = nil
        } catch {
            reorderError = "Couldn’t move this screen. Check the current order and try again."
        }
    }

    private func showScreenToggle(_ title: String, id: String, owner: String) -> some View {
        Toggle("Show", isOn: Binding(
            get: { !model.hiddenScreenIDs.contains(id) },
            set: { model.setScreenShown($0, id: id, owner: owner) }
        ))
        .fixedSize().accessibilityLabel("Show " + title)
        .disabled(owner.isEmpty || model.accountOperationInProgress)
    }

    @ViewBuilder private func sharedProvider(_ provider: DeviceSettingsPage) -> some View {
        switch provider {
        case .home:
            DeviceHomeAssistantSettings(owner: model.permissionOwner, onChange: model.refreshConnections) {
                sharedScreenLinks(aliases: ["home"])
            }
        case .calendar:
            DeviceGoogleCalendarSettings(onChange: model.refreshConnections) {
                sharedScreenLinks(aliases: ["googleCalendar", "google-calendar"])
            }
        case .television:
            DeviceGoogleTVSettings(onChange: model.refreshConnections) {
                sharedScreenLinks(aliases: ["googleTV"])
            }
        default: EmptyView()
        }
    }

    @ViewBuilder private func sharedScreenLinks(aliases: Set<String>) -> some View {
        let revisions = Set(model.manifests(requiring: aliases).map(\.revision))
        let screens = model.installedScreens.filter { revisions.contains($0.revision) }
        if screens.isEmpty { Text("No installed screens use this connection.").foregroundStyle(.secondary) }
        ForEach(screens) { saved in
            NavigationLink(saved.displayName, value: ScreenSettingsRoute.screen(saved.id, owner: model.permissionOwner))
        }
    }

    private var customConnections: some View {
        let uses = model.customConnectionUses()
        let saved = model.savedCustomConnections
        let serviceIDs = Set(uses.map { $0.declaration.id }).union(saved.map(\.id))
        return Form {
            if serviceIDs.isEmpty { Text("No custom connections on this device.").foregroundStyle(.secondary) }
            ForEach(serviceIDs.sorted(), id: \.self) { id in
                let label = uses.first(where: { $0.declaration.id == id })?.declaration.label
                    ?? saved.first(where: { $0.id == id })?.label ?? id
                NavigationLink(model.connectionName(serviceID: id, fallback: label), value: ScreenSettingsRoute.sharedCustom(id, owner: model.permissionOwner))
            }
        }
    }

    @ViewBuilder private func sharedCustomConnection(_ serviceID: String, owner: String,
                                                     focus: DeviceModel.CustomConnectionUse? = nil) -> some View {
        let uses = model.customConnectionUses(serviceID: serviceID)
        if let use = focus ?? uses.first(where: { model.customConnectionStatus($0.declaration) != nil }) ?? uses.first {
            DeviceCustomConnectionSettings(model: model, use: use, owner: owner, focusScreen: focus?.id,
                                           deletionError: customConnectionError) {
                customConnectionError = nil
                customConnectionToRemove = .sharedCustom(serviceID, owner: owner)
            }
        } else if let saved = model.savedCustomConnections.first(where: { $0.id == serviceID }) {
            OrphanedCustomConnectionSettings(label: model.connectionName(serviceID: serviceID, fallback: saved.label),
                                             origin: saved.origin, error: customConnectionError) {
                customConnectionError = nil
                customConnectionToRemove = .sharedCustom(serviceID, owner: owner)
            }
        } else {
            Text("Connection unavailable")
        }
    }

    private func screenDetails(_ saved: ScreenLibrary.Saved, owner: String) -> some View {
        let manifest = model.installedManifests.first { $0.revision == saved.revision }
        let aliases = Set(manifest?.connections.map(\.alias) ?? [])
        let linked = model.linkedEditOptions(for: saved.id)
        return Form {
            Section {
                ScreenNameField(name: saved.displayName) { name in
                    try model.renameScreen(saved.id, to: name, owner: owner)
                } reportError: { renameError = $0 }
                .id(saved.id)
                if saved.id == model.screen?.id {
                    Button("Edit this screen with keyboard") { sheet = .editKeyboardRequest }
                        .disabled(model.routeChangeBlocked || model.accountOperationInProgress || linked?.blocksEditing == true)
                }
                if model.rollbackScreenID == saved.id && linked == nil {
                    Button("Restore previous version", action: model.rollback)
                }
            }
            if let linked { linkedScreenSettings(linked) }
            if let manifest {
                if manifest.connections.contains(where: { $0.publicHTTP != nil }) {
                    Section("Public Data") {
                        NavigationLink {
                            DevicePublicDataDetails(model: model, screenID: saved.id, owner: owner)
                        } label: {
                            LabeledContent("Public data access", value: model.publicDataAllowed(manifest) ? "Allowed" : "Off")
                        }
                    }
                }
                if aliases.contains("home") {
                    DeviceHomeAssistantScreenSettings(owner: owner, manifest: manifest, onChange: model.refreshConnections)
                    sharedLink(.home)
                }
                if !aliases.isDisjoint(with: ["googleCalendar", "google-calendar"]) {
                    DeviceGoogleCalendarScreenSettings(manifest: manifest, onChange: model.refreshConnections)
                    sharedLink(.calendar)
                }
                if aliases.contains("googleTV") { sharedLink(.television) }
            }
            let customUses = model.customConnectionUses().filter { $0.screen.id == saved.id }
            if !customUses.isEmpty {
                Section("Custom Connections") {
                    ForEach(customUses, id: \.alias) { use in
                        NavigationLink(value: ScreenSettingsRoute.custom(saved.id, alias: use.alias, owner: owner)) {
                            let label = model.connectionName(serviceID: use.declaration.id, fallback: use.declaration.label)
                            LabeledContent {
                                Text(model.customConnectionApproved(use) ? "Allowed" : "Approval required")
                                    .foregroundStyle(.secondary)
                            } label: {
                                Text(label).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            ScreenDataAccessSettings(model: model, screenID: saved.id)
            Section {
                Button("Delete from this device", role: .destructive) { screenToRemove = saved }
                    .disabled(model.busy)
            }
        }
        .navigationTitle(saved.displayName)
        .disabled(model.accountOperationInProgress)
    }

    @ViewBuilder private func linkedScreenSettings(_ linked: DeviceModel.LinkedEditOptions) -> some View {
        Section("Catalog Link") {
            LabeledContent("Shared version", value: "Version \(linked.version)")
            if let count = linked.deviceCount {
                LabeledContent("Linked iPads", value: String(count))
            }
            if linked.hasConflict {
                Text("Another iPad updated this screen. Your edit is saved on this iPad.")
                Button("Keep edit on this iPad") { resolveLinkedConflict(linked, keep: true) }
                    .disabled(model.routeChangeBlocked)
                    .accessibilityHint("Saves the edit as " + linked.forkName)
                Button("Discard this iPad’s edit", role: .destructive) { linkedConflictToDiscard = linked }
                    .disabled(model.routeChangeBlocked)
                if let linkedConflictError {
                    Text(linkedConflictError).foregroundStyle(.secondary)
                }
            } else if linked.pendingPublication {
                Text("Your changes are waiting to update the linked iPads.")
            }
        }
    }

    private func resolveLinkedConflict(_ options: DeviceModel.LinkedEditOptions, keep: Bool) {
        do {
            try model.resolveLinkedEditConflict(options, keepOnThisIPad: keep)
            linkedConflictError = nil
            if keep { path.removeAll() }
        } catch { linkedConflictError = error.localizedDescription }
    }

    private func sharedLink(_ provider: DeviceSettingsPage) -> some View {
        NavigationLink(value: ScreenSettingsRoute.shared(provider)) {
            Label("Shared connection · " + provider.rawValue, systemImage: provider.symbol)
        }
    }
}

let screenpunkSignInTitle = "Sign in, or create a Screenpunk account"

private struct ProviderPicker<Options: View>: View {
    let title: String
    let dismissLabel: String
    let close: () -> Void
    @ViewBuilder let buttons: () -> Options

    var body: some View {
        if #available(iOS 18, *) {
            content.presentationSizing(.fitted)
        } else {
            content.presentationDetents([.medium, .large])
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSheetHeader(title: title, dismissLabel: dismissLabel, close: close)
            ProviderButtons(buttons: buttons)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .frame(idealWidth: 420, maxWidth: 420)
    }

}

private struct ProviderButtons<Options: View>: View {
    @ViewBuilder let buttons: () -> Options

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 8) {
                options.buttonStyle(.glass)
            }
        } else {
            options.buttonStyle(.bordered)
        }
    }

    private var options: some View {
        VStack(spacing: 12) { buttons() }
            .controlSize(.large)
            .padding(.vertical, 24)
    }
}

private struct CloudPluginPicker: View {
    @ScaledMetric(relativeTo: .body) private var logoSize: CGFloat = 22
    let showChatGPT: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            buttons.fixedSize(horizontal: true, vertical: false)
            buttons
        }
        .frame(maxWidth: .infinity)
    }

    private var buttons: some View {
        ProviderButtons {
            option("ChatGPT instructions", logo: "openai", action: showChatGPT)
            option("Grokbot instructions (coming soon)", logo: "grokbot") {}
                .disabled(true)
        }
    }

    private func option(_ title: String, logo: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let path = Bundle.main.path(forResource: logo, ofType: "png", inDirectory: "OnboardingAssets"),
                   let symbol = UIImage(contentsOfFile: path) {
                    Image(uiImage: symbol).renderingMode(.template).resizable().scaledToFit()
                        .frame(width: logoSize, height: logoSize)
                        .accessibilityHidden(true)
                }
                Text(title).font(.body.weight(.medium))
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        }
    }
}

private struct AccountCreationAlert: ViewModifier {
    @ObservedObject var model: DeviceModel
    let isHost: Bool
    @State private var selectedProvider: CloudSignInProvider?
    @ScaledMetric(relativeTo: .body) private var logoSize: CGFloat = 22

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { isHost && model.choosingSignInProvider },
            set: { if isHost { model.choosingSignInProvider = $0 } }
        ), onDismiss: {
            guard let provider = selectedProvider else { return }
            selectedProvider = nil
            Task { await model.signIn(provider: provider) }
        }) {
            signInOptions
        }
        .alert("Create a new Screenpunk account?", isPresented: Binding(
            get: { isHost && model.accountCreationEmail != nil },
            set: { _ in }
        )) {
            Button("Create New Account") { model.resolveAccountCreation(true) }
            Button("Cancel", role: .cancel) { model.resolveAccountCreation(false) }
        } message: {
            Text("Create a new Screenpunk account with \(model.accountCreationEmail ?? "this Apple Account")?")
        }
    }

    private var signInOptions: some View {
        ProviderPicker(title: screenpunkSignInTitle, dismissLabel: "Cancel", close: {
            model.choosingSignInProvider = false
        }) {
            providerOption(.apple, title: "Continue with Apple")
            providerOption(.google, title: "Continue with Google")
        }
    }

    private func providerOption(_ provider: CloudSignInProvider, title: String) -> some View {
        Button {
            selectedProvider = provider
            model.choosingSignInProvider = false
        } label: {
            HStack(spacing: 14) {
                Group {
                    if provider == .apple {
                        Image(systemName: "apple.logo").resizable()
                    } else if let path = Bundle.main.path(forResource: "google-g.png", ofType: nil,
                                                          inDirectory: "OnboardingAssets"),
                              let logo = UIImage(contentsOfFile: path) {
                        Image(uiImage: logo).renderingMode(.original).resizable()
                    }
                }
                .scaledToFit().frame(width: logoSize, height: logoSize)
                .accessibilityHidden(true)
                Text(title).font(.body.weight(.medium))
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        }
        .foregroundStyle(.primary)
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
            Toggle("Back up screens on this device", isOn: Binding(
                get: { model.catalogBackupsEnabled },
                set: { enabled in
                    if enabled, model.catalogBackupAccess == .inactive { showUpgrade = true }
                    else { model.setCatalogBackupsEnabled(enabled) }
                }
            ))
            .disabled(!model.catalogBackupsCanConfigure)

            if !model.catalogBackupsCanConfigure, model.email == nil {
                Text("Go to Account and sign in to Screenpunk to enable backups.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.catalogBackupsEnabled {
                if let status = model.presentedInlineMessage(.backup) {
                    DismissibleMessage(status.text, onDismiss: { model.dismissInlineMessage(.backup, id: status.id) }).id(status.id).font(.footnote)
                }
                if let status = model.presentedInlineMessage(.preview) {
                    DismissibleMessage(status.text, onDismiss: { model.dismissInlineMessage(.preview, id: status.id) }).id(status.id).font(.footnote)
                }
                if model.catalogCanResume {
                    Button("Resume backups with current screens") { confirmResume = true }
                }
            }
        } header: {
            Text("Screen backups")
        } footer: {
            if model.catalogBackupsCanConfigure, model.catalogBackupAccess == .unknown {
                Text("Backups are paused until Screenpunk can verify your plan.")
            } else if model.catalogBackupsCanConfigure {
                Text("Save current screens, screenshots, and future edits to your Screenpunk account. Turning this off keeps existing backups.")
            } else if model.email != nil {
                Text("Backups require a connected Cloud library.")
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
            if let price = model.billing.offer(.proAnnual, for: model.cloud)?.product.displayPrice {
                Text("Back up screens with Screenpunk Pro for \(price) per year. Review the plan in Account → Plan.")
            } else {
                Text("Screen backups require Screenpunk Pro. Review the plan in Account → Plan.")
            }
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
    var lookingForListener = false
    private var caption: String {
        if lookingForListener { return "Looking for ChatGPT plugin listener…" }
        return connected == false ? "Waiting for plugin connection…" : "Checking plugin connection…"
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

private struct CatalogScreenPicker: View {
    @ObservedObject var model: DeviceModel
    @Environment(\.dismiss) private var dismiss
    @State private var screens: [CatalogScreen] = []
    @State private var loading = true
    @State private var addingID: String?
    @State private var errorMessage: String?
    @State private var reload = UUID()
    @State private var addedCount = 0
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.secondary)
                        Button("Try again") { reload = UUID() }.disabled(addingID != nil)
                    }
                }
                if loading {
                    ProgressView("Loading your catalog…")
                } else if screens.isEmpty && errorMessage == nil {
                    Text(addedCount > 0 ? "All available screens have been added to this device." : "No screens to add. Your catalog is empty or all its screens are already on this device.")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(screens, id: \.catalogScreenID) { screen in
                            Button {
                                addingID = screen.catalogScreenID
                                errorMessage = nil
                                importTask = Task {
                                    defer { addingID = nil }
                                    do {
                                        try await model.addCatalogScreen(screen)
                                        screens.removeAll { $0.catalogScreenID == screen.catalogScreenID }
                                        addedCount += 1
                                    } catch is CancellationError { }
                                    catch { errorMessage = error.localizedDescription }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(screen.latest.screenName).foregroundStyle(.primary)
                                        Text("Version \(screen.latest.displayVersion) · \(screen.latest.deviceDisplayName)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if addingID == screen.catalogScreenID { ProgressView() }
                                    else { Image(systemName: "plus.circle") }
                                }
                            }
                            .disabled(addingID != nil || !model.canAddCatalogScreen)
                            .accessibilityLabel("Add \(screen.latest.screenName) to this device")
                        }
                    } footer: {
                        Text(model.catalogPickerFollowsUpdates
                             ? "Screens added here follow shared updates. You can make a separate copy when you edit on this iPad."
                             : "Adds the latest saved version. Connections may need to be set up on this device.")
                    }
                }
            }
            .navigationTitle("My catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: reload) {
                loading = true; errorMessage = nil
                defer { loading = false }
                do { screens = try await model.availableCatalogScreens() }
                catch is CancellationError { }
                catch { errorMessage = error.localizedDescription }
            }
        }
        .onDisappear { importTask?.cancel() }
        .onChange(of: model.keyboardRequestScope) { _ in importTask?.cancel(); dismiss() }
    }
}

private struct KeyboardRequestEditor: View {
    @ObservedObject var model: DeviceModel
    let creatingNew: Bool
    let owner: String
    let screenID: String?
    let revision: String?
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var submitted = false
    @State private var linkedEdit: ScreenLibrary.LinkedCatalogEditScope?
    @FocusState private var instructionsFocused: Bool

    init(model: DeviceModel, creatingNew: Bool) {
        self.model = model; self.creatingNew = creatingNew
        owner = model.keyboardRequestScope
        screenID = creatingNew ? nil : model.screen?.id
        revision = creatingNew ? nil : model.screen?.revision
        _text = State(initialValue: model.keyboardDraft(owner: model.keyboardRequestScope, screenID: creatingNew ? nil : model.screen?.id))
    }
    var body: some View {
        let options = model.linkedEditOptions(for: screenID)
        NavigationStack {
            Form {
                Section(creatingNew ? "Describe a new screen" : "Describe your changes") {
                    TextEditor(text: $text)
                        .focused($instructionsFocused)
                        .frame(minHeight: 200)
                        .accessibilityLabel("Screen instructions")
                        .accessibilityIdentifier("request.instructions")
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && KeyboardRequestText.normalized(text) == nil { DismissibleMessage("Please shorten your instructions. Your draft is kept.") }
                }
                if let message = model.presentedStatusMessage {
                    DismissibleMessage(message.text, onDismiss: { model.dismissStatusMessage(id: message.id) }).id(message.id)
                }
                if let options {
                    Section {
                        Picker("Apply changes to", selection: $linkedEdit) {
                            Text("Choose").tag(nil as ScreenLibrary.LinkedCatalogEditScope?)
                            Text(options.updateAllTitle).tag(ScreenLibrary.LinkedCatalogEditScope?.some(.all))
                            Text("Only this iPad").tag(ScreenLibrary.LinkedCatalogEditScope?.some(.thisDevice))
                        }
                        .accessibilityIdentifier("request.linkedEditScope")
                    } footer: {
                        if linkedEdit == .thisDevice {
                            Text("This iPad will use “\(options.forkName)”. Other iPads keep the linked screen.")
                        }
                    }
                }
            }
            .navigationTitle(creatingNew ? "New screen" : "Edit screen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        if model.submitKeyboardRequest(text, owner: owner, screenID: screenID, revision: revision,
                                                       creatingNew: creatingNew, linkedEdit: linkedEdit) {
                            submitted = true; dismiss()
                        }
                    }
                    .disabled(submitted || KeyboardRequestText.normalized(text) == nil || model.busy || model.requestPending || model.routeChangeBlocked || model.accountOperationInProgress ||
                              model.keyboardRequestScope != owner || options?.blocksEditing == true || (options != nil && linkedEdit == nil))
                    .accessibilityIdentifier("request.send")
                }
            }
        }
        .task { instructionsFocused = true }
        .onChange(of: text) { model.saveKeyboardDraft($0, owner: owner, screenID: screenID) }
        .onDisappear { model.persistKeyboardDraft(text, owner: owner, screenID: screenID) }
    }
}

private struct RequestStatusPill: View {
    @ObservedObject var model: DeviceModel
    @ObservedObject var speech: SpeechCapture
    let maximumTextHeight: CGFloat
    var body: some View {
        let message = model.presentedStatusMessage
        let speechError = speech.presentedError
        let presentationID = speechError?.id ?? message?.id
        let dismissible = speechError != nil || model.canDismissStatusMessage
        VStack(spacing: 12) {
            if let accountStatus = model.accountStatusCaption {
                ShimmeringStatusCaption(caption: accountStatus)
            } else if !model.accountOperationInProgress && (model.requestPending || model.busy) {
                if let agent = model.resolvedAgentName { Text(agent).font(.caption).foregroundStyle(.secondary) }
                ShimmeringStatusCaption(caption: model.takingLonger ? "Taking longer than expected" : model.progressCaption)
                HStack(spacing: 20) {
                    if model.takingLonger { Button("Keep waiting", action: model.keepWaiting) }
                    if model.canCancelRequest { Button("Cancel", role: .cancel, action: model.cancelRequest) }
                }.buttonStyle(.bordered)
            } else {
                if model.canRetry { Button("Retry", action: model.retryRequest).buttonStyle(.bordered).disabled(model.busy) }
                if model.canCancelRequest { Button("Cancel saved request", role: .cancel, action: model.cancelRequest).buttonStyle(.bordered) }
            }
            if let text = speechError?.text ?? message?.text { statusText(text) }
            if model.linkedEditOptions(for: model.screen?.id)?.hasConflict == true {
                Button("Review shared edit", action: model.openConnectionSettings)
                    .buttonStyle(.borderedProminent)
            }
            if dismissible, let id = presentationID {
                Button { dismissMessage(id: id) } label: {
                    Label("Dismiss", systemImage: "xmark").frame(minWidth: 80, minHeight: 44)
                }
                .id(id)
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Dismiss message")
                .accessibilityHint("Hides this message. Your screen stays unchanged.")
            }
        }
        .modifier(StatusPillAppearance())
        // Consume card taps without dismissing. Touches never pass through to
        // the screen below; only a deliberate swipe or Dismiss action hides it.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { })
        .background(DeviceStatusInteractionRegion(presentationID: presentationID, dismissalEnabled: dismissible, onDismiss: dismissMessage))
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) {
            if dismissible, let id = presentationID { dismissMessage(id: id) }
        }
    }
    private func dismissMessage(id: UUID) {
        if speech.presentedError != nil { speech.dismissError(id: id) }
        else { model.dismissStatusMessage(id: id) }
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
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Acknowledgement is local presentation state. It never changes the failed
/// operation, account, permission, purchase, saved draft or recovery controls.
struct DismissibleMessage: View {
    let text: String
    let color: Color
    let onDismiss: (() -> Void)?
    @State private var presentation: StatusMessagePresentationState

    init(_ text: String, color: Color = .secondary, onDismiss: (() -> Void)? = nil) {
        self.text = text; self.color = color; self.onDismiss = onDismiss
        var state = StatusMessagePresentationState(); state.update(text)
        _presentation = State(initialValue: state)
    }
    var body: some View {
        Group {
            if let message = presentation.presentedMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.text).foregroundStyle(color).textSelection(.enabled)
                    Button("Dismiss") { dismiss(message.id) }
                        .accessibilityLabel("Dismiss message")
                }
                .accessibilityElement(children: .contain)
                .accessibilityAction(.escape) { dismiss(message.id) }
            }
        }
        .onChange(of: text) { presentation.update($0) }
    }
    private func dismiss(_ id: UUID) {
        if presentation.dismiss(id: id, busy: false, requestPending: false,
                                routeChangeBlocked: false, canRetry: false, canCancelRequest: false) { onDismiss?() }
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
