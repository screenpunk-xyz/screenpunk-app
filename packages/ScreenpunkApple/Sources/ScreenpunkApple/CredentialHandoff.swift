import CryptoKit
import Foundation
import ScreenpunkCore

/// This pairing secret is imported by native Settings and remains in device-local Keychain.
public struct CredentialHandoffPair: Codable, Sendable {
    public let version: Int
    public let relayOrigin: String
    public let pairID: String
    private let pairKey: String
    public let capabilityHash: String

    public static func parse(_ text: String, relayOrigin: String) throws -> Self {
        guard text.utf8.count <= 2048,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              Set(object.keys) == ["version", "relayOrigin", "pairID", "pairKey", "capabilityHash"],
              let pair = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              pair.version == 1, pair.relayOrigin == relayOrigin,
              Self.decodeBase64URL(pair.pairID)?.count == 16,
              Self.decodeBase64URL(pair.pairKey)?.count == 32,
              CredentialHandoffScope.isDigest(pair.capabilityHash) else {
            throw ConnectionFailure.validationFailed
        }
        return pair
    }

    public func challenge(for scope: CredentialHandoffScope) throws -> String {
        let message = try scope.authenticatedBytes()
        let key = try derivedKey(for: scope, purpose: "challenge")
        return Self.base64URL(Data(HMAC<SHA256>.authenticationCode(for: message, using: key)))
    }

    public func open(_ envelope: String, for scope: CredentialHandoffScope) throws -> String {
        guard envelope.utf8.count <= 5500, let bytes = Self.decodeBase64URL(envelope),
              (29...4124).contains(bytes.count) else { throw ConnectionFailure.validationFailed }
        let message = try scope.authenticatedBytes()
        let key = try derivedKey(for: scope, purpose: "envelope")
        let box = try AES.GCM.SealedBox(combined: bytes)
        let plaintext = try AES.GCM.open(box, using: key, authenticating: message)
        guard let token = String(data: plaintext, encoding: .utf8), (1...4096).contains(plaintext.count),
              plaintext.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || [46, 95, 126, 43, 47, 61, 45].contains($0) }) else {
            throw ConnectionFailure.validationFailed
        }
        return token
    }

    private func derivedKey(for scope: CredentialHandoffScope, purpose: String) throws -> SymmetricKey {
        guard version == 1, pairID == scope.pairID, relayOrigin == scope.relayOrigin,
              let material = Self.decodeBase64URL(pairKey), material.count == 32 else {
            throw ConnectionFailure.permissionRequired
        }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material),
                                       salt: Data(scope.deliveryID.utf8),
                                       info: Data("\(CredentialHandoffScope.domain):\(purpose)".utf8),
                                       outputByteCount: 32)
    }

    private static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ text: String) -> Data? {
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") +
            String(repeating: "=", count: (4 - text.utf8.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), base64URL(bytes) == text else { return nil }
        return bytes
    }
}

public struct CredentialHandoffScope: Codable, Equatable, Sendable {
    static let domain = "screenpunk-credential-handoff-v1"
    public let version: Int
    public let accountRoute: String
    public let relayOrigin: String
    public let deliveryID: String
    public let pairID: String
    public let requestID: String
    public let inputDigest: String
    public let deviceID: String
    public let screenID: String
    public let operationID: String
    public let alias: String
    public let name: String
    public let origin: String
    public let serviceID: String
    public let declarationDigest: String
    public let expiresAt: Int64

    public static func canonicalHTTPSOrigin(_ server: String) throws -> String {
        let origin = try CustomHTTPDestination.origin(server, allowInsecureHTTP: false)
        guard var parts = URLComponents(string: origin), parts.scheme == "https" else {
            throw ConnectionFailure.validationFailed
        }
        if parts.port == 443 { parts.port = nil }
        guard let normalized = parts.url?.absoluteString else { throw ConnectionFailure.validationFailed }
        return normalized
    }

    public static func declarationDigest(_ declaration: CustomHTTPDeclaration) throws -> String {
        AuthoringContract.contentDigest(try AuthoringContract.encodedCanonical(declaration))
    }

    func authenticatedBytes() throws -> Data {
        let strings = [accountRoute, relayOrigin, deliveryID, pairID, requestID, inputDigest, deviceID,
                       screenID, operationID, alias, name, origin, serviceID, declarationDigest]
        guard version == 1, expiresAt > 0, expiresAt <= 9_007_199_254_740_991,
              Self.isDigest(accountRoute), Self.isDigest(inputDigest), Self.isDigest(declarationDigest),
              UUID(uuidString: deliveryID)?.uuidString.lowercased() == deliveryID,
              strings.allSatisfy({ (1...512).contains($0.utf8.count) && $0.utf8.allSatisfy {
                  (32...126).contains($0) && $0 != 34 && $0 != 92
              } }) else { throw ConnectionFailure.validationFailed }
        let tuple: [Any] = [Self.domain, version] + strings.map { $0 as Any } + [expiresAt]
        return try JSONSerialization.data(withJSONObject: tuple, options: [.withoutEscapingSlashes])
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
