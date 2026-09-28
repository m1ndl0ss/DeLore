import SwiftUI

struct ConnectView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack {
                    Wordmark()
                    Spacer()
                    if model.env.hasLibrary {
                        CloseButton { model.returnHome() }
                    }
                }
                .padding(.top, Spacing.m)

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Connect Instagram")
                        .font(.display(.largeTitle))
                        .foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Sign in with Instagram. You'll use Instagram's own page — we never see your password.")
                        .font(.body)
                        .foregroundStyle(Palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card {
                    PromiseRow(symbol: "key.slash", title: "We never see your password", detail: "You type it into Instagram, not into DeLore.")
                    PromiseRow(symbol: "person.fill.checkmark", title: "Only messages you sent", detail: "Other people's messages are never touched.")
                    PromiseRow(symbol: "iphone", title: "Your login stays on this phone", detail: "Nothing is sent to a DeLore server.")
                    PromiseRow(symbol: "eye.slash", title: "Message text is never saved", detail: "We keep dates and message types, not what you said.")
                }

                Text("If Instagram asks you to verify, complete it there. We won't skip that check.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.xl)
        }
        .safeAreaInset(edge: .bottom) {
            Button("Connect Instagram") { model.beginLogin(.connect) }
                .buttonStyle(.primary)
                .accessibilityHint("Opens Instagram's sign-in page")
                .accessibilityIdentifier("connectInstagram")
                .padding(.horizontal, Spacing.screen)
                .padding(.vertical, Spacing.s)
                .background(Palette.background.opacity(0.96))
        }
    }
}
