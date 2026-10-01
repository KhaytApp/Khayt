import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Correcting one part of a job.
///
/// The arithmetic is `lib/calculator-cost.js` and it has its own tests. These
/// are about the WRITE: that a corrected weight re-costs rather than keeping the
/// price it had, that the seven rates go back on the record, and that the fill
/// suggestion is the library's figures rather than an invented default.
@MainActor
struct EditPartTests {

    static func shop() async -> Shop {
        let s = Shop()
        await s.load(.sample)
        return s
    }

    /// The sample job that has a part linked to a library model.
    static func jobWithLinkedPart(_ shop: Shop) -> (Order, Order.Part)? {
        for order in shop.orders {
            if let part = order.parts.first(where: { $0.printFileId != nil }) {
                return (order, part)
            }
        }
        return nil
    }

    @Test("a part's recorded hours are readable, even though the model drops them")
    func hours() async throws {
        // `Order.Part` has no printTime — nothing needed it until a part could
        // be edited. The record has always carried it, and the editor opens on
        // it, so a shop that saves without touching hours must not zero them.
        let shop = await Self.shop()
        let (job, part) = try #require(Self.jobWithLinkedPart(shop))
        let hours = try #require(await shop.partHours(job.id, partId: part.id))
        #expect(hours > 0, "the sample part records no print time, so this cannot be judged")
    }

    @Test("an unknown part and an unknown job both answer nil rather than throwing")
    func missing() async throws {
        let shop = await Self.shop()
        let (job, _) = try #require(Self.jobWithLinkedPart(shop))
        #expect(await shop.partHours(job.id, partId: "NOPE") == nil)
        #expect(await shop.partHours("NOPE", partId: "NOPE") == nil)
    }

    @Test("the fill suggestion is the library's own figures")
    func suggestion() async throws {
        let shop = await Self.shop()
        let (_, part) = try #require(Self.jobWithLinkedPart(shop))
        let fileId = try #require(part.printFileId)
        let said = try #require(await shop.partSuggestion(fileId: fileId))

        // Whatever it offers has to come from the record, not from a default:
        // a fill that quietly proposes zero is worse than no button.
        if let grams = said.printWeight { #expect(grams > 0) }
        if let hours = said.printTime { #expect(hours > 0) }
        // And where it cannot answer, it says which field it could not answer
        // for — a silent partial fill leaves zeros that look typed.
        if said.printWeight == nil { #expect(said.missing.contains("printWeight")) }
        if said.printTime == nil { #expect(said.missing.contains("printTime")) }
    }

    @Test("a part with no library link has nothing to suggest")
    func noLink() async throws {
        let shop = await Self.shop()
        #expect(await shop.partSuggestion(fileId: nil) == nil)
        #expect(await shop.partSuggestion(fileId: "PF-does-not-exist") == nil)
    }

    // MARK: - The patch, with no store in it

    static func partRecord(_ id: String, grams: Double, hours: Double,
                           cost: Double) -> JSONValue {
        .object(["id": .string(id), "name": .string("Bracket"),
                 "printWeight": .number(grams), "printTime": .number(hours),
                 "qty": .number(1), "unitCost": .number(cost),
                 "baseCost": .number(cost), "material": .string("PETG")])
    }

    static func orderRecord(_ parts: [JSONValue]) -> JSONValue {
        .object(["id": .string("ORD-1"), "parts": .array(parts)])
    }

    static func fields(_ order: JSONValue, partId: String) -> [String: JSONValue]? {
        guard case .object(let o) = order, case .array(let rows)? = o["parts"] else { return nil }
        for row in rows {
            guard case .object(let p) = row, case .string(let id)? = p["id"],
                  id == partId else { continue }
            return p
        }
        return nil
    }

    @Test("correcting the weight writes the new cost, not the old one")
    func recosts() async throws {
        // The failure this guards: a shop corrects 30 g to 300 g, the weight is
        // written and the price is not, and the job's parts no longer add up to
        // its own total.
        let shop = await Self.shop()
        let order = Self.orderRecord([Self.partRecord("P1", grams: 30, hours: 1, cost: 12)])
        let costed = try #require(await shop.costedPart(spoolId: nil, grams: 300,
                                                        hours: 1, qty: 1))

        let out = Shop.orderWithPartEdited(order, partId: "P1", name: "Bracket",
                                           spool: nil, grams: 300, hours: 1, qty: 1,
                                           costed: costed)
        let part = try #require(Self.fields(out, partId: "P1"))
        #expect(part["printWeight"] == .number(300))
        #expect(part["unitCost"] == .number(costed.cost))
        #expect(part["baseCost"] == .number(costed.cost),
                "baseCost is what the Electron editor re-costs from")
        #expect(part["unitCost"] != .number(12), "the old price was kept")
    }

    @Test("the seven rates are written back, or the price is lost on another machine")
    func ratesSurvive() async throws {
        // The Electron calculator reads all seven off the part into its form and
        // re-costs at whatever it finds. A part saved without them opens there
        // with every rate field blank and the next save costs it at nothing — so
        // a job edited here would lose its price, quietly, on somebody else's
        // machine.
        let shop = await Self.shop()
        let order = Self.orderRecord([Self.partRecord("P1", grams: 30, hours: 2, cost: 12)])
        let costed = try #require(await shop.costedPart(spoolId: nil, grams: 30,
                                                        hours: 2, qty: 1))

        let out = Shop.orderWithPartEdited(order, partId: "P1", name: "Bracket",
                                           spool: nil, grams: 30, hours: 2, qty: 1,
                                           costed: costed)
        let part = try #require(Self.fields(out, partId: "P1"))
        for rate in ["wearRate", "powerDraw", "elecRate", "prepTime",
                     "postTime", "laborRate", "failureRate"] {
            #expect(part[rate] != nil, Comment(rawValue: "\(rate) was not written back"))
        }
    }

    @Test("only the named part is touched")
    func othersUntouched() async throws {
        let shop = await Self.shop()
        let order = Self.orderRecord([
            Self.partRecord("P1", grams: 30, hours: 1, cost: 12),
            Self.partRecord("P2", grams: 90, hours: 4, cost: 44),
        ])
        let costed = await shop.costedPart(spoolId: nil, grams: 300, hours: 1, qty: 1)

        let out = Shop.orderWithPartEdited(order, partId: "P1", name: "Renamed",
                                           spool: nil, grams: 300, hours: 1, qty: 1,
                                           costed: costed)
        let other = try #require(Self.fields(out, partId: "P2"))
        #expect(other["printWeight"] == .number(90))
        #expect(other["unitCost"] == .number(44))
        #expect(other["name"] == .string("Bracket"), "the other part was renamed")
    }

    @Test("a part id that is not there changes nothing")
    func unknownPart() async throws {
        let order = Self.orderRecord([Self.partRecord("P1", grams: 30, hours: 1, cost: 12)])
        let out = Shop.orderWithPartEdited(order, partId: "NOPE", name: "x", spool: nil,
                                           grams: 999, hours: 9, qty: 9, costed: nil)
        let part = try #require(Self.fields(out, partId: "P1"))
        #expect(part["printWeight"] == .number(30))
    }

    @Test("a quantity below one is not written")
    func qtyFloor() async throws {
        // The cost model multiplies by it and a zero would price the part at
        // nothing; the stepper cannot produce one, but the patch is the thing
        // that writes the record.
        let order = Self.orderRecord([Self.partRecord("P1", grams: 30, hours: 1, cost: 12)])
        let out = Shop.orderWithPartEdited(order, partId: "P1", name: "Bracket", spool: nil,
                                           grams: 30, hours: 1, qty: 0, costed: nil)
        let part = try #require(Self.fields(out, partId: "P1"))
        #expect(part["qty"] == .number(1))
    }

    @Test("a negative weight or time is floored rather than stored")
    func negatives() async throws {
        let order = Self.orderRecord([Self.partRecord("P1", grams: 30, hours: 1, cost: 12)])
        let out = Shop.orderWithPartEdited(order, partId: "P1", name: "Bracket", spool: nil,
                                           grams: -5, hours: -2, qty: 1, costed: nil)
        let part = try #require(Self.fields(out, partId: "P1"))
        #expect(part["printWeight"] == .number(0))
        #expect(part["printTime"] == .number(0))
    }

    // MARK: - Costed at the spool it is written with

    static func spoolPart(filamentId: String, spoolCost: Double) -> [String: JSONValue] {
        ["id": .string("P1"), "name": .string("Bracket"), "printWeight": .number(30),
         "printTime": .number(1), "qty": .number(1), "filamentId": .string(filamentId),
         "material": .string("PLA"), "spoolCost": .number(spoolCost), "spoolWeight": .number(1000)]
    }

    @Test("a weight corrected on a part whose spool is on the shelf writes the price it was costed at")
    func recostWritesItsSpool() throws {
        // The cost is worked out at the shelf's price for INV-2 (60). The part
        // was bought at 50, and used to keep 50 beside a cost made from 60.
        let raw = Self.spoolPart(filamentId: "INV-2", spoolCost: 50)
        let opened = EditPartSheet.Opened(name: "Bracket", grams: "30", hours: "1", qty: 1, spoolId: "INV-2")
        var now = opened
        now.grams = "60"
        let spool = try #require(Shop.partCostSpool(now, opened: opened, raw: raw, spools: RoundTripTests.spools))
        #expect(spool.id == "INV-2")
        let out = Shop.orderWithPartEdited(Self.orderRecord([.object(raw)]), partId: "P1", now,
                                           opened: opened, spool: spool, costed: nil)
        let part = try #require(Self.fields(out, partId: "P1"))
        #expect(part["spoolCost"] == .number(60), "the part kept a price its cost was not made from")
        #expect(part["printWeight"] == .number(60))
    }

    @Test("a part whose spool is gone is costed at its own price, not the first roll of its material")
    func goneSpoolIsNotSubstituted() throws {
        // INV-9 is not on the shelf. The sheet opens the part on INV-1, the
        // first PLA, because it has to show something — and a weight corrected
        // there was costed at INV-1's 85 while the part still named INV-9.
        let raw = Self.spoolPart(filamentId: "INV-9", spoolCost: 50)
        let opened = EditPartSheet.Opened(name: "Bracket", grams: "30", hours: "1", qty: 1, spoolId: "INV-1")
        var now = opened
        now.grams = "60"
        #expect(Shop.partCostSpool(now, opened: opened, raw: raw, spools: RoundTripTests.spools) == nil)
        guard case .object(let input) = Shop.costInput(spool: nil, grams: 60, hours: 1, qty: 1, extra: raw) else {
            Issue.record("no input"); return
        }
        #expect(input["spoolCost"] == .number(50))
        #expect(input["filamentId"] == .string("INV-9"))
        let out = Shop.orderWithPartEdited(Self.orderRecord([.object(raw)]), partId: "P1", now,
                                           opened: opened, spool: nil, costed: nil)
        let part = try #require(Self.fields(out, partId: "P1"))
        #expect(part["filamentId"] == .string("INV-9"))
        #expect(part["spoolCost"] == .number(50))
        // Choosing a roll on purpose still moves the part onto it.
        var moved = now
        moved.spoolId = "INV-2"
        #expect(Shop.partCostSpool(moved, opened: opened, raw: raw, spools: RoundTripTests.spools)?.id == "INV-2")
    }

    @Test("the sheet's preview is costed at the part's own rates, as Save is")
    func previewMatchesSave() async throws {
        let shop = await Self.shop()
        var raw = Self.spoolPart(filamentId: "INV-GONE", spoolCost: 20)
        raw["laborRate"] = .number(500)
        raw["prepTime"] = .number(1)
        let opened = EditPartSheet.Opened(name: "Bracket", grams: "30", hours: "1", qty: 1, spoolId: nil)
        var now = opened
        now.grams = "60"
        let preview = try #require(await shop.partEditCost(raw: raw, now, opened: opened).costed)
        let defaults = try #require(await shop.costedPart(spoolId: nil, grams: 60, hours: 1, qty: 1))
        #expect(preview.rates.laborRate == 500, "the preview ignored the part's own labour rate")
        #expect(preview.cost != defaults.cost)
        // And both the sheet and the save go through that one call.
        let sheet = EmptyStateTests.source("EditPartSheet.swift")
        #expect(sheet.contains("preview = await shop.partEditCost(raw: shop.rawPart(orderId, partId: part.id)"),
                "the preview no longer costs the way Save does")
        #expect(EmptyStateTests.source("Shop.swift").contains(
            "? await partEditCost(raw: rawPart(orderId, partId: partId), now, opened: opened)"))
    }

    @Test("a sample book refuses the edit rather than half-applying it")
    func sampleIsReadOnly() async throws {
        // `canMoveJobs` is false on the sample. The sheet disables its save
        // button, but the write path must refuse too — a disabled button is a
        // UI fact, not a guarantee.
        let shop = await Self.shop()
        #expect(!shop.canMoveJobs, "the sample book is supposed to be read-only")
        let (job, part) = try #require(Self.jobWithLinkedPart(shop))
        let before = part.printWeight

        await shop.editPart(job.id, partId: part.id,
                            .init(name: part.name, grams: String(before * 5), hours: "1",
                                  qty: part.qty, spoolId: nil),
                            opened: nil)

        let after = try #require(shop.orders.first { $0.id == job.id }?
            .parts.first { $0.id == part.id })
        #expect(after.printWeight == before, "the sample book was written to")
    }
}
