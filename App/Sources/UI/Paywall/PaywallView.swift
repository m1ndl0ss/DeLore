import DeLoreCore
import SwiftUI

struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let context: AnalyticsEvent.PaywallContext
    @State private var selectedID: String?
    @State private var notice: LocalizedStringKey?

    private var entitlements: EntitlementManager { model.entitlements }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack {
                    Spacer()
                    CloseButton { dismiss() }
                }

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Clean it all.")
                        .font(.display())
                        .foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Free covers your first ^[\(entitlements.freeLimit) message](inflect: true). Unlock the rest whenever you're ready.")
                        .foregroundStyle(Palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: Spacing.m) {
                    PromiseRow(symbol: "infinity", title: "Unlimited cleanup", detail: "Every chat, every message you sent.")
                    PromiseRow(symbol: "slider.horizontal.3", title: "Date & type filters", detail: "Only old stuff. Only photos. Your call.")
                    PromiseRow(symbol: "sparkles", title: "New features as they land", detail: "Included with Pro.")
                }

                plans

                if let notice {
                    Text(notice)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.secondaryInk)
                }
            }
            .padding(Spacing.screen)
        }
        .screenBackground()
        .safeAreaInset(edge: .bottom) { footer }
        .task {
            model.env.analytics.track(.paywallShown(context: context))
            await entitlements.loadProducts()
            if selectedID == nil { selectedID = entitlements.products.first?.id }
        }
        .onChange(of: entitlements.isPro) { _, isPro in
            if isPro { dismiss() }
        }
    }

    @ViewBuilder
    private var plans: some View {
        if entitlements.isLoadingProducts && entitlements.products.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if entitlements.products.isEmpty {
            Card {
                Text("The App Store isn't reachable right now")
                    .font(.title(.headline))
                    .foregroundStyle(Palette.ink)
                Text("You can keep using the free version. Try again in a bit.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
                Button("Try again") {
                    Task { await entitlements.loadProducts() }
                }
                .buttonStyle(.secondary)
            }
        } else {
            VStack(spacing: Spacing.s) {
                ForEach(entitlements.products) { product in
                    Button {
                        selectedID = product.id
                    } label: {
                        PlanCard(product: product, isSelected: product.id == selectedID)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(product.id == selectedID ? .isSelected : [])
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: Spacing.xs) {
            Button {
                purchase()
            } label: {
                if entitlements.isPurchasing { ProgressView().tint(Palette.onVolt) } else { Text("Continue") }
            }
            .buttonStyle(.primary)
            .disabled(selectedProduct == nil || entitlements.isPurchasing)
            .accessibilityIdentifier("purchase")

            HStack(spacing: Spacing.m) {
                Button("Restore purchases") {
                    Task {
                        if await entitlements.restore() {
                            if !entitlements.isPro { notice = "No active Pro plan found." }
                        } else {
                            notice = "We couldn't reach the App Store. Try again later."
                        }
                    }
                }
                Link("Terms", destination: model.env.configuration.termsURL)
                Link("Privacy", destination: model.env.configuration.privacyPolicyURL)
            }
            .buttonStyle(.text)
            .font(.footnote)

            Text("Pro renews automatically until you cancel in Settings. A one-time cleanup covers one full cleanup and doesn't renew.")
                .font(.caption2)
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.vertical, Spacing.s)
        .background(Palette.background.opacity(0.96))
    }

    private var selectedProduct: StoreProduct? {
        entitlements.products.first { $0.id == selectedID }
    }

    private func purchase() {
        guard let product = selectedProduct else { return }
        Task {
            switch await entitlements.purchase(product) {
            case .purchased?:
                dismiss()
            case .pending?:
                notice = "Waiting for approval. We'll unlock things as soon as it goes through."
            case .cancelled?:
                break
            case nil:
                notice = "That didn't go through. You haven't been charged."
            }
        }
    }
}

private struct PlanCard: View {
    let product: StoreProduct
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.title2)
                .foregroundStyle(isSelected ? Palette.onVolt : Palette.secondaryInk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if product.kind == .proYearly {
                    Pill(text: "Best value", filled: !isSelected)
                        .padding(.bottom, 2)
                }
                Text(title)
                    .font(.title(.headline))
                Text(subtitle)
                    .font(.subheadline)
                    .opacity(0.75)
            }
            Spacer()
            Text(product.displayPrice)
                .font(.system(.headline, design: .rounded, weight: .heavy))
        }
        .foregroundStyle(isSelected ? Palette.onVolt : Palette.ink)
        .padding(Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isSelected ? Palette.volt : Palette.surface)
        )
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.hairline))
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringKey {
        switch product.kind {
        case .proYearly: return "Pro · Yearly"
        case .proMonthly: return "Pro · Monthly"
        case .oneTimeCleanup: return "One-time cleanup"
        }
    }

    private var subtitle: LocalizedStringKey {
        switch product.kind {
        case .proYearly:
            if let monthly = product.monthlyEquivalent { return "Just \(monthly)/month, billed yearly" }
            return "Billed yearly"
        case .proMonthly: return "Billed monthly, cancel anytime"
        case .oneTimeCleanup: return "Clean everything once. No subscription."
        }
    }
}
