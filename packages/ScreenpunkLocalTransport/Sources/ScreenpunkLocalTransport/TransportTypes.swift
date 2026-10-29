import Foundation

/// Non-secret settings. A fingerprint must be confirmed outside this connection before use.
public struct SSHTransportEndpoint: Sendable, Codable, Equatable {
    public var host: String
    public var port: Int
    public var username: String
    public var hostKeySHA256: String
    public var appServerPort: Int

    public init(host: String, port: Int = 22, username: String, hostKeySHA256: String, appServerPort: Int) {
        self.host = host
        self.port = port
        self.username = username
        self.hostKeySHA256 = hostKeySHA256
        self.appServerPort = appServerPort
    }
}

/// An account identifier in a credential store, never credential bytes.
public struct SSHCredentialReference: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Ed25519 raw private-key bytes and the App Server bearer token. Deliberately not Codable.
public struct SSHTransportCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let privateKey: Data
    public let appServerToken: String
    public init(privateKey: Data, appServerToken: String) {
        self.privateKey = privateKey
        self.appServerToken = appServerToken
    }
    public var description: String { "SSHTransportCredentials(<redacted>)" }
    public var debugDescription: String { description }
}

/// The transport calls this synchronous store from its actor, away from the main actor.
public protocol SSHCredentialStore: Sendable {
    func load(reference: SSHCredentialReference) throws -> SSHTransportCredentials
}

public enum SSHTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidEndpoint
    case invalidFingerprint
    case credentialsUnavailable
    case invalidCredentials
    case hostKeyMismatch(expected: String, observed: String)
    case authenticationFailed
    case unreachable
    case timeout
    case webSocketRejected(status: Int)
    case protocolViolation
    case messageTooLarge
    case receiveBufferFull
    case disconnected

    public var description: String {
        switch self {
        case .invalidEndpoint: return "The SSH endpoint is invalid."
        case .invalidFingerprint: return "A valid, confirmed SHA256 host-key fingerprint is required."
        case .credentialsUnavailable: return "The saved SSH credentials are unavailable."
        case .invalidCredentials: return "The saved SSH credentials are invalid."
        case .hostKeyMismatch: return "The SSH host key does not match the confirmed fingerprint."
        case .authenticationFailed: return "The SSH public key was rejected."
        case .unreachable: return "The SSH host could not be reached."
        case .timeout: return "The connection timed out."
        case .webSocketRejected(let status): return "App Server rejected the WebSocket connection (HTTP \(status))."
        case .protocolViolation: return "The peer sent an invalid WebSocket message."
        case .messageTooLarge: return "The WebSocket message exceeded the size limit."
        case .receiveBufferFull: return "The receiver could not keep up with incoming messages."
        case .disconnected: return "The connection closed."
        }
    }
}

extension SSHTransportEndpoint {
    func validate() throws {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !host.isEmpty, host.count <= 253, host.rangeOfCharacter(from: forbidden) == nil,
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "/@?#")) == nil,
              !username.isEmpty, username.utf8.count <= 255,
              username.rangeOfCharacter(from: forbidden) == nil,
              (1...65535).contains(port), (1...65535).contains(appServerPort) else {
            throw SSHTransportError.invalidEndpoint
        }
        guard hostKeySHA256.hasPrefix("SHA256:") else { throw SSHTransportError.invalidFingerprint }
        let suffix = String(hostKeySHA256.dropFirst(7))
        guard suffix.count == 43, !suffix.contains("="),
              suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/") }),
              let decoded = Data(base64Encoded: suffix + "="), decoded.count == 32,
              decoded.base64EncodedString().dropLast() == suffix else { throw SSHTransportError.invalidFingerprint }
    }
}

extension SSHTransportCredentials {
    func validate() throws {
        // RFC 6750 b64token; CR/LF and whitespace can never enter the HTTP headers.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/")
        let content = appServerToken[...]
        let core = content.prefix(while: { $0 != "=" })
        let padding = content.dropFirst(core.count)
        guard privateKey.count == 32, !core.isEmpty, appServerToken.utf8.count <= 8192,
              core.unicodeScalars.allSatisfy({ allowed.contains($0) }), padding.allSatisfy({ $0 == "=" }) else {
            throw SSHTransportError.invalidCredentials
        }
    }
}
