import Foundation
import UniformTypeIdentifiers
import AppKit
import Observation
import KhaytCore

/// Everything on screen comes from here: one store, opened once, read only.
@MainActor @Observable
final class Shop {

    /// Where the book being shown comes from. Named on screen at all times —
    /// looking at the sample and thinking it is the shop's real position is the
    /// one mistake this app must not let anyone make.
    enum Source: Hashable, Identifiable {
        case sample
        case store(StoreReader.Build)

        var id: String {
            switch self {
            case .sample: "sample"
            case .store(let b): b.rawValue
            }
        }
        /// Which book this is, in the shop's own language.
        ///
        /// Takes the words rather than reading a global: this is an enum, and
        /// an enum that reaches for the interface language is one that cannot
        /// be tested without one.
        @MainActor func title(_ words: Words) -> String {
            switch self {
            case .sample: words.callIt("mac.book_sample")
            case .store(.development): words.callIt("mac.book_dev")
            case .store(.shipped): words.callIt("mac.book_khayt")
            }
        }
        var symbol: String {
            switch self {
            case .sample: "theatermasks"
            case .store: "internaldrive"
            }
        }
        var isReal: Bool { if case .store = self { true } else { false } }
        var build: StoreReader.Build? { if case .store(let b) = self { b } else { nil } }
    }

    private(set) var source: Source
    private(set) var orders: [Order] = []
    private(set) var files: [LibraryFile] = []

    /// Show the models that have been put aside. Off: they are still there.
    var libraryShowArchived = false

    /// How many are hidden right now, so the library can offer to show them
    /// rather than leave a shop wondering where a model went.
    var archivedCount: Int { files.count { $0.isArchived } }
    private(set) var machines: [Machine] = []
    private(set) var spools: [Spool] = []
    /// The shop's own record of its customers. Read from the `clients`
    /// collection, which this app did not open until it needed to point a new
    /// job at one.
    private(set) var clients: [Client] = []
    /// Wear per machine, keyed by id. `nozzleWear` answers for one machine at
    /// a time, so this is one call each — a handful of printers, not a table.
    private(set) var wear: [String: NozzleWear] = [:]

    /// The biggest bed on this floor, which every bed plan is drawn against.
    ///
    /// A minimum of one so the drawing cannot divide by zero on a book whose
    /// machines have no bed recorded, and it is the WIDEST and DEEPEST across
    /// the shop rather than one machine's — a laser 1300 wide and 900 deep and
    /// a flatbed 508 × 330 have different proportions, and comparing every card
    /// against a single rectangle is the only way the cards compare to
    /// each other.
    var widestBed: Double { max(machines.compactMap { $0.bed?.x }.max() ?? 1, 1) }
    var deepestBed: Double { max(machines.compactMap { $0.bed?.y }.max() ?? 1, 1) }
    /// Where this shop's models live. Resolved once per book, because it reads
    /// settings and probes the disk, and every cell asks about it.
    private(set) var libraryRoots: LibraryLocation.Roots?
    /// Who has this book open, when that is somebody else. Nil when nothing
    /// claims it — which is the ordinary case, and says nothing on screen.
    private(set) var owner: String?
    /// The dashboard, from the shared modules. Nil until the book has loaded,
    /// or when the engine could not start — the screen says so rather than
    /// showing zeros, which would be a statement about the shop.
    private(set) var facts: DashboardFacts?
    /// Invoices past their due date and still owing, and quotes about to run
    /// out. Chosen by `lib/payment-reminder.js` and `lib/quote-followup.js`,
    /// each of which the shop switches on in Settings.
    private(set) var invoicesToChase: [Chase] = []
    private(set) var quotesToChase: [Chase] = []
    /// This month's revenue, whatever period the tiles are showing.
    ///
    /// A SECOND `kpis` call, fixed to the month, because the goal is a monthly
    /// one — `dash.goal_hint` says so — and the tiles above it move with the
    /// period buttons. Reading the picker's answer would have shown a year's
    /// takings against a month's target the moment somebody pressed "This
    /// year".
    private(set) var thisMonthRevenue: Double = 0
    private var owedByOrderId: [String: Double] = [:]
    /// The period's figures, from the shared modules. Nil when the engine could
    /// not start; the screen then shows nothing rather than zeros.
    private(set) var kpis: Kpis?
    /// Which period those figures cover. `month` is what the Electron app's
    /// executive summary opens on.
    var kpiRange = "month" {
        didSet { Task { await recomputeKpis() } }
    }
    var attention: DashboardFacts.Attention? { facts?.attn }
    /// The ownership record this app holds, when the book was free to take.
    /// Nil means read-only: somebody else has it, or this is the sample.
    private(set) var ownership: StoreLock.Record?
    /// What this shop calls things. Loaded with the book, because the language
    /// is a property of the shop rather than of the Mac.
    let words = Words()
    private var heartbeat: Task<Void, Never>?

    /// May this app change anything? False for the sample, and false whenever
    /// the Electron app has the book.
    var canWrite: Bool { ownership != nil }
    /// The last refusal, for the screen to say out loud. A write that fails
    /// silently is worse than one that never ran.
    var writeProblem: String?
    private(set) var shopName = "Khayt"
    private(set) var currency = "SAR"
    private(set) var skipped: [String] = []
    private(set) var problem: String?
    /// Why the shared rules did not start, when they did not. Everything this
    /// app computes and every word it says comes through them, so a shop is
    /// told rather than shown a screen of keys.
    private(set) var engineProblem: String?
    private(set) var taxSummary: String?
    private(set) var settingsValue: JSONValue = .object([:])

    /// Put a shop into a mode, for a test. The book on disk is not touched.
    func pretendMode(_ mode: String?) {
        var held: [String: JSONValue] = settingsDict
        if let mode { held["mode"] = .string(mode) } else { held.removeValue(forKey: "mode") }
        settingsValue = .object(held)
    }

    var selection: Order.ID?
    var fileSelection: Set<LibraryFile.ID> = []
    /// The model the shop has asked to delete, until it confirms or backs out.
    /// A question in the window's `WindowSheets`, so both shells can ask it.
    var pendingLibraryDelete: LibraryFile?
    var customerSelection: Customer.ID?
    /// Which screen, and for the library which folder.
    ///
    /// Moving between them recounts the filter chips, because both bars count
    /// what is in front of the shop rather than what is in the book: opening a
    /// project of forty must not leave a chip promising the hundred behind it.
    /// Set from a dozen places — a click, a menu, a folder tile — so the recount
    /// is here rather than at each of them.
    var shelf: Shelf = .dashboard {
        didSet {
            guard shelf != oldValue else { return }
            if case .library = shelf { recountLibrarySoon() }
            else if case .library = oldValue { recountLibrarySoon() }
        }
    }
    /// Opens the way Khayt opens. See `LibrarySort`.
    var librarySort: LibrarySort = .khayt
    /// Typed into the search box. The chips count what the search leaves, so
    /// they follow it — the other app's catalogue does the same, and a chip
    /// saying seven over a searched list of two is the bug its note describes.
    var search = "" {
        didSet {
            guard search != oldValue else { return }
            if case .library = shelf { recountLibrarySoon() }
            if case .catalogue = shelf { recountCatalogueSoon() }
        }
    }

    /// Which shelf of the book is open. One selection rather than two, because
    /// "a stage is chosen" and "the library is showing" are not independent —
    /// holding them separately is how a screen ends up filtering jobs by a stage
    /// nobody can see.
    enum Shelf: Hashable {
        /// nil is every job.
        case jobs(Stage?)
        /// nil is every model; a string is one group.
        case library(String?)
        case customers
        case dashboard
        case machines
        case inventory
        case board
        case expenses
        case waste
        case reports
        case catalogue
        case colour
        case calculator
        case portfolio
        case giftCards

        /// Whether two shelves are the same SCREEN, ignoring which folder or
        /// which stage. The sidebar highlights Jobs while a stage is chosen
        /// and Library while a project is open — the row names the screen, not
        /// the filter on it.
        func sameScreen(as other: Shelf) -> Bool {
            switch (self, other) {
            case (.jobs, .jobs), (.library, .library): true
            default: self == other
            }
        }
    }

    var stage: Stage? { if case .jobs(let s) = shelf { s } else { nil } }
    var showingLibrary: Bool { if case .library = shelf { true } else { false } }
    var showingCustomers: Bool { shelf == .customers }
    var showingDashboard: Bool { shelf == .dashboard }
    var showingMachines: Bool { shelf == .machines }
    var showingInventory: Bool { shelf == .inventory }
    var showingCatalogue: Bool { shelf == .catalogue }
    var showingBoard: Bool { shelf == .board }
    var showingExpenses: Bool { shelf == .expenses }
    var showingWaste: Bool { shelf == .waste }
    var showingReports: Bool { shelf == .reports }
    var showingColour: Bool { shelf == .colour }
    var showingCalculator: Bool { shelf == .calculator }
    var showingPortfolio: Bool { shelf == .portfolio }
    var showingGiftCards: Bool { shelf == .giftCards }

    /// The open jobs, grouped by the stage they are in.
    ///
    /// Computed once per read rather than filtered per column: four passes over
    /// the book to draw four columns is three too many, and the board is the
    /// screen most likely to be left open all day.
    var board: [Stage: [Order]] {
        var out: [Stage: [Order]] = [:]
        // The search box is one box for the whole window. A board that ignored
        // it left somebody typing a customer's name into a field that visibly
        // did nothing.
        for order in matching(orders) {
            guard let stage = Stage.of(order) else { continue }
            out[stage, default: []].append(order)
        }
        for (stage, jobs) in out {
            // Urgent first, then by due date, then by what has been waiting
            // longest — the order someone would work through them in.
            out[stage] = jobs.sorted { a, b in
                if a.priority != b.priority { return a.priority }
                let da = Order.day(a.dueDate), db = Order.day(b.dueDate)
                if let da, let db, da != db { return da < db }
                if (da == nil) != (db == nil) { return da != nil }
                return (a.day ?? .distantPast) < (b.day ?? .distantPast)
            }
        }
        return out
    }

    /// The jobs that match what is typed in the search box, or all of them.
    ///
    /// Project, customer and job number — the three things somebody standing at
    /// the bench actually has to hand.
    func matching(_ rows: [Order]) -> [Order] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.project.lowercased().contains(q) || $0.client.lowercased().contains(q)
                || $0.id.lowercased().contains(q)
        }
    }

    /// Jobs the board has no column for.
    ///
    /// A `split` parent, or a status a later version of Khayt introduces. They
    /// are counted rather than dropped: the board's job is to show where the
    /// work is, and quietly leaving some of it out is the one thing it must not
    /// do.
    var unplaced: [Order] { matching(orders).filter { Stage.of($0) == nil } }

    /// The sources that can actually be opened on this Mac. A menu offering a
    /// store that is not there is a dead end dressed up as a choice.
    static var available: [Source] {
        // Most recently written first. Guessing between "khayt" and "Khayt" by
        // name means guessing whether this Mac belongs to a developer or a
        // shop; the file dates already know.
        let stores = StoreReader.Build.allCases
            .filter(\.exists)
            .sorted { ($0.lastWritten ?? .distantPast) > ($1.lastWritten ?? .distantPast) }
            .map(Source.store)
        return [.sample] + stores
    }

    /// The shared business logic, started once. Building a JSContext and
    /// loading eight modules takes a few milliseconds — trivial once, wasteful
    /// per row, and this is the object rows ask about money.
    /// The shared business logic. Not private: the invoice is assembled in
    /// `Invoice`, which needs to ask it the same questions the screens do.
    private(set) var engine: KhaytEngine?

    init(source: Source = .sample) {
        self.source = source
    }

    func load(_ next: Source) async {
        source = next
        problem = nil
        skipped = []
        do {
            let root: [String: JSONValue]
            switch next {
            case .sample:
                guard let url = AppResources.bundle.url(forResource: "sample-shop", withExtension: "json"),
                      let data = try? Data(contentsOf: url) else {
                    throw Failure.missingSample
                }
                root = try JSONDecoder().decode([String: JSONValue].self, from: data)
            case .store(let build):
                root = try StoreReader(build: build).raw
            }
            let decoded = try Self.decodeOrders(root)
            orders = decoded.items
            skipped = decoded.skipped
            machines = Self.decode(root, "machines", as: Machine.self)
            spools = Self.decode(root, "inventory", as: Spool.self)
            let library = Self.decodeFiles(root)
            files = library.items
            skipped += library.skipped
            libraryRoots = next.build.map { build in
                LibraryLocation.resolveRoots(settings: Self.librarySettings(root),
                                             defaultRoot: LibraryLocation.defaultRoot(for: build))
            }
            fileSelection = []
            // Read, never taken. This app does not write, and a reader that
            // claimed ownership would lock a shop out of its own app for
            // nothing. When writing arrives, this is the check that gates it.
            owner = next.build.flatMap { whoElseHasIt($0) }
            takeOwnership(of: next.build)
            if case .object(let settings)? = root["settings"],
               case .string(let c)? = settings["currency"] { currency = c }
            // THE ENGINE FAILING IS NOT A SILENT CONDITION.
            //
            // It was `try?`, so a bad module list left `engine` nil and every
            // screen carried on: no words (the catalogue is loaded through the
            // runtime, so every label rendered as its own key), no tax, no P&L,
            // no writes. Nothing said why. Bundling one module whose file name
            // did not match the global it assigns did exactly that, and it took
            // a photograph to notice.
            if engine == nil {
                do { engine = try KhaytEngine() }
                catch { engineProblem = String(describing: error) }
            }
            // `settings.lang` and not the system language: a Riyadh shop on an
            // English Mac still keeps its book in Arabic, and the book is what
            // this window shows. (The Electron app keeps the live choice in
            // localStorage, which nothing outside it can read — settings.lang is
            // the copy that travels with the store.)
            var wanted: String?
            if case .object(let settings)? = root["settings"], case .string(let l)? = settings["lang"] {
                wanted = l
            }
            // KHAYT_LANG forces a language for one run. There is no other way to
            // photograph the Arabic layout from a shop whose book is in English,
            // and a right-to-left screen that nobody has looked at is a
            // right-to-left screen that is wrong.
            if let forced = ProcessInfo.processInfo.environment["KHAYT_LANG"] { wanted = forced }
            await words.load(wanted, engine: engine)
            settingsValue = root["settings"] ?? .object([:])
            await readFeatures()
            // A shop that has just switched to Simple must not be left looking
            // at a screen that is no longer theirs.
            if shelf == .reports, !has("analytics") { shelf = .dashboard }
            if shelf == .expenses, !has("expenses") { shelf = .dashboard }
            lanBook = ["printLog": root["printLog"] ?? .array([]),
                       "waitingList": root["waitingList"] ?? .array([]),
                       "settings": root["settings"] ?? .object([:]),
                       "machines": root["machines"] ?? .array([])]
            await syncLanServer()
            // AFTER the words, because the name is read in the shop's language.
            // It is `bizEn`/`bizAr`, the fields Khayt's own Settings page
            // writes and every document prints — not `shopName`, which nothing
            // in Khayt writes. Read as `shopName` for six weeks, this shop's
            // invoice would have been issued by "Khayt".
            shopName = await Self.shopName(from: Self.settings(root), engine: engine,
                                           language: words.language) ?? next.title(words)
            if case .array(let shelf)? = root["inventory"] { inventoryRows = shelf } else { inventoryRows = [] }
            // The other shelf: glue, IPA, bags, nozzles. Read raw — the reorder
            // rule reads fields this app has no model for, and picking which of
            // them matter is a decision that belongs in the rule.
            if case .array(let bits)? = root["consumables"] {
                consumableRows = bits
            } else {
                consumableRows = []
            }
            // The calculator's saved printer presets — a name and the seven
            // figures a part is costed at. `lib/public-quote.js` builds a
            // customer's price from one of these, so a shop with none cannot
            // quote publicly at all.
            // Who the shop buys from, and what they quote. Read raw because the
            // price rule reads a supplier's whole price list, and picking which
            // of it matters belongs in the rule.
            if case .array(let sellers)? = root["suppliers"] {
                supplierRows = sellers
            } else {
                supplierRows = []
            }
            // What has been ordered and not yet arrived. Read raw for the same
            // reason the consumables are: the rule reads fields this app has no
            // model for, and deciding which of them matter belongs in the rule.
            if case .array(let ordered)? = root["purchaseOrders"] {
                purchaseOrderRows = ordered
            } else {
                purchaseOrderRows = []
            }
            // Orders priced per SPOOL where a per-gram rate was expected — a
            // thousand times the real amount. Report only, and this app could
            // not even say so until now.
            suspectOrders = (try? await engine?.suspectOrders(purchaseOrderRows,
                                                             inventory: inventoryRows)) ?? []
            if case .array(let saved)? = root["printers"] { presetRows = saved } else { presetRows = [] }
            // The print files as written. `files` above is the decoded model;
            // this is what the setups and versions rules read, which is a wider
            // set of fields than the model carries.
            if case .array(let library)? = root["printFiles"] {
                fileRows = library
            } else {
                fileRows = []
            }
            if case .array(let jobs)? = root["printLog"] { orderRows = jobs } else { orderRows = [] }
            if case .array(let people)? = root["clients"] { clientRows = people } else { clientRows = [] }
            if case .array(let catalog)? = root["products"] { productRows = catalog } else { productRows = [] }
            catalogueRows = (try? await engine?.catalogue(
                productRows, language: words.language, settings: Self.settings(root))) ?? []
            productCategories = Dictionary(uniqueKeysWithValues: productRows.compactMap { row in
                guard case .object(let p) = row, case .string(let id)? = p["id"] else { return nil }
                if case .string(let c)? = p["category"] { return (id, c) }
                return (id, "")
            })
            await readCatalogueFacets()
            catalogueLanguages = await Self.catalogueLanguages(Self.settings(root), engine: engine)
            if case .array(let fleet)? = root["machines"] { machineRows = fleet } else { machineRows = [] }
            // Recurring maintenance tasks, written by the Electron app's
            // machine editor. Read here, and written back only when someone
            // marks one done — the intervals themselves are still edited there.
            if case .array(let upkeep)? = root["machMaintTasks"] {
                maintTaskRows = upkeep
            } else {
                maintTaskRows = []
            }
            // The finished jobs the printers still remember. Written by Khayt
            // on a timer; read here, never written — this app does not poll
            // into the cache, so anything it wrote would be a guess overwriting
            // a measurement.
            printerCompletions = root["printerCompletions"] ?? .object([:])
            // What the shop has spent SERVICING its machines. `machMaintLog` is
            // the key the other app's store snapshot writes it under; it is
            // read here and nowhere else, by the machine P&L.
            //
            // A Mac alpha wrote this log under `hub_maint_log_v1` — that app's
            // localStorage key, not its store key — so those rows are read
            // here too, and moved on the next write. See
            // `ServiceLogEdit.rescueStranded`.
            var serviceLog: [JSONValue] = []
            if case .array(let serviced)? = root[ServiceLogEdit.collection] { serviceLog = serviced }
            rawHasStrandedLog = root[ServiceLogEdit.strandedCollection] != nil
            if case .array(let stranded)? = root[ServiceLogEdit.strandedCollection] {
                serviceLog += stranded
            }
            maintenanceRows = serviceLog
            // The shop's own saved messages. Written in the other app's
            // settings and, until now, readable only there — three of them on
            // this shop's book, in its own words.
            if case .array(let saved)? = root[MessageTemplate.collection] {
                messageTemplates = MessageTemplate.from(saved)
            } else { messageTemplates = [] }
            clients = Self.decodeClients(root)
            clientNames = (try? await engine?.customerNames(
                clientRows, language: words.language, settings: Self.settings(root))) ?? [:]
            await keepTheDaysBackup()
            expenses = Self.decode(root, "expenses", as: Expense.self)
            giftCards = Self.decode(root, "giftCards", as: GiftCard.self)
            fits = await Self.measureFit(files, machines: machineRows, engine: engine)
            // The setting first, then the summaries it governs. Re-judged on
            // every load rather than cached with the verdict, because the
            // nozzle and the plate come from the machines and those change.
            estimates = await Self.priceMeshes(files, settings: Self.settings(root),
                                               orders: orderRows, engine: engine)
            riskWhen = try? await engine?.riskWhen(settings: Self.settings(root))
            await rejudgeStoredRisks()
            lowSpools = (try? await engine?.lowStock(inventoryRows, settings: settingsDict)) ?? [:]
            spoolRunway = (try? await engine?.runway(spools: inventoryRows, orders: orderRows,
                                                     now: Date())) ?? [:]
            spoolDryness = (try? await engine?.dryness(spools: inventoryRows, now: Date())) ?? [:]
            timeline = await Self.project(orders: orders, engine: engine,
                                          settings: settingsDict)
            // Once per book rather than per right-click: the list is twenty-two
            // fixed entries and a context menu is built while a grid draws.
            printerProfiles = (try? await engine?.printerProfiles()) ?? []
            // What kind each machine is, resolved once per book. Read in view
            // bodies, so a hop into JavaScript per machine per redraw would be
            // a hop for a constant.
            machineKinds = (try? await engine?.machineKinds(machineRows)) ?? [:]
            // And what each shelf row is counted in. Same reason: read in view
            // bodies, and a constant per item per redraw is a hop for nothing.
            inventoryUnits = (try? await engine?.inventoryUnits(
                inventoryRows, settings: settingsDict)) ?? [:]
            // What each model's licence permits, asked once for the library:
            // the inspector shows it for the selected model and the grid does
            // not, so a hop per row would be a hop for nothing.
            var standings: [String: KhaytEngine.Standing] = [:]
            for file in files where !(file.licence ?? "").isEmpty || !(file.source ?? "").isEmpty {
                if let standing = try? await engine?.licenceStanding(source: file.source,
                                                                     licence: file.licence) {
                    standings[file.id] = standing
                }
            }
            licences = standings
            // The library's own chips, counted once per book for the same
            // reason as everything above it: the grid redraws on every
            // keystroke in the search box, and a hop into JavaScript per chip
            // per redraw is a hop for a constant.
            if case .array(let rows)? = root["printFiles"] { libraryRows = rows } else { libraryRows = [] }
            await readLibraryFacets()
            // And the names those chips can be filed under, which is the whole
            // book rather than what the chips are currently counting.
            await readLibraryNames()
            // The status of each, from the shared rule rather than a Swift
            // comparison of two date strings — asked once for all of them,
            // because the table redraws on every keystroke in the search box.
            giftCardRows = (root["giftCards"].flatMap { if case .array(let r) = $0 { r } else { nil } }) ?? []
            // The points ledger travels with them: store credit IS a gift card
            // here, and a card issued without its ledger row is points spent
            // twice.
            loyaltyRows = (root["loyaltyLedger"].flatMap { if case .array(let r) = $0 { r } else { nil } }) ?? []
            // Money an old defect took off the book. Asked once per load: the
            // answer changes only when the book does, and the list is walked
            // by a banner that draws on every screen.
            erasedDeposits = (try? await engine?.erasedDeposits(orders: orderRows)) ?? []

            // AFTER `orderRows`, and that is not tidiness. The rate a
            // reorder figure is built from comes from the jobs, so asking
            // this before the book's orders are read answers from an empty
            // one: the shelf offered a different count on the first load
            // than on the second, and the first was the wrong one.
            // What is low AND not already coming. The dedupe is why this is
            // asked of the rule rather than counted off the low badges: two of
            // three low things may already be on their way, and offering to
            // order them again is how a shelf ends up with four kilos of
            // something a shop uses twice a year.
            needsOrdering = (try? await engine?.needsOrdering(
                spools: inventoryRows, consumables: consumableRows, orders: orderRows,
                purchaseOrders: purchaseOrderRows, settings: settingsDict,
                now: Date())) ?? []
            // What one plate holds, from the packer rather than from a number
            // typed twice in Swift.
            if let limits = try? await engine?.plateDefaults() {
                batchMaxHours = limits.maxHours
                batchMaxGrams = limits.maxGrams
            }
            giftCardStatuses = (try? await engine?.giftCardStatuses(
                giftCardRows, today: Self.today())) ?? [:]
            wasteLog = Self.decode(root, "wasteLog", as: WasteEntry.self)
            if case .array(let rows)? = root["expenses"] { expenseRows = rows } else { expenseRows = [] }
            if case .array(let rows)? = root["wasteLog"] { wasteRows = rows } else { wasteRows = [] }
            readSnapshots(root)
            // AFTER `orderRows` is read, which it groups. A kit is several
            // print-log entries that are one physical object, and the rollup
            // is asked for here rather than in the view so that a table
            // redrawing on every keystroke does not cross into JavaScript.
            await readKits(root)
            // Whether the shop has agreed to the assistant drafting a quote.
            // Asked of the shared rule — it reads the master switch, the
            // per-feature answer AND the consent migration, and a Swift copy
            // would be a fourth place for those three to disagree on the one
            // question that decides whether data leaves the building.
            let aiFeatures = (try? await engine?.aiFeatures(settings: Self.settings(root))) ?? []
            aiQuoteAllowed = aiFeatures.first { $0.id == "quote" }?.enabled ?? false
            aiAssistantAllowed = aiFeatures.first { $0.id == "assistant" }?.enabled ?? false
            aiReplyAllowed = aiFeatures.first { $0.id == "reply" }?.enabled ?? false
            aiPriceAllowed = aiFeatures.first { $0.id == "price" }?.enabled ?? false
            taxSummary = await describeTax(root["settings"])
            await readSettingsTables(root)
            // What each job still owes is `order-money`'s answer, not a
            // subtraction — a credit note and a gift card both pay an order
            // down, and the title bar, the customers table and the card all
            // read this number. AFTER the settings tables: the rule resolves an
            // order's currency against them, and a book whose rows had not been
            // read yet would price a foreign job against the previous shop's.
            await resolveOwed(root)
            await computeDashboard(root)
            // Ask the machines what they are doing — but never for the sample
            // shop, whose printers are somebody else's addresses on somebody
            // else's network.
            printers.source = next.build
            if next.build != nil {
                printers.start(shop: self)
                cameras.start(shop: self)
            } else {
                printers.stop()
                // AND THE SAMPLE HAS NO CAMERAS. Its machines carry no webcam,
                // and pointing a fetch at one that is not there would be five
                // failed requests every few seconds for a book that is only
                // being looked at.
                cameras.stop()
            }
            // The shop's published delivery dates. Not for the sample book,
            // whose cloud settings belong to nobody.
            if next.build != nil { startPublishingLeadTime() } else { stopPublishingLeadTime() }
            refreshSyncStatus()
            // Move a service log a Mac alpha wrote under the wrong key. Inside
            // the write chain, because anything that reads and writes the store
            // outside it races whatever is in flight — and only for a real
            // book, which is the only kind that can have one.
            rescueStrandedServiceLog(next.build)
            await readSlicers()
            remeasureIfDue()
            createRecurringIfDue()
            // The library, in this Mac's own search. Compares before it works,
            // so a book that reloads unchanged costs one string comparison —
            // and takes the library back OUT when the sample is opened.
            Spotlight.shared.reindex(shop: self)
            // A model chosen in Spotlight before the book was open.
            answerPendingReveal()
        } catch {
            orders = []
            files = []
            // A book that would not open must not stay findable.
            Spotlight.shared.forget()
            libraryRows = []
            libraryFacets = LibraryFacets()
            categoriesInUse = []
            tagsInUse = []
            machines = []
            spools = []
            messageTemplates = []
            wear = [:]
            libraryRoots = nil
            owner = nil
            facts = nil
            printers.stop()
            problem = String(describing: error)
        }
    }

    /// Recompute just the fleet tile, when the printers have answered.
    ///
    /// Not the whole dashboard: `computeDashboard` walks every machine's nozzle
    /// wear, and doing that every ten seconds to move one tile from 0/1 to 1/1
    /// would be paying for the wrong thing.
    func printersAnswered() async {
        guard let engine, !machineRows.isEmpty else { return }
        facts = try? await engine.dashboardFacts(orders: orderRows, machines: machineRows,
                                                 settings: kpiSettings.isEmpty ? settingsDict : kpiSettings,
                                                 statusCache: printers.statusCache,
                                                 inventory: inventoryRows)
    }

    /// Ask the shared rule what every job still owes, and put it on the rows.
    ///
    /// One crossing for the whole book rather than one per row: `orderOwedBase`
    /// is cheap, the bridge is not, and a table of hundreds of jobs would pay
    /// for it on every redraw otherwise.
    private func resolveOwed(_ root: [String: JSONValue]) async {
        guard let engine else { return }
        let rows: [JSONValue]
        if case .array(let jobs)? = root["printLog"] { rows = jobs } else { rows = [] }
        let clients: [JSONValue]
        if case .array(let people)? = root["clients"] { clients = people } else { clients = [] }
        guard let owed = try? await engine.owedByOrder(
            rows, settings: Self.settings(root), clients: clients,
            currencies: Invoice.currencyTable(self)) else { return }
        for i in orders.indices {
            if let amount = owed[orders[i].id] { orders[i].owedResolved = amount }
        }
        // Kept whole, not just on the rows: `payment-reminder` asks what each
        // order still owes, converted, and this is the converted answer.
        owedByOrderId = owed
        await resolveLate(root)
    }

    /// Ask the attention engine which jobs are late, and put it on the rows.
    ///
    /// The same answer the dashboard's Late tile already showed, so the badges
    /// and the count stop being two numbers about one book.
    private func resolveLate(_ root: [String: JSONValue]) async {
        guard let engine else { return }
        let rows: [JSONValue]
        if case .array(let jobs)? = root["printLog"] { rows = jobs } else { rows = [] }
        let fleet: [JSONValue]
        if case .array(let m)? = root["machines"] { fleet = m } else { fleet = [] }
        guard let late = try? await engine.lateOrders(
            rows, machines: fleet, settings: Self.settings(root)) else { return }
        for i in orders.indices { orders[i].isLateResolved = late.contains(orders[i].id) }
    }

    /// One call per load, not one per tile. Building the arguments means
    /// crossing the bridge with every order, which is cheap once and absurd
    /// four times over for four figures on one screen.
    private func computeDashboard(_ root: [String: JSONValue]) async {
        guard let engine else { facts = nil; return }
        let orders: [JSONValue]
        if case .array(let rows)? = root["printLog"] { orders = rows } else { orders = [] }
        let machines: [JSONValue]
        if case .array(let rows)? = root["machines"] { machines = rows } else { machines = [] }
        let clients: [JSONValue]
        if case .array(let rows)? = root["clients"] { clients = rows } else { clients = [] }
        var settings: [String: JSONValue] = [:]
        if case .object(let dict)? = root["settings"] { settings = dict }
        // The shelf goes in with everything else: a spool about to stop the
        // next job is a thing the operator must act on, and until now it was
        // the only one of those with a rule, a screen, and no place on the one
        // screen a shop leaves open.
        var shelf: [JSONValue] = []
        if case .array(let rows)? = root["inventory"] { shelf = rows }
        // The P&L charges expenses against the period, so they go in with the
        // orders rather than being left out and the figure quietly overstated.
        var expenses: [JSONValue] = []
        if case .array(let rows)? = root["expenses"] { expenses = rows }
        facts = try? await engine.dashboardFacts(orders: orders, machines: machines, settings: settings,
                                                 statusCache: printers.statusCache,
                                                 inventory: shelf)
        // ── THE MONTH'S NET, FROM THE RULE REPORTS USES ───────────────────
        //
        // Through `pnlByPeriod` at month granularity rather than a sum taken
        // here. That is the whole reason it can be shown at all: the objection
        // to a net figure on this screen was that net-of-tax depends on
        // whether the shop prices tax-inclusive, and a figure divided by a VAT
        // rate that may not apply is the subtly-wrong number. The shared rule
        // is given the settings and answers that question itself, so this
        // figure and the one in Reports are the same arithmetic on the same
        // inputs and cannot drift apart.
        //
        // One more crossing per LOAD, beside the several already here — not
        // per redraw.
        monthNetRevenue = await Self.thisMonthsNet(
            engine: engine, orders: orders, expenses: expenses,
            settings: settings, clients: clients, currencies: Invoice.currencyTable(self))
        var perMachine: [String: NozzleWear] = [:]
        for machine in machines {
            guard case .object(let record) = machine,
                  case .string(let id)? = record["id"] else { continue }
            if let w = try? await engine.nozzleWear(orders: orders, machine: machine, settings: settings) {
                perMachine[id] = w
            }
        }
        wear = perMachine
        // What to chase. Both selectors are off unless the shop has switched
        // them on, and both return nothing on a book with no due dates — so
        // the section they feed simply does not appear.
        invoicesToChase = (try? await engine.invoicesToChase(
            orders: orders, settings: settings, owed: owedByOrderId)) ?? []
        quotesToChase = (try? await engine.quotesToChase(
            orders: orders, settings: settings)) ?? []
        thisMonthRevenue = (try? await engine.kpis(orders: orders, clients: clients,
                                                   settings: settings, range: "month",
                                                   language: words.language))?.revenue ?? 0
        kpiOrders = orders
        kpiClients = clients
        kpiSettings = settings
        await recomputeKpis()
        // Six whole months and what the next one looks like. Not part of
        // `recomputeKpis`: that one changes with the period buttons, and the
        // trend deliberately does not — it is the same six months whichever
        // period the tiles above are showing.
        outlook = try? await engine.revenueOutlook(orders: orders, clients: clients,
                                                   settings: settings,
                                                   now: Date().timeIntervalSince1970 * 1000)
    }

    /// The shop's last six months of takings, and next month on that evidence.
    private(set) var outlook: KhaytEngine.RevenueOutlook?

    private var kpiOrders: [JSONValue] = []
    private var kpiClients: [JSONValue] = []
    private var kpiSettings: [String: JSONValue] = [:]

    /// One call for the whole period. Changing the range does not re-read the
    /// book — the orders are already here; only the arithmetic changes.
    private func recomputeKpis() async {
        guard let engine, !kpiOrders.isEmpty else { kpis = nil; return }
        kpis = try? await engine.kpis(orders: kpiOrders, clients: kpiClients,
                                      settings: kpiSettings, range: kpiRange,
                                      language: words.language)
    }

    enum Failure: Error { case missingSample }

    /// Claim the book if nothing else has it.
    ///
    /// Symmetrical with Electron's own claim, and deliberately weaker: Electron
    /// takes ownership whatever it finds, because refusing to open a shop's own
    /// app is worse than the collision. This app defers — it is the newcomer,
    /// and it has somewhere to fall back to, which is reading.
    private func takeOwnership(of build: StoreReader.Build?) {
        heartbeat?.cancel()
        heartbeat = nil
        StoreLock.release(ownership, for: previousBuild)
        ownership = nil
        previousBuild = build
        guard let build else { return }
        guard let record = StoreLock.take(for: build) else { return }
        ownership = record
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, let held = self.ownership else { return }
                self.ownership = StoreLock.beat(held, for: build)
            }
        }
    }

    private var previousBuild: StoreReader.Build?

    /// Hand the book back on the way out. A crash skips this and leaves a record
    /// whose pid is dead, which the next reader resolves on its own.
    func relinquish() {
        heartbeat?.cancel()
        heartbeat = nil
        StoreLock.release(ownership, for: previousBuild)
        ownership = nil
    }

    // MARK: - Changing something

    // MARK: - What the menus ask for

    /// The menu bar acts on the selection, not on a row it was handed. These
    /// are the same actions the context menu and the inspector use, named once
    /// so the two can never drift into meaning different things.
    func reload() { Task { await load(source) } }

    // MARK: - Measuring the library again

    /// Which books this process has already checked. Once per book per launch:
    /// the pass reads every due 3MF and marks it, so the next launch finds
    /// nothing due — and a book whose write was refused is simply due again.
    private var remeasuredBooks: Set<String> = []
    /// The pass in flight, so a quit — or a test — can wait for it.
    private(set) var remeasuring: Task<Void, Never>?

    /// Reads again the 3MFs an older reader measured, and rewrites the keys
    /// that come out different. The rule and the reasons are on `Remeasure`;
    /// this is the wiring: after the book loads, off the main thread at a
    /// priority below the screen's, one write at the end, and a note when a
    /// number the shop was shown has changed. Nothing for the sample book,
    /// whose files are nobody's.
    func remeasureIfDue() {
        guard case .store(let build) = source, let roots = libraryRoots, let engine,
              !remeasuredBooks.contains(build.rawValue) else { return }
        remeasuredBooks.insert(build.rawValue)
        let files = self.files
        let vault = URL(fileURLWithPath: roots.primary)
        remeasuring = Task { [weak self] in
            let due = await Remeasure.due(files, engine: engine)
            guard !due.isEmpty else { return }
            let report = await Task.detached(priority: .utility) {
                await Remeasure.measure(due, vault: vault, engine: engine)
            }.value
            guard !report.measured.isEmpty, let self else { return }
            await self.recordRemeasure(report, build: build, engine: engine)
        }
    }

    private func recordRemeasure(_ report: Remeasure.Report, build: StoreReader.Build,
                                 engine: KhaytEngine) async {
        guard let reader = try? await engine.geometryReader() else { return }
        do {
            try StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                Remeasure.apply(report, reader: reader, to: &root)
            }
        } catch {
            // Somebody else has the book, or the disk refused: nothing was
            // marked, so the same files are due at the next launch.
            return
        }
        guard !report.changed.isEmpty else { return }
        await load(source)
        importNote = words.callIt("mac.remeasured", ["n": .number(Double(report.changed.count))])
    }

    // MARK: - Standing orders

    /// The books whose standing orders this launch has already made.
    private var recurringBooks: Set<String> = []

    /// Make today's standing orders, once per book per launch.
    ///
    /// The other app does this at boot and every six hours; this one does it
    /// when the book opens, which for a shop is once a morning. The rule is
    /// idempotent — a cycle that already has its job asks for nothing — so a
    /// Mac and a PC opening the same book both run it and one job results.
    /// Nothing for the sample book, and nothing while another app owns the
    /// book: the same jobs are due at the next launch.
    func createRecurringIfDue() {
        guard case .store(let build) = source, let engine,
              !recurringBooks.contains(build.rawValue) else { return }
        recurringBooks.insert(build.rawValue)
        Task { [weak self] in
            guard let self else { return }
            var created: [String] = []
            do {
                try await StoreWriter.update(
                    storeURL: build.storeURL,
                    owns: { StoreLock.weOwnIt(build) },
                    whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
                ) { root in
                    let outcome = try await RecurringOrders.run(&root, engine: engine)
                    guard outcome.changed else { throw RecurringOrders.NothingDue() }
                    created = outcome.created
                }
            } catch {
                return
            }
            await load(source)
            if !created.isEmpty {
                importNote = words.callIt("rec.created", ["n": .number(Double(created.count))])
            }
        }
    }

    /// One cycle on from a day, by the shared rule. Nil with no engine.
    func nextCycle(after day: String, interval: String) async -> String? {
        guard let engine else { return nil }
        return try? await engine.nextCycle(after: day, interval: interval)
    }

    // MARK: - A customer's communications log

    /// Write a line in a customer's log NOW, not on Save.
    ///
    /// A note about a phone call is a fact the moment the call ends, and the
    /// other app writes it to the record straight away for the same reason —
    /// so that closing the sheet with the × does not lose it. Only the log is
    /// touched: the rest of the record stays as it is on disk, whatever a
    /// sheet somewhere else is holding.
    func addCommunication(_ entry: CommEntry, to clientId: String) async {
        moveProblem = nil
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        do {
            try StoreWriter.updateRecord(build, collection: "clients", id: clientId) { record in
                var log: [JSONValue] = []
                if case .array(let had)? = record["commLog"] { log = had }
                log.append(.object(entry.raw))
                // Khayt keeps two hundred. The NEWEST two hundred: the other
                // app's editor appended and then cut the tail, which threw
                // away the note just written the moment the log was full.
                if log.count > 200 { log = Array(log.suffix(200)) }
                record["commLog"] = .array(log)
            }
            await load(source)
        } catch {
            moveProblem = String(describing: error)
        }
    }

    /// Take one line out of a customer's log. The FIRST line equal to it: two
    /// identical quick notes are two lines, and deleting one deletes one.
    func removeCommunication(_ entry: CommEntry, from clientId: String) async {
        moveProblem = nil
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        do {
            try StoreWriter.updateRecord(build, collection: "clients", id: clientId) { record in
                guard case .array(var log)? = record["commLog"],
                      let at = log.firstIndex(of: .object(entry.raw)) else { return }
                log.remove(at: at)
                record["commLog"] = .array(log)
            }
            await load(source)
        } catch {
            moveProblem = String(describing: error)
        }
    }

    // MARK: - What a customer has agreed to pay

    /// The agreed price for each named part, or nil. Empty answers — no
    /// customer, no record, no agreements, no engine — are all "nothing
    /// applies", so a caller never has to tell them apart.
    func agreedPrices(for names: [String], clientId: String?) async -> [Double?] {
        let none = names.map { _ in Double?.none }
        guard let clientId, let engine,
              let client = clients.first(where: { $0.id == clientId }),
              !client.priceList.isEmpty else { return none }
        let list = client.priceList.map { JSONValue.object($0.raw) }
        return (try? await engine.agreedPrices(names: names, priceList: list)) ?? none
    }

    func open(_ next: Source) { Task { await load(next) } }

    var canEditSelection: Bool { canWrite && !fileSelection.isEmpty }

    var selectionIsOnThisMac: Bool {
        guard let one = selectedFile else { return false }
        return modelFile(for: one) != nil
    }

    func toggleFavouriteOnSelection() {
        guard let one = selectedFile else { return }
        toggleFavourite(one)
    }

    func revealSelection() {
        guard let one = selectedFile, let url = modelFile(for: one) else { return }
        FileActions.reveal(url)
    }

    func openSelection() {
        guard let one = selectedFile, let url = modelFile(for: one) else { return }
        FileActions.open(url)
    }

    /// The model the window is showing a Quick Look of, or nil.
    ///
    /// Set it and the panel opens; Quick Look puts it back to nil when the
    /// panel is dismissed, which is why this is a plain var rather than
    /// something with a close method.
    var previewing: URL?

    /// Space in the library, and ⌘Y in the menu — Finder's own two gestures.
    ///
    /// A print-file library where you cannot look at the file without launching
    /// a slicer is a filing cabinet. This costs nothing: macOS already knows how
    /// to draw an STL, an OBJ, a USDZ and a PDF, and for anything it does not it
    /// shows the file's own icon and details rather than failing.
    func quickLookSelection() {
        guard let one = selectedFile, let url = modelFile(for: one) else { return }
        quickLook(url)
    }

    /// Show one file in Quick Look.
    ///
    /// ── A SECOND QUICK LOOK USED TO TAKE THE APP WITH IT ──────────────────
    ///
    /// Silently: no crash report from macOS, no `last-crash.txt`, nothing on
    /// stderr, and not even an orderly `terminate:` in the log. The app was
    /// simply gone, which reads to the person using it as a crash and leaves
    /// nothing at all to look at.
    ///
    /// What the log shows, three reproductions running:
    ///
    ///     [PlugInKit:lifecycle] all extension sessions ended     <- dismissed
    ///     (AppKit) perform action for menu item                  <- second ⌘Y
    ///     [quicklook] QLPreviewPanel called while the panel has no controller
    ///
    /// `.quickLookPreview` does NOT put its binding back to nil when the panel
    /// is dismissed. So `previewing` still held the first file, and the next
    /// selection was a url → url change rather than a fresh one.
    ///
    /// THAT TRANSITION IS THE FATAL PART, not the warning above it. The
    /// "no controller" line is still logged after this fix — nineteen times
    /// across fifteen Quick Looks in the run that proved it, with the app
    /// staying up throughout. So it is a symptom that appears either way, and
    /// a comment blaming it would send the next person after the wrong thing.
    /// What changed is only the shape of the binding change.
    ///
    /// Clearing it first makes every Quick Look a fresh nil → url, which is
    /// the only transition the modifier is reliable for. The set is deferred to
    /// the next turn of the main loop because both halves inside one update are
    /// coalesced into no change at all.
    ///
    /// BOTH CALLERS COME THROUGH HERE. The menu's ⌘Y and the file row's
    /// context menu each used to assign `previewing` themselves, so a fix in
    /// one would have left the other still doing it.
    func quickLook(_ url: URL) {
        guard previewing != nil else { previewing = url; return }
        previewing = nil
        Task { @MainActor in self.previewing = url }
    }

    /// Mark a model a favourite, or stop. The first thing this app ever wrote.
    func toggleFavourite(_ file: LibraryFile) {
        let wanted = !file.isFavourite
        editFiles([file.id],
                  named: words.callIt(wanted ? "mac.add_to_favourites" : "mac.remove_from_favourites")) { record in
            record["favorite"] = .bool(wanted)
        }
    }

    /// File every selected model under one name, or clear it.
    ///
    /// One write for the whole selection, not one per model. Seven kings filed
    /// one at a time is seven read-modify-writes, seven `.prev` generations, and
    /// six windows in which a crash leaves the collection half made.
    func fileSelection(under name: String) async {
        guard !fileSelection.isEmpty else { return }
        let ids = fileSelection
        // Through the engine, so a name matching one the shop already uses
        // adopts that spelling rather than becoming a second chip holding part
        // of the same collection.
        guard let engine, let patch = try? await engine.fileUnderGroup(name, known: groups) else {
            writeProblem = words.callIt("mac.group_unknown")
            return
        }
        let named = name.isEmpty
            ? words.callIt("mac.remove_from_group")
            : words.callIt("mac.file_in", ["name": .string(name)])
        editFiles(ids, named: named) { record in
            for (key, value) in patch { record[key] = value }
        }
    }

    /// The Mac's undo stack, handed over by the window.
    ///
    /// Weak: it belongs to the window, and a Shop outliving one must not keep
    /// it alive. Nil is a supported state — the environment says so when a
    /// context has no undo — and every registration below is guarded.
    weak var undoManager: UndoManager?

    /// Change some print files, and be able to put them back.
    ///
    /// The Edit menu has always shown Undo and Redo; until now they did
    /// nothing, which is worse than their being absent — a menu item that is
    /// enabled and inert teaches people not to trust the menu.
    ///
    /// What is captured is the WHOLE record as it was, not the fields about to
    /// change. An undo then restores everything, including a field some later
    /// version of this method starts touching and forgets to snapshot.
    ///
    /// What is NOT restored is `rev`. An undo is an edit like any other: it
    /// stamps a new revision, because a record that went backwards would look
    /// to the next sync like the change never happened and the other machine's
    /// copy would win.
    private func editFiles(_ ids: Set<LibraryFile.ID>, named actionName: String,
                           change: @escaping (inout [String: JSONValue]) -> Void) {
        guard let build = source.build, !ids.isEmpty else { return }
        var before: [String: [String: JSONValue]] = [:]
        do {
            try StoreWriter.update(build) { root in
                guard case .array(var rows)? = root["printFiles"] else { return }
                for i in rows.indices {
                    guard case .object(var record) = rows[i],
                          case .string(let id)? = record["id"], ids.contains(id) else { continue }
                    before[id] = record
                    change(&record)
                    StoreWriter.stamp(&record)
                    rows[i] = .object(record)
                }
                root["printFiles"] = .array(rows)
            }
            writeProblem = nil
            registerUndo(of: before, named: actionName)
            Task { await load(source) }
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// Put those records back exactly as they were, and make THAT undoable too.
    private func registerUndo(of before: [String: [String: JSONValue]], named actionName: String) {
        guard let undoManager, !before.isEmpty else { return }
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: self) { shop in
            shop.restore(before, named: actionName)
        }
    }

    private func restore(_ snapshot: [String: [String: JSONValue]], named actionName: String) {
        guard let build = source.build else { return }
        var before: [String: [String: JSONValue]] = [:]
        do {
            try StoreWriter.update(build) { root in
                guard case .array(var rows)? = root["printFiles"] else { return }
                for i in rows.indices {
                    guard case .object(let current) = rows[i],
                          case .string(let id)? = current["id"],
                          let wanted = snapshot[id] else { continue }
                    before[id] = current
                    rows[i] = .object(StoreWriter.restoring(wanted, over: current))
                }
                root["printFiles"] = .array(rows)
            }
            writeProblem = nil
            registerUndo(of: before, named: actionName)
            Task { await load(source) }
        } catch {
            // An undo that cannot be applied — the book changed hands while the
            // menu was open — must say so rather than fail quietly.
            writeProblem = String(describing: error)
        }
    }


    // MARK: - Moving a job

    /// The job waiting for someone to say why it is being held.
    ///
    /// A hold is the one move that asks a question first. The answer is
    /// optional — a shop that just needs the job out of the way should not have
    /// to invent a reason — but the question is worth asking, because "waiting
    /// on filament" three weeks later is the difference between a record and a
    /// gap.
    var pendingHold: PendingHold?

    /// The job waiting for someone to say what went wrong.
    var pendingQcFail: PendingHold?

    /// The failure categories, from `lib/qc-failure.js`. A category not on this
    /// list reaches the waste screen as a value it cannot name.
    static let failureTypes = ["bed_adhesion", "nozzle_jam", "warping", "stringing",
                               "operator_error", "design_issue", "power_failure",
                               "material_quality", "other"]

    /// Record a QC failure and send the job back to be printed again.
    ///
    /// THREE RECORDS, ONE SWAP: the fields on the order that the metrics count,
    /// the defect the analytics table is built from, and the waste row. A book
    /// where the job says it failed and the waste log has never heard of it is
    /// a shop whose scrap costs are quietly understated.
    func recordQcFailure(_ id: Order.ID, failureType: String, reason: String,
                         weight: Double) async {
        moveProblem = nil
        moveNotices = []
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            moveProblem = words.callIt("mac.move_no_engine"); return
        }

        var undo: [ChangedRecord] = []
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let orders = Self.rows(root, "printLog")
                guard let target = orders.first(where: { Self.recordId($0) == id }) else {
                    throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                }
                let shelfBefore = Self.rows(root, "inventory")
                let out = try await engine.recordQcFailure(
                    order: target, failureType: failureType, severity: "major",
                    reason: reason, weight: weight, inspector: nil,
                    inventory: shelfBefore, now: Date(),
                    wasteId: Self.uid("WASTE"),
                    defaultReason: self.words.callIt("ord.qc_fail"),
                    settings: Self.settings(root), machines: Self.rows(root, "machines"),
                    today: Self.today())

                Self.write(&root, "printLog", changed: [out.order], before: orders, into: &undo)

                // Newest first, the way the waste screen reads it. A new row is
                // not an edit to an existing one, so nothing is stamped.
                var waste = Self.rows(root, "wasteLog")
                waste.insert(out.waste, at: 0)
                root["wasteLog"] = .array(waste)

                // THE SHELF, in the same swap. A failed print takes its
                // filament off the spools it was printing from — a book saying
                // a print failed and wasted 200g while the spool still holds
                // them has told the shop it has filament it has already burned.
                // Only the spools it actually touched are stamped, and they go
                // into the undo so putting the failure back puts the grams back.
                Self.write(&root, "inventory", changed: out.inventory,
                           before: shelfBefore, into: &undo)
            }
            registerMoveUndo(undo, named: words.callIt("ord.qc_fail"))
            await load(source)
            // Back to be printed again — the move Khayt and Bed Ready both make
            // after a failure, and it carries its own gate and effects.
            await moveJob(id, to: .pending)
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch {
            moveProblem = String(describing: error)
        }
    }

    /// The job waiting for someone to say it passed inspection.
    ///
    /// A job leaving QC for completed is an INSPECTION, and `qcStatusOf` reads
    /// the record off the order. A completion that skipped it is not counted as
    /// failed — it is not counted at all, so the shop's pass rate would be
    /// quietly computed over a shrinking subset of its work.
    var pendingQC: PendingHold?

    /// A job being finished, what it was quoted at, and what — if anything —
    /// the printer said it actually took.
    /// A window a machine is out of action for.
    ///
    /// `from` and `to` are `YYYY-MM-DDTHH:mm` local wall-clock, the shape
    /// Khayt's own `datetime-local` field writes — see `DowntimeEditor` for why
    /// both apps must write the same one.
    struct DowntimeBlock: Identifiable, Equatable, Hashable {
        var from: String
        var to: String
        var reason: String
        var id: String { from + "|" + to + "|" + reason }

        /// Does this window run forwards? The shared rule DROPS one that does
        /// not, so a sheet that cannot say so lets a shop type something and
        /// find nothing saved.
        var isReadable: Bool {
            guard let a = DowntimeEditor.parse(from), let z = DowntimeEditor.parse(to) else { return false }
            return z > a
        }
    }

    struct PendingCompletion: Identifiable, Equatable {
        let id: Order.ID
        let project: String
        let estHours: Double
        let estGrams: Double
        /// Whether this job is leaving inspection, which is the only case that
        /// also wants QC notes.
        let leavingQC: Bool
        /// Nil until the answer arrives — an engine call, and the sheet must
        /// open at once rather than after a round trip.
        var measured: KhaytEngine.ActualsPrefill?
    }

    /// The finished jobs the shop's printers still remember.
    ///
    /// Khayt freezes a print's filament and duration on the edge out of
    /// printing — the counters are per-job and reset when the next one starts —
    /// and persists them here. This app does not poll into that cache yet, so a
    /// shop running only this one gets an honest "nothing measured" and a shop
    /// running both gets the measurement.
    private(set) var printerCompletions: JSONValue = .object([:])

    /// Ask what the printer said, once the sheet is already up.
    func askWhatThePrinterSaid(for id: Order.ID) async {
        guard let engine, let job = orders.first(where: { $0.id == id }) else { return }
        guard let machineId = job.machineId, !machineId.isEmpty else { return }
        let pre = try? await engine.actualsPrefill(
            completions: printerCompletions, machineId: machineId,
            // The printer knows a FILENAME, and the only honest link between an
            // order and a set of figures is that name matching. A job with no
            // print file gets the machine's newest completion, which the sheet
            // then names so the shop can see whose numbers these are.
            filename: job.parts.compactMap(\.fileRef).first,
            estimateHours: job.printTime, estimateGrams: Self.quotedGrams(job),
            now: Date())
        guard var asking = pendingCompletion, asking.id == id, let pre else { return }
        asking.measured = pre
        pendingCompletion = asking
    }

    var pendingCompletion: PendingCompletion?

    /// What the job was quoted to weigh — the sum of its parts, times their
    /// quantities.
    ///
    /// The same shape `lib/order-file-link.js` uses to allocate a finished
    /// job's real figures back to those parts, so the number the shop is asked
    /// to correct is the number everything downstream compares against. An
    /// order carries no total weight of its own; taking the first part's would
    /// under-quote every multi-part job on this screen.
    static func quotedGrams(_ job: Order) -> Double {
        job.parts.reduce(0) { $0 + $1.printWeight * Double(max(1, $1.qty)) }
    }

    struct PendingHold: Identifiable, Sendable {
        let id: Order.ID
        let project: String
    }

    /// The customer being written down, or edited.
    var editingCustomer: Client?

    /// Save a customer — a new one, or changes to one the shop already has.
    ///
    /// A NAME IS THE ONLY THING REQUIRED, in either language, because that is
    /// Khayt's own rule and because a customer with a phone number and no name
    /// is not a customer anyone can find again.
    func saveCustomer(_ client: Client) async {
        moveProblem = nil
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        guard !client.nameEn.trimmingCharacters(in: .whitespaces).isEmpty
                || !client.nameAr.trimmingCharacters(in: .whitespaces).isEmpty else {
            moveProblem = words.callIt("ce.need_name"); return
        }

        var undo: [ChangedRecord] = []
        do {
            try StoreWriter.update(build) { root in
                var rows = Self.rows(root, "clients")
                var record = client.record
                if let at = rows.firstIndex(where: { Self.recordId($0) == client.id }) {
                    // An edit, so it is stamped like any other — and undoable.
                    guard case .object(let was) = rows[at] else { return }
                    undo.append(ChangedRecord(collection: "clients", id: client.id, was: was))
                    // Fields this app does not offer are the shop's and stay:
                    // the price list, the recurring schedule, the comms log.
                    for (key, value) in was where record[key] == nil {
                        record[key] = value
                    }
                    StoreWriter.stamp(&record)
                    rows[at] = .object(record)
                } else {
                    StoreWriter.stamp(&record)
                    rows.append(.object(record))
                }
                root["clients"] = .array(rows)
            }
            if !undo.isEmpty { registerMoveUndo(undo, named: words.callIt("mac.edit_customer")) }
            editingCustomer = nil
            await load(source)
        } catch {
            moveProblem = String(describing: error)
        }
    }

    /// Put rows on the catalogue without a book. FOR TESTS ONLY, and named so
    /// it cannot be mistaken for a way to write products — it changes what is
    /// on screen and nothing on disk.
    func setCatalogueForTesting(_ rows: [KhaytEngine.CatalogueRow]) { catalogueRows = rows }

    /// What the catalogue can be narrowed by.
    ///
    /// Two axes and a state, answering three different questions:
    ///
    ///   CATEGORY — what the shop files a product under, and what the other
    ///              app's catalogue chips already use. NOT `group`: products
    ///              carry `category`, and a chip on a field nothing writes is a
    ///              chip that never appears.
    ///   MATERIAL — what it is printed in. "Everything in resin" is the
    ///              question the search box was being used for.
    ///   NO PRICE — added and never priced. The catalogue's own "unfiled": a
    ///              product a shop cannot sell, sitting silently among ones it
    ///              can, and the only one of the three worth interrupting for.
    ///
    /// Counted the same way as the library's — each axis over what the others
    /// leave, by the shared folding rule. `LibraryFacets` carries the argument
    /// for both, including the bug the other app shipped by counting the whole
    /// catalogue while the grid narrowed on three things at once.
    ///
    /// A product's material is not a field `lib/organise.js` knows — it is
    /// derived from the parts — so the rows are handed over as records it does
    /// know. What is borrowed is the FOLDING, not the field name: a catalogue
    /// holding "PETG" and "petg" has one material.
    struct CatalogueFacets: Equatable {
        var categories: [KhaytEngine.GroupCount] = []
        var materials: [KhaytEngine.GroupCount] = []
        var unpriced = 0
        var isEmpty: Bool { categories.isEmpty && materials.isEmpty && unpriced == 0 }
    }

    private(set) var catalogueFacets = CatalogueFacets()

    var catalogueCategory: FilterChoice? { didSet { recountCatalogueSoon() } }
    var catalogueMaterial: FilterChoice? { didSet { recountCatalogueSoon() } }
    /// Products with no price at all.
    var catalogueUnpricedOnly = false { didSet { recountCatalogueSoon() } }

    /// Nothing typed and nothing worked out — NOT "costs zero".
    ///
    /// `lib/product-price.js` is explicit that a typed zero is a real answer:
    /// *"a giveaway, a sample, a part priced inside a bundle"*, and it goes out
    /// of its way not to re-price those at cost plus margin. A chip that swept
    /// them up with the ones nobody has got round to pricing would tell a shop
    /// its deliberate freebies are mistakes.
    static func isUnpriced(_ row: KhaytEngine.CatalogueRow) -> Bool {
        row.final <= 0 && row.source != "override"
    }

    var catalogueFilterOn: Bool {
        catalogueCategory != nil || catalogueMaterial != nil || catalogueUnpricedOnly
    }

    func clearCatalogueFilter() {
        catalogueCategory = nil
        catalogueMaterial = nil
        catalogueUnpricedOnly = false
    }

    enum CatalogueAxis { case unpriced, category, material }

    /// A row's category, which the catalogue row does not carry: it is the
    /// product's own field, read from the record the row was built from.
    private var productCategories: [String: String] = [:]

    private func cataloguePool(skipping axis: CatalogueAxis) -> [KhaytEngine.CatalogueRow] {
        var rows = catalogueRows
        if axis != .unpriced, catalogueUnpricedOnly { rows = rows.filter(Self.isUnpriced) }
        if axis != .category, let category = catalogueCategory {
            rows = rows.filter { category.matches(productCategories[$0.id]) }
        }
        if axis != .material, let material = catalogueMaterial {
            rows = rows.filter { material.matches($0.material) }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { Self.catalogueMatches($0, q, category: productCategories[$0.id]) }
    }

    private static func catalogueMatches(_ row: KhaytEngine.CatalogueRow, _ q: String,
                                         category: String?) -> Bool {
        row.name.lowercased().contains(q)
            || row.description.lowercased().contains(q)
            || row.material.lowercased().contains(q)
            || row.group.lowercased().contains(q)
            || (category ?? "").lowercased().contains(q)
    }

    /// The same race as `libraryRecount`, for the same reason.
    private var catalogueRecount = 0

    func readCatalogueFacets() async {
        catalogueRecount += 1
        let mine = catalogueRecount
        guard let engine, !catalogueRows.isEmpty else { catalogueFacets = CatalogueFacets(); return }
        let categoryRows = cataloguePool(skipping: .category).map {
            JSONValue.object(["category": .string(productCategories[$0.id] ?? "")])
        }
        let materialRows = cataloguePool(skipping: .material).map {
            JSONValue.object(["category": .string($0.material)])
        }
        let categories = (try? await engine.categoryCounts(categoryRows)) ?? []
        let materials = (try? await engine.categoryCounts(materialRows)) ?? []
        guard mine == catalogueRecount else { return }
        let unpriced = cataloguePool(skipping: .unpriced).count(where: Self.isUnpriced)
        catalogueFacets = CatalogueFacets(categories: categories, materials: materials,
                                          unpriced: unpriced)
    }

    private var catalogueRecountTask: Task<Void, Never>?
    private func recountCatalogueSoon() { catalogueRecountTask = Task { await readCatalogueFacets() } }

    /// The same, for the catalogue's chips. See `settleLibraryFacets`.
    func settleCatalogueFacets() async {
        while let pending = catalogueRecountTask {
            catalogueRecountTask = nil
            await pending.value
        }
    }

    /// The catalogue, matching the search box and whatever chips are on.
    ///
    /// The rule `shownExpenses` states: a search field that does nothing on the
    /// screen you are looking at is worse than no search field. Every other
    /// list in this app had been held to it and the catalogue had not — the
    /// field sat above the products prompting "Job, customer or number" and
    /// narrowed nothing.
    ///
    /// Name, description, material and group: a shop hunting for "the palm one"
    /// or "everything in resin" is asking one of those four.
    var shownProducts: [KhaytEngine.CatalogueRow] {
        var rows = catalogueRows
        // Every axis narrows at once, as in the library: "the resin ones in the
        // Kings collection" is one question, not two screens.
        if catalogueUnpricedOnly { rows = rows.filter(Self.isUnpriced) }
        if let category = catalogueCategory {
            rows = rows.filter { category.matches(productCategories[$0.id]) }
        }
        if let material = catalogueMaterial { rows = rows.filter { material.matches($0.material) } }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { Self.catalogueMatches($0, q, category: productCategories[$0.id]) }
    }

    /// Whether the screen now showing has anything for the search box to narrow.
    ///
    /// ── A FIELD THAT DOES NOTHING IS WORSE THAN NO FIELD ──────────────────
    ///
    /// `.searchable` was on the window unconditionally, so every screen carried
    /// a search field — including the four that are not lists at all. On the
    /// calculator, the colour studio, the reports and the dashboard it was a
    /// control that could be typed into and did nothing, labelled "Job,
    /// customer or number" because the prompt fell through to the jobs one.
    ///
    /// Listed the positive way round, so a NEW screen gets no search box until
    /// somebody says it has one. The other order — naming the screens without
    /// search — hands every future screen a field that does nothing by default,
    /// which is the state this is fixing.
    var canSearch: Bool {
        switch shelf {
        case .jobs, .board, .library, .customers, .inventory,
             .expenses, .waste, .portfolio, .giftCards, .catalogue:
            return true
        case .dashboard, .machines, .reports, .colour, .calculator:
            return false
        }
    }

    /// What this screen's search box looks for, in its own words.
    ///
    /// Three screens fell through to the jobs prompt and were asking for a
    /// "Job, customer or number" while filtering spools, products and a board.
    /// The board keeps the jobs prompt on purpose — it IS jobs.
    ///
    /// On the book rather than in the window because both shells ask for it:
    /// the old one for its toolbar field, the new one for the strip's.
    @MainActor var searchPrompt: String {
        if shelf == .giftCards { return words.callIt("giftCardCode") }
        if shelf == .portfolio { return words.callIt("pf.search_ph") }
        if showingLibrary { return words.callIt("mac.search_models") }
        if showingCustomers { return words.callIt("mac.search_people") }
        if showingExpenses { return words.callIt("mac.search_expenses") }
        if showingWaste { return words.callIt("mac.search_waste") }
        if showingInventory { return words.callIt("mac.search_filament") }
        if showingCatalogue { return words.callIt("mac.search_products") }
        return words.callIt("mac.search_jobs")
    }

    // MARK: - Finding a printer

    /// True while the find-printers sheet is up.
    var findingPrinters = false

    private let finder = PrinterFinder()

    /// Ask the network what is on it. Owner-initiated, time-boxed, never a timer.
    func findPrinters() async -> [KhaytEngine.FoundPrinter] {
        guard let engine else { return [] }
        return await finder.find(engine: engine)
    }

    // MARK: - What a model would cost

    /// An estimate per model, worked out once when the book loads.
    ///
    /// Not per redraw: the calibration reads the whole print log, and a grid of
    /// four hundred models asking for that on every frame is four hundred trips
    /// through the runtime for one number that cannot have changed.
    private(set) var estimates: [String: KhaytEngine.MeshEstimate] = [:]

    static func priceMeshes(_ files: [LibraryFile], settings: [String: JSONValue],
                            orders: [JSONValue], engine: KhaytEngine?) async
        -> [String: KhaytEngine.MeshEstimate] {
        guard let engine else { return [:] }
        var out: [String: KhaytEngine.MeshEstimate] = [:]
        for file in files {
            guard let mesh = file.mesh, mesh.volumeMm3 > 0 else { continue }
            // THE SURFACE AREA, WHERE THE SHOP HAS ALREADY PAID FOR IT.
            //
            // The shell fraction is `area x wallThickness / volume`, and with no
            // area the estimator keeps a flat assumed constant — honest, and
            // weaker. The geometry key holds triangles, volume and dimensions
            // but no area, and measuring every file on every load would mean
            // reading the whole library.
            //
            // But a model the shop has checked for print risks ALREADY has its
            // area measured and stored. So a mesh that has been walked gets a
            // real shell fraction, and one that has not keeps the assumption —
            // and `shellSource` says which, because "a number nobody can
            // attribute is a number nobody can check".
            var area = 0.0
            if case .number(let a)? = file.riskAnalysis?["totalAreaMm2"], a > 0 { area = a }
            if let e = try? await engine.estimateMesh(
                volumeMm3: mesh.volumeMm3, areaMm2: area,
                bbox: (x: mesh.x, y: mesh.y, z: mesh.z),
                settings: settings, orders: orders) {
                out[file.id] = e
            }
        }
        return out
    }

    // MARK: - A printer that changed address

    /// Machines whose address appears to have moved, and where to.
    private(set) var relocations: [KhaytEngine.Relocation] = []
    var relocateProblem: String?
    var relocateNote: String?
    /// True while the network is being asked where a quiet machine went.
    var lookingForMoved = false
    /// True while the subnets are being asked, which is the slow half and
    /// worth saying: mDNS answers instantly and a sweep takes seconds.
    var sweeping = false

    /// True when this machine has gone quiet for long enough to be worth asking.
    ///
    /// The same three-strike rule the status badge uses, so the button appears
    /// exactly when the screen already says something is wrong.
    func looksUnreachable(_ machineId: String) -> Bool {
        guard case .object(let entry)? = printers.statusCache[machineId],
              case .string(let err)? = entry["error"], !err.isEmpty,
              case .number(let n)? = entry["consecutiveFailures"] else { return false }
        return n >= 3
    }

    /// Ask the network where the quiet machines went.
    ///
    /// Owner-initiated and time-boxed, like `findPrinters` — never a timer. A
    /// shop whose router reboots should not have Khayt sweeping its LAN on a
    /// schedule for the rest of the day.
    func findMovedPrinters() async {
        relocateProblem = nil
        relocateNote = nil
        guard let engine else { return }
        lookingForMoved = true
        defer { lookingForMoved = false }

        let found = await findPrinters()
        // Back through JSON rather than hand-copied: `planRelocations` reads
        // `serial`, `model`, `firmware` and `port`, and a Swift struct that
        // named only some of them is exactly how the serial went missing in the
        // first place.
        let discovered: [JSONValue] = found.compactMap { printer in
            guard let data = try? JSONEncoder().encode(printer),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { return nil }
            return value
        }
        relocations = (try? await engine.planRelocations(
            machines: machineRows,
            discovered: discovered,
            statusCache: printers.statusCache)) ?? []

        // ── AND IF NOTHING ANNOUNCED ITSELF, ASK ──────────────────────────
        //
        // mDNS only finds a printer that talks. A Snapmaker U1 advertises
        // neither `_moonraker._tcp` nor `_octoprint._tcp` — browsed on the LAN
        // it was printing on, the answer was nothing at all — so the shop was
        // told "no printers on the network" while the printer sat two
        // addresses away answering every question put to it directly.
        //
        // So when the announcement turns up nothing that matches, the subnets
        // of the machines that are actually offline get asked. Only then: a
        // sweep is the expensive, noisy way to find something mDNS hands over
        // for free, and it is never the first thing tried.
        if relocations.isEmpty {
            let offline = offlineMachineHosts()
            if !offline.isEmpty {
                sweeping = true
                let swept = await PrinterSweep.look(from: offline, engine: engine)
                sweeping = false
                if !swept.isEmpty {
                    relocations = (try? await engine.planRelocations(
                        machines: machineRows,
                        discovered: discovered + swept,
                        statusCache: printers.statusCache)) ?? []
                }
            }
        }

        if relocations.isEmpty {
            relocateNote = words.callIt(found.isEmpty ? "mac.moved_none_on_network"
                                                      : "mac.moved_none_matched")
        }
    }

    /// The last-known addresses of the machines that are not answering.
    ///
    /// Only those: sweeping the subnet of a printer that is replying perfectly
    /// well asks two hundred and fifty questions to learn something already
    /// known. A machine with no address configured has no subnet to sweep.
    func offlineMachineHosts() -> [String] {
        var out: [String] = []
        for row in machineRows {
            guard case .object(let m) = row,
                  case .string(let id)? = m["id"],
                  case .object(let api)? = m["printerApi"],
                  case .string(let host)? = api["host"] else { continue }
            // `looksUnreachable` and not a test written here: it is the same
            // three-strike rule the status badge uses, so this asks about
            // exactly the machines the screen already says are in trouble.
            guard looksUnreachable(id) else { continue }
            let bare = host.split(separator: ":").first.map(String.init) ?? host
            if !bare.isEmpty { out.append(bare) }
        }
        return out
    }

    /// Point a machine at the address the printer is actually on.
    ///
    /// A WRITE, and the write is what the app will later send commands through
    /// — so an identity match (a MAC or a serial, neither of which moves with a
    /// DHCP lease) is applied on one confirmation, and a guess is only ever
    /// offered. `lib/printer-relocate.js` draws that line and this does not
    /// redraw it.
    func applyRelocation(_ move: KhaytEngine.Relocation) async {
        relocateProblem = nil
        guard let engine, let build = source.build else {
            relocateProblem = words.callIt("mac.move_sample"); return
        }
        guard let row = machineRows.first(where: { row in
            guard case .object(let m) = row, case .string(let id)? = m["id"] else { return false }
            return id == move.machineId
        }) else { relocateProblem = words.callIt("mac.not_found"); return }

        guard let updated = try? await engine.applyRelocation(row, move),
              case .object(let record) = updated else {
            relocateProblem = words.callIt("mac.moved_failed"); return
        }
        do {
            try StoreWriter.update(build) { root in
                guard case .array(var rows)? = root["machines"] else { return }
                for i in rows.indices {
                    guard case .object(let m) = rows[i],
                          case .string(let id)? = m["id"], id == move.machineId else { continue }
                    var next = record
                    StoreWriter.stamp(&next)
                    rows[i] = .object(next)
                }
                root["machines"] = .array(rows)
            }
            relocations.removeAll { $0.machineId == move.machineId }
            relocateNote = words.callIt("mac.moved_done",
                                        ["name": .string(move.machineName),
                                         "host": .string(move.to)])
            await load(source)
        } catch {
            relocateProblem = String(describing: error)
        }
    }

    /// Write a found printer down as a machine.
    ///
    /// Its name, address and port, and the connection type the shared rule
    /// chose — and the catalog entry when it recognised the model, which is
    /// what fills in the bed, the nozzle and what it costs to run.
    func addFound(_ printer: KhaytEngine.FoundPrinter) async {
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        let id = Self.uid("MCH")
        do {
            var record: [String: JSONValue] = [
                "id": .string(id),
                "name": .string(printer.name),
                "status": .string("idle"),
                "createdAt": .string(Self.localDay()),
                "printerApi": .object([
                    "type": .string(printer.connection ?? "none"),
                    "host": .string(printer.host),
                    "port": .number(Double(printer.port ?? 0)),
                ]),
            ]
            // What the catalog knows about this model, when it recognised one.
            if let catalogId = printer.catalogId, !catalogId.isEmpty, let engine {
                var settings: [String: JSONValue] = [:]
                if case .object(let held) = settingsValue { settings = held }
                let written = try? await engine.applyPrinterModel(
                    .object(record), catalogId: catalogId, settings: settings)
                if case .object(let filled)? = written?.machine { record = filled }
            }
            try StoreWriter.update(build) { root in
                var fleet = Self.rows(root, "machines")
                // A printer already written down at this address is the same
                // printer. Adding it twice gives a shop two cards that disagree.
                guard !fleet.contains(where: { row in
                    guard case .object(let m) = row,
                          case .object(let api)? = m["printerApi"],
                          case .string(let host)? = api["host"] else { return false }
                    return host == printer.host
                }) else { return }
                StoreWriter.stamp(&record)
                fleet.append(.object(record))
                root["machines"] = .array(fleet)
            }
            await load(source)
        } catch {
            moveProblem = String(describing: error)
        }
    }

    // MARK: - Telling a printer what to do

    /// What went wrong the last time a machine was told something, by machine.
    /// Per machine rather than one banner: a shop with eight printers needs to
    /// know WHICH one refused.
    private(set) var printerProblem: [String: String] = [:]
    /// Machines with a command in flight, so the buttons can say so and cannot
    /// be pressed twice.
    private(set) var printerBusy: Set<String> = []

    /// A job this app is about to cancel, held for the confirmation.
    ///
    /// Cancelling throws away however many hours are already in the plate, and
    /// no printer asks twice. Pause and resume go straight through — they are
    /// each other's undo.
    var confirmingCancel: Machine?

    /// The machine whose plate is being looked at, for dropping one object.
    var droppingFrom: Machine?

    func tell(_ machine: Machine, _ verb: PrinterControl.Verb) async {
        guard let engine else { return }
        printerProblem[machine.id] = nil
        printerBusy.insert(machine.id)
        defer { printerBusy.remove(machine.id) }
        do {
            try await PrinterControl.send(verb, to: machine, engine: engine, build: source.build)
            // Ask straight away rather than waiting for the next poll: a button
            // that appears to do nothing for ten seconds gets pressed again.
            await printers.refresh(machine, shop: self)
        } catch {
            printerProblem[machine.id] = String(describing: error)
        }
    }

    /// What is on a machine's plate, for the sheet that offers to drop one.
    func plate(of machine: Machine) async -> KhaytEngine.Plate? {
        guard let engine else { return nil }
        do { return try await PrinterControl.plate(of: machine, engine: engine, build: source.build) }
        catch { printerProblem[machine.id] = String(describing: error); return nil }
    }

    /// Drop one object from a running print. NOT UNDOABLE — the caller has
    /// already asked; see `lib/exclude-object.js`.
    func drop(_ object: String, on machine: Machine) async {
        guard let engine else { return }
        printerProblem[machine.id] = nil
        printerBusy.insert(machine.id)
        defer { printerBusy.remove(machine.id) }
        do {
            try await PrinterControl.drop(object, on: machine, engine: engine, build: source.build)
        } catch {
            printerProblem[machine.id] = String(describing: error)
        }
    }

    // MARK: - What to run next

    /// The dispatcher's answer, recomputed when the book or the printers move.
    private(set) var dispatch: KhaytEngine.DispatchPlan?

    /// Machines the shop has held back from the dispatcher, this session.
    ///
    /// Not written to the book: "do not send this one work for the next hour"
    /// is a fact about today, and a flag that outlived the reason for it is
    /// worse than no flag.
    var dispatchHeld: Set<String> = []

    /// Accept one of the dispatcher's proposals.
    ///
    /// Sets `machineId` and NOTHING ELSE — not the status, not the queue
    /// position. The same rule `applySchedule` follows, and for the same
    /// reason: the rule proposes a printer, and moving the card is the
    /// operator's. It also re-reads inside the write, so a job assigned by hand
    /// since the panel was drawn is never overwritten by a stale suggestion.
    func accept(_ proposal: KhaytEngine.DispatchProposal) async {
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        do {
            try StoreWriter.updateRecord(build, collection: "printLog",
                                         id: proposal.orderId) { record in
                guard (Self.plainString(record["machineId"]) ?? "").isEmpty else { return }
                record["machineId"] = .string(proposal.machineId)
            }
            await load(source)
            await planDispatch()
        } catch {
            moveProblem = String(describing: error)
        }
    }

    /// Ask the rule what to run next.
    ///
    /// Cheap, and called whenever the fleet's readings change: the answer is a
    /// function of the queue and what the printers just said, and one that is
    /// several minutes old is an answer about a shop that has moved on.
    func planDispatch() async {
        guard let engine else { dispatch = nil; return }
        let live = printers.statusCache
        dispatch = try? await engine.dispatchPlan(
            orders: orderRows, machines: machineRows, live: live,
            lastMaterialByMachine: lastMaterialByMachine(),
            paused: Dictionary(uniqueKeysWithValues: dispatchHeld.map { ($0, JSONValue.bool(true)) }))
    }

    /// What each machine printed last, so the rule can prefer the one that
    /// needs no spool change.
    ///
    /// Khayt does not record what is LOADED in a machine — only what it has
    /// printed — so the most recent finished job is the best signal there is,
    /// and it is very often still in the machine.
    private func lastMaterialByMachine() -> [String: JSONValue] {
        var seen: [String: (day: String, material: String)] = [:]
        for order in orders {
            guard let id = order.machineId, !id.isEmpty else { continue }
            guard let finished = order.completedAt ?? order.deliveredAt else { continue }
            let material = order.parts.compactMap { $0.material.isEmpty ? nil : $0.material }.first
            guard let material else { continue }
            if let held = seen[id], held.day >= finished { continue }
            seen[id] = (day: finished, material: material)
        }
        return seen.mapValues { JSONValue.string($0.material) }
    }

    /// Say a machine's plate is empty, so the dispatcher may offer it again.
    ///
    /// THE ONE THING A PRINTER CANNOT TELL US. None of them can clear their own
    /// bed or see that it is clear, so this is a person's sentence and it is
    /// written down as one — stamped on the machine, and compared against when
    /// that machine last finished a print.
    func markBedClear(_ machine: Machine) async {
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        do {
            try StoreWriter.updateRecord(build, collection: "machines", id: machine.id) { record in
                record["bedClearedAt"] = .string(StoreWriter.iso(Date()))
            }
            await load(source)
            await planDispatch()
        } catch {
            moveProblem = String(describing: error)
        }
    }

    // MARK: - Writing a product down

    /// The product being edited, or nil. Drives the sheet, as the customer's does.
    var editingProduct: Product?
    /// Why a product could not be made from a model, when it could not.
    var productProblem: String?
    /// What the file could not answer for — said rather than left as zeros.
    var productNote: String?

    /// Every product id in the book — how the sheet tells a new one from an edit.
    var productIds: Set<String> {
        Set(productRows.compactMap { Self.recordId($0) })
    }

    /// One entry per language the shop's catalogue carries: the code, its name
    /// in its own script, and the two record keys it owns.
    ///
    /// Asked of the engine rather than assumed, because `fieldKey` is the rule
    /// that decides `nameEn` vs `name_de` and there must not be a second copy
    /// of it in Swift. Resolved once per book — every field in the sheet asks.
    private(set) var catalogueLanguages: [Product.LanguageKey] = []

    static func catalogueLanguages(_ settings: [String: JSONValue],
                                   engine: KhaytEngine?) async -> [Product.LanguageKey] {
        guard let engine, let codes = try? await engine.contentLanguages(settings: settings) else { return [] }
        var out: [Product.LanguageKey] = []
        for code in codes {
            guard let name = try? await engine.fieldKey("name", language: code),
                  let description = try? await engine.fieldKey("description", language: code)
            else { continue }
            let title = (try? await engine.languageName(code)) ?? code
            out.append(Product.LanguageKey(language: code, title: title, name: name, description: description))
        }
        return out
    }

    /// EVERY key a product could hold, not only the shop's current languages.
    ///
    /// A shop that carried French last year still has `name_fr` on its older
    /// products. Reading and writing only today's languages would drop that
    /// text on the first save — deleting the shop's own words as a side effect
    /// of editing the margin.
    private func allLanguageKeys() async -> [Product.LanguageKey] {
        var keys = catalogueLanguages
        let known = Set(keys.map(\.language))
        guard let engine, let supported = try? await engine.supportedContentLanguages() else { return keys }
        for code in supported where !known.contains(code) {
            guard let name = try? await engine.fieldKey("name", language: code),
                  let description = try? await engine.fieldKey("description", language: code)
            else { continue }
            keys.append(Product.LanguageKey(language: code, title: code, name: name, description: description))
        }
        return keys
    }

    /// Read one product for editing, with every language key it might carry.
    func productForEditing(_ id: String) async -> Product? {
        guard case .object(let record)? = productRows.first(where: { Self.recordId($0) == id })
        else { return nil }
        return Product.from(record, keys: await allLanguageKeys())
    }

    /// The papers that travel with a job, through the shared rule.
    ///
    /// Empty for a job nobody took from a product, which is most of them — and
    /// for a product with nothing attached.
    func documents(for job: Order) async -> [KhaytEngine.OrderDocument] {
        guard job.productId?.isEmpty == false, let engine else { return [] }
        return (try? await engine.orderDocuments(
            order: .object(["productId": .string(job.productId ?? "")]),
            products: productRows)) ?? []
    }

    // MARK: - Taking a job from something the shop already makes

    /// The product a new job is being taken from, if any.
    ///
    /// ── WHY A JOB REMEMBERS ITS PRODUCT ───────────────────────────────────
    ///
    /// `productId` on the order is not bookkeeping. It is what the catalogue
    /// counts to say a product has been made 14 times and earned 6,300; it is
    /// what `lib/product-docs.js` follows to put the right assembly sheet in
    /// the box; and it is what a shop's second machine reads to know two
    /// orders are the same thing. A job typed out by hand that happens to
    /// match a product is none of those.
    var jobFromProduct: Product?

    /// Start a job from a product: its parts, its components, its margin.
    func takeJob(from product: Product) {
        jobFromProduct = product
        takingAJob = true
    }

    /// The tiers a product offers, as the sheet shows them.
    ///
    /// A NAMED MARGIN, not a price. "Wholesale 20%" replaces the margin on the
    /// sheet and the price follows from the parts, so a tier stays right when
    /// filament gets dearer — which a stored price would not.
    struct PriceTier: Identifiable, Sendable, Hashable {
        var id: String { label + "/" + String(margin) }
        let label: String
        let margin: Double
    }

    static func tiers(of product: Product?) -> [PriceTier] {
        guard case .array(let rows)? = product?.rest["priceTiers"] else { return [] }
        return rows.compactMap { row in
            guard case .object(let o) = row,
                  let label = plainString(o["label"])?.trimmingCharacters(in: .whitespaces),
                  !label.isEmpty,
                  let margin = plainNumber(o["margin"]) else { return nil }
            return PriceTier(label: label, margin: margin)
        }
    }

    /// A blank product with an id in Khayt's own shape — `uid('PROD')`, as the
    /// Electron editor mints it, so one written here is indistinguishable.
    func newProduct() -> Product {
        Product(id: Self.uid("PROD"), names: [:], descriptions: [:],
                margin: nil, group: "", category: "",
                createdAt: Self.localDay(), rest: [:])
    }

    /// A product that sells this model, with its first part already filled in.
    ///
    /// ── THE TWO SCREENS DID NOT MEET ───────────────────────────────────────
    ///
    /// The library held 83 models with their weights and print times parsed at
    /// import; the catalogue held products whose parts were typed in by hand.
    /// Nothing joined them, in either direction — and the one product in this
    /// shop's book shows what that costs:
    ///
    ///     "fileRef": "KING-Abdulaziz-ART-200mm-U1_PLA_4h32m.gcode"
    ///
    /// a filename, not a link. `lib/order-file-link.js` opens by naming exactly
    /// that: "an order carried a free-text `fileRef` — a filename somebody
    /// typed — so none of it joined up."
    ///
    /// So the part is filled by `lib/part-from-print-file.js`, which already
    /// does all of it: weight and time from what the slicer measured, material
    /// and layer height from the setup the shop has had most success with, and
    /// `printFileId` — the real join, which is what makes "for THIS part, with
    /// THESE settings, how far out is my estimate?" answerable later.
    ///
    /// `missing` is carried back rather than swallowed. A part the file could
    /// not answer for leaves fields at zero, and a zero that looks typed is
    /// worse than a blank somebody was told about.
    func productFromFile(_ file: LibraryFile) async -> Product? {
        guard let filled = await partFields(from: file) else { return nil }
        var product = newProduct()
        // The model's name in every language the catalogue carries — the same
        // name, because a model has one and a shop can correct it on the sheet.
        for key in await allLanguageKeys() {
            product.names[key.language] = file.title
        }
        product.rest["parts"] = .array([.object(filled.part)])
        productNote = filled.note
        return product
    }

    /// A library model, as one part of a product — the figures and the note
    /// that goes with them.
    ///
    /// Split out of `productFromFile` so the product sheet can fill a part
    /// from a model the shop CHOOSES, and not only make a whole product from a
    /// model it selected in the library. Reported from the running app: "in
    /// Catalogue I should be able to load the print file to calculate the
    /// price". Same rule both ways round, so a product built either way prices
    /// the same.
    ///
    /// `note` is what the shop has to be told: which figures are estimates
    /// from the geometry rather than measurements, and which are still blank.
    /// The two are different claims and are said separately. Nil when the
    /// file answered for everything.
    func partFields(from file: LibraryFile) async -> (part: [String: JSONValue], note: String?)? {
        productProblem = nil
        guard let engine, let rec = row(for: file.id) else {
            productProblem = words.callIt("mac.not_found"); return nil
        }
        guard let patch = try? await engine.partFieldsFromFile(rec) else {
            productProblem = words.callIt("mac.product_from_file_failed"); return nil
        }

        var part = patch.fields
        // The part's name is the model's, which is what a shop would have
        // typed. Everything else on it came from the file.
        part["name"] = .string(file.title)
        // `qty`, NOT `quantity`. Every consumer reads `qty` — the calculator's
        // per-part cost, the packaging split, the price tiers, the specs the
        // catalogue row shows — so `quantity` is a field nothing reads, with
        // the real one absent beside it.
        //
        // Benign only by accident: `Math.max(1, +part.qty || 1)` falls back to
        // one, and the value written here was always one. It would have stopped
        // being benign the moment anything wrote a different number.
        part["qty"] = .number(1)

        // ── WHAT THE FILE COULD NOT ANSWER, THE GEOMETRY OFTEN CAN ────────
        //
        // A shop's library is mostly UNSLICED models — the file this was found
        // on is a 15 MB 3MF with no weight, no time and no material recorded,
        // because nothing has sliced it yet. `partPatch` correctly reports both
        // as missing, and the product was then written with neither, which is
        // honest and not much use: a product with no weight has no cost, so it
        // has no price.
        //
        // This app can MEASURE the mesh and price it at the shop's OWN measured
        // rate, which the other app cannot do at all. So where the file cannot
        // answer, the geometry does — and the answer is LABELLED, because an
        // estimate that looks typed is the same bug as a zero that looks typed.
        var estimated: [String] = []
        if let e = estimates[file.id] {
            if Self.plainNumber(part["printWeight"]) ?? 0 <= 0, e.grams > 0 {
                part["printWeight"] = .number(e.grams)
                estimated.append(words.callIt("mac.weight"))
            }
            if Self.plainNumber(part["printTime"]) ?? 0 <= 0, e.hours > 0 {
                part["printTime"] = .number(e.hours)
                estimated.append(words.callIt("common.hours"))
            }
        }

        // Said plainly, and only when there is something to say.
        //
        // The ESTIMATED fields are named first and separately from the ones
        // still blank. They are different claims: one is a figure this app
        // worked out and stands behind, the other is a gap the shop has to
        // fill. Rolling them into one sentence would make the estimate sound
        // like a measurement, which is exactly what it is not.
        var note: String?
        if !estimated.isEmpty {
            let e = estimates[file.id]
            note = words.callIt(
                e?.isCalibrated == true ? "mac.product_estimated_calibrated"
                                        : "mac.product_estimated",
                ["fields": .string(estimated.joined(separator: ", ")),
                 "n": .number(Double(e?.jobs ?? 0))])
        }
        let stillMissing = patch.missing.filter { field in
            Self.plainNumber(part[field]).map { $0 <= 0 } ?? true
        }
        if !stillMissing.isEmpty {
            let gap = words.callIt("mac.product_from_file_missing",
                                   ["fields": .string(stillMissing.joined(separator: ", "))])
            // APPENDED, not assigned: with two sentences, assigning wiped the
            // estimate note whenever nothing was left missing — the good case,
            // and the one where the shop most needs telling.
            note = note.map { $0 + " " + gap } ?? gap
        }
        return (part, note)
    }

    /// Open the product sheet on a product made from the selected model.
    func productFromSelection() async {
        guard let one = selectedFile else { return }
        if let product = await productFromFile(one) { editingProduct = product }
    }

    /// Write it down. Follows `saveCustomer` exactly, including the undo.
    /// What this shop has actually realized on jobs like this one.
    ///
    /// NO MODEL IS INVOLVED. `buildComparables` is arithmetic over the shop's
    /// own finished jobs — so this needs no key, no consent and no network, and
    /// a shop that will never switch the assistant on still gets it.
    ///
    /// `settings` is passed because the margins are NET OF TAX: for an
    /// inclusive-VAT shop part of every price was the tax authority's and was
    /// never revenue, and a median computed on the gross is one a shop would
    /// price against and come out thin.
    func priceComparables(material: String) async -> KhaytEngine.PriceComparables? {
        guard let engine else { return nil }
        return try? await engine.priceComparables(orders: orderRows, material: material,
                                                  settings: settingsDict)
    }

    /// The same answer, unparsed — what the model is shown when asked to weigh
    /// it. Kept as the raw value rather than re-encoding the decoded struct,
    /// because the rule's own shape is what its prompt builder expects and a
    /// Swift round-trip is a chance to lose a field.
    func priceComparablesRaw(material: String) async -> JSONValue? {
        guard let engine else { return nil }
        return try? await engine.rawPriceComparables(orders: orderRows, material: material,
                                                     settings: settingsDict)
    }

    /// Price a product from the parts the sheet is holding.
    ///
    /// Through the shared rule, which is what `renderer/inventory.js` now
    /// prices with too. A product's price is COMPUTED — the calculator's
    /// per-part cost, the components, the margin, the shop's rounding — and two
    /// apps computing it separately is two prices for one product, with the one
    /// the customer sees decided by which app last saved it.
    /// What a part is costed at before anybody types anything — the shared
    /// rule's own figures, so a product made here is priced the way the other
    /// app would price it. See `ProductSheet.PartRow.rates`.
    func printRateDefaults() async -> [String: String]? {
        guard let engine, let defaults = try? await engine.printRateDefaults() else { return nil }
        return defaults.mapValues { Money.fieldValue($0) }
    }

    func priceProduct(parts: [JSONValue], margin: Double?,
                      components: JSONValue?, rule: PriceRule = PriceRule()) async -> KhaytEngine.ProductPricing? {
        guard let engine else { return nil }
        var record: [String: JSONValue] = ["parts": .array(parts)]
        if let margin { record["defaultMargin"] = .number(margin) }
        if let components { record["components"] = components }
        for (key, value) in rule.fields { record[key] = value }
        return try? await engine.priceProduct(.object(record),
                                              inventory: inventoryRows,
                                              settings: settingsDict,
                                              consumables: consumableRows)
    }

    /// Whether the shop has agreed to price advice, on this book.
    private(set) var aiPriceAllowed = false

    /// A recommended margin, with the reason for it.
    struct PriceAdvice: Sendable {
        var margin: Double
        var rationale: String
    }

    /// Advice or a sentence. Not `Result<_, String>` — `String` is not an
    /// `Error`, and inventing an error type for something the shop simply has
    /// to READ buys nothing.
    enum PriceOutcome: Sendable {
        case advised(PriceAdvice)
        case refused(String)
    }

    /// Ask the model to weigh this shop's own comparables.
    ///
    /// The comparables are already on screen — computed here, net of tax, with
    /// nothing sent anywhere. This is the optional second opinion over them.
    func recommendMargin(comparables: KhaytEngine.PriceComparables,
                         raw: JSONValue, cost: Double, grams: Double,
                         hours: Double, material: String) async
        -> PriceOutcome {
        let job = JSONValue.object([
            "material": .string(material), "grams": .number(grams),
            "hours": .number(hours), "cost": .number(cost),
            "currency": .string(currency),
        ])
        do {
            let out = try await AiClient.recommendMargin(
                comparables: raw, job: job,
                fallback: comparables.suggestedMargin, shop: self)
            guard out.ok, let margin = out.suggestedMargin else {
                return .refused(out.problem ?? words.callIt("mac.ai_no_draft"))
            }
            return .advised(PriceAdvice(margin: margin,
                                        rationale: out.rationale ?? ""))
        } catch AiClient.Failure.notConsented {
            return .refused(words.callIt("mac.ai_price_not_consented"))
        } catch AiClient.Failure.noKey {
            return .refused(words.callIt("mac.ai_no_key"))
        } catch {
            return .refused(String(describing: error))
        }
    }

    // MARK: - Drafting a message to a customer

    /// Whether the shop has agreed to message drafting, on this book.
    private(set) var aiReplyAllowed = false

    /// The job a message is being drafted about, while the sheet is up.
    var draftingFor: Order?

    /// The job whose customer is being written to from a saved message.
    var messagingFor: Order?

    /// The shop's own saved messages, in the order it keeps them.
    private(set) var messageTemplates: [MessageTemplate] = []

    /// The number to open WhatsApp on, or empty.
    ///
    /// From the CUSTOMER RECORD, never from the job: a job carries a name, and
    /// a name is not something to dial. A job with no customer record has no
    /// number, which the sheet says out loud rather than showing a dead button.
    func customerPhone(for job: Order) -> String {
        guard let id = job.clientId, !id.isEmpty else { return "" }
        return clients.first { $0.id == id }?.phone ?? ""
    }

    /// One of the shop's messages, with this job's facts in it.
    ///
    /// The SUBSTITUTION is `WaTemplate` — which placeholders exist and what
    /// stands in for a blank — shared with the other app, because a template
    /// written there is sent from here and a placeholder this app did not know
    /// would go out with braces in it, to a customer.
    ///
    /// The FORMATTING is this app's: a price is written the way every other
    /// figure on this screen is written, and the status is the word this app
    /// uses for that stage rather than the raw field.
    func fillMessage(_ template: MessageTemplate, for job: Order) -> String {
        let name = job.client.isEmpty ? job.project : job.client
        let stage = Stage.of(job)
        return WaTemplate.fill(template.body, values: [
            "client": name,
            "id": job.id,
            "price": Money.figure(job.price),
            "currency": Money.mark(currency),
            "due": job.dueDate ?? "",
            "status": stage.map { words.callIt("queue." + $0.rawValue, fallback: $0.rawValue) } ?? "",
        ])
    }

    /// Draft one, or say why not.
    ///
    /// Returns the text for the shop to read and change. NOTHING IS SENT: this
    /// app cannot email, and a drafted message a shop has not read is not a
    /// message anyone should be sending on its behalf anyway.
    func draftMessage(for job: Order, intent: String, note: String) async -> DraftOutcomeText {
        guard let row = orderRow(job.id) else { return .refused(words.callIt("mac.move_gone")) }
        do {
            // The NAME only. The customer record has an email, a phone and an
            // address on it; the disclosure does not name them and they are not
            // the shop's to send on that person's behalf.
            let text = try await AiClient.draftReply(
                order: row, clientName: job.client, intent: intent, note: note, shop: self)
            return .drafted(text)
        } catch AiClient.Failure.notConsented {
            return .refused(words.callIt("mac.ai_reply_not_consented"))
        } catch AiClient.Failure.noKey {
            return .refused(words.callIt("mac.ai_no_key"))
        } catch {
            return .refused(String(describing: error))
        }
    }

    enum DraftOutcomeText: Sendable {
        case drafted(String)
        case refused(String)
    }

    // MARK: - Asking about the book

    /// The collections the assistant's summary is built from.
    ///
    /// Named rather than handing over the whole store: the summary is the only
    /// thing that leaves the building, and it is built from these four. A shop
    /// asking "what does it send?" is owed a list, and this is it.
    var bookForAssistant: [String: JSONValue] {
        ["printLog": .array(orderRows),
         "inventory": .array(inventoryRows),
         "clients": .array(clientRows),
         "settings": settingsValue]
    }

    /// Whether the shop has agreed to the assistant, on this book.
    private(set) var aiAssistantAllowed = false

    /// One question and its answer, kept so a follow-up resolves.
    struct AskedTurn: Identifiable, Sendable {
        let id = UUID()
        let question: String
        var answer: String?
        var problem: String?
    }

    /// True while the ask-the-book sheet is up.
    var askingTheBook = false

    private(set) var asked: [AskedTurn] = []
    var asking = false

    /// Ask the assistant, keeping the conversation so "and last month?" works.
    func ask(_ question: String) async {
        let said = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, !asking else { return }
        asking = true
        defer { asking = false }
        asked.append(AskedTurn(question: said))
        let at = asked.count - 1

        // The turns BEFORE this one, which is what lets a follow-up resolve.
        let history: [JSONValue] = asked.dropLast().compactMap { turn in
            guard let answer = turn.answer else { return nil }
            return .object(["q": .string(turn.question), "a": .string(answer)])
        }
        do {
            asked[at].answer = try await AiClient.ask(said, history: history, shop: self)
        } catch AiClient.Failure.notConsented {
            asked[at].problem = words.callIt("mac.ai_assistant_not_consented")
        } catch AiClient.Failure.noKey {
            asked[at].problem = words.callIt("mac.ai_no_key")
        } catch {
            asked[at].problem = String(describing: error)
        }
    }

    func forgetConversation() { asked = [] }

    // MARK: - Drafting a quote from a description

    /// The AI features this app can actually perform.
    ///
    /// ── A LIST, BECAUSE THE ALTERNATIVE WAS A CAVEAT THAT OUTLIVED ITSELF ─
    ///
    /// The assistant pane carried one sentence over the whole list saying these
    /// run in the other app. It was true when it was written and false the hour
    /// `quote` started working here, which is how a caveat becomes a lie.
    ///
    /// So the pane asks this instead, per feature, and the note disappears from
    /// each one as it lands. ADD AN ID HERE when its feature can run — the note
    /// is the only thing telling a shop the switch does nothing on this Mac,
    /// and leaving it on a working feature is as wrong as dropping it from a
    /// missing one.
    static let aiFeaturesOnThisMac: Set<String> = ["quote"]

    static func aiRunsHere(_ id: String) -> Bool { aiFeaturesOnThisMac.contains(id) }

    /// Has the shop actually agreed to this, on this book?
    ///
    /// Asked of the shared rule rather than worked out from the settings here.
    /// `isFeatureEnabled` reads the master switch, the per-feature answer AND
    /// the consent migration — a Swift copy would be a fourth place for the
    /// three to disagree, and the one that decides whether data leaves.
    var aiCanDraftQuotes: Bool { aiQuoteAllowed }
    private(set) var aiQuoteAllowed = false

    /// What came back, in the shape the sheet's own form takes.
    struct DraftedPart: Sendable {
        var qty: Int
        var grams: Double
        var hours: Double
        var spoolId: String?
        var assumptions: [String]
    }

    /// Either a filled form or a sentence saying why not.
    ///
    /// A sentence rather than a thrown error, because every way this can go
    /// wrong is something the shop has to READ: a feature it has not switched
    /// on, a key it has not set, a provider that refused, a network that did
    /// not answer. A spinner that stops with nothing said is the one outcome
    /// that teaches people the button is broken.
    enum DraftOutcome: Sendable {
        case filled(DraftedPart)
        case refused(String)
    }

    /// Ask the assistant to fill a part from a description.
    func draftPartFromDescription(_ said: String) async -> DraftOutcome {
        guard let engine else { return .refused(words.callIt("mac.move_no_engine")) }
        do {
            let draft = try await AiClient.draftQuote(said, shop: self)
            // `defaults` are the shop's RATE fields, which this screen does not
            // take from the draft — it costs the part with `costedPart`, the
            // same call a hand-typed part goes through. Empty is honest here;
            // filling it would be pretending the model set rates it never saw.
            let out = try await engine.aiQuoteToPart(
                draft: draft, inventory: inventoryRows,
                defaults: [:], reclaimsTax: reclaimsTax)
            guard case .object(let o) = out, case .object(let part)? = o["part"] else {
                return .refused(words.callIt("mac.ai_no_draft"))
            }
            var notes: [String] = []
            if case .array(let list)? = o["assumptions"] {
                notes = list.compactMap(Self.plainString)
            }
            return .filled(DraftedPart(
                qty: Int(Self.plainNumber(part["qty"]) ?? 1),
                grams: Self.plainNumber(part["printWeight"]) ?? 0,
                hours: Self.plainNumber(part["printTime"]) ?? 0,
                spoolId: Self.plainString(part["filamentId"]),
                assumptions: notes))
        } catch AiClient.Failure.notConsented {
            return .refused(words.callIt("mac.ai_not_consented"))
        } catch AiClient.Failure.noKey {
            return .refused(words.callIt("mac.ai_no_key"))
        } catch {
            return .refused(String(describing: error))
        }
    }

    /// A product's pictures, read the way the shared rule reads them.
    ///
    /// Never by pulling `images` off the record: a product can carry the legacy
    /// `imagePath`/`thumbnail` pair, the array, or BOTH — an older build
    /// editing a record a newer one saved writes the legacy fields and leaves
    /// the array behind — and deciding which wins is exactly the migration
    /// `lib/product-images.js` exists to own.
    func pictures(of productId: String) async -> [StagedPicture] {
        guard let engine,
              let row = productRows.first(where: { Self.recordId($0) == productId }),
              let read = try? await engine.productPictures(of: row) else { return [] }
        return read.images.map {
            StagedPicture(id: $0.id, kind: $0.kind, caption: $0.caption,
                          thumbnail: $0.thumbnail, path: $0.path, bytes: nil)
        }
    }

    /// Save a product, and its pictures.
    ///
    /// `pictures` is nil for a caller that is not editing them at all, which is
    /// not the same as an empty array — that means "this product now has none"
    /// and is how the last picture is removed. The two were one value in the
    /// first draft and a product with its last photo deleted came back with the
    /// photo still on it.
    func saveProduct(_ product: Product, pictures: [StagedPicture]? = nil,
                     unlinking removed: [String] = [],
                     parts: [JSONValue]? = nil,
                     tiers: [JSONValue]? = nil, docs: [JSONValue]? = nil,
                     unlinkingDocs droppedDocs: [String] = []) async {
        moveProblem = nil
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        guard product.hasAName else {
            moveProblem = words.callIt("mac.product_need_name"); return
        }
        let keys = await allLanguageKeys()

        // ── THE BYTES GO DOWN BEFORE THE RECORD DOES ──────────────────────
        //
        // A record naming a file that was never written is a broken picture on
        // every screen that draws the catalogue. A file written for a record
        // that was never saved is a few unreferenced kilobytes nobody sees. So
        // if one of the two has to fail, it is this one, first, where the
        // failure can still be reported instead of shipped.
        var staged = pictures
        if staged != nil {
            for i in staged!.indices {
                guard let bytes = staged![i].bytes else { continue }
                do {
                    staged![i].path = try ProductPhotos.write(
                        bytes, productId: product.id, imageId: staged![i].id, in: build)
                    staged![i].bytes = nil
                } catch {
                    moveProblem = String(describing: error)
                    return
                }
            }
        }

        // The picture fields, settled BEFORE the write opens.
        //
        // `StoreWriter.update` takes a synchronous closure and the shared rule
        // lives behind an actor, so the mirroring cannot happen inside it. That
        // is the right way round anyway: this is a pure transformation of a
        // record, and doing it here keeps the write itself to the one thing a
        // write should be.
        var pictureFields: [String: JSONValue] = [:]
        if let staged {
            var draft: [String: JSONValue] = [
                "id": .string(product.id),
                // Written even when the array is EMPTY, so removing the last
                // picture actually removes it. `normalise` treats an empty
                // array beside a set `imagePath` as an unmigrated product and
                // rebuilds the array from it — which would resurrect the
                // picture just deleted — so the legacy fields are cleared here
                // in the same breath.
                "images": .array(staged.map { $0.record() }),
                "imagePath": .string(staged.first?.path ?? ""),
                "thumbnail": .string(staged.first?.thumbnail ?? ""),
            ]
            // And then the shared rule has the last word on all three, because
            // `imagePath` and `thumbnail` are what the storefront, the portal
            // and label printing still read, and a Swift copy of that mirroring
            // is a second thing to get out of step.
            if let engine, case .object(let applied)? =
                try? await engine.applyProductPictures(.object(draft)) {
                draft = applied
            }
            for key in ["images", "imagePath", "thumbnail"] {
                pictureFields[key] = draft[key] ?? .string("")
            }
        }

        // ── THE PARTS, AND THE PRICE THEY MAKE ────────────────────────────
        //
        // A product's price is not typed anywhere: it is the calculator's
        // per-part cost summed over these, plus the components, plus the
        // margin, plus the shop's rounding. So the two are written together and
        // through the SHARED rule — which `renderer/inventory.js` prices with
        // too, because two apps computing this separately is two prices for one
        // product and the customer sees whichever app saved last.
        //
        // Settled before the write opens: `StoreWriter.update` takes a
        // synchronous closure and the rule lives behind an actor.
        var partFields: [String: JSONValue] = [:]
        if let parts {
            partFields["parts"] = .array(parts)
            let forPricing = Self.pricingInput(for: product, parts: parts)
            if let engine,
               let priced = try? await engine.productPricingFields(
                .object(forPricing), inventory: inventoryRows,
                settings: settingsDict, consumables: consumableRows) {
                for (key, value) in priced { partFields[key] = value }
            }
        }

        // ── WRITTEN EVEN WHEN THE LIST IS EMPTY ───────────────────────────
        //
        // Because removing the last tier has to actually remove it. Everything
        // else about a product is merged forward from the record that was
        // there, so an absent key means "the sheet is not editing this" — and
        // an empty list has to be a list, not an absence.
        var listFields: [String: JSONValue] = [:]
        if let tiers { listFields["priceTiers"] = .array(tiers) }
        if let docs { listFields["docs"] = .array(docs) }

        var undo: [ChangedRecord] = []
        do {
            try StoreWriter.update(build) { root in
                var rows = Self.rows(root, "products")
                var record = product.record(keys: keys)
                for (key, value) in pictureFields { record[key] = value }
                for (key, value) in partFields { record[key] = value }
                for (key, value) in listFields { record[key] = value }
                if let at = rows.firstIndex(where: { Self.recordId($0) == product.id }) {
                    guard case .object(let was) = rows[at] else { return }
                    undo.append(ChangedRecord(collection: "products", id: product.id, was: was))
                    // Whatever this sheet is not editing — the components, the
                    // storefront fields, anything a newer build writes: the
                    // shop's, and none of this app's business to drop.
                    for (key, value) in was where record[key] == nil {
                        record[key] = value
                    }
                    StoreWriter.stamp(&record)
                    rows[at] = .object(record)
                } else {
                    StoreWriter.stamp(&record)
                    rows.append(.object(record))
                }
                root["products"] = .array(rows)
            }
            if !undo.isEmpty { registerMoveUndo(undo, named: words.callIt("mac.edit_product")) }
            // ONLY NOW. A file unlinked before the record is written is a file
            // the shop cannot get back if the write fails — and one unlinked
            // when the sheet was cancelled is one it never asked to lose.
            for path in removed where !path.isEmpty {
                ProductPhotos.delete(path, in: build)
            }
            for name in droppedDocs where !name.isEmpty {
                ProductDocs.delete(name, in: build)
            }
            editingProduct = nil
            await load(source)
        } catch {
            moveProblem = String(describing: error)
        }
    }

    /// A blank customer with an id in Khayt's own shape.
    ///
    /// `uid('CLI')` — prefix, base-36 milliseconds, three random base-36
    /// characters upper-cased. Matched so a customer written down here is
    /// indistinguishable from one written down in Khayt.
    static func newCustomer() -> Client {
        Client(id: uid("CLI"), createdAt: localDay())
    }

    // MARK: - Taking a job

    /// True while the new-job sheet is up.
    var takingAJob = false

    /// The job this app just created, so the table can select it.
    private(set) var lastCreated: Order.ID?

    /// The margin this shop quotes at, or thirty per cent.
    ///
    /// Its own number, not a Swift opinion about what a print shop charges —
    /// and the same default the Electron calculator opens on.
    var defaultMargin: Double {
        if case .object(let s) = settingsValue, case .number(let m)? = s["defaultMargin"] { return m }
        return 30
    }

    /// One part, in the shape the cost model reads it.
    ///
    /// The spool supplies the material and what it cost — the shelf already
    /// knows, and asking a shop to retype it is asking twice.
    private func partFor(spoolId: String?, grams: Double, hours: Double, qty: Int,
                         extra: [String: JSONValue] = [:]) -> JSONValue {
        Self.costInput(spool: spoolId.flatMap { id in spools.first { $0.id == id } },
                       grams: grams, hours: hours, qty: qty, extra: extra)
    }

    /// The part the shared cost model is handed. `extra` is the part as the
    /// book holds it — its own labour, power, wear and failure figures beat
    /// the machine's defaults inside `costPart`, exactly as they do when the
    /// other app costs the same part — and the four measured fields are
    /// written over it. Static so a test can hold it to a record.
    static func costInput(spool: Spool?, grams: Double, hours: Double, qty: Int,
                          extra: [String: JSONValue] = [:]) -> JSONValue {
        var part = extra
        part["printWeight"] = .number(max(0, grams))
        part["printTime"] = .number(max(0, hours))
        part["qty"] = .number(Double(max(1, qty)))
        if let spool {
            part["filamentId"] = .string(spool.id)
            part["material"] = .string(spool.material)
            part["spoolCost"] = .number(spool.cost ?? 0)
            // At least one gram: the cost model divides by this.
            part["spoolWeight"] = .number(max(1, spool.weight ?? 1000))
        }
        return .object(part)
    }

    /// What one part costs to make, through the shared cost model.
    ///
    /// WHAT THIS USED TO DO, AND WHY IT WAS EXPENSIVE. Wear, power, labour and
    /// the failure allowance were read from `settings.defaultWearRate` and four
    /// siblings — five keys **Khayt has never written anywhere**. The fallback
    /// branch was therefore the only branch, every one of those came out zero,
    /// and `computePartBaseCost` returned the material cost without complaint.
    /// On a real 272g / 14.9h job that is 20.40 against the 109.43 the Electron
    /// calculator quotes for the same work: a job taken here was priced at
    /// under a fifth of what it costs the shop to make.
    ///
    /// The rates now come from `lib/print-rates.js`, which holds the figures
    /// the calculator form actually opens on, tied to the HTML by a test.
    func costOfPart(spoolId: String?, grams: Double, hours: Double, qty: Int,
                    machineId: String? = nil) async -> Double {
        guard let engine else { return 0 }
        return (try? await engine.partCost(partFor(spoolId: spoolId, grams: grams,
                                                   hours: hours, qty: qty),
                                           inventory: inventoryRows, settings: settingsDict,
                                           machine: machineRow(machineId))) ?? 0
    }

    /// What a part costs, where it went, and what it was costed AT — one
    /// crossing, because all three are wanted at the same moment and the third
    /// has to be written down with the job.
    /// The parts of a product, COSTED, as the new-job sheet takes them.
    ///
    /// `Draft.from` carries the figures — grams, hours, the spool — and
    /// nothing else: what a part costs is the shared cost model's answer,
    /// asked here exactly as `addPart` asks it for a part typed by hand. It
    /// was not asked at all on this path, so a job taken from the catalogue
    /// arrived with every part at nothing and a total of nothing. That is the
    /// report behind #1254 ("I click create a job for an item in catalogue
    /// but the price is zero?"), which fixed the number parsing beside it and
    /// left the costing out. A part with nothing to cost stays at nothing and
    /// the sheet says so.
    func jobParts(from product: Product) async -> [NewJobSheet.Draft] {
        guard case .array(let rows)? = product.rest["parts"] else { return [] }
        var out: [NewJobSheet.Draft] = []
        for row in rows {
            guard var draft = NewJobSheet.Draft.from(row) else { continue }
            // AT THE PRODUCT'S OWN RATES. The part carries the labour, power,
            // wear and failure figures it was priced with in the catalogue;
            // costing it from grams and hours alone priced a 35.91 part at
            // 10.57 and opened the job at 15 where the catalogue said 50.
            if draft.isComplete,
               let costed = await costedPart(spoolId: draft.spoolId,
                                             grams: Double(draft.grams) ?? 0,
                                             hours: Double(draft.hours) ?? 0,
                                             qty: draft.qty, extra: draft.raw) {
                draft.cost = costed.cost
                draft.parts = costed.parts
                draft.rates = costed.rates
            }
            out.append(draft)
        }
        return out
    }

    /// How a product's own price reaches the job taken for it.
    ///
    /// A product priced by hand ("Your own price") sells for that figure, so
    /// the job opens with it typed in; a product rounded to a step opens
    /// rounded the same way. A product priced by its parts and margin brings
    /// only the margin, which `NewJobSheet` already takes.
    static func priceRule(of product: Product) -> PriceRule {
        var rule = PriceRule()
        if let typed = plainNumber(product.rest["priceOverride"]), typed >= 0 { rule.override = typed }
        if case .object(let r)? = product.rest["priceRound"],
           let step = plainNumber(r["step"]), step > 0 {
            rule.step = step
            rule.mode = plainString(r["mode"]) ?? "nearest"
        }
        return rule
    }

    func costedPart(spoolId: String?, grams: Double, hours: Double, qty: Int,
                    machineId: String? = nil, extra: [String: JSONValue] = [:]) async -> KhaytEngine.CostedPart? {
        guard let engine else { return nil }
        return try? await engine.costPart(partFor(spoolId: spoolId, grams: grams,
                                                  hours: hours, qty: qty, extra: extra),
                                          inventory: inventoryRows, settings: settingsDict,
                                          machine: machineRow(machineId))
    }

    /// A machine as the book holds it, for the two rates a printer knows about
    /// itself. Nil for a job on no particular machine, which is the usual case
    /// at the moment somebody is quoting it.
    private func machineRow(_ id: String?) -> JSONValue? {
        guard let id, !id.isEmpty else { return nil }
        return machineRows.first {
            if case .object(let m) = $0 { return m["id"] == .string(id) }
            return false
        }
    }


    /// A machine's `printerApi` as the shared rules want it, with the key
    /// OPENED — for the one caller that has to send it.
    ///
    /// A snapshot from a PrusaLink or OctoPrint camera is authenticated: a
    /// correct URL that sends nothing answers 401 every time. The key is opened
    /// here, at the moment it is used, and handed straight to the request — the
    /// same rule `PrinterWatch` follows, and the reason the Telegram token bug
    /// happened when somebody passed the sealed string through instead.
    ///
    /// Safe only because the caller has already pinned the host: these headers
    /// carry the shop's printer credential and must reach the printer alone.
    func printerApiRow(_ machine: Machine) async -> JSONValue? {
        guard let api = machine.printerApi, let host = api.host, !host.isEmpty else { return nil }
        var row: [String: JSONValue] = [
            "type": .string(api.type ?? ""),
            "host": .string(host),
        ]
        if let port = api.port { row["port"] = .number(Double(port)) }
        if let sealed = api.apiKey, !sealed.isEmpty, let build = source.build,
           let opened = try? await Secrets.open(sealed, for: build) {
            row["apiKey"] = .string(opened)
        }
        return .object(row)
    }

    /// What the cart comes to, before anything is written.
    ///
    /// The same `quoteTotal` the record will use, so the figure on the screen is
    /// the figure in the book.
    /// How a job's total gets its last word: rounded to a step, or typed.
    ///
    /// The same rule and steps a product's price uses (`lib/product-price.js`);
    /// `nil` step means the arithmetic stands. A typed `override` wins over
    /// the rounding, as it does on a product.
    struct PriceRule: Equatable, Sendable {
        var step: Double = 0
        var mode: String = "nearest"
        var override: Double?

        /// The product editor's own list (`lib/product-price.js` STEPS), so a
        /// product rounded to 25 opens a job the picker can show.
        static let steps: [Double] = [0, 0.5, 1, 5, 10, 25, 50, 100]
        static let modes = ["nearest", "up", "down"]

        var isPlain: Bool { step <= 0 && override == nil }

        /// The two inputs `lib/pricing.js` reads, or nothing.
        var fields: [String: JSONValue] {
            var out: [String: JSONValue] = [:]
            if step > 0 { out["priceRound"] = .object(["step": .number(step), "mode": .string(mode)]) }
            if let override { out["priceOverride"] = .number(override) }
            return out
        }
    }

    func previewQuote(baseCost: Double, margin: Double, discountPct: Double,
                      shippingCost: Double, rush: Bool,
                      agreedAmount: Double = 0, rule: PriceRule = PriceRule()) async -> QuoteTotal? {
        guard let engine else { return nil }
        var input: [String: JSONValue] = [
            "baseCost": .number(baseCost), "qty": .number(1),
            "margin": .number(margin), "discountPct": .number(discountPct),
            "shippingCost": .number(shippingCost),
            "rushEnabled": .bool(rush), "business": .bool(true),
            "agreedAmount": .number(agreedAmount),
        ]
        for (key, value) in rule.fields { input[key] = value }
        // The shop's own rush percentage, or Khayt's default of twenty-five.
        if rush {
            var pct = 25.0
            if case .object(let all) = settingsValue, case .number(let own)? = all["rushFeePct"] { pct = own }
            input["rushPct"] = .number(pct)
        }
        return try? await engine.quoteTotal(input)
    }

    /// The cart and the money, in the shape `lib/order-new.js` takes.
    /// The parts of a job, as the book records them.
    ///
    /// Pulled out of `newJobInput` so a test can call THIS rather than restate
    /// it: what a saved part carries is the whole question, and the answer has
    /// to be checkable without standing up a window.
    static func partRows(_ parts: [NewJobSheet.Draft], spools: [Spool],
                         unnamed: String) -> [JSONValue] {
        var rows: [JSONValue] = []
        for p in parts {
            var row: [String: JSONValue] = [
                "name": .string(p.name.isEmpty ? unnamed : p.name),
                "printWeight": .number(Double(p.grams) ?? 0),
                "printTime": .number(Double(p.hours) ?? 0),
                "qty": .number(Double(max(1, p.qty))),
                // What the shared cost model said, frozen: a job priced today
                // must not re-cost itself at next year's filament prices.
                "unitCost": .number(p.cost),
                "baseCost": .number(p.cost * Double(max(1, p.qty))),
            ]
            // What the customer agreed for this part, per unit. The cost above
            // is still the cost: the shared rule charges the agreed figure
            // instead of cost plus margin, and measures the margin against
            // what it really cost. See lib/price-agreements.js.
            if let agreed = p.agreedPrice { row["agreedPrice"] = .number(agreed) }
            // The rates this part was costed at, written down beside the cost.
            //
            // Not bookkeeping. `renderer/build.js` reads them straight back into
            // its form — `$('#wearRate').value = part.wearRate || ''` — so a
            // part saved without them opens in Khayt's editor with every rate
            // field blank, and the next save re-costs the job at nothing. A job
            // taken here would have lost its price on somebody else's machine,
            // with nothing said on either.
            if let rates = p.rates {
                for (key, value) in rates.fields { row[key] = value }
            }
            if let spoolId = p.spoolId, let spool = spools.first(where: { $0.id == spoolId }) {
                row["filamentId"] = .string(spool.id)
                row["material"] = .string(spool.material)
                row["spoolCost"] = .number(spool.cost ?? 0)
                row["spoolWeight"] = .number(max(1, spool.weight ?? 1000))
            }
            rows.append(.object(row))
        }
        return rows
    }

    func newJobInput(parts: [NewJobSheet.Draft], project: String, clientId: String?,
                     margin: Double, discountPct: Double, shippingCost: Double,
                     deposit: Double, rush: Bool, asQuote: Bool,
                     fromProduct product: Product? = nil,
                     rule: PriceRule = PriceRule()) -> [String: JSONValue] {
        var input: [String: JSONValue] = [
            "parts": .array(Self.partRows(parts, spools: spools,
                                          unnamed: words.callIt("mac.a_part"))),
            "project": .string(project),
            "margin": .number(margin),
            "discountPct": .number(discountPct),
            "shippingCost": .number(shippingCost),
            "depositAmount": .number(deposit),
            "rushEnabled": .bool(rush),
            "asQuote": .bool(asQuote),
        ]
        if let clientId { input["clientId"] = .string(clientId) }
        // The last word on the total — rounded to a step, or typed — travels
        // to the rule, which writes how the price was reached on the record.
        for (key, value) in rule.fields { input[key] = value }
        // ── WHAT THE PRODUCT BRINGS WITH IT ───────────────────────────────
        //
        // The components (magnets, screws, a box) and the assembly count are
        // the product's, not the parts' — they are what turns printed pieces
        // into the thing the customer buys, and the shared rule prices and
        // deducts them. Carried here because a job taken from a product and
        // then missing its packaging would under-price every sale and leave
        // the consumable count wrong on the shelf.
        if let product {
            input["productId"] = .string(product.id)
            if let components = product.rest["components"] { input["components"] = components }
            if let qty = product.rest["assemblyQty"] { input["assemblyQty"] = qty }
        }
        return input
    }

    /// The shelf and the settings, as the shared modules take them.
    ///
    /// The RAW rows, not this app's decoded `Spool` re-encoded: the cost model
    /// reads `materialType` to tell resin from filament, and `Spool` does not
    /// carry it. Re-encoding would silently cost every resin part as if it were
    /// filament.
    private(set) var inventoryRows: [JSONValue] = []

    /// `consumables` as written. See `consumableNeeds`.
    private(set) var consumableRows: [JSONValue] = []

    /// `printers` as written: the calculator's saved presets.
    private(set) var presetRows: [JSONValue] = []

    /// One saved preset, as a screen reads it.
    struct Preset: Identifiable, Hashable, Sendable {
        let id: String
        var name: String
        /// The seven figures, keyed as the book keys them.
        var rates: [String: Double] = [:]

        static let rateKeys = ["wearRate", "powerDraw", "elecRate",
                               "laborRate", "failureRate", "prepTime", "postTime"]

        @MainActor static func from(_ value: JSONValue) -> Preset? {
            guard case .object(let o) = value, case .string(let id)? = o["id"], !id.isEmpty else { return nil }
            var p = Preset(id: id, name: Shop.plainString(o["name"]) ?? id)
            for key in rateKeys { if let v = Shop.plainNumber(o[key]) { p.rates[key] = v } }
            return p
        }

        var record: JSONValue {
            var o: [String: JSONValue] = ["id": .string(id), "name": .string(name)]
            for key in Self.rateKeys { o[key] = .number(rates[key] ?? 0) }
            return .object(o)
        }
    }

    var presets: [Preset] { presetRows.compactMap(Preset.from) }

    /// Save a preset, matching the other app's rule: a name already in use is
    /// REPLACED rather than duplicated, compared without case, and the id is
    /// kept so anything pointing at it still does.
    func savePreset(name: String, rates: [String: Double]) async -> String? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, let build = source.build else {
            moveProblem = words.callIt(source.build == nil ? "mac.move_sample" : "mac.product_need_name")
            return nil
        }
        let existing = presets.first { $0.name.lowercased() == wanted.lowercased() }
        let id = existing?.id ?? "PRNTR-\(UUID().uuidString.prefix(8))"
        var preset = Preset(id: id, name: wanted)
        preset.rates = rates
        do {
            try StoreWriter.update(build) { root in
                var rows: [JSONValue] = []
                if case .array(let had)? = root["printers"] { rows = had }
                rows.removeAll {
                    if case .object(let o) = $0, case .string(let had)? = o["id"] { return had == id }
                    return false
                }
                rows.append(preset.record)
                root["printers"] = .array(rows)
            }
            await load(source)
            return id
        } catch {
            moveProblem = String(describing: error)
            return nil
        }
    }

    /// `printFiles` as written. See `setups(for:)` and `versions(for:)`.
    private(set) var fileRows: [JSONValue] = []

    /// The book as the LAN server's shared pages read it — `printLog`,
    /// `waitingList`, `settings` and `machines`, raw. See `LanServer`.
    private(set) var lanBook: [String: JSONValue] = [:]
    /// The phone's way in, while the settings say it should be running.
    var lanServer: LanServer?
    /// What the running server was started with, so a save that changed the
    /// port or the PIN restarts it and one that did not leaves it be.
    var lanRunning: LanConfig?
    var lanProblem: String?
    /// The calendar subscription token, opened, while the server runs.
    var lanCalendarToken: String?
    /// What the last "Copy quote link" did, shown beside the button.
    var quoteLinkNote: String?

    /// Which of the shop's chosen mode's features are on.
    ///
    /// ── WHY THIS EXISTS AT ALL ────────────────────────────────────────────
    ///
    /// Khayt has two modes and this app honoured neither. A shop set to
    /// Simple in the other app opened this one and found the whole
    /// Professional surface — the nine features `lib/feature-tiers.js` calls
    /// Pro, of which this app has built four. Two apps disagreeing about what
    /// a shop has bought is exactly what the shared rules exist to stop, and
    /// the mode was the one such rule nothing here read.
    ///
    /// Resolved once per load rather than asked per row: the sidebar redraws
    /// constantly and the answer only changes when the book does.
    private(set) var features: Set<String> = []

    /// Every key the tier registry knows. Asked for by name so a feature this
    /// app has not heard of is simply never gated, rather than silently off.
    static let gatedFeatures = ["analytics", "expenses", "maintenance", "zatca"]

    /// Does this shop's mode include it? Unknown keys are on: a screen this
    /// app added and forgot to classify must not vanish.
    func has(_ feature: String) -> Bool {
        Self.gatedFeatures.contains(feature) ? features.contains(feature) : true
    }

    /// How loudly a sync line should be said.
    ///
    /// A TONE rather than a colour, because `Shop` does not import SwiftUI and
    /// should not: the model says what the state IS and each window decides
    /// how it looks. That also stopped the two shells inheriting one file's
    /// private styling.
    enum SyncTone { case quiet, normal, attention }

    /// One line for every state sync can be in.
    ///
    /// ── LIFTED OUT OF THE RETIRED SHELL ───────────────────────────────────
    ///
    /// It was `Provenance.syncLine`, private to a type in `Sidebar.swift` —
    /// the window the app stopped opening with in 4.0.0-alpha.12. So the
    /// shipping shell showed no sync state at all, and nothing outside that
    /// one file read `syncStatus`.
    ///
    /// Locked is the one worth reading twice: it is not a fault, it is a shop
    /// that has not typed its passphrase since the app opened, and the data
    /// key deliberately lives no longer than that.
    var syncLine: (text: String, symbol: String, tone: SyncTone) {
        switch syncStatus {
        case .off:
            (words.callIt("mac.sync_off"), "icloud.slash", .quiet)
        case .locked:
            (words.callIt("mac.sync_locked"), "lock.icloud", .normal)
        case .idle:
            (words.callIt("mac.sync_on"), "icloud", .quiet)
        case .syncing:
            (words.callIt("mac.sync_sending"), "icloud.and.arrow.up", .normal)
        case .waiting:
            (words.callIt("mac.sync_waiting"), "clock.arrow.circlepath", .quiet)
        case .synced(let when):
            (words.callIt("mac.sync_done", ["time": .string(Shop.clockText(when))]),
             "checkmark.icloud", .quiet)
        case .failing:
            // ATTENTION, not late: it is going to be tried again and nothing
            // has been lost — the change is still in the book. Those two are
            // the difference between "this needs you when you have a moment"
            // and "this has failed".
            (words.callIt("mac.sync_retrying"), "exclamationmark.icloud", .attention)
        }
    }

    /// The time of day, in the shop's own locale.
    static func clockText(_ when: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: when)
    }

    /// The feature a whole SCREEN needs, or nil for one everybody has.
    ///
    /// ── WHY THIS IS A FUNCTION AND NOT AN `if` IN THE SIDEBAR ─────────────
    ///
    /// It was two `if`s in the sidebar, and they were in the wrong sidebar.
    /// The gate was written for the shell the app used to open with; the
    /// redesigned one has shipped by default since 4.0.0-alpha.12 and asks
    /// nothing, so a Simple shop saw Expenses and Reports exactly as a
    /// Professional one did — while the rule, the book and the old shell's
    /// gate were all correct, which is what made it so hard to place.
    ///
    /// The menu bar and the restore path never asked either, so hiding the row
    /// alone would still have left ⌘-menu and a reopened window going straight
    /// to the screen. "Simple does not include this" has to mean it cannot be
    /// reached, not that one list omits it.
    ///
    /// So the answer lives here once, and everything that can navigate asks.
    /// The waste log is deliberately absent: it is not gated in
    /// `lib/feature-tiers.js` either.
    static func gate(of shelf: Shelf) -> String? {
        switch shelf {
        case .expenses: "expenses"
        case .reports: "analytics"
        default: nil
        }
    }

    /// Can this shop reach that screen at all?
    func canShow(_ shelf: Shelf) -> Bool {
        guard let gate = Self.gate(of: shelf) else { return true }
        return has(gate)
    }

    /// What this shop's mode includes, asked of the shared rule.
    ///
    /// Internal rather than private so a test can drive it with a mode the
    /// bundled sample book does not have. Nothing proved that Simple actually
    /// HID anything through this path: every test loaded the sample, which
    /// carries no mode at all and is therefore Professional, and asserted that
    /// everything was present. So the one thing the feature exists to do was
    /// the one thing untested, and someone reading the screen could not tell
    /// whether it worked.
    func readFeatures() async {
        guard let engine else { features = Set(Self.gatedFeatures); return }
        let mode = Self.plainString(settingsDict["mode"])
        var on: Set<String> = []
        for key in Self.gatedFeatures {
            if (try? await engine.featureEnabled(key, mode: mode)) ?? true { on.insert(key) }
        }
        features = on
    }

    var settingsDict: [String: JSONValue] {
        if case .object(let s) = settingsValue { return s }
        return [:]
    }

    /// Take a new job, or quote for one.
    ///
    /// THE ORDER AND THE SETTINGS ARE WRITTEN TOGETHER. Creating a job consumes
    /// an invoice number from a counter the shop owns; saving the order without
    /// the counter hands the same number to the next job, and saving the counter
    /// without the order burns one for nothing. One swap, both records.
    func createJob(_ input: [String: JSONValue]) async {
        moveProblem = nil
        moveNotices = []
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            moveProblem = words.callIt("mac.move_no_engine"); return
        }

        var created: String?
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let orders = Self.rows(root, "printLog")
                let out = try await engine.newOrder(
                    input, orders: orders, settings: Self.settings(root), now: Date(),
                    tokens: (tracking: Self.randomBytes(16), quoteApproval: Self.randomBytes(16)))

                guard case .object(let record) = out.order,
                      case .string(let id)? = record["id"] else {
                    throw MoveRefused(sentence: self.words.callIt("mac.move_refused"))
                }
                // Newest first, the way every screen reads the book.
                root["printLog"] = .array([out.order] + orders)
                root["settings"] = .object(out.settings)
                Self.appendActivity(&root,
                                    text: "\(id)" + (record["project"].flatMap(Self.plainString).map { $0.isEmpty ? "" : " · \($0)" } ?? ""),
                                    ref: id, settings: out.settings, root: root,
                                    action: Self.plainString(record["status"]) == "quote"
                                            ? "quote_created" : "order_created")
                created = id
            }
            lastCreated = created
            await load(source)
            // Put the person on the job they just took.
            if let created {
                selection = created
                shelf = .jobs(nil)
            }
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch {
            moveProblem = String(describing: error)
        }
    }

    static func plainString(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    /// Bytes for the tokens the shared rule cannot mint itself.
    static func randomBytes(_ n: Int) -> [UInt8] {
        (0..<n).map { _ in UInt8.random(in: 0...255) }
    }

    // MARK: - Money received

    /// The job waiting for someone to say what was paid.
    var pendingPayment: PendingHold?

    /// The payment methods Khayt offers, in its own order.
    ///
    /// Not a Swift opinion about how a Saudi shop is paid: the list is
    /// `renderer/order-flows.js`'s, and the words are Khayt's own
    /// (`pay.method.*`), so the two apps offer one set of choices.
    static let paymentMethods = ["cash", "mada", "transfer", "stcpay", "applepay", "visa", "other"]

    /// Record what a customer has paid.
    ///
    /// One record changes, not three — but through the same door as a move, so
    /// the ownership check, the atomic swap and the undo are the ones already
    /// proven rather than a second set written for money.
    func recordPayment(_ id: Order.ID, amount: Double, method: String, paidAt: Date) async {
        await writeToOneOrder(id, named: words.callIt("pay.modal_title")) { order, engine, root in
            let reaches = (try? await engine.paymentOutbound(
                order: order, settings: Self.settings(root), clients: Self.rows(root, "clients"))) ?? []
            if !reaches.isEmpty { throw MoveRefused(sentence: self.words.outboundRefusal(reaches)) }

            // A payment is not a status change and Khayt writes no log line for
            // one, so neither does this.
            return OneOrderEdit(order: try await engine.recordPayment(
                order: order, amount: amount, method: method,
                paidAt: Self.localDay(paidAt), today: Self.localDay()).order)
        }
    }

    /// The job being edited.
    var pendingEdit: PendingHold?

    /// The priority a job is at, however old its record is.
    ///
    /// Read through the shared rule rather than off `order.priority`, because
    /// an older record carries only the boolean and a newer one only the level.
    func priorityOf(_ job: Order?) -> String {
        guard let job else { return "normal" }
        if let level = job.priorityLevel, Self.priorityLevels.contains(level) { return level }
        return job.priority ? "high" : "normal"
    }

    /// The priority levels, in the order a shop escalates.
    static let priorityLevels = ["normal", "high", "urgent"]

    /// Change a job's due date and priority.
    ///
    /// Two fields, not thirty: the ones a shop floor actually adjusts. Every
    /// other field the order editor writes is left exactly as it was, which the
    /// shared rule guarantees rather than this app promising it.
    func editJob(_ id: Order.ID, dueDate: Date?, priorityLevel: String,
                 price: Double? = nil) async {
        await writeToOneOrder(id, named: words.callIt("mac.edit_job")) { order, engine, _ in
            let out = try await engine.editJob(
                order: order,
                dueDate: dueDate.map(Self.localDay),
                priorityLevel: priorityLevel,
                price: price,
                now: Date(), editId: Self.uid("edit"))
            // Nothing moved: return the order untouched so the write path finds
            // no change, stamps nothing and syncs nothing.
            return OneOrderEdit(order: out.order)
        }
    }

    /// Change one part of a job, and re-cost it.
    ///
    /// ── WHY THE RATES ARE WRITTEN BACK, NOT JUST THE COST ──────────────────
    ///
    /// The Electron calculator stores all seven rates on every part it saves and
    /// its editor reads them straight back into the form. A part saved without
    /// them opens there with every rate field blank and the next save re-costs
    /// it at nothing — so a part edited here and then opened in Khayt would lose
    /// its price, quietly, on somebody else's machine. `costPart` returns the
    /// rates for exactly this reason and they go back on the record.
    ///
    /// The cost is NOT taken from whatever was on the part before. A shop that
    /// corrects a weight has corrected the price of the job, and leaving the old
    /// figure there would be a job whose parts no longer add up to its total.
    func editPart(_ orderId: Order.ID, partId: String, name: String,
                  spoolId: String?, grams: Double, hours: Double, qty: Int) async {
        let costed = await costedPart(spoolId: spoolId, grams: grams, hours: hours, qty: qty)
        let spool = spoolId.flatMap { id in spools.first { $0.id == id } }

        await writeToOneOrder(orderId, named: words.callIt("mac.edit_part")) { order, _, _ in
            OneOrderEdit(order: Self.orderWithPartEdited(
                order, partId: partId, name: name, spool: spool,
                grams: grams, hours: hours, qty: qty, costed: costed))
        }
    }

    /// The patch itself, with no store and no clock in it.
    ///
    /// Pulled out of `editPart` so it can be tested: a Shop write needs a real
    /// store on disk and an ownership record, and nothing in this suite has
    /// ever built one — which would have left the two things that lose money
    /// here (re-costing, and writing the rates back) with no test at all.
    static func orderWithPartEdited(_ order: JSONValue, partId: String, name: String,
                                    spool: Spool?, grams: Double, hours: Double, qty: Int,
                                    costed: KhaytEngine.CostedPart?) -> JSONValue {
        guard case .object(var record) = order,
              case .array(var rows)? = record["parts"] else { return order }

        for i in rows.indices {
            guard case .object(var part) = rows[i],
                  case .string(let id)? = part["id"], id == partId else { continue }

            part["name"] = .string(name)
            part["printWeight"] = .number(max(0, grams))
            part["printTime"] = .number(max(0, hours))
            part["qty"] = .number(Double(max(1, qty)))

            if let spool {
                part["filamentId"] = .string(spool.id)
                part["material"] = .string(spool.material)
                part["spoolCost"] = .number(spool.cost ?? 0)
                // At least one gram: the cost model divides by this.
                part["spoolWeight"] = .number(max(1, spool.weight ?? 1000))
            }
            if let costed {
                part["unitCost"] = .number(costed.cost)
                part["baseCost"] = .number(costed.cost)
                for (key, value) in costed.rates.fields { part[key] = value }
            }
            rows[i] = .object(part)
        }
        record["parts"] = .array(rows)
        return .object(record)
    }

    /// How long one part took, from the record rather than the decoded model.
    ///
    /// `Order.Part` does not carry `printTime` — nothing on screen needed it
    /// until a part could be edited, and adding it to the model would change
    /// what every other reader of that type decodes. The record has always had
    /// it.
    func partHours(_ orderId: Order.ID, partId: String) async -> Double? {
        guard case .object(let order)? = orderRows.first(where: {
            if case .object(let o) = $0, case .string(let id)? = o["id"] { return id == orderId }
            return false
        }), case .array(let rows)? = order["parts"] else { return nil }

        for row in rows {
            guard case .object(let part) = row,
                  case .string(let id)? = part["id"], id == partId else { continue }
            if case .number(let hours)? = part["printTime"] { return hours }
            return nil
        }
        return nil
    }

    /// What the library file this part was printed from says it weighs and takes.
    ///
    /// Nil when the part was never linked to one — a job auto-logged from a
    /// printer's own history knows a filename and nothing about the library.
    func partSuggestion(fileId: String?) async -> KhaytEngine.PartFromFile? {
        guard let engine, let fileId, let rec = row(for: fileId) else { return nil }
        return try? await engine.partFromFile(rec)
    }

    /// Hand a finished job over.
    ///
    /// Not a status change: a delivered job stays `completed` and carries a
    /// `deliveredAt`. Setting a status here would take it out of the very
    /// column the action feeds — see `KhaytOrderStatus.stageOf`.
    func markDelivered(_ id: Order.ID) async {
        await writeToOneOrder(id, named: words.callIt("queue.delivered")) { order, engine, _ in
            let out = try await engine.markDelivered(order: order, now: Date())
            guard out.ok, let changed = out.order else {
                throw MoveRefused(sentence: self.words.callIt("mac.not_finished_yet"))
            }
            // The same line Khayt and Bed Ready write.
            return OneOrderEdit(order: changed, activity: "\(id) → delivered")
        }
    }

    /// The parcel left the shop.
    ///
    /// Like `markDelivered`, this does not move the status — a job in the post
    /// is finished work, and giving it a status of its own would take it out of
    /// every figure that counts finished work. `lib/order-status.js` owns the
    /// rule; this is the same call Khayt makes.
    func markShipped(_ id: Order.ID) async {
        await writeToOneOrder(id, named: words.callIt("queue.shipped")) { order, engine, _ in
            let out = try await engine.markShipped(order: order, now: Date())
            guard out.ok, let changed = out.order else {
                throw MoveRefused(sentence: self.words.callIt("mac.not_finished_yet"))
            }
            return OneOrderEdit(order: changed, activity: "\(id) → shipped")
        }
    }

    /// Undo a payment: the money was never received, or was recorded against
    /// the wrong job. Nothing leaves the shop, so nothing is refused.
    func clearPayment(_ id: Order.ID) async {
        await writeToOneOrder(id, named: words.callIt("mac.clear_payment")) { order, engine, _ in
            OneOrderEdit(order: try await engine.clearPayment(order: order).order)
        }
    }

    /// The shape both money edits share: one order, changed by the shared rules,
    /// written and stamped inside the same swap every other edit uses.
    private func writeToOneOrder(_ id: Order.ID, named actionName: String,
                                 change: @escaping (JSONValue, KhaytEngine, [String: JSONValue])
                                 async throws -> OneOrderEdit) async {
        moveProblem = nil
        moveNotices = []
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            moveProblem = words.callIt("mac.move_no_engine"); return
        }

        var undo: [ChangedRecord] = []
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let orders = Self.rows(root, "printLog")
                guard let target = orders.first(where: { Self.recordId($0) == id }) else {
                    throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                }
                let edit = try await change(target, engine, root)
                Self.write(&root, "printLog", changed: [edit.order], before: orders, into: &undo)
                // The shared rules ask for this and it is the app's to write. A
                // handover that reached the book but not the log would be the
                // one status change a shop most often has to explain later,
                // recorded nowhere.
                if let text = edit.activity {
                    Self.appendActivity(&root, text: text, ref: id,
                                        settings: Self.settings(root), root: root)
                }
            }
            registerMoveUndo(undo, named: actionName)
            await load(source)
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch {
            moveProblem = String(describing: error)
        }
    }

    /// One order after a rule changed it, and the line it asked for in the log.
    struct OneOrderEdit {
        let order: JSONValue
        var activity: String? = nil
    }

    // MARK: - Labels for work going out the door

    /// The shop's portal address, for a label's QR to point at.
    ///
    /// Empty when the cloud is not connected, which is what makes
    /// `ShelfLabels.orderCode` fall back to the code the shop's own phone
    /// reads rather than printing a link to nowhere.
    var cloudLabelBase: String {
        guard cloudConnected, case .object(let cloud)? = settingsDict["cloud"],
              case .string(let url)? = cloud["url"] else { return "" }
        return url
    }

    /// Build a printable sheet of ORDER labels, for the jobs given.
    ///
    /// The shelf could be labelled from this app and a job could not, so a box
    /// going out of the door had to be labelled from the other one. Same sheet
    /// builder, same QR rule, same preview before anything is printed.
    func askForOrderLabels(_ ids: [Order.ID]) async {
        let chosen = orderRows.filter { row in
            guard let id = Self.recordId(row) else { return false }
            return ids.contains(id)
        }
        guard !chosen.isEmpty, let engine else { return }
        let entries = chosen.map { ShelfLabels.entry(forOrder: $0, shop: self) }
        let heading = words.callIt("lbl.orders")
        guard let html = try? await engine.labelSheet(entries, heading: heading) else { return }
        pendingLabels = LabelSheetRequest(html: html, count: chosen.count)
    }

    // MARK: - What the shop has on order

    /// Purchase orders, as the book holds them.
    private(set) var purchaseOrderRows: [JSONValue] = []

    /// The shop's suppliers, with whatever they quote.
    private(set) var supplierRows: [JSONValue] = []

    /// What is low and has not already been ordered.
    private(set) var needsOrdering: [KhaytEngine.ToOrder] = []

    /// Orders asking for about a thousand times what they should.
    private(set) var suspectOrders: [KhaytEngine.SuspectOrder] = []

    /// The order being received, or nil.
    var receivingGoods: PurchaseOrder?

    /// Everything still to arrive, worst-waited first.
    ///
    /// A received order is history; what a shop looking at a thin shelf wants
    /// to know is what is COMING. `received` orders are left out for that
    /// reason, not hidden.
    var openOrders: [PurchaseOrder] {
        purchaseOrderRows.compactMap(PurchaseOrder.init(row:))
            .filter { $0.status != "received" }
            .sorted { a, b in
                // Oldest first: the one waited on longest is the one to chase.
                if a.orderedAt != b.orderedAt { return a.orderedAt < b.orderedAt }
                return a.id < b.id
            }
    }

    /// Draft an order for everything that is low and not already coming.
    ///
    /// ONE WRITE, not one per item. A shop that pressed this and got four of
    /// six orders because the fifth item had been deleted underneath would have
    /// a book it cannot reason about; the whole batch lands or none of it does.
    ///
    /// The list is re-read INSIDE the write for the same reason every other
    /// write here re-reads: what was low a minute ago may be on its way now.
    ///
    /// Returns the number drafted, or nil with `moveProblem` set.
    func draftWhatIsLow() async -> Int? {
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            moveProblem = words.callIt("mac.read_only"); return nil
        }
        guard let engine else { moveProblem = words.callIt("mac.move_no_engine"); return nil }

        var drafted = 0
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let wanted = try await engine.needsOrdering(
                    spools: Self.rows(root, "inventory"),
                    consumables: Self.rows(root, "consumables"),
                    orders: Self.rows(root, "printLog"),
                    purchaseOrders: Self.rows(root, "purchaseOrders"),
                    settings: Self.settings(root), now: Date())
                guard !wanted.isEmpty else { throw NothingWasLow() }

                var orders = Self.rows(root, "purchaseOrders")
                let suppliers = Self.rows(root, "suppliers")
                let today = Self.localDay()
                for want in wanted {
                    let shelf = Self.rows(root, want.consumable ? "consumables" : "inventory")
                    guard let item = shelf.first(where: { Self.recordId($0) == want.id }) else { continue }
                    var ask: [String: JSONValue] = [
                        "status": .string("draft"),
                        // The RULE's figure for how much to buy, not a default:
                        // it is what covers the days of cover the shop asked
                        // for, and a spool's own reorder quantity would ignore
                        // how fast this one is actually going.
                        "qty": .number(want.quantity),
                    ]
                    var supplierName = ""
                    if want.consumable {
                        ask["kind"] = .string("consumable")
                    } else {
                        let price = try await engine.perGramPrice(item: item, suppliers: suppliers)
                        if price.perG > 0 { ask["unitPrice"] = .number(price.perG) }
                        if let id = price.supplierId, !id.isEmpty { ask["supplierId"] = .string(id) }
                        supplierName = price.supplierName
                    }
                    orders.insert(try await engine.draftOrder(
                        item: item, ask: ask, id: Self.uid("PO"),
                        today: today, supplierName: supplierName), at: 0)
                    drafted += 1
                }
                root["purchaseOrders"] = .array(orders)
            }
        } catch is NothingWasLow {
            moveProblem = words.callIt("po.none_needed"); return nil
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence; return nil
        } catch {
            moveProblem = String(describing: error); return nil
        }
        await load(source)
        return drafted
    }

    /// Nothing was low by the time the write opened. Not a fault.
    private struct NothingWasLow: Error {}

    /// Order more of something.
    ///
    /// ── WHAT THIS APP DECIDES, WHICH IS ALMOST NOTHING ────────────────────
    ///
    /// How much to ask for, what to call the order, whether it is counted in
    /// grams or the shop's own unit, and what a gram costs are all decided by
    /// `lib/purchase-orders.js` and `lib/reorder.js`. This finds the record,
    /// asks them, and writes what comes back.
    ///
    /// The price is the one worth naming: a per-SPOOL cost against a quantity
    /// measured in GRAMS is what made auto-drafted orders about a thousand
    /// times too expensive, and it is why `po-audit` exists. That division is
    /// the shared rule's, not this app's.
    ///
    /// Drafted, never ordered. A purchase order is something a shop sends to a
    /// supplier, and an app that sent one because somebody chose a menu item
    /// would be doing something on their behalf that they cannot take back.
    ///
    /// Returns nil when it worked, or what to tell the shop.
    func draftOrder(for itemId: String, consumable: Bool) async -> String? {
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            return words.callIt("mac.read_only")
        }
        guard let engine else { return words.callIt("mac.move_no_engine") }

        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let shelf = Self.rows(root, consumable ? "consumables" : "inventory")
                guard let item = shelf.first(where: { Self.recordId($0) == itemId }) else {
                    throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                }
                var ask: [String: JSONValue] = ["status": .string("draft")]
                var supplierName = ""
                if consumable {
                    ask["kind"] = .string("consumable")
                } else {
                    // A material nothing prices carries NO price, rather than a
                    // price of nothing: `draft` leaves `unitPrice` out when the
                    // caller asks for none, and a receipt against an order with
                    // no price books no expense instead of one for zero.
                    let price = try await engine.perGramPrice(item: item,
                                                              suppliers: Self.rows(root, "suppliers"))
                    if price.perG > 0 { ask["unitPrice"] = .number(price.perG) }
                    if let id = price.supplierId, !id.isEmpty { ask["supplierId"] = .string(id) }
                    supplierName = price.supplierName
                }
                let drafted = try await engine.draftOrder(
                    item: item, ask: ask, id: Self.uid("PO"),
                    today: Self.localDay(), supplierName: supplierName)

                var orders = Self.rows(root, "purchaseOrders")
                orders.insert(drafted, at: 0)
                root["purchaseOrders"] = .array(orders)
            }
        } catch let refusal as MoveRefused {
            return refusal.sentence
        } catch {
            return String(describing: error)
        }
        await load(source)
        return nil
    }

    /// Book goods in against an order.
    ///
    /// ── FOUR RECORDS, ONE WRITE ───────────────────────────────────────────
    ///
    /// The order, the spool or the consumable, that spool's history line, and
    /// an expense. The shared rule returns all four and this writes all four in
    /// ONE swap — both faults this chain has carried were one of them going
    /// missing on its own: a consumable order that restocked nothing and marked
    /// itself received, and a filament receipt that booked no expense at all.
    ///
    /// Returns nil when it worked, or what to tell the shop.
    func receiveGoods(_ id: String, quantity: Double, notes: String) async -> String? {
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            return words.callIt("mac.read_only")
        }
        guard let engine else { return words.callIt("mac.move_no_engine") }
        guard quantity > 0 else { return words.callIt("exp.amount_required") }

        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                // Read INSIDE the write: a receipt computed from the in-memory
                // copy would put a stale shelf back. `StoreWriter` says so.
                var orders = Self.rows(root, "purchaseOrders")
                guard let at = orders.firstIndex(where: { Self.recordId($0) == id }) else {
                    throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                }
                let order = orders[at]
                let consumable = try await engine.isConsumableOrder(order)
                let itemId = Self.itemId(of: order)

                var shelf = Self.rows(root, "inventory")
                var bits = Self.rows(root, "consumables")
                let spoolAt = consumable ? nil : shelf.firstIndex { Self.recordId($0) == itemId }
                let bitAt = consumable ? bits.firstIndex { Self.recordId($0) == itemId } : nil

                let done = try await engine.receiveGoods(
                    order: order,
                    item: spoolAt.map { shelf[$0] },
                    consumable: bitAt.map { bits[$0] },
                    quantity: quantity, notes: notes, today: Self.localDay(),
                    expenseId: Self.uid("EXP"),
                    expenseLabel: self.words.callIt("po.receive"))
                guard done.ok, let written = done.po else {
                    throw MoveRefused(sentence: self.words.callIt("exp.amount_required"))
                }

                orders[at] = written
                root["purchaseOrders"] = .array(orders)
                if let spoolAt, let item = done.item {
                    shelf[spoolAt] = item
                    root["inventory"] = .array(shelf)
                }
                if let bitAt, let bit = done.consumable {
                    bits[bitAt] = bit
                    root["consumables"] = .array(bits)
                }
                if let expense = done.expense {
                    var spend = Self.rows(root, "expenses")
                    spend.append(expense)
                    root["expenses"] = .array(spend)
                }
            }
        } catch let refusal as MoveRefused {
            return refusal.sentence
        } catch {
            return String(describing: error)
        }
        await load(source)
        return nil
    }

    /// Close an order by hand: the goods are all in, whatever was counted.
    func closeOrder(_ id: String) async -> String? {
        await writeToOnePurchaseOrder(id) { order, engine in
            try await engine.closeOrder(order, today: Self.localDay())
        }
    }

    /// Correct one order priced per spool where a per-gram rate was expected.
    ///
    /// The rule decides the figure and refuses an order that no longer looks
    /// affected — which is what makes a list read a minute ago harmless.
    func correctOrderPrice(_ id: String) async -> String? {
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            return words.callIt("mac.read_only")
        }
        guard let engine else { return words.callIt("mac.move_no_engine") }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var orders = Self.rows(root, "purchaseOrders")
                let out = try await engine.correctOrderPrice(
                    orders: orders, inventory: Self.rows(root, "inventory"), orderId: id)
                guard out.ok, let fixed = out.po,
                      let at = orders.firstIndex(where: { Self.recordId($0) == id }) else {
                    throw MoveRefused(sentence: self.words.callIt("mac.order_not_suspect"))
                }
                orders[at] = fixed
                root["purchaseOrders"] = .array(orders)
            }
        } catch let refusal as MoveRefused {
            return refusal.sentence
        } catch {
            return String(describing: error)
        }
        await load(source)
        return nil
    }

    /// One purchase order changed by a rule, written through the same swap.
    private func writeToOnePurchaseOrder(
        _ id: String,
        change: @escaping (JSONValue, KhaytEngine) async throws -> JSONValue
    ) async -> String? {
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            return words.callIt("mac.read_only")
        }
        guard let engine else { return words.callIt("mac.move_no_engine") }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var orders = Self.rows(root, "purchaseOrders")
                guard let at = orders.firstIndex(where: { Self.recordId($0) == id }) else {
                    throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                }
                orders[at] = try await change(orders[at], engine)
                root["purchaseOrders"] = .array(orders)
            }
        } catch let refusal as MoveRefused {
            return refusal.sentence
        } catch {
            return String(describing: error)
        }
        await load(source)
        return nil
    }

    /// Which shelf record an order restocks.
    static func itemId(of order: JSONValue) -> String {
        guard case .object(let o) = order else { return "" }
        return plainString(o["itemId"]) ?? ""
    }

    // MARK: - Money an old defect took off the book

    /// Orders whose deposit was erased when their payment plan was saved.
    ///
    /// ── WHY THIS APP HAD TO GROW ONE ──────────────────────────────────────
    ///
    /// Saving an order that had instalments used to write the collected
    /// instalment total straight over `paidAmount`, erasing the deposit the
    /// shop had already taken. The code is fixed; the books written before it
    /// are not. Khayt has shown a banner about it since the fix — this app
    /// showed nothing, so a shop working here was chasing customers for money
    /// they had already handed over and had no way to find out.
    ///
    /// Read at load with everything else, because the answer only changes when
    /// the book does.
    private(set) var erasedDeposits: [KhaytEngine.ErasedDeposit] = []

    /// What the affected orders are understating by, in total.
    var depositsUnaccounted: Double {
        (erasedDeposits.reduce(0) { $0 + $1.lost } * 100).rounded() / 100
    }

    /// Whether the review sheet is open.
    var reviewingDeposits = false

    /// Put one order's paid figure back.
    ///
    /// Through `writeToOneOrder` like every other money edit, so it takes the
    /// same ownership check, the same atomic swap and the same undo — a repair
    /// a shop cannot take back would be a worse thing to offer than none.
    ///
    /// The REPAIR is the shared rule's: this app does not decide what the
    /// figure should be, and the rule refuses an order that no longer looks
    /// affected, which is what makes a list read a minute ago harmless.
    func restoreDeposit(_ id: Order.ID) async {
        await writeToOneOrder(id, named: words.callIt("dep.restore_btn")) { _, engine, root in
            let out = try await engine.restoreDeposit(orders: Self.rows(root, "printLog"),
                                                      orderId: id)
            guard out.ok, let repaired = out.order else {
                throw MoveRefused(sentence: self.words.callIt("mac.deposit_not_affected"))
            }
            // A money figure changing under a shop's feet is exactly what the
            // activity log is for.
            return OneOrderEdit(order: repaired,
                                activity: "\(id) → " + self.words.callIt("dep.restored"))
        }
    }

    // MARK: - Paying over months

    /// The job whose payment plan is open, or nil.
    ///
    /// ── WHY THIS HAD TO EXIST ─────────────────────────────────────────────
    ///
    /// A customer paying a large job over three months could be SET UP only in
    /// the Electron app. This app read the plan — aged debt on the Spending
    /// screen already bills each instalment from its own due date — and could
    /// neither write one nor collect one. A Mac-only shop that agreed a plan on
    /// the phone had nowhere to put it, and `engine.buildSchedule` sat in the
    /// engine with tests and no caller: the rule was right and nothing reached
    /// it. That is this book's most-repeated fault, not a missing screen.
    var planFor: Order?

    /// Write a plan onto a job: three payments, a month apart, covering what is
    /// still owed.
    ///
    /// Every figure here comes from `lib/payment-plan.js` and
    /// `lib/order-money.js`. What is OWED — not the price — is the rule's own
    /// subtraction, gift cards and credit notes included: a plan built on
    /// price − paidAmount bills a customer for a credit note they were already
    /// given, and one built on the gross price bills the deposit twice.
    func makePlan(_ id: Order.ID) async {
        await writeToOneOrder(id, named: words.callIt("inst.generate")) { order, engine, _ in
            let owed = try await engine.owedRaw(order: order)
            guard case .object(var record) = order else {
                throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
            }
            guard owed > 0 else {
                // Two different refusals, because they need two different
                // answers: a job with no price needs one typing in, and a
                // settled job needs nothing at all.
                let price = (Self.plainNumber(record["price"]) ?? 0)
                throw MoveRefused(sentence: self.words.callIt(
                    price > 0 ? "inst.nothing_owed" : "inst.need_price"))
            }
            let plan = try await engine.monthlyPlan(owed: owed, today: Self.localDay())
            guard !plan.isEmpty else {
                throw MoveRefused(sentence: self.words.callIt("inst.nothing_owed"))
            }
            record["instalments"] = .array(plan.map { row in
                .object([
                    "id": .string(Self.uid("INS")),
                    "amount": .number(row.amount),
                    "dueDate": .string(row.dueDate),
                    "note": .string(""),
                    "paid": .bool(false),
                    "paidAt": .null,
                ])
            })
            // The cash the job holds RIGHT NOW. The plan covers the balance, so
            // its rows are money on top of this rather than instead of it —
            // without this figure, collecting the plan in full either erases the
            // deposit or leaves it owed forever. Written only here, by the
            // generator, exactly as Khayt writes it.
            record["instalmentBase"] = .number((Self.plainNumber(record["paidAmount"]) ?? 0))
            return OneOrderEdit(order: .object(record),
                                activity: "\(id) → " + self.words.callIt("inst.title"))
        }
    }

    /// Collect one payment of a plan — or put it back.
    ///
    /// ── UNCOLLECTING DOES NOT TAKE THE MONEY BACK ─────────────────────────
    ///
    /// `collectionTotals` never returns less than the job already holds, and
    /// that is deliberate: `paidAmount` is the authoritative cash figure and can
    /// have grown since the plan was made — a payment taken at the counter and
    /// typed straight in. Lowering it here would destroy that cash. So clearing
    /// a row clears the ROW, and the notice says where the cash figure is
    /// corrected. An immediate mis-tap is ⌘Z, which puts both back.
    func collect(_ id: Order.ID, rowId: String, collected: Bool) async {
        await writeToOneOrder(id, named: words.callIt("inst.mark_paid")) { order, engine, _ in
            guard case .object(var record) = order,
                  case .array(let rows)? = record["instalments"] else {
                throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
            }
            let today = Self.localDay()
            var written: [JSONValue] = []
            var found = false
            for row in rows {
                guard case .object(var entry) = row else { written.append(row); continue }
                if case .string(let rid)? = entry["id"], rid == rowId {
                    found = true
                    entry["paid"] = .bool(collected)
                    // The day it was collected, cleared when it is put back:
                    // a row reading "not collected" with a collection date on
                    // it is a row two readers would answer differently.
                    entry["paidAt"] = collected ? .string(today) : .null
                }
                written.append(.object(entry))
            }
            guard found else { throw MoveRefused(sentence: self.words.callIt("mac.move_gone")) }

            let held = (Self.plainNumber(record["paidAmount"]) ?? 0)
            var base: Double?
            if case .number(let b)? = record["instalmentBase"] { base = b }
            let totals = try await engine.collectionTotals(
                price: (Self.plainNumber(record["price"]) ?? 0), paidAmount: held,
                instalments: written, instalmentBase: base)
            record["instalments"] = .array(written)
            record["paidAmount"] = .number(totals.paidAmount)
            record["paymentStatus"] = .string(totals.paymentStatus)
            if !collected && totals.paidAmount >= held {
                self.moveNotices = [self.words.callIt("mac.plan_cash_stays")]
            }
            return OneOrderEdit(order: .object(record))
        }
    }

    /// Take the plan off a job.
    ///
    /// The plan goes; the money does not. Cash already collected stays on
    /// `paidAmount` because it was received — a schedule is an agreement about
    /// WHEN, not a record of what arrived. `instalmentBase` goes with the plan:
    /// it is meaningless without one, and a stale base left behind would be
    /// added to the next plan's collections.
    func dropPlan(_ id: Order.ID) async {
        await writeToOneOrder(id, named: words.callIt("common.remove")) { order, _, _ in
            guard case .object(var record) = order else {
                throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
            }
            record["instalments"] = .null
            record["instalmentBase"] = .null
            return OneOrderEdit(order: .object(record))
        }
    }

    /// What one job still owes, by the rule every other owed figure uses.
    ///
    /// Asked of the engine rather than subtracted here: `orderOwedRaw` takes
    /// gift cards and credit notes off as well as the cash, and it is the same
    /// figure the masthead and the Spending screen already show — a second
    /// subtraction would give the plan sheet an opinion of its own about what a
    /// customer owes.
    func owedOn(_ id: Order.ID) async -> Double? {
        guard let engine,
              let raw = orderRows.first(where: { Self.recordId($0) == id }) else { return nil }
        return try? await engine.owedRaw(order: raw)
    }

    // MARK: - What the customer thought

    /// The job whose rating is being written down, or nil.
    var ratingFor: Order?

    /// Record what a customer said about a finished job.
    ///
    /// ── WHY THIS HAD TO EXIST ─────────────────────────────────────────────
    ///
    /// A rating could only reach this book one way: a customer opening the
    /// portal on their phone and submitting it. A shop that rings a customer
    /// and hears "yes, five out of five" had nowhere to put it — while the
    /// Reports screen draws a ratings line that, on a Mac-only shop, could
    /// never fill.
    ///
    /// `recordedAt`, NOT `submittedAt`. The customer portal writes
    /// `submittedAt` and this writes `recordedAt`, which is the other app's own
    /// split: one is the customer saying it, the other is the shop writing it
    /// down, and a book that cannot tell them apart has lost the difference.
    func recordRating(_ id: Order.ID, rating: Int, comment: String) async {
        // Bounds from the rule that READS them, so a rating this app writes is
        // one the chart will draw. `RatingTrend.ratingOf` refuses anything
        // outside 1–5, and a rating stored outside it would sit in the book
        // looking recorded and count for nothing.
        guard Double(rating) >= RatingTrend.minRating,
              Double(rating) <= RatingTrend.maxRating else {
            moveProblem = words.callIt("mac.rating_out_of_range"); return
        }
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = ISO8601DateFormatter().string(from: Date())
        await writeToOneOrder(id, named: words.callIt("ord.record_survey")) { order, _, _ in
            guard case .object(var o) = order else {
                throw MoveRefused(sentence: self.words.callIt("mac.move_refused"))
            }
            // Only a FINISHED job has anything to rate — the other app offers
            // this on finished work alone, and a rating on a job still on the
            // bench would be counted by every reader as the finished job's.
            guard case .string(let status)? = o["status"],
                  RatingTrend.finishedStatuses.contains(status) else {
                throw MoveRefused(sentence: self.words.callIt("mac.not_finished_yet"))
            }
            o["survey"] = .object(["rating": .number(Double(rating)),
                                   "comment": .string(comment),
                                   "recordedAt": .string(now)])
            return OneOrderEdit(order: .object(o),
                                activity: "\(id) rated \(rating)/5")
        }
    }

    /// What a job already carries, for the sheet to open on.
    func ratingOn(_ id: Order.ID) -> (rating: Int, comment: String) {
        guard let row = orderRows.first(where: { Self.recordId($0) == id }),
              case .object(let o) = row, case .object(let survey)? = o["survey"]
        else { return (0, "") }
        let rating = Int(JSSemantics.number(survey["rating"]))
        var comment = ""
        if case .string(let c)? = survey["comment"] { comment = c }
        return (rating, comment)
    }

    // MARK: - Several prints that are one object

    /// The kits in this book, each already totalled.
    ///
    /// A figure printed as Head, Hand, Body and Legs is four jobs and four
    /// print-log entries, and "what did that figure cost me" was arithmetic
    /// across four rows that nobody does. Grouped ACROSS orders rather than
    /// merged into one, because the actuals live on the order — folding four
    /// jobs into one would replace four measured numbers with one, and those
    /// are what the estimator calibrates from.
    private(set) var kits: [KhaytEngine.PrintKit] = []

    /// `settings.kits` as written — `[{id, name}]`. Kept raw because every
    /// rule that touches a kit name takes this list, and re-encoding a decoded
    /// Swift struct would be a second opinion about its shape.
    private(set) var kitDefs: [JSONValue] = []

    /// The kit this job is filed under, if any.
    func kit(of id: Order.ID) -> KhaytEngine.PrintKit? {
        kits.first { $0.jobIds.contains(id) }
    }

    /// Read the kits back after the book changed. Called from `load`.
    private func readKits(_ root: [String: JSONValue]) async {
        if case .array(let rows)? = Self.settings(root)["kits"] { kitDefs = rows }
        else { kitDefs = [] }
        kits = (try? await engine?.kits(orders: orderRows, defs: kitDefs)) ?? []
    }

    /// File every job named under one kit, creating it if the name is new.
    ///
    /// ONE WRITE for all of them, and the settings change in the same write:
    /// a kit whose definition reached the book while its jobs did not is a
    /// name attached to nothing, and the reverse is an orphan. Both are
    /// recoverable and neither should be produced by a crash in the middle.
    func fileJobs(_ ids: [Order.ID], inKitNamed name: String) async {
        guard !ids.isEmpty, let build = source.build, let engine else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        // Through the engine, so a name matching one the shop already uses IS
        // that kit rather than a second one holding half the rollup.
        guard let resolved = try? await engine.resolveKitName(
            clean, known: kitDefs, newId: Self.mintKitId(clean)) else {
            writeProblem = words.callIt("mac.kit_unknown"); return
        }
        await writeKits(build, named: words.callIt("mac.file_in", ["name": .string(resolved.name)])) { root in
            var settings = Self.settings(root)
            var defs = Self.kitRows(settings)
            if !defs.contains(where: { Self.recordId($0) == resolved.id }) {
                defs.append(.object(["id": .string(resolved.id), "name": .string(resolved.name)]))
            }
            settings["kits"] = .array(defs)
            root["settings"] = .object(settings)
            Self.stampKit(&root, ids: Set(ids), to: resolved.id)
        }
    }

    /// Kit names one or two edits from this one, to ask about before filing.
    ///
    /// Asked by the view rather than inside `fileJobs`, because the answer is a
    /// QUESTION for the shop and not a decision this app may make: "Leg L" and
    /// "Leg R" are one edit apart and genuinely different.
    func nearKits(_ name: String) async -> [KhaytEngine.NearKitName] {
        guard let engine else { return [] }
        return (try? await engine.similarKitNames(name, known: kitDefs)) ?? []
    }

    /// Take jobs back out.
    ///
    /// Grouping after the fact means grouping the wrong things sometimes, and
    /// until this existed the only correction was disbanding the whole kit —
    /// which is why anyone would rather leave it wrong.
    ///
    /// A definition left pointing at nothing goes with them. The jobs are what
    /// a kit IS; with none left there is nothing to keep, and the name is
    /// clutter the shop reads past every time it files something.
    func unfileJobs(_ ids: [Order.ID]) async {
        guard !ids.isEmpty, let build = source.build else { return }
        await writeKits(build, named: words.callIt("mac.remove_from_kit")) { root in
            Self.stampKit(&root, ids: Set(ids), to: nil)
        }
        await sweepEmptyKits()
    }

    /// Drop kit names no job points at any more.
    ///
    /// A SECOND transaction, after the jobs have moved and the book has been
    /// read back, because the rule that answers this is asynchronous and the
    /// store write is not. That is the right way round anyway: taking jobs out
    /// is the shop's action, and sweeping up a name attached to nothing is a
    /// tidy-up. A crash between the two leaves an empty kit name — which is
    /// exactly the state `lib/print-kits.js` chose to report rather than act
    /// on, and one more filing puts it back to work.
    private func sweepEmptyKits() async {
        guard let build = source.build, let engine, !kitDefs.isEmpty else { return }
        let dead = Set((try? await engine.emptyKitIds(orders: orderRows, defs: kitDefs)) ?? [])
        guard !dead.isEmpty else { return }
        await writeKits(build, named: words.callIt("mac.remove_from_kit")) { root in
            var settings = Self.settings(root)
            settings["kits"] = .array(Self.kitRows(settings)
                .filter { !dead.contains(Self.recordId($0) ?? "") })
            root["settings"] = .object(settings)
        }
    }

    /// Rename a kit — and ADOPT an orphan.
    ///
    /// A kit whose definition was deleted still groups its jobs, and there was
    /// no way back: the jobs were stuck in something unnameable. Naming one
    /// writes the definition again.
    ///
    /// Refuses a name another kit already holds rather than merging into it.
    /// Merging would move somebody else's jobs on the strength of a typo, and
    /// "reuse the kit with this name" is a rule that belongs to FILING, where
    /// the shop has just chosen which jobs are involved.
    func renameKit(_ kitId: String, to name: String) async {
        guard let build = source.build else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let folded = clean.lowercased()
        if let taken = kitDefs.first(where: {
            Self.recordId($0) != kitId && Self.kitName($0)?.lowercased() == folded
        }), let other = Self.kitName(taken) {
            writeProblem = words.callIt("mac.kit_name_taken", ["name": .string(other)])
            return
        }
        await writeKits(build, named: words.callIt("mac.rename_kit")) { root in
            var settings = Self.settings(root)
            var defs = Self.kitRows(settings)
            if let at = defs.firstIndex(where: { Self.recordId($0) == kitId }) {
                guard case .object(var def) = defs[at] else { return }
                def["name"] = .string(clean)
                defs[at] = .object(def)
            } else {
                // The orphan, adopted.
                defs.append(.object(["id": .string(kitId), "name": .string(clean)]))
            }
            settings["kits"] = .array(defs)
            root["settings"] = .object(settings)
        }
    }

    /// Take every job out of a kit and forget the kit. The prints are untouched.
    func disbandKit(_ kitId: String) async {
        guard let build = source.build else { return }
        let ids = Set(kits.first { $0.id == kitId }?.jobIds ?? [])
        await writeKits(build, named: words.callIt("mac.disband_kit")) { root in
            Self.stampKit(&root, ids: ids, to: nil)
            var settings = Self.settings(root)
            let defs = Self.kitRows(settings)
            settings["kits"] = .array(defs.filter { Self.recordId($0) != kitId })
            root["settings"] = .object(settings)
        }
    }

    /// Put `kitId` on some jobs, or take it off, stamping only what changed.
    ///
    /// REMOVED rather than set to an empty string. `groupByKit` reads the field
    /// with a trim and treats blank as ungrouped, so an empty string would work
    /// — right up until the record syncs to a machine running a build that
    /// checks the key's presence instead.
    static func stampKit(_ root: inout [String: JSONValue],
                                 ids: Set<String>, to kitId: String?) {
        guard !ids.isEmpty, case .array(var rows)? = root["printLog"] else { return }
        var touched = false
        for i in rows.indices {
            guard case .object(var record) = rows[i],
                  let id = recordId(rows[i]), ids.contains(id) else { continue }
            let was = record["kitId"]
            if let kitId { record["kitId"] = .string(kitId) } else { record["kitId"] = nil }
            guard record["kitId"] != was else { continue }
            StoreWriter.stamp(&record)
            rows[i] = .object(record)
            touched = true
        }
        guard touched else { return }
        root["printLog"] = .array(rows)
    }

    /// The shared shape of every kit edit: one guarded write, then re-read.
    ///
    /// `named` is carried for the Edit menu's benefit the day these become
    /// undoable; the write itself is one transaction either way.
    private func writeKits(_ build: StoreReader.Build, named actionName: String,
                           change: @escaping (inout [String: JSONValue]) -> Void) async {
        do {
            try StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in change(&root) }
            writeProblem = nil
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// A kit id from the name the shop typed, salted so two kits called the
    /// same thing on two machines do not collide into one after a sync.
    ///
    /// ── AND IT IS `uid`, NOT A STRING BUILT HERE ──────────────────────────
    ///
    /// Twice now this was written inline and twice `WordsAreTranslatedTests`
    /// refused it. That guard flags any short literal carrying an
    /// interpolation, because that is the shape of a unit written in Swift
    /// where the catalogue has a word for it — `"\(n) kg"` — and it cannot
    /// tell one from an id prefix. First it caught the English fallback "kit";
    /// with that gone it caught "KIT-" itself.
    ///
    /// The guard is not wrong either time, and the answer was already in this
    /// file: every other id in the app comes from `uid(_:)`, which takes the
    /// prefix as an ARGUMENT so no literal ever sits next to an interpolation.
    /// A kit id is an id like any other and had no business being special.
    ///
    /// The slug is still worth having — `KIT-dragon-…` is readable in a store
    /// somebody is debugging — and is dropped when the name leaves nothing,
    /// which is most Arabic names, since it keeps only ASCII.
    private static func mintKitId(_ name: String) -> String {
        let slug = name.lowercased()
            .map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        let trimmed = slug.split(separator: "-").prefix(4).joined(separator: "-")
        return trimmed.isEmpty ? uid("KIT") : uid("KIT-" + trimmed)
    }

    private static func kitName(_ value: JSONValue) -> String? {
        guard case .object(let o) = value, case .string(let n)? = o["name"] else { return nil }
        return n
    }

    /// `settings.kits` — a collection that lives INSIDE settings rather than
    /// at the root, which is why `Shop.rows` cannot reach it.
    private static func kitRows(_ settings: [String: JSONValue]) -> [JSONValue] {
        if case .array(let rows)? = settings["kits"] { return rows }
        return []
    }

    /// One order as the book holds it, rather than as this app decoded it.
    ///
    /// The invoice document reads fields this app has no use for on screen —
    /// the extra lines, the rush fee, the discount it was given — so it is
    /// handed the row, not the `Order`.
    private(set) var orderRows: [JSONValue] = []

    func orderRow(_ id: Order.ID) -> JSONValue? {
        orderRows.first { Self.recordId($0) == id }
    }

    /// The customers, as the book holds them.
    ///
    /// The RAW rows, not this app's decoded `Client` re-encoded: the invoice
    /// reads fields this app has no use for on screen, and a customer's
    /// registration number vanishing from a tax document because a Swift struct
    /// did not name it is exactly the kind of loss this avoids.
    private(set) var clientRows: [JSONValue] = []

    /// The machines, as the book holds them. Kept so the fleet tile can be
    /// recomputed when the printers answer, without redoing the whole dashboard.
    private(set) var machineRows: [JSONValue] = []

    /// The tasks, set directly — for tests of what the SIGNATURE does, which
    /// needs two books that differ by one field and nothing else. A real change
    /// arrives through `load`, and this does not pretend otherwise.
    func setMaintTaskRowsForTesting(_ rows: [JSONValue]) { maintTaskRows = rows }

    /// `machMaintTasks` as written: what each machine is due for, and when it
    /// was last done. Kept raw because the shared rule reads fields this app
    /// has no model for, and decoding to a Swift struct here would mean
    /// deciding which of them matter — a decision that belongs in the rule.
    private(set) var maintTaskRows: [JSONValue] = []

    /// Every machine's kind and what follows from it, keyed by machine id.
    /// `lib/machine-kinds.js` decides; this holds the answer.
    private(set) var machineKinds: [String: KhaytEngine.MachineKind] = [:]

    /// What this machine is. A book written before Khayt knew about anything
    /// but filament printers has no `kind` on any machine, and the module reads
    /// that as FDM — correctly, because until now nothing else could be
    /// recorded. The fallback here is for the moment before the book loads.
    func kind(of machine: Machine) -> KhaytEngine.MachineKind? { machineKinds[machine.id] }

    /// What each shelf row is counted in, keyed by item id.
    /// `lib/inventory-units.js` decides; this holds the answer.
    private(set) var inventoryUnits: [String: KhaytEngine.InventoryUnit] = [:]

    /// What this spool, bottle or stack of sheets is measured in. Nil only for
    /// the instant before the book has loaded; every caller reads that as grams,
    /// which every item written before this existed genuinely is.
    func unit(of spool: Spool) -> KhaytEngine.InventoryUnit? { inventoryUnits[spool.id] }

    /// The units the editor can offer.
    func inventoryUnitChoices() async -> [KhaytEngine.InventoryUnit] {
        (try? await engine?.inventoryUnitChoices()) ?? []
    }

    /// The kinds the editor can offer. Asked when the sheet opens rather than
    /// held on the shop: it is five records and the sheet is not a hot path.
    func machineKindChoices() async -> [KhaytEngine.MachineKind] {
        (try? await engine?.machineKindChoices()) ?? []
    }

    /// The catalogue, as the book holds it.
    ///
    /// This app does not show the catalogue — it has no products screen — but
    /// it does rank what the shop is asked for most, and that list is a column
    /// of ids without the names.
    private(set) var productRows: [JSONValue] = []

    /// The shop's address, resolved the way its name already is.
    var shopAddress: String { shopFieldValue("addr") }

    /// Every field an invoice asks the shop for, resolved the way the renderer
    /// resolves them.
    ///
    /// The document wants `biz`, `addr`, `tagline` and `footer`. It used to be
    /// handed the name and the address and nothing else, and its `shopField`
    /// answered the shop's NAME for the other two — so every invoice printed
    /// the name twice at the top and again in the footer, and the tagline the
    /// shop had typed into Settings appeared nowhere.
    var shopDocumentFields: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for base in ["biz", "addr", "tagline", "footer"] {
            out[base] = .string(shopFieldValue(base))
        }
        return out
    }

    private func shopFieldValue(_ base: String) -> String {
        for key in ["\(base)En", "\(base)Ar"] {
            if case .string(let v)? = settingsDict[key], !v.isEmpty { return v }
        }
        return ""
    }

    /// Whether this shop can reclaim the tax it pays on a purchase.
    ///
    /// A shop with no registration reclaims nothing, so asking it for the tax
    /// on a receipt would be asking for a number it cannot use — and recording
    /// one would understate its costs.
    /// Read from the profile the settings load already resolved, so this asks
    /// the same rule the invoice asks and gets the same answer.
    var reclaimsTax: Bool { taxProfile?.isRegistered == true }

    /// The combined tax percentage, or zero for a shop that is not registered.
    func taxPercent() async -> Double {
        guard let engine, case .object(let dict) = settingsValue,
              let profile = try? await engine.taxProfile(settings: dict) else { return 0 }
        return profile.totalPercent
    }

    /// The currency table the document formats against — the shop's whole
    /// table, from `lib/currencies.js`. It was a one-row stand-in that knew
    /// SAR, so a shop pricing in euros would have printed "EUR" where the
    /// document prints "€".
    var currencyTable: JSONValue {
        .object(currencies.mapValues {
            .object(["symbol": .string($0.symbol), "label": .string($0.label), "pos": .string($0.pos)])
        })
    }

    // MARK: - What the shop spent, and what it wasted

    private(set) var expenses: [Expense] = []
    private(set) var wasteLog: [WasteEntry] = []
    /// The raw rows, for the rules that read fields this app does not decode.
    private(set) var expenseRows: [JSONValue] = []
    /// Machine maintenance entries — `{ machineId, date, cost }`.
    private(set) var maintenanceRows: [JSONValue] = []
    private(set) var wasteRows: [JSONValue] = []

    /// Which period the two screens are showing. On the shop, not the view, so
    /// a snapshot run can turn to a month and photograph it.
    var period: Period = .month
    /// What the last expense or waste write said — an overspent budget, a
    /// refusal, a deletion.
    var spendNote: String?
    var spendProblem: String?

    /// The expenses in the chosen period, newest first, matching the search.
    ///
    /// The search box is on the window, so it is on these screens too — and a
    /// search field that does nothing on the screen you are looking at is
    /// worse than no search field. What a shop looks for here is a note or a
    /// category: "nozzles", "electricity", the job a cost was booked to.
    var shownExpenses: [Expense] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return expenses
            .filter { inPeriod($0.date) }
            .filter {
                q.isEmpty || $0.note.lowercased().contains(q)
                    || words.callIt("exp.cat." + $0.category).lowercased().contains(q)
                    || ($0.orderId ?? "").lowercased().contains(q)
            }
            .sorted { $0.date > $1.date }
    }

    /// The waste entries in the chosen period, newest first, matching the
    /// search — by material, by what went wrong, or by the words somebody
    /// wrote about it.
    var shownWaste: [WasteEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return wasteLog
            .filter { inPeriod($0.date) }
            .filter {
                q.isEmpty || $0.material.lowercased().contains(q)
                    || $0.reason.lowercased().contains(q)
                    || words.callIt("waste.ft." + $0.failureType).lowercased().contains(q)
            }
            .sorted { $0.date > $1.date }
    }

    /// Whether a date falls in the chosen period.
    ///
    /// Swift, not the engine, and deliberately: this decides whether to draw a
    /// row, so it is asked once per record while a list lays out — a bridge
    /// crossing each time would be thousands of them. `PeriodTests` runs it
    /// against `lib/date-range.js` over every range and a year of dates, so the
    /// two cannot answer differently.

    /// Everything the machine P&L needs, filtered to the chosen period — ALL
    /// FOUR THE SAME WAY.
    ///
    /// That symmetry is the whole care here. `renderer/analytics.js` carries a
    /// note about the version that got it wrong: maintenance was filtered by
    /// calendar YEAR while revenue and material were filtered by the chosen
    /// range, so picking "This month" charged January's nozzle-and-belt
    /// overhaul against July's revenue — and a profitable printer read as
    /// loss-making, which is the exact figure an owner uses to decide whether
    /// to retire a machine.
    ///
    /// `lib/machine-pl.js` does not know what a range is, deliberately. It is
    /// decided once, here.
    /// The two spellings of finished, as `lib/order-status.js` names them.
    ///
    /// Held here rather than asked per row — this filters every order in the
    /// book — and `FinishedStatusTests` holds the list to the rule's own, so
    /// it cannot drift from the shared vocabulary the way the comparison it
    /// replaces did. That comparison was `status == "completed"` alone, which
    /// left every job a shop had marked delivered out of what its printers had
    /// earned, in this app and the other one both.
    static let finishedStatuses: Set<String> = ["completed", "delivered"]

    func completedInPeriod() async -> (orders: [JSONValue],
                                       expenses: [JSONValue],
                                       maintenance: [JSONValue]) {
        let orders = orderRows.filter { row in
            guard case .object(let o) = row,
                  case .string(let status)? = o["status"], Self.finishedStatuses.contains(status),
                  case .string(let date)? = o["date"] else { return false }
            return inPeriod(date)
        }
        // An expense with no order behind it is a shop cost, not a machine's —
        // the shop's own P&L has it, and charging it to a printer would count
        // it twice.
        let spend = expenseRows.filter { row in
            guard case .object(let e) = row, case .string(let id)? = e["orderId"], !id.isEmpty,
                  case .string(let date)? = e["date"] else { return false }
            return inPeriod(date)
        }
        let serviced = maintenanceRows.filter { row in
            guard case .object(let m) = row, case .string(let date)? = m["date"] else { return false }
            return inPeriod(date)
        }
        return (orders, spend, serviced)
    }

    func inPeriod(_ date: String, now: Date = Date()) -> Bool {
        Self.inPeriod(date, period: period, now: now)
    }

    /// How long the chosen period is, in days.
    ///
    /// The denominator under "hours run against hours wanted". It has to match
    /// what the other app's `analyticsRangeDays` answers or the same machine
    /// reads at two utilisations depending on which app is open — which is the
    /// whole class of fault the shared rules exist to end, arriving through the
    /// back door as an argument rather than as arithmetic.
    ///
    /// A WHOLE month, not the days elapsed in it. Mid-month that makes every
    /// machine look under-worked, and it is still the right answer: the target
    /// is a rate for the month, the figure is what has been done against it so
    /// far, and a shop reading 40% on the 12th is reading something true.
    func periodDays(now: Date = Date(), dates: [String] = []) -> Int {
        let cal = Calendar.current
        switch period {
        case .month:
            return cal.range(of: .day, in: .month, for: now)?.count ?? 30
        case .last_month:
            guard let lm = cal.date(byAdding: .month, value: -1, to: now) else { return 30 }
            return cal.range(of: .day, in: .month, for: lm)?.count ?? 30
        case .quarter: return 91
        case .year: return 365
        case .all:
            // Span the data itself, as the other app does. A shop six weeks old
            // is not running against a year.
            let days = dates.map { String($0.prefix(10)) }.filter { !$0.isEmpty }.sorted()
            guard let first = days.first, let last = days.last,
                  let from = Order.day(first), let to = Order.day(last) else { return 30 }
            return max(1, Int((to.timeIntervalSince(from) / 86_400).rounded()) + 1)
        }
    }

    static func inPeriod(_ date: String, period: Period, now: Date = Date()) -> Bool {
        if period == .all { return true }
        guard !date.isEmpty else { return false }
        let ds = String(date.prefix(10))
        guard ds.count == 10, Order.day(ds) != nil else { return false }
        let cal = Calendar.current
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        switch period {
        case .month:
            return ds.hasPrefix(String(format: "%04d-%02d", year, month))
        case .last_month:
            let lm = cal.date(byAdding: .month, value: -1, to: cal.date(from: DateComponents(year: year, month: month, day: 1))!)!
            return ds.hasPrefix(String(format: "%04d-%02d", cal.component(.year, from: lm), cal.component(.month, from: lm)))
        case .quarter:
            guard let dsYear = Int(ds.prefix(4)), let dsMonth = Int(ds.dropFirst(5).prefix(2)) else { return false }
            return dsYear == year && (dsMonth - 1) / 3 == (month - 1) / 3
        case .year:
            return ds.hasPrefix(String(format: "%04d", year))
        case .all:
            return true
        }
    }

    /// What the shown expenses come to, and what each category came to.
    var expenseTotals: (total: Double, byCategory: [String: Double]) {
        var byCategory: [String: Double] = [:]
        for category in Self.expenseCategories { byCategory[category] = 0 }
        var total = 0.0
        for e in shownExpenses {
            byCategory[e.category, default: 0] += e.amount
            total += e.amount
        }
        return (total, byCategory)
    }

    /// What THIS CALENDAR MONTH's expenses came to, per category — whatever the
    /// period picker is showing.
    ///
    /// A BUDGET IS A MONTHLY THING. `lib/expense-book.js`'s `overBudget` filters
    /// on `date.startsWith(month)` and the toast after an overspend says "this
    /// month", so a budget compared against anything else is comparing two
    /// different periods. The panel used the SHOWN totals, which the period
    /// picker moves: on "All time" a shop with 1,240 of filament against a 1,500
    /// budget was told it was over by 2,130, and every category eventually goes
    /// over a monthly budget if you total enough months into it. Two of the
    /// sample book's three "Over budget" warnings were false.
    ///
    /// The shop's own calendar day, like `today()` — not UTC's. See
    /// `overBudget`'s note about a month boundary being local.
    var expenseTotalsThisMonth: [String: Double] {
        Self.totals(of: expenses, inMonth: String(Self.today().prefix(7)))   // "2026-09"
    }

    /// The filtering on its own, so it can be asked about a month that is not
    /// today's — `BudgetIsMonthlyTests`.
    static func totals(of expenses: [Expense], inMonth month: String) -> [String: Double] {
        var byCategory: [String: Double] = [:]
        for category in expenseCategories { byCategory[category] = 0 }
        for e in expenses where e.date.hasPrefix(month) {
            byCategory[e.category, default: 0] += e.amount
        }
        return byCategory
    }

    /// A shop that has not sold anything yet — as opposed to one that sold
    /// nothing this month.
    ///
    /// The difference matters on the dashboard: a shop with a quiet September
    /// genuinely earned 0.00 and should be told so, while a shop that opened
    /// yesterday has nothing to total and a row of zeros tells it only that the
    /// app can count to zero. Asked of the WHOLE book, not the period, so
    /// changing the picker cannot turn the front door into an empty state.
    var hasNotTradedYet: Bool { Self.hasNotTraded(orders: orders) }

    /// Separated so it can be asked without a loaded shop — `FirstRunTests`.
    static func hasNotTraded(orders: [Order]) -> Bool { orders.isEmpty }

    /// Khayt's own categories, in its own order.
    static let expenseCategories = ["filament", "electricity", "maintenance", "tools", "shipping", "other"]

    /// Record an expense.
    ///
    /// The record is `lib/expense-book.js`'s, so this app and Khayt write the
    /// same one. A budget the month has now gone past is said afterwards, by
    /// the same rule the Electron page says it with — a warning, not a refusal:
    /// the money has already been spent.
    func addExpense(_ input: [String: JSONValue]) async {
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            spendProblem = words.callIt("mac.move_no_engine"); return
        }
        var overspend: (category: String, over: Overspend)?
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let made = try await engine.newExpense(input, id: Self.uid("EXP"), today: Self.today())
                guard let record = made.expense, case .object(let fields) = record else {
                    throw MoveRefused(sentence: self.words.callIt("exp.amount_required"))
                }
                var rows = Self.rows(root, "expenses")
                rows.insert(record, at: 0)
                root["expenses"] = .array(rows)
                // Asked with the expense already in, on the shop's own calendar
                // month — a UTC month counts the wrong one for the first hours
                // of the 1st east of London.
                if let category = Self.plainString(fields["category"]),
                   let over = try await engine.overBudget(rows, category: category,
                                                          month: String(Self.today().prefix(7)),
                                                          budgets: Self.settings(root)["expBudgets"].flatMap {
                                                              if case .object(let b) = $0 { return b } else { return nil }
                                                          } ?? [:]) {
                    overspend = (category, over)
                }
            }
            await load(source)
            if let overspend {
                spendNote = words.callIt("exp.budget_exceeded", [
                    "cat": .string(words.callIt("exp.cat." + overspend.category)),
                    "spent": .string(Money.figure(overspend.over.spent)),
                    "budget": .string(Money.figure(overspend.over.budget)),
                ])
            } else {
                spendNote = words.callIt("exp.added")
            }
        } catch let refusal as MoveRefused {
            spendProblem = refusal.sentence
        } catch {
            spendProblem = String(describing: error)
        }
    }

    /// Log a failed print.
    ///
    /// Two collections in one swap: the log and the shelf. A log saying a print
    /// wasted 200g while the spool still holds them has told the shop it has
    /// filament it has already thrown away.
    func logWaste(_ input: [String: JSONValue]) async {
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            spendProblem = words.callIt("mac.move_no_engine"); return
        }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let made = try await engine.newWasteEntry(
                    input, id: Self.uid("W"), today: Self.today(),
                    inventory: Self.rows(root, "inventory"))
                guard let entry = made.entry else {
                    throw MoveRefused(sentence: self.words.callIt("waste.err_material"))
                }
                var log = Self.rows(root, "wasteLog")
                log.insert(entry, at: 0)
                root["wasteLog"] = .array(log)
                // The shelf as the deduction left it — stamped, because those
                // spools are edits to existing records and the cloud's sync
                // baseline reads the stamp.
                root["inventory"] = .array(Self.stamping(made.inventory,
                                                         against: Self.rows(root, "inventory")))
            }
            await load(source)
            spendNote = words.callIt("waste.saved")
        } catch let refusal as MoveRefused {
            spendProblem = refusal.sentence
        } catch {
            spendProblem = String(describing: error)
        }
    }

    /// Take a waste entry out, and put its grams back on the spool it came off.
    ///
    /// An entry written before the spool was recorded (anything logged by hand
    /// before #971) restores nothing, because nothing knows where the filament
    /// came from. It is deleted anyway: leaving a row a shop cannot remove is
    /// worse than a shelf figure it can correct.
    func deleteWaste(_ id: String) async {
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            spendProblem = words.callIt("mac.move_no_engine"); return
        }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let before = Self.rows(root, "inventory")
                let out = try await engine.removeWasteEntry(
                    Self.rows(root, "wasteLog"), id: id, inventory: before)
                guard out.removed else { throw MoveRefused(sentence: self.words.callIt("mac.move_gone")) }
                root["wasteLog"] = .array(out.wasteLog)
                root["inventory"] = .array(Self.stamping(out.inventory, against: before))
            }
            await load(source)
            spendNote = words.callIt("waste.deleted")
        } catch let refusal as MoveRefused {
            spendProblem = refusal.sentence
        } catch {
            spendProblem = String(describing: error)
        }
    }

    /// Stamp the rows a rule actually changed, and leave the rest alone.
    ///
    /// `rev` and `updatedAt` are what the cloud's sync baseline reads, so an
    /// unstamped edit never leaves this Mac — and stamping a row nothing
    /// touched sends the whole shelf up on every deletion.
    static func stamping(_ after: [JSONValue], against before: [JSONValue]) -> [JSONValue] {
        let was = Dictionary(before.compactMap { row -> (String, JSONValue)? in
            guard let id = recordId(row) else { return nil }
            return (id, row)
        }, uniquingKeysWith: { a, _ in a })
        return after.map { row in
            guard case .object(var fields) = row, let id = recordId(row),
                  let previous = was[id], previous != row else { return row }
            StoreWriter.stamp(&fields)
            return .object(fields)
        }
    }

    /// Today, as the book writes a day: the shop's own calendar.
    static func today(_ now: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Keeping the shop's data

    /// When the shop's last backup was taken, for the sidebar to show.
    private(set) var lastBackup: String?

    /// Take the day's backup, once, when a real book is opened.
    ///
    /// A shop running only this app had no backup at all — one disk failure
    /// from losing its book. Khayt writes one a day into the same folder, so
    /// between them the two apps keep one set of backups rather than two that
    /// each know half the days.
    ///
    /// Failure is recorded and not raised: a backup that could not be written
    /// is worth saying out loud, and is not a reason to refuse to open the
    /// book it was protecting.
    private func keepTheDaysBackup() async {
        guard let build = source.build else { lastBackup = nil; return }
        // Only the app holding the book. Two apps writing the same folder in
        // the same second is a race for no gain, and the one that does not own
        // the store is the one reading a copy.
        guard StoreLock.weOwnIt(build) else {
            lastBackup = Backups.lastBackupDay(in: Backups.directory(for: build))
            return
        }
        do {
            _ = try await Backups.writeDaily(for: build, engine: engine)
            backupProblem = nil
        } catch {
            backupProblem = String(describing: error)
        }
        lastBackup = Backups.lastBackupDay(in: Backups.directory(for: build))
        lastCrash = LastWords.read(for: build)
    }

    /// Why the day's backup could not be taken, when it could not.
    private(set) var backupProblem: String?

    /// What the app said as it died last time, if it did.
    ///
    /// Read once when a book opens. A crash a shop cannot see is a crash it
    /// cannot report, and the macOS report for an uncaught exception does not
    /// carry the reason.
    private(set) var lastCrash: String?

    // MARK: - What the menu bar asks

    /// How many machines are printing RIGHT NOW, from the poller rather than
    /// from the book.
    ///
    /// The book's `status` is what somebody last told Khayt; this is what the
    /// printers last said themselves. On the one question the menu bar exists
    /// to answer they can disagree for hours — a print that finished at 03:00
    /// is still "printing" in a book nobody has touched since.
    var printingNow: Int {
        machines.reduce(into: 0) { count, machine in
            // `PrinterWatch.isPrinting`, not `== "printing"`. OctoPrint passes
            // the printer's own `state.text` through untouched and OctoPrint
            // capitalises it — so an exact comparison counted zero on every
            // OctoPrint shop, and the menu bar this property exists for said
            // "nothing is printing" while the machine was printing.
            if let state = printers.readings[machine.id]?.status?.state,
               PrinterWatch.isPrinting(state) { count += 1 }
        }
    }

    /// Seconds until the first machine is free, or nil when none is running.
    var soonestFinish: Double? {
        machines.compactMap { machine -> Double? in
            guard let status = printers.readings[machine.id]?.status,
                  PrinterWatch.isPrinting(status.state),
                  let left = status.timeRemaining, left > 0 else { return nil }
            return left
        }.min()
    }

    // MARK: - Which printer takes which job

    /// Whether the proposal panel is up.
    var schedulingWork = false

    /// The scheduler's proposal, or nil when nobody has asked for one.
    ///
    /// Held rather than recomputed on every redraw, because it is a PROPOSAL: a
    /// panel whose rows changed underneath the person reading them would be a
    /// panel nobody could approve.
    private(set) var schedulePlan: KhaytEngine.SchedulePlan?
    /// Why there is no proposal, in the shop's own words.
    private(set) var scheduleProblem: String?
    /// Nothing is waiting for a machine — every job already has one. A state,
    /// not a fault, and kept apart from `scheduleProblem` for that reason.
    private(set) var scheduleIdle = false
    /// How many jobs the last apply moved.
    private(set) var scheduleApplied: Int?

    /// The jobs a scheduler is allowed to place: waiting, and on no machine yet.
    ///
    /// The same filter the Electron kanban uses. A job already on a printer is
    /// left alone — the scheduler seeds each machine's load with it, but never
    /// proposes moving work somebody has already committed.
    var schedulableRows: [JSONValue] { Self.schedulable(orderRows) }

    /// Static and separate so it can be tested without opening a book — the
    /// version that lived inline returned nothing against a sample where six
    /// jobs plainly qualified, and there was no way to ask it why.
    /// What the scheduler should be HANDED: every job still to happen.
    ///
    /// Three sets were candidates and only this one is right.
    ///
    /// * Just the unassigned jobs — what the Electron kanban passes — makes
    ///   `machineLoadMins` see every printer as empty, so each proposal comes
    ///   back finishing in minutes. That is where "0.1 hrs" came from.
    /// * The whole book seeds the load correctly for in-flight work and then
    ///   adds thirteen delivered and nine completed jobs to it, because
    ///   `machineLoadMins` sums by `machineId` without looking at status. A
    ///   printer that has done a hundred jobs would look booked for a month.
    /// * The work still to happen — waiting, queued, printing — seeds each
    ///   machine with what is actually on it and nothing else. `isSchedulable`
    ///   then refuses anything already on a printer, so the proposal covers the
    ///   same jobs either way; only the finishing times change, and they become
    ///   true.
    static func stillToHappen(_ rows: [JSONValue]) -> [JSONValue] {
        rows.filter { row in
            guard case .object(let o) = row else { return false }
            let status = plainString(o["status"]) ?? ""
            return status == "pending" || status == "queued" || status == "printing"
        }
    }

    static func schedulable(_ rows: [JSONValue]) -> [JSONValue] {
        rows.filter { row in
            guard case .object(let o) = row else { return false }
            let status = plainString(o["status"]) ?? ""
            guard status == "pending" || status == "queued" else { return false }
            return (plainString(o["machineId"]) ?? "").isEmpty
        }
    }

    // MARK: - What can go on one plate

    /// Whether the batch planner is open.
    var planningBatch = false

    /// The proposed plates, or nil when nobody has asked yet.
    ///
    /// Held rather than recomputed on every redraw, for the reason the
    /// scheduler's proposal is: rows that changed underneath the person reading
    /// them cannot be acted on.
    private(set) var batchPlates: KhaytEngine.PlatePlan?
    /// Why there is no proposal — the app failing, not the shop having nothing.
    private(set) var batchProblem: String?
    /// There is no work to plan. A state, not a fault; kept apart for the same
    /// reason `scheduleIdle` is.
    private(set) var batchIdle = false

    /// What one plate will take.
    ///
    /// Seeded from the rule's own `DEFAULTS` when the book loads, not typed
    /// here: a Swift copy of 24 and 1,000 is a copy that goes stale the day the
    /// shared rule changes its mind. These are the values until then, so the
    /// fields are never blank while the engine is still starting.
    var batchMaxHours: Double = 24
    var batchMaxGrams: Double = 1000

    /// The jobs the shop ticked. Empty means "everything below", which is what
    /// the other app's planner does with an empty selection.
    var batchChosen: Set<String> = []

    /// The work a plate could be planned from: not finished, not a quote, not
    /// voided. The other app's filter, through the same shared rule.
    var batchCandidates: [Order] {
        Self.planCandidates(orders, voided: Self.voidedIds(orderRows))
    }

    /// The filter itself, static so it can be shown to work without a book on
    /// disk — the shape `schedulable` already uses, and for the same reason:
    /// the version that lived inline could not be asked why it had dropped a
    /// job.
    ///
    /// `finishedStatuses` is the shared vocabulary, held to `lib/order-status.js`
    /// by `FinishedStatusTests` — NOT `status == "completed"`, which would leave
    /// every delivered job sitting in the planner for ever.
    static func planCandidates(_ jobs: [Order], voided: Set<String>) -> [Order] {
        jobs.filter { job in
            job.status != "quote" && !finishedStatuses.contains(job.status)
                && !voided.contains(job.id)
        }
    }

    /// The jobs the shop has written off. `Order` does not carry `voidedAt` —
    /// nothing on screen needed it — so it is read off the raw record.
    static func voidedIds(_ rows: [JSONValue]) -> Set<String> {
        Set(rows.compactMap { row -> String? in
            guard case .object(let o) = row, let id = recordId(row),
                  let mark = o["voidedAt"], mark != .null else { return nil }
            return id
        })
    }

    /// Ask the shared packer what could run together.
    ///
    /// Reads only, and writes nothing at all — unlike the scheduler, there is
    /// no "apply": a plate is a way of running the work, not a field on a
    /// record. Khayt has never written one either.
    func planBatch() async {
        batchProblem = nil
        batchIdle = false
        batchPlates = nil
        guard let engine else {
            batchProblem = words.callIt("mac.move_no_engine"); return
        }
        let chosen = batchCandidates.filter { batchChosen.isEmpty || batchChosen.contains($0.id) }
        guard !chosen.isEmpty else { batchIdle = true; return }
        do {
            batchPlates = try await engine.planPlates(
                jobs: chosen.map(Self.plateJob),
                maxHours: max(1, batchMaxHours), maxGrams: max(1, batchMaxGrams))
        } catch {
            batchProblem = String(describing: error)
        }
    }

    /// What a job weighs and what of, for the packer.
    ///
    /// The weight is the PARTS', quantity included — a job's own record does
    /// not carry one, and a plate packed on a per-part weight would fit four
    /// copies of something in the space of one. The material is the first the
    /// job's parts name, which is the other app's reading too: a plate cannot
    /// mix filaments, so a job printed in two is planned by the first and the
    /// shop sees the rest on the row.
    static func plateJob(_ job: Order) -> KhaytEngine.PlateJob {
        let grams = job.parts.reduce(0.0) { $0 + $1.printWeight * Double(max(1, $1.qty)) }
        let material = job.parts.first(where: { !$0.material.isEmpty })?.material ?? ""
        return KhaytEngine.PlateJob(id: job.id, project: job.project.isEmpty ? job.id : job.project,
                                    hours: job.printTime, grams: grams, material: material)
    }

    /// Ask the shared scheduler where the unassigned work should go.
    ///
    /// Reads only. `lib/scheduling.js` writes nothing and neither does this;
    /// `applySchedule` is the one that touches the book.
    func proposeSchedule() async {
        scheduleProblem = nil
        scheduleIdle = false
        scheduleApplied = nil
        schedulePlan = nil
        guard let engine else {
            scheduleProblem = words.callIt("mac.move_no_engine"); return
        }
        let waiting = schedulableRows
        guard !waiting.isEmpty else {
            // ── NOT A PROBLEM, AND IT WAS FILED AS ONE ───────────────────
            //
            // `scheduleProblem` is the field for "the app cannot do this":
            // no engine, a thrown error, a refusal from the rule. The sheet
            // draws it under the system's warning triangle, deliberately,
            // because those are faults.
            //
            // Every job already having a machine is the OPPOSITE of a fault.
            // It went in the same field, so a shop that had finished
            // assigning its work opened the scheduler and was shown a
            // warning sign telling it so.
            scheduleIdle = true; return
        }
        do {
            // Everything still to happen — see `stillToHappen`. Not just the
            // waiting jobs, or every printer looks empty and every proposal
            // comes back finishing in minutes.
            schedulePlan = try await engine.proposeSchedule(
                machines: machineRows, orders: Self.stillToHappen(orderRows), now: Date())
        } catch {
            scheduleProblem = String(describing: error)
        }
    }

    /// Put the proposal into the book. The only part of this that writes.
    ///
    /// Each assignment sets one job's `machineId` and nothing else — not its
    /// status, not its queue position. The scheduler proposes a printer; moving
    /// the card is still the operator's.
    func applySchedule() async {
        guard let plan = schedulePlan, !plan.assignments.isEmpty else { return }
        guard let build = source.build else {
            scheduleProblem = words.callIt("mac.move_sample"); return
        }
        let wanted = Dictionary(plan.assignments.map { ($0.orderId, $0.machineId) },
                                uniquingKeysWith: { first, _ in first })
        var moved = 0
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                // Read INSIDE the write: the book on disk may have moved since
                // the proposal was drawn, and a job somebody assigned by hand in
                // the meantime must not be overwritten by a stale suggestion.
                let orders = Self.rows(root, "printLog")
                var out: [JSONValue] = []
                out.reserveCapacity(orders.count)
                for row in orders {
                    guard case .object(var o) = row,
                          let id = Self.plainString(o["id"]),
                          let machine = wanted[id],
                          (Self.plainString(o["machineId"]) ?? "").isEmpty else {
                        out.append(row); continue
                    }
                    o["machineId"] = .string(machine)
                    out.append(.object(o))
                    moved += 1
                }
                root["printLog"] = .array(out)
            }
            scheduleApplied = moved
            schedulePlan = nil
            await load(source)
        } catch let refusal as StoreWriter.Refusal {
            scheduleProblem = refusal.description
        } catch {
            scheduleProblem = String(describing: error)
        }
    }

    /// Put the proposal out of mind.
    func forgetSchedule() {
        schedulePlan = nil
        scheduleProblem = nil
        scheduleApplied = nil
    }

    /// What a proposal row says, ready for a screen: the job, the printer, and
    /// the module's own reason.
    func scheduleRow(_ a: KhaytEngine.SchedulePlan.Assignment) -> (job: String, machine: String, why: String) {
        let job = orders.first { $0.id == a.orderId }?.project ?? a.orderId
        let machine = machines.first { $0.id == a.machineId }?.name ?? a.machineId
        return (job, machine, a.reason ?? "")
    }

    /// Take a backup now, for the shop that is about to do something it might
    /// want to undo.
    ///
    /// The day's file already exists more often than not, and overwriting it
    /// would throw away the copy taken before whatever the shop did earlier —
    /// so this writes a SECOND file for today, stamped with the time. Khayt's
    /// own rotation counts it as a day, which is right: it is one.
    func backUpNow() async {
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        do {
            let file = try await Backups.writeNow(for: build, engine: engine)
            lastBackup = Backups.lastBackupDay(in: Backups.directory(for: build))
            spendNote = words.callIt("mac.backed_up") + " " + file.lastPathComponent
            backupProblem = nil
        } catch {
            backupProblem = String(describing: error)
            spendProblem = words.callIt("mac.backup_failed") + " " + String(describing: error)
        }
    }

    /// Put the last crash out of mind, once somebody has looked at it.
    func forgetLastCrash() {
        guard let build = source.build else { return }
        LastWords.clear(for: build)
        lastCrash = nil
    }

    /// Show the shop where its backups are, so it can copy one somewhere safe.
    func revealBackups() {
        guard let build = source.build else { return }
        let directory = Backups.directory(for: build)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting(
            [directory.appending(path: Backups.filename())].filter {
                FileManager.default.fileExists(atPath: $0.path)
            }.isEmpty ? [directory] : [directory.appending(path: Backups.filename())])
    }

    /// Write a copy of the book the shop can send somebody.
    ///
    /// Redacted, always — see `Export`. The panel comes up before the file is
    /// built so that a shop that changes its mind never has a redacted copy of
    /// its book sitting in a temp folder.
    func exportForSharing() async {
        spendProblem = nil
        spendNote = nil
        guard let build = source.build, let engine else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = Export.filename()
        panel.message = words.callIt("mac.export_redacted")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // From disk, not from what this app is holding: the screens decode
            // two collections out of thirty-three, and an export built from
            // those would be an export missing thirty-one.
            let root = try JSONDecoder().decode([String: JSONValue].self,
                                                from: Data(contentsOf: build.storeURL))
            try await Export.payload(from: root, engine: engine).write(to: url, options: .atomic)
            spendNote = words.callIt("mac.exported_to") + " " + url.lastPathComponent
        } catch {
            spendProblem = words.callIt("mac.export_failed") + " " + String(describing: error)
        }
    }

    /// The accounting packages `lib/accounting-export.js` lays out columns for.
    ///
    /// The names are the products' own and are deliberately NOT translated —
    /// "QuickBooks" is what the software is called in every language, and a
    /// localised guess at it is a menu item nobody recognises.
    static let accountingFormats: [(String, String)] = [
        ("generic", "CSV"), ("quickbooks", "QuickBooks"),
        ("xero", "Xero"), ("zoho", "Zoho Books"),
    ]

    /// The two files an accountant actually wants.
    ///
    /// ── WHY NOT THE EXPORT ABOVE ──────────────────────────────────────────
    ///
    /// `exportForSharing` writes the whole book as redacted JSON, which is the
    /// right thing to hand a support thread and the wrong thing to hand a
    /// bookkeeper: nobody opens a thirty-three-collection JSON in the software
    /// that files a VAT return. This writes what that software reads — one CSV
    /// of invoices, one of expenses — and the columns are laid out the way the
    /// chosen package wants them.
    ///
    /// The arithmetic is `lib/accounting-export.js`: the VAT split, the
    /// category-to-account mapping, the four column layouts. None of it is
    /// worked out here. A quarter exported from this Mac is the same set of
    /// rows, to the halalah, as the same quarter exported from the other app —
    /// which matters more here than anywhere else in this program, because two
    /// apps disagreeing about a VAT figure is a disagreement an auditor finds.
    ///
    /// A FOLDER, not a file, because there are two of them. Asking twice for
    /// somewhere to put a pair of files is a dialogue nobody finishes.
    func exportForAccounting(format: String) async {
        spendProblem = nil
        spendNote = nil
        guard let engine else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = words.callIt("common.save")
        panel.message = words.callIt("mac.export_accounting_where")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            let day = Shop.today(Date())
            // The rule already puts a BOM on each file. It is asked for rather
            // than assumed, because the reason for it — Excel on Windows reads
            // a UTF-8 CSV without one as the system code page, and turns a
            // shop's Arabic customer names into mojibake — is the rule's
            // decision to make and to change.
            let invoices = try await engine.invoiceCsv(
                orderRows, settings: settingsDict, clients: clientRows, format: format)
            let expenses = try await engine.expenseCsv(expenseRows, format: format)
            let a = dir.appending(path: "khayt-invoices-\(day).csv")
            let b = dir.appending(path: "khayt-expenses-\(day).csv")
            try Data(invoices.utf8).write(to: a, options: .atomic)
            try Data(expenses.utf8).write(to: b, options: .atomic)
            spendNote = words.callIt("mac.exported_to") + " " + dir.lastPathComponent
        } catch {
            spendProblem = words.callIt("mac.export_failed") + " " + String(describing: error)
        }
    }

    /// Is this book connected to Khayt Cloud, and therefore expecting to be in
    /// step with another device?
    ///
    /// THIS APP DOES NOT SYNC. It writes to the store on this Mac and stamps
    /// every record so the Electron app's next sync picks the change up — which
    /// is the mechanism, and it only runs when that app runs. A shop that keeps
    /// its book on two machines and stops opening Khayt would have the two
    /// drift apart with nothing said, which is the one failure worth putting on
    /// screen before the feature exists.
    var cloudConnected: Bool { Self.cloudConnected(settingsDict) }

    /// Where this shop's cloud is, for the links a storefront needs pasted
    /// into it. Nil unless the connection is actually finished — a half-set-up
    /// cloud would produce a URL that looks right and serves nothing.
    var cloudAddress: (url: String, shopId: String)? {
        guard cloudConnected, case .object(let cloud)? = settingsDict["cloud"],
              case .string(let url)? = cloud["url"],
              case .string(let shopId)? = cloud["shopId"],
              !url.isEmpty, !shopId.isEmpty else { return nil }
        return (url, shopId)
    }

    /// The same, as a function of the settings alone — `settingsValue` is only
    /// the model's to set, and a rule about a shop's data should be testable
    /// without building one.
    static func cloudConnected(_ settings: [String: JSONValue]) -> Bool {
        guard case .object(let cloud)? = settings["cloud"] else { return false }
        if case .bool(let on)? = cloud["enabled"], on == false { return false }
        guard case .string(let shop)? = cloud["shopId"], !shop.isEmpty else { return false }
        // A shop that started connecting and never finished is not connected,
        // and telling it its changes are stranded would be a false alarm.
        if case .bool(let verified)? = cloud["verified"] { return verified }
        return false
    }

    // MARK: - The catalogue

    /// What the shop sells, priced by the shared rule.
    ///
    /// Resolved once per load. Three crossings per row — the name, the price
    /// and the specs — would be three hundred for a hundred products.
    private(set) var catalogueRows: [KhaytEngine.CatalogueRow] = []

    // MARK: - What the cloud holds

    /// The comparison, once it has been asked for.
    var cloudCheck: CloudCompare.Result?
    /// Why it could not be made.
    var cloudProblem: String?
    /// True while the passphrase sheet is up.
    var checkingCloud = false
    var signingIntoCloud = false
    /// True while the request is in flight.
    var cloudBusy = false
    /// What the last send put up, if there was one.
    var cloudSent: CloudWriter.Sent?
    /// Whether the last comparison found a settings change this app cannot send.
    var cloudSettingsStay = false

    /// The shop's data key, held for as long as this app runs.
    ///
    /// ── IT USED TO GO WHEN THE SHEET DID, AND THAT IS WHY NOTHING SYNCED ──
    ///
    /// The key was dropped in `onDisappear`, which was right while the only
    /// thing that could use it was a button on that sheet. Automatic sync
    /// cannot work that way: it runs after a save, minutes later, with nothing
    /// on screen — and a background push that stops to ask for a passphrase is
    /// a background push nobody has consented to.
    ///
    /// So the lifetime is now the app's, which is exactly Khayt's: the desktop
    /// configures its sync controller "after unlock" and keeps the backend for
    /// the session. This is not a loosening of the end-to-end story. The
    /// PASSPHRASE is still never kept and still never written; this is the
    /// unwrapped key, in memory, dropped when the app quits or the shop locks
    /// it — and re-earning it costs a scrypt at N=32768, most of a minute.
    private var cloudDek: Data?

    /// Has somebody unlocked the cloud this session?
    var cloudUnlocked: Bool { cloudDek != nil }

    /// Lock the cloud again: drop the data key and stop syncing until somebody
    /// unlocks it. The shop's own choice, from the menu bar.
    func forgetCloudKey() {
        cloudDek = nil
        cloudSent = nil
        cancelPendingSync()
        syncStatus = Self.cloudConnected(settingsDict) ? .locked : .off
    }

    /// Is there anything this Mac could send, and the key to send it with?
    var canSendToCloud: Bool {
        cloudDek != nil && !cloudBusy && (cloudCheck?.sendable ?? 0) > 0
    }

    /// Ask Khayt Cloud what it holds and say how far apart the two books are.
    ///
    /// READ ONLY. Nothing is pushed, nothing is merged and nothing is written
    /// on either side — this counts. `cloud-backend.js` §7 is why: a push with
    /// a baseRev the server accepts replaces its newer copy and every device
    /// pulls the older store down, with nothing said. Counting cannot do that.
    ///
    /// The passphrase is asked for, used, and not kept. It is the one thing
    /// Khayt deliberately stores nowhere — that is what makes the cloud copy
    /// end-to-end encrypted — so this app must ask each time and hold it no
    /// longer than the unwrap.
    /// Sign this Mac in to the shop's cloud, and unlock it in the same breath.
    ///
    /// THE TOKEN IS A SESSION, NOT A SETTING. The server issues it at login and
    /// it is sealed against the Keychain of the machine that asked — so a book
    /// carried to another Mac arrives with a token nothing here can read, and
    /// until this existed the only cure was to open the other app. That is the
    /// one thing this app is for not needing.
    ///
    /// Four things happen, in this order and for these reasons:
    ///
    ///   1. **Log in**, which is the only part that was missing.
    ///   2. **Unwrap the keyset with the passphrase, BEFORE anything is
    ///      written.** A token saved beside a passphrase that does not fit
    ///      leaves the shop connected and unable to read a word of its own
    ///      cloud data, which looks like the server losing it.
    ///   3. **Seal the token.** A token written in plaintext would sit in a
    ///      file that syncs, backs up and exports. `Secrets.seal` refuses
    ///      rather than downgrading, so a Mac with no Keychain is told.
    ///   4. **Write `settings.cloud` whole**, inside the write chain — the
    ///      same shape `renderer/settings.js` writes, so the other app reads
    ///      this Mac's sign-in as its own.
    ///
    /// The passphrase is used and not kept, the way `checkCloud` uses it: it is
    /// the one thing Khayt stores nowhere, which is what makes the cloud copy
    /// end-to-end encrypted.
    func signInToCloud(url: String, email: String, password: String,
                       passphrase: String) async {
        cloudProblem = nil
        cloudBusy = true
        defer { cloudBusy = false }
        guard let build = source.build, let engine else {
            cloudProblem = words.callIt("mac.move_sample"); return
        }
        do {
            let session = try await CloudSignIn.logIn(url: url, email: email,
                                                      password: password, engine: engine)
            // ── WHERE THE KEYSET COMES FROM, AND WHY BOTH PLACES COUNT ────
            //
            // The server returns `keyset: null` from login quite legitimately —
            // it is stored and fetched separately (`PUT /v1/shops/{id}/keyset`),
            // and login does not always carry it. The book has its own copy,
            // which is what `checkCloud` has always unlocked with.
            //
            // So: the server's when it sends one, because another device may
            // have rotated it; otherwise the book's. Demanding it from the
            // login response refused a shop whose book HAS a key — which is
            // precisely the restored-book case this whole path exists for, and
            // it is how this was found.
            var fromServer = true
            var keysetValue = session.keyset
            if keysetValue == nil {
                keysetValue = cloudKeyset()
                fromServer = false
            }
            guard case .object(let keyset)? = keysetValue else {
                throw CloudSignIn.Failure.noKeyset
            }
            guard case .object(let wrappedFields)? = keyset["wrappedByPassphrase"],
                  let wrapped = try? JSONDecoder().decode(
                      SyncCrypto.Blob.self,
                      from: JSONEncoder().encode(JSONValue.object(wrappedFields)))
            else {
                throw CloudReader.Failure.malformed("the keyset has no passphrase-wrapped key")
            }
            // Before the write, so a wrong passphrase changes nothing.
            let dek = try SyncCrypto.unwrapDek(secret: passphrase, wrapped: wrapped)
            let sealed = try await Secrets.seal(session.token, for: build)

            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var settings = Self.settings(root)
                // `lastServerRev: 0` on purpose, exactly as the other app writes
                // it: this machine has seen nothing from the server yet, and a
                // carried-over rev would let a push claim a base it never read.
                settings["cloud"] = .object([
                    "enabled": .bool(true),
                    "url": .string(url),
                    "email": .string(email),
                    "shopId": .string(session.shopId),
                    "token": .string(sealed),
                    "keyset": .object(keyset),
                    "lastServerRev": .number(0),
                    "verified": .bool(session.verified),
                    "role": .string(session.role),
                ])
                root["settings"] = .object(settings)
            }

            cloudDek = dek
            if case .locked = syncStatus { syncStatus = .idle }
            await load(source)
            // Said, not swallowed: a server that holds no keyset cannot hand
            // this shop's key to the NEXT machine, so the recovery key is the
            // only copy that is not on a disk in this room. That is worth
            // knowing before it matters.
            moveNotices = fromServer
                ? [words.callIt("mac.cloud_signed_in")]
                : [words.callIt("mac.cloud_signed_in"), words.callIt("mac.cloud_key_local")]
        } catch let failure as CloudSignIn.Failure {
            cloudProblem = failure.errorDescription ?? String(describing: failure)
        } catch let locked as Secrets.Failure {
            cloudProblem = words.callIt("mac.cloud_signin_failed") + " " + locked.description
        } catch let crypto as SyncCrypto.Failure {
            // The overwhelmingly common one, and worth its own sentence: the
            // login succeeded and the passphrase did not fit.
            cloudProblem = words.callIt("mac.cloud_wrong_passphrase")
                + " (" + String(describing: crypto) + ")"
        } catch {
            cloudProblem = words.callIt("mac.cloud_signin_failed") + " "
                + ((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    /// Ask the cloud to email a reset code.
    ///
    /// Nothing is written and nothing changes until the code comes back with a
    /// new password. What this reports is whether the SERVER can send mail at
    /// all — a server with none configured accepts the request and delivers
    /// nothing, which from a shop's side looks exactly like an email that has
    /// not arrived yet, and it would wait for it.
    func requestPasswordReset(url: String, email: String) async {
        cloudProblem = nil
        cloudBusy = true
        defer { cloudBusy = false }
        guard let engine else { cloudProblem = words.callIt("mac.move_no_engine"); return }
        do {
            let sent = try await CloudSignIn.requestReset(url: url, email: email, engine: engine)
            if !sent.configured {
                cloudProblem = words.callIt("mac.cloud_reset_no_mail")
            } else if sent.failed {
                cloudProblem = words.callIt("mac.cloud_reset_send_failed")
            } else {
                moveNotices = [words.callIt("mac.cloud_reset_sent", ["email": .string(email)])]
            }
        } catch {
            cloudProblem = words.callIt("mac.cloud_signin_failed") + " "
                + ((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    /// Set a new account password with the emailed code.
    ///
    /// THE ACCOUNT PASSWORD ONLY. The shop's data stays encrypted under the key
    /// the sync passphrase wraps, which this cannot read and does not touch —
    /// so a shop that has lost its PASSPHRASE is not helped by this, and needs
    /// its recovery key. The sheet says so where it can be read before typing.
    ///
    /// No sign-in follows automatically: the new password is a thing the person
    /// just chose and may have mistyped into a password manager, and signing in
    /// with it is the proof that it is what they think it is.
    func resetCloudPassword(url: String, email: String, code: String,
                            newPassword: String) async {
        cloudProblem = nil
        cloudBusy = true
        defer { cloudBusy = false }
        guard let engine else { cloudProblem = words.callIt("mac.move_no_engine"); return }
        do {
            try await CloudSignIn.resetPassword(url: url, email: email, code: code,
                                                newPassword: newPassword, engine: engine)
            moveNotices = [words.callIt("mac.cloud_reset_done")]
        } catch {
            cloudProblem = words.callIt("mac.cloud_reset_failed") + " "
                + ((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    func checkCloud(passphrase: String) async {
        cloudProblem = nil
        cloudCheck = nil
        cloudBusy = true
        defer { cloudBusy = false }
        guard let build = source.build, let engine else {
            cloudProblem = words.callIt("mac.move_sample"); return
        }
        do {
            let connection = try CloudReader.connection(settingsDict)
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }

            let reply = try await CloudReader.pull(connection, token: token) { request in
                try await URLSession(configuration: .ephemeral).data(for: request)
            }
            guard case .object(let keyset)? = cloudKeyset() else {
                throw CloudReader.Failure.malformed("this book has no keyset to unlock")
            }
            guard case .object(let wrappedFields)? = keyset["wrappedByPassphrase"],
                  let wrapped = try? JSONDecoder().decode(
                      SyncCrypto.Blob.self, from: JSONEncoder().encode(JSONValue.object(wrappedFields)))
            else {
                throw CloudReader.Failure.malformed("the keyset has no passphrase-wrapped key")
            }
            let dek = try SyncCrypto.unwrapDek(secret: passphrase, wrapped: wrapped)
            cloudDek = dek
            // Unlocked. From here on this app pushes on its own, and the first
            // push carries whatever was changed while it was locked.
            if case .locked = syncStatus { syncStatus = .idle }
            let folded = try await CloudReader.store(reply, dek: dek, engine: engine)

            // Read from disk rather than from what this app is holding: the
            // screens decode two collections out of thirty-three, and a
            // comparison built from those would report thirty-one as missing.
            let mine = (try? Data(contentsOf: build.storeURL))
                .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
            let collections = (try? await engine.storeCollections()) ?? []
            cloudCheck = CloudCompare.compare(here: mine, there: folded.store,
                                              collections: collections, cloudRev: reply.rev,
                                              chain: folded.chain, applied: folded.applied)
            // Asked here rather than on the send, so a shop is told about a
            // setting this app cannot carry BEFORE it presses a button that
            // will not carry it.
            cloudSettingsStay = (try? await engine.changesToSend(local: mine, server: folded.store))?
                .settingsDiffer ?? false
        } catch let failure as CloudReader.Failure {
            cloudProblem = failure.description
        } catch let failure as SyncCrypto.Failure {
            cloudProblem = failure.description
        } catch let locked as Secrets.Failure {
            cloudProblem = locked.description
        } catch {
            cloudProblem = String(describing: error)
        }
    }

    /// Send the half of the difference that is only on this Mac.
    ///
    /// It **pulls again first**, and that is not politeness — it is the whole
    /// safety property. The payload has to be measured against the store the
    /// cloud holds at the moment of sending, and `baseRev` has to be that same
    /// pull's revision, or the service's optimistic guard is guarding nothing.
    /// Anything that arrived between the check and the button then shows up as
    /// a 409 and this refuses, instead of appending a change computed against
    /// a store that no longer exists.
    ///
    /// It appends and never replaces. See `CloudWriter` for why that line is
    /// where the danger lives.
    func sendToCloud() async {
        cloudProblem = nil
        cloudSent = nil
        cloudBusy = true
        defer { cloudBusy = false }
        guard let build = source.build, let engine, let dek = cloudDek else {
            cloudProblem = words.callIt("mac.move_sample"); return
        }
        do {
            let connection = try CloudReader.connection(settingsDict)
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }

            let session = URLSession(configuration: .ephemeral)
            let reply = try await CloudReader.pull(connection, token: token) { request in
                try await session.data(for: request)
            }
            let folded = try await CloudReader.store(reply, dek: dek, engine: engine)
            // From disk, for the same reason the comparison reads from disk:
            // the screens hold two collections out of thirty-three, and a
            // payload built from those would claim the other thirty-one are
            // gone.
            let mine = (try? Data(contentsOf: build.storeURL))
                .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
            let outbox = try await engine.changesToSend(local: mine, server: folded.store)
            cloudSettingsStay = outbox.settingsDiffer

            let collections = (try? await engine.storeCollections()) ?? []
            guard !outbox.isEmpty else {
                // Nothing to do is not a failure. Show the fresh comparison so
                // the screen stops offering a button that would do nothing.
                cloudCheck = CloudCompare.compare(here: mine, there: folded.store,
                                                  collections: collections, cloudRev: reply.rev,
                                                  chain: folded.chain, applied: folded.applied)
                return
            }

            do {
                cloudSent = try await CloudWriter.send(connection, token: token, payload: outbox,
                                                       dek: dek, baseRev: reply.rev) { request in
                    try await session.data(for: request)
                }
            } catch CloudWriter.Failure.notAccepted {
                // THE SHOP'S CHAIN IS CLOSED, and this is not rare: khayt-cloud
                // shuts it for a shop with any device it believes cannot fold a
                // chain, or any live token nobody has been seen using. This
                // shop's is shut, which is how the case was found — a live
                // POST /deltas answers 404 today.
                //
                // Both causes end by opening Khayt on the machine. A device on
                // a build older than v3.6.0 sends no `x-delta-capable` header
                // and is recorded as unable; its next sync after an update
                // overwrites that with a yes. A token that has been issued and
                // never used has no capability row at all, and unknown fails
                // closed — one sync gives it one. (An abandoned login also ages
                // out on its own: tokens carry a 90-day sliding expiry, and the
                // migration that added the column backfilled the rows that
                // predated it, so none of them is immortal. An earlier note
                // here said they never expire. They do.)
                //
                // The desktop falls back to sending the whole store. That is
                // only safe from a book that already holds everything the cloud
                // has, so the merge below is not a courtesy — it is the thing
                // that makes the push legal. Anything arriving in between comes
                // back as a 409 from `baseRev`.
                cloudSent = try await sendWholeBookAfterMerging(
                    connection: connection, token: token, dek: dek, engine: engine,
                    build: build, server: folded.store, baseRev: reply.rev, session: session)
            }
            // Say what is true NOW, not what was true before the send: fold the
            // payload onto the store that was just pulled, which is exactly
            // what every other device will do when it next pulls the chain.
            let after = try await engine.foldDeltas(base: folded.store, deltas: [outbox.wire])
            cloudCheck = CloudCompare.compare(here: mine, there: after.store,
                                              collections: collections,
                                              cloudRev: cloudSent?.rev ?? reply.rev,
                                              chain: folded.chain + 1,
                                              applied: folded.applied + after.applied)
        } catch let failure as CloudWriter.Failure {
            cloudProblem = failure.description
            // A 409 means the comparison on screen is stale. Take it away
            // rather than leave a table that no longer describes anything.
            if case .moved = failure { cloudCheck = nil }
        } catch let failure as CloudReader.Failure {
            cloudProblem = failure.description
        } catch let failure as SyncCrypto.Failure {
            cloudProblem = failure.description
        } catch let locked as Secrets.Failure {
            cloudProblem = locked.description
        } catch {
            cloudProblem = String(describing: error)
        }
    }

    /// What the last pull brought down, if there was one.
    var cloudPulled: KhaytEngine.Merged?

    /// Is there anything in the cloud this Mac does not have, and may we write?
    var canPullFromCloud: Bool {
        cloudDek != nil && !cloudBusy && canMoveJobs
            && ((cloudCheck?.lines.reduce(0) { $0 + $1.onlyThere + $1.newerThere } ?? 0) > 0)
    }

    /// Bring the cloud's copy down and merge it into this Mac's book.
    ///
    /// THE MOST DANGEROUS THING THIS APP DOES, and the arrangement is what makes
    /// it safe rather than the intention:
    ///
    /// * **A backup first.** Not because the merge is expected to go wrong, but
    ///   because this is the one operation that changes records a shop did not
    ///   touch, and the app already knows how to take one.
    /// * **The read is inside the write.** `StoreWriter.update` reads the book,
    ///   hands it to the merge, re-checks ownership and swaps — so a merge
    ///   computed from a copy that went stale cannot put the stale copy back.
    ///   The engine is an actor, so this is the async form of that chain, and
    ///   the window is a JavaScript call wide.
    /// * **Nothing is stamped.** A merged record keeps the cloud's `rev`.
    ///   Bumping it would make this Mac look like it had edited every record it
    ///   received, and it would push them all straight back.
    /// * **`settings.cloud` is left exactly as it is.** The desktop's own
    ///   `viewSafeForLocal` decides whether its cached server view still holds,
    ///   and after a merge the book has only moved FORWARD — so the view stays
    ///   valid and nothing here has to reach into another app's bookkeeping.
    func pullFromCloud() async {
        cloudProblem = nil
        cloudSent = nil
        cloudPulled = nil
        cloudBusy = true
        defer { cloudBusy = false }
        guard let build = source.build, let engine, let dek = cloudDek else {
            cloudProblem = words.callIt("mac.move_sample"); return
        }
        guard canMoveJobs else {
            cloudProblem = words.callIt("mac.read_only"); return
        }
        do {
            let connection = try CloudReader.connection(settingsDict)
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }

            let session = URLSession(configuration: .ephemeral)
            let reply = try await CloudReader.pull(connection, token: token) { request in
                try await session.data(for: request)
            }
            let folded = try await CloudReader.store(reply, dek: dek, engine: engine)

            // Before anything is written. A shop that does not like what came
            // down has this morning's book to go back to.
            await backUpNow()

            var report: KhaytEngine.Merged?
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let merged = try await engine.mergeFromCloud(local: root, server: folded.store)
                root = merged.store
                report = merged
            }
            cloudPulled = report
            await load(source)

            // Say what is true now rather than what was true before: compare
            // the book as it stands against the store that was just folded in.
            let mine = (try? Data(contentsOf: build.storeURL))
                .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
            let collections = (try? await engine.storeCollections()) ?? []
            cloudCheck = CloudCompare.compare(here: mine, there: folded.store,
                                              collections: collections, cloudRev: reply.rev,
                                              chain: folded.chain, applied: folded.applied)
        } catch let refusal as StoreWriter.Refusal {
            cloudProblem = refusal.description
        } catch let failure as CloudReader.Failure {
            cloudProblem = failure.description
        } catch let failure as SyncCrypto.Failure {
            cloudProblem = failure.description
        } catch let locked as Secrets.Failure {
            cloudProblem = locked.description
        } catch {
            cloudProblem = String(describing: error)
        }
    }

    /// Merge the cloud into this book, then replace the cloud with this book.
    ///
    /// Only for a shop whose delta chain the service refuses. The order is the
    /// whole safety argument and it is written as one function so the two
    /// halves cannot drift apart: after the merge this book is a superset of
    /// what the cloud held at `baseRev`, so replacing the cloud with it loses
    /// nothing — and if the cloud moved while we were doing it, `baseRev` earns
    /// a 409 and nothing is written at all.
    private func sendWholeBookAfterMerging(
        connection: CloudReader.Connection, token: String, dek: Data, engine: KhaytEngine,
        build: StoreReader.Build, server: [String: JSONValue], baseRev: Int,
        session: URLSession
    ) async throws -> CloudWriter.Sent {
        // A backup first, exactly as a pull takes one: this writes to the book.
        await backUpNow()

        var merged: KhaytEngine.Merged?
        var book: [String: JSONValue] = [:]
        try await StoreWriter.update(
            storeURL: build.storeURL,
            owns: { StoreLock.weOwnIt(build) },
            whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
        ) { root in
            let out = try await engine.mergeFromCloud(local: root, server: server)
            root = out.store
            merged = out
            book = out.store
        }
        guard let report = merged else {
            throw CloudWriter.Failure.malformed("the merge produced nothing to send")
        }
        cloudPulled = report
        await load(source)

        // MASKED, and this is the last thing before it is sealed. The desktop's
        // renderer is handed a store whose secrets are already masks; this app
        // reads the book from disk and holds the real ones, so it has to take
        // them out itself or the shop's API key, sync token and S3 secret go up
        // with everything else.
        let forCloud = try await engine.storeForCloud(book)
        return try await CloudWriter.sendWholeStore(
            connection, token: token, store: forCloud, dek: dek, baseRev: baseRev,
            mergedFrom: report) { request in
            try await session.data(for: request)
        }
    }

    private func cloudKeyset() -> JSONValue? {
        guard case .object(let cloud)? = settingsDict["cloud"] else { return nil }
        return cloud["keyset"]
    }

    // MARK: - What the printers are doing

    /// Read the machine's own job history and keep it, for the nozzle counter.
    ///
    /// THE PRINTER IS THE GROUND TRUTH FOR WEAR, and the order log is a sample
    /// of it. `nozzle-wear` counts completed ORDERS, so the U1 on this bench —
    /// which has extruded twelve kilos across a hundred and thirty-three jobs
    /// while nineteen of them were customer orders — reported a fraction of its
    /// real wear, and the replacement warning would fire late, in the direction
    /// that ruins parts.
    ///
    /// It REPLACES the order log for wear specifically and is ignored
    /// everywhere else; mixing the two would double-count every job that is
    /// both an order and a print. That rule is `lib/moonraker-history.js`'s and
    /// is not restated here.
    func importPrinterHistory(_ machine: Machine) async {
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            spendProblem = words.callIt("mac.move_no_engine"); return
        }
        importingHistory = machine.id
        defer { importingHistory = nil }
        do {
            let incoming = try await PrinterWatch.history(machine, engine: engine)
            var kept = 0
            var added = 0
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var floor = Self.rows(root, "machines")
                guard let at = floor.firstIndex(where: { Self.recordId($0) == machine.id }),
                      case .object(var fields) = floor[at] else {
                    throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                }
                var before: [JSONValue] = []
                if case .object(let held)? = fields["printerHistory"],
                   case .array(let jobs)? = held["jobs"] { before = jobs }
                let merged = try await engine.mergePrinterHistory(before, incoming)
                kept = merged.count
                added = merged.count - before.count
                fields["printerHistory"] = .object([
                    "source": .string("moonraker"),
                    "importedAt": .string(StoreWriter.iso(Date())),
                    "jobs": .array(merged),
                ])
                StoreWriter.stamp(&fields)
                floor[at] = .object(fields)
                root["machines"] = .array(floor)
            }
            await load(source)
            // What it actually found, in the shop's own units. "Imported" alone
            // says nothing about whether the number that matters moved.
            let totals = try? await engine.printerHistoryTotals(incoming, since: "")
            var line = words.callIt("mac.history_read") + " \(kept)"
            if added > 0 { line += " (+\(added))" }
            if let totals {
                line += " · \(Int(totals.grams)) \(words.callIt("common.grams"))"
                line += " · \(Int(totals.hours)) \(words.callIt("common.hours"))"
            }
            spendNote = line
        } catch {
            spendProblem = words.callIt("mac.history_failed") + " " + PrinterWatch.say(error)
        }
    }

    /// The machine whose history is being read, for the button to say so.
    var importingHistory: Machine.ID?


    /// The live poll. Started when a book is opened and stopped with it, so a
    /// window showing the sample shop is not knocking on a shop's printers.
    // MARK: - Adding a model

    /// What the last import had to say. Cleared by the next one.
    var importNote: String?
    var importProblem: String?
    /// True while a model is being measured. A 46 MB 3MF takes a few seconds
    /// and a window that looks frozen for a few seconds is a window somebody
    /// clicks again.
    private(set) var importing = false
    /// How far a batch has got, and what it is reading right now. Nil for a
    /// single file, which is over before a progress bar would finish drawing.
    private(set) var importProgress: (done: Int, total: Int, name: String)?
    /// Set by the Stop button. A batch checks it between files, so it stops
    /// cleanly between imports rather than halfway through one.
    var importCancelled = false

    /// Ask for a file and add it.
    func addModelToLibrary() async {
        importNote = nil
        importProblem = nil
        guard source.build != nil else {
            importProblem = words.callIt("mac.move_sample"); return
        }
        let panel = NSOpenPanel()
        // MANY, AND FOLDERS. A shop importing what it has downloaded has
        // hundreds of files in nested folders, and one trip through this panel
        // per file is not an import, it is an afternoon.
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = words.callIt("mac.add_model")
        // Archives too: a zip is not a model, but the models come out of it —
        // see ArchiveImport. Offering only model types meant a shop that had
        // just downloaded one could not even select it.
        panel.allowedContentTypes = LibraryImport.kinds.union(ArchiveImport.kinds).compactMap {
            UTType(filenameExtension: $0)
        }
        // A slicer's own type is not always registered on a Mac that has no
        // slicer, and a panel that will open nothing is worse than one that
        // opens too much.
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        await addModelsToLibrary(panel.urls)
    }

    /// Every model under what was chosen, in a stable order.
    ///
    /// A folder is walked; a file is taken as it is. Anything that is not a
    /// kind the library holds is passed over silently — a folder of models has
    /// READMEs and slicer projects in it, and a summary that reported each of
    /// them as a failure would bury the ones that matter.
    ///
    /// The library's own root is skipped. Importing the vault into itself would
    /// refuse every file as a duplicate, which is harmless, and take a very long
    /// time to do it.
    static func modelsUnder(_ chosen: [URL], skipping root: String?) -> [LibraryImport.Incoming] {
        let fm = FileManager.default
        var found: [LibraryImport.Incoming] = []
        let vault = root.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        func isInVault(_ u: URL) -> Bool {
            guard let vault else { return false }
            return u.standardizedFileURL.path.hasPrefix(vault)
        }
        for url in chosen where !isInVault(url) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let next = walker?.nextObject() as? URL {
                    if LibraryImport.kinds.contains(next.pathExtension.lowercased()),
                       !isInVault(next) {
                        // Where it sat on disk IS the shop's grouping — see
                        // `ImportGrouping` for why it is not just the parent.
                        found.append(LibraryImport.Incoming(
                            url: next, group: ImportGrouping.group(for: next, chosen: url)))
                    }
                }
            } else if LibraryImport.kinds.contains(url.pathExtension.lowercased()) {
                // Picked on its own: no group. The shop chose one file, not a set.
                found.append(LibraryImport.Incoming(url: url, group: nil))
            }
        }
        // Sorted so a run is repeatable and a person watching can follow it.
        return found.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    /// Import everything under what was chosen.
    ///
    /// ONE reload at the end rather than one per file. `LibraryImport.add(_:shop:)`
    /// re-reads the whole book after each import, which is right for a single
    /// file and quadratic for three thousand — a megabyte of JSON parsed once
    /// per model. This calls the lower seam directly and reloads once.
    ///
    /// `known` grows as it goes, so two copies of the same model inside one
    /// selection do not both get in.
    func addModelsToLibrary(_ chosen: [URL]) async {
        importNote = nil
        importProblem = nil
        importCancelled = false
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            importProblem = LibraryImport.Failure.notOurs.description; return
        }
        guard let roots = libraryRoots else {
            importProblem = LibraryImport.Failure.noLibrary.description; return
        }
        guard let engine else { importProblem = "the engine is not loaded"; return }

        // ARCHIVES FIRST, so what comes out of them is imported like anything
        // else. A shop downloads a model as a zip because that is how every
        // model site hands one over, and dropping one here used to do nothing
        // at all — the walk below looks for models and a `.zip` is not one, so
        // it was skipped in silence.
        //
        // The archive itself is never consumed: it stays where the shop put it,
        // and only copies of the models inside are moved into the vault.
        var files = Self.modelsUnder(chosen, skipping: roots.primary)
        var scratches: [URL] = []
        var refusals: [String] = []
        for url in chosen where ArchiveImport.kinds.contains(url.pathExtension.lowercased()) {
            do {
                let out = try await ArchiveImport.expand(url, engine: engine)
                scratches.append(out.scratch)
                // Grouped by the archive's own name, the way a folder of models
                // is grouped by the folder — see `ImportGrouping`.
                files += out.models.map { LibraryImport.Incoming(url: $0, group: out.group) }
            } catch let refusal as ArchiveImport.Failure {
                refusals.append(refusal.description)
            } catch {
                refusals.append(String(describing: error))
            }
        }
        // The scratch copies are consumed by the import (it MOVES them in), but
        // a refusal or a duplicate leaves some behind, and they are in the
        // system temp directory either way.
        defer { for dir in scratches { try? FileManager.default.removeItem(at: dir) } }

        guard !files.isEmpty else {
            // A refused archive is a reason, not an absence. "Nothing to
            // import" beside a zip the shop can see is the unhelpful half of
            // this, and it is what the old code would have said.
            importProblem = refusals.isEmpty
                ? words.callIt("mac.import_nothing")
                : refusals.joined(separator: "\n")
            return
        }
        if !refusals.isEmpty { importProblem = refusals.joined(separator: "\n") }

        importing = true
        defer { importing = false; importProgress = nil }

        let titles = Dictionary(self.files.compactMap { f in
            f.contentHash.map { ($0, f.title) }
        }, uniquingKeysWith: { a, _ in a })

        // The loop itself is `LibraryImport.addMany`, shared with `--import`.
        // What is left here is only how a WINDOW says what happened: a banner
        // per file, and a sentence at the end.
        let report = await LibraryImport.addMany(
            files,
            storeURL: build.storeURL,
            libraryRoot: URL(fileURLWithPath: roots.primary),
            knownHashes: Set(self.files.compactMap(\.contentHash)),
            nameOfExisting: { titles[$0] },
            engine: engine,
            analyseRisk: analysesRiskAtImport,
            owns: { StoreLock.weOwnIt(build) },
            whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
            shouldStop: { [weak self] in self?.importCancelled ?? false },
            progress: { [weak self] done, total, file in
                self?.importProgress = (done: done, total: total, name: file.lastPathComponent)
            })

        await load(source)
        importProgress = nil
        importNote = words.callIt("mac.import_done", [
            "moved": .number(Double(report.moved)),
            "duplicates": .number(Double(report.duplicates)),
            "failed": .number(Double(report.failures.count)),
        ])
        if !report.failures.isEmpty {
            importProblem = report.failures.prefix(10).joined(separator: "\n")
                + (report.failures.count > 10
                   ? "\n" + "… and \(report.failures.count - 10) more" : "")
        }
    }

    /// Which of the shop's machines each measured model goes on.
    ///
    /// Only the models that were measured: a model with no `geometryKey` has no
    /// bounds, and guessing at one would put a warning on a screen about a fact
    /// nobody has.
    static func measureFit(_ files: [LibraryFile], machines: [JSONValue],
                           engine: KhaytEngine?) async -> [String: KhaytEngine.Fit] {
        guard let engine, !machines.isEmpty else { return [:] }
        var out: [String: KhaytEngine.Fit] = [:]
        for file in files {
            guard let mesh = file.mesh else { continue }
            if let fit = try? await engine.bestFit((x: mesh.x, y: mesh.y, z: mesh.z),
                                                   among: machines) {
                out[file.id] = fit
            }
        }
        return out
    }

    // MARK: - Converting a model

    /// Convert a model for another printer, and put the result where the shop
    /// says. `nil` target means normalise: strip the vendor's settings and
    /// leave a clean standard 3MF that any slicer opens.
    ///
    /// The save panel first, deliberately. A conversion that runs and then asks
    /// where to put it has already spent the time before the shop can change
    /// its mind, and a shop that cancels should have cost nothing.
    func convertModel(_ file: LibraryFile, targetId: String?) async {
        convertNote = nil
        convertProblem = nil
        guard let source = modelFile(for: file) else {
            convertProblem = words.callIt("mac.not_found"); return
        }
        guard let engine else { convertProblem = "the engine is not loaded"; return }

        let target = printerProfiles.first { $0.id == targetId }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedConvertName(file, target: target)
        panel.allowedContentTypes = [UTType(filenameExtension: "3mf")].compactMap { $0 }
        panel.canCreateDirectories = true

        // ASKED HERE, WITH EVERYTHING ELSE ABOUT WHERE IT GOES.
        //
        // In the same panel as the name and the folder, because it is the same
        // question — what this conversion is FOR. A shop converting a model to
        // move to a new printer wants the old one out of the way; a shop
        // keeping both wants both. Asking afterwards would be asking about work
        // already done.
        //
        // OFF by default. Keeping both is the answer that loses nothing.
        let replace = NSButton(checkboxWithTitle: words.callIt("mac.replace_original"),
                               target: nil, action: nil)
        replace.state = .off
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        replace.frame = NSRect(x: 12, y: 5, width: 296, height: 20)
        holder.addSubview(replace)
        panel.accessoryView = holder

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let replaceOriginal = replace.state == .on

        converting = true
        defer { converting = false }
        var options: [String: JSONValue] = [:]
        if let targetId { options["targetId"] = .string(targetId) }
        else { options["mode"] = .string("normalize") }

        do {
            _ = try await Converter.convert(source, into: destination,
                                            options: options, engine: engine)

            // AND INTO THE LIBRARY.
            //
            // A conversion used to end at a file in a folder. The shop then had
            // to go and import the thing it had just made, in the one app whose
            // whole job is knowing what models it has — so the converted file
            // was the only model in the building Khayt did not know about.
            //
            // `keepOriginal: true` because the shop chose that folder in a save
            // panel a moment ago. The import copies the bytes in and would
            // otherwise take the file away from where it was just asked to put
            // it. The library ends up with its own copy, which is what the
            // library is.
            //
            // A failed import is NOT a failed conversion: the file exists and is
            // correct, and saying otherwise would send a shop looking for a
            // problem with a conversion that worked. It is said separately.
            var landed = false
            do {
                _ = try await LibraryImport.add(destination, shop: self, keepOriginal: true)
                landed = true
            } catch let refusal as LibraryImport.Failure {
                convertProblem = refusal.description
            } catch {
                convertProblem = String(describing: error)
            }

            // Only once the replacement is IN the library. Putting the
            // original aside in favour of a file the library does not have
            // would leave the shop with neither.
            if replaceOriginal, landed,
               let replacement = files.first(where: { $0.name == destination.lastPathComponent })
                                 ?? files.first(where: { $0.title == destination.deletingPathExtension().lastPathComponent }) {
                await supersede(file, with: replacement.id)
            }

            convertNote = words.callIt(landed ? "mac.converted_into_library" : "mac.converted", [
                "name": .string(destination.lastPathComponent),
                "target": .string(target?.name ?? words.callIt("mac.standard_3mf")),
            ])
        } catch let refusal as Converter.Failure {
            convertProblem = refusal.description
        } catch {
            convertProblem = String(describing: error)
        }
    }

    /// Put a model aside because another has taken its place.
    ///
    /// ARCHIVED, NOT DELETED. A job printed from this model months ago was
    /// printed from THESE bytes. Deleting them so the converted file could take
    /// the record's place would make that job appear to have been printed from
    /// a file it never saw, and a book that misreports its own history is worse
    /// than a library with one extra thing in it.
    ///
    /// So the record keeps everything it had, gains the date and the id of what
    /// replaced it, and stops being offered. The file stays where it is.
    func supersede(_ original: LibraryFile, with replacement: String) async {
        guard let build = source.build else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            try StoreWriter.updateRecord(build, collection: "printFiles", id: original.id) { record in
                record["archivedAt"] = .string(now)
                record["supersededBy"] = .string(replacement)
            }
        } catch {
            convertProblem = String(describing: error)
            return
        }
        await load(source)
    }

    /// Bring a model back into the library.
    ///
    /// The other half, because a one-way door is not a decision a shop should
    /// have to be sure about before it makes it.
    func unarchive(_ file: LibraryFile) async {
        guard let build = source.build else { return }
        do {
            try StoreWriter.updateRecord(build, collection: "printFiles", id: file.id) { record in
                record.removeValue(forKey: "archivedAt")
                record.removeValue(forKey: "supersededBy")
            }
        } catch {
            convertProblem = String(describing: error)
            return
        }
        await load(source)
    }

    /// `Falcon hood — Snapmaker U1.3mf`. The target in the name, because a
    /// folder of conversions of one model is otherwise a folder of the same
    /// filename with numbers after it.
    func suggestedConvertName(_ file: LibraryFile,
                              target: KhaytEngine.PrinterProfile?) -> String {
        let base = file.title.isEmpty ? "model" : file.title
        let suffix = target?.name ?? words.callIt("mac.standard_3mf")
        return "\(base) — \(suffix).3mf"
    }

    // MARK: - Gift cards

    /// A code somebody can read down a telephone: no I/O/0/1, nothing to
    /// mishear. Only a SUGGESTION — the sheet lets it be typed over, and the
    /// shared rule has the final say on whether it is allowed.
    static func giftCardCode() -> String {
        let alphabet = Array("ACDEFGHJKLMNPQRTUVWXY2346789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    /// Issue one, through `lib/gift-card.js`.
    ///
    /// The rule builds the record and refuses the bad ones; this writes what it
    /// returns. Nothing is written when it refuses, so a rejected code leaves
    /// the book exactly as it was.
    /// Returns nil when the card was issued, or what to tell the shop.
    func issueGiftCard(code: String, balance: Double,
                       issuedTo: String?, expires: Date?) async -> String? {
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            return words.callIt("mac.read_only")
        }
        guard let engine else { return "the engine is not loaded" }

        var input: [String: JSONValue] = [
            "code": .string(code),
            "initialBalance": .number(balance),
        ]
        if let issuedTo {
            input["issuedTo"] = .string(issuedTo)
            input["issuedToName"] = .string(clientNames[issuedTo]?.name ?? "")
        }
        if let expires { input["expiresAt"] = .string(Self.localDay(expires)) }

        let made: KhaytEngine.IssuedCard
        do {
            made = try await engine.newGiftCard(input, id: Self.uid("GC"),
                                                now: Self.isoNow(), existing: giftCardRows)
        } catch {
            return String(describing: error)
        }
        guard made.ok, let card = made.card else {
            // The rule answers with a key; the window owns the language.
            return words.callIt(made.error ?? "giftCardCodeInvalid")
        }

        do {
            try StoreWriter.update(storeURL: build.storeURL,
                                   owns: { StoreLock.weOwnIt(build) },
                                   whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }) { root in
                var rows: [JSONValue] = []
                if case .array(let existing)? = root["giftCards"] { rows = existing }
                rows.append(card)
                root["giftCards"] = .array(rows)
            }
        } catch {
            return String(describing: error)
        }
        await load(source)
        return nil
    }

    /// The same, for a file that arrived some other way.
    func addModelToLibrary(_ url: URL) async {
        importing = true
        defer { importing = false }
        do {
            let added = try await LibraryImport.add(url, shop: self)
            let key = added.movedIn ? "mac.model_moved" : "mac.model_added"
            importNote = added.measured
                ? words.callIt(key,
                               ["name": .string(added.name),
                                "n": .number(Double(added.triangleCount ?? 0))])
                : words.callIt(key + "_plain", ["name": .string(added.name)])
        } catch let refusal as LibraryImport.Failure {
            importProblem = refusal.description
        } catch {
            importProblem = String(describing: error)
        }
    }

    // MARK: - The shop's slicers

    /// The slicers this shop has configured, read by the shared rule.
    private(set) var slicers: [KhaytEngine.Slicer] = []
    /// The one to reach for when nobody has said which.
    private(set) var defaultSlicer: KhaytEngine.Slicer?
    /// What the last attempt to open a model in a slicer had to say.
    var slicerProblem: String?

    /// Read them when the book loads. Two crossings, once, rather than one per
    /// model in a context menu that is built while a grid of four hundred draws.
    func readSlicers() async {
        guard let engine else { slicers = []; defaultSlicer = nil; return }
        slicers = (try? await engine.slicers(settings: settingsDict)) ?? []
        defaultSlicer = try? await engine.defaultSlicer(settings: settingsDict)
    }

    /// Every slicer this Mac has installed, whether or not the shop has added it.
    ///
    /// Asks the shared rule twice — once for whether a bundle may be launched at
    /// all, once for what to call it — so a slicer Khayt would offer and one
    /// this app offers are the same slicer under the same name.
    func installedSlicers() async -> [(name: String, path: String)] {
        guard let engine else { return [] }
        // The two crossings are hoisted out of the walk: a JSContext call per
        // entry in /Applications would be a hundred of them to list four.
        var allowedCache: [String: Bool] = [:]
        var nameCache: [String: String] = [:]
        let entries = SlicerFinder.searched.flatMap {
            (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []
        }
        for entry in entries where entry.lowercased().hasSuffix(".app") {
            allowedCache[entry] = (try? await engine.mayLaunchAsSlicer(path: entry)) ?? false
            if allowedCache[entry] == true {
                nameCache[entry] = (try? await engine.slicerDisplayName(path: entry)) ?? entry
            }
        }
        return SlicerFinder.installed(allowed: { allowedCache[$0] ?? false },
                                      name: { nameCache[$0] ?? $0 })
    }

    /// Write the shop's slicer list and which of them is the default.
    ///
    /// NOT through `settings-edit`. That rule maps FORM FIELDS onto settings
    /// keys and keeps every key a form does not carry — which is exactly what
    /// makes a pane safe, and exactly why a list cannot go through it: it has no
    /// form field, so it would be kept rather than replaced, and Save would do
    /// nothing at all. Two named keys, written explicitly, is the same
    /// narrowness by another route.
    func saveSlicers(_ list: [KhaytEngine.Slicer], defaultId: String) async {
        settingsProblem = nil
        settingsNote = nil
        guard let build = source.build else {
            settingsProblem = words.callIt("mac.settings_sample"); return
        }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var settings = Self.settings(root)
                settings["slicers"] = .array(list.map { slicer in
                    .object(["id": .string(slicer.id), "name": .string(slicer.name),
                             "path": .string(slicer.path), "args": .string(slicer.args)])
                })
                settings["defaultSlicerId"] = .string(defaultId)
                // The legacy single slicer, kept in step. `lib/slicers.js` says
                // it is mirrored to the default "so existing consumers keep
                // working unchanged" — the kanban print, machine slice-and-
                // print and the quote slice all still read it, in the app next
                // to this one.
                if let chosen = list.first(where: { $0.id == defaultId }) ?? list.first {
                    settings["slicer"] = .object(["path": .string(chosen.path),
                                                  "args": .string(chosen.args)])
                }
                root["settings"] = .object(settings)
            }
            await load(source)
            settingsNote = words.callIt("mac.settings_saved")
        } catch {
            settingsProblem = String(describing: error)
        }
    }

    /// Whether the shop can take another job, and when it would start.
    ///
    /// SEVEN DAYS, the same window the other app uses. The load is not clamped
    /// at 100 — a machine three weeks behind is a different answer from one
    /// exactly full, and that difference is the whole point of the card.
    func capacity() async -> KhaytEngine.Capacity? {
        guard let engine else { return nil }
        return try? await engine.capacity(
            machines: machineRows, orders: orderRows, days: 7,
            unassigned: words.callIt("dash.unassigned"))
    }

    /// Which machine scraps the most of what it prints.
    ///
    /// The whole book, no window. A scrap rate over one month of a small shop
    /// is two or three failures, which is not a rate — and the question this
    /// answers, whether a machine is worth keeping, is not a monthly one.
    func machineReliability() async -> KhaytEngine.MachineReliability? {
        guard let engine else { return nil }
        return try? await engine.machineReliability(
            machines: machineRows, orders: orderRows, waste: wasteRows,
            from: "", to: "", unassigned: words.callIt("dash.unassigned"))
    }

    /// What the shelf costs, and whether that has moved.
    ///
    /// The RAW inventory rows: `materialCost` reads `spoolWeight` and the unit,
    /// and `Spool` carries neither — re-encoding the decoded shelf would price
    /// every sheet good as if it were filament.
    func materialCost() async -> KhaytEngine.MaterialCost? {
        guard let engine else { return nil }
        return try? await engine.materialCost(inventory: inventoryRows, minimum: 2)
    }

    /// Keep the shop's saved reports.
    ///
    /// The same narrowness as `saveSlicers` and for the same reason: one named
    /// key, written explicitly, rather than through `settings-edit` — which
    /// keeps every key no form field carries, so a list would be kept rather
    /// than replaced and Save would do nothing.
    ///
    /// The LIST is computed by `lib/saved-reports.js` before it gets here. This
    /// only writes it, so the rule about what a re-save under one name does
    /// lives in one place and both apps obey it.
    func saveReports(_ list: [KhaytEngine.SavedReport]) async {
        settingsProblem = nil
        settingsNote = nil
        guard let build = source.build else {
            settingsProblem = words.callIt("mac.settings_sample"); return
        }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var settings = Self.settings(root)
                settings["savedReports"] = .array(list.map { r in
                    .object(["id": .string(r.id), "name": .string(r.name),
                             "fields": .array(r.fields.map { .string($0) }),
                             "statusIn": .array(r.statusIn.map { .string($0) }),
                             "from": .string(r.from), "to": .string(r.to)])
                })
                root["settings"] = .object(settings)
            }
            await load(source)
        } catch {
            settingsProblem = String(describing: error)
        }
    }

    /// Open a model in a named slicer.
    func openInSlicer(_ url: URL, slicer: KhaytEngine.Slicer) async {
        slicerProblem = nil
        guard let engine else { return }
        let allowed = (try? await engine.mayLaunchAsSlicer(path: slicer.path)) ?? false
        let refusal = FileActions.openInSlicer(url, slicerPath: slicer.path) { _ in allowed }
        switch refusal {
        case nil: return
        case "notAllowed":
            // Named as a refusal rather than a failure. A shop whose settings
            // arrived from somewhere else deserves to know this was a decision.
            slicerProblem = words.callIt("mac.slicer_not_allowed", ["name": .string(slicer.name)])
        default:
            slicerProblem = words.callIt("mac.slicer_missing", ["name": .string(slicer.name)])
        }
    }

    // MARK: - Syncing without being asked

    /// What the sidebar says about sync.
    private(set) var syncStatus: AutoSync.Status = .off

    private var syncTask: Task<Void, Never>?
    /// How many attempts have failed in a row, for the backoff.
    private var syncFailures = 0
    /// A change arrived while a push was in flight — run once more after.
    private var syncAgainAfter = false
    private var syncInFlight = false
    /// When the whole book last went up, for the floor. See `AutoSync`.
    private var lastWholeBookPush: Date?
    /// Set once the service has refused a delta for this shop. The desktop
    /// remembers the same 404 for the same reason: one probe per session.
    private var chainIsClosed = false

    /// Start listening for this app's own writes.
    ///
    /// Called once, from the app's entry point. Every path that changes the
    /// book lands in `StoreWriter.atomicWrite`, so this hears about all of them
    /// — including the ones written after this comment.
    func listenForOwnWrites() {
        StoreWriter.didWrite = { [weak self] url in
            guard let self, self.source.build?.storeURL == url else { return }
            self.bookChanged()
        }
    }

    /// This app just changed the book. Push it, shortly.
    func bookChanged() {
        guard AutoSync.shouldSyncOnWrite(unlocked: cloudUnlocked,
                                         connected: Self.cloudConnected(settingsDict),
                                         canWrite: canMoveJobs) else {
            noteSync("a change was not sent — "
                   + (!Self.cloudConnected(settingsDict) ? "no cloud on this book"
                      : !cloudUnlocked ? "the cloud is locked"
                      : "another app owns this book"))
            return
        }
        if syncInFlight { syncAgainAfter = true; return }
        // A fresh edit supersedes a pending backoff and resets it — the same
        // rule `scheduleSync` applies, and for the same reason: the shop has
        // just told us the situation changed.
        syncFailures = 0
        scheduleSync(after: AutoSync.debounce)
    }

    private func scheduleSync(after delay: Duration) {
        syncTask?.cancel()
        syncStatus = .waiting
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.autoSyncNow()
        }
    }

    private func cancelPendingSync() {
        syncTask?.cancel()
        syncTask = nil
        syncAgainAfter = false
    }

    /// One automatic push.
    ///
    /// It reuses `sendToCloud()` rather than having its own opinion about how
    /// to send. That matters more than the duplication it saves: `sendToCloud`
    /// is where the whole-book fallback is made legal by merging the cloud in
    /// first, and a second, quieter path to `PUT /store` is precisely the thing
    /// `CloudWriter`'s own comment says must not exist.
    ///
    /// A 409 needs no special handling here. `sendToCloud` begins with a fresh
    /// pull, so the retry below measures against the head the cloud actually
    /// has — which is what Khayt's pull-merge-repush achieves by a longer road.
    ///
    /// ── IT PUSHES A BOOK IT IS ABOUT TO WRITE TO, AND THAT TERMINATES ─────
    ///
    /// The whole-book path merges the cloud into this book before it uploads,
    /// which is a write, which the listener hears — so a push schedules a push.
    /// It settles rather than spinning: `bookChanged` sees the sync in flight
    /// and only sets `syncAgainAfter`, and the one follow-up finds an empty
    /// outbox and returns before sending anything. A gated shop pays one extra
    /// GET a quarter of an hour later, which is the floor doing its job.
    func autoSyncNow() async {
        guard cloudDek != nil, Self.cloudConnected(settingsDict), canMoveJobs else {
            syncStatus = Self.cloudConnected(settingsDict) ? .locked : .off
            return
        }
        guard !syncInFlight, !cloudBusy else { syncAgainAfter = true; return }

        // The expensive path has a floor. Checked BEFORE the pull, so a gated
        // shop inside its floor costs nothing at all rather than a request.
        if chainIsClosed, !AutoSync.mayPushWholeBook(lastAt: lastWholeBookPush) {
            let wait = AutoSync.wholeBookFloor
                - Date().timeIntervalSince(lastWholeBookPush ?? .distantPast)
            scheduleSync(after: .seconds(Int(max(1, wait.rounded(.up)))))
            return
        }

        syncInFlight = true
        syncStatus = .syncing
        await sendToCloud()
        syncInFlight = false

        if cloudSent?.wholeStore == true {
            chainIsClosed = true
            lastWholeBookPush = Date()
        }

        if let problem = cloudProblem {
            syncStatus = .failing(problem)
            noteSync("failed — \(problem)")
            let delay = AutoSync.retryDelay(attempt: syncFailures)
            syncFailures += 1
            scheduleSync(after: delay)
            return
        }

        syncFailures = 0
        syncStatus = .synced(Date())
        noteSync(cloudSent.map { $0.wholeStore ? "sent the whole book" : "sent \($0.count)" }
                 ?? "nothing to send")
        if syncAgainAfter {
            syncAgainAfter = false
            scheduleSync(after: AutoSync.debounce)
        }
    }

    /// The only trace this leaves, for the same reason `note` exists beside the
    /// lead-time publisher: it runs on a timer with nothing on screen, and when
    /// it silently does nothing there is otherwise no way to tell whether it
    /// never ran, declined, or was refused.
    private func noteSync(_ what: String) {
        FileHandle.standardError.write(Data("khayt: sync — \(what)\n".utf8))
    }

    /// Say where sync stands, without pushing anything.
    ///
    /// Called when the book is loaded: a shop that has not unlocked the cloud
    /// this session should read "Locked", not "Not synced automatically", and
    /// certainly not silence.
    func refreshSyncStatus() {
        // A push reloads the book when it merges, and this runs on every load.
        // Without this line a whole-book push would overwrite its own
        // "Sending…" with "Syncing automatically" halfway through.
        guard !syncInFlight else { return }
        guard Self.cloudConnected(settingsDict) else { syncStatus = .off; return }
        if cloudDek == nil { syncStatus = .locked; return }
        if case .synced = syncStatus { return }
        if case .failing = syncStatus { return }
        syncStatus = .idle
    }

    // MARK: - The shop's published delivery dates

    private var leadTimeTask: Task<Void, Never>?

    /// What the last successful publish said, so a withdrawal happens ONCE.
    /// `.some(nil)` means "we published a withdrawal"; `nil` means we have not
    /// published anything this session.
    private var leadTimePublished: JSONValue??

    /// What went wrong last, for the diagnostic pane. Never surfaced as an
    /// alert: a promise nobody can read is better than a shop interrupted about
    /// its storefront while it is trying to work.
    private(set) var leadTimeProblem: String?

    /// Electron's cadence, and for its reasons: once shortly after launch so a
    /// shop that has just opened the app is answering, then every six hours —
    /// comfortably inside the 24-hour default staleness window, so a storefront
    /// keeps quoting even if one publish fails.
    static let leadTimeFirst: Duration = .seconds(90)
    static let leadTimeEvery: Duration = .seconds(6 * 60 * 60)

    /// ALREADY RUNNING IS LEFT ALONE, and that is the whole point.
    ///
    /// `load` runs again every time the book changes on disk — a backup, a sync,
    /// the shop typing into a sheet — and the first version of this restarted
    /// the task each time. The task opens with a ninety-second wait, so a book
    /// touched more often than that reset the clock before it ever expired and
    /// this published NOTHING, for ever, on a machine where everything else
    /// worked. It was watched doing exactly that for two minutes with a trace
    /// attached and not one line came out.
    ///
    /// The task holds no snapshot of the shop; it reads the current state on
    /// each tick. So the right lifetime is the book's, not the load's.
    func startPublishingLeadTime() {
        guard leadTimeTask == nil else { return }
        leadTimeTask = Task { [weak self] in
            try? await Task.sleep(for: Shop.leadTimeFirst)
            while !Task.isCancelled {
                await self?.publishLeadTime()
                try? await Task.sleep(for: Shop.leadTimeEvery)
            }
        }
    }

    func stopPublishingLeadTime() {
        leadTimeTask?.cancel()
        leadTimeTask = nil
    }

    /// Build this shop's promise and send it — or withdraw the last one.
    ///
    /// ── WHY IT WAITS FOR THE PRINTERS ─────────────────────────────────────
    ///
    /// `lead-time-publish` asks the status cache what each machine is doing. A
    /// machine it finds nothing about is a machine with nothing on it, so a
    /// publish made before the first poll lands prices the shop's capacity as
    /// though every printer were free — and it would overwrite a snapshot the
    /// Electron app had published from a cache that DID know. Two apps, one
    /// shop, and the one with less information wins by being later.
    ///
    /// So a shop with machines this app can watch publishes nothing until at
    /// least one of them has answered. A shop with none publishes immediately:
    /// there is nothing to wait for, and waiting for ever is how a feature
    /// silently does nothing.
    func publishLeadTime() async {
        guard let engine, source.build != nil else { return note("no book open") }
        let watchable = machines.contains { PrinterWatch.notWatched($0) == nil }
        let cache = printers.statusCache
        if watchable && cache.isEmpty { return note("waiting for the printers to answer") }

        do {
            let connection = try CloudReader.connection(settingsDict)
            let snapshot = try await engine.leadTimeSnapshot(
                settings: settingsDict, printLog: orderRows, machines: machineRows,
                today: LeadTimePublisher.localDay(), nowIso: Self.isoNow(), statusCache: cache)

            // Nothing to say and nothing said: a shop that has never turned
            // this on must not be sent a withdrawal every six hours for ever.
            if snapshot == nil, leadTimePublished == nil { return }

            guard let build = source.build else { return }
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }
            let session = URLSession(configuration: .ephemeral)
            try await LeadTimePublisher.publish(connection, token: token, snapshot: snapshot) {
                try await session.data(for: $0)
            }
            leadTimePublished = .some(snapshot)
            leadTimeProblem = nil
            note(snapshot == nil ? "withdrawn" : "published")
        } catch CloudReader.Failure.notConnected {
            // Not an error. Most shops have no cloud, and saying so every six
            // hours would fill a diagnostic pane with the absence of a feature.
            leadTimeProblem = nil
            note("this shop has no cloud")
        } catch {
            leadTimeProblem = String(describing: error)
            note(String(describing: error))
        }
    }

    /// The only trace this leaves.
    ///
    /// It runs on a timer, in the background, and writes nothing to the book —
    /// so when it silently does nothing there is otherwise no way to tell
    /// whether it never ran, refused, or was refused. That was the first
    /// question asked of it and it could not be answered.
    ///
    /// `log stream --predicate 'process == "Khayt"'`, or run the binary
    /// directly and read stderr.
    private func note(_ what: String) {
        FileHandle.standardError.write(Data("khayt: lead time — \(what)\n".utf8))
    }

    /// The injected clock, in the shape `lib/lead-time.js` records.
    static func isoNow(_ now: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: now)
    }

    let printers = PrinterWatch()

    /// The stills from those printers' cameras, on a slower timer of their own —
    /// a picture is worth refetching every few seconds, a status every ten.
    let cameras = Camera()

    // MARK: - Putting a backup back

    /// The backup a shop has chosen and not yet confirmed.
    var restoring: Restore.Candidate?

    /// Every backup on the shelf, newest first — empty for the sample shop.
    var restorable: [Restore.Candidate] {
        guard let build = source.build else { return [] }
        return Restore.list(in: Backups.directory(for: build))
    }

    /// Replace the book with a backup.
    ///
    /// Destructive, and the only write in this app that is. Everything that
    /// makes it safe is in `Restore`: it refuses a file that is not a Khayt
    /// store, refuses a damaged one, copies the book before replacing it, and
    /// carries forward the credentials and the completion history a backup
    /// cannot contain. What is left here is saying which of those happened.
    func restore(_ candidate: Restore.Candidate) async {
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        do {
            try await Restore.restore(candidate.filename, for: build, engine: engine)
            lastBackup = Backups.lastBackupDay(in: Backups.directory(for: build))
            spendNote = words.callIt("mac.restored") + " " + candidate.filename
            await load(source)
        } catch {
            spendProblem = words.callIt("mac.restore_failed") + " " + String(describing: error)
        }
    }

    // MARK: - The shelf

    /// The spool being written down, or corrected.
    var editingSpool: Spool?
    /// True while the sheet is for a spool that is not on the shelf yet.
    var addingSpool = false

    /// Put a spool on the shelf, or correct one that is already there.
    ///
    /// A NEW spool is a new record and is not stamped; an edit is stamped like
    /// every other, because the cloud's sync baseline reads the stamp. The
    /// settings go with it when a colour variant taught the shop's library
    /// something — one swap, or the library forgets what was just typed.
    func saveSpool(_ input: [String: JSONValue], id: Spool.ID?) async {
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            spendProblem = words.callIt("mac.move_no_engine"); return
        }
        var undo: [ChangedRecord] = []
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var shelf = Self.rows(root, "inventory")
                if let id {
                    guard let at = shelf.firstIndex(where: { Self.recordId($0) == id }),
                          case .object(let was) = shelf[at] else {
                        throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                    }
                    let out = try await engine.editSpool(shelf[at], input: input,
                                                         settings: Self.settings(root),
                                                         today: Self.today())
                    if out.refused != nil {
                        throw MoveRefused(sentence: self.words.callIt("inv.material_ph"))
                    }
                    guard case .object(var record) = out.spool else { return }
                    undo.append(ChangedRecord(collection: "inventory", id: id, was: was))
                    StoreWriter.stamp(&record)
                    shelf[at] = .object(record)
                    root["settings"] = .object(out.settings)
                } else {
                    let made = try await engine.newSpool(input, id: Self.uid("INV"), today: Self.today())
                    guard let record = made.spool else {
                        throw MoveRefused(sentence: self.words.callIt("inv.material_ph"))
                    }
                    shelf.append(record)
                }
                root["inventory"] = .array(shelf)
            }
            if !undo.isEmpty { registerMoveUndo(undo, named: words.callIt("mac.edit_spool")) }
            editingSpool = nil
            addingSpool = false
            await load(source)
            spendNote = words.callIt(id == nil ? "inv.added" : "inv.updated")
        } catch let refusal as MoveRefused {
            spendProblem = refusal.sentence
        } catch {
            spendProblem = String(describing: error)
        }
    }

    /// Take a spool off the shelf.
    ///
    /// Undoable, because it is a whole record: a spool deleted by mistake takes
    /// its price history and its usage with it, and nothing else in the book
    /// can reconstruct them.
    func deleteSpool(_ id: Spool.ID) async {
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        var removed: [String: JSONValue]?
        do {
            try StoreWriter.update(build) { root in
                var shelf = Self.rows(root, "inventory")
                guard let at = shelf.firstIndex(where: { Self.recordId($0) == id }),
                      case .object(let was) = shelf[at] else { return }
                removed = was
                shelf.remove(at: at)
                root["inventory"] = .array(shelf)
            }
            if let removed { registerSpoolUndo(removed) }
            await load(source)
            spendNote = words.callIt("inv.removed")
        } catch {
            spendProblem = String(describing: error)
        }
    }

    // MARK: - Taking a product off the catalogue

    /// Delete a product, and everything that pointed at it.
    ///
    /// ── WHAT A DELETE HAS TO DO BESIDES DELETING ──────────────────────────
    ///
    /// Dropping the row is the easy quarter of it. `renderer/inventory.js`
    /// also unlinks the jobs that named the product, drops it from any quote
    /// bundle, and removes its pictures from disk — and offers all of that
    /// back as one undo. A Mac delete that only dropped the row would leave a
    /// job pointing at a product that is not there, which is the shape of bug
    /// that shows up months later as a screen that cannot draw.
    ///
    /// PAST INVOICES ARE UNTOUCHED, and the sentence the shop is shown says
    /// so: an invoice is what was actually charged, and a catalogue tidy-up is
    /// not permission to rewrite it.
    func deleteProduct(_ id: String) async {
        productProblem = nil
        productNote = nil
        guard let build = source.build else {
            productProblem = words.callIt("mac.move_sample"); return
        }
        // The pictures, read BEFORE the record goes: afterwards there is
        // nothing left to read their names off.
        let pictureNames = await pictures(of: id).compactMap(\.path)
        var removed: [String: JSONValue]?
        var unlinked: [String] = []
        var bundles: [String] = []
        do {
            try StoreWriter.update(build) { root in
                var rows = Self.rows(root, "products")
                guard let at = rows.firstIndex(where: { Self.recordId($0) == id }),
                      case .object(let was) = rows[at] else { return }
                removed = was
                rows.remove(at: at)
                root["products"] = .array(rows)

                // A job that named this product keeps everything else it has;
                // only the pointer goes.
                var log = Self.rows(root, "printLog")
                for i in log.indices {
                    guard case .object(var order) = log[i],
                          case .string(let named)? = order["productId"], named == id else { continue }
                    order["productId"] = .null
                    StoreWriter.stamp(&order)
                    if case .string(let orderId)? = order["id"] { unlinked.append(orderId) }
                    log[i] = .object(order)
                }
                if !unlinked.isEmpty { root["printLog"] = .array(log) }

                // And out of any quote bundle that listed it.
                var settings = Self.settings(root)
                if case .array(var list)? = settings["bundles"] {
                    var touched = false
                    for i in list.indices {
                        guard case .object(var bundle) = list[i],
                              case .array(let ids)? = bundle["productIds"] else { continue }
                        let kept = ids.filter { $0 != .string(id) }
                        guard kept.count != ids.count else { continue }
                        bundle["productIds"] = .array(kept)
                        if case .string(let bundleId)? = bundle["id"] { bundles.append(bundleId) }
                        list[i] = .object(bundle)
                        touched = true
                    }
                    if touched {
                        settings["bundles"] = .array(list)
                        root["settings"] = .object(settings)
                    }
                }
            }
            guard let removed else {
                productProblem = words.callIt("mac.move_gone"); return
            }
            // The bytes go LAST, and only once the record is gone: a picture
            // deleted beside a record that survived is a broken thumbnail on
            // every screen that draws the catalogue.
            for name in pictureNames where !name.isEmpty {
                ProductPhotos.delete(name, in: build)
            }
            registerProductUndo(removed, unlinked: unlinked, bundles: bundles, pictures: pictureNames)
            await load(source)
            productNote = words.callIt("pe.deleted")
        } catch {
            productProblem = String(describing: error)
        }
    }

    /// Put a deleted product back, with the jobs and bundles that named it.
    ///
    /// The pictures do NOT come back: their bytes were deleted, and an undo
    /// that silently restored a record naming files that are gone would put a
    /// broken thumbnail on the catalogue. The record is restored without them,
    /// which is honest and which the shop can see.
    private func registerProductUndo(_ record: [String: JSONValue], unlinked: [String],
                                     bundles: [String], pictures: [String]) {
        guard let undoManager, let build = source.build,
              case .string(let id)? = record["id"] else { return }
        var restored = record
        if !pictures.isEmpty {
            for key in ["images", "imagePath", "thumbnail"] { restored.removeValue(forKey: key) }
        }
        undoManager.setActionName(words.callIt("pe.deleted"))
        undoManager.registerUndo(withTarget: self) { shop in
            do {
                try StoreWriter.update(build) { root in
                    var rows = Self.rows(root, "products")
                    guard !rows.contains(where: { Self.recordId($0) == id }) else { return }
                    rows.append(.object(restored))
                    root["products"] = .array(rows)

                    var log = Self.rows(root, "printLog")
                    var touchedLog = false
                    for i in log.indices {
                        guard case .object(var order) = log[i],
                              case .string(let orderId)? = order["id"], unlinked.contains(orderId) else { continue }
                        order["productId"] = .string(id)
                        StoreWriter.stamp(&order)
                        log[i] = .object(order)
                        touchedLog = true
                    }
                    if touchedLog { root["printLog"] = .array(log) }

                    var settings = Self.settings(root)
                    if case .array(var list)? = settings["bundles"], !bundles.isEmpty {
                        for i in list.indices {
                            guard case .object(var bundle) = list[i],
                                  case .string(let bundleId)? = bundle["id"], bundles.contains(bundleId) else { continue }
                            var ids: [JSONValue] = []
                            if case .array(let had)? = bundle["productIds"] { ids = had }
                            guard !ids.contains(.string(id)) else { continue }
                            ids.append(.string(id))
                            bundle["productIds"] = .array(ids)
                            list[i] = .object(bundle)
                        }
                        settings["bundles"] = .array(list)
                        root["settings"] = .object(settings)
                    }
                }
                Task { await shop.deleteProduct(id) }   // redo
                Task { await shop.load(shop.source) }
            } catch {
                shop.productProblem = String(describing: error)
            }
        }
    }

    /// Put a deleted spool back, and make THAT undoable.
    ///
    /// `registerMoveUndo` restores fields onto records that are still there; a
    /// deleted spool is not, so it needs its own path.
    private func registerSpoolUndo(_ record: [String: JSONValue]) {
        guard let undoManager, let build = source.build,
              case .string(let id)? = record["id"] else { return }
        undoManager.setActionName(words.callIt("inv.removed"))
        undoManager.registerUndo(withTarget: self) { shop in
            do {
                try StoreWriter.update(build) { root in
                    var shelf = Self.rows(root, "inventory")
                    guard !shelf.contains(where: { Self.recordId($0) == id }) else { return }
                    shelf.append(.object(record))
                    root["inventory"] = .array(shelf)
                }
                Task { await shop.deleteSpool(id) }
            } catch {
                shop.spendProblem = String(describing: error)
            }
        }
    }

    // MARK: - The machines

    /// The machine being written down, or corrected.
    var editingMachine: Machine?
    var addingMachine = false

    /// Writing down what was spent, and what was thrown away.
    ///
    /// On the book rather than in the screen because the new shell's strip
    /// carries the "+" and the strip is not inside the screen — see
    /// `ScreenActions`. The sheets stay where they were.
    var addingExpense = false
    var loggingWaste = false
    /// The printers Khayt knows, read once per launch — the catalogue is a
    /// constant, not something a book carries.
    private(set) var catalog: [CatalogPrinter] = []

    /// The nozzle fitments, from the wear data rather than from a list here.
    private(set) var nozzleMaterials: [NozzleMaterial] = []

    func readCatalog() async {
        guard let engine else { return }
        if catalog.isEmpty { catalog = (try? await engine.printerCatalog()) ?? [] }
        if nozzleMaterials.isEmpty { nozzleMaterials = (try? await engine.nozzleMaterials()) ?? [] }
    }

    /// Put a machine on the floor, or correct one.
    ///
    /// `catalogId` applies a printer model FIRST, the way Khayt's picker does
    /// on the change — the bed, the colours, the power and what the nozzle is
    /// made of, arriving together rather than as eight fields to type.
    func saveMachine(_ input: [String: JSONValue], id: Machine.ID?, catalogId: String?) async {
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            spendProblem = words.callIt("mac.move_no_engine"); return
        }
        var undo: [ChangedRecord] = []
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var floor = Self.rows(root, "machines")
                let settings = Self.settings(root)
                var record: JSONValue
                var at: Int?
                if let id {
                    guard let found = floor.firstIndex(where: { Self.recordId($0) == id }),
                          case .object(let was) = floor[found] else {
                        throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                    }
                    undo.append(ChangedRecord(collection: "machines", id: id, was: was))
                    record = floor[found]
                    at = found
                } else {
                    let made = try await engine.newMachine(input, id: Self.uid("MACH"), count: floor.count)
                    guard let fresh = made.machine else {
                        throw MoveRefused(sentence: self.words.callIt("mach.need_name"))
                    }
                    record = fresh
                }
                if let catalogId, !catalogId.isEmpty {
                    record = try await engine.applyPrinterModel(record, catalogId: catalogId,
                                                                settings: settings).machine ?? record
                }
                let edited = try await engine.editMachine(record, input: input, settings: settings)
                if edited.refused != nil {
                    throw MoveRefused(sentence: self.words.callIt("mach.need_name"))
                }
                guard case .object(var fields)? = edited.machine else { return }
                if let at {
                    StoreWriter.stamp(&fields)
                    floor[at] = .object(fields)
                } else {
                    floor.append(.object(fields))
                }
                root["machines"] = .array(floor)
            }
            if !undo.isEmpty { registerMoveUndo(undo, named: words.callIt("mach.edit")) }
            editingMachine = nil
            addingMachine = false
            await load(source)
            spendNote = words.callIt("mach.saved")
        } catch let refusal as MoveRefused {
            spendProblem = refusal.sentence
        } catch {
            spendProblem = String(describing: error)
        }
    }

    // MARK: - The shop's own settings

    /// What stopped the last settings save, and what it did.
    var settingsProblem: String?
    var settingsNote: String?
    /// Which pane the Settings window shows. On the shop so a snapshot run can
    /// turn the pages.
    var settingsPane: SettingsPane = .business
    /// Which half of the Reports screen is showing.
    var reportPage: ReportPage = .profit
    /// The P&L by quarter (the table's word for it) or by month. A view
    /// preference, not the book's.
    var pnlByMonth = false

    /// The tables a Settings window is built from, read once per load.
    private(set) var currencies: [String: Currency] = [:]
    private(set) var taxPresets: [String: TaxProfile] = [:]
    private(set) var taxProfile: TaxProfile?
    private(set) var contentLanguages: [String] = ["en", "ar"]

    private func readSettingsTables(_ root: [String: JSONValue]) async {
        guard let engine else { return }
        let settings = Self.settings(root)
        currencies = (try? await engine.currencies()) ?? [:]
        taxPresets = (try? await engine.taxPresets()) ?? [:]
        taxProfile = try? await engine.taxProfile(settings: settings)
        contentLanguages = (try? await engine.contentLanguages(settings: settings)) ?? ["en", "ar"]
    }

    /// What the shared product-pricing rule is handed on a save: the parts,
    /// the margin, the components — AND the shop's rounding and typed price,
    /// which `lib/product-price.js` reads off the same record. Without those
    /// two a product rounded up to 5 saved here as its unrounded base, and a
    /// typed price was replaced by cost plus margin. Pulled out so a test can
    /// hold it to the record without a store.
    static func pricingInput(for product: Product, parts: [JSONValue]) -> [String: JSONValue] {
        var forPricing: [String: JSONValue] = ["parts": .array(parts)]
        if let margin = product.margin { forPricing["defaultMargin"] = .number(margin) }
        if let components = product.rest["components"] { forPricing["components"] = components }
        for key in ["priceRound", "priceOverride"] {
            if let value = product.rest[key] { forPricing[key] = value }
        }
        return forPricing
    }

    /// Save what one Settings pane showed.
    ///
    /// `form` carries only that pane's keys, and `lib/settings-edit.js` keeps
    /// every other setting as it finds it — the Business pane saving a phone
    /// number must not zero the WIP limits it never displayed. A country chosen
    /// for tax rules is applied first, the way Khayt's picker applies it on the
    /// change, so name, registration label, convention and rate arrive together.
    ///
    /// The whole record is re-read from disk inside the write and the window
    /// reloads from the file afterwards: what the screen shows is what was
    /// written, not what was hoped.
    func saveSettings(_ form: [String: JSONValue], country: String? = nil) async {
        settingsProblem = nil
        settingsNote = nil
        guard let build = source.build else {
            settingsProblem = words.callIt("mac.settings_sample"); return
        }
        guard let engine else {
            settingsProblem = words.callIt("mac.move_no_engine"); return
        }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                try await Self.applySettings(to: &root, form: form, country: country, engine: engine)
            }
            await load(source)
            settingsNote = words.callIt("mac.settings_saved")
        } catch {
            settingsProblem = String(describing: error)
        }
    }

    /// The settings write, on a book already read: the seam the tests use.
    static func applySettings(to root: inout [String: JSONValue], form: [String: JSONValue],
                              country: String?, engine: KhaytEngine) async throws {
        var settings = Self.settings(root)
        if let country, country != Self.taxCountry(settings) {
            settings = try await engine.chooseTaxCountry(settings, code: country)
        }
        settings = try await engine.applySettings(
            settings, form: form, year: Calendar.current.component(.year, from: Date()))
        root["settings"] = .object(settings)
    }

    // MARK: - Photographs of finished work

    /// One photograph on one job.
    ///
    /// Flattened out of `printLog[].printPhotos[]`, which is where Khayt keeps
    /// them: a thumbnail inline in the record as a data URI, and the full-size
    /// file by name in `order-photos/` beside the store.
    struct Snapshot: Identifiable, Hashable, Sendable {
        let orderId: String
        let project: String
        let date: String
        let index: Int
        let thumb: String?
        let filename: String?
        var id: String { "\(orderId)#\(index)" }

        /// Where the full-size photo is, when it is on this Mac at all.
        var file: URL?
    }

    private(set) var snapshots: [Snapshot] = []

    /// The folder Khayt writes order photos into: `order-photos/`, beside the
    /// store, which is `userData` in Electron's terms.
    var photoFolder: URL? {
        source.build.map { $0.storeURL.deletingLastPathComponent().appending(path: "order-photos") }
    }

    /// The seam the portfolio's tests use: the flattening on a book in memory,
    /// without a file, a lock or an engine.
    func readSnapshotsForTests(_ root: [String: JSONValue]) { readSnapshots(root) }

    private func readSnapshots(_ root: [String: JSONValue]) {
        guard case .array(let jobs)? = root["printLog"] else { snapshots = []; return }
        let folder = photoFolder
        var out: [Snapshot] = []
        for job in jobs {
            guard case .object(let record) = job,
                  case .array(let photos)? = record["printPhotos"] else { continue }
            let id = Self.plainString(record["id"]) ?? ""
            let project = Self.plainString(record["project"]) ?? ""
            let date = Self.plainString(record["date"]) ?? ""
            for (i, photo) in photos.enumerated() {
                guard case .object(let p) = photo else { continue }
                let name = Self.plainString(p["filename"])
                out.append(Snapshot(
                    orderId: id, project: project, date: date, index: i,
                    thumb: Self.plainString(p["thumb"]),
                    filename: name,
                    // Only when it is actually there. A record whose file was
                    // never copied to this Mac still shows in the grid — the
                    // thumbnail is in the book — and simply cannot be opened.
                    file: name.flatMap { n in
                        folder.map { $0.appending(path: n) }
                            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                    }))
            }
        }
        snapshots = out
    }

    func openPhoto(_ snap: Snapshot) { if let file = snap.file { FileActions.open(file) } }
    func revealPhoto(_ snap: Snapshot) { if let file = snap.file { FileActions.reveal(file) } }
    func revealPhotoFolder() { if let folder = photoFolder { FileActions.reveal(folder) } }

    /// The job a photo is being added to, or nil.
    var photographing: Order?

    /// Whether a photo can be added to this job at all.
    ///
    /// A finished job only. A photograph of the finished print is a record of
    /// what came off the bed, and one attached to a quote is a picture of
    /// something that has not been made.
    func canPhotograph(_ job: Order) -> Bool {
        canWrite && ["completed", "delivered"].contains(job.status)
    }

    /// Add a photograph of the finished print to a job.
    ///
    /// ── THE RECORD IS THE OTHER APP'S, EXACTLY ────────────────────────────
    ///
    /// Portfolio has always read `printLog[].printPhotos[]` and nothing here
    /// could write one, so the screen told a shop to add a photo to a completed
    /// order and offered no way to do it. Both apps read these back, so the
    /// sizes, the folder and the filename are `hub:save-order-photo`'s — see
    /// `OrderPhoto`.
    ///
    /// The file is written BEFORE the record, and the record only if the file
    /// was written: a row naming a file that is not there draws an empty cell
    /// with no way to fix it, whereas a file with no row is invisible and
    /// harmless.
    func addPhoto(to job: Order, from data: Data) async {
        guard let build = source.build, canPhotograph(job) else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        guard data.count <= OrderPhoto.maxBytes else {
            writeProblem = words.callIt("pe.image_too_big"); return
        }
        guard let made = OrderPhoto.encode(data) else {
            writeProblem = words.callIt("pe.upload_failed"); return
        }
        guard let folder = photoFolder else { return }

        // The index the other app uses is the position in the job's own list,
        // so it is read from the record rather than counted from the screen.
        let index = orderRow(job.id).flatMap { row -> Int? in
            guard case .object(let o) = row, case .array(let had)? = o["printPhotos"]
            else { return 0 }
            return had.count
        } ?? 0
        let name = OrderPhoto.filename(orderId: job.id, index: index)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try made.full.write(to: folder.appending(path: name))
        } catch {
            writeProblem = String(describing: error); return
        }

        do {
            try StoreWriter.update(build) { root in
                guard case .array(var jobs)? = root["printLog"] else { return }
                for i in jobs.indices {
                    guard case .object(var record) = jobs[i],
                          Self.recordId(jobs[i]) == job.id else { continue }
                    var photos: [JSONValue] = []
                    if case .array(let had)? = record["printPhotos"] { photos = had }
                    photos.append(OrderPhoto.record(thumb: made.thumb, filename: name))
                    record["printPhotos"] = .array(photos)
                    // Without the stamp the other machine's older copy wins the
                    // next merge and the photograph disappears again.
                    StoreWriter.stamp(&record)
                    jobs[i] = .object(record)
                }
                root["printLog"] = .array(jobs)
            }
            writeProblem = nil
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// Who else has this book open, in the shop's own language.
    ///
    /// `StoreLock` hands back the application's name and — only when it is
    /// somewhere else — the machine. Everything a person reads is added here,
    /// because that file is nonisolated and has no catalogue to ask.
    private func whoElseHasIt(_ build: StoreReader.Build) -> String? {
        guard let held = StoreLock.held(StoreLock.verdict(for: build)) else { return nil }
        let who = held.app ?? words.callIt("mac.lock_another")
        guard let host = held.host else {
            return words.callIt("mac.lock_held", ["who": .string(who)])
        }
        return words.callIt("mac.lock_held_on", ["who": .string(who), "where": .string(host)])
    }

    /// The shop's name, as its documents print it: `biz` in the language asked
    /// for by the shared fallback, or nil when nothing is filled in.
    static func shopName(from settings: [String: JSONValue], engine: KhaytEngine?,
                         language: String) async -> String? {
        if let engine, let name = try? await engine.shopText("biz", settings: settings, language: language),
           !name.isEmpty { return name }
        // No engine: the two keys every existing record uses, by hand.
        for key in ["bizEn", "bizAr"] {
            if let v = plainString(settings[key]), !v.isEmpty { return v }
        }
        return nil
    }

    /// The pricing convention, read the way `profileFromSettings` reads it: the
    /// profile's when there is one, inclusive otherwise — the only thing Khayt
    /// ever did before there was a profile.
    static func taxMode(_ settings: [String: JSONValue]) -> String {
        if case .object(let tax)? = settings["tax"], let mode = plainString(tax["mode"]),
           mode == "exclusive" || mode == "inclusive" { return mode }
        return "inclusive"
    }

    /// The country the tax rules were chosen for, or "" for a hand-made profile.
    static func taxCountry(_ settings: [String: JSONValue]) -> String {
        guard case .object(let tax)? = settings["tax"] else { return "" }
        return plainString(tax["country"]) ?? ""
    }

    static func plainNumber(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let n)?: return n
        case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func plainBool(_ value: JSONValue?) -> Bool? {
        if case .bool(let b)? = value { return b }
        return nil
    }

    private var shopCurrency: String {
        if case .string(let c)? = settingsDict["currency"], !c.isEmpty { return c }
        return "SAR"
    }

    /// The shop's own currency, from a settings dictionary rather than the
    /// loaded book — `applyMove` runs against the record it read from disk.
    static func shopCurrencyOf(_ settings: [String: JSONValue]) -> String {
        if case .string(let c)? = settings["currency"], !c.isEmpty { return c }
        return "SAR"
    }

    static func settings(_ root: [String: JSONValue]) -> [String: JSONValue] {
        if case .object(let s)? = root["settings"] { return s }
        return [:]
    }

    /// The question this move has to ask before it can happen, if any.
    ///
    /// Two moves are not just a change of column. Putting a job on hold starts a
    /// clock somebody will want explained; finishing a job that was IN QC is an
    /// inspection, and the record of it is what the shop's pass rate is computed
    /// from. Every other move is a move.
    func questionFor(_ id: Order.ID, moving to: Stage) -> (() -> Void)? {
        guard let job = orders.first(where: { $0.id == id }) else { return nil }
        let subject = PendingHold(id: id, project: job.project)
        if to == .on_hold { return { self.pendingHold = subject } }
        // EVERY completion asks what it took, not only one out of inspection.
        // `order-status.gate` sets `needsActuals` for this move and no other,
        // and nothing in this app read it — so a job finished here recorded
        // what it was quoted at and never what it cost.
        //
        // A job leaving QC is asked once, in this sheet, rather than being
        // handed a second dialog for its notes.
        if to == .completed {
            let finishing = PendingCompletion(
                id: id, project: job.project,
                estHours: job.printTime, estGrams: Self.quotedGrams(job),
                leavingQC: Stage.of(job) == .qc)
            return {
                self.pendingCompletion = finishing
                // The sheet opens NOW, with the estimate in the boxes, and the
                // printer's answer replaces it when it arrives. A sheet that
                // waited for a JavaScriptCore round trip would be a click that
                // does nothing for a moment, which reads as a click that missed.
                Task { await self.askWhatThePrinterSaid(for: id) }
            }
        }
        // A job leaving inspection for anywhere else FAILED it. Sending it back
        // without recording that is how a shop's scrap costs go unrecorded and
        // its pass rate is computed over the jobs that happened to pass.
        if Stage.of(job) == .qc { return { self.pendingQcFail = subject } }
        return nil
    }

    /// The job whose invoice is on screen.
    ///
    /// Not a question the way the others are — nothing waits on the answer and
    /// nothing is written — but it is a sheet over the same window, and it is
    /// dismissed by the same call, so it lives with them.
    var pendingInvoice: PendingHold?

    /// Show a job's invoice.
    func showInvoice(_ id: Order.ID) {
        guard let job = orders.first(where: { $0.id == id }) else { return }
        pendingInvoice = PendingHold(id: id, project: job.project)
    }

    /// The label sheet waiting to be looked at, as finished HTML.
    ///
    /// Built once when the shop asks rather than per redraw: a QR code per
    /// spool is real work — CoreImage rasterises each one — and a shelf of
    /// forty would redo it on every frame of the sheet's animation.
    var pendingLabels: LabelSheetRequest?

    /// Build a printable sheet of shelf labels, for the spools given or for the
    /// whole shelf when none are.
    ///
    /// The HTML comes from `lib/labels.js` — the same builder the Electron app
    /// prints from, so a rack labelled half from one app and half from the
    /// other is one rack — and the QR images come from CoreImage. Nothing is
    /// printed here: the sheet is shown first, because a shop should see forty
    /// labels before it spends forty labels' worth of paper.
    func askForShelfLabels(_ ids: [String] = []) async {
        let chosen = ids.isEmpty ? spools : spools.filter { ids.contains($0.id) }
        guard !chosen.isEmpty, let engine else { return }
        let entries = chosen.map { ShelfLabels.entry(for: $0, shop: self) }
        let heading = words.callIt("mac.shelf_labels")
        guard let html = try? await engine.labelSheet(entries, heading: heading) else { return }
        pendingLabels = LabelSheetRequest(html: html, count: chosen.count)
    }

    func clearQuestion() {
        pendingHold = nil
        pendingQC = nil
        pendingCompletion = nil
        pendingPayment = nil
        pendingEdit = nil
        pendingQcFail = nil
        pendingInvoice = nil
        pendingLabels = nil
    }

    /// Whether a job may be moved at all: a real book, held by this app, with
    /// the shared rules running. The sample shop is for looking at.
    var canMoveJobs: Bool { source.isReal && ownership != nil }


    // ── WHICH COLUMNS WOULD TAKE THE CARD IN THE AIR ──────────────────────────
    //
    // Answered when a card is picked UP, not when it is dropped. Every column
    // lit up identically while a job was dragged over it, and a move the rules
    // refuse was refused after the drop, as an error — so a shop learnt where a
    // job could go by trying, and the board it was reading gave it no help.
    // `KhaytOrderStatus.gate` has always been able to answer this, and
    // `KhaytEngine.statusGate` was written for exactly this use and documented
    // as "what greys out a drop target before anything is dragged onto it".
    // Nothing called it.

    /// The job being dragged, or nil.
    var draggingJob: Order.ID?
    /// What each column said about that job, keyed by status.
    ///
    /// EMPTY IS NOT "EVERY COLUMN REFUSES". It is "the answer has not arrived",
    /// which is true for the first moments of every drag, and a board that
    /// greys out all seven columns while it thinks is a board that looks broken.
    private(set) var dragGates: [String: StatusGate] = [:]

    /// The raw rows the last load read. Named for the KPIs because that is what
    /// first needed them; every engine call that takes the whole book wants the
    /// same two, and re-reading the store to answer a drag would be a disk read
    /// for a hover.
    private var bookOrders: [JSONValue] { kpiOrders }
    private var bookSettings: [String: JSONValue] { kpiSettings }

    /// A card has been picked up: ask every column at once.
    func beganDragging(_ id: Order.ID) {
        draggingJob = id
        dragGates = [:]
        watchForDragEnd()
        guard canMoveJobs, let engine else { return }
        guard let order = bookOrders.first(where: { Self.recordId($0) == id }) else { return }
        let statuses = Stage.boardColumns.map(\.rawValue)
        let book = bookOrders
        let settings = bookSettings
        Task { [weak self] in
            let gates = try? await engine.statusGates(order: order, to: statuses,
                                                      orders: book, settings: settings)
            // The card may have been dropped, or another picked up, while this
            // was crossing into the engine. Answers about a job nobody is
            // holding would dim the columns for the next drag.
            guard let self, self.draggingJob == id else { return }
            self.dragGates = gates ?? [:]
        }
    }


    /// The card has landed, or the drag was abandoned.
    func stoppedDragging() {
        draggingJob = nil
        dragGates = [:]
        releaseWatchers.forEach { NSEvent.removeMonitor($0) }
        releaseWatchers = []
    }

    /// The mouse-up that ends a drag, wherever it happens.
    ///
    /// A DRAG THAT IS ABANDONED TELLS NOBODY. `dropDestination` fires when a
    /// card lands on a column; a card released over the sidebar, over another
    /// application, or back where it started produces no callback at all — and
    /// the board would sit there with four columns greyed out and outlined in
    /// red, about a job nobody is holding, until the next drag or the next
    /// reload. A state that can only be cleared by the happy path is a state
    /// that gets stuck.
    ///
    /// Both monitors, because either alone has a hole: the local one never sees
    /// a release outside this app, and the global one never sees one inside it.
    ///
    /// AND NOT `isTargeted`, which is the obvious-looking hook and is wrong: it
    /// goes false every time the pointer crosses from one column to the next,
    /// so clearing on it would end the drag halfway across the board — the
    /// feature would work only for the first column tried.
    /// Removed in `stoppedDragging`, always — see the menu-bar timer in
    /// `MenuBar.swift` for what an unremoved AppKit monitor costs.
    private func watchForDragEnd() {
        releaseWatchers.forEach { NSEvent.removeMonitor($0) }
        releaseWatchers = []
        let ended: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.stoppedDragging() }
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            ended(); return event
        } { releaseWatchers.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { _ in
            ended()
        }) { releaseWatchers.append(global) }
    }

    private var releaseWatchers: [Any] = []


    /// Why this column would refuse the card in the air — nil if it would take
    /// it, nil while the answer has not arrived, and nil when nothing is being
    /// dragged.
    ///
    /// The column the card is ALREADY IN is not a refusal. Dropping a card back
    /// where it started is not a move and the board must not draw it as barred.
    func dragRefusal(_ stage: Stage) -> String? {
        guard let id = draggingJob else { return nil }
        // Shipped takes the card by stamping a date rather than by moving the
        // status, so the rules refuse it as a DESTINATION and the column would
        // otherwise paint itself barred while a card it will happily take is in
        // the air. What it actually refuses — a job that is not finished — is
        // `markShipped`'s answer, given when the card lands.
        if stage == .shipped { return nil }
        guard let gate = dragGates[stage.rawValue] else { return nil }
        if orders.first(where: { $0.id == id }).flatMap(Stage.of) == stage { return nil }
        return gate.ok ? nil : words.gateRefusal(gate)
    }

    /// What stopped a move, when something did. Cleared by the next attempt.
    var moveProblem: String?
    /// What the last move had to say — the due date it pushed out, the spools
    /// it emptied, the ones that are now low.
    var moveNotices: [String] = []

    /// Move a job to a stage, and take what it costs off the shelf.
    ///
    /// Three collections change together and are written in one swap: the job,
    /// the spools its filament came off, and the consumables it spent. A book
    /// where the job says "completed" and the spools still hold its filament
    /// has told the shop it has stock it has already used.
    ///
    /// Read `Kanban` for what a person sees; this is what happens.
    /// What a finished job really took, as the shop typed it.
    ///
    /// `source` is `manual` and nothing else, and that is not a placeholder to
    /// fill in later — these figures came off a keyboard. A margin report that
    /// cannot tell a measurement from a shop's best guess is the whole reason
    /// the field exists, and `Quoting` refuses typed figures outright: a typed
    /// actual is usually the estimate confirmed, so counting it would compare
    /// an estimate to itself.
    ///
    /// Measured figures need the printer's own completion, which means
    /// `PrinterWatch` remembering the job that just ended. It does not yet.
    struct Actuals: Equatable {
        var hours: Double
        var grams: Double
        /// Which instrument read each axis, or `manual` where the shop typed
        /// it. Per-axis because a printer can report one and not the other:
        /// PrusaLink gives a duration and no filament, so calling that record
        /// "measured" would put a fabricated variance into every report.
        ///
        /// A figure the shop CHANGED is manual whatever the printer said —
        /// correcting a measurement makes it a correction, and the record
        /// claiming otherwise is how a wrong number gets trusted twice.
        var timeSource: String = "manual"
        var weightSource: String = "manual"
    }

    func moveJob(_ id: Order.ID, to stage: Stage,
                 holdReason: String? = nil, qcNotes: String? = nil,
                 actuals: Actuals? = nil) async {
        moveProblem = nil
        moveNotices = []
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample")
            return
        }
        guard let engine else {
            moveProblem = words.callIt("mac.move_no_engine")
            return
        }

        var undoSnapshot: [ChangedRecord] = []
        var said: [String] = []
        var telegram: TelegramMessage?
        var owed: [KhaytEngine.WebhookDelivery] = []
        var mail: OrderEmail?
        var portal: PortalRefresh?
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let out = try await Self.applyMove(
                    to: &root, id: id, stage: stage, engine: engine, words: self.words,
                    holdReason: holdReason, qcNotes: qcNotes, actuals: actuals)
                undoSnapshot = out.undo; said = out.notices
                telegram = out.telegram; owed = out.webhooks
                mail = out.email; portal = out.portal
            }
            // Only once the swap has happened. The last ownership check is after
            // the mutation, so a book that changed hands mid-move throws here —
            // and a shop told which spools were emptied by a move that was
            // refused would be worse than being told nothing.
            moveNotices = said
            registerMoveUndo(undoSnapshot, named: words.callIt("mac.move_action"))
            await load(source)
            // AFTER the write, and only if it succeeded. A message about a job
            // that was not saved is worse than no message. A send that fails is
            // said out loud rather than swallowed: the whole point of the app
            // refusing these moves before was that a piece of the move would
            // silently not happen.
            if let telegram { await tell(telegram) }
            if let mail { await post(mail) }
            if let portal { await refresh(portal) }
            if !owed.isEmpty { await fire(owed) }
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch {
            moveProblem = String(describing: error)
        }
    }

    /// Deliver what the move owes, and say what did not arrive.
    ///
    /// Not fatal, for the same reason a failed Telegram message is not: the job
    /// IS moved and the book says so. Undoing a correct write because a
    /// consumer was down would be the wrong trade. The shop is TOLD, which is
    /// the whole point of the app having refused these moves before.
    private func fire(_ deliveries: [KhaytEngine.WebhookDelivery]) async {
        guard let engine else { return }
        var sent = 0
        for one in deliveries {
            // The HOST, not the whole URL: a webhook URL usually carries a
            // token in its path, and a sentence on screen is a sentence that
            // gets screenshotted into a support chat.
            let name = URL(string: one.url)?.host ?? one.url
            guard let url = URL(string: one.url) else {
                moveProblem = words.callIt("mac.webhook_failed", ["where": .string(name)])
                    + " " + words.callIt("mac.webhook_bad_url")
                continue
            }
            do {
                // SEALED SECRETS ARE OPENED AT THE POINT OF USE, the way the
                // Telegram token is. `settings.webhooks.secret` is a registered
                // path, and the legacy config carries it down into every
                // migrated subscription — so signing with the string as it sits
                // in the book would sign with the ciphertext and every delivery
                // would fail verification at the consumer.
                // `open` returns a value with no marker untouched, so this is
                // the same call whether the shop's secret is sealed or is from
                // a store written before sealing existed.
                let secret = try await Secrets.open(one.secret, for: source)
                let status = try await WebhookClient.deliver(
                    one.body, to: url, secret: secret, event: one.event, engine: engine)
                if (200..<300).contains(status) {
                    sent += 1
                } else {
                    moveProblem = words.callIt("mac.webhook_failed", ["where": .string(name)])
                        + " HTTP \(status)"
                }
            } catch {
                moveProblem = words.callIt("mac.webhook_failed", ["where": .string(name)])
                    + " " + ((error as? LocalizedError)?.errorDescription
                             ?? String(describing: error))
            }
        }
        if sent > 0 {
            moveNotices.append(words.callIt("mac.webhooks_sent", ["n": .number(Double(sent))]))
        }
    }

    /// Send what the shop's bot has to say, and say so if it could not.
    ///
    /// Not fatal: the job IS finished, the book says so, and undoing a correct
    /// write because a message did not go out would be the wrong trade. The
    /// shop is told, and can send it by hand.
    /// Send the customer the email this move owes them, and say so if it failed.
    ///
    /// Not fatal, for the reason `tell` is not: the job IS finished and the
    /// book says so. What is NOT acceptable is silence — the app refused these
    /// moves in the first place precisely so that no customer would go untold
    /// while a shop believed otherwise.
    /// Refresh the customer's tracking link, and say so if it did not go.
    ///
    /// Not fatal, for the reason the email and the message are not: the job IS
    /// finished and the book says so. But a stale page is the failure mode this
    /// whole refusal existed to prevent — a customer reading "Printing" about a
    /// job that was collected yesterday — so it is said out loud.
    private func refresh(_ portal: PortalRefresh) async {
        guard let engine else { return }
        do {
            var cloud: [String: JSONValue] = [:]
            if case .object(let c)? = settingsDict["cloud"] { cloud = c }
            // `settings.cloud.token` is a registered sealed path, so the string
            // in the book is ciphertext. Opened here, at the point of use, and
            // never held — the same rule as the bot token and the webhook
            // secret. Sent as the bearer, it would fail every request and read
            // to a shop as a cloud that had stopped accepting its account.
            let token = try await Secrets.open(Self.plainString(cloud["token"]) ?? "", for: source)
            try await PortalClient.republish(
                portal,
                baseUrl: Self.plainString(cloud["url"]) ?? "",
                shopId: Self.plainString(cloud["shopId"]) ?? "",
                token: token, engine: engine)
            moveNotices.append(words.callIt("mac.portal_refreshed"))
        } catch let failure as PortalClient.Failure {
            moveProblem = words.callIt("mac.portal_failed") + " "
                + (failure.errorDescription ?? String(describing: failure))
        } catch let locked as Secrets.Failure {
            moveProblem = words.callIt("mac.portal_failed") + " " + locked.description
        } catch {
            moveProblem = words.callIt("mac.portal_failed") + " " + String(describing: error)
        }
    }

    private func post(_ mail: OrderEmail) async {
        do {
            // OPENED AT THE POINT OF USE, like the bot token and the webhook
            // secret. `settings.emailConfig.apiKey` is a registered sealed
            // path, so the string in the book is ciphertext; handing it to a
            // provider would fail authentication on every send and read to the
            // shop as an expired key.
            var config: [String: JSONValue] = [:]
            if case .object(let c)? = settingsDict["emailConfig"] { config = c }
            let key = try await Secrets.open(Self.plainString(config["apiKey"]) ?? "", for: source)
            try await EmailClient.send(mail, apiKey: key, config: config)
            moveNotices.append(words.callIt("mac.email_sent"))
        } catch let failure as EmailClient.Failure {
            moveProblem = words.callIt("mac.email_failed") + " "
                + (failure.errorDescription ?? String(describing: failure))
        } catch let locked as Secrets.Failure {
            moveProblem = words.callIt("mac.email_failed") + " " + locked.description
        } catch {
            moveProblem = words.callIt("mac.email_failed") + " " + String(describing: error)
        }
    }

    private func tell(_ message: TelegramMessage) async {
        do {
            // THE TOKEN IS ENCRYPTED ON DISK, and the rule that this app never
            // decrypts belonged to the WRITE path. Handed the `__enc__` string
            // straight through, `isBotToken` refused it and every shop with
            // Telegram configured was told its message did not go out — every
            // time, since the day this shipped. Opened here, at the point of
            // use, and never held anywhere.
            let token = try await Secrets.open(message.botToken, for: source)
            try await Telegram.send(botToken: token, chatId: message.chatId,
                                    message: message.message)
            moveNotices.append(words.callIt("mac.telegram_sent"))
        } catch let failure as Telegram.Failure {
            moveProblem = words.callIt("mac.telegram_failed") + " " + Self.describe(failure)
        } catch let locked as Secrets.Failure {
            moveProblem = words.callIt("mac.telegram_failed") + " " + locked.description
        } catch {
            moveProblem = words.callIt("mac.telegram_failed") + " " + String(describing: error)
        }
    }

    static func describe(_ failure: Telegram.Failure) -> String {
        switch failure {
        case .badToken: return "The bot token in Settings is not a Telegram token."
        case .badChatId: return "The chat ID in Settings is not one Telegram can deliver to."
        case .refused(let status, let why): return why.isEmpty ? "HTTP \(status)" : why
        case .unreachable(let why): return why
        }
    }

    /// One record as it was before a move, and where it lives.
    ///
    /// A move changes three collections, so an undo has to put three
    /// collections back — including the spools. Undoing a completion that
    /// emptied a spool without returning the filament would be an undo that
    /// lies about the shelf.
    struct ChangedRecord: Sendable {
        let collection: String
        let id: String
        let was: [String: JSONValue]
    }

    /// A move the rules refused, said in the shop's own words.
    struct MoveRefused: Error { let sentence: String }

    /// The move itself, against the book as it is ON DISK.
    ///
    /// Static and taking `root` because it runs inside the write: everything it
    /// reads — the other jobs the WIP limit counts, the spools it draws from,
    /// the settings that decide whether it deducts at all — must be what is in
    /// the file, not what this app last drew on screen.
    /// Everything one move produced: what changed, what to say, and what it
    /// owes the world outside this book.
    ///
    /// A STRUCT rather than the tuple this was. `applyMove` returned six
    /// positional values, and every new outbound channel — email, then the
    /// portal — meant editing the signature plus four test helpers plus a
    /// `let (_, _, _, owed, _, _)` that nobody could read. Twice in one day.
    /// Names also make `out.portal` mean something at the call site, where
    /// `out.5` did not.
    ///
    /// The three outbound fields are nil or empty when the move owes nothing —
    /// which is the common case, a shop with no integrations configured.
    struct MoveOutcome {
        /// Enough to put the book back as it was.
        let undo: [ChangedRecord]
        /// Sentences for the person, already in their language.
        let notices: [String]
        let telegram: TelegramMessage?
        let webhooks: [KhaytEngine.WebhookDelivery]
        let email: OrderEmail?
        let portal: PortalRefresh?
    }

    /// The customer's name as the shop writes it, for a message about their job.
    ///
    /// One resolution, used by the webhook bodies and by the email, because a
    /// customer called one thing in a webhook and another in the email about
    /// the same move is the shop speaking with two voices. Empty when the job
    /// has no customer, or the customer has no name — the email greets the
    /// address in that case, which is what the other app does.
    static func emailClientName(for order: [String: JSONValue],
                                in clients: [JSONValue]) -> String {
        guard case .string(let clientId)? = order["clientId"] else { return "" }
        for row in clients where recordId(row) == clientId {
            if case .object(let c) = row {
                return plainString(c["nameEn"]) ?? plainString(c["nameAr"])
                    ?? plainString(c["name"]) ?? ""
            }
        }
        return ""
    }

    static func applyMove(to root: inout [String: JSONValue],
                                  id: Order.ID, stage: Stage,
                                  engine: KhaytEngine, words: Words,
                                  holdReason: String? = nil, qcNotes: String? = nil,
                                  actuals: Actuals? = nil)
    async throws -> MoveOutcome {

        var orders = rows(root, "printLog")
        let inventory = rows(root, "inventory")
        let consumables = rows(root, "consumables")
        let machines = rows(root, "machines")
        let clients = rows(root, "clients")
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }

        guard var target = orders.first(where: { recordId($0) == id }) else {
            throw MoveRefused(sentence: words.callIt("mac.move_gone"))
        }

        // ── WHAT IT REALLY TOOK, WRITTEN BEFORE THE MOVE IS MADE ──────────
        //
        // Onto the order first, then the move — which is the order Electron
        // uses. The move hands this record to the engine and stores what comes
        // back, so actuals written afterwards would be written onto a copy the
        // book has already replaced.
        //
        // AND NOT BECAUSE THE DEDUCTION READS THEM. It does not, in either
        // app: `deductForOrder` takes an `actualGrams` — "what the PRINTER says
        // the job used" — and nobody passes it, `renderer/inventory.js`'s
        // `deductionContext()` included. So a job that used 260 g against a
        // 160 g quote still takes 160 g off the shelf. That is a gap in the
        // shared rule rather than in this app, and closing it here alone would
        // make the two disagree about a shop's shelf, so it is left alone and
        // pinned by `MoveJobTests.theShelfStillFollowsTheEstimate`.
        //
        // Both figures and their provenance travel together. A record with
        // actuals and no `actualsSource` reads as measured to anything that
        // checks the source only when it is present.
        if let actuals, case .object(var fields) = target {
            fields["actualPrintTime"] = .number((actuals.hours * 100).rounded() / 100)
            fields["actualWeight"] = .number((actuals.grams * 10).rounded() / 10)
            fields["actualsSource"] = .object([
                "time": .string(actuals.timeSource),
                "weight": .string(actuals.weightSource),
                "at": .string(ISO8601DateFormatter().string(from: Date())),
            ])
            target = .object(fields)
            if let at = orders.firstIndex(where: { recordId($0) == id }) { orders[at] = target }
            root["printLog"] = .array(orders)
        }

        // Asked BEFORE anything is written. A webhook, an email or a portal
        // refresh cannot be sent from here and cannot be sent afterwards, so a
        // move that would trigger one is refused whole rather than made with a
        // piece missing.
        //
        // TELEGRAM IS THE EXCEPTION, because this app can now send it: the
        // message is the shared rule's and the sending is URLSession's. It is
        // sent AFTER the write succeeds — a message about a job that was not
        // saved is worse than no message — and a send that fails is reported
        // rather than swallowed, so a shop knows the customer was not told.
        let reaches = (try? await engine.outbound(order: target, to: stage.rawValue,
                                                  settings: settings, clients: clients)) ?? []
        // The channels this app can actually reach. Everything else is still
        // refused WHOLE rather than made with a piece missing — an email or a
        // portal refresh cannot be sent from here and cannot be sent
        // afterwards, so a half-made move would leave a customer told nothing
        // with no way to notice.
        //
        // EMAIL IS CONDITIONAL, and the condition is the provider rather than
        // the channel. SendGrid and Mailgun are one HTTPS POST each and this
        // app makes them; `custom` is SMTP, which it does not speak. So the
        // question is not "can I email" but "can I email THROUGH THIS", and
        // `via` is what the shared rule sends along to answer it. A shop on
        // SMTP is still refused, by name, and still has the other app.
        let canSend: Set<String> = ["telegram", "webhooks", "event_webhook"]
        // A loop rather than a `filter`, because asking the module whether a
        // provider can be carried is a call into the engine actor, and an
        // `await` cannot happen inside a synchronous closure.
        var cannotSend: [Outbound] = []
        for reach in reaches {
            if canSend.contains(reach.channel) { continue }
            if reach.channel == "email",
               (try? await engine.emailProviderIsHttp(reach.via ?? "")) == true { continue }
            // The customer's tracking link. `PortalClient` PUTs it, so a move
            // on a published job is no longer refused.
            if reach.channel == "portal" { continue }
            cannotSend.append(reach)
        }
        if !cannotSend.isEmpty {
            throw MoveRefused(sentence: words.outboundRefusal(cannotSend))
        }
        let telegram = reaches.contains { $0.channel == "telegram" }
            ? try? await engine.telegramMessage(order: target, newStatus: stage.rawValue,
                                                settings: settings, currency: shopCurrencyOf(settings))
            : nil

        let move = try await engine.moveJob(
            order: target, to: stage.rawValue, orders: orders, settings: settings,
            inventory: inventory, consumables: consumables, machines: machines,
            now: Date(), today: localDay(), holdReason: holdReason, qcNotes: qcNotes)

        guard move.ok else {
            throw MoveRefused(sentence: words.gateRefusal(move.gate))
        }
        // An effect nobody classified is a gap, and a gap in a status change is
        // how something goes missing on this Mac and nowhere else. Refuse.
        if let unhandled = move.unhandled, !unhandled.isEmpty {
            throw MoveRefused(sentence: words.callIt("mac.move_unhandled")
                              + " (" + unhandled.joined(separator: ", ") + ")")
        }
        guard var changedOrder = move.order.flatMap(asObject) else {
            throw MoveRefused(sentence: words.callIt("mac.move_gone"))
        }

        // A completion asks for a survey token, and a random source is exactly
        // what a pure module does not have. The FORMAT is shared, so the token
        // this app mints is the token Khayt would have minted.
        if move.performed?.contains("ensure_survey_token") == true, changedOrder["surveyToken"] == nil {
            changedOrder["surveyToken"] = .string(surveyToken())
        }

        // ── WHAT THE MOVE OWES OUTWARD, BUILT FROM THE MOVED JOB ──────────
        //
        // AFTER the move, because the body names the job's state and the whole
        // point of the message is that the state changed: built from the record
        // as it was before, every consumer would be told the job is still where
        // it was. The other app builds them here too, for the same reason.
        //
        // And HERE rather than after the write, because this runs inside the
        // write and the settings, the subscriptions and the customer's name are
        // the ones on disk. Sending is the caller's job; this only addresses.
        var owed: [KhaytEngine.WebhookDelivery] = []
        if let asked = move.webhookEffects, !asked.isEmpty {
            let clientName = emailClientName(for: changedOrder, in: clients)
            owed = (try? await engine.webhookDeliveries(
                order: .object(changedOrder), effects: asked, settings: settings,
                shopName: plainString(settings["bizEn"]) ?? plainString(settings["bizAr"]) ?? "Khayt",
                clientName: clientName, currency: shopCurrencyOf(settings),
                at: ISO8601DateFormatter().string(from: Date()),
                nowMs: Date().timeIntervalSince1970 * 1000)) ?? []
        }

        // ── AND WHAT IT OWES THE CUSTOMER ─────────────────────────────────
        //
        // Built from the moved job for the same reason as the webhooks, and
        // through the same module the other app builds it with, so a customer
        // whose shop has two machines is not written to twice in two voices.
        //
        // `outboundFor` has already refused the move if this could not be
        // carried, so reaching here means it can be. A nil is the ordinary
        // case: no provider, a status the shop does not announce, or no
        // address on file — none of which is an error and none of which is
        // worth a sentence.
        // ── AND WHAT IT OWES THE CUSTOMER'S LINK ──────────────────────────
        //
        // After the move, like everything else here: the page says what the job
        // is doing, and built from the record as it was the customer would be
        // shown the stage it has just left.
        let portal = try? await engine.portalRefresh(
            order: .object(changedOrder), settings: settings, clients: clients,
            shopName: plainString(settings["bizEn"]) ?? plainString(settings["bizAr"]) ?? "Khayt",
            shopAddress: plainString(settings["addrEn"]) ?? plainString(settings["addrAr"]) ?? "",
            stages: [
                words.callIt("track.received", fallback: "Received"),
                words.callIt("track.printing", fallback: "Printing"),
                words.callIt("track.finishing", fallback: "Finishing"),
                words.callIt("track.done", fallback: "Done"),
                words.callIt("track.ready", fallback: "Ready for pickup"),
            ],
            now: Date())

        let mail = try? await engine.orderEmail(
            order: .object(changedOrder), newStatus: stage.rawValue,
            settings: settings, clients: clients,
            shopName: plainString(settings["bizEn"]) ?? plainString(settings["bizAr"]) ?? "Khayt",
            clientName: emailClientName(for: changedOrder, in: clients),
            statusLabel: words.callIt("queue." + stage.rawValue, fallback: stage.rawValue))

        var undo: [ChangedRecord] = []
        write(&root, "printLog", changed: [.object(changedOrder)], before: orders, into: &undo)
        write(&root, "inventory", changed: move.inventory ?? [], before: inventory, into: &undo)
        write(&root, "consumables", changed: move.consumables ?? [], before: consumables, into: &undo)

        if let text = move.activity {
            appendActivity(&root, text: text, ref: id, settings: settings, root: root)
        }

        let notices = (move.notices ?? []).map { words.sentence(for: $0) }
        return MoveOutcome(undo: undo, notices: notices, telegram: telegram,
                           webhooks: owed, email: mail, portal: portal)
    }

    // MARK: - Reading and writing rows

    static func rows(_ root: [String: JSONValue], _ collection: String) -> [JSONValue] {
        if case .array(let r)? = root[collection] { return r }
        return []
    }

    static func asObject(_ value: JSONValue) -> [String: JSONValue]? {
        if case .object(let o) = value { return o }
        return nil
    }

    static func recordId(_ value: JSONValue) -> String? {
        guard case .object(let o) = value, case .string(let id)? = o["id"] else { return nil }
        return id
    }

    /// Put changed rows back, stamping only the ones that actually changed.
    ///
    /// Stamping a row that did not change would push it to the cloud as an edit
    /// nobody made, and on a shop with two machines that is how the older build
    /// gets to win with a stale copy.
    static func write(_ root: inout [String: JSONValue], _ collection: String,
                              changed: [JSONValue], before: [JSONValue],
                              into undo: inout [ChangedRecord]) {
        guard !changed.isEmpty else { return }
        var byId: [String: JSONValue] = [:]
        for row in changed { if let id = recordId(row) { byId[id] = row } }

        var out = before
        var touched = false
        for i in out.indices {
            guard let id = recordId(out[i]), let next = byId[id], next != out[i] else { continue }
            guard case .object(let was) = out[i], case .object(var now) = next else { continue }
            undo.append(ChangedRecord(collection: collection, id: id, was: was))
            StoreWriter.stamp(&now)
            out[i] = .object(now)
            touched = true
        }
        guard touched else { return }
        root[collection] = .array(out)
    }

    /// The team's activity log — the same collection, shape and cap Khayt uses.
    static func appendActivity(_ root: inout [String: JSONValue], text: String,
                                       ref: String, settings: [String: JSONValue],
                                       root snapshot: [String: JSONValue],
                                       action: String = "status") {
        var log = rows(snapshot, "auditLog")
        var operatorId: JSONValue = .null
        var operatorName = ""
        if case .string(let opId)? = settings["activeOperatorId"] {
            operatorId = .string(opId)
            if let op = rows(snapshot, "operators").first(where: { recordId($0) == opId }),
               case .object(let o) = op, case .string(let name)? = o["name"] {
                operatorName = name
            }
        }
        log.append(.object([
            "id": .string(uid("AL")),
            "at": .string(StoreWriter.iso(Date())),
            "action": .string(action),
            "detail": .string(text),
            "ref": .string(ref),
            "operatorId": operatorId,
            "operatorName": .string(operatorName),
        ]))
        // Khayt keeps two thousand and drops the oldest. A log that grew for
        // ever would be the one collection that could push a book past the size
        // every backup is built to hold.
        if log.count > 2000 { log = Array(log.suffix(2000)) }
        root["auditLog"] = .array(log)
    }

    /// `YYYY-MM-DD` in this Mac's own timezone, the way `localDateStr` in
    /// renderer/util.js writes it. A spool's usage history records the local
    /// DAY a job drew from it, not an instant, so UTC would put a Riyadh
    /// evening on the wrong date.
    static func localDay(_ date: Date = Date()) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `uid()` from renderer/util.js: prefix, base-36 milliseconds, three random
    /// base-36 characters upper-cased. Matched so an entry written here is
    /// indistinguishable from one Khayt wrote.
    static func uid(_ prefix: String) -> String {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let stamp = String(ms, radix: 36)
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let tail = String((0..<3).map { _ in alphabet.randomElement()! }).uppercased()
        return "\(prefix)-\(stamp)\(tail)"
    }

    /// `srv-` and twelve random bytes in hex, the format `lib/order-status.js`
    /// defines and both apps read.
    static func surveyToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return "srv-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Undo

    private func registerMoveUndo(_ before: [ChangedRecord], named actionName: String) {
        guard let undoManager, !before.isEmpty else { return }
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: self) { shop in
            shop.restoreMove(before, named: actionName)
        }
    }

    /// Put every collection back exactly as it was, and make THAT undoable.
    ///
    /// The deductions come back with it: undoing a completion that emptied a
    /// spool has to put the filament back, or the undo is a lie about the shelf.
    private func restoreMove(_ snapshot: [ChangedRecord], named actionName: String) {
        guard let build = source.build else { return }
        var before: [ChangedRecord] = []
        do {
            try StoreWriter.update(build) { root in
                for (collection, wanted) in Dictionary(grouping: snapshot, by: \.collection) {
                    guard case .array(var rows)? = root[collection] else { continue }
                    let byId = Dictionary(wanted.map { ($0.id, $0.was) }, uniquingKeysWith: { a, _ in a })
                    var touched = false
                    for i in rows.indices {
                        guard case .object(let current) = rows[i],
                              case .string(let id)? = current["id"],
                              let was = byId[id] else { continue }
                        before.append(ChangedRecord(collection: collection, id: id, was: current))
                        rows[i] = .object(StoreWriter.restoring(was, over: current))
                        touched = true
                    }
                    if touched { root[collection] = .array(rows) }
                }
            }
            moveProblem = nil
            registerMoveUndo(before, named: actionName)
            Task { await load(source) }
        } catch {
            moveProblem = String(describing: error)
        }
    }

    /// The shared shape of every edit: check we may write, do it, re-read.
    private func write(_ change: (inout [String: JSONValue]) -> Void) {
        guard let build = source.build else { return }
        do {
            try StoreWriter.update(build) { root in change(&root) }
            writeProblem = nil
            // Read the whole book back rather than patching what is on screen.
            // The screen must show what is on disk, not what this app believes
            // it just put there.
            Task { await load(source) }
        } catch {
            writeProblem = String(describing: error)
        }
    }

    // MARK: - The shop's saved messages

    /// Save a message template — a new one, or a correction to one it has.
    ///
    /// ── WHY THIS HAD TO EXIST ─────────────────────────────────────────────
    ///
    /// `MessageSheet` has always READ `waTemplates` and nothing on this Mac
    /// could write one. A shop whose book carries none opened the sheet to an
    /// empty picker and an empty box with nothing to explain it, and the only
    /// way to make a template was to open the other app. The templates are how
    /// a shop talks to its customers, so that is a gap, not a difference.
    ///
    /// Both fields are required, exactly as the other app requires them: a
    /// template with no name cannot be picked off a list, and one with no body
    /// sends nothing.
    func saveTemplate(id: String?, name: String, body: String) {
        writeProblem = nil
        // THE FIELDS BEFORE THE BOOK. What is wrong with the two strings is a
        // fact about the arguments, true whichever book is open, so the answer
        // does not depend on which one is. Nobody reaches these through the
        // sheet — Save is disabled until both are filled — but a caller that
        // does is told what it got wrong rather than where it would have gone.
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { writeProblem = words.callIt("wa.tpl_need_name"); return }
        guard !body.isEmpty else { writeProblem = words.callIt("wa.tpl_need_body"); return }
        guard source.build != nil else { writeProblem = words.callIt("mac.move_sample"); return }
        // `uid('WATPL')`, the other app's own shape, so a template made here
        // looks like one made there to anything that sorts or dedupes ids.
        let wanted = id ?? Self.uid("WATPL")
        write { root in
            var rows = Self.rows(root, MessageTemplate.collection)
            let row: JSONValue = .object(["id": .string(wanted), "name": .string(name),
                                          "body": .string(body)])
            if let at = rows.firstIndex(where: { Self.recordId($0) == wanted }) {
                // REPLACED IN PLACE, keeping its position. A corrected template
                // that jumps to the bottom of the list is one a shop has to
                // find again every time it fixes a typo.
                rows[at] = row
            } else {
                rows.append(row)
            }
            root[MessageTemplate.collection] = .array(rows)
        }
    }

    /// Take one off the list. An id nobody has is not an error.
    func deleteTemplate(_ id: String) {
        writeProblem = nil
        guard source.build != nil else { writeProblem = words.callIt("mac.move_sample"); return }
        write { root in
            let rows = Self.rows(root, MessageTemplate.collection)
                .filter { Self.recordId($0) != id }
            root[MessageTemplate.collection] = .array(rows)
        }
    }

    /// The template being edited, or a blank one being written. Nil when the
    /// editor is closed — the sheet is raised from `WindowSheets` so that both
    /// shells can raise it.
    var editingTemplate: MessageTemplate?

    // MARK: - The shop's own mark

    /// The logo as the book holds it, or empty.
    var bizLogo: String {
        guard case .object(let s) = settingsValue else { return "" }
        let stored = Shop.plainString(s["bizLogo"]) ?? ""
        // Read through the SAME test the document applies. A picture Settings
        // showed and the invoice refused would be the worst of both.
        return stored.hasPrefix("data:image/") ? stored : ""
    }

    /// Put a picture on the shop's documents.
    ///
    /// Written straight onto `settings.bizLogo` rather than through a form:
    /// `settings-edit.js` keeps `out.bizLogo = s.bizLogo || ''`, so it
    /// preserves what it finds and takes none from a form.
    func setLogo(from url: URL) {
        writeProblem = nil
        guard source.build != nil else { writeProblem = words.callIt("mac.move_sample"); return }
        let uri: String
        do { uri = try ShopLogo.dataURI(of: url) }
        catch let refused as ShopLogo.Refused {
            // The refusal's own sentence — too big, or not a picture — because
            // each of them tells the shop something different to do.
            writeProblem = words.callIt(refused.errorDescription ?? "")
            return
        } catch {
            writeProblem = String(describing: error)
            return
        }
        write { root in
            var settings = Self.settings(root)
            settings["bizLogo"] = .string(uri)
            root["settings"] = .object(settings)
        }
    }

    /// Take it off again, back to Khayt's own mark on the document.
    func clearLogo() {
        writeProblem = nil
        guard source.build != nil else { writeProblem = words.callIt("mac.move_sample"); return }
        write { root in
            var settings = Self.settings(root)
            // The EMPTY STRING, which is what `settings-edit` writes for an
            // absent one — not a removed key, which a merge could resurrect
            // from an older copy on another machine.
            settings["bizLogo"] = .string("")
            root["settings"] = .object(settings)
        }
    }

    /// Ask for a picture, then put it on the documents.
    func pickLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = words.callIt("set.logo")
        panel.prompt = words.callIt("set.logo_upload")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setLogo(from: url)
    }

    // MARK: - How much of the app the shop wants

    /// The two modes Khayt offers. `enthusiast` exists in the book and is NOT
    /// on this list on purpose: it is Bed Ready's only mode and was retired as
    /// a Khayt one, so a book carrying it is read as Simple and re-saving would
    /// pin it there rather than offering it back.
    static let modes = ["simple", "professional"]

    /// What the shop is on now, with `enthusiast` resolved the way every reader
    /// resolves it and an absent mode read as Professional — which is what a
    /// book written before modes existed means.
    var mode: String { Self.modeOf(settingsValue) }

    /// Static so it can be shown to agree with `KhaytEngine.featureEnabled`,
    /// which makes the same two decisions on the other side of the bridge. A
    /// picker that showed one mode while the shelves obeyed another would be
    /// the Simple-mode bug again, from the other end.
    static func modeOf(_ settings: JSONValue) -> String {
        guard case .object(let s) = settings, case .string(let m)? = s["mode"],
              !m.isEmpty else { return "professional" }
        return m == "enthusiast" ? "simple" : m
    }

    /// Switch between Simple and Professional.
    ///
    /// ── WHY THIS HAD TO EXIST ─────────────────────────────────────────────
    ///
    /// This app has HONOURED the mode since the shells were fixed — Simple
    /// hides Expenses and Reports — and had no way to set one. A shop that
    /// wanted its Mac simpler had to open the other app to say so, which is a
    /// gap rather than a difference.
    ///
    /// Written straight onto `settings.mode`, exactly as the other app's mode
    /// pills do it, and NOT through the settings form: `settings-edit.js` keeps
    /// `out.mode = s.mode || 'professional'` — it preserves what it finds and
    /// takes no mode from a form — so a pane saving through it could never
    /// change this.
    func chooseMode(_ wanted: String) async {
        writeProblem = nil
        guard Self.modes.contains(wanted) else {
            writeProblem = words.callIt("mac.mode_unknown"); return
        }
        guard source.build != nil else { writeProblem = words.callIt("mac.move_sample"); return }
        guard wanted != mode else { return }
        write { root in
            var settings = Self.settings(root)
            settings["mode"] = .string(wanted)
            root["settings"] = .object(settings)
        }
    }

    // MARK: - Stopping the floor

    /// Whether the shop has stopped starting new prints.
    ///
    /// ── WHY THIS HAD TO EXIST ─────────────────────────────────────────────
    ///
    /// `lib/order-status.js` REFUSES a move to printing while this is set, and
    /// this app already translates that refusal — "Production is paused —
    /// resume before starting new prints." So a shop that paused production in
    /// the other app arrived here to find every start refused, with no way to
    /// resume and nothing on screen saying production was paused at all. That
    /// is worse than a missing feature: it is a dead end that looks like a bug.
    var productionPaused: Bool {
        guard case .object(let s) = settingsValue else { return false }
        return Shop.plainBool(s["productionPaused"]) ?? false
    }

    /// Why, as the shop wrote it. Empty is allowed on purpose — a shop that
    /// just needs the floor stopped should not have to invent a reason.
    var pauseReason: String {
        guard case .object(let s) = settingsValue else { return "" }
        return Shop.plainString(s["pauseReason"]) ?? ""
    }

    /// When it was paused, as stored. Read for the banner, not for arithmetic.
    var pausedAt: String {
        guard case .object(let s) = settingsValue else { return "" }
        return Shop.plainString(s["pausedAt"]) ?? ""
    }

    /// The reason box, open. Nil when nobody is being asked.
    var pausingProduction = false

    func pauseProduction(reason: String) {
        writeProblem = nil
        guard source.build != nil else { writeProblem = words.callIt("mac.move_sample"); return }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        // All three fields, the other app's own shape — `productionPaused`,
        // `pauseReason`, `pausedAt`. A pause that set only the flag would leave
        // a stale reason from the last one on the banner.
        write { root in
            var settings = Self.settings(root)
            settings["productionPaused"] = .bool(true)
            settings["pauseReason"] = .string(reason)
            settings["pausedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
            root["settings"] = .object(settings)
        }
    }

    func resumeProduction() {
        writeProblem = nil
        guard source.build != nil else { writeProblem = words.callIt("mac.move_sample"); return }
        write { root in
            var settings = Self.settings(root)
            settings["productionPaused"] = .bool(false)
            settings["pauseReason"] = .string("")
            // NULL, not absent. The other app writes `pausedAt = null`, and a
            // field removed entirely is one a merge can resurrect from an older
            // copy on another machine.
            settings["pausedAt"] = .null
            root["settings"] = .object(settings)
        }
    }

    // MARK: - What is likely to go wrong with this print

    /// The overhang report for each model, keyed by the model's id.
    ///
    /// Loaded from the record where one has been stored, so a shop that turned
    /// the walk on at import sees every answer immediately and one that did not
    /// sees the ones it has asked for.
    private(set) var risks: [String: KhaytEngine.PrintRiskReport] = [:]
    /// The models whose mesh is being walked right now.
    private(set) var riskRunning: Set<String> = []
    var riskProblem: String?

    /// `demand` or `import`, from the shared rule — nil until it has answered.
    ///
    /// NOT defaulted to a literal here. The shared rule owns that default, and
    /// a second copy of it in Swift is a second thing to get wrong when it
    /// changes. Nil reads as "not at import", which is the same conservative
    /// direction `lib/print-risk.js` takes for a value it does not recognise:
    /// the cost of being wrong is one click, not an hour added to an import.
    private(set) var riskWhen: String?

    /// True when an import should walk the mesh as each file lands.
    var analysesRiskAtImport: Bool { riskWhen == "import" }

    /// Look at one model's mesh and keep the answer.
    ///
    /// STORES THE MEASUREMENT AND NOT THE VERDICT, which is the whole reason
    /// this is worth storing at all. `assessModel`'s thresholds are applied to
    /// the shop's own nozzle and support angle, and a shop changes those — a
    /// stored verdict would go stale silently and be read as current. Ninety-one
    /// buckets and a handful of scalars re-judge in microseconds; re-reading a
    /// hundred-megabyte mesh is the part that takes seconds.
    func analyseRisk(_ file: LibraryFile) async {
        guard let engine, !riskRunning.contains(file.id) else { return }
        guard let url = modelFile(for: file) else {
            riskProblem = words.callIt("mac.not_found"); return
        }
        riskRunning.insert(file.id)
        riskProblem = nil
        defer { riskRunning.remove(file.id) }

        // OFF THE MAIN ACTOR. This is seconds of arithmetic on a real file and
        // it is the thread drawing the app — the same mistake that made the
        // library screen hang while it measured.
        let walked = await Task.detached(priority: .userInitiated) {
            try? Mesh.overhangs(of: url)
        }.value
        guard let analysis = walked else {
            riskProblem = words.callIt("risk.unreadable")
            return
        }

        await judge(analysis, for: file, engine: engine)
        store(analysis, for: file.id, hash: file.contentHash)
    }

    /// Turn a stored or fresh summary into findings, using this shop's numbers.
    private func judge(_ analysis: [String: JSONValue], for file: LibraryFile,
                       engine: KhaytEngine) async {
        let mesh = file.mesh
        // NO BED, deliberately, and it is not an omission.
        //
        // `shop.fits` already answers "does it go on a plate you own" properly
        // — per machine, through `lib/print-fit.js` — and the inspector prints
        // that answer three lines above this section. Passing a bed here made
        // the risk report say it a second time in different words: the Mesh
        // section read "Too big for every machine you have" and this one read
        // "It does not fit: 1435×1057×185 mm against …". One fact, two
        // sentences, and a reader left wondering whether they are the same one.
        //
        // The engine still takes a bed, and `PrintRiskTests` covers it, for a
        // caller with no fit line of its own.
        let report = try? await engine.assessModel(
            analysis: analysis,
            nozzleDiameter: nozzleForRisk,
            bbox: mesh.map { (x: $0.x, y: $0.y, z: $0.z) })
        if let report { risks[file.id] = report }
    }

    /// Judge every model that already has a stored summary.
    ///
    /// Runs on load and after a settings change, because both move the answer:
    /// a shop that fits a 0.6 mm nozzle stops having thin-wall warnings on half
    /// its library, and it should not have to re-read a single file to find out.
    func rejudgeStoredRisks() async {
        guard let engine else { return }
        for file in files {
            guard let analysis = file.riskAnalysis else { continue }
            await judge(analysis, for: file, engine: engine)
        }
    }

    /// The nozzle to judge against: the widest any machine has, or nil.
    ///
    /// The WIDEST rather than an average, because a thin wall is only a problem
    /// on a nozzle too fat to lay it — reporting against the finest nozzle in
    /// the shop would warn about walls the shop can print. Nil when no machine
    /// records one, and the shared rule's own 0.4 default then applies.
    private var nozzleForRisk: Double? {
        var widest: Double?
        for row in machineRows {
            guard case .object(let m) = row, case .number(let d)? = m["nozzleDiameter"], d > 0
            else { continue }
            widest = max(widest ?? 0, d)
        }
        return widest
    }

    /// Keep the summary on the record so the mesh is walked once, not once a look.
    private func store(_ analysis: [String: JSONValue], for id: String, hash: String?) {
        guard let build = source.build else { return }
        do {
            try StoreWriter.update(build) { root in
                Self.edit(&root, ids: [id]) { record in
                    var held: [String: JSONValue] = ["analysis": .object(analysis)]
                    // The hash it was measured from. A record whose file has
                    // been replaced has a summary describing the OLD mesh, and
                    // a stale answer presented as current is worse than none.
                    if let hash { held["contentHash"] = .string(hash) }
                    held["at"] = .number(Date().timeIntervalSince1970 * 1000)
                    record["printRisk"] = .object(held)
                }
            }
            // NOT an undoable edit. A measurement is not a change the shop
            // made, and putting it on the undo stack would mean Cmd-Z after
            // asking a question un-asks it and leaves the shop's own last edit
            // one step further away.
            Task { await load(source) }
        } catch {
            riskProblem = String(describing: error)
        }
    }

    /// Change some print-file records in place, stamping each.
    private static func edit(_ root: inout [String: JSONValue], ids: Set<LibraryFile.ID>,
                             change: (inout [String: JSONValue]) -> Void) {
        guard case .array(var rows)? = root["printFiles"] else { return }
        for i in rows.indices {
            guard case .object(var record) = rows[i],
                  case .string(let id)? = record["id"], ids.contains(id) else { continue }
            change(&record)
            StoreWriter.stamp(&record)
            rows[i] = .object(record)
        }
        root["printFiles"] = .array(rows)
    }

    /// The customers, skipping any row without an id.
    ///
    /// A client with no id cannot be pointed at by a job, so it is not a client
    /// this app can offer — every other field is optional, because a customer
    /// written down in a hurry has a name and nothing else.
    private static func decodeClients(_ root: [String: JSONValue]) -> [Client] {
        guard case .array(let rows)? = root["clients"] else { return [] }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        return rows.compactMap { try? decoder.decode(Client.self, from: encoder.encode($0)) }
    }

    private static func decodeOrders(_ root: [String: JSONValue]) throws -> (items: [Order], skipped: [String]) {
        guard case .array(let rows)? = root["printLog"] else { return ([], []) }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var items: [Order] = [], skipped: [String] = []
        for row in rows {
            do { items.append(try decoder.decode(Order.self, from: try encoder.encode(row))) }
            catch {
                var id = "(no id)"
                if case .object(let o) = row, case .string(let s)? = o["id"] { id = s }
                skipped.append(id)
            }
        }
        return (items, skipped)
    }

    private static func decodeFiles(_ root: [String: JSONValue]) -> (items: [LibraryFile], skipped: [String]) {
        guard case .array(let rows)? = root["printFiles"] else { return ([], []) }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var items: [LibraryFile] = [], skipped: [String] = []
        for row in rows {
            do { items.append(try decoder.decode(LibraryFile.self, from: try encoder.encode(row))) }
            catch {
                var id = "(no id)"
                if case .object(let o) = row, case .string(let s)? = o["id"] { id = s }
                skipped.append(id)
            }
        }
        return (items, skipped)
    }

    /// Decode one collection, skipping records that do not fit rather than
    /// losing the collection. Same reasoning as the orders and the library: a
    /// newer build will put fields here this app has never heard of.
    private static func decode<T: Decodable>(_ root: [String: JSONValue], _ key: String,
                                             as type: T.Type) -> [T] {
        guard case .array(let rows)? = root[key] else { return [] }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        return rows.compactMap { row in
            guard let data = try? encoder.encode(row) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }
    }

    private static func librarySettings(_ root: [String: JSONValue]) -> JSONValue? {
        guard case .object(let settings)? = root["settings"] else { return nil }
        return settings["printLibrary"]
    }

    /// Read the shop's tax setup through the shared engine rather than the
    /// settings dictionary. `lib/tax.js` is what decides whether a shop is
    /// registered, at what rate, and whether its prices include the tax — and
    /// the answer differs by country, which is exactly the sort of thing a
    /// second implementation gets subtly wrong.
    private func describeTax(_ settings: JSONValue?) async -> String? {
        guard case .object(let dict)? = settings, let engine else { return nil }
        guard let profile = try? await engine.taxProfile(settings: dict), profile.isRegistered else { return nil }
        // `name` is the tax's own label from `lib/tax.js` — VAT, GST, what the
        // shop's invoices say — so it is not translated here. The sentence
        // around it is, and used not to be: this line sits in the sidebar
        // footer on every screen, and an Arabic shop read its tax name in
        // Arabic followed by "included in the price" in English.
        let key = profile.mode == .inclusive ? "mac.tax_inclusive" : "mac.tax_exclusive"
        return words.callIt(key, ["name": .string(profile.name),
                                  "pct": .string(Money.figure(profile.totalPercent))])
    }

    /// A price split into what the shop keeps and what it is only holding for
    /// the tax authority. Computed by `lib/tax.js`, not here.
    func taxSplit(_ amount: Double) async -> TaxSplit? {
        guard let engine, case .object(let dict) = settingsValue else { return nil }
        guard let profile = try? await engine.taxProfile(settings: dict), profile.isRegistered else { return nil }
        return try? await engine.computeTax(amount, profile: profile)
    }

    // MARK: - What the table shows

    var shown: [Order] {
        var rows = orders
        if let stage { rows = rows.filter { Stage.of($0) == stage } }
        // Narrowed to one kit, when the band above the table has been asked
        // for one. A chip that only states a total is decoration; this is what
        // makes it a control — "show me the four jobs that made the figure".
        if let kitFilter, let kit = kits.first(where: { $0.id == kitFilter }) {
            let inKit = Set(kit.jobIds)
            rows = rows.filter { inKit.contains($0.id) }
        }
        return matching(rows)
    }

    /// Which kit the book is narrowed to, if any. Not persisted: a filter that
    /// survives a relaunch is a book that opens showing four of its jobs with
    /// no visible reason why.
    var kitFilter: String? {
        didSet {
            guard kitFilter != oldValue else { return }
            // A selection outside the narrowed book is a row the table cannot
            // show and an inspector describing something invisible.
            if let selection, !shown.contains(where: { $0.id == selection }) { self.selection = nil }
        }
    }

    func count(_ stage: Stage) -> Int { orders.count { Stage.of($0) == stage } }

    // MARK: - What the library shows

    /// The groups a shop has actually made, in the order it reads them.
    var groups: [String] {
        var seen = Set<String>(), out: [String] = []
        for g in files.compactMap(\.groupName) where !seen.contains(g) {
            seen.insert(g); out.append(g)
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var ungroupedCount: Int { files.count { $0.groupName == nil } }

    // MARK: - What the shell needs to draw itself
    //
    // Small readings, kept together because they are all answers to "what
    // does the window say about this book" rather than facts about the shop.

    /// The title the window shows for the screen now open — §7's title bar.
    /// Which question the Ledger is answering, and which row is open in the
    /// inspector. Screen state, so it lives with the screen rather than in the
    /// book — a shop reopening Khayt wants its jobs, not its last filter.
    var ledgerFilter: LedgerFilter = .needsMe
    var ledgerSelection: LedgerLine?

    /// WHAT THE STRIP SAYS YOU ARE LOOKING AT — the name, not the screen.
    ///
    /// `shelfTitleKey` answers with the SCREEN, and inside a library group that
    /// is wrong in a way a shop cannot get out of: opening a folder left the
    /// title reading "All models", the sidebar row still on Library, and
    /// nothing anywhere naming the folder or offering a way back up. The old
    /// window had a subtitle and a group menu in its toolbar; this one has the
    /// strip.
    ///
    /// A stage does the same to Jobs, and says so the same way.
    @MainActor var shelfTitle: String {
        switch shelf {
        case .library(let group?): group
        case .jobs(let stage?):    words.callIt(stage.key)
        default:                   words.callIt(shelfTitleKey)
        }
    }

    var shelfTitleKey: String {
        switch shelf {
        case .dashboard:  "mac.dashboard"
        case .jobs:       "mac.all_jobs"
        case .board:      "mac.board"
        case .library:    "mac.all_models"
        case .catalogue:  "cat.title"
        case .customers:  "tab.clients"
        case .machines:   "mac.machines"
        case .inventory:  "mac.inventory"
        case .expenses:   "mac.nav_expenses"
        case .waste:      "mac.nav_waste"
        case .reports:    "mac.nav_reports"
        case .portfolio:  "pf.title"
        case .calculator: "mac.calc_title"
        case .colour:     "cmix.title"
        case .giftCards:  "giftCards"
        }
    }

    /// The file this book lives in, by name only. The whole path in a 150px
    /// sidebar is a middle-truncated string nobody can read; the name is what
    /// a shop with two books actually distinguishes them by.
    var bookFileName: String {
        source.build.map { $0.storeURL.lastPathComponent } ?? "sample-shop.json"
    }

    /// Whether this Mac is signed in to the cloud at all — NOT whether it has
    /// synced recently, which is a different sentence and belongs in Settings.
    var isCloudLinked: Bool { cloudConnected }

    /// "saved 11:38", or when the book has never been written, nothing.
    var lastSavedLabel: String {
        guard let backup = lastBackup, let day = Order.day(backup) else {
            return words.callIt("mac.never")
        }
        return words.callIt("mac.saved_at",
                            ["t": .string(day.formatted(date: .omitted, time: .shortened))])
    }

    /// Is anything actually printing? One dot in the sidebar, and a dot is
    /// the right weight: the number of running machines is on the Machines
    /// screen, and repeating it in the nav is a figure to keep in step.
    var anyMachineRunning: Bool {
        machines.contains {
            PrinterWatch.isPrinting(printers.readings[$0.id]?.status?.state ?? "")
        }
    }

    /// The categories and the tags the shop already uses, most-used first.
    ///
    /// Offered before typing, and that order is the point: the menu exists so a
    /// model gets filed under a name that is ALREADY in use rather than a second
    /// spelling of it.
    ///
    /// The WHOLE book, deliberately — not `libraryFacets`, which is narrowed by
    /// the shelf and whatever chips are on. A shop standing inside one project
    /// and offered only that project's categories would type a name the book
    /// already holds elsewhere, and the folding rule can only fold against names
    /// it was given. That is the exact drift this menu exists to prevent.
    private(set) var categoriesInUse: [String] = []
    private(set) var tagsInUse: [String] = []

    private func readLibraryNames() async {
        guard let engine, !libraryRows.isEmpty else {
            categoriesInUse = []; tagsInUse = []; return
        }
        categoriesInUse = ((try? await engine.categoryCounts(libraryRows)) ?? []).map(\.name)
        tagsInUse = ((try? await engine.tagCounts(libraryRows)) ?? []).map(\.name)
    }

    /// File the selected models under a category, or clear it with "".
    func fileSelection(underCategory name: String) async {
        guard !fileSelection.isEmpty else { return }
        let ids = fileSelection
        // Through the engine, for the same reason as the group above: a name
        // matching one the shop already uses adopts that spelling rather than
        // becoming a second chip holding part of the same idea.
        guard let engine,
              let patch = try? await engine.fileUnderCategory(name, known: categoriesInUse)
        else {
            writeProblem = words.callIt("mac.group_unknown")
            return
        }
        let named = name.isEmpty
            ? words.callIt("mac.remove_from_category")
            : words.callIt("mac.file_in", ["name": .string(name)])
        editFiles(ids, named: named) { record in
            for (key, value) in patch { record[key] = value }
        }
    }

    /// Set the tags on the selected models from a typed, comma-separated line.
    ///
    /// Replaces rather than merges. Tagging several models at once is how a
    /// shop says "these are the same kind of thing", and a merge would make the
    /// result depend on what each already carried — so what is typed is what
    /// they all end up with, which is the only version of this a person can
    /// predict.
    func tagSelection(_ typed: String) async {
        guard !fileSelection.isEmpty else { return }
        let ids = fileSelection
        guard let engine, let tags = try? await engine.normaliseTags(typed, known: tagsInUse)
        else {
            writeProblem = words.callIt("mac.group_unknown")
            return
        }
        editFiles(ids, named: words.callIt("mac.tag_models")) { record in
            record["tags"] = .array(tags.map { .string($0) })
        }
    }

    /// Attach a photograph of the finished print to a model.
    ///
    /// `thumbnail(for:)` has always preferred one — "a photograph the shop took
    /// beats a generated thumbnail" — and this app had no way to take one. The
    /// bytes are the other app's: 480px, JPEG at 0.82, inline as a data URI, so
    /// a picture attached here is one Khayt draws without knowing where it came
    /// from.
    func setLibraryPhoto(_ fileId: LibraryFile.ID, from url: URL) {
        writeProblem = nil
        guard source.build != nil else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        let uri: String
        do { uri = try LibraryPhoto.dataURI(of: url) }
        catch {
            // The reader's own sentence — "8 MB", "not a picture Khayt can
            // read" — rather than a generic failure, because each of them
            // tells the shop what to do differently.
            writeProblem = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            return
        }
        editFiles([fileId], named: words.callIt("mac.lp_action")) { record in
            record["userPhoto"] = .string(uri)
        }
    }

    /// Take the photograph off again, leaving the generated preview to show.
    func clearLibraryPhoto(_ fileId: LibraryFile.ID) {
        writeProblem = nil
        guard source.build != nil else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        // NULL, not absent. The other app writes `userPhoto: null` on a new
        // record, and a field removed entirely is a field a merge can resurrect
        // from the older copy on another machine.
        editFiles([fileId], named: words.callIt("mac.lp_removed")) { record in
            record["userPhoto"] = .null
        }
    }

    // MARK: - Where a model came from

    /// Record what a model's licence is, on everything selected.
    ///
    /// ── WHY THIS HAD TO EXIST ─────────────────────────────────────────────
    ///
    /// The inspector has always READ a licence and nothing on this Mac could
    /// write one, so on a real book the panel was blank on every model and the
    /// only way to fill it in was to open the other app. A library holds work
    /// the shop made and models it downloaded, they look identical in a grid,
    /// and the difference decides whether a print can be SOLD.
    ///
    /// An empty string CLEARS it, back to "nobody has recorded one" — which is
    /// not the same as "may not be sold" and must stay reachable, because a
    /// licence set by mistake is worse than no licence at all.
    func fileSelection(licence: String) async {
        guard !fileSelection.isEmpty else { return }
        // Through `ModelLicence`, so a value this app cannot name never reaches
        // the book: the id stored is the module's own spelling of it.
        let id = ModelLicence.find(licence)?.id ?? ""
        guard !licence.isEmpty == !id.isEmpty else {
            writeProblem = words.callIt("mac.licence_unknown"); return
        }
        let named = id.isEmpty ? words.callIt("mac.licence_cleared")
                               : words.callIt("mac.licence_set")
        editFiles(fileSelection, named: named) { record in
            record["licence"] = .string(id)
        }
    }

    /// Record where a model came from — a model-site URL, or the shop's own
    /// name for it. Free text on purpose: it is a note to a person.
    func setSourceOnSelection(_ typed: String) async {
        guard !fileSelection.isEmpty else { return }
        // Trimmed and capped at the other app's own `maxlength`, so a source
        // typed here is one it will show back.
        let source = String(typed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        editFiles(fileSelection, named: words.callIt("mac.source_set")) { record in
            record["source"] = .string(source)
        }
    }

    /// The licence everything selected already carries, or nil when they
    /// disagree — the same reasoning as `tagsOnSelection`: showing one model's
    /// answer and writing it to the rest would hand them one they never had.
    var licenceOnSelection: String? {
        let chosen = selectedFiles
        guard let first = chosen.first else { return nil }
        let id = ModelLicence.find(first.licence)?.id ?? ""
        return chosen.allSatisfy { (ModelLicence.find($0.licence)?.id ?? "") == id } ? id : nil
    }

    /// The source shared by everything selected, or empty when they disagree.
    var sourceOnSelection: String {
        let chosen = selectedFiles
        guard let first = chosen.first?.source else { return "" }
        return chosen.allSatisfy { ($0.source ?? "") == first } ? first : ""
    }

    /// What the tag box starts with: the tags shared by everything selected.
    ///
    /// Not the first one's tags. With several chosen, showing one model's tags
    /// and then writing them to all of them would quietly hand the rest a set
    /// they never had.
    var tagsOnSelection: [String] {
        let chosen = selectedFiles
        guard let first = chosen.first else { return [] }
        var shared = first.tags ?? []
        for file in chosen.dropFirst() {
            let theirs = Set((file.tags ?? []).map { $0.lowercased() })
            shared = shared.filter { theirs.contains($0.lowercased()) }
        }
        return shared
    }

    /// What the library grid shows: projects as folders, then loose files.
    ///
    /// Only at the TOP of the library. Inside a folder the shelf already
    /// carries the group, and the grid is the files in it — a folder within a
    /// folder is a different feature and this is not pretending to be it.
    var shownEntries: [LibraryEntry] {
        guard case .library(let group) = shelf, group == nil else {
            return shownFiles.map { LibraryEntry.file($0) }
        }
        return LibraryEntry.top(of: shownFiles, order: librarySort.order)
    }

    /// One axis of the library filter: a name, or the things that have none.
    ///
    /// "Unfiled" is a CASE rather than a sentinel string. The other app used a
    /// magic value and it went through a `data-` attribute, where a NUL became
    /// U+FFFD and the chip quietly matched nothing — the Unfiled chip was dead
    /// for weeks. A case cannot be mangled on the way to a comparison.
    enum FilterChoice: Hashable {
        case named(String)
        case unfiled

        /// Does a record's value for this axis match? Case-insensitively,
        /// because the shop's own spellings are folded everywhere else too.
        func matches(_ value: String?) -> Bool {
            switch self {
            case .unfiled: return (value ?? "").isEmpty
            case .named(let want):
                return (value ?? "").lowercased() == want.lowercased()
            }
        }
    }

    /// The chips the library filter bar offers.
    ///
    /// ── EVERY AXIS IS COUNTED OVER WHAT THE OTHERS LEAVE ──────────────────
    ///
    /// A chip says a number, a shop decides whether to press it on that number,
    /// and a count describing a different population from the grid under it is
    /// a lie the shop cannot see. The other app shipped exactly that and its own
    /// note records the symptom: *"these counted the whole catalogue while the
    /// grid narrows on three things at once, so with a category on, a group
    /// chip said 7 and pressing it showed 2."*
    ///
    /// So each axis is counted over the rows the OTHER axes leave — the shelf,
    /// the search box and the two chips that are not this one. Counting a chip
    /// against its own axis would instead narrow the row to whatever is already
    /// on and the shop could never press a second value.
    ///
    /// ── AND FROM THE SHARED RULE, NOT FROM SWIFT ──────────────────────────
    ///
    /// The arithmetic is the easy half. What matters is the FOLDING: a shop that
    /// typed "Wall art" once and "wall art" twice has one category holding
    /// three, not two holding some each. `Dictionary(grouping:)` would get the
    /// sum right and the shop's own idea of its library wrong.
    struct LibraryFacets: Equatable {
        var categories: [KhaytEngine.GroupCount] = []
        var tags: [KhaytEngine.GroupCount] = []
        /// Models in no project at all — the answer to "what have I not filed
        /// yet". Zero inside a folder, where nothing can be unfiled, which is
        /// how that chip disappears when it would teach the wrong thing.
        var unfiled = 0
        var isEmpty: Bool { categories.isEmpty && tags.isEmpty && unfiled == 0 }
    }

    private(set) var libraryFacets = LibraryFacets()

    /// The library rows as they sit in the book. Kept because the counts are
    /// asked of a JavaScript rule, which reads records rather than `LibraryFile`
    /// — and re-encoding the decoded ones per keystroke would be a hop for a
    /// round trip.
    private var libraryRows: [JSONValue] = []

    enum LibraryAxis { case unfiled, category, tag }

    /// What one axis counts: the shelf, the search, and the other two chips.
    private func libraryPool(skipping axis: LibraryAxis) -> [JSONValue] {
        var rows = libraryRows
        if case .library(let group) = shelf, let group {
            rows = rows.filter { Self.rowGroup($0) == group }
        }
        if axis != .unfiled, libraryUnfiledOnly {
            rows = rows.filter { Self.rowGroup($0) == nil }
        }
        if axis != .category, let category = libraryCategory {
            rows = rows.filter { category.matches(Self.rowText($0, "category")) }
        }
        if axis != .tag, let tag = libraryTag {
            rows = rows.filter { Self.rowTags($0).contains { $0.lowercased() == tag.lowercased() } }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { row in
            Self.rowText(row, "title").lowercased().contains(q)
                || Self.rowText(row, "material").lowercased().contains(q)
                || Self.rowTags(row).contains { $0.lowercased().contains(q) }
        }
    }

    /// The group a record is in, by the rule the grid files it under —
    /// `folder` if the key is there at all, then `group`. Splitting on `group`
    /// alone would count a model under one project and draw it in another.
    private static func rowGroup(_ row: JSONValue) -> String? {
        guard case .object(let o) = row else { return nil }
        let text: (String) -> String? = { key in
            if case .string(let v)? = o[key] { return v }
            return o[key] == nil ? nil : ""
        }
        return LibraryFile.groupName(folder: text("folder"), group: text("group"))
    }

    private static func rowText(_ row: JSONValue, _ key: String) -> String {
        guard case .object(let o) = row, case .string(let v)? = o[key] else { return "" }
        return v
    }

    private static func rowTags(_ row: JSONValue) -> [String] {
        guard case .object(let o) = row, case .array(let rows)? = o["tags"] else { return [] }
        return rows.compactMap { if case .string(let t) = $0 { t } else { nil } }
    }

    /// Recount the chips. Called from the setters below rather than by the
    /// views, so a chip cannot be added to a screen and quietly left stale.
    /// Typing in the search box starts one of these per keystroke, and each
    /// hops into JavaScript twice. The LAST one started is the only one allowed
    /// to write — otherwise a slow recount of "wal" lands after a fast one of
    /// "wall art" and the chips describe a search the shop has finished typing.
    ///
    /// Not covered by a test, and deliberately kept anyway: an actor makes no
    /// promise about the order its suspended callers resume in, so this cannot
    /// be forced to happen from a test and a passing suite is not evidence it
    /// never will. `settleLibraryFacets` is what the tests use, and it proves
    /// the recount finishes — not the order two of them finish in.
    private var libraryRecount = 0

    func readLibraryFacets() async {
        libraryRecount += 1
        let mine = libraryRecount
        guard let engine, !libraryRows.isEmpty else { libraryFacets = LibraryFacets(); return }
        let categories = (try? await engine.categoryCounts(libraryPool(skipping: .category))) ?? []
        let tags = (try? await engine.tagCounts(libraryPool(skipping: .tag))) ?? []
        guard mine == libraryRecount else { return }
        let unfiled = libraryPool(skipping: .unfiled).count { Self.rowGroup($0) == nil }
        libraryFacets = LibraryFacets(categories: categories, tags: tags, unfiled: unfiled)
    }

    private var libraryRecountTask: Task<Void, Never>?
    private func recountLibrarySoon() { libraryRecountTask = Task { await readLibraryFacets() } }

    /// Wait for the chips to catch up with what was last asked of them.
    ///
    /// The recounts are started by the setters, so nothing on screen has to
    /// remember to ask — but that leaves no moment at which they are known to be
    /// finished, and a test that reads them right after changing the shelf is
    /// reading whatever happened to land. Draining in a loop rather than
    /// awaiting once, because a change made WHILE one is in flight starts
    /// another.
    func settleLibraryFacets() async {
        while let pending = libraryRecountTask {
            libraryRecountTask = nil
            await pending.value
        }
    }

    /// What a shop is looking at: a category, a tag, both, or neither.
    ///
    /// The GROUP axis is not here — it is the shelf, because a group is a
    /// folder now and opening one is navigating rather than filtering. Unfiled
    /// is the exception and lives here, since there is no folder to open for
    /// models that are in none.
    var libraryCategory: FilterChoice? { didSet { recountLibrarySoon() } }
    var libraryTag: String? { didSet { recountLibrarySoon() } }
    /// Models in no project at all — the answer to "what have I not filed yet".
    var libraryUnfiledOnly = false { didSet { recountLibrarySoon() } }

    var libraryFilterOn: Bool {
        libraryCategory != nil || libraryTag != nil || libraryUnfiledOnly
    }

    func clearLibraryFilter() {
        libraryCategory = nil
        libraryTag = nil
        libraryUnfiledOnly = false
    }

    var shownFiles: [LibraryFile] {
        var rows = files
        // A model a conversion has replaced is put aside rather than deleted —
        // see `LibraryFile.archivedAt`. It is still in the book, still on disk
        // and still what a past job was printed from; it is simply not one of
        // the things the shop is choosing between today.
        if !libraryShowArchived { rows = rows.filter { !$0.isArchived } }
        if case .library(let group) = shelf, let group {
            rows = rows.filter { $0.groupName == group }
        }
        // Every axis narrows at once, deliberately: "the busts in the Saudi
        // Kings" is the question a library of hundreds is actually asked — the
        // same reasoning renderer/printfiles.js gives for its own chips.
        if libraryUnfiledOnly { rows = rows.filter { ($0.groupName ?? "").isEmpty } }
        if let category = libraryCategory { rows = rows.filter { category.matches($0.category) } }
        if let tag = libraryTag {
            rows = rows.filter { ($0.tags ?? []).contains { $0.lowercased() == tag.lowercased() } }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            rows = rows.filter {
                $0.title.lowercased().contains(q)
                    || ($0.material ?? "").lowercased().contains(q)
                    || ($0.tags ?? []).contains { $0.lowercased().contains(q) }
            }
        }
        return rows.sorted(by: librarySort.order)
    }

    /// The inspector shows one model. More than one selected is a different
    /// screen — what they have in common, and what can be done to all of them.
    var selectedFile: LibraryFile? {
        fileSelection.count == 1 ? files.first { fileSelection.contains($0.id) } : nil
    }
    var selectedFiles: [LibraryFile] { shownFiles.filter { fileSelection.contains($0.id) } }

    /// Click, ⌘-click, ⇧-click. Written out because a grid is not a `List` and
    /// gets none of this for free — and a Mac app where ⌘-click does not extend
    /// a selection is one that reads as a web page however it is drawn.
    func select(_ file: LibraryFile, modifiers: SelectionModifier) {
        switch modifiers {
        case .replace:
            fileSelection = [file.id]
            anchor = file.id
            cursor = file.id
        case .toggle:
            if fileSelection.contains(file.id) { fileSelection.remove(file.id) }
            else { fileSelection.insert(file.id); anchor = file.id }
            cursor = file.id
        case .extend:
            let rows = shownFiles
            guard let end = rows.firstIndex(where: { $0.id == file.id }) else { return }
            let start = anchor.flatMap { a in rows.firstIndex { $0.id == a } } ?? end
            let range = start <= end ? start...end : end...start
            fileSelection.formUnion(rows[range].map(\.id))
            cursor = file.id
        }
    }

    enum SelectionModifier { case replace, toggle, extend }
    /// Where a selection run started, and where the keyboard is standing.
    private var anchor: LibraryFile.ID?
    private var cursor: LibraryFile.ID?

    /// Move the selection by `step` places in reading order.
    ///
    /// Reading order, not screen order: in a mirrored window the next model is
    /// to the LEFT. The caller has already turned the key into a direction;
    /// this only counts.
    ///
    /// TWO POSITIONS, NOT ONE. `anchor` is where a selection run started and
    /// `cursor` is where the keyboard is standing. Computing the next place from
    /// the anchor — which is what this did first — means a second shift-arrow
    /// lands where the first one did and the selection never grows past two.
    ///
    /// Returns whether it moved, so a key at either end is left unhandled and
    /// the system beep can do its job.
    @discardableResult
    func moveSelection(by step: Int, extending: Bool) -> Bool {
        let rows = shownFiles
        guard !rows.isEmpty else { return false }

        guard let here = cursor.flatMap({ c in rows.firstIndex { $0.id == c } }) else {
            // Nothing chosen yet: the first press picks an end rather than doing
            // nothing, which is what a Finder window does.
            let landing = step >= 0 ? rows.first! : rows.last!
            fileSelection = [landing.id]
            anchor = landing.id
            cursor = landing.id
            return true
        }

        let next = here + step
        guard rows.indices.contains(next) else { return false }
        cursor = rows[next].id
        if extending {
            let start = anchor.flatMap { a in rows.firstIndex { $0.id == a } } ?? here
            let range = start <= next ? start...next : next...start
            fileSelection = Set(rows[range].map(\.id))
        } else {
            fileSelection = [rows[next].id]
            anchor = rows[next].id
        }
        return true
    }

    func selectAllShown() {
        fileSelection = Set(shownFiles.map(\.id))
        anchor = shownFiles.first?.id
        cursor = anchor
    }

    /// The one the keyboard is standing on, for scrolling into view.
    var focusedFile: LibraryFile.ID? { cursor ?? fileSelection.first }

    /// Show one model, whatever the library is currently filtered to.
    ///
    /// For Spotlight: somebody searched their Mac, chose a model, and the app
    /// came forward. If it came forward on a filtered grid that does not
    /// contain what they picked, the search result was a lie — so every filter
    /// that could hide it is cleared, including the archived switch, because a
    /// superseded model is still a model somebody can ask for by name.
    ///
    /// A model somebody asked for before the book was open.
    ///
    /// Held here rather than dropped: a Spotlight result is often what launches
    /// the app, and the activity arrives while `files` is still empty.
    private var pendingReveal: String?

    /// Show a model now if the book is open, and as soon as it is if not.
    func revealWhenLoaded(fileId: String) {
        if reveal(fileId: fileId) { return }
        // Not found YET is not the same as not there. If the library has rows
        // and this is not one of them, the model is genuinely gone and holding
        // the request would make the next load jump somewhere unasked.
        pendingReveal = files.isEmpty ? fileId : nil
    }

    /// Answer a held request, once there is a library to answer it from.
    private func answerPendingReveal() {
        guard let wanted = pendingReveal else { return }
        pendingReveal = nil
        reveal(fileId: wanted)
    }

    /// Returns whether the model was found at all. A book that has moved on
    /// since Spotlight last heard about it is a real state, and the caller
    /// needs to know rather than leave the window sitting on an empty library.
    @discardableResult
    func reveal(fileId: String) -> Bool {
        guard let file = files.first(where: { $0.id == fileId }) else { return false }
        search = ""
        libraryCategory = nil
        libraryTag = nil
        libraryUnfiledOnly = false
        if file.isArchived { libraryShowArchived = true }
        // Into its own project if it has one: that is where the model lives,
        // and opening the library at the top with one tile selected somewhere
        // below is not showing it to anybody.
        shelf = .library(file.groupName)
        fileSelection = [file.id]
        cursor = file.id
        return true
    }

    // MARK: - What the customers screen shows

    var customers: [Customer] { Customer.from(orders, clients: clients, names: clientNames) }

    /// What the shop calls each of its customers, in its own language.
    ///
    /// Resolved once when the book loads — thirty-one rows asking the engine
    /// one at a time would be thirty-one bridge crossings for one screen.
    private(set) var clientNames: [String: KhaytEngine.Named] = [:]
    /// What each model's licence permits, by model id. Absent for a model
    /// nobody has recorded one for, which is NOT the same as one that may not
    /// be sold — the screen says nothing rather than something wrong.
    private(set) var licences: [String: KhaytEngine.Standing] = [:]

    /// The printers a model can be converted for, from the shared rule.
    private(set) var printerProfiles: [KhaytEngine.PrinterProfile] = []
    /// What the last conversion had to say, and whether one is running.
    var convertNote: String?
    var convertProblem: String?
    private(set) var converting = false

    /// Which spools are running low, by id — the shared rule's answer, asked
    /// once for the whole shelf.
    private(set) var lowSpools: [String: Bool] = [:]
    /// How long each spool has got, by id.
    ///
    /// The reorder list's own arithmetic, asked of every spool rather than
    /// only the urgent ones — a shelf wants to know a spool is fine as much as
    /// it wants to know one is not. Worked out once when the book loads: it
    /// reads the whole order history, which is not a thing to do per card per
    /// redraw. A spool absent from this map, or one whose `daysLeft` is nil,
    /// has had nothing printed from it in the window and gets no line.
    private(set) var spoolRunway: [String: KhaytEngine.Runway] = [:]
    /// Whether each spool has gone damp, by id. Mostly `unknown` on a real
    /// shelf, and that is the honest answer — see `KhaytEngine.Dryness`.
    private(set) var spoolDryness: [String: KhaytEngine.Dryness] = [:]
    /// When each queued job will actually be ready, and which will miss its due
    /// date because of the queue in front of it.
    ///
    /// NOT the same as `late`, which means already past due. This one is a
    /// projection: a shop told on Tuesday that Friday's job will not make it
    /// can still move it, split it, or ring the customer. Worked out once when
    /// the book loads — it reads the whole active queue and the shop's working
    /// week, which is not a thing to redo per row per redraw.
    private(set) var timeline: KhaytEngine.Timeline?

    /// What the shop earned this month, net of tax — `lib/pnl-report.js` at
    /// month granularity, which is the same rule and the same figure Reports
    /// prints.
    ///
    /// Nil before the book is read, and nil for a month with no row of its own,
    /// which is a month nothing happened in. The masthead draws its dash then,
    /// rather than a confident zero.
    private(set) var monthNetRevenue: Double?

    /// The current month's row, or nil.
    ///
    /// The period key is `YYYY-MM` in LOCAL time, built by `DateRange` — the
    /// same construction the rule uses for its own keys, so the lookup cannot
    /// miss by a day at either end of a month for a shop not on UTC.
    static func thisMonthsNet(engine: KhaytEngine?, orders: [JSONValue],
                              expenses: [JSONValue], settings: [String: JSONValue],
                              clients: [JSONValue],
                              currencies: [String: JSONValue],
                              now: Date = Date()) async -> Double? {
        guard let engine else { return nil }
        let periods = (try? await engine.pnlByPeriod(
            orders: orders, expenses: expenses, settings: settings, clients: clients,
            currencies: currencies, now: now, granularity: "month")) ?? []
        return periods.first { $0.period == DateRange.localMonth(now) }?.revenue
    }

    /// Ask the shared rule when the queue will finish.
    ///
    /// Only the jobs actually ON the floor: a quote nobody has accepted is not
    /// in the queue, and counting it would push every real job's date out and
    /// invent lateness that does not exist. `printTime` is the estimate the job
    /// carries; a job with none contributes nothing but still takes its place
    /// in the order, which is what a real queue does with an unestimated job.
    ///
    /// The start day is the SHOP'S calendar day, not UTC's. A projection made
    /// at one in the morning in Riyadh must not be dated yesterday.
    static func project(orders: [Order], engine: KhaytEngine?,
                        settings: [String: JSONValue]) async -> KhaytEngine.Timeline? {
        guard let engine else { return nil }
        let onTheFloor: Set<String> = ["pending", "printing", "post", "qc", "on_hold"]
        let queued = orders.filter { onTheFloor.contains($0.status) }
        guard !queued.isEmpty else { return nil }
        let jobs: [JSONValue] = queued.map { o in
            .object([
                "id": .string(o.id),
                "machineId": .string(o.machineId ?? ""),
                "hours": .number(o.printTime),
                "dueDate": .string(o.dueDate ?? ""),
                "project": .string(o.project),
                "status": .string(o.status),
            ])
        }
        let daily = (try? await engine.dailyWorkingHours(settings: settings)) ?? 8
        let today = DateFormatter.shopDay.string(from: Date())
        return try? await engine.timeline(jobs: jobs, dailyHours: daily, startDate: today)
    }

    /// The jobs projected to miss their due date, soonest due first.
    var willBeLate: [Order] {
        guard let timeline else { return [] }
        var risky: [String: String] = [:]                 // id → its projected date
        for machine in timeline.machines {
            for job in machine.jobs where job.late { risky[job.id] = job.etaDate }
        }
        guard !risky.isEmpty else { return [] }
        // A job that is ALREADY late is not news from a projection — it is in
        // the attention panel, and saying it twice in two different words is
        // how a screen teaches somebody to skim it.
        let already = Set((facts?.attn.items ?? [])
            .filter { $0.kind == "order" }.map(\.id))
        return orders
            .filter { risky[$0.id] != nil && !already.contains($0.id) }
            .sorted { ($0.dueDate ?? "") < ($1.dueDate ?? "") }
    }

    /// The day a job is now expected to be ready, when that is known.
    func readyDate(of id: Order.ID) -> String? {
        guard let timeline else { return nil }
        for machine in timeline.machines {
            if let job = machine.jobs.first(where: { $0.id == id }) { return job.etaDate }
        }
        return nil
    }
    /// Which machine each model fits, keyed by the model's id. Worked out once
    /// when the book loads rather than per row: a grid of four hundred models
    /// asking the runtime on every redraw is four hundred context hops.
    private(set) var fits: [String: KhaytEngine.Fit] = [:]
    /// The cards the shop has issued, and what each one is today.
    private(set) var giftCards: [GiftCard] = []
    private(set) var giftCardRows: [JSONValue] = []

    // MARK: - Points a customer has earned

    /// The points ledger, as the book holds it.
    private(set) var loyaltyRows: [JSONValue] = []

    /// Whether the shop runs a rewards programme at all.
    ///
    /// Off unless the shop turned it on, and then nothing below is drawn. A
    /// points line on a customer who earns none is a screen inventing a
    /// programme the shop never agreed to.
    var loyaltyOn: Bool {
        if case .bool(true)? = settingsDict["loyaltyEnabled"] { return true }
        return false
    }

    /// Where one customer stands: earned, spent, and left to spend.
    ///
    /// ── WHY THIS APP COULD NOT ANSWER IT ──────────────────────────────────
    ///
    /// The sum lived in `renderer/clients.js`, so a customer's points existed
    /// only in the other window — while the programme went on accruing them
    /// for a shop working here. It is `lib/loyalty.js` now, and this asks it.
    func loyalty(of clientId: String) async -> KhaytEngine.LoyaltyStanding? {
        guard loyaltyOn, let engine, !clientId.isEmpty else { return nil }
        return try? await engine.loyalty(orders: orderRows, ledger: loyaltyRows,
                                         clientId: clientId, settings: settingsDict,
                                         clients: clientRows)
    }

    /// Turn a customer's points into store credit.
    ///
    /// TWO RECORDS, ONE SWAP. The gift card and the ledger row are written
    /// together or not at all: a card written without its row is the same
    /// points spent again next month, and a row written without its card is a
    /// customer told their balance is gone with nothing to show for it.
    ///
    /// Returns nil when it worked, or what to tell the shop.
    func redeemPoints(_ clientId: String) async -> String? {
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            return words.callIt("mac.read_only")
        }
        guard let engine, loyaltyOn else { return words.callIt("loyalty.none_to_redeem") }
        guard let standing = await loyalty(of: clientId), standing.available > 0 else {
            return words.callIt("loyalty.none_to_redeem")
        }

        // The shop's own rate, and the rule's default when it has not set one:
        // a hundred points to the unit.
        var rate = 0.01
        if case .number(let set)? = settingsDict["loyaltyRedeemRate"], set > 0 { rate = set }

        let made: KhaytEngine.Redemption
        do {
            made = try await engine.redeemLoyalty(
                clientId: clientId, clientName: clientNames[clientId]?.name ?? "",
                points: standing.available, rate: rate,
                code: Self.uid("LOY"), cardId: Self.uid("GC"),
                entryId: Self.uid("LOY"), now: Self.isoNow())
        } catch {
            return String(describing: error)
        }
        guard made.ok, let card = made.card, let entry = made.entry else {
            return words.callIt("loyalty.none_to_redeem")
        }

        do {
            try StoreWriter.update(storeURL: build.storeURL,
                                   owns: { StoreLock.weOwnIt(build) },
                                   whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }) { root in
                var cards: [JSONValue] = []
                if case .array(let existing)? = root["giftCards"] { cards = existing }
                cards.append(card)
                root["giftCards"] = .array(cards)

                var ledger: [JSONValue] = []
                if case .array(let existing)? = root["loyaltyLedger"] { ledger = existing }
                ledger.append(entry)
                root["loyaltyLedger"] = .array(ledger)
            }
        } catch {
            return String(describing: error)
        }
        await load(source)
        return nil
    }
    private(set) var giftCardStatuses: [String: String] = [:]
    /// Which state the screen is narrowed to, or nil for all of them.
    ///
    /// §4 took the Status column off this screen — three other things in the
    /// row already say it — and the three words became the way a shop ASKS
    /// instead. See `GiftCardFilterBar`.
    var giftCardState: String?
    /// True while the Issue sheet is up.
    var issuingGiftCard = false

    var shownCustomers: [Customer] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return customers }
        return customers.filter {
            $0.name.lowercased().contains(q) || $0.orders.contains { $0.project.lowercased().contains(q) }
        }
    }

    var selectedCustomer: Customer? { customers.first { $0.id == customerSelection } }

    func count(group: String) -> Int { files.count { $0.groupName == group } }

    /// The record's folder on this Mac, if it is on this Mac at all.
    /// Take a model out of the library — the record, and its files.
    ///
    /// ── THE MAC HAD NO WAY TO DO THIS ───────────────────────────────────────
    ///
    /// Reported from the running app: "I can't delete something from the
    /// library?" — and the answer was that nothing in the Mac app could. The
    /// menu offered Quick Look, Reveal, Open, Convert, Copy name; the model
    /// stayed forever. The Electron app has had this since the library
    /// existed, and a renderer-only feature is a gap to close.
    ///
    /// The rule is `renderer/printfiles.js deletePrintFile`'s, kept in step:
    /// confirmed first, in the same words; every file in the model's own
    /// folder is deleted and the record goes regardless — but a file that
    /// would not go is SAID, because the record was once removed and "File
    /// deleted" shown while the bytes stayed on disk. No undo: the files are
    /// gone, and an undo that puts the record back without them is a model
    /// that looks present and is not.
    func deleteLibraryFile(_ file: LibraryFile) async {
        importProblem = nil
        importNote = nil
        pendingLibraryDelete = nil
        guard let build = source.build else {
            importProblem = words.callIt("mac.move_sample"); return
        }
        var allGone = true
        if let dir = directory(for: file) {
            let contents = (try? FileManager.default.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: nil)) ?? []
            for url in contents {
                do { try FileManager.default.removeItem(at: url) } catch { allGone = false }
            }
            if allGone { try? FileManager.default.removeItem(at: dir) }
        }
        do {
            try StoreWriter.update(build) { root in
                var rows = Self.rows(root, "printFiles")
                rows.removeAll { Self.recordId($0) == file.id }
                root["printFiles"] = .array(rows)
            }
            // Out of the selection too, or the inspector keeps describing a
            // model that is gone.
            fileSelection.remove(file.id)
            await load(source)
            if allGone {
                importNote = words.callIt("plib.deleted")
            } else {
                importProblem = words.callIt("plib.delete_partial")
            }
        } catch {
            importProblem = String(describing: error)
        }
    }

    func directory(for file: LibraryFile) -> URL? {
        guard let roots = libraryRoots else { return nil }
        return LibraryLocation.directory(for: file.id, roots: roots.roots)
    }

    func fileIsPresent(_ file: LibraryFile) -> Bool { directory(for: file) != nil }

    /// The model file itself, if it is on this Mac.
    ///
    /// The record names it (`sourceFile.filename`), but a folder that has one
    /// model in it and a differently-named record is a state this app should
    /// survive rather than shrug at, so a single model file in the folder is
    /// taken as the model.
    func modelFile(for file: LibraryFile) -> URL? {
        guard let dir = directory(for: file) else { return nil }
        if let named = file.sourceFile?.filename, !named.isEmpty {
            let url = dir.appending(path: named)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil)) ?? []
        let models = contents.filter { !["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
        return models.count == 1 ? models[0] : nil
    }

    // MARK: - What a model is set up to print like

    /// The slicer's own settings for a model, once they have been read.
    ///
    /// Keyed by record id. `nil` means not read yet; a present entry holding
    /// `nil` facts means read and the file had nothing to say, which is a real
    /// answer and must not send the reader back to the disk on every redraw.
    private var factsByFile: [String: KhaytEngine.PrintFacts?] = [:]
    private var factsInFlight: Set<String> = []

    /// What the file says about how it prints, or nil until it has been read.
    ///
    /// READ FROM THE FILE, NOT FROM THE RECORD. These could have been captured
    /// at import and stored, and then every model imported before today would
    /// have none — and a model re-sliced for a different machine would keep
    /// saying what it used to be. The configs are two small members of the zip;
    /// finding them costs the central directory, not the 436 MB in front of it.
    /// Stand up a farm, for a snapshot that has no farm to photograph.
    ///
    /// A ten-printer shop is the case the band's compact density exists for, and
    /// nothing in this repo has ten printers — so without this the layout that
    /// only appears above four machines would ship having been reviewed by
    /// nobody. It is the same concession as `setReadingForTesting`: the runner
    /// cannot put nine more printers on this Mac's network.
    ///
    /// Copies the shop's own machines and the jobs on them, so the picture is of
    /// this app drawing real rows rather than of a fixture.
    func standUpFarmForSnapshot(_ n: Int) {
        guard !machines.isEmpty, machines.count < n else { return }
        var grown = machines
        var rows = machineRows
        var i = machines.count
        while grown.count < n, i < n {
            guard case .object(var row) = machineRows[i % machineRows.count] else { break }
            row["id"] = .string(String(format: "FARM-%02d", i + 1))
            row["name"] = .string(String(format: "Printer %02d", i + 1))
            let copy = JSONValue.object(row)
            // Decoded rather than copied field by field: a `Machine` built here
            // by hand would drift from the one the store produces the moment
            // anybody adds a field, and this is the only place that would not
            // notice.
            if let data = try? JSONEncoder().encode(copy),
               let machine = try? JSONDecoder().decode(Machine.self, from: data) {
                grown.append(machine)
                rows.append(copy)
            }
            i += 1
        }
        machines = grown
        machineRows = rows
    }

    /// The next `hours` on the machines.
    ///
    /// Recomputed rather than cached: it depends on the printers' answers and on
    /// the time, and a band that is five minutes stale draws its now-line in the
    /// wrong place — which is the one mark on it that has to be right.
    ///
    /// ── WHICH MACHINES GET A READING ───────────────────────────────────────
    ///
    /// Only the ones whose printer says it is PRINTING. A failed poll carries a
    /// `problem` and no status, so it is already absent — but an idle printer
    /// answers perfectly well with `progress: 0`, and a job still marked
    /// printing in the book against an idle machine would then be drawn as
    /// starting now and running its whole estimate. That is a confident picture
    /// of something that is not happening. Left out, the row says the end is
    /// unknown, which is true and is what a shop should go and look at.
    func machineBand(hours: Double = 48) async -> KhaytEngine.MachineBand? {
        guard let engine else { return nil }
        var live: [String: JSONValue] = [:]
        for (id, reading) in printers.readings {
            guard let status = reading.status, PrinterWatch.isPrinting(status.state) else { continue }
            var seen: [String: JSONValue] = ["progress": .number(Double(status.progress))]
            if let left = status.timeRemaining { seen["timeRemaining"] = .number(left) }
            live[id] = .object(seen)
        }
        return try? await engine.machineBand(machines: machineRows, orders: orderRows,
                                             inventory: inventoryRows, live: live,
                                             now: Date(), hours: hours)
    }

    /// What one machine is due for.
    ///
    /// Recomputed rather than cached, like the band: the hour meter climbs with
    /// every job that finishes, and a card still showing "40h remaining" after
    /// the meter passed it is the one thing this screen exists to prevent.
    ///
    /// Nil when the machine has no tasks at all, so the card can leave the
    /// section out entirely rather than drawing an empty heading — most shops
    /// have not set any up, and a permanent "No tasks" on every printer is
    /// noise on the screen a shop looks at most.
    func maintenance(for machine: Machine) async -> KhaytEngine.MaintenanceCard? {
        guard let engine, !maintTaskRows.isEmpty else { return nil }
        let card = try? await engine.maintenance(
            machineId: machine.id, tasks: maintTaskRows, jobs: orderRows,
            machine: .object(["id": .string(machine.id)]), now: Date())
        guard let card, !card.tasks.isEmpty else { return nil }
        return card
    }

    /// Record a task as done, at the meter's current reading.
    ///
    /// The patch is the shared rule's, not one assembled here — which fields a
    /// completion writes is part of the maintenance contract, and the Electron
    /// app reads these same records back.
    ///
    /// The hours written are the meter as it reads NOW, which is the whole
    /// point: the next interval is counted from this moment, and writing the
    /// figure the card happened to be showing would count any job that finished
    /// while the card was open twice.
    /// Move a service log written under the old key into the right one.
    ///
    /// ── WHY THIS RUNS AT ALL, AND WHY IT RUNS ONCE ────────────────────────
    ///
    /// A fix verified only on newly-created data strands what a shop already
    /// has. Alphas 21 through 23 wrote every repair into `hub_maint_log_v1`,
    /// which nothing reads, so those rows are a shop's own work sitting in a
    /// field that has no meaning. They are moved, not dropped.
    ///
    /// It is a no-op the second time: the stray key is removed by the same
    /// write, so there is nothing left to find.
    func rescueStrandedServiceLog(_ build: StoreReader.Build?) {
        guard let build, canWrite else { return }
        // Asked before writing, so an ordinary load of an ordinary book does
        // not open the store for writing at all.
        guard rawHasStrandedLog else { return }
        try? StoreWriter.update(build) { root in
            _ = ServiceLogEdit.rescueStranded(&root)
        }
    }

    /// Whether the book on disk still carries the old key. Read from the copy
    /// this load decoded, so it costs nothing.
    private(set) var rawHasStrandedLog = false

    func markMaintenanceDone(_ taskId: String, on machine: Machine) async {
        guard let engine, let build = source.build, canMoveJobs else { return }
        guard let task = maintTaskRows.first(where: {
            if case .object(let o) = $0, case .string(let id)? = o["id"] { return id == taskId }
            return false
        }) else { return }
        guard let card = try? await engine.maintenance(
            machineId: machine.id, tasks: maintTaskRows, jobs: orderRows,
            machine: .object(["id": .string(machine.id)]), now: Date()),
              let patch = try? await engine.markMaintenanceDone(
                task: task, hours: card.hours, at: Date())
        else { return }

        // What the task is called, for the line this writes in the log.
        var taskName = ""
        if case .object(let o) = task, case .string(let n)? = o["name"] { taskName = n }

        do {
            try StoreWriter.update(build) { root in
                guard case .array(var rows)? = root["machMaintTasks"] else { return }
                for i in rows.indices {
                    guard case .object(var record) = rows[i],
                          case .string(let id)? = record["id"], id == taskId else { continue }
                    for (key, value) in patch { record[key] = value }
                    // Without the stamp the other machine's older copy wins the
                    // next merge and the task goes back to overdue.
                    StoreWriter.stamp(&record)
                    rows[i] = .object(record)
                }
                root["machMaintTasks"] = .array(rows)

                // ── AND THE SERVICE ITSELF ────────────────────────────────
                //
                // The schedule says a nozzle is due; the log says one was
                // changed. Only the second is a history, and this app used to
                // write only the first — so a shop that did its servicing here
                // and read it in Khayt found no record of any of it, and the
                // maintenance figures totalled nothing however much work had
                // been done. The other app has always written both.
                //
                // At no cost. Marking a task done is one click and the shop is
                // standing at the machine, not holding a receipt; what it cost
                // is typed into the entry afterwards, which is also how Khayt
                // does it.
                var log: [JSONValue] = []
                if case .array(let had)? = root[ServiceLogEdit.collection] { log = had }
                var entry = ServiceLogEdit.entry(machineId: machine.id, day: Self.localDay(),
                                                 note: taskName, cost: 0,
                                                 id: Self.uid("MAINT"))
                StoreWriter.stamp(&entry)
                root[ServiceLogEdit.collection] = .array(ServiceLogEdit.appending(entry, to: log))
            }
            writeProblem = nil
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// The machine's hours meter, as the shared rule counts it.
    ///
    /// A new task is counted from this reading, so a schedule set up today does
    /// not open overdue on a printer that has been running for two years.
    private func machineHours(_ machineId: String) async -> Double {
        guard let engine else { return 0 }
        let card = try? await engine.maintenance(
            machineId: machineId, tasks: maintTaskRows, jobs: orderRows,
            machine: .object(["id": .string(machineId)]), now: Date())
        return card?.hours ?? 0
    }

    /// Set up a recurring maintenance task.
    ///
    /// The schedule half of maintenance, which this app could show and tick off
    /// but never write. A shop whose only app is this one had no way to create
    /// a task at all, so it had no schedule.
    func addMaintenanceTask(machineId: String, name: String,
                            intervalHours: Double, intervalDays: Double) async {
        writeProblem = nil
        guard let build = source.build, canMoveJobs else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        if let problem = MaintenanceTaskEdit.problem(name: name, intervalHours: intervalHours,
                                                     intervalDays: intervalDays) {
            writeProblem = words.callIt(problem); return
        }
        let hours = await machineHours(machineId)
        let record = MaintenanceTaskEdit.record(
            machineId: machineId, name: name, intervalHours: intervalHours,
            intervalDays: intervalDays, hours: hours,
            nowIso: StoreWriter.iso(Date()), id: Self.uid("MTASK"))
        do {
            try StoreWriter.update(build) { root in
                var rows: [JSONValue] = []
                if case .array(let had)? = root[MaintenanceTaskEdit.collection] { rows = had }
                var stamped = record
                StoreWriter.stamp(&stamped)
                rows.append(.object(stamped))
                root[MaintenanceTaskEdit.collection] = .array(rows)
            }
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// Change what a task is called and how often it comes round.
    ///
    /// Deliberately does NOT restamp when it was last done: changing "every 100
    /// hours" to "every 80" says something about the schedule, not that the work
    /// was just carried out. Restamping would quietly clear a task that is
    /// overdue at this moment.
    func editMaintenanceTask(_ taskId: String, name: String,
                             intervalHours: Double, intervalDays: Double) async {
        writeProblem = nil
        guard let build = source.build, canMoveJobs else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        if let problem = MaintenanceTaskEdit.problem(name: name, intervalHours: intervalHours,
                                                     intervalDays: intervalDays) {
            writeProblem = words.callIt(problem); return
        }
        do {
            try StoreWriter.update(build) { root in
                guard case .array(var rows)? = root[MaintenanceTaskEdit.collection] else { return }
                for i in rows.indices {
                    guard case .object(let task) = rows[i],
                          case .string(let id)? = task["id"], id == taskId else { continue }
                    var next = MaintenanceTaskEdit.edited(task, name: name,
                                                          intervalHours: intervalHours,
                                                          intervalDays: intervalDays)
                    // Without the stamp the other machine's older copy wins the
                    // next merge and the interval goes back.
                    StoreWriter.stamp(&next)
                    rows[i] = .object(next)
                }
                root[MaintenanceTaskEdit.collection] = .array(rows)
            }
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// Stop tracking a task. The services already logged against the machine
    /// stay: a schedule is a plan, and deleting a plan does not unmake the work.
    func deleteMaintenanceTask(_ taskId: String) async {
        writeProblem = nil
        guard let build = source.build, canMoveJobs else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        do {
            try StoreWriter.update(build) { root in
                guard case .array(let rows)? = root[MaintenanceTaskEdit.collection] else { return }
                root[MaintenanceTaskEdit.collection] =
                    .array(MaintenanceTaskEdit.removing(taskId, from: rows))
            }
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// Write down a service: what was done, when, and what it cost.
    ///
    /// The one thing this app could not record about its machines. A shop can
    /// see what its printers are due for and tick them off, and until now none
    /// of that reached the figures — because the figures come from this log and
    /// nothing here wrote to it.
    func addServiceEntry(machineId: String, date: Date, note: String, cost: Double,
                         alsoAnExpense: Bool) async {
        writeProblem = nil
        guard let build = source.build, canMoveJobs else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        let said = note.trimmingCharacters(in: .whitespaces)
        guard !said.isEmpty else {
            writeProblem = words.callIt("maint.need_note"); return
        }
        let day = Self.localDay(date)
        let paid = max(0, cost)
        let name = machines.first { $0.id == machineId }?.name ?? machineId
        do {
            try StoreWriter.update(build) { root in
                var log: [JSONValue] = []
                if case .array(let had)? = root[ServiceLogEdit.collection] { log = had }
                var entry = ServiceLogEdit.entry(machineId: machineId, day: day,
                                                 note: said, cost: paid,
                                                 id: Self.uid("MAINT"))
                StoreWriter.stamp(&entry)
                root[ServiceLogEdit.collection] = .array(ServiceLogEdit.appending(entry, to: log))

                // ── AND, IF ASKED, THE EXPENSE ────────────────────────────
                //
                // OPT IN, never automatic, and this is the reason: a machine's
                // profit already has its servicing subtracted from it, so a
                // shop that also books the repair as an expense has charged
                // itself twice. Which of the two a shop wants is a question
                // about how it keeps its books, so it is asked rather than
                // decided here — the other app asks it the same way.
                guard alsoAnExpense, paid > 0 else { return }
                var expenses: [JSONValue] = []
                if case .array(let had)? = root["expenses"] { expenses = had }
                var expense: [String: JSONValue] = [
                    "id": .string(Self.uid("EXP")),
                    "date": .string(day),
                    "category": .string("maintenance"),
                    "amount": .number(paid),
                    "note": .string("\(name): \(said)"),
                ]
                StoreWriter.stamp(&expense)
                expenses.insert(.object(expense), at: 0)
                root["expenses"] = .array(expenses)
            }
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// Take one service out of the log.
    ///
    /// The entry only. An expense written beside it is left alone: it is a
    /// record of money that left the shop, the shop's accountant may already
    /// have seen it, and deleting a line from a maintenance history is not a
    /// statement that the money was never spent.
    func deleteServiceEntry(_ entryId: String) async {
        writeProblem = nil
        guard let build = source.build, canMoveJobs else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        do {
            try StoreWriter.update(build) { root in
                guard case .array(let log)? = root[ServiceLogEdit.collection] else { return }
                root[ServiceLogEdit.collection] = .array(ServiceLogEdit.removing(entryId, from: log))
            }
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// Whether the shop's invoices have been reported to ZATCA.
    ///
    /// Recomputed rather than cached: it moves when a job completes and when
    /// the Electron app submits one, and a stale "not submitted" against an
    /// invoice that has been reported is worse than no answer at all.
    func zatcaReporting() async -> KhaytEngine.ZatcaReporting? {
        guard let engine else { return nil }
        return try? await engine.zatcaReporting(settings: settingsDict, orders: orderRows)
    }

    /// One print file's raw record, for the rules that read more of it than
    /// `LibraryFile` models.
    func row(for id: LibraryFile.ID) -> JSONValue? {
        fileRows.first {
            if case .object(let rec) = $0, case .string(let known)? = rec["id"] { return known == id }
            return false
        }
    }

    /// The files this print is made of.
    func parts(for id: LibraryFile.ID) async -> KhaytEngine.PrintParts? {
        guard let engine, let rec = row(for: id) else { return nil }
        return try? await engine.printParts(rec)
    }

    /// The settings this file is known to work at, and which to reach for.
    func setups(for id: LibraryFile.ID) async -> KhaytEngine.PrintSetups? {
        guard let engine, let rec = row(for: id) else { return nil }
        return try? await engine.printSetups(rec)
    }

    /// The alternatives this file exists as.
    func versions(for id: LibraryFile.ID) async -> KhaytEngine.PrintVersions? {
        guard let engine, let rec = row(for: id) else { return nil }
        return try? await engine.printVersions(rec)
    }

    /// Filaments in the bundled catalogue matching what has been typed.
    ///
    /// The catalogue is handed to the engine on first use rather than found by
    /// it: the file belongs to this target, and `AppResources` is what knows
    /// where this target's resources are.
    func filamentSearch(_ query: String, limit: Int = 8) async -> [KhaytEngine.FilamentHit] {
        guard let engine, query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        guard let json = AppResources.filamentCatalogJSON else { return [] }
        guard (try? await engine.useFilamentCatalog(json)) != nil else { return [] }
        return (try? await engine.filamentSearch(query, limit: limit)) ?? []
    }

    /// The spool fields a catalogue entry can speak for — and only those.
    func filamentFields(brand: String, name: String, colour: String,
                        weight: Double?) async -> [String: JSONValue] {
        guard let engine, let json = AppResources.filamentCatalogJSON else { return [:] }
        guard (try? await engine.useFilamentCatalog(json)) != nil else { return [:] }
        return (try? await engine.filamentAsSpool(brand: brand, name: name,
                                                  colour: colour, weight: weight)) ?? [:]
    }

    /// How old the bundled catalogue is, in days.
    func filamentCatalogAge() async -> Double? {
        guard let engine, let json = AppResources.filamentCatalogJSON else { return nil }
        guard (try? await engine.useFilamentCatalog(json)) != nil else { return nil }
        return (try? await engine.filamentCatalogAge()) ?? nil
    }

    /// The consumables worth ordering, most urgent first.
    ///
    /// Recomputed rather than cached: the rate is measured over a trailing
    /// window, so what is urgent changes as jobs finish even when nobody has
    /// touched the shelf.
    func consumableNeeds() async -> [KhaytEngine.ConsumableNeed] {
        guard let engine, !consumableRows.isEmpty else { return [] }
        return (try? await engine.consumableNeeds(
            consumables: consumableRows, orders: orderRows, now: Date())) ?? []
    }

    /// What that list was computed FROM.
    ///
    /// The shelf changes when stock moves; the rate changes when a job
    /// finishes. Counting the finished jobs is enough for the second — the
    /// window is trailing, so the answer moves when the set of jobs in it does.
    var consumableSignature: String {
        let shelf = consumableRows.compactMap { row -> String? in
            guard case .object(let c) = row, case .string(let id)? = c["id"] else { return nil }
            var have = "-"
            if case .number(let n)? = c["stock"] { have = String(n) }
            return id + ":" + have
        }
        let done = orderRows.reduce(into: 0) { total, row in
            if case .object(let job) = row, case .string(let state)? = job["status"],
               state == "completed" { total += 1 }
        }
        return "\(done)|" + shelf.sorted().joined(separator: ",")
    }

    /// What one machine's maintenance card was computed FROM.
    ///
    /// Same job as `bandSignature`: a `.task(id:)` needs something cheap that
    /// changes exactly when the answer would. That is the task records
    /// themselves — a completion rewrites `lastDoneHours` — and the hours this
    /// machine has run, because the meter climbing is what moves a task from
    /// ok to due without anybody touching it.
    func maintenanceSignature(for machine: Machine) -> String {
        var meter = 0.0
        for row in orderRows {
            guard case .object(let job) = row,
                  case .string(let on)? = job["machineId"], on == machine.id,
                  case .string(let state)? = job["status"], state == "completed",
                  case .number(let hours)? = job["printTime"] else { continue }
            meter += hours
        }
        let marks = maintTaskRows.compactMap { row -> String? in
            guard case .object(let task) = row,
                  case .string(let on)? = task["machineId"], on == machine.id,
                  case .string(let id)? = task["id"] else { return nil }
            var done = "-"
            if case .number(let h)? = task["lastDoneHours"] { done = String(h) }
            if case .string(let at)? = task["lastDoneAt"] { done += "@" + at }
            // ── AND WHAT THE TASK SAYS, NOT ONLY WHEN IT WAS LAST DONE ────
            //
            // The name and the intervals are here because they can now be
            // EDITED. While the schedule could only be written in the other
            // app, an id and a last-done stamp caught everything this app could
            // change; the moment it could rename a task or tighten an interval,
            // a signature blind to both meant the card carried on drawing the
            // old one until something unrelated moved.
            var says = ""
            if case .string(let name)? = task["name"] { says += name }
            if case .number(let h)? = task["intervalHours"] { says += "/h" + String(h) }
            if case .number(let d)? = task["intervalDays"] { says += "/d" + String(d) }
            return id + ":" + done + ":" + says
        }
        return "\(machine.id)|\(meter)|" + marks.sorted().joined(separator: ",")
    }

    /// What the band was computed FROM, as one string.
    ///
    /// A `.task(id:)` needs something cheap that changes exactly when the answer
    /// would. The readings change on every sweep and most sweeps change nothing,
    /// so this is the progress and the time left, which are the only two things
    /// the band reads out of a printer.
    var bandSignature: String {
        printers.readings.keys.sorted().map { id in
            guard let s = printers.readings[id]?.status, PrinterWatch.isPrinting(s.state) else { return "\(id):-" }
            return "\(id):\(s.progress):\(s.timeRemaining.map { String(Int($0 / 60)) } ?? "-")"
        }.joined(separator: "|")
    }

    func printFacts(for file: LibraryFile) -> KhaytEngine.PrintFacts? {
        if let known = factsByFile[file.id] { return known }
        loadPrintFacts(for: file)
        return nil
    }

    /// True once the answer is in, whatever the answer was. The inspector uses
    /// it to tell "still reading" from "this file says nothing".
    func printFactsAreIn(for file: LibraryFile) -> Bool { factsByFile[file.id] != nil }

    private func loadPrintFacts(for file: LibraryFile) {
        guard !factsInFlight.contains(file.id), let engine else { return }
        guard let url = modelFile(for: file),
              url.pathExtension.lowercased() == "3mf" else {
            factsByFile[file.id] = .some(nil)
            return
        }
        factsInFlight.insert(file.id)
        let id = file.id
        Task { [weak self] in
            // The zip is read off the main thread; the RULE runs on the engine's
            // own actor, which is where the one JavaScriptCore context lives.
            // What goes to a background thread is the file, not the interpreter.
            let configs = await Task.detached(priority: .userInitiated) {
                () -> (project: String, model: String, prusa: String)? in
                guard let entries = try? Zip.entries(of: url) else { return nil }
                func text(_ name: String) -> String {
                    guard let e = entries.first(where: { $0.name.lowercased() == name.lowercased() }),
                          let d = try? Zip.data(of: e, in: url) else { return "" }
                    return String(decoding: d, as: UTF8.self)
                }
                let project = text("Metadata/project_settings.config")
                let model = text("Metadata/model_settings.config")
                // Either spelling, depending on how old the PrusaSlicer was.
                var prusa = text("Metadata/Slic3r_PE.config")
                if prusa.isEmpty { prusa = text("Metadata/Prusa_Slicer.config") }
                if project.isEmpty && model.isEmpty && prusa.isEmpty { return nil }
                return (project, model, prusa)
            }.value
            guard let self else { return }
            self.factsInFlight.remove(id)
            guard let configs else { self.factsByFile[id] = .some(nil); return }
            self.factsByFile[id] = .some(try? await engine.printFacts(
                projectSettings: configs.project,
                modelSettings: configs.model,
                prusa: configs.prusa))
        }
    }

    /// A photograph the shop took beats a generated thumbnail: it is the print
    /// as it came off the bed, which is what someone is trying to recognise.
    func thumbnail(for file: LibraryFile) -> ThumbnailSource? {
        if let photo = file.userPhoto, photo.hasPrefix("data:") { return .inlineData(photo) }
        guard let dir = directory(for: file) else { return nil }
        let name = file.thumbFile ?? "thumb.jpg"
        let url = dir.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? .file(url) : nil
    }

    /// Does ANY job name a customer, or promise a date?
    ///
    /// The jobs table drops those columns when nothing in the book fills them:
    /// a shop whose work is auto-logged from its printers has neither, and a
    /// column of dashes is not a column. Asked of the whole book rather than of
    /// what is on screen, so filtering to one stage cannot make a column vanish
    /// and reappear as the shop types in the search box.
    var anyJobHasAClient: Bool { orders.contains { !$0.client.isEmpty } }
    var anyJobHasADueDate: Bool { orders.contains { !($0.dueDate ?? "").isEmpty } }

    /// The picture of what a job printed.
    ///
    /// A job is a row of text in a table of rows of text, and the shop is
    /// looking for the one it made last Tuesday. It already knows what that
    /// looked like — the model is in the library with a thumbnail — and the
    /// table was the only place not showing it.
    ///
    /// Only where the job SAYS which model it was: a job auto-logged from a
    /// printer's history knows a filename and nothing about the library, and
    /// guessing by name would eventually put the wrong picture on a job.
    /// Nothing rather than the wrong thing.
    func modelThumbnail(for job: Order) -> ThumbnailSource? {
        for part in job.parts {
            guard let id = part.printFileId,
                  let file = files.first(where: { $0.id == id }) else { continue }
            if let source = thumbnail(for: file) { return source }
        }
        return nil
    }

    /// The colours a job was printed in, as the shop wrote them down.
    ///
    /// Words, not swatches. "bone", "sand" and "natural" are a shop's own
    /// names for filament it owns, and nothing in Khayt maps a word to a
    /// colour — so a swatch here would be this app's guess at what "sand"
    /// looks like, painted next to a photograph of the real thing.
    func partColours(of job: Order) -> [String] {
        var seen = Set<String>()
        return job.parts.compactMap { part in
            let word = part.colour.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { return nil }
            return word
        }
    }

    /// What the shop is owed across everything still open. The one number an
    /// owner looks for, so it is on screen without being asked for.
    var owed: Double { orders.filter { !$0.isSettled }.reduce(0) { $0 + $1.owed } }
    var overdueCount: Int { orders.count { $0.isOverdue() } }

    var selected: Order? { orders.first { $0.id == selection } }
}
