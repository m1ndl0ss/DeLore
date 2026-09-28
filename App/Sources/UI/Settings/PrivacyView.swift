import SwiftUI

/// Plain-language privacy explanation. Every claim here must stay true of the code.
struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    PromiseRow(symbol: "iphone", title: "Your Instagram content is processed on your phone.")
                    PromiseRow(symbol: "hand.raised.fill", title: "We don't sell or store your messages.")
                    PromiseRow(symbol: "eye.slash.fill", title: "We don't need your message content to provide the cleanup.")
                    PromiseRow(symbol: "chart.bar.xaxis", title: "No analytics. No identifiers sent to us.")
                }

                Card {
                    Text("What stays on this phone")
                        .font(.title(.headline))
                    Text("Your Instagram login for this app, your chat names, and the date and type of each message you sent. Never what the messages say. It's encrypted by iOS, kept out of backups, and deleted when you tap Disconnect & delete my data.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card {
                    Text("What leaves this phone")
                        .font(.title(.headline))
                    Text("Cleanup talks to Instagram from this phone, the same way you would unsend a message yourself. Nothing from your DMs is sent to a DeLore server. We don't collect analytics, advertising IDs, or other identifiers. There's no tracking or ads. Purchases are handled by Apple.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card {
                    Text("Your password")
                        .font(.title(.headline))
                    Text("You type it into Instagram's own sign-in page. We never see it, we never store it, and it never leaves this phone through us. After you sign in, Instagram's session stays in the Keychain on this device until you disconnect.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("DeLore isn't affiliated with, endorsed by, or connected to Instagram or Meta.")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryInk)
            }
            .foregroundStyle(Palette.ink)
            .padding(Spacing.screen)
        }
        .screenBackground()
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
