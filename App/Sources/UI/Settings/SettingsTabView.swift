import DeLoreCore
import SwiftUI

struct SettingsTabView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingErase = false
    @State private var restoreMessage: LocalizedStringKey?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("Settings")
                    .font(Type.medium(26))
                    .foregroundStyle(Palette.ink)

                HStack(spacing: Spacing.m) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Instagram")
                            .font(Type.medium(17))
                            .foregroundStyle(Palette.ink)
                        Text(
                            model.env.hasLiveSession
                                ? "Connected · stays on this phone"
                                : (model.isDemoMode ? "Sample inbox · not a real account" : "Not connected")
                        )
                            .font(Type.body(14))
                            .foregroundStyle(model.env.hasLiveSession || model.isDemoMode ? Palette.accent : Palette.secondaryInk)
                    }
                    Spacer()
                    if model.env.hasLiveSession || model.isDemoMode {
                        Button {
                            Task { await model.logOutInstagram() }
                        } label: {
                            Text("Log out")
                                .font(Type.medium(15))
                                .foregroundStyle(Palette.danger)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Palette.danger.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            model.beginLogin(.connect)
                        } label: {
                            Text("Connect")
                                .font(Type.medium(15))
                                .foregroundStyle(Palette.onAccent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Palette.accent))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Metrics.cardInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .elevated()

                VStack(spacing: 0) {
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

                    divider
                    Button("Restore purchases") {
                        Task {
                            if await model.entitlements.restore() {
                                restoreMessage = model.entitlements.isPro ? "Purchases restored." : "No Pro plan on this Apple ID."
                            } else {
                                restoreMessage = "App Store isn’t reachable."
                            }
                        }
                    }
                    .font(Type.body(17))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
                    .padding(.horizontal, Metrics.cardInset)

                    if let restoreMessage {
                        Text(restoreMessage)
                            .font(Type.body(13))
                            .foregroundStyle(Palette.secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Metrics.cardInset)
                            .padding(.bottom, Spacing.s)
                    }
                }
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
