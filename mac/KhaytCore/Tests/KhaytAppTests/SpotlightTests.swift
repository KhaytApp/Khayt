import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The library in this Mac's own search.
///
/// Two halves, and the second is the one that usually breaks: describing the
/// models correctly, and OPENING the one somebody picked. A search result that
/// brings the app forward onto a grid that does not contain what was chosen is
/// worse than no result at all, and every filter the library has is a way for
/// that to happen.
@MainActor
struct SpotlightTests {

    static func file(id: String = "PF-1", name: String = "Dragon bust",
                     group: String? = nil, material: String? = nil,
                     category: String? = nil, tags: [String]? = nil,
                     original: String? = nil, filename: String? = nil,
                     printed: Int? = nil, archived: String? = nil,
                     updated: String? = nil, thumb: String? = nil) -> LibraryFile {
        var record: [String: JSONValue] = ["id": .string(id), "name": .string(name)]
        if let group { record["group"] = .string(group) }
        if let material { record["material"] = .string(material) }
        if let category { record["category"] = .string(category) }
        if let tags { record["tags"] = .array(tags.map(JSONValue.string)) }
        if let original { record["originalName"] = .string(original) }
        if let filename { record["sourceFile"] = .object(["filename": .string(filename)]) }
        if let printed { record["timesPrinted"] = .number(Double(printed)) }
        if let archived { record["archivedAt"] = .string(archived) }
        if let updated { record["updatedAt"] = .string(updated) }
        if let thumb { record["thumbFile"] = .string(thumb) }
        return try! JSONDecoder().decode(
            LibraryFile.self, from: JSONEncoder().encode(JSONValue.object(record)))
    }

    // MARK: - What a result says

    @Test("the card names the project, the material and the category, in that order")
    func cardReads() {
        let card = Spotlight.card(for: Self.file(group: "Saudi Kings", material: "PLA",
                                                 category: "Busts"),
                                  printedTimes: "printed 4×")
        #expect(card.title == "Dragon bust")
        #expect(card.subtitle == "Saudi Kings · PLA · Busts · printed 4×")
    }

    @Test("a model with nothing filed against it has no second line at all")
    func emptyCardSaysNothing() {
        // Not "Unfiled · —". A subtitle made of placeholders is a line that
        // costs a glance and returns nothing.
        #expect(Spotlight.card(for: Self.file()).subtitle == "")
    }

    @Test("the keywords carry what the subtitle has no room for")
    func keywordsCarryTheRest() {
        let card = Spotlight.card(for: Self.file(group: "Saudi Kings", material: "PLA",
                                                 category: "Busts", tags: ["gift", "resin"],
                                                 original: "king_faisal_v3.stl",
                                                 filename: "PF-1-m3x.stl"))
        #expect(card.keywords.contains("gift"))
        #expect(card.keywords.contains("resin"))
        // The name it arrived under, which is often what somebody remembers.
        #expect(card.keywords.contains("king_faisal_v3.stl"))
        #expect(card.keywords.contains("stl"), "the extension is searchable")
        #expect(card.keywords.contains("Khayt"), "so 'khayt' finds the lot")
    }

    @Test("a keyword is not repeated because two fields hold the same word")
    func keywordsAreDistinct() {
        let card = Spotlight.card(for: Self.file(group: "PLA", material: "PLA",
                                                 category: "pla", tags: ["PLA"]))
        #expect(card.keywords.filter { $0.lowercased() == "pla" }.count == 1,
                Comment(rawValue: "\(card.keywords)"))
    }

    @Test("an identifier round-trips, and one from somewhere else is refused")
    func identifiersRoundTrip() {
        #expect(Spotlight.recordId(forItem: Spotlight.itemId(for: "PF-9")) == "PF-9")
        // Spotlight hands over whatever identifier the result carried, and
        // another app's — or a malformed one — must not be read as a record id.
        #expect(Spotlight.recordId(forItem: "com.other.app.thing") == nil)
        #expect(Spotlight.recordId(forItem: "") == nil)
        #expect(Spotlight.recordId(forItem: "khayt.library.") == nil)
        // A record id containing the prefix is still recovered whole.
        #expect(Spotlight.recordId(forItem: Spotlight.itemId(for: "khayt.library.x"))
                == "khayt.library.x")
    }

    // MARK: - When it re-describes the library, and when it does not

    @Test("the signature moves for anything a card shows")
    func signatureFollowsTheCard() {
        let base = [Self.file()]
        for changed in [Self.file(name: "Dragon bust v2"), Self.file(group: "Dragons"),
                        Self.file(material: "PETG"), Self.file(category: "Busts"),
                        Self.file(tags: ["gift"]), Self.file(original: "d.stl"),
                        Self.file(printed: 3), Self.file(updated: "2026-09-01"),
                        Self.file(thumb: "thumb.png"), Self.file(id: "PF-2")] {
            #expect(Spotlight.signature(of: base) != Spotlight.signature(of: [changed]),
                    Comment(rawValue: "a change nothing noticed: \(changed.id) \(changed.title)"))
        }
    }

    @Test("the signature does not move for a field no card reads")
    func signatureIgnoresTheRest() {
        // A print finishing writes `lastPrinted`, and re-describing two hundred
        // models every time one job ends is work for no visible difference.
        var withLastPrinted: [String: JSONValue] = ["id": .string("PF-1"), "name": .string("Dragon bust")]
        withLastPrinted["lastPrinted"] = .string("2026-09-17")
        withLastPrinted["contentHash"] = .string("abc123")
        let other = try! JSONDecoder().decode(
            LibraryFile.self, from: JSONEncoder().encode(JSONValue.object(withLastPrinted)))
        #expect(Spotlight.signature(of: [Self.file()]) == Spotlight.signature(of: [other]))
    }

    @Test("two models that differ only in order are a different library")
    func signatureKeepsOrder() {
        let a = [Self.file(id: "PF-1"), Self.file(id: "PF-2")]
        #expect(Spotlight.signature(of: a) != Spotlight.signature(of: a.reversed()))
    }

    @Test("a field holding the separator cannot forge another record")
    func signatureCannotBeForged() {
        // Joined on control characters precisely so a model called "a\u{1F}b"
        // cannot make two records look like one.
        let odd = Self.file(id: "PF-1", name: "a\u{1F}b\u{1E}c")
        #expect(Spotlight.signature(of: [odd]) != Spotlight.signature(of: [Self.file(id: "PF-1")]))
    }

    // MARK: - What is indexed at all

    @Test("the sample book is never indexed")
    func sampleStaysOut() {
        // Khayt opens on invented data when a shop has none. Putting "Benchy"
        // into somebody's Mac-wide search because they looked at the demo is a
        // mess they did not ask for and could not explain.
        #expect(Spotlight.indexable(source: .sample, files: [Self.file()], wanted: true) == nil)
        #expect(Spotlight.indexable(source: .store(.shipped), files: [Self.file()],
                                    wanted: true)?.count == 1)
    }

    @Test("switched off means nothing, which is not the same as an empty list")
    func offMeansEmpty() {
        // nil is the instruction to WITHDRAW what is already indexed. Returning
        // [] instead would index nothing and leave yesterday's library in
        // Spotlight for ever — a pause dressed as an off switch.
        #expect(Spotlight.indexable(source: .store(.shipped), files: [Self.file()],
                                    wanted: false) == nil)
    }

    @Test("an archived model is left out")
    func archivedStaysOut() {
        let files = [Self.file(id: "PF-1"), Self.file(id: "PF-2", archived: "2026-08-01")]
        #expect(Spotlight.indexable(source: .store(.shipped), files: files, wanted: true)?
            .map(\.id) == ["PF-1"])
    }

    @Test("the toggle is on by default")
    func onByDefault() {
        // Read through the same accessor the app reads, so a renamed key fails
        // here rather than by silently reverting to off.
        UserDefaults.standard.removeObject(forKey: Spotlight.defaultsKey)
        #expect(Spotlight.wanted)
    }

    // MARK: - A picture

    @Test("an inline photograph is decoded, and anything else is refused")
    func dataURIs() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let uri = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        #expect(Spotlight.bytes(ofDataURI: uri) == jpeg)
        #expect(Spotlight.bytes(ofDataURI: "https://example.com/a.jpg") == nil)
        #expect(Spotlight.bytes(ofDataURI: "data:image/jpeg,notbase64") == nil)
        #expect(Spotlight.bytes(ofDataURI: "data:") == nil)
        #expect(Spotlight.bytes(ofDataURI: "") == nil)
    }
}

/// Opening the model somebody chose.
///
/// ── THE HALF THAT BREAKS ──────────────────────────────────────────────────
///
/// Every one of these starts from a library filtered so that the wanted model
/// is NOT on screen, because that is the state a person is actually in when
/// they reach for Spotlight: they were looking at one project, or had a tag
/// chip on, and went to find something else. If `reveal` only sets a selection,
/// the app comes forward showing a grid without it.
@MainActor
struct SpotlightRevealTests {

    static func loaded() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    @Test("a model in another project is shown, with the search box cleared")
    func revealCrossesProjects() async throws {
        let shop = await Self.loaded()
        let wanted = try #require(shop.files.first { !($0.groupName ?? "").isEmpty })
        // Somewhere else entirely, with a search narrowing it further.
        shop.shelf = .library("a project that does not exist")
        shop.search = "zzzz"
        #expect(shop.reveal(fileId: wanted.id))
        #expect(shop.search.isEmpty)
        #expect(shop.shelf == .library(wanted.groupName))
        #expect(shop.fileSelection == [wanted.id])
        #expect(shop.shownFiles.contains { $0.id == wanted.id },
                "revealed a model the grid does not show")
        #expect(shop.focusedFile == wanted.id, "the grid scrolls to whatever this names")
    }

    @Test("every filter that could hide it is cleared")
    func revealClearsEveryFilter() async throws {
        let shop = await Self.loaded()
        let wanted = try #require(shop.files.first)
        // One at a time would pass while the code cleared only the last one
        // written, so all of them are on at once.
        shop.libraryCategory = .some(.named("a category nothing has"))
        shop.libraryTag = "a tag nothing has"
        shop.libraryUnfiledOnly = true
        shop.search = "zzzz"
        #expect(shop.reveal(fileId: wanted.id))
        #expect(shop.shownFiles.contains { $0.id == wanted.id },
                Comment(rawValue: "a filter survived: category \(String(describing: shop.libraryCategory)), tag \(shop.libraryTag ?? "-"), unfiled \(shop.libraryUnfiledOnly)"))
    }

    @Test("a model nobody has is refused rather than half-shown")
    func revealRefusesTheUnknown() async {
        let shop = await Self.loaded()
        let before = shop.shelf
        #expect(shop.reveal(fileId: "PF-nothing") == false)
        #expect(shop.shelf == before, "the window moved for a model that is not there")
        #expect(shop.fileSelection.isEmpty)
    }

    @Test("a request that arrives before the book is open is answered when it opens")
    func revealWaitsForTheBook() async throws {
        // A Spotlight result is often what LAUNCHES the app, so the activity
        // lands while the library is still empty. Dropping it makes the very
        // first use of the feature do nothing.
        let shop = Shop()
        #expect(shop.files.isEmpty)
        shop.revealWhenLoaded(fileId: "sample-will-decide")
        await shop.load(.sample)
        let wanted = try #require(shop.files.first)
        shop.revealWhenLoaded(fileId: wanted.id)
        #expect(shop.fileSelection == [wanted.id])
    }

    @Test("a held request for a model the book turns out not to have changes nothing")
    func staleHeldRequestIsHarmless() async {
        let shop = Shop()
        shop.revealWhenLoaded(fileId: "PF-gone")
        await shop.load(.sample)
        #expect(shop.fileSelection.isEmpty)
        #expect(shop.showingLibrary == false, "the app opened somewhere nobody asked for")
    }
}
