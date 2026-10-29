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
enum CloudSignOutError: Error { case secureCredentialsNotCleared }
struct AgentStatus: Decodable {
    let agentReady: Bool
    let profileID: String?
    let authoringCapabilities: CloudAuthoringCapabilities?
    let latestRequest: Summary?
    let command: Command?
    struct Command: Decodable { let id: String; let type: String; let screenID: String?; let activationID: String?; let expiresAt: Double }
    struct Summary: Decodable { let id: String; let status: String }
}
@MainActor final class CloudClient: NSObject, ASWebAuthenticationPresentationContextProviding {
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
    private var authSession: ASWebAuthenticationSession?
    private var enrolledToken: String?
    var session: DeviceSession? = SessionKeychain.load()
    /// Used only for local libraries, ownership, permissions and preference eligibility.
    var localAccountID: String? { session.map { Self.originScope.localAccountID(serverUserID: $0.user.id) } }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    func signIn() async throws -> DeviceSession {
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
        var url = URLComponents(url: Self.origin.appendingPathComponent("auth/device/authorize"), resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state)]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let flow = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: "screenpunk-one") { callback, error in
                if let error { continuation.resume(throwing: error) }
                else if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: DeviceError.message("Sign-in did not return a response.")) }
            }
            flow.presentationContextProvider = self
            self.authSession = flow
            if !flow.start() { continuation.resume(throwing: DeviceError.message("Could not open sign-in.")) }
        }
        defer { authSession = nil }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard callback.host == "auth", callback.path == "/callback", items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else { throw DeviceError.message("Sign-in response could not be verified.") }
        let value: DeviceSession = try await call("auth/device/token", method: "POST", body: ["code": code, "codeVerifier": verifier, "installationKey": installationKey], authenticated: false)
        let registered = try await registerSession(value)
        // Publish credentials only after enrollment succeeds. An interrupted account
        // switch must never drive the previous account's open library with a new token.
        try SessionKeychain.save(registered)
        session = registered; enrolledToken = registered.accessToken
        return registered
    }
    func enrollInstallation() async throws {
        guard let value = session else { throw DeviceError.message("Sign in to Screenpunk to continue.") }
        guard enrolledToken != value.accessToken else { return }
        let registered = try await registerSession(value)
        guard session?.accessToken == value.accessToken else { throw CancellationError() }
        try SessionKeychain.save(registered); session = registered; enrolledToken = value.accessToken
    }
    private func registerSession(_ value: DeviceSession) async throws -> DeviceSession {
        let key = try InstallationIdentity.loadOrCreate()
        let registration: DeviceRegistration
        do { registration = try await call("api/device/register", method: "POST", body: ["name": UIDevice.current.name, "installationKey": key], authorizationToken: value.accessToken) }
        catch DeviceError.http(let status, _) where status == 409 {
            throw DeviceError.http(409, "This device has an earlier saved connection. Sign in again from Settings to restore it.")
        }
        guard registration.id == value.deviceId else { throw DeviceError.message("Your device connection changed. Sign in again to continue.") }
        var next = value; next.profileID = registration.profileID
        return next
    }
    func rememberProfile(_ profileID: String) throws {
        guard var value = session, value.profileID != profileID else { return }
        value.profileID = profileID; try SessionKeychain.save(value); session = value
    }
    func call<T: Decodable>(_ path: String, method: String = "GET", body: Any? = nil, authenticated: Bool = true, authorizationToken: String? = nil, authoringVersion: Int = 1) async throws -> T {
        var request = URLRequest(url: Self.origin.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue(String(authoringVersion), forHTTPHeaderField: "X-Screenpunk-Authoring-Version")
        if authenticated {
            guard let token = authorizationToken ?? session?.accessToken else { throw DeviceError.message("Sign in to Screenpunk to continue.") }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            let bytes = try JSONSerialization.data(withJSONObject: body)
            guard bytes.count <= 768 * 1024 else { throw DeviceError.message("Request exceeded the device limit.") }
            request.httpBody = bytes
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let transport = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { transport.finishTasksAndInvalidate() }
        let (data, response) = try await transport.data(for: request)
        guard data.count <= 768 * 1024 else { throw DeviceError.message("Cloud response exceeded the device limit.") }
        guard let http = response as? HTTPURLResponse else { throw DeviceError.message("Cloud did not respond.") }
        if http.statusCode == 401 { throw DeviceError.http(401, "Your connection has expired. Sign in again from Settings.") }
        guard (200..<300).contains(http.statusCode) else {
            throw DeviceError.http(http.statusCode, "Screenpunk could not complete this request (\(http.statusCode)). Try again shortly.")
        }
        if path.hasPrefix("api/device/requests") || path == "api/device/preferences/sync" {
            try DeviceAuthoringWire.validateResponse(data.isEmpty ? Data("{}".utf8) : data)
        }
        return try JSONDecoder().decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
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
private struct DeviceRegistration: Decodable { let id: String; let profileID: String }

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
        ])
        guard response.id == request.requestID, let accepted = response.snapshot else {
            throw DeviceError.message("Cloud did not confirm the authoring snapshot. Your screen is unchanged.")
        }
        return accepted
    }
    func progress(requestID: String) async throws -> AuthoringProgress {
        let response: AgentRequest = try await cloud.call("api/device/requests/\(requestID)")
        return Self.progress(response)
    }
    func reconcile(requestID: String) async throws -> AuthoringDeliveryState {
        let response: AgentRequest = try await cloud.call("api/device/requests/\(requestID)")
        if let unsupported = response.canonicalUnsupported { return .ended(status: unsupported.code, message: unsupported.message) }
        if response.status == "completed" {
            guard let result = response.authoringResult else {
                throw DeviceError.message("This result has no verified authoring envelope. Your screen is unchanged.")
            }
            return .completed(result)
        }
        if ["failed", "cancelled", "timed_out"].contains(response.status) {
            return .ended(status: response.status, message: response.failure)
        }
        return .pending(Self.progress(response))
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
    init(cloud: CloudClient) { self.cloud = cloud }
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
        ], authoringVersion: 2)
        guard response.id == request.requestID, let accepted = response.snapshot,
              accepted == snapshot else {
            throw DeviceError.message("Cloud did not confirm the authoring snapshot. Your screen is unchanged.")
        }
        return accepted
    }
    func progress(requestID: String) async throws -> AuthoringProgress {
        let response: AgentRequestV2 = try await cloud.call("api/device/requests/\(requestID)", authoringVersion: 2)
        return Self.progress(response)
    }
    func reconcile(requestID: String) async throws -> AuthoringDeliveryStateV2 {
        let response: AgentRequestV2 = try await cloud.call("api/device/requests/\(requestID)", authoringVersion: 2)
        if let unsupported = response.canonicalUnsupported { return .ended(status: unsupported.code, message: unsupported.message) }
        if response.status == "completed" {
            guard let result = response.authoringResult else {
                throw DeviceError.message("This result has no verified asset mutation envelope. Your screen is unchanged.")
            }
            return .completed(result)
        }
        if ["failed", "cancelled", "timed_out"].contains(response.status) {
            return .ended(status: response.status, message: response.failure)
        }
        return .pending(Self.progress(response))
    }
    func cancel(requestID: String) async throws {
        do { let _: AgentRequestV2 = try await cloud.call("api/device/requests/\(requestID)/cancel", method: "POST", authoringVersion: 2) }
        catch DeviceError.http(let status, _) where status == 409 { }
    }
    func acknowledge(_ receipt: ApplicationReceiptV1) async throws {
        let _: EmptyResponse = try await cloud.call("api/device/requests/\(receipt.requestID)/application-receipt", method: "POST", body: CloudAuthoringTransport.object(receipt), authoringVersion: 2)
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
        return try? JSONDecoder().decode(DeviceSession.self, from: data)
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

    func start(token: String, changed: @escaping @MainActor () -> Void,
               disconnected: @escaping @MainActor () -> Void) {
        stop()
        runner = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                var components = URLComponents(url: CloudClient.origin.appendingPathComponent("api/device/connect"), resolvingAgainstBaseURL: false)!
                components.scheme = "wss"
                var request = URLRequest(url: components.url!)
                request.timeoutInterval = 25
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let transport = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
                let socket = transport.webSocketTask(with: request)
                socket.maximumMessageSize = 4096
                self.transport = transport; self.socket = socket
                let openedAt = Date()
                socket.resume()
                // Server also sends an initial invalidation once the handshake completes.
                changed()
                let lifetime = Task {
                    do { try await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000) }
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
                        guard data.count <= 4096,
                              let notice = try? JSONDecoder().decode(Notice.self, from: data),
                              notice.type == "status_changed" else { continue }
                        changed()
                    }
                } catch { /* Reconnect below; never expose token or socket URLs in errors. */ }
                lifetime.cancel()
                socket.cancel(with: .goingAway, reason: nil)
                transport.invalidateAndCancel()
                guard !Task.isCancelled else { return }
                disconnected()
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
    private struct Notice: Decodable { let type: String }
}
