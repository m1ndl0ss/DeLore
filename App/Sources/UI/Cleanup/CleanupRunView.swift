import DeLoreCore
import SwiftUI

struct CleanupRunView: View {
    @Environment(AppModel.self) private var model
    let session: CleanupSessionModel
    @State private var confirmingCancel = false

    private var loginBinding: Binding<AppModel.LoginPurpose?> {
        Binding(get: { model.loginPurpose }, set: { model.loginPurpose = $0 })
    }

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
                        .font(Type.medium(48))
                        .contentTransition(.numericText(value: Double(progress.processed)))
                        .animation(.snappy, value: progress.processed)
                    Text("/ \(progress.total.formatted())")
                        .font(Type.medium(20))
                        .foregroundStyle(Palette.secondaryInk)
                }
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(progress.processed) of \(progress.total) messages cleaned"))

                LoreProgressBar(fraction: progress.fraction)

                if progress.remaining > 0 {
                    Text(TimeRemainingCopy.text(for: progress.estimatedSecondsRemaining
                        ?? model.env.ratePolicy.estimatedDuration(forItemCount: progress.remaining)))
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
                Label("Keep Retract open while we clean.", systemImage: "iphone")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.secondaryInk)
                    .frame(maxWidth: .infinity)
                Label("If Instagram asks us to wait, we wait — on purpose, to keep your account safe.", systemImage: "shield.lefthalf.filled")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.secondaryInk)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

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
        .fullScreenCover(item: loginBinding) { purpose in
            InstagramLoginView(
                onComplete: { session in model.handleLogin(session, purpose: purpose) },
                onCancel: { model.cancelLogin() }
            )
            .environment(model)
        }
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
        case .reconnect:
            VStack(spacing: Spacing.s) {
                Button("Reconnect Instagram") { model.beginLogin(.reconnect) }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("reconnectInstagram")
                Button("I've signed in, continue") {
                    Task { await session.resume(userResolvedIssue: true) }
                }
                .buttonStyle(.secondary)
                .disabled(session.isBusy)
                .accessibilityIdentifier("resume")
            }
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
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Palette.onAccent)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Palette.accent))
                .scaleEffect(appeared ? 1 : 0.92)
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
            Text("Sign in to Instagram first")
                .font(.display(.title))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Cleaning uses Instagram's own Unsend action from this phone. Reconnect your account, then try again.")
                .foregroundStyle(Palette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Card {
                PromiseRow(symbol: "key.slash", title: "We never see your password", detail: "You sign in on Instagram's page.")
                PromiseRow(symbol: "lock.fill", title: "Still private", detail: "Your login stays on this phone.")
                PromiseRow(symbol: "chart.bar.xaxis", title: "No analytics", detail: "We don't collect identifiers or usage stats.")
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
