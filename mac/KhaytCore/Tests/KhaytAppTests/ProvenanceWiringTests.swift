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
        return try ShopSources.read(root.appending(path: "Sources/KhaytApp/Shop.swift"))
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
    ///
    /// Oct 2026: a record with a designer but no licence is asked too (a file
    /// whose `Standard Digital File License` once translated to nothing), so
    /// the guard is now the write, which fills each field only while blank.
    @Test("only records with no licence are considered, and only blanks are filled")
    func itOnlyFillsBlanks() throws {
        let shop = try Self.shopSource()
        #expect(shop.contains("let blank = files.filter { ($0.licence ?? \"\").isEmpty }"),
                "the candidate filter changed — a record with a licence must never be re-read")
        #expect(shop.contains("""
                if !said.source.isEmpty, (Self.plainString(record["source"]) ?? "").isEmpty {
            """), "the source is written over what a shop typed")
        #expect(shop.contains("""
                if !said.licence.isEmpty, (Self.plainString(record["licence"]) ?? "").isEmpty {
            """), "the licence is written over what a shop chose")
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
