import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The model page's summary card, fit-aware readiness, the multi-select
/// pane's bulk actions, and the delete count.
@MainActor
struct LibraryInspectorRedesignTests {

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

    // MARK: Summary facts

    @Test("cost to make is the catalogue's own cost for the model, and the linked product's margin is its price over its cost")
    func summaryFacts() async throws {
        let shop = await Self.sample()
        let falcon = try #require(shop.files.first { $0.id == "PF-sample-falcon" })
        let summary = await shop.modelSummary(for: falcon)
        // ONE formula: the same parts a product made from it starts with,
        // through the same pricing rule.
        let draft = try #require(await shop.modelPartsDraft(falcon))
        let priced = try #require(await shop.priceProduct(parts: draft.parts, margin: nil, components: nil))
        let cost = try #require(summary.cost)
        #expect(abs(cost - priced.cost) < 0.0001)
        #expect(summary.hours == priced.hours && summary.grams == priced.grams)
        #expect(summary.estimated, "the falcon was never sliced: its figures come from the mesh")
        let product = try #require(summary.product, "the sample links PRD-2CF8FF to the falcon")
        #expect(product.id == "PRD-2CF8FF")
        #expect(product.price > 0)
        let margin = try #require(product.margin)
        #expect(margin > 0 && margin < 1)
        #expect(!product.belowFloor, "the sample sets no minimum margin")
        // The product that would be made from it costs the same as the card says.
        let made = try #require(await shop.productFromFile(falcon))
        guard case .array(let parts)? = made.rest["parts"] else { Issue.record("no parts"); return }
        let again = try #require(await shop.priceProduct(parts: parts, margin: nil, components: nil))
        #expect(abs(again.cost - cost) < 0.0001)
    }

    @Test("a model in no product says so, and a sliced one is not marked estimated")
    func unlinkedAndSliced() async throws {
        let shop = await Self.sample()
        let king = try #require(shop.files.first { $0.id == "PF-sample-king-1" })
        #expect(await shop.modelSummary(for: king).product == nil)
        #expect(Shop.linkedProductId("PF-sample-king-1", in: shop.productRows) == nil)
        #expect(Shop.linkedProductId("PF-sample-lantern", in: shop.productRows) == "PRD-B5BCAD")
        let vase = try #require(shop.files.first { $0.id == "PF-sample-vase" })
        let sliced = await shop.modelSummary(for: vase)
        #expect(!sliced.estimated)
        #expect(LibraryInspector.fullySliced(vase))
    }

    @Test("the sample's Kings measure as the 200 mm reliefs they are, not a metre-wide helmet")
    func kingsAreTwoHundred() async throws {
        let shop = await Self.sample()
        for king in shop.files where king.id.hasPrefix("PF-sample-king") {
            let mesh = try #require(king.mesh)
            #expect(mesh.x == 200 && mesh.y == 200 && mesh.z < 10, "\(king.id): \(mesh)")
        }
    }

    // MARK: Fit-aware readiness

    @Test("a model too big for the bed is not ready there, in the inspector and in the Ready chip alike")
    func fitAwareReadiness() async throws {
        let shop = await Self.sample()
        // The sample's U1 has the Kings' four colours loaded.
        let u1 = "MACH-u1"
        #expect(shop.readyByMachine[u1]?.contains("PF-sample-king-2") == true)
        let king = try #require(shop.files.first { $0.id == "PF-sample-king-2" })
        #expect(shop.machineFits(for: king).first { $0.id == u1 }?.state == .ready)

        // The same King at a metre wide.
        var rows = shop.libraryRows
        let i = try #require(rows.firstIndex { Shop.recordId($0) == "PF-sample-king-2" })
        guard case .object(var o) = rows[i] else { Issue.record("not an object"); return }
        o["geometryKey"] = .string("6290060:117171.2:1141.57x757.09x207.37")
        rows[i] = .object(o)
        shop.pretendLibrary(rows)
        shop.libraryRows = rows
        shop.recountLibrarySoon()
        await shop.settleLibraryFacets()
        let big = try #require(shop.files.first { $0.id == "PF-sample-king-2" })
        let fits = shop.machineFits(for: big)
        #expect(!fits.isEmpty && fits.allSatisfy { $0.state == .tooBig })
        #expect(ModelSummary(machines: fits).tooBigEverywhere)
        #expect(shop.spoolReadyByMachine[u1]?.contains(big.id) == true, "the spools still match")
        #expect(shop.readyByMachine[u1]?.contains(big.id) == false, "the Ready chip counted a model that does not fit")
        #expect(!shop.isReady(big, on: u1))
        // A laser bed or a UV flatbed is never offered as somewhere a model prints.
        #expect(!fits.contains { $0.id == "MACH-LASER" || $0.id == "MACH-UVFLAT" })
    }

    // MARK: The delete count

    @Test("the multi-select delete names exactly the models it deletes, and counts the hidden ones it will not touch")
    func deleteCountIncludesHidden() async throws {
        let shop = await Self.sample()
        shop.libraryFlat = false   // the Kings fold into their folder tile
        let kings = shop.files.filter { $0.id.hasPrefix("PF-sample-king") }.map(\.id)
        try #require(kings.count == 7)
        let loose = shop.visibleFiles.prefix(2).map(\.id)
        try #require(loose.count == 2 && kings.allSatisfy { !loose.contains($0) })
        shop.fileSelection = Set(kings + loose)
        let chosen = shop.selectedFiles
        #expect(chosen.count == 2, "a model inside a folder tile became part of the selection")
        #expect(shop.selectedButHidden == 7, "the pane must say how many selected models it will not touch")
        #expect(ManyModels.deleteTitle(count: chosen.count, words: shop.words).contains("2"))
        #expect(shop.askToDeleteFromLibrary(chosen).isEmpty)
        #expect(shop.pendingLibraryDeletes.map(\.id) == chosen.map(\.id))
        let lines = Shop.libraryDeleteLines(shop.pendingLibraryDeletes, words: shop.words)
        #expect(lines.first?.contains("2") == true)
        shop.pendingLibraryDeletes = []
        // And a hidden model handed in anyway is refused, not deleted.
        let hidden = shop.files.filter { kings.contains($0.id) }
        #expect(shop.askToDeleteFromLibrary(hidden).count == 7)
        #expect(shop.pendingLibraryDeletes.isEmpty)
    }

    // MARK: Totals

    @Test("totals add the slicer's figures, else the mesh estimate, and count what had none")
    func totals() async throws {
        let shop = await Self.sample()
        let picked = shop.files.filter { ["PF-sample-vase", "PF-sample-king-1"].contains($0.id) }
        let t = shop.selectionTotals(picked)
        let vase = try #require(picked.first { $0.id == "PF-sample-vase" })
        let king = try #require(picked.first { $0.id == "PF-sample-king-1" })
        let kingHours = shop.estimates[king.id]?.hours ?? 0
        #expect(t.count == 2)
        #expect(abs(t.hours - ((vase.parsed?.printTimeMins ?? 0) / 60 + kingHours)) < 0.0001)
        #expect(t.withFigures == 2)
        #expect(t.bytes == (vase.size ?? 0) + (king.size ?? 0))
    }

    // MARK: Words and wiring

    @Test("every new word has English and Arabic, in Arabic script")
    func words() throws {
        let keys = Words.own.keys.filter { $0.hasPrefix("mac.li_") }
        #expect(keys.count > 50)
        for key in keys {
            let entry = try #require(Words.own[key])
            #expect(entry["en"]?.isEmpty == false, "\(key) en")
            let ar = entry["ar"] ?? ""
            #expect(ar.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }, "\(key) ar")
        }
        // Every mac.li_ key the redesign's sources use exists.
        for file in ["LibraryInspector.swift", "GroupMenu.swift", "FileActions.swift", "Shop+ModelSummary.swift"] {
            let src = try String(contentsOf: GroupFromRightClickTests.source(file), encoding: .utf8)
            for m in src.matches(of: /"(mac\.li_[a-z_]+)"/) {
                #expect(Words.own[String(m.output.1)] != nil, "\(m.output.1) used in \(file) has no words")
            }
        }
    }

    @Test("the summary card holds the photo drop and the three buttons; the separate photo box is gone")
    func wiring() throws {
        let inspector = try String(contentsOf: GroupFromRightClickTests.source("LibraryInspector.swift"), encoding: .utf8)
        #expect(inspector.contains("ModelSummaryCard(shop: shop, file: file"))
        #expect(!inspector.contains("PhotoSection("), "the empty drop box is back")
        #expect(inspector.contains("shop.setLibraryPhoto(file.id, from: url)"))
        #expect(inspector.contains("InspectorSection(id: \"print\""))
        // The buttons are never hidden behind the file's state.
        let card = try #require(inspector.range(of: "private var actions: some View")).upperBound
        let body = String(inspector[card...].prefix(1400))
        #expect(!body.contains("isInCloudOnly") && !body.contains("modelFile(for"))
        let many = try String(contentsOf: GroupFromRightClickTests.source("GroupMenu.swift"), encoding: .utf8)
        for call in ["shop.addTagToSelection(", "shop.fileSelection(underCategory:", "shop.fileSelection(under:",
                     "shop.setMaterialOnSelection(", "shop.startJob(fromModels: chosen, asQuote: true)",
                     "shop.shareByLink(", "shop.sellAsProduct(", "shop.freeUpSpace(models:",
                     "shop.keepOnThisMac(models:", "shop.askToDeleteFromLibrary(chosen)"] {
            #expect(many.contains(call), "\(call) is not in the multi-select pane")
        }
        // Share & Sell inside the vault gate there too.
        let gate = try #require(many.range(of: "if shop.libraryOnVault"))
        let share = try #require(many.range(of: "shop.shareByLink("))
        #expect(gate.lowerBound < share.lowerBound)
        // The right-click menu is grouped.
        let menu = try String(contentsOf: GroupFromRightClickTests.source("FileActions.swift"), encoding: .utf8)
        for group in ["\"mac.li_group_organise\"", "\"mac.li_group_share\"", "\"mac.li_group_storage\""] {
            #expect(menu.contains("Menu(shop.words.callIt(\(group)))"), "\(group) submenu missing")
        }
    }
}

/// The bulk actions' store writes, on a real (temporary) book.
extension LibraryEditPerfTests {

    @Test("Add Tag keeps each model's tags and adds one; Set Material writes the shop's own spelling")
    func bulkWrites() async throws {
        try await withPerfBook(PerfBook.synthesize(models: 12)) { shop, url in
            shop.clearLibraryFilter()
            shop.libraryFlat = true
            shop.shelf = .library(nil)
            let shown = shop.visibleFiles
            try #require(shown.count >= 3)
            shop.select(shown[0], modifiers: .replace)
            shop.select(shown[1], modifiers: .toggle)
            let ids = shop.selectedIds
            try #require(ids.count == 2)
            func record(_ id: String) throws -> [String: JSONValue]? {
                for case .object(let o) in try diskRows(url) where o["id"] == .string(id) { return o }
                return nil
            }
            let before = try ids.map { ($0, try record($0)?["tags"]) }

            await shop.addTagToSelection("Ramadan")
            await shop.settleLibraryWrites()
            for (id, had) in before {
                let now = Shop.mergedTags(try record(id)?["tags"], adding: [])
                let was = Shop.mergedTags(had, adding: [])
                #expect(now.count == was.count + (was.contains { $0.lowercased() == "ramadan" } ? 0 : 1))
                #expect(now.contains { $0.lowercased() == "ramadan" })
                #expect(was.allSatisfy(now.contains), "a tag the model had was lost")
            }
            // A model outside the selection is untouched.
            #expect(Shop.mergedTags(try record(shown[2].id)?["tags"], adding: []).allSatisfy { $0.lowercased() != "ramadan" })

            shop.setMaterialOnSelection("  petg-cf ")
            await shop.settleLibraryWrites()
            for id in ids { #expect(try record(id)?["material"] == .string("petg-cf")) }
            shop.setMaterialOnSelection("")
            await shop.settleLibraryWrites()
            for id in ids { #expect(try record(id)?["material"] == .null) }
        }
    }

    @Test("mergedTags adds once, case-insensitively, in order")
    func merged() {
        let had: JSONValue = .array([.string("relief"), .string("Portrait")])
        #expect(Shop.mergedTags(had, adding: ["portrait", "Ramadan"]) == ["relief", "Portrait", "Ramadan"])
        #expect(Shop.mergedTags(nil, adding: ["a"]) == ["a"])
    }
}
