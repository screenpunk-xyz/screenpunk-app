import Foundation
import ScreenpunkCore

/// Applies only before a request is sealed. Prepared deliveries keep their stored route.
enum NewRequestRoutePolicy {
    enum LocalState: Equatable { case ready, unavailable, repairRequired }
    enum CloudState: Equatable { case unchecked, notConfigured, notReady, ready(supportsV2: Bool) }
    enum Decision: Equatable {
        case use(AuthoringRoute, contractVersion: Int)
        case checkCloud, needsComputer, repairComputer, connectCloud, listenCloud, updateCloud
    }
    static func resolve(preference: AuthoringRoutePreference, local: LocalState, cloud: CloudState, requiresV2: Bool) -> Decision {
        if preference != .cloud {
            switch local {
            case .ready: return .use(.local, contractVersion: 2)
            case .repairRequired: return .repairComputer
            case .unavailable: if preference == .local { return .needsComputer }
            }
        }
        switch cloud {
        case .unchecked: return .checkCloud
        case .notConfigured: return .connectCloud
        case .notReady: return .listenCloud
        case .ready(let supportsV2):
            if requiresV2 && !supportsV2 { return .updateCloud }
            return .use(.cloud, contractVersion: supportsV2 ? 2 : 1)
        }
    }
}

/// Recovery never chooses a new route or a new request identity. A durable native
/// receipt takes precedence over enrollment/delivery deadlines and cancellation.
enum PreparedRequestRecoveryPolicy {
    enum Action: Equatable {
        case acknowledgeReceipt, cancelExpired, cancelled, reconcile
        case retrySameRequest(requestID: String, route: AuthoringRoute)
    }
    static func acknowledgedReceipt(requestID: String, receipts: [String: ApplicationReceiptV1], acknowledgedReceiptIDs: Set<String>) -> ApplicationReceiptV1? {
        let matches = receipts.filter { $0.value.requestID == requestID }
        guard matches.count == 1, let entry = matches.first,
              entry.key == entry.value.operationID,
              entry.value.schemaVersion == 1,
              ["applied", "conflict", "rejected"].contains(entry.value.status),
              acknowledgedReceiptIDs.contains(entry.value.operationID) else { return nil }
        return entry.value
    }
    static func action(requestID: String, route: AuthoringRoute, deadlineAt: Int64, now: Int64, hasReceipt: Bool, submissionKey: String?, cancelled: Bool) -> Action {
        if hasReceipt { return .acknowledgeReceipt }
        if cancelled { return .cancelled }
        if now >= deadlineAt { return .cancelExpired }
        if submissionKey == requestID { return .retrySameRequest(requestID: requestID, route: route) }
        return .reconcile
    }
}

/// Foreground reconnects wait for every queued local teardown. Both authoring
/// versions share this barrier so an older disconnect cannot close a new session.
@MainActor final class LocalConnectionLifecycleBarrier {
    private var pending: Task<Void, Never>?
    private var revision: UInt64 = 0
    func enqueue(_ disconnect: @escaping @MainActor () async -> Void) {
        let previous = pending
        revision &+= 1
        pending = Task { await previous?.value; await disconnect() }
    }
    func wait() async {
        while let current = pending {
            let observed = revision
            await current.value
            if observed == revision { return }
        }
    }
}

/// Transient message presentation only. Delivery state and the original message
/// remain outside this value, so dismissal cannot complete or cancel a request.
struct StatusMessagePresentationState {
    struct Message: Identifiable, Equatable {
        let id: UUID
        let text: String
    }
    private(set) var message: Message?
    private var dismissedID: UUID?
    var presentedMessage: Message? {
        guard let message, message.id != dismissedID else { return nil }
        return message
    }
    mutating func update(_ text: String?) {
        message = text.map { Message(id: UUID(), text: $0) }
        dismissedID = nil
    }
    func canDismiss(busy: Bool, requestPending: Bool, routeChangeBlocked: Bool, canRetry: Bool, canCancelRequest: Bool) -> Bool {
        presentedMessage != nil && !busy && !requestPending && !routeChangeBlocked && !canRetry && !canCancelRequest
    }
    @discardableResult mutating func dismiss(id: UUID, busy: Bool, requestPending: Bool, routeChangeBlocked: Bool, canRetry: Bool, canCancelRequest: Bool) -> Bool {
        guard presentedMessage?.id == id,
              canDismiss(busy: busy, requestPending: requestPending, routeChangeBlocked: routeChangeBlocked, canRetry: canRetry, canCancelRequest: canCancelRequest) else { return false }
        dismissedID = id
        return true
    }
}

/// Account synchronization has its own foreground cadence. Authoring never awaits
/// this pump: local delivery can finish or cancel while Cloud is unreachable.
@MainActor final class PreferenceSyncPump {
    typealias Sleep = (UInt64) async throws -> Void
    private let sleep: Sleep
    private let idleDelay: UInt64
    private var runner: Task<Void, Never>?
    private var timer: Task<Void, Error>?
    private var identity: UUID?
    private var requested = false
    init(idleDelay: UInt64 = 60_000_000_000, sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) }) { self.idleDelay = idleDelay; self.sleep = sleep }
    func wake(_ operation: @escaping @MainActor () async -> Bool) {
        requested = true
        timer?.cancel()
        guard runner == nil else { return }
        let id = UUID(); identity = id
        runner = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.identity == id else { return }
                self.requested = false
                let success = await operation()
                guard self.identity == id, !Task.isCancelled else { return }
                failures = success ? 0 : min(failures + 1, 6)
                // Coalesce any number of notices during I/O into one trailing run.
                if self.requested { continue }
                let delay = success ? self.idleDelay : min(UInt64(1 << failures) * 1_000_000_000, 60_000_000_000)
                let timer = Task { try await self.sleep(delay) }
                self.timer = timer
                do { try await timer.value } catch { }
                guard self.identity == id, !Task.isCancelled else { return }
                self.timer = nil
            }
        }
    }
    func cancel() {
        identity = nil; requested = false
        runner?.cancel(); runner = nil
        timer?.cancel(); timer = nil
    }
}

/// Cloud polling and the independent pump share one mutation flight. A replacement
/// binding waits for the cancelled old flight to drain before issuing another call.
@MainActor final class PreferenceSyncSingleFlight<Binding: Equatable> {
    private struct Flight { let id: UUID; let binding: Binding; let task: Task<Bool, Never> }
    private var current: Flight?
    func run(binding: Binding, operation: @escaping @MainActor () async -> Bool) async -> Bool {
        while let old = current {
            if old.binding == binding { return await old.task.value }
            old.task.cancel()
            _ = await old.task.value
            if current?.id == old.id { current = nil }
            guard !Task.isCancelled else { return true }
        }
        guard !Task.isCancelled else { return true }
        let flight = Flight(id: UUID(), binding: binding, task: Task { await operation() })
        current = flight
        let result = await flight.task.value
        if current?.id == flight.id { current = nil }
        return result
    }
    func cancel() { current?.task.cancel() }
}

/// No route argument: saved Cloud preferences belong to the account/library, not
/// to the agent chosen for authoring. Nil session profile may finish enrollment.
enum CloudPreferenceSyncEligibility {
    static func matches(profile: LocalProfileDescriptor?, accountID: String?, deviceID: String?, profileID: String?) -> Bool {
        guard let binding = profile?.cloudBinding, let accountID, let deviceID else { return false }
        return binding.accountID == accountID && binding.deviceID == deviceID && (profileID == nil || binding.profileID == profileID)
    }
}
