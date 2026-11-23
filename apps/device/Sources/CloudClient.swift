import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit
import ScreenpunkCore

struct DeviceSession: Codable {
    let accessToken: String
    let deviceId: String
    let user: User
    var profileID: String?
    struct User: Codable { let id: String; let email: String; let name: String? }
}
enum CloudSignInProvider: String { case apple, google }

enum CloudSignOutError: Error { case secureCredentialsNotCleared }
struct AgentStatus: Decodable {
    let agentReady: Bool
    let pluginConnected: Bool?
    let profileID: String?
    let authoringCapabilities: CloudAuthoringCapabilities?
    let credentialRegistrationVersion: Int?
    let latestRequest: Summary?
    let awaitingApplicationRequestIDs: [String]?
    let command: Command?
    struct Command: Decodable { let id: String; let type: String; let screenID: String?; let activationID: String?; let expiresAt: Double }
    struct Summary: Decodable { let id: String; let status: String }
}
@MainActor final class CloudClient: NSObject, ASWebAuthenticationPresentationContextProviding, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let originScope: CloudOriginScope = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "ScreenpunkAPIOrigin") as? String
        let value = configured.flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
            ?? "https://staging.screenpunk.xyz"
        guard let scope = CloudOriginScope(origin: value) else {
            preconditionFailure("ScreenpunkAPIOrigin must be an HTTPS origin")
        }
        return scope
    }()
    static var origin: URL { originScope.url }
    private var appleController: ASAuthorizationController?
    private var appleContinuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?
    private var authSession: ASWebAuthenticationSession?
    private var enrolledToken: String?
    private let deviceNameWrites = DeviceNameWriteQueue()
    var session: DeviceSession? = SessionKeychain.load()
    private static let catalogInventoryHeader = "X-Screenpunk-Catalog-Inventory"
    private var catalogInventoryCapability: (token: String, validUntil: Date, supported: Bool)?
    var sessionRevoked: (() -> Void)?
    var deviceNameChanged: ((String, String?) -> Void)?
    private(set) var deviceNameSyncNotice: String?
    private(set) var revocationPersistenceFailed = false
    /// Captured credentials fence late responses from another sign-in or account.
    @discardableResult func acceptRevocation(token: String, deviceID: String) -> Bool {
        guard let current = session, current.accessToken == token, current.deviceId == deviceID else { return false }
        // Persist before detaching the library; never delete user content here.
        var recorded = false, cleared = false
        do { try SessionKeychain.recordRevocation(current); recorded = true } catch { }
        do { try SessionKeychain.clear(); cleared = true } catch { }
        revocationPersistenceFailed = !recorded && !cleared
        session = nil; enrolledToken = nil
        sessionRevoked?()
        return true
    }
    /// Used only for local libraries, ownership, permissions and preference eligibility.
    var localAccountID: String? { session.map { Self.originScope.localAccountID(serverUserID: $0.user.id) } }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    func signIn(provider: CloudSignInProvider? = nil, confirmCreation: @escaping @MainActor (String) async -> Bool) async throws -> DeviceSession {
        // Enroll a still-valid legacy session before rotating its credentials so the
        // installation keeps the same account-scoped Cloud device identity.
        if session != nil {
            do { try await enrollInstallation() }
            catch DeviceError.http(let status, _) where status == 401 || status == 409 { }
        }
        let installationKey = try InstallationIdentity.loadOrCreate()
        let verifier = try Self.randomToken()
        let state = try Self.randomToken()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let code: String
        if provider == .apple {
            let challengeResponse: AppleChallenge = try await call(
                "auth/device/apple/challenge", method: "POST",
                body: ["codeChallenge": challenge, "codeChallengeMethod": "S256",
                       "state": state, "installationKey": installationKey], authenticated: false)
            guard challengeResponse.state == state else { throw DeviceError.message("Sign-in response could not be verified.") }
            let credential = try await authorizeApple(nonce: challengeResponse.nonce, state: state)
            guard credential.state == state,
                  let identityData = credential.identityToken, let identityToken = String(data: identityData, encoding: .utf8),
                  let codeData = credential.authorizationCode, let authorizationCode = String(data: codeData, encoding: .utf8) else {
                throw DeviceError.message("Apple sign-in did not return a verified response.")
            }
            let response: DeviceSignInCompletion = try await call(
                "auth/device/apple/complete", method: "POST",
                body: ["challengeToken": challengeResponse.challengeToken, "identityToken": identityToken,
                       "authorizationCode": authorizationCode, "codeVerifier": verifier,
                       "state": state, "installationKey": installationKey], authenticated: false)
            guard response.state == state else { throw DeviceError.message("Sign-in response could not be verified.") }
            code = try await resolveDeviceSignInCompletion(response, verifier: verifier, installationKey: installationKey, state: state, confirmCreation: confirmCreation)
        } else {
            var url = URLComponents(url: Self.origin.appendingPathComponent("auth/device/authorize"), resolvingAgainstBaseURL: false)!
            url.queryItems = [.init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state)]
            if let provider { url.queryItems?.append(.init(name: "provider", value: provider.rawValue)) }
            defer { authSession = nil }
            let callback: URL = try await withCheckedThrowingContinuation { continuation in
                let flow = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: "screenpunk-one") { callback, error in
                    if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { continuation.resume(throwing: CancellationError()) }
                    else if let error { continuation.resume(throwing: error) }
                    else if let callback { continuation.resume(returning: callback) }
                    else { continuation.resume(throwing: DeviceError.message("Sign-in did not return a response.")) }
                }
                flow.presentationContextProvider = self
                self.authSession = flow
                if !flow.start() { continuation.resume(throwing: DeviceError.message("Could not open sign-in.")) }
            }
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard callback.host == "auth", callback.path == "/callback", items.filter({ $0.name == "state" }).count == 1,
                  items.first(where: { $0.name == "state" })?.value == state else { throw DeviceError.message("Sign-in response could not be verified.") }
            if items.first(where: { $0.name == "error" })?.value == "access_denied" { throw CancellationError() }
            let codes = items.filter { $0.name == "code" }
            let confirmations = items.filter { $0.name == "confirmationToken" }
            let emails = items.filter { $0.name == "email" }
            guard codes.count <= 1, confirmations.count <= 1, emails.count <= 1,
                  (codes.count == 1) != (confirmations.count == 1) else {
                throw DeviceError.message("Sign-in response could not be verified.")
            }
            let response = DeviceSignInCompletion(code: codes.first?.value, state: state, confirmationToken: confirmations.first?.value, email: emails.first?.value)
            code = try await resolveDeviceSignInCompletion(response, verifier: verifier, installationKey: installationKey, state: state, confirmCreation: confirmCreation)
        }
        let value: DeviceSession = try await call("auth/device/token", method: "POST", body: ["code": code, "codeVerifier": verifier, "installationKey": installationKey], authenticated: false)
        let registered = try await registerSession(value)
        // Publish credentials only after enrollment succeeds. An interrupted account
        // switch must never drive the previous account's open library with a new token.
        try SessionKeychain.save(registered)
        session = registered; enrolledToken = registered.accessToken
        try publishCloudName(registered)
        return registered
    }
    private struct CancelledAccountCreation: Decodable {
        let cancelled: Bool
        let state: String
    }
    private struct AppleChallenge: Decodable {
        let challengeToken: String
        let nonce: String
        let state: String
    }
    private struct DeviceSignInCompletion: Decodable {
        let code: String?
        let state: String
        let confirmationToken: String?
        let email: String?
    }

    private func resolveDeviceSignInCompletion(_ response: DeviceSignInCompletion, verifier: String, installationKey: String, state: String,
                                               confirmCreation: @MainActor (String) async -> Bool) async throws -> String {
        guard response.state == state else { throw DeviceError.message("Sign-in response could not be verified.") }
        if let code = response.code, !code.isEmpty, response.confirmationToken == nil { return code }
        guard response.code == nil, let token = response.confirmationToken, !token.isEmpty,
              let email = response.email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeviceError.message("Sign-in did not provide a verified account email. Try signing in again.")
        }
        let create = await confirmCreation(email)
        if !create {
            let _: CancelledAccountCreation? = try? await call("auth/device/account/confirm", method: "POST", body: ["confirmationToken": token, "codeVerifier": verifier, "installationKey": installationKey, "state": state, "action": "cancel"], authenticated: false)
            throw CancellationError()
        }
        let result: DeviceSignInCompletion = try await call("auth/device/account/confirm", method: "POST", body: ["confirmationToken": token, "codeVerifier": verifier, "installationKey": installationKey, "state": state, "action": "create"], authenticated: false)
        guard result.state == state, result.confirmationToken == nil, let code = result.code, !code.isEmpty else { throw DeviceError.message("Account creation could not be verified. Try signing in again.") }
        return code
    }

    private func authorizeApple(nonce: String, state: String) async throws -> ASAuthorizationAppleIDCredential {
        defer { appleController = nil; appleContinuation = nil }
        return try await withCheckedThrowingContinuation { continuation in
            appleContinuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.email, .fullName]
            request.nonce = nonce
            request.state = state
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            appleController = controller
            controller.performRequests()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let continuation = appleContinuation else { return }
        appleContinuation = nil
        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential { continuation.resume(returning: credential) }
        else { continuation.resume(throwing: DeviceError.message("Apple sign-in returned an unsupported response.")) }
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard let continuation = appleContinuation else { return }
        appleContinuation = nil
        if (error as? ASAuthorizationError)?.code == .canceled { continuation.resume(throwing: CancellationError()) }
        else { continuation.resume(throwing: error) }
    }

    func enrollInstallation() async throws {
        guard let value = session else { throw DeviceError.message("Sign in to Screenpunk to continue.") }
        guard enrolledToken != value.accessToken else { return }
        let registered = try await registerSession(value)
        guard session?.accessToken == value.accessToken else { throw CancellationError() }
        try SessionKeychain.save(registered); session = registered; enrolledToken = value.accessToken
    }
    static var installationDeviceNameKey: String? { (try? LocalProfileRepository().snapshot().installationID).map { "installation|" + $0 } }
    private func registerSession(_ value: DeviceSession) async throws -> DeviceSession {
        try await deviceNameWrites.perform { [self] in try await performRegisterSession(value) }
    }
    private func performRegisterSession(_ value: DeviceSession) async throws -> DeviceSession {
        let key = try InstallationIdentity.loadOrCreate()
        let fallback = (try? DeviceNameStore.normalized(UIDevice.current.name)) ?? "Screenpunk"
        let desiredName = DeviceNameStore().name(for: Self.installationDeviceNameKey ?? "unavailable", fallback: fallback)
        let registration: DeviceRegistration
        do { registration = try await call("api/device/register", method: "POST", body: ["name": desiredName, "installationKey": key], authorizationToken: value.accessToken) }
        catch DeviceError.http(let status, _) where status == 409 {
            throw DeviceError.http(409, "This device has an earlier saved connection. Sign in again from Settings to restore it.")
        }
        guard registration.id == value.deviceId else { throw DeviceError.message("Your device connection changed. Sign in again to continue.") }
        if let snapshot = registration.nameSnapshot {
            try CloudDeviceNameRepository().observe(snapshot, key: Self.cloudNameKey(value))
            if session?.accessToken == value.accessToken { try publishCloudName(value) }
        }
        var next = value; next.profileID = registration.profileID
        return next
    }
    private static func cloudNameKey(_ session: DeviceSession) -> String {
        CloudDeviceNameRepository.key(origin: originScope.canonicalOrigin, accountID: session.user.id, deviceID: session.deviceId)
    }
    func queueDeviceName(_ name: String) throws {
        guard let session else { return }
        try CloudDeviceNameRepository().queue(name: name, key: Self.cloudNameKey(session))
        deviceNameSyncNotice = nil
    }
    private func publishCloudName(_ captured: DeviceSession) throws {
        guard session?.accessToken == captured.accessToken, session?.deviceId == captured.deviceId else { return }
        let state = try CloudDeviceNameRepository().record(key: Self.cloudNameKey(captured))
        guard let name = state.pending?.name ?? state.canonical?.name else { return }
        if let key = Self.installationDeviceNameKey { _ = try DeviceNameStore().save(name, for: key) }
        deviceNameSyncNotice = state.conflict ? "The device name changed in Cloud. The latest Cloud name has been kept." : nil
        deviceNameChanged?(name, deviceNameSyncNotice)
    }
    func observeDeviceName(_ snapshot: CloudDeviceNameSnapshot, token: String) throws -> Bool {
        guard let captured = session, captured.accessToken == token,
              snapshot.valid, snapshot.deviceId == captured.deviceId else { return false }
        let repository = try CloudDeviceNameRepository(), key = Self.cloudNameKey(captured)
        guard try repository.record(key: key).canonical?.enrollmentRevision == snapshot.enrollmentRevision else { return false }
        try repository.observe(snapshot, key: key)
        try publishCloudName(captured)
        return true
    }
    /// Only explicit edits use the revisioned mutation endpoint. Registration's
    /// legacy name field is a seed and never a reconnect rename operation.
    func syncDeviceName() async throws {
        guard let captured = session else { return }
        try await deviceNameWrites.perform { [self] in
            guard session?.accessToken == captured.accessToken else { throw CancellationError() }
            let repository = try CloudDeviceNameRepository(), key = Self.cloudNameKey(captured)
            for _ in 0..<4 {
                guard let edit = try repository.record(key: key).pending else { try publishCloudName(captured); return }
                var conflict = false
                let snapshot: CloudDeviceNameSnapshot
                do {
                    snapshot = try await call("api/device/name", method: "POST", body: ["name": edit.name, "expectedNameRevision": edit.expectedNameRevision, "operationID": edit.operationID] as [String: Any], authorizationToken: captured.accessToken)
                } catch DeviceError.deviceNameConflict(let canonical) { snapshot = canonical; conflict = true }
                guard session?.accessToken == captured.accessToken, session?.deviceId == captured.deviceId else { throw CancellationError() }
                guard snapshot.valid, snapshot.deviceId == captured.deviceId else { throw DeviceError.message("Cloud returned a different device name identity.") }
                guard conflict || snapshot.name == edit.name else { throw DeviceError.message("Cloud did not confirm the requested device name.") }
                try repository.complete(edit, snapshot: snapshot, conflict: conflict, key: key)
                try publishCloudName(captured)
            }
            if try repository.record(key: key).pending != nil { throw DeviceError.message("The latest device name is saved on this iPad and will retry.") }
        }
    }
    func rememberProfile(_ profileID: String) throws {
        guard var value = session, value.profileID != profileID else { return }
        value.profileID = profileID; try SessionKeychain.save(value); session = value
    }
    func call<T: Decodable>(_ path: String, method: String = "GET", body: Any? = nil, authenticated: Bool = true, authorizationToken: String? = nil, authoringVersion: Int = 1, idempotencyKey: String? = nil, timelineRequestID: String? = nil, screenDataProtocol: Bool = false, requiredStatus: Int? = nil) async throws -> T {
#if DEBUG
        let timeline: (start: RequestTimeline.Event, end: RequestTimeline.Event, id: String?, operation: RequestTimeline.Operation)?
        if path == "api/device/status" && method == "GET" {
            timeline = (.httpStatusStart, .httpStatusEnd, nil, .status)
        } else if path == "api/device/requests", method == "POST", let timelineRequestID {
            timeline = (.submitStart, .submitEnd, timelineRequestID, .submit)
        } else {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 4, parts.prefix(3).elementsEqual(["api", "device", "requests"]), method == "GET" {
                timeline = (.reconcileStart, .reconcileEnd, String(parts[3]), .reconcile)
            } else if parts.count == 5, parts.prefix(3).elementsEqual(["api", "device", "requests"]),
                      parts[4] == "application-receipt", method == "POST" {
                timeline = (.acknowledgementStart, .acknowledgementEnd, String(parts[3]), .acknowledgement)
            } else {
                timeline = nil
            }
        }
        var timelineHTTPStatus: Int?
        if let timeline { RequestTimeline.record(timeline.start, requestID: timeline.id) }
        defer {
            if let timeline { RequestTimeline.record(timeline.end, requestID: timeline.id, httpStatus: timelineHTTPStatus) }
        }
#endif
        var request = URLRequest(url: Self.origin.appendingPathComponent(path))
        let capturedSession = session
        let requestToken = authorizationToken ?? (authenticated ? capturedSession?.accessToken : nil)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue(String(authoringVersion), forHTTPHeaderField: "X-Screenpunk-Authoring-Version")
        if screenDataProtocol { request.setValue("1", forHTTPHeaderField: "X-Screenpunk-Screen-Data-Protocol") }
        if authenticated {
            guard let token = authorizationToken ?? session?.accessToken else { throw DeviceError.message("Sign in to Screenpunk to continue.") }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let body {
            let bytes = try JSONSerialization.data(withJSONObject: body)
            guard bytes.count <= (screenDataProtocol && path == "api/device/screens" ? 2 * 1024 * 1024 : 768 * 1024) else { throw DeviceError.message("Request exceeded the device limit.") }
            request.httpBody = bytes
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let transport = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { transport.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do {
#if DEBUG
            if let timeline { RequestTimeline.record(.httpTransportStart, requestID: timeline.id, operation: timeline.operation) }
            defer {
                if let timeline {
                    RequestTimeline.record(.httpTransportEnd, requestID: timeline.id, httpStatus: timelineHTTPStatus,
                                           operation: timeline.operation)
                }
            }
#endif
            (data, response) = try await transport.data(for: request)
#if DEBUG
            timelineHTTPStatus = (response as? HTTPURLResponse)?.statusCode
#endif
        }
        guard data.count <= 768 * 1024 else { throw DeviceError.message("Cloud response exceeded the device limit.") }
        guard let http = response as? HTTPURLResponse else { throw DeviceError.message("Cloud did not respond.") }
        if ["api/device/account/delete", "auth/account/delete/retry"].contains(path),
           let fields = body as? [String: String], let operationID = fields["operationID"] {
            try DeviceAccountDeletionTransaction.validateHTTPResponse(data, status: http.statusCode, operationID: operationID)
        }
        if let capturedSession, requestToken == capturedSession.accessToken,
           CloudDeviceRevocationEvidence.matches(status: http.statusCode, data: data, deviceID: capturedSession.deviceId) {
            guard acceptRevocation(token: capturedSession.accessToken, deviceID: capturedSession.deviceId) else { throw CancellationError() }
            throw DeviceError.deviceRevoked
        }
        if http.statusCode == 401 { throw DeviceError.http(401, "Your connection has expired. Sign in again from Settings.") }
        if http.statusCode == 409, path == "api/device/name",
           let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any], fields["error"] as? String == "device_name_conflict",
           let snapshot = try? JSONDecoder().decode(CloudDeviceNameSnapshot.self, from: data), snapshot.valid {
            throw DeviceError.deviceNameConflict(snapshot)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DeviceError.http(http.statusCode, "Screenpunk could not complete this request (\(http.statusCode)). Try again shortly.")
        }
        if let requiredStatus, http.statusCode != requiredStatus {
            throw DeviceError.http(http.statusCode, "The server has not confirmed completion. Try again shortly.")
        }
        if path.hasPrefix("api/device/requests") || path == "api/device/preferences/sync" {
            try DeviceAuthoringWire.validateResponse(data.isEmpty ? Data("{}".utf8) : data)
        }
        let decoded = try JSONDecoder().decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
        if path == "api/device/status", let capturedSession, requestToken == capturedSession.accessToken,
           session?.accessToken == capturedSession.accessToken,
           let snapshot = try? JSONDecoder().decode(CloudDeviceNameSnapshot.self, from: data), snapshot.valid, snapshot.deviceId == capturedSession.deviceId {
            try CloudDeviceNameRepository().observe(snapshot, key: Self.cloudNameKey(capturedSession))
            try publishCloudName(capturedSession)
        }
        return decoded
    }

    func queryScreenData(readerID: String, revision: String, generation: String, alias: String, socketID: String, token: String) async throws -> ScreenDataSnapshot {
        let bytes = try JSONEncoder().encode([
            "readerScreenId": readerID, "readerRevision": revision, "readerGeneration": generation,
            "alias": alias, "screenDataSocketId": socketID
        ])
        let (status, data) = try await screenDataRequest("api/device/screen-data/query", bytes: bytes, token: token)
        guard status == 200 else { throw ScreenDataError.unavailable }
        let reply = try JSONDecoder().decode(DeviceScreenDataWire.Reply.self, from: data)
        return try reply.snapshot()
    }

    func replyToScreenDataQuery(id: String, reply: DeviceScreenDataWire.Reply, token: String) async throws -> Bool {
        guard UUID(uuidString: id) != nil else { throw ScreenDataError.invalidRequest }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let (status, _) = try await screenDataRequest("api/device/screen-data/queries/\(id)/reply", bytes: encoder.encode(reply), token: token)
        return status == 204
    }

    private func screenDataRequest(_ path: String, bytes: Data, token: String) async throws -> (Int, Data) {
        guard bytes.count <= DeviceScreenDataWire.replyLimit else { throw ScreenDataError.invalidRequest }
        var request = URLRequest(url: Self.origin.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = bytes
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 12
        let transport = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { transport.invalidateAndCancel() }
        do {
            let (stream, response) = try await transport.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  response.expectedContentLength <= DeviceScreenDataWire.replyLimit else { throw ScreenDataError.unavailable }
            var data = Data()
            for try await byte in stream {
                guard data.count < DeviceScreenDataWire.replyLimit else { throw ScreenDataError.unavailable }
                data.append(byte)
            }
            return (http.statusCode, data)
        } catch let error as URLError where error.code == .timedOut {
            throw ScreenDataError.timeout
        }
    }

    struct CatalogHTTPError: LocalizedError {
        var status: Int
        var code: String
        var retryAfterSeconds: Int?
        var errorDescription: String? { "Cloud backups are paused (\(code))." }
    }
    private struct CatalogErrorEnvelope: Decodable { var error: CatalogError }
    func catalogRequest<T: Decodable>(_ path: String, method: String = "GET", bytes: Data? = nil, token: String, package: Bool = false, image: Bool = false) async throws -> T {
        let data = try await catalogBytes(path, method: method, bytes: bytes, token: token, requestLimit: image ? CatalogContract.previewBytes : package ? CatalogContract.packageBytes : 64 * 1024, responseLimit: path.hasPrefix("/api/catalog/device-screens") ? 2 * 1024 * 1024 : 64 * 1024, contentType: image ? "image/png" : "application/json")
        return try JSONDecoder().decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }
    func catalogPackage(_ path: String, token: String, declaration: CatalogObjectDeclaration) async throws -> CatalogPackage {
        let bytes = try await catalogBytes(path, method: "GET", bytes: nil, token: token, requestLimit: 0, responseLimit: CatalogContract.packageBytes, contentType: "application/json")
        return try CatalogContract.verifyPackage(bytes, declaration: declaration)
    }
    struct CatalogAssetProgress: Decodable {
        struct MissingFile: Decodable {
            var digest: String
            var offset: Int
        }
        let status: CatalogBackupStatus
        let missingFiles: [MissingFile]

        init(from decoder: Decoder) throws {
            status = try CatalogBackupStatus(from: decoder)
            missingFiles = try decoder.container(keyedBy: CodingKeys.self).decode([MissingFile].self, forKey: .missingFiles)
        }
        private enum CodingKeys: CodingKey { case missingFiles }
    }

    private static let linkedCatalogPath = "/api/catalog/linked-installs"
    nonisolated static func validCatalogIdentifier(_ value: String) -> Bool {
        CatalogLinkedInstall.validIdentifier(value)
    }

    func registerCatalogLink(_ link: CatalogLinkedInstallRequest, token: String) async throws -> CatalogLinkedInstall {
        guard [link.catalogScreenID, link.versionID, link.sourceRevisionID, link.libraryID, link.localScreenID, link.localRevisionID]
            .allSatisfy(Self.validCatalogIdentifier) else {
            throw DeviceError.message("The linked screen reference is invalid.")
        }
        let reply: CatalogLinkedInstall = try await catalogRequest(Self.linkedCatalogPath, method: "POST",
            bytes: CatalogContract.canonical(link), token: token)
        try reply.validate()
        guard reply.matches(link) else {
            throw DeviceError.message("Cloud returned a different linked screen.")
        }
        return reply
    }

    func catalogLinkUpdates(cursor: String?, token: String) async throws -> CatalogLinkedUpdates {
        var path = URLComponents()
        path.path = Self.linkedCatalogPath + "/updates"
        if let cursor { path.queryItems = [.init(name: "cursor", value: cursor)] }
        let data = try await catalogBytes(path.string!, method: "GET", bytes: nil, token: token,
                                          requestLimit: 0, responseLimit: 2 * 1024 * 1024, contentType: "application/json")
        let page = try JSONDecoder().decode(CatalogLinkedUpdates.self, from: data)
        guard page.schemaVersion == 1, page.subscriptions.count <= 100,
              page.nextCursor.map({ (1...1024).contains($0.utf8.count) }) != false else {
            throw DeviceError.message("Cloud returned an invalid linked screen page.")
        }
        for entry in page.subscriptions { try entry.validate() }
        return page
    }

    func deleteCatalogLink(catalogScreenID: String, copyID: String, token: String) async throws {
        struct Receipt: Decodable { var schemaVersion: Int; var catalogScreenID: String; var deleted: Bool }
        guard [catalogScreenID, copyID].allSatisfy(Self.validCatalogIdentifier) else {
            throw DeviceError.message("The linked screen reference is invalid.")
        }
        let path = Self.linkedCatalogPath + "/" + catalogScreenID + "?copyID=" + copyID
        let reply: Receipt = try await catalogRequest(path, method: "DELETE", token: token)
        guard reply.schemaVersion == 1, reply.catalogScreenID == catalogScreenID, reply.deleted else {
            throw DeviceError.message("Cloud did not confirm removal of the linked screen.")
        }
    }

    static let assetBackupsPath = "/api/catalog/asset-backups"
    static let assetOperationsPath = assetBackupsPath + "/operations/"
    static let assetUploadsPath = assetBackupsPath + "/uploads/"

    func catalogAssetProgress(_ path: String, method: String = "GET", bytes: Data? = nil, token: String, chunk: Bool = false) async throws -> CatalogAssetProgress {
        let data = try await catalogBytes(path, method: method, bytes: bytes, token: token,
                                          requestLimit: chunk ? CatalogContract.assetChunkBytes : CatalogContract.assetManifestBytes + 16 * 1024,
                                          responseLimit: CatalogContract.assetManifestBytes,
                                          contentType: chunk ? "application/octet-stream" : "application/json")
        return try JSONDecoder().decode(CatalogAssetProgress.self, from: data)
    }

    func catalogVersionManifest(_ path: URLComponents, token: String, declaration: CatalogObjectDeclaration) async throws -> CatalogAssetManifest {
        var request = path
        request.path += "/manifest"
        let bytes = try await catalogBytes(request.string!, method: "GET", bytes: nil, token: token, requestLimit: 0,
                                           responseLimit: CatalogContract.assetManifestBytes, contentType: "application/json")
        let manifest = try JSONDecoder().decode(CatalogAssetManifest.self, from: bytes)
        guard try CatalogContract.validateAssetManifest(manifest) == declaration.byteLength,
              CatalogContract.digest(try CatalogContract.canonical(manifest)) == declaration.digest else {
            throw DeviceError.message("The restored catalog manifest did not match the saved version.")
        }
        return manifest
    }

    func catalogRestoreAssets(_ path: URLComponents, manifest: CatalogAssetManifest, directory: URL, token: String, current: () throws -> Void) async throws {
        var downloaded: [String: URL] = [:]
        for file in manifest.files {
            try current()
            let destination = directory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let identical = downloaded[file.digest], !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: identical, to: destination)
            } else {
                try await catalogRestoreAsset(path, file: file, destination: destination, token: token, current: current)
                downloaded[file.digest] = destination
            }
        }
    }

    private func catalogRestoreAsset(_ path: URLComponents, file: CatalogAssetFile, destination: URL, token: String, current: () throws -> Void) async throws {
        try await CatalogAssetDownload.restore(file: file, destination: destination, current: current) { offset, length in
            var request = path
            request.path += "/assets/" + file.digest
            request.queryItems = (path.queryItems ?? []) + [.init(name: "offset", value: String(offset))]
            return try await self.catalogRestoreChunk(request.string!, token: token, length: length, current: current)
        }
    }

    private func catalogRestoreChunk(_ path: String, token: String, length: Int, current: () throws -> Void) async throws -> Data {
        for attempt in 0..<3 {
            try current()
            do {
                return try await catalogBytes(path, method: "GET", bytes: nil, token: token, requestLimit: 0,
                                              responseLimit: length, contentType: "application/octet-stream")
            } catch let error as CatalogHTTPError where attempt < 2 && [429, 500, 502, 503, 504].contains(error.status) {
                try await Task.sleep(for: .seconds(max(attempt + 1, min(error.retryAfterSeconds ?? 0, 30))))
            } catch is URLError where attempt < 2 && !Task.isCancelled {
                try await Task.sleep(for: .seconds(attempt + 1))
            }
        }
        throw DeviceError.message("The catalog asset could not be downloaded.")
    }

    private func catalogBytes(_ path: String, method: String, bytes: Data?, token: String, requestLimit: Int, responseLimit: Int,
                              contentType: String, timeout: TimeInterval = 60, onResponse: ((HTTPURLResponse) -> Void)? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard path.hasPrefix("/api/catalog"), let relative = URLComponents(string: path), relative.scheme == nil, relative.host == nil, relative.fragment == nil,
              bytes?.count ?? 0 <= requestLimit, var target = URLComponents(url: Self.origin, resolvingAgainstBaseURL: false) else { throw DeviceError.message("Backup request exceeded its limit.") }
        target.path = relative.path; target.queryItems = relative.queryItems
        guard let url = target.url else { throw DeviceError.message("Invalid backup route.") }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.timeoutInterval = timeout; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(CatalogContract.version, forHTTPHeaderField: "X-Screenpunk-Catalog-Version")
        request.setValue(CatalogContract.assetBackupVersion, forHTTPHeaderField: "X-Screenpunk-Catalog-Assets")
        request.setValue("1", forHTTPHeaderField: "X-Screenpunk-Catalog-Links")
        if path == CatalogContract.capabilitiesPath { request.setValue("1", forHTTPHeaderField: Self.catalogInventoryHeader) }
        if let bytes { request.httpBody = bytes; request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let transport = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { transport.invalidateAndCancel() }
        let (stream, response) = try await transport.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeviceError.message("Cloud backups did not respond.") }
        let limit = (200..<300).contains(http.statusCode) ? responseLimit : 64 * 1024
        guard response.expectedContentLength <= limit else { throw DeviceError.message("Backup response exceeded its limit.") }
        var data = Data()
        for try await byte in stream { guard data.count < limit else { throw DeviceError.message("Backup response exceeded its limit.") }; data.append(byte) }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(CatalogError.self, from: data)) ?? (try? JSONDecoder().decode(CatalogErrorEnvelope.self, from: data).error)
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) ?? detail?.retryAfterSeconds
            throw CatalogHTTPError(status: http.statusCode, code: detail?.code ?? (http.statusCode == 401 ? "unauthorized" : "retry_later"), retryAfterSeconds: retry)
        }
        onResponse?(http)
        return data
    }

    func catalogInventorySupported(token: String) async -> Bool {
        if let cached = catalogInventoryCapability, cached.token == token, cached.validUntil > Date() { return cached.supported }
        _ = try? await catalogCapability(token: token, timeout: 3)
        return catalogInventoryCapability.map { $0.token == token && $0.validUntil > Date() && $0.supported } ?? false
    }

    func catalogCapability(token: String, timeout: TimeInterval = 60) async throws -> CatalogCapability? {
        do {
            var inventoryOptIn = false
            let bytes = try await catalogBytes(CatalogContract.capabilitiesPath, method: "GET", bytes: nil, token: token,
                                               requestLimit: 0, responseLimit: 64 * 1024, contentType: "application/json", timeout: timeout) {
                inventoryOptIn = $0.value(forHTTPHeaderField: Self.catalogInventoryHeader) == "1"
            }
            let capability = try JSONDecoder().decode(CatalogCapability.self, from: bytes)
            let understood = capability.version == CatalogContract.version && capability.feature == CatalogContract.feature
            recordCatalogInventoryCapability(understood && inventoryOptIn, token: token)
            return understood ? capability : nil
        } catch let error as CatalogHTTPError where error.status == 404 || error.status == 405 {
            recordCatalogInventoryCapability(false, token: token)
            return nil
        }
    }

    private func recordCatalogInventoryCapability(_ supported: Bool, token: String) {
        guard session?.accessToken == token else { return }
        catalogInventoryCapability = (token, Date().addingTimeInterval(supported ? 300 : 60), supported)
    }
    func pendingAccountDeletion() throws -> DeviceAccountDeletionIntent? {
        guard let data = try CloudKeychainVault().read(service: Self.originScope.keychainService, account: "account-deletion") else { return nil }
        let intent = try JSONDecoder().decode(DeviceAccountDeletionIntent.self, from: data)
        guard intent.origin == Self.origin.absoluteString else { throw DeviceError.message("Account deletion belongs to a different server.") }
        return intent
    }

    func saveAccountDeletion(_ intent: DeviceAccountDeletionIntent) throws {
        guard intent.origin == Self.origin.absoluteString else { throw DeviceError.message("Account deletion belongs to a different server.") }
        try CloudKeychainVault().write(JSONEncoder().encode(intent), service: Self.originScope.keychainService, account: "account-deletion")
    }

    func requestAccountDeletion(_ captured: DeviceAccountDeletionIntent) async throws -> DeviceAccountDeletionIntent {
        guard captured.origin == Self.origin.absoluteString else { throw DeviceError.message("Account deletion belongs to a different server.") }
        return try await DeviceAccountDeletionTransaction.perform(captured, prepare: {
            guard self.localAccountID == captured.accountID, self.session?.user.id == captured.serverAccountID else {
                throw DeviceError.message("Sign in to this account to prepare deletion.")
            }
            return try await self.call("api/device/account/delete/prepare", method: "POST", body: ["operationID": captured.operationID], requiredStatus: 200)
        }, execute: { intent, retrying in
            guard let token = intent.deletionToken else { throw DeviceError.message("Account deletion could not be prepared.") }
            var body = ["operationID": intent.operationID, "deletionToken": token, "confirmation": "DELETE",
                        "appleRevocationConsent": intent.appleRevocationConsent ?? ""]
            if let consent = intent.externalCredentialCleanupConsent { body["externalCredentialCleanupConsent"] = consent }
            return try await self.call(
                retrying ? "auth/account/delete/retry" : "api/device/account/delete", method: "POST",
                body: body, authenticated: !retrying, requiredStatus: 200)
        }, persist: saveAccountDeletion)
    }

    func clearDeletedAccountSession(accountID: String) throws {
        guard localAccountID == nil || localAccountID == accountID else { throw DeviceError.message("A different account is signed in.") }
        try SessionKeychain.clear()
        session = nil
        enrolledToken = nil
    }

    func finishAccountDeletion() throws {
        try CloudKeychainVault().delete(service: Self.originScope.keychainService, account: "account-deletion")
    }

    func signOut() async throws {
        defer { session = nil; enrolledToken = nil }
        var revocationError: Error?
        do { let _: EmptyResponse = try await call("api/device/session", method: "DELETE") }
        catch { revocationError = error }
        do { try SessionKeychain.clear() }
        catch { throw CloudSignOutError.secureCredentialsNotCleared }
        if let revocationError { throw revocationError }
    }
    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DeviceError.message("Could not create secure sign-in request.") }
        return Data(bytes).base64URL
    }
}
struct EmptyResponse: Decodable {}
private struct DeviceRegistration: Decodable {
    let id: String; let profileID: String; let name: String?; let nameRevision: Int?; let enrollmentRevision: Int?
    enum CodingKeys: String, CodingKey { case id, deviceId, profileID, name, nameRevision, enrollmentRevision }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacyID = try c.decodeIfPresent(String.self, forKey: .id)
        let canonicalID = try c.decodeIfPresent(String.self, forKey: .deviceId)
        guard legacyID == nil || canonicalID == nil || legacyID == canonicalID else {
            throw DecodingError.dataCorruptedError(forKey: .deviceId, in: c, debugDescription: "Registration device identities differ.")
        }
        id = try legacyID ?? c.decode(String.self, forKey: .deviceId)
        profileID = try c.decode(String.self, forKey: .profileID)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        nameRevision = try c.decodeIfPresent(Int.self, forKey: .nameRevision)
        enrollmentRevision = try c.decodeIfPresent(Int.self, forKey: .enrollmentRevision)
        if nameRevision != nil || enrollmentRevision != nil {
            guard nameSnapshot != nil else { throw DecodingError.dataCorruptedError(forKey: .nameRevision, in: c, debugDescription: "Invalid canonical device name metadata.") }
        }
    }
    var nameSnapshot: CloudDeviceNameSnapshot? {
        guard let name, let nameRevision, let enrollmentRevision else { return nil }
        let snapshot = CloudDeviceNameSnapshot(deviceId: id, name: name, nameRevision: nameRevision, enrollmentRevision: enrollmentRevision)
        return snapshot.valid ? snapshot : nil
    }
}

struct PreferenceSyncResponse: Decodable {
    struct Accepted: Decodable { let id: String; let revision: Int }
    struct Conflict: Decodable { let id: String; let current: PreferenceRecordV1? }
    let operationID: String
    let records: [PreferenceRecordV1]
    let accepted: [Accepted]
    let conflicts: [Conflict]
    func acceptedMap() throws -> [String: Int] {
        guard accepted.count <= 128, Set(accepted.map(\.id)).count == accepted.count else { throw DeviceError.message("Cloud returned invalid preference acknowledgements.") }
        return Dictionary(uniqueKeysWithValues: accepted.map { ($0.id, $0.revision) })
    }
    func conflictMap() throws -> [String: PreferenceRecordV1?] {
        guard conflicts.count <= 128, Set(conflicts.map(\.id)).count == conflicts.count else { throw DeviceError.message("Cloud returned invalid preference conflicts.") }
        return Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, $0.current) })
    }
}

/// Converts only typed, validated authoring values to the existing bounded HTTP client.
@MainActor final class CloudAuthoringTransport: AuthoringTransport {
    private let cloud: CloudClient
    init(cloud: CloudClient) { self.cloud = cloud }
    func readiness() async throws -> Bool {
        let status: AgentStatus = try await cloud.call("api/device/status")
        return status.agentReady
    }
    func submit(_ request: AuthoringRequestV1) async throws -> AuthoringRequestV1 {
        let snapshot = try AuthoringContract.validateRequest(JSONEncoder().encode(request))
        let response: AgentRequest = try await cloud.call("api/device/requests", method: "POST", body: [
            "text": snapshot.context.userRequest, "idempotencyKey": snapshot.requestID,
            "snapshot": try Self.object(snapshot)
        ], timelineRequestID: snapshot.requestID)
        guard response.id == request.requestID, let accepted = response.snapshot else {
            throw DeviceError.message("Cloud did not confirm the authoring snapshot. Your screen is unchanged.")
        }
        RequestTimeline.record(.submitAccepted, requestID: request.requestID)
        return accepted
    }
    func progress(requestID: String) async throws -> AuthoringProgress {
        let response: AgentRequest = try await cloud.call("api/device/requests/\(requestID)")
        return Self.progress(response)
    }
    func reconcile(requestID: String) async throws -> AuthoringDeliveryState {
        let response: AgentRequest = try await cloud.call("api/device/requests/\(requestID)")
        return try response.deliveryState(requestID: requestID)
    }
    func cancel(requestID: String) async throws {
        do { let _: AgentRequest = try await cloud.call("api/device/requests/\(requestID)/cancel", method: "POST") }
        catch DeviceError.http(let status, _) where status == 409 { }
    }
    func acknowledge(_ receipt: ApplicationReceiptV1) async throws {
        let _: EmptyResponse = try await cloud.call("api/device/requests/\(receipt.requestID)/application-receipt", method: "POST", body: Self.object(receipt))
    }
    private static func progress(_ response: AgentRequest) -> AuthoringProgress {
        AuthoringProgress(status: response.status, caption: response.progress?.caption, updatedAt: response.progress?.updatedAt ?? response.createdAt, deadlineAt: response.deadlineAt)
    }
    static func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
}
/// V2 uses logical asset mutations throughout delivery; only native application resolves bytes.
@MainActor final class CloudAuthoringTransportV2: AuthoringTransportV2 {
    private let cloud: CloudClient
    private let credentialRegistrationRevision: (ApplicationReceiptV1) -> String?
    init(cloud: CloudClient, credentialRegistrationRevision: @escaping (ApplicationReceiptV1) -> String? = { _ in nil }) {
        self.cloud = cloud
        self.credentialRegistrationRevision = credentialRegistrationRevision
    }
    func capabilities() async throws -> CloudAuthoringCapabilities {
        let status: AgentStatus = try await cloud.call("api/device/status", authoringVersion: 2)
        return status.authoringCapabilities ?? .unavailable
    }
    func readiness() async throws -> Bool {
        let status: AgentStatus = try await cloud.call("api/device/status", authoringVersion: 2)
        return status.agentReady && status.authoringCapabilities?.supportsV2 == true
    }
    func submit(_ request: AuthoringRequestV2) async throws -> AuthoringRequestV2 {
        let snapshot = try AuthoringV2Contract.validateRequest(JSONEncoder().encode(request))
        let response: AgentRequestV2 = try await cloud.call("api/device/requests", method: "POST", body: [
            "text": snapshot.context.userRequest, "idempotencyKey": snapshot.requestID,
            "snapshot": try CloudAuthoringTransport.object(snapshot)
        ], authoringVersion: 2, timelineRequestID: snapshot.requestID)
        guard response.id == request.requestID, let accepted = response.snapshot,
              accepted == snapshot else {
            throw DeviceError.message("Cloud did not confirm the authoring snapshot. Your screen is unchanged.")
        }
        RequestTimeline.record(.submitAccepted, requestID: request.requestID)
        return accepted
    }
    func progress(requestID: String) async throws -> AuthoringProgress {
        let response: AgentRequestV2 = try await cloud.call("api/device/requests/\(requestID)", authoringVersion: 2)
        return Self.progress(response)
    }
    func reconcile(requestID: String) async throws -> AuthoringDeliveryStateV2 {
        let response: AgentRequestV2 = try await cloud.call("api/device/requests/\(requestID)", authoringVersion: 2)
        return try response.deliveryState(requestID: requestID)
    }
    func cancel(requestID: String) async throws {
        do { let _: AgentRequestV2 = try await cloud.call("api/device/requests/\(requestID)/cancel", method: "POST", authoringVersion: 2) }
        catch DeviceError.http(let status, _) where status == 409 { }
    }
    func acknowledge(_ receipt: ApplicationReceiptV1) async throws {
        guard var body = try CloudAuthoringTransport.object(receipt) as? [String: Any] else { throw ConnectionFailure.validationFailed }
        if let revision = credentialRegistrationRevision(receipt) { body["credentialRegistrationScreenRevision"] = revision }
        let _: EmptyResponse = try await cloud.call("api/device/requests/\(receipt.requestID)/application-receipt", method: "POST", body: body, authoringVersion: 2)
    }
    private static func progress(_ response: AgentRequestV2) -> AuthoringProgress {
        AuthoringProgress(status: response.status, caption: response.progress?.caption, updatedAt: response.progress?.updatedAt ?? response.createdAt, deadlineAt: response.deadlineAt)
    }
}

private extension Data { var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") } }
@MainActor private enum SessionKeychain {
    private static var credentials: OriginScopedCloudCredentials { .init(scope: CloudClient.originScope) }
    static func load() -> DeviceSession? {
        guard let data = try? credentials.load(account: "session", vault: CloudKeychainVault()) else { return nil }
        guard let session = try? JSONDecoder().decode(DeviceSession.self, from: data),
              let revoked = try? CloudSessionRevocationLedger().contains(origin: CloudClient.origin.absoluteString, credential: session.accessToken),
              !revoked else { return nil }
        return session
    }
    static func recordRevocation(_ session: DeviceSession) throws {
        try CloudSessionRevocationLedger().record(origin: CloudClient.origin.absoluteString, credential: session.accessToken)
    }
    static func save(_ session: DeviceSession) throws {
        try credentials.save(JSONEncoder().encode(session), account: "session", vault: CloudKeychainVault())
    }
    static func clear() throws { try credentials.clear(account: "session", vault: CloudKeychainVault()) }
}

/// Installation secret is scoped independently of sign-in credentials and survives sign-out.
/// Only canonical staging can adopt the public app's earlier fixed installation identity.
@MainActor private enum InstallationIdentity {
    static func loadOrCreate() throws -> String {
        let credentials = OriginScopedCloudCredentials(scope: CloudClient.originScope)
        let vault = CloudKeychainVault()
        if let data = try credentials.load(account: "installation-key", vault: vault) {
            guard let key = String(data: data, encoding: .utf8), key.utf8.count == 43 else {
                throw DeviceError.message("Could not read this device’s secure installation identity.")
            }
            return key
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DeviceError.message("Could not create this device’s secure installation identity.") }
        let key = Data(bytes).base64URL
        try credentials.save(Data(key.utf8), account: "installation-key", vault: vault)
        return key
    }
}

private struct CloudKeychainVault: CloudCredentialVault {
    private func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read(service: String, account: String) throws -> Data? {
        var request = query(service: service, account: account)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw DeviceError.message("Could not read your secure Cloud connection.") }
        return data
    }
    func write(_ data: Data, service: String, account: String) throws {
        let query = query(service: service, account: account)
        let updates: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; updates.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw DeviceError.message("Could not save your secure Cloud connection.") }
        } else if status != errSecSuccess { throw DeviceError.message("Could not update your secure Cloud connection.") }
    }
    func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceError.message("Could not remove your earlier secure Cloud connection.") }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Foreground invalidation channel. Durable state remains on the HTTP API, so reconnects
/// always reconcile instead of depending on replay or treating socket delivery as storage.
@MainActor final class DeviceConnection {
    private var runner: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var transport: URLSession?

    func start(token: String, received: @escaping @MainActor (DeviceCloudNotice, Bool) -> Void,
               disconnected: @escaping @MainActor (_ authorizationRejected: Bool) -> Void,
               billingUpdated: @escaping @MainActor (DeviceBillingUpdateNotice) -> Void = { _ in }) {
        stop()
        runner = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                var components = URLComponents(url: CloudClient.origin.appendingPathComponent("api/device/connect"), resolvingAgainstBaseURL: false)!
                components.scheme = "wss"
                var request = URLRequest(url: components.url!)
                // Do not let URLSession's ordinary resource deadline rotate a
                // socket. Both deadlines exceed the server's 90-day credential
                // lifetime; a separate task bounds only the actual handshake.
                let transportLimit: TimeInterval = 365 * 24 * 60 * 60
                request.timeoutInterval = transportLimit
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("1", forHTTPHeaderField: "X-Screenpunk-Screen-Data-Protocol")
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = transportLimit
                configuration.timeoutIntervalForResource = transportLimit
                let transport = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
                let socket = transport.webSocketTask(with: request)
                socket.maximumMessageSize = 4096
                self.transport = transport; self.socket = socket
                let openedAt = Date()
                socket.resume()
                var receivedInitialNotice = false
                let handshakeTimeout = Task {
                    do { try await Task.sleep(nanoseconds: 25_000_000_000) }
                    catch { return }
                    socket.cancel(with: .goingAway, reason: nil)
                }
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard !Task.isCancelled else { break }
                        let data: Data
                        switch message {
                        case .data(let value): data = value
                        case .string(let value): data = Data(value.utf8)
                        @unknown default: continue
                        }
                        if let update = DeviceBillingUpdateNotice.decode(data) { billingUpdated(update); continue }
                        guard let notice = DeviceCloudNotice.decode(data) else { continue }
                        // A recognized server frame proves authentication and the
                        // upgrade. The initial status frame doubles as catch-up.
                        let initial = !receivedInitialNotice
                        receivedInitialNotice = true
                        if initial { handshakeTimeout.cancel() }
                        received(notice, initial)
                    }
                } catch { /* Reconnect below; never expose token or socket URLs in errors. */ }
                handshakeTimeout.cancel()
                let httpStatus = (socket.response as? HTTPURLResponse)?.statusCode
                let authorizationRejected = socket.closeCode.rawValue == 4003 || httpStatus == 401 || httpStatus == 403
                socket.cancel(with: .goingAway, reason: nil)
                transport.invalidateAndCancel()
                guard !Task.isCancelled else { return }
                self.socket = nil; self.transport = nil
                disconnected(authorizationRejected)
                if authorizationRejected { return }
                // Healthy long-lived connections restart quickly. Repeated failed handshakes
                // back off up to one minute, with jitter to avoid synchronized reconnects.
                failures = Date().timeIntervalSince(openedAt) >= 60 ? 0 : min(failures + 1, 6)
                let delay = min(60, pow(2, Double(failures)) * Double.random(in: 0.75...1.25))
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
            }
        }
    }
    func stop() {
        runner?.cancel(); runner = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        transport?.invalidateAndCancel(); transport = nil
    }
}
