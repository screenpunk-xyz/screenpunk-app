import Foundation
import Combine

/// Discovery provides address suggestions only. It never changes a stored SSH pin.
@MainActor final class LocalComputerDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Computer: Identifiable, Sendable {
        let id: String
        let name: String
        let host: String
        let port: Int
    }
    struct Limits: Sendable {
        var identities = 64
        var concurrentResolutions = 8
        var duration: TimeInterval = 10
    }
    struct BudgetSnapshot: Sendable { let identities: Int; let resolvers: Int; let callbackTasks: Int }
    typealias ScheduleDeadline = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (() -> Void)
    @Published private(set) var computers: [Computer] = []
    @Published private(set) var searching = false
    @Published private(set) var message: String?
    private let limits: Limits
    private let makeBrowser: () -> NetServiceBrowser
    private let makeService: (String, String, String) -> NetService
    private let scheduleDeadline: ScheduleDeadline
    private var cancelDeadline: (() -> Void)?
    private var generation: UUID?
    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]
    private var pending: [Descriptor] = []
    private nonisolated let ingress = DiscoveryIngress()
    private static let limitMessage = "The nearby-computer search reached its limit. Choose a listed computer, search again, or enter its address manually."

    init(limits: Limits = .init(), makeBrowser: @escaping () -> NetServiceBrowser = { NetServiceBrowser() },
         makeService: @escaping (String, String, String) -> NetService = { NetService(domain: $0, type: $1, name: $2) },
         scheduleDeadline: @escaping ScheduleDeadline = { seconds, action in
             let task = Task { @MainActor in
                 do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                 catch { return }
                 guard !Task.isCancelled else { return }; action()
             }
             return { task.cancel() }
         }) {
        precondition((1...64).contains(limits.identities) && (1...min(8, limits.identities)).contains(limits.concurrentResolutions)
                     && limits.duration.isFinite && limits.duration > 0 && limits.duration <= 10)
        self.limits = limits; self.makeBrowser = makeBrowser; self.makeService = makeService; self.scheduleDeadline = scheduleDeadline
        super.init()
    }
    func start() {
        stop(); computers = []; searching = true
        message = "Searching nearby SSH services. If nothing appears, enter the computer’s address manually."
        let generation = UUID(), browser = makeBrowser()
        self.generation = generation; self.browser = browser
        ingress.begin(generation: generation, browser: ObjectIdentifier(browser), limits: limits)
        browser.delegate = self
        cancelDeadline = scheduleDeadline(limits.duration) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.stop()
            self.message = "Nearby-computer search finished. Choose a listed computer, search again, or enter its address manually."
        }
        browser.searchForServices(ofType: "_ssh._tcp.", inDomain: "local.")
    }
    func stop() {
        // Close ingress before Foundation can synchronously or asynchronously call back.
        ingress.end(); generation = nil
        cancelDeadline?(); cancelDeadline = nil
        let oldBrowser = browser, oldServices = Array(services.values)
        browser = nil; services = [:]; pending = []; searching = false
        oldBrowser?.delegate = nil; oldBrowser?.stop()
        for service in oldServices { service.delegate = nil; service.stop() }
    }
    nonisolated var budgetSnapshot: BudgetSnapshot { ingress.snapshot() }

    private struct Descriptor: Sendable { let id: String; let name: String; let type: String; let domain: String }
    private nonisolated static func descriptor(_ service: NetService) -> Descriptor? {
        let name = service.name, type = service.type, domain = service.domain
        guard !name.isEmpty, name.utf8.count <= 63, type.utf8.count <= 32, domain.utf8.count <= 255,
              type.lowercased() == "_ssh._tcp.", domain.lowercased() == "local.",
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return .init(id: name + "._ssh._tcp.local.", name: name, type: "_ssh._tcp.", domain: "local.")
    }
    /// Claims occur BEFORE the actor hop: at most one find, removal and completion
    /// task per admitted identity, plus one browser failure. Churn cannot recycle slots.
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard let descriptor = Self.descriptor(service),
              let token = ingress.admit(browser: ObjectIdentifier(browser), id: descriptor.id) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.generation == token.generation else { return }
            if token.reachedLimit { self.browser?.stop(); self.message = Self.limitMessage }
            guard self.ingress.isCurrent(token) else { self.resolvePending(); return }
            self.pending.append(descriptor); self.resolvePending()
        }
    }
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard let descriptor = Self.descriptor(service),
              let token = ingress.remove(browser: ObjectIdentifier(browser), id: descriptor.id) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.generation == token.generation else { return }
            self.pending.removeAll { $0.id == token.id }; self.releaseResolver(id: token.id)
            self.computers.removeAll { $0.id == token.id }; self.resolvePending()
        }
    }
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let serviceID = ObjectIdentifier(sender)
        guard let token = ingress.complete(service: serviceID) else { return }
        let host = sender.hostName, port = sender.port
        let validHost = host.flatMap { value -> String? in
            guard !value.isEmpty, value.utf8.count <= 255,
                  !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return value
        }
        Task { @MainActor [weak self] in self?.completed(token, serviceID: serviceID, host: validHost, port: port) }
    }
    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let serviceID = ObjectIdentifier(sender)
        guard let token = ingress.complete(service: serviceID) else { return }
        Task { @MainActor [weak self] in self?.completed(token, serviceID: serviceID, host: nil, port: 0) }
    }
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard let generation = ingress.fail(browser: ObjectIdentifier(browser)) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.generation == generation else { return }
            self.stop(); self.message = "Nearby computers could not be found. Check Screenpunk’s Local Network permission in Settings, or enter an address manually."
        }
    }
    private func resolvePending() {
        guard let generation else { return }
        while services.count < limits.concurrentResolutions, !pending.isEmpty {
            let descriptor = pending.removeFirst()
            let owned = DiscoveryIngress.Token(generation: generation, id: descriptor.id)
            guard ingress.isCurrent(owned) else { continue }
            let service = makeService(descriptor.domain, descriptor.type, descriptor.name)
            guard ingress.register(owned, service: ObjectIdentifier(service)) else { service.stop(); continue }
            services[descriptor.id] = service; service.delegate = self
            service.resolve(withTimeout: min(5, limits.duration))
        }
        if services.isEmpty, pending.isEmpty, ingress.finishedBudget() { stop(); message = Self.limitMessage }
    }
    private func releaseResolver(id: String) {
        guard let service = services.removeValue(forKey: id) else { return }
        ingress.release(service: ObjectIdentifier(service)); service.delegate = nil; service.stop()
    }
    private func completed(_ token: DiscoveryIngress.Token, serviceID: ObjectIdentifier, host: String?, port: Int) {
        guard generation == token.generation, let service = services[token.id], ObjectIdentifier(service) == serviceID else { return }
        let name = service.name
        releaseResolver(id: token.id)
        let current = ingress.isCurrent(token)
        if current, let host, (1...65535).contains(port), computers.count < limits.identities {
            computers.append(.init(id: token.id, name: name, host: host, port: port))
            computers.sort { ($0.name, $0.host) < ($1.name, $1.host) }
        } else if current, !token.reachedLimit {
            message = "Some nearby names could not be resolved. You can enter the Mac’s address manually."
        }
        resolvePending()
    }

    /// Bounded value metadata only; Foundation objects stay on MainActor.
    private final class DiscoveryIngress: @unchecked Sendable {
        struct Token: Sendable { let generation: UUID; let id: String; var reachedLimit = false }
        private struct Identity { var removed = false; var completed = false }
        private let lock = NSLock()
        private var generation: UUID?
        private var browser: ObjectIdentifier?
        private var identities: [String: Identity] = [:]
        private var resolvers: [ObjectIdentifier: String] = [:]
        private var limit = 0, concurrency = 0, callbackTasks = 0
        private var accepting = false
        func begin(generation: UUID, browser: ObjectIdentifier, limits: Limits) {
            lock.lock(); defer { lock.unlock() }
            self.generation = generation; self.browser = browser
            identities = [:]; resolvers = [:]; callbackTasks = 0
            limit = limits.identities; concurrency = limits.concurrentResolutions; accepting = true
        }
        func end() {
            lock.lock(); defer { lock.unlock() }
            generation = nil; browser = nil; identities = [:]; resolvers = [:]; accepting = false
        }
        func admit(browser: ObjectIdentifier, id: String) -> Token? {
            lock.lock(); defer { lock.unlock() }
            guard self.browser == browser, let generation, accepting, identities[id] == nil, identities.count < limit else { return nil }
            identities[id] = .init(); callbackTasks += 1
            let reachedLimit = identities.count == limit
            if reachedLimit { accepting = false }
            return .init(generation: generation, id: id, reachedLimit: reachedLimit)
        }
        func remove(browser: ObjectIdentifier, id: String) -> Token? {
            lock.lock(); defer { lock.unlock() }
            guard self.browser == browser, let generation, var identity = identities[id], !identity.removed else { return nil }
            identity.removed = true; identities[id] = identity; callbackTasks += 1
            return .init(generation: generation, id: id)
        }
        func register(_ token: Token, service: ObjectIdentifier) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard generation == token.generation, let identity = identities[token.id], !identity.removed, !identity.completed,
                  resolvers.count < concurrency else { return false }
            resolvers[service] = token.id; return true
        }
        func complete(service: ObjectIdentifier) -> Token? {
            lock.lock(); defer { lock.unlock() }
            guard let generation, let id = resolvers.removeValue(forKey: service), var identity = identities[id], !identity.removed, !identity.completed else { return nil }
            identity.completed = true; identities[id] = identity; callbackTasks += 1
            return .init(generation: generation, id: id, reachedLimit: !accepting)
        }
        func release(service: ObjectIdentifier) { lock.lock(); defer { lock.unlock() }; resolvers.removeValue(forKey: service) }
        func isCurrent(_ token: Token) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return generation == token.generation && identities[token.id]?.removed == false
        }
        func fail(browser: ObjectIdentifier) -> UUID? {
            lock.lock(); defer { lock.unlock() }
            guard self.browser == browser, let generation else { return nil }
            self.browser = nil; accepting = false; callbackTasks += 1
            self.generation = nil; resolvers = [:]
            return generation
        }
        func finishedBudget() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return generation != nil && !accepting && identities.values.allSatisfy { $0.removed || $0.completed }
        }
        func snapshot() -> BudgetSnapshot {
            lock.lock(); defer { lock.unlock() }
            return .init(identities: identities.count, resolvers: resolvers.count, callbackTasks: callbackTasks)
        }
    }
}
