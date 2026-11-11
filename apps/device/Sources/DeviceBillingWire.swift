import Foundation
import CryptoKit

import StoreKit

enum DeviceTestCheckout {
    @MainActor
    static func check(
        installedBundleID: String?,
        loadVerifiedApp: () async throws -> (environment: AppStore.Environment, bundleID: String),
        sessionIsCurrent: () -> Bool
    ) async -> Bool {
        let app = try? await loadVerifiedApp()
        return allows(verifiedEnvironment: app?.environment, verifiedBundleID: app?.bundleID,
                      installedBundleID: installedBundleID, sessionIsCurrent: sessionIsCurrent() && !Task.isCancelled)
    }

    static func allows(
        verifiedEnvironment: AppStore.Environment?,
        verifiedBundleID: String?,
        installedBundleID: String?,
        sessionIsCurrent: Bool
    ) -> Bool {
        guard sessionIsCurrent, verifiedEnvironment == .sandbox,
              let installedBundleID, !installedBundleID.isEmpty else { return false }
        return verifiedBundleID == installedBundleID
    }
}

struct DeviceBillingFinancial {
    let proActive: Bool
    let monthlyCredits: UInt64
    let purchasedCredits: UInt64
    let version: UInt64

    var showsCredits: Bool { proActive || purchasedCredits > 0 }
    var visibleMonthlyCredits: UInt64? { proActive ? monthlyCredits : nil }

    func allowsNewPurchase(_ kind: DeviceBillingPurchaseKind) -> Bool {
        switch kind {
        case .proAnnual: return !proActive
        case .credits1000: return proActive
        }
    }
}

enum DeviceBillingPurchaseKind: CaseIterable { case proAnnual, credits1000 }

/// Scoped by the owning billing session. Only an explicit annual checkout can arm it.
struct DeviceBackupUpgradeConsent {
    private var productID: String?
    private var startedAt: Date?
    private var transactionID: UInt64?
    private var checkoutTransactionID: UInt64?
    private var checkoutAccepted = false
    private var fulfilled = false
    private(set) var promptID: UUID?

    mutating func start(productID: String, at date: Date) {
        self = .init()
        self.productID = productID
        startedAt = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 * 1_000) / 1_000)
    }

    mutating func acceptCheckout(transactionID: UInt64? = nil) {
        guard startedAt != nil else { return }
        if let transactionID, transactionID != self.transactionID {
            self.transactionID = nil
            fulfilled = false
        }
        checkoutTransactionID = transactionID
        checkoutAccepted = true
    }

    mutating func abandonPurchase() {
        self = .init()
    }

    mutating func match(productID: String, transactionID: UInt64, purchasedAt: Date, isNewPurchase: Bool,
                        allowPinnedCheckout: Bool = false) {
        let isDirectCheckout = allowPinnedCheckout && checkoutTransactionID == transactionID
        guard self.transactionID == nil, checkoutTransactionID == nil || checkoutTransactionID == transactionID,
              productID == self.productID, isNewPurchase || isDirectCheckout,
              let startedAt, purchasedAt >= startedAt else { return }
        self.transactionID = transactionID
    }

    mutating func confirmFulfillment(transactionID: UInt64) {
        if transactionID == self.transactionID { fulfilled = true }
    }

    mutating func offerIfReady(hasProGrant: Bool, backupsEnabled: Bool) {
        if backupsEnabled { self = .init(); return }
        if checkoutAccepted, fulfilled, hasProGrant, promptID == nil { promptID = UUID() }
    }

    mutating func consume(_ id: UUID) -> Bool {
        guard promptID == id else { return false }
        self = .init()
        return true
    }
}

enum DeviceBackupAccess: Equatable {
    case unknown
    case inactive
    case active(until: Date)

    func current(at now: Date) -> Self {
        if case .active(let until) = self, until <= now { return .unknown }
        return self
    }

    var allowsBackups: Bool {
        if case .active = current(at: Date()) { return true }
        return false
    }

    static func isVerifiedDenial(enabled: Bool, reason: String) -> Bool {
        !enabled && reason == "pro_required"
    }

    static func isVerifiedDenial(status: Int, code: String) -> Bool {
        status == 403 && code == "not_entitled"
    }
}

struct DeviceBillingStatusResponse: Decodable {
    enum Availability: String, Decodable { case ready, unavailable }
    struct Customer: Decodable { let app_account_token: UUID }
    struct Catalog: Decodable {
        let pro_annual_product_id: String
        let credits_1000_product_id: String
    }
    struct Entitlements: Decodable {
        struct Feature: Decodable {
            let key: String
            let tier: String?
            let valid_from: String?
            let valid_until: String?
        }
        let customer_id: String
        let wallet_version: UInt64
        let entitlements: [Feature]

        var proActive: Bool {
            entitlements.contains { $0.tier == "pro" && Self.proFeatures.contains($0.key) }
        }
        private static let proFeatures = ["screenpunk_cloud_devices_over_three", "screenpunk_cloud_backups"]

        func backupAccess(at now: Date) -> DeviceBackupAccess {
            let grants = entitlements.filter { $0.key == "screenpunk_cloud_backups" }
            var activeUntil: Date?
            var malformed = false
            for grant in grants {
                guard grant.tier == "pro", let from = Self.utcDate(grant.valid_from),
                      let until = Self.utcDate(grant.valid_until), from < until else {
                    malformed = true
                    continue
                }
                if from <= now, now < until { activeUntil = max(activeUntil ?? until, until) }
            }
            if let activeUntil { return .active(until: activeUntil) }
            return malformed ? .unknown : .inactive
        }

        private static func utcDate(_ value: String?) -> Date? {
            guard let value, value.hasSuffix("Z") else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }
    }
    struct Balance: Decodable {
        struct Bucket: Decodable {
            let available: UInt64
            enum CodingKeys: String, CodingKey { case available }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let decimal = try container.decode(String.self, forKey: .available)
                guard let units = UInt64(decimal), units <= 9_007_199_254_740_991, String(units) == decimal else {
                    throw DecodingError.dataCorruptedError(forKey: .available, in: container, debugDescription: "Invalid credit units")
                }
                available = units
            }
        }
        let customer_id: String
        let wallet_version: UInt64
        let included: Bucket
        let purchased: Bucket
    }

    let schema_version: Int
    let availability: Availability
    let sales_enabled: Bool
    let verification_available: Bool
    let customer: Customer?
    let catalog: Catalog?
    let entitlements: Entitlements?
    let balance: Balance?

    var ready: Bool {
        schema_version == 1 && availability == .ready && customer != nil && knownCatalog != nil
            && entitlements != nil && entitlements?.customer_id == balance?.customer_id
            && entitlements?.wallet_version == balance?.wallet_version
    }

    var knownCatalog: Catalog? {
        guard schema_version == 1, let catalog,
              !catalog.pro_annual_product_id.isEmpty, !catalog.credits_1000_product_id.isEmpty,
              catalog.pro_annual_product_id != catalog.credits_1000_product_id else { return nil }
        return catalog
    }
}

struct DeviceBillingOperationResponse: Decodable {
    struct Operation: Decodable {
        enum Status: String, Decodable { case pending, verified_unbound, fulfilled, rejected, review_required }
        let operation_id: String
        let status: Status
        let safe_to_finish: Bool

        var safeToFinish: Bool { status == .fulfilled && safe_to_finish }
        static func validID(_ id: String) -> Bool {
            id.range(of: "\\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,159}\\z", options: .regularExpression) != nil
        }
    }
    let schema_version: Int
    let operation: Operation
}

struct DeviceBillingUpdateNotice: Decodable {
    let type: String
    let schema_version: Int
    let event_id: String
    let operation_id: String

    static func decode(_ data: Data) -> Self? {
        guard data.count <= 4096, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.type == "billing.updated", value.schema_version == 1,
              DeviceBillingOperationResponse.Operation.validID(value.event_id),
              DeviceBillingOperationResponse.Operation.validID(value.operation_id) else { return nil }
        return value
    }
}

struct DeviceBillingOperationJournal {
    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }

    private func key(owner: String, transactionID: String) -> String {
        "screenpunk.billing.operation.v1." + Self.digest(owner + "\u{0}" + transactionID)
    }

    static func digest(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func operationID(owner: String, transactionID: String, proofDigest: String) -> String? {
        guard let record = preferences.dictionary(forKey: key(owner: owner, transactionID: transactionID)),
              let id = record[proofDigest] as? String,
              DeviceBillingOperationResponse.Operation.validID(id) else { return nil }
        return id
    }

    func contains(owner: String, transactionID: String, operationID: String? = nil) -> Bool {
        guard let record = preferences.dictionary(forKey: key(owner: owner, transactionID: transactionID)) else { return false }
        return operationID.map { id in record.values.contains { ($0 as? String) == id } } ?? true
    }

    func record(id: String, owner: String, transactionID: String, proofDigest: String) {
        let key = key(owner: owner, transactionID: transactionID)
        var record = preferences.dictionary(forKey: key) ?? [:]
        record[proofDigest] = id
        preferences.set(record, forKey: key)
    }

    func clear(owner: String, transactionID: String, proofDigest: String) {
        let key = key(owner: owner, transactionID: transactionID)
        guard var record = preferences.dictionary(forKey: key), record.removeValue(forKey: proofDigest) != nil else { return }
        if record.isEmpty { preferences.removeObject(forKey: key) }
        else { preferences.set(record, forKey: key) }
    }
}
