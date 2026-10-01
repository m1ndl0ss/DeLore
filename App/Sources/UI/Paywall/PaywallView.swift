import DeLoreCore
import StoreKit
import SwiftUI

struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let context: AnalyticsEvent.PaywallContext
    var embedded = false
    @State private var selectedID: String?
    @State private var notice: LocalizedStringKey?
    @State private var glow = false
    @State private var legal: LegalDestination?
    @State private var promoCode = ""
    @State private var promoNotice: String?
    @State private var managingSubscription = false

    private var entitlements: EntitlementManager { model.entitlements }
    private var plans: [StoreProduct] {
        entitlements.products.filter { ($0.kind == .proYearly || $0.kind == .proMonthly) && !$0.isPromo }
    }

    var body: some View {
        Group {
            if entitlements.isPro {
                subscribedContent
            } else {
                buyContent
            }
        }
        .background(Palette.background)
        .presentationBackground(Palette.background)
        .manageSubscriptionsSheet(isPresented: $managingSubscription)
        .sheet(item: $legal) { destination in
            NavigationStack {
                Group {
                    switch destination {
                    case .terms: TermsView()
                    case .privacy: PrivacyView()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { legal = nil }
                    }
                }
            }
            .presentationBackground(Palette.background)
        }
        .task {
            await entitlements.refresh()
            if entitlements.isPro { return }
            model.env.analytics.track(.paywallShown(context: context))
            await entitlements.loadProducts()
            if selectedID == nil {
                selectedID = plans.first { $0.kind == .proYearly }?.id ?? plans.first?.id
            }
        }
        .onAppear {
            guard !entitlements.isPro, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { glow = true }
        }
        .onChange(of: entitlements.isPro) { wasPro, isPro in
            if isPro && !wasPro { dismiss() }
        }
    }

    private var subscribedUntilCopy: String {
        if let date = entitlements.state.proRenewsOrExpiresAt {
            return "Subscribed till \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Subscribed"
    }

    private var subscribedContent: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            if !embedded {
                HStack {
                    Spacer()
                    CloseButton { dismiss() }
                }
            }
            Text("Plan")
                .font(Type.medium(28))
                .foregroundStyle(Palette.ink)
            Text(subscribedUntilCopy)
                .font(Type.body(17))
                .foregroundStyle(Palette.accent)
            Button("Cancel my subscription") { managingSubscription = true }
                .buttonStyle(TextButtonStyle(tint: Palette.secondaryInk))
            Spacer()
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.top, Spacing.m)
        .padding(.bottom, Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var buyContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if !embedded {
                    HStack {
                        Spacer()
                        CloseButton { dismiss() }
                    }
                }

                Text("Go Pro")
                    .font(Type.medium(28))
                    .foregroundStyle(Palette.ink)
                Text("Unlimited unsends. Pick a plan.")
                    .font(Type.body(15))
                    .foregroundStyle(Palette.secondaryInk)
                Text(LegalCopy.notResponsible)
                    .font(Type.body(14))
                    .foregroundStyle(Palette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                promoBox
                plansBlock

                if let notice {
                    Text(notice)
                        .font(Type.body(14))
                        .foregroundStyle(Palette.secondaryInk)
                }

                HStack(spacing: Spacing.l) {
                    Button("Restore") {
                        Task {
                            if await entitlements.restore() {
                                if !entitlements.isPro { notice = "No Pro plan on this Apple ID." }
                            } else {
                                notice = "App Store isn’t reachable."
                            }
                        }
                    }
                    Button("Terms") { legal = .terms }
                    Button("Privacy") { legal = .privacy }
                    Spacer()
                }
                .font(Type.medium(14))
                .foregroundStyle(Palette.secondaryInk)

                Text(LegalCopy.subscriptionFinePrint)
                    .font(Type.body(12))
                    .foregroundStyle(Palette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.top, Spacing.m)
            .padding(.bottom, Spacing.xl)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var plansBlock: some View {
        if entitlements.isLoadingProducts && plans.isEmpty {
            ProgressView().tint(Palette.accent).frame(maxWidth: .infinity, minHeight: 80)
        } else if plans.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Plans unavailable")
                    .font(Type.medium(17))
                Button("Retry") { Task { await entitlements.loadProducts() } }
                    .buttonStyle(.secondary)
            }
        } else {
            VStack(spacing: Spacing.m) {
                ForEach(plans) { product in
                    planCard(product)
                }
            }
        }
    }

    private func planCard(_ product: StoreProduct) -> some View {
        let on = product.id == selectedID
        let yearly = product.kind == .proYearly
        return VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(yearly ? "Yearly" : "Monthly")
                    .font(Type.medium(yearly ? 22 : 17))
                Spacer()
                if yearly {
                    Text("Best value")
                        .font(Type.medium(11))
                        .foregroundStyle(Palette.onCtaSoft)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                LinearGradient(
                                    colors: [Palette.valueGold, Palette.valuePink],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        )
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if entitlements.percentOff > 0, let checkout = entitlements.checkoutProduct(for: product) {
                    Text(product.displayPrice)
                        .font(Type.body(yearly ? 20 : 16))
                        .foregroundStyle(Palette.secondaryInk)
                        .strikethrough()
                    Text(checkout.displayPrice)
                        .font(Type.medium(yearly ? 34 : 24))
                } else {
                    Text(product.displayPrice)
                        .font(Type.medium(yearly ? 34 : 24))
                }
                Text(yearly ? "/ year" : "/ month")
                    .font(Type.body(15))
                    .foregroundStyle(Palette.secondaryInk)
            }
            .foregroundStyle(Palette.ink)
            if yearly, let monthly = entitlements.checkoutProduct(for: product)?.monthlyEquivalent ?? product.monthlyEquivalent {
                Text("\(monthly) / mo")
                    .font(Type.body(14))
                    .foregroundStyle(Palette.accent)
            }
            if yearly {
                Button {
                    selectedID = product.id
                    purchase(product)
                } label: {
                    Text("Subscribe yearly")
                }
                .buttonStyle(.primary)
                .disabled(entitlements.isPurchasing || entitlements.isPro || (entitlements.percentOff > 0 && entitlements.checkoutProduct(for: product) == nil))
                .accessibilityIdentifier("purchaseYearly")
            } else {
                Button {
                    selectedID = product.id
                    purchase(product)
                } label: {
                    Text("Subscribe monthly")
                }
                .buttonStyle(.secondary)
                .disabled(entitlements.isPurchasing || entitlements.isPro || (entitlements.percentOff > 0 && entitlements.checkoutProduct(for: product) == nil))
                .accessibilityIdentifier("purchaseMonthly")
            }
        }
        .padding(yearly ? 20 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .fill(yearly ? Palette.surfaceElevated : Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .strokeBorder(
                    yearly
                        ? Palette.cta.opacity(glow && on ? 1 : 0.72)
                        : Palette.accent.opacity(on ? 0.85 : 0.5),
                    lineWidth: yearly ? 1.8 : 1.4
                )
        )
        .shadow(color: (yearly ? Palette.cta : Palette.accent).opacity(yearly ? 0.32 : 0.18), radius: yearly && glow ? 22 : 12, y: 8)
        .onTapGesture { selectedID = product.id }
    }

    private var promoBox: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                TextField("Promo code", text: $promoCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { redeemPromo() }
                    .disabled(entitlements.isPromoLocked)
                Button("Apply") { redeemPromo() }
                    .font(Type.medium(15))
                    .foregroundStyle(Palette.accent)
                    .disabled(entitlements.isPromoLocked || promoCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Palette.surface))
            if entitlements.percentOff > 0, let code = entitlements.appliedPromoCode {
                Text("\(entitlements.percentOff)% off with \(code)")
                    .font(Type.body(13))
                    .foregroundStyle(Palette.accent)
            }
            if let promoNotice {
                Text(promoNotice)
                    .font(Type.body(13))
                    .foregroundStyle(Palette.secondaryInk)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func redeemPromo() {
        switch entitlements.redeemPromo(promoCode) {
        case .empty:
            promoNotice = "Enter a code first."
        case .locked:
            promoNotice = "That's 3 tries for today. Come back tomorrow."
        case .invalid(let remaining):
            promoNotice = remaining == 0
                ? "That's 3 tries for today. Come back tomorrow."
                : "That code isn't valid. \(remaining) \(remaining == 1 ? "try" : "tries") left today."
        case .applied(.complimentary):
            promoCode = ""
            promoNotice = nil
        case .applied(.percentOff(let percent)):
            promoCode = ""
            promoNotice = "\(percent)% off applied."
        }
    }

    private func purchase(_ product: StoreProduct) {
        Task {
            if entitlements.percentOff > 0 && entitlements.checkoutProduct(for: product) == nil {
                notice = "That discount isn’t in the store yet."
                return
            }
            switch await entitlements.purchase(product) {
            case .purchased?:
                dismiss()
            case .pending?:
                notice = "Waiting for approval."
            case .cancelled?:
                break
            case nil:
                notice = "Not charged."
            }
        }
    }
}

private enum LegalDestination: String, Identifiable {
    case terms, privacy
    var id: String { rawValue }
}
