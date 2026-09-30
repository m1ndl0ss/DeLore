import SwiftUI
import UIKit

/// True near-black canvas, one lavender accent. No glow, no muddy purple wash.
enum Palette {
    static let background = Color(red: 0.063, green: 0.043, blue: 0.110)
    static let backgroundTop = Color(red: 0.090, green: 0.063, blue: 0.157)
    static let surface = Color(red: 0.110, green: 0.110, blue: 0.133)
    static let surfaceElevated = Color(red: 0.149, green: 0.149, blue: 0.180)
    static let accent = Color(red: 0.788, green: 0.722, blue: 1.0)
    static let onAccent = Color(red: 0.071, green: 0.063, blue: 0.094)
    static let cta = Color(red: 0.306, green: 0.227, blue: 0.941)
    static let ctaDeep = Color(red: 0.227, green: 0.157, blue: 0.831)
    static let onCta = Color.white
    static let ctaSoft = Color(red: 0.953, green: 0.933, blue: 1.0)
    static let onCtaSoft = Color(red: 0.086, green: 0.063, blue: 0.133)
    static let valueGold = Color(red: 1.0, green: 0.784, blue: 0.341)
    static let valuePink = Color(red: 1.0, green: 0.420, blue: 0.604)
    static let ink = Color(red: 0.961, green: 0.961, blue: 0.969)
    static let secondaryInk = Color.white.opacity(0.60)
    static let tertiaryInk = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.10)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.45)
    static let disabled = Color.white.opacity(0.28)

    /// Compatibility aliases used across existing screens.
    static let volt = accent
    static let onVolt = onAccent
    static let lilac = accent
    static let stamp = surface
    static let accentInk = accent
}

enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let screen: CGFloat = 20
}

enum Radius {
    static let s: CGFloat = 10
    static let m: CGFloat = 14
    static let l: CGFloat = 18
}

enum Metrics {
    static let buttonHeight: CGFloat = 52
    static let buttonPadding: CGFloat = 20
    static let rowHeight: CGFloat = 52
    static let icon: CGFloat = 20
    static let cardInset: CGFloat = 16
    static let progress: CGFloat = 6
}

enum Type {
    static func mark(_ size: CGFloat) -> Font { .custom("Unbounded ExtraBold", size: size) }
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
    static func body(_ size: CGFloat) -> Font { .system(size: size) }
    static func medium(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
}

extension Font {
    static func display(_ style: Font.TextStyle = .largeTitle) -> Font {
        Type.display(style == .largeTitle ? 32 : 26)
    }

    static func title(_ style: Font.TextStyle = .title2) -> Font {
        Type.medium(style == .headline ? 17 : 20)
    }
}

struct Wordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("BrandMark")
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(Circle())
                .accessibilityHidden(true)
            (Text("retract").foregroundStyle(Palette.ink) + Text(".").foregroundStyle(Palette.accent))
                .font(Type.mark(18))
                .lineLimit(1)
        }
        .frame(height: 28, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Retract")
    }
}

struct ScreenBackground: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                GhostFibersView(paused: reduceMotion)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    func screenBackground() -> some View { modifier(ScreenBackground()) }

    func elevated(radius: CGFloat = Radius.m) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.surface))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.accent.opacity(0.16), lineWidth: 1)
            )
    }

    func stamp(fill: Color = Palette.surface, radius: CGFloat = Radius.m) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
    }

    func appearRise(_ visible: Bool, delay: Double = 0) -> some View {
        opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 8)
            .animation(.easeOut(duration: 0.28).delay(delay), value: visible)
    }
}
