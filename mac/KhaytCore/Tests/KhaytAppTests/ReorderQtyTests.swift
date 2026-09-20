import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// How much to order when a spool runs low, and when it was bought.
///
/// ── WHY THE QUANTITY IS NOT COSMETIC ──────────────────────────────────────
///
/// `lib/purchase-orders.js` reads `reorderQty` when it drafts an order and
/// falls back to a KILO when there is none. Nothing in this app could set it,
/// so every order it drafted asked for a kilo of whatever it was — for a shop
/// buying 250 g spools and for one buying 5 kg boxes alike.
///
/// That was harmless while drafting was a button somebody pressed and read.
/// It stopped being harmless when this app learnt to draft without being
/// asked, which is the same day.
@MainActor
struct ReorderQtyTests {

    @Test("the drafting rule orders what the spool says, and a kilo when it says nothing")
    func theRuleReadsIt() async throws {
        let engine = try KhaytEngine()
        func qtyFor(_ spool: JSONValue) async throws -> Double {
            let made = try await engine.draftOrder(item: spool, ask: [:], id: "PO-T",
                                                   today: "2026-09-20", supplierName: "")
            guard case .object(let row) = made else { return -1 }
            return Shop.plainNumber(row["qty"]) ?? -1
        }
        let bare = JSONValue.object(["id": .string("SP-1"), "material": .string("PLA")])
        #expect(try await qtyFor(bare) == 1000, "the fallback is no longer a kilo")

        var withQty = ["id": JSONValue.string("SP-2"), "material": .string("PLA")]
        withQty["reorderQty"] = .number(250)
        #expect(try await qtyFor(.object(withQty)) == 250, Comment(rawValue:
            "a shop that buys 250 g spools still has a kilo drafted for it"))
    }

    @Test("the rule stores both, and clears them when the shop empties the box")
    func theRuleKeepsThem() async throws {
        let engine = try KhaytEngine()
        let existing = JSONValue.object(["id": .string("SP-3"), "material": .string("PLA"),
                                         "weight": .number(1000)])
        let saved = try await engine.editSpool(
            existing,
            input: ["material": .string("PLA"), "reorderQty": .number(5000),
                    "purchasedAt": .string("2026-01-15")],
            settings: [:], today: "2026-09-20")
        guard case .object(let row) = try #require(saved.spool) else {
            Issue.record("not an object"); return
        }
        #expect(row["reorderQty"] == .number(5000))
        #expect(row["purchasedAt"] == .string("2026-01-15"))

        let cleared = try await engine.editSpool(
            .object(row),
            input: ["material": .string("PLA"), "reorderQty": .number(0),
                    "purchasedAt": .string("")],
            settings: [:], today: "2026-09-20")
        guard case .object(let after) = try #require(cleared.spool) else {
            Issue.record("not an object"); return
        }
        // ── A CLEARED QUANTITY IS STORED AS ZERO, NOT REMOVED ─────────────
        //
        // Unlike the temperatures, which the rule drops when they are not
        // above zero. That looked like an inconsistency worth reporting until
        // it was measured: `lib/purchase-orders.js` reads
        // `num(reorderQty) || DEFAULT`, so a stored 0 and an absent field
        // draft exactly the same kilo. The contract is what the DRAFT does,
        // not what the field looks like, so that is what is pinned.
        #expect(after["reorderQty"] == .number(0))
        #expect(after["purchasedAt"] == nil, "an emptied date left the old one behind")
    }

    @Test("a cleared quantity drafts the same as one never set")
    func zeroIsTheSameAsAbsent() async throws {
        let engine = try KhaytEngine()
        func qty(_ spool: [String: JSONValue]) async throws -> Double {
            let made = try await engine.draftOrder(item: .object(spool), ask: [:], id: "PO-T",
                                                   today: "2026-09-20", supplierName: "")
            guard case .object(let row) = made else { return -1 }
            return Shop.plainNumber(row["qty"]) ?? -1
        }
        let base: [String: JSONValue] = ["id": .string("SP-5"), "material": .string("PLA")]
        var zeroed = base
        zeroed["reorderQty"] = .number(0)
        #expect(try await qty(base) == (try await qty(zeroed)), Comment(rawValue:
            "emptying the box changed what gets drafted, so clearing it is not the "
            + "same as never having set it"))
    }

    @Test("bought and opened are different dates on purpose")
    func twoDates() throws {
        // A spool bought a year ago and opened yesterday is not the same spool
        // as one bought yesterday and opened a year ago, and filament takes up
        // moisture from the day it is made.
        let spool = try JSONDecoder().decode(Spool.self, from: JSONEncoder().encode(
            JSONValue.object(["id": .string("SP-4"), "material": .string("PLA"),
                              "purchasedAt": .string("2025-10-01"),
                              "openedAt": .string("2026-09-19")])))
        #expect(spool.purchasedAt == "2025-10-01")
        #expect(spool.openedAt == "2026-09-19")
    }

    @Test("the sheet offers both, and sends them")
    func wired() throws {
        let sheet = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/SpoolSheet.swift"), encoding: .utf8)
        #expect(sheet.contains("inv.reorder_qty"), "there is no way to say how much to order")
        #expect(sheet.contains("inv.purchased_on"), "there is no way to say when it was bought")
        #expect(sheet.contains("\"reorderQty\": .number(reorderQty)"),
                "the sheet draws the box and does not send it")
        #expect(sheet.contains("input[\"purchasedAt\"]"),
                "the date is drawn and never sent")
    }
}
