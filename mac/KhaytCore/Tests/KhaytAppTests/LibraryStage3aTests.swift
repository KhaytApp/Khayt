import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Library stage 3a: the printer chips on a tile, the Fits filter, the list's
/// Fits column, and ⌘J — on the sample, and on the 600-model library the
/// density scenes use (`Snapshot.scaled`), all in memory.
@MainActor
struct LibraryStage3aTests {

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

    /// The sample's rows, with the lantern too tall for the X1C and the vase
    /// too big for every bed — the snapshot scene's own (`Snapshot.stretched`).
    static func varied(_ rows: [JSONValue]) -> [JSONValue] { Snapshot.stretched(rows) }

    static func pretend(_ shop: Shop, _ rows: [JSONValue]) async {
        shop.pretendLibrary(rows)
        shop.libraryRows = rows
        shop.recountLibrarySoon()
        await shop.settleLibraryFacets()
    }

    // MARK: The tile and the page agree

    @Test("every tile's chips are the inspector's own answer, machine by machine")
    func tileMatchesInspector() async {
        let shop = await Self.sample()
        await Self.pretend(shop, Self.varied(shop.libraryRows))
        var sawReady = false, sawSwap = false, sawFits = false, sawTooBig = false
        for file in shop.files {
            let page = shop.machineFits(for: file)
            let tile = shop.libraryFitChips(file)
            let expected = LibraryFitChips.row(page.map { ($0.id, $0.name, $0.state) })
            #expect(tile == expected, "\(file.id)")
            // Every chip is a machine the page says it goes on, in the page's state.
            for chip in tile.chips {
                let state = page.first { $0.id == chip.machineId }?.state
                #expect(state.map(LibraryFitChips.shows) == true, "\(file.id) \(chip.machineId)")
                #expect(state.flatMap(LibraryFitChips.tone) == chip.tone)
            }
            #expect(tile.tooBigEverywhere == ModelSummary(machines: page).tooBigEverywhere)
            sawReady = sawReady || tile.chips.contains { $0.tone == .ready }
            sawSwap = sawSwap || tile.chips.contains { $0.tone == .swap }
            sawFits = sawFits || tile.chips.contains { $0.tone == .fits }
            sawTooBig = sawTooBig || tile.tooBigEverywhere
        }
        #expect(sawReady && sawSwap && sawFits && sawTooBig, "the sample should show every kind of chip")
        // A laser or a UV flatbed is never a chip.
        #expect(!shop.files.contains { f in
            shop.libraryFitChips(f).chips.contains { $0.machineId == "MACH-LASER" || $0.machineId == "MACH-UVFLAT" }
        })
        // The lantern at 262 mm tall: on the U1 and the CORE One, not the X1C (256).
        let lantern = shop.files.first { $0.id == "PF-sample-lantern" }!
        let ids = shop.libraryFitChips(lantern).chips.map(\.machineId)
        #expect(ids.contains("MACH-u1") && ids.contains("MACH-core-one") && !ids.contains("MACH-x1c"))
    }

    @Test("ready chips come first, on the leading side, before a swap and a plain fit")
    func readyFirst() async throws {
        let shop = await Self.sample()
        let king = try #require(shop.files.first { $0.id == "PF-sample-king-2" })
        let row = shop.libraryFitChips(king)
        #expect(row.chips.first?.machineId == "MACH-u1", "the U1 has the Kings' colours loaded")
        #expect(row.chips.first?.tone == .ready)
        #expect(row.chips.map(\.tone) == row.chips.map(\.tone).sorted { a, b in
            let r: [LibraryFitChips.Tone: Int] = [.ready: 0, .swap: 1, .fits: 2]
            return r[a]! < r[b]!
        })
    }

    // MARK: Worked out once

    @Test("the chips are worked out once per model per change, never per redraw")
    func memoised() async throws {
        let shop = await Self.sample()
        let files = shop.files
        // From cold: one fit per model, however many machines.
        shop.libraryMemo.machineFitsKey = nil
        let start = shop.libraryMemo.work.fitBuilds
        for f in files { _ = shop.libraryFitChips(f) }
        let built = shop.libraryMemo.work.fitBuilds
        #expect(built - start == files.count)
        // A hundred redraws of every tile.
        for _ in 0..<100 { for f in files { _ = shop.libraryFitChips(f); _ = shop.machineFits(for: f) } }
        #expect(shop.libraryMemo.work.fitBuilds == built, "a redraw worked out a fit again")
        // The Fits sets: once.
        _ = shop.libraryFitSets(); _ = shop.libraryFitSets()
        let sets = shop.libraryMemo.work.fitSetBuilds
        _ = shop.libraryFitSets()
        #expect(shop.libraryMemo.work.fitSetBuilds == sets)
        // A change to the library: worked out again.
        await Self.pretend(shop, Self.varied(shop.libraryRows))
        _ = shop.libraryFitChips(try #require(shop.files.first))
        #expect(shop.libraryMemo.work.fitBuilds > built)
    }

    // MARK: Fits <machine>

    @Test("Fits <machine> goes through the one matcher: the grid, the count and the chip agree")
    func fitsFilter() async throws {
        let shop = await Self.sample()
        await Self.pretend(shop, Self.varied(shop.libraryRows))
        let x1c = "MACH-x1c"
        let expected = Set(shop.files.filter { f in
            !f.isArchived && shop.libraryFitChips(f).chips.contains { $0.machineId == x1c }
        }.map(\.id))
        #expect(!expected.isEmpty)
        #expect(!expected.contains("PF-sample-lantern") && !expected.contains("PF-sample-vase"))

        shop.libraryFitsOn = x1c
        await shop.settleLibraryFacets()
        #expect(Set(shop.shownFiles.map(\.id)) == expected)
        #expect(shop.libraryQuery.fitsOn == x1c)
        #expect(shop.libraryFilterOn)
        // The count beside a saved search of it is the number of tiles.
        var q = LibraryQuery()
        q.fitsOn = x1c
        #expect(shop.libraryCount(q) == expected.count)
        // The facet's own count, over what the other axes leave.
        let facet = try #require(shop.libraryFacets.fits.first { $0.machineId == x1c })
        #expect(facet.count == expected.count)
        // Not offered for a laser or a UV flatbed.
        #expect(!shop.libraryFacets.fits.contains { $0.machineId == "MACH-LASER" || $0.machineId == "MACH-UVFLAT" })

        // Cleared with every other filter, and loaded back from a saved query.
        shop.clearLibraryFilter()
        #expect(shop.libraryFitsOn == nil)
        shop.openLibraryQuery(q)
        #expect(shop.libraryFitsOn == x1c)
        shop.clearLibraryFilter()
    }

    @Test("the Printer menu holds Ready on and Fits; the Fits label says so in both languages")
    func filterBarWords() {
        let bar = MenuCoverageTests.source("LibraryFilterBar.swift")
        #expect(bar.contains("prefix: \"ready:\", alsoPrefix: \"fits:\""))
        #expect(bar.contains("\"mac.fits_on\""))
    }

    // MARK: The list

    @Test("the list's Fits column reads the tile's chips")
    func listColumn() async {
        let shop = await Self.sample()
        let rows = shop.libraryListRows()
        for row in rows {
            guard let file = row.file else { continue }
            #expect(row.fits == shop.libraryFitChips(file), "\(file.id)")
        }
        #expect(MenuCoverageTests.source("LibraryList.swift").contains("mac.lg_col_fits"))
    }

    // MARK: 600 models

    @Test("600 models: every tile's chips and the Fits sets, once each; then nothing on a redraw")
    func sixHundred() async throws {
        let shop = await Self.sample()
        let rows = Snapshot.scaled(Self.varied(shop.libraryRows), to: 600)
        await Self.pretend(shop, rows)
        #expect(shop.files.count == 600)
        // From cold, as after a change to the book (the recount above has
        // already filled the memo once).
        shop.libraryMemo.machineFitsKey = nil
        let before = shop.libraryMemo.work.fitBuilds
        let clock = ContinuousClock()
        let first = clock.measure {
            for f in shop.files { _ = shop.libraryFitChips(f) }
            _ = shop.libraryFitSets()
        }
        let built = shop.libraryMemo.work.fitBuilds - before
        #expect(built == 600, "\(built) fits for 600 models")
        let again = clock.measure {
            for _ in 0..<10 { for f in shop.files { _ = shop.libraryFitChips(f) } }
        }
        #expect(shop.libraryMemo.work.fitBuilds - before == built, "a redraw worked a fit out again")
        // Fits on: the grid's pass reads the sets, not 600 fits.
        shop.libraryFitsOn = "MACH-u1"
        let filtered = clock.measure { _ = shop.shownFiles }
        #expect(shop.libraryMemo.work.fitBuilds - before == built)
        shop.libraryFitsOn = nil
        // A whole recount of the chips' counts, Fits included, from cold.
        shop.libraryMemo.machineFitsKey = nil
        shop.facetMemo = nil
        let recount = await clock.measure {
            shop.recountLibrarySoon()
            await shop.settleLibraryFacets()
        }
        #expect(shop.libraryFacets.fits.contains { $0.machineId == "MACH-u1" && $0.count > 0 })
        print("stage3a 600 models: full facet recount from cold \(recount)")
        // Wall-clock bounds only as a backstop (CI runners are slow); the
        // counts above are the real guard.
        #expect(first < .seconds(10) && again < .seconds(10) && filtered < .seconds(10))
        print("stage3a 600 models: first pass \(first), ten redraws \(again), Fits filter \(filtered), builds \(built)")
    }

    // MARK: ⌘J

    @Test("⌘J lists models, folders, compressed files, tags and saved searches — nothing archived")
    func jumpCandidates() async {
        let shop = await Self.sample()
        let all = shop.libraryJumpCandidates()
        let kinds = Set(all.map(\.kind))
        #expect(kinds.isSuperset(of: [.model, .folder, .tag, .search]), "\(kinds)")
        #expect(!all.contains { c in c.kind == .model && shop.files.first { $0.id == c.id }?.isArchived == true })
        // Every level of a folder path is a folder.
        for c in all where c.kind == .folder || c.kind == .archive {
            #expect(shop.files.contains { ($0.groupName ?? "") == c.id || ($0.groupName ?? "").hasPrefix(c.id + "/") })
        }
        // The built-in smart folders are there by the sidebar's ids.
        #expect(all.contains { $0.kind == .search && $0.id == "builtin:ready" })
    }

    @Test("⌘J ranks and narrows like ⌘K, and opens a model where the grid can show it")
    func jumpModel() async throws {
        let shop = await Self.sample()
        let model = LibraryJumpModel(shop: shop)
        await model.load()
        #expect(model.answer.recent && !model.rows.isEmpty, "nothing typed lists recent models")
        #expect(model.rows.allSatisfy { $0.entry.kind == .model })
        model.query = "dallah"
        await model.search()
        let row = try #require(model.rows.first)
        #expect(row.entry.id == "PF-sample-dallah")
        // Put a filter on that would hide it, then jump.
        shop.libraryNeverPrintedOnly = true
        let asked = shop.libraryScrollRequest
        shop.jumping = true
        model.open()
        #expect(!shop.jumping)
        #expect(!shop.libraryNeverPrintedOnly, "the filter that hid it is off")
        #expect(shop.fileSelection == ["PF-sample-dallah"])
        #expect(shop.libraryScrollRequest == asked + 1, "the grid is asked to bring it into view")
        #expect(shop.visibleFiles.contains { $0.id == "PF-sample-dallah" })
    }

    @Test("⌘J opens a folder, a tag and a saved search the way the library does")
    func jumpOthers() async throws {
        let shop = await Self.sample()
        let index = await shop.libraryJumpIndex()
        let folder = try #require(index.entries.first { $0.kind == .folder })
        shop.jump(to: folder)
        #expect(shop.shelf == .library(folder.id))

        let tag = try #require(index.entries.first { $0.kind == .tag })
        shop.jump(to: tag)
        #expect(shop.shelf == .library(nil))
        #expect(shop.libraryTag == tag.id)

        let search = try #require(index.entries.first { $0.kind == .search && $0.id == "builtin:neverPrinted" })
        shop.jump(to: search)
        #expect(shop.libraryNeverPrintedOnly && shop.libraryTag == nil)
        shop.clearLibraryFilter()
    }

    @Test("⌘↩ and ⌥↩ start nothing where the menus' Quote and New Job are greyed")
    func jumpGates() async throws {
        let shop = await Self.sample()
        // The sample cannot move jobs: the menus grey Quote and New Job.
        #expect(!shop.canMoveJobs)
        let index = await shop.libraryJumpIndex()
        let model = try #require(index.entries.first { $0.kind == .model })
        #expect(!shop.libraryJumpAllows(.quote, on: .model))
        #expect(!shop.libraryJumpAllows(.newJob, on: .model))
        shop.jump(to: model, .quote)
        #expect(shop.fileSelection == [model.id], "a refused quote still opens the model")
        try await Task.sleep(for: .milliseconds(50))
        #expect(!shop.takingAJob)
        #expect(shop.libraryJumpAllows(.open, on: .folder))
        #expect(!shop.libraryJumpAllows(.quote, on: .folder))
    }

    @Test("Go ▸ Jump to in Library… is ⌘J, gated like the Library, and on both shells")
    func menuItem() {
        let menus = MenuCoverageTests.menus
        #expect(menus.contains("Button(Words.upfront(\"mac.jump\") + \"\\u{2026}\") { shop.jumping = true }"))
        #expect(menus.contains(".keyboardShortcut(\"j\")\n"), "⌘J is not on Jump to in Library…")
        #expect(menus.contains(".disabled(!shop.canJumpInLibrary)"))
        let window = MenuCoverageTests.source("ShopWindow.swift")
        #expect(window.components(separatedBy: ".overlay { jump }").count == 3, "the palette is missing from a shell")
        let help = ["en", "ar"].map { MenuCoverageTests.source("Help/\($0)/shortcuts.md") }
        #expect(help.allSatisfy { $0.contains("**⌘J**") }, "the Help shortcuts page does not list ⌘J")
    }

    @Test("⌘J and ⌘K are one at a time, and the lock puts ⌘J away")
    func oneAtATime() async {
        let shop = await Self.sample()
        shop.goingTo = true
        shop.jumping = true
        #expect(shop.jumping && !shop.goingTo)
        shop.goingTo = true
        #expect(!shop.jumping)
        shop.jumping = true
        shop.dismissEverySheet()
        #expect(!shop.jumping)
    }

    @Test("every new word has English and Arabic")
    func words() {
        let keys = ["mac.fits_on", "mac.lfc_more", "mac.lfc_more_said", "mac.lfc_where", "mac.lfc_too_big_all",
                    "mac.lg_col_fits", "mac.jump", "mac.jump_prompt", "mac.jump_hint", "mac.jump_hint_open",
                    "mac.jump_none", "mac.jump_recent", "mac.jump_kind_folder", "mac.jump_kind_archive",
                    "mac.jump_kind_tag", "mac.jump_kind_search", "mac.lib_printer"]
        for key in keys {
            #expect(Words.own[key]?["en"]?.isEmpty == false, "\(key) has no English")
            #expect(Words.own[key]?["ar"]?.isEmpty == false, "\(key) has no Arabic")
        }
    }
}
