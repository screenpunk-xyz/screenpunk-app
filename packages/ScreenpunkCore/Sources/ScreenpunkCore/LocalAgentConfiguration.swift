import Foundation

public enum LocalAgentServerLifecycle: String, Codable, Sendable { case foreground, background }

/// Public endpoint metadata only. credentialReference points into the device Keychain.
public struct LocalAgentConfiguration: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var host: String
    public var sshPort: Int
    public var username: String
    public var hostKeySHA256: String
    public var appServerPort: Int
    public var macWorkspace: String
    public var credentialReference: String
    public var pinnedCodexVersion: String
    public var profileThreads: [String: String]
    public var lastSuccessfulConnectionAt: Int64?
    public var serverLifecycle: LocalAgentServerLifecycle
    public init(id: String = UUID().uuidString, name: String = "Local agent", host: String, sshPort: Int = 22, username: String, hostKeySHA256: String, appServerPort: Int = 4500, macWorkspace: String, credentialReference: String, pinnedCodexVersion: String = "0.164.0-alpha.11.1", profileThreads: [String: String] = [:], lastSuccessfulConnectionAt: Int64? = nil, serverLifecycle: LocalAgentServerLifecycle = .foreground) {
        self.id = id; self.name = name; self.host = host; self.sshPort = sshPort; self.username = username
        self.hostKeySHA256 = hostKeySHA256; self.appServerPort = appServerPort; self.macWorkspace = macWorkspace
        self.credentialReference = credentialReference; self.pinnedCodexVersion = pinnedCodexVersion
        self.profileThreads = profileThreads; self.lastSuccessfulConnectionAt = lastSuccessfulConnectionAt; self.serverLifecycle = serverLifecycle
    }
    private enum CodingKeys: String, CodingKey { case id, name, host, sshPort, username, hostKeySHA256, appServerPort, macWorkspace, credentialReference, pinnedCodexVersion, profileThreads, lastSuccessfulConnectionAt, serverLifecycle }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name), host: try c.decode(String.self, forKey: .host), sshPort: try c.decode(Int.self, forKey: .sshPort), username: try c.decode(String.self, forKey: .username), hostKeySHA256: try c.decode(String.self, forKey: .hostKeySHA256), appServerPort: try c.decode(Int.self, forKey: .appServerPort), macWorkspace: try c.decode(String.self, forKey: .macWorkspace), credentialReference: try c.decode(String.self, forKey: .credentialReference), pinnedCodexVersion: try c.decode(String.self, forKey: .pinnedCodexVersion), profileThreads: try c.decodeIfPresent([String: String].self, forKey: .profileThreads) ?? [:], lastSuccessfulConnectionAt: try c.decodeIfPresent(Int64.self, forKey: .lastSuccessfulConnectionAt), serverLifecycle: c.contains(.serverLifecycle) ? try c.decode(LocalAgentServerLifecycle.self, forKey: .serverLifecycle) : .foreground)
    }
}
public final class LocalAgentConfigurationRepository: @unchecked Sendable {
    private struct State: Codable {
        var configuration: LocalAgentConfiguration?
        var pairingCommits: [String: LocalPairingCommit] = [:]
        private enum CodingKeys: String, CodingKey { case configuration, pairingCommits }
        init(configuration: LocalAgentConfiguration?, pairingCommits: [String: LocalPairingCommit] = [:]) { self.configuration = configuration; self.pairingCommits = pairingCommits }
        init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); configuration = try c.decodeIfPresent(LocalAgentConfiguration.self, forKey: .configuration); pairingCommits = try c.decodeIfPresent([String: LocalPairingCommit].self, forKey: .pairingCommits) ?? [:] }
    }
    private static let sharedLock = NSRecursiveLock()
    private let lock = LocalAgentConfigurationRepository.sharedLock
    private let file: LocalDurableFile<State>
    public init(rootDirectory: URL? = nil) throws { file = try .init(kind: "configuration", rootDirectory: rootDirectory) }
    public func load() throws -> LocalAgentConfiguration? { try lock.locallyLocked { try file.load()?.configuration } }
    public func save(_ configuration: LocalAgentConfiguration) throws {
        try lock.locallyLocked {
            guard !configuration.id.isEmpty, !configuration.host.isEmpty, !configuration.username.isEmpty,
                  !configuration.hostKeySHA256.isEmpty, !configuration.credentialReference.isEmpty,
                  (1...65535).contains(configuration.sshPort), (1...65535).contains(configuration.appServerPort),
                  configuration.macWorkspace.hasPrefix("/"), !configuration.macWorkspace.contains("\0"),
                  configuration.profileThreads.allSatisfy({ !$0.key.isEmpty && !$0.value.isEmpty }),
                  Set(configuration.profileThreads.values).count == configuration.profileThreads.count else { throw LocalPersistenceError.invalid("Complete the Mac endpoint settings first.") }
            if let previous = try load(), previous.id == configuration.id {
                let endpointChanged = previous.host != configuration.host || previous.sshPort != configuration.sshPort || previous.username != configuration.username || previous.hostKeySHA256 != configuration.hostKeySHA256 || previous.appServerPort != configuration.appServerPort || previous.macWorkspace != configuration.macWorkspace || previous.credentialReference != configuration.credentialReference
                guard !endpointChanged else { throw LocalPersistenceError.conflict("Use a new connection ID when changing the Mac endpoint.") }
            }
            var state = try file.load() ?? State(configuration: nil); state.configuration = configuration; try file.save(state)
        }
    }
    public func pairingCommit(pairingID: String) throws -> LocalPairingCommit? { try lock.locallyLocked { try file.load()?.pairingCommits[pairingID] } }
    /// Endpoint and consumed pairing receipt share one durable atomic write.
    public func commitPairing(_ configuration: LocalAgentConfiguration, expectedConfigurationID: String?, pairingID: String, replyDigest: String, nonce: String? = nil) throws {
        try lock.locallyLocked {
            var state = try file.load() ?? State(configuration: nil)
            guard UUID(uuidString: pairingID) != nil, replyDigest.count == 64 else { throw LocalPairingError.malformed }
            if let receipt = state.pairingCommits[pairingID] {
                guard receipt.replyDigest == replyDigest, receipt.configurationID == configuration.id, state.configuration?.id == configuration.id else { throw LocalPairingError.replay }
                return
            }
            guard state.configuration?.id == expectedConfigurationID else { throw LocalPairingError.connectionChanged }
            let nonceDigest = nonce.map { LocalPairingParser.digest(Data($0.utf8)) }
            if let nonceDigest, state.pairingCommits.values.contains(where: { $0.nonceDigest == nonceDigest }) { throw LocalPairingError.replay }
            // Use the established public endpoint validator, then persist receipt with that endpoint.
            guard configuration.id != expectedConfigurationID, !configuration.host.isEmpty, !configuration.username.isEmpty, !configuration.credentialReference.isEmpty,
                  (1...65535).contains(configuration.sshPort), (1...65535).contains(configuration.appServerPort), configuration.macWorkspace.hasPrefix("/") else { throw LocalPairingError.malformed }
            state.configuration = configuration
            state.pairingCommits[pairingID] = .init(pairingID: pairingID, replyDigest: replyDigest, configurationID: configuration.id, nonceDigest: nonceDigest)
            // Historical requests have no pending nonce and cannot be imported again. Keep bounded recovery receipts.
            if state.pairingCommits.count > 256 {
                for key in state.pairingCommits.keys.filter({ $0 != pairingID }).sorted().prefix(state.pairingCommits.count - 256) { state.pairingCommits.removeValue(forKey: key) }
            }
            try file.save(state)
        }
    }
    public func setThreadID(_ threadID: String, profileID: String, configurationID: String) throws {
        try lock.locallyLocked {
            guard var config = try load(), config.id == configurationID else { throw LocalPersistenceError.conflict("The local connection changed.") }
            guard !threadID.isEmpty, !profileID.isEmpty else { throw LocalPersistenceError.invalid("The local thread identity is incomplete.") }
            // A dedicated thread cannot be reused across profiles.
            guard !config.profileThreads.contains(where: { $0.key != profileID && $0.value == threadID }) else { throw LocalPersistenceError.conflict("This thread belongs to another profile.") }
            config.profileThreads[profileID] = threadID; var state = try file.load() ?? State(configuration: nil); state.configuration = config; try file.save(state)
        }
    }
    /// Publish a thread only if this profile still has the observed mapping.
    /// Pairing commits, other profile threads and credentials remain unchanged.
    public func replaceThreadID(_ threadID: String, profileID: String, configurationID: String, expectedThreadID: String?) throws {
        try lock.locallyLocked {
            guard var config = try load(), config.id == configurationID,
                  config.profileThreads[profileID] == expectedThreadID else { throw LocalPersistenceError.conflict("The local conversation changed while checking readiness.") }
            guard !threadID.isEmpty, !profileID.isEmpty,
                  !config.profileThreads.contains(where: { $0.key != profileID && $0.value == threadID }) else { throw LocalPersistenceError.conflict("This thread belongs to another profile.") }
            if config.profileThreads[profileID] == threadID { return }
            config.profileThreads[profileID] = threadID
            var state = try file.load() ?? State(configuration: nil)
            state.configuration = config
            try file.save(state)
        }
    }
    public func markSuccessfulConnection(configurationID: String, at: Int64) throws {
        try lock.locallyLocked {
            guard var config = try load(), config.id == configurationID else { throw LocalPersistenceError.conflict("The local connection changed.") }
            config.lastSuccessfulConnectionAt = at; var state = try file.load() ?? State(configuration: nil); state.configuration = config; try file.save(state)
        }
    }
    @discardableResult public func remove(configurationID: String) throws -> LocalAgentConfiguration? {
        try lock.locallyLocked {
            guard let config = try load() else { return nil }
            guard config.id == configurationID else { throw LocalPersistenceError.conflict("The local connection changed.") }
            var state = try file.load() ?? State(configuration: nil); state.configuration = nil; try file.save(state); return config
        }
    }
}
