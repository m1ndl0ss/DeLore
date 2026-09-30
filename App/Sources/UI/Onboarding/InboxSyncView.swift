import DeLoreCore
import SwiftUI

struct InboxSyncView: View {
    @Environment(AppModel.self) private var model
    let sync: InboxSyncModel

    var body: some View {
        VStack(spacing: Spacing.m) {
            HStack {
                Wordmark()
                Spacer()
                if showsClose {
                    CloseButton { model.dismissSync() }
                }
            }
            switch sync.phase {
            case let .running(progress):
                tracker(
                    title: progress.isListing ? "Finding who you talked to…" : "Reading selected chats…",
                    progress: progress
                )
            case .finished:
                tracker(title: "All set", progress: sync.latest)
            case let .failed(title, message, kind):
                failure(title: title, message: message, kind: kind)
            }
            if !titles.isEmpty {
                peopleList(
                    titles: titles,
                    caption: failed ? "Kept on this phone" : "Found so far"
                )
            } else {
                Spacer()
            }
            Text("This happens on your phone. Nothing is uploaded.")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.vertical, Spacing.m)
        .screenBackground()
        .interactiveDismissDisabled()
    }

    private var showsClose: Bool { true }

    private var failed: Bool {
        if case .failed = sync.phase { return true }
        return false
    }

    private var titles: [String] {
        let fromSync = sync.latest.foundTitles
        if !fromSync.isEmpty { return fromSync }
        return model.overview?.conversations.map(\.title) ?? []
    }

    private func tracker(title: LocalizedStringKey, progress: InboxReadProgress) -> some View {
        VStack(spacing: Spacing.s) {
            Text(title)
                .font(.title(.title2))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)

            Text(progress.isListing
                 ? "\(progress.chatsFound.formatted()) people so far"
                 : "\(progress.chatsRead.formatted()) / \((progress.chatsTotal ?? 0).formatted()) chats")
                .font(Type.medium(16))
                .foregroundStyle(Palette.accent)
                .contentTransition(.numericText())
                .animation(.snappy, value: progress.chatsRead + progress.chatsFound)
                .accessibilityLabel(progress.isListing
                    ? Text("\(progress.chatsFound) people so far")
                    : Text("\(progress.chatsRead) of \(progress.chatsTotal ?? 0) chats"))

            LoreProgressBar(fraction: progress.fraction)
                .frame(maxWidth: 280)

            if progress.sendsFound > 0 {
                Text("\(progress.sendsFound.formatted()) of your sends")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
            }
        }
    }

    private func failure(title: String, message: String, kind: InboxSyncModel.Kind) -> some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .accessibilityHidden(true)
            VStack(spacing: Spacing.s) {
                Text(title)
                    .font(.title(.title2))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.body)
                    .foregroundStyle(Palette.secondaryInk)
                    .multilineTextAlignment(.center)
            }
            switch kind {
            case .holdOff:
                Button("Keep going") { model.retryInboxNow() }
                    .buttonStyle(.connect)
                Button("I'll wait") { model.acceptInboxHoldOff(later: false) }
                    .buttonStyle(.text)
            case .reconnect:
                Button("Sign in again") { model.signInAgainFromSync() }
                    .buttonStyle(.connect)
                Button("Not now") { model.dismissSync() }
                    .buttonStyle(.text)
            case .verify:
                Button("I'll handle it") { model.dismissSync() }
                    .buttonStyle(.connect)
                Button("Not now") { model.dismissSync() }
                    .buttonStyle(.text)
            case .offline:
                Button("Try again") { model.retryInboxWhenAllowed() }
                    .buttonStyle(.connect)
                Button("Not now") { model.dismissSync() }
                    .buttonStyle(.text)
            }
        }
    }

    private func peopleList(titles: [String], caption: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(caption)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.secondaryInk)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(titles.enumerated()).reversed(), id: \.offset) { _, name in
                        Text(name)
                            .font(Type.medium(16))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Palette.surface)
                            )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
