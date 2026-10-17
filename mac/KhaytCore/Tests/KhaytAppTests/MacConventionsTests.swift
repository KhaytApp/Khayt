import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Mac's own commands — Print (⌘P), Share, Delete (⌫ / ⌘⌫), Duplicate
/// (⌘D) and a model dropped on New Job — and that each one is a door onto the
/// path the app already had, greyed when there is nothing in front for it.
@MainActor
struct MacConventionsTests {

    static func sample() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    /// A sample job with parts, preferring one with a customer.
    static func jobWithParts(_ shop: Shop) -> (Order, JSONValue)? {
        let rows = shop.orderRows.compactMap { row -> (Order, JSONValue)? in
            guard let id = Shop.recordId(row), let job = shop.orders.first(where: { $0.id == id }),
                  case .object(let o) = row, case .array(let parts)? = o["parts"], !parts.isEmpty
            else { return nil }
            return (job, row)
        }
        return rows.first { pair in
            if case .object(let o) = pair.1, case .string(let c)? = o["clientId"], !c.isEmpty { return true }
            return false
        } ?? rows.first
    }

    // MARK: - Print

    @Test("⌘P prints the selected job's invoice, the P&L on Reports, and nothing elsewhere")
    func printTarget() async throws {
        let shop = await Self.sample()
        let job = try #require(shop.orders.first)

        shop.shelf = .dashboard
        shop.selection = job.id
        #expect(shop.printTarget == nil, "the dashboard is not a document")

        shop.shelf = .jobs(nil)
        shop.selection = nil
        #expect(shop.printTarget == nil, "nothing selected, nothing to print")
        shop.selection = job.id
        #expect(shop.printTarget == .invoice(job.id))
        shop.shelf = .board
        #expect(shop.printTarget == .invoice(job.id), "the board selects jobs too")

        shop.shelf = .reports
        shop.reportPage = .profit
        #expect(shop.printTarget == .pnl)
        shop.reportPage = .best
        #expect(shop.printTarget == nil, "only the P&L has a printed page")

        shop.shelf = .library(nil)
        #expect(shop.printTarget == nil)
    }

    @Test("Print and Share draw the invoice through the sheet's own path")
    func onePathToThePaper() throws {
        let sheet = try QuoteSheetStatusTests.source("InvoiceSheet.swift")
        #expect(sheet.contains("await shop.invoiceDocument(for: subject.id)"),
                "the invoice sheet draws its paper some other way than Print and Share")
        let commands = try QuoteSheetStatusTests.source("Shop+Conventions.swift")
        #expect(commands.contains("await issueInvoiceNumberIfOwed(id)"),
                "an accepted quote could be printed before it is numbered")
        #expect(commands.contains("pnlDocuments(engine: engine, input: input, now: now)"),
                "the printed P&L is not the exported one")
        let pnl = try QuoteSheetStatusTests.source("Shop+Pnl.swift")
        #expect(pnl.contains("try await pnlDocuments(engine: engine, input: input, now: now)"))
    }

    @Test("the sample's invoice is drawn for printing — a read-only book still prints")
    func sampleInvoiceDraws() async throws {
        let shop = await Self.sample()
        let job = try #require(shop.orders.first { $0.status != "quote" } ?? shop.orders.first)
        switch await shop.invoiceDocument(for: job.id) {
        case .paper(let doc, _):
            #expect(!doc.html.isEmpty)
        case .refused(let why):
            // A sample job that began as a quote cannot be numbered on a read-
            // only book — refused WITH a reason, never drawn under the wrong number.
            #expect(!why.isEmpty)
        }
        if case .refused = await shop.invoiceDocument(for: "no-such-job") {} else {
            Issue.record("a job that is not there was drawn")
        }
    }

    // MARK: - Share

    @Test("Share offers the selected job's invoice, and the library's reachable models")
    func shareTarget() async throws {
        let shop = await Self.sample()
        let job = try #require(shop.orders.first)
        shop.shelf = .jobs(nil)
        shop.selection = job.id
        #expect(shop.shareTarget == .invoice(job.id))
        shop.shelf = .customers
        #expect(shop.shareTarget == nil)
        // The sample library's files are not on this Mac: nothing to share.
        shop.shelf = .library(nil)
        shop.fileSelection = Set(shop.visibleFiles.prefix(2).map(\.id))
        let urls = shop.selectedFiles.compactMap(shop.modelFile(for:))
        #expect(shop.shareTarget == (urls.isEmpty ? nil : .models(urls)))
    }

    // MARK: - Delete

    @Test("⌘⌫ on the library: only visible models, the existing question, the count named")
    func deleteRespectsHiddenSelection() async {
        let shop = await LibrarySelectionVisibleTests.shop()
        // Everything selected — the 30 inside the collapsed "Luffy Card" tile
        // as well as the 3 loose ones. The 27 Sep 2026 state.
        shop.fileSelection = Set(shop.shownFiles.map(\.id))
        #expect(shop.fileSelection.count == 33)
        #expect(Set(shop.selectedFiles.map(\.id)) == LibrarySelectionVisibleTests.loose,
                "the selection reaches inside a folder tile")

        // The keyboard's request goes through the right-click menu's door.
        shop.askToDelete(shop.selectedFiles)
        #expect(Set(shop.pendingLibraryDeletes.map(\.id)) == LibrarySelectionVisibleTests.loose)
        #expect(shop.pendingLibraryDelete == nil)
        let lines = Shop.libraryDeleteLines(shop.pendingLibraryDeletes, words: shop.words)
        #expect(lines.first?.contains("3") == true, "the question does not say how many")
        shop.pendingLibraryDeletes = []

        // Handed hidden models anyway, it refuses — several, or one.
        let hidden = shop.shownFiles.filter { !LibrarySelectionVisibleTests.loose.contains($0.id) }
        shop.askToDelete(Array(hidden.prefix(3)))
        #expect(shop.pendingLibraryDeletes.isEmpty, "hidden models reached the question")
        #expect(shop.importProblem != nil)
        shop.importProblem = nil
        shop.askToDelete([hidden[0]])
        #expect(shop.pendingLibraryDelete == nil, "a hidden model reached the single question")
        #expect(shop.importProblem != nil)

        // One visible model: the single question, with its plan.
        let one = shop.visibleFiles[0]
        shop.askToDelete([one])
        #expect(shop.pendingLibraryDelete?.id == one.id)
    }

    @Test("Delete is off on a read-only book and off every screen but the library")
    func deleteEnablement() async {
        let shop = await LibrarySelectionVisibleTests.shop()
        shop.fileSelection = LibrarySelectionVisibleTests.loose
        #expect(!shop.canMoveJobs, "the sample book is meant to be read-only")
        #expect(shop.librarySelectionToDelete.isEmpty, "a read-only book offers Delete")
        shop.askToDeleteLibrarySelection()
        #expect(shop.pendingLibraryDelete == nil && shop.pendingLibraryDeletes.isEmpty)
        #expect(shop.deleteTarget == nil)
        shop.shelf = .jobs(nil)
        #expect(shop.librarySelectionToDelete.isEmpty)
        #expect(shop.deleteTarget == nil, "a read-only book offers Delete on its jobs")
    }

    @Test("⌫ in the grid and ⌘⌫ in the menu both reach the same door")
    func deleteIsWired() throws {
        let grid = try QuoteSheetStatusTests.source("LibraryGrid.swift")
        #expect(grid.contains(".onDeleteCommand { shop.askToDeleteLibrarySelection() }"))
        // The menu asks about whatever is in front; on the library that is
        // the same door, and greyed by the same visible selection.
        let menus = try QuoteSheetStatusTests.source("Menus.swift")
        #expect(menus.contains("shop.askToDeleteFrontmost()"))
        #expect(menus.contains(".keyboardShortcut(.delete, modifiers: .command)"))
        #expect(menus.contains(".disabled(shop.deleteTarget == nil)"))
        let doors = try QuoteSheetStatusTests.source("Shop+Delete.swift")
        #expect(doors.contains("if showingLibrary { askToDeleteLibrarySelection(); return }"))
        #expect(doors.contains("if showingLibrary { return librarySelectionToDelete.isEmpty ? nil : .library }"))
    }

    // MARK: - Duplicate

    @Test("⌘D: off on a read-only book, and only where a job or product is selected")
    func duplicateEnablement() async throws {
        let shop = await Self.sample()
        let job = try #require(shop.orders.first)
        shop.shelf = .jobs(nil)
        shop.selection = job.id
        #expect(shop.duplicateTarget == nil, "a copy is a write; the sample is read-only")
        shop.shelf = .catalogue
        shop.catalogueSelection = shop.catalogueRows.first?.id
        #expect(shop.duplicateTarget == nil)
        await shop.duplicateJob(job.id)
        #expect(!shop.takingAJob, "the read-only sample opened a new job")
        #expect(shop.moveProblem != nil)
    }

    @Test("a duplicated job opens New Job with the customer, parts and notes — and nothing of its run")
    func duplicateSeed() async throws {
        let shop = await Self.sample()
        let (job, row) = try #require(Self.jobWithParts(shop))
        guard case .object(var record) = row else { Issue.record("not a record"); return }
        // Notes and a run's history, so the test does not depend on what the
        // sample happens to have written.
        record["notes"] = .string("Matte black")
        record["internalNotes"] = .string("0.6 nozzle")
        record["paidAmount"] = .number(99)
        record["invoiceNumber"] = .string("INV-2026-0001")
        record["printRuns"] = .array([.object(["machineId": .string("M1")])])

        let seed = try #require(await shop.duplicateSeed(of: .object(record)))
        #expect(seed.project == job.project)
        if case .string(let client)? = record["clientId"], !client.isEmpty {
            #expect(seed.clientId == client)
        }
        guard case .array(let parts)? = record["parts"] else { return }
        #expect(seed.parts.count == parts.count)
        #expect(seed.asQuote == (job.status == "quote"))
        #expect(seed.carried["notes"] == .string("Matte black"))
        #expect(seed.carried["internalNotes"] == .string("0.6 nozzle"))
        for key in ["paidAmount", "invoiceNumber", "printRuns", "id", "status", "parts", "project"] {
            #expect(seed.carried[key] == nil, "\(key) rode along on the copy")
        }

        // What the sheet saves: the sheet's own fields, the carried notes,
        // and nothing from the original's run.
        let input = shop.newJobInput(parts: seed.parts, project: seed.project, clientId: seed.clientId,
                                     margin: seed.margin, discountPct: seed.discountPct,
                                     shippingCost: seed.shippingCost, deposit: 0, rush: false,
                                     asQuote: seed.asQuote, extraLines: seed.extraLines,
                                     carried: seed.carried)
        #expect(input["notes"] == .string("Matte black"))
        #expect(input["paidAmount"] == nil && input["invoiceNumber"] == nil && input["printRuns"] == nil)
        guard case .array(let saved)? = input["parts"] else { Issue.record("no parts"); return }
        #expect(saved.count == parts.count, "the carried parts replaced the sheet's")
    }

    @Test("carried fields never overwrite what the sheet itself set")
    func carriedNeverWins() async {
        let shop = await Self.sample()
        let input = shop.newJobInput(parts: [], project: "Mine", clientId: "C-sheet",
                                     margin: 40, discountPct: 0, shippingCost: 0, deposit: 0,
                                     rush: false, asQuote: false,
                                     carried: ["project": .string("theirs"), "clientId": .string("C-old"),
                                               "notes": .string("kept")])
        #expect(input["project"] == .string("Mine"))
        #expect(input["clientId"] == .string("C-sheet"))
        #expect(input["notes"] == .string("kept"))
    }

    @Test("a duplicated product drops the original's pictures and takes a new id")
    func duplicateProductRule() async throws {
        let shop = await Self.sample()
        let engine = try #require(shop.engine)
        let made = try await engine.duplicateProduct(
            .object(["id": .string("PROD-1"), "nameEn": .string("Lamp"), "imagePath": .string("p.jpg"),
                     "images": .array([.object(["path": .string("p.jpg")])]), "sku": .string("L1"),
                     "defaultMargin": .number(50)]),
            id: "PROD-2", today: "2026-10-16", suffix: shop.words.callIt("mac.copy_suffix"))
        #expect(made["id"] == .string("PROD-2"))
        #expect(made["imagePath"] == nil && made["images"] == nil && made["sku"] == nil)
        #expect(made["defaultMargin"] == .number(50))
        if case .string(let name)? = made["nameEn"] { #expect(name.hasPrefix("Lamp ") && name != "Lamp") }
        else { Issue.record("the copy lost its name") }
    }

    // MARK: - A model dropped on New Job

    @Test("only model files are taken from a drop")
    func droppable() {
        let urls = ["a.3mf", "b.STL", "c.obj", "d.gcode", "e.zip", "f.pdf", "g.step"]
            .map { URL(fileURLWithPath: "/tmp/\($0)") }
        #expect(Shop.droppableModels(urls).map(\.lastPathComponent) == ["a.3mf", "b.STL", "c.obj", "d.gcode"])
        #expect(Shop.droppableModels([URL(string: "https://example.com/a.3mf")!]).isEmpty)
    }

    @Test("a drop on a read-only book is refused, and nothing is imported")
    func dropRefusedOnSample() async {
        let shop = await Self.sample()
        let before = shop.files.count
        let taken = await shop.newJob(fromDropped: [URL(fileURLWithPath: "/tmp/nowhere.stl")])
        #expect(!taken)
        #expect(!shop.takingAJob)
        #expect(shop.moveProblem != nil)
        #expect(shop.files.count == before)
        #expect(await shop.newJob(fromDropped: [URL(fileURLWithPath: "/tmp/a.pdf")]) == false)
    }

    @Test("the jobs list and the Dock both take a dropped model")
    func dropIsWired() throws {
        let table = try QuoteSheetStatusTests.source("OrdersTable.swift")
        #expect(table.contains("await shop.newJob(fromDropped: urls)"))
        let app = try QuoteSheetStatusTests.source("KhaytApp.swift")
        #expect(app.contains("func application(_ application: NSApplication, open urls: [URL])"))
        #expect(app.contains("await shop.takeOpenedFiles()"))
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "make-app.sh")
        let plist = try String(contentsOf: script, encoding: .utf8)
        #expect(plist.contains("<key>CFBundleDocumentTypes</key>"), "the Dock refuses a drop on an app that opens nothing")
        #expect(plist.contains("<key>LSHandlerRank</key><string>Alternate</string>"),
                "Khayt must not become the default app for a shop's model files")
    }

    // MARK: - The menu bar

    @Test("each command is in the File menu, shows its key, and greys when it cannot act")
    func menuWiring() throws {
        let menus = try QuoteSheetStatusTests.source("Menus.swift")
        #expect(menus.contains("CommandGroup(replacing: .printItem)"))
        // After the save group, not in place of it: that group is where
        // macOS keeps File ▸ Close, and replacing it left ⌘W doing nothing.
        #expect(menus.contains("CommandGroup(after: .saveItem)"))
        #expect(!menus.contains("CommandGroup(replacing: .saveItem)"), "replacing .saveItem removes Close (⌘W)")
        #expect(menus.contains(".disabled(shop.printTarget == nil)"))
        #expect(menus.contains(".disabled(shop.shareTarget == nil)"))
        #expect(menus.contains(".disabled(shop.duplicateTarget == nil)"))
        // Under the sign-in lock like every other group.
        #expect(menus.contains("EditCommands().environment(shop).disabled(shop.needsSignIn)"))
        #expect(menus.contains("PrintCommands().environment(shop).disabled(shop.needsSignIn)"))
        // The Invoice item gave ⌘P to Print, and Favourite gave ⌘D to Duplicate.
        #expect(menus.contains(".keyboardShortcut(\"p\", modifiers: [.option, .command])"))
        #expect(menus.contains(".keyboardShortcut(\"d\", modifiers: [.command, .shift])"))
    }

    @Test("the new words are in both languages")
    func wordsInBoth() {
        for key in ["mac.share", "mac.duplicate", "mac.copy_suffix", "mac.print"] {
            let entry = Words.own[key]
            #expect(entry?["en"]?.isEmpty == false, "\(key) has no English")
            #expect(entry?["ar"]?.isEmpty == false, "\(key) has no Arabic")
        }
    }
}
