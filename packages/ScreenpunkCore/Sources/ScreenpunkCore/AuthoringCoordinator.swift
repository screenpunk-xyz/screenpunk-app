import Foundation

/// Delivery progress is independent of the device's durable application receipt.
public struct AuthoringProgress: Codable, Equatable {
    public var status: String
    public var caption: String?
    public var updatedAt: Double?
    public var deadlineAt: Double?

    public init(status: String, caption: String? = nil, updatedAt: Double? = nil, deadlineAt: Double? = nil) {
        self.status = status; self.caption = caption; self.updatedAt = updatedAt; self.deadlineAt = deadlineAt
    }
}

public enum AuthoringDeliveryState: Equatable {
    case pending(AuthoringProgress)
    case completed(AuthoringResultV1)
    case ended(status: String, message: String?)
    /// Acceptance could not be established. Do not consume or automatically replay.
    case deliveryUncertain(message: String)
    /// An unsupported approval/input interaction needs explicit attention on the Mac.
    case needsAttention(message: String)
}

/// A transport produces complete results. It never installs screens or grants permissions.
@MainActor public protocol AuthoringTransport {
    func readiness() async throws -> Bool
    func submit(_ request: AuthoringRequestV1) async throws -> AuthoringRequestV1
    func progress(requestID: String) async throws -> AuthoringProgress
    func reconcile(requestID: String) async throws -> AuthoringDeliveryState
    func cancel(requestID: String) async throws
    func acknowledge(_ receipt: ApplicationReceiptV1) async throws
}

public enum AuthoringCoordinationError: Error, LocalizedError {
    case changedSnapshot
    case unknownRequest
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .changedSnapshot: return "The delivery service changed this request's immutable snapshot."
        case .unknownRequest: return "This authoring request is unavailable."
        case .cancelled: return "This authoring request was cancelled."
        }
    }
}

/// Both Cloud and fixture delivery cross the same persistence boundary. The supplied
/// closures must commit before returning; acknowledgement runs only after that commit.
@MainActor public final class AuthoringCoordinator {
    private let transport: any AuthoringTransport
    private let persistRequest: (AuthoringRequestV1) throws -> Void
    private let applyResult: (AuthoringResultV1) throws -> ApplicationReceiptV1
    private let persistCancellation: (String) throws -> Void
    private let acknowledged: (ApplicationReceiptV1) throws -> Void

    public init(transport: any AuthoringTransport,
                persistRequest: @escaping (AuthoringRequestV1) throws -> Void,
                applyResult: @escaping (AuthoringResultV1) throws -> ApplicationReceiptV1,
                persistCancellation: @escaping (String) throws -> Void,
                acknowledged: @escaping (ApplicationReceiptV1) throws -> Void) {
        self.transport = transport; self.persistRequest = persistRequest
        self.applyResult = applyResult; self.persistCancellation = persistCancellation
        self.acknowledged = acknowledged
    }

    public func readiness() async throws -> Bool { try await transport.readiness() }

    public func submit(_ request: AuthoringRequestV1) async throws -> AuthoringRequestV1 {
        _ = try AuthoringContract.validateRequest(JSONEncoder().encode(request))
        try persistRequest(request)
        let accepted = try await transport.submit(request)
        _ = try AuthoringContract.validateRequest(JSONEncoder().encode(accepted))
        guard accepted.requestID == request.requestID,
              accepted.delivery.snapshotDigest == request.delivery.snapshotDigest else {
            throw AuthoringCoordinationError.changedSnapshot
        }
        // The identical binding is persisted again intentionally: storage provides
        // replay checks and the same method also handles recovery after response loss.
        try persistRequest(accepted)
        return accepted
    }

    public func progress(requestID: String) async throws -> AuthoringProgress {
        try await transport.progress(requestID: requestID)
    }
    public func reconcile(requestID: String) async throws -> AuthoringDeliveryState {
        try await transport.reconcile(requestID: requestID)
    }
    public func apply(_ result: AuthoringResultV1) throws -> ApplicationReceiptV1 {
        try applyResult(result)
    }
    public func cancel(requestID: String) async throws {
        try persistCancellation(requestID)
        try await transport.cancel(requestID: requestID)
    }
    public func acknowledge(_ receipt: ApplicationReceiptV1) async throws {
        try await transport.acknowledge(receipt)
        try acknowledged(receipt)
    }
}

/// Phase 1's local seam. Synthetic fixtures use exactly the same contract validation,
/// coordinator, and durable application closures as Cloud, without a network client.
@MainActor public final class FixtureAuthoringTransport: AuthoringTransport {
    public typealias Produce = (AuthoringRequestV1) throws -> AuthoringResultV1
    private let produce: Produce
    private var requests: [String: AuthoringRequestV1] = [:]
    private var results: [String: AuthoringResultV1] = [:]
    private var cancelled: Set<String> = []
    public private(set) var receipts: [String: ApplicationReceiptV1] = [:]
    public private(set) var productionCount = 0

    public init(produce: @escaping Produce) { self.produce = produce }
    public func readiness() async throws -> Bool { true }
    public func submit(_ request: AuthoringRequestV1) async throws -> AuthoringRequestV1 {
        _ = try AuthoringContract.validateRequest(JSONEncoder().encode(request))
        if let previous = requests[request.requestID] {
            guard previous.delivery.snapshotDigest == request.delivery.snapshotDigest else {
                throw AuthoringCoordinationError.changedSnapshot
            }
            return previous
        }
        guard !cancelled.contains(request.requestID) else { throw AuthoringCoordinationError.cancelled }
        let result = try produce(request)
        _ = try AuthoringContract.validateResult(JSONEncoder().encode(result), request: request)
        requests[request.requestID] = request; results[request.requestID] = result
        productionCount += 1
        return request
    }
    public func progress(requestID: String) async throws -> AuthoringProgress {
        guard requests[requestID] != nil else { throw AuthoringCoordinationError.unknownRequest }
        return AuthoringProgress(status: cancelled.contains(requestID) ? "cancelled" : "completed")
    }
    public func reconcile(requestID: String) async throws -> AuthoringDeliveryState {
        if cancelled.contains(requestID) { return .ended(status: "cancelled", message: nil) }
        guard let result = results[requestID] else { throw AuthoringCoordinationError.unknownRequest }
        return .completed(result)
    }
    public func cancel(requestID: String) async throws { cancelled.insert(requestID) }
    public func acknowledge(_ receipt: ApplicationReceiptV1) async throws {
        guard let request = requests[receipt.requestID], let result = results[receipt.requestID],
              request.delivery.snapshotDigest == receipt.inputDigest,
              result.operationID == receipt.operationID else { throw AuthoringCoordinationError.unknownRequest }
        if let previous = receipts[receipt.requestID], previous != receipt {
            throw AuthoringCoordinationError.changedSnapshot
        }
        receipts[receipt.requestID] = receipt
    }
}
