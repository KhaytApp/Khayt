import Foundation
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
