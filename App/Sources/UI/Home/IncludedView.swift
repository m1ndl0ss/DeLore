import DeLoreCore
import SwiftUI

struct IncludedView: View {
    @Environment(\.dismiss) private var dismiss
    let overview: LibraryOverview

    private var skippedChats: Int { overview.conversations.filter(\.ownershipAmbiguous).count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Card {
                        Text("Messages you sent")
                            .font(.title(.headline))
                            .foregroundStyle(Palette.ink)
                        KindRow(symbol: "text.bubble.fill", title: "Texts", count: overview.sentByKind[.text] ?? 0)
                        KindRow(symbol: "photo.fill", title: "Photos & videos", count: overview.sentByKind[.media] ?? 0)
                        KindRow(symbol: "link", title: "Links & shared posts", count: overview.sentByKind[.link] ?? 0)
                        KindRow(symbol: "waveform", title: "Voice messages", count: overview.sentByKind[.voice] ?? 0)
                        if let other = overview.sentByKind[.other], other > 0 {
                            KindRow(symbol: "ellipsis.bubble.fill", title: "Everything else", count: other)
                        }
                    }

                    Card {
                        Label("Messages from others: never touched", systemImage: "lock.fill")
                            .font(.title(.headline))
                            .foregroundStyle(Palette.ink)
                        Text("^[\(overview.receivedFromOthers) message](inflect: true) other people sent you stay exactly where they are. Only you can clean what you sent.")
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if skippedChats > 0 {
                        Card {
                            Label("Some chats are left out", systemImage: "questionmark.circle.fill")
                                .font(.title(.headline))
                                .foregroundStyle(Palette.ink)
                            Text("In ^[\(skippedChats) chat](inflect: true) we can't tell for sure which messages are yours (like when someone shares your name), so we leave them alone.")
                                .font(.subheadline)
                                .foregroundStyle(Palette.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Text("Counts come from the chats we read on this phone. Refresh chats to pick up newer messages. Message requests aren't included.")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryInk)
                }
                .padding(Spacing.screen)
            }
            .screenBackground()
            .navigationTitle("What's included")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct KindRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let count: Int

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
                .foregroundStyle(Palette.ink)
            Spacer()
            Text(count.formatted())
                .font(.system(.body, design: .rounded, weight: .bold))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
