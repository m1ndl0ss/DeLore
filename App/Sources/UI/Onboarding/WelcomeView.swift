import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var struck = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark()
                .padding(.top, Spacing.m)

            Spacer(minLength: Spacing.xl)

            VStack(alignment: .leading, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Delete")
                    HStack(spacing: 0) {
                        Text("the ")
                        Text("lore")
                            .overlay(alignment: .leading) {
                                GeometryReader { proxy in
                                    let thickness = max(8, proxy.size.height * 0.16)
                                    Capsule()
                                        .fill(Palette.volt)
                                        .frame(width: struck ? proxy.size.width : 0, height: thickness)
                                        .offset(y: proxy.size.height * 0.55 - thickness / 2)
                                }
                                .accessibilityHidden(true)
                            }
                        Text(".")
                    }
                }
                .font(.display())
                .foregroundStyle(Palette.ink)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Delete the lore.")
                .accessibilityAddTraits(.isHeader)

                Text("Clean up your old DMs without deleting them one by one.")
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .foregroundStyle(Palette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.xl)

            VStack(spacing: Spacing.m) {
                Button("Get started") { model.getStarted() }
                    .buttonStyle(.primary)
                    .sensoryFeedback(.impact(weight: .light), trigger: model.route)
                    .accessibilityIdentifier("getStarted")

                Label("Your data stays on your device.", systemImage: "lock.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.secondaryInk)
            }
            .padding(.bottom, Spacing.m)
        }
        .padding(.horizontal, Spacing.screen)
        .onAppear {
            if reduceMotion {
                struck = true
            } else {
                withAnimation(.easeInOut(duration: 0.7).delay(0.5)) { struck = true }
            }
        }
    }
}
