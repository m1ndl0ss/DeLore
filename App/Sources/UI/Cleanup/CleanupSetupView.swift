import DeLoreCore
import SwiftUI

struct CleanupSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var setup: CleanupSetupModel
    @State private var showingChats = false
    @State private var showingPaywall = false

    init(setup: CleanupSetupModel) {
        _setup = State(initialValue: setup)
    }

    private var isPro: Bool { model.entitlements.isPro }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    scopeSection
                    ownershipCard
                    if model.env.configuration.advancedFilters {
                        filtersSection
                    }
                }
                .padding(Spacing.screen)
            }
            .screenBackground()
            .navigationTitle("Clean up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await setup.prepare() }
                } label: {
                    if setup.isPreparing {
                        ProgressView().tint(Palette.onVolt)
                    } else {
                        Text("Review")
                    }
                }
                .buttonStyle(.primary)
                .disabled(!setup.canContinue || setup.isPreparing)
                .accessibilityIdentifier("review")
                .padding(.horizontal, Spacing.screen)
                .padding(.vertical, Spacing.s)
                .background(Palette.background.opacity(0.96))
            }
            .navigationDestination(isPresented: preparedBinding) {
                ConfirmCleanupView(setup: setup)
            }
            .sheet(isPresented: $showingChats) {
                ChatPicker(overview: setup.overview, selection: $setup.chosen)
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(context: .filters)
                    .environment(model)
            }
            .alert("Something went wrong", isPresented: failedBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("We couldn't get your messages ready. Try again.")
            }
        }
        .onDisappear {
            // Leaving without confirming: don't keep an unconfirmed job around.
            if model.session == nil { setup.discardPrepared() }
        }
    }

    private var preparedBinding: Binding<Bool> {
        Binding(get: { setup.prepared != nil }, set: { if !$0 { setup.discardPrepared() } })
    }

    private var failedBinding: Binding<Bool> {
        Binding(get: { setup.failed }, set: { if !$0 { setup.clearFailure() } })
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("What should go?")
                .font(.title(.title3))
                .foregroundStyle(Palette.ink)
            Picker("Scope", selection: $setup.scopeKind) {
                Text("Everything").tag(CleanupSetupModel.ScopeKind.everything)
                Text("Chosen chats").tag(CleanupSetupModel.ScopeKind.chosen)
            }
            .pickerStyle(.segmented)

            if setup.scopeKind == .chosen {
                Button {
                    showingChats = true
                } label: {
                    HStack {
                        if setup.chosen.isEmpty {
                            Text("Pick chats")
                        } else {
                            Text("^[\(setup.chosen.count) chat](inflect: true) picked")
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.secondary)
            }
        }
    }

    private var ownershipCard: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("Messages you sent")
                    .font(.title(.headline))
                Spacer()
                Text(setup.estimatedCount.formatted())
                    .font(.system(.title2, design: .rounded, weight: .black))
                    .contentTransition(.numericText())
                    .monospacedDigit()
            }
            .foregroundStyle(Palette.ink)
            .accessibilityElement(children: .combine)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Label("Messages from others", systemImage: "lock.fill")
                Spacer()
                Text("Never touched")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
            }
            .foregroundStyle(Palette.secondaryInk)
            .accessibilityElement(children: .combine)
        }
    }

    private var filtersSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text("Filters")
                    .font(.title(.title3))
                    .foregroundStyle(Palette.ink)
                if !isPro { Pill(text: "Pro") }
            }

            Card {
                Text("When they were sent")
                    .font(.title(.headline))
                    .foregroundStyle(Palette.ink)
                Picker("When they were sent", selection: gatedDateBound) {
                    Text("Anytime").tag(CleanupSetupModel.DateBound.any)
                    Text("Before").tag(CleanupSetupModel.DateBound.before)
                    Text("After").tag(CleanupSetupModel.DateBound.after)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("When they were sent")
                if setup.dateBound != .any {
                    DatePicker(
                        setup.dateBound == .before ? "Sent before" : "Sent after",
                        selection: $setup.cutoff,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                }
                Divider()
                ForEach(CleanupSetupModel.filterableKinds, id: \.self) { kind in
                    Toggle(isOn: gated(kindBinding(kind))) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            }
            .tint(Palette.accentInk)
        }
    }

    private var gatedDateBound: Binding<CleanupSetupModel.DateBound> {
        Binding(
            get: { setup.dateBound },
            set: { newValue in
                if isPro || newValue == .any {
                    setup.dateBound = newValue
                } else {
                    showingPaywall = true
                }
            }
        )
    }

    /// Filters are Pro-only: flipping one on the free tier opens the paywall instead.
    private func gated(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                if isPro {
                    binding.wrappedValue = newValue
                } else {
                    showingPaywall = true
                }
            }
        )
    }

    private func kindBinding(_ kind: MessageKind) -> Binding<Bool> {
        Binding(
            get: { setup.kinds.contains(kind) },
            set: { isOn in
                if isOn { setup.kinds.insert(kind) } else { setup.kinds.remove(kind) }
            }
        )
    }
}

extension MessageKind {
    var title: LocalizedStringKey {
        switch self {
        case .text: return "Texts"
        case .media: return "Photos & videos"
        case .link: return "Links & shared posts"
        case .voice: return "Voice messages"
        case .other: return "Everything else"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.bubble.fill"
        case .media: return "photo.fill"
        case .link: return "link"
        case .voice: return "waveform"
        case .other: return "ellipsis.bubble.fill"
        }
    }
}

private struct ChatPicker: View {
    @Environment(\.dismiss) private var dismiss
    let overview: LibraryOverview
    @Binding var selection: Set<ConversationID>

    var body: some View {
        NavigationStack {
            List(overview.cleanableConversations.sorted { $0.sentByOwner > $1.sentByOwner }) { chat in
                Button {
                    if selection.contains(chat.id) { selection.remove(chat.id) } else { selection.insert(chat.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(chat.title).foregroundStyle(Palette.ink)
                            Text("^[\(chat.sentByOwner) message](inflect: true) from you")
                                .font(.subheadline)
                                .foregroundStyle(Palette.secondaryInk)
                        }
                        Spacer()
                        Image(systemName: selection.contains(chat.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.contains(chat.id) ? Palette.accentInk : Palette.hairline)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityAddTraits(selection.contains(chat.id) ? .isSelected : [])
            }
            .navigationTitle("Pick chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
