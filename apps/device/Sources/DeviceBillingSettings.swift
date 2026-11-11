import StoreKit
import SwiftUI
import UIKit

struct DeviceBillingSection: View {
    @ObservedObject var device: DeviceModel

    var body: some View {
        Section {
            NavigationLink {
                DeviceBillingSettings(device: device, billing: device.billing)
            } label: {
                Label("Billing", systemImage: "creditcard")
            }
        }
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
            let notices = [billing.notice(for: device.cloud), billing.restoreNotice(for: device.cloud)].compactMap { $0 }
            if !notices.isEmpty {
                Section {
                    ForEach(notices, id: \.self) { notice in
                        Label(notice, systemImage: "info.circle").foregroundStyle(.secondary)
                    }
                }
            }
            if signedIn { purchaseSupport }
            legalSection
        }
        .navigationTitle("Billing")
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
            VStack(alignment: .leading, spacing: 6) {
                planTitle("Free", current: snapshot?.financial?.proActive == false)
                Text("Use your Local agent without an account. Sign in to use Screenpunk Cloud on up to three devices.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                planTitle("Screenpunk Pro", current: snapshot?.financial?.proActive == true)
                Text("More than three Cloud devices, 1 GB of Cloud backup storage, and up to 200 API data credits each month.")
                    .foregroundStyle(.secondary)
                if snapshot?.financial?.proActive == false, let offer = billing.offer(.proAnnual, for: device.cloud) {
                    Text("\(offer.product.displayPrice) per year. Renews automatically until canceled.")
                        .foregroundStyle(.secondary)
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
            } else {
                if snapshot?.financial?.proActive != true { offerButton(.proAnnual) }
                Button("Refresh Billing") { Task { await billing.refresh(cloud: device.cloud) } }
                    .disabled(busy || billing.loading)
            }
        }
    }

    @ViewBuilder private func planTitle(_ title: LocalizedStringKey, current: Bool) -> some View {
        if current {
            Label(title, systemImage: "checkmark.circle.fill")
                .font(.headline)
                .accessibilityValue("Current plan")
        } else {
            Text(title).font(.headline)
        }
    }

    @ViewBuilder private func offerButton(_ kind: DeviceBillingOffer.Kind) -> some View {
        if let offer = billing.offer(kind, for: device.cloud) {
            Button(offer.confirmationTitle) { confirmation = offer }.disabled(busy || billing.loading)
        } else if billing.loading {
            ProgressView("Checking App Store availability…")
        } else {
            Text(billing.purchaseUnavailableMessage(for: device.cloud)).foregroundStyle(.secondary)
        }
    }

    private var purchaseSupport: some View {
        Section("App Store purchases") {
            Button("Restore Purchases") { Task { await billing.restore(cloud: device.cloud) } }
                .disabled(busy || billing.loading || snapshot?.canVerify != true)
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
