import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A purchase order's quantity, and a spool's history, in the shelf's words.
///
/// An order copies its unit from the item it restocks, so `Quantity.ordered`
/// saw "g", "ml" and "sheet" and wrote them raw: "1000 g" with an English
/// letter in the Arabic app, "12.35 g" in a spool's history beside a shelf that
/// said "12 غ" (alpha.79 review).
@MainActor
@Suite struct OrderedQuantityTests {

    static func words(_ language: String) async -> Words {
        // With the engine: `common.grams` is Khayt's, not this app's, and
        // without it the gram comes back as its key.
        let w = Words()
        await w.load(language, engine: try? KhaytEngine())
        return w
    }

    @Test("a shelf unit on an order is said in the shelf's words, in both languages")
    func shelfUnitsAreTheShelfs() async {
        let ar = await Self.words("ar")
        #expect(Quantity.ordered(1000, unit: "g", words: ar) == Quantity.say(1000, nil, ar))
        #expect(Quantity.ordered(12.35, unit: "g", words: ar) == Quantity.say(12.35, nil, ar))
        #expect(!Quantity.ordered(1000, unit: "g", words: ar).contains("g"))
        #expect(Quantity.ordered(2.5, unit: "sheet", words: ar).hasSuffix(ar.callIt("unit.sheet")))
        #expect(Quantity.ordered(500, unit: "ml", words: ar).hasSuffix(ar.callIt("unit.ml")))

        let en = await Self.words("en")
        #expect(Quantity.ordered(2.5, unit: "sheet", words: en) == "2.5 sheets")
        #expect(Quantity.ordered(3, unit: "sheet", words: en) == "3 sheets")
        #expect(Quantity.ordered(1250, unit: "", words: en) == "1,250 g")
    }

    @Test("a unit the shop typed is written back as typed")
    func typedUnitsStay() async {
        let en = await Self.words("en")
        #expect(Quantity.ordered(4, unit: "roll", words: en) == "4 roll")
        #expect(Quantity.ordered(1.25, unit: "pcs", words: en) == "1.25 pcs")
    }

    @Test("the shelf decimals copied here are the shared module's")
    func shelfPlacesMatchTheModule() async throws {
        let engine = try KhaytEngine()
        let choices = try await engine.inventoryUnitChoices()
        let module = Dictionary(uniqueKeysWithValues: choices.map { ($0.unit, $0.decimals) })
        var others = module
        others["g"] = nil
        #expect(others == Quantity.shelfPlaces,
                "lib/inventory-units.js and Quantity.shelfPlaces disagree — copy the module's decimals")
        #expect(module["g"] == 0, "say(_, nil, _) writes whole grams")
    }

    @Test("a spool's history says its figures the way the shelf does")
    func historyUsesTheShelf() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/KhaytApp/SpoolHistorySheet.swift"), encoding: .utf8)
        #expect(!src.contains("Quantity.ordered("),
                "a spool is not an order — say its figures with Quantity.say and the shelf's unit")
    }

    @Test("no unit letter is written raw on screen")
    func noRawUnitLetters() throws {
        // "19.9 h" in the Arabic job inspector, and the capacity card's booked hours:
        // a letter typed into Swift is English in both languages. `mac.unit_h`
        // and `common.grams` are where Khayt keeps them.
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/KhaytApp")
        let raw = try NSRegularExpression(pattern: #"%\.?\d*f (h|g|ml|kg)"|\+ " (h|g|ml|kg)"(?!\w)"#)
        var found: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path)
        where name.hasSuffix(".swift") && name != "ImportCommand.swift" {
            let src = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for (i, line) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = String(line)
                if raw.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil {
                    found.append("\(name):\(i + 1)")
                }
            }
        }
        #expect(found.isEmpty, "a unit written as an English letter: \(found)")
    }
}
