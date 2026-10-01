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
                tracker(title: progress.headline, progress: progress)
            case .finished:
                tracker(title: "All set", progress: sync.latest)
            case let .failed(title, message, kind):
                failure(title: title, message: message, kind: kind)
            }
            peopleList(
                titles: titles,
                caption: caption
            )
            Text("This happens on your phone. You can exit — don't close Retract.")
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
        if !sync.latest.isListing { return sync.latest.foundTitles }
        let fromSync = sync.latest.foundTitles
        if !fromSync.isEmpty { return fromSync }
        return model.overview?.conversations.map(\.title) ?? []
    }

    private var caption: String {
        if titles.isEmpty && !failed { return "Names land here as we find them" }
        if failed { return "Kept on this phone · \(titles.count)" }
        if !sync.latest.isListing { return sync.latest.displayChat ?? "This chat" }
        return "Found so far · \(titles.count)"
    }

    private func tracker(title: String, progress: InboxReadProgress) -> some View {
        VStack(spacing: Spacing.s) {
            Text(title)
                .font(Type.medium(20))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)

            Text(progress.detail)
                .font(Type.medium(15))
                .foregroundStyle(Palette.accent)
                .contentTransition(.numericText())
                .animation(.snappy, value: progress.sendsFound + progress.chatsFound)
                .accessibilityLabel(Text(progress.detail))

            LoreProgressBar(fraction: progress.fraction)
                .frame(maxWidth: 280)
        }
    }

    private func failure(title: String, message: String, kind: InboxSyncModel.Kind) -> some View {
        VStack(spacing: Spacing.s) {
            Text(title)
                .font(Type.medium(20))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
            switch kind {
            case .holdOff:
                overlayChoices("Keep going", { model.retryInboxNow() }, "I'll wait") { model.acceptInboxHoldOff(later: false) }
            case .reconnect:
                overlayChoices("Sign in again", { model.signInAgainFromSync() }, "Not now") { model.dismissSync() }
            case .verify:
                overlayChoices("I'll handle it", { model.dismissSync() }, "Not now") { model.dismissSync() }
            case .offline:
                overlayChoices("Try again", { model.retryInboxWhenAllowed() }, "Not now") { model.dismissSync() }
            }
        }
    }

    private func overlayChoices(_ primary: String, _ onPrimary: @escaping () -> Void, _ secondary: String, _ onSecondary: @escaping () -> Void) -> some View {
        HStack(spacing: Spacing.s) {
            overlayPrimary(primary, action: onPrimary)
            overlaySecondary(secondary, action: onSecondary)
        }
    }

    private func overlayPrimary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(Type.medium(15))
            .foregroundStyle(Palette.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Palette.accent))
    }

    private func overlaySecondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(Type.medium(15))
            .foregroundStyle(Palette.secondaryInk)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
    }

    private func peopleList(titles: [String], caption: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(caption)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.secondaryInk)
            if titles.isEmpty {
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(titles.enumerated()).reversed(), id: \.offset) { index, name in
                            FoundPersonRow(name: name, newest: index == titles.count - 1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct FoundPersonRow: View {
    let name: String
    let newest: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(personInitial(name))
                .font(Type.medium(14))
                .foregroundStyle(Palette.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Palette.accent.opacity(0.22)))
                .accessibilityHidden(true)
            Text(name)
                .font(Type.medium(16))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if newest {
                Text("new")
                    .font(Type.medium(11))
                    .foregroundStyle(Palette.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(newest ? Palette.surfaceElevated : Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(newest ? Palette.accent.opacity(newest ? 0.7 : 0.45) : Color.clear, lineWidth: 1)
        )
        .scaleEffect(newest ? 1.015 : 1)
        .animation(.spring(duration: 0.28), value: newest)
    }
}

private func personInitial(_ name: String) -> String {
    let cleaned = name.trimmingCharacters(in: CharacterSet(charactersIn: "@ ").union(.whitespaces))
    guard let first = cleaned.first else { return "?" }
    return String(first).uppercased()
}
