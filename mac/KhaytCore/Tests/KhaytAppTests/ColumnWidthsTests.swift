import Foundation
import SwiftUI
import Testing
@testable import KhaytApp

/// Arabic Jobs without its Owed column (alpha.51 review): widths restored from
/// the last launch kept the row wider than its slot. `ColumnWidths` drops them
/// and keeps what the shop chose.
@MainActor
struct ColumnWidthsTests {
    struct Row: Identifiable { let id: Int }

    /// The encoding a real table wrote, captured from a probe: `client` hidden
    /// by the shop, every other column with a width from a wider window.
    static let stored = #"""
    {"perColumnState":[{"base":{"explicit":{"_0":"client"}}},{"visibility":{"hidden":{}}},{"base":{"explicit":{"_0":"owed"}}},{"currentWidth":193,"visibility":{"automatic":{}}},{"base":{"explicit":{"_0":"job"}}},{"currentWidth":353,"visibility":{"automatic":{}}}]}
    """#

    @Test("restored widths are dropped, and a hidden column stays hidden")
    func widthsGoChoicesStay() throws {
        var c = try JSONDecoder().decode(TableColumnCustomization<Row>.self, from: Data(Self.stored.utf8))
        #expect(String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("currentWidth"),
                "the fixture no longer carries a width, so this proves nothing")
        ColumnWidths.forget(&c)
        let after = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        #expect(!after.contains("currentWidth"), Comment(rawValue: after))
        #expect(c[visibility: "client"] == .hidden, "the shop's hidden column came back")
    }

    /// A `Table` never shrinks a column below its IDEAL (measured in the app:
    /// 1,023pt of ideals in an 887pt slot beside the panel, Owed under the
    /// panel). So the ideals of all six Jobs columns, plus the spacing between
    /// them, have to fit the narrowest ordinary slot: a 1,320pt window less the
    /// sidebar and the detail panel.
    @Test("the jobs columns' ideal widths fit beside the detail panel")
    func idealsFit() throws {
        let source = try QuoteSheetStatusTests.source("OrdersTable.swift")
        let pattern = /\.width\(min: (\d+), ideal: (\d+)\)/
        let ideals = source.matches(of: pattern).compactMap { Int($0.output.2) }
        #expect(ideals.count == 6, "expected six Jobs columns, found \(ideals.count)")
        let spacing = 17 * ideals.count
        #expect(ideals.reduce(0, +) + spacing <= 860,
                Comment(rawValue: "ideals \(ideals) come to \(ideals.reduce(0, +) + spacing)pt"))
    }

    @Test("the jobs table is not built until the widths are gone")
    func tableWaitsForFreshWidths() throws {
        let source = try QuoteSheetStatusTests.source("OrdersTable.swift")
        #expect(source.contains("ColumnWidths.forget(&columns)"))
        #expect(source.contains("if widthsFresh {"))
    }
}
