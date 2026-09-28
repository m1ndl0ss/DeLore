import SwiftUI

struct InboxSyncView: View {
    @Environment(AppModel.self) private var model
    let sync: InboxSyncModel

    var body: some View {
        VStack(spacing: Spacing.l) {
            HStack {
                Spacer()
                if !isFinished {
                    CloseButton { model.dismissSync() }
                }
            }
            Spacer()
            switch sync.phase {
            case let .running(fraction):
                progress(title: "Reading your DMs…", fraction: fraction)
            case .finished:
                progress(title: "All set", fraction: 1)
            case let .failed(title, message):
                failure(title: title, message: message)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.vertical, Spacing.m)
        .screenBackground()
        .interactiveDismissDisabled()
    }

    private var isFinished: Bool {
        if case .finished = sync.phase { return true }
        return false
    }

    private func progress(title: LocalizedStringKey, fraction: Double) -> some View {
        VStack(spacing: Spacing.l) {
            ZStack {
                Circle().stroke(Palette.hairline, lineWidth: 14)
                Circle()
                    .trim(from: 0, to: max(0.04, fraction))
                    .stroke(Palette.volt, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut, value: fraction)
            }
            .frame(width: 140, height: 140)
            .accessibilityHidden(true)

            VStack(spacing: Spacing.s) {
                Text(title)
                    .font(.title(.title))
                    .foregroundStyle(Palette.ink)
                Text("This happens on your phone. Nothing is uploaded.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func failure(title: String, message: String) -> some View {
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
            Button("Try again") {
                model.dismissSync()
                model.refreshChats()
            }
                .buttonStyle(.primary)
            Button("Close") { model.dismissSync() }
                .buttonStyle(.text)
        }
    }
}
