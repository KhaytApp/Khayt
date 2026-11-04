import SwiftUI
import UIKit

/// The design's typefaces — the website's three (the 2026 redesign), bundled
/// and registered in Info.plist (`UIAppFonts`):
///
/// - **Hanken Grotesk** for text: every `.khayt(size, weight)` below 22 pt.
/// - **Archivo** for display: large titles, hero numbers, and any `.khayt` of
///   22 pt or more, so the screens' big figures move with no call site touched.
/// - **JetBrains Mono** for data and eyebrows: `.khaytMono`.
///
/// Every size scales with Dynamic Type through `relativeTo:`. None of the three
/// has Arabic; iOS falls back to its Arabic system face for those glyphs on its
/// own, as the website's stack does.
enum KhaytType {
    /// The size from which `.khayt` draws in the display face.
    static let displayFrom: CGFloat = 22

    /// Hanken Grotesk, the text face.
    static func postScriptName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "HankenGrotesk-Bold"
        case .semibold: return "HankenGrotesk-SemiBold"
        case .medium: return "HankenGrotesk-Medium"
        default: return "HankenGrotesk-Regular"
        }
    }

    /// Archivo, the display face: Bold up to semibold, ExtraBold above.
    static func displayName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "Archivo-ExtraBold"
        default: return "Archivo-Bold"
        }
    }

    /// JetBrains Mono, the data face.
    static func monoName(_ weight: Font.Weight) -> String {
        switch weight {
        case .regular, .light, .thin, .ultraLight: return "JetBrainsMono-Regular"
        default: return "JetBrainsMono-Medium"
        }
    }

    /// Every face the app asks for by name — what Info.plist must register.
    static var allNames: [String] {
        let w: [Font.Weight] = [.regular, .medium, .semibold, .bold]
        return Array(Set(w.map(postScriptName) + w.map(displayName) + w.map(monoName))).sorted()
    }

    /// Navigation titles in the design's faces, set once at launch: the large
    /// title in Archivo, the inline title in Hanken Grotesk.
    static func applyNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        if let large = UIFont(name: displayName(.semibold), size: 32) {
            appearance.largeTitleTextAttributes = [
                .font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large),
                .kern: -0.6,
            ]
        }
        if let inline = UIFont(name: postScriptName(.semibold), size: 17) {
            appearance.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline)]
        }
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        let edge = UINavigationBarAppearance(); edge.configureWithTransparentBackground()
        edge.largeTitleTextAttributes = appearance.largeTitleTextAttributes
        edge.titleTextAttributes = appearance.titleTextAttributes
        UINavigationBar.appearance().scrollEdgeAppearance = edge
    }
}

extension Font {
    /// The design's face at `size`, scaling with Dynamic Type like `style`:
    /// Hanken Grotesk for text, Archivo from `KhaytType.displayFrom` up.
    static func khayt(_ size: CGFloat, _ weight: Font.Weight = .regular,
                      relativeTo style: Font.TextStyle = .body) -> Font {
        size >= KhaytType.displayFrom
            ? .custom(KhaytType.displayName(weight), size: size, relativeTo: style)
            : .custom(KhaytType.postScriptName(weight), size: size, relativeTo: style)
    }

    /// Archivo at any size — a hero number or title below the display cut.
    static func khaytDisplay(_ size: CGFloat, _ weight: Font.Weight = .bold,
                             relativeTo style: Font.TextStyle = .title) -> Font {
        .custom(KhaytType.displayName(weight), size: size, relativeTo: style)
    }

    /// JetBrains Mono — order numbers, grams, times, eyebrows.
    ///
    /// Not in Arabic: JetBrains Mono has no Arabic, and Arabic set in it
    /// came out spaced letter by letter ("الـمـبـلـغ") in every eyebrow and
    /// label that carries a translated word. There the text face stands in;
    /// its figures are tabular already, so numbers still line up.
    static func khaytMono(_ size: CGFloat, _ weight: Font.Weight = .medium,
                          relativeTo style: Font.TextStyle = .caption) -> Font {
        L10n.usesArabicLayout
            ? .custom(KhaytType.postScriptName(weight), size: size, relativeTo: style)
            : .custom(KhaytType.monoName(weight), size: size, relativeTo: style)
    }
}

/// Letter-spacing for eyebrows and labels, dropped in Arabic: tracking pulls
/// a cursive script's joined letters apart. Negative tracking (tightened
/// display figures) is kept. `Text` keeps its own overload so concatenation
/// and Text-only modifiers still chain.
extension Text {
    func khaytTracking(_ value: CGFloat) -> Text {
        tracking(L10n.usesArabicLayout && value > 0 ? 0 : value)
    }
}

extension View {
    func khaytTracking(_ value: CGFloat) -> some View {
        tracking(L10n.usesArabicLayout && value > 0 ? 0 : value)
    }
}
