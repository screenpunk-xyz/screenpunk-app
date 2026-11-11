import Foundation
import Combine
import StoreKit
import OSLog

struct DeviceBillingSnapshot {
    struct Apple: Equatable {
        let accountToken: UUID
        let proAnnualProductID: String?
        let credits1000ProductID: String?

        func productID(for kind: DeviceBillingOffer.Kind) -> String? {
            switch kind {
            case .proAnnual: return proAnnualProductID
            case .credits1000: return credits1000ProductID
            }
        }
    }
    let financial: DeviceBillingFinancial?
    let apple: Apple?
    let salesEnabled: Bool
    let backupAccess: DeviceBackupAccess
    let verificationAvailable: Bool

    var canSell: Bool { salesEnabled && verificationAvailable && financial != nil && apple != nil }
    var canVerify: Bool { verificationAvailable && apple != nil }

    func allowsNewPurchase(_ kind: DeviceBillingOffer.Kind) -> Bool {
        canSell && financial?.allowsNewPurchase(kind) == true
    }
}

struct DeviceBillingOffer {
    typealias Kind = DeviceBillingPurchaseKind
    let kind: Kind
    let product: Product
    let accountToken: UUID
    let generation: UUID

    var confirmationTitle: String {
        switch kind {
        case .proAnnual: return "Subscribe for \(product.displayPrice) per year"
        case .credits1000: return "Buy 1,000 credits for \(product.displayPrice)"
        }
    }
    var disclosure: String {
        switch kind {
        case .proAnnual:
            return "Screenpunk Pro costs \(product.displayPrice) for one year. It renews automatically at the annual price unless canceled in your App Store subscriptions. It includes more than three Cloud devices, 1 GB of Cloud backup storage, and up to 200 API data credits each month. Unused monthly credits don’t carry over."
        case .credits1000:
            return "Pay \(product.displayPrice) once for 1,000 credits. They’re added to this Screenpunk account and never expire."
        }
    }

    static func matches(_ product: Product, kind: Kind) -> Bool {
        configuration(product, kind: kind) == .accepted
    }

    enum Configuration: String { case accepted, wrongType, wrongPeriod }

    static func configuration(_ product: Product, kind: Kind) -> Configuration {
        switch kind {
        case .proAnnual:
            guard product.type == .autoRenewable else { return .wrongType }
            guard let period = product.subscription?.subscriptionPeriod, period.unit == .year,
                  period.value == 1 else { return .wrongPeriod }
        case .credits1000:
            guard product.type == .consumable else { return .wrongType }
        }
        return .accepted
    }
}

@MainActor
final class DeviceBillingStore: ObservableObject {
    private let backend: DeviceBillingBackend
    @Published private var context: Context?
    @Published private(set) var loading = false
    @Published private(set) var working = false
    private var inFlight = Set<Flight>()
    private var generation = UUID()
    private var statusRevision = 0
    private var observingAccount: AnyCancellable?
    private var listener: Task<Void, Never>?
    private var changingAccount = false
    private var deliveryHints = Set<String>()
    private var receivedEvents: [String] = []
    private weak var backupObserver: DeviceModel?
    private var backupDeadline: Task<Void, Never>?
    private var backupRefreshSession: Session?
    private var trailingBackupRefresh: Session?

    private struct Session: Equatable {
        let generation: UUID
        let authorization: String
        let owner: String
    }
    private struct Flight: Hashable {
        let generation: UUID
        let transactionID: UInt64
    }
    enum SubscriptionDate {
        case renews(Date)
        case expires(Date)

        static func verified(for subscription: Product.SubscriptionInfo, apple: DeviceBillingSnapshot.Apple) async -> Self? {
            guard let statuses = try? await subscription.status else { return nil }
            let now = Date()
            let dates = statuses.compactMap { status -> Self? in
                guard status.state == .subscribed,
                      case .verified(let transaction) = status.transaction,
                      case .verified(let renewal) = status.renewalInfo,
                      transaction.appAccountToken == apple.accountToken,
                      transaction.productID == apple.proAnnualProductID,
                      transaction.revocationDate == nil, !transaction.isUpgraded,
                      renewal.originalTransactionID == transaction.originalID,
                      renewal.currentProductID == transaction.productID,
                      renewal.appAccountToken == nil || renewal.appAccountToken == apple.accountToken else { return nil }
                if renewal.willAutoRenew {
                    guard renewal.autoRenewPreference == transaction.productID,
                          let date = renewal.renewalDate, date > now else { return nil }
                    return .renews(date)
                }
                guard let date = transaction.expirationDate, date > now else { return nil }
                return .expires(date)
            }
            return dates.count == 1 ? dates[0] : nil
        }
    }

    private struct Context {
        let session: Session
        var snapshot: DeviceBillingSnapshot?
        var offers: [DeviceBillingOffer.Kind: DeviceBillingOffer] = [:]
        var notice: String?
        var restoreNotice: String?
        var subscriptionDate: SubscriptionDate?
        var storeLookupFailed = false
        var backupAccess: DeviceBackupAccess = .unknown
        var backupWalletVersion: UInt64?
        var backupAccountToken: UUID?
        var backupDenialWalletVersion: UInt64?
        var backupUpgrade = DeviceBackupUpgradeConsent()
    }

    init(backend: DeviceBillingBackend) { self.backend = backend }
    deinit { listener?.cancel(); backupDeadline?.cancel() }

    func observeAccount(_ device: DeviceModel) {
        guard observingAccount == nil else { return }
        backupObserver = device
        observingAccount = device.$accountOperationInProgress.removeDuplicates().sink { [weak self] changing in
            guard let self else { return }
            self.changingAccount = changing
            if changing {
                self.generation = UUID()
                _ = self.nextStatusRevision()
                self.context = nil
                self.deliveryHints.removeAll()
                self.receivedEvents.removeAll()
                self.loading = false
                self.backupDeadline?.cancel()
                self.backupObserver?.billingBackupAccessChanged()
            }
        }
        let cloud = device.cloud
        listener = Task { [weak self] in
            for await verification in Transaction.updates {
                guard let self, !Task.isCancelled else { return }
                await self.deliver(verification, cloud: cloud, finishOnSuccess: true)
            }
        }
    }

    func snapshot(for cloud: CloudClient) -> DeviceBillingSnapshot? { currentContext(cloud)?.snapshot }
    func backupAccess(for cloud: CloudClient) -> DeviceBackupAccess {
        currentContext(cloud)?.backupAccess.current(at: Date()) ?? .unknown
    }

    func backupUpgradePrompt(for cloud: CloudClient) -> UUID? {
        guard backupAccess(for: cloud).allowsBackups, backupObserver?.catalogBackupsEnabled == false,
              backupObserver?.catalogBackupsCanConfigure == true else { return nil }
        return currentContext(cloud)?.backupUpgrade.promptID
    }

    func backupsWereEnabled() {
        context?.backupUpgrade = .init()
    }

    func answerBackupUpgrade(_ id: UUID, enable: Bool, cloud: CloudClient) async {
        guard backupUpgradePrompt(for: cloud) == id, let session = currentSession(cloud),
              let token = context?.backupAccountToken, context?.backupUpgrade.consume(id) == true,
              enable else { return }
        guard let latest = try? await backend.read(cloud: cloud, authorization: session.authorization),
              isCurrent(cloud, session), !Task.isCancelled else {
            if isCurrent(cloud, session), !Task.isCancelled {
                backupObserver?.message = "Couldn’t verify your Screenpunk Pro plan. You can enable backups in Settings → Screens."
            }
            return
        }
        apply(latest)
        guard latest.apple?.accountToken == token, context?.backupAccountToken == token,
              latest.financial?.proActive == true, latest.backupAccess.allowsBackups,
              backupAccess(for: cloud).allowsBackups, backupObserver?.catalogBackupsCanConfigure == true else {
            backupObserver?.message = "Backups are off. Check your Screenpunk Pro plan in Account → Billing."
            return
        }
        backupObserver?.setCatalogBackupsEnabled(true)
    }

    /// One wallet read for a connection, entitlement event, or elapsed grant deadline.
    func refreshBackupAccess(cloud: CloudClient, invalidated: Bool = false) async {
        guard let session = currentSession(cloud) else { return }
        if backupRefreshSession == session {
            if invalidated { trailingBackupRefresh = session }
            return
        }
        activate(session)
        backupRefreshSession = session
        defer { if backupRefreshSession == session { backupRefreshSession = nil } }
        repeat {
            if trailingBackupRefresh == session { trailingBackupRefresh = nil }
            let updated = try? await backend.read(cloud: cloud, authorization: session.authorization)
            guard isCurrent(cloud, session), !Task.isCancelled else { return }
            if let updated { apply(updated) }
        } while trailingBackupRefresh == session
    }

    func recordBackupDenial(cloud: CloudClient) {
        guard let session = currentSession(cloud), context?.session == session else { return }
        context?.backupDenialWalletVersion = context?.backupWalletVersion
        updateBackupAccess(.inactive, session: session)
    }
    func notice(for cloud: CloudClient) -> String? { currentContext(cloud)?.notice }
    func restoreNotice(for cloud: CloudClient) -> String? { currentContext(cloud)?.restoreNotice }
    func subscriptionDate(for cloud: CloudClient) -> SubscriptionDate? {
        currentContext(cloud)?.subscriptionDate
    }
    func purchaseUnavailableMessage(for cloud: CloudClient) -> String {
        guard let context = currentContext(cloud), let snapshot = context.snapshot else {
            return "Billing couldn’t load. Refresh billing to try again."
        }
        guard snapshot.financial != nil else { return "Screenpunk purchases are temporarily unavailable." }
        guard snapshot.salesEnabled else { return "Screenpunk purchases are currently turned off." }
        guard snapshot.canSell else { return "Screenpunk purchases are temporarily unavailable." }
        if context.storeLookupFailed { return "Couldn’t load products from the App Store. Refresh billing to try again." }
        return "This product isn’t available from the App Store right now."
    }
    func offer(_ kind: DeviceBillingOffer.Kind, for cloud: CloudClient) -> DeviceBillingOffer? {
        currentContext(cloud)?.offers[kind]
    }

    /// Refresh on entering Billing and when the user asks. This performs a single pass.
    func refresh(cloud: CloudClient) async {
        guard !working, let session = currentSession(cloud) else { return }
        guard !loading || context?.session != session else { return }
        activate(session)
        let revision = nextStatusRevision()
        loading = true
        context?.offers = [:]
        context?.restoreNotice = nil
        context?.subscriptionDate = nil
        context?.storeLookupFailed = false
        defer { if statusRevision == revision { loading = false } }
        let value: DeviceBillingSnapshot
        do {
            value = try await backend.read(cloud: cloud, authorization: session.authorization)
            guard isCurrent(cloud, session), statusRevision == revision, !Task.isCancelled else { return }
            apply(value)
        } catch {
            guard isCurrent(cloud, session), statusRevision == revision, !Task.isCancelled else { return }
            context?.snapshot = nil
            return
        }
        let kinds = DeviceBillingOffer.Kind.allCases
        let identifiers: [String] = kinds.compactMap { kind in
            if value.canSell || (kind == .proAnnual && value.financial?.proActive == true) {
                return value.apple?.productID(for: kind)
            }
            return nil
        }
        if let apple = value.apple, !identifiers.isEmpty {
            #if SCREENPUNK_STOREKIT_DIAGNOSTICS
            Self.storeLookupSequence += 1
            let requestSequence = Self.storeLookupSequence
            async let storefrontSample = Self.currentStorefrontSample()
            let lookupStartedAt = Date()
            #endif
            let lookup: Result<[Product], Error>
            do {
                lookup = .success(try await Product.products(for: Set(identifiers)))
            } catch {
                lookup = .failure(error)
            }
            #if SCREENPUNK_STOREKIT_DIAGNOSTICS
            let lookupCompletedAt = Date()
            #endif
            guard isCurrent(cloud, session), statusRevision == revision, !Task.isCancelled,
                  context?.snapshot?.apple == apple else { return }
            if case .success(let products) = lookup {
                if context?.snapshot?.canSell == true {
                    context?.offers = Dictionary(uniqueKeysWithValues: kinds.compactMap { kind in
                        guard let product = products.first(where: { $0.id == apple.productID(for: kind) }),
                              DeviceBillingOffer.matches(product, kind: kind) else { return nil }
                        return (kind, DeviceBillingOffer(kind: kind, product: product, accountToken: apple.accountToken,
                                                         generation: session.generation))
                    })
                }
                if context?.snapshot?.financial?.proActive == true,
                   let annual = products.first(where: { $0.id == apple.proAnnualProductID }),
                   DeviceBillingOffer.matches(annual, kind: .proAnnual), let subscription = annual.subscription {
                    let date = await SubscriptionDate.verified(for: subscription, apple: apple)
                    guard isCurrent(cloud, session), statusRevision == revision, !Task.isCancelled,
                          context?.snapshot?.apple == apple else { return }
                    if context?.snapshot?.financial?.proActive == true { context?.subscriptionDate = date }
                }
            } else {
                context?.storeLookupFailed = true
            }
            #if SCREENPUNK_STOREKIT_DIAGNOSTICS
            let storefront = await storefrontSample
            guard isCurrent(cloud, session), statusRevision == revision, !Task.isCancelled,
                  context?.snapshot?.apple == apple else { return }
            Self.saveStoreLookup(lookup, identifiers: identifiers, apple: apple,
                                 requestSequence: requestSequence, startedAt: lookupStartedAt,
                                 completedAt: lookupCompletedAt, storefront: storefront)
            #endif
        }
        guard isCurrent(cloud, session), statusRevision == revision, !Task.isCancelled else { return }
        await recover(cloud: cloud)
    }

    #if SCREENPUNK_STOREKIT_DIAGNOSTICS
    private static let storeLookupRunID = UUID().uuidString
    private static var storeLookupSequence = 0

    private static func currentStorefrontSample() async -> (value: Storefront?, observedAt: Date) {
        let storefront = await Storefront.current
        return (storefront, Date())
    }

    private static func saveStoreLookup(
        _ lookup: Result<[Product], Error>, identifiers: [String], apple: DeviceBillingSnapshot.Apple,
        requestSequence: Int, startedAt: Date, completedAt: Date,
        storefront: (value: Storefront?, observedAt: Date)
    ) {
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestamp.timeZone = TimeZone(secondsFromGMT: 0)
        var storefrontFields = ["status": "unavailable", "observedAt": timestamp.string(from: storefront.observedAt)]
        if let value = storefront.value {
            storefrontFields["status"] = "available"
            storefrontFields["countryCode"] = storeLogComponent(value.countryCode)
            storefrontFields["id"] = storeLogComponent(value.id)
        }
        var diagnostic: [String: Any] = [
            "requested": identifiers.sorted().map(storeLogComponent),
            "build": storeLogComponent(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
            "version": storeLogComponent(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""),
            "runID": storeLookupRunID,
            "requestSequence": requestSequence,
            "lookupStartedAt": timestamp.string(from: startedAt),
            "lookupCompletedAt": timestamp.string(from: completedAt),
            "storefront": storefrontFields
        ]
        switch lookup {
        case .success(let products):
            diagnostic["returned"] = products.prefix(4).map { product -> [String: Any] in
                let kind = DeviceBillingOffer.Kind.allCases.first { apple.productID(for: $0) == product.id }
                let type: String
                switch product.type {
                case .autoRenewable: type = "autoRenewable"
                case .consumable: type = "consumable"
                case .nonConsumable: type = "nonConsumable"
                case .nonRenewable: type = "nonRenewable"
                default: type = "unknown"
                }
                var entry: [String: Any] = [
                    "id": storeLogComponent(product.id),
                    "type": type,
                    "configuration": kind.map { DeviceBillingOffer.configuration(product, kind: $0).rawValue } ?? "unexpected"
                ]
                if let period = product.subscription?.subscriptionPeriod {
                    let unit: String
                    switch period.unit {
                    case .day: unit = "day"
                    case .week: unit = "week"
                    case .month: unit = "month"
                    case .year: unit = "year"
                    @unknown default: unit = "unknown"
                    }
                    entry["periodUnit"] = unit
                    entry["periodValue"] = period.value
                }
                return entry
            }
            diagnostic["missing"] = Set(identifiers).subtracting(products.map(\.id)).sorted().map(storeLogComponent)
        case .failure(let error):
            let failure = error as NSError
            diagnostic["errorDomain"] = storeLogComponent(failure.domain)
            diagnostic["errorCode"] = failure.code
        }
        diagnostic["diagnosticWrittenAt"] = timestamp.string(from: Date())
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let bytes = try? JSONSerialization.data(withJSONObject: diagnostic, options: .sortedKeys),
              bytes.count <= 4096 else { return }
        try? bytes.write(to: directory.appendingPathComponent("screenpunk-billing-product-diagnostic.json"), options: .atomic)
    }

    private static func storeLogComponent(_ value: String) -> String {
        guard value.utf8.count <= 160,
              value.range(of: "\\A[A-Za-z0-9_.-]+\\z", options: .regularExpression) != nil else {
            return "<redacted>"
        }
        return value
    }
    #endif

    /// A socket event is an account-scoped hint. Another device may own the StoreKit transaction.
    func billingUpdated(operationID: String, eventID: String, cloud: CloudClient) async {
        guard let session = currentSession(cloud), !receivedEvents.contains(eventID) else { return }
        if receivedEvents.count >= 64 { receivedEvents.removeFirst() }
        receivedEvents.append(eventID)
        if deliveryHints.count >= 64 { deliveryHints.removeFirst() }
        deliveryHints.insert(operationID)
        let matched = await recover(cloud: cloud, operationID: operationID)
        guard !matched, isCurrent(cloud, session), !Task.isCancelled else { return }
        await refreshBackupAccess(cloud: cloud, invalidated: true)
    }

    /// Reconcile only StoreKit transactions awaiting delivery at a discrete lifecycle or user action.
    @discardableResult
    func recover(cloud: CloudClient, restoring: Bool = false, operationID: String? = nil) async -> Bool {
        guard let session = currentSession(cloud) else { return false }
        var handled = Set<UInt64>()
        var matched = false
        for await verification in Transaction.unfinished {
            guard isCurrent(cloud, session), !Task.isCancelled else { return matched }
            if case .verified(let transaction) = verification { handled.insert(transaction.id) }
            if let operationID {
                guard case .verified(let transaction) = verification,
                      tracks(transaction, session: session, operationID: operationID) else { continue }
            }
            matched = true
            await deliver(verification, cloud: cloud, finishOnSuccess: true, explicit: restoring)
        }
        for await verification in Transaction.currentEntitlements {
            guard isCurrent(cloud, session), !Task.isCancelled else { return matched }
            guard case .verified(let transaction) = verification, !handled.contains(transaction.id),
                  restoring || tracks(transaction, session: session, operationID: operationID) else { continue }
            matched = true
            await deliver(verification, cloud: cloud, finishOnSuccess: false, explicit: restoring)
        }
        return matched
    }

    private func tracks(_ transaction: Transaction, session: Session, operationID: String? = nil) -> Bool {
        guard let token = transaction.appAccountToken else { return false }
        return backend.tracks(owner: journalOwner(session, token), transactionID: String(transaction.id), operationID: operationID)
    }

    func buy(_ offer: DeviceBillingOffer, cloud: CloudClient) async {
        guard !working, !loading, let session = currentSession(cloud), offer.generation == session.generation,
              let currentOffer = currentContext(cloud)?.offers[offer.kind],
              currentOffer.accountToken == offer.accountToken, currentOffer.product == offer.product,
              snapshot(for: cloud)?.allowsNewPurchase(offer.kind) == true else { return }
        working = true
        context?.notice = nil
        context?.restoreNotice = nil
        defer { working = false }

        // Checkout is sandbox-only for this release. Enabling live sales requires
        // deliberate client and server policy changes for verified production purchases.
        let checkout = await DeviceTestCheckout.check(
            installedBundleID: Bundle.main.bundleIdentifier,
            loadApp: { try await .init(AppTransaction.shared) },
            refreshApp: { try await .init(AppTransaction.refresh()) },
            sessionIsCurrent: { self.isCurrent(cloud, session) }
        )
        let logger = Logger(subsystem: "xyz.screenpunk.ios", category: "Billing")
        logger.notice("Sandbox checkout app verification: \(checkout.rawValue, privacy: .public)")
        guard isCurrent(cloud, session), !Task.isCancelled else { return }
        let verificationNotice: String?
        switch checkout {
        case .allowed, .allowedAfterRefresh:
            verificationNotice = nil
        case .cancelled, .staleSession:
            return
        case .refreshFailed:
            verificationNotice = "The App Store couldn’t verify this app right now. Try the purchase again."
        case .unverified, .bundleMismatch:
            verificationNotice = "The App Store couldn’t verify this copy of Screenpunk."
        case .production, .xcode, .unsupportedEnvironment:
            verificationNotice = "Test purchases are available in Apple’s sandbox environment."
        }
        if let verificationNotice {
            currentNotice("\(verificationNotice) (\(checkout.rawValue))", cloud: cloud, session: session)
            return
        }
        do {
            let latest = try await backend.read(cloud: cloud, authorization: session.authorization)
            guard isCurrent(cloud, session), !Task.isCancelled else { return }
            apply(latest)
            let effective = snapshot(for: cloud)
            guard latest.allowsNewPurchase(offer.kind), effective?.allowsNewPurchase(offer.kind) == true,
                  latest.apple?.accountToken == offer.accountToken,
                  latest.apple?.productID(for: offer.kind) == offer.product.id,
                  effective?.apple?.accountToken == offer.accountToken,
                  effective?.apple?.productID(for: offer.kind) == offer.product.id else {
                if offer.kind == .credits1000 && latest.financial?.proActive == false {
                    context?.notice = "An active Screenpunk Pro subscription is required to buy credits."
                } else {
                    context?.notice = "This purchase is no longer available. Refresh billing to check again."
                }
                return
            }
        } catch {
            guard isCurrent(cloud, session), !Task.isCancelled else { return }
            context?.offers = [:]
            context?.notice = "Purchases aren’t available right now. Refresh billing and try again."
            return
        }
        if offer.kind == .proAnnual { context?.backupUpgrade.start(productID: offer.product.id, at: Date()) }
        do {
            let result = try await offer.product.purchase(options: [.appAccountToken(offer.accountToken)])
            guard isCurrent(cloud, session) else { return }
            switch result {
            case .success(let verification):
                if offer.kind == .proAnnual {
                    if case .verified(let transaction) = verification,
                       transaction.appAccountToken == offer.accountToken, transaction.productID == offer.product.id {
                        context?.backupUpgrade.acceptCheckout(transactionID: transaction.id)
                        matchUpgradePurchase(transaction, fromDirectCheckout: true)
                        offerBackupUpgradeIfReady()
                    } else {
                        context?.backupUpgrade.abandonPurchase()
                    }
                }
                await deliver(verification, cloud: cloud, finishOnSuccess: true, explicit: true)
            case .pending:
                if offer.kind == .proAnnual {
                    context?.backupUpgrade.acceptCheckout()
                    offerBackupUpgradeIfReady()
                }
                context?.notice = "Your purchase is awaiting App Store approval."
            case .userCancelled:
                if offer.kind == .proAnnual { context?.backupUpgrade.abandonPurchase() }
            @unknown default:
                if offer.kind == .proAnnual { context?.backupUpgrade.abandonPurchase() }
                context?.notice = "The App Store did not confirm this purchase."
            }
        } catch {
            if isCurrent(cloud, session), offer.kind == .proAnnual { context?.backupUpgrade.abandonPurchase() }
            currentNotice("The App Store couldn’t complete this purchase. Try again later.", cloud: cloud, session: session)
        }
    }

    /// Only triggered by Restore Purchases, which can prompt for the Apple Account.
    func restore(cloud: CloudClient) async {
        guard !working, !loading, let session = currentSession(cloud), snapshot(for: cloud)?.canVerify == true else { return }
        working = true
        let previousNotice = context?.notice
        context?.restoreNotice = nil
        defer { working = false }
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return
        } catch {
            guard isCurrent(cloud, session), !Task.isCancelled else { return }
            context?.restoreNotice = "The App Store couldn’t restore purchases. Try again later."
            return
        }
        guard isCurrent(cloud, session), !Task.isCancelled else { return }
        await recover(cloud: cloud, restoring: true)
        guard isCurrent(cloud, session), !Task.isCancelled, context?.notice == previousNotice else { return }
        do {
            let value = try await backend.read(cloud: cloud, authorization: session.authorization)
            guard isCurrent(cloud, session), !Task.isCancelled else { return }
            apply(value)
            context?.restoreNotice = value.financial == nil
                ? "Couldn’t check your Screenpunk balance after restoring. Refresh billing to try again."
                : "Your Screenpunk account is up to date."
        } catch {
            guard isCurrent(cloud, session), !Task.isCancelled else { return }
            context?.restoreNotice = "Couldn’t check your Screenpunk balance after restoring. Refresh billing to try again."
        }
    }

    private func deliver(_ verification: VerificationResult<Transaction>, cloud: CloudClient, finishOnSuccess: Bool, explicit: Bool = false) async {
        guard let session = currentSession(cloud) else { return }
        activate(session)
        guard case .verified(let transaction) = verification else {
            if explicit { currentNotice("The App Store couldn’t verify a transaction.", cloud: cloud, session: session) }
            return
        }
        let flight = Flight(generation: session.generation, transactionID: transaction.id)
        guard transaction.productType == .autoRenewable || transaction.productType == .consumable,
              inFlight.insert(flight).inserted else { return }
        defer { inFlight.remove(flight) }
        let transactionID = String(transaction.id)
        let proof = verification.jwsRepresentation
        do {
            let value: DeviceBillingSnapshot
            if let snapshot = context?.snapshot, snapshot.canVerify {
                value = snapshot
            } else {
                value = try await backend.read(cloud: cloud, authorization: session.authorization)
                guard isCurrent(cloud, session), !Task.isCancelled else { return }
                if context?.snapshot?.canVerify != true { apply(value) }
            }
            guard value.canVerify, let apple = value.apple,
                  DeviceBillingOffer.Kind.allCases.contains(where: { apple.productID(for: $0) == transaction.productID }) else { return }
            guard apple.accountToken == transaction.appAccountToken else {
                if explicit {
                    context?.notice = "An App Store purchase couldn’t be matched to this Screenpunk account. Check the account you used to buy it."
                }
                return
            }
            if transaction.productType == .autoRenewable, transaction.productID == apple.proAnnualProductID,
               transaction.revocationDate == nil, !transaction.isUpgraded {
                matchUpgradePurchase(transaction)
            }
            let owner = journalOwner(session, apple.accountToken)
            let queuedHint = deliveryHints.first { tracks(transaction, session: session, operationID: $0) }
            if let queuedHint { deliveryHints.remove(queuedHint) }
            var delivery = try await backend.submit(cloud: cloud, authorization: session.authorization,
                                                    owner: owner, proof: proof, transactionID: transactionID)
            guard isCurrent(cloud, session), !Task.isCancelled else { return }
            // Completion can arrive while the initial proof POST is still returning.
            if case .pending = delivery,
               let hint = deliveryHints.first(where: { tracks(transaction, session: session, operationID: $0) }) {
                deliveryHints.remove(hint)
                delivery = try await backend.submit(cloud: cloud, authorization: session.authorization,
                                                    owner: owner, proof: proof, transactionID: transactionID)
                guard isCurrent(cloud, session), !Task.isCancelled else { return }
            }
            switch delivery {
            case .fulfilled:
                let updated = try await backend.read(cloud: cloud, authorization: session.authorization)
                guard isCurrent(cloud, session), !Task.isCancelled,
                      updated.apple?.accountToken == apple.accountToken, updated.financial != nil else {
                    currentNotice("Your purchase is being processed. Refresh billing to check again.", cloud: cloud, session: session)
                    return
                }
                apply(updated)
                if finishOnSuccess { await transaction.finish() }
                if isCurrent(cloud, session), !Task.isCancelled {
                    context?.backupUpgrade.confirmFulfillment(transactionID: transaction.id)
                    offerBackupUpgradeIfReady()
                }
                backend.clear(owner: owner, transactionID: transactionID, proof: proof)
                currentNotice("Your purchase is available on your Screenpunk account.", cloud: cloud, session: session)
            case .pending:
                context?.notice = "Your purchase is being processed. Refresh billing to check again."
            case .reviewRequired:
                context?.notice = "Your purchase needs review before it can be added to this account."
            case .rejected:
                context?.notice = "Screenpunk couldn’t apply this purchase. Contact support if you were charged."
            }
        } catch {
            currentNotice("Couldn’t confirm delivery. Refresh billing to try again.", cloud: cloud, session: session)
        }
    }

    private func apply(_ snapshot: DeviceBillingSnapshot) {
        if let incoming = snapshot.financial, let current = context?.snapshot,
           snapshot.apple?.accountToken == current.apple?.accountToken,
           let existing = current.financial, incoming.version < existing.version { return }
        if !snapshot.canSell || context?.snapshot?.apple != snapshot.apple { context?.offers = [:] }
        if snapshot.financial?.proActive != true || context?.snapshot?.apple != snapshot.apple {
            context?.subscriptionDate = nil
        }
        context?.snapshot = snapshot
        if let token = snapshot.apple?.accountToken, context?.backupAccountToken != token,
           let session = context?.session {
            if context?.backupAccountToken != nil { context?.backupUpgrade = .init() }
            context?.backupAccountToken = token
            context?.backupWalletVersion = nil
            context?.backupDenialWalletVersion = nil
            updateBackupAccess(.unknown, session: session)
        }
        if snapshot.backupAccess != .unknown, let version = snapshot.financial?.version,
           version >= (context?.backupWalletVersion ?? 0), let session = context?.session {
            if snapshot.backupAccess.allowsBackups,
               let denied = context?.backupDenialWalletVersion, version <= denied { return }
            context?.backupWalletVersion = version
            updateBackupAccess(snapshot.backupAccess, session: session)
        }
        offerBackupUpgradeIfReady()
    }

    private func offerBackupUpgradeIfReady() {
        let hasProGrant = context?.snapshot?.financial?.proActive == true &&
            context?.snapshot?.backupAccess.allowsBackups == true &&
            context?.backupAccess.allowsBackups == true
        let backupsEnabled = backupObserver?.catalogBackupsEnabled == true
        context?.backupUpgrade.offerIfReady(hasProGrant: hasProGrant, backupsEnabled: backupsEnabled)
    }

    private func matchUpgradePurchase(_ transaction: Transaction, fromDirectCheckout: Bool = false) {
        guard transaction.productType == .autoRenewable, transaction.revocationDate == nil, !transaction.isUpgraded else { return }
        let isNewPurchase: Bool
        let allowPinnedCheckout: Bool
        if #available(iOS 17.0, *) {
            isNewPurchase = transaction.reason == .purchase
            allowPinnedCheckout = false
        } else {
            isNewPurchase = transaction.id == transaction.originalID
            allowPinnedCheckout = fromDirectCheckout
        }
        context?.backupUpgrade.match(productID: transaction.productID, transactionID: transaction.id,
                                     purchasedAt: transaction.purchaseDate, isNewPurchase: isNewPurchase,
                                     allowPinnedCheckout: allowPinnedCheckout)
    }

    private func updateBackupAccess(_ access: DeviceBackupAccess, session: Session) {
        guard context?.backupAccess != access else { return }
        if access == .inactive, case .active = context?.backupAccess {
            context?.backupUpgrade = .init()
        }
        context?.backupAccess = access
        scheduleBackupDeadline(access, session: session)
        backupObserver?.billingBackupAccessChanged()
    }

    private func activate(_ session: Session) {
        if context?.session != session {
            backupDeadline?.cancel()
            context = Context(session: session)
            backupObserver?.billingBackupAccessChanged()
        }
    }

    private func scheduleBackupDeadline(_ access: DeviceBackupAccess, session: Session) {
        backupDeadline?.cancel()
        guard case .active(let until) = access, let cloud = backupObserver?.cloud else { return }
        // Stop accepting work at the deadline even if the process missed the renewal event.
        backupDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow))) }
            catch { return }
            guard let self, self.isCurrent(cloud, session), self.context?.backupAccess == access else { return }
            if until > Date() {
                self.scheduleBackupDeadline(access, session: session)
                return
            }
            self.backupDeadline = nil
            self.context?.backupUpgrade = .init()
            self.backupObserver?.billingBackupAccessChanged()
            await self.refreshBackupAccess(cloud: cloud)
        }
    }

    private func currentContext(_ cloud: CloudClient) -> Context? {
        guard let context, isCurrent(cloud, context.session) else { return nil }
        return context
    }

    private func currentSession(_ cloud: CloudClient) -> Session? {
        guard !changingAccount, let authorization = cloud.session?.accessToken, let owner = cloud.localAccountID else { return nil }
        return .init(generation: generation, authorization: authorization, owner: owner)
    }

    private func journalOwner(_ session: Session, _ token: UUID) -> String {
        CloudClient.originScope.canonicalOrigin + "\u{0}" + session.owner + "\u{0}" + token.uuidString
    }

    private func isCurrent(_ cloud: CloudClient, _ session: Session) -> Bool { currentSession(cloud) == session }

    private func currentNotice(_ notice: String, cloud: CloudClient, session: Session) {
        guard !Task.isCancelled, isCurrent(cloud, session), context?.session == session else { return }
        context?.notice = notice
    }

    private func nextStatusRevision() -> Int { statusRevision += 1; return statusRevision }
}
