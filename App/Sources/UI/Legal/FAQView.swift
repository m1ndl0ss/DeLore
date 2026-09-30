import SwiftUI

struct FAQView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("If this doesn’t cover it, email \(LegalCopy.supportEmail).")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(LegalCopy.faq.enumerated()), id: \.offset) { _, item in
                    Card {
                        Text(item.question)
                            .font(.title(.headline))
                            .foregroundStyle(Palette.ink)
                        Text(item.answer)
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Link("Email \(LegalCopy.supportEmail)", destination: LegalCopy.supportMailto)
                    .font(Type.medium(16))
                    .foregroundStyle(Palette.accent)
            }
            .padding(Spacing.screen)
        }
        .screenBackground()
        .navigationTitle("FAQ")
        .navigationBarTitleDisplayMode(.inline)
    }
}
