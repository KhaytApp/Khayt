import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The library's search: tokens, quoted values, Arabic, a wider default scope,
/// and the memo's narrowing kept only where it still gives the same answer.
@MainActor
struct LibraryQueryTests {

    @Test("tokens, quotes of every kind, free text left over")
    func parses() {
        let q = LibraryQuery.parse(#"dragon tag:PLA group:"Saudi Kings" category:“Wall art” bust"#)
        #expect(q.text == "dragon bust")
        #expect(q.tokens.map(\.field) == [.tag, .group, .category])
        #expect(q.tokens.map(\.value) == ["PLA", "Saudi Kings", "Wall art"])
        #expect(q.tokens[0].folded == "pla")
        #expect(q.tokens[1].source == #"group:"Saudi Kings""#)
        // An unclosed quote runs to the end: the shop is still typing it.
        #expect(LibraryQuery.parse(#"group:"Saudi K"#).tokens.first?.value == "Saudi K")
        // `tag:` alone asks for nothing and is not the word "tag".
        let bare = LibraryQuery.parse("tag:")
        #expect(bare.isEmpty)
        // A colon in something that is not a field is just text.
        #expect(LibraryQuery.parse("https://printables.com").tokens.isEmpty)
        #expect(LibraryQuery.parse("Printer:U1").tokens.first?.field == .printer, "field names fold")
    }

    @Test("Arabic field names and Arabic values")
    func arabic() {
        let q = LibraryQuery.parse("وسم:تنين مجموعة:«ملوك السعودية» فئه:تماثيل دلة")
        #expect(q.tokens.map(\.field) == [.tag, .group, .category], "ة and ه are one letter to the search")
        #expect(q.tokens[1].value == "ملوك السعودية")
        #expect(q.text == SearchText.fold("دلة"))
        // A full-width colon, as an Arabic keyboard may give.
        #expect(LibraryQuery.parse("خامة\u{FF1A}PLA").tokens.first?.field == .material)
    }

    @Test("removing a chip takes out exactly its text")
    func removing() throws {
        let raw = #"dragon  group:"Saudi Kings" tag:pla"#
        let q = LibraryQuery.parse(raw)
        let group = try #require(q.tokens.first { $0.field == .group })
        #expect(LibraryQuery.removing(group, from: raw) == "dragon tag:pla")
    }

    @Test("narrowing is allowed only when the new search is inside the old one")
    func narrows() {
        func n(_ new: String, _ old: String) -> Bool {
            LibraryQuery.parse(SearchText.fold(new)).narrows(from: LibraryQuery.parse(SearchText.fold(old)))
        }
        #expect(n("model 12", "model 1"))
        #expect(n("tag:dra", "tag:dr"))
        #expect(n("dragon tag:pla", "dragon"))
        #expect(!n("tag:d", "tag"), "typing the colon turns a word into a token")
        #expect(!n("group:x", "tag:x"))
        #expect(!n("tag:pla", "dragon"), "the free text was dropped")
    }

    static func row(_ id: String, name: String, tags: [String] = [], group: String? = nil,
                    category: String? = nil, material: String? = nil, notes: String? = nil,
                    source: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "name": .string(name),
                                      "tags": .array(tags.map { .string($0) })]
        if let group { o["group"] = .string(group) }
        if let category { o["category"] = .string(category) }
        if let material { o["material"] = .string(material) }
        if let notes { o["testedNotes"] = .string(notes) }
        if let source { o["source"] = .string(source) }
        return .object(o)
    }

    static func shop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        shop.pretendLibrary([
            row("A", name: "Falcon", tags: ["dragon"], group: "Saudi Kings/Busts", category: "Busts",
                material: "PLA", notes: "needs a brim", source: "https://www.printables.com/model/1"),
            row("B", name: "Dragon egg", tags: ["egg"], group: "Eggs", category: "Toys", material: "PETG"),
            row("C", name: "دلة", tags: ["تنين"], group: "ملوك السعودية", category: "تماثيل", material: "PLA",
                notes: "طباعة بطيئة"),
        ])
        shop.clearLibraryFilter()
        shop.shelf = .library(nil)
        shop.libraryFlat = true
        return shop
    }

    @Test("the default scope reads notes, category and group")
    func defaultScope() async {
        let shop = await Self.shop()
        func ids(_ q: String) -> [String] { shop.search = q; return shop.shownFiles.map(\.id).sorted() }
        #expect(ids("brim") == ["A"], "notes")
        #expect(ids("toys") == ["B"], "category")
        #expect(ids("saudi kings") == ["A"], "group")
        #expect(ids("بطيئه") == ["C"], "Arabic notes, folded")
        #expect(ids("dragon") == ["A", "B"], "a tag and a title, as before")
    }

    @Test("each token narrows on its own field")
    func tokensFilter() async {
        let shop = await Self.shop()
        func ids(_ q: String) -> [String] { shop.search = q; return shop.shownFiles.map(\.id).sorted() }
        #expect(ids("tag:dragon") == ["A"], "the title Dragon egg is not a tag")
        #expect(ids("material:pla") == ["A", "C"])
        #expect(ids("material:pla tag:dragon") == ["A"])
        #expect(ids(#"group:"saudi kings""#) == ["A"])
        #expect(ids("category:busts") == ["A"])
        #expect(ids("creator:printables") == ["A"])
        #expect(ids("وسم:تنين") == ["C"])
        #expect(ids("مجموعة:«ملوك السعوديه»") == ["C"])
        #expect(ids("tag:dragon falcon") == ["A"])
        #expect(ids("tag:dragon egg").isEmpty)
        // No machine says what it has loaded in this book, so Ready on finds
        // nothing, as the menu would.
        #expect(ids("printer:zz").isEmpty)
    }

    @Test("tokens typed one letter at a time narrow, and agree with a fresh search")
    func narrowingAgrees() async {
        let shop = await LibrarySpeedTests.bigShop()
        shop.libraryFlat = true
        let start = shop.libraryMemo.work
        for q in ["t", "ta", "tag", "tag:", "tag:t", "tag:ta", "tag:tag 1", "tag:tag 1 m", "tag:tag 1 model 1"] {
            shop.search = q
            LibrarySpeedTests.draw(shop)
            let fresh = shop.buildShownFiles(query: SearchText.fold(q)).map(\.id)
            #expect(shop.shownFiles.map(\.id) == fresh, "'\(q)': narrowing changed the answer")
        }
        let work = shop.libraryMemo.work
        // "t" builds; "tag:" and "tag:t" start over (a word became a token,
        // then a token got its first letter after a pass that had none).
        #expect(work.builds - start.builds <= 4, "\(work.builds - start.builds) whole-book passes")
        #expect(work.narrowed - start.narrowed >= 5)
        #expect(work.folds - start.folds <= 5_000, "a model's text was folded twice")
    }
}
