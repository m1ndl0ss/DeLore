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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background.ignoresSafeArea())
        .animation(.easeInOut, value: session.isFinished)
        .interactiveDismissDisabled(session.isRunning)
    }

    private var running: some View {
        let progress = session.progress
        let copy = session.copy
        return VStack(alignment: .leading, spacing: Spacing.l) {
            HStack {
                Button {
                    model.isSessionPresented = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(session.isRunning)
                .opacity(session.isRunning ? 0.35 : 1)
                .accessibilityLabel("Back")
                Spacer()
            }
            .padding(.top, Spacing.s)

            Spacer(minLength: Spacing.m)

            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(copy.headline)
                    .font(Type.medium(28))
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
                        .font(Type.body(15))
                        .foregroundStyle(Palette.secondaryInk)
                }

                if let message = copy.message {
                    Text(message)
                        .font(Type.body(15))
                        .foregroundStyle(Palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Spacing.m)

            VStack(spacing: Spacing.s) {
                Text("You can leave. Don't close Retract.")
                    .font(Type.body(13))
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
            Text("Messages already unsent stay unsent.")
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
                Text("Pause")
            }
            .buttonStyle(.secondary)
            .accessibilityIdentifier("pause")
        case .resume, .tryAgain:
            Button {
                Task { await session.resume() }
            } label: {
                Text(action == .resume ? "Resume" : "Try again")
            }
            .buttonStyle(.primary)
            .disabled(session.isBusy)
            .accessibilityIdentifier("resume")
        case .resumeAfterVerifying:
            Button {
                Task { await session.resume(userResolvedIssue: true) }
            } label: {
                Text("Continue")
            }
            .buttonStyle(.primary)
            .disabled(session.isBusy)
        case .reconnect:
            VStack(spacing: Spacing.s) {
                Button("Reconnect Instagram") { model.beginLogin(.reconnect) }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("reconnectInstagram")
                Button("Continue") {
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
            HStack {
                Button {
                    Task { await model.closeSession() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                Spacer()
            }
            .padding(.top, Spacing.s)

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
                Text(wasCancelled ? "Stopped" : "Done")
                    .font(Type.medium(28))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("doneHeadline")

                if progress.completed > 0 {
                    Text("^[\(progress.completed) message](inflect: true) cleaned.")
                        .font(Type.body(17))
                        .foregroundStyle(Palette.secondaryInk)
                } else if wasCancelled {
                    Text("Nothing cleaned yet.")
                        .font(Type.body(17))
                        .foregroundStyle(Palette.secondaryInk)
                }

                // Cancelled leftovers are not failures — they simply weren't reached.
                if wasCancelled, progress.cancelled > 0 {
                    Text("The rest stay where they are.")
                        .font(Type.body(15))
                        .foregroundStyle(Palette.secondaryInk)
                        .multilineTextAlignment(.center)
                }
                if notCleaned > 0 {
                    Text("^[\(notCleaned) message](inflect: true) couldn't be unsent.")
                        .font(Type.body(15))
                        .foregroundStyle(Palette.secondaryInk)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()

            Button("Done") {
                Task { await model.closeSession() }
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("done")
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
                .font(Type.medium(28))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Cleaning uses Instagram's own Unsend action from this phone. Reconnect your account, then try again.")
                .foregroundStyle(Palette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Got it") { dismiss() }
                .buttonStyle(.primary)
        }
        .padding(Spacing.screen)
        .background(Palette.background.ignoresSafeArea())
        .presentationDetents([.large])
    }
}
