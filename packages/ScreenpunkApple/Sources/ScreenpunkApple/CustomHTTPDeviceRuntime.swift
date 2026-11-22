import Foundation
import ScreenpunkCore

/// Device-local configuration and grants. The Keychain record never becomes part of a package.
public final class CustomHTTPDeviceVault: @unchecked Sendable {
    public struct Status: Sendable, Equatable {
        public let fields: [String: String]
        public let generation: UUID
        public let hasCredential: Bool
        public let allowInsecureHTTP: Bool
        public let origin: String
    }

    public struct SavedService: Identifiable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let origin: String
    }

    private struct Service: Codable, Equatable {
        var definition: CustomHTTPDeclaration
        var fields: [String: String]
        var secret: String?
        var origin: String
        var allowInsecureHTTP: Bool
        var generation: UUID

        func matches(_ declaration: CustomHTTPDeclaration) -> Bool {
            definition.id == declaration.id && definition.version == declaration.version &&
                definition.fields == declaration.fields && definition.originField == declaration.originField &&
                definition.auth == declaration.auth
        }

        var status: Status {
            .init(fields: fields, generation: generation, hasCredential: secret != nil, allowInsecureHTTP: allowInsecureHTTP, origin: origin)
        }
    }

    private struct Approval: Codable, Equatable {
        var serviceID: String
        var declarationDigest: String
        var serviceGeneration: UUID
        var generation: UUID
    }

    private struct Account: Codable {
        var services: [String: Service] = [:]
        var approvals: [String: [String: Approval]] = [:]
        var denials: [String: [String: String]]?
    }

    fileprivate struct Authorized: Sendable {
        var origin: String
        var secret: String?
        var fields: [String: String]
        var generation: UUID
    }

    private static let lock = NSLock()
    private let store: any CredentialStore
    private let key = "service-records-v1"

    public init(store: any CredentialStore = KeychainCredentialStore(service: "xyz.screenpunk.device.custom-http")) {
        self.store = store
    }

    public func status(owner: String, declaration: CustomHTTPDeclaration) -> Status? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let service = try? load()[owner]?.services[declaration.id], service.matches(declaration) else { return nil }
        return service.status
    }

    public func savedServices(owner: String) -> [SavedService] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let services = try? load()[owner]?.services else { return [] }
        return services.map { .init(id: $0.key, label: $0.value.definition.label, origin: $0.value.origin) }
            .sorted { $0.id < $1.id }
    }

    public func save(owner: String, declaration: CustomHTTPDeclaration, fields: [String: String],
                     secret: String? = nil, allowInsecureHTTP: Bool) throws {
        guard !owner.isEmpty else { throw ConnectionFailure.permissionRequired }
        try declaration.validate(alias: "customConnection")
        let visible = declaration.fields.filter { $0.type != "secret" }
        guard Set(visible.map(\.id)) == Set(fields.keys),
              let originValue = fields[declaration.originField] else { throw ConnectionFailure.validationFailed }
        for field in visible {
            guard let value = fields[field.id] else { throw ConnectionFailure.validationFailed }
            try field.validate(value)
        }
        let origin = try CustomHTTPDestination.origin(originValue, allowInsecureHTTP: allowInsecureHTTP)

        Self.lock.lock(); defer { Self.lock.unlock() }
        var accounts = try load()
        var account = accounts[owner] ?? Account()
        let previous = account.services[declaration.id]
        var token: String?
        if let auth = declaration.auth {
            guard let field = declaration.fields.first(where: { $0.id == auth.field }) else { throw ConnectionFailure.validationFailed }
            if let secret, !secret.isEmpty {
                try field.validate(secret)
                token = secret
            } else if let previous, previous.matches(declaration), previous.origin == origin {
                token = previous.secret
            }
            guard token != nil else { throw ConnectionFailure.permissionRequired }
        } else if let secret, !secret.isEmpty {
            throw ConnectionFailure.validationFailed
        }

        let allowsHTTP = origin.hasPrefix("http://") && allowInsecureHTTP
        if let previous, previous.matches(declaration), previous.origin == origin,
           previous.fields == fields, previous.secret == token, previous.allowInsecureHTTP == allowsHTTP {
            return
        }
        guard previous != nil || account.services.count < 64 else { throw ConnectionFailure.sizeLimit }
        Self.removeApprovals(for: declaration.id, from: &account)
        account.services[declaration.id] = .init(definition: declaration, fields: fields, secret: token, origin: origin,
                                                 allowInsecureHTTP: allowsHTTP, generation: UUID())
        accounts[owner] = account
        try persist(accounts)
    }

    public func isApproved(owner: String, screenID: String, manifest: DashboardManifest, alias: String) -> Bool {
        guard let declaration = manifest.connections.first(where: { $0.alias == alias })?.customHTTP else { return false }
        return (try? authorized(owner: owner, screenID: screenID, alias: alias, declaration: declaration)) != nil
    }

    public func approve(owner: String, screenID: String, manifest: DashboardManifest, alias: String, expectedGeneration: UUID? = nil) throws {
        guard !screenID.isEmpty, let declaration = manifest.connections.first(where: { $0.alias == alias })?.customHTTP else {
            throw ConnectionFailure.permissionRequired
        }
        try declaration.validate(alias: alias)
        let declarationDigest = try Self.digest(declaration)
        Self.lock.lock(); defer { Self.lock.unlock() }
        var accounts = try load()
        guard var account = accounts[owner], let service = account.services[declaration.id], service.matches(declaration) else {
            throw ConnectionFailure.permissionRequired
        }
        guard expectedGeneration == nil || service.generation == expectedGeneration else { throw ConnectionFailure.permissionRequired }
        let existing = account.approvals[screenID]?[alias]
        if let existing, existing.declarationDigest == declarationDigest, existing.serviceGeneration == service.generation { return }
        guard account.approvals[screenID] != nil || account.approvals.count < 256 else {
            throw ConnectionFailure.sizeLimit
        }
        var dashboard = account.approvals[screenID] ?? [:]
        guard existing != nil || dashboard.count < 32 else { throw ConnectionFailure.sizeLimit }
        dashboard[alias] = .init(serviceID: declaration.id, declarationDigest: declarationDigest, serviceGeneration: service.generation, generation: UUID())
        account.approvals[screenID] = dashboard
        account.denials?[screenID]?[alias] = nil
        accounts[owner] = account
        try persist(accounts)
    }

    public func revoke(owner: String, screenID: String, alias: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var accounts = try load()
        guard var account = accounts[owner], var dashboard = account.approvals[screenID],
              dashboard.removeValue(forKey: alias) != nil else { return }
        account.approvals[screenID] = dashboard.isEmpty ? nil : dashboard
        accounts[owner] = account
        try persist(accounts)
    }

    public func shouldOfferAccess(owner: String, screenID: String, alias: String, declaration: CustomHTTPDeclaration) -> Bool {
        guard !owner.isEmpty, let digest = try? Self.digest(declaration) else { return false }
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let accounts = try? load() else { return false }
        let account = accounts[owner]
        let scope = digest + "/" + (account?.services[declaration.id]?.generation.uuidString ?? "unconfigured")
        return account?.denials?[screenID]?[alias] != scope
    }

    public func deny(owner: String, screenID: String, alias: String, declaration: CustomHTTPDeclaration) throws {
        guard !owner.isEmpty, !screenID.isEmpty else { throw ConnectionFailure.permissionRequired }
        try declaration.validate(alias: alias)
        let digest = try Self.digest(declaration)
        Self.lock.lock(); defer { Self.lock.unlock() }
        var accounts = try load()
        var account = accounts[owner] ?? Account()
        guard (account.denials?.count ?? 0) < 256 || account.denials?[screenID] != nil else { throw ConnectionFailure.sizeLimit }
        var denials = account.denials ?? [:]
        var screen = denials[screenID] ?? [:]
        guard screen.count < 32 || screen[alias] != nil else { throw ConnectionFailure.sizeLimit }
        screen[alias] = digest + "/" + (account.services[declaration.id]?.generation.uuidString ?? "unconfigured")
        denials[screenID] = screen; account.denials = denials
        account.approvals[screenID]?[alias] = nil
        accounts[owner] = account
        try persist(accounts)
    }

    public func remove(owner: String, serviceID: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var accounts = try load()
        guard var account = accounts[owner], account.services.removeValue(forKey: serviceID) != nil else { return }
        Self.removeApprovals(for: serviceID, from: &account)
        accounts[owner] = account
        try persist(accounts)
    }

    public func removeOwner(_ owner: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var accounts = try load()
        guard accounts.removeValue(forKey: owner) != nil else { return }
        try persist(accounts)
    }

    fileprivate func authorized(owner: String, screenID: String, alias: String, declaration: CustomHTTPDeclaration) throws -> Authorized {
        let declarationDigest = try Self.digest(declaration)
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let account = try load()[owner], let service = account.services[declaration.id], service.matches(declaration),
              let approval = account.approvals[screenID]?[alias], approval.declarationDigest == declarationDigest,
              approval.serviceGeneration == service.generation else { throw ConnectionFailure.permissionRequired }
        return .init(origin: service.origin, secret: service.secret, fields: service.fields, generation: approval.generation)
    }

    private func load() throws -> [String: Account] {
        guard let data = try store.secret(for: key) else { return [:] }
        return try JSONDecoder().decode([String: Account].self, from: data)
    }

    private func persist(_ accounts: [String: Account]) throws {
        if accounts.isEmpty { try store.delete(key) }
        else { try store.put(JSONEncoder().encode(accounts), for: key) }
    }

    private static func digest(_ declaration: CustomHTTPDeclaration) throws -> String {
        CatalogContract.digest(try CatalogContract.canonical(declaration))
    }

    private static func removeApprovals(for serviceID: String, from account: inout Account) {
        for dashboard in Array(account.approvals.keys) {
            let remaining = account.approvals[dashboard]?.filter { $0.value.serviceID != serviceID } ?? [:]
            account.approvals[dashboard] = remaining.isEmpty ? nil : remaining
        }
    }
}

private enum CustomHTTPDestination {
    static func origin(_ value: String, allowInsecureHTTP: Bool) throws -> String {
        guard var parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, ["", "/"].contains(parts.percentEncodedPath),
              parts.port.map({ (1...65535).contains($0) }) != false,
              ["https", "http"].contains(scheme) else { throw ConnectionFailure.validationFailed }
        let addressClass = AddressClassifier.classify(host: host)
        guard ![.invalid, .loopback, .linkLocal, .metadata].contains(addressClass) else {
            throw ConnectionFailure.deniedEgress
        }
        if scheme == "http" {
            // A literal private address keeps plaintext credentials on the approved LAN endpoint.
            guard allowInsecureHTTP, addressClass == .privateLAN else { throw ConnectionFailure.deniedEgress }
        }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.path = ""
        guard let canonical = parts.url?.absoluteString else { throw ConnectionFailure.validationFailed }
        return canonical
    }

    static func url(origin: String, path: String, query: [URLQueryItem], resolver: any DestinationResolver) throws -> URL {
        guard var parts = URLComponents(string: origin), let host = parts.host, let scheme = parts.scheme else {
            throw ConnectionFailure.validationFailed
        }
        let addresses = try resolver.addresses(for: host)
        let classes = Set(addresses.map { AddressClassifier.classify(host: $0) })
        guard classes == [.publicUnicast] || classes == [.privateLAN],
              scheme == "https" || classes == [.privateLAN] else { throw ConnectionFailure.deniedEgress }
        parts.path = path
        if !query.isEmpty {
            parts.queryItems = query
            // Preserve a literal plus with servers that decode form-style query strings.
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = parts.url else { throw ConnectionFailure.validationFailed }
        return url
    }
}

/// Executes declared GET JSON operations without accepting endpoints, headers or secrets from WebKit.
public struct CustomHTTPDeviceRuntime: Sendable {
    private let owner: String
    private let screenID: String
    private let manifest: DashboardManifest
    private let vault: CustomHTTPDeviceVault
    private let transport: any HTTPTransport
    private let resolver: any DestinationResolver
    private let accessRequired: (@Sendable (String) async -> Void)?

    public init(owner: String, screenID: String, manifest: DashboardManifest, vault: CustomHTTPDeviceVault = .init(),
                transport: any HTTPTransport = URLSessionHTTPTransport(privateRequests: true),
                resolver: any DestinationResolver = LiteralOrResolvedDestinationResolver(),
                accessRequired: (@Sendable (String) async -> Void)? = nil) {
        self.owner = owner
        self.screenID = screenID
        self.manifest = manifest
        self.vault = vault
        self.transport = transport
        self.resolver = resolver
        self.accessRequired = accessRequired
    }

    func declares(alias: String) -> Bool {
        manifest.connections.contains { $0.alias == alias && $0.customHTTP != nil }
    }

    public func request(alias: String, operation: String, parameters: [String: String]) async throws -> Data {
        guard let declaration = manifest.connections.first(where: { $0.alias == alias })?.customHTTP,
              let operation = declaration.operations.first(where: { $0.name == operation }) else {
            throw ConnectionFailure.permissionRequired
        }
        try declaration.validate(alias: alias)
        guard vault.isApproved(owner: owner, screenID: screenID, manifest: manifest, alias: alias) else {
            if vault.shouldOfferAccess(owner: owner, screenID: screenID, alias: alias, declaration: declaration) {
                await accessRequired?(alias)
            }
            throw ConnectionFailure.permissionRequired
        }
        let approval = try vault.authorized(owner: owner, screenID: screenID, alias: alias, declaration: declaration)
        let query = try Self.query(operation: operation, fields: approval.fields, parameters: parameters)
        let url = try CustomHTTPDestination.url(origin: approval.origin, path: operation.path, query: query, resolver: resolver)
        try Task.checkCancellation()
        try checkApproval(alias: alias, declaration: declaration, generation: approval.generation)
        var headers = ["Accept": "application/json"]
        if let token = approval.secret { headers["Authorization"] = "Bearer \(token)" }
        let result = try await transport.send(.init(url: url, method: "GET", headers: headers, body: nil,
                                                    timeout: TimeInterval(ConnectionBounds.httpTimeoutSeconds),
                                                    maxBytes: ConnectionBounds.httpResponseBytes))
        try Task.checkCancellation()
        try checkApproval(alias: alias, declaration: declaration, generation: approval.generation)
        guard !(300...399).contains(result.status) else { throw ConnectionFailure.deniedEgress }
        guard (200...299).contains(result.status) else { throw ConnectionFailure.deviceOffline }
        guard result.body.count <= ConnectionBounds.httpResponseBytes else { throw ConnectionFailure.sizeLimit }
        guard let json = try? JSONSerialization.jsonObject(with: result.body, options: .fragmentsAllowed) else {
            throw ConnectionFailure.validationFailed
        }
        if let token = approval.secret, Self.contains(token, in: json) { throw ConnectionFailure.permissionRequired }
        return result.body
    }

    private func checkApproval(alias: String, declaration: CustomHTTPDeclaration, generation: UUID) throws {
        guard try vault.authorized(owner: owner, screenID: screenID, alias: alias,
                                   declaration: declaration).generation == generation else {
            throw ConnectionFailure.permissionRequired
        }
    }

    private static func query(operation: CustomHTTPOperation, fields: [String: String],
                              parameters: [String: String]) throws -> [URLQueryItem] {
        guard parameters.keys.allSatisfy({ operation.parameters[$0]?.field == nil && operation.parameters[$0] != nil }) else {
            throw ConnectionFailure.permissionRequired
        }
        guard try ConnectionPolicy.jsonBody(parameters).count <= ConnectionBounds.parameterBytes else { throw ConnectionFailure.sizeLimit }
        return try operation.parameters.sorted(by: { $0.key < $1.key }).compactMap { name, parameter in
            let value = parameter.field.flatMap { fields[$0] } ?? parameters[name]
            guard let value else { return nil }
            try parameter.validate(value)
            return URLQueryItem(name: name, value: value)
        }
    }

    private static func contains(_ secret: String, in json: Any) -> Bool {
        // Iterate through decoded values to cover JSON escapes and avoid recursive stack growth.
        var remaining = [json]
        while let value = remaining.popLast() {
            if let text = value as? String, text.contains(secret) { return true }
            if let number = value as? NSNumber, number.stringValue == secret { return true }
            if let object = value as? [String: Any] {
                if object.keys.contains(where: { $0.contains(secret) }) { return true }
                remaining.append(contentsOf: object.values)
            } else if let array = value as? [Any] {
                remaining.append(contentsOf: array)
            }
        }
        return false
    }
}
