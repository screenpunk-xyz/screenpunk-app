import Foundation
import ScreenpunkCore

/// Device-local configuration and grants. The Keychain record never becomes part of a package.
public final class CustomHTTPDeviceVault: @unchecked Sendable {
    public struct Status: Sendable, Equatable {
        public let fields: [String: String]
        public let generation: UUID
        public let certificatePin: ReviewedCertificatePin?
        public let hasCredential: Bool
        public let allowInsecureHTTP: Bool
        public let origin: String

        public func canReuseCredential(for server: String, allowInsecureHTTP: Bool) -> Bool {
            hasCredential && (try? CustomHTTPDestination.origin(server, allowInsecureHTTP: allowInsecureHTTP)) == origin
        }
    }

    public struct SavedService: Identifiable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let origin: String
    }

    private struct Service: Codable, Equatable {
        var definition: CustomHTTPDeclaration
        var fields: [String: String]
        var certificatePin: ReviewedCertificatePin?
        var secret: String?
        var secretDeclarationDigest: String?
        var credentialRegistrationID: String?
        var origin: String
        var allowInsecureHTTP: Bool
        var generation: UUID

        func matches(_ declaration: CustomHTTPDeclaration) -> Bool {
            definition.id == declaration.id && definition.version == declaration.version &&
                definition.fields == declaration.fields && definition.originField == declaration.originField &&
                definition.auth == declaration.auth &&
                (secretDeclarationDigest == nil ||
                 secretDeclarationDigest == (try? CredentialRegistrationContext.declarationDigest(declaration)))
        }

        var supportsJSONPost: Bool {
            origin.hasPrefix("https://") && secret != nil && credentialRegistrationID == nil
        }

        var status: Status {
            .init(fields: fields, generation: generation, certificatePin: certificatePin, hasCredential: secret != nil, allowInsecureHTTP: allowInsecureHTTP, origin: origin)
        }
    }

    private struct Approval: Codable, Equatable {
        var serviceID: String
        var declarationDigest: String
        var serviceGeneration: UUID
        var generation: UUID
        var permitsJSONPost: Bool?
    }

    private struct StoredRegistration: Codable {
        var registrationID: String
        var context: CredentialRegistrationContext
        var verifier: String
        var pendingBearer: String?
        var removalRequested: Bool

        var summary: PendingCredentialRegistration {
            .init(registrationID: registrationID, context: context, verifier: verifier, removalRequested: removalRequested)
        }
    }

    private struct Account: Codable {
        var services: [String: Service] = [:]
        var approvals: [String: [String: Approval]] = [:]
        var denials: [String: [String: String]]?
        var credentialRegistrations: [String: StoredRegistration]?
        var connectionNames: [String: String]?
    }

    fileprivate struct Authorized: Sendable {
        var origin: String
        var certificatePin: ReviewedCertificatePin?
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
        guard let service = try? load()[owner]?.services[declaration.id], service.matches(declaration),
              !declaration.operations.contains(where: { $0.method == "POST" }) || service.supportsJSONPost else { return nil }
        return service.status
    }

    public func savedServices(owner: String) -> [SavedService] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let services = try? load()[owner]?.services else { return [] }
        return services.map { .init(id: $0.key, label: $0.value.definition.label, origin: $0.value.origin) }
            .sorted { $0.id < $1.id }
    }

    public func connectionName(owner: String, serviceID: String) -> String? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try? load()[owner]?.connectionNames?[serviceID]
    }

    public func renameConnection(owner: String, serviceID: String, name: String) throws {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !serviceID.isEmpty, (1...128).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ConnectionFailure.validationFailed
        }
        Self.lock.lock(); defer { Self.lock.unlock() }
        var accounts = try load()
        var account = accounts[owner] ?? Account()
        var names = account.connectionNames ?? [:]
        guard names.count < 128 || names[serviceID] != nil else { throw ConnectionFailure.sizeLimit }
        names[serviceID] = value
        account.connectionNames = names
        accounts[owner] = account
        try persist(accounts)
    }

    public func prepareCredentialRegistration(owner: String, context: CredentialRegistrationContext,
                                              now: Int64) throws -> PendingCredentialRegistration {
        guard !owner.isEmpty, context.isCurrent(now),
              try CredentialRegistrationContext.canonicalHTTPSOrigin(context.origin) == context.origin else {
            throw ConnectionFailure.validationFailed
        }
        Self.lock.lock(); defer { Self.lock.unlock() }
        var accounts = try load()
        var account = accounts[owner] ?? Account()
        var registrations = account.credentialRegistrations ?? [:]
        guard account.services[context.serviceID]?.generation == context.expectedGeneration else {
            throw ConnectionFailure.permissionRequired
        }
        if let existing = registrations.values.first(where: { $0.context.requestID == context.requestID && $0.context.alias == context.alias }) {
            guard existing.context == context, existing.pendingBearer != nil, !existing.removalRequested else {
                throw ConnectionFailure.permissionRequired
            }
            return existing.summary
        }
        guard registrations.count < 128 else { throw ConnectionFailure.sizeLimit }
        let generated = try DeviceBearerCredential.generate()
        let record = StoredRegistration(registrationID: UUID().uuidString.lowercased(), context: context,
                                        verifier: generated.verifier, pendingBearer: generated.bearer, removalRequested: false)
        registrations[record.registrationID] = record
        account.credentialRegistrations = registrations
        accounts[owner] = account
        try persist(accounts)
        return record.summary
    }

    public func pendingCredentialRegistration(owner: String, requestID: String,
                                              alias: String) throws -> PendingCredentialRegistration? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try load()[owner]?.credentialRegistrations?.values.first {
            $0.context.requestID == requestID && $0.context.alias == alias &&
                ($0.pendingBearer != nil || $0.removalRequested)
        }?.summary
    }

    public func stageStaleCredentialRegistrationRemovals(owner: String, deviceID: String,
                                                         currentRevisions: [String: String], now: Int64) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var accounts = try load()
        guard var account = accounts[owner] else { return }
        let stale = (account.credentialRegistrations ?? [:]).values.filter { record in
            let context = record.context
            return context.deviceID == deviceID && record.pendingBearer != nil &&
                (!context.isCurrent(now) || currentRevisions[context.screenID] != context.revision ||
                    account.services[context.serviceID]?.generation != context.expectedGeneration)
        }
        guard !stale.isEmpty else { return }
        for record in stale { Self.scheduleRemoval(record.registrationID, in: &account) }
        accounts[owner] = account
        try persist(accounts)
    }

    public func credentialRegistrationRemovals(owner: String, deviceID: String) throws -> [PendingCredentialRegistration] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try load()[owner]?.credentialRegistrations?.values.filter {
            $0.removalRequested && $0.context.deviceID == deviceID
        }.map(\.summary) ?? []
    }

    /// Clear local bearer access and durably remember the exact source ID to revoke, even offline.
    public func requestCredentialRegistrationRemoval(owner: String, registrationID: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var accounts = try load()
        guard var account = accounts[owner],
              let record = account.credentialRegistrations?[registrationID] else {
            throw ConnectionFailure.permissionRequired
        }
        if account.services[record.context.serviceID]?.credentialRegistrationID == registrationID {
            account.services[record.context.serviceID] = nil
            Self.removeApprovals(for: record.context.serviceID, from: &account)
        }
        Self.scheduleRemoval(registrationID, in: &account)
        accounts[owner] = account
        try persist(accounts)
    }

    /// An authorized source explicitly confirmed that it did not attempt an external credential write.
    public func discardUninstalledCredentialRegistration(owner: String, registrationID: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var accounts = try load()
        guard var account = accounts[owner], let record = account.credentialRegistrations?[registrationID],
              record.pendingBearer != nil, !record.removalRequested else { return }
        account.credentialRegistrations?[registrationID] = nil
        accounts[owner] = account
        try persist(accounts)
    }

    public func confirmCredentialRegistrationRemoval(owner: String, registrationID: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var accounts = try load()
        guard var account = accounts[owner], account.credentialRegistrations?[registrationID]?.removalRequested == true else {
            return
        }
        account.credentialRegistrations?[registrationID] = nil
        accounts[owner] = account
        try persist(accounts)
    }

    private static func scheduleRemoval(_ registrationID: String?, in account: inout Account) {
        guard let registrationID, var record = account.credentialRegistrations?[registrationID] else { return }
        record.pendingBearer = nil
        record.removalRequested = true
        account.credentialRegistrations?[registrationID] = record
    }

    public func serviceGeneration(owner: String, serviceID: String) throws -> UUID? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try load()[owner]?.services[serviceID]?.generation
    }

    public func save(owner: String, declaration: CustomHTTPDeclaration, fields: [String: String],
                     secret: String? = nil, allowInsecureHTTP: Bool, certificatePin: ReviewedCertificatePin? = nil) throws {
        try save(owner: owner, declaration: declaration, fields: fields, secret: secret,
                 allowInsecureHTTP: allowInsecureHTTP, certificatePin: certificatePin, registration: nil)
    }

    public func acceptCredentialRegistration(owner: String, declaration: CustomHTTPDeclaration, fields: [String: String],
                                             registrationID: String, fingerprint: String,
                                             certificatePin: ReviewedCertificatePin, now: Int64,
                                             approveScreenRead: Bool = false, approvalScreenID: String? = nil) throws {
        guard declaration.auth?.mode == "bearer",
              fingerprint == certificatePin.fingerprint else { throw ConnectionFailure.certificateRejected }
        try save(owner: owner, declaration: declaration, fields: fields, secret: nil, allowInsecureHTTP: false,
                 certificatePin: certificatePin, registration: (registrationID, now, approveScreenRead, approvalScreenID))
    }

    private func save(owner: String, declaration: CustomHTTPDeclaration, fields: [String: String],
                      secret: String?, allowInsecureHTTP: Bool, certificatePin: ReviewedCertificatePin?,
                      registration: (id: String, now: Int64, approveScreenRead: Bool, approvalScreenID: String?)?) throws {
        guard !owner.isEmpty else { throw ConnectionFailure.permissionRequired }
        try declaration.validate(alias: "customConnection")
        let visible = declaration.fields.filter { $0.type != "secret" }
        guard Set(visible.map(\.id)) == Set(fields.keys),
              let originValue = fields[declaration.originField] else { throw ConnectionFailure.validationFailed }
        for field in visible {
            guard let value = fields[field.id] else { throw ConnectionFailure.validationFailed }
            try field.validate(value)
        }
        let usesPOST = declaration.operations.contains { $0.method == "POST" }
        let origin = try CustomHTTPDestination.origin(originValue, allowInsecureHTTP: allowInsecureHTTP && !usesPOST)
        guard !usesPOST || registration == nil else { throw ConnectionFailure.permissionRequired }

        if let certificatePin, certificatePin.origin != origin {
            throw ConnectionFailure.validationFailed
        }

        Self.lock.lock(); defer { Self.lock.unlock() }
        var accounts = try load()
        var account = accounts[owner] ?? Account()
        let previous = account.services[declaration.id]
        var token = secret
        var tokenDeclarationDigest: String?
        var credentialRegistrationID: String?
        var reviewedRead: CredentialRegistrationContext?
        if let registration {
            guard var pending = account.credentialRegistrations?[registration.id], !pending.removalRequested,
                  let bearer = pending.pendingBearer, certificatePin != nil,
                  pending.context.isCurrent(registration.now),
                  try CredentialRegistrationContext.canonicalHTTPSOrigin(origin) == pending.context.origin,
                  pending.context.serviceID == declaration.id,
                  pending.context.declarationDigest == (try CredentialRegistrationContext.declarationDigest(declaration)),
                  pending.context.expectedGeneration == previous?.generation else {
                throw ConnectionFailure.permissionRequired
            }
            token = bearer
            tokenDeclarationDigest = pending.context.declarationDigest
            credentialRegistrationID = registration.id
            pending.pendingBearer = nil
            account.credentialRegistrations?[registration.id] = pending
            if registration.approveScreenRead { reviewedRead = pending.context }
        }
        if let auth = declaration.auth {
            guard let field = declaration.fields.first(where: { $0.id == auth.field }) else { throw ConnectionFailure.validationFailed }
            if let token, !token.isEmpty {
                try field.validate(token)
            } else if let previous, previous.matches(declaration), previous.origin == origin {
                token = previous.secret
                tokenDeclarationDigest = previous.secretDeclarationDigest
                credentialRegistrationID = previous.credentialRegistrationID
            }
            guard token != nil, credentialRegistrationID == nil || certificatePin != nil else {
                throw ConnectionFailure.permissionRequired
            }
        } else if let secret, !secret.isEmpty {
            throw ConnectionFailure.validationFailed
        }

        let allowsHTTP = origin.hasPrefix("http://") && allowInsecureHTTP
        if registration == nil, let previous, previous.matches(declaration), previous.origin == origin,
           previous.certificatePin == certificatePin, previous.fields == fields, previous.secret == token,
           previous.secretDeclarationDigest == tokenDeclarationDigest,
           previous.credentialRegistrationID == credentialRegistrationID, previous.allowInsecureHTTP == allowsHTTP {
            return
        }
        guard previous != nil || account.services.count < 64 else { throw ConnectionFailure.sizeLimit }
        if let oldID = previous?.credentialRegistrationID, oldID != credentialRegistrationID {
            Self.scheduleRemoval(oldID, in: &account)
        }
        Self.removeApprovals(for: declaration.id, from: &account)
        let generation = UUID()
        account.services[declaration.id] = .init(definition: declaration, fields: fields, certificatePin: certificatePin, secret: token,
                                                 secretDeclarationDigest: tokenDeclarationDigest, credentialRegistrationID: credentialRegistrationID,
                                                 origin: origin,
                                                 allowInsecureHTTP: allowsHTTP, generation: generation)
        if let reviewedRead {
            let approvalScreenID = registration?.approvalScreenID ?? reviewedRead.screenID
            guard !approvalScreenID.isEmpty else { throw ConnectionFailure.permissionRequired }
            try declaration.validate(alias: reviewedRead.alias)
            let declarationDigest = try Self.digest(declaration)
            // A denial at the generation shown by the modal cannot be bypassed by setup.
            let priorScope = declarationDigest + "/" + (previous?.generation.uuidString ?? "unconfigured")
            guard account.denials?[approvalScreenID]?[reviewedRead.alias] != priorScope else {
                throw ConnectionFailure.permissionRequired
            }
            try Self.recordApproval(screenID: approvalScreenID, alias: reviewedRead.alias, serviceID: declaration.id,
                                    declarationDigest: declarationDigest, generation: generation, in: &account)
        }
        accounts[owner] = account
        try persist(accounts)
    }

    /// Replaces executable-code consent while leaving the shared service and its token intact.
    /// Existing explicit denials remain in force for the same declaration and service generation.
    public func rotateScreenApprovalScope(owner: String, priorScope: String, nextScope: String) throws {
        guard !owner.isEmpty, !priorScope.isEmpty, !nextScope.isEmpty,
              priorScope != nextScope else { throw ConnectionFailure.permissionRequired }
        Self.lock.lock(); defer { Self.lock.unlock() }
        var accounts = try load()
        guard var account = accounts[owner] else { return }
        let priorApproval = account.approvals.removeValue(forKey: priorScope)
        let priorDenial = account.denials?.removeValue(forKey: priorScope)
        if let priorDenial { account.denials?[nextScope] = priorDenial }
        guard priorApproval != nil || priorDenial != nil else { return }
        accounts[owner] = account
        try persist(accounts)
    }

    public func isApproved(owner: String, screenID: String, manifest: DashboardManifest, alias: String) -> Bool {
        guard let declaration = manifest.connections.first(where: { $0.alias == alias })?.customHTTP else { return false }
        return (try? authorized(owner: owner, screenID: screenID, alias: alias, declaration: declaration)) != nil
    }

    public func approve(owner: String, screenID: String, manifest: DashboardManifest, alias: String, expectedGeneration: UUID? = nil,
                        requireOfferedAccess: Bool = false, permitJSONPost: Bool = false) throws {
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
        let usesPOST = declaration.operations.contains { $0.method == "POST" }
        if usesPOST {
            guard permitJSONPost, expectedGeneration == service.generation, service.supportsJSONPost else {
                throw ConnectionFailure.permissionRequired
            }
        }
        if requireOfferedAccess,
           account.denials?[screenID]?[alias] == declarationDigest + "/" + service.generation.uuidString {
            throw ConnectionFailure.permissionRequired
        }
        if let existing = account.approvals[screenID]?[alias],
           existing.declarationDigest == declarationDigest, existing.serviceGeneration == service.generation,
           !usesPOST || existing.permitsJSONPost == true { return }
        try Self.recordApproval(screenID: screenID, alias: alias, serviceID: declaration.id,
                                declarationDigest: declarationDigest, generation: service.generation,
                                permitsJSONPost: usesPOST ? true : nil, in: &account)
        accounts[owner] = account
        try persist(accounts)
    }

    private static func recordApproval(screenID: String, alias: String, serviceID: String, declarationDigest: String,
                                       generation: UUID, permitsJSONPost: Bool? = nil, in account: inout Account) throws {
        guard account.approvals[screenID] != nil || account.approvals.count < 256 else {
            throw ConnectionFailure.sizeLimit
        }
        var dashboard = account.approvals[screenID] ?? [:]
        guard dashboard[alias] != nil || dashboard.count < 32 else { throw ConnectionFailure.sizeLimit }
        dashboard[alias] = .init(serviceID: serviceID, declarationDigest: declarationDigest,
                                 serviceGeneration: generation, generation: UUID(), permitsJSONPost: permitsJSONPost)
        account.approvals[screenID] = dashboard
        account.denials?[screenID]?[alias] = nil
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
        guard var account = accounts[owner] else { return }
        account.services[serviceID] = nil
        account.connectionNames?[serviceID] = nil
        for registration in (account.credentialRegistrations ?? [:]).values
            where registration.context.serviceID == serviceID {
            Self.scheduleRemoval(registration.registrationID, in: &account)
        }
        Self.removeApprovals(for: serviceID, from: &account)
        accounts[owner] = account
        try persist(accounts)
    }

    public func removeOwner(_ owner: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var accounts = try load()
        guard let account = accounts[owner] else { return }
        if let registrations = account.credentialRegistrations, !registrations.isEmpty {
            var tombstones = Account(credentialRegistrations: registrations)
            for id in registrations.keys { Self.scheduleRemoval(id, in: &tombstones) }
            accounts[owner] = tombstones
        } else {
            accounts[owner] = nil
        }
        try persist(accounts)
    }

    fileprivate func authorized(owner: String, screenID: String, alias: String, declaration: CustomHTTPDeclaration) throws -> Authorized {
        let declarationDigest = try Self.digest(declaration)
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let account = try load()[owner], let service = account.services[declaration.id], service.matches(declaration),
              let approval = account.approvals[screenID]?[alias], approval.declarationDigest == declarationDigest,
              approval.serviceGeneration == service.generation else { throw ConnectionFailure.permissionRequired }
        if declaration.operations.contains(where: { $0.method == "POST" }) {
            guard approval.permitsJSONPost == true, service.supportsJSONPost else {
                throw ConnectionFailure.permissionRequired
            }
        }
        return .init(origin: service.origin, certificatePin: service.certificatePin, secret: service.secret, fields: service.fields, generation: approval.generation)
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

enum CustomHTTPDestination {
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

    static func url(origin: String, path: String, query: [URLQueryItem], resolver: any DestinationResolver,
                    diagnose: Bool = false) throws -> URL {
        guard var parts = URLComponents(string: origin), let host = parts.host, let scheme = parts.scheme else {
            throw ConnectionFailure.validationFailed
        }
        let addresses: [String]
        do { addresses = try resolver.addresses(for: host) }
        catch {
            if diagnose { throw CustomHTTPConnectionTestFailure.addressResolutionFailed }
            throw error
        }
        if diagnose && addresses.isEmpty { throw CustomHTTPConnectionTestFailure.addressResolutionFailed }
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

public enum CustomHTTPPostFailure: String, Error, Sendable {
    case modelUnavailable = "upstream_model_unavailable"
    case unauthorized = "upstream_unauthorized"
    case unavailable = "upstream_unavailable"
    case rejected = "upstream_rejected"

    init(response: HTTPTransportResponse) {
        switch response.status {
        case 401, 403: self = .unauthorized
        case 408, 429, 500...599: self = .unavailable
        default:
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: response.body)
            self = (400...499).contains(response.status) &&
                ["model_not_found", "model_unavailable"].contains(envelope?.error.code ?? "") ? .modelUnavailable : .rejected
        }
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { let code: String? }
        let error: Detail
    }
}

/// Executes declared JSON operations without accepting endpoints, headers or secrets from WebKit.
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

    func permitsJSONPost(alias: String, operation: String) -> Bool {
        manifest.connections.first(where: { $0.alias == alias })?.customHTTP?.operations
            .contains { $0.name == operation && $0.method == "POST" } == true
    }

    public func request(alias: String, operation: String, parameters: [String: String]) async throws -> Data {
        try await performRequest(alias: alias, operation: operation, parameters: parameters, postBody: nil, diagnose: false)
    }

    public func requestJSONPost(alias: String, operation name: String, body: Any) async throws -> Data {
        guard let operation = manifest.connections.first(where: { $0.alias == alias })?.customHTTP?.operations
            .first(where: { $0.name == name && $0.method == "POST" }) else { throw ConnectionFailure.permissionRequired }
        let encoded = try operation.validatedJSONBody(body)
        return try await performRequest(alias: alias, operation: name, parameters: [:], postBody: encoded, diagnose: false)
    }

    /// Runs an approved GET. Only the native test receives diagnostics.
    public func test(alias: String, operation: String) async throws {
        do { _ = try await performRequest(alias: alias, operation: operation, parameters: [:], postBody: nil, diagnose: true) }
        catch let failure as ConnectionFailure {
            switch failure {
            case .permissionRequired: throw CustomHTTPConnectionTestFailure.screenAccessRequired
            case .deniedEgress: throw CustomHTTPConnectionTestFailure.destinationBlocked
            case .validationFailed: throw CustomHTTPConnectionTestFailure.invalidConfiguration
            case .sizeLimit: throw CustomHTTPConnectionTestFailure.responseTooLarge
            case .timeout: throw CustomHTTPConnectionTestFailure.timedOut
            case .certificateRejected: throw CustomHTTPConnectionTestFailure.certificateRejected
            case .deviceOffline: throw CustomHTTPConnectionTestFailure.unreachable
            }
        }
    }

    private func performRequest(alias: String, operation: String, parameters: [String: String],
                                postBody: Data?, diagnose: Bool) async throws -> Data {
        guard let declaration = manifest.connections.first(where: { $0.alias == alias })?.customHTTP,
              let operation = declaration.operations.first(where: { $0.name == operation }),
              operation.method == (postBody == nil ? "GET" : "POST") else {
            throw ConnectionFailure.permissionRequired
        }
        try declaration.validate(alias: alias)
        guard vault.isApproved(owner: owner, screenID: screenID, manifest: manifest, alias: alias) else {
            if !diagnose, vault.shouldOfferAccess(owner: owner, screenID: screenID, alias: alias, declaration: declaration) {
                await accessRequired?(alias)
            }
            throw ConnectionFailure.permissionRequired
        }
        let approval = try vault.authorized(owner: owner, screenID: screenID, alias: alias, declaration: declaration)
        if let postBody, let token = approval.secret,
           let body = try? JSONSerialization.jsonObject(with: postBody), Self.contains(token, in: body) {
            throw ConnectionFailure.permissionRequired
        }
        let query = try Self.query(operation: operation, fields: approval.fields, parameters: parameters)
        let url = try CustomHTTPDestination.url(origin: approval.origin, path: operation.path, query: query,
                                                resolver: resolver, diagnose: diagnose)
        try Task.checkCancellation()
        try checkApproval(alias: alias, declaration: declaration, generation: approval.generation)
        var headers = ["Accept": "application/json"]
        if let token = approval.secret { headers["Authorization"] = "Bearer \(token)" }
        let bounds = postBody == nil ? HTTPAdapterBounds.production :
            HTTPAdapterBounds(timeoutSeconds: 60, maxResponseBytes: ConnectionBounds.httpResponseBytes)
        // A fresh session binds TLS trust to this pin and gives POST its own bounded resource timeout.
        let requestTransport: any HTTPTransport
        if approval.certificatePin != nil || (postBody != nil && transport is URLSessionHTTPTransport) {
            requestTransport = URLSessionHTTPTransport(bounds: bounds, privateRequests: true, certificatePin: approval.certificatePin)
        } else {
            requestTransport = transport
        }
        let request = AuthorizedHTTPRequest(url: url, method: operation.method, headers: headers, body: postBody,
                                            timeout: bounds.timeoutSeconds, maxBytes: bounds.maxResponseBytes)
        let result: HTTPTransportResponse
        do {
            if let native = requestTransport as? URLSessionHTTPTransport, diagnose || postBody != nil {
                result = try await native.send(request, diagnose: diagnose, preventBodyReplay: postBody != nil)
            } else {
                result = try await requestTransport.send(request)
            }
        } catch ConnectionFailure.deviceOffline where postBody != nil {
            throw CustomHTTPPostFailure.unavailable
        }
        try Task.checkCancellation()
        try checkApproval(alias: alias, declaration: declaration, generation: approval.generation)
        if diagnose && !(200...299).contains(result.status) {
            switch result.status {
            case 300...399: throw CustomHTTPConnectionTestFailure.redirectBlocked
            case 401: throw CustomHTTPConnectionTestFailure.unauthorized
            case 403: throw CustomHTTPConnectionTestFailure.forbidden
            case 100...599: throw CustomHTTPConnectionTestFailure.httpStatus(result.status)
            default: throw CustomHTTPConnectionTestFailure.invalidResponse
            }
        }
        guard !(300...399).contains(result.status) else { throw ConnectionFailure.deniedEgress }
        if postBody != nil {
            guard result.body.count <= ConnectionBounds.httpResponseBytes else { throw ConnectionFailure.sizeLimit }
            guard (200...299).contains(result.status) else { throw CustomHTTPPostFailure(response: result) }
        } else {
            guard (200...299).contains(result.status) else { throw ConnectionFailure.deviceOffline }
            guard result.body.count <= ConnectionBounds.httpResponseBytes else { throw ConnectionFailure.sizeLimit }
        }
        guard let json = try? JSONSerialization.jsonObject(with: result.body, options: .fragmentsAllowed) else {
            if diagnose { throw CustomHTTPConnectionTestFailure.invalidResponse }
            throw ConnectionFailure.validationFailed
        }
        if let token = approval.secret, Self.contains(token, in: json) {
            if diagnose { throw CustomHTTPConnectionTestFailure.invalidResponse }
            throw ConnectionFailure.permissionRequired
        }
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
