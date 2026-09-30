import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Type.medium(17))
            .foregroundStyle(Palette.onCta)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Palette.cta, Palette.ctaDeep],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .strokeBorder(Color.white.opacity(isEnabled ? 0.28 : 0.12), lineWidth: 1)
            )
            .shadow(color: Palette.cta.opacity(isEnabled ? 0.5 : 0), radius: 16, y: 8)
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
            .animation(reduceMotion ? .none : .easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Type.medium(17))
            .foregroundStyle(Palette.onCtaSoft)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.buttonHeight)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Palette.ctaSoft))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .strokeBorder(Palette.accent.opacity(isEnabled ? 0.95 : 0.35), lineWidth: 1.5)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
    }
}

struct TextButtonStyle: ButtonStyle {
    var tint: Color = Palette.secondaryInk

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Type.medium(16))
            .foregroundStyle(tint)
            .frame(minHeight: 44)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

struct ConnectButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 24.0, paused: reduceMotion || !isEnabled)) { timeline in
            let glow = reduceMotion || !isEnabled
                ? 0.4
                : 0.28 + 0.18 * (0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 2.2))
            configuration.label
            .font(Type.medium(17))
            .foregroundStyle(Palette.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.buttonHeight)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Palette.accent))
            .shadow(color: Palette.accent.opacity(isEnabled ? glow : 0), radius: 14, y: 6)
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        }
    }
}

extension ButtonStyle where Self == ConnectButtonStyle {
    static var connect: ConnectButtonStyle { ConnectButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == TextButtonStyle {
    static var text: TextButtonStyle { TextButtonStyle() }
}

struct Card<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) { content }
            .padding(Metrics.cardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .elevated()
    }
}

struct PromiseRow: View {
    let symbol: String
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: Metrics.icon, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Type.medium(16))
                    .foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail)
                        .font(Type.body(14))
                        .foregroundStyle(Palette.secondaryInk)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SettingsRow: View {
    let symbol: String
    let title: LocalizedStringKey
    var detail: String? = nil
    var tint: Color = Palette.ink

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.secondaryInk)
                .frame(width: 24)
            Text(title)
                .font(Type.body(17))
                .foregroundStyle(tint)
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .font(Type.body(15))
                    .foregroundStyle(Palette.tertiaryInk)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.tertiaryInk)
        }
        .frame(minHeight: Metrics.rowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct Pill: View {
    let text: LocalizedStringKey
    var filled = true

    var body: some View {
        Text(text)
            .font(Type.medium(12))
            .foregroundStyle(filled ? Palette.onAccent : Palette.secondaryInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(filled ? Palette.accent : Palette.surface))
    }
}

struct LoreProgressBar: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 24.0, paused: reduceMotion)) { timeline in
                let shimmer = reduceMotion ? 0.0 : abs(sin(timeline.date.timeIntervalSinceReferenceDate * 1.6))
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surfaceElevated)
                    Capsule()
                        .fill(Palette.accent.opacity(0.75 + 0.25 * shimmer))
                        .frame(width: max(Metrics.progress, proxy.size.width * min(1, max(0, fraction))))
                        .animation(.easeOut(duration: 0.3), value: fraction)
                }
            }
        }
        .frame(height: Metrics.progress)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(Text(fraction.formatted(.percent.precision(.fractionLength(0)))))
    }
}

struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Palette.surface))
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("Close")
    }
}

struct LoreHeadline: View {
    var text: LocalizedStringKey = "Take it back."
    var wipe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var struck = false
    @State private var risen = false

    init() {
        self.text = "Take it back."
        self.wipe = true
    }

    init(text: LocalizedStringKey) {
        self.text = text
        self.wipe = false
    }

    var body: some View {
        Group {
            if wipe {
                wipeLine
            } else {
                Text(text)
            }
        }
        .font(Type.medium(28))
        .lineSpacing(2)
        .lineLimit(3)
        .foregroundStyle(Palette.ink)
        .shadow(color: .black.opacity(0.72), radius: 12, y: 1)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(risen ? 1 : 0)
        .offset(y: risen ? 0 : 10)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(Text(text))
        .onAppear {
            if reduceMotion {
                risen = true
                struck = true
            } else {
                withAnimation(.easeOut(duration: 0.45)) { risen = true }
                if wipe {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        withAnimation(.easeInOut(duration: 0.7)) { struck = true }
                    }
                }
            }
        }
    }

    private var wipeLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Take it ")
            Text("back.")
                .foregroundStyle(struck ? Palette.ink.opacity(0.82) : Palette.ink)
                .overlay(alignment: .center) {
                    Capsule()
                        .fill(Palette.cta)
                        .frame(height: 3.5)
                        .offset(y: 1)
                        .scaleEffect(x: struck ? 1 : 0.02, y: 1, anchor: .leading)
                }
        }
    }
}

struct QuietLink: View {
    let title: LocalizedStringKey
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Type.medium(15))
                .foregroundStyle(Palette.ink)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

struct FreeMeter: View {
    let remaining: Int
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text("Free leftover")
                    .font(Type.medium(13))
                    .foregroundStyle(Palette.secondaryInk)
                Spacer()
                Text("^[\(remaining) message](inflect: true)")
                    .font(Type.medium(13))
                    .foregroundStyle(Palette.ink)
            }
            LoreProgressBar(fraction: Double(max(0, remaining)) / Double(max(1, limit)))
        }
        .padding(Metrics.cardInset)
        .elevated(radius: Radius.s)
        .accessibilityElement(children: .combine)
    }
}
