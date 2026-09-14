import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Narrowing a library of hundreds, and a catalogue of twenty.
///
/// Three things are checked here and they are deliberately not one test:
///
///  1. the COUNTS come from the shared rule and fold the shop's own spellings;
///  2. every axis counts what the OTHER axes leave, which is the bug the other
///     app shipped — *"with a category on, a group chip said 7 and pressing it
///     showed 2"*;
///  3. the chips are WIRED — pressing one narrows the thing the screen draws.
///
/// The third is the one this app keeps getting wrong: a rule with tests and no
/// caller. So the wiring is proven by reading `shownEntries` and `shownProducts`
/// — what the grid and the table actually draw — rather than the filter state
/// that feeds them.
@MainActor
struct LibraryFilterTests {

    // MARK: the counts come from the shared rule

    @Test("a category typed two ways is one chip holding all of them")
    func categoriesFold() async throws {
        let engine = try KhaytEngine()
        let rows: [JSONValue] = [
            .object(["category": .string("Wall art")]),
            .object(["category": .string("wall art")]),
            .object(["category": .string("  Wall   art ")]),
            .object(["category": .string("Dental")]),
            .object([:]),
        ]
        let counts = try await engine.categoryCounts(rows)
        #expect(counts.first?.name == "Wall art", "the most-used spelling is the one shown")
        #expect(counts.first?.count == 3, "a differently-typed spelling is the same category")
        #expect(counts.count == 2, "the record in no category is not a category")
    }

    @Test("a tag typed two ways is one chip, and a record naming it twice counts once")
    func tagsFold() async throws {
        let engine = try KhaytEngine()
        let rows: [JSONValue] = [
            .object(["tags": .array([.string("Resin"), .string("resin")])]),
            .object(["tags": .array([.string(" resin ")])]),
            .object(["tags": .array([.string("portrait")])]),
            .object(["tags": .array([])]),
        ]
        let counts = try await engine.tagCounts(rows)
        let resin = try #require(counts.first { $0.name.lowercased() == "resin" })
        #expect(resin.count == 2, """
            a record carrying one tag under two spellings was counted twice, so \
            the chip promises more files than it can find
            """)
        #expect(counts.count == 2)
    }

    // MARK: the library's chips

    @Test("the sample library's chips are counted from the shared rule")
    func sampleFacets() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .library(nil)
        await shop.settleLibraryFacets()

        let categories = shop.libraryFacets.categories
        #expect(!categories.isEmpty, """
            the sample library has no categories, so the category chips are a \
            row nobody has ever seen drawn
            """)
        let wall = try #require(categories.first { $0.name.lowercased() == "wall art" })
        #expect(wall.count == 7, """
            the seven kings are one category typed two ways; counting them as \
            two is the drift lib/organise.js exists to fold
            """)
        #expect(!shop.libraryFacets.tags.isEmpty, "the sample library has no tags")
        #expect(shop.libraryFacets.unfiled > 0, """
            no sample model is unfiled, so the chip that answers "what have I \
            not filed yet" never draws
            """)
    }

    @Test("inside a project the chips count that project, not the book")
    func facetsFollowTheShelf() async throws {
        let shop = Shop()
        await shop.load(.sample)

        shop.shelf = .library(nil)
        await shop.settleLibraryFacets()
        let everywhere = shop.libraryFacets.categories.count
        #expect(shop.libraryFacets.unfiled > 0)

        shop.shelf = .library("Saudi Kings")
        await shop.settleLibraryFacets()
        let inside = shop.libraryFacets
        #expect(inside.categories.count == 1, """
            a folder holding one category offered \(inside.categories.count) \
            chips, so at least one of them finds nothing inside the folder it \
            sits above
            """)
        #expect(inside.categories.first?.count == 7)
        #expect(everywhere > inside.categories.count, """
            the whole library and one project offered the same chips, so the \
            bar is reading the book rather than the shelf
            """)
        #expect(inside.unfiled == 0, """
            a folder offered an "unfiled" chip; nothing inside a folder is \
            unfiled, so that chip could only find zero
            """)
    }

    @Test("a chip counts what the other chips leave")
    func axesCountEachOthersLeavings() async throws {
        // The bug the other app shipped and wrote down: "with a category on, a
        // group chip said 7 and pressing it showed 2." A chip is pressed on the
        // strength of its number, so a number describing a different population
        // from the grid under it is the one thing a filter must not do.
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .library(nil)
        await shop.settleLibraryFacets()

        let dental = try #require(shop.libraryFacets.categories
            .first { $0.name.lowercased() == "dental" })
        shop.libraryCategory = .named(dental.name)
        await shop.settleLibraryFacets()

        for tag in shop.libraryFacets.tags {
            shop.libraryTag = tag.name
            #expect(shop.shownFiles.count == tag.count, """
                the "\(tag.name)" chip promised \(tag.count) models with a \
                category already on, and pressing it drew \(shop.shownFiles.count)
                """)
            shop.libraryTag = nil
        }

        // And the axis a chip is ON is NOT narrowed by itself, or a shop could
        // never press a second value on it.
        #expect(shop.libraryFacets.categories.count > 1, """
            with one category chosen the row offered only that category, so \
            choosing a different one is impossible without clearing first
            """)
    }

    @Test("a chip still switched on stays on the row at zero")
    func activeChipSurvivesAnEmptyCount() async throws {
        // Otherwise it vanishes while still narrowing the screen, and the shop
        // is left looking at an empty grid with nothing on it to explain why.
        let rows = LibraryFilterBar.withActive([], Shop.FilterChoice.named("Wall art"))
        #expect(rows.count == 1)
        #expect(rows.first?.count == 0, "the chip must say the truth, which is none")
        #expect(LibraryFilterBar.withActive([], nil).isEmpty,
                "nothing is on, so nothing is added")
    }

    // MARK: and pressing one narrows the grid

    @Test("pressing a category chip narrows what the grid draws")
    func categoryNarrowsTheGrid() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .library(nil)

        let all = shop.shownFiles.count
        shop.libraryCategory = .named("Wall art")
        #expect(shop.shownFiles.count == 7, """
            filtering by a category matched \(shop.shownFiles.count) of \(all); \
            the chip's own count says seven
            """)
        // Typed the other way round, because the chip carries the most-used
        // spelling and the records carry both.
        shop.libraryCategory = .named("wall art")
        #expect(shop.shownFiles.count == 7, "the filter is case-sensitive and the data is not")
        shop.clearLibraryFilter()
        #expect(shop.shownFiles.count == all)
    }

    @Test("pressing a tag chip narrows what the grid draws")
    func tagNarrowsTheGrid() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .library(nil)
        await shop.settleLibraryFacets()

        let tag = try #require(shop.libraryFacets.tags.first)
        shop.libraryTag = tag.name
        #expect(shop.shownFiles.count == tag.count, """
            the chip promised \(tag.count) models and the grid drew \
            \(shop.shownFiles.count)
            """)
    }

    @Test("unfiled finds exactly the models in no project")
    func unfiledFindsTheLooseOnes() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .library(nil)

        let loose = shop.files.count { ($0.groupName ?? "").isEmpty }
        #expect(loose > 0, "every sample model is filed, so this chip never draws")
        shop.libraryUnfiledOnly = true
        #expect(shop.shownFiles.count == loose)
        #expect(shop.shownEntries.allSatisfy { entry in
            if case .folder = entry { return false }
            return true
        }, "a folder was drawn while showing only the models in no folder")
    }

    @Test("two chips narrow together")
    func axesCompose() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .library("Saudi Kings")

        shop.libraryCategory = .named("Wall art")
        shop.libraryTag = "portrait"
        #expect(shop.shownFiles.count == 7, """
            "the portrait wall art in the Saudi Kings" is the question a library \
            of hundreds is actually asked, and it found \(shop.shownFiles.count)
            """)
        shop.libraryTag = "vase mode"
        #expect(shop.shownFiles.isEmpty, "the axes are OR-ed, so neither of them narrows")
    }

    @Test("a book nobody has opened offers no chips")
    func emptyLibraryDrawsNothing() async throws {
        let shop = Shop()
        #expect(shop.libraryFacets.isEmpty, """
            a book that has not been opened offered chips, so the bar is \
            furniture on the screen a new shop sees first
            """)
        #expect(shop.catalogueFacets.isEmpty)
    }

    @Test("the chips settle on what the shop last asked for")
    func recountsSettleOnTheLastAsk() async throws {
        // One recount is started per keystroke and each hops into JavaScript
        // twice, so they can finish in any order. The chips must describe the
        // search the shop has finished typing, not one it typed through.
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .library(nil)
        await shop.settleLibraryFacets()
        let whole = shop.libraryFacets

        // Typed, then cleared, with no waiting in between — which is what
        // typing is.
        shop.search = "wall"
        shop.search = "wall art"
        shop.search = ""
        await shop.settleLibraryFacets()

        #expect(shop.libraryFacets == whole, """
            a recount started earlier wrote after a later one finished, so the \
            chips describe a search that is no longer in the box
            """)
    }

    // MARK: the catalogue asks the same question in its own words

    @Test("the catalogue's chips are its materials, its categories and its unpriced")
    func catalogueFacets() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .catalogue
        await shop.settleCatalogueFacets()

        #expect(!shop.catalogueFacets.materials.isEmpty, """
            the sample catalogue offers no materials, so "everything in resin" \
            — the question the search box was being used for — has no chip
            """)
        let total = shop.catalogueFacets.materials.reduce(0) { $0 + $1.count }
        #expect(total <= shop.catalogueRows.count,
                "the material chips promise more products than the catalogue holds")
    }

    @Test("pressing a material chip narrows the catalogue")
    func materialNarrowsTheCatalogue() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .catalogue
        await shop.settleCatalogueFacets()

        let material = try #require(shop.catalogueFacets.materials.first)
        shop.catalogueMaterial = .named(material.name)
        #expect(shop.shownProducts.count == material.count, """
            the "\(material.name)" chip promised \(material.count) products and \
            the table drew \(shop.shownProducts.count)
            """)
        shop.clearCatalogueFilter()
        #expect(shop.shownProducts.count == shop.catalogueRows.count)
    }

    @Test("the unpriced chip finds products a shop cannot sell")
    func unpricedFindsWhatCannotBeSold() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .catalogue
        await shop.settleCatalogueFacets()

        let unpriced = shop.catalogueFacets.unpriced
        #expect(unpriced > 0, """
            no sample product is unpriced, so the one chip on this screen worth             interrupting a shop for is never drawn
            """)
        shop.catalogueUnpricedOnly = true
        #expect(shop.shownProducts.count == unpriced)
        #expect(shop.shownProducts.allSatisfy { $0.final <= 0 },
                "a product with a price was drawn under the chip for ones without")
    }

    @Test("a product priced at nothing on purpose is not called unpriced")
    func aGiveawayIsAnAnswer() async throws {
        // `lib/product-price.js`: a typed zero is "a giveaway, a sample, a part
        // priced inside a bundle", and it refuses to re-price those. Sweeping
        // them into this chip would tell a shop its deliberate freebies are
        // things it forgot to do.
        let shop = Shop()
        await shop.load(.sample)
        let free = try #require(shop.catalogueRows.first { $0.source == "override" && $0.final <= 0 },
                                "no sample product is deliberately free, so this case never draws")
        #expect(!Shop.isUnpriced(free))

        shop.shelf = .catalogue
        shop.catalogueUnpricedOnly = true
        #expect(!shop.shownProducts.contains(free),
                "a giveaway was listed among the products nobody has priced")
    }
}
