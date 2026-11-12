import Foundation
import Darwin
import ScreenpunkApple
import ScreenpunkCore

/// One atomic metadata replacement commits an installation. Failed writes never replace the current screen.
@MainActor final class ScreenLibrary {
    static let instructionsID = "screenpunk.instructions"
    enum Onboarding: String, Codable {
        case connectAgent, gallery, complete

        static func agentIsReady(route: AuthoringRoutePreference, verifiedLocal: Bool, cloudListenerConnected: Bool) -> Bool {
            switch route {
            case .local: return verifiedLocal
            case .cloud: return cloudListenerConnected
            case .automatic: return verifiedLocal || cloudListenerConnected
            }
        }
    }
    var needsAgentSetup: Bool { state.onboarding == .connectAgent }
    var galleryIntroPending: Bool { state.onboarding == .gallery }
    var temporaryActivationID: String? { temporary.activeActivationID }
    var hasTemporaryScreen: Bool { state.selectedID.map { temporary.isActiveTarget($0) } ?? false }
    var rotationIDs: [String] { needsAgentSetup ? [Self.instructionsID] : state.screens.map(\.id) + [Self.instructionsID] }
    var instructionsSelected: Bool { state.selectedID == Self.instructionsID || (state.selectedID == nil && isScreenShown(Self.instructionsID)) }
    func containsRotationScreen(_ id: String) -> Bool { id == Self.instructionsID || state.screens.contains { $0.id == id } }

    struct Saved: Codable, Identifiable { let id: String; let revision: String; let artifact: ScreenArtifact }
    struct State: Codable { var screens: [Saved] = []; var selectedID: String?; var previous: Saved?; var lastRequest: String?; var pendingID: String?; var pendingScreenID: String?; var consumedID: String?; var cancelledRequests: [String]?; var cancelIntents: [String]?; var lastInstruction: String?; var submissionKey: String?; var submissionText: String?; var submissionScreen: ScreenArtifact?; var requestDeadline: Double?; var authoring: AuthoringStoreState?; var linkedProfile: LocalProfileDescriptor?; var localRequestIDs: Set<String>?; var bundledScreenSeeds: Set<String>?; var catalog: CatalogQueue?; var hiddenScreenIDs: Set<String>?; var onboarding: Onboarding?; var publicDataRevocations: Set<String>?; var screenDataGenerations: [String: String]? }
    private(set) var state = State()
    var onCatalogRevisionCommitted: (() -> Void)?
    private let root: URL
    let screenDataArchive: DeviceScreenDataArchive
    private let screenDataLocalDeviceIds: Set<String>
    private let libraryOwner: String
    private var approvalOwner: String
    private let catalogDefaults: UserDefaults
    private var catalogBackupScope: CatalogBinding?
    private var catalogBackupValidUntil: Date?
    private var catalogConsentGeneration = UUID()
    private var catalogCapabilityChecked = false
    private var temporary: LocalTemporaryActivationController!
    private var journal: AuthoringJournal!
    init(accountID: String, rootDirectory: URL? = nil, permissionOwner: String? = nil, catalogDefaults: UserDefaults = .standard, journalFault: AuthoringJournal.Fault? = nil, onboardNewLibrary: Bool = false, screenDataLocalDeviceIds: Set<String> = []) throws {
        self.screenDataLocalDeviceIds = screenDataLocalDeviceIds
        libraryOwner = accountID
        approvalOwner = permissionOwner ?? accountID
        self.catalogDefaults = catalogDefaults
        root = try rootDirectory ?? Self.directory(for: accountID)
        screenDataArchive = DeviceScreenDataArchive(root: root)
        let discarded = Self.discardedDirectory(for: root)
        if FileManager.default.fileExists(atPath: discarded.path),
           let data = try AuthoringJournal(root: discarded).recover() {
            let deleted = try Self.decodeState(data)
            PublicDataApprovalStore(defaults: catalogDefaults).forget(owner: approvalOwner,
                dashboardIDs: Self.publicDashboardIDs(deleted.screens + [deleted.previous].compactMap { $0 }).union(deleted.publicDataRevocations ?? []))
        }
        try Self.removeIfPresent(discarded)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        journal = try AuthoringJournal(root: root, fault: journalFault)
        if let data = try journal.recover() {
            state = try Self.decodeState(data)
        } else if onboardNewLibrary {
            var next = state
            next.onboarding = .connectAgent
            next.selectedID = Self.instructionsID
            try commit(next)
        }
        if state.screenDataGenerations == nil, !state.screens.isEmpty {
            try commit(state, captureCatalog: false)
        }
        reconcileScreenDataArchive()
        try flushPublicDataRevocations()
        try retireCancelledLocalSources()
        temporary = try LocalTemporaryActivationController(root: root, owner: accountID)
        try reconcileTemporary()
        // Recover the index (including unresolved pins) before any startup pruning.
        pruneUnusedRevisions()
    }
    convenience init(profile: LocalProfileDescriptor, rootDirectory: URL? = nil, journalFault: AuthoringJournal.Fault? = nil, onboardNewLibrary: Bool = false) throws {
        try self.init(accountID: profile.libraryOwner, rootDirectory: rootDirectory, permissionOwner: profile.permissionOwner, journalFault: journalFault, onboardNewLibrary: onboardNewLibrary, screenDataLocalDeviceIds: [profile.localDeviceID, profile.authoringDeviceID])
    }

    struct ScreenDataInstallation {
        let screen: Saved
        let generation: String
        let declarations: ManifestScreenData

        func target(exportName: String) -> DeviceScreenDataTarget {
            .init(screenId: screen.id, revision: screen.revision, generation: generation, exportName: exportName)
        }
    }

    func screenDataInstallation(_ id: String) -> ScreenDataInstallation? {
        guard let screen = state.screens.first(where: { $0.id == id }),
              let generation = state.screenDataGenerations?[id],
              let file = screen.artifact.files.first(where: { $0.path == "manifest.json" }),
              let manifest = try? JSONDecoder().decode(DashboardManifest.self, from: Data(file.content.utf8)),
              let declarations = manifest.screenData,
              (try? PackageValidator.validate(manifest)) != nil else { return nil }
        return .init(screen: screen, generation: generation, declarations: declarations)
    }

    func screenDataPermission(owner: String, target: DeviceScreenDataTarget, reader: DeviceScreenDataReader) throws -> DeviceScreenDataPermission {
        guard let installed = screenDataInstallation(target.screenId), installed.target(exportName: target.exportName) == target,
              let declaration = installed.declarations.exports.first(where: { $0.name == target.exportName }) else { throw ScreenDataError.notFound }
        return .init(key: .init(owner: owner, target: target, reader: reader.identity), targetTitle: installed.screen.artifact.title,
                     exportDescription: declaration.description, readerLabel: reader.label, decision: .denied)
    }

    func publishScreenData(owner: String, target: DeviceScreenDataTarget, value: AuthoringJSONValue?) throws {
        guard let installed = screenDataInstallation(target.screenId), installed.target(exportName: target.exportName) == target,
              installed.declarations.exports.contains(where: { $0.name == target.exportName }) else { throw ScreenDataError.permissionRequired }
        try screenDataArchive.publish(owner: owner, target: target, value: value)
    }

    private static func directory(for owner: String, librariesDirectory: URL? = nil) throws -> URL {
        let parent = try librariesDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ScreenpunkScreens", isDirectory: true)
        let name = Data(owner.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return parent.appendingPathComponent(name, isDirectory: true)
    }

    private static func discardedDirectory(for root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent(".discarded-" + root.lastPathComponent, isDirectory: true)
    }

    private static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
    }

    static func deleteAccountScreens(accountID: String, profile: LocalProfileDescriptor?, librariesDirectory: URL? = nil, approvalDefaults: UserDefaults = .standard) throws {
        let owner = profile?.libraryOwner ?? accountID
        guard !accountID.isEmpty, !accountID.hasPrefix("local:"), !owner.isEmpty,
              profile == nil || profile?.cloudBinding?.accountID == accountID ||
                (profile?.cloudBinding == nil && owner == accountID && profile?.permissionOwner == accountID) else {
            throw DeviceError.message("The saved screens belong to a different account.")
        }
        let root = try directory(for: owner, librariesDirectory: librariesDirectory)
        let discarded = discardedDirectory(for: root)
        // Inspect only the selected library before explicit deletion, never unrelated profiles.
        var dashboards = Set<String>()
        for directory in [root, discarded] where FileManager.default.fileExists(atPath: directory.path) {
            if let data = try AuthoringJournal(root: directory).recover() {
                let state = try Self.decodeState(data)
                let pending = Self.publicDashboardIDs(state.screens + [state.previous].compactMap { $0 }).union(state.publicDataRevocations ?? [])
                dashboards.formUnion(pending)
                if directory == discarded {
                    PublicDataApprovalStore(defaults: approvalDefaults).forget(owner: profile?.permissionOwner ?? accountID, dashboardIDs: pending)
                }
            }
        }
        try removeIfPresent(discarded)
        // Move the journal and its assets together so an interrupted removal cannot reopen a partial library.
        do { try FileManager.default.moveItem(at: root, to: discarded) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            PublicDataApprovalStore(defaults: approvalDefaults).forget(owner: profile?.permissionOwner ?? accountID, dashboardIDs: dashboards)
            return
        }
        PublicDataApprovalStore(defaults: approvalDefaults).forget(owner: profile?.permissionOwner ?? accountID, dashboardIDs: dashboards)
        try removeIfPresent(discarded)
    }

    private func flushPublicDataRevocations() throws {
        guard let pending = state.publicDataRevocations, !pending.isEmpty else { return }
        PublicDataApprovalStore(defaults: catalogDefaults).forget(owner: approvalOwner, dashboardIDs: pending)
        var next = state; next.publicDataRevocations = nil
        try commit(next, captureCatalog: false)
    }

    private static func publicDashboardIDs(_ screens: [Saved]) -> Set<String> {
        Set(screens.compactMap { saved in
            guard let file = saved.artifact.files.first(where: { $0.path == "manifest.json" }),
                  let manifest = try? JSONDecoder().decode(DashboardManifest.self, from: Data(file.content.utf8)) else { return nil }
            return manifest.dashboardId
        })
    }

    var linkedProfile: LocalProfileDescriptor? { state.linkedProfile }
    /// Explicit native migration: owner paths and screen IDs stay fixed. The descriptor is
    /// the authoritative recovery receipt if the separate profile index adoption is interrupted.
    func linkLocalProfile(_ profile: LocalProfileDescriptor, to binding: LocalCloudBinding) throws -> LocalProfileDescriptor {
        if let linked = state.linkedProfile {
            guard linked.id == profile.id, linked.cloudBinding == binding else { throw DeviceError.message("This library is already linked to another Cloud profile.") }
            return linked
        }
        guard profile.libraryOwner == libraryOwner, profile.cloudBinding == nil, !binding.accountID.isEmpty, !binding.profileID.isEmpty, !binding.deviceID.isEmpty else { throw DeviceError.message("Only an unlinked local profile can be explicitly linked.") }
        let captured = state.authoring?.requests ?? [:]
        guard state.authoring?.requestsV2?.isEmpty != false else { throw DeviceError.message("Resolve pending authoring before linking this profile.") }
        let changesPreferenceTargets = state.authoring?.records.values.contains { record in
            (record.scope == "profile" && record.targetID == profile.id && record.targetID != binding.profileID) ||
            (record.scope == "device" && record.targetID == profile.localDeviceID && record.targetID != binding.deviceID)
        } ?? false
        let exactCloudSnapshot: (AuthoringRequestV1) -> Bool = {
            $0.delivery.route == "cloud" && $0.context.profileID == binding.profileID && $0.context.deviceID == binding.deviceID
        }
        let pendingIDs = [state.pendingID, state.submissionKey].compactMap { $0 }
        let confirmsExistingAccount = profile.libraryOwner == binding.accountID && profile.permissionOwner == binding.accountID && !changesPreferenceTargets &&
            captured.values.allSatisfy(exactCloudSnapshot) && pendingIDs.allSatisfy { id in captured[id].map(exactCloudSnapshot) ?? false }
        guard confirmsExistingAccount || (state.pendingID == nil && state.submissionKey == nil && captured.isEmpty) else { throw DeviceError.message("Resolve pending authoring before linking this profile.") }
        var linked = profile; linked.cloudBinding = binding
        var next = state; var authoring = next.authoring ?? .init()
        guard confirmsExistingAccount || authoring.conflicts.isEmpty else { throw DeviceError.message("Resolve preference conflicts before linking this profile.") }
        let origin = "link-" + UUID().uuidString
        for original in Array(authoring.records.values) {
            var record = original
            if record.scope == "profile", record.targetID == profile.id, record.targetID != binding.profileID { record.targetID = binding.profileID }
            else if record.scope == "device", record.targetID == profile.localDeviceID, record.targetID != binding.deviceID { record.targetID = binding.deviceID }
            else { continue }
            guard authoring.cloudRevisions[record.id] == nil else { throw DeviceError.message("A Cloud-owned preference cannot be rebound to another account.") }
            record.revision += 1; record.originRequestID = origin
            _ = try AuthoringContract.validatePreferenceRecord(JSONEncoder().encode(record))
            authoring.records[record.id] = record
            authoring.outbox.removeAll { $0.record.id == record.id }
            if !record.deleted { authoring.outbox.append(.init(id: UUID().uuidString, record: record, baseCloudRevision: nil)) }
        }
        next.authoring = authoring; next.linkedProfile = linked
        try commit(next); return linked
    }
    var selected: Saved? {
        guard !needsAgentSetup || hasTemporaryScreen else { return nil }
        return state.screens.first { $0.id == state.selectedID }
    }

    func finishAgentSetup() throws {
        guard needsAgentSetup, !hasTemporaryScreen else { return }
        var next = state
        next.onboarding = .gallery
        next.selectedID = Self.instructionsID
        try commit(next)
    }

    #if DEBUG
    private struct GuideResetReceipt: Encodable {
        let stage: Onboarding
        let libraryMetadataPreserved: Bool
        let screensPreserved: Bool
        let selectionPreserved: Bool
        let showPreferencesPreserved: Bool
        let backupConsentPreserved: Bool
    }

    func restartGuideForTesting(receiptURL: URL? = nil) throws {
        let before = state
        var expected = before
        expected.onboarding = .connectAgent
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expectedBytes = try encoder.encode(expected)
        // Write exactly the reset state. Regular commits may also prune catalog metadata.
        try persist(expected, encoded: expectedBytes)
        let receipt = GuideResetReceipt(
            stage: .connectAgent,
            libraryMetadataPreserved: expectedBytes == (try encoder.encode(state)),
            screensPreserved: before.screens.map(\.id) == state.screens.map(\.id) &&
                before.screens.map(\.revision) == state.screens.map(\.revision),
            selectionPreserved: before.selectedID == state.selectedID,
            showPreferencesPreserved: before.hiddenScreenIDs == state.hiddenScreenIDs,
            backupConsentPreserved: before.catalog?.captureAllowed == state.catalog?.captureAllowed
        )
        if let receiptURL { try encoder.encode(receipt).write(to: receiptURL, options: .atomic) }
    }
    #endif

    func dismissGalleryIntro() throws {
        guard galleryIntroPending else { return }
        var next = state
        next.onboarding = .complete
        try commit(next)
    }
    func store(for screen: Saved) throws -> PackageAssetStore { try PackageAssetStore.load(directory: root.appendingPathComponent(screen.revision)) }
    func install(_ artifact: ScreenArtifact, requestID: String, replacing id: String?, selectInstalled: Bool = true, preserveRequestHistory: Bool = false) throws {
        guard state.lastRequest != requestID else { return }
        guard !(state.cancelledRequests ?? []).contains(requestID), !(state.authoring?.cancelledRequestIDs ?? []).contains(requestID) else { throw DeviceError.message("This request was cancelled on this device.") }
        try Self.validate(artifact)
        let revision = UUID().uuidString
        let directory = root.appendingPathComponent(revision, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var committing = false
        do {
            for file in artifact.files {
                let url = directory.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(file.content.utf8).write(to: url, options: .atomic)
            }
            _ = try PackageAssetStore.load(directory: directory)
            var next = state
            let saved = Saved(id: id ?? UUID().uuidString, revision: revision, artifact: artifact)
            if let position = next.screens.firstIndex(where: { $0.id == saved.id }) { next.previous = next.screens[position]; next.screens[position] = saved }
            else { next.screens.append(saved) }
            if selectInstalled && selectsInstalledRevision(saved.id) { next.selectedID = saved.id }
            if !preserveRequestHistory { next.lastRequest = requestID }
            committing = true
            try commit(next, stagedDirectory: revision)
            pruneUnusedRevisions()
        } catch { if !committing { try? FileManager.default.removeItem(at: directory) }; throw error }
    }
    /// Upgrade only the exact pristine shipped Weather package. A committed replacement
    /// is recognizable on retry; edited/configured/deleted screens are never recreated.
    func migratePristineWeatherIfNeeded() throws {
        guard state.pendingID == nil, state.submissionKey == nil,
              let index = state.screens.firstIndex(where: { $0.id == "starter-weather" }),
              let artifact = try StarterWeather.migrateOriginalIfNeeded(state.screens[index].artifact) else { return }
        let revision = UUID().uuidString
        let directory = root.appendingPathComponent(revision, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var committing = false
        do {
            try Self.validate(artifact)
            for file in artifact.files {
                let url = directory.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(file.content.utf8).write(to: url, options: .atomic)
            }
            _ = try PackageAssetStore.load(directory: directory)
            var next = state
            next.screens[index] = Saved(id: state.screens[index].id, revision: revision, artifact: artifact)
            committing = true
            try commit(next, stagedDirectory: revision, captureCatalog: false)
            pruneUnusedRevisions()
        } catch {
            if !committing { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }

    /// Seed once per library. A durable per-template marker survives edits/removal;
    /// an interrupted first install resumes only its missing templates.
    func installStarterScreensIfNeeded(_ templates: [StarterScreens.Template]) throws {
        guard state.pendingID == nil, state.submissionKey == nil else { return }
        if state.bundledScreenSeeds == nil {
            var next = state
            // Add beside existing screens, preserving their selection and revisions.
            next.bundledScreenSeeds = []
            try commit(next)
        }
        // An installation marker needs an installed copy or a removal tombstone.
        // Repair an interrupted/older initialization without resurrecting removed screens.
        let installedOrRemoved = Set(state.screens.map(\.id)).union(state.authoring?.knownScreenIDs ?? [])
        let uninstalled = (state.bundledScreenSeeds ?? []).subtracting(installedOrRemoved)
        if !uninstalled.isEmpty {
            var next = state; next.bundledScreenSeeds?.subtract(uninstalled); try commit(next)
        }
        for template in templates where !(state.bundledScreenSeeds ?? []).contains(template.id) {
            if state.screens.contains(where: { $0.id == template.id }) {
                var next = state; next.bundledScreenSeeds?.insert(template.id); try commit(next)
                continue // Never replace an existing, potentially edited copy.
            }
            try Self.validate(template.artifact)
            let revision = UUID().uuidString
            let directory = root.appendingPathComponent(revision, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var committing = false
            do {
                for file in template.artifact.files {
                    let url = directory.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(file.content.utf8).write(to: url, options: .atomic)
                }
                _ = try PackageAssetStore.load(directory: directory)
                var next = state
                next.screens.append(Saved(id: template.id, revision: revision, artifact: template.artifact))
                if next.screens.count == 1 && next.selectedID == nil { next.selectedID = template.id }
                next.bundledScreenSeeds?.insert(template.id)
                committing = true
                try commit(next, stagedDirectory: revision, captureCatalog: false)
                pruneUnusedRevisions()
            } catch {
                if !committing { try? FileManager.default.removeItem(at: directory) }
                throw error
            }
        }
    }
    func savePending(id: String?, screenID: String?, consumedID: String?) throws {
        var next = state; next.pendingID = id; next.pendingScreenID = screenID; next.consumedID = consumedID; try commit(next)
    }
    func saveInstruction(_ text: String) throws { var next = state; next.lastInstruction = text; try commit(next) }
    func saveSubmission(key: String, text: String, screen: ScreenArtifact?) throws {
        var next = state; next.submissionKey = key; next.submissionText = text; next.submissionScreen = screen; next.lastInstruction = text; try commit(next)
    }
    func submissionAccepted(deadline: Double?) throws {
        var next = state; next.submissionKey = nil; next.submissionText = nil; next.submissionScreen = nil; next.requestDeadline = deadline; try commit(next)
    }
    func saveDeadline(_ deadline: Double) throws { var next = state; next.requestDeadline = deadline; try commit(next) }
    func cancelRequest(_ id: String, route: AuthoringRoute? = nil) throws {
        var next = state
        next.cancelledRequests = Array(((next.cancelledRequests ?? []).filter { $0 != id } + [id]).suffix(100))
        let savedRoute = state.authoring?.requests[id]?.delivery.route ?? state.authoring?.requestsV2?[id]?.delivery.route
        // The coordinator persists cancellation again before remote interruption.
        // Source retirement must not erase the request's durable Local route.
        let resolvedRoute = savedRoute.flatMap(AuthoringRoute.init(rawValue:)) ?? ((state.localRequestIDs ?? []).contains(id) ? .local : route ?? .cloud)
        if resolvedRoute == .cloud { next.cancelIntents = Array(Set((next.cancelIntents ?? []) + [id])) }
        else { next.cancelIntents?.removeAll { $0 == id } }
        if resolvedRoute == .local { clearTerminalDelivery(id, in: &next) }
        else if next.pendingID == id { next.pendingID = nil }
        next.consumedID = id
        // The cancellation tombstone and pin release are durable together, even while Cloud acknowledgement is uncertain.
        var authoring = next.authoring ?? .init()
        authoring.cancelledRequestIDs = (authoring.cancelledRequestIDs ?? []).union([id])
        if resolvedRoute == .local { AuthoringStore.retireRequest(id: id, in: &authoring) }
        else { authoring.revisionPins?.removeValue(forKey: id) }
        next.authoring = authoring
        try commit(next)
        pruneUnusedRevisions()
    }
    /// Earlier versions released Local pins but retained cancelled source snapshots.
    /// Their durable tombstones prove that these sources can never apply again.
    private func retireCancelledLocalSources() throws {
        guard var authoring = state.authoring else { return }
        let cancelled = (authoring.cancelledRequestIDs ?? []).union(state.cancelledRequests ?? [])
        let local = Set(authoring.requests.values.filter { $0.delivery.route == "local" }.map(\.requestID))
            .union(authoring.requestsV2?.values.filter { $0.delivery.route == "local" }.map(\.requestID) ?? [])
        let retired = cancelled.intersection(local)
        guard !retired.isEmpty else { return }
        for id in retired { AuthoringStore.retireRequest(id: id, in: &authoring) }
        authoring.cancelledRequestIDs = (authoring.cancelledRequestIDs ?? []).union(retired)
        var next = state; next.authoring = authoring
        next.localRequestIDs = (next.localRequestIDs ?? []).union(retired)
        next.cancelIntents?.removeAll { retired.contains($0) }
        for id in retired { clearTerminalDelivery(id, in: &next) }
        try commit(next)
    }
    func acknowledgeCancellation(_ id: String) throws {
        var next = state; next.cancelIntents?.removeAll { $0 == id }
        var authoring = next.authoring ?? .init(); AuthoringStore.retireRequest(id: id, in: &authoring); next.authoring = authoring
        clearTerminalDelivery(id, in: &next)
        try commit(next); pruneUnusedRevisions()
    }
    func retireAuthoringRequest(id: String) throws {
        var next = state; var authoring = next.authoring ?? .init()
        AuthoringStore.retireRequest(id: id, in: &authoring); next.authoring = authoring
        if next.pendingID == id || next.submissionKey == id { next.consumedID = id }
        clearTerminalDelivery(id, in: &next)
        try commit(next); pruneUnusedRevisions()
    }
    func isScreenShown(_ id: String) -> Bool { state.hiddenScreenIDs?.contains(id) != true }

    private func selectsInstalledRevision(_ id: String) -> Bool {
        guard !needsAgentSetup, isScreenShown(id) else { return false }
        if let selected = state.selectedID { return !temporary.isActiveTarget(selected) }
        return true
    }

    func setScreenShown(_ shown: Bool, id: String) throws {
        guard !needsAgentSetup, containsRotationScreen(id), shown != isScreenShown(id) else { return }
        var next = state
        var hidden = next.hiddenScreenIDs ?? []
        if shown { hidden.remove(id) } else { hidden.insert(id) }
        next.hiddenScreenIDs = hidden.isEmpty ? nil : hidden
        if !shown, (next.selectedID == id || (id == Self.instructionsID && instructionsSelected)), !temporary.isActiveTarget(id) {
            next.selectedID = nextVisible(after: id, in: next)
        } else if shown, next.selectedID == nil, rotationIDs.allSatisfy({ !isScreenShown($0) }) {
            next.selectedID = id
        }
        try commit(next)
    }

    private func nextVisible(after id: String?, in snapshot: State, backwards: Bool = false) -> String? {
        let ids = snapshot.onboarding == .connectAgent ? [Self.instructionsID] : snapshot.screens.map(\.id) + [Self.instructionsID]
        let shown: (String) -> Bool = { snapshot.hiddenScreenIDs?.contains($0) != true }
        guard let id, let current = ids.firstIndex(of: id) else {
            return backwards ? ids.last(where: shown) : ids.first(where: shown)
        }
        let direction = backwards ? -1 : 1
        return (1...ids.count).lazy.map { ids[(current + direction * $0 + ids.count) % ids.count] }.first(where: shown)
    }

    func selectVisible(_ id: String) throws {
        guard !needsAgentSetup, isScreenShown(id), containsRotationScreen(id) else { return }
        try temporary.manualSelection()
        var next = state; next.selectedID = id; try commit(next)
    }

    func select(offset: Int) throws {
        guard !needsAgentSetup, offset != 0 else { return }
        let visible = rotationIDs.filter(isScreenShown)
        guard !visible.isEmpty else { return }
        if let selected = state.selectedID, let current = visible.firstIndex(of: selected) {
            let step = offset % visible.count
            try selectVisible(visible[(current + step + visible.count) % visible.count])
        } else if let next = nextVisible(after: state.selectedID, in: state, backwards: offset < 0) {
            try selectVisible(next)
        }
    }

    func remove(_ id: String) throws {
        guard state.screens.contains(where: { $0.id == id }) else { return }
        guard state.pendingID == nil, state.submissionKey == nil else {
            throw DeviceError.message("Finish or cancel the current request before removing a screen.")
        }
        let deletedDashboards = Self.publicDashboardIDs(state.screens.filter { $0.id == id } + [state.previous].compactMap { $0 }.filter { $0.id == id })
        if state.selectedID == id { try temporary.manualSelection() }
        var next = state
        var authoring = next.authoring ?? .init(); var knownScreens = authoring.knownScreenIDs ?? []; knownScreens.insert(id); authoring.knownScreenIDs = knownScreens; next.authoring = authoring
        next.screens.removeAll { $0.id == id }
        next.hiddenScreenIDs?.remove(id)
        if next.hiddenScreenIDs?.isEmpty == true { next.hiddenScreenIDs = nil }
        if next.selectedID == id {
            let fallback = nextVisible(after: id, in: state)
            next.selectedID = fallback == id ? nil : fallback
        }
        if next.previous?.id == id { next.previous = nil }
        if next.pendingScreenID == id { next.pendingScreenID = nil }
        next.publicDataRevocations = (next.publicDataRevocations ?? []).union(deletedDashboards)
        try commit(next)
        try flushPublicDataRevocations()
        pruneUnusedRevisions()
    }

    func newScreen() throws { guard !needsAgentSetup else { return }; try temporary.manualSelection(); var next = state; next.selectedID = nil; try commit(next) }

    // Installed screen IDs are non-empty. The checkpoint stores this sentinel as
    // an explicit neutral selection, distinct from no pending selection.
    private static let neutralSelection = ""

    /// Only call from an authenticated, account-scoped external command handler.
    func activateTemporarily(id: String, screenID: String, expiresAt: Date) throws {
        guard !screenID.isEmpty, state.screens.contains(where: { $0.id == screenID }) else {
            throw DeviceError.message("Temporary screen is not installed.")
        }
        let selected = state.selectedID ?? (instructionsSelected ? Self.instructionsID : Self.neutralSelection)
        try applyTemporary(temporary.activate(id: id, target: screenID, expiresAt: expiresAt, selected: selected))
    }

    func endTemporary(id: String) throws {
        let selected = state.selectedID ?? (instructionsSelected ? Self.instructionsID : Self.neutralSelection)
        try applyTemporary(temporary.end(id: id, selected: selected, fallbackSelection: temporaryFallback))
    }

    func reconcileTemporary(now: Date = Date()) throws {
        let selected = state.selectedID ?? (instructionsSelected ? Self.instructionsID : Self.neutralSelection)
        try applyTemporary(temporary.reconcile(selected: selected, now: now, fallbackSelection: temporaryFallback))
    }

    private var temporaryFallback: String? {
        guard let selected = state.selectedID, temporary.isActiveTarget(selected), !isScreenShown(selected) else { return nil }
        return nextVisible(after: selected, in: state) ?? Self.neutralSelection
    }

    private func applyTemporary(_ id: String?) throws {
        guard let id else { return }
        var next = state
        if id == Self.neutralSelection {
            next.selectedID = nil
        } else if temporary.expiresAt == nil {
            next.selectedID = isScreenShown(id) && containsRotationScreen(id)
                ? id : nextVisible(after: id, in: next)
        } else if next.screens.contains(where: { $0.id == id }) {
            next.selectedID = id
        }
        try commit(next)
        try temporary.acknowledgeSelection()
    }

    func rollback() throws {
        guard !needsAgentSetup, let previous = state.previous, let position = state.screens.firstIndex(where: { $0.id == previous.id }) else { return }
        try temporary.manualSelection()
        var next = state; next.previous = next.screens[position]; next.screens[position] = previous
        if isScreenShown(previous.id) { next.selectedID = previous.id }
        else if let selected = next.selectedID, !isScreenShown(selected) { next.selectedID = nextVisible(after: selected, in: next) }
        try commit(next)
    }
    private func clearTerminalDelivery(_ id: String, in next: inout State) {
        if next.submissionKey == id {
            next.submissionKey = nil; next.submissionText = nil; next.submissionScreen = nil
            next.requestDeadline = nil
        }
        if next.pendingID == id {
            next.pendingID = nil; next.pendingScreenID = nil; next.requestDeadline = nil
        }
    }
    private func commit(_ proposed: State, stagedDirectory: String? = nil, captureCatalog: Bool = true) throws {
        let previousCatalogRevision = state.catalog?.entries.last?.id
        defer {
            if let latest = state.catalog?.entries.last?.id, latest != previousCatalogRevision,
               captureCatalog, stagedDirectory != nil {
                onCatalogRevisionCommitted?()
            }
        }
        var next = proposed
        let currentRevisions = Dictionary(state.screens.map { ($0.id, $0.revision) }, uniquingKeysWith: { first, _ in first })
        let generations = Dictionary(next.screens.map { screen in
            let retained = currentRevisions[screen.id] == screen.revision ? state.screenDataGenerations?[screen.id] : nil
            return (screen.id, retained ?? UUID().uuidString)
        }, uniquingKeysWith: { first, _ in first })
        next.screenDataGenerations = generations
        let previousGenerations = state.screenDataGenerations
        if captureCatalog, catalogCapabilityChecked, let revision = stagedDirectory,
           let saved = next.screens.first(where: { $0.revision == revision }) {
            captureCatalogRevision(saved, origin: "apply", in: &next)
        }
        if let known = next.catalog?.knownSavedRevisions {
            let retained = next.screens.map(\.revision) + [next.previous?.revision].compactMap { $0 }
            next.catalog?.knownSavedRevisions = known.intersection(retained)
        }
        defer {
            if state.screenDataGenerations != previousGenerations {
                reconcileScreenDataArchive()
            }
        }
        try persist(next, encoded: JSONEncoder().encode(next), stagedDirectory: stagedDirectory)
    }
    private func reconcileScreenDataArchive() {
        let localDeviceIds = screenDataLocalDeviceIds.union(
            [state.linkedProfile?.localDeviceID, state.linkedProfile?.authoringDeviceID].compactMap { $0 })
        // The committed generation fences access even if removing old archive entries fails.
        try? screenDataArchive.reconcile(generations: state.screenDataGenerations ?? [:], localDeviceIds: localDeviceIds)
    }

    private func persist(_ next: State, encoded: Data, stagedDirectory: String? = nil) throws {
        do {
            try journal.commit(encoded, stagedDirectory: stagedDirectory)
            state = next
        } catch {
            // A durable intent may already have committed. Refresh before another mutation.
            if let recovered = try? journal.recover(), let decoded = try? Self.decodeState(recovered) { state = decoded }
            throw error
        }
    }
    private static func decodeState(_ data: Data) throws -> State {
        var state = try JSONDecoder().decode(State.self, from: data)
        // Before opt-in existed, eligible commits were always journaled. Recover
        // rollback provenance once, before any new opt-out edits can occur.
        if var queue = state.catalog, queue.knownSavedRevisions == nil {
            var known = Set<String>()
            let queued = Set(queue.entries.map(\.revision))
            for saved in state.screens + [state.previous].compactMap({ $0 }) {
                let copy = queue.copies[saved.id]
                if copy?.head == saved.revision || copy?.acknowledgedRevision == saved.revision || queued.contains(saved.revision) {
                    known.insert(saved.revision)
                }
            }
            if let previous = state.previous, let current = state.screens.first(where: { $0.id == previous.id }),
               let copy = queue.copies[current.id], copy.counter > 1, copy.gapFrom == nil,
               copy.head == previous.revision || copy.head == current.revision {
                known.formUnion([previous.revision, current.revision])
            }
            queue.knownSavedRevisions = known
            state.catalog = queue
        }
        return state
    }
    private func pruneUnusedRevisions() {
        let retained = Set(state.screens.map(\.revision) + [state.previous?.revision].compactMap { $0 } + (state.authoring?.revisionPins?.values.map(\.revision) ?? []) + (state.catalog?.entries.map(\.revision) ?? []))
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if UUID(uuidString: url.lastPathComponent) != nil && !retained.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
        }
        let images = root.appendingPathComponent("catalog-previews", isDirectory: true)
        let referenced = Set((state.catalog?.previews ?? []).map { $0.id + ".png" })
        for url in (try? FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil)) ?? [] {
            if url.pathExtension == "png", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil, !referenced.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
        }
    }
    var preferences: [PreferenceRecordV1] { (state.authoring?.records.values.filter { !$0.deleted } ?? []).sorted { $0.id < $1.id } }
    var preferenceOutbox: [AuthoringPreferenceOutboxEntry] { state.authoring?.outbox ?? [] }
    var preferenceConflicts: [AuthoringPreferenceConflict] { state.authoring?.conflicts ?? [] }
    var pendingReceipts: [ApplicationReceiptV1] {
        guard let authoring = state.authoring else { return [] }
        return authoring.receipts.values.filter { !authoring.acknowledgedReceiptIDs.contains($0.operationID) && !(state.localRequestIDs ?? []).contains($0.requestID) && authoring.requests[$0.requestID]?.delivery.route != "local" && authoring.requestsV2?[$0.requestID]?.delivery.route != "local" }.sorted { $0.appliedAt < $1.appliedAt }
    }
    func pendingReceipts(deviceID: String) -> [ApplicationReceiptV1] {
        pendingReceipts.filter { receipt in
            (state.authoring?.requestDeviceIDs?[receipt.requestID] ?? state.authoring?.requests[receipt.requestID]?.context.deviceID) == deviceID
        }
    }
    /// Reauthentication may use a different enrolled device. Preserve old receipts and
    /// preference records, but quarantine delivery work that this credential cannot own.
    func activateAuthoringDevice(deviceID: String) throws {
        var next = state; var authoring = next.authoring ?? .init()
        authoring.knownScreenIDs = (authoring.knownScreenIDs ?? []).union(next.screens.map(\.id))
        var devices = authoring.requestDeviceIDs ?? [:]
        for request in authoring.requests.values { devices[request.requestID] = request.context.deviceID }
        for request in authoring.requestsV2?.values ?? [:].values { devices[request.requestID] = request.context.deviceID }
        authoring.requestDeviceIDs = devices
        for request in Array(authoring.requests.values) where request.context.deviceID != deviceID {
            AuthoringStore.retireRequest(id: request.requestID, in: &authoring)
        }
        for request in Array(authoring.requestsV2?.values ?? [:].values) where request.context.deviceID != deviceID {
            AuthoringStore.retireRequest(id: request.requestID, in: &authoring)
        }
        if let id = next.pendingID, devices[id] != deviceID {
            AuthoringStore.retireRequest(id: id, in: &authoring)
            next.pendingID = nil; next.pendingScreenID = nil; next.consumedID = id; next.requestDeadline = nil
        }
        if let id = next.submissionKey, devices[id] != deviceID {
            AuthoringStore.retireRequest(id: id, in: &authoring)
            next.submissionKey = nil; next.submissionText = nil; next.submissionScreen = nil
        }
        let inaccessible = (next.cancelIntents ?? []).filter { devices[$0] != deviceID }
        authoring.quarantinedCancellationIDs = (authoring.quarantinedCancellationIDs ?? []).union(inaccessible)
        next.cancelIntents?.removeAll { inaccessible.contains($0) }
        next.authoring = authoring; try commit(next)
    }
    func preferences(profileID: String, deviceID: String, screenID: String) -> [PreferenceRecordV1] {
        AuthoringStore.preferences(in: state.authoring ?? .init(), profileID: profileID, deviceID: deviceID, screenID: screenID)
    }
    var hasCloudSubmission: Bool {
        guard let id = state.submissionKey else { return false }
        return (authoringRequestV2(id: id)?.delivery.route ?? authoringRequest(id: id)?.delivery.route) == "cloud"
    }
    var unacknowledgedLocalReceiptIDs: [String] {
        guard let authoring = state.authoring else { return [] }
        return authoring.receipts.values.compactMap { receipt in
            guard !authoring.acknowledgedReceiptIDs.contains(receipt.operationID) else { return nil }
            let route = authoringRequestV2(id: receipt.requestID)?.delivery.route ?? authoringRequest(id: receipt.requestID)?.delivery.route
            return route == "local" || (state.localRequestIDs ?? []).contains(receipt.requestID) ? receipt.requestID : nil
        }.sorted()
    }
    func isUnsentLocalRequest(_ id: String, ledgerRecordExists: Bool) -> Bool {
        state.submissionKey == id && (state.pendingID == nil || state.pendingID == id) &&
            !ledgerRecordExists && !hasApplicationReceipt(requestID: id) &&
            (authoringRequestV2(id: id)?.delivery.route ?? authoringRequest(id: id)?.delivery.route) == "local"
    }

    func hasApplicationReceipt(requestID: String) -> Bool {
        state.authoring?.receipts.values.contains(where: { $0.requestID == requestID }) == true
    }

    /// Resume only work this library already owns, never completed Cloud history
    /// restored into a fresh container or a different account/device.
    func recoverableCloudCompletion(_ ids: [String], profileID: String, deviceID: String) -> String? {
        guard state.pendingID == nil, state.submissionKey == nil, let authoring = state.authoring else { return nil }
        return ids.first { id in
            guard id != state.consumedID, id != state.lastRequest,
                  !(state.cancelledRequests ?? []).contains(id),
                  !(authoring.cancelledRequestIDs ?? []).contains(id),
                  !(authoring.retiredRequestIDs ?? []).contains(id),
                  !authoring.receipts.values.contains(where: { $0.requestID == id }) else { return false }
            if let request = authoring.requestsV2?[id] {
                return request.delivery.route == "cloud" && request.context.profileID == profileID &&
                    request.context.deviceID == deviceID && request.context.libraryID == libraryOwner
            }
            if let request = authoring.requests[id] {
                return request.delivery.route == "cloud" && request.context.profileID == profileID && request.context.deviceID == deviceID
            }
            return false
        }
    }

    func authoringRequestV2(id: String) -> AuthoringRequestV2? { state.authoring?.requestsV2?[id] }
    /// The model receives a compact manifest; raw native package bytes remain the authority.
    func makeAuthoringRequestV2(from request: AuthoringRequestV1, libraryID: String? = nil) throws -> AuthoringRequestV2 {
        guard libraryID == nil || libraryID == libraryOwner else { throw DeviceError.message("The request belongs to another library.") }
        var input = request
        if let revision = request.context.baseRevision {
            guard let saved = state.screens.first(where: { $0.id == request.context.screenID }), saved.revision == revision else { throw DeviceError.message("The screen changed before the request was prepared.") }
            let files = try saved.artifact.files.map { file -> AuthoringScreenFile in
                let expected = Data(file.content.utf8)
                let raw = try AuthoringPinnedPackage.read(directory: root.appendingPathComponent(revision), path: file.path, byteLength: expected.count, digest: AuthoringContract.contentDigest(expected))
                guard let content = String(data: raw, encoding: .utf8) else { throw DeviceError.message("The base asset is not supported UTF8.") }
                return .init(path: file.path, content: content)
            }
            input.context.currentScreen = .init(title: saved.artifact.title, entry: saved.artifact.entry, files: files)
        } else {
            guard !state.screens.contains(where: { $0.id == request.context.screenID }) else { throw DeviceError.message("The screen revision is missing from this request.") }
            input.context.currentScreen = nil
        }
        input = try AuthoringContract.seal(input)
        return try AuthoringV2Contract.makeRequest(from: input, libraryID: libraryOwner)
    }
    /// Persist and pin the sealed request before a transport is allowed to prepare or send it.
    func saveAuthoringRequest(_ request: AuthoringRequestV2) throws {
        try saveAuthoringRequestV2(request, text: nil, screen: nil)
    }
    /// Preparation is one durable transaction: no orphan pin can exist without visible pending work.
    func prepareAuthoringRequest(_ request: AuthoringRequestV2, text: String, screen: ScreenArtifact?) throws {
        guard text == request.context.userRequest else { throw DeviceError.message("The prepared instructions differ from the sealed request.") }
        try saveAuthoringRequestV2(request, text: text, screen: screen)
    }
    private func saveAuthoringRequestV2(_ request: AuthoringRequestV2, text: String?, screen: ScreenArtifact?) throws {
        _ = try AuthoringV2Contract.validateRequest(JSONEncoder().encode(request))
        guard request.context.libraryID == libraryOwner else { throw DeviceError.message("The request belongs to another library.") }
        if let existing = state.authoring?.requestDigests[request.requestID] {
            guard existing == AuthoringContract.contentDigest(try AuthoringContract.encodedCanonical(request)) else { throw DeviceError.message("This request ID is already bound to another snapshot.") }
            guard let text else { return }
            guard state.authoring?.requestsV2?[request.requestID] != nil,
                  state.authoring?.receipts.values.contains(where: { $0.requestID == request.requestID }) != true,
                  !(state.authoring?.cancelledRequestIDs ?? []).contains(request.requestID) else { throw DeviceError.message("This authoring request has already ended.") }
            var next = state
            try prepareDelivery(request, text: text, screen: screen, in: &next)
            try commit(next); return
        }
        var pin: AuthoringRevisionPin?
        if let revision = request.context.baseRevision {
            guard UUID(uuidString: revision) != nil,
                  let saved = state.screens.first(where: { $0.id == request.context.screenID }), saved.revision == revision,
                  let source = request.context.currentScreen,
                  source.title == saved.artifact.title, source.entry == saved.artifact.entry,
                  Set(source.files.map(\.path)) == Set(saved.artifact.files.map(\.path)) else { throw DeviceError.message("The screen changed before the request was prepared.") }
            for file in source.files {
                let raw = try AuthoringPinnedPackage.read(directory: root.appendingPathComponent(revision), path: file.path, byteLength: file.byteLength, digest: file.digest)
                if let content = file.content { guard Data(content.utf8) == raw else { throw DeviceError.message("The editable source differs from its pinned bytes.") } }
            }
            pin = .init(requestID: request.requestID, profileID: request.context.profileID, libraryID: libraryOwner, screenID: request.context.screenID, revision: revision, byteLength: source.files.reduce(0, { $0 + $1.byteLength }))
        } else {
            guard request.context.currentScreen == nil, !state.screens.contains(where: { $0.id == request.context.screenID }) else { throw DeviceError.message("The new screen snapshot cannot reference an installed screen.") }
        }
        var next = state; var authoring = next.authoring ?? .init()
        try AuthoringStore.saveRequest(request, pin: pin, in: &authoring)
        if request.delivery.route == "local" { next.localRequestIDs = (next.localRequestIDs ?? []).union([request.requestID]) }
        next.authoring = authoring
        if let text { try prepareDelivery(request, text: text, screen: screen, in: &next) }
        try commit(next)
    }
    private func prepareDelivery(_ request: AuthoringRequestV2, text: String, screen: ScreenArtifact?, in next: inout State) throws {
        guard (next.pendingID == nil || next.pendingID == request.requestID),
              (next.submissionKey == nil || next.submissionKey == request.requestID) else { throw DeviceError.message("Resolve the current request before preparing another.") }
        next.submissionKey = request.requestID; next.submissionText = text; next.submissionScreen = screen
        next.lastInstruction = text; next.pendingID = request.requestID; next.pendingScreenID = request.context.screenID
        next.requestDeadline = Double(request.deadlineAt)
    }
    func authoringRequest(id: String) -> AuthoringRequestV1? { state.authoring?.requests[id] }
    func saveAuthoringRequest(_ request: AuthoringRequestV1) throws {
        var next = state; var authoring = next.authoring ?? .init()
        try AuthoringStore.saveRequest(request, in: &authoring)
        if request.delivery.route == "local" { next.localRequestIDs = (next.localRequestIDs ?? []).union([request.requestID]) }
        next.authoring = authoring; try commit(next)
    }
    func acknowledgeReceipt(_ receipt: ApplicationReceiptV1) throws {
        guard state.authoring?.receipts[receipt.operationID] == receipt else { throw DeviceError.message("The application receipt does not match this library.") }
        var next = state
        if var authoring = next.authoring { authoring.acknowledgedReceiptIDs.insert(receipt.operationID); AuthoringStore.compactSources(in: &authoring); next.authoring = authoring }
        clearTerminalDelivery(receipt.requestID, in: &next)
        try commit(next); pruneUnusedRevisions()
    }
    /// The complete next index (screen, CAS mutations, receipt, outbox) is one redo transaction.
    func applyAuthoringResult(_ result: AuthoringResultV1, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> ApplicationReceiptV1 {
        if let old = state.authoring?.receipts[result.operationID] {
            let digest = AuthoringContract.contentDigest(try AuthoringContract.encodedCanonical(result))
            guard state.authoring?.operationDigests[result.operationID] == digest else { throw DeviceError.message("This operation ID was reused with different content.") }
            if state.pendingID == result.requestID || state.submissionKey == result.requestID {
                var next = state; next.consumedID = result.requestID; clearTerminalDelivery(result.requestID, in: &next); try commit(next)
            }
            return old
        }
        guard let request = state.authoring?.requests[result.requestID] else { throw DeviceError.message("The original authoring snapshot is missing.") }
        var next = state; var authoring = next.authoring ?? .init()
        let current = next.screens.first { $0.id == request.context.screenID }
        let receipt = try AuthoringStore.apply(result, to: &authoring, currentScreenRevision: current?.revision, cancelled: (state.cancelledRequests ?? []).contains(result.requestID), now: now)
        next.authoring = authoring
        var stagedRevision: String?
        if receipt.status == "applied", let screen = result.screen {
            let artifact = ScreenArtifact(title: screen.title, entry: screen.entry, files: screen.files.map { ScreenFile(path: $0.path, content: $0.content) })
            let revision = UUID().uuidString
            let directory = root.appendingPathComponent(revision, isDirectory: true)
            do {
                try Self.validate(artifact)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for file in artifact.files {
                    let url = directory.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(file.content.utf8).write(to: url, options: .atomic)
                }
                _ = try PackageAssetStore.load(directory: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                var rejected = state; var original = rejected.authoring ?? .init()
                let rejection = try AuthoringStore.reject(result, reason: "The screen package could not be installed: " + error.localizedDescription, in: &original, now: now)
                rejected.authoring = original; rejected.consumedID = result.requestID
                clearTerminalDelivery(result.requestID, in: &rejected)
                try commit(rejected)
                return rejection
            }
            stagedRevision = revision
            let saved = Saved(id: request.context.screenID, revision: revision, artifact: artifact)
            if let index = next.screens.firstIndex(where: { $0.id == saved.id }) { next.previous = next.screens[index]; next.screens[index] = saved }
            else { next.screens.append(saved) }
            if selectsInstalledRevision(saved.id) { next.selectedID = saved.id }; next.lastRequest = result.requestID
        }
        next.consumedID = result.requestID; clearTerminalDelivery(result.requestID, in: &next)
        try commit(next, stagedDirectory: stagedRevision)
        if stagedRevision != nil { pruneUnusedRevisions() }
        return receipt
    }
    func applyAuthoringResult(_ result: AuthoringResultV2, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> ApplicationReceiptV1 {
        if let old = state.authoring?.receipts[result.operationID] {
            guard state.authoring?.operationDigests[result.operationID] == AuthoringContract.contentDigest(try AuthoringContract.encodedCanonical(result)) else { throw DeviceError.message("This operation ID was reused with different content.") }
            if state.pendingID == result.requestID || state.submissionKey == result.requestID {
                var next = state; next.consumedID = result.requestID; clearTerminalDelivery(result.requestID, in: &next); try commit(next)
            }
            return old
        }
        guard let request = state.authoring?.requestsV2?[result.requestID], request.context.libraryID == libraryOwner else { throw DeviceError.message("The original authoring snapshot is missing or belongs to another library.") }
        var next = state; var authoring = next.authoring ?? .init()
        let current = next.screens.first { $0.id == request.context.screenID }
        let receipt = try AuthoringStore.apply(result, to: &authoring, currentScreenRevision: current?.revision, cancelled: (state.cancelledRequests ?? []).contains(result.requestID), now: now)
        next.authoring = authoring
        var stagedRevision: String?
        if receipt.status == "applied", let mutation = result.screen {
            let revision = UUID().uuidString
            let directory = root.appendingPathComponent(revision, isDirectory: true)
            do {
                var retained: [String: Data] = [:]
                let materialized = try AuthoringV2Contract.materialize(result, request: request) { source in
                    guard let pin = self.state.authoring?.revisionPins?[request.requestID],
                          pin.requestID == request.requestID, pin.libraryID == self.libraryOwner,
                          pin.profileID == request.context.profileID, pin.screenID == request.context.screenID,
                          pin.revision == request.context.baseRevision, UUID(uuidString: pin.revision) != nil else { throw DeviceError.message("The immutable base package pin is missing.") }
                    let raw = try AuthoringPinnedPackage.read(directory: self.root.appendingPathComponent(pin.revision), path: source.path, byteLength: source.byteLength, digest: source.digest)
                    retained[source.path] = raw
                    return raw
                }
                try AuthoringPackageDependencies.validateManifest(files: materialized.files)
                let artifact = ScreenArtifact(title: materialized.title, entry: materialized.entry, files: materialized.files.map { .init(path: $0.path, content: $0.content) })
                try Self.validate(artifact)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for file in mutation.files {
                    let data: Data
                    if file.kind == "retain", let path = file.sourcePath, let raw = retained[path] { data = raw }
                    else if file.kind == "write", let content = file.content { data = Data(content.utf8) }
                    else { throw DeviceError.message("The materialized asset is missing.") }
                    let url = directory.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                }
                _ = try PackageAssetStore.load(directory: directory)
                stagedRevision = revision
                let saved = Saved(id: request.context.screenID, revision: revision, artifact: artifact)
                if let index = next.screens.firstIndex(where: { $0.id == saved.id }) { next.previous = next.screens[index]; next.screens[index] = saved }
                else { next.screens.append(saved) }
                if selectsInstalledRevision(saved.id) { next.selectedID = saved.id }; next.lastRequest = result.requestID
            } catch {
                try? FileManager.default.removeItem(at: directory)
                return try rejectAuthoringResult(result, reason: "The screen package could not be installed: " + error.localizedDescription, now: now)
            }
        }
        next.consumedID = result.requestID; clearTerminalDelivery(result.requestID, in: &next)
        try commit(next, stagedDirectory: stagedRevision)
        pruneUnusedRevisions()
        return receipt
    }
    func rejectAuthoringResult(_ result: AuthoringResultV2, reason: String, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> ApplicationReceiptV1 {
        var next = state; var authoring = next.authoring ?? .init()
        let receipt = try AuthoringStore.reject(result, reason: reason, in: &authoring, now: now)
        next.authoring = authoring; next.consumedID = result.requestID; clearTerminalDelivery(result.requestID, in: &next)
        try commit(next); pruneUnusedRevisions(); return receipt
    }
    func rejectAuthoringResult(_ result: AuthoringResultV1, reason: String, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> ApplicationReceiptV1 {
        var next = state; var authoring = next.authoring ?? .init()
        let receipt = try AuthoringStore.reject(result, reason: reason, in: &authoring, now: now)
        next.authoring = authoring; next.consumedID = result.requestID; clearTerminalDelivery(result.requestID, in: &next)
        try commit(next); return receipt
    }
    func editPreference(id: String, value: AuthoringJSONValue, expectedRevision: Int) throws {
        guard var record = state.authoring?.records[id], !record.deleted else { throw DeviceError.message("This preference no longer exists.") }
        let origin = "settings-" + UUID().uuidString
        record.value = value; record.revision = expectedRevision + 1; record.originRequestID = origin
        var next = state; var authoring = next.authoring ?? .init()
        try AuthoringStore.mutate(.init(kind: "upsert", id: id, expectedRevision: expectedRevision, record: record), originRequestID: origin, in: &authoring)
        next.authoring = authoring; try commit(next)
    }
    func deletePreference(id: String, expectedRevision: Int) throws {
        var next = state; var authoring = next.authoring ?? .init()
        try AuthoringStore.mutate(.init(kind: "delete", id: id, expectedRevision: expectedRevision), originRequestID: "settings-" + UUID().uuidString, in: &authoring)
        next.authoring = authoring; try commit(next)
    }
    func applyPreferenceSync(records: [PreferenceRecordV1], accepted: [String: Int], sent: [AuthoringPreferenceOutboxEntry], conflicts: [String: PreferenceRecordV1?], profileID: String, deviceID: String) throws {
        let screenIDs = Set(state.screens.map(\.id) + (state.authoring?.requests.values.map { $0.context.screenID } ?? [])).union(state.authoring?.requestsV2?.values.map { $0.context.screenID } ?? []).union(state.authoring?.knownScreenIDs ?? [])
        var seen = Set<String>()
        for record in records {
            guard seen.insert(record.id).inserted else { throw DeviceError.message("Cloud returned duplicate preferences.") }
            try validateRemotePreference(record, profileID: profileID, deviceID: deviceID, screenIDs: screenIDs)
        }
        let sentIDs = Set(sent.map { $0.record.id })
        guard accepted.allSatisfy({ sentIDs.contains($0.key) && $0.value > 0 && $0.value <= 9_007_199_254_740_991 }), conflicts.keys.allSatisfy({ sentIDs.contains($0) }), Set(accepted.keys).isDisjoint(with: conflicts.keys) else { throw DeviceError.message("Cloud returned an unrelated preference acknowledgement.") }
        for (id, record) in conflicts {
            if let record {
                guard record.id == id else { throw DeviceError.message("Cloud returned a mismatched preference conflict.") }
                try validateRemotePreference(record, profileID: profileID, deviceID: deviceID, screenIDs: screenIDs)
            }
        }
        var next = state; var authoring = next.authoring ?? .init()
        AuthoringStore.mergeCloud(records: records, accepted: accepted, sent: sent, conflicts: conflicts, in: &authoring)
        next.authoring = authoring; try commit(next)
    }
    private func validateRemotePreference(_ record: PreferenceRecordV1, profileID: String, deviceID: String, screenIDs: Set<String>) throws {
        _ = try AuthoringContract.validatePreferenceRecord(JSONEncoder().encode(record))
        guard (record.scope == "profile" && record.targetID == profileID) || (record.scope == "device" && record.targetID == deviceID) || (record.scope == "screen" && screenIDs.contains(record.targetID)) else { throw DeviceError.message("Cloud returned a preference outside this account and device.") }
    }
    func acceptRemotePreference(id: String) throws { try resolvePreference(id: id, keepingLocal: false) }
    func keepLocalPreference(id: String) throws { try resolvePreference(id: id, keepingLocal: true) }
    private func resolvePreference(id: String, keepingLocal: Bool) throws {
        var next = state; var authoring = next.authoring ?? .init()
        try AuthoringStore.resolveConflict(id: id, keepingLocal: keepingLocal, in: &authoring)
        next.authoring = authoring; try commit(next)
    }
    static func validate(_ artifact: ScreenArtifact) throws {
        _ = try AuthoringContract.validateScreen(JSONEncoder().encode(AuthoringScreen(title: artifact.title, entry: artifact.entry, files: artifact.files.map { .init(path: $0.path, content: $0.content) })))
        guard !artifact.title.isEmpty, artifact.entry == "index.html", (1...20).contains(artifact.files.count) else { throw DeviceError.message("The screen package is too large or incomplete.") }
        var paths = Set<String>()
        for file in artifact.files {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.path.contains("\\"), !file.path.contains("%"), !file.path.contains(":"), !file.path.contains("\0"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  ["html", "css", "js", "json", "svg", "txt"].contains((file.path as NSString).pathExtension), paths.insert(file.path).inserted else { throw DeviceError.message("The screen contains an unsafe or unsupported file path.") }
        }
        guard paths.contains("index.html") else { throw DeviceError.message("The screen is missing index.html.") }
        try AuthoringPackageDependencies.validate(files: artifact.files.map { .init(path: $0.path, content: $0.content) })
    }
}


extension ScreenLibrary {
    /// Credentials never enter this durable binding. A changed account/enrollment must
    /// open its own library; an old queue remains quarantined until its owner returns.
    struct CatalogBinding: Codable, Equatable {
        var origin: String
        var accountID: String
        var userID: String
        var deviceID: String
        var libraryID: String

        var preferenceKey: String {
            let fields = [origin, accountID, userID, deviceID, libraryID]
            let scope = fields.map { "\($0.utf8.count):\($0)" }.joined()
            return "cloudBackups.v1." + CatalogContract.digest(Data(scope.utf8))
        }
    }
    struct CatalogCopy: Codable {
        var id: String = UUID().uuidString
        var localScreenID: String = UUID().uuidString
        var counter: Int = 0
        var head: String?
        var lastQueuedCounter: Int = 0
        var acknowledgedCounter: Int = 0
        var acknowledgedRevision: String?
        var gapFrom: Int?
        var gapThrough: Int?
    }
    struct CatalogIntent: Codable, Identifiable {
        var id: String = UUID().uuidString
        var operationID: String = UUID().uuidString
        var screenID: String
        var revision: String
        var copyID: String
        var counter: Int
        var parentIDs: [String]
        var title: String
        var entry: String
        var paths: [String]
        var appliedAt: Int64
        var origin: String
        var packageBytes: Int
        var attempts: Int = 0
        var retryAt: Double = 0
        var uploadID: String?
        var packageDigest: String?
        var beginDigest: String?
        var blockedReason: String?
        var gap: CatalogGapDeclaration?
    }
    struct CatalogQueue: Codable {
        var binding: CatalogBinding
        var libraryID: String = UUID().uuidString
        var copies: [String: CatalogCopy] = [:]
        var entries: [CatalogIntent] = []
        var paused: Bool = false
        var captureAllowed: Bool = true
        var authPaused: Bool = false
        var status: String?
        var seedAnnounced: Bool = false
        var acknowledgedCount: Int = 0
        var maxRevisions: Int = 100
        var maxBytes: Int = 100 * 1024 * 1024
        var previews: [CatalogCapturedPreview]?
        var previewFinishedSources: [String]?
        // Bounded to revisions still visible in the saved library or rollback.
        // Retains provenance after an upload is acknowledged or removed in Cloud.
        var knownSavedRevisions: Set<String>?
    }
    struct CatalogCapturedPreview: Codable, Identifiable {
        var id: String = UUID().uuidString
        var operationID: String = UUID().uuidString
        var revision: String
        var packageDigest: String
        var capturedAt: String
        var declaration: CatalogPNGPreviewDeclaration
        var candidate: CatalogPreviewCandidate?
        var attempts: Int = 0
        var retryAt: Double = 0
        var beginDigest: String?
    }
    var catalogQueue: CatalogQueue? { state.catalog }

    @discardableResult
    func setCatalogBackupScope(_ binding: CatalogBinding?, validUntil: Date? = nil) -> Bool {
        let scope = binding?.libraryID == libraryOwner && validUntil != nil ? binding : nil
        let deadline = scope == nil ? nil : validUntil
        guard scope != catalogBackupScope || deadline != catalogBackupValidUntil else { return false }
        catalogBackupScope = scope
        catalogBackupValidUntil = deadline
        catalogConsentGeneration = UUID()
        catalogCapabilityChecked = false
        return true
    }

    func catalogAuthorization(binding: CatalogBinding) -> UUID? {
        guard catalogBackupScope == binding, let deadline = catalogBackupValidUntil, Date() < deadline,
              catalogBackupsPreference(binding: binding) else { return nil }
        return catalogConsentGeneration
    }

    func catalogWorkAllowed(binding: CatalogBinding) -> Bool { catalogAuthorization(binding: binding) != nil }

    func catalogBackupsPreference(binding: CatalogBinding) -> Bool {
        binding.libraryID == libraryOwner && catalogDefaults.bool(forKey: binding.preferenceKey)
    }

    /// Turn off consent even when an unknown entitlement has already suspended work.
    func disableCatalogBackups(binding: CatalogBinding) {
        guard binding.libraryID == libraryOwner, catalogBackupScope == nil || catalogBackupScope == binding,
              catalogBackupsPreference(binding: binding) else { return }
        catalogDefaults.set(false, forKey: binding.preferenceKey)
        catalogConsentGeneration = UUID()
        catalogCapabilityChecked = false
    }

    func setCatalogBackupsEnabled(_ enabled: Bool, binding: CatalogBinding) throws {
        guard catalogBackupScope == binding else { throw DeviceError.message("The backup account changed.") }
        if enabled, (catalogBackupValidUntil ?? .distantPast) <= Date() {
            throw DeviceError.message("Verify Screenpunk Pro before enabling backups.")
        }
        guard enabled != catalogBackupsPreference(binding: binding) else { return }
        catalogDefaults.set(enabled, forKey: binding.preferenceKey)
        catalogConsentGeneration = UUID()
        catalogCapabilityChecked = false
    }

    /// Only call after an authenticated capability response for this exact library.
    /// Existing content is an honestly labelled current-screen seed, never history.
    func activateCatalog(binding: CatalogBinding, maxRevisions: Int = 100, maxBytes: Int = 100 * 1024 * 1024) throws {
        guard catalogWorkAllowed(binding: binding), !binding.origin.isEmpty, !binding.accountID.isEmpty,
              !binding.userID.isEmpty, !binding.deviceID.isEmpty else { throw DeviceError.message("The backup account binding is incomplete.") }
        guard state.catalog == nil || state.catalog?.binding == binding else {
            throw DeviceError.message("Saved backups belong to an earlier account or device connection.")
        }
        var next = state
        var changed = state.catalog == nil || state.catalog?.captureAllowed == false
        if next.catalog == nil {
            next.catalog = CatalogQueue(binding: binding, maxRevisions: max(1, min(100, maxRevisions)), maxBytes: max(1, min(100 * 1024 * 1024, maxBytes)))
            next.catalog?.knownSavedRevisions = []
            next.catalog?.seedAnnounced = true
            next.catalog?.status = "Current screens are queued for backup."
        }
        next.catalog?.captureAllowed = true
        if next.catalog?.paused != true {
            for saved in next.screens where needsCatalogSeed(saved, in: next) {
                captureCatalogRevision(saved, origin: "seed", in: &next)
                changed = true
            }
        }
        if changed { try commit(next) }
        catalogCapabilityChecked = true
    }

    private func needsCatalogSeed(_ saved: Saved, in state: State) -> Bool {
        guard let queue = state.catalog, let copy = queue.copies[saved.id] else { return true }
        if saved.revision == copy.head || saved.revision == copy.acknowledgedRevision || queue.knownSavedRevisions?.contains(saved.revision) == true ||
            queue.entries.contains(where: { $0.screenID == saved.id && $0.revision == saved.revision }) { return false }
        return true
    }

    private func captureCatalogRevision(_ saved: Saved, origin: String, in next: inout State) {
        guard var queue = next.catalog, catalogWorkAllowed(binding: queue.binding), !queue.authPaused else { return }
        var copy = queue.copies[saved.id] ?? CatalogCopy()
        // Journal recovery/replay must not assign a new operation or counter.
        guard copy.head != saved.revision else { return }
        let parents = copy.head.map { [$0] } ?? []
        copy.counter += 1
        copy.head = saved.revision
        let directory = root.appendingPathComponent(saved.revision)
        // This is admission accounting only. Export validates paths and exact bytes
        // independently before transport; failed export never changes application.
        var bytes = 0
        var admissionError: String?
        var packageDigest: String?
        for path in saved.artifact.files.map(\.path) {
            do {
                let values = try directory.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size >= 0, size <= 204_800 else { throw DeviceError.message("A backup asset is missing or unsafe.") }
                bytes += size
            } catch { admissionError = "A backup asset is missing or unsafe. Review this screen before resuming backups." }
        }
        // Base64 plus manifest overhead; budget conservatively before export.
        bytes = ((bytes + 2) / 3) * 4 + saved.artifact.files.count * 512 + 8192
        do {
            let exported = try CatalogPackageExporter.export(directory: directory, title: saved.artifact.title, entry: saved.artifact.entry, paths: saved.artifact.files.map(\.path))
            bytes = exported.bytes.count
            packageDigest = exported.declaration.digest
        } catch {
            admissionError = "Backups paused: this committed package is unsafe, incomplete, or contains credential markers. Keep the installed screen and contact support to reconcile its pending backup."
        }
        let outstanding = Set(queue.entries.map(\.revision) + (queue.previews ?? []).map(\.revision))
        if queue.paused || !queue.captureAllowed || outstanding.count >= queue.maxRevisions || bytes > queue.maxBytes - queue.entries.reduce(0, { $0 + $1.packageBytes }) - (queue.previews ?? []).reduce(0, { $0 + $1.declaration.byteLength }) {
            queue.paused = true
            copy.gapFrom = copy.gapFrom ?? copy.counter
            copy.gapThrough = copy.counter
            queue.status = "Backups paused: capture is unavailable or the saved queue is full. Further edits stay on this device and are not queued. After queued backups finish, choose Resume backups to save each current screen."
        } else {
            queue.entries.append(CatalogIntent(screenID: saved.id, revision: saved.revision, copyID: copy.id, counter: copy.counter,
                parentIDs: parents, title: saved.artifact.title, entry: saved.artifact.entry, paths: saved.artifact.files.map(\.path),
                appliedAt: Int64(Date().timeIntervalSince1970 * 1000), origin: origin, packageBytes: bytes, packageDigest: packageDigest, blockedReason: admissionError))
            copy.lastQueuedCounter = copy.counter
            queue.knownSavedRevisions?.insert(saved.revision)
        }
        queue.copies[saved.id] = copy
        next.catalog = queue
    }

    func updateCatalogIntent(_ intent: CatalogIntent, binding: CatalogBinding) throws {
        guard catalogWorkAllowed(binding: binding), state.catalog?.binding == binding, let index = state.catalog?.entries.firstIndex(where: { $0.id == intent.id }) else { throw DeviceError.message("The backup connection changed.") }
        var next = state; next.catalog?.entries[index] = intent; try commit(next)
    }
    func acknowledgeCatalogIntent(id: String, binding: CatalogBinding) throws {
        guard catalogWorkAllowed(binding: binding), state.catalog?.binding == binding, state.catalog?.entries.first?.id == id else { throw DeviceError.message("The backup connection changed.") }
        var next = state
        let intent = next.catalog!.entries.removeFirst()
        if intent.counter > (next.catalog?.copies[intent.screenID]?.acknowledgedCounter ?? 0) {
            next.catalog?.copies[intent.screenID]?.acknowledgedCounter = intent.counter
            next.catalog?.copies[intent.screenID]?.acknowledgedRevision = intent.revision
        }
        next.catalog?.acknowledgedCount += 1
        if next.catalog?.entries.isEmpty == true, next.catalog?.paused != true { next.catalog?.status = nil }
        try commit(next)
        pruneUnusedRevisions()
    }
    func setCatalogStatus(_ status: String?, binding: CatalogBinding) throws {
        guard state.catalog?.binding == binding else { return }
        var next = state; next.catalog?.status = status; try commit(next)
    }
}


extension ScreenLibrary {
    func exportCatalogIntent(_ intent: CatalogIntent, binding: CatalogBinding) throws -> CatalogPackageExporter.Export {
        guard catalogCaptureAllowed(binding: binding), state.catalog?.entries.contains(where: { $0.id == intent.id && $0.revision == intent.revision }) == true else { throw DeviceError.message("The backup connection changed.") }
        let exported = try CatalogPackageExporter.export(directory: root.appendingPathComponent(intent.revision), title: intent.title, entry: intent.entry, paths: intent.paths)
        guard intent.packageDigest == nil || intent.packageDigest == exported.declaration.digest else { throw DeviceError.message("The immutable backup package changed. Backups are paused for review.") }
        return exported
    }
    func catalogBegin(_ intent: CatalogIntent, declaration: CatalogObjectDeclaration, binding: CatalogBinding) throws -> CatalogBeginBackup {
        guard catalogCaptureAllowed(binding: binding), let queue = state.catalog,
              let copy = queue.copies[intent.screenID], copy.id == intent.copyID else { throw DeviceError.message("The backup connection changed.") }
        let begin = CatalogBeginBackup(operationID: intent.operationID, libraryID: queue.libraryID, localScreenID: copy.localScreenID,
            sourceRevisionID: intent.revision, parentRevisionIDs: intent.parentIDs, predecessorRevisionID: intent.parentIDs.first,
            commitCounter: intent.counter, origin: intent.origin == "apply" ? "applied" : "seed",
            sourceAppliedAt: CatalogContract.timestamp(Date(timeIntervalSince1970: Double(intent.appliedAt) / 1000)), screenName: intent.title, gap: intent.gap, package: declaration)
        try CatalogContract.validateBegin(begin)
        return begin
    }
    /// Explicit user acknowledgement excludes the recorded intermediate edits.
    /// Existing pins must drain first; a copy without a server checkpoint cannot reset.
    func resumeCatalog(binding: CatalogBinding) throws {
        guard catalogCaptureAllowed(binding: binding), let queue = state.catalog, queue.paused,
              queue.entries.isEmpty else { throw DeviceError.message("Wait for queued backups to finish before resuming.") }
        var next = state
        for saved in state.screens {
            guard var copy = next.catalog?.copies[saved.id], let from = copy.gapFrom, let through = copy.gapThrough else { continue }
            guard copy.acknowledgedCounter >= 1, let checkpoint = copy.acknowledgedRevision,
                  from == copy.acknowledgedCounter + 1 else { throw DeviceError.message("This screen has no verified backup checkpoint. Backups remain paused; contact support to reconcile this screen without losing its history.") }
            guard saved.revision != checkpoint, next.catalog?.knownSavedRevisions?.contains(saved.revision) != true else {
                throw DeviceError.message("The current screen is an earlier backed-up revision. Make a new screen edit before resuming; saved revisions cannot be renumbered.")
            }
            let gap = CatalogGapDeclaration(checkpointCounter: copy.acknowledgedCounter, checkpointRevisionID: checkpoint, skippedFromCounter: from, skippedThroughCounter: through)
            copy.head = checkpoint; copy.counter = through
            copy.gapFrom = nil; copy.gapThrough = nil
            next.catalog?.copies[saved.id] = copy
            next.catalog?.paused = false
            captureCatalogRevision(saved, origin: "seed", in: &next)
            guard let index = next.catalog?.entries.lastIndex(where: { $0.screenID == saved.id }) else { throw DeviceError.message("The current screen exceeds the backup queue limit.") }
            next.catalog?.entries[index].gap = gap
        }
        next.catalog?.paused = false
        next.catalog?.status = "Backups resumed. Current screens are queued; edits made while paused are not a backup history."
        try commit(next)
    }
}


extension ScreenLibrary {
    func setCatalogEntitlement(_ enabled: Bool, binding: CatalogBinding) throws {
        guard catalogWorkAllowed(binding: binding), state.catalog?.binding == binding else { return }
        if !enabled { catalogCapabilityChecked = true }
        guard state.catalog?.captureAllowed != enabled else { return }
        var next = state; next.catalog?.captureAllowed = enabled; try commit(next)
    }
}


extension ScreenLibrary {
    func restartExpiredCatalogOperation(intentID: String, operationID: String, binding: CatalogBinding) throws {
        guard catalogWorkAllowed(binding: binding), state.catalog?.binding == binding,
              let index = state.catalog?.entries.firstIndex(where: { $0.id == intentID && $0.operationID == operationID }) else { throw DeviceError.message("The backup connection changed.") }
        var next = state
        next.catalog?.entries[index].operationID = UUID().uuidString
        next.catalog?.entries[index].beginDigest = nil
        next.catalog?.entries[index].uploadID = nil
        next.catalog?.entries[index].attempts = 0
        next.catalog?.entries[index].retryAt = 0
        // Source identity, counter, package digest and revision pin remain unchanged.
        try commit(next)
    }
}


extension ScreenLibrary {
    func pauseCatalogAuthentication(binding: CatalogBinding) throws {
        guard catalogWorkAllowed(binding: binding), state.catalog?.binding == binding, state.catalog?.authPaused != true else { return }
        var next = state; next.catalog?.authPaused = true; try commit(next)
    }
    /// Only explicit successful sign-in of the identical account/enrollment clears
    /// this durable pause. Restart or selecting a different library does not.
    func resumeCatalogAuthentication(binding: CatalogBinding) throws {
        guard binding.libraryID == libraryOwner, catalogBackupScope == nil || catalogBackupScope == binding,
              state.catalog?.binding == binding, state.catalog?.authPaused == true else { return }
        var next = state; next.catalog?.authPaused = false
        for index in next.catalog!.entries.indices { next.catalog?.entries[index].retryAt = 0 }
        try commit(next)
    }
}


extension ScreenLibrary {
    func catalogPackage(revision: String, digest: String, binding: CatalogBinding) throws -> CatalogPackageExporter.Export {
        guard catalogCaptureAllowed(binding: binding) else { throw DeviceError.message("The preview account changed.") }
        if let intent = state.catalog?.entries.first(where: { $0.revision == revision }) {
            let exported = try exportCatalogIntent(intent, binding: binding)
            guard exported.declaration.digest == digest else { throw DeviceError.message("The preview source changed.") }; return exported
        }
        guard let saved = (state.screens + [state.previous].compactMap { $0 }).first(where: { $0.revision == revision }) else { throw DeviceError.message("This exact source revision is no longer stored on this device.") }
        let exported = try CatalogPackageExporter.export(directory: root.appendingPathComponent(revision), title: saved.artifact.title, entry: saved.artifact.entry, paths: saved.artifact.files.map(\.path))
        guard exported.declaration.digest == digest else { throw DeviceError.message("The preview source changed.") }; return exported
    }
    func captureCatalogPreview(bytes: Data, declaration: CatalogPNGPreviewDeclaration, revision: String, packageDigest: String, capturedAt: String, binding: CatalogBinding, candidate: CatalogPreviewCandidate? = nil) throws {
        guard catalogCaptureAllowed(binding: binding), var queue = state.catalog,
              declaration.mediaType == "image/png", bytes.count > 0, bytes.count <= CatalogContract.previewBytes,
              declaration.byteLength == bytes.count, declaration.digest == CatalogContract.digest(bytes),
              (1...2048).contains(declaration.width), (1...2048).contains(declaration.height),
              bytes.starts(with: [137,80,78,71,13,10,26,10]), UUID(uuidString: revision) != nil else { throw DeviceError.message("Invalid exact-version preview.") }
        let date = ISO8601DateFormatter(); date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let captured = date.date(from: capturedAt), CatalogContract.timestamp(captured) == capturedAt,
              packageDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw DeviceError.message("Invalid screenshot source or capture time.") }
        let ownsRecovered = candidate.map { target in target.libraryID == queue.libraryID && target.sourceRevisionID == revision && target.packageDigest == packageDigest && queue.copies.values.contains(where: { $0.localScreenID == target.localScreenID }) } ?? false
        guard (try? catalogPackage(revision: revision, digest: packageDigest, binding: binding)) != nil || ownsRecovered else { throw DeviceError.message("This screenshot does not belong to an exact saved revision.") }
        if queue.previewFinishedSources?.contains(revision + ":" + packageDigest) == true || queue.previews?.contains(where: { $0.revision == revision && $0.packageDigest == packageDigest }) == true { return }
        let used = queue.entries.reduce(0) { $0 + $1.packageBytes } + (queue.previews ?? []).reduce(0) { $0 + $1.declaration.byteLength }
        let outstanding = Set(queue.entries.map(\.revision) + (queue.previews ?? []).map(\.revision))
        guard outstanding.contains(revision) || outstanding.count < queue.maxRevisions,
              (queue.previews?.count ?? 0) < queue.maxRevisions, bytes.count <= queue.maxBytes - used else { throw DeviceError.message("Preview capture is paused until queued previews finish.") }
        let preview = CatalogCapturedPreview(revision: revision, packageDigest: packageDigest, capturedAt: capturedAt, declaration: declaration)
        let directory = root.appendingPathComponent("catalog-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent(preview.id + ".png"), options: .atomic)
        queue.previews = (queue.previews ?? []) + [preview]
        var next = state; next.catalog = queue
        // The journal fsyncs PNG and directory before making the reference durable.
        try commit(next, stagedDirectory: "catalog-previews", captureCatalog: false)
    }
    func readCatalogPreview(_ preview: CatalogCapturedPreview, binding: CatalogBinding) throws -> Data {
        guard catalogCaptureAllowed(binding: binding), state.catalog?.previews?.contains(where: { $0.id == preview.id }) == true,
              UUID(uuidString: preview.id) != nil else { throw DeviceError.message("The preview account changed.") }
        let url = root.appendingPathComponent("catalog-previews").appendingPathComponent(preview.id + ".png")
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == preview.declaration.byteLength,
              preview.declaration.byteLength <= CatalogContract.previewBytes else { throw DeviceError.message("The saved preview is missing or unsafe.") }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw DeviceError.message("Unsafe saved screenshot directory.") }
        defer { _ = close(directory) }
        let descriptor = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw DeviceError.message("Unsafe saved screenshot file.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size == preview.declaration.byteLength else { throw DeviceError.message("The saved screenshot changed.") }
        let data = try handle.read(upToCount: preview.declaration.byteLength + 1) ?? Data()
        guard data.count == preview.declaration.byteLength, CatalogContract.digest(data) == preview.declaration.digest else { throw DeviceError.message("The saved preview changed.") }
        return data
    }
    func updateCatalogPreview(_ preview: CatalogCapturedPreview, binding: CatalogBinding) throws {
        guard catalogCaptureAllowed(binding: binding), let index = state.catalog?.previews?.firstIndex(where: { $0.id == preview.id }) else { throw DeviceError.message("The preview account changed.") }
        let original = state.catalog!.previews![index]
        guard original.revision == preview.revision, original.packageDigest == preview.packageDigest, original.capturedAt == preview.capturedAt, original.declaration == preview.declaration else { throw DeviceError.message("The immutable screenshot source changed.") }
        var next = state; next.catalog?.previews?[index] = preview; try commit(next)
    }
    func acknowledgeCatalogPreview(_ preview: CatalogCapturedPreview, binding: CatalogBinding) throws {
        guard catalogWorkAllowed(binding: binding), state.catalog?.binding == binding,
              state.catalog?.previews?.contains(where: { $0.id == preview.id && $0.operationID == preview.operationID }) == true else { throw DeviceError.message("The preview account changed.") }
        var next = state; next.catalog?.previews?.removeAll { $0.id == preview.id }
        var finished = next.catalog?.previewFinishedSources ?? []
        let source = preview.revision + ":" + preview.packageDigest
        if !finished.contains(source) { finished.append(source) }
        next.catalog?.previewFinishedSources = Array(finished.suffix(200))
        try commit(next)
        if UUID(uuidString: preview.id) != nil { try? FileManager.default.removeItem(at: root.appendingPathComponent("catalog-previews").appendingPathComponent(preview.id + ".png")) }
    }
}


extension ScreenLibrary {
    func bindCatalogPreview(_ candidate: CatalogPreviewCandidate, binding: CatalogBinding) throws {
        guard catalogCaptureAllowed(binding: binding), state.catalog?.libraryID == candidate.libraryID,
              state.catalog?.copies.values.contains(where: { $0.localScreenID == candidate.localScreenID }) == true else { throw DeviceError.message("The preview copy changed.") }
        guard let index = state.catalog?.previews?.firstIndex(where: { $0.revision == candidate.sourceRevisionID && $0.packageDigest == candidate.packageDigest }) else { return }
        var next = state; next.catalog?.previews?[index].candidate = candidate; try commit(next)
    }

    func catalogCaptureAllowed(binding: CatalogBinding) -> Bool {
        catalogCapabilityChecked && catalogWorkAllowed(binding: binding) && state.catalog?.binding == binding &&
            state.catalog?.captureAllowed == true && state.catalog?.authPaused == false
    }
}
