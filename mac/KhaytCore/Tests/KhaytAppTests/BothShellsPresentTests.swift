import Foundation
import Testing
@testable import KhaytApp

/// Both windows can raise a sheet.
///
/// ── THE BUG THIS EXISTS FOR ───────────────────────────────────────────────
///
/// The app has two shells while the redesign is being migrated. Every sheet in
/// it was chained onto the OLD one, so with the new shell switched on — which
/// shipped as the default — take a job, edit a product, record a payment and
/// add a spool all did nothing whatsoever. No error, no log line: the buttons
/// simply had no effect, and a shop's only possible report is "nothing
/// happened".
///
/// A sheet added to one shell and not the other is that bug again, so the test
/// is structural: the presentation chain must live in `WindowSheets` and both
/// shells must apply it. Reading the source rather than the rendering, because
/// what is being checked is that there is ONE chain, which no screenshot shows.
@MainActor
struct BothShellsPresentTests {

    static let source: String = {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/ShopWindow.swift")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }()

    @Test("the window's sheets live in one place")
    func sheetsAreInOneChain() {
        let text = Self.source
        #expect(!text.isEmpty, "ShopWindow.swift moved — this test is reading nothing")

        // Every `.sheet(` in the file must be inside `WindowSheets`, which is
        // at the end. Anything before it is attached to one shell only.
        guard let chain = text.range(of: "struct WindowSheets: ViewModifier") else {
            Issue.record("WindowSheets is gone; the sheets are attached to a shell again")
            return
        }
        let before = text[text.startIndex..<chain.lowerBound]
        let strays = before.components(separatedBy: ".sheet(").count - 1
        #expect(strays == 0, Comment(rawValue: """
            \(strays) sheet(s) are attached above WindowSheets, so they exist in \
            one shell and not the other — which is silent: the button does \
            nothing and nothing is logged.
            """))
    }

    @Test("both shells apply the chain")
    func bothShellsApplyIt() {
        let applied = Self.source.components(separatedBy: "WindowSheets(shop: shop)").count - 1
        #expect(applied >= 2, Comment(rawValue: """
            WindowSheets is applied \(applied) time(s). There are two shells and \
            both need it.
            """))
    }
}
