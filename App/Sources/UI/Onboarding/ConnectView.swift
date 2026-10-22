import SwiftUI

struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack {
                Wordmark()
                Spacer()
                if model.env.hasLibrary {
                    CloseButton { model.returnHome() }
                }
            }

            Spacer()

            LoreHeadline()
            Text("Find who you talked to. Retract what you sent. It stays on this phone.")
                .font(Type.body(17))
                .foregroundStyle(Palette.secondaryInk)
                .appearRise(shown, delay: 0.06)
            Button("Open Instagram.com") { model.beginLogin(.connect) }
                .buttonStyle(.primary)
                .accessibilityHint("Opens Instagram.com’s sign-in page")
                .accessibilityIdentifier("connectInstagram")
                .appearRise(shown, delay: 0.12)
            Text("Login stays on this phone. We never see your password.")
                .font(Type.body(14))
                .foregroundStyle(Palette.secondaryInk)
                .appearRise(shown, delay: 0.16)

            Spacer()

            Text("If Instagram asks you to verify, finish it there. We never skip that.")
                .font(Type.body(13))
                .foregroundStyle(Palette.tertiaryInk)
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.vertical, Spacing.m)
        .screenBackground()
        .onAppear {
            shown = true
        }
    }
}
