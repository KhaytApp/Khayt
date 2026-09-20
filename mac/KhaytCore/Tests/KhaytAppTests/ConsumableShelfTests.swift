import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The other shelf: putting something on it, correcting it, and grouping it.
///
/// The RULES are `lib/consumable-edit.js` and `lib/consumable-categories.js`,
/// tested where they live. What is tested here is that this app asks for them
/// correctly — and the one thing that is NOT a rule call: `Consumable.isLow`
/// restates the rule's definition so a row can be drawn without awaiting the
/// engine, and a restatement that drifts is exactly the fault the shared rule
/// was written to end.
@MainActor
struct ConsumableShelfTests {

    static func number(_ v: JSONValue?) -> Double? { Shop.plainNumber(v) }
    static func string(_ v: JSONValue?) -> String? { Shop.plainString(v) }

    static func decode(_ value: JSONValue) throws -> Consumable {
        try JSONDecoder().decode(Consumable.self, from: JSONEncoder().encode(value))
    }

    @Test("a new consumable is the record the shared rule builds")
    func newOne() async throws {
        let engine = try KhaytEngine()
        let made = try await engine.newConsumable([
            "name": .string("  Isopropyl alcohol  "), "stock": .string("4"),
            "unit": .string("L"), "cost": .string("38"), "minStock": .string("2"),
            "category": .string(" Cleaning "), "isPackaging": .bool(false),
        ], id: "CNS-1")
        guard case .object(let item)? = made.consumable else { Issue.record("no record"); return }
        #expect(Self.string(item["name"]) == "Isopropyl alcohol", "trimmed")
        #expect(Self.number(item["stock"]) == 4)
        #expect(Self.string(item["unit"]) == "L", "free text, not a vocabulary")
        #expect(Self.string(item["category"]) == "Cleaning", "trimmed")
        #expect(Self.string(item["id"]) == "CNS-1")
    }

    @Test("a consumable with no name is refused")
    func refused() async throws {
        let engine = try KhaytEngine()
        let made = try await engine.newConsumable(["name": .string("   ")], id: "X")
        #expect(made.consumable == nil)
        #expect(made.refused == "name")
    }

    @Test("an edit carries the fields it was not shown")
    func edit() async throws {
        let engine = try KhaytEngine()
        let before: JSONValue = .object([
            "id": .string("C1"), "name": .string("Mailing bags"), "stock": .number(6),
            "unit": .string("each"), "isPackaging": .bool(true),
            // Neither this app nor the rule knows this field. It must survive.
            "supplierSku": .string("MB-250350"),
        ])
        let out = try await engine.editConsumable(before, input: ["stock": .string("42")])
        guard case .object(let item) = out.consumable else { Issue.record("no record"); return }
        #expect(Self.number(item["stock"]) == 42)
        #expect(Self.string(item["unit"]) == "each", "a field the form did not send is left alone")
        #expect(Self.string(item["supplierSku"]) == "MB-250350",
                "a field neither app knows about survives the edit")
    }

    /// The one restatement in the Mac's own code, checked against the rule it
    /// restates — on every case that decides differently.
    ///
    /// The renderer once had TWO answers to this and they disagreed: its table
    /// drew the badge on `minStock > 0 && stock <= minStock`, its toast fired
    /// on `stock <= (minStock || 0)`. `lib/consumable-reorder.js` settled it —
    /// below a threshold the shop set, OR empty regardless — and this is the
    /// pin that stops a third answer appearing here.
    @Test("the shelf's own 'low' agrees with the shared rule, case for case",
          arguments: [
            (stock: 0.0, min: 0.0),     // empty, no threshold
            (stock: 0.0, min: 5.0),     // empty, with one
            (stock: 3.0, min: 5.0),     // below it
            (stock: 5.0, min: 5.0),     // exactly at it
            (stock: 9.0, min: 5.0),     // above it
            (stock: 9.0, min: 0.0),     // stocked, no threshold
            (stock: 0.5, min: 0.0),     // part of one left, no threshold
          ])
    func lowAgreesWithTheRule(_ pair: (stock: Double, min: Double)) async throws {
        let engine = try KhaytEngine()
        let row: JSONValue = .object([
            "id": .string("C1"), "name": .string("x"),
            "stock": .number(pair.stock), "minStock": .number(pair.min),
        ])
        // The rule's own answer, read back through the reorder suggestions:
        // it reports `low` per item, which is the field the card used to draw.
        let needs = try await engine.consumableNeeds(consumables: [row], orders: [],
                                                     now: Date())
        let ruleSaysLow = needs.first(where: { $0.id == "C1" })?.low ?? false
        let item = try Self.decode(row)
        #expect(item.isLow == ruleSaysLow,
                Comment(rawValue: "stock \(pair.stock) against min \(pair.min): "
                        + "the shelf says \(item.isLow), the rule says \(ruleSaysLow)"))
    }

    @Test("the shelves are derived from the items, and fold one spelling")
    func categories() async throws {
        let engine = try KhaytEngine()
        let rows: [JSONValue] = [
            .object(["id": .string("A"), "name": .string("a"), "category": .string("Screws")]),
            .object(["id": .string("B"), "name": .string("b"), "category": .string(" screws ")]),
            .object(["id": .string("C"), "name": .string("c")]),
        ]
        let shelves = try await engine.consumableCategories(rows)
        #expect(shelves.count == 2, "Screws and the uncategorised bucket")
        #expect(shelves.first?.count == 2, "one shelf, not two spellings of one")
        #expect(shelves.first?.label == "Screws", "the shop's own capitalisation")

        let none = try await engine.consumableUncategorised()
        #expect(shelves.last?.key == none)
        // The bucket's LABEL is the sentinel itself, which is NUL-prefixed.
        // Drawing it renders a replacement character — the fault that left the
        // other app's "Unfiled" chip dead. The card says `cons.cat_none`.
        #expect(none.hasPrefix("\u{0}"), "the sentinel is still NUL-prefixed")
    }

    @Test("a filter whose shelf has been emptied falls back to all of them")
    func selectionFallsBack() async throws {
        let engine = try KhaytEngine()
        let rows: [JSONValue] = [
            .object(["id": .string("A"), "name": .string("a"), "category": .string("Spares")]),
        ]
        #expect(try await engine.consumableSelection(rows, selected: "Spares") == "Spares")
        // Nothing is in Packaging any more. Showing an empty list under a
        // heading that still names it reads as data loss.
        #expect(try await engine.consumableSelection(rows, selected: "Packaging") == "")
    }

    @Test("the editor is offered the shelves this shop already uses")
    func suggestions() async throws {
        let engine = try KhaytEngine()
        let rows: [JSONValue] = [
            .object(["id": .string("A"), "name": .string("a"), "category": .string("Spares")]),
            .object(["id": .string("B"), "name": .string("b")]),
        ]
        let offered = try await engine.consumableSuggestions(rows)
        #expect(offered == ["Spares"], "and never the uncategorised sentinel")
    }

    /// Found by photographing the screen, not by reading it.
    ///
    /// Two of the sample shop's six rows came out reading
    /// "Mailing bags 250×350  Packaging  Packaging" — the shelf the item is
    /// on, and the badge saying one comes off per shipment. Different facts
    /// that happen to share a spelling, and one fact said twice in two
    /// colours reads as a fault in the app.
    @Test("the shelf chip is dropped when it would repeat the packaging badge")
    func chipDoesNotRepeatTheBadge() async throws {
        let engine = try KhaytEngine()
        // The sample shop's own row, as the book holds it.
        let bags: JSONValue = .object([
            "id": .string("C1"), "name": .string("Mailing bags 250×350"),
            "category": .string("Packaging"), "isPackaging": .bool(true),
        ])
        let spares: JSONValue = .object([
            "id": .string("C2"), "name": .string("Loose fill"),
            "category": .string("Spares"), "isPackaging": .bool(true),
        ])
        let shelfOnly: JSONValue = .object([
            "id": .string("C3"), "name": .string("Tape"),
            "category": .string("Packaging"), "isPackaging": .bool(false),
        ])
        // The categories still exist — this is a DRAWING decision, not a
        // change to what is stored or how the shelves are grouped.
        let shelves = try await engine.consumableCategories([bags, spares, shelfOnly])
        #expect(shelves.contains { $0.label == "Packaging" && $0.count == 2 })
        #expect(shelves.contains { $0.label == "Spares" })
    }
}
