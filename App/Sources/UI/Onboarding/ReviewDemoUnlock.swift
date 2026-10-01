import SwiftUI

/// Hidden App Review unlock. Sighted users never see a control; seven taps on the
/// wordmark (or the VoiceOver action) loads fake chats without Instagram.
struct ReviewDemoUnlock: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var taps = 0
    @State private var windowStart = Date.distantPast

    func body(content: Content) -> some View {
        content
            .onTapGesture { registerTap() }
            .accessibilityAction(named: "Load sample inbox") {
                model.openSampleInbox()
            }
    }

    private func registerTap() {
        guard !model.env.hasLiveSession, !model.isDemoMode else { return }
        let now = Date()
        if now.timeIntervalSince(windowStart) > 2 {
            taps = 1
            windowStart = now
        } else {
            taps += 1
        }
        if taps >= 7 {
            taps = 0
            model.openSampleInbox()
        }
    }
}

extension View {
    func reviewDemoUnlock() -> some View {
        modifier(ReviewDemoUnlock())
    }
}
