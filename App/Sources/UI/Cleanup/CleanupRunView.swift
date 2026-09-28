import DeLoreCore
import SwiftUI

struct CleanupRunView: View {
    @Environment(AppModel.self) private var model
    let session: CleanupSessionModel
    @State private var confirmingCancel = false

    var body: some View {
        Group {
            if session.isFinished {
                CleanupDoneView(session: session)
            } else {
                running
            }
        }
        .screenBackground()
        .animation(.easeInOut, value: session.isFinished)
        .interactiveDismissDisabled(session.isRunning)
    }

    private var running: some View {
        let progress = session.progress
        let copy = session.copy
        return VStack(alignment: .leading, spacing: Spacing.l) {
            HStack {
                Wordmark()
                Spacer()
                if !session.isRunning {
                    Button {
                        model.isSessionPresented = false
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(.headline, weight: .bold))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Back to home")
                }
            }
            .padding(.top, Spacing.m)

            Spacer(minLength: Spacing.m)

            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(copy.headline)
                    .font(.display(.title))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("runHeadline")

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(progress.processed.formatted())
                        .font(.system(size: 56, weight: .black, design: .rounded))
                        .contentTransition(.numericText(value: Double(progress.processed)))
                        .animation(.snappy, value: progress.processed)
                    Text("/ \(progress.total.formatted())")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(Palette.secondaryInk)
                }
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(progress.processed) of \(progress.total) messages cleaned"))

                LoreProgressBar(fraction: progress.fraction)

                if session.isRunning {
                    Text(TimeRemainingCopy.text(for: progress.estimatedSecondsRemaining))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Palette.secondaryInk)
                }

                if let message = copy.message {
                    Card {
                        Label {
                            Text(message)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: copy.tone == .caution ? "shield.lefthalf.filled" : "info.circle.fill")
                                .foregroundStyle(copy.tone == .caution ? Palette.accentInk : Palette.secondaryInk)
                        }
                        .font(.subheadline)
                        .foregroundStyle(Palette.ink)
                        if let until = session.tryAgainAt ?? progress.resumeNotBefore, until > Date(), progress.status.pauseReason != nil {
                            Text("You can try again after \(until.formatted(date: .omitted, time: .shortened)).")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Palette.secondaryInk)
                        }
                    }
                }
            }

            Spacer(minLength: Spacing.m)

            VStack(spacing: Spacing.s) {
                Label("Keep the app open while cleaning.", systemImage: "iphone")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.secondaryInk)
                    .frame(maxWidth: .infinity)

                primaryAction(copy.action)

                Button("Cancel cleanup", role: .destructive) { confirmingCancel = true }
                    .buttonStyle(TextButtonStyle(tint: Palette.danger))
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("cancelCleanup")
            }
            .padding(.bottom, Spacing.m)
        }
        .padding(.horizontal, Spacing.screen)
        .confirmationDialog("Stop cleaning?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Stop cleaning", role: .destructive) {
                Task { await session.cancel() }
            }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("Messages already unsent stay unsent. The rest stay where they are.")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: progress.status)
    }

    @ViewBuilder
    private func primaryAction(_ action: CleanupStatusCopy.Action) -> some View {
        switch action {
        case .pause:
            Button {
                Task { await session.pause() }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .buttonStyle(.secondary)
            .accessibilityIdentifier("pause")
        case .resume, .tryAgain:
            Button {
                Task { await session.resume() }
            } label: {
                if action == .resume {
                    Label("Resume", systemImage: "play.fill")
                } else {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.primary)
            .disabled(session.isBusy)
            .accessibilityIdentifier("resume")
        case .resumeAfterVerifying:
            Button {
                Task { await session.resume(userResolvedIssue: true) }
            } label: {
                Text("I've done that, continue")
            }
            .buttonStyle(.primary)
            .disabled(session.isBusy)
        case .none:
            EmptyView()
        }
    }
}

struct CleanupDoneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: CleanupSessionModel
    @State private var appeared = false

    private var progress: CleanupProgress { session.progress }
    private var wasCancelled: Bool { progress.status == .cancelled }
    private var notCleaned: Int { progress.failed + progress.skipped }

    var body: some View {
        VStack(spacing: Spacing.l) {
            Spacer()

            Image(systemName: wasCancelled ? "stop.fill" : "checkmark")
                .font(.system(size: 52, weight: .black))
                .foregroundStyle(Palette.onVolt)
                .frame(width: 128, height: 128)
                .background(Circle().fill(Palette.volt))
                .scaleEffect(appeared ? 1 : 0.4)
                .opacity(appeared ? 1 : 0)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.s) {
                Group {
                    if wasCancelled {
                        Text("Cleanup stopped")
                    } else {
                        Text("Fresh start ✨")
                    }
                }
                .font(.display())
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("doneHeadline")

                Text("^[\(progress.completed) message](inflect: true) cleaned.")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(Palette.secondaryInk)

                if notCleaned > 0 {
                    Text("^[\(notCleaned) message](inflect: true) couldn't be unsent. They're still there.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryInk)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()

            VStack(spacing: Spacing.s) {
                Button("Done") {
                    Task { await model.closeSession() }
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier("done")
                Button("Clean another chat") {
                    Task { await model.closeSession(thenChooseChats: true) }
                }
                .buttonStyle(.text)
            }
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.bottom, Spacing.m)
        .sensoryFeedback(.success, trigger: appeared)
        .onAppear {
            withAnimation(reduceMotion ? .none : .spring(response: 0.5, dampingFraction: 0.6)) { appeared = true }
        }
    }
}

struct CleanupUnavailableView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack {
                Spacer()
                CloseButton { dismiss() }
            }
            Text("Unsending isn't available yet")
                .font(.display(.title))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Instagram doesn't currently offer a way for apps to unsend your messages for you, and we won't use workarounds that could put your account at risk.")
                .foregroundStyle(Palette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Card {
                PromiseRow(symbol: "checkmark.seal.fill", title: "Your scan is ready", detail: "See exactly how much lore there is, chat by chat.")
                PromiseRow(symbol: "lock.fill", title: "Still private", detail: "Nothing from your DMs left your phone.")
            }
            Spacer()
            Button("Got it") { dismiss() }
                .buttonStyle(.primary)
        }
        .padding(Spacing.screen)
        .screenBackground()
        .presentationDetents([.large])
    }
}
