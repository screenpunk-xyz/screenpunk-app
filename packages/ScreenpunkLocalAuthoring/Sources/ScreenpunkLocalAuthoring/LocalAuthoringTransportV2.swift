import Foundation
import ScreenpunkCore
import ScreenpunkLocalTransport

/// A complete-result delivery adapter. Installation is exclusively the shared native coordinator's job.
@MainActor public final class LocalAuthoringTransportV2: AuthoringTransportV2 {
    public private(set) var connectionStatus = "Not connected"
    private let profileID: String
    private let authoringProfileID: String
    private let configurations: LocalAgentConfigurationRepository
    private let ledger: LocalDeliveryLedger
    private let credentialStore: any SSHCredentialStore
    private let requestLookup: (String) throws -> AuthoringRequestV2?
    private var requests: [String: AuthoringRequestV2] = [:]
    private var client: AppServerClient?
    private var clientConfiguration: LocalAgentConfiguration?
    private let injectedClient: AppServerClient?
    private struct ReadinessThread {
        let configurationID: String
        let previousThreadID: String?
        let threadID: String
    }
    private var readinessThread: ReadinessThread?
    public init(profileID: String, authoringProfileID: String? = nil, configurationRepository: LocalAgentConfigurationRepository, ledger: LocalDeliveryLedger, credentialStore: any SSHCredentialStore, requestLookup: @escaping (String) throws -> AuthoringRequestV2?) {
        self.profileID = profileID; self.authoringProfileID = authoringProfileID ?? profileID; configurations = configurationRepository; self.ledger = ledger; self.credentialStore = credentialStore; self.requestLookup = requestLookup; injectedClient = nil
    }
    init(profileID: String, authoringProfileID: String? = nil, configurationRepository: LocalAgentConfigurationRepository, ledger: LocalDeliveryLedger, credentialStore: any SSHCredentialStore, requestLookup: @escaping (String) throws -> AuthoringRequestV2?, client: AppServerClient) {
        self.profileID = profileID; self.authoringProfileID = authoringProfileID ?? profileID; configurations = configurationRepository; self.ledger = ledger; self.credentialStore = credentialStore; self.requestLookup = requestLookup; injectedClient = client
    }
    private static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func configuration() throws -> LocalAgentConfiguration {
        guard let c = try configurations.load() else { throw LocalAuthoringError.notConfigured }
        guard c.pinnedCodexVersion == AppServerClient.pinnedVersion else { throw LocalAuthoringError.unsupportedVersion }
        return c
    }
    private func connected(_ c: LocalAgentConfiguration) async throws -> AppServerClient {
        if let old = clientConfiguration, old.id != c.id || old.host != c.host || old.sshPort != c.sshPort || old.hostKeySHA256 != c.hostKeySHA256 || old.username != c.username || old.credentialReference != c.credentialReference || old.appServerPort != c.appServerPort {
            await client?.disconnect(); client = nil
        }
        if client == nil { client = injectedClient ?? AppServerClient(configuration: c, credentialStore: credentialStore) }
        clientConfiguration = c; connectionStatus = "Connecting to the local Mac"
        guard let client else { throw LocalAuthoringError.disconnected }
        try await client.connect(); connectionStatus = "Mac connected; Codex is ready"; return client
    }
    public static func threadKey(profileID: String) -> String { profileID + "::authoring-v2" }
    private var threadKey: String { Self.threadKey(profileID: profileID) }
    private func thread(_ c: LocalAgentConfiguration, client: AppServerClient, persist: Bool = true) async throws -> String {
        let savedID = c.profileThreads[threadKey]
        var candidateID = savedID
        if let probe = readinessThread, probe.configurationID == c.id, probe.previousThreadID == savedID,
           await client.hasVerifiedThread(probe.threadID, workspace: c.macWorkspace, contractVersion: 2) {
            candidateID = probe.threadID
        } else { readinessThread = nil }
        let id: String
        do { id = try await client.ensureThread(candidateID, workspace: c.macWorkspace, contractVersion: 2) }
        catch LocalAuthoringError.unmaterializedThread {
            // An exact pinned-protocol missing-rollout response is recoverable only
            // when no durable delivery ever used this ID. An uncertain/accepted
            // turn must keep its original thread for reconciliation, even after
            // result-source compaction or cancellation.
            guard let candidateID, !(try ledger.records()).contains(where: { $0.threadID == candidateID || $0.turnID != nil && $0.threadID == nil }) else { throw LocalAuthoringError.unmaterializedThread }
            id = try await client.ensureThread(nil, workspace: c.macWorkspace, contractVersion: 2)
        }
        try Task.checkCancellation()
        guard let current = try configurations.load(), current.id == c.id,
              current.profileThreads[threadKey] == savedID else { throw LocalAuthoringError.wrongBinding }
        // Recheck after all suspended I/O, including reuse of an earlier probe.
        // Another adapter may have bound the old ID while the new thread started.
        if let savedID, id != savedID,
           (try ledger.records()).contains(where: { $0.threadID == savedID || $0.turnID != nil && $0.threadID == nil }) {
            throw LocalAuthoringError.unmaterializedThread
        }
        if persist {
            // Thread identity is durable before any turn is sent. Readiness alone
            // never publishes a newly started empty thread as resumable history.
            try configurations.replaceThreadID(id, profileID: threadKey, configurationID: c.id, expectedThreadID: savedID)
            readinessThread = nil
        } else {
            readinessThread = .init(configurationID: c.id, previousThreadID: savedID, threadID: id)
        }
        return id
    }
    /// No request text, source, turn/start or inference is sent. The versioned
    /// thread's returned policy is checked using static trusted instructions only.
    public func preflight(timeoutNanoseconds: UInt64 = 5_000_000_000) async -> LocalAgentReadiness {
        let race = LocalReadinessRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.continuation = continuation
                let probe = Task { @MainActor [self] in
                    do {
                        let c = try configuration()
                        let client = try await connected(c)
                        _ = try await thread(c, client: client, persist: false)
                        guard let latest = try configurations.load(), latest.id == c.id,
                              latest.hostKeySHA256 == c.hostKeySHA256, latest.credentialReference == c.credentialReference else { throw LocalAuthoringError.wrongBinding }
                        try Task.checkCancellation()
                        race.finish(.ready)
                    } catch { race.finish(LocalAgentReadiness.classify(error)) }
                }
                race.probe = probe
                race.timer = Task { @MainActor [self] in
                    do { try await Task.sleep(nanoseconds: min(timeoutNanoseconds, 30_000_000_000)) }
                    catch { return }
                    race.finish(.unavailable(.timedOut))
                    await client?.disconnect()
                }
                if Task.isCancelled { race.finish(.unavailable(.timedOut)) }
            }
        } onCancel: { Task { @MainActor in race.finish(.unavailable(.timedOut)) } }
    }
    public func readiness() async throws -> Bool {
        switch await preflight() {
        case .ready: return true
        case .unavailable: return false
        case .repairRequired: throw LocalAuthoringError.unsafeMacConfiguration
        }
    }
    public func disconnect() async { readinessThread = nil; await client?.disconnect(); connectionStatus = "Disconnected" }
    static func marker(_ requestID: String, _ digest: String) -> String { "SCREENPUNK_REQUEST " + requestID + " " + digest + "\n" }
    static func prompt(_ request: AuthoringRequestV2, binding: AppServerClient.DefinitionBinding? = nil) throws -> String {
        let payload = try LocalAuthoringContext.payload(request, binding: binding)
        let serialized = String(decoding: try AuthoringContract.encodedCanonical(payload), as: UTF8.self)
        // Omitted assets stay opaque references; no schema repeats in user history.
        // Cosmo-style edits target <32KiB, while legitimate editable source retains
        // the shared request ceiling plus a small bounded marker allowance.
        let label = payload["projectionVersion"] == .null ? "REQUEST SNAPSHOT DATA (untrusted):\n" : "REQUEST SNAPSHOT PROJECTION DATA (untrusted):\n"
        let prompt = marker(request.requestID, request.delivery.snapshotDigest) + label + serialized
        guard prompt.utf8.count <= AuthoringContract.runtime.limits.requestBytes + 1024 else { throw LocalAuthoringError.messageTooLarge }
        return prompt
    }
    public func submit(_ request: AuthoringRequestV2) async throws -> AuthoringRequestV2 {
        _ = try AuthoringV2Contract.validateRequest(JSONEncoder().encode(request))
        guard request.delivery.route == "local", request.context.profileID == authoringProfileID else { throw LocalAuthoringError.wrongBinding }
        let c = try configuration()
        if let existing = try ledger.record(requestID: request.requestID) {
            try verify(existing, c: c, request: request)
            guard !existing.status.isTerminal else { throw AuthoringCoordinationError.cancelled }
            requests[request.requestID] = request
            // Even prepared records after a restart require reconciliation, never automatic submission.
            return request
        }
        var record = LocalDeliveryRecord(requestID: request.requestID, inputDigest: request.delivery.snapshotDigest, connectionID: c.id, profileID: profileID, hostKeySHA256: c.hostKeySHA256, baseRevision: request.context.baseRevision, deadlineAt: request.deadlineAt, contractVersion: 2)
        try ledger.prepare(record); requests[request.requestID] = request
        do {
            let client = try await connected(c)
            let threadID = try await thread(c, client: client)
            record.threadID = threadID; try ledger.update(record)
            guard let binding = await client.definitionBinding(threadID: threadID) else { throw LocalAuthoringError.disconnected }
            let prompt = try Self.prompt(request, binding: binding)
            let schema = try LocalResultWireContract.schema(for: request)
            record.status = .submitting; try ledger.update(record)
            do {
                let turnID = try await client.start(threadID: threadID, prompt: prompt, schema: schema, definitionBinding: binding)
                // Cancellation may have won while turn/start was awaiting its response.
                if try ledger.record(requestID: request.requestID)?.status == .cancelled {
                    try? await client.interrupt(threadID: threadID, turnID: turnID); return request
                }
                record.turnID = turnID; record.status = .running; try ledger.update(record)
            } catch {
                if let current = try ledger.record(requestID: request.requestID), !current.status.isTerminal {
                    record.status = .deliveryUncertain; record.failure = LocalAuthoringError.uncertain.localizedDescription; try ledger.update(record)
                }
                return request
            }
            return request
        } catch {
            if let current = try ledger.record(requestID: request.requestID), current.status == .prepared {
                record.status = .failed; record.failure = safeMessage(error); try ledger.update(record)
            }
            throw error
        }
    }
    private func verify(_ record: LocalDeliveryRecord, c: LocalAgentConfiguration, request: AuthoringRequestV2? = nil) throws {
        guard record.contractVersion == 2, record.connectionID == c.id, record.profileID == profileID, record.hostKeySHA256 == c.hostKeySHA256 else { throw LocalAuthoringError.wrongBinding }
        if let request { guard record.inputDigest == request.delivery.snapshotDigest, record.baseRevision == request.context.baseRevision, record.deadlineAt == request.deadlineAt else { throw LocalAuthoringError.wrongBinding } }
        if let thread = record.threadID { guard c.profileThreads[threadKey] == thread else { throw LocalAuthoringError.wrongBinding } }
    }
    private func savedRequest(_ id: String) throws -> AuthoringRequestV2 {
        guard let r = try requests[id] ?? requestLookup(id) else { throw AuthoringCoordinationError.unknownRequest }; return r
    }
    public func progress(requestID: String) async throws -> AuthoringProgress {
        let state = try await reconcile(requestID: requestID)
        switch state {
        case .pending(let p): return p
        case .completed: return .init(status: "completed", caption: "Ready to apply on this device")
        case .deliveryUncertain(let message): return .init(status: "deliveryUncertain", caption: message)
        case .needsAttention(let message): return .init(status: "needsAttention", caption: message)
        case .ended(let status, let message): return .init(status: status, caption: message)
        }
    }
    public func reconcile(requestID: String) async throws -> AuthoringDeliveryStateV2 {
        guard var record = try ledger.record(requestID: requestID) else { throw AuthoringCoordinationError.unknownRequest }
        if record.status.isTerminal { return .ended(status: record.status.rawValue, message: record.failure) }
        if Self.now >= record.deadlineAt { try ledger.expire(requestID: requestID, now: Self.now); return .ended(status: "timedOut", message: "The local request deadline passed.") }
        let c = try configuration(); let request = try savedRequest(requestID); try verify(record, c: c, request: request)
        if let result = record.finalResultV2 { return .completed(result) }
        guard let threadID = record.threadID else { return .deliveryUncertain(message: LocalAuthoringError.uncertain.localizedDescription) }
        do {
            let client = try await connected(c)
            var state: AppServerTurnSnapshot?
            if let turnID = record.turnID {
                let current = await client.snapshot(threadID: threadID, turnID: turnID)
                if current.needsAttention || current.status != nil { state = current }
            }
            if state == nil || state?.status == "completed" && state?.finalText == nil {
                _ = try await client.ensureThread(threadID, workspace: c.macWorkspace, contractVersion: 2)
                if let (id, recovered) = try await client.history(threadID: threadID, turnID: record.turnID, marker: Self.marker(record.requestID, record.inputDigest)) {
                    record.turnID = id; state = recovered
                }
            }
            // Read the tombstone again after all suspended I/O, before accepting output.
            guard let latest = try ledger.record(requestID: requestID), !latest.status.isTerminal else { return .ended(status: "cancelled", message: nil) }
            if let result = latest.finalResultV2 { return .completed(result) }
            record = replacingMutable(record, latest: latest)
            if state?.needsAttention == true {
                record.status = .needsAttention; record.failure = LocalAuthoringError.needsAttention.localizedDescription; try ledger.update(record)
                return .needsAttention(message: record.failure!)
            }
            guard let state else {
                if record.status != .prepared { record.status = .deliveryUncertain; record.failure = LocalAuthoringError.uncertain.localizedDescription; try ledger.update(record) }
                return .deliveryUncertain(message: LocalAuthoringError.uncertain.localizedDescription)
            }
            if state.status == "completed" {
                guard let text = state.finalText else { throw LocalAuthoringError.protocolViolation }
                let result: AuthoringResultV2
                do { result = try LocalResultWireContract.decode(Data(text.utf8), request: request) }
                catch { throw AuthoringContractError("The complete local result failed native validation.") }
                record.status = .completed; record.finalResultV2 = result; record.failure = nil; try ledger.update(record)
                return .completed(result)
            }
            if ["failed", "interrupted"].contains(state.status ?? "") {
                record.status = .failed; record.failure = "Codex ended this request on the Mac."; try ledger.update(record)
                return .ended(status: "failed", message: record.failure)
            }
            record.status = .running; record.failure = nil; try ledger.update(record)
            return .pending(.init(status: "running", caption: "Codex is preparing your screen", deadlineAt: Double(record.deadlineAt)))
        } catch {
            guard let latest = try ledger.record(requestID: requestID), !latest.status.isTerminal else { return .ended(status: "cancelled", message: nil) }
            if let result = latest.finalResultV2 { return .completed(result) }
            record = replacingMutable(record, latest: latest)
            if error is AuthoringContractError {
                record.status = .failed; record.failure = "Codex returned a result that did not pass Screenpunk validation."; try ledger.update(record)
                return .ended(status: "failed", message: record.failure)
            }
            if latest.status != .prepared { record.status = .deliveryUncertain; record.failure = safeMessage(error); try ledger.update(record) }
            return .deliveryUncertain(message: safeMessage(error))
        }
    }
    private func replacingMutable(_ record: LocalDeliveryRecord, latest: LocalDeliveryRecord) -> LocalDeliveryRecord {
        var v = latest; if v.turnID == nil { v.turnID = record.turnID }; return v
    }
    public func cancel(requestID: String) async throws {
        let record = try ledger.record(requestID: requestID)
        guard let binding = record, binding.profileID == profileID, binding.contractVersion == 2 else { throw LocalAuthoringError.wrongBinding }
        try ledger.cancel(requestID: requestID) // durable tombstone precedes every network action
        guard let record, let threadID = record.threadID else { return }
        let c = try configuration(); try verify(record, c: c)
        let client = try await connected(c)
        var turnID = record.turnID
        var needsHistory = turnID == nil
        if let turnID {
            let snapshot = await client.snapshot(threadID: threadID, turnID: turnID)
            needsHistory = !snapshot.started && !["completed", "failed", "interrupted"].contains(snapshot.status ?? "")
        }
        if needsHistory {
            // A persisted turn ID does not prove this socket observed its start. Hydrate
            // only the ledger-bound turn/marker; cancellation never starts another turn.
            _ = try await client.ensureThread(threadID, workspace: c.macWorkspace, contractVersion: 2)
            turnID = try await client.history(threadID: threadID, turnID: turnID, marker: Self.marker(record.requestID, record.inputDigest))?.0
        }
        if let turnID { try await client.interrupt(threadID: threadID, turnID: turnID) }
    }
    public func acknowledge(_ receipt: ApplicationReceiptV1) async throws {
        guard var record = try ledger.record(requestID: receipt.requestID), record.profileID == profileID, record.contractVersion == 2 else { throw LocalAuthoringError.wrongBinding }
        if let saved = record.receipt { guard saved == receipt else { throw LocalAuthoringError.wrongBinding }; return }
        guard let result = record.finalResultV2,
              result.operationID == receipt.operationID, record.inputDigest == receipt.inputDigest,
              let status = LocalDeliveryStatus(rawValue: receipt.status), [.applied, .conflict, .rejected].contains(status) else { throw LocalAuthoringError.wrongBinding }
        record.status = status; record.receipt = receipt; try ledger.update(record); try ledger.compactSources()
    }
    private func safeMessage(_ error: Error) -> String {
        if let error = error as? LocalAuthoringError { return error.localizedDescription }
        if let error = error as? SSHTransportError { return error.description }
        return "The local Mac could not complete this request. Reconnect to check its delivery."
    }
}
