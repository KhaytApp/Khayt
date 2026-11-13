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
/// - **IBM Plex Sans Arabic** for every face when the app is in Arabic
///   (Turki, Nov 11: one Arabic font on every app). None of the three above
///   has Arabic, and iOS's fallback face sat beside them mid-line.
///
/// Every size scales with Dynamic Type through `relativeTo:`.
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

    /// IBM Plex Sans Arabic: in Arabic, every face (text, display and data)
    /// is this one (Turki, Nov 11: one Arabic font on every app, as the
    /// desktop and the website already use). It carries Latin too, so a
    /// customer's name or "S-1041" inside Arabic text sets in the same face
    /// instead of iOS's Arabic fallback beside Hanken Grotesk.
    static func arabicName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "IBMPlexSansArabic-Bold"
        case .semibold: return "IBMPlexSansArabic-SemiBold"
        case .medium: return "IBMPlexSansArabic-Medium"
        default: return "IBMPlexSansArabic-Regular"
        }
    }

    /// The text face for the app's language: Plex Arabic in Arabic.
    static func textName(_ weight: Font.Weight, arabic: Bool = L10n.usesArabicLayout) -> String {
        arabic ? arabicName(weight) : postScriptName(weight)
    }

    /// The display face for the app's language: Plex Arabic Bold in Arabic.
    static func titleName(_ weight: Font.Weight, arabic: Bool = L10n.usesArabicLayout) -> String {
        arabic ? arabicName(.bold) : displayName(weight)
    }

    /// Every face the app asks for by name — what Info.plist must register.
    static var allNames: [String] {
        let w: [Font.Weight] = [.regular, .medium, .semibold, .bold]
        return Array(Set(w.map(postScriptName) + w.map(displayName) + w.map(monoName) + w.map(arabicName))).sorted()
    }

    /// Navigation titles in the design's faces, set once at launch: the large
    /// title in Archivo, the inline title in Hanken Grotesk.
    static func applyNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        if let large = UIFont(name: titleName(.semibold), size: 32) {
            appearance.largeTitleTextAttributes = [
                .font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large),
                .kern: -0.6,
            ]
        }
        if let inline = UIFont(name: textName(.semibold), size: 17) {
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
            ? .custom(KhaytType.titleName(weight), size: size, relativeTo: style)
            : .custom(KhaytType.textName(weight), size: size, relativeTo: style)
    }

    /// Archivo at any size — a hero number or title below the display cut.
    static func khaytDisplay(_ size: CGFloat, _ weight: Font.Weight = .bold,
                             relativeTo style: Font.TextStyle = .title) -> Font {
        .custom(KhaytType.titleName(weight), size: size, relativeTo: style)
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
            ? .custom(KhaytType.arabicName(weight), size: size, relativeTo: style)
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
