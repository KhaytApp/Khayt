import Testing
import Foundation
import KhaytCore
@testable import KhaytApp

/// THE MAC SPEAKS EVERY LANGUAGE THE OTHER APP DOES.
///
/// Two halves make a language here: Khayt's shared strings
/// (`renderer/locales/<code>.js`, bundled and read on first use by
/// `KhaytEngine.ensureLocale`) and this app's own words
/// (`Words.own` for English and Arabic, `mac-words-<code>.json` for the rest).
/// A language with only the first half reads as a German app with English
/// menus, which is what these tests stop.
@Suite @MainActor struct MacLanguagesTests {

    /// Arabic-only grammar: the dual, 3–10, and none. `Words.counting` reads
    /// them only when the language is Arabic, so no other file carries them.
    static func arabicOnly(_ key: String) -> Bool {
        for tail in ["_two", "_few", "_zero"] where key.hasSuffix(tail) {
            if Words.own[String(key.dropLast(tail.count))] != nil { return true }
        }
        return false
    }

    static func placeholders(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "\\{[A-Za-z0-9_]+\\}")
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s))
            .map { String(s[Range($0.range, in: s)!]) }.sorted()
    }

    static let beyondArabic = Words.supported.filter { $0 != "en" && $0 != "ar" }

    @Test("the Mac offers the nine languages the other app does")
    func nine() {
        #expect(Set(Words.supported) == ["en", "ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh"])
    }

    @Test("a language beyond English and Arabic loads its shared strings on first use",
          arguments: ["de", "es", "fr", "ja", "pt-BR", "tr", "zh"])
    func shared(_ code: String) async throws {
        let engine = try KhaytEngine()
        let en = try await engine.translations(language: "en")
        let theirs = try await engine.translations(language: code)
        #expect(theirs.count == en.count, "\(code): \(theirs.count) of \(en.count) shared strings")
        #expect(theirs["ord.gen_proforma"] != nil)
        #expect(theirs["ord.gen_proforma"] != en["ord.gen_proforma"], "\(code) proforma reads as English")
    }

    @Test("every Mac word has a translation in each language, with its placeholders",
          arguments: ["de", "es", "fr", "ja", "pt-BR", "tr", "zh"])
    func complete(_ code: String) {
        let table = Words.translated(code)
        var missing: [String] = [], placeholders: [String] = []
        for (key, entry) in Words.own where !Self.arabicOnly(key) {
            guard let said = table[key], !said.isEmpty else { missing.append(key); continue }
            if Self.placeholders(said) != Self.placeholders(entry["en"] ?? "") { placeholders.append(key) }
        }
        #expect(missing.isEmpty, "\(code) is missing \(missing.count): \(missing.sorted().prefix(10))")
        #expect(placeholders.isEmpty, "\(code) placeholders differ: \(placeholders.sorted().prefix(10))")
        let extra = table.keys.filter { Words.own[$0] == nil }
        #expect(extra.isEmpty, "\(code) has words the app no longer uses: \(extra.sorted().prefix(10))")
    }

    @Test("a shop in German reads German, in both halves")
    func german() async throws {
        let engine = try KhaytEngine()
        let words = Words()
        await words.load("de", engine: engine)
        #expect(words.language == "de")
        // Shared: the other app's word.
        let shared = try await engine.translations(language: "de")
        #expect(words.callIt("ord.gen_proforma") == shared["ord.gen_proforma"])
        // The Mac's own: from its file, not English.
        #expect(words.callIt("mac.take_the_job") == Words.translated("de")["mac.take_the_job"])
        #expect(words.callIt("mac.take_the_job") != Words.english("mac.take_the_job"))
        // Left to right, and dates in German.
        #expect(!words.isRTL)
        #expect(words.locale.language.languageCode?.identifier == "de")
    }

    @Test("an unknown language reads English, never keys")
    func unknown() async throws {
        let words = Words()
        await words.load("xx", engine: try KhaytEngine())
        #expect(words.language == "en")
        #expect(words.callIt("mac.take_the_job") == Words.english("mac.take_the_job"))
        #expect(Words.translated("xx").isEmpty)
    }
}
