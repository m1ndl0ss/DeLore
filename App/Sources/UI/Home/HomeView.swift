import DeLoreCore
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header

                if let session = model.session, !session.isFinished {
                    PausedSessionCard(progress: session.progress) { model.isSessionPresented = true }
                }

                if let overview = model.overview {
                    counts(overview)
                    if !model.env.hasLiveSession {
                        ReconnectNotice { model.beginLogin(.reconnect) }
                    }
                    actions(overview)
                } else if model.isLoadingOverview {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    Card {
                        Text("We couldn't read your DMs")
                            .font(.title(.headline))
                        Text("Connect Instagram again to continue.")
                            .foregroundStyle(Palette.secondaryInk)
                        Button("Connect Instagram") { model.showConnect() }
                            .buttonStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.xl)
        }
        .refreshable { await model.reloadOverview() }
    }

    private var header: some View {
        HStack {
            Wordmark()
            Spacer()
            if model.entitlements.isPro {
                Pill(text: "Pro")
            }
            Button {
                model.sheet = .settings
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("You and settings")
            .accessibilityIdentifier("settings")
        }
        .padding(.top, Spacing.m)
    }

    private func counts(_ overview: LibraryOverview) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Your DMs")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(Palette.secondaryInk)
            Text(overview.sentByOwner.formatted())
                .font(.system(size: 76, weight: .black, design: .rounded))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .foregroundStyle(Palette.ink)
                .contentTransition(.numericText())
                .accessibilityIdentifier("messageCount")
            Group {
                if overview.sentByOwner == 1 {
                    Text("message you sent, across ^[\(overview.cleanableConversations.count) chat](inflect: true).")
                } else {
                    Text("messages you sent, across ^[\(overview.cleanableConversations.count) chat](inflect: true).")
                }
            }
            .font(.body)
            .foregroundStyle(Palette.secondaryInk)
            if let quip = quip(for: overview.sentByOwner) {
                Text(quip)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Palette.accentInk)
                    .padding(.top, Spacing.xs)
            }
        }
        .padding(.top, Spacing.l)
        .accessibilityElement(children: .combine)
    }

    private func quip(for count: Int) -> LocalizedStringKey? {
        switch count {
        case 0: return "You're all cleaned up."
        case 1..<500: return "Light lore. Easy clean."
        case 500..<5_000: return "That's a lot of lore."
        default: return "That's a LOT of lore."
        }
    }

    private func actions(_ overview: LibraryOverview) -> some View {
        VStack(spacing: Spacing.s) {
            Button("Clean up") { model.openSetup(.everything) }
                .buttonStyle(.primary)
                .disabled(overview.sentByOwner == 0)
                .accessibilityIdentifier("cleanUp")
            Button("Choose chats") {
                if model.hasUnfinishedSession { model.openSetup(.everything) } else { model.sheet = .chooseChats }
            }
            .buttonStyle(.secondary)
            .disabled(overview.sentByOwner == 0)
            Button("See what's included") { model.sheet = .included }
                .buttonStyle(.secondary)
            Button("Refresh chats") { model.refreshChats() }
                .buttonStyle(.text)
                .padding(.top, Spacing.s)
        }
        .padding(.top, Spacing.m)
    }
}

private struct PausedSessionCard: View {
    let progress: CleanupProgress
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Spacing.m) {
                Image(systemName: progress.status == .running ? "sparkles" : "pause.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Palette.onVolt)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.status == .running ? "Cleaning in progress" : "Cleanup paused")
                        .font(.title(.headline))
                    Text("^[\(progress.remaining) message](inflect: true) to go")
                        .font(.subheadline)
                }
                .foregroundStyle(Palette.onVolt)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Palette.onVolt)
                    .accessibilityHidden(true)
            }
            .padding(Spacing.m)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.volt))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the cleanup")
    }
}

private struct ReconnectNotice: View {
    var reconnect: () -> Void

    var body: some View {
        Card {
            Text("Instagram signed you out")
                .font(.title(.headline))
                .foregroundStyle(Palette.ink)
            Text("Reconnect to keep cleaning. Your progress is still on this phone.")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reconnect Instagram", action: reconnect)
                .buttonStyle(.secondary)
        }
    }
}
