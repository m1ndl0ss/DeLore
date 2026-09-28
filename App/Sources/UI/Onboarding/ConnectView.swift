import SwiftUI
import UniformTypeIdentifiers

struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showingImporter = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack {
                    Wordmark()
                    Spacer()
                    if model.env.hasLibrary {
                        CloseButton { model.returnHome() }
                    }
                }
                .padding(.top, Spacing.m)

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Connect Instagram")
                        .font(.display(.largeTitle))
                        .foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Instagram lets you download a copy of your DMs. We read it right here on your phone to find the messages you sent.")
                        .font(.body)
                        .foregroundStyle(Palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card {
                    PromiseRow(symbol: "key.slash", title: "We never see your password", detail: "You get the file from Instagram yourself.")
                    PromiseRow(symbol: "person.fill.checkmark", title: "Only messages you sent", detail: "Other people's messages are never touched.")
                    PromiseRow(symbol: "eye.slash", title: "Message text is never saved", detail: "We keep dates and message types, not what you said.")
                }

                VStack(alignment: .leading, spacing: Spacing.m) {
                    StepRow(number: 1, title: "Ask Instagram for your DMs", detail: "In Accounts Center, choose Download your information → Messages, format JSON. Instagram lets you know when it's ready.")
                    Button {
                        openURL(model.env.configuration.instagramDownloadURL)
                    } label: {
                        Label("Open Instagram's download page", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.secondary)

                    StepRow(number: 2, title: "Bring the file here", detail: "Pick the download (a .zip or its unzipped folder) from Files.")
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.xl)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Spacing.s) {
                Button("Connect Instagram") { showingImporter = true }
                    .buttonStyle(.primary)
                    .accessibilityHint("Choose your Instagram download in Files")
                    .accessibilityIdentifier("connectInstagram")
                if model.env.configuration.features.sampleDataMode {
                    Button("Try with sample chats") {
                        Task { await model.useSampleData() }
                    }
                    .buttonStyle(.text)
                    .accessibilityIdentifier("sampleData")
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.vertical, Spacing.s)
            .background(Palette.background.opacity(0.96))
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.zip, .folder]) { result in
            if case let .success(url) = result {
                model.beginImport(from: url)
            }
        }
        .fullScreenCover(item: importBinding) { importModel in
            ImportProgressView(importModel: importModel)
                .environment(model)
        }
    }

    private var importBinding: Binding<ImportModel?> {
        Binding(get: { model.importModel }, set: { if $0 == nil { model.dismissImport() } })
    }
}

private struct StepRow: View {
    let number: Int
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Text("\(number)")
                .font(.system(.headline, design: .rounded, weight: .black))
                .foregroundStyle(Palette.onVolt)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Palette.volt))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title(.headline))
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(number): ") + Text(title))
    }
}
