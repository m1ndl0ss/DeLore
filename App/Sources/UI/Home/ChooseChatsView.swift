import DeLoreCore
import SwiftUI

struct ChooseChatsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let overview: LibraryOverview
    @State private var selection: Set<ConversationID> = []
    @State private var query = ""

    private var chats: [ConversationSummary] {
        let sorted = overview.cleanableConversations.sorted { $0.sentByOwner > $1.sentByOwner }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var selectedCount: Int {
        overview.cleanableConversations.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.sentByOwner }
    }

    var body: some View {
        NavigationStack {
            List(chats) { chat in
                Button {
                    toggle(chat.id)
                } label: {
                    ChatRow(chat: chat, isSelected: selection.contains(chat.id))
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .accessibilityAddTraits(selection.contains(chat.id) ? .isSelected : [])
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .searchable(text: $query, prompt: "Search chats")
            .overlay {
                if chats.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Choose chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.openSetup(.conversations(selection))
                } label: {
                    if selection.isEmpty {
                        Text("Pick at least one chat")
                    } else {
                        Text("Continue with ^[\(selectedCount) message](inflect: true)")
                    }
                }
                .buttonStyle(.primary)
                .disabled(selection.isEmpty)
                .padding(.horizontal, Spacing.screen)
                .padding(.vertical, Spacing.s)
                .background(Palette.background.opacity(0.96))
            }
        }
    }

    private func toggle(_ id: ConversationID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

struct ChatRow: View {
    let chat: ConversationSummary
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Spacing.m) {
            Text(initials)
                .font(Type.medium(16))
                .foregroundStyle(isSelected ? Palette.onAccent : Palette.accent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(isSelected ? Palette.accent : Palette.accent.opacity(0.22)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                    .font(Type.medium(16))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isSelected ? Palette.accentInk : Palette.hairline)
                .accessibilityHidden(true)
        }
        .padding(Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? Palette.surfaceElevated : Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? Palette.accent.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if !chat.messagesLoaded { return "Name only · tap to load" }
        if chat.sentByOwner == 0 { return "Nothing from you" }
        return chat.sentByOwner == 1 ? "1 message from you" : "\(chat.sentByOwner) messages from you"
    }

    private var initials: String {
        let cleaned = chat.title.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let letters = cleaned.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
