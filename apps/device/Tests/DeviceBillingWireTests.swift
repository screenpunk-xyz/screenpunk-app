import Foundation
import StoreKit
import XCTest
@testable import DeviceAuthoring

final class DeviceBillingWireTests: XCTestCase {

    func testTestCheckoutRequiresVerifiedSandboxForThisBundleAndCurrentSession() {
        let bundleID = "xyz.screenpunk.ios"
        XCTAssertTrue(DeviceTestCheckout.allows(verifiedEnvironment: .sandbox, verifiedBundleID: bundleID,
                                                installedBundleID: bundleID, sessionIsCurrent: true))
        for environment in [AppStore.Environment.production, .xcode] {
            XCTAssertFalse(DeviceTestCheckout.allows(verifiedEnvironment: environment, verifiedBundleID: bundleID,
                                                     installedBundleID: bundleID, sessionIsCurrent: true))
        }
        // A failed or unverified AppTransaction provides no trusted environment or bundle ID.
        XCTAssertFalse(DeviceTestCheckout.allows(verifiedEnvironment: nil, verifiedBundleID: nil,
                                                 installedBundleID: bundleID, sessionIsCurrent: true))
        XCTAssertFalse(DeviceTestCheckout.allows(verifiedEnvironment: .sandbox, verifiedBundleID: "xyz.other",
                                                 installedBundleID: bundleID, sessionIsCurrent: true))
        XCTAssertFalse(DeviceTestCheckout.allows(verifiedEnvironment: .sandbox, verifiedBundleID: bundleID,
                                                 installedBundleID: nil, sessionIsCurrent: true))
        XCTAssertFalse(DeviceTestCheckout.allows(verifiedEnvironment: .sandbox, verifiedBundleID: bundleID,
                                                 installedBundleID: bundleID, sessionIsCurrent: false))
    }
    @MainActor func testTestCheckoutChecksSessionAfterAppVerificationSuspends() async {
        let bundleID = "xyz.screenpunk.ios"
        var currentSession = true
        let authorized = await DeviceTestCheckout.check(
            installedBundleID: bundleID,
            loadVerifiedApp: {
                await Task.yield()
                currentSession = false
                return (.sandbox, bundleID)
            },
            sessionIsCurrent: { currentSession }
        )
        XCTAssertFalse(authorized)
    }

    @MainActor func testTestCheckoutRejectsThrowingAndCancelledAppVerification() async {
        struct VerificationUnavailable: Error {}
        let bundleID = "xyz.screenpunk.ios"
        let unavailable = await DeviceTestCheckout.check(
            installedBundleID: bundleID, loadVerifiedApp: { throw VerificationUnavailable() },
            sessionIsCurrent: { true }
        )
        XCTAssertFalse(unavailable)

        let cancelled = await Task { @MainActor in
            await DeviceTestCheckout.check(
                installedBundleID: bundleID,
                loadVerifiedApp: {
                    await Task.yield()
                    withUnsafeCurrentTask { $0?.cancel() }
                    return (.sandbox, bundleID)
                },
                sessionIsCurrent: { true }
            )
        }.value
        XCTAssertFalse(cancelled)
    }

    func testCreditsPanelAndNewPurchasePolicyFollowVerifiedPlan() {
        let emptyFree = DeviceBillingFinancial(proActive: false, monthlyCredits: 0, purchasedCredits: 0, version: 1)
        XCTAssertFalse(emptyFree.showsCredits)
        XCTAssertTrue(emptyFree.allowsNewPurchase(.proAnnual))
        XCTAssertFalse(emptyFree.allowsNewPurchase(.credits1000))

        let freeWithCredits = DeviceBillingFinancial(proActive: false, monthlyCredits: 0, purchasedCredits: 37, version: 2)
        XCTAssertTrue(freeWithCredits.showsCredits)
        XCTAssertNil(freeWithCredits.visibleMonthlyCredits)
        XCTAssertEqual(freeWithCredits.purchasedCredits, 37)
        XCTAssertFalse(freeWithCredits.allowsNewPurchase(.credits1000))

        let pro = DeviceBillingFinancial(proActive: true, monthlyCredits: 0, purchasedCredits: 0, version: 3)
        XCTAssertTrue(pro.showsCredits)
        XCTAssertEqual(pro.visibleMonthlyCredits, 0)
        XCTAssertFalse(pro.allowsNewPurchase(.proAnnual))
        XCTAssertTrue(pro.allowsNewPurchase(.credits1000))
    }

    private let customer = "{\"app_account_token\":\"6E715884-53C9-4F1B-84F0-DF4713A47B17\"}"
    private let catalog = "{\"pro_annual_product_id\":\"test.pro\",\"credits_1000_product_id\":\"test.credits\"}"

    private func status(availability: String = "ready", sales: Bool = true, verification: Bool = true,
                        entitlements: String = "{\"customer_id\":\"c\",\"wallet_version\":3,\"entitlements\":[]}",
                        balance: String = "{\"customer_id\":\"c\",\"wallet_version\":3,\"included\":{\"available\":\"0\"},\"purchased\":{\"available\":\"120\"}}") throws -> DeviceBillingStatusResponse {
        try JSONDecoder().decode(DeviceBillingStatusResponse.self, from: Data("""
        {"schema_version":1,"availability":"\(availability)","sales_enabled":\(sales),"verification_available":\(verification),"customer":\(customer),"catalog":\(catalog),"entitlements":\(entitlements),"balance":\(balance)}
        """.utf8))
    }

    func testFreeAccountUsesActualZeroAllowanceAndExistingPurchasedBalance() throws {
        let value = try status()
        XCTAssertTrue(value.ready)
        XCTAssertEqual(value.entitlements?.proActive, false)
        XCTAssertEqual(value.balance?.included.available, 0)
        XCTAssertEqual(value.balance?.purchased.available, 120)
    }

    func testBackupAccessUsesExactActiveGrantAndDistinguishesUnknown() throws {
        let formatter = ISO8601DateFormatter()
        let from = try XCTUnwrap(formatter.date(from: "2026-11-01T00:00:00Z"))
        let until = try XCTUnwrap(formatter.date(from: "2026-11-08T00:00:00Z"))
        func access(key: String = "screenpunk_cloud_backups", end: String = "2026-11-08T00:00:00.000Z",
                    at date: Date) throws -> DeviceBackupAccess? {
            let response = """
            {"customer_id":"c","wallet_version":3,"entitlements":[{"key":"\(key)","tier":"pro","valid_from":"2026-11-01T00:00:00.000Z","valid_until":"\(end)"}]}
            """
            return try status(entitlements: response).entitlements?.backupAccess(at: date)
        }

        XCTAssertEqual(try access(at: from.addingTimeInterval(-1)), .inactive)
        XCTAssertEqual(try access(at: from), .active(until: until))
        XCTAssertEqual(try access(at: until.addingTimeInterval(-1)), .active(until: until))
        XCTAssertEqual(try access(at: until), .inactive)
        XCTAssertEqual(try access(key: "screenpunk_cloud_devices_over_three", at: from), .inactive)
        XCTAssertEqual(try access(end: "malformed", at: from), .unknown)
        XCTAssertEqual(DeviceBackupAccess.active(until: until).current(at: until), .unknown)
        XCTAssertEqual(DeviceBackupAccess.inactive.current(at: until), .inactive)
    }

    func testOnlyAuthoritativeBackupDenialsDisableConsent() {
        XCTAssertTrue(DeviceBackupAccess.isVerifiedDenial(enabled: false, reason: "pro_required"))
        XCTAssertFalse(DeviceBackupAccess.isVerifiedDenial(enabled: true, reason: "pro_required"))
        XCTAssertFalse(DeviceBackupAccess.isVerifiedDenial(enabled: false, reason: "billing_unavailable"))
        XCTAssertFalse(DeviceBackupAccess.isVerifiedDenial(enabled: false, reason: "storage_unavailable"))
        XCTAssertTrue(DeviceBackupAccess.isVerifiedDenial(status: 403, code: "not_entitled"))
        XCTAssertFalse(DeviceBackupAccess.isVerifiedDenial(status: 503, code: "offline"))
        XCTAssertFalse(DeviceBackupAccess.isVerifiedDenial(status: 403, code: "unauthorized"))
    }

    func testBackupPromptRequiresExplicitMatchingProPurchaseAndVerifiedGrant() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var consent = DeviceBackupUpgradeConsent()
        consent.match(productID: "annual", transactionID: 1, purchasedAt: now, isNewPurchase: true)
        consent.confirmFulfillment(transactionID: 1)
        consent.offerIfReady(hasProGrant: true, backupsEnabled: false)
        XCTAssertNil(consent.promptID)

        consent.start(productID: "annual", at: now)
        consent.match(productID: "annual", transactionID: 2, purchasedAt: now.addingTimeInterval(-1), isNewPurchase: true)
        consent.match(productID: "credits", transactionID: 3, purchasedAt: now, isNewPurchase: true)
        consent.match(productID: "annual", transactionID: 4, purchasedAt: now, isNewPurchase: false)
        consent.confirmFulfillment(transactionID: 4)
        consent.acceptCheckout()
        consent.offerIfReady(hasProGrant: true, backupsEnabled: false)
        XCTAssertNil(consent.promptID)

        consent.match(productID: "annual", transactionID: 5, purchasedAt: now, isNewPurchase: true)
        consent.confirmFulfillment(transactionID: 5)
        consent.offerIfReady(hasProGrant: false, backupsEnabled: false)
        XCTAssertNil(consent.promptID)
        consent.offerIfReady(hasProGrant: true, backupsEnabled: false)
        let prompt = try XCTUnwrap(consent.promptID)
        consent.confirmFulfillment(transactionID: 5)
        consent.offerIfReady(hasProGrant: true, backupsEnabled: false)
        XCTAssertEqual(consent.promptID, prompt)
        XCTAssertFalse(consent.consume(UUID()))
        XCTAssertTrue(consent.consume(prompt))
        consent.confirmFulfillment(transactionID: 5)
        consent.offerIfReady(hasProGrant: true, backupsEnabled: false)
        XCTAssertNil(consent.promptID)
    }

    func testBackupPromptWaitsForCheckoutAndDiscardsCancelledOrSupersededMatch() {
        let now = Date(timeIntervalSince1970: 1000)
        var consent = DeviceBackupUpgradeConsent()
        consent.start(productID: "annual", at: now)
        consent.match(productID: "annual", transactionID: 1, purchasedAt: now, isNewPurchase: true)
        consent.confirmFulfillment(transactionID: 1)
        consent.offerIfReady(hasProGrant: true, backupsEnabled: false)
        XCTAssertNil(consent.promptID)
        consent.abandonPurchase()
        consent.acceptCheckout()
        consent.offerIfReady(hasProGrant: true, backupsEnabled: false)
        XCTAssertNil(consent.promptID)

        consent.start(productID: "annual", at: now)
        consent.match(productID: "annual", transactionID: 1, purchasedAt: now, isNewPurchase: true)
        consent.confirmFulfillment(transactionID: 1)
        consent.acceptCheckout(transactionID: 2)
        consent.offerIfReady(hasProGrant: true, backupsEnabled: false)
        XCTAssertNil(consent.promptID)
        consent.match(productID: "annual", transactionID: 2, purchasedAt: now, isNewPurchase: true)
        consent.confirmFulfillment(transactionID: 2)
        consent.offerIfReady(hasProGrant: true, backupsEnabled: true)
        consent.offerIfReady(hasProGrant: true, backupsEnabled: false)
        XCTAssertNil(consent.promptID)
    }

    func testPinnedLegacyCheckoutCanMatchFreshResubscribeButNotAnOldOrDifferentPurchase() {
        let storeDate = Date(timeIntervalSince1970: 1000)
        var consent = DeviceBackupUpgradeConsent()
        consent.start(productID: "annual", at: storeDate.addingTimeInterval(0.0008))
        consent.acceptCheckout(transactionID: 2)
        consent.match(productID: "annual", transactionID: 2, purchasedAt: storeDate.addingTimeInterval(-0.001),
                      isNewPurchase: false, allowPinnedCheckout: true)
        consent.match(productID: "annual", transactionID: 1, purchasedAt: storeDate,
                      isNewPurchase: false, allowPinnedCheckout: true)
        consent.match(productID: "annual", transactionID: 2, purchasedAt: storeDate, isNewPurchase: false)
        consent.confirmFulfillment(transactionID: 1)
        consent.confirmFulfillment(transactionID: 2)
        consent.offerIfReady(hasProGrant: true, backupsEnabled: false)
        XCTAssertNil(consent.promptID)

        consent.match(productID: "annual", transactionID: 2, purchasedAt: storeDate,
                      isNewPurchase: false, allowPinnedCheckout: true)
        consent.confirmFulfillment(transactionID: 2)
        consent.offerIfReady(hasProGrant: true, backupsEnabled: false)
        XCTAssertNotNil(consent.promptID)
    }

    func testProAndWalletMustBeCoherentBeforeDisplayingFinancialState() throws {
        let entitlements = "{\"customer_id\":\"c\",\"wallet_version\":3,\"entitlements\":[{\"key\":\"screenpunk_cloud_backups\",\"tier\":\"pro\"}]}"
        XCTAssertEqual(try status(entitlements: entitlements).entitlements?.proActive, true)
        XCTAssertFalse(try status(entitlements: entitlements, balance: "{\"customer_id\":\"other\",\"wallet_version\":3,\"included\":{\"available\":\"0\"},\"purchased\":{\"available\":\"120\"}}").ready)
        XCTAssertFalse(try status(entitlements: entitlements, balance: "{\"customer_id\":\"c\",\"wallet_version\":4,\"included\":{\"available\":\"0\"},\"purchased\":{\"available\":\"120\"}}").ready)
    }

    func testMissingWalletStillCarriesVerificationCatalogWithoutInventingBalance() throws {
        let value = try status(availability: "unavailable", sales: false, entitlements: "null", balance: "null")
        XCTAssertFalse(value.ready)
        XCTAssertFalse(value.sales_enabled)
        XCTAssertTrue(value.verification_available)
        XCTAssertNotNil(value.customer)
        XCTAssertNotNil(value.knownCatalog)
        XCTAssertNil(value.balance)
    }

    func testMalformedCreditUnitsAreRejected() {
        for units in ["-1", "+1", "01", "9007199254740992", "1.0"] {
            XCTAssertThrowsError(try status(balance: "{\"customer_id\":\"c\",\"wallet_version\":3,\"included\":{\"available\":\"\(units)\"},\"purchased\":{\"available\":\"0\"}}"))
        }
    }

    func testFinishRequiresBothFulfillmentAndServerPermission() throws {
        for (status, flag, expected) in [("pending", true, false), ("review_required", true, false), ("fulfilled", false, false), ("fulfilled", true, true)] {
            let wire = "{\"schema_version\":1,\"operation\":{\"operation_id\":\"op_1\",\"status\":\"\(status)\",\"safe_to_finish\":\(flag)}}"
            let result = try JSONDecoder().decode(DeviceBillingOperationResponse.self, from: Data(wire.utf8))
            XCTAssertEqual(result.operation.safeToFinish, expected)
        }
        for id in ["../other", "other/id", "other?query=1", ".", "x\n"] {
            XCTAssertFalse(DeviceBillingOperationResponse.Operation.validID(id))
        }
    }

    func testBillingCompletionHintRequiresVersionAndScopedOperationShape() {
        func decode(_ event: String) -> DeviceBillingUpdateNotice? { DeviceBillingUpdateNotice.decode(Data(event.utf8)) }
        XCTAssertEqual(decode(#"{"type":"billing.updated","schema_version":1,"event_id":"event-1","operation_id":"op-1"}"#)?.operation_id, "op-1")
        XCTAssertNil(decode(#"{"type":"billing.updated","schema_version":2,"event_id":"event-1","operation_id":"op-1"}"#))
        XCTAssertNil(decode(#"{"type":"billing.updated","schema_version":1,"event_id":"event-1","operation_id":"../../op-1"}"#))
        XCTAssertNil(decode(#"{"type":"billing.updated","schema_version":1,"operation_id":"op-1"}"#))
    }

    func testPendingOperationJournalSeparatesAccountRealmAndSignedSnapshot() throws {
        let suite = "ScreenpunkBillingTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DeviceBillingOperationJournal.digest("signed transaction")
        let updated = DeviceBillingOperationJournal.digest("updated signed transaction")
        let journal = DeviceBillingOperationJournal(preferences: defaults)
        journal.record(id: "op_1", owner: "A-staging", transactionID: "7", proofDigest: first)
        journal.record(id: "op_2", owner: "A-staging", transactionID: "7", proofDigest: updated)
        let reopened = DeviceBillingOperationJournal(preferences: defaults)
        XCTAssertEqual(reopened.operationID(owner: "A-staging", transactionID: "7", proofDigest: first), "op_1")
        XCTAssertNil(reopened.operationID(owner: "A-production", transactionID: "7", proofDigest: first))
        XCTAssertNil(reopened.operationID(owner: "B-staging", transactionID: "7", proofDigest: first))
        XCTAssertTrue(reopened.contains(owner: "A-staging", transactionID: "7", operationID: "op_2"))
        reopened.clear(owner: "A-staging", transactionID: "7", proofDigest: first)
        XCTAssertFalse(reopened.contains(owner: "A-staging", transactionID: "7", operationID: "op_1"))
        XCTAssertEqual(reopened.operationID(owner: "A-staging", transactionID: "7", proofDigest: updated), "op_2")
    }
}
