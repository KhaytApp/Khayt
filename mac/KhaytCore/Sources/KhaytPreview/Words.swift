import Foundation
import KhaytCore

/// What the preview calls things.
///
/// The app has a `Words` of its own — 980 lines, `@MainActor`, `@Observable`,
/// wired to a live shop. None of that can cross into an extension bundle, and
/// none of it is needed here: this panel has seven labels and reads them once.
///
/// What it must NOT do is invent its own translations. Khayt's catalogue is the
/// same catalogue, fetched through the same engine — a preview that called a
/// printer something the app does not call it would give one shop two
/// vocabularies. The handful of words Khayt has never needed come from
/// `PrintFactLines.ownWords`, which is also where the app gets them, so the two
/// panels cannot drift apart.
///
/// THE LANGUAGE IS THE SYSTEM'S, NOT THE SHOP'S. A Quick Look panel is part of
/// Finder, and a person whose Mac is in English gets an English Finder even if
/// they keep their books in Arabic. The extension is sandboxed and has no
/// business reading the app's preferences to find out otherwise.
struct Words: Sendable {
    let language: String
    private let khayt: [String: String]

    /// Internal rather than private so the tests can hand it a catalogue: what
    /// is worth testing here is the ORDER it consults them in, not the fetch.
    init(language: String, khayt: [String: String]) {
        self.language = language
        self.khayt = khayt
    }

    var isRTL: Bool { language == "ar" }

    /// The catalogue for whatever language macOS is showing, falling back to
    /// English — which is what the app does, for the same reason.
    /// - Parameter engine: the caller's engine, so a preview stands up ONE
    ///   JavaScriptCore context rather than one for the facts and another for
    ///   the words. `nil` (the engine would not start) gives a panel with this
    ///   file's own English, which is the least bad thing left.
    static func load(using engine: KhaytEngine?) async -> Words {
        let language = Self.preferred()
        guard let engine, let strings = try? await engine.translations(language: language) else {
            return Words(language: language, khayt: [:])
        }
        return Words(language: language, khayt: strings)
    }

    /// Arabic when the Mac is in Arabic, English otherwise. The other seven
    /// languages Khayt has are a matter of the app bundling more locale files,
    /// not of anything here.
    static func preferred() -> String {
        for tag in Locale.preferredLanguages {
            let code = Locale(identifier: tag).language.languageCode?.identifier ?? ""
            if code == "ar" { return "ar" }
            if code == "en" { return "en" }
        }
        return "en"
    }

    /// Khayt's word first, this panel's own second, and the key itself last —
    /// which is visible, and is meant to be: a label reading `conv.cp_nozzle` is
    /// a bug report.
    func callIt(_ key: String) -> String {
        if let shared = khayt[key], !shared.isEmpty { return shared }
        if let own = PrintFactLines.ownWords[key]?[language]
            ?? PrintFactLines.ownWords[key]?["en"], !own.isEmpty { return own }
        return key
    }

    /// `(3, "mac.objects_n") -> "3 objects"`, with the singular when there is
    /// one of them. The number goes in front, so the catalogue values are bare
    /// nouns.
    func counting(_ n: Int, _ key: String) -> String {
        "\(n) " + callIt(n == 1 ? key + "_one" : key)
    }
}
