import DeLoreCore
import SwiftUI

struct SettingsTabView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingErase = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("Settings")
                    .font(Type.medium(26))
                    .foregroundStyle(Palette.ink)

                Button {
                    if model.env.hasLiveSession { return }
                    model.beginLogin(.connect)
                } label: {
                    HStack(spacing: Spacing.m) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Instagram")
                                .font(Type.medium(17))
                                .foregroundStyle(Palette.ink)
                            Text(model.env.hasLiveSession ? "Connected · stays on this phone" : "Not connected")
                                .font(Type.body(14))
                                .foregroundStyle(model.env.hasLiveSession ? Palette.accent : Palette.secondaryInk)
                        }
                        Spacer()
                        if !model.env.hasLiveSession {
                            Text("Connect")
                                .font(Type.medium(15))
                                .foregroundStyle(Palette.onAccent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Palette.accent))
                        }
                    }
                    .padding(Metrics.cardInset)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .elevated()

                Button {
                    model.sheet = .paywall(.settings)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Plan")
                                .font(Type.body(17))
                                .foregroundStyle(Palette.ink)
                            Text(model.entitlements.isPro ? "Pro" : "Free · Upgrade")
                                .font(Type.body(14))
                                .foregroundStyle(model.entitlements.isPro ? Palette.accent : Palette.secondaryInk)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.tertiaryInk)
                    }
                    .padding(Metrics.cardInset)
                }
                .buttonStyle(.plain)
                .elevated()

                VStack(spacing: 0) {
                    row(symbol: "hand.raised", title: "Privacy") { model.sheet = .privacy }
                    divider
                    row(symbol: "questionmark.circle", title: "Support") { model.sheet = .support }
                    divider
                    row(symbol: "doc", title: "Terms") { model.sheet = .terms }
                }
                .elevated()

                Button("Delete my data", role: .destructive) { confirmingErase = true }
                    .font(Type.medium(16))
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
                    .padding(.horizontal, Metrics.cardInset)
                    .elevated()
                    .accessibilityIdentifier("eraseData")
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.top, Spacing.m)
            .padding(.bottom, Spacing.xl)
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .confirmationDialog("Delete everything on this phone?", isPresented: $confirmingErase, titleVisibility: .visible) {
            Button("Delete my data", role: .destructive) {
                Task { await model.eraseEverything() }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Login, chats, history and progress leave this phone. Already unsent messages stay unsent. Purchases stay with your Apple ID.")
        }
        .task { await model.reloadOverview() }
    }

    private var divider: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 0.5)
            .padding(.horizontal, Metrics.cardInset)
    }

    private func row(symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.secondaryInk)
                    .frame(width: 24)
                Text(title)
                    .font(Type.body(17))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.tertiaryInk)
            }
            .frame(minHeight: Metrics.rowHeight)
            .padding(.horizontal, Metrics.cardInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
