import SwiftUI
import UIKit

struct TermsAcceptView: View {
    var kind: AppModel.TermsPrompt
    var onPrimary: (_ dontShowAgain: Bool) -> Void
    var onCancel: () -> Void
    @State private var reachedEnd = false
    @State private var agreed = false
    @State private var readThis = false
    @State private var dontShowAgain = false

    private var reminder: Bool { kind == .reminder }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Wordmark()
                    .reviewDemoUnlock()
                Spacer()
                CloseButton(action: onCancel)
            }
            Text(reminder ? "Read this" : "Read this first")
                .font(Type.medium(28))
                .foregroundStyle(Palette.ink)
            Text(reminder
                 ? "We are not responsible for anything."
                 : "Retract is at your own risk. Scroll to the end, then agree, before Instagram.")
                .font(Type.body(16))
                .foregroundStyle(Palette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
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
                    GeometryReader { geo in
                        let minY = geo.frame(in: .global).minY
                        Color.clear
                            .onAppear { markEndIfVisible(minY) }
                            .onChange(of: minY) { _, y in markEndIfVisible(y) }
                    }
                    .frame(height: 1)
                }
                .padding(.bottom, Spacing.s)
            }
            if reminder {
                termsToggle(readThis, "I read this") { readThis.toggle() }
                termsToggle(dontShowAgain, "Don't show this again") { dontShowAgain.toggle() }
            } else {
                termsToggle(agreed, "I understand I use Retract at my own risk.") { agreed.toggle() }
            }
            Button(primaryTitle) {
                onPrimary(reminder ? dontShowAgain : true)
            }
            .buttonStyle(.primary)
            .disabled(!canContinue)
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.vertical, Spacing.m)
        .screenBackground()
        .interactiveDismissDisabled()
    }

    private var primaryTitle: String {
        if !reachedEnd { return "Scroll to the end first" }
        return reminder ? "Proceed" : "I agree — open Instagram"
    }

    private var canContinue: Bool {
        if !reachedEnd { return false }
        return reminder ? readThis : agreed
    }

    private func termsToggle(_ on: Bool, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(on ? Palette.accent : Palette.secondaryInk)
                Text(title)
                    .font(Type.medium(15))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? "Checked" : "Unchecked")
    }

    private func markEndIfVisible(_ minY: CGFloat) {
        let fold = UIScreen.main.bounds.height - 24
        if minY < fold { reachedEnd = true }
    }
}
