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
    private(set) var machines: [Machine] = []
    private(set) var spools: [Spool] = []
    /// The shop's own record of its customers. Read from the `clients`
    /// collection, which this app did not open until it needed to point a new
    /// job at one.
    private(set) var clients: [Client] = []
    /// Wear per machine, keyed by id. `nozzleWear` answers for one machine at
    /// a time, so this is one call each — a handful of printers, not a table.
    private(set) var wear: [String: NozzleWear] = [:]
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

    var selection: Order.ID?
    var fileSelection: Set<LibraryFile.ID> = []
    var customerSelection: Customer.ID?
    var shelf: Shelf = .dashboard
    /// Opens the way Khayt opens. See `LibrarySort`.
    var librarySort: LibrarySort = .khayt
    var search = ""

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
                guard let url = Bundle.module.url(forResource: "sample-shop", withExtension: "json"),
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
            // AFTER the words, because the name is read in the shop's language.
            // It is `bizEn`/`bizAr`, the fields Khayt's own Settings page
            // writes and every document prints — not `shopName`, which nothing
            // in Khayt writes. Read as `shopName` for six weeks, this shop's
            // invoice would have been issued by "Khayt".
            shopName = await Self.shopName(from: Self.settings(root), engine: engine,
                                           language: words.language) ?? next.title(words)
            if case .array(let shelf)? = root["inventory"] { inventoryRows = shelf } else { inventoryRows = [] }
            if case .array(let jobs)? = root["printLog"] { orderRows = jobs } else { orderRows = [] }
            if case .array(let people)? = root["clients"] { clientRows = people } else { clientRows = [] }
            if case .array(let catalog)? = root["products"] { productRows = catalog } else { productRows = [] }
            catalogueRows = (try? await engine?.catalogue(
                productRows, language: words.language, settings: Self.settings(root))) ?? []
            if case .array(let fleet)? = root["machines"] { machineRows = fleet } else { machineRows = [] }
            clients = Self.decodeClients(root)
            clientNames = (try? await engine?.customerNames(
                clientRows, language: words.language, settings: Self.settings(root))) ?? [:]
            await keepTheDaysBackup()
            expenses = Self.decode(root, "expenses", as: Expense.self)
            giftCards = Self.decode(root, "giftCards", as: GiftCard.self)
            fits = await Self.measureFit(files, machines: machineRows, engine: engine)
            lowSpools = (try? await engine?.lowStock(inventoryRows, settings: settingsDict)) ?? [:]
            spoolRunway = (try? await engine?.runway(spools: inventoryRows, orders: orderRows,
                                                     now: Date())) ?? [:]
            spoolDryness = (try? await engine?.dryness(spools: inventoryRows, now: Date())) ?? [:]
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
            // The status of each, from the shared rule rather than a Swift
            // comparison of two date strings — asked once for all of them,
            // because the table redraws on every keystroke in the search box.
            giftCardRows = (root["giftCards"].flatMap { if case .array(let r) = $0 { r } else { nil } }) ?? []
            giftCardStatuses = (try? await engine?.giftCardStatuses(
                giftCardRows, today: Self.today())) ?? [:]
            wasteLog = Self.decode(root, "wasteLog", as: WasteEntry.self)
            if case .array(let rows)? = root["expenses"] { expenseRows = rows } else { expenseRows = [] }
            if case .array(let rows)? = root["wasteLog"] { wasteRows = rows } else { wasteRows = [] }
            readSnapshots(root)
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
            if next.build != nil { printers.start(shop: self) } else { printers.stop() }
            // The shop's published delivery dates. Not for the sample book,
            // whose cloud settings belong to nobody.
            if next.build != nil { startPublishingLeadTime() } else { stopPublishingLeadTime() }
            refreshSyncStatus()
            await readSlicers()
        } catch {
            orders = []
            files = []
            machines = []
            spools = []
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
        facts = try? await engine.dashboardFacts(orders: orders, machines: machines, settings: settings,
                                                 statusCache: printers.statusCache,
                                                 inventory: shelf)
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
        previewing = url
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
    private func partFor(spoolId: String?, grams: Double, hours: Double, qty: Int) -> JSONValue {
        var part: [String: JSONValue] = [
            "printWeight": .number(max(0, grams)),
            "printTime": .number(max(0, hours)),
            "qty": .number(Double(max(1, qty))),
        ]
        if let spoolId, let spool = spools.first(where: { $0.id == spoolId }) {
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
    func costedPart(spoolId: String?, grams: Double, hours: Double, qty: Int,
                    machineId: String? = nil) async -> KhaytEngine.CostedPart? {
        guard let engine else { return nil }
        return try? await engine.costPart(partFor(spoolId: spoolId, grams: grams,
                                                  hours: hours, qty: qty),
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

    /// What the cart comes to, before anything is written.
    ///
    /// The same `quoteTotal` the record will use, so the figure on the screen is
    /// the figure in the book.
    func previewQuote(baseCost: Double, margin: Double, discountPct: Double,
                      shippingCost: Double, rush: Bool) async -> QuoteTotal? {
        guard let engine else { return nil }
        var input: [String: JSONValue] = [
            "baseCost": .number(baseCost), "qty": .number(1),
            "margin": .number(margin), "discountPct": .number(discountPct),
            "shippingCost": .number(shippingCost),
            "rushEnabled": .bool(rush), "business": .bool(true),
        ]
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
                     deposit: Double, rush: Bool, asQuote: Bool) -> [String: JSONValue] {
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
        return input
    }

    /// The shelf and the settings, as the shared modules take them.
    ///
    /// The RAW rows, not this app's decoded `Spool` re-encoded: the cost model
    /// reads `materialType` to tell resin from filament, and `Spool` does not
    /// carry it. Re-encoding would silently cost every resin part as if it were
    /// filament.
    private(set) var inventoryRows: [JSONValue] = []

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
    func editJob(_ id: Order.ID, dueDate: Date?, priorityLevel: String) async {
        await writeToOneOrder(id, named: words.callIt("mac.edit_job")) { order, engine, _ in
            let out = try await engine.editJob(
                order: order,
                dueDate: dueDate.map(Self.localDay),
                priorityLevel: priorityLevel,
                now: Date(), editId: Self.uid("edit"))
            // Nothing moved: return the order untouched so the write path finds
            // no change, stamps nothing and syncs nothing.
            return OneOrderEdit(order: out.order)
        }
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
    func inPeriod(_ date: String, now: Date = Date()) -> Bool {
        Self.inPeriod(date, period: period, now: now)
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

    /// Ask the shared scheduler where the unassigned work should go.
    ///
    /// Reads only. `lib/scheduling.js` writes nothing and neither does this;
    /// `applySchedule` is the one that touches the book.
    func proposeSchedule() async {
        scheduleProblem = nil
        scheduleApplied = nil
        schedulePlan = nil
        guard let engine else {
            scheduleProblem = words.callIt("mac.move_no_engine"); return
        }
        let waiting = schedulableRows
        guard !waiting.isEmpty else {
            scheduleProblem = words.callIt("sched.none_to_assign"); return
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
        panel.allowedContentTypes = LibraryImport.kinds.compactMap {
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
    static func modelsUnder(_ chosen: [URL], skipping root: String?) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
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
                       !isInVault(next) { found.append(next) }
                }
            } else if LibraryImport.kinds.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        // Sorted so a run is repeatable and a person watching can follow it.
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
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

        let files = Self.modelsUnder(chosen, skipping: roots.primary)
        guard !files.isEmpty else {
            importProblem = words.callIt("mac.import_nothing"); return
        }

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
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        converting = true
        defer { converting = false }
        var options: [String: JSONValue] = [:]
        if let targetId { options["targetId"] = .string(targetId) }
        else { options["mode"] = .string("normalize") }

        do {
            _ = try await Converter.convert(source, into: destination,
                                            options: options, engine: engine)
            convertNote = words.callIt("mac.converted", [
                "name": .string(destination.lastPathComponent),
                "target": .string(target?.name ?? words.callIt("mac.standard_3mf")),
            ])
        } catch let refusal as Converter.Failure {
            convertProblem = refusal.description
        } catch {
            convertProblem = String(describing: error)
        }
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
        if to == .completed && Stage.of(job) == .qc { return { self.pendingQC = subject } }
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

    func clearQuestion() {
        pendingHold = nil
        pendingQC = nil
        pendingPayment = nil
        pendingEdit = nil
        pendingQcFail = nil
        pendingInvoice = nil
    }

    /// Whether a job may be moved at all: a real book, held by this app, with
    /// the shared rules running. The sample shop is for looking at.
    var canMoveJobs: Bool { source.isReal && ownership != nil }

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
    func moveJob(_ id: Order.ID, to stage: Stage,
                 holdReason: String? = nil, qcNotes: String? = nil) async {
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
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                (undoSnapshot, said, telegram) = try await Self.applyMove(
                    to: &root, id: id, stage: stage, engine: engine, words: self.words,
                    holdReason: holdReason, qcNotes: qcNotes)
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
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch {
            moveProblem = String(describing: error)
        }
    }

    /// Send what the shop's bot has to say, and say so if it could not.
    ///
    /// Not fatal: the job IS finished, the book says so, and undoing a correct
    /// write because a message did not go out would be the wrong trade. The
    /// shop is told, and can send it by hand.
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
    static func applyMove(to root: inout [String: JSONValue],
                                  id: Order.ID, stage: Stage,
                                  engine: KhaytEngine, words: Words,
                                  holdReason: String? = nil, qcNotes: String? = nil)
    async throws -> (undo: [ChangedRecord], notices: [String], telegram: TelegramMessage?) {

        let orders = rows(root, "printLog")
        let inventory = rows(root, "inventory")
        let consumables = rows(root, "consumables")
        let machines = rows(root, "machines")
        let clients = rows(root, "clients")
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }

        guard let target = orders.first(where: { recordId($0) == id }) else {
            throw MoveRefused(sentence: words.callIt("mac.move_gone"))
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
        let cannotSend = reaches.filter { $0.channel != "telegram" }
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

        var undo: [ChangedRecord] = []
        write(&root, "printLog", changed: [.object(changedOrder)], before: orders, into: &undo)
        write(&root, "inventory", changed: move.inventory ?? [], before: inventory, into: &undo)
        write(&root, "consumables", changed: move.consumables ?? [], before: consumables, into: &undo)

        if let text = move.activity {
            appendActivity(&root, text: text, ref: id, settings: settings, root: root)
        }

        let notices = (move.notices ?? []).map { words.sentence(for: $0) }
        return (undo, notices, telegram)
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
        return matching(rows)
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

    var shownFiles: [LibraryFile] {
        var rows = files
        if case .library(let group) = shelf, let group {
            rows = rows.filter { $0.groupName == group }
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
    /// Which machine each model fits, keyed by the model's id. Worked out once
    /// when the book loads rather than per row: a grid of four hundred models
    /// asking the runtime on every redraw is four hundred context hops.
    private(set) var fits: [String: KhaytEngine.Fit] = [:]
    /// The cards the shop has issued, and what each one is today.
    private(set) var giftCards: [GiftCard] = []
    private(set) var giftCardRows: [JSONValue] = []
    private(set) var giftCardStatuses: [String: String] = [:]
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
