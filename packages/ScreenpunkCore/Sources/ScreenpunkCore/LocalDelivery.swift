import Foundation

public enum LocalDeliveryStatus: String, Codable, Sendable {
    case prepared, submitting, running, deliveryUncertain, needsAttention, completed, cancelled, applied, conflict, rejected, failed, timedOut
    public var isTerminal: Bool { [.cancelled, .applied, .conflict, .rejected, .failed, .timedOut].contains(self) }
    /// A completed transport result still awaits native CAS application and receipt.
    public var blocksNewRequest: Bool { !isTerminal }
}
public struct LocalDeliveryRecord: Codable, Equatable, Sendable {
    public var requestID: String
    public var inputDigest: String
    public var connectionID: String
    public var profileID: String
    public var hostKeySHA256: String
    public var threadID: String?
    public var turnID: String?
    public var baseRevision: String?
    public var deadlineAt: Int64
    public var status: LocalDeliveryStatus
    public var contractVersion: Int
    public var finalResultV2: AuthoringResultV2?
    public var finalResult: AuthoringResultV1?
    public var resultDigest: String?
    public var receipt: ApplicationReceiptV1?
    public var failure: String?
    public init(requestID: String, inputDigest: String, connectionID: String, profileID: String, hostKeySHA256: String, threadID: String? = nil, turnID: String? = nil, baseRevision: String? = nil, deadlineAt: Int64, status: LocalDeliveryStatus = .prepared, contractVersion: Int = 1, finalResultV2: AuthoringResultV2? = nil, finalResult: AuthoringResultV1? = nil, receipt: ApplicationReceiptV1? = nil, failure: String? = nil) {
        self.requestID = requestID; self.inputDigest = inputDigest; self.connectionID = connectionID
        self.profileID = profileID; self.hostKeySHA256 = hostKeySHA256; self.threadID = threadID; self.turnID = turnID
        self.baseRevision = baseRevision; self.deadlineAt = deadlineAt; self.status = status
        self.contractVersion = contractVersion; self.finalResultV2 = finalResultV2
        self.finalResult = finalResult; self.resultDigest = nil; self.receipt = receipt; self.failure = failure
    }
    private enum CodingKeys: String, CodingKey { case requestID, inputDigest, connectionID, profileID, hostKeySHA256, threadID, turnID, baseRevision, deadlineAt, status, contractVersion, finalResultV2, finalResult, resultDigest, receipt, failure }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decode(String.self, forKey: .requestID); inputDigest = try c.decode(String.self, forKey: .inputDigest)
        connectionID = try c.decode(String.self, forKey: .connectionID); profileID = try c.decode(String.self, forKey: .profileID)
        hostKeySHA256 = try c.decode(String.self, forKey: .hostKeySHA256); deadlineAt = try c.decode(Int64.self, forKey: .deadlineAt)
        status = try c.decode(LocalDeliveryStatus.self, forKey: .status)
        contractVersion = try c.decodeIfPresent(Int.self, forKey: .contractVersion) ?? 1
        guard [1, 2].contains(contractVersion) else { throw DecodingError.dataCorruptedError(forKey: .contractVersion, in: c, debugDescription: "Unsupported local contract version") }
        threadID = try c.decodeIfPresent(String.self, forKey: .threadID); turnID = try c.decodeIfPresent(String.self, forKey: .turnID)
        baseRevision = try c.decodeIfPresent(String.self, forKey: .baseRevision)
        finalResult = try c.decodeIfPresent(AuthoringResultV1.self, forKey: .finalResult)
        finalResultV2 = try c.decodeIfPresent(AuthoringResultV2.self, forKey: .finalResultV2)
        guard contractVersion == 1 ? finalResultV2 == nil : finalResult == nil else { throw DecodingError.dataCorruptedError(forKey: .contractVersion, in: c, debugDescription: "Mixed local result versions") }
        resultDigest = try c.decodeIfPresent(String.self, forKey: .resultDigest); receipt = try c.decodeIfPresent(ApplicationReceiptV1.self, forKey: .receipt)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
    }
}
/// Persistent request bindings and cancellation tombstones. Never authorizes resubmission after uncertain acceptance.
public final class LocalDeliveryLedger: @unchecked Sendable {
    private struct State: Codable { var records: [String: LocalDeliveryRecord] = [:] }
    private let lock = NSRecursiveLock()
    private let file: LocalDurableFile<State>
    public init(rootDirectory: URL? = nil) throws { file = try .init(kind: "delivery", rootDirectory: rootDirectory) }
    public func record(requestID: String) throws -> LocalDeliveryRecord? { try lock.locallyLocked { try file.load()?.records[requestID] } }
    public func records() throws -> [LocalDeliveryRecord] { try lock.locallyLocked { Array((try file.load() ?? .init()).records.values).sorted { $0.requestID < $1.requestID } } }
    public func unresolvedRecord() throws -> LocalDeliveryRecord? { try records().first { $0.status.blocksNewRequest } }
    public func prepare(_ record: LocalDeliveryRecord) throws {
        try lock.locallyLocked {
            var state = try file.load() ?? .init()
            guard !record.requestID.isEmpty, !record.inputDigest.isEmpty, !record.connectionID.isEmpty, !record.profileID.isEmpty, !record.hostKeySHA256.isEmpty, record.deadlineAt > 0,
                  [1, 2].contains(record.contractVersion), record.finalResultV2 == nil, record.status == .prepared, record.threadID?.isEmpty != true, record.turnID == nil, record.finalResult == nil, record.receipt == nil else { throw LocalPersistenceError.invalid("Prepare a complete immutable delivery binding before submitting.") }
            if let old = state.records[record.requestID] {
                guard sameBinding(old, record), old.threadID == nil || record.threadID == nil || old.threadID == record.threadID else { throw LocalPersistenceError.conflict("This request ID is already bound to a different local delivery.") }
                return
            }
            guard !state.records.values.contains(where: { $0.status.blocksNewRequest }) else { throw LocalPersistenceError.conflict("Resolve the outstanding local request first.") }
            state.records[record.requestID] = record; try file.save(state)
        }
    }
    public func update(_ proposed: LocalDeliveryRecord) throws {
        try lock.locallyLocked {
            var state = try file.load() ?? .init()
            guard let old = state.records[proposed.requestID] else { throw LocalPersistenceError.invalid("Prepare the local request before updating delivery.") }
            guard sameBinding(old, proposed), old.threadID == nil || old.threadID == proposed.threadID, old.turnID == nil || old.turnID == proposed.turnID,
                  proposed.turnID == nil || proposed.threadID != nil, proposed.threadID?.isEmpty != true, proposed.turnID?.isEmpty != true else { throw LocalPersistenceError.conflict("The immutable local request binding changed.") }
            var next = proposed
            guard canTransition(old.status, next.status) else { throw LocalPersistenceError.conflict("This local delivery cannot return to an earlier state or accept a late result.") }
            guard next.contractVersion == 1 ? next.finalResultV2 == nil : next.finalResult == nil else { throw LocalPersistenceError.conflict("The result contract version changed.") }
            if let result = next.finalResultV2 {
                guard [.completed, .applied, .conflict, .rejected].contains(next.status), result.requestID == next.requestID, result.inputDigest == next.inputDigest, result.baseRevision == next.baseRevision else { throw LocalPersistenceError.conflict("The local v2 result does not match its immutable request.") }
                let data = try AuthoringContract.encodedCanonical(result)
                guard data.count <= AuthoringContract.resultBytes else { throw LocalPersistenceError.invalid("The local result exceeds the source retention limit.") }
                let digest = AuthoringContract.contentDigest(data)
                guard old.resultDigest == nil || old.resultDigest == digest else { throw LocalPersistenceError.conflict("The local result changed after completion.") }
                next.resultDigest = digest
            } else if old.finalResultV2 != nil && !old.status.isTerminal { throw LocalPersistenceError.conflict("The completed v2 result must remain available until application.") }
            if let result = next.finalResult {
                guard [.completed, .applied, .conflict, .rejected].contains(next.status), result.requestID == next.requestID, result.inputDigest == next.inputDigest, result.baseRevision == next.baseRevision else { throw LocalPersistenceError.conflict("The local result does not match its immutable request.") }
                let resultData = try AuthoringContract.encodedCanonical(result)
                guard resultData.count <= AuthoringContract.resultBytes else { throw LocalPersistenceError.invalid("The local result exceeds the source retention limit.") }
                let digest = AuthoringContract.contentDigest(resultData)
                guard old.resultDigest == nil || old.resultDigest == digest else { throw LocalPersistenceError.conflict("The local result changed after completion.") }
                next.resultDigest = digest
            } else if next.finalResultV2 == nil {
                guard old.finalResult == nil || old.status.isTerminal else { throw LocalPersistenceError.conflict("The completed result must remain available until application.") }
                guard next.resultDigest == nil || next.resultDigest == old.resultDigest else { throw LocalPersistenceError.conflict("The retained local result digest changed.") }
                next.resultDigest = old.resultDigest
            }
            if let receipt = next.receipt {
                guard [.applied, .conflict, .rejected].contains(next.status), receipt.requestID == next.requestID, receipt.inputDigest == next.inputDigest,
                      receipt.status == next.status.rawValue, next.finalResult?.operationID == receipt.operationID || next.finalResultV2?.operationID == receipt.operationID || old.receipt?.operationID == receipt.operationID else { throw LocalPersistenceError.conflict("The local application receipt does not match this delivery.") }
            }
            guard old.receipt == nil || old.receipt == next.receipt else { throw LocalPersistenceError.conflict("The local receipt is immutable.") }
            if old.status.isTerminal {
                guard old == next else { throw LocalPersistenceError.conflict("This local delivery has already ended.") }
                return
            }
            if let failure = next.failure { next.failure = String(failure.prefix(2048)) }
            state.records[next.requestID] = next; try file.save(state)
        }
    }
    public func cancel(requestID: String) throws { try end(requestID: requestID, status: .cancelled, reason: "Cancelled on this device.") }
    public func expire(requestID: String, now: Int64) throws {
        try lock.locallyLocked {
            guard let record = try record(requestID: requestID), now >= record.deadlineAt else { return }
            try end(requestID: requestID, status: .timedOut, reason: "The local request deadline passed.")
        }
    }
    public func blockOutstanding(configurationID: String, reason: String) throws {
        try lock.locallyLocked {
            for record in try records() where record.connectionID == configurationID && !record.status.isTerminal {
                try end(requestID: record.requestID, status: .cancelled, reason: reason)
            }
        }
    }
    private func end(requestID: String, status: LocalDeliveryStatus, reason: String) throws {
        try lock.locallyLocked {
            guard var record = try record(requestID: requestID) else { throw LocalPersistenceError.invalid("The local delivery is missing.") }
            guard !record.status.isTerminal else { return }
            record.status = status; record.failure = reason; record.finalResult = nil; record.finalResultV2 = nil
            // A cancellation tombstone deliberately discards a transport-only result.
            var state = try file.load() ?? .init(); state.records[requestID] = record; try file.save(state)
        }
    }
    public func compactSources() throws {
        try lock.locallyLocked {
            var state = try file.load() ?? .init()
            let old = state.records.values.filter { $0.status.isTerminal && ($0.finalResult != nil || $0.finalResultV2 != nil) }.sorted { $0.deadlineAt > $1.deadlineAt }.dropFirst(32)
            for record in old { state.records[record.requestID]?.finalResult = nil; state.records[record.requestID]?.finalResultV2 = nil }
            try file.save(state)
        }
    }
    private func sameBinding(_ a: LocalDeliveryRecord, _ b: LocalDeliveryRecord) -> Bool {
        a.contractVersion == b.contractVersion && a.requestID == b.requestID && a.inputDigest == b.inputDigest && a.connectionID == b.connectionID && a.profileID == b.profileID && a.hostKeySHA256 == b.hostKeySHA256 && a.baseRevision == b.baseRevision && a.deadlineAt == b.deadlineAt
    }
    private func canTransition(_ old: LocalDeliveryStatus, _ next: LocalDeliveryStatus) -> Bool {
        if old == next { return true }; if old.isTerminal { return false }
        if [.cancelled, .timedOut, .failed, .rejected].contains(next) { return true }
        switch old {
        case .prepared: return [.submitting, .needsAttention].contains(next)
        case .submitting: return [.running, .deliveryUncertain, .needsAttention, .completed].contains(next)
        case .running: return [.deliveryUncertain, .needsAttention, .completed].contains(next)
        case .deliveryUncertain: return [.running, .needsAttention, .completed].contains(next)
        case .needsAttention: return [.running, .deliveryUncertain, .completed].contains(next)
        case .completed: return [.applied, .conflict].contains(next)
        default: return false
        }
    }
}
