import Foundation
import CryptoKit

/// Credentials remain in the platform vault; Core sees opaque references only.
public protocol LocalPairingCredentialStore {
    func stagePairingCredential(appServerToken: String, identityReference: String, stagedReference: String) throws
    func hasPairingCredential(reference: String) throws -> Bool
    func forgetPairingCredential(reference: String) throws
}
public struct LocalPairingCommit: Codable, Equatable, Sendable {
    public let pairingID: String
    public let replyDigest: String
    public let configurationID: String
    public let nonceDigest: String?
}
public struct LocalPairingImport: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let pairingID: String
    public let replyDigest: String
    public let configuration: LocalAgentConfiguration
    public let expiresAt: Int64
    let expectedConfigurationID: String?
    let issuedAt: Int64
}
public enum LocalPairingCheckpoint: Sendable { case intentSaved, credentialStaged, candidateSaved, endpointCommitted, pendingCleared }
/// One journal contains pending identity, staged ownership and candidate metadata, never the bearer.
public final class LocalPairingRepository: @unchecked Sendable {
    private struct Pending: Codable { var request: LocalPairingRequest; var identityReference: String }
    private struct State: Codable { var pending: Pending?; var candidate: LocalPairingImport?; var candidateReady = false }
    private let file: LocalDurableFile<State>
    private let configurations: LocalAgentConfigurationRepository
    private static let sharedLock = NSRecursiveLock()
    private let lock = LocalPairingRepository.sharedLock
    private let checkpoint: ((LocalPairingCheckpoint) throws -> Void)?
    public init(rootDirectory: URL? = nil, configurationRepository: LocalAgentConfigurationRepository, checkpoint: ((LocalPairingCheckpoint) throws -> Void)? = nil) throws {
        file = try .init(kind: "pairing", rootDirectory: rootDirectory?.appendingPathComponent("pairing", isDirectory: true))
        configurations = configurationRepository; self.checkpoint = checkpoint
    }
    private func load() throws -> State { try file.load() ?? State() }
    /// Call cancel before replacing an unfinished import. The original identity may be reused.
    public func begin(publicKeyOpenSSH: String, identityReference: String, deviceName: String, now: Int64) throws -> LocalPairingRequest {
        try lock.locallyLocked {
            var state = try load()
            guard state.candidate == nil else { throw LocalPairingError.conflictingReply }
            guard !identityReference.isEmpty, identityReference.utf8.count <= 128, now > 0, now < Int64.max - LocalPairingLimits.requestLifetime, LocalPairingParser.validLabel(deviceName) else { throw LocalPairingError.malformed }
            var rng = SystemRandomNumberGenerator()
            let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let request = LocalPairingRequest(pairingID: UUID().uuidString, nonce: nonce, issuedAt: now, publicKeyOpenSSH: publicKeyOpenSSH, publicKeySHA256: try LocalPairingParser.publicKeyDigest(publicKeyOpenSSH), deviceName: deviceName)
            state.pending = .init(request: request, identityReference: identityReference); try file.save(state); return request
        }
    }
    public func pendingIdentityReference() throws -> String? { try lock.locallyLocked { try load().pending?.identityReference } }
    public func pendingRequest(now: Int64) throws -> LocalPairingRequest? {
        try lock.locallyLocked {
            guard let pending = try load().pending else { return nil }
            try LocalPairingParser.times(issuedAt: pending.request.issuedAt, expiresAt: pending.request.expiresAt, lifetime: LocalPairingLimits.requestLifetime, now: now)
            return pending.request
        }
    }
    public func stageReply(_ data: Data, source: LocalPairingSource, now: Int64, credentials: LocalPairingCredentialStore) throws -> LocalPairingImport {
        try lock.locallyLocked {
            var reply = try LocalPairingParser.decodeReply(data, source: source); defer { reply.clearSecret() }
            var state = try load()
            guard let pending = state.pending else { throw LocalPairingError.unknownRequest }
            guard try configurations.pairingCommit(pairingID: reply.pairingID) == nil else { throw LocalPairingError.replay }
            guard pending.request.pairingID == reply.pairingID, pending.request.nonce == reply.nonce, pending.request.publicKeySHA256 == reply.publicKeySHA256 else { throw LocalPairingError.unknownRequest }
            try LocalPairingParser.times(issuedAt: pending.request.issuedAt, expiresAt: pending.request.expiresAt, lifetime: LocalPairingLimits.requestLifetime, now: now)
            try LocalPairingParser.times(issuedAt: reply.issuedAt, expiresAt: reply.expiresAt, lifetime: LocalPairingLimits.replyLifetime, now: now)
            guard reply.issuedAt >= pending.request.issuedAt - LocalPairingLimits.clockSkew else { throw LocalPairingError.clock }
            let object = try JSONSerialization.jsonObject(with: data)
            let digest = LocalPairingParser.digest(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            let candidate: LocalPairingImport
            if let existing = state.candidate {
                guard existing.replyDigest == digest else { throw LocalPairingError.conflictingReply }
                candidate = existing
            } else {
                let id = UUID().uuidString, reference = "pairing-" + UUID().uuidString
                candidate = .init(id: id, pairingID: reply.pairingID, replyDigest: digest, configuration: reply.configuration(reference: reference, id: id), expiresAt: reply.expiresAt, expectedConfigurationID: try configurations.load()?.id, issuedAt: reply.issuedAt)
                state.candidate = candidate; state.candidateReady = false
                try file.save(state); try checkpoint?(.intentSaved)
            }
            guard try configurations.load()?.id == candidate.expectedConfigurationID else { throw LocalPairingError.connectionChanged }
            // The vault must make exact repetition idempotent and reject overwriting any other value.
            try reply.stage(in: credentials, identity: pending.identityReference, reference: candidate.configuration.credentialReference)
            try checkpoint?(.credentialStaged)
            state.candidateReady = true; try file.save(state); try checkpoint?(.candidateSaved)
            return candidate
        }
    }
    /// The caller authenticates/tests this exact candidate before committing it.
    public func commit(importID: String, replyDigest: String, now: Int64, credentials: LocalPairingCredentialStore) throws -> LocalAgentConfiguration {
        try lock.locallyLocked {
            var state = try load()
            guard let candidate = state.candidate, state.candidateReady, candidate.id == importID, candidate.replyDigest == replyDigest, let pending = state.pending else { throw LocalPairingError.unknownRequest }
            try LocalPairingParser.times(issuedAt: pending.request.issuedAt, expiresAt: pending.request.expiresAt, lifetime: LocalPairingLimits.requestLifetime, now: now)
            try LocalPairingParser.times(issuedAt: candidate.issuedAt, expiresAt: candidate.expiresAt, lifetime: LocalPairingLimits.replyLifetime, now: now)
            guard try credentials.hasPairingCredential(reference: candidate.configuration.credentialReference) else { throw LocalPairingError.credentialUnavailable }
            try configurations.commitPairing(candidate.configuration, expectedConfigurationID: candidate.expectedConfigurationID, pairingID: candidate.pairingID, replyDigest: candidate.replyDigest, nonce: pending.request.nonce)
            try checkpoint?(.endpointCommitted)
            state = State(); try file.save(state); try checkpoint?(.pendingCleared)
            return candidate.configuration
        }
    }
    public func recover(now: Int64, credentials: LocalPairingCredentialStore) throws -> LocalPairingImport? {
        try lock.locallyLocked {
            var state = try load()
            if let candidate = state.candidate, let receipt = try configurations.pairingCommit(pairingID: candidate.pairingID) {
                guard receipt.replyDigest == candidate.replyDigest, receipt.configurationID == candidate.configuration.id else { throw LocalPairingError.conflictingReply }
                // A newer endpoint may have superseded this committed import: never reinstall it.
                state = State(); try file.save(state); return nil
            }
            guard let pending = state.pending else { return nil }
            do {
                try LocalPairingParser.times(issuedAt: pending.request.issuedAt, expiresAt: pending.request.expiresAt, lifetime: LocalPairingLimits.requestLifetime, now: now)
                if let candidate = state.candidate { try LocalPairingParser.times(issuedAt: candidate.issuedAt, expiresAt: candidate.expiresAt, lifetime: LocalPairingLimits.replyLifetime, now: now) }
            } catch LocalPairingError.expired { try cancel(credentials: credentials); return nil }
            guard let candidate = state.candidate else { return nil }
            guard try configurations.load()?.id == candidate.expectedConfigurationID else { try cancel(credentials: credentials); throw LocalPairingError.connectionChanged }
            // Intent is saved before vault write, so a crash there requires the private reply again.
            guard try credentials.hasPairingCredential(reference: candidate.configuration.credentialReference) else { return nil }
            if !state.candidateReady { state.candidateReady = true; try file.save(state) }
            return candidate
        }
    }
    public func cancel(credentials: LocalPairingCredentialStore) throws {
        try lock.locallyLocked {
            let state = try load()
            if let candidate = state.candidate {
                let committed = try configurations.pairingCommit(pairingID: candidate.pairingID)
                let active = try configurations.load()
                if committed == nil && active?.credentialReference != candidate.configuration.credentialReference {
                    try credentials.forgetPairingCredential(reference: candidate.configuration.credentialReference)
                }
            }
            try file.save(State())
        }
    }
    public func expire(now: Int64, credentials: LocalPairingCredentialStore) throws { _ = try recover(now: now, credentials: credentials) }
}
