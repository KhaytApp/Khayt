import Foundation
import SwiftUI
import KhaytCore
import Testing
@testable import KhaytApp

/// A size, a ratio or a phone number keeps its order inside an Arabic line.
///
/// `Figure.isolated` used a first-strong isolate for everything. Text with no
/// letter has no strong character, so the isolate took the direction of the
/// Arabic paragraph and the parts swapped: a 250 × 220 × 270 bed read
/// 270 × 220 × 250, and nozzle wear 8,419 / 8,000 read 8,000 / 8,419 — used
/// and limit exchanged (Nov 11 2026 UI review, B16).
@MainActor
struct FiguresKeepTheirOrderTests {
    static let lri = "\u{2066}", fsi = "\u{2068}", pdi = "\u{2069}"

    @Test("text with no letter is isolated left to right, in either digit set")
    func bareFigures() {
        for figure in ["250 × 220 × 270", "8,419 / 8,000", "9 / 10", "210° / 60°", "+966 50 123 4567",
                       "٢٥٠ × ٢٢٠ × ٢٧٠", "−390.00", "62%", "3×"] {
            #expect(Figure.isBareFigure(figure), "\(figure)")
            #expect(Figure.isolated(figure) == Self.lri + figure + Self.pdi, "\(figure)")
        }
    }

    @Test("a name or a word keeps the first-strong isolate, so Arabic in an English line is still right to left")
    func names() {
        for text in ["Maker", "4 rolls", "ORD-01011", "Bambu X1C", "الرياض", "3 بكرات", "\u{20C1}", "—", ""] {
            #expect(!Figure.isBareFigure(text), "\(text)")
            #expect(Figure.isolated(text) == Self.fsi + text + Self.pdi, "\(text)")
        }
    }

    @Test("the screens that showed them reversed isolate the whole expression, not each number")
    func theSitesAreWired() {
        let floor = MenuCoverageTests.source("ShopFloor.swift")
        #expect(floor.contains(#"Figure.isolated(shop.words.numeral(Int(saturating: wear.wear)) + " / ""#),
                "nozzle wear: used / limit")
        #expect(floor.contains("machine.bedSize(numeral: shop.words.numeral).map({ Figure.isolated($0) })"),
                "the bed: x × y × z")
        #expect(MenuCoverageTests.source("LibraryInspector.swift")
            .contains(#"Figure.isolated("\(setup.ok) / \(setup.ok + setup.failed)")"#), "tried and passed")
        #expect(MenuCoverageTests.source("TestPrintLogSheet.swift").contains(#"Figure.isolated(print + " / " + bed)"#))
    }
}

/// Arabic headings join, and the footer's tax line is Arabic (B17, B22).
@MainActor
struct ArabicHeadingsAndTaxLineTests {

    @Test("a small heading is monospaced in Latin script and the interface face in Arabic")
    func eyebrowFace() {
        #expect(TypeScale.eyebrow(11, joined: false) == Font.system(size: 11, weight: .medium, design: .monospaced))
        #expect(TypeScale.eyebrow(11, joined: true) == Font.system(size: 12, weight: .semibold))
        // The three headings that drew Arabic in a typewriter fallback.
        #expect(MenuCoverageTests.source("Sidebar.swift").contains(".font(TypeScale.eyebrow(10))"))
        let today = MenuCoverageTests.source("TodayPieces.swift")
        #expect(today.contains(".font(TypeScale.eyebrow(11))") && today.contains(".font(TypeScale.eyebrow(10))"))
        #expect(!today.contains("design: .monospaced"))
    }

    @Test("the tax line names the tax in the app's language, and Arabic says the price includes the tax")
    func taxLine() async throws {
        let engine = try KhaytEngine()
        let ar = Words(), en = Words()
        await ar.load("ar", engine: engine)
        await en.load("en", engine: engine)
        #expect(Shop.taxLabel("VAT", words: ar) == ar.callIt("an.pnl_vat"))
        #expect(Shop.taxLabel("GST", words: ar) == "GST")
        let line = ar.callIt("mac.tax_inclusive", ["name": .string(Shop.taxLabel("VAT", words: ar)), "pct": .string("15.00")])
        #expect(line.hasPrefix("السعر شامل"), "\(line)")
        #expect(!line.contains("VAT"))
        #expect(line.contains("15.00%"))
        #expect(en.callIt("mac.tax_inclusive", ["name": .string("VAT"), "pct": .string("15.00")]) == "VAT 15.00% included in the price")
        #expect(MenuCoverageTests.source("Shop+Printers.swift").contains(#""name": .string(Self.taxLabel(profile.name, words: words))"#))
    }
}
