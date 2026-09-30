import SwiftUI

struct TermsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                ForEach(Array(LegalCopy.terms.enumerated()), id: \.offset) { _, section in
                    Card {
                        Text(section.title)
                            .font(.title(.headline))
                            .foregroundStyle(Palette.ink)
                        Text(section.body)
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Spacing.screen)
        }
        .screenBackground()
        .navigationTitle("Terms of use")
        .navigationBarTitleDisplayMode(.inline)
    }
}
