import DeLoreCore
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = Self.snapshot(history: model.history, overview: model.overview)
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                LoreHeadline(text: snapshot.total == 0 ? "Nothing taken back yet." : "What you took back.")

                hero(snapshot)

                if !snapshot.groups.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("By person")
                            .font(Type.medium(13))
                            .foregroundStyle(Palette.secondaryInk)
                        VStack(spacing: Spacing.s) {
                            ForEach(snapshot.groups) { group in
                                personCard(group)
                            }
                        }
                    }
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

    private func hero(_ snapshot: ActivitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.total.formatted())
                    .font(Type.medium(48))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("unsent")
                    .font(Type.medium(17))
                    .foregroundStyle(Palette.accent)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(snapshot.total) unsent")

            if snapshot.total == 0 {
                Text("When you retract, people show up here. Message text never leaves this phone.")
                    .font(Type.body(15))
                    .foregroundStyle(Palette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(heroSubtitle(snapshot))
                    .font(Type.body(15))
                    .foregroundStyle(Palette.secondaryInk)
            }
        }
        .padding(Metrics.cardInset)
        .elevated()
        .accessibilityElement(children: .combine)
    }

    private func personCard(_ group: HistoryGroup) -> some View {
        HStack(spacing: Spacing.m) {
            Text(initials(group.title))
                .font(Type.medium(16))
                .foregroundStyle(Palette.accent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Palette.accent.opacity(0.22)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(Type.medium(16))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text("Unsent \(Self.relativeTime(group.lastCleanedAt))")
                    .font(Type.body(13))
                    .foregroundStyle(Palette.secondaryInk)
            }
            Spacer(minLength: 8)
            Text(group.count.formatted())
                .font(Type.medium(20))
                .monospacedDigit()
                .foregroundStyle(Palette.accent)
        }
        .padding(Metrics.cardInset)
        .elevated()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.title), \(group.count) unsent, last \(Self.relativeTime(group.lastCleanedAt))")
    }

    private func heroSubtitle(_ snapshot: ActivitySnapshot) -> String {
        let people = snapshot.people == 1 ? "1 person" : "\(snapshot.people) people"
        if let last = snapshot.lastCleanedAt {
            return "across \(people) · last \(Self.relativeTime(last))"
        }
        return "across \(people)"
    }

    private func initials(_ title: String) -> String {
        let cleaned = title.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let letters = cleaned.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static func relativeTime(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 45 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static func snapshot(history: [CleanupHistoryEntry], overview: LibraryOverview?) -> ActivitySnapshot {
        let titles = Dictionary(uniqueKeysWithValues: (overview?.conversations ?? []).map { ($0.id.rawValue, $0.title) })
        let grouped = Dictionary(grouping: history, by: \.conversationID)
        let groups = grouped.map { id, entries -> HistoryGroup in
            HistoryGroup(
                id: id,
                title: titles[id] ?? "A chat",
                count: entries.count,
                lastCleanedAt: entries.map(\.cleanedAt).max() ?? .distantPast
            )
        }.sorted {
            if $0.lastCleanedAt != $1.lastCleanedAt { return $0.lastCleanedAt > $1.lastCleanedAt }
            return $0.count > $1.count
        }
        return ActivitySnapshot(
            total: history.count,
            people: groups.count,
            lastCleanedAt: groups.map(\.lastCleanedAt).max(),
            groups: groups
        )
    }
}

private struct ActivitySnapshot {
    let total: Int
    let people: Int
    let lastCleanedAt: Date?
    let groups: [HistoryGroup]
}

private struct HistoryGroup: Identifiable {
    let id: String
    let title: String
    let count: Int
    let lastCleanedAt: Date
}
