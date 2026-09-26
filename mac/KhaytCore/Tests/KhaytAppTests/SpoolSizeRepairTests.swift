import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A part is costed on its spool's SIZE, and products costed on the grams
/// left are repaired once, on open.
@MainActor
struct SpoolSizeRepairTests {

    @Test("a part carrying the grams left is given the spool's size; one already right is left")
    func fixesOnlyWhatIsWrong() throws {
        let parts: [JSONValue] = [
            .object(["filamentId": .string("S1"), "spoolWeight": .number(859)]),
            .object(["filamentId": .string("S2"), "spoolWeight": .number(750)]),
            .object(["printWeight": .number(10)]),
        ]
        let fixed = try #require(Shop.spoolSizesFixed(parts, sizes: ["S1": 1000, "S2": 750]))
        guard case .object(let a) = fixed[0], case .object(let b) = fixed[1] else { Issue.record("shape"); return }
        #expect(a["spoolWeight"] == .number(1000))
        #expect(b["spoolWeight"] == .number(750))
        #expect(fixed[2] == parts[2])
        #expect(Shop.spoolSizesFixed(fixed, sizes: ["S1": 1000, "S2": 750]) == nil, "not idempotent")
    }

    @Test("every place a part takes a spool uses its size, and the repair runs when a book opens")
    func wired() throws {
        let shop = try QuoteSheetStatusTests.source("Shop.swift")
        let sheet = try QuoteSheetStatusTests.source("ProductSheet.swift")
        #expect(!shop.contains("spool.weight ?? 1000"))
        #expect(!sheet.contains("spool.weight ?? 1000"))
        #expect(shop.contains("await repairSpoolSizes()"))
    }
}
