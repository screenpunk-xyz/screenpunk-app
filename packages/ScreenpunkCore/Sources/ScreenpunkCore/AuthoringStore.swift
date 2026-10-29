import Foundation

public enum AuthoringStoreError: LocalizedError {
    case invalid(String), conflict(String)
    public var errorDescription: String? { switch self { case .invalid(let s), .conflict(let s): return s } }
}
public struct AuthoringPreferenceOutboxEntry: Codable, Equatable, Sendable {
    public var id: String
    public var record: PreferenceRecordV1
    public var baseCloudRevision: Int?
    public init(id: String, record: PreferenceRecordV1, baseCloudRevision: Int?) { self.id = id; self.record = record; self.baseCloudRevision = baseCloudRevision }
    public var mutation: PreferenceMutationV1 {
        if record.deleted, let baseCloudRevision { return .init(kind: "delete", id: record.id, expectedRevision: baseCloudRevision) }
        var cloud = record; cloud.revision = (baseCloudRevision ?? 0) + 1
        return .init(kind: "upsert", id: record.id, expectedRevision: baseCloudRevision, record: cloud)
    }
}
public struct AuthoringPreferenceConflict: Codable, Equatable, Sendable {
    public var id: String
    public var local: PreferenceRecordV1
    public var remote: PreferenceRecordV1?
    public init(id: String, local: PreferenceRecordV1, remote: PreferenceRecordV1?) { self.id = id; self.local = local; self.remote = remote }
}
/// Durable ownership of an immutable package. Lives in the same redo transaction as its snapshot.
public struct AuthoringRevisionPin: Codable, Equatable, Sendable {
    public var requestID: String
    public var profileID: String
    public var libraryID: String
    public var screenID: String
    public var revision: String
    public var byteLength: Int
    public init(requestID: String, profileID: String, libraryID: String, screenID: String, revision: String, byteLength: Int) {
        self.requestID = requestID; self.profileID = profileID; self.libraryID = libraryID
        self.screenID = screenID; self.revision = revision; self.byteLength = byteLength
    }
}
/// Embedded in the account's library index, never persisted in a second independent store.
public struct AuthoringStoreState: Codable, Equatable, Sendable {
    public var records: [String: PreferenceRecordV1] = [:]
    public var requests: [String: AuthoringRequestV1] = [:]
    // Optional for compatibility with pre-v2 indexes; never persisted independently.
    public var requestsV2: [String: AuthoringRequestV2]?
    public var revisionPins: [String: AuthoringRevisionPin]?
    public var receipts: [String: ApplicationReceiptV1] = [:]
    public var operationDigests: [String: String] = [:]
    public var requestDigests: [String: String] = [:]
    public var cloudRevisions: [String: Int] = [:]
    public var outbox: [AuthoringPreferenceOutboxEntry] = []
    public var conflicts: [AuthoringPreferenceConflict] = []
    public var acknowledgedReceiptIDs: Set<String> = []
    public var knownScreenIDs: Set<String>?
    public var requestDeviceIDs: [String: String]?
    public var quarantinedCancellationIDs: Set<String>?
    public var retiredRequestIDs: Set<String>?
    public var cancelledRequestIDs: Set<String>?
    public var syncCursor: String?
    public init() {}
}

public enum AuthoringStore {
    public static func preferences(in state: AuthoringStoreState, profileID: String, deviceID: String, screenID: String) -> [PreferenceRecordV1] {
        state.records.values.filter { record in
            !record.deleted && ((record.scope == "profile" && record.targetID == profileID) || (record.scope == "device" && record.targetID == deviceID) || (record.scope == "screen" && record.targetID == screenID))
        }.sorted { $0.id < $1.id }
    }
    public static func saveRequest(_ request: AuthoringRequestV1, in state: inout AuthoringStoreState) throws {
        _ = try AuthoringContract.validateRequest(JSONEncoder().encode(request))
        let digest = AuthoringContract.contentDigest(try AuthoringContract.encodedCanonical(request))
        if let existing = state.requestDigests[request.requestID] {
            guard existing == digest else { throw AuthoringStoreError.conflict("This request ID is already bound to a different immutable snapshot.") }
            if state.requests[request.requestID] != nil || (state.retiredRequestIDs ?? []).contains(request.requestID) { return }
        }
        guard !(state.retiredRequestIDs ?? []).contains(request.requestID), !(state.cancelledRequestIDs ?? []).contains(request.requestID) else { throw AuthoringStoreError.conflict("This request ID has already ended.") }
        compactSources(in: &state)
        guard state.requests.count + (state.requestsV2?.count ?? 0) < 32 else { throw AuthoringStoreError.invalid("Too many unfinished authoring snapshots are retained. Finish or cancel them before starting another.") }
        state.requests[request.requestID] = request
        var screens = state.knownScreenIDs ?? []; screens.insert(request.context.screenID); state.knownScreenIDs = screens
        state.requestDigests[request.requestID] = digest
        var devices = state.requestDeviceIDs ?? [:]; devices[request.requestID] = request.context.deviceID; state.requestDeviceIDs = devices
    }
    /// Pure preparation: callers atomically commit this state with any validated screen.
    public static func apply(_ result: AuthoringResultV1, to state: inout AuthoringStoreState, currentScreenRevision: String?, cancelled: Bool = false, now: Int64) throws -> ApplicationReceiptV1 {
        let digest = AuthoringContract.contentDigest(try AuthoringContract.encodedCanonical(result))
        if let bound = state.operationDigests[result.operationID] {
            guard bound == digest, let receipt = state.receipts[result.operationID] else { throw AuthoringStoreError.conflict("This operation ID was reused with different content.") }
            return receipt
        }
        guard !state.receipts.values.contains(where: { $0.requestID == result.requestID }) else { throw AuthoringStoreError.conflict("This request already has a terminal application receipt.") }
        guard let request = state.requests[result.requestID] else { throw AuthoringStoreError.invalid("The original immutable authoring request is missing.") }
        // Schema and request bindings are checked before even a rejected receipt is accepted.
        _ = try AuthoringContract.validateResult(JSONEncoder().encode(result), request: request)
        var status = "applied", message: String?
        if cancelled || (state.cancelledRequestIDs ?? []).contains(result.requestID) { status = "rejected"; message = "This request was cancelled on this device." }
        else if now >= request.deadlineAt { status = "rejected"; message = "The authoring request has expired." }
        else if request.context.baseRevision != currentScreenRevision { status = "conflict"; message = "The screen changed after this request started." }
        else if request.preferences.contains(where: { state.records[$0.id]?.revision != $0.revision || state.records[$0.id]?.deleted == true }) {
            status = "conflict"; message = "A preference changed after this request started."
        }
        if status == "applied", result.screen == nil, currentScreenRevision == nil,
           (result.preferenceMutations ?? []).contains(where: { ($0.record ?? state.records[$0.id])?.scope == "screen" }) {
            status = "rejected"; message = "Install a screen before saving a preference for that screen."
        }
        var next = state
        if status == "applied" {
            do {
                for mutation in result.preferenceMutations ?? [] {
                    try mutate(mutation, originRequestID: request.requestID, in: &next, allowedContext: request.context)
                }
            } catch AuthoringStoreError.conflict(let text) { status = "conflict"; message = text; next = state }
              catch AuthoringStoreError.invalid(let text) { status = "rejected"; message = text; next = state }
        }
        let receipt = ApplicationReceiptV1(requestID: result.requestID, operationID: result.operationID, inputDigest: result.inputDigest, status: status, appliedAt: now, message: message)
        next.operationDigests[result.operationID] = digest; next.receipts[result.operationID] = receipt
        state = next
        return receipt
    }
    public static func reject(_ result: AuthoringResultV1, reason: String, in state: inout AuthoringStoreState, now: Int64) throws -> ApplicationReceiptV1 {
        let digest = AuthoringContract.contentDigest(try AuthoringContract.encodedCanonical(result))
        if let bound = state.operationDigests[result.operationID] {
            guard bound == digest, let receipt = state.receipts[result.operationID] else { throw AuthoringStoreError.conflict("This operation ID was reused with different content.") }
            return receipt
        }
        guard !state.receipts.values.contains(where: { $0.requestID == result.requestID }) else { throw AuthoringStoreError.conflict("This request already has a terminal application receipt.") }
        guard let request = state.requests[result.requestID] else { throw AuthoringStoreError.invalid("The original immutable authoring request is missing.") }
        _ = try AuthoringContract.validateResult(JSONEncoder().encode(result), request: request)
        let receipt = ApplicationReceiptV1(requestID: result.requestID, operationID: result.operationID, inputDigest: result.inputDigest, status: "rejected", appliedAt: now, message: String(reason.prefix(2048)))
        state.operationDigests[result.operationID] = digest; state.receipts[result.operationID] = receipt
        return receipt
    }
    /// Retain immutable IDs, digests and receipts for replay, but release source payloads
    /// after acknowledgement. Unacknowledged/in-flight snapshots are capped at 32.
    public static func compactSources(in state: inout AuthoringStoreState) {
        let acknowledgedRequests = Set(state.receipts.values.filter { state.acknowledgedReceiptIDs.contains($0.operationID) }.map(\.requestID))
        for id in acknowledgedRequests { retireRequest(id: id, in: &state) }
    }
    /// A confirmed terminal delivery has no result left to apply. Release its large
    /// immutable source while retaining the ID binding and a late-result tombstone.
    public static func retireRequest(id: String, in state: inout AuthoringStoreState) {
        if let request = state.requests[id] { var devices = state.requestDeviceIDs ?? [:]; devices[id] = request.context.deviceID; state.requestDeviceIDs = devices }
        if let request = state.requestsV2?[id] { var devices = state.requestDeviceIDs ?? [:]; devices[id] = request.context.deviceID; state.requestDeviceIDs = devices }
        state.requestsV2?.removeValue(forKey: id)
        state.revisionPins?.removeValue(forKey: id)
        state.requests.removeValue(forKey: id)
        var retired = state.retiredRequestIDs ?? []; retired.insert(id); state.retiredRequestIDs = retired
    }
    public static func saveRequest(_ request: AuthoringRequestV2, pin: AuthoringRevisionPin?, in state: inout AuthoringStoreState) throws {
        _ = try AuthoringV2Contract.validateRequest(JSONEncoder().encode(request))
        let digest = AuthoringContract.contentDigest(try AuthoringContract.encodedCanonical(request))
        if let existing = state.requestDigests[request.requestID] {
            guard existing == digest else { throw AuthoringStoreError.conflict("This request ID is already bound to a different immutable snapshot.") }
            if state.requestsV2?[request.requestID] != nil || (state.retiredRequestIDs ?? []).contains(request.requestID) { return }
        }
        guard !(state.retiredRequestIDs ?? []).contains(request.requestID), !(state.cancelledRequestIDs ?? []).contains(request.requestID), state.requests[request.requestID] == nil else { throw AuthoringStoreError.conflict("This request ID has already ended or belongs to another contract.") }
        if let revision = request.context.baseRevision {
            guard let pin, pin.requestID == request.requestID, pin.profileID == request.context.profileID,
                  pin.libraryID == request.context.libraryID, pin.screenID == request.context.screenID,
                  pin.revision == revision, pin.byteLength == request.context.currentScreen?.files.reduce(0, { $0 + $1.byteLength }) else { throw AuthoringStoreError.invalid("The immutable base package must be pinned before preparing delivery.") }
        } else if pin != nil { throw AuthoringStoreError.invalid("A new screen cannot pin an existing package.") }
        compactSources(in: &state)
        guard state.requests.count + (state.requestsV2?.count ?? 0) < 32,
              (state.revisionPins?.values.reduce(0, { $0 + $1.byteLength }) ?? 0) + (pin?.byteLength ?? 0) <= 32 * 204_800 else { throw AuthoringStoreError.invalid("Too many unfinished authoring snapshots are retained. Finish or cancel them before starting another.") }
        var requests = state.requestsV2 ?? [:]; requests[request.requestID] = request; state.requestsV2 = requests
        if let pin { var pins = state.revisionPins ?? [:]; pins[request.requestID] = pin; state.revisionPins = pins }
        state.knownScreenIDs = (state.knownScreenIDs ?? []).union([request.context.screenID])
        state.requestDigests[request.requestID] = digest
        var devices = state.requestDeviceIDs ?? [:]; devices[request.requestID] = request.context.deviceID; state.requestDeviceIDs = devices
    }
    /// Pure CAS/preference preparation. The caller materializes assets before atomically committing this state.
    public static func apply(_ result: AuthoringResultV2, to state: inout AuthoringStoreState, currentScreenRevision: String?, cancelled: Bool = false, now: Int64) throws -> ApplicationReceiptV1 {
        let digest = AuthoringContract.contentDigest(try AuthoringContract.encodedCanonical(result))
        if let bound = state.operationDigests[result.operationID] {
            guard bound == digest, let receipt = state.receipts[result.operationID] else { throw AuthoringStoreError.conflict("This operation ID was reused with different content.") }
            return receipt
        }
        guard !state.receipts.values.contains(where: { $0.requestID == result.requestID }) else { throw AuthoringStoreError.conflict("This request already has a terminal application receipt.") }
        guard let request = state.requestsV2?[result.requestID] else { throw AuthoringStoreError.invalid("The original immutable authoring request is missing.") }
        _ = try AuthoringV2Contract.validateResult(JSONEncoder().encode(result), request: request)
        var status = "applied", message: String?
        if cancelled || (state.cancelledRequestIDs ?? []).contains(result.requestID) { status = "rejected"; message = "This request was cancelled on this device." }
        else if now >= request.deadlineAt { status = "rejected"; message = "The authoring request has expired." }
        else if request.context.baseRevision != currentScreenRevision { status = "conflict"; message = "The screen changed after this request started." }
        else if request.preferences.contains(where: { state.records[$0.id]?.revision != $0.revision || state.records[$0.id]?.deleted == true }) { status = "conflict"; message = "A preference changed after this request started." }
        if status == "applied", result.screen == nil, currentScreenRevision == nil,
           (result.preferenceMutations ?? []).contains(where: { ($0.record ?? state.records[$0.id])?.scope == "screen" }) {
            status = "rejected"; message = "Install a screen before saving a preference for that screen."
        }
        var next = state
        if status == "applied" {
            do {
                for mutation in result.preferenceMutations ?? [] {
                    try mutate(mutation, originRequestID: request.requestID, in: &next, allowedContext: try request.legacyRequest(currentScreen: nil).context)
                }
            } catch AuthoringStoreError.conflict(let text) { status = "conflict"; message = text; next = state }
              catch AuthoringStoreError.invalid(let text) { status = "rejected"; message = text; next = state }
        }
        let receipt = ApplicationReceiptV1(requestID: result.requestID, operationID: result.operationID, inputDigest: result.inputDigest, status: status, appliedAt: now, message: message)
        next.operationDigests[result.operationID] = digest; next.receipts[result.operationID] = receipt
        next.revisionPins?.removeValue(forKey: result.requestID)
        state = next
        return receipt
    }
    public static func reject(_ result: AuthoringResultV2, reason: String, in state: inout AuthoringStoreState, now: Int64) throws -> ApplicationReceiptV1 {
        let digest = AuthoringContract.contentDigest(try AuthoringContract.encodedCanonical(result))
        if let bound = state.operationDigests[result.operationID] {
            guard bound == digest, let receipt = state.receipts[result.operationID] else { throw AuthoringStoreError.conflict("This operation ID was reused with different content.") }
            return receipt
        }
        guard !state.receipts.values.contains(where: { $0.requestID == result.requestID }) else { throw AuthoringStoreError.conflict("This request already has a terminal application receipt.") }
        guard let request = state.requestsV2?[result.requestID] else { throw AuthoringStoreError.invalid("The original immutable authoring request is missing.") }
        _ = try AuthoringV2Contract.validateResult(JSONEncoder().encode(result), request: request)
        let receipt = ApplicationReceiptV1(requestID: result.requestID, operationID: result.operationID, inputDigest: result.inputDigest, status: "rejected", appliedAt: now, message: String(reason.prefix(2048)))
        state.operationDigests[result.operationID] = digest; state.receipts[result.operationID] = receipt
        state.revisionPins?.removeValue(forKey: result.requestID)
        return receipt
    }
    public static func mutate(_ mutation: PreferenceMutationV1, originRequestID: String, in state: inout AuthoringStoreState, allowedContext: AuthoringContextV1? = nil) throws {
        let old = state.records[mutation.id]
        guard old?.revision == mutation.expectedRevision else { throw AuthoringStoreError.conflict("Preference \(mutation.id) changed; review its current value before saving.") }
        var record: PreferenceRecordV1
        if mutation.kind == "delete" {
            guard var existing = old, !existing.deleted else { throw AuthoringStoreError.conflict("The preference has already been deleted.") }
            existing.deleted = true; existing.revision += 1; existing.originRequestID = originRequestID; record = existing
        } else if mutation.kind == "upsert", let proposed = mutation.record {
            guard proposed.id == mutation.id, proposed.revision == (old?.revision ?? 0) + 1, proposed.originRequestID == originRequestID, !proposed.deleted else { throw AuthoringStoreError.invalid("Invalid preference revision or origin.") }
            if let old { guard old.scope == proposed.scope, old.targetID == proposed.targetID else { throw AuthoringStoreError.invalid("Preference scope and owner cannot change.") } }
            record = proposed
        } else { throw AuthoringStoreError.invalid("Unknown preference mutation.") }
        guard ["profile", "device", "screen"].contains(record.scope), !record.id.isEmpty, !record.targetID.isEmpty, !record.category.isEmpty else { throw AuthoringStoreError.invalid("Invalid preference scope or identifier.") }
        if let context = allowedContext {
            guard (record.scope == "profile" && record.targetID == context.profileID) || (record.scope == "device" && record.targetID == context.deviceID) || (record.scope == "screen" && record.targetID == context.screenID) else { throw AuthoringStoreError.invalid("Preference target is outside this request.") }
        }
        switch record.value { case .null, .bool: break; case .string(let text): guard text.utf8.count <= 4096 else { throw AuthoringStoreError.invalid("Preference text is too long.") }; case .number(let n): guard n.isFinite else { throw AuthoringStoreError.invalid("Preference number must be finite.") }; default: throw AuthoringStoreError.invalid("Preference values must be scalar.") }
        _ = try AuthoringContract.validatePreferenceRecord(JSONEncoder().encode(record))
        state.records[record.id] = record
        let base = state.cloudRevisions[record.id]
        state.outbox.removeAll { $0.record.id == record.id }
        // An unsynced creation deleted locally has nothing to delete in Cloud.
        if !record.deleted || base != nil { state.outbox.append(.init(id: UUID().uuidString, record: record, baseCloudRevision: base)) }
    }
    /// Merge individual records. A concurrent edit is retained alongside the remote value.
    /// accepted must refer to exactly the sent outbox entry: a later local edit is not lost.
    public static func mergeCloud(records: [PreferenceRecordV1], accepted: [String: Int], sent: [AuthoringPreferenceOutboxEntry], conflicts: [String: PreferenceRecordV1?], cursor: String? = nil, in state: inout AuthoringStoreState) {
        for entry in sent {
            guard let revision = accepted[entry.record.id], revision >= (state.cloudRevisions[entry.record.id] ?? 0) else { continue }
            state.cloudRevisions[entry.record.id] = revision
            if let local = state.records[entry.record.id], local.deleted, local.revision != entry.record.revision,
               !state.outbox.contains(where: { $0.record.id == entry.record.id }) {
                state.outbox.append(.init(id: UUID().uuidString, record: local, baseCloudRevision: revision))
            }
            if let current = state.outbox.firstIndex(where: { $0.record.id == entry.record.id }) {
                if state.outbox[current].id == entry.id { state.outbox.remove(at: current) }
                else if state.outbox[current].baseCloudRevision != revision {
                    // A rebase changes the immutable wire mutation. The previous ID may
                    // already have reached Cloud, so bind the new payload to a fresh ID.
                    state.outbox[current].baseCloudRevision = revision
                    state.outbox[current].id = UUID().uuidString
                }
            }
        }
        for remote in records {
            if remote.revision < (state.cloudRevisions[remote.id] ?? 0) { continue }
            // A deleted unsynced creation may have reached Cloud before a crash. Keep
            // the local tombstone and ask for explicit resolution instead of reviving it.
            if let local = state.records[remote.id], local.deleted, state.cloudRevisions[remote.id] == nil, !remote.deleted {
                state.conflicts.removeAll { $0.id == remote.id }
                state.conflicts.append(.init(id: remote.id, local: local, remote: remote))
                continue
            }
            if let local = state.records[remote.id], let pending = state.outbox.first(where: { $0.record.id == remote.id }) {
                if pending.baseCloudRevision != remote.revision {
                    state.conflicts.removeAll { $0.id == remote.id }
                    state.conflicts.append(.init(id: remote.id, local: local, remote: remote))
                }
                continue
            }
            state.cloudRevisions[remote.id] = remote.revision
            // Cloud revisions never replace the local CAS counter.
            if var local = state.records[remote.id] {
                if local.scope != remote.scope || local.targetID != remote.targetID || local.category != remote.category || local.value != remote.value || local.deleted != remote.deleted || local.originRequestID != remote.originRequestID {
                    let revision = local.revision + 1; local = remote; local.revision = revision; state.records[remote.id] = local
                }
            } else { var local = remote; local.revision = 1; state.records[remote.id] = local }
        }
        for (id, remote) in conflicts {
            guard let local = state.records[id] else { continue }
            if let remote, remote.revision < (state.cloudRevisions[id] ?? 0) { continue }
            if let sentEntry = sent.first(where: { $0.record.id == id }) {
                if let pending = state.outbox.first(where: { $0.record.id == id }), pending.id != sentEntry.id,
                   pending.baseCloudRevision == remote?.revision { continue }
                if state.outbox.first(where: { $0.record.id == id }) == nil,
                   let remote, state.cloudRevisions[id] == remote.revision,
                   local.scope == remote.scope, local.targetID == remote.targetID, local.category == remote.category,
                   local.value == remote.value, local.deleted == remote.deleted { continue }
            }
            state.conflicts.removeAll { $0.id == id }; state.conflicts.append(.init(id: id, local: local, remote: remote))
        }
        state.syncCursor = cursor ?? state.syncCursor
    }
    public static func resolveConflict(id: String, keepingLocal: Bool, in state: inout AuthoringStoreState) throws {
        guard let conflict = state.conflicts.first(where: { $0.id == id }), let local = state.records[id] else { throw AuthoringStoreError.invalid("This preference conflict no longer exists.") }
        state.conflicts.removeAll { $0.id == id }; state.outbox.removeAll { $0.record.id == id }
        state.cloudRevisions[id] = conflict.remote?.revision
        if keepingLocal {
            if !local.deleted || conflict.remote != nil { state.outbox.append(.init(id: UUID().uuidString, record: local, baseCloudRevision: conflict.remote?.revision)) }
        } else if var remote = conflict.remote {
            remote.revision = local.revision + 1; state.records[id] = remote
        } else {
            var deleted = local; deleted.deleted = true; deleted.revision += 1; state.records[id] = deleted
        }
    }
}
