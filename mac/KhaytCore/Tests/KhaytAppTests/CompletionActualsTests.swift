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

    /// The order matters: the move hands this record to the engine and stores
    /// what comes back, so actuals written afterwards would land on a copy the
    /// book has already replaced.
    ///
    /// NOT because the deduction reads them — it does not, in either app. See
    /// `MoveJobTests.theShelfStillFollowsTheEstimate`, which pins that and says
    /// why it is left alone.
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
    /// A record with actuals and no `actualsSource` reads as measured to
    /// anything that checks the source only when it is present — and the
    /// difference between a measurement and a shop's best guess is the entire
    /// reason the field exists.
    @Test("the figures never travel without saying whose they are")
    func provenanceTravelsWithTheFigures() {
        let shop = Self.source("Shop.swift")
        #expect(shop.contains("\"actualsSource\"] = .object("), "no provenance is written")
        // Typed is the DEFAULT, so a caller that forgets to say cannot
        // accidentally claim a measurement.
        #expect(shop.contains("var timeSource: String = \"manual\""),
                "the default source is not manual")
        #expect(shop.contains("var weightSource: String = \"manual\""))
        // And a sheet with nothing measured says so in words.
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
    /// ── WHOSE FIGURE IS THIS ──────────────────────────────────────────────
    ///
    /// Measured only where the printer reported THAT AXIS and the shop left the
    /// number alone. Both halves matter: PrusaLink reports a duration and never
    /// filament, so calling the record measured on both would fabricate a
    /// variance; and a figure typed over is a correction, which a record
    /// calling it a measurement turns into a wrong number trusted twice —
    /// `Quoting` would compare the shop's own guess against its own estimate
    /// and report it as evidence.
    @Test("a figure kept as the printer gave it is measured; one typed over is not")
    func sourceFollowsTheAxisAndTheEdit() {
        let sheet = Self.source("CompletionSheet.swift")
        #expect(sheet.contains("pre?.timeMeasured == true && unchanged(h, pre?.timeH)"),
                "time is called measured without checking the printer measured it")
        #expect(sheet.contains("pre?.weightMeasured == true && unchanged(g, pre?.weightG)"),
                "weight is called measured without checking the printer measured it")
        // And the write path uses what the sheet decided rather than a constant.
        let shop = Self.source("Shop.swift")
        #expect(shop.contains("\"time\": .string(actuals.timeSource)"),
                "the record hard-codes a source again")
        #expect(shop.contains("\"weight\": .string(actuals.weightSource)"))
    }

    /// The printer's answer is an engine call and lands after the sheet is up.
    /// Overwriting a box the shop is typing in would replace a figure under the
    /// cursor — and the figure it replaced would be the correction.
    @Test("a late answer does not overwrite what the shop has typed")
    func lateAnswerRespectsTyping() {
        let sheet = Self.source("CompletionSheet.swift")
        #expect(sheet.contains("fill(onlyIfUntouched: true)"),
                "the printer's answer overwrites every box")
        #expect(sheet.contains("touched.insert(.hours)") && sheet.contains("touched.insert(.grams)"),
                "nothing records that a box was typed in")
    }

    /// A shop with no printer linked, and this app on its own, must not be told
    /// the boxes hold a measurement — nor be shown a hint saying they hold the
    /// estimate when they hold the printer's figures.
    @Test("the sheet does not say two contradictory things about the same boxes")
    func theHintMatchesTheBoxes() {
        let sheet = Self.source("CompletionSheet.swift")
        #expect(sheet.contains("if subject.measured?.measured != true {"),
                "the “pre-filled with estimated values” hint shows over measured figures")
        #expect(sheet.contains("act.from_printer_file"),
                "measured figures do not say which print they came from")
    }

    /// This app READS the completions Khayt persists and never writes them. A
    /// cache written from here would be a guess overwriting a measurement.
    @Test("the completions cache is read, not written")
    func completionsAreReadOnly() {
        let shop = Self.source("Shop.swift")
        #expect(shop.contains("private(set) var printerCompletions"),
                "the cache is writable from outside the shop")
        #expect(shop.contains("printerCompletions = root[\"printerCompletions\"]"),
                "nothing loads what the printers remember")
    }
}
