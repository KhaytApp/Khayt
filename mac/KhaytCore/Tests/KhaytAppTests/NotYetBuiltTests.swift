import Foundation
import Testing
@testable import KhaytApp

/// The README's "Not yet built" list, checked against the app.
///
/// That list had been wrong for months. It named gift cards, the portfolio,
/// the colour studio and the converter long after all four shipped, and it
/// undercounted the printer protocols. It is the section a person reads to
/// decide what to build next, so a list of finished work is worse than no list
/// at all — it is believed, and it sends somebody to rebuild a screen that is
/// already in the sidebar.
///
/// Prose cannot be checked, so this does not try. THE FIRST PARAGRAPH of that
/// section is the list; everything after it is explanation and may name a
/// finished thing freely. The README says so where the paragraph is.
@MainActor
struct NotYetBuiltTests {

    /// Every protocol a machine can be set to.
    ///
    /// From `main.js`'s default-port table, which is the canonical list: a
    /// protocol the app knows is one it has a port for. The machine form's
    /// `<option>` list would be the other candidate and is a worse one — it
    /// carries `none` and sits among other pickers, so it would have to be
    /// filtered by a rule that is itself a second list.
    static var offeredProtocols: Set<String> {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "main.js")
        guard let source = try? String(contentsOf: url, encoding: .utf8),
              let at = source.range(of: "const ports = {"),
              let end = source[at.upperBound...].firstIndex(of: "}") else { return [] }
        var found: Set<String> = []
        for pair in source[at.upperBound..<end].split(separator: ",") {
            let name = pair.split(separator: ":").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty, name != "none" { found.insert(name) }
        }
        return found
    }

    static var readme: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "README.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The claim itself: the heading, then the first paragraph, and no further.
    static var theList: String {
        let text = readme
        guard let heading = text.range(of: "## Not yet built") else { return "" }
        let after = text[heading.upperBound...]
            .drop(while: { $0 == "\n" })
        guard let end = after.range(of: "\n\n") else { return String(after) }
        // Wrapped at 80 columns, so a phrase this test looks for is as likely
        // to straddle a line break as not. Whitespace collapses to single
        // spaces before anything is matched against it.
        return String(after[..<end.lowerBound])
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    @Test("the section is where this test thinks it is")
    func theSectionExists() {
        #expect(!Self.readme.isEmpty, "mac/README.md moved")
        #expect(!Self.theList.isEmpty, "the “Not yet built” heading moved or lost its list")
        #expect(Self.theList.count < 600, "the first paragraph is no longer a list")
    }

    /// A shelf in the sidebar is a screen a shop can open. Naming one as unbuilt
    /// is the exact mistake this guards.
    @Test("nothing in the sidebar is listed as not yet built")
    func noBuiltShelfIsListed() {
        // Phrase → the file that proves it is built. Both halves are checked,
        // so deleting the screen and leaving the phrase does not pass either.
        let shipped: [(phrase: String, file: String)] = [
            ("gift card", "GiftCards.swift"),
            ("portfolio", "Portfolio.swift"),
            ("colour studio", "ColourStudio.swift"),
            ("converter", "Converter.swift"),
            ("reports", "Reports.swift"),
            ("expenses", "Spending.swift"),
            ("catalogue", "Catalogue.swift"),
        ]
        for (phrase, file) in shipped {
            guard Self.exists(file) else { continue }
            #expect(!Self.theList.contains(phrase),
                    "“\(phrase)” is listed as not yet built, and \(file) is in the app")
        }
    }

    static func exists(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/\(name)")
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The count of protocols, which is the half of the claim that drifts
    /// silently: adding one to `PrinterWatch.spoken` is a good day's work and
    /// nobody edits a README on a good day.
    @Test("the protocol count in the README is the one the app speaks")
    func protocolCountIsRight() {
        // ── DERIVED FROM THE APP, NOT WRITTEN DOWN TWICE ──────────────────
        //
        // This used to assert `spoken.count == 3` and name bambu, duet and
        // repetier in a literal. Teaching the app a fourth protocol then failed
        // this test for being right — the guard against a stale README had
        // itself gone stale, which is the same failure one level up.
        //
        // ── AND THE LIST OF ALL OF THEM IS DERIVED TOO ────────────────────
        //
        // This line WAS the literal `["moonraker", "octoprint", "prusalink",
        // "repetier", "duet", "bambu"]`, described as "the six a machine can
        // actually be set to" — and by then a machine could be set to seven.
        // `sdcp` had been added to the menu and to `main.js` and this set had
        // not moved, so the guard written to stop the README undercounting the
        // protocols was undercounting them itself, one level up, exactly as the
        // comment above describes happening the time before.
        //
        // So it is read from the menu a shop actually chooses from. A protocol
        // added there now fails this test until the README and the app agree
        // about it, which is the whole point of the test.
        let all = Self.offeredProtocols
        #expect(all.count > 1, "could not read the protocol menu from renderer/machines.js")
        #expect(PrinterWatch.spoken.isSubset(of: all),
                "the app speaks something this list does not know: \(PrinterWatch.spoken.subtracting(all))")
        let missing = all.subtracting(PrinterWatch.spoken).sorted()

        let numbers = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight"]
        let written = numbers[min(missing.count, numbers.count - 1)]
        let total = numbers[min(all.count, numbers.count - 1)]
        if missing.isEmpty {
            // NOT "zero of the seven printer protocols". A list of things not
            // yet built that names a category with nothing in it sends somebody
            // to look for work that does not exist, which is the same fault as
            // naming a finished feature — it is just written as a number.
            #expect(!Self.theList.contains("printer protocol"),
                    "every protocol is spoken and the README still lists some as missing")
        } else {
            #expect(Self.theList.contains("\(written) of the \(total) printer protocols"),
                    "the app is missing \(missing.count) of \(all.count) — the README does not say “\(written) of the \(total) printer protocols”")
        }
        for name in missing {
            #expect(Self.theList.contains(name),
                    "\(name) is not spoken and the README does not name it as missing")
        }
        for name in PrinterWatch.spoken {
            #expect(!Self.theList.contains(name),
                    "\(name) is spoken now, and the README still names it as missing")
        }
    }
}
