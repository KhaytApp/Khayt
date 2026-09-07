import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The app's vocabulary must be complete in every language it offers.
///
/// A missing word does not crash — it renders the KEY, and `queue.printing`
/// sitting in a sidebar is the kind of thing that ships.
@MainActor
struct WordsTests {

    @Test("every Khayt key this app borrows exists in every bundled language")
    func borrowedKeysExist() async throws {
        let engine = try KhaytEngine()
        for language in Words.supported {
            let catalogue = try await engine.translations(language: language)
            #expect(!catalogue.isEmpty, "\(language) loaded no strings at all")
            for key in Words.borrowed {
                let value = catalogue[key]
                #expect(value?.isEmpty == false,
                        "\(language) has no \(key) — the Mac app would show the key itself")
            }
        }
    }

    @Test("every word this app supplies itself carries both languages")
    func ownKeysAreComplete() {
        for (key, values) in Words.own {
            for language in Words.supported {
                let value = values[language]
                #expect(value?.isEmpty == false, "\(key) has no \(language)")
            }
            // An Arabic value identical to the English one is an untranslated
            // string wearing a translation's clothes — the exact failure
            // test/locale-quality.test.js was written for on the shared
            // catalogue. Numbers and symbols are the honest exceptions.
            //
            // So are PLACEHOLDER NAMES. "{month} · {amount}" is the same line
            // in both languages because everything in it is substituted and the
            // only literal is a separator; the letters belong to `{month}`, not
            // to the sentence. Stripping the braces before the check is what
            // tells that apart from a real string somebody forgot — which is
            // still caught, because a forgotten one has letters outside them.
            if let en = values["en"], let ar = values["ar"], en == ar {
                let literal = en.replacing(/\{[A-Za-z0-9_]+\}/, with: "")
                #expect(literal.rangeOfCharacter(from: .letters) == nil,
                        "\(key) is the same in both languages: \(en.debugDescription)")
            }
        }
    }

    /// `counting` appends `_one` and asks for it. A key that is not there comes
    /// back AS ITS OWN NAME — the window would read "1 mac.machines_count_one"
    /// — so every base a screen counts with has to have its singular.
    @Test("every count this app makes has a word for one of them")
    func everyCountHasASingular() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        var asked: Set<String> = []
        for file in try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            // Not Words.swift: `counting` is DEFINED there, and its own body
            // is not a call site — the first string after it is `"\(n) "`.
            where file.pathExtension == "swift" && file.lastPathComponent != "Words.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            var rest = text[...]
            // `.counting(`, WITH THE DOT. Bare `counting(` also matches the
            // tail of `exportForAccounting(` — exportAc·counting( — and the
            // scan then took the next string literal it could find, which was
            // whatever happened to come after that call. It reported
            // `mac.open_book` and `mac.move_sample` as counted words needing a
            // singular, and neither is counted at all.
            while let at = rest.range(of: ".counting(") {
                let after = rest[at.upperBound...]
                rest = after
                guard let quote = after.firstIndex(of: "\"") else { continue }
                let tail = after[after.index(after: quote)...]
                guard let end = tail.firstIndex(of: "\"") else { continue }
                asked.insert(String(tail[..<end]))
            }
        }
        #expect(asked.count >= 5, "found \(asked.count) counted words — the scan is wrong, not the app")

        let words = Words()
        for base in asked.sorted() {
            for key in [base, base + "_one"] {
                #expect(Words.own[key] != nil, "\(key) is counted with and does not exist")
                #expect(Words.own[key]?["ar"]?.isEmpty == false, "\(key) has no Arabic")
                #expect(words.callIt(key) != key, "\(key) would print as its own name")
            }
        }
    }

    @Test("a borrowed key never shadows one this app supplies")
    func noOverlap() async throws {
        // Both catalogues are consulted, Khayt's first. A key in both means this
        // app's word is dead code that reads as if it were in use.
        let engine = try KhaytEngine()
        let catalogue = try await engine.translations(language: "en")
        for key in Words.own.keys {
            #expect(catalogue[key] == nil,
                    "\(key) is in Khayt's catalogue too — this app's copy would never be used")
        }
    }

    @Test("Khayt's word wins, and the key is the last resort")
    func resolutionOrder() async throws {
        let words = Words()
        await words.load("ar", engine: try KhaytEngine())
        #expect(words.language == "ar")
        #expect(words.isRTL)
        #expect(words.layout == .rightToLeft)
        // Borrowed: Khayt's Arabic, not a Swift string.
        #expect(words.callIt("queue.printing") == "قيد الطباعة")
        // Own: this app's Arabic.
        #expect(words.callIt("mac.cancelled") == "ملغى")
        // Neither: the key, visibly.
        #expect(words.callIt("mac.no.such.key") == "mac.no.such.key")
    }

    @Test("an unsupported language falls back to English rather than to nothing")
    func fallsBack() async throws {
        let words = Words()
        await words.load("ja", engine: try KhaytEngine())
        #expect(words.language == "en")
        #expect(!words.isRTL)
        #expect(words.callIt("queue.printing") == "Printing")
    }

    @Test("every stage has a word in both languages")
    func stagesAreNamed() async throws {
        let engine = try KhaytEngine()
        for language in Words.supported {
            let words = Words()
            await words.load(language, engine: engine)
            for stage in Stage.allCases {
                let said = words.callIt(stage.key)
                #expect(said != stage.key, "\(language) has no word for \(stage.rawValue)")
                #expect(!said.isEmpty)
            }
        }
    }
}

/// Everything the menu bar says.
///
/// The menu bar is the one part of the app whose words are decided BEFORE a
/// book is open — a SwiftUI menu title is baked when the bar is built and never
/// rewritten, so `Words.upfront` reads the catalogue that `Words.preload` warms
/// in `main.swift`. A key with no value there does not fall back to English on
/// screen; it renders as the key, in the menu bar, for ever.
@MainActor
struct MenuWordsTests {

    /// Every key any menu asks `Words.upfront` for.
    static let menuKeys = [
        "mac.menu_book", "mac.menu_go", "mac.menu_job", "mac.menu_model",
        "mac.reload", "mac.open_book",
        "mac.dashboard", "mac.all_jobs", "mac.board", "mac.customers",
        "mac.library", "mac.machines", "mac.inventory",
        "mac.favourite", "mac.reveal_in_finder", "mac.open",
        "mac.sort_by", "ord.hold_btn", "pay.modal_title", "queue.delivered", "mac.edit_job", "mac.new_job", "mac.new_customer",
    ]

    @Test("every menu word exists in both languages, warm or not")
    func everyMenuWordResolves() async throws {
        let engine = try KhaytEngine()
        for language in Words.supported {
            let words = Words()
            await words.load(language, engine: engine)
            for key in Self.menuKeys + Stage.allCases.map(\.key) {
                let said = words.callIt(key)
                #expect(said != key, "\(language) has no word for \(key) — the menu would show the key")
                #expect(!said.isEmpty)
            }
        }
    }

    @Test("a cold start still says words, not keys")
    func upfrontWithoutAWarmCatalogue() {
        // Before preload runs — or when it fails, because a store could not be
        // read — `upfront` has only this app's own catalogue. Every key the menu
        // BAR itself needs must be in it, or the bar reads as broken on a Mac
        // with no book on it yet.
        let ownOnly = ["mac.menu_book", "mac.menu_go", "mac.menu_job", "mac.menu_model",
                       "mac.reload", "mac.open_book", "mac.favourite",
                       "mac.reveal_in_finder", "mac.open", "mac.dashboard",
                       "mac.all_jobs", "mac.board", "mac.customers", "mac.library",
                       "mac.machines", "mac.inventory", "mac.sort_by"]
        for key in ownOnly {
            #expect(Words.upfront(key) != key, "\(key) is not in Words.own, so a cold menu shows the key")
        }
    }
}

/// SENTENCES ASSEMBLED IN SWIFT.
///
/// Every visible string in this app goes through `words.callIt`, and a test
/// above checks that each key it supplies carries both languages. Neither
/// noticed the one line that was built by concatenation:
///
///     "\(profile.name) \(percent)% included in the price"
///
/// It sits in the sidebar footer on every screen, so an Arabic shop read its
/// tax name in Arabic followed by four English words. It never passed through a
/// `Text` literal, so nothing was looking.
///
/// This looks for the shape rather than that one instance: an English phrase,
/// several words long, sitting in a string literal in a source file.
@MainActor
struct AssembledSentenceTests {

    /// Words that only turn up in prose. A literal containing two or more of
    /// them, outside a comment, is a sentence somebody wrote for a screen.
    static let prose = ["the", "and", "in the", "on top", "of the", "to the", "is not",
                        "does not", "has been", "will be", "was not"]

    @Test("no visible sentence is welded together in Swift")
    func noAssembledProse() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        // `Words.swift` IS the sentences. `CloudReader`/`CloudWriter`/
        // `LeadTime` carry English service errors on purpose, and say so in
        // their own comments — a gap those three share and none should close
        // alone.
        // Every name here carries its reason in its OWN file, next to the
        // messages — a list of exemptions with the argument kept somewhere else
        // is a list that grows without anybody deciding anything.
        let exempt: Set<String> = ["Words.swift", "CloudReader.swift", "CloudWriter.swift",
                                   "LeadTime.swift", "StoreWriter.swift", "StoreLock.swift",
                                   "Restore.swift", "Backups.swift", "Export.swift",
                                   "PrinterWatch.swift", "Secrets.swift", "LastWords.swift",
                                   // File-format readers. Their failures describe
                                   // a file, not a situation a shop is in.
                                   "Mesh.swift", "Zip.swift", "ModelInfo.swift"]
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") && !exempt.contains($0) }

        for file in files.sorted() {
            let source = try String(contentsOf: dir.appending(path: file), encoding: .utf8)
            for line in source.split(separator: "\n") {
                let text = String(line)
                // Comments, not just doc comments: the fix for the tax line
                // quotes the English it replaced, in an ordinary `//` note
                // explaining why. Prose about a sentence is not that sentence.
                let code = text.components(separatedBy: "//").first ?? text
                guard let quoted = code.firstMatch(of: /"([^"\\]{12,})"/) else { continue }
                let literal = String(quoted.1).lowercased()
                // A key, a symbol name or a path is not prose.
                guard !literal.contains("."), !literal.contains("/") else { continue }
                let hits = Self.prose.filter { literal.contains(" \($0) ") }.count
                if hits >= 2 {
                    Issue.record(Comment(rawValue:
                        "\(file) builds a sentence in Swift: \"\(quoted.1)\" — it needs a Words key"))
                }
            }
        }
    }
}
