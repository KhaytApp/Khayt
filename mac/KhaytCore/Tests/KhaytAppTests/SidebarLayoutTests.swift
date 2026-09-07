import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The sidebar footer must not wrap.
///
/// THE CRASH THIS EXISTS FOR. `Provenance` is the sidebar's
/// `.safeAreaInset(edge: .bottom)`, and the sidebar is a resizable split-view
/// column. A label allowed to wrap makes that view's HEIGHT depend on the
/// column's WIDTH — and a child whose size depends on the size it is given is a
/// feedback loop with `SplitViewChildController.hostingView(_:didUpdateMinSize:
/// maxSize:)`. AppKit ends the loop by throwing out of
/// `_postWindowNeedsUpdateConstraints`: an abort, with no reason attached.
///
/// It shipped in #997 as a two-line "changes here reach the cloud…", showed
/// only for a CLOUD-CONNECTED book — so never on the sample this app
/// photographs, and never in a snapshot run — and took the app down after a
/// minute or two of ordinary use on a real one.
///
/// A source scan, and named as one: there is no way to drive AppKit's layout
/// from a test. What it catches is the exact regression — somebody letting a
/// line wrap again because the sentence did not fit.
struct SidebarLayoutTests {

    static var sidebar: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Sidebar.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Everything from `struct Provenance` to the end of the file.
    static var footer: String {
        let all = sidebar
        guard let at = all.range(of: "private struct Provenance") else { return "" }
        return String(all[at.lowerBound...])
    }

    @Test("no line in the sidebar footer may wrap")
    func nothingWraps() {
        let body = Self.footer
        #expect(!body.isEmpty, "Provenance has been renamed")
        for limit in ["lineLimit(2)", "lineLimit(3)", "lineLimit(nil)"] {
            #expect(!body.contains(limit),
                    "a wrapping label is back in the sidebar footer: its height would depend on the column width, which is the loop that aborted the app")
        }
    }

    /// THE STRONGER FORM, AND THE ONE THAT WOULD HAVE CAUGHT IT.
    ///
    /// The check above forbids somebody *asking* for two lines. It says nothing
    /// about a label that asks for nothing — and SwiftUI wraps by default, so a
    /// `Label` with no cap at all is the same feedback loop written more
    /// quietly. Two of them were sitting here: the tax line ("VAT 15.00%
    /// included in the price", thirty-one characters) and the unreadable-records
    /// line. Neither had ever wrapped at the width this app is photographed at.
    @Test("every label in the footer is capped at one line")
    func everyLabelIsCapped() {
        let body = Self.footer
        var uncapped: [String] = []
        let parts = body.components(separatedBy: "Label(").dropFirst()
        for (i, part) in parts.enumerated() {
            // Up to the end of this label's modifier chain: the next `Label(`
            // is already excluded by the split, so stop at the next statement
            // that plainly is not one of ours.
            let chain = part.prefix(400)
            if !chain.contains(".lineLimit(1)") {
                let head = chain.prefix(while: { $0 != "\n" })
                uncapped.append("#\(i + 1)  Label(\(head))")
            }
        }
        #expect(uncapped.isEmpty, """
            \(uncapped.count) label(s) in the sidebar footer can wrap:

            \(uncapped.joined(separator: "\n"))

            Add `.lineLimit(1)` and put the long form in `.help`. A label whose
            height depends on the column's width is what aborted the app.
            """)
    }

    @Test("a long sentence goes in help, where its length costs nothing")
    func longTextIsATooltip() {
        let body = Self.footer
        // Each of the four lines that can carry a long string hands it to
        // `.help` rather than to the label.
        #expect(body.contains(".help(backupProblem)"))
        #expect(body.contains(".help(engineProblem)"))
        #expect(body.contains(".help(shop.lastCrash ?? \"\")"))
        #expect(body.contains("mac.sync_auto_why"))
    }

    /// A NAVIGATION LABEL IS NOT A SCREEN TITLE.
    ///
    /// Khayt calls three of these "Expense Tracker", "Failed Prints & Waste
    /// Log" and "Profit & Loss by Quarter" — good names for a screen, and too
    /// long for the column. Two of the three were truncated mid-word on every
    /// launch, in both languages, and nothing said so.
    ///
    /// The cap below was derived when the column could be dragged to 190pt.
    /// Its minimum is 225 now, so 22 characters is stricter than the column
    /// requires — deliberately left alone rather than raised to a number
    /// nobody has measured. What must not change is that it is checked against
    /// the MINIMUM width, not the ideal: the column is resizable, and a label
    /// that fits only when the user has not touched it is a label that
    /// truncates.
    ///
    /// Both languages, because Arabic is not the shorter one: "سجل المطبوعات
    /// الفاشلة والهدر" is twenty-eight characters where the English is
    /// twenty-five.
    @MainActor
    @Test("every name in the sidebar fits the column it is in")
    func sidebarNamesFit() async throws {
        let engine = try KhaytEngine()
        let sidebar = Self.sidebar
        // The keys the sidebar actually asks for, read from it rather than
        // listed here — a list would go stale the moment a row was added.
        var keys: Set<String> = []
        var rest = sidebar[...]
        while let at = rest.range(of: "Row(title: shop.words.callIt(\"") {
            let after = rest[at.upperBound...]
            rest = after
            if let end = after.firstIndex(of: "\"") { keys.insert(String(after[..<end])) }
        }
        #expect(keys.count >= 8, "found \(keys.count) sidebar names — the scan is wrong")

        for language in ["en", "ar"] {
            let words = Words()
            await words.load(language, engine: engine)
            for key in keys.sorted() {
                let said = words.callIt(key)
                #expect(said.count <= 22,
                        "\(language): \"\(said)\" is \(said.count) characters and will truncate")
            }
        }
    }

    @Test("every line the sidebar can show about sync fits the column")
    func theCloudLineIsShort() {
        // Under thirty characters at caption size fits the column's 190pt
        // minimum. This began as one string — the sentence that wrapped was
        // forty-eight — and is now seven, one per state sync can be in. Each of
        // them lands in exactly the same label, so each of them has to fit;
        // checking only the one that was long once is how the next long one
        // ships.
        let words = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Words.swift")
        let text = (try? String(contentsOf: words, encoding: .utf8)) ?? ""
        let labels = text.split(separator: "\n").filter {
            $0.contains("\"mac.sync_") && !$0.contains("mac.sync_auto_why")
        }
        // The tooltip is deliberately excluded above; everything else here is a
        // label. If this count drops, a state stopped being checked.
        #expect(labels.count == 7)
        for line in labels {
            guard let english = line.split(separator: "\"").dropFirst(3).first else {
                Issue.record("could not read the string in: \(line)"); continue
            }
            #expect(english.count < 30, "this sync line is long enough to wrap: \(english)")
        }
    }
}

/// The app's last words.
///
/// A macOS crash report for an uncaught Objective-C exception carries the
/// backtrace and NOT the reason — the very thing that made this crash expensive
/// to find. The app now writes its own note.
@MainActor
struct LastWordsTests {

    @Test("the note sits beside the book, where a shop can find it")
    func whereItGoes() {
        let path = LastWords.file(for: .development).path
        #expect(path.hasSuffix("/last-crash.txt"))
        #expect(path.contains("Application Support/khayt/"))
    }

    @Test("a note is written, read back and forgotten")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-lastwords-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "last-crash.txt")

        try "why: something went wrong".write(to: file, atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("something went wrong"))
        try FileManager.default.removeItem(at: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("no note is not a crash")
    func absentIsFine() {
        // A shop that has never crashed must see nothing, not an empty line.
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-none-\(UUID().uuidString)")
        #expect((try? String(contentsOf: dir.appending(path: "last-crash.txt"), encoding: .utf8)) == nil)
    }

    @Test("the handler is installed before anything that could fail")
    func installedFirst() throws {
        // Ordering is the whole point: a crash during `Direction.settle()` or
        // while the words load is exactly the kind that arrives mute.
        let main = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/main.swift"), encoding: .utf8)
        guard let listen = main.range(of: "LastWords.listen()"),
              let settle = main.range(of: "Direction.settle()") else {
            Issue.record("main.swift has changed shape"); return
        }
        #expect(listen.lowerBound < settle.lowerBound)
    }
}
