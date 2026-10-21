import SwiftUI

/// Plain-language privacy explanation. Every claim here must stay true of the code.
struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("We never read your chats.")
                    .font(.title(.headline))
                    .foregroundStyle(Palette.ink)
                Text("Message text never leaves this phone and is never sent to us.")
                    .font(.title(.headline))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Spacing.m) {
                    PromiseRow(symbol: "iphone", title: "Your Instagram content is processed on your phone.")
                    PromiseRow(symbol: "hand.raised.fill", title: "We don't sell your messages.")
                    PromiseRow(symbol: "eye.slash.fill", title: "We don't need your message content to provide the cleanup.")
                    PromiseRow(symbol: "chart.bar.xaxis", title: "No analytics SDK. No ads.")
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
                    Text("Cleanup talks to Instagram from this phone, the same way you would unsend a message yourself. Nothing from your DMs is sent to a Retract server. When you connect Instagram, and when you buy Pro, Retract emails the publisher your Instagram username (and any promo code on purchase) so we know who signed up. Purchases are handled by Apple.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card {
                    Text("Sample data")
                        .font(.title(.headline))
                    Text("Retract may include sample chats for App Review and testing. Sample data is fake, stays on this phone, and never contacts Instagram or a real account.")
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

                Card {
                    Text("Children")
                        .font(.title(.headline))
                    Text("Retract is not directed at children under 13. We do not knowingly collect personal information from children under 13.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card {
                    Text("Your choices")
                        .font(.title(.headline))
                    Text("Disconnect & delete my data clears local Instagram session and library data on this phone, and deletes your server-side usage record (user id, username, free-usage count). You can also request deletion at kandalintsev.com/retract/delete-data. Uninstall also removes local data. Manage or cancel subscriptions in Settings → Apple ID → Subscriptions — deleting the app does not cancel billing by itself.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Retract isn't affiliated with, endorsed by, or connected to Instagram or Meta.")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryInk)
            }
            .foregroundStyle(Palette.ink)
            .padding(Spacing.screen)
        }
        .background(Palette.background)
        .screenBackground()
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
