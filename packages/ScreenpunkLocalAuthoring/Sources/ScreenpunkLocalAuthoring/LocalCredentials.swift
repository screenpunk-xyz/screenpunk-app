import Foundation
import CryptoKit
import Security
import ScreenpunkCore
import ScreenpunkLocalTransport

public struct LocalCredentialSetup: Sendable, Equatable {
    public let reference: SSHCredentialReference
    public let publicKeyOpenSSH: String
}
public enum LocalCredentialError: Error, LocalizedError {
    case invalidToken, unavailable, storageFailure
    public var errorDescription: String? {
        switch self { case .invalidToken: return "Enter the App Server bearer token without spaces or line breaks."
        case .unavailable: return "The saved local Mac credentials are unavailable."
        case .storageFailure: return "The local Mac credentials could not be saved in Keychain." }
    }
}
public protocol LocalCredentialVault: SSHCredentialStore, LocalPairingCredentialStore {
    func createIdentity() throws -> LocalCredentialSetup
    func create(appServerToken: String) throws -> LocalCredentialSetup
    func updateToken(_ token: String, reference: SSHCredentialReference) throws
    func publicKey(reference: SSHCredentialReference) throws -> String
    func forget(reference: SSHCredentialReference) throws
}
private func validateToken(_ token: String) throws {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/")
    let core = token.prefix(while: { $0 != "=" })
    guard !core.isEmpty, token.utf8.count <= 8192,
          core.unicodeScalars.allSatisfy({ allowed.contains($0) }), token.dropFirst(core.count).allSatisfy({ $0 == "=" }) else { throw LocalCredentialError.invalidToken }
}
private func openSSH(_ key: Data) throws -> String {
    let publicBytes = try Curve25519.Signing.PrivateKey(rawRepresentation: key).publicKey.rawRepresentation
    func field(_ value: Data) -> Data { var size = UInt32(value.count).bigEndian; return withUnsafeBytes(of: &size) { Data($0) } + value }
    return "ssh-ed25519 " + (field(Data("ssh-ed25519".utf8)) + field(publicBytes)).base64EncodedString() + " Screenpunk-iPad"
}
private func encodeSecret(_ secret: SSHTransportCredentials) -> Data { secret.privateKey + Data(secret.appServerToken.utf8) }
private func decodeSecret(_ data: Data, allowEmpty: Bool = false) throws -> SSHTransportCredentials {
    guard data.count >= 32, let token = String(data: data.dropFirst(32), encoding: .utf8) else { throw LocalCredentialError.unavailable }
    if !allowEmpty || !token.isEmpty { try validateToken(token) }
    return SSHTransportCredentials(privateKey: Data(data.prefix(32)), appServerToken: token)
}
/// Private key and bearer token are one device-only Keychain item. Neither is Codable.
public final class KeychainLocalCredentialStore: LocalCredentialVault, @unchecked Sendable {
    private let service: String
    public init(service: String = "com.screenpunk.local-authoring") { self.service = service }
    private func query(_ reference: SSHCredentialReference) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference.rawValue]
    }
    private func read(_ reference: SSHCredentialReference) throws -> SSHTransportCredentials {
        var q = query(reference); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { throw LocalCredentialError.unavailable }
        return try decodeSecret(data, allowEmpty: true)
    }
    public func load(reference: SSHCredentialReference) throws -> SSHTransportCredentials { let value = try read(reference); try validateToken(value.appServerToken); return value }
    public func createIdentity() throws -> LocalCredentialSetup {
        let reference = SSHCredentialReference(rawValue: UUID().uuidString)
        let key = Curve25519.Signing.PrivateKey().rawRepresentation
        var q = query(reference); q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecValueData as String] = encodeSecret(.init(privateKey: key, appServerToken: ""))
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw LocalCredentialError.storageFailure }
        return LocalCredentialSetup(reference: reference, publicKeyOpenSSH: try openSSH(key))
    }
    public func create(appServerToken: String) throws -> LocalCredentialSetup {
        try validateToken(appServerToken)
        let setup = try createIdentity()
        do { try updateToken(appServerToken, reference: setup.reference); return setup }
        catch { try? forget(reference: setup.reference); throw error }
    }
    public func updateToken(_ token: String, reference: SSHCredentialReference) throws {
        try validateToken(token); let old = try read(reference)
        guard SecItemUpdate(query(reference) as CFDictionary, [kSecValueData as String: encodeSecret(.init(privateKey: old.privateKey, appServerToken: token))] as CFDictionary) == errSecSuccess else { throw LocalCredentialError.storageFailure }
    }
    /// Copy only this identity into a NEW item. Never update the working item's bearer.
    public func stagePairingCredential(appServerToken: String, identityReference: String, stagedReference: String) throws {
        try validateToken(appServerToken)
        guard identityReference != stagedReference, stagedReference.hasPrefix("pairing-") else { throw LocalCredentialError.storageFailure }
        let identity = try read(.init(rawValue: identityReference))
        let value = SSHTransportCredentials(privateKey: identity.privateKey, appServerToken: appServerToken)
        var q = query(.init(rawValue: stagedReference)); q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecValueData as String] = encodeSecret(value)
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let existing = try read(.init(rawValue: stagedReference))
            guard existing.privateKey == value.privateKey, existing.appServerToken == value.appServerToken else { throw LocalCredentialError.storageFailure }
        } else if status != errSecSuccess { throw LocalCredentialError.storageFailure }
    }
    public func hasPairingCredential(reference: String) throws -> Bool {
        var q = query(.init(rawValue: reference)); q[kSecReturnData as String] = false
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw LocalCredentialError.unavailable }
        _ = try load(reference: .init(rawValue: reference)); return true
    }
    public func forgetPairingCredential(reference: String) throws { guard reference.hasPrefix("pairing-") else { throw LocalCredentialError.storageFailure }; try forget(reference: .init(rawValue: reference)) }
    public func publicKey(reference: SSHCredentialReference) throws -> String { try openSSH(read(reference).privateKey) }
    public func forget(reference: SSHCredentialReference) throws {
        let status = SecItemDelete(query(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LocalCredentialError.storageFailure }
    }
}
/// An isolated test vault; descriptions of its credential values are redacted by the transport type.
public final class MemoryLocalCredentialStore: LocalCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SSHCredentialReference: SSHTransportCredentials] = [:]
    public init() {}
    public func createIdentity() throws -> LocalCredentialSetup {
        let ref = SSHCredentialReference(rawValue: UUID().uuidString), key = Curve25519.Signing.PrivateKey().rawRepresentation
        lock.lock(); values[ref] = .init(privateKey: key, appServerToken: ""); lock.unlock()
        return .init(reference: ref, publicKeyOpenSSH: try openSSH(key))
    }
    public func create(appServerToken: String) throws -> LocalCredentialSetup { try validateToken(appServerToken); let v = try createIdentity(); try updateToken(appServerToken, reference: v.reference); return v }
    private func read(_ reference: SSHCredentialReference) throws -> SSHTransportCredentials { lock.lock(); defer { lock.unlock() }; guard let v = values[reference] else { throw LocalCredentialError.unavailable }; return v }
    public func load(reference: SSHCredentialReference) throws -> SSHTransportCredentials { let v = try read(reference); try validateToken(v.appServerToken); return v }
    public func updateToken(_ token: String, reference: SSHCredentialReference) throws { try validateToken(token); lock.lock(); defer { lock.unlock() }; guard let v = values[reference] else { throw LocalCredentialError.unavailable }; values[reference] = .init(privateKey: v.privateKey, appServerToken: token) }
    public func stagePairingCredential(appServerToken: String, identityReference: String, stagedReference: String) throws {
        try validateToken(appServerToken)
        guard identityReference != stagedReference, stagedReference.hasPrefix("pairing-") else { throw LocalCredentialError.storageFailure }
        lock.lock(); defer { lock.unlock() }
        guard let identity = values[.init(rawValue: identityReference)] else { throw LocalCredentialError.unavailable }
        let reference = SSHCredentialReference(rawValue: stagedReference)
        if let existing = values[reference] {
            guard existing.privateKey == identity.privateKey, existing.appServerToken == appServerToken else { throw LocalCredentialError.storageFailure }; return
        }
        values[reference] = .init(privateKey: identity.privateKey, appServerToken: appServerToken)
    }
    public func hasPairingCredential(reference: String) throws -> Bool { lock.lock(); defer { lock.unlock() }; guard let value = values[.init(rawValue: reference)] else { return false }; try validateToken(value.appServerToken); return true }
    public func forgetPairingCredential(reference: String) throws { guard reference.hasPrefix("pairing-") else { throw LocalCredentialError.storageFailure }; try forget(reference: .init(rawValue: reference)) }
    public func publicKey(reference: SSHCredentialReference) throws -> String { try openSSH(read(reference).privateKey) }
    public func forget(reference: SSHCredentialReference) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: reference) }
}
