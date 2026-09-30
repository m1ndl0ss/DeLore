import DeLoreCore
import SwiftUI

struct InboxSyncView: View {
    @Environment(AppModel.self) private var model
    let sync: InboxSyncModel

    var body: some View {
        VStack(spacing: Spacing.l) {
            HStack {
                Wordmark()
                Spacer()
                if showsClose {
                    CloseButton { model.dismissSync() }
                }
            }
            Spacer()
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
            Spacer()
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.vertical, Spacing.m)
        .screenBackground()
        .interactiveDismissDisabled()
    }

    private var showsClose: Bool { true }

    private func tracker(title: LocalizedStringKey, progress: InboxReadProgress) -> some View {
        VStack(spacing: Spacing.l) {
            Text(title)
                .font(.title(.title))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text((progress.isListing ? progress.chatsFound : progress.chatsRead).formatted())
                    .font(Type.medium(48))
                    .contentTransition(.numericText(value: Double(progress.isListing ? progress.chatsFound : progress.chatsRead)))
                    .animation(.snappy, value: progress.chatsRead + progress.chatsFound)
                if !progress.isListing {
                    Text("/ \((progress.chatsTotal ?? 0).formatted())")
                        .font(Type.medium(20))
                        .foregroundStyle(Palette.secondaryInk)
                }
            }
            .foregroundStyle(Palette.ink)
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(progress.isListing
                ? Text("\(progress.chatsFound) people so far")
                : Text("\(progress.chatsRead) of \(progress.chatsTotal ?? 0) chats"))

            Text(progress.isListing ? "people so far" : "chats")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.secondaryInk)

            LoreProgressBar(fraction: progress.fraction)
                .frame(maxWidth: 280)

            if progress.sendsFound > 0 {
                Text("\(progress.sendsFound.formatted()) of your sends")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accent)
            }
            if let chat = progress.displayChat {
                Text("in \(chat)")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
                    .multilineTextAlignment(.center)
            }

            Text("This happens on your phone. Nothing is uploaded.")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
        }
    }

    private func failure(title: String, message: String, kind: InboxSyncModel.Kind) -> some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 56, weight: .semibold))
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
                Button("Try reading") { model.retryInboxNow() }
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
}
