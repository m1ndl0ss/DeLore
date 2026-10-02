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
                    Text(setup.estimatedCount > 0
                         ? "Messages you sent \(setup.estimatedCount.formatted())"
                         : "We'll count what you sent")
                        .font(Type.medium(28))
                        .foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)

                    scopeSection
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
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                    }
                    .accessibilityLabel("Back")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await startCleaning() }
                } label: {
                    if setup.isPreparing {
                        ProgressView().tint(Palette.onVolt)
                    } else {
                        Text("Start cleaning")
                    }
                }
                .buttonStyle(.primary)
                .disabled(!setup.canContinue || setup.isPreparing)
                .accessibilityIdentifier("startCleaning")
                .padding(.horizontal, Spacing.screen)
                .padding(.vertical, Spacing.s)
                .background(Palette.background.opacity(0.96))
            }
            .navigationDestination(isPresented: needsConfirmBinding) {
                ConfirmCleanupView(setup: setup)
            }
            .sheet(isPresented: $showingChats) {
                ChatPicker(overview: setup.overview, selection: $setup.chosen)
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(context: .filters)
                    .environment(model)
                    .presentationBackground(Palette.background)
            }
            .alert("Something went wrong", isPresented: failedBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("We couldn't get your messages ready. Try again.")
            }
        }
        .onDisappear {
            if model.session == nil { setup.discardPrepared() }
        }
        .overlay {
            if setup.isEvaluating {
                EvaluatingChatSizeOverlay(progress: setup.evaluateProgress)
            }
        }
    }

    private var needsConfirmBinding: Binding<Bool> {
        Binding(
            get: {
                guard let prepared = setup.prepared, prepared.count > 0 else { return setup.prepared != nil }
                if case .allowed = model.entitlements.allowance(
                    requestedCount: prepared.count,
                    usesAdvancedFilters: setup.usesAdvancedFilters
                ) {
                    return false
                }
                return true
            },
            set: { if !$0 { setup.discardPrepared() } }
        )
    }

    private func startCleaning() async {
        await setup.prepare()
        await model.reloadOverview()
        guard let prepared = setup.prepared else { return }
        let decision = model.entitlements.allowance(
            requestedCount: prepared.count,
            usesAdvancedFilters: setup.usesAdvancedFilters
        )
        guard prepared.count > 0, case .allowed = decision else { return }
        await model.startCleanup(PreparedCleanup(job: prepared.job, decision: decision))
    }

    private var failedBinding: Binding<Bool> {
        Binding(get: { setup.failed }, set: { if !$0 { setup.clearFailure() } })
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Who")
                .font(Type.medium(15))
                .foregroundStyle(Palette.secondaryInk)
            Picker("Scope", selection: $setup.scopeKind) {
                Text("Everyone").tag(CleanupSetupModel.ScopeKind.everything)
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

    private var filtersSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Text("When")
                    .font(Type.medium(15))
                    .foregroundStyle(Palette.secondaryInk)
                if !isPro { Pill(text: "Pro") }
            }

            VStack(spacing: Spacing.s) {
                dateOption(.any, title: "Any time", detail: "All messages you sent")
                dateOption(.before, title: "Before a date", detail: "Older than the day you pick")
                dateOption(.after, title: "After a date", detail: "Newer than the day you pick")
            }

            if setup.dateBound != .any {
                CleanupDateCalendar(
                    label: setup.dateBound == .before ? "Before this day" : "After this day",
                    date: $setup.cutoff
                )
                .padding(.top, Spacing.xs)
            }
        }
    }

    private func dateOption(_ bound: CleanupSetupModel.DateBound, title: String, detail: String) -> some View {
        let selected = setup.dateBound == bound
        return Button {
            if isPro || bound == .any {
                setup.dateBound = bound
            } else {
                showingPaywall = true
            }
        } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Palette.accent : Palette.tertiaryInk)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Type.medium(16))
                        .foregroundStyle(Palette.ink)
                    Text(detail)
                        .font(Type.body(13))
                        .foregroundStyle(Palette.secondaryInk)
                }
                Spacer()
            }
            .padding(Metrics.cardInset)
            .elevated()
            .overlay(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .strokeBorder(selected ? Palette.accent.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

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
}

extension MessageKind {
    var title: LocalizedStringKey {
        switch self {
        case .text: return "Texts"
        case .media: return "Media"
        case .link: return "Links & shared posts"
        case .voice: return "Voice"
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

/// Inline month calendar — same pattern as Apple's graphical DatePicker / Material docked calendar.
private struct CleanupDateCalendar: View {
    let label: String
    @Binding var date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(label)
                .font(Type.medium(13))
                .foregroundStyle(Palette.secondaryInk)
            Text(date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                .font(Type.medium(20))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            DatePicker(
                label,
                selection: $date,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .tint(Palette.accent)
            .colorScheme(.dark)
        }
        .padding(Metrics.cardInset)
        .elevated()
        .accessibilityElement(children: .contain)
    }
}

private struct EvaluatingChatSizeOverlay: View {
    let progress: InboxReadProgress

    private var headline: String {
        if progress.isComplete { return "All set" }
        if let name = progress.displayChat { return "Checking \(name)" }
        return "Evaluating chat size"
    }

    private var titles: [String] { progress.foundTitles }

    private var caption: String {
        if titles.isEmpty { return "Names land here as we check them" }
        return "Checking · \(titles.count)"
    }

    var body: some View {
        VStack(spacing: Spacing.m) {
            HStack {
                Wordmark()
                Spacer()
            }
            VStack(spacing: Spacing.s) {
                Text(headline)
                    .font(Type.medium(20))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                Text(progress.detail)
                    .font(Type.medium(15))
                    .foregroundStyle(Palette.accent)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: progress.sendsFound + progress.chatsRead)
                LoreProgressBar(fraction: progress.fraction)
                    .frame(maxWidth: 280)
            }
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(caption)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.secondaryInk)
                if !titles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(titles.suffix(4).enumerated()), id: \.offset) { index, name in
                            let visible = Array(titles.suffix(4))
                            EvaluatePersonRow(name: name, newest: index == visible.count - 1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)

            Spacer(minLength: Spacing.m)
            Text("We're sizing each chat so unsending stays efficient — only what's still there, nothing wasted.")
                .font(Type.body(15))
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, Spacing.m)

            Text("This happens on your phone. You can exit — don't close Retract.")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.vertical, Spacing.m)
        .screenBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Evaluating chat size")
    }
}

private struct EvaluatePersonRow: View {
    let name: String
    let newest: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(personInitial(name))
                .font(Type.medium(14))
                .foregroundStyle(Palette.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Palette.accent.opacity(0.22)))
                .accessibilityHidden(true)
            Text(name)
                .font(Type.medium(16))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if newest {
                Text("new")
                    .font(Type.medium(11))
                    .foregroundStyle(Palette.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(newest ? Palette.surfaceElevated : Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(newest ? Palette.accent.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        .scaleEffect(newest ? 1.015 : 1)
        .animation(.spring(duration: 0.28), value: newest)
    }
}

private func personInitial(_ name: String) -> String {
    let cleaned = name.trimmingCharacters(in: CharacterSet(charactersIn: "@ ").union(.whitespaces))
    guard let first = cleaned.first else { return "?" }
    return String(first).uppercased()
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
