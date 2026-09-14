import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Saying what a model IS, and tagging it, from this Mac.
///
/// Both axes could be FILTERED on and neither could be SET, so on a real book —
/// a hundred and fifty-two models, no categories, no tags — the chips that
/// answer "show me the wall art" could only ever have been empty, and the one
/// way to fill them was the other app. `OrganiseParityTests` holds the group
/// axis to `lib/organise.js`; this holds the other two to it and to
/// `lib/tags.js`.
@MainActor
struct FilingModelsTests {

    // MARK: what a thing IS

    @Test("a category matching one in use adopts its spelling")
    func categoryAdoptsTheSpellingInUse() async throws {
        let engine = try KhaytEngine()
        let patch = try await engine.fileUnderCategory("wall art", known: ["Wall art", "Dental"])
        #expect(patch["category"] == .string("Wall art"), """
            typing an existing category in a different case made a second one, \
            which is two chips each holding part of one idea
            """)
    }

    @Test("a new category is kept exactly as typed, with its spacing tidied")
    func aNewCategoryIsKept() async throws {
        let engine = try KhaytEngine()
        let patch = try await engine.fileUnderCategory("  Functional   Parts ",
                                                      known: ["Wall art"])
        #expect(patch["category"] == .string("Functional Parts"),
                "whitespace is collapsed, the name is not")
    }

    @Test("clearing a category writes the field empty, not absent")
    func clearingACategory() async throws {
        let engine = try KhaytEngine()
        let patch = try await engine.fileUnderCategory("", known: ["Wall art"])
        #expect(patch["category"] == .string(""), """
            leaving the field out would let a sync merge bring the old name \
            back, which is the reason the group axis writes both of its fields
            """)
    }

    @Test("filing a category does not touch the group")
    func categoryLeavesTheGroupAlone() async throws {
        // `assign` writes group AND folder for a group; a category is one field.
        // Writing a stray `group: ""` here would empty a model out of its
        // project as a side effect of saying what it is.
        let engine = try KhaytEngine()
        let patch = try await engine.fileUnderCategory("Wall art", known: [])
        #expect(patch["group"] == nil && patch["folder"] == nil,
                "saying what a model is moved it out of its project")
    }

    // MARK: tags

    @Test("a tag matching one in use adopts its spelling, and repeats count once")
    func tagsAreReconciled() async throws {
        let engine = try KhaytEngine()
        let tags = try await engine.normaliseTags("Resin, resin ,  portrait",
                                                  known: ["resin", "relief"])
        #expect(tags == ["resin", "portrait"], """
            got \(tags) — "Resin" and "resin" are one tag and it keeps the \
            spelling the shop already uses
            """)
    }

    @Test("an empty line clears the tags rather than writing an empty one")
    func clearingTags() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.normaliseTags("", known: ["resin"]).isEmpty)
        #expect(try await engine.normaliseTags(" , ,, ", known: ["resin"]).isEmpty)
    }

    // MARK: what the menu offers

    @Test("the menu offers the names the whole book uses, not the filtered ones")
    func namesComeFromTheWholeBook() async throws {
        // Offered before typing, and that order is the point. A shop standing
        // inside one project and offered only that project's categories would
        // type a name the book already holds elsewhere — and the folding rule
        // can only fold against the names it is given.
        let shop = Shop()
        await shop.load(.sample)

        shop.shelf = .library(nil)
        await shop.settleLibraryFacets()
        let everywhere = shop.categoriesInUse
        #expect(everywhere.count > 1, "the sample book has too few categories to tell")

        shop.shelf = .library("Saudi Kings")
        await shop.settleLibraryFacets()
        #expect(shop.libraryFacets.categories.count == 1, "the CHIPS follow the shelf")
        #expect(shop.categoriesInUse == everywhere, """
            the menu narrowed with the shelf, so filing a model inside a project \
            cannot adopt a spelling the rest of the book already uses
            """)
        #expect(!shop.tagsInUse.isEmpty, "no tags are offered, so the box has nothing to reconcile against")
    }

    @Test("the tag box starts with what everything selected already shares")
    func tagBoxStartsFromTheCommonTags() async throws {
        // Not the first model's tags. Tagging several at once REPLACES what each
        // carried, so starting from one of them and writing to all of them would
        // quietly hand the rest a set they never had.
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .library(nil)

        let kings = shop.files.filter { $0.groupName == "Saudi Kings" }
        #expect(kings.count > 1)
        shop.fileSelection = Set(kings.map(\.id))
        #expect(Set(shop.tagsOnSelection.map { $0.lowercased() }) == ["relief", "portrait"])

        // Add one that shares nothing, and what they have in common is nothing.
        let other = try #require(shop.files.first { ($0.tags ?? []).contains("vase mode") })
        shop.fileSelection.insert(other.id)
        #expect(shop.tagsOnSelection.isEmpty, """
            a tag only some of them carried was offered as the starting point, \
            so confirming the box would have written it onto the rest
            """)
    }

    @Test("nothing selected means nothing is offered")
    func nothingSelected() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.fileSelection = []
        #expect(shop.tagsOnSelection.isEmpty)
    }
}
