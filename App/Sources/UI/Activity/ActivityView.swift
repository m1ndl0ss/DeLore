import DeLoreCore
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("Activity")
                    .font(Type.medium(26))
                    .foregroundStyle(Palette.ink)

                if model.history.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("Nothing unsent yet.")
                            .font(Type.medium(17))
                            .foregroundStyle(Palette.ink)
                        Text("When you clean, chats show up here. Message text never leaves this phone.")
                            .font(Type.body(15))
                            .foregroundStyle(Palette.secondaryInk)
                    }
                    .padding(Metrics.cardInset)
                    .elevated()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(groupedHistory.enumerated()), id: \.element.id) { index, group in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.title)
                                        .font(Type.medium(16))
                                    Text(group.detail)
                                        .font(Type.body(13))
                                        .foregroundStyle(Palette.secondaryInk)
                                }
                                Spacer()
                                Text("\(group.count)")
                                    .font(Type.medium(16))
                                    .foregroundStyle(Palette.accent)
                            }
                            .padding(.horizontal, Metrics.cardInset)
                            .padding(.vertical, 14)
                            if index < groupedHistory.count - 1 {
                                Rectangle()
                                    .fill(Palette.hairline)
                                    .frame(height: 0.5)
                                    .padding(.horizontal, Metrics.cardInset)
                            }
                        }
                    }
                    .elevated()
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.top, Spacing.m)
            .padding(.bottom, Spacing.xl)
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .task { await model.reloadOverview() }
    }

    private var groupedHistory: [HistoryGroup] {
        let titles = Dictionary(uniqueKeysWithValues: (model.overview?.conversations ?? []).map { ($0.id.rawValue, $0.title) })
        let grouped = Dictionary(grouping: model.history, by: \.conversationID)
        return grouped.map { id, entries in
            let kinds = Dictionary(grouping: entries, by: \.kind).map { "\(Self.label($0.key)) ×\($0.value.count)" }.sorted()
            return HistoryGroup(
                id: id,
                title: titles[id] ?? "A chat",
                count: entries.count,
                detail: kinds.joined(separator: " · ")
            )
        }.sorted { $0.count > $1.count }
    }

    private static func label(_ kind: MessageKind) -> String {
        switch kind {
        case .text: return "Texts"
        case .media: return "Photos"
        case .link: return "Links"
        case .voice: return "Voice"
        case .other: return "Other"
        }
    }
}

private struct HistoryGroup: Identifiable {
    let id: String
    let title: String
    let count: Int
    let detail: String
}
