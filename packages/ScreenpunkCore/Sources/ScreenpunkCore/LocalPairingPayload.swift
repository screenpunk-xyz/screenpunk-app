import Foundation
import CryptoKit

public enum LocalPairingError: String, Error, LocalizedError, Sendable {
    case malformed, oversized, unsupported, expired, clock, unknownRequest, conflictingReply, replay, credentialUnavailable, connectionChanged
    public var errorDescription: String? {
        switch self {
        case .malformed: return "The connection code is invalid. Scan the code displayed on your Mac again."
        case .oversized: return "This connection code is too large. Import the private reply file instead."
        case .unsupported: return "This Mac uses an unsupported pairing or Codex version."
        case .expired: return "This setup request or connection code expired. Prepare a new request."
        case .clock: return "Check the date and time on both devices, then refresh the connection code."
        case .unknownRequest: return "Prepare a setup request on this iPad first."
        case .conflictingReply: return "A different reply already uses this setup request. Prepare a new request."
        case .replay: return "This setup request was already used. Prepare a new request."
        case .credentialUnavailable: return "The staged connection credentials are unavailable. Scan the code again."
        case .connectionChanged: return "The local connection changed. Prepare a new setup request."
        }
    }
}
public enum LocalPairingSource: Sendable { case qr, privateFile }
public enum LocalPairingLimits {
    public static let requestLifetime: Int64 = 30 * 60 * 1000
    public static let replyLifetime: Int64 = 5 * 60 * 1000
    public static let clockSkew: Int64 = 2 * 60 * 1000
    public static let codexVersion = "0.164.0-alpha.11.1"
    public static let protocolProfile = "macos-codex-0.164.0-alpha.11.1"
}
public struct LocalPairingRequest: Codable, Equatable, Sendable {
    public let type: String
    public let schemaVersion: Int
    public let pairingID: String
    public let nonce: String
    public let issuedAt: Int64
    public let expiresAt: Int64
    public let publicKeyOpenSSH: String
    public let publicKeySHA256: String
    public let deviceName: String
    public let codexVersion: String
    public let protocolProfile: String
    init(pairingID: String, nonce: String, issuedAt: Int64, publicKeyOpenSSH: String, publicKeySHA256: String, deviceName: String) {
        type = "screenpunk.pairing-request.v1"; schemaVersion = 1; self.pairingID = pairingID; self.nonce = nonce
        self.issuedAt = issuedAt; expiresAt = issuedAt + LocalPairingLimits.requestLifetime
        self.publicKeyOpenSSH = publicKeyOpenSSH; self.publicKeySHA256 = publicKeySHA256; self.deviceName = deviceName
        codexVersion = LocalPairingLimits.codexVersion; protocolProfile = LocalPairingLimits.protocolProfile
    }
    public func encoded() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(self) }
}
/// The bearer is deliberately not Encodable or printable. Persist only the candidate metadata.
public struct LocalPairingReply: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let type: String
    public let schemaVersion: Int
    public let pairingID: String
    public let nonce: String
    public let publicKeySHA256: String
    public let issuedAt: Int64
    public let expiresAt: Int64
    public let computerName: String
    public let host: String
    public let sshPort: Int
    public let username: String
    public let hostKeySHA256: String
    public let appServerPort: Int
    public let macWorkspace: String
    public let codexVersion: String
    public let protocolProfile: String
    public let serverLifecycle: LocalAgentServerLifecycle
    private var tokenBytes: Data
    fileprivate var appServerToken: String { String(decoding: tokenBytes, as: UTF8.self) }
    private enum CodingKeys: String, CodingKey { case type, schemaVersion, pairingID, nonce, publicKeySHA256, issuedAt, expiresAt, computerName, host, sshPort, username, hostKeySHA256, appServerPort, macWorkspace, codexVersion, protocolProfile, appServerToken, serverLifecycle }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type); schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        pairingID = try c.decode(String.self, forKey: .pairingID); nonce = try c.decode(String.self, forKey: .nonce)
        publicKeySHA256 = try c.decode(String.self, forKey: .publicKeySHA256)
        issuedAt = try c.decode(Int64.self, forKey: .issuedAt); expiresAt = try c.decode(Int64.self, forKey: .expiresAt)
        computerName = try c.decode(String.self, forKey: .computerName); host = try c.decode(String.self, forKey: .host)
        sshPort = try c.decode(Int.self, forKey: .sshPort); username = try c.decode(String.self, forKey: .username)
        hostKeySHA256 = try c.decode(String.self, forKey: .hostKeySHA256); appServerPort = try c.decode(Int.self, forKey: .appServerPort)
        macWorkspace = try c.decode(String.self, forKey: .macWorkspace); codexVersion = try c.decode(String.self, forKey: .codexVersion)
        protocolProfile = try c.decode(String.self, forKey: .protocolProfile)
        serverLifecycle = c.contains(.serverLifecycle) ? try c.decode(LocalAgentServerLifecycle.self, forKey: .serverLifecycle) : .foreground
        let token = try c.decode(String.self, forKey: .appServerToken)
        guard token.utf8.count <= 4096 else { throw LocalPairingError.malformed }
        tokenBytes = Data(token.utf8)
    }
    public var description: String { "LocalPairingReply(<private connection code>)" }
    public var debugDescription: String { description }
    mutating func clearSecret() { tokenBytes.resetBytes(in: 0..<tokenBytes.count); tokenBytes.removeAll(keepingCapacity: false) }
    func configuration(reference: String, id: String) -> LocalAgentConfiguration {
        .init(id: id, name: computerName, host: host, sshPort: sshPort, username: username, hostKeySHA256: hostKeySHA256, appServerPort: appServerPort, macWorkspace: macWorkspace, credentialReference: reference, pinnedCodexVersion: codexVersion, serverLifecycle: serverLifecycle)
    }
    func stage(in credentials: LocalPairingCredentialStore, identity: String, reference: String) throws {
        try credentials.stagePairingCredential(appServerToken: appServerToken, identityReference: identity, stagedReference: reference)
    }
}
public enum LocalPairingParser {
    private static let requestKeys: Set<String> = ["type", "schemaVersion", "pairingID", "nonce", "issuedAt", "expiresAt", "publicKeyOpenSSH", "publicKeySHA256", "deviceName", "codexVersion", "protocolProfile"]
    private static let replyKeys: Set<String> = ["type", "schemaVersion", "pairingID", "nonce", "publicKeySHA256", "issuedAt", "expiresAt", "computerName", "host", "sshPort", "username", "hostKeySHA256", "appServerPort", "macWorkspace", "codexVersion", "protocolProfile", "appServerToken"]
    public static func decodeRequest(_ data: Data, now: Int64) throws -> LocalPairingRequest {
        try envelope(data, limit: 8192, keys: requestKeys)
        guard let value = try? JSONDecoder().decode(LocalPairingRequest.self, from: data) else { throw LocalPairingError.malformed }
        try common(type: value.type, expected: "screenpunk.pairing-request.v1", version: value.schemaVersion, id: value.pairingID, nonce: value.nonce, digest: value.publicKeySHA256, codex: value.codexVersion, profile: value.protocolProfile)
        try times(issuedAt: value.issuedAt, expiresAt: value.expiresAt, lifetime: LocalPairingLimits.requestLifetime, now: now)
        guard validLabel(value.deviceName), try publicKeyDigest(value.publicKeyOpenSSH) == value.publicKeySHA256 else { throw LocalPairingError.malformed }
        return value
    }
    public static func decodeReply(_ data: Data, source: LocalPairingSource) throws -> LocalPairingReply {
        try envelope(data, limit: source == .qr ? 1536 : 8192, keys: replyKeys, optionalKeys: ["serverLifecycle"])
        guard let value = try? JSONDecoder().decode(LocalPairingReply.self, from: data) else { throw LocalPairingError.malformed }
        try common(type: value.type, expected: "screenpunk.pairing-reply.v1", version: value.schemaVersion, id: value.pairingID, nonce: value.nonce, digest: value.publicKeySHA256, codex: value.codexVersion, profile: value.protocolProfile)
        let hostAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:%_")
        let userAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let tokenAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~+/=")
        let parts = value.macWorkspace.split(separator: "/", omittingEmptySubsequences: false)
        guard validLabel(value.computerName), ascii(value.host, limit: 253, allowed: hostAllowed), !value.host.hasPrefix("-"), ascii(value.username, limit: 64, allowed: userAllowed), !value.username.hasPrefix("-"), validDigest(value.hostKeySHA256), (1...65535).contains(value.sshPort), (1...65535).contains(value.appServerPort), value.macWorkspace.hasPrefix("/"), value.macWorkspace.utf8.count <= 1024, !value.macWorkspace.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !parts.contains(".."), !parts.contains("."), !value.macWorkspace.contains("//"), value.macWorkspace != "/", ascii(value.appServerToken, limit: 4096, allowed: tokenAllowed), value.appServerToken.first != "=", value.appServerToken.drop(while: { $0 != "=" }).allSatisfy({ $0 == "=" }) else { throw LocalPairingError.malformed }
        return value
    }
    static func times(issuedAt: Int64, expiresAt: Int64, lifetime: Int64, now: Int64) throws {
        guard issuedAt > 0, expiresAt > issuedAt, expiresAt - issuedAt <= lifetime, now > 0 else { throw LocalPairingError.malformed }
        guard issuedAt <= now || issuedAt - now <= LocalPairingLimits.clockSkew else { throw LocalPairingError.clock }
        guard expiresAt >= now || now - expiresAt <= LocalPairingLimits.clockSkew else { throw LocalPairingError.expired }
    }
    static func validLabel(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespaces).isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet(charactersIn: "\u{202a}\u{202b}\u{202c}\u{202d}\u{202e}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0) } }
    private static func ascii(_ value: String, limit: Int, allowed: CharacterSet) -> Bool { !value.isEmpty && value.utf8.count <= limit && value.unicodeScalars.allSatisfy { allowed.contains($0) } }
    private static func validDigest(_ value: String) -> Bool {
        guard value.hasPrefix("SHA256:"), value.count == 50, let bytes = Data(base64Encoded: String(value.dropFirst(7)) + "="), bytes.count == 32 else { return false }
        return "SHA256:" + bytes.base64EncodedString().replacingOccurrences(of: "=", with: "") == value
    }
    private static func common(type: String, expected: String, version: Int, id: String, nonce: String, digest: String, codex: String, profile: String) throws {
        guard type == expected, version == 1, codex == LocalPairingLimits.codexVersion, profile == LocalPairingLimits.protocolProfile else { throw LocalPairingError.unsupported }
        guard UUID(uuidString: id) != nil, nonce.count == 43, let bytes = Data(base64Encoded: nonce.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="), bytes.count == 32, bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == nonce, validDigest(digest) else { throw LocalPairingError.malformed }
    }
    public static func publicKeyDigest(_ publicKey: String) throws -> String {
        guard publicKey.utf8.count <= 512, !publicKey.contains("\n"), !publicKey.contains("\r") else { throw LocalPairingError.malformed }
        let parts = publicKey.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "ssh-ed25519", let blob = Data(base64Encoded: String(parts[1])), blob.count == 51, Array(blob.prefix(4)) == [0,0,0,11], String(data: blob.subdata(in: 4..<15), encoding: .utf8) == "ssh-ed25519", Array(blob.subdata(in: 15..<19)) == [0,0,0,32] else { throw LocalPairingError.malformed }
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// Flat schema only. Detect duplicate (including escaped) keys before Foundation's decoder discards them.
    private static func envelope(_ data: Data, limit: Int, keys: Set<String>, optionalKeys: Set<String> = []) throws {
        guard data.count <= limit else { throw LocalPairingError.oversized }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], keys.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: keys.union(optionalKeys)), object.values.allSatisfy({ $0 is String || $0 is NSNumber }) else { throw LocalPairingError.malformed }
        let bytes = Array(data); var index = 0; var seen = Set<String>(); var depth = 0; var expectingKey = false
        while index < bytes.count {
            let b = bytes[index]
            if b == 123 { depth += 1; expectingKey = true }
            else if b == 125 { depth -= 1 }
            else if b == 44 && depth == 1 { expectingKey = true }
            else if b == 34 {
                let start = index; index += 1
                while index < bytes.count { if bytes[index] == 92 { index += 2; continue }; if bytes[index] == 34 { break }; index += 1 }
                guard index < bytes.count else { throw LocalPairingError.malformed }
                if expectingKey && depth == 1 {
                    guard let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start...index])), seen.insert(key).inserted else { throw LocalPairingError.malformed }
                    expectingKey = false
                }
            }
            index += 1
        }
        guard seen == Set(object.keys) else { throw LocalPairingError.malformed }
    }
}
