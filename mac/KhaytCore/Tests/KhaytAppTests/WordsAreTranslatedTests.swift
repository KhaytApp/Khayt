import Foundation
import Testing
@testable import KhaytApp

/// Nothing on a screen may be written in English in the source.
///
/// THIS IS THE GUARD, and it exists because the last two of these were found in
/// a photograph. A shop running Khayt in Arabic saw its customers' names in
/// English on one screen (#994) and, until this file, read "No jobs yet",
/// "Reveal in Finder", "Marked urgent" and forty more the same way — every one
/// of them under a right-to-left toolbar.
///
/// A string literal handed to a view is not a compile error, not a lint error,
/// and looks perfectly correct in the language it happens to be written in. The
/// only thing that catches it is a rule, so this is the rule: **if it reaches a
/// view, it comes from `Words`.**
@MainActor
struct WordsAreTranslatedTests {

    /// Constructors whose first argument lands on screen.
    static let shows = ["Text", "Label", "Button", "Toggle", "TextField", "SecureField",
                        "ContentUnavailableView", "DetailSection", "DetailLine",
                        "Picker", "LabeledContent"]
    /// Modifiers whose argument lands on screen — or in VoiceOver, which counts.
    static let modifiers = [".help", ".accessibilityLabel", ".navigationTitle"]

    /// Files that legitimately hold English, with the reason.
    ///
    /// Kept short on purpose. Each line here is a place a shop could still be
    /// shown a word it does not read.
    static let exempt: [String: String] = [
        // The dictionary itself: English is one of the two columns.
        "Words.swift": "the catalogue — English sits beside Arabic by design",
        // Low-level writers with no interface language in scope. What they carry
        // is a fallback for a lock whose holder did not name itself, and
        // threading `Words` into a file writer to say it would be worse than the
        // gap. KNOWN GAP: these four sentences are English in every language.
        "StoreWriter.swift": "a nonisolated writer, below the interface",
        "StoreLock.swift": "a nonisolated lock, below the interface",
        "Restore.swift": "shares the writer's refusals",
    ]

    /// Units no locale file has a word for, so writing one is not a decision
    /// about translation.
    ///
    /// `mm` and `W` are in none of the nine. `h m` is the printer's compact
    /// "2h 15m" remaining time: `common.hours` is "hrs" / Arabic, and there is
    /// no minutes key at all, so translating the hour and leaving the minute
    /// reads worse than leaving both. Add `common.minutes` in nine languages
    /// and those two go.
    /// `ΔE` is the CIE's symbol for colour difference and no locale file
    /// translates it — `cmix.plot_title` is "خريطة ΔE · مستوى اللون a*b*" in
    /// Arabic, which keeps the symbol inside its own sentence. Looked up, like
    /// the rest of this list.
    /// Things that are not words in any language: units, and the tail of a
    /// filename. `— .3mf` is what is left of a suggested save name once its
    /// interpolations are removed, and a file extension is not translated —
    /// a converted model is `.3mf` on an Arabic Mac too.
    static let noWordForIt: Set<String> = ["mm", "W", "h m", "m", "kB", "MB", "GB", "ΔE",
                                           "— .3mf", ".3mf"]

    /// A literal with its `\(…)` taken out, brackets BALANCED.
    ///
    /// It was `#"\\\([^)]*\)"#`, which stops at the first `)` — so
    /// `"\(Int((done / goal * 100).rounded()))%"` had only its first bracket
    /// pair removed and left `.rounded()))%` behind. That is seven letters of
    /// Swift, and the guard reported a line whose only visible character is a
    /// percent sign. An interpolation is code and none of it is words, however
    /// many brackets deep it goes.
    static func withoutInterpolations(_ text: String) -> String {
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let next = text.index(after: i)
            if text[i] == "\\", next < text.endIndex, text[next] == "(" {
                var depth = 0
                var j = next
                while j < text.endIndex {
                    if text[j] == "(" { depth += 1 }
                    else if text[j] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    j = text.index(after: j)
                }
                guard j < text.endIndex else { break }
                i = text.index(after: j)
                continue
            }
            out.append(text[i])
            i = next
        }
        return out
    }

    /// Words that are the same in every language, or are not words.
    static func isNotAWord(_ text: String) -> Bool {
        // Take the interpolations out first. What is left is what a shop
        // actually has to read: `"×\(part.qty)"` is a multiplication sign and a
        // number, and neither of those is English.
        let literal = Self.withoutInterpolations(text)
        if literal.rangeOfCharacter(from: .letters) == nil { return true }
        if text.count < 3 { return true }                      // "—", "×", "mm"
        if !text.contains(" ") && text.first?.isLowercase == true { return true }  // a key or an id
        // A UNIT — and the two rules that used to sit here let every one of
        // them through. `"\(Int(grams)) g"` starts with an interpolation, so
        // the "pure interpolation" rule said yes; and what is left once the
        // interpolations come out is " g", which is shorter than three
        // characters, so the length rule said yes as well. Seven weights in
        // this app were followed by a Latin g on an Arabic screen because of
        // those two lines, and common.grams had been carrying the Arabic the
        // whole time.
        //
        // A short leftover is no longer a pass. It has to be a unit the
        // catalogue has no word for, and each of those was looked up in
        // `renderer/locales/*.js` rather than assumed.
        if Self.noWordForIt.contains(literal.trimmingCharacters(in: .whitespaces)) { return true }
        // A locale key, which is the whole point.
        if text.range(of: #"^[a-z][a-z0-9]*\.[a-z0-9_.]+$"#, options: .regularExpression) != nil {
            return true
        }
        // Names and marks that do not translate.
        return ["Khayt", "SAR", "PLA", "PETG", "VAT No.", "+966 5x xxx xxxx"].contains(text)
    }

    /// Read one Swift string literal, starting at its opening quote.
    ///
    /// It has to skip `\(…)` WHOLE, brackets and quotes together, because an
    /// interpolation can hold a string of its own — and
    /// `Text("\(grams) \(words.callIt("common.grams"))")` is one literal, not
    /// two. Reading quote-to-quote cuts it at `callIt("`, and then the guard
    /// reports the half it cut, which is how a correct line ends up on a list
    /// of mistakes.
    static func literal(from after: Substring) -> String? {
        var out = ""
        var i = after.index(after: after.startIndex)
        while i < after.endIndex {
            let c = after[i]
            if c == "\\", after.index(after: i) < after.endIndex, after[after.index(after: i)] == "(" {
                var depth = 0
                var j = after.index(after: i)
                while j < after.endIndex {
                    if after[j] == "(" { depth += 1 }
                    else if after[j] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    j = after.index(after: j)
                }
                guard j < after.endIndex else { return nil }
                out += after[i...j]
                i = after.index(after: j)
                continue
            }
            if c == "\\" {
                let next = after.index(after: i)
                guard next < after.endIndex else { return nil }
                out += after[i...next]
                i = after.index(after: next)
                continue
            }
            if c == "\"" { return out }
            out.append(c)
            i = after.index(after: i)
        }
        return nil
    }

    @Test("no screen in this app spells anything out in English")
    func everyVisibleStringComesFromWords() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let files = try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 30, "the source moved — this test is reading the wrong directory")

        let calls = (Self.shows.map { "\($0)(" } + Self.modifiers.map { "\($0)(" })
        var found: [String] = []

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            if Self.exempt[name] != nil { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for call in calls {
                    var search = trimmed[...]
                    while let at = search.range(of: call) {
                        let after = search[at.upperBound...]
                        search = after
                        guard let quote = after.first, quote == "\"" else { continue }
                        guard let literal = Self.literal(from: after) else { continue }
                        if Self.isNotAWord(literal) { continue }
                        found.append("\(name):\(n + 1)  \(call)\"\(literal)\"")
                    }
                }
            }
        }

        #expect(found.isEmpty, """
            \(found.count) string(s) reach a screen without going through Words:

            \(found.joined(separator: "\n"))

            Add a key to `Words.own` with its Arabic and call `words.callIt(_:)`.
            """)
    }

    /// Names of things, which are short and look exactly like units.
    ///
    /// Listed one by one rather than matched by a pattern, because any pattern
    /// loose enough to exclude `tmp` and `En` also excludes `g`.
    static let notShown: Set<String> = [
        #"\(base)En"#, #"\(base)Ar"#,                       // store field names
        #" on \($0)"#,                                       // the lock's English sentence
        #"\(rawValue) Key"#,                                 // a Keychain item's name
        #"\(url.lastPathComponent).tmp.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"#,
    ]

    /// The SECOND rule, and the one that catches what the first cannot see.
    ///
    /// The test above reads the argument of `Text(`, `Label(` and the rest. Of
    /// the seven weights this app printed with an English `g`, it saw three.
    /// The other four were built into a `String` first — inside a `.map {}`,
    /// in a `var label`, appended to a note — and shown a line or a file away,
    /// which no scan of a constructor's argument will ever find.
    ///
    /// What they have in common is not where they are. It is their SHAPE: a
    /// number, then one to three letters. That is a unit, it is narrow enough
    /// to look for anywhere in the file without argument, and it does not drag
    /// in the app's English error messages, which are prose and are a separate
    /// question.
    @Test("no unit is spelled out in Swift where the catalogue has a word for it")
    func unitsComeFromTheCatalogue() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let files = try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 30, "the source moved — this test is reading the wrong directory")

        var found: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                // A log is for whoever is reading the console, not for a shop.
                if trimmed.contains("standardError") { continue }
                var search = trimmed[...]
                while let quote = search.firstIndex(of: "\"") {
                    let from = search[quote...]
                    guard let literal = Self.literal(from: from) else { break }
                    search = from.dropFirst(literal.count + 1)
                    guard literal.contains("\\(") else { continue }   // no number, no unit
                    if Self.notShown.contains(literal) { continue }
                    let rest = Self.withoutInterpolations(literal)
                    let letters = rest.filter(\.isLetter)
                    // Nothing is nothing; four letters or more is prose.
                    guard !letters.isEmpty, letters.count <= 3 else { continue }
                    if Self.noWordForIt.contains(rest.trimmingCharacters(in: .whitespaces)) { continue }
                    if Self.noWordForIt.contains(String(letters)) { continue }
                    found.append("\(name):\(n + 1)  \"\(literal)\"")
                }
            }
        }

        #expect(found.isEmpty, """
            \(found.count) unit(s) written in Swift where the catalogue has a word:

            \(found.joined(separator: "\n"))

            Use `words.callIt("common.grams")` and the like. If the catalogue really
            has no key for it, go and look before adding it to `noWordForIt`.
            """)
    }

    /// Every exemption names a file that exists, so the list cannot quietly
    /// grow to cover files that were renamed away.
    @Test("nothing is exempt that is not there")
    func exemptionsAreReal() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        for (name, why) in Self.exempt {
            #expect(FileManager.default.fileExists(atPath: views.appending(path: name).path),
                    "\(name) is exempt (\(why)) and does not exist")
        }
    }
}

/// One of a thing, said as one.
@MainActor
struct SingularTests {
    /// "1 days late" was on the dashboard of every shop with a job one day
    /// over. `counting` cannot fix this one: it puts the number first — right
    /// for "3 jobs", wrong here, because Arabic says متأخر before the count. So
    /// the placeholder stays inside the sentence and the sentence has a
    /// singular, which BOTH languages have to carry.
    ///
    /// Asserted against the catalogue rather than a loaded `Words`, which takes
    /// its language from the engine and cannot be asked for one directly.
    @Test("a sentence with a count inside it has a singular in every language")
    func sentencesWithCountsHaveSingulars() throws {
        for key in ["mac.days_late"] {
            let many = try #require(Words.own[key], "\(key) is missing")
            let one = try #require(Words.own[key + "_one"], "\(key)_one is missing")
            for language in ["en", "ar"] {
                let singular = try #require(one[language], "\(key)_one has no \(language)")
                let plural = try #require(many[language], "\(key) has no \(language)")
                // The count still has somewhere to go in both.
                #expect(singular.contains("{n}"), "\(language) singular lost its count")
                #expect(plural.contains("{n}"), "\(language) plural lost its count")
            }
            // And in English they actually differ, or the singular is decoration.
            #expect(one["en"] != many["en"], "the English singular is the plural")
        }
        #expect(Words.own["mac.days_late_one"]?["en"] == "{n} day late")
        #expect(Words.own["mac.days_late"]?["en"] == "{n} days late")
    }
}
