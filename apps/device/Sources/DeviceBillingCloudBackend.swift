import Foundation

@MainActor
struct DeviceBillingBackend {
    private static let path = "api/device/billing"
    private let journal = DeviceBillingOperationJournal()

    enum Delivery { case pending, reviewRequired, rejected, fulfilled }
    private enum Failure: Error { case invalidResponse }

    func read(cloud: CloudClient, authorization: String) async throws -> DeviceBillingSnapshot {
        let value: DeviceBillingStatusResponse = try await cloud.call(Self.path, authorizationToken: authorization)
        guard value.schema_version == 1 else { throw Failure.invalidResponse }
        let apple: DeviceBillingSnapshot.Apple?
        if let customer = value.customer, let catalog = value.knownCatalog {
            apple = .init(accountToken: customer.app_account_token,
                          proAnnualProductID: catalog.pro_annual_product_id,
                          credits1000ProductID: catalog.credits_1000_product_id)
        } else {
            apple = nil
        }
        let financial: DeviceBillingFinancial?
        if value.ready, let entitlements = value.entitlements, let balance = value.balance {
            financial = .init(proActive: entitlements.proActive, monthlyCredits: balance.included.available,
                              purchasedCredits: balance.purchased.available, version: balance.wallet_version)
        } else {
            financial = nil
        }
        return .init(financial: financial, apple: apple, salesEnabled: value.sales_enabled,
                     backupAccess: value.ready ? value.entitlements?.backupAccess(at: Date()) ?? .unknown : .unknown,
                     verificationAvailable: value.verification_available)
    }

    /// Replay an accepted operation at a discrete recovery trigger, or submit a new signed snapshot once.
    func submit(cloud: CloudClient, authorization: String, owner: String, proof: String, transactionID: String) async throws -> Delivery {
        let proofDigest = DeviceBillingOperationJournal.digest(proof)
        let result: DeviceBillingOperationResponse
        if let operationID = journal.operationID(owner: owner, transactionID: transactionID, proofDigest: proofDigest) {
            do {
                result = try await cloud.call("\(Self.path)/operations/\(operationID)", authorizationToken: authorization)
            } catch DeviceError.http(404, _) {
                // A later explicit trigger can replay this proof with the same idempotency key.
                journal.record(id: "", owner: owner, transactionID: transactionID, proofDigest: proofDigest)
                return .pending
            }
            guard result.operation.operation_id == operationID else { throw Failure.invalidResponse }
        } else {
            let key = "apple-" + DeviceBillingOperationJournal.digest(owner + "\u{0}" + proofDigest)
            result = try await cloud.call("\(Self.path)/apple/transactions", method: "POST",
                                          body: ["signed_transaction": proof], authorizationToken: authorization,
                                          idempotencyKey: key)
            guard result.schema_version == 1,
                  DeviceBillingOperationResponse.Operation.validID(result.operation.operation_id) else { throw Failure.invalidResponse }
            journal.record(id: result.operation.operation_id, owner: owner, transactionID: transactionID, proofDigest: proofDigest)
        }
        guard result.schema_version == 1 else { throw Failure.invalidResponse }
        if result.operation.safeToFinish { return .fulfilled }
        switch result.operation.status {
        case .pending, .fulfilled: return .pending
        case .verified_unbound, .review_required: return .reviewRequired
        case .rejected: return .rejected
        }
    }

    func tracks(owner: String, transactionID: String, operationID: String? = nil) -> Bool {
        journal.contains(owner: owner, transactionID: transactionID, operationID: operationID)
    }

    func clear(owner: String, transactionID: String, proof: String) {
        journal.clear(owner: owner, transactionID: transactionID, proofDigest: DeviceBillingOperationJournal.digest(proof))
    }
}
