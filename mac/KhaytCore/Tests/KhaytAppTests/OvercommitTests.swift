import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Taking a job that promises a spool more than it holds: the desktop asks
/// first and marks the spool "Over-committed"; so does the Mac, on the shared
/// sums (`KhaytReorder.overcommitWarnings`).
@MainActor
struct OvercommitTests {
    static let spools: [JSONValue] = [
        .object(["id": .string("s1"), "material": .string("PLA Black"), "weight": .number(500)]),
        .object(["id": .string("r1"), "material": .string("Resin"), "weight": .number(100), "unit": .string("ml")]),
    ]

    static func part(_ spool: String, grams: Double, qty: Double = 1) -> JSONValue {
        .object(["filamentId": .string(spool), "printWeight": .number(grams), "qty": .number(qty)])
    }

    @Test("open jobs' reservations plus the new parts, against what is on the spool")
    func theSum() throws {
        let engine = try KhaytEngine()
        let orders: [JSONValue] = [
            .object(["id": .string("o1"), "status": .string("printing"), "parts": .array([Self.part("s1", grams: 400)])]),
            .object(["id": .string("q"), "status": .string("quote"), "parts": .array([Self.part("s1", grams: 400)])]),
            .object(["id": .string("c"), "status": .string("cancelled"), "parts": .array([Self.part("s1", grams: 400)])]),
        ]
        let fits = try engine.overcommit(parts: [Self.part("s1", grams: 100)], orders: orders, spools: Self.spools)
        #expect(fits.isEmpty, "400 reserved + 100 fits 500; the quote and the cancelled job reserve nothing")
        let over = try engine.overcommit(parts: [Self.part("s1", grams: 50, qty: 3)], orders: orders, spools: Self.spools)
        #expect(over == [KhaytEngine.Overcommit(spoolId: "s1", spoolName: "PLA Black", needed: 150, available: 100)])
        let mine = try engine.overcommit(parts: [Self.part("s1", grams: 450)], orders: orders, spools: Self.spools,
                                         excludeOrderId: "o1")
        #expect(mine.isEmpty, "the job being edited does not count against itself")
    }

    @Test("an item counted in ml is not weighed against grams")
    func notGrams() throws {
        let engine = try KhaytEngine()
        #expect(try engine.overcommit(parts: [Self.part("r1", grams: 900)], orders: [], spools: Self.spools).isEmpty)
    }

    @Test("the new job's parts reach the check through the rows the job is saved with")
    func throughPartRows() throws {
        let engine = try KhaytEngine()
        let spool = try JSONDecoder().decode(Spool.self, from: JSONEncoder().encode(Self.spools[0]))
        var draft = NewJobSheet.Draft()
        draft.grams = "600"
        draft.spoolId = "s1"
        let rows = Shop.partRows([draft], spools: [spool], unnamed: "")
        let found = try engine.overcommit(parts: rows, orders: [], spools: Self.spools)
        #expect(found.map(\.spoolId) == ["s1"])
        #expect(found.first?.needed == 600)
    }

    @Test("the sentence is the desktop's, rounded to the gram")
    func sentence() {
        let s = Shop.overcommitSentence(.init(spoolId: "s1", spoolName: "PLA", needed: 299.6, available: 120.2),
                                        words: Words())
        #expect(s.contains("PLA") && s.contains("300") && s.contains("120"))
        #expect(!s.contains("{"), "every placeholder filled")
    }

    @Test("the shelf marks a spool whose open jobs want more than is on it")
    func theChip() throws {
        func runway(_ committed: Double) throws -> KhaytEngine.Runway {
            try JSONDecoder().decode(KhaytEngine.Runway.self, from: Data(
                #"{"gramsPerDay":0,"daysLeft":null,"available":0,"committedG":\#(committed),"emptyAt":null}"#.utf8))
        }
        #expect(SpoolCard.overcommitted(weight: 500, unit: "g", runway: try runway(600)))
        #expect(!SpoolCard.overcommitted(weight: 500, unit: "g", runway: try runway(500)))
        #expect(!SpoolCard.overcommitted(weight: 500, unit: "g", runway: nil))
        #expect(!SpoolCard.overcommitted(weight: 50, unit: "ml", runway: try runway(600)))
        #expect(SpoolCard.overcommitted(weight: nil, unit: nil, runway: try runway(10)))
    }
}
