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
                }

                Card {
                    Text("What stays on this phone")
                        .font(.title(.headline))
                    Text("Your chat names, and the date and type of each message you sent. Never what the messages say. It's encrypted by iOS, kept out of backups, and deleted when you tap Disconnect & delete my data.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card {
                    Text("What leaves this phone")
                        .font(.title(.headline))
                    Text("Nothing from your DMs. We don't run servers that receive your data, and there's no tracking or ads. Purchases are handled by Apple.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card {
                    Text("Your password")
                        .font(.title(.headline))
                    Text("We never ask for it. You download your data from Instagram yourself, then choose the file here.")
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
