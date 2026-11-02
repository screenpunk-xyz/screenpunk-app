import Foundation
import ScreenpunkCore

typealias ScreenFile = AuthoringScreenFile
typealias ScreenArtifact = AuthoringScreen

enum DeviceError: LocalizedError {
    case message(String)
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .message(let value), .http(_, let value): return value
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
    let checkedAt: Date
    static func status(_ observation: Self?, accountID: String?, deviceID: String?, profileID: String?, now: Date = Date()) -> Status {
        guard let accountID, let deviceID else { return .notSignedIn }
        guard let observation, observation.accountID == accountID, observation.deviceID == deviceID,
              now.timeIntervalSince(observation.checkedAt) >= 0,
              now.timeIntervalSince(observation.checkedAt) < 30 else { return .unchecked }
        guard let observedProfile = observation.profileID, !observedProfile.isEmpty,
              profileID == nil || profileID == observedProfile,
              let ready = observation.ready else { return .unavailable }
        return ready ? .connected : .waiting
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
    private enum CodingKeys: String, CodingKey { case id,status,result,failure,text,createdAt,deadlineAt,progress,snapshot,authoringResult,applicationReceipt,canonicalUnsupported }
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
        guard response.status == "pending", response.applicationReceipt == nil,
              let deadline = response.deadlineAt, deadline > now else { return nil }
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
        if status == "pending", let deadlineAt, now >= deadlineAt { return .ended(status: "timed_out", message: nil) }
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
        if status == "pending", let deadlineAt, now >= deadlineAt { return .ended(status: "timed_out", message: nil) }
        return .pending(.init(status: status, caption: progress?.caption, updatedAt: progress?.updatedAt ?? createdAt, deadlineAt: deadlineAt))
    }
}
