import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case ar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return L10n.tr("lang.system")
        case .en: return "English"
        case .ar: return "العربية"
        }
    }

    var locale: Locale? {
        switch self {
        case .system: return nil
        case .en: return Locale(identifier: "en")
        case .ar: return Locale(identifier: "ar")
        }
    }

    var layoutDirection: LayoutDirection {
        switch self {
        case .ar: return .rightToLeft
        case .system:
            if Locale.current.language.languageCode?.identifier == "ar" { return .rightToLeft }
            return .leftToRight
        case .en: return .leftToRight
        }
    }
}

enum L10n {
    private static var bundle: Bundle = .main
    private(set) static var currentLanguage: AppLanguage = .system

    static var usesArabicLayout: Bool {
        switch currentLanguage {
        case .ar: return true
        case .en: return false
        case .system:
            return Locale.current.language.languageCode?.identifier == "ar"
        }
    }

    static func setLanguage(_ language: AppLanguage) {
        currentLanguage = language
        switch language {
        case .system:
            bundle = .main
        case .en:
            bundle = bundleFor("en") ?? .main
        case .ar:
            bundle = bundleFor("ar") ?? .main
        }
    }

    private static func bundleFor(_ code: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    static func tr(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }

    /// A string that counts something, in the chosen language's own plural
    /// forms (`Localizable.stringsdict`).
    ///
    /// Formatted with THAT language's locale, not the device's: the plural
    /// rule comes from the locale, and a phone set to English with the app
    /// set to Arabic otherwise gets English's two forms — "إضافة 2 بكرة"
    /// where Arabic says "إضافة بكرتين".
    static func count(_ key: String, _ n: Int) -> String {
        String(format: tr(key), locale: locale, n)
    }

    /// The app's language as a locale — what every number and date is written
    /// in — with WESTERN digits, whatever the language.
    ///
    /// ── ARABIC WORDS, WESTERN DIGITS ──────────────────────────────────────
    ///
    /// Saudi products write numbers 0–9: codepoint scans of Al Rajhi, SNB,
    /// Absher, Tawakkalna, Salla, STC and SAMA find Western digits on
    /// essentially every figure, and the desktop guards the same rule
    /// (`test/arabic-numerals.test.js`); `Money` already pinned it. A bare
    /// `ar` locale resolves to the `arab` numbering system and leaks ٠–٩ —
    /// which this app did, half the time, until the same numbering was forced
    /// on every number it writes (Oct 2026; an earlier pass forced the other
    /// way, in error).
    static var locale: Locale { latinDigits(currentLanguage.locale ?? Locale.current) }

    /// `base`, with the `latn` numbering system: month names and plural rules
    /// stay the language's own, the digits are 0–9.
    static func latinDigits(_ base: Locale) -> Locale {
        var parts = Locale.Components(locale: base)
        parts.numberingSystem = Locale.NumberingSystem("latn")
        return Locale(components: parts)
    }

    /// `String(format:)` in the app's language. A bare `String(format: tr(k), n)`
    /// ignores the app's language for plural-free text but SwiftUI `Text`
    /// interpolation follows the environment locale, so the two disagreed.
    /// Both now go through `locale`, and both write Western digits.
    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), locale: locale, arguments: args)
    }

    /// "640 g" / "640 غ" — the unit in the app's language, the digits Western.
    static func grams(_ n: Int) -> String {
        "\(n.formatted(.number.locale(locale).grouping(.never))) \(tr("unit.g"))"
    }
}

/// Apply shop language to SwiftUI tree.
struct CompanionLocaleModifier: ViewModifier {
    @ObservedObject var settings: ConnectionSettings

    func body(content: Content) -> some View {
        content
            .environment(\.layoutDirection, settings.appLanguage.layoutDirection)
            // Western digits for every `Text` that formats a number or date —
            // see `L10n.locale`.
            .environment(\.locale, L10n.latinDigits(settings.appLanguage.locale ?? Locale.current))
            .onAppear { L10n.setLanguage(settings.appLanguage) }
            .onChange(of: settings.appLanguage) { _, lang in
                L10n.setLanguage(lang)
            }
    }
}

extension View {
    func companionLocale(_ settings: ConnectionSettings) -> some View {
        modifier(CompanionLocaleModifier(settings: settings))
    }
}
