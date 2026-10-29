import Foundation

public enum AuthoringDeliveryStateV2: Equatable {
    case pending(AuthoringProgress)
    case completed(AuthoringResultV2)
    case ended(status: String, message: String?)
    case deliveryUncertain(message: String)
    case needsAttention(message: String)
}
/// Both routes retain v2 semantics. A result is never an installation receipt.
@MainActor public protocol AuthoringTransportV2 {
    func readiness() async throws -> Bool
    func submit(_ request: AuthoringRequestV2) async throws -> AuthoringRequestV2
    func progress(requestID: String) async throws -> AuthoringProgress
    func reconcile(requestID: String) async throws -> AuthoringDeliveryStateV2
    func cancel(requestID: String) async throws
    func acknowledge(_ receipt: ApplicationReceiptV1) async throws
}
@MainActor public final class AuthoringCoordinatorV2 {
    private let transport: any AuthoringTransportV2
    private let persistRequest: (AuthoringRequestV2) throws -> Void
    private let applyResult: (AuthoringResultV2) throws -> ApplicationReceiptV1
    private let persistCancellation: (String) throws -> Void
    private let acknowledged: (ApplicationReceiptV1) throws -> Void
    /// persistRequest must atomically pin referenced revisions and save the sealed snapshot.
    /// Cancellation/application closures durably tombstone or receipt before releasing pins.
    public init(transport: any AuthoringTransportV2, persistRequest: @escaping (AuthoringRequestV2) throws -> Void, applyResult: @escaping (AuthoringResultV2) throws -> ApplicationReceiptV1, persistCancellation: @escaping (String) throws -> Void, acknowledged: @escaping (ApplicationReceiptV1) throws -> Void) {
        self.transport = transport; self.persistRequest = persistRequest; self.applyResult = applyResult; self.persistCancellation = persistCancellation; self.acknowledged = acknowledged
    }
    public func readiness() async throws -> Bool { try await transport.readiness() }
    public func submit(_ request: AuthoringRequestV2) async throws -> AuthoringRequestV2 {
        _ = try AuthoringV2Contract.validateRequest(JSONEncoder().encode(request))
        try persistRequest(request)
        let accepted = try await transport.submit(request)
        _ = try AuthoringV2Contract.validateRequest(JSONEncoder().encode(accepted))
        guard accepted.requestID == request.requestID, accepted.delivery.snapshotDigest == request.delivery.snapshotDigest else { throw AuthoringCoordinationError.changedSnapshot }
        try persistRequest(accepted)
        return accepted
    }
    public func progress(requestID: String) async throws -> AuthoringProgress { try await transport.progress(requestID: requestID) }
    public func reconcile(requestID: String) async throws -> AuthoringDeliveryStateV2 { try await transport.reconcile(requestID: requestID) }
    public func apply(_ result: AuthoringResultV2) throws -> ApplicationReceiptV1 { try applyResult(result) }
    public func cancel(requestID: String) async throws { try persistCancellation(requestID); try await transport.cancel(requestID: requestID) }
    public func acknowledge(_ receipt: ApplicationReceiptV1) async throws { try await transport.acknowledge(receipt); try acknowledged(receipt) }
}
@MainActor public final class FixtureAuthoringTransportV2: AuthoringTransportV2 {
    public typealias Produce = (AuthoringRequestV2) throws -> AuthoringResultV2
    private let produce: Produce
    private var requests: [String: AuthoringRequestV2] = [:]
    private var results: [String: AuthoringResultV2] = [:]
    private var cancelled = Set<String>()
    public private(set) var receipts: [String: ApplicationReceiptV1] = [:]
    public private(set) var productionCount = 0
    public init(produce: @escaping Produce) { self.produce = produce }
    public func readiness() async throws -> Bool { true }
    public func submit(_ request: AuthoringRequestV2) async throws -> AuthoringRequestV2 {
        _ = try AuthoringV2Contract.validateRequest(JSONEncoder().encode(request))
        guard !cancelled.contains(request.requestID) else { throw AuthoringCoordinationError.cancelled }
        if let old = requests[request.requestID] { guard old.delivery.snapshotDigest == request.delivery.snapshotDigest else { throw AuthoringCoordinationError.changedSnapshot }; return old }
        let result = try produce(request); _ = try AuthoringV2Contract.validateResult(JSONEncoder().encode(result), request: request)
        requests[request.requestID] = request; results[request.requestID] = result; productionCount += 1
        return request
    }
    public func progress(requestID: String) async throws -> AuthoringProgress { guard requests[requestID] != nil else { throw AuthoringCoordinationError.unknownRequest }; return .init(status: cancelled.contains(requestID) ? "cancelled" : "completed") }
    public func reconcile(requestID: String) async throws -> AuthoringDeliveryStateV2 { if cancelled.contains(requestID) { return .ended(status: "cancelled", message: nil) }; guard let result = results[requestID] else { throw AuthoringCoordinationError.unknownRequest }; return .completed(result) }
    public func cancel(requestID: String) async throws { cancelled.insert(requestID) }
    public func acknowledge(_ receipt: ApplicationReceiptV1) async throws {
        _ = try AuthoringContract.validateApplicationReceipt(JSONEncoder().encode(receipt))
        guard let request = requests[receipt.requestID], let result = results[receipt.requestID], request.delivery.snapshotDigest == receipt.inputDigest, result.operationID == receipt.operationID else { throw AuthoringCoordinationError.unknownRequest }
        if let previous = receipts[receipt.requestID], previous != receipt { throw AuthoringCoordinationError.changedSnapshot }
        receipts[receipt.requestID] = receipt
    }
}
