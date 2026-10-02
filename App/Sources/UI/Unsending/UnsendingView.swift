import DeLoreCore
import SwiftUI

struct UnsendingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var query = ""
    @State private var selection: Set<ConversationID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            header
            if let session = model.session, !session.isFinished {
                ActiveCleanupCard(progress: session.progress) { model.isSessionPresented = true }
                    .padding(.horizontal, Spacing.screen)
            }
            if let overview = model.overview, !overview.conversations.isEmpty {
                people(overview)
            } else {
                ScrollView {
                    content
                        .padding(.horizontal, Spacing.screen)
                        .padding(.top, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.top, Spacing.m)
        .opacity(shown ? 1 : 0)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.28), value: shown)
        .screenBackground()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Spacing.m) {
                if let overview = model.overview, !overview.conversations.isEmpty {
                    Button(actionLabel(for: overview)) { model.retractWith(selection) }
                        .buttonStyle(.primary)
                        .disabled(!canAct(overview) || (!model.env.isCleanupAvailable && !model.hasUnfinishedSession))
                        .padding(.horizontal, Spacing.screen)
                } else if model.overview == nil && !model.isLoadingOverview {
                    Button(model.env.hasLiveSession ? "Find people" : "Connect Instagram") { model.showConnect() }
                        .buttonStyle(.connect)
                        .accessibilityIdentifier("connectInstagram")
                        .padding(.horizontal, Spacing.screen)
                }
                if !model.entitlements.isPro {
                    UpgradeDock(remaining: model.entitlements.remainingFree) {
                        model.sheet = .paywall(.settings)
                    }
                    .padding(.horizontal, Spacing.screen)
                }
            }
            .padding(.bottom, Spacing.s)
            .appearRise(shown, delay: 0.2)
        }
        .onAppear {
            shown = true
            model.deletionAppeared()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            Wordmark()
                .reviewDemoUnlock()
            Spacer(minLength: 12)
            if model.overview != nil && model.env.hasLiveSession {
                Button {
                    model.refreshChats()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh")
            }
            if model.entitlements.isPro {
                Button {
                    model.tab = .settings
                } label: {
                    Pill(text: "Pro")
                }
                .buttonStyle(.plain)
                .padding(.leading, 20)
                .accessibilityLabel("Account")
            }
        }
        .padding(.horizontal, Spacing.screen)
    }

    @ViewBuilder
    private var content: some View {
        if model.overview != nil {
            VStack(alignment: .leading, spacing: Spacing.l) {
                LoreHeadline(text: "No DMs on this account.")
            }
        } else if model.isLoadingOverview {
            loading
        } else if model.env.hasLiveSession {
            scanError
        } else {
            disconnected
        }
    }

    private var disconnected: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            LoreHeadline()
            Text("Find who you talked to. Retract what you sent. It stays on this phone.")
                .font(Type.body(17))
                .foregroundStyle(Palette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            LoreHeadline(text: "Finding who you talked to.")
            Text("This happens on your phone. Nothing is uploaded.")
                .font(Type.body(17))
                .foregroundStyle(Palette.secondaryInk)
            ProgressView()
                .tint(Palette.accent)
                .padding(.top, Spacing.s)
        }
    }

    private var scanError: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            LoreHeadline(text: "Couldn't find your people.")
            Text("Reconnect Instagram and we'll pull the names again.")
                .font(Type.body(17))
                .foregroundStyle(Palette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func people(_ overview: LibraryOverview) -> some View {
        let filtered = filteredPeople(overview)
        return VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                LoreHeadline(text: "Pick who to retract with.")
                HStack(alignment: .firstTextBaseline) {
                    Text("\(overview.conversations.count == 1 ? "1 person" : "\(overview.conversations.count) people") in your DMs. We only load a chat after you pick it.")
                        .font(Type.body(15))
                        .foregroundStyle(Palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    if !selection.isEmpty {
                        Pill(text: "\(selection.count) picked")
                    }
                }
            }
            .padding(.horizontal, Spacing.screen)

            if !model.env.hasLiveSession && !model.isDemoMode {
                expiredSession
                    .padding(.horizontal, Spacing.screen)
            }
            if model.isDemoMode {
                Text("Sample chats for review. Connect Instagram in Settings to use a real account.")
                    .font(Type.body(14))
                    .foregroundStyle(Palette.secondaryInk)
                    .padding(.horizontal, Spacing.screen)
            }

            HStack(spacing: Spacing.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.secondaryInk)
                    .accessibilityHidden(true)
                TextField("Search @username", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.tertiaryInk)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Palette.surface))
            .padding(.horizontal, Spacing.screen)

            if filtered.isEmpty && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No one matches that.")
                    .font(Type.body(15))
                    .foregroundStyle(Palette.secondaryInk)
                    .padding(.horizontal, Spacing.screen)
                Spacer()
            } else {
                List(filtered) { chat in
                    Button {
                        toggle(chat.id)
                    } label: {
                        ChatRow(chat: chat, isSelected: selection.contains(chat.id))
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: Spacing.screen, bottom: 4, trailing: Spacing.screen))
                    .accessibilityAddTraits(selection.contains(chat.id) ? .isSelected : [])
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func filteredPeople(_ overview: LibraryOverview) -> [ConversationSummary] {
        let sorted = overview.conversations.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sorted }
        return sorted.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    private func toggle(_ id: ConversationID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func canAct(_ overview: LibraryOverview) -> Bool {
        !selection.isEmpty
    }

    private func actionLabel(for overview: LibraryOverview) -> String {
        if selection.isEmpty { return "Pick people to retract with" }
        return selection.count == 1 ? "Retract with 1 person" : "Retract with \(selection.count) people"
    }

    private var expiredSession: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Instagram signed you out")
                .font(Type.medium(16))
            Text("Progress is still on this phone. Reconnect to keep cleaning — we won't unsend twice.")
                .font(Type.body(15))
                .foregroundStyle(Palette.secondaryInk)
            Button("Reconnect Instagram") { model.beginLogin(.reconnect) }
                .buttonStyle(.secondary)
                .accessibilityIdentifier("reconnectInstagram")
        }
        .padding(Metrics.cardInset)
        .elevated()
    }
}

struct UpgradeDock: View {
    let remaining: Int
    let upgrade: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(remaining) free unsends")
                    .font(Type.medium(16))
                    .foregroundStyle(Palette.ink)
                Text("Then Pro takes over")
                    .font(Type.body(13))
                    .foregroundStyle(Palette.secondaryInk)
            }
            Spacer(minLength: 0)
            Button("Upgrade", action: upgrade)
                .font(Type.medium(15))
                .foregroundStyle(Palette.onCta)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Palette.cta))
                .shadow(color: Palette.cta.opacity(0.45), radius: 12, y: 4)
                .accessibilityIdentifier("upgrade")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .fill(Palette.surfaceElevated.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.45), lineWidth: 1.2)
        )
        .shadow(color: Palette.accent.opacity(0.18), radius: 20, y: 8)
    }
}

private struct ActiveCleanupCard: View {
    let progress: CleanupProgress
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    Text(progress.status == .running ? "Cleaning now" : "Cleanup paused")
                        .font(Type.medium(16))
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? .none : .easeOut(duration: 0.22), value: progress.status == .running)
                    Spacer()
                    Text("Open")
                        .font(Type.medium(14))
                        .foregroundStyle(Palette.accent)
                }
                LoreProgressBar(fraction: progress.fraction)
                Text(progress.status == .running
                     ? "^[\(progress.remaining) message](inflect: true) to go. You can exit — don't close Retract."
                     : "Resume. We won't unsend twice.")
                    .font(Type.body(14))
                    .foregroundStyle(Palette.secondaryInk)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? .none : .snappy, value: progress.remaining)
            }
            .padding(Metrics.cardInset)
            .elevated()
        }
        .buttonStyle(.plain)
        .scaleEffect(shown ? 1 : 0.97)
        .opacity(shown ? 1 : 0)
        .onAppear {
            guard !reduceMotion else { shown = true; return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { shown = true }
        }
        .accessibilityHint("Opens the cleanup. Resume picks up without unsending twice.")
    }
}
