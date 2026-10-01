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
                        Text("Unsend ^[\(prepared.count) message](inflect: true)?")
                            .font(Type.medium(28))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("confirmHeadline")

                        if let eta = model.env.ratePolicy.estimatedDuration(forItemCount: prepared.count) {
                            Text(TimeRemainingCopy.text(for: eta))
                                .font(Type.body(17))
                                .foregroundStyle(Palette.secondaryInk)
                        }

                        Text("This can't be undone. You can leave — don't close Retract.")
                            .font(Type.body(15))
                            .foregroundStyle(Palette.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)

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
            VStack(alignment: .leading, spacing: Spacing.m) {
                Group {
                    if remaining > 0 {
                        Text("Free covers ^[\(remaining) message](inflect: true)")
                    } else {
                        Text("You've used your free cleanups")
                    }
                }
                .font(Type.medium(17))
                .foregroundStyle(Palette.ink)
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
            .padding(Metrics.cardInset)
            .elevated()
        case .filtersRequirePro?:
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Filters are part of Pro")
                    .font(Type.medium(17))
                    .foregroundStyle(Palette.ink)
                Button("Unlock Pro") { showingPaywall = true }
                    .buttonStyle(.primary)
            }
            .padding(Metrics.cardInset)
            .elevated()
        default:
            EmptyView()
        }
    }

    private var nothingToClean: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Nothing to clean here")
                .font(Type.medium(28))
                .foregroundStyle(Palette.ink)
            Text("Everything you picked is already gone, or doesn't match your filters.")
                .foregroundStyle(Palette.secondaryInk)
            Button("Change what's included") { dismiss() }
                .buttonStyle(.secondary)
        }
    }
}
