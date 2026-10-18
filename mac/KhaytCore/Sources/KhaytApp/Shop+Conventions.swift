import AppKit
import KhaytCore

/// The Mac's own commands — Print, Share, Delete, Duplicate, and a file
/// dropped on the app — answered for whatever is in front.
///
/// ── NOTHING NEW HAPPENS HERE ──────────────────────────────────────────────
///
/// Every command below is a door onto a path that already exists: the
/// invoice's paper (`invoiceDocument`, the one `InvoiceSheet` draws), the P&L's
/// page (`pnlDocuments`, the one the PDF export writes), the library's delete
/// with its confirmation (`pendingLibraryDelete` / `askToDeleteFromLibrary`,
/// the right-click menu's), the new-job sheet (`takeJob`), and the import
/// (`addModelsToLibrary`) followed by "New job from model" (`startJob`). A
/// keyboard shortcut that took a different path from the button beside it
/// would be two features that happen to share a name.
///
/// Each command has a `…Target` that says what it would act on, or nil. The
/// menu greys the item on nil — "Menu items show their shortcuts and disable
/// when they can't act" — and the action asks again, because a menu can be
/// opened over one screen and chosen after the book changed underneath it.
extension Shop {

    /// The jobs list or the board — the two screens a job is selected on.
    var showingJobWork: Bool {
        if case .jobs = shelf { return true }
        return showingBoard
    }

    /// The job selected on a screen that shows jobs, when it still exists.
    var frontJob: Order? {
        guard showingJobWork, let id = selection else { return nil }
        return orders.first { $0.id == id }
    }

    // MARK: - File ▸ Print… (⌘P)

    /// What ⌘P would print.
    enum PrintTarget: Equatable {
        /// A job's invoice — or its quotation, for a quote.
        case invoice(Order.ID)
        /// The P&L over the period the Reports page shows.
        case pnl
    }

    /// The document in front, or nil when there is nothing to print. Never
    /// the window itself: a picture of a screen is not a document anybody
    /// asked for.
    var printTarget: PrintTarget? {
        if showingReports {
            guard reportPage == .profit, engine != nil, canShow(.reports),
                  lockAllows("analytics", "view") else { return nil }
            return .pnl
        }
        if let job = frontJob { return .invoice(job.id) }
        return nil
    }

    /// Print what is in front, through the system's print panel.
    func printFrontmost() async {
        moveProblem = nil
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        switch printTarget {
        case .invoice(let id):
            switch await invoiceDocument(for: id) {
            case .refused(let why):
                moveProblem = why
            case .paper(let doc, let number):
                let paper = InvoicePaper(document: doc)
                await paper.printWithPanel(title: number ?? id, over: window)
            }
        case .pnl:
            guard permitted("analytics", "view") else { return }
            let now = Date()
            guard let engine, let input = pnlInputs(now: now) else {
                moveProblem = words.callIt("pnl.custom_invalid"); return
            }
            do {
                let docs = try await pnlDocuments(engine: engine, input: input, now: now)
                await Self.pnlPaper(docs.html)
                    .printWithPanel(title: pnlFilename(.pdf, now: now), over: window)
            } catch {
                moveProblem = words.callIt("mac.export_failed") + " " + self.said(error)
            }
        case nil:
            return
        }
    }

    // MARK: - The invoice's paper, for every door onto it

    /// What `invoiceDocument` drew: the paper and the number it states, or
    /// why it may not be drawn.
    enum InvoiceBuild {
        case paper(InvoiceDocument, number: String?)
        case refused(String)
    }

    /// A job's invoice — or quotation — as the customer gets it.
    ///
    /// The one path the invoice sheet, ⌘P and Share all take, so none of them
    /// can print a tax invoice under a quote's number: an accepted quote is
    /// numbered first (`issueInvoiceNumberIfOwed`), and one still owed a
    /// number after that — this viewer could not give it one — is refused
    /// with the reason rather than drawn.
    func invoiceDocument(for id: Order.ID) async -> InvoiceBuild {
        guard orders.contains(where: { $0.id == id }) else {
            return .refused(words.callIt("mac.move_gone"))
        }
        await issueInvoiceNumberIfOwed(id)
        guard let job = orders.first(where: { $0.id == id }) else {
            return .refused(words.callIt("mac.move_gone"))
        }
        let number: String?
        switch await invoiceNumbering(of: orderRow(job.id) ?? .null) {
        case .notIssued:
            return .refused(words.callIt("mac.invoice_not_issued"))
        case .number(let n):
            number = n
        case nil:
            number = job.id
        }
        guard let doc = await Invoice.html(for: job, shop: self) else {
            return .refused(words.callIt("mac.no_document"))
        }
        return .paper(doc, number: number)
    }

    // MARK: - File ▸ Share…

    /// What Share would hand to the system's share sheet.
    enum ShareTarget: Equatable {
        /// A job's invoice, as the PDF the invoice sheet saves.
        case invoice(Order.ID)
        /// The selected library models' own files, where they are on this Mac.
        case models([URL])
    }

    var shareTarget: ShareTarget? {
        if showingLibrary {
            let urls = selectedFiles.compactMap(modelFile(for:))
            return urls.isEmpty ? nil : .models(urls)
        }
        if let job = frontJob { return .invoice(job.id) }
        return nil
    }

    /// Open the system's share picker on what is in front.
    func shareFrontmost() async {
        moveProblem = nil
        guard let target = shareTarget else { return }
        let items: [URL]
        switch target {
        case .models(let urls):
            items = urls
        case .invoice(let id):
            guard let url = await invoicePdfForSharing(id) else { return }
            items = [url]
        }
        Self.presentSharePicker(items)
    }

    /// The invoice as a PDF in a folder of its own under the temporary
    /// directory, named as the invoice sheet names it — the name is what the
    /// recipient sees.
    func invoicePdfForSharing(_ id: Order.ID) async -> URL? {
        switch await invoiceDocument(for: id) {
        case .refused(let why):
            moveProblem = why
            return nil
        case .paper(let doc, let number):
            let paper = InvoicePaper(document: doc)
            // A hang guard, not a speed limit: a PDF asked for before WebKit
            // has laid the page out is blank.
            for _ in 0..<6000 where !paper.drawn { try? await Task.sleep(for: .milliseconds(100)) }
            do {
                let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appending(path: "khayt-share-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let job = orders.first { $0.id == id }
                let url = dir.appending(path: InvoiceSheet.filename(job, words: words, number: number))
                try await paper.pdf().write(to: url, options: .atomic)
                Telemetry.feature(.invoiceExported, in: self)
                return url
            } catch {
                moveProblem = words.callIt("mac.export_failed") + " " + self.said(error)
                return nil
            }
        }
    }

    /// The picker is held until it closes: an `NSSharingServicePicker` nobody
    /// holds can be released while its menu is still on screen.
    @MainActor private static var picker: NSSharingServicePicker?

    static func presentSharePicker(_ items: [URL]) {
        guard !items.isEmpty, let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let view = window.contentView else { return }
        let picker = NSSharingServicePicker(items: items)
        Self.picker = picker
        // From the top of the window, under the title strip, centred — where
        // the toolbar's own share button would have put it.
        let anchor = NSRect(x: view.bounds.midX - 1, y: view.bounds.maxY - 44, width: 2, height: 2)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    // MARK: - Delete (⌫ and ⌘⌫), on the library

    /// The library's visible selection, when it may be deleted. Only models
    /// DRAWN AS TILES: `selectedFiles` is the selection narrowed to
    /// `visibleFiles`, so a model folded inside a group tile can never be in
    /// it — the 27 Sep 2026 loss was a delete that reached those.
    var librarySelectionToDelete: [LibraryFile] {
        guard showingLibrary, canMoveJobs, lockAllows("inventory", "delete") else { return [] }
        return selectedFiles
    }

    /// Ask to delete the library's visible selection.
    func askToDeleteLibrarySelection() {
        askToDelete(librarySelectionToDelete)
    }

    /// Exactly the right-click menu's Delete: one model goes to the single
    /// question with its plan, several to `askToDeleteFromLibrary`, which
    /// checks again that every one of them is on screen and names how many.
    /// A single model not on screen is refused the same way.
    func askToDelete(_ chosen: [LibraryFile]) {
        guard !chosen.isEmpty else { return }
        if chosen.count == 1 {
            let hidden = notOnScreen(chosen)
            guard hidden.isEmpty else {
                importProblem = words.counting(hidden.count, "mac.delete_not_on_screen")
                return
            }
            pendingLibraryDelete = chosen[0]
        } else {
            askToDeleteFromLibrary(chosen)
        }
    }

    // MARK: - File ▸ Duplicate (⌘D)

    enum DuplicateTarget: Equatable {
        case job(Order.ID)
        case product(String)
    }

    /// What ⌘D would copy: the selected job, or the selected catalogue
    /// product. Nil on a book this Mac may only read — a copy is a write.
    var duplicateTarget: DuplicateTarget? {
        guard canMoveJobs else { return nil }
        if let job = frontJob, lockAllows("orders", "create") { return .job(job.id) }
        if showingCatalogue, let id = catalogueSelection, lockAllows("inventory", "edit"),
           productRows.contains(where: { Self.recordId($0) == id }) {
            return .product(id)
        }
        return nil
    }

    func duplicateFrontmost() async {
        switch duplicateTarget {
        case .job(let id): await duplicateJob(id)
        case .product(let id): await duplicateProduct(id)
        case nil: return
        }
    }

    /// The fields of `lib/record-duplicate.js`'s job input the new-job sheet
    /// does not collect itself, and so carries through as they were.
    static let carriedOnDuplicate = ["notes", "internalNotes", "invoiceNotes", "clientRef",
                                     "currency", "productId", "components", "assemblyQty"]

    /// What the new-job sheet opens on for another of `row`. Nil without a
    /// runtime. Pure enough to test: the parts are costed through the same
    /// `jobParts` a product's are.
    func duplicateSeed(of row: JSONValue) async -> JobFromModel? {
        guard let engine, let input = try? await engine.duplicateJobInput(row) else { return nil }
        var parts: [JSONValue] = []
        if case .array(let rows)? = input["parts"] { parts = rows }
        var seed = JobFromModel(project: Self.plainString(input["project"]) ?? "",
                                parts: await jobParts(fromRows: parts),
                                margin: defaultMargin,
                                discountPct: Self.plainNumber(input["discountPct"]) ?? 0,
                                asQuote: input["asQuote"] == .bool(true))
        seed.clientId = Self.plainString(input["clientId"])
        seed.shippingCost = Self.plainNumber(input["shippingCost"]) ?? 0
        if case .array(let lines)? = input["extraLines"] {
            seed.extraLines = lines.compactMap(Self.extraLine(from:))
        }
        for key in Self.carriedOnDuplicate {
            if let value = input[key], value != .null { seed.carried[key] = value }
        }
        return seed
    }

    /// One extra charge, read back from a record.
    static func extraLine(from value: JSONValue) -> ExtraLine? {
        guard case .object(let o) = value else { return nil }
        var line = ExtraLine()
        line.label = plainString(o["label"]) ?? ""
        if let pct = plainNumber(o["pct"]) { line.pct = pct } else { line.amount = plainNumber(o["amount"]) ?? 0 }
        line.platformId = plainString(o["platformId"])
        line.fee = o["fee"] == .bool(true)
        return line.isWorthKeeping ? line : nil
    }

    /// Another of a job: the new-job sheet, filled in with the same customer,
    /// parts and notes. Nothing is written — and no invoice number taken —
    /// until the shop presses Save, and then `newOrder` gives it its own id
    /// and number, status and empty payments like any job.
    func duplicateJob(_ id: Order.ID) async {
        moveProblem = nil
        guard canMoveJobs else { moveProblem = words.callIt("mac.move_sample"); return }
        guard permitted("orders", "create") else { return }
        guard let row = orderRow(id), let seed = await duplicateSeed(of: row) else {
            moveProblem = words.callIt("mac.move_gone"); return
        }
        takeJob(seed)
    }

    /// Another of a catalogue product, under a new id, opened in the product
    /// sheet. Nothing is written until the sheet's Save.
    func duplicateProduct(_ id: String) async {
        moveProblem = nil
        guard canMoveJobs else { moveProblem = words.callIt("mac.move_sample"); return }
        guard permitted("inventory", "edit") else { return }
        guard let engine, let row = productRows.first(where: { Self.recordId($0) == id }),
              let made = try? await engine.duplicateProduct(
                row, id: Self.uid("PROD"), today: Self.localDay(),
                suffix: words.callIt("mac.copy_suffix")) else {
            moveProblem = words.callIt("mac.move_gone"); return
        }
        editingProduct = Product.from(made, keys: await allLanguageKeys())
    }

    // MARK: - A model file dropped on New Job

    /// The files a drop on the jobs list, or on the Dock icon, takes a job
    /// from. Machine files and the meshes this app can measure.
    static let droppableModelKinds: Set<String> = ["3mf", "stl", "obj", "gcode"]

    static func droppableModels(_ urls: [URL]) -> [URL] {
        urls.filter { $0.isFileURL && droppableModelKinds.contains($0.pathExtension.lowercased()) }
    }

    /// Open New Job on the dropped models — the library's "New job from
    /// model", after the models are in the library.
    ///
    /// INTO THE LIBRARY FIRST, because that is how the existing path works:
    /// `startJob(fromModels:)` takes library records, and a job made from a
    /// model is linked to the record (`printFileId`) so its actuals and
    /// estimates join up. The import KEEPS the original where it was dropped
    /// from — dropping a file on New Job is not asking for it to be moved. A
    /// model already in the library is found by its content, not imported
    /// twice.
    ///
    /// Returns whether the drop was taken.
    @discardableResult
    func newJob(fromDropped urls: [URL]) async -> Bool {
        moveProblem = nil
        let models = Self.droppableModels(urls)
        guard !models.isEmpty else { return false }
        guard canMoveJobs else { moveProblem = words.callIt("mac.move_sample"); return false }
        guard permitted("orders", "create") else { return false }
        // Hashed BEFORE the import: the content is what finds the record
        // afterwards, whether this drop added it or it was there already.
        var hashes: [String] = []
        for url in models {
            if let hash = await PinWork.run({ try? LibraryImport.contentHash(of: url) }) ?? nil {
                hashes.append(hash)
            }
        }
        let known = Set(files.compactMap(\.contentHash))
        if hashes.contains(where: { !known.contains($0) }) {
            await addModelsToLibrary(models, movesOriginals: false)
        }
        let chosen = hashes.compactMap { hash in files.first { $0.contentHash == hash } }
        guard !chosen.isEmpty else {
            if moveProblem == nil { moveProblem = importProblem ?? words.callIt("mac.calc_model_none") }
            return false
        }
        shelf = .jobs(nil)
        await startJob(fromModels: chosen, asQuote: false)
        return true
    }

    /// Files handed to the app by the Dock or the Finder ("Open With"),
    /// waiting for the window's shop to take them.
    @MainActor static var openedFiles: [URL] = [] {
        didSet {
            guard !openedFiles.isEmpty else { return }
            openedFilesArrived = Date()
            NotificationCenter.default.post(name: .khaytOpenedFiles, object: nil)
        }
    }

    /// When the newest of `openedFiles` arrived — see `Shop.isStale`.
    @MainActor static var openedFilesArrived = Date.distantPast

    /// Take whatever the Dock handed over, once a book is open. A drop from
    /// well before the taking window began is discarded rather than turned into
    /// a New Job nobody just asked for (`isStale`).
    func takeOpenedFiles(windowOpenedAt: Date? = nil) async {
        let urls = Self.openedFiles
        guard !urls.isEmpty, engine != nil, !needsSignIn else { return }
        Self.openedFiles = []
        guard !Self.isStale(arrivedAt: Self.openedFilesArrived, windowOpenedAt: windowOpenedAt) else { return }
        await newJob(fromDropped: urls)
    }
}

extension Notification.Name {
    /// Files arrived through `application(_:open:)` — see `Shop.openedFiles`.
    static let khaytOpenedFiles = Notification.Name("app.khayt.mac.openedFiles")
}
