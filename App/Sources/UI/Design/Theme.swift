import SwiftUI
import UIKit

/// Brand palette. One loud accent ("volt") on calm neutrals; ink text on volt keeps
/// contrast well above WCAG AA in both light and dark mode.
enum Palette {
    static let volt = Color(red: 0.831, green: 1.0, blue: 0.227)
    static let onVolt = Color(red: 0.067, green: 0.067, blue: 0.067)
    static let lilac = Color(red: 0.725, green: 0.659, blue: 1.0)
    static let danger = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1.0, green: 0.45, blue: 0.40, alpha: 1)
        : UIColor(red: 0.78, green: 0.16, blue: 0.12, alpha: 1) })

    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.055, green: 0.055, blue: 0.063, alpha: 1)
        : UIColor(red: 0.969, green: 0.961, blue: 0.941, alpha: 1) })

    static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.105, green: 0.105, blue: 0.118, alpha: 1)
        : UIColor.white })

    static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.96, green: 0.96, blue: 0.95, alpha: 1)
        : UIColor(red: 0.067, green: 0.067, blue: 0.067, alpha: 1) })

    static let secondaryInk = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.64)
        : UIColor(white: 0, alpha: 0.6) })

    static let hairline = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.12)
        : UIColor(white: 0, alpha: 0.08) })

    /// Accent used for text/icons on the neutral background (volt is too light for text on white).
    static let accentInk = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.831, green: 1.0, blue: 0.227, alpha: 1)
        : UIColor(red: 0.30, green: 0.40, blue: 0.0, alpha: 1) })
}

enum Spacing {
    static let xs: CGFloat = 6
    static let s: CGFloat = 10
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 36
    static let screen: CGFloat = 24
}

extension Font {
    /// Headline type: heavy rounded, scales with Dynamic Type via the text style.
    static func display(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .rounded, weight: .black)
    }

    static func title(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, design: .rounded, weight: .bold)
    }
}

/// The brand wordmark: lowercase, with the dot in volt.
struct Wordmark: View {
    var body: some View {
        (Text("delore").foregroundStyle(Palette.ink) + Text(".").foregroundStyle(Palette.accentInk))
            .font(.system(.title3, design: .rounded, weight: .black))
            .accessibilityLabel("DeLore")
    }
}

struct ScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background.ignoresSafeArea())
    }
}

extension View {
    func screenBackground() -> some View { modifier(ScreenBackground()) }
}
