import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Charges that are not printing.
///
/// ── WHAT THIS SUITE IS GUARDING ───────────────────────────────────────────
///
/// A design fee, painting, a marketplace's cut. Khayt has priced these since
/// 3.0 and this app could not carry one, so a shop that charges for anything
/// but the print had to take the job in the other window.
///
/// The assertion that matters is that a PERCENTAGE is not an amount. The rule
/// works it out against the price before extras — after the margin, the
/// discount and the rounding — so a form that resolved it itself and handed
/// over a number would be a second answer, free to disagree with the invoice
/// the customer is sent.
@MainActor
struct ExtraLinesTests {

    static func flat(_ label: String, _ amount: Double) -> Shop.ExtraLine {
        var line = Shop.ExtraLine(); line.label = label; line.amount = amount; return line
    }

    static func percent(_ label: String, _ pct: Double) -> Shop.ExtraLine {
        var line = Shop.ExtraLine(); line.label = label; line.pct = pct; return line
    }

    @Test("a flat line writes an amount and a percentage line writes a percentage")
    func twoShapes() {
        guard case .object(let flat) = Self.flat("Design fee", 150).row,
              case .object(let pct) = Self.percent("Etsy", 6.5).row else {
            Issue.record("a line did not encode as an object"); return
        }
        #expect(flat["amount"] == .number(150))
        #expect(flat["pct"] == nil, "a flat line carries a percentage of nothing")
        #expect(pct["pct"] == .number(6.5))
        // AND NO AMOUNT. The resolved figure is the rule's to work out; writing
        // one here would be a second answer free to disagree with it.
        #expect(pct["amount"] == nil, "a percentage line carried a resolved amount")
    }

    @Test("a line nobody finished typing is not a charge")
    func halfWrittenLinesAreDropped() {
        // A zero-amount line is "Design fee 0.00" on the customer's invoice.
        #expect(!Shop.ExtraLine().isWorthKeeping)
        #expect(!Self.flat("Design fee", 0).isWorthKeeping)
        #expect(!Self.percent("Etsy", 0).isWorthKeeping)
        #expect(Self.flat("Design fee", 150).isWorthKeeping)
        #expect(Self.percent("Etsy", 6.5).isWorthKeeping)
    }

    // MARK: - Through the rule

    @Test("a flat charge is added to what the job comes to")
    func flatReachesTheTotal() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.engineProblem == nil, "no engine means this proves nothing")

        let without = try #require(await shop.previewQuote(
            baseCost: 100, margin: 40, discountPct: 0, shippingCost: 0, rush: false))
        let with = try #require(await shop.previewQuote(
            baseCost: 100, margin: 40, discountPct: 0, shippingCost: 0, rush: false,
            extraLines: [Self.flat("Design fee", 150)]))
        #expect(with.total == without.total + 150)
    }

    @Test("a percentage is worked out against the price before extras, by the rule")
    func percentIsTheRules() async throws {
        // 100 at 40% margin is a price before extras; 10% of THAT is the
        // charge. Asserted as a relationship rather than a figure typed here,
        // because the figure is the rule's and this app must not have a second
        // opinion about it.
        let shop = Shop()
        await shop.load(.sample)
        let plain = try #require(await shop.previewQuote(
            baseCost: 100, margin: 40, discountPct: 0, shippingCost: 0, rush: false))
        let tenth = try #require(await shop.previewQuote(
            baseCost: 100, margin: 40, discountPct: 0, shippingCost: 0, rush: false,
            extraLines: [Self.percent("Marketplace", 10)]))
        #expect(abs(tenth.total - plain.total * 1.1) < 0.005,
                "a percentage line did not resolve against the price before extras")

        // And it is NOT ten percent of the cost, which is the answer a form
        // working it out for itself would most likely have given.
        #expect(abs(tenth.total - (plain.total + 10)) > 0.005)
    }

    @Test("the job written down carries the lines, and not the half-written ones")
    func theRecordCarriesThem() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let input = shop.newJobInput(
            parts: [], project: "Bracket", clientId: nil,
            margin: 40, discountPct: 0, shippingCost: 0, deposit: 0,
            rush: false, asQuote: false,
            extraLines: [Self.flat("Design fee", 150), Shop.ExtraLine(),
                         Self.percent("Etsy", 6.5)])
        guard case .array(let lines)? = input["extraLines"] else {
            Issue.record("the job input carries no extra lines at all"); return
        }
        #expect(lines.count == 2, "a blank row was written onto the job")

        // A job with none carries no field rather than an empty list: the other
        // app writes `extraLines` only when there are some, and a book two apps
        // write has to look the same whichever one wrote it.
        let bare = shop.newJobInput(
            parts: [], project: "Bracket", clientId: nil,
            margin: 40, discountPct: 0, shippingCost: 0, deposit: 0,
            rush: false, asQuote: false)
        #expect(bare["extraLines"] == nil)
    }

    @Test("the sheet offers them, and reprices when one changes")
    func theSheetIsWired() throws {
        let sheet = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/NewJobSheet.swift"), encoding: .utf8)
        #expect(sheet.contains("calc.add_extra_line"), "there is no way to add one")
        #expect(sheet.contains("extraLines: extraLines"),
                "the lines are typed in and never reach the quote or the job")
        // A charge added without the total moving is a form that looks broken.
        #expect(sheet.contains(".onChange(of: extraLines)"))
    }
}
