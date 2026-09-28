import SwiftUI

struct ImportProgressView: View {
    @Environment(AppModel.self) private var model
    let importModel: ImportModel

    var body: some View {
        VStack(spacing: Spacing.l) {
            HStack {
                Spacer()
                if !isFinished {
                    CloseButton { model.dismissImport() }
                }
            }

            Spacer()

            switch importModel.phase {
            case .reading:
                progress(title: "Reading your DMs…", fraction: nil)
            case let .importing(fraction):
                progress(title: "Reading your DMs…", fraction: fraction)
            case .finished:
                progress(title: "All set", fraction: 1)
            case let .chooseOwner(candidates):
                OwnerPicker(candidates: candidates) { importModel.chooseOwner($0) }
            case let .failed(failure):
                failureView(failure)
            }

            Spacer()
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.vertical, Spacing.m)
        .screenBackground()
        .interactiveDismissDisabled()
    }

    private var isFinished: Bool { importModel.phase == .finished }

    private func progress(title: LocalizedStringKey, fraction: Double?) -> some View {
        VStack(spacing: Spacing.l) {
            ZStack {
                Circle().stroke(Palette.hairline, lineWidth: 14)
                Circle()
                    .trim(from: 0, to: fraction ?? 0.25)
                    .stroke(Palette.volt, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut, value: fraction)
                if fraction == nil {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(width: 140, height: 140)
            .accessibilityHidden(true)

            VStack(spacing: Spacing.s) {
                Text(title)
                    .font(.title(.title))
                    .foregroundStyle(Palette.ink)
                Text("This happens on your phone. Nothing is uploaded.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryInk)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(fraction.map { Text($0.formatted(.percent.precision(.fractionLength(0)))) } ?? Text(""))
        }
    }

    private func failureView(_ failure: ImportModel.ImportFailure) -> some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .accessibilityHidden(true)
            VStack(spacing: Spacing.s) {
                Text(failure.title)
                    .font(.title(.title2))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                Text(failure.message)
                    .font(.body)
                    .foregroundStyle(Palette.secondaryInk)
                    .multilineTextAlignment(.center)
            }
            Button("Pick another file") { model.dismissImport() }
                .buttonStyle(.primary)
        }
    }
}

private struct OwnerPicker: View {
    let candidates: [String]
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Which one is you?")
                    .font(.display(.title))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("We only ever touch messages you sent, so we need to be sure.")
                    .font(.body)
                    .foregroundStyle(Palette.secondaryInk)
            }
            VStack(spacing: Spacing.s) {
                ForEach(candidates, id: \.self) { name in
                    Button(name) { onPick(name) }
                        .buttonStyle(.secondary)
                }
            }
        }
    }
}
