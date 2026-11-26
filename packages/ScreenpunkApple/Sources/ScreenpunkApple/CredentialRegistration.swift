import Foundation
import Security
import ScreenpunkCore

/// The device creates and retains the bearer. A source receives only its verifier.
public struct DeviceBearerCredential: Sendable {
    public let bearer: String
    public let verifier: String

    public static func generate() throws -> Self {
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw ConnectionFailure.permissionRequired
        }
        let bearer = Data(random).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return .init(bearer: bearer, verifier: verifier(for: bearer))
    }

    public static func verifier(for bearer: String) -> String {
        AuthoringContract.contentDigest(Data(bearer.utf8))
    }
}

public struct CatalogCredentialRegistrationSource: Codable, Equatable, Sendable {
    public let catalogScreenID: String
    public let versionID: String
    public let sourceRevisionID: String
    public let packageDigest: String

    public init(catalogScreenID: String, versionID: String, sourceRevisionID: String, packageDigest: String) {
        self.catalogScreenID = catalogScreenID
        self.versionID = versionID
        self.sourceRevisionID = sourceRevisionID
        self.packageDigest = packageDigest
    }
}

public struct CredentialRegistrationContext: Codable, Equatable, Sendable {
    public let requestID: String
    public let inputDigest: String
    public let operationID: String
    public let deviceID: String
    public let screenID: String
    public let alias: String
    public let serviceID: String
    public let origin: String
    public let readPath: String
    public let declarationDigest: String
    public let deadlineAt: Int64
    public let revision: String
    public let expectedGeneration: UUID?
    public let catalogSource: CatalogCredentialRegistrationSource?

    public init(requestID: String, inputDigest: String, operationID: String, deviceID: String, screenID: String, alias: String,
                serviceID: String, origin: String, readPath: String, declarationDigest: String, deadlineAt: Int64, revision: String,
                expectedGeneration: UUID?, catalogSource: CatalogCredentialRegistrationSource? = nil) {
        self.requestID = requestID; self.inputDigest = inputDigest; self.operationID = operationID
        self.deviceID = deviceID; self.screenID = screenID; self.alias = alias; self.serviceID = serviceID
        self.origin = origin; self.readPath = readPath; self.declarationDigest = declarationDigest; self.deadlineAt = deadlineAt
        self.revision = revision; self.expectedGeneration = expectedGeneration; self.catalogSource = catalogSource
    }

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

    public func isCurrent(_ now: Int64) -> Bool {
        now >= 0 && now < deadlineAt && deadlineAt - now <= 15 * 60 * 1000
    }
}

public struct PendingCredentialRegistration: Equatable, Sendable {
    public let registrationID: String
    public let context: CredentialRegistrationContext
    public let verifier: String
    public let removalRequested: Bool
}

public struct CredentialRegistrationReceipt: Decodable, Equatable, Sendable {
    public let version: Int
    public let registrationID: String
    public let screenRevision: String
    public let relayOrigin: String?
    public let requestID: String
    public let inputDigest: String
    public let operationID: String
    public let deviceID: String
    public let screenID: String
    public let alias: String
    public let serviceID: String
    public let origin: String
    public let readPath: String
    public let declarationDigest: String
    public let expiresAt: Int64

    public func matches(_ registration: PendingCredentialRegistration) -> Bool {
        let context = registration.context
        return version == 1 && registrationID == registration.registrationID && requestID == context.requestID &&
            inputDigest == context.inputDigest && operationID == context.operationID && deviceID == context.deviceID &&
            screenID == context.screenID && screenRevision == context.revision && alias == context.alias && serviceID == context.serviceID &&
            origin == context.origin && readPath == context.readPath && declarationDigest == context.declarationDigest && expiresAt > 0 && expiresAt <= context.deadlineAt
    }

    public func isCurrent(for registration: PendingCredentialRegistration, now: Int64) -> Bool {
        matches(registration) && registration.context.isCurrent(now) && now < expiresAt
    }
}

/// A never-submitted registration has no installed-source receipt. Cloud must echo its exact local binding.
public struct CredentialRegistrationRemovalAcknowledgement: Decodable, Sendable {
    let status: String
    let scope: CredentialRegistrationReceipt?
    let cancelledBeforeStart: Bool?
    let registrationID: String?
    let requestID: String?
    let deviceID: String?
    let alias: String?
    let screenRevision: String?
    let deadlineAt: Int64?

    public func confirmsRemoval(of pending: PendingCredentialRegistration, relayOrigin: String) -> Bool {
        guard status == "removed", pending.removalRequested else { return false }
        if cancelledBeforeStart == true {
            let context = pending.context
            return scope == nil && registrationID == pending.registrationID && requestID == context.requestID &&
                deviceID == context.deviceID && alias == context.alias && screenRevision == context.revision &&
                deadlineAt == context.deadlineAt
        }
        return scope?.matches(pending) == true && scope?.relayOrigin == relayOrigin
    }
}
