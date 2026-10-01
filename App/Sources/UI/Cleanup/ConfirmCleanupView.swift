import DeLoreCore
import SwiftUI

/// The explicit authorization step. Nothing destructive happens before "Start cleaning".
struct ConfirmCleanupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let setup: CleanupSetupModel
    @State private var showingPaywall = false
    @State private var isStarting = false

    private var prepared: PreparedCleanup? { setup.prepared }

    /// Re-evaluated live so a purchase made from here takes effect immediately.
    private var decision: CleanupAllowanceDecision? {
        prepared.map { model.entitlements.allowance(requestedCount: $0.count, usesAdvancedFilters: setup.usesAdvancedFilters) }
    }

    var body: some View {
        ScrollView {
            if let prepared {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if prepared.count == 0 {
                        nothingToClean
                    } else {
                        Text("You're about to unsend ^[\(prepared.count) message](inflect: true).")
                            .font(.display(.title))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("confirmHeadline")

                        if let eta = model.env.ratePolicy.estimatedDuration(forItemCount: prepared.count) {
                            Text(TimeRemainingCopy.text(for: eta))
                                .font(.system(.title3, design: .rounded, weight: .semibold))
                                .foregroundStyle(Palette.secondaryInk)
                        }

                        Card {
                            PromiseRow(symbol: "eye.fill", title: "Unsent messages may already have been seen, copied, screenshotted, or retained elsewhere.")
                            PromiseRow(symbol: "arrow.uturn.backward", title: "This can't be undone.")
                            PromiseRow(symbol: "person.fill.checkmark", title: "Only messages you sent.", detail: "Never anyone else's.")
                            PromiseRow(symbol: "tortoise.fill", title: "Slow on purpose.", detail: "We pace unsends because Instagram rate-limits. Big cleanups can take hours. You can exit — don't close Retract. That does not protect your account.")
                            PromiseRow(symbol: "exclamationmark.triangle.fill", title: "We are not responsible for anything.", detail: "You use Retract at your own risk. We are not responsible for anything that happens — including Instagram bans, locks, lost messages, or failed unsends.")
                        }

                        allowanceSection
                    }
                }
                .padding(Spacing.screen)
            }
        }
        .screenBackground()
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let prepared, prepared.count > 0, case .allowed? = decision {
                VStack(spacing: Spacing.xs) {
                    Button {
                        start(prepared)
                    } label: {
                        if isStarting { ProgressView().tint(Palette.onVolt) } else { Text("Start cleaning") }
                    }
                    .buttonStyle(.primary)
                    .disabled(isStarting)
                    .sensoryFeedback(.warning, trigger: isStarting)
                    .accessibilityIdentifier("startCleaning")
                    Button("Not now") { dismiss() }
                        .buttonStyle(.text)
                }
                .padding(.horizontal, Spacing.screen)
                .padding(.vertical, Spacing.s)
                .background(Palette.background.opacity(0.96))
            }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(context: .limit)
                .environment(model)
                .presentationBackground(Palette.background)
        }
    }

    private func start(_ prepared: PreparedCleanup) {
        guard let decision else { return }
        isStarting = true
        Task {
            await model.startCleanup(PreparedCleanup(job: prepared.job, decision: decision))
            isStarting = false
        }
    }

    @ViewBuilder
    private var allowanceSection: some View {
        switch decision {
        case let .limited(remaining)?:
            Card {
                Group {
                    if remaining > 0 {
                        Text("Free covers ^[\(remaining) message](inflect: true)")
                    } else {
                        Text("You've used your free cleanups")
                    }
                }
                .font(.title(.headline))
                .foregroundStyle(Palette.ink)
                Text("Unlock everything to clean it all in one go.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
                Button("Unlock everything") { showingPaywall = true }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("unlockEverything")
                if remaining > 0 {
                    Button {
                        Task { await setup.prepare(limit: remaining) }
                    } label: {
                        Text("Clean \(remaining) for free")
                    }
                    .buttonStyle(.secondary)
                    .disabled(setup.isPreparing)
                    .accessibilityIdentifier("cleanFree")
                }
            }
        case .filtersRequirePro?:
            Card {
                Text("Filters are part of Pro")
                    .font(.title(.headline))
                    .foregroundStyle(Palette.ink)
                Button("Unlock Pro") { showingPaywall = true }
                    .buttonStyle(.primary)
            }
        default:
            EmptyView()
        }
    }

    private var nothingToClean: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Nothing to clean here")
                .font(.display(.title))
                .foregroundStyle(Palette.ink)
            Text("Everything you picked is already gone, or doesn't match your filters.")
                .foregroundStyle(Palette.secondaryInk)
            Button("Change what's included") { dismiss() }
                .buttonStyle(.secondary)
        }
    }
}
