import Foundation
import ScreenpunkCore

typealias ScreenFile = AuthoringScreenFile
typealias ScreenArtifact = AuthoringScreen

enum DeviceError: LocalizedError {
    case message(String)
    case http(Int, String)
    case deviceNameConflict(CloudDeviceNameSnapshot)
    case deviceRevoked
    var authorizationRejected: Bool {
        if case .deviceRevoked = self { return true }
        if case .http(401, _) = self { return true }
        return false
    }
    var errorDescription: String? {
        switch self {
        case .message(let value), .http(_, let value): return value
        case .deviceNameConflict: return "The device name changed in Cloud. The latest Cloud name has been kept."
        case .deviceRevoked: return "This device was removed from your Cloud account. Sign in again to reconnect it."
        }
    }
}

/// A read-only listener observation belongs to one signed-in account/device, never
/// the Local agent or selected request route. Old/offline observations cannot say connected.
struct CloudListenerObservation {
    enum Status: Equatable {
        case notSignedIn, unchecked, connected, waiting, unavailable
        var label: String {
            switch self {
            case .notSignedIn: return "Not signed in"
            case .unchecked: return "Listener status not checked"
            case .connected: return "Listener connected"
            case .waiting: return "Waiting for listener"
            case .unavailable: return "Listener status unavailable"
            }
        }
    }
    let accountID: String
    let deviceID: String
    let profileID: String?
    let ready: Bool?
    let pluginConnected: Bool?

    init(accountID: String, deviceID: String, profileID: String?, ready: Bool?, pluginConnected: Bool? = nil) {
        self.accountID = accountID
        self.deviceID = deviceID
        self.profileID = profileID
        self.ready = ready
        self.pluginConnected = pluginConnected
    }

    var canCompleteCloudSetup: Bool {
        ready == true && pluginConnected != false
    }

    func matches(accountID: String?, deviceID: String?, profileID: String?) -> Bool {
        guard self.accountID == accountID, self.deviceID == deviceID,
              let observedProfile = self.profileID, !observedProfile.isEmpty else { return false }
        return profileID == nil || profileID == observedProfile
    }

    func pluginConnection(accountID: String?, deviceID: String?, profileID: String?) -> Bool? {
        guard matches(accountID: accountID, deviceID: deviceID, profileID: profileID) else { return nil }
        return pluginConnected
    }

    static func status(_ observation: Self?, accountID: String?, deviceID: String?, profileID: String?) -> Status {
        guard let accountID, let deviceID else { return .notSignedIn }
        guard let observation, observation.accountID == accountID, observation.deviceID == deviceID else { return .unchecked }
        guard observation.matches(accountID: accountID, deviceID: deviceID, profileID: profileID),
              let ready = observation.ready else { return .unavailable }
        return ready ? .connected : .waiting
    }
}

/// Status reads can overlap. The newest published read wins even if an older
/// request returns later, and only socket-owned observations expire on disconnect.
struct CloudListenerObservations {
    enum Source { case direct, socket }

    private(set) var observation: CloudListenerObservation?
    private var source: Source?
    private var publishedRead: UInt64 = 0

    @discardableResult
    mutating func publish(_ observation: CloudListenerObservation, source: Source, read: UInt64) -> Bool {
        guard read >= publishedRead else { return false }
        if source == .socket, observation.ready == nil, self.source == .direct { return false }
        self.observation = observation
        self.source = source
        publishedRead = read
        return true
    }

    mutating func clearSocket() {
        if source == .socket { clear() }
    }

    mutating func clear() {
        observation = nil
        source = nil
    }
}

/// Presentation timing only: authenticated server observations still decide
/// connection and readiness. A grace expiry offers help, never installation failure.
struct CloudPluginSetupProgress: Equatable {
    struct Scope: Equatable {
        let origin: String
        let account: String
        let device: String
        let owner: String
    }
    struct Input: Equatable {
        let scope: Scope?
        let pluginConnected: Bool?
        let listenerReady: Bool
    }
    enum Phase: Equatable { case plugin, looking, manualListener, ready }
    private(set) var phase: Phase = .plugin
    private(set) var scope: Scope?
    private(set) var firstConnectionDeadline: Date?
    var wakeDeadline: Date? { phase == .looking ? firstConnectionDeadline : nil }

    func presentsPluginInstructions(for input: Input) -> Bool {
        guard input.scope != nil, !input.listenerReady else { return false }
        // The first connected render must retain the existing instructions,
        // even before SwiftUI's observation callback starts the grace clock.
        if scope == input.scope, firstConnectionDeadline != nil, input.pluginConnected != false {
            return phase != .manualListener
        }
        return true
    }

    mutating func update(_ input: Input, now: Date) {
        if input.scope != scope {
            scope = input.scope
            firstConnectionDeadline = nil
        }
        guard scope != nil else {
            phase = .plugin
            firstConnectionDeadline = nil
            return
        }
        if input.listenerReady { phase = .ready; return }
        // Explicit revocation ends this connection generation. Unknown reads
        // preserve its clock; repeated connected reads never restart it.
        if input.pluginConnected == false {
            phase = .plugin
            firstConnectionDeadline = nil
            return
        }
        if input.pluginConnected == true, firstConnectionDeadline == nil {
            firstConnectionDeadline = now.addingTimeInterval(30)
        }
        guard let deadline = firstConnectionDeadline else { phase = .plugin; return }
        phase = now < deadline ? .looking : .manualListener
    }
}

/// Socket messages are invalidations only. Unknown or incomplete frames cannot
/// wake an account sync, and durable values always come from authenticated HTTP.
enum DeviceCloudNotice: Equatable {
    case deviceRevoked(deviceID: String)
    case deviceNameUpdated(CloudDeviceNameSnapshot)
    case statusChanged
    case preferenceUpdated(profileID: String)
    case catalogUpdated
    case screenDataConnected(socketID: String)
    case screenDataQuery(DeviceScreenDataNotice)

    private struct Wire: Decodable { let type: String; let profileID: String?; let screenDataSocketId: String?; let deviceId: String? }

    static func decode(_ data: Data) -> Self? {
        guard data.count <= 4096, let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        switch wire.type {
        case "device_name_updated":
            guard let snapshot = try? JSONDecoder().decode(CloudDeviceNameSnapshot.self, from: data), snapshot.valid else { return nil }
            return .deviceNameUpdated(snapshot)
        case "device_revoked":
            guard let id = wire.deviceId, !id.isEmpty, id.utf8.count <= 128 else { return nil }
            return .deviceRevoked(deviceID: id)
        case "status_changed":
            if let socketID = wire.screenDataSocketId {
                guard UUID(uuidString: socketID) != nil else { return nil }
                return .screenDataConnected(socketID: socketID)
            }
            return .statusChanged
        case "screen_data_query":
            guard let query = try? JSONDecoder().decode(DeviceScreenDataNotice.self, from: data), query.valid else { return nil }
            return .screenDataQuery(query)
        case "preference.updated":
            guard let profileID = wire.profileID, !profileID.isEmpty else { return nil }
            return .preferenceUpdated(profileID: profileID)
        case "catalog.updated": return .catalogUpdated
        default: return nil
        }
    }
}

/// Generic 401/403 responses, timeouts and server outages are not proof that an
/// enrollment was removed. Only this explicit authenticated response revokes it.
enum CloudDeviceRevocationEvidence {
    static func matches(status: Int, data: Data, deviceID: String) -> Bool {
        guard status == 401, data.count <= 4096,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["error"] as? String == "device_revoked",
              body["deviceId"] as? String == deviceID else { return false }
        return true
    }
}

/// Validate canonical nested payloads before Codable can discard unknown wire fields.
enum DeviceAuthoringWire {
    static func validateResponse(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeviceError.message("Cloud returned an invalid authoring response.")
        }
        func bytes(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) }
        var snapshot: AuthoringRequestV1?
        var snapshotV2: AuthoringRequestV2?
        if let value = object["snapshot"], !(value is NSNull) {
            if (value as? [String: Any])?["schemaVersion"] as? Int == 2 {
                snapshotV2 = try AuthoringV2Contract.validateRequest(bytes(value))
            } else { snapshot = try AuthoringContract.validateRequest(bytes(value)) }
        }
        if let value = object["authoringResult"], !(value is NSNull) {
            if (value as? [String: Any])?["schemaVersion"] as? Int == 2 {
                guard snapshot == nil else { throw DeviceError.message("Cloud returned a mismatched authoring contract.") }
                _ = try AuthoringV2Contract.validateResult(bytes(value), request: snapshotV2)
            } else {
                guard snapshotV2 == nil else { throw DeviceError.message("Cloud returned a mismatched authoring contract.") }
                _ = try AuthoringContract.validateResult(bytes(value), request: snapshot)
            }
        }
        if let value = object["applicationReceipt"], !(value is NSNull) { _ = try AuthoringContract.validateApplicationReceipt(bytes(value)) }
        if let records = object["records"] as? [Any] {
            guard records.count <= 128 else { throw DeviceError.message("Cloud returned too many preferences.") }
            for record in records { _ = try AuthoringContract.validatePreferenceRecord(bytes(record)) }
        }
        if let conflicts = object["conflicts"] as? [[String: Any]] {
            guard conflicts.count <= 128 else { throw DeviceError.message("Cloud returned too many preference conflicts.") }
            for conflict in conflicts {
                if let current = conflict["current"], !(current is NSNull) { _ = try AuthoringContract.validatePreferenceRecord(bytes(current)) }
            }
        }
    }
}

/// Absent or unknown capabilities never opt a request into retained asset delivery.
struct CloudAuthoringCapabilities: Codable, Equatable, Sendable {
    let contractVersions: [String]
    let features: [String]
    var supportsV2: Bool { contractVersions.contains("2") && features.contains("asset-references-v2") }
    var supportsPackageAssets: Bool { supportsV2 && features.contains("package-assets-v2") }
    static let unavailable = CloudAuthoringCapabilities(contractVersions: [], features: [])
}

struct AgentRequest: Decodable {
    let id: String
    let status: String
    let result: ResultValue?
    let failure: String?
    let text: String?
    let createdAt: Double?
    let deadlineAt: Double?
    let progress: ProgressValue?
    let snapshot: AuthoringRequestV1?
    let snapshotV2: AuthoringRequestV2?
    let authoringResult: AuthoringResultV1?
    let authoringResultV2: AuthoringResultV2?
    let applicationReceipt: ApplicationReceiptV1?
    let canonicalUnsupported: Unsupported?
    let remoteOperationID: String?
    private enum CodingKeys: String, CodingKey { case id,status,result,failure,text,createdAt,deadlineAt,progress,snapshot,authoringResult,applicationReceipt,canonicalUnsupported,remoteOperationID }
    private struct Version: Decodable { let schemaVersion: Int }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        status = try values.decode(String.self, forKey: .status)
        result = try values.decodeIfPresent(ResultValue.self, forKey: .result)
        failure = try values.decodeIfPresent(String.self, forKey: .failure)
        text = try values.decodeIfPresent(String.self, forKey: .text)
        createdAt = try values.decodeIfPresent(Double.self, forKey: .createdAt)
        deadlineAt = try values.decodeIfPresent(Double.self, forKey: .deadlineAt)
        progress = try values.decodeIfPresent(ProgressValue.self, forKey: .progress)
        if try values.decodeIfPresent(Version.self, forKey: .snapshot)?.schemaVersion == 2 {
            snapshotV2 = try values.decode(AuthoringRequestV2.self, forKey: .snapshot); snapshot = nil
        } else { snapshot = try values.decodeIfPresent(AuthoringRequestV1.self, forKey: .snapshot); snapshotV2 = nil }
        if try values.decodeIfPresent(Version.self, forKey: .authoringResult)?.schemaVersion == 2 {
            authoringResultV2 = try values.decode(AuthoringResultV2.self, forKey: .authoringResult); authoringResult = nil
        } else { authoringResult = try values.decodeIfPresent(AuthoringResultV1.self, forKey: .authoringResult); authoringResultV2 = nil }
        applicationReceipt = try values.decodeIfPresent(ApplicationReceiptV1.self, forKey: .applicationReceipt)
        canonicalUnsupported = try values.decodeIfPresent(Unsupported.self, forKey: .canonicalUnsupported)
        remoteOperationID = try values.decodeIfPresent(String.self, forKey: .remoteOperationID)
    }
    struct Unsupported: Decodable { let code: String; let message: String }
    struct ProgressValue: Decodable { let caption: String; let updatedAt: Double }
    struct ResultValue: Decodable { let type: String; let screen: ScreenArtifact?; let text: String? }
}
struct AgentRequestV2: Decodable {
    let id: String
    let status: String
    let failure: String?
    let createdAt: Double?
    let deadlineAt: Double?
    let progress: AgentRequest.ProgressValue?
    let snapshot: AuthoringRequestV2?
    let authoringResult: AuthoringResultV2?
    let applicationReceipt: ApplicationReceiptV1?
    let canonicalUnsupported: AgentRequest.Unsupported?
    let remoteOperationID: String?
}

struct RemoteAuthoringGrant: Codable, Equatable, Identifiable {
    let grantID: String
    let name: String
    let allowCreate: Bool
    let allowEdit: Bool
    var id: String { grantID }
}

struct RemoteAuthoringPermissions: Decodable {
    let grants: [RemoteAuthoringGrant]
}

struct RemoteAuthoringIntent: Decodable {
    enum Kind: String, Decodable { case create, edit }
    enum Status: String, Decodable { case queued, prepared, completed, applied, conflict, rejected, expired, cancelled }
    let operationID: String
    let kind: Kind
    let deviceID: String
    let grantID: String
    let prompt: String
    let expiresAt: Int64
    let status: Status
    let screenID: String?
    let baseRevision: String?
    let requestID: String?
    let applyClaimed: Bool?

    var isValid: Bool {
        guard UUID(uuidString: operationID) != nil, operationID.lowercased() == operationID, !grantID.isEmpty, !deviceID.isEmpty,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              requestID == nil || requestID == operationID else { return false }
        switch kind {
        case .create: return baseRevision == nil && (status != .queued || screenID == nil)
        case .edit: return screenID?.isEmpty == false && baseRevision?.isEmpty == false
        }
    }

    func matches(_ snapshot: AuthoringRequestV2) -> Bool {
        isValid && snapshot.requestID == operationID && snapshot.deadlineAt == expiresAt &&
            snapshot.context.deviceID == deviceID && snapshot.context.userRequest == prompt &&
            snapshot.context.baseRevision == baseRevision &&
            (screenID == nil || snapshot.context.screenID == screenID)
    }
}
struct RemoteAuthoringInbox: Decodable {
    let intents: [RemoteAuthoringIntent]
}


/// A fresh library is not evidence that the account's latest request is new work.
/// Only adopt work that is still pending after an authoritative read. Existing
/// locally journaled requests continue through normal reconciliation instead.
enum CloudRequestRecovery {
    static let alreadyAppliedStatus = "already_applied"

    @MainActor static func discoverPending(id: String, status: String, consumedID: String?, lastAppliedRequestID: String?, now: Double = Date().timeIntervalSince1970 * 1000,
        load: (String) async throws -> AgentRequest) async throws -> AgentRequest? {
        guard status == "pending", id != consumedID, id != lastAppliedRequestID else { return nil }
        let response = try await load(id)
        guard response.id == id else { throw DeviceError.message("Cloud returned a different request.") }
        guard response.status == "pending", response.applicationReceipt == nil, response.remoteOperationID == nil else { return nil }
        return response
    }

    static func receiptOutcome(_ receipt: ApplicationReceiptV1?, requestID: String, snapshotDigest: String?, operationID: String?) throws -> (status: String, message: String?)? {
        guard let receipt else { return nil }
        guard receipt.schemaVersion == 1, ["applied", "conflict", "rejected"].contains(receipt.status),
              receipt.requestID == requestID, receipt.inputDigest == snapshotDigest,
              operationID == nil || receipt.operationID == operationID else {
            throw DeviceError.message("Cloud returned a mismatched application receipt.")
        }
        if receipt.status == "applied" { return (alreadyAppliedStatus, nil) }
        return (receipt.status, receipt.message ?? "This result was already acknowledged as \(receipt.status). Your screen is unchanged.")
    }
}

extension AgentRequest {
    func deliveryState(requestID: String, now: Double = Date().timeIntervalSince1970 * 1000) throws -> AuthoringDeliveryState {
        guard id == requestID else { throw DeviceError.message("Cloud returned a different request.") }
        if applicationReceipt != nil {
            guard snapshot?.requestID == requestID, snapshot?.delivery.route == "cloud" else {
                throw DeviceError.message("Cloud returned an application receipt without its matching snapshot.")
            }
        }
        if let receipt = try CloudRequestRecovery.receiptOutcome(applicationReceipt, requestID: requestID,
            snapshotDigest: snapshot?.delivery.snapshotDigest, operationID: authoringResult?.operationID) {
            return .ended(status: receipt.status, message: receipt.message)
        }
        if let unsupported = canonicalUnsupported { return .ended(status: unsupported.code, message: unsupported.message) }
        if status == "completed" {
            guard let authoringResult else { throw DeviceError.message("This result has no verified authoring envelope. Your screen is unchanged.") }
            return .completed(authoringResult)
        }
        if ["failed", "cancelled", "timed_out"].contains(status) { return .ended(status: status, message: failure) }
        return .pending(.init(status: status, caption: progress?.caption, updatedAt: progress?.updatedAt ?? createdAt, deadlineAt: deadlineAt))
    }
}

extension AgentRequestV2 {
    func deliveryState(requestID: String, now: Double = Date().timeIntervalSince1970 * 1000) throws -> AuthoringDeliveryStateV2 {
        guard id == requestID else { throw DeviceError.message("Cloud returned a different request.") }
        if applicationReceipt != nil {
            guard snapshot?.requestID == requestID, snapshot?.delivery.route == "cloud" else {
                throw DeviceError.message("Cloud returned an application receipt without its matching snapshot.")
            }
        }
        if let receipt = try CloudRequestRecovery.receiptOutcome(applicationReceipt, requestID: requestID,
            snapshotDigest: snapshot?.delivery.snapshotDigest, operationID: authoringResult?.operationID) {
            return .ended(status: receipt.status, message: receipt.message)
        }
        if let unsupported = canonicalUnsupported { return .ended(status: unsupported.code, message: unsupported.message) }
        if status == "completed" {
            guard let authoringResult else { throw DeviceError.message("This result has no verified asset mutation envelope. Your screen is unchanged.") }
            return .completed(authoringResult)
        }
        if ["failed", "cancelled", "timed_out"].contains(status) { return .ended(status: status, message: failure) }
        return .pending(.init(status: status, caption: progress?.caption, updatedAt: progress?.updatedAt ?? createdAt, deadlineAt: deadlineAt))
    }
}

/// Coalesces work arriving during a pass and wakes once at a retry deadline.
@MainActor
final class CatalogWorkPump {
    enum Next {
        case idle
        case ready
        case retry(Date)
    }

    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var pending = false

    func request(_ step: @escaping @MainActor () async -> Next) {
        timer?.cancel()
        timer = nil
        pending = true
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.pending = false
                let next = await step()
                guard !Task.isCancelled else { return }
                if self.pending { continue }
                switch next {
                case .ready: continue
                case .idle:
                    self.worker = nil
                    return
                case .retry(let deadline):
                    self.worker = nil
                    self.timer = Task { [weak self] in
                        do {
                            try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                        } catch { return }
                        guard !Task.isCancelled else { return }
                        self?.request(step)
                    }
                    return
                }
            }
        }
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        timer?.cancel()
        timer = nil
        pending = false
    }
}

struct CatalogLinkedInstallRequest: Encodable {
    let schemaVersion = 1
    var catalogScreenID: String
    var versionID: String
    var sourceRevisionID: String
    var packageDigest: String
    var libraryID: String
    var localScreenID: String
    var localRevisionID: String
    var commitCounter: Int
}

struct CatalogLinkedInstall: Decodable {
    var schemaVersion: Int
    var catalogScreenID: String
    var libraryID: String
    var localScreenID: String
    var localRevisionID: String
    var commitCounter: Int
    var copyID: String
    var installedVersionID: String
    var installedSourceRevisionID: String
    var installedDisplayVersion: Int
    var installedPackageDigest: String
    var linkedDeviceCount: Int
    var current: CatalogVersion?

    func validate() throws {
        guard schemaVersion == 1,
              [catalogScreenID, libraryID, localScreenID, localRevisionID, copyID, installedVersionID, installedSourceRevisionID]
                .allSatisfy(Self.validIdentifier),
              (1...9_007_199_254_740_991).contains(commitCounter), (1...9_007_199_254_740_991).contains(linkedDeviceCount),
              installedDisplayVersion > 0,
              installedPackageDigest.range(of: #"^[a-f0-9]{64}\z"#, options: .regularExpression) != nil,
              current.map({ $0.catalogScreenID == catalogScreenID }) != false else {
            throw DeviceError.message("Cloud returned an invalid linked screen.")
        }
    }

    static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z"#, options: .regularExpression) != nil
    }

    func matches(_ request: CatalogLinkedInstallRequest) -> Bool {
        catalogScreenID == request.catalogScreenID && libraryID == request.libraryID &&
            localScreenID == request.localScreenID && localRevisionID == request.localRevisionID &&
            installedVersionID == request.versionID && commitCounter == request.commitCounter &&
            installedSourceRevisionID == request.sourceRevisionID && installedPackageDigest == request.packageDigest
    }

    func matches(_ link: ScreenLibrary.LinkedCatalogInstall) -> Bool {
        catalogScreenID == link.catalogScreenID && libraryID == link.libraryID &&
            localScreenID == link.localScreenID && localRevisionID == link.localRevision &&
            installedVersionID == link.versionID && commitCounter == link.commitCounter &&
            installedSourceRevisionID == link.sourceRevisionID && installedPackageDigest == link.packageDigest &&
            installedDisplayVersion == link.displayVersion && copyID == link.copyID
    }

}

struct CatalogLinkedUpdates: Decodable {
    var schemaVersion: Int
    var subscriptions: [CatalogLinkedInstall]
    var nextCursor: String?
}


/// Request-local silence timer, reset before a new preflight becomes visible.
struct RequestProgressTiming {
    var lastProgressAt: Date = Date()
    var warningDismissedAt: Date = .distantPast

    mutating func begin(at now: Date) {
        lastProgressAt = now
        warningDismissedAt = .distantPast
    }
    func isTakingLonger(at now: Date) -> Bool {
        now.timeIntervalSince(max(lastProgressAt, warningDismissedAt)) >= 60
    }
}

/// A valid pending Cloud response is a successful read: await the next push.
/// The existing Local adapter has no device wake callback and still needs its
/// bounded reconciliation fallback until that separate transport gains one.
enum AuthoringRefreshPolicy {
    /// A foreground probe with no work and no live push channel must go idle.
    static func retryFailedRead(hasPendingWork: Bool, hasCloudSocket: Bool) -> Bool {
        hasPendingWork || hasCloudSocket
    }
    static func reconciliationSucceeded(_ delivery: AuthoringDeliveryStateV2, route: String) -> Bool {
        switch delivery {
        case .pending: return route == "cloud"
        case .completed, .ended: return true
        case .deliveryUncertain, .needsAttention: return false
        }
    }
}

enum CredentialRegistrationEligibilityIssue: LocalizedError {
    case system, session, environment, connection, proposal, server

    var errorDescription: String? {
        switch self {
        case .system: return "Automatic setup requires iPadOS 18 or later. You can enter a provider token manually."
        case .session: return "Sign in to the Cloud account that created this screen to use automatic setup."
        case .environment: return "Automatic setup isn’t available in this Screenpunk environment. You can enter a provider token manually."
        case .connection: return "Automatic setup requires a bearer connection with one fixed read operation. You can enter a provider token manually."
        case .proposal: return "There’s no matching setup proposal for this screen on this iPad. Update the screen with your Cloud agent or enter a provider token manually."
        case .server: return "Automatic setup uses the HTTPS server from this screen’s setup proposal. Use that server or enter a provider token manually."
        }
    }
}

/// Stored in the origin-scoped Keychain. A deletion capability is never a normal login credential.
struct DeviceAccountDeletionIntent: Codable, Equatable {
    let origin: String
    let accountID: String
    let serverAccountID: String
    let operationID: String
    let profiles: [LocalProfileDescriptor]
    let preferenceKeys: [String]
    var preferenceDashboardIDs: Set<String> = []
    let billingJournalOwner: String?
    var deletionToken: String?
    var appleRevocationConsent: String?
    var externalCredentialCleanupRequired: Bool?
    var externalCredentialCleanupConsent: String?
    var lastFailure: DeviceAccountDeletionDiagnostic?
    var serverConfirmed = false
    var manualAppleRevocationRequired = false
    var appleRevocationHelpURL: String?
}

/// Optional support metadata is restricted to known values; never retain arbitrary response text.
struct DeviceAccountDeletionDiagnostic: Codable, Equatable {
    enum Stage: String, Codable, CaseIterable {
        case receiptCheck = "receipt_check", billingPreflight = "billing_preflight", appleStatus = "apple_status"
        case intentMetadata = "intent_metadata", intentStart = "intent_start", accountFence = "account_fence"
        case appleRevocation = "apple_revocation", catalogPlan = "catalog_plan", authCleanup = "auth_cleanup"
        case billingCleanup = "billing_cleanup", catalogCleanup = "catalog_cleanup"
        case accountFinalize = "account_finalize", receiptFinalize = "receipt_finalize"
    }
    enum Category: String, Codable, CaseIterable {
        case authorization, invalidRequest = "invalid_request", timeout, typeError = "type_error"
        case storageSchema = "storage_schema", requestLimit = "request_limit"
        case providerRecoveryRequired = "provider_recovery_required", providerUnavailable = "provider_unavailable"
        case storageUnavailable = "storage_unavailable", operationFailed = "operation_failed"
        case billingUnavailable = "billing_deletion_unavailable", appleConsent = "apple_revocation_consent_required"
        case authPending = "auth_deletion_pending", applePending = "apple_revocation_pending"
        case billingPending = "billing_deletion_pending", catalogPending = "catalog_deletion_pending"
        case incomplete = "deletion_incomplete"
    }
    let stage: Stage?
    let category: Category?
    init?(stage: String?, category: String?) {
        self.stage = stage.flatMap(Stage.init(rawValue:))
        self.category = category.flatMap(Category.init(rawValue:))
        if self.stage == nil && self.category == nil { return nil }
    }
    var supportCode: String { [stage?.rawValue, category?.rawValue].compactMap { $0 }.joined(separator: " / ") }
}

/// Only allowlisted server categories become user-visible; response capabilities never enter error text.
enum DeviceAccountDeletionFailure: LocalizedError, Equatable {
    enum Pending: String, Decodable, CaseIterable {
        case billingUnavailable = "billing_deletion_unavailable"
        case appleConsent = "apple_revocation_consent_required"
        case externalCredentialConsent = "external_credential_cleanup_consent_required"
        case auth = "auth_deletion_pending"
        case apple = "apple_revocation_pending"
        case billing = "billing_deletion_pending"
        case catalog = "catalog_deletion_pending"
        case incomplete = "deletion_incomplete"
    }
    case pending(Pending, diagnostic: DeviceAccountDeletionDiagnostic? = nil)
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .pending(.billingUnavailable, _): return "Account deletion is waiting for the billing service. Your recovery information is saved on this iPad."
        case .pending(.appleConsent, _): return "Apple authorization still needs confirmation. Your recovery information is saved on this iPad."
        case .pending(.externalCredentialConsent, _): return "Review credential cleanup at your connection providers before continuing."
        case .pending(.auth, _): return "Screenpunk has not finished removing account sign-in access. Your recovery information is saved on this iPad."
        case .pending(.apple, _): return "Screenpunk has not finished disconnecting Apple sign-in. Your recovery information is saved on this iPad."
        case .pending(.billing, _): return "Screenpunk has not finished removing account billing data. Your recovery information is saved on this iPad."
        case .pending(.catalog, _): return "Screenpunk has not finished removing account screens and settings. Your recovery information is saved on this iPad."
        case .pending(.incomplete, _), .invalidResponse: return "Screenpunk has not confirmed that account deletion finished. Your recovery information is saved on this iPad."
        case .http(let status): return "Screenpunk could not complete the deletion request (\(status)). Your recovery information is saved on this iPad."
        }
    }
}

/// Persistence must complete before the destructive request. A failed/lost response keeps the same retry capability.
enum DeviceAccountDeletionTransaction {
    static let appleAuthorizationWarning = "If you use Sign in with Apple, deletion also disconnects it for Screenpunk. You may need to sign in again in other Screenpunk environments; their data will not be deleted."
    static let externalCredentialCleanupWarning = "Removal of some credentials at your connection providers is unconfirmed. You can delete your Screenpunk account now. To revoke those credentials, remove them at the providers directly."
    struct Preparation: Decodable {
        let operationID: String
        let deletionToken: String
        var appleRevocationConsentRequired = false
        var appleAuthorizationWarning: String?
        var externalCredentialCleanupRequired: Bool?
        var externalCredentialCleanupWarning: String?
    }
    struct Result: Decodable {
        let deleted: Bool
        let operationID: String
        let manualAppleRevocationRequired: Bool?
        let appleRevocationHelpURL: String?
    }

    /// A partial response describes a pending operation, never successful deletion.
    static func validateHTTPResponse(_ data: Data, status: Int, operationID: String) throws {
        if status == 200 { return }
        if status == 409,
           let problem = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           problem["operationID"] as? String == operationID, problem["deleted"] as? Bool == false,
           problem["retryable"] as? Bool == true, problem["externalCredentialCleanupRequired"] as? Bool == true,
           problem["error"] as? String == DeviceAccountDeletionFailure.Pending.externalCredentialConsent.rawValue {
            throw DeviceAccountDeletionFailure.pending(.externalCredentialConsent)
        }
        if status == 503 {
            struct Partial: Decodable {
                let deleted: Bool
                let retryable: Bool
                let operationID: String
                let error: DeviceAccountDeletionFailure.Pending
                let stage: String?
                let category: String?
            }
            guard let partial = try? JSONDecoder().decode(Partial.self, from: data),
                  !partial.deleted, partial.retryable, partial.operationID == operationID else {
                throw DeviceAccountDeletionFailure.invalidResponse
            }
            throw DeviceAccountDeletionFailure.pending(partial.error, diagnostic: .init(stage: partial.stage, category: partial.category))
        }
        throw DeviceAccountDeletionFailure.http(status)
    }

    @MainActor static func perform(
        _ captured: DeviceAccountDeletionIntent,
        prepare: () async throws -> Preparation,
        execute: (DeviceAccountDeletionIntent, Bool) async throws -> Result,
        persist: (DeviceAccountDeletionIntent) throws -> Void
    ) async throws -> DeviceAccountDeletionIntent {
        if captured.serverConfirmed { return captured }
        guard captured.appleRevocationConsent == "REVOKE" else {
            throw DeviceError.message("Review the Apple authorization warning and confirm account deletion again.")
        }
        var intent = captured
        let retrying = intent.deletionToken != nil
        if intent.deletionToken == nil {
            let preparation = try await prepare()
            guard preparation.operationID == intent.operationID, !preparation.deletionToken.isEmpty else {
                throw DeviceError.message("Account deletion could not be prepared.")
            }
            if preparation.appleRevocationConsentRequired, preparation.appleAuthorizationWarning != appleAuthorizationWarning {
                throw DeviceError.message("The Apple authorization warning changed. Update Screenpunk before deleting this account.")
            }
            intent.deletionToken = preparation.deletionToken
            intent.externalCredentialCleanupRequired = preparation.externalCredentialCleanupRequired
            try persist(intent)
        }
        if intent.externalCredentialCleanupRequired == true && intent.externalCredentialCleanupConsent != "CONTINUE" {
            throw DeviceAccountDeletionFailure.pending(.externalCredentialConsent)
        }
        let response: Result
        do { response = try await execute(intent, retrying) }
        catch let failure as DeviceAccountDeletionFailure {
            if case .pending(let kind, let diagnostic) = failure {
                if kind == .externalCredentialConsent {
                    intent.externalCredentialCleanupRequired = true
                    intent.externalCredentialCleanupConsent = nil
                }
                intent.lastFailure = diagnostic
                try persist(intent)
            }
            throw failure
        }
        guard response.operationID == intent.operationID, response.deleted else {
            throw DeviceError.message("Account deletion is incomplete. Retry when you are online.")
        }
        intent.serverConfirmed = true
        intent.manualAppleRevocationRequired = response.manualAppleRevocationRequired ?? false
        if response.appleRevocationHelpURL == "https://support.apple.com/en-us/102571" {
            intent.appleRevocationHelpURL = response.appleRevocationHelpURL
        }
        try persist(intent)
        return intent
    }
}
