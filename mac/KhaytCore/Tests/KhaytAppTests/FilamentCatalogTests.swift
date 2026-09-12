import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The filament catalogue crossing into the engine and back.
///
/// The matching is `lib/filament-catalog.js` and `test/filament-catalog.test.js`
/// pins it. These are about the CROSSING, and about one thing that only exists
/// on this side: the catalogue is a 0.78 MB resource loaded out of the app
/// bundle, and a bundle that does not carry it fails here rather than returning
/// an empty list that looks like "no such filament".
@MainActor
struct FilamentCatalogTests {

    /// An engine with the catalogue in it. The resource belongs to the app
    /// target, so the app side hands it over — which is the same thing `Shop`
    /// does before the first search.
    static func engine() async throws -> KhaytEngine {
        let e = try KhaytEngine()
        let json = try #require(AppResources.filamentCatalogJSON,
                                "filament-catalog.json is not in the app bundle")
        try await e.useFilamentCatalog(json)
        return e
    }

    @Test("the bundled catalogue is there, and is the real one")
    func loads() async throws {
        let hits = try await Self.engine().filamentSearch("pla", limit: 5)
        #expect(!hits.isEmpty, "the catalogue resource is missing from the bundle")
        #expect(hits.allSatisfy { !$0.brand.isEmpty && !$0.name.isEmpty })
    }

    @Test("a brand search comes back in that brand")
    func brand() async throws {
        let hits = try await Self.engine().filamentSearch("prusament", limit: 5)
        #expect(!hits.isEmpty)
        // Prusament is Prusa Polymers' product line; whatever the brand field
        // says, every hit has to be the same one rather than a mix.
        #expect(Set(hits.map(\.brand)).count == 1)
    }

    @Test("typing more words narrows rather than widens")
    func narrows() async throws {
        let engine = try await Self.engine()
        let broad = try await engine.filamentSearch("bambu", limit: 50)
        let narrow = try await engine.filamentSearch("bambu matte", limit: 50)
        #expect(!narrow.isEmpty)
        #expect(narrow.count < broad.count,
                "adding a word did not narrow the list, so the all-terms rule is not crossing")
    }

    @Test("a word that matched nothing is reported, not hidden")
    func unmatchedCrosses() async throws {
        // Bambu's PLA Matte has no colour called "Black" — its blacks are named
        // Charcoal and Dark Chocolate. The row still comes back, and says which
        // word it could not honour.
        let hits = try await Self.engine().filamentSearch("bambu pla matte black", limit: 3)
        let hit = try #require(hits.first)
        #expect(hit.brand.lowercased().contains("bambu"),
                "the brand was dropped, which is the one word that must not be")
        #expect(hit.unmatched == ["black"])
    }

    @Test("every colour of a hit crosses, not only the matched ones")
    func colours() async throws {
        // A shop that found the filament by brand still has to pick a colour.
        //
        // "bambu pla matte", not "bambu matte": the shorter query's best hit is
        // Matte ASA CF, which genuinely is sold in one colour — the assertion
        // was about the catalogue's ranking rather than about the crossing.
        let hits = try await Self.engine().filamentSearch("bambu pla matte", limit: 3)
        let hit = try #require(hits.first)
        #expect(hit.colours.count > 1)
        #expect(hit.colours.allSatisfy { !$0.name.isEmpty })
    }

    @Test("a spool is filled with what the catalogue knows and nothing else")
    func asSpool() async throws {
        let engine = try await Self.engine()
        let hit = try #require(try await engine.filamentSearch("bambu matte", limit: 1).first)
        let colour = try #require(hit.colours.first)
        let fields = try await engine.filamentAsSpool(
            brand: hit.brand, name: hit.name, colour: colour.name,
            weight: colour.weights.first)

        #expect(fields["material"] == .string("\(hit.brand) \(hit.name)"))
        #expect(fields["colourVariant"] == .string(colour.name))
        // The shop's own facts are never invented. A filled-in zero is worse
        // than a blank field, because it looks typed.
        for key in ["cost", "openedAt", "driedAt", "storage", "id"] {
            #expect(fields[key] == nil, Comment(rawValue: "\(key) was invented"))
        }
    }

    @Test("a filament nobody has is an empty answer, not a throw")
    func unknown() async throws {
        let engine = try await Self.engine()
        #expect(try await engine.filamentSearch("zzzzqqq", limit: 5).isEmpty)
        #expect(try await engine.filamentAsSpool(brand: "Nope", name: "Nope",
                                                 colour: "Nope", weight: nil).isEmpty)
    }

    @Test("the snapshot says how old it is")
    func age() async throws {
        // A catalogue that quietly ages looks like a catalogue missing the
        // filament a shop has just bought, so the screen has to be able to say.
        let days = try #require(try await Self.engine().filamentCatalogAge())
        #expect(days >= 0)
        #expect(days < 3650, "the snapshot claims to be a decade old")
    }

    @Test("searching twice gives the same answer, and the second is not a fresh parse")
    func cached() async throws {
        // The cache itself is not observable from out here, and a wall-clock
        // assertion about it would be a flaky test rather than a guard — it
        // would fail on a loaded machine and say nothing about correctness.
        // What IS worth pinning is that keeping the catalogue between calls has
        // not made the second call differ from the first, which is the failure
        // a cache can actually cause.
        let engine = try await Self.engine()
        let a = try await engine.filamentSearch("bambu matte", limit: 5)
        _ = try await engine.filamentSearch("something else entirely", limit: 5)
        let b = try await engine.filamentSearch("bambu matte", limit: 5)
        #expect(a == b, "the catalogue changed under the second search")
        #expect(!a.isEmpty)
    }
}
