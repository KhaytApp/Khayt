import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What the pre-release review for 4.0.0-beta.34 found in the range since
/// beta.33, pinned.
@MainActor
struct Beta34ReviewTests {

    static func number(_ row: JSONValue, _ key: String) -> Double? {
        guard case .object(let o) = row, case .number(let n)? = o[key] else { return nil }
        return n
    }

    @Test("a part typed in Arabic digits or with a decimal comma is SAVED with its weight and time")
    func typedPartsAreSaved() {
        // The sheet's costing already read these; the saved record did not,
        // so the price was right on screen and the job had 0 g and 0 h.
        for (grams, hours, g, h) in [("١٥٠", "٢٫٥", 150.0, 2.5), ("150", "1,5", 150.0, 1.5), ("150", "2.5", 150.0, 2.5)] {
            var draft = NewJobSheet.Draft()
            draft.name = "Bracket"
            draft.grams = grams
            draft.hours = hours
            #expect(draft.isComplete)
            let rows = Shop.partRows([draft], spools: [], unnamed: "Part")
            #expect(rows.count == 1)
            #expect(Self.number(rows[0], "printWeight") == g, "\(grams) g")
            #expect(Self.number(rows[0], "printTime") == h, "\(hours) h")
        }
    }

    @Test("the payment sheet closes on a written payment, and one press sends once")
    func paymentSheetClosesOnTheWrite() {
        let sheet = MenuCoverageTests.source("PaymentSheet.swift")
        #expect(sheet.contains("let wrote = await shop.recordPayment(id, amount: paid, method: how, paidAt: when)"))
        #expect(sheet.contains("if wrote { shop.clearQuestion() }"))
        #expect(!sheet.contains("if shop.moveProblem == nil { shop.clearQuestion() }"),
                "a failed email after the write left the sheet open over a recorded payment")
        #expect(sheet.contains("guard !saving else { return }"))
    }

    @Test("a sheet that stays open while it writes takes one press at a time")
    func oneSaveAtATime() {
        for name in ["SpoolSheet.swift", "ConsumableSheet.swift"] {
            let source = MenuCoverageTests.source(name)
            #expect(source.contains("guard !saving else { return }"), "\(name)")
            #expect(source.contains("saving = false"), "\(name)")
        }
    }

    @Test("New Job takes the part out of the field before it waits, so it cannot be added twice")
    func aPartIsAddedOnce() throws {
        let source = MenuCoverageTests.source("NewJobSheet.swift")
        let start = try #require(source.range(of: "private func addPart() async {"))
        let body = source[start.upperBound...]
        let taken = try #require(body.range(of: "draft = Draft()"))
        let firstAwait = try #require(body.range(of: "await "))
        #expect(taken.lowerBound < firstAwait.lowerBound)
    }

    @Test("the finished columns keep their newest cards when the cap cuts them")
    func theBoardKeepsTheNewest() {
        let board = MenuCoverageTests.source("Kanban.swift")
        #expect(board.contains("stage == .completed || stage == .shipped ? jobs.suffix(cap) : jobs.prefix(cap)"))
        #expect(board.contains("ForEach(Self.shown(jobs, in: stage))"))
    }

    // ── THE LOW ITEMS OF THE SAME REVIEW ─────────────────────────────────────

    @Test("something typed that is not a number is unreadable; empty and every number we read are not")
    func unreadableNumbers() {
        for text in ["5o", "abc", "1.2.3", "-5", "12 SAR"] { #expect(TypedNumber.unreadable(text), "\(text)") }
        for text in ["", "   ", "50", "١٥٠", "2,5", "1,250.5", " 40 "] { #expect(!TypedNumber.unreadable(text), "'\(text)'") }
    }

    /// The box showed "5o" and the job saved at the figure typed before it.
    @Test("a price box that was not read is marked, says so, and holds Save",
          arguments: ["NewJobSheet.swift", "ProductSheet.swift"])
    func aPriceNotReadHoldsTheSave(file: String) {
        let source = MenuCoverageTests.source(file)
        #expect(source.contains("private var priceNotRead: Bool { TypedNumber.unreadable(overrideText) }"))
        #expect(source.contains("if TypedNumber.unreadable(overrideText) {\n"), "the box itself is outlined")
        #expect(source.contains("shop.words.callIt(\"mac.price_not_read\")"), "and the sheet says why")
        #expect(source.contains("|| priceNotRead)"), "Save is greyed out")
        #expect(source.contains("guard !priceNotRead else { return }"), "and Return cannot save past it")
    }
}
