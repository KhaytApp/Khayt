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
        let locale = currentLanguage.locale ?? Locale.current
        return String(format: tr(key), locale: locale, n)
    }
}

/// Apply shop language to SwiftUI tree.
struct CompanionLocaleModifier: ViewModifier {
    @ObservedObject var settings: ConnectionSettings

    func body(content: Content) -> some View {
        content
            .environment(\.layoutDirection, settings.appLanguage.layoutDirection)
            .environment(\.locale, settings.appLanguage.locale ?? Locale.current)
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
