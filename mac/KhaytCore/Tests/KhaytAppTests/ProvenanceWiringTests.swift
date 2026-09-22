import Foundation
import Testing
@testable import KhaytApp

/// The read has a caller, and the caller is where a book opens.
///
/// A rule with no caller is this repository's recurring bug — a correct module
/// nothing asks. `readProvenanceFromFiles` is exactly the shape that goes
/// wrong that way: it is complete, it is tested, and a shop would never see a
/// designer's name if nothing ran it. `RecurringOrdersTests` pins its own
/// runner to the same two lines for the same reason.
@MainActor
struct ProvenanceWiringTests {

    static func shopSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "Sources/KhaytApp/Shop.swift"),
                          encoding: .utf8)
    }

    @Test("the provenance read is wired to the book opening")
    func itIsCalled() throws {
        let shop = try Self.shopSource()
        #expect(shop.contains("            createRecurringIfDue()\n            readProvenanceIfDue()\n"), """
            `readProvenanceIfDue` is no longer called where a book finishes \
            loading, so no model will ever be asked who made it
            """)
    }

    /// It must only ever fill a blank. A shop that typed "my own design" over
    /// a remix has said something this must not undo, and a licence a person
    /// CHOSE outranks one a slicer copied into the file.
    @Test("only records with both fields blank are even considered")
    func itOnlyFillsBlanks() throws {
        let shop = try Self.shopSource()
        #expect(shop.contains("""
                ($0.source ?? "").isEmpty && ($0.licence ?? "").isEmpty
            """), """
            the candidate filter changed — if it stopped requiring BOTH fields \
            blank, this overwrites what a shop wrote about its own models
            """)
    }

    /// A book nobody has opened, and a sample with no vault behind it: neither
    /// may throw, and neither may claim to have filled anything.
    @Test("a book with no files on disk fills nothing and does not fail")
    func emptyIsQuiet() async {
        let shop = Shop()
        #expect(await shop.readProvenanceFromFiles() == 0)
        await shop.load(.sample)
        // The sample's models are records without a vault behind them.
        #expect(await shop.readProvenanceFromFiles() == 0,
                "the sample book reported filling records whose files do not exist")
    }
}
