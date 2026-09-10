import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Finishing a job records what it took, not what it was quoted at.
///
/// `order-status.gate` has always returned `needsActuals` — true for exactly
/// one move, into `completed` — and nothing in this app read it. So a job
/// finished on this Mac kept its estimate as its only figure, the margin on it
/// was the quoted margin rather than the real one, and `Quoting` had no Mac
/// path to any data at all.
@MainActor
struct CompletionActualsTests {

    static func source(_ name: String) -> String { EmptyStateTests.source(name) }

    @Test("every completion asks what the job took, not only one out of QC")
    func everyCompletionAsks() {
        let shop = Self.source("Shop.swift")
        #expect(shop.contains("if to == .completed {"),
                "only some completions ask, or none do")
        #expect(shop.contains("pendingCompletion = finishing"),
                "nothing opens the sheet")
        #expect(Self.source("ShopWindow.swift").contains("CompletionSheet(shop: shop, subject: $0)"),
                "the sheet is never put on the window")
    }

    /// One dialog for one action. Completing out of inspection already opened a
    /// sheet for QC notes, and following it with a second is a shop pressing
    /// Return twice to get past a question it did not ask for.
    @Test("a job leaving inspection is asked once, for both things")
    func qcIsAskedInTheSameSheet() {
        let sheet = Self.source("CompletionSheet.swift")
        #expect(sheet.contains("subject.leavingQC"), "the notes field is unconditional or absent")
        #expect(sheet.contains("qcNotes: leavingQC ? said : nil"),
                "notes are sent for a job that never went through QC")
    }

    /// The order matters and is not arbitrary. `order-deduction` takes this
    /// job's filament off the shelf as PART of completing it, so a move made
    /// before the actual weight landed deducts the estimate — and the shelf
    /// then disagrees with the job by exactly the amount the shop just typed.
    @Test("the actuals are written onto the job before the move is applied")
    func actualsLandBeforeTheDeduction() {
        let shop = Self.source("Shop.swift")
        guard let written = shop.range(of: "fields[\"actualWeight\"]"),
              let moved = shop.range(of: "let move = try await engine.moveJob(") else {
            Issue.record("applyMove no longer has both halves"); return
        }
        #expect(written.lowerBound < moved.lowerBound,
                "the move runs first, so the shelf is deducted against the estimate")
    }

    /// A record with actuals and no `actualsSource` reads as measured to
    /// anything that checks the source only when it is present — and the
    /// difference between a measurement and a shop's best guess is the entire
    /// reason the field exists.
    @Test("what was typed is recorded as typed")
    func provenanceTravelsWithTheFigures() {
        let shop = Self.source("Shop.swift")
        #expect(shop.contains("\"actualsSource\"] = .object("), "no provenance is written")
        #expect(shop.contains("\"time\": .string(\"manual\")"), "typed time is not marked manual")
        #expect(shop.contains("\"weight\": .string(\"manual\")"), "typed weight is not marked manual")
        // And the sheet says so, rather than letting a shop believe the figures
        // carry more weight than they do.
        #expect(Self.source("CompletionSheet.swift").contains("mac.completion_typed"))
    }

    /// The quoted weight is the sum of the parts times their quantities — the
    /// same shape `lib/order-file-link.js` allocates a finished job's real
    /// figures back through. Taking the first part's would under-quote every
    /// multi-part job on this sheet.
    @Test("what the job was quoted to weigh counts every part, and every one of each")
    func quotedGramsSumsTheParts() throws {
        // The same minimal row `CustomerTests` builds — an `Order` requires
        // more keys than this test cares about, and inventing a shorter one
        // tests the decoder rather than the sum.
        let part: (String, Int, Double) -> JSONValue = { name, qty, grams in
            .object(["id": .string(name), "name": .string(name), "material": .string("PLA"),
                     "qty": .number(Double(qty)), "printWeight": .number(grams),
                     "unitCost": .number(0), "colour": .string("#ffffff")])
        }
        let row: [String: JSONValue] = [
            "id": .string("J1"), "date": .string("2026-09-01"), "status": .string("post"),
            "project": .string("Rack"), "client": .string(""), "price": .number(0),
            "paidAmount": .number(0), "paymentStatus": .string("unpaid"),
            "printTime": .number(4), "priority": .bool(false), "notes": .string(""),
            "parts": .array([part("A", 3, 100), part("B", 1, 50)]),
        ]
        let job = try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(row))
        #expect(Shop.quotedGrams(job) == 350, "got \(Shop.quotedGrams(job)) rather than 3×100 + 1×50")
    }

    /// The fields are pre-filled by this app's own formatter, which groups
    /// thousands — so the string handed back can be `1,528`, and `Double` of
    /// that is nil. Falling through to the estimate would be survivable; the
    /// bug is that a shop's CORRECTION would be silently discarded.
    @Test("a grouped figure typed back is still a number")
    func groupedFiguresParse() {
        #expect(CompletionSheet.number("1,528") == 1528)
        #expect(CompletionSheet.number("587.5") == 587.5)
        #expect(CompletionSheet.number("") == nil)
        #expect(CompletionSheet.number("abc") == nil)
    }
}
