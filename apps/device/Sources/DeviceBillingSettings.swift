import StoreKit
import SwiftUI
import UIKit

struct DeviceBillingRow: View {
    @ObservedObject var device: DeviceModel
    @ObservedObject var billing: DeviceBillingStore
    let openPlan: () -> Void

    var body: some View {
        Button(action: openPlan) {
            AccountFieldRow(title: "Plan", value: planName)
        }
        .buttonStyle(.plain)
        .disabled(device.accountOperationInProgress)
        .task(id: device.cloud.localAccountID) {
            await billing.refreshBackupAccess(cloud: device.cloud)
        }
    }

    private var planName: String {
        guard let financial = billing.snapshot(for: device.cloud)?.financial else { return billing.loading ? "Checking…" : "Unavailable" }
        return financial.proActive ? "Pro" : "Free"
    }

}

struct DeviceBillingSettings: View {
    @ObservedObject var device: DeviceModel
    @ObservedObject var billing: DeviceBillingStore
    @Environment(\.openURL) private var openURL
    @State private var confirmation: DeviceBillingOffer?

    private var signedIn: Bool { device.email != nil && device.cloud.session != nil }
    private var snapshot: DeviceBillingSnapshot? { billing.snapshot(for: device.cloud) }
    private var busy: Bool { billing.working || device.accountOperationInProgress }

    var body: some View {
        Form {
            plansSection
            if let financial = snapshot?.financial, financial.showsCredits {
                creditsSection(financial)
            }
            let notices = billing.presentedNotices(for: device.cloud)
            if !notices.isEmpty {
                Section {
                    ForEach(notices) { notice in
                        DismissibleMessage(notice.text, onDismiss: { billing.dismissNotice(id: notice.id, cloud: device.cloud) }).id(notice.id)
                    }
                }
            }
            legalSection
        }
        .navigationTitle("Plan")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: AccountState(id: device.cloud.localAccountID, changing: device.accountOperationInProgress)) {
            confirmation = nil
            if signedIn && !device.accountOperationInProgress { await billing.refresh(cloud: device.cloud) }
        }
        .refreshable { if signedIn { await billing.refresh(cloud: device.cloud) } }
        .alert("Confirm purchase", isPresented: Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { offer in
            Button(offer.confirmationTitle) {
                Task { await billing.buy(offer, cloud: device.cloud) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { offer in
            Text(offer.disclosure)
        }
    }

    private func creditsSection(_ financial: DeviceBillingFinancial) -> some View {
        Section {
            if let monthly = financial.visibleMonthlyCredits {
                LabeledContent("Monthly credits remaining", value: monthly.formatted())
            }
            LabeledContent("Purchased credits remaining", value: financial.purchasedCredits.formatted())
            if financial.allowsNewPurchase(.credits1000) { offerButton(.credits1000) }
        } header: {
            Text("Credits")
        } footer: {
            if financial.proActive {
                Text("Use credits for paid API data on your screens. Monthly credits reset each month and are used first. Purchased credits never expire. National Weather Service weather costs no credits.")
            } else {
                Text("Use credits for paid API data on your screens. Purchased credits never expire. National Weather Service weather costs no credits.")
            }
        }
    }

    private var plansSection: some View {
        Section("Plan") {
            planRow("Free", current: snapshot?.financial?.proActive == false) {
                Text("Use your Local agent without an account. Sign in to use Screenpunk Cloud on up to three devices.")
                    .foregroundStyle(.secondary)
            }
            planRow("Screenpunk Pro", current: snapshot?.financial?.proActive == true) {
                let benefits = "More than three Cloud devices, 1 GB of Cloud backup storage, and up to 200 API data credits each month."
                if snapshot?.financial?.proActive == false, let offer = billing.offer(.proAnnual, for: device.cloud) {
                    Text("\(benefits) \(offer.product.displayPrice) per year. Renews automatically until canceled.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(benefits).foregroundStyle(.secondary)
                }
                if snapshot?.financial?.proActive == true {
                    switch billing.subscriptionDate(for: device.cloud) {
                    case .renews(let date):
                        Text("Renews on \(date.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(.secondary)
                    case .expires(let date):
                        Text("Expires on \(date.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(.secondary)
                    case nil:
                        EmptyView()
                    }
                }
            }
            if !signedIn {
                Button("Sign in for Screenpunk Cloud") { Task { await device.signIn() } }
                    .disabled(busy || device.routeChangeBlocked)
            } else if snapshot?.financial?.proActive == true {
                manageSubscription
            } else if billing.offer(.proAnnual, for: device.cloud) != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { offerButton(.proAnnual); Spacer(minLength: 0); restorePurchases }
                    VStack(alignment: .leading, spacing: 12) { offerButton(.proAnnual); restorePurchases }
                }
                .buttonStyle(.borderless)
            } else {
                offerButton(.proAnnual)
                restorePurchases
            }
        }
    }

    private func planRow<Details: View>(_ title: LocalizedStringKey, current: Bool,
                                        @ViewBuilder details: () -> Details) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .opacity(current ? 1 : 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                    .accessibilityAddTraits(current ? .isSelected : [])
                details()
            }
        }
    }

    @ViewBuilder private func offerButton(_ kind: DeviceBillingOffer.Kind) -> some View {
        if let offer = billing.offer(kind, for: device.cloud) {
            Button(offer.confirmationTitle) { confirmation = offer }.disabled(busy || billing.loading)
        } else if billing.loading {
            ProgressView("Checking App Store availability…")
        } else {
            DismissibleMessage(billing.purchaseUnavailableMessage(for: device.cloud))
        }
    }

    private var restorePurchases: some View {
        Button("Restore Purchases") { Task { await billing.restore(cloud: device.cloud) } }
            .disabled(busy || billing.loading || snapshot?.canVerify != true)
    }

    private var manageSubscription: some View {
        Button("Manage Subscription") {
            Task {
                guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.windows.contains(where: \.isKeyWindow) }) else {
                    openURL(Self.subscriptionsURL)
                    return
                }
                do {
                    try await AppStore.showManageSubscriptions(in: scene)
                    await billing.refresh(cloud: device.cloud)
                }
                catch { openURL(Self.subscriptionsURL) }
            }
        }
    }

    private var legalSection: some View {
        Section {
            Link("Terms of Use", destination: URL(string: "https://screenpunk.xyz/terms")!)
            Link("Privacy Policy", destination: URL(string: "https://screenpunk.xyz/privacy")!)
        }
    }

    private struct AccountState: Equatable {
        let id: String?
        let changing: Bool
    }

    private static let subscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!
}
