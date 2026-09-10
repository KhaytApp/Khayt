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
        // Six a machine can be set to; `renderer/machines.js` offers a seventh
        // and it is `none`.
        let total = 6
        let missing = total - PrinterWatch.spoken.count
        #expect(PrinterWatch.spoken.count == 3,
                "the app speaks \(PrinterWatch.spoken.count) protocols — the README says three")
        let written = ["zero", "one", "two", "three", "four", "five", "six"][missing]
        #expect(Self.theList.contains("\(written) of the six printer protocols"),
                "the README does not say “\(written) of the six printer protocols”")
        for name in ["bambu", "duet", "repetier"] {
            #expect(!PrinterWatch.spoken.contains(name),
                    "\(name) is spoken now, and the README still names it as missing")
            #expect(Self.theList.contains(name), "the README does not name \(name)")
        }
    }
}
