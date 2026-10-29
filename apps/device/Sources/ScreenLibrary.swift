import Foundation
import ScreenpunkApple
import ScreenpunkCore

/// One atomic metadata replacement commits an installation. Failed writes never replace the current screen.
@MainActor final class ScreenLibrary {
    struct Saved: Codable, Identifiable { let id: String; let revision: String; let artifact: ScreenArtifact }
    struct State: Codable { var screens: [Saved] = []; var selectedID: String?; var previous: Saved?; var lastRequest: String?; var pendingID: String?; var pendingScreenID: String?; var consumedID: String?; var cancelledRequests: [String]?; var cancelIntents: [String]?; var lastInstruction: String?; var submissionKey: String?; var submissionText: String?; var submissionScreen: ScreenArtifact?; var requestDeadline: Double?; var authoring: AuthoringStoreState?; var linkedProfile: LocalProfileDescriptor?; var localRequestIDs: Set<String>? }
    private(set) var state = State()
    private let root: URL
    private let libraryOwner: String
    private var temporary: LocalTemporaryActivationController!
    private var journal: AuthoringJournal!
    init(accountID: String, rootDirectory: URL? = nil, journalFault: AuthoringJournal.Fault? = nil) throws {
        libraryOwner = accountID
        root = try rootDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ScreenpunkScreens", isDirectory: true).appendingPathComponent(accountID.data(using: .utf8)!.base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-"), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        journal = try AuthoringJournal(root: root, fault: journalFault)
        if let data = try journal.recover() { state = try JSONDecoder().decode(State.self, from: data) }
        try retireCancelledLocalSources()
        temporary = try LocalTemporaryActivationController(root: root, owner: accountID)
        try reconcileTemporary()
        // Recover the index (including unresolved pins) before any startup pruning.
        pruneUnusedRevisions()
    }
    convenience init(profile: LocalProfileDescriptor, rootDirectory: URL? = nil, journalFault: AuthoringJournal.Fault? = nil) throws {
        try self.init(accountID: profile.libraryOwner, rootDirectory: rootDirectory, journalFault: journalFault)
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
    var selected: Saved? { state.screens.first { $0.id == state.selectedID } }
    func store(for screen: Saved) throws -> PackageAssetStore { try PackageAssetStore.load(directory: root.appendingPathComponent(screen.revision)) }
    func install(_ artifact: ScreenArtifact, requestID: String, replacing id: String?) throws {
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
            next.selectedID = saved.id; next.lastRequest = requestID
            committing = true
            try commit(next, stagedDirectory: revision)
            pruneUnusedRevisions()
        } catch { if !committing { try? FileManager.default.removeItem(at: directory) }; throw error }
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
    func select(offset: Int) throws {
        guard !state.screens.isEmpty else { return }
        try temporary.manualSelection()
        let current = state.screens.firstIndex { $0.id == state.selectedID } ?? 0
        var next = state; next.selectedID = next.screens[(current + offset + state.screens.count) % state.screens.count].id
        try commit(next)
    }
    func remove(_ id: String) throws {
        guard state.screens.contains(where: { $0.id == id }) else { return }
        guard state.pendingID == nil, state.submissionKey == nil else {
            throw DeviceError.message("Finish or cancel the current request before removing a screen.")
        }
        // A manual library change ends temporary activation and its restore target.
        try temporary.manualSelection()
        var next = state
        var authoring = next.authoring ?? .init(); var knownScreens = authoring.knownScreenIDs ?? []; knownScreens.insert(id); authoring.knownScreenIDs = knownScreens; next.authoring = authoring
        next.screens.removeAll { $0.id == id }
        if next.selectedID == id { next.selectedID = next.screens.first?.id }
        if next.previous?.id == id { next.previous = nil }
        if next.pendingScreenID == id { next.pendingScreenID = nil }
        try commit(next)
        pruneUnusedRevisions()
    }
    func newScreen() throws { try temporary.manualSelection(); var next = state; next.selectedID = nil; try commit(next) }
    /// Only call from an authenticated, account-scoped external command handler.
    func activateTemporarily(id: String, screenID: String, expiresAt: Date) throws {
        guard state.screens.contains(where: { $0.id == screenID }), let selected = state.selectedID else { throw DeviceError.message("Temporary screen is not installed.") }
        try applyTemporary(temporary.activate(id: id, target: screenID, expiresAt: expiresAt, selected: selected))
    }
    func endTemporary(id: String) throws {
        guard let selected = state.selectedID else { return }; try applyTemporary(temporary.end(id: id, selected: selected))
    }
    func reconcileTemporary() throws {
        guard let selected = state.selectedID else { return }; try applyTemporary(temporary.reconcile(selected: selected))
    }
    private func applyTemporary(_ id: String?) throws {
        guard let id, state.screens.contains(where: { $0.id == id }) else { return }
        var next = state; next.selectedID = id; try commit(next); try temporary.acknowledgeSelection()
    }
    func rollback() throws {
        try temporary.manualSelection()
        guard let previous = state.previous, let position = state.screens.firstIndex(where: { $0.id == previous.id }) else { return }
        var next = state; next.previous = next.screens[position]; next.screens[position] = previous; next.selectedID = previous.id
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
    private func commit(_ next: State, stagedDirectory: String? = nil) throws {
        do {
            try journal.commit(JSONEncoder().encode(next), stagedDirectory: stagedDirectory)
            state = next
        } catch {
            // A durable intent may already have committed. Refresh before another mutation.
            if let recovered = try? journal.recover(), let decoded = try? JSONDecoder().decode(State.self, from: recovered) { state = decoded }
            throw error
        }
    }
    private func pruneUnusedRevisions() {
        let retained = Set(state.screens.map(\.revision) + [state.previous?.revision].compactMap { $0 } + (state.authoring?.revisionPins?.values.map(\.revision) ?? []))
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if UUID(uuidString: url.lastPathComponent) != nil && !retained.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
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
            next.selectedID = saved.id; next.lastRequest = result.requestID
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
                next.selectedID = saved.id; next.lastRequest = result.requestID
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
