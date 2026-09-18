import Foundation
import Testing
@testable import KhaytApp

/// Nothing the app has to say lives only in the window it no longer opens.
///
/// ── THE BUG THIS EXISTS FOR ───────────────────────────────────────────────
///
/// `ShellChoice.byDefault` has been true since 4.0.0-alpha.12, so `Shell.swift`
/// is the window that ships and `Sidebar.swift` is the one being retired.
/// Anything written into the old one after that date shipped in no window at
/// all — and nothing said so, because the code was there, correct, and tested.
///
/// It has happened three times that we know of:
///
///   * the Simple-mode feature gate, so a Simple shop saw every screen;
///   * `shop.skipped`, so a shop was never told that records in its book could
///     not be read — the app dropped data and said nothing;
///   * `shop.lastCrash` and the sync line, so neither was ever shown.
///
/// The sheets had already been caught once — see `BothShellsPresentTests`,
/// which guards the presentation chain and only that.
///
/// So this is the general form: every `shop.…` the RETIRED shell reads must be
/// read somewhere the shipping window can reach, or be named here with a
/// reason. It reads the source rather than the rendering, because what is
/// being checked is that something asks at all.
@MainActor
struct NothingLivesOnlyInTheOldShellTests {

    static let sources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/KhaytApp")

    static func text(_ file: String) -> String {
        (try? String(contentsOf: sources.appending(path: file), encoding: .utf8)) ?? ""
    }

    /// Properties the retired shell may read alone, with the reason.
    ///
    /// `count` is not a property of `Shop` at all — it is the tail of
    /// `shop.customers.count` and friends, which the scan cannot tell apart.
    /// `wasteLog` is read by the Waste screen through `Spending.swift`.
    static let allowed: Set<String> = ["count", "wasteLog"]

    @Test("the old shell is still the one being retired, not the one that ships")
    func theShippingShellIsTheNewOne() {
        // If this ever flips, the whole test is pointed at the wrong file.
        #expect(ShellChoice.byDefault,
                "the app opens with Sidebar.swift again — swap the two files here")
    }

    @Test("everything the retired shell reads is read somewhere that ships")
    func nothingIsStrandedInTheOldShell() throws {
        let old = Self.text("Sidebar.swift")
        guard !old.isEmpty else { return }   // when it goes, so does this

        var read: Set<String> = []
        for match in old.ranges(of: /shop\.([a-zA-Z][a-zA-Z0-9]*)/) {
            read.insert(String(old[match]).replacingOccurrences(of: "shop.", with: ""))
        }
        #expect(read.count > 15, Comment(rawValue: "only \(read.count) found — the scan has rotted"))

        // Every other source file in the app, which is everything the shipping
        // window can reach.
        var elsewhere = ""
        let walker = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  url.lastPathComponent != "Sidebar.swift" else { continue }
            elsewhere += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        #expect(elsewhere.count > 100_000, "the walk read almost nothing")

        var stranded: [String] = []
        for name in read.subtracting(Self.allowed).sorted() where !elsewhere.contains("shop.\(name)") {
            stranded.append(name)
        }
        #expect(stranded.isEmpty, Comment(rawValue: """
            \(stranded.count) thing(s) are read only by the shell the app no longer \
            opens with, so they ship in no window at all: \(stranded.joined(separator: ", ")).

            Add them to the shipping window, or name them in `allowed` with the \
            reason. This has happened three times: the Simple-mode gate, the \
            unreadable-records warning, and the crash notice.
            """))
    }

    @Test("the three that were stranded are shown by the shipping shell now")
    func theKnownThreeAreShown() {
        // Named individually as well as caught by the sweep, so a rename
        // cannot quietly take one out of both.
        let shell = Self.text("Shell.swift")
        #expect(!shell.isEmpty, "Shell.swift moved")
        for name in ["shop.skipped", "shop.lastCrash", "shop.syncLine"] {
            #expect(shell.contains(name), Comment(rawValue: """
                the shipping window stopped reading \(name). A shop is not being \
                told something the app knows.
                """))
        }
    }

    @Test("sync is described in one place, not two")
    func syncIsOneSentence() {
        // It was private to a type inside the retired shell. Two copies of
        // "what sync is doing" is how the two windows start telling a shop
        // different things.
        let old = Self.text("Sidebar.swift")
        guard !old.isEmpty else { return }
        #expect(!old.contains("func syncLine(_ shop: Shop)"),
                "syncLine is back inside the retired shell")
        #expect(Self.text("Shop.swift").contains("var syncLine:"),
                "syncLine left Shop — the two shells can drift again")
    }
}
