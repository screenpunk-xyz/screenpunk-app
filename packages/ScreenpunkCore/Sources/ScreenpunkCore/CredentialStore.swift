import Foundation

/// Public app Cloud identity. The server's user ID remains unchanged on the wire;
/// only local storage ownership includes the origin outside the legacy staging service.
public struct CloudOriginScope: Equatable, Sendable {
    public static let legacyStagingOrigin = "https://staging.screenpunk.xyz"
    public static let legacyKeychainService = "xyz.screenpunk.one.cloud"
    public let canonicalOrigin: String
    public var permitsLegacyMigration: Bool { canonicalOrigin == Self.legacyStagingOrigin }
    public var keychainService: String { Self.legacyKeychainService + ".origin." + Self.encode(canonicalOrigin) }
    public var url: URL { URL(string: canonicalOrigin)! }

    public init?(origin: String) {
        guard var components = URLComponents(string: origin), components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        components.scheme = "https"; components.host = host
        if components.port == 443 { components.port = nil }
        components.path = ""
        guard let canonical = components.string, components.url != nil else { return nil }
        canonicalOrigin = canonical
    }

    public func localAccountID(serverUserID: String) -> String {
        // A fixed-width ID also fits the authoring contract's opaque libraryID limit.
        permitsLegacyMigration ? serverUserID : "cloud-origin:" + AuthoringContract.contentDigest(Data((canonicalOrigin + "\n" + serverUserID).utf8))
    }

    /// Restoring a session must also restore its Cloud library after an origin/account
    /// switch. An intentionally selected, unlinked local library stays available locally.
    public func shouldRestoreAccountProfile(activeProfile: LocalProfileDescriptor?, serverUserID: String) -> Bool {
        guard let activeProfile else { return true }
        if activeProfile.cloudBinding == nil, activeProfile.libraryOwner.hasPrefix("local:") { return false }
        let activeAccountID = activeProfile.cloudBinding?.accountID ?? activeProfile.libraryOwner
        return activeAccountID != localAccountID(serverUserID: serverUserID)
    }

    private static func encode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// The adapter owns platform access; the migration policy can be exercised without Keychain.
public protocol CloudCredentialVault {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

public struct OriginScopedCloudCredentials {
    public let scope: CloudOriginScope
    public init(scope: CloudOriginScope) { self.scope = scope }

    public func load(account: String, vault: any CloudCredentialVault) throws -> Data? {
        if let scoped = try vault.read(service: scope.keychainService, account: account) {
            // Empty data is a durable signed-out marker. Never retry legacy migration.
            return scoped.isEmpty ? nil : scoped
        }
        guard scope.permitsLegacyMigration,
              let legacy = try vault.read(service: CloudOriginScope.legacyKeychainService, account: account) else { return nil }
        // Preserve the original until the scoped copy is durable. A failed cleanup is
        // harmless: future reads always prefer the scoped value, including its marker.
        try vault.write(legacy, service: scope.keychainService, account: account)
        try? vault.delete(service: CloudOriginScope.legacyKeychainService, account: account)
        return legacy.isEmpty ? nil : legacy
    }

    public func save(_ data: Data, account: String, vault: any CloudCredentialVault) throws {
        try vault.write(data, service: scope.keychainService, account: account)
        if scope.permitsLegacyMigration { try? vault.delete(service: CloudOriginScope.legacyKeychainService, account: account) }
    }

    public func clear(account: String, vault: any CloudCredentialVault) throws {
        // Persist before cleanup so a leftover legacy session can never be resurrected.
        try save(Data(), account: account, vault: vault)
    }
}

/// Native secret storage. Implementations must not write secrets to packages, logs, or MCP.
public protocol CredentialStore: Sendable {
    func secret(for authRef: String) throws -> Data?
    func put(_ secret: Data, for authRef: String) throws
    func delete(_ authRef: String) throws
    func deleteAll() throws
}

public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]

    public init() {}

    public func secret(for authRef: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[authRef]
    }

    public func put(_ secret: Data, for authRef: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[authRef] = secret
    }

    public func delete(_ authRef: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeValue(forKey: authRef)
    }

    public func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeAll()
    }

    public var debugDescription: String {
        "MemoryCredentialStore(count: redacted)"
    }
}
