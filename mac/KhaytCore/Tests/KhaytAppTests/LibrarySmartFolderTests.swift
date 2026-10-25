import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Stage 2a of the library redesign: one query model (`LibraryQuery`) shared
/// by the filter bar, the saved searches and the facet counts; the ranges;
/// the built-in smart folders; and the saved-search write path.
@MainActor
struct LibrarySmartFolderTests {

    // MARK: - The query value

    static func full() -> LibraryQuery {
        var q = LibraryQuery()
        q.text = #"dragon tag:"wall art""#
        q.printNext = true; q.duplicates = true; q.unfiled = true; q.neverPrinted = true
        q.archived = true; q.storage = .onlineOnly; q.noFigures = true; q.inCatalogue = true
        q.readyOn = "M-1"; q.readyAnywhere = true; q.creator = "Printables"; q.category = "Busts"
        q.uncategorised = true; q.tag = "relief"; q.sort = "printTime"
        q.ranges.minutes = .init(min: 30, max: 240)
        q.ranges.grams = .init(max: 500)
        q.ranges.price = .init(min: 10)
        q.ranges.timesPrinted = .init(min: 0, max: 0)
        q.ranges.added = .init(from: "2026-01-01", to: "2026-06-30")
        return q
    }

    @Test("a query goes into the book and comes back the same, through JSON and through Codable")
    func roundTrip() throws {
        let q = Self.full()
        #expect(LibraryQuery(json: q.json) == q)
        let data = try JSONEncoder().encode(q)
        #expect(try JSONDecoder().decode(LibraryQuery.self, from: data) == q)
        // Only what is set is written.
        #expect(LibraryQuery().json == .object([:]))
        var lastDays = LibraryQuery()
        lastDays.ranges.added = .init(lastDays: 30)
        #expect(LibraryQuery(json: lastDays.json) == lastDays)
    }

    @Test("a query from another build reads leniently: unknown fields ignored, wrong types off")
    func lenient() {
        let odd: JSONValue = .object([
            "printNext": .string("yes"), "unfiled": .bool(true), "storage": .string("onTheMoon"),
            "tag": .string("  "), "futureAxis": .bool(true),
            "ranges": .object(["grams": .object(["min": .string("5"), "max": .number(90)]),
                               "added": .object(["lastDays": .number(-3), "from": .string("2026-02-03T10:00:00Z")])]),
        ])
        let q = LibraryQuery(json: odd)
        #expect(q != nil)
        #expect(q?.printNext == false)
        #expect(q?.unfiled == true)
        #expect(q?.storage == nil)
        #expect(q?.tag == nil)
        #expect(q?.ranges.grams == .init(min: nil, max: 90))
        #expect(q?.ranges.added == .init(from: "2026-02-03"))
        #expect(LibraryQuery(json: .array([])) == nil)
    }

    @Test("an unknown figure never matches a range; open ends and reversed bounds behave")
    func rangesWithUnknowns() {
        let b = LibraryQuery.Bound(min: 60, max: 120)
        #expect(b.contains(60) && b.contains(120) && b.contains(90))
        #expect(!b.contains(59) && !b.contains(121))
        #expect(!b.contains(nil), "unknown is never inside a range")
        #expect(!b.contains(.nan))
        #expect(LibraryQuery.Bound().contains(nil), "no range at all asks nothing")
        #expect(LibraryQuery.Bound(min: 120, max: 60).contains(90), "typed the wrong way round")
        #expect(LibraryQuery.Bound(max: 10).contains(0))

        let d = LibraryQuery.Days(from: "2026-03-01", to: "2026-03-31")
        #expect(d.contains("2026-03-01", today: "2026-10-24"))
        #expect(d.contains("2026-03-31", today: "2026-10-24"))
        #expect(!d.contains("2026-04-01", today: "2026-10-24"))
        #expect(!d.contains(nil, today: "2026-10-24"))
        let last = LibraryQuery.Days(lastDays: 7)
        #expect(last.contains("2026-10-18", today: "2026-10-24"))
        #expect(!last.contains("2026-10-17", today: "2026-10-24"))

        var r = LibraryQuery.Ranges()
        r.minutes = .init(max: 180)
        #expect(r.matches(.init(minutes: 120), today: "2026-10-24"))
        #expect(!r.matches(.init(minutes: nil, grams: 50), today: "2026-10-24"))
        #expect(r.activeCount == 1)
    }

    // MARK: - The bar and the value are one

    static func sample() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        shop.clearLibraryFilter()
        shop.search = ""
        shop.shelf = .library(nil)
        shop.libraryFlat = true
        await shop.settleLibraryFacets()
        return shop
    }

    @Test("libraryQuery reads every axis the bar sets, and setting it sets them")
    func barIsTheQuery() async {
        let shop = await Self.sample()
        shop.libraryTag = "relief"
        shop.libraryCategory = .named("Wall art")
        shop.libraryRanges.minutes = .init(max: 600)
        shop.search = "king"
        let q = shop.libraryQuery
        #expect(q.tag == "relief" && q.category == "Wall art" && q.text == "king")
        #expect(q.ranges.minutes.max == 600)

        shop.clearLibraryFilter()
        shop.search = ""
        #expect(shop.libraryQuery.isEmpty)
        shop.libraryQuery = q
        #expect(shop.libraryTag == "relief")
        #expect(shop.libraryCategory == .named("Wall art"))
        #expect(shop.libraryRanges == q.ranges)
        #expect(shop.search == "king")
        #expect(shop.libraryQuery == q)
    }

    @Test("a saved search's count is the number of tiles opening it draws")
    func countIsTheGrid() async {
        let shop = await Self.sample()
        var queries: [LibraryQuery] = LibrarySmartFolder.allCases.map(\.query)
        queries += shop.librarySavedSearches.map(\.query)
        var tagged = LibraryQuery(); tagged.text = "tag:relief"; queries.append(tagged)
        var cat = LibraryQuery(); cat.category = "wall art"; cat.ranges.timesPrinted = .init(min: 4)
        queries.append(cat)
        for q in queries {
            let counted = shop.libraryCount(q)
            shop.openLibraryQuery(q)
            await shop.settleLibraryFacets()
            #expect(shop.shownFiles.count == counted, "\(q.json)")
            shop.clearLibraryFilter()
            shop.search = ""
        }
        // The Kings printed 7,6,5,4 times are the four with 4 or more.
        #expect(shop.libraryCount(cat) == 4)
    }

    @Test("a range leaves out every model whose figure is unknown, and says how many")
    func rangeLeavesUnknownsOut() async throws {
        let shop = await Self.sample()
        // Every sample model has a time, sliced or estimated; one more with
        // nothing to tell it by — no slicer figures, no colours, no mesh.
        var rows = shop.libraryRows
        let lantern = try #require(rows.first { Shop.recordId($0) == "PF-sample-lantern" })
        guard case .object(var bare) = lantern else { return }
        bare["id"] = .string("PF-test-bare")
        for k in ["parsed", "colors", "geometryKey", "contentHash"] { bare.removeValue(forKey: k) }
        rows.append(.object(bare))
        shop.pretendLibrary(rows)
        shop.libraryRows = rows
        let all = shop.files.filter { !$0.isArchived }
        let timed = all.filter { shop.libraryFacts($0).minutes != nil }
        #expect(!timed.contains { $0.id == "PF-test-bare" })
        try #require(timed.count < all.count)
        shop.libraryRanges.minutes = .init(min: 0)
        await shop.settleLibraryFacets()
        #expect(Set(shop.shownFiles.map(\.id)) == Set(timed.map(\.id)))
        #expect(shop.libraryUnknownCount(.time) == all.count - timed.count)
    }

    // MARK: - Built in

    @Test("the six built-in smart folders find what they say")
    func builtIns() async {
        let shop = await Self.sample()
        let live = shop.files.filter { !$0.isArchived }
        #expect(shop.libraryCount(LibrarySmartFolder.neverPrinted.query) == live.count { $0.printCount == 0 })
        #expect(shop.libraryCount(LibrarySmartFolder.noFigures.query)
                == live.count { shop.libraryFacts($0).minutes == nil && shop.libraryFacts($0).grams == nil })
        let sells = shop.catalogueFileIds()
        #expect(!sells.isEmpty, "the sample sells some of its models")
        #expect(shop.libraryCount(LibrarySmartFolder.inCatalogue.query) == live.count { sells.contains($0.id) })
        // Online only needs an index of where the bytes are; the sample has none.
        #expect(shop.libraryCount(LibrarySmartFolder.onlineOnly.query) == 0)
        // Ready to print is every machine's ready set together (`ModelReadiness`).
        shop.readyByMachine = ["M-a": ["PF-sample-lantern"], "M-b": ["PF-sample-vase", "PF-sample-lantern"]]
        #expect(shop.libraryCount(LibrarySmartFolder.ready.query) == 2)
        // Saved from web: the sample has no page saved from the browser.
        #expect(shop.libraryCount(LibrarySmartFolder.fromWeb.query) == live.count(where: \.isFromWeb))
        // Always there, and not stored: the sample book's own one comes after.
        let rows = shop.librarySmartRows
        #expect(rows.prefix(6).map(\.saved) == [nil, nil, nil, nil, nil, nil])
        #expect(rows.count == 6 + shop.librarySavedSearches.count)
        #expect(shop.librarySavedSearches.map(\.name) == ["Quick prints"],
                "the sample book carries one saved search, so the sidebar shows one")
    }

    @Test("a count is worked out once per query until the library moves")
    func countsAreMemoised() async {
        let shop = await Self.sample()
        let q = LibrarySmartFolder.neverPrinted.query
        _ = shop.libraryCount(q)
        let before = shop.libraryMemo.work.queryCounts
        for _ in 0..<20 { _ = shop.libraryCount(q) }
        var sorted = q; sorted.sort = "name"
        _ = shop.libraryCount(sorted)
        #expect(shop.libraryMemo.work.queryCounts == before, "the order is not part of a count")
        shop.pretendLibrary(Array(shop.libraryRows.prefix(5)))
        _ = shop.libraryCount(q)
        #expect(shop.libraryMemo.work.queryCounts == before + 1)
    }

    // MARK: - The list rules

    @Test("saving under a name replaces; renaming refuses a taken name; duplicate names the copy")
    func listRules() throws {
        var q1 = LibraryQuery(); q1.tag = "a"
        var q2 = LibraryQuery(); q2.tag = "b"
        var list = try #require(LibrarySavedSearch.saving("  Wall   art ", q1, into: [], id: "1", at: "t"))
        #expect(list.map(\.name) == ["Wall art"])
        list = try #require(LibrarySavedSearch.saving("wall art", q2, into: list, id: "2", at: "t"))
        #expect(list.count == 1 && list[0].id == "1" && list[0].query == q2, "same name replaces")
        #expect(LibrarySavedSearch.saving("   ", q1, into: list, id: "3", at: "t") == nil)
        list = try #require(LibrarySavedSearch.saving("Busts", q1, into: list, id: "3", at: "t"))
        #expect(LibrarySavedSearch.renaming("3", to: "WALL ART", in: list) == nil, "taken")
        list = try #require(LibrarySavedSearch.duplicating("1", in: list, newId: "4", at: "t") { "\($0) \($1)" })
        #expect(list.map(\.name) == ["wall art", "wall art 2", "Busts"])
        list = try #require(LibrarySavedSearch.deleting("1", from: list))
        #expect(list.map(\.id) == ["4", "3"])
        // Junk in the book is dropped; the first of a repeated id wins.
        let settings: [String: JSONValue] = [LibrarySavedSearch.settingsKey: .array([
            .string("nope"), .object(["id": .string("x"), "name": .string("")]),
            .object(["id": .string("a"), "name": .string("One")]),
            .object(["id": .string("a"), "name": .string("Two")]),
        ])]
        #expect(LibrarySavedSearch.all(settings: settings).map(\.name) == ["One"])
    }

    @Test("behind the lock, nobody signed in cannot save a search, and a viewer cannot either")
    func gated() async {
        let shop = await OperatorLockTests.shop()
        #expect(shop.needsSignIn)
        #expect(await shop.saveLibrarySearch(named: "Locked out") == false)
        #expect(shop.moveProblem != nil)
        #expect(await shop.signIn("OP-v", pin: "4444") == .ok)
        shop.moveProblem = nil
        #expect(await shop.saveLibrarySearch(named: "A viewer's") == false)
        #expect(shop.moveProblem != nil)
        #expect(shop.librarySavedSearches.allSatisfy { $0.name != "A viewer's" })
    }

    @Test("the sample book is for looking at: Save Search… says so and writes nothing")
    func sampleRefuses() async {
        let shop = await Self.sample()
        shop.libraryTag = "relief"
        #expect(await shop.saveLibrarySearch(named: "Reliefs") == false)
        #expect(shop.moveProblem == shop.words.callIt("mac.ls_sample"))
    }

    @Test("every word this stage added is in English and Arabic, with its placeholders in both")
    func words() throws {
        let keys = Words.own.keys.filter { $0.hasPrefix("mac.ls_") }
        #expect(keys.count >= 40)
        for key in keys {
            let entry = try #require(Words.own[key])
            let en = try #require(entry["en"]), ar = try #require(entry["ar"])
            #expect(!en.isEmpty && !ar.isEmpty, "\(key)")
            for p in ["{name}", "{n}", "{currency}"] where en.contains(p) {
                #expect(ar.contains("\u{2068}" + p + "\u{2069}"), "\(key): \(p) is not isolated in the Arabic")
            }
        }
    }

    // MARK: - Speed

    /// The 600-model library of the grid's snapshot scene, in memory.
    static func scaled() async -> Shop {
        let shop = await Self.sample()
        shop.pretendLibrary(Snapshot.scaled(shop.libraryRows, to: 600))
        shop.libraryRows = Snapshot.scaled(shop.libraryRows, to: 600)
        shop.recountLibrarySoon()
        await shop.settleLibraryFacets()
        return shop
    }

    /// Measured on a debug build (Oct 24 2026, M-series, this suite alone): a
    /// facet recount over 600 models with a range on took 13–110 ms (the
    /// slow one is the engine counting a new pool of categories and tags).
    /// In a filtered run beside 160 other main-actor tests the worst was
    /// 660 ms — time spent queued behind them, not counting. So the bound is
    /// generous, and the WORK is counted as well, which does not depend on
    /// the machine or on what else is running.
    ///
    /// CI's shared runner, in the full 2,161-test run, took 1,664 ms (PR
    /// #2059, Oct 25), so the clock bounds below only catch a runaway (a
    /// recount per model, say); the work counts are the real guard.
    @Test("facet counts and smart-folder counts stay quick on 600 models, and a repeat is free")
    func facetSpeed() async {
        let shop = await Self.scaled()
        #expect(shop.files.count == 600)

        let clock = ContinuousClock()
        var worst: Duration = .zero
        for max in [60.0, 120, 240, 480] {
            shop.libraryRanges.minutes = .init(max: max)
            let t = clock.now
            await shop.settleLibraryFacets()
            worst = Swift.max(worst, clock.now - t)
        }
        #expect(ms(worst) < 10_000, "a facet recount took \(ms(worst)) ms")

        // The same question again: the memo answers, nothing is counted.
        let ran = shop.libraryMemo.work.facetRecounts
        let hits = shop.libraryMemo.work.facetMemoHits
        shop.recountLibrarySoon()
        await shop.settleLibraryFacets()
        #expect(shop.libraryMemo.work.facetRecounts == ran)
        #expect(shop.libraryMemo.work.facetMemoHits == hits + 1)

        let rows = shop.librarySmartRows
        let t = clock.now
        let counts = rows.map { shop.libraryCount($0.query) }
        let took = clock.now - t
        #expect(ms(took) < 5_000, "\(rows.count) smart-folder counts took \(ms(took)) ms")
        #expect(counts.allSatisfy { $0 >= 0 && $0 <= 600 })
        // A redraw of the sidebar asks again and does no work.
        let before = shop.libraryMemo.work.queryCounts
        for _ in 0..<10 { _ = rows.map { shop.libraryCount($0.query) } }
        #expect(shop.libraryMemo.work.queryCounts == before)
    }

    @Test("a range figure: a comma grouping thousands is not a decimal point, in either language's digits")
    func rangeNumbers() {
        #expect(RangeNumber.parse("1,000") == 1000)
        #expect(RangeNumber.parse("1,000.5") == 1000.5)
        #expect(RangeNumber.parse("1,000,000") == 1_000_000)
        #expect(RangeNumber.parse("1,5") == 1.5)
        #expect(RangeNumber.parse("0,125") == 0.125)
        #expect(RangeNumber.parse("12.5") == 12.5)
        #expect(RangeNumber.parse("\u{0661}\u{066C}\u{0660}\u{0660}\u{0660}") == 1000)
        #expect(RangeNumber.parse("\u{0661}\u{066B}\u{0665}") == 1.5)
        #expect(RangeNumber.parse("") == nil && RangeNumber.parse("abc") == nil && RangeNumber.parse("-3") == nil)
    }
}

extension LibraryEditPerfTests {

    @Test("saved searches: written on the chain to settings, two at once both land, rename/duplicate/delete")
    func savedSearchWritePath() async throws {
        try await withPerfBook(PerfBook.synthesize(models: 20)) { shop, url in
            func onDisk() throws -> [LibrarySavedSearch] {
                let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
                return LibrarySavedSearch.all(settings: Shop.settings(root))
            }
            shop.shelf = .library(nil)
            shop.libraryRanges.minutes = .init(max: 180)
            async let a = shop.saveLibrarySearch(named: "Quick")
            async let b = shop.saveLibrarySearch(named: "Also quick")
            let (wroteA, wroteB) = await (a, b)
            #expect(wroteA && wroteB)
            #expect(Set(try onDisk().map(\.name)) == ["Quick", "Also quick"], "a write was lost")
            #expect(try onDisk().allSatisfy { $0.query.ranges.minutes.max == 180 })
            // The rest of the settings are kept.
            let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
            #expect(Shop.settings(root)["bizEn"] == .string("Perf Shop"))

            let quick = try #require(shop.librarySavedSearches.first { $0.name == "Quick" })
            #expect(await shop.renameLibrarySearch(quick.id, to: "Fast"))
            #expect(await shop.renameLibrarySearch(quick.id, to: "also QUICK") == false, "taken")
            #expect(await shop.duplicateLibrarySearch(quick.id))
            #expect(try onDisk().map(\.name).contains("Fast 2"))

            shop.libraryTag = "x"
            #expect(await shop.replaceLibrarySearch(quick.id))
            #expect(try onDisk().first { $0.id == quick.id }?.query.tag == "x")

            #expect(await shop.deleteLibrarySearch(quick.id))
            #expect(try onDisk().contains { $0.id == quick.id } == false)
            #expect(shop.librarySavedSearches.map(\.id) == (try onDisk()).map(\.id))
        }
    }
}
