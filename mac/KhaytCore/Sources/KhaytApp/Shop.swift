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

    /// The library on screen, patched in place by a library edit
    /// (`Shop+LibraryWrites.swift`) rather than by reloading the whole book.
    /// Only ever the book's own records: a put-aside model stays in here.
    func showLibraryFiles(_ next: [LibraryFile]) { files = next }

    /// Show the models that have been put aside. Off: they are still there.
    var libraryShowArchived = false {
        didSet { if libraryShowArchived != oldValue { pruneSelectionToVisible() } }
    }

    /// How many are hidden right now, so the library can offer to show them
    /// rather than leave a shop wondering where a model went.
    var archivedCount: Int { files.count { $0.isArchived } }
    var machines: [Machine] = []
    private(set) var spools: [Spool] = []
    /// The other shelf, decoded for drawing. `consumableRows` stays the raw
    /// truth the rules are handed; this is what the screen lists.
    private(set) var consumables: [Consumable] = []
    /// The shop's own record of its customers. Read from the `clients`
    /// collection, which this app did not open until it needed to point a new
    /// job at one.
    private(set) var clients: [Client] = []
    /// Wear per machine, keyed by id. `nozzleWear` answers for one machine at
    /// a time, so this is one call each — a handful of printers, not a table.
    private(set) var wear: [String: NozzleWear] = [:]
    /// What each machine with depreciation set is worth, keyed by id —
    /// `lib/depreciation.js`, worked out once per load beside the wear above.
    /// Absent for a machine without it.
    private(set) var machineValue: [String: KhaytEngine.MachineValue] = [:]

    /// What each machine has actually printed a month, lately — the figure a
    /// straight-line machine's hourly wear rate and P&L share lean on when the
    /// shop has not typed its own.
    var recentMonthlyHours: [String: Double] {
        machineValue.compactMapValues { $0.recentMonthlyHours }
    }

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
    /// Moving the library to another folder — see `LibraryMove`.
    var libraryMoveBusy = false
    var libraryMoveNote: String?
    var libraryMoveProblem: String?
    var libraryMoveProgress: (done: Int, total: Int, name: String)?
    /// The print library in the cloud — see `CloudLibrary`.
    var cloudLibraryNote: String?
    /// The Google sign-in page while a Connect is waiting for it, so the
    /// Settings pane can offer to open or copy it.
    var googleSignInURL: URL?
    /// The Connect in progress, so Cancel can stop it — see `cancelGoogleSignIn`.
    var googleSignInTask: Task<Void, Never>?
    var cloudLibraryProblem: String?
    var cloudLibraryBusy = false
    var cloudProgress: (done: Int, total: Int, name: String)?
    /// Models moved off this Mac whose online copy is no longer there — see
    /// `verifyCloudCopies`. Said on every screen until it is empty.
    var cloudMissing: [MissingCopy] = []
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
    var settingsValue: JSONValue = .object([:])

    /// Give a shop a mail provider, for a test. The book on disk is not
    /// touched — `pretendMode`'s sibling, and there for the same reason.
    ///
    /// The email settings pane is four different screens depending on this one
    /// field, and `SnapshotTests` has to photograph all four. Building a book
    /// on disk per picture would be photographing `StoreWriter`.
    func pretendEmailConfig(_ config: [String: JSONValue]) {
        var held: [String: JSONValue] = settingsDict
        held["emailConfig"] = .object(config)
        settingsValue = .object(held)
    }

    /// Whether this launch has already sent the low-stock warning.
    ///
    /// ── ONCE PER LAUNCH, WHICH IS WHAT THE OTHER APP DOES ─────────────────
    ///
    /// `checkTelegramLowStock` runs when the renderer loads and sends if
    /// anything is low — so a shop that opens the app twice is told twice, and
    /// that is the behaviour shops already have. This app loads the book far
    /// more often than it launches (every save re-reads it), so sending on
    /// every load would turn one warning into a stream of them.
    ///
    /// A flag rather than a stored timestamp: what is on disk syncs, and a
    /// shop with two Macs would have one of them deciding the other had
    /// already warned.
    private var lowStockWarned = false

    /// Tell the shop its filament is running out, if it asked to be told.
    ///
    /// The decision is entirely the shared rule's — which spools count as low
    /// and whether there is a bot to tell — so this app cannot come to a
    /// different conclusion from the shelf badges beside it.
    private func warnAboutLowStock(_ spools: [JSONValue],
                                   settings: [String: JSONValue]) async {
        guard !lowStockWarned, let engine else { return }
        guard let warning = try? await engine.lowStockWarning(spools, settings: settings) else {
            return
        }
        // Set BEFORE the send, not after: a send that fails is still an
        // attempt, and retrying it on the next of this launch's many loads is
        // how a shop with an unreachable bot gets a hundred of them.
        lowStockWarned = true
        do {
            let token = try await Secrets.open(warning.botToken, for: source)
            try await Telegram.send(botToken: token, chatId: warning.chatId,
                                    message: warning.message)
        } catch {
            // NOT shown to the shop. Nothing was asked for and nothing is
            // waiting on it — unlike a move, which is refused when it cannot
            // reach somebody. A banner about a warning nobody requested is
            // itself the interruption it is warning about.
            FileHandle.standardError.write(Data(
                "low-stock telegram failed: \(RedactedError.describe(error))\n".utf8))
        }
    }

    /// Send one printer alert to the shop's Telegram and ntfy, as its switches
    /// say (`lib/alert-routes.js`). NOT awaited by anyone and NOT shown when it
    /// fails — like the low-stock warning, nothing is waiting on it — but
    /// logged, and the last ntfy failure is kept for the settings pane.
    func sendAlert(type: String, title: String, body: String) async {
        guard let engine, source.build != nil,
              let routes = try? await engine.alertRoutes(type: type, settings: settingsDict) else { return }
        if routes.telegram, case .object(let tg)? = settingsDict["telegram"],
           case .string(let sealed)? = tg["botToken"], case .string(let chat)? = tg["chatId"] {
            do {
                let token = try await Secrets.open(sealed, for: source)
                try await Telegram.send(botToken: token, chatId: chat, message: title + "\n" + body)
            } catch {
                FileHandle.standardError.write(Data("printer alert telegram failed: \(RedactedError.describe(error))\n".utf8))
            }
        }
        if routes.ntfy {
            do { try await sendNtfy(type: type, title: title, body: body) }
            catch {
                // Shown in the shop's own settings pane, where the address is
                // theirs to see; the LOG gets the kind of failure only.
                ntfyProblem = String(describing: error)
                FileHandle.standardError.write(Data("printer alert ntfy failed: \(RedactedError.describe(error))\n".utf8))
            }
        }
    }

    /// The last ntfy send that failed, for the settings pane.
    var ntfyProblem: String?

    /// One ntfy push. The Test button and the alerts both come here.
    func sendNtfy(type: String, title: String, body: String) async throws {
        guard let engine,
              let request = try await engine.ntfyRequest(type: type, title: title, body: body, settings: settingsDict)
        else { throw Ntfy.Failure.badAddress }
        var token = ""
        if case .object(let n)? = settingsDict["ntfy"], case .string(let sealed)? = n["token"], !sealed.isEmpty {
            token = try await Secrets.open(sealed, for: source)
        }
        try await Ntfy.send(request, token: token)
        ntfyProblem = nil
    }

    /// Give a shop some monthly costs, for a test.
    func pretendFixedCosts(_ rows: [JSONValue]) {
        var held: [String: JSONValue] = settingsDict
        held["fixedCosts"] = .array(rows)
        settingsValue = .object(held)
    }

    /// Give a shop a Telegram bot, for a test. `pretendEmailConfig`'s sibling.
    func pretendTelegram(_ config: [String: JSONValue]) {
        var held: [String: JSONValue] = settingsDict
        held["telegram"] = .object(config)
        settingsValue = .object(held)
    }

    /// Give the shop a `printLibrary` block, or none, for a picture of the
    /// online storage pane. The book on disk is not touched.
    func pretendPrintLibrary(_ library: [String: JSONValue]?) {
        var held: [String: JSONValue] = settingsDict
        if let library { held["printLibrary"] = .object(library) } else { held.removeValue(forKey: "printLibrary") }
        settingsValue = .object(held)
    }

    /// Give the shop a library, for a test. The book on disk is not touched.
    func pretendLibrary(_ rows: [JSONValue]) {
        files = Self.decodeFiles(["printFiles": .array(rows)]).items
        clearLibrarySelection()
    }

    /// Give the library's groups their kinds, for a test. The book on disk is
    /// not touched. See `GroupKind`.
    func pretendGroupKinds(_ kinds: [String: GroupKind]) {
        libraryGroupKinds = kinds
        pruneSelectionToVisible()
    }

    /// Put a shop into a mode, for a test. The book on disk is not touched.
    func pretendMode(_ mode: String?) {
        var held: [String: JSONValue] = settingsDict
        if let mode { held["mode"] = .string(mode) } else { held.removeValue(forKey: "mode") }
        settingsValue = .object(held)
    }

    var selection: Order.ID?
    var fileSelection: Set<LibraryFile.ID> = [] {
        // One kind of selection at a time: choosing a model — click, ⌘A, an
        // arrow — lets go of any chosen group tiles, so no action is ever
        // offered for a mixture of the two.
        didSet { if !fileSelection.isEmpty, !groupSelection.isEmpty { groupSelection = []; groupAnchor = nil } }
    }
    /// Group tiles chosen with ⌘/⇧-click, by PATH — for "Move into Group…".
    /// Apart from `fileSelection` on purpose: a selected group tile is a
    /// group, never the models hidden inside it (#1691). See
    /// `LibraryGroupMove.swift`.
    var groupSelection: Set<String> = []
    /// Where a ⇧-click run of group tiles started.
    var groupAnchor: String?
    /// The move or rename the shop has asked for, until it confirms.
    var movingGroups: GroupMoveRequest?
    /// Set by the model's right-click "New Group…": a context menu cannot
    /// hold a text field, so it asks the toolbar's Group menu to open its
    /// naming popover over the same selection.
    var namingGroup = false
    /// The model the shop has asked to delete, until it confirms or backs out.
    /// A question in the window's `WindowSheets`, so both shells can ask it.
    var pendingLibraryDelete: LibraryFile?
    /// Several models chosen for deletion at once; asked about in one go.
    var pendingLibraryDeletes: [LibraryFile] = []
    /// What deleting the models in the open question would do — what stays
    /// online, what goes for good (`LibraryDelete`). Nil while it is worked out.
    var deletePlan: LibraryDeletePlan?
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
            // A selection belongs to the view it was made in. Carried into
            // another folder — or out of one — it holds models that are not on
            // the screen, and a right-click on the one that is offers to act
            // on all of them. That is how a shop lost a 34-model group to a
            // delete it never chose (27 Sep 2026).
            clearLibrarySelection()
            if case .library = shelf { recountLibrarySoon() }
            else if case .library = oldValue { recountLibrarySoon() }
        }
    }
    /// Opens the way Khayt opens. See `LibrarySort`.
    var librarySort: LibrarySort = .added
    /// Typed into the search box. The chips count what the search leaves, so
    /// they follow it — the other app's catalogue does the same, and a chip
    /// saying seven over a searched list of two is the bug its note describes.
    var search = "" {
        didSet {
            guard search != oldValue else { return }
            if case .library = shelf { recountLibrarySoon(); pruneSelectionToVisible() }
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
    /// Walk the selection around the board with the arrow keys.
    ///
    /// The board had no keyboard at all — the library was the only screen in
    /// the app that did, and a board is a screen people use with one hand
    /// while holding a part in the other.
    ///
    /// ARROWS NAVIGATE, ⌘ARROWS MOVE. The Job menu's ⌘→ sends the job one step
    /// along the way work goes; a bare arrow only changes which card is
    /// selected. Two different verbs, and the modifier is the difference.
    ///
    /// `dx` walks the COLUMNS and `dy` the cards within one. A column change
    /// keeps the row where it can and lands on the last card where it cannot,
    /// so walking right across a short column does not silently jump to the
    /// top. Returns false at the edges, so the system beep still means "there
    /// is nothing that way" rather than the app swallowing the key.
    @discardableResult
    func moveBoardSelection(dx: Int, dy: Int) -> Bool {
        let columns = Stage.boardColumns
        let filled = columns.map { board[$0] ?? [] }
        guard filled.contains(where: { !$0.isEmpty }) else { return false }

        // Nothing selected yet: the first press picks an end rather than
        // doing nothing, which is how the library behaves.
        guard let id = selection,
              let here = filled.firstIndex(where: { $0.contains { $0.id == id } }),
              let row = filled[here].firstIndex(where: { $0.id == id })
        else {
            selection = filled.first { !$0.isEmpty }?.first?.id
            return selection != nil
        }

        if dy != 0 {
            let next = row + dy
            guard next >= 0, next < filled[here].count else { return false }
            selection = filled[here][next].id
            return true
        }

        // Skip empty columns rather than stopping at them: a board with seven
        // columns and three in use would otherwise need three presses to cross
        // an empty one, and the shop cannot see why it stopped.
        var column = here + dx
        while column >= 0, column < filled.count, filled[column].isEmpty { column += dx }
        guard column >= 0, column < filled.count else { return false }
        selection = filled[column][min(row, filled[column].count - 1)].id
        return true
    }

    var board: [Stage: [Order]] {
        var out: [Stage: [Order]] = [:]
        // The search box is one box for the whole window. A board that ignored
        // it left somebody typing a customer's name into a field that visibly
        // did nothing.
        // And the site, when the shop is looking at one (SiteFilter.swift).
        for order in matching(orders) where inSite(order) {
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
    var engine: KhaytEngine?

    /// The day a test pinned with `load(_:asOf:)`, or nil for the real
    /// calendar. The period filter and the masthead's month read it, so a book
    /// rebased to a pinned day is also READ on that day — on the 1st of a
    /// month the rebased sample has nothing in "this month" otherwise, and
    /// every test that looks at this month failed on the calendar, not code.
    private(set) var clock: Date?

    /// Which `load` is the latest. A real book is read off the main thread
    /// now, so two loads can be in flight at once — and the one that started
    /// first must not finish last and put the older book on screen.
    private(set) var loadGeneration = 0

    /// TESTS ONLY: run between a load's read of the book and its use of it,
    /// so a test can land a library write in exactly that gap. Nothing in
    /// the app sets it.
    static var afterBookReadForTests: (@MainActor () async -> Void)?
    /// TESTS ONLY: run once a load has put its models up and is about to do
    /// the seconds of work after — where a newer load can overtake it.
    static var whileLoadingForTests: (@MainActor () async -> Void)?
    /// TESTS ONLY: run after a load has worked out every model's figures and
    /// before it puts them up, so a test can land a library edit in that gap.
    static var whileFiguringForTests: (@MainActor () async -> Void)?

    /// Library edits on screen and not yet written (`Shop+LibraryWrites`).
    @ObservationIgnored var pendingLibraryChanges: [PendingLibraryChange] = []
    @ObservationIgnored var pendingLibraryToken = 0
    /// The latest library write on screen (`LibraryWritten.sequence`).
    @ObservationIgnored var libraryShownSequence = 0
    /// The library as that write left it, before any pending edit is drawn.
    @ObservationIgnored var libraryShownRows: [JSONValue] = []
    /// Moved by every load's read and every library write put on screen, so
    /// a load still working can tell its rows are no longer the newest.
    @ObservationIgnored var libraryEpoch = 0
    /// Library writes started and not yet waited for (`settleLibraryWrites`).
    @ObservationIgnored var libraryWrites: [Int: Task<LibraryUndo?, Never>] = [:]
    var now: Date { clock ?? Date() }

    init(source: Source = .sample) {
        self.source = source
    }

    /// `asOf` is the day the book is read on. It defaults to today and is only
    /// ever passed by `SampleBookAgesTests`, which loads the sample book on
    /// days nobody has lived through to prove it cannot age out of the case the
    /// screens are built against. Everything the day reaches — the rebasing of
    /// the sample's dates, and the projection that reads them — takes it from
    /// here, so the two cannot be asked about different days.
    func load(_ next: Source, asOf pinned: Date? = nil) async {
        let day = pinned ?? Date()
        clock = pinned
        // ANOTHER BOOK: its staff are not this one's. Closed until its levels
        // are read (`lockReady`), and nobody signed in. A reload of the same
        // book keeps both — every write reloads, and a sign-in screen flashing
        // after each would be the lock punishing the person it let in.
        if source != next { lockReady = false; lockSessionId = nil }
        source = next
        problem = nil
        skipped = []
        loadGeneration += 1
        let generation = loadGeneration
        // ── OVERTAKEN, IT STOPS — AND PUTS NOTHING MORE ON SCREEN ─────────
        //
        // A load that a newer one has overtaken used to carry on through
        // every await below and set what it found there — orders, customers,
        // fits, licences — from the OLDER book, over what the newer load had
        // already put up, whichever finished last. So after every await this
        // asks whether it is still the newest, and an older load stops there:
        // the newer one is putting up everything, and it read the newer book.
        // Each figure worked out across an await is held in a local and
        // assigned only after that check, never assigned and then checked.
        // (`OvertakenLoadTests`.)
        func overtaken() -> Bool { generation != loadGeneration }
        do {
            let root: [String: JSONValue]
            var library: (items: [LibraryFile], skipped: [String])?
            // The library write on screen when this book was read. Moved on
            // by the time the rows below are taken, a write has landed in
            // between, and its rows are the newer ones.
            var readMark = libraryEpoch
            switch next {
            case .sample:
                guard let url = AppResources.bundle.url(forResource: "sample-shop", withExtension: "json"),
                      let data = try? Data(contentsOf: url) else {
                    throw Failure.missingSample
                }
                // Moved to sit where it sat the day it was written — see
                // `SampleBook`. A fixed book and a moving calendar drift
                // apart, and the screens that draw the difference between
                // today and a due date are the ones that lose their case.
                root = SampleBook.rebased(
                    try JSONValue.decode([String: JSONValue].self, from: data),
                    to: day)
            case .store(let build):
                // ── OFF THE MAIN THREAD ──────────────────────────────────
                //
                // A shop's book of 9,802 models is 15 MB; decoding it, and
                // then its library into `LibraryFile`s, held the main thread
                // for seconds on every reload — and every write reloads, so
                // deleting one model froze the window (`LibraryEditPerfTests`).
                //
                // ── A READ OLDER THAN A WRITE ALREADY ON SCREEN ──────────
                //
                // The read is not on the write chain, so a library edit can
                // land, and be put on screen (`showLibraryWritten`), while
                // this read of the book from BEFORE it is still decoding.
                // Shown after it, that book put the deleted model back on
                // screen, or took the star off again, with nothing pending
                // to correct it. So each read notes, on the chain, how many
                // library writes it already holds; one older than what is on
                // screen is read again.
                var read: (root: [String: JSONValue], files: [LibraryFile], skipped: [String], holds: Int)
                var tries = 0
                repeat {
                    read = try await BookWork.run { () throws -> ([String: JSONValue], [LibraryFile], [String], Int) in
                        let holds = StoreWriter.serialised { LibraryWritten.current }
                        let raw = try StoreReader(build: build).raw
                        let files = Self.decodeFiles(raw)
                        return (raw, files.items, files.skipped, holds)
                    }
                    if let hook = Self.afterBookReadForTests { await hook() }
                    // A later load started while this one was reading: it has
                    // the newer book, and it will put everything on screen.
                    guard generation == loadGeneration else { return }
                    tries += 1
                } while read.holds < libraryShownSequence && tries < 10
                root = read.root
                library = (items: read.files, skipped: read.skipped)
                // This book is now the library on screen: a write it already
                // holds, heard late, patches from THIS, never from older rows.
                libraryShownSequence = max(libraryShownSequence, read.holds)
            }
            // ── THE NEWEST LIBRARY WINS, WHICHEVER LOAD FINISHES LAST ────
            //
            // The generation guard above stops a load whose READ finished
            // after a newer load began. It cannot stop one that read first
            // and is still in the seconds of work below when a newer load
            // (or a library write) puts a newer library up — and that older
            // load then took its rows at the end and drew the older library:
            // a scan's models gone again, a star off (the flaky
            // `quickEditsInARow`, under load). So every read and every write
            // put on screen moves `libraryEpoch`, and the rows below come
            // from this read only while it is still the newest.
            libraryShownRows = Self.rows(root, "printFiles")
            libraryEpoch += 1
            readMark = libraryEpoch
            let decoded = try Self.decodeOrders(root)
            orders = decoded.items
            skipped = decoded.skipped
            machines = Self.decode(root, "machines", as: Machine.self)
            spools = Self.decode(root, "inventory", as: Spool.self)
            consumables = Self.decode(root, "consumables", as: Consumable.self)
            let decodedFiles = library ?? Self.decodeFiles(root)
            files = decodedFiles.items
            skipped += decodedFiles.skipped
            // In the same breath, not after the seconds of work below: a
            // model being deleted must not reappear (and be choosable) for
            // the length of a reload.
            reapplyPendingLibraryChanges()
            libraryGroupKinds = GroupKinds.read(Self.settings(root))
            libraryGroupCovers = GroupKinds.covers(Self.settings(root))
            if let hook = Self.whileLoadingForTests { await hook() }
            if overtaken() { return }
            libraryRoots = next.build.map { build in
                LibraryLocation.resolveRoots(settings: Self.librarySettings(root),
                                             defaultRoot: LibraryLocation.defaultRoot(for: build))
            }
            fileSelection = []
            groupSelection = []
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
            if overtaken() { return }
            // A library write that landed during the await above has put the
            // newer settings (group kinds, covers) on screen already.
            if libraryEpoch == readMark { settingsValue = root["settings"] ?? .object([:]) }
            await readFeatures()
            if overtaken() { return }
            // A shop that has just switched to Simple must not be left looking
            // at a screen that is no longer theirs.
            if shelf == .reports, !has("analytics") { shelf = .dashboard }
            if !canShow(shelf) { shelf = .dashboard }
            if shelf == .expenses, !has("expenses") { shelf = .dashboard }
            lanBook = Self.lanBook(from: root)
            pricingBook = Self.pricingBook(from: root)
            await syncLanServer()
            if overtaken() { return }
            // AFTER the words, because the name is read in the shop's language.
            // It is `bizEn`/`bizAr`, the fields Khayt's own Settings page
            // writes and every document prints — not `shopName`, which nothing
            // in Khayt writes. Read as `shopName` for six weeks, this shop's
            // invoice would have been issued by "Khayt".
            let named = await Self.shopName(from: Self.settings(root), engine: engine,
                                            language: words.language)
            if overtaken() { return }
            shopName = named ?? next.title(words)
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
            locationRows = Self.rows(root, "locations")
            operatorRows = Self.rows(root, "operators")
            timeEntryRows = Self.rows(root, "timeEntries")
            await refreshLock()
            if overtaken() { return }
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
            let suspect = (try? await engine?.suspectOrders(purchaseOrderRows,
                                                           inventory: inventoryRows)) ?? []
            if overtaken() { return }
            suspectOrders = suspect
            if case .array(let saved)? = root["printers"] { presetRows = saved } else { presetRows = [] }
            // The print files as written. `files` above is the decoded model;
            // this is what the setups and versions rules read, which is a wider
            // set of fields than the model carries.
            if libraryEpoch != readMark {
                // A library write landed during the work above: its rows
                // are newer than this read's (`readMark`).
                fileRows = libraryShownRows
            } else if case .array(let library)? = root["printFiles"] {
                fileRows = library
            } else {
                fileRows = []
            }
            if case .array(let jobs)? = root["printLog"] { orderRows = jobs } else { orderRows = [] }
            if case .array(let people)? = root["clients"] { clientRows = people } else { clientRows = [] }
            if case .array(let catalog)? = root["products"] { productRows = catalog } else { productRows = [] }
            // A live web store follows the catalogue: see `webStoreFollow`.
            // Which book this is comes FIRST: a different book forgets the last
            // one's store before anything is compared, and a re-read of the
            // same book forgets nothing (see `webStoreBookRead`).
            let anotherStore = webStoreBookRead(next.build?.storeURL)
            webStoreFollow(products: productRows, settings: Self.settings(root))
            let catalogued = (try? await engine?.catalogue(
                productRows, language: words.language, settings: Self.settings(root))) ?? []
            if overtaken() { return }
            catalogueRows = catalogued
            productCategories = Dictionary(uniqueKeysWithValues: productRows.compactMap { row in
                guard case .object(let p) = row, case .string(let id)? = p["id"] else { return nil }
                if case .string(let c)? = p["category"] { return (id, c) }
                return (id, "")
            })
            await readCatalogueFacets()
            if overtaken() { return }
            let languages = await Self.catalogueLanguages(Self.settings(root), engine: engine)
            if overtaken() { return }
            catalogueLanguages = languages
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
            let names = (try? await engine?.customerNames(
                clientRows, language: words.language, settings: Self.settings(root))) ?? [:]
            if overtaken() { return }
            clientNames = names
            await keepTheDaysBackup()
            if overtaken() { return }
            expenses = Self.decode(root, "expenses", as: Expense.self)
            giftCards = Self.decode(root, "giftCards", as: GiftCard.self)
            // EVERY MODEL'S FIGURES — which machine it fits, what it would
            // weigh and take, what its licence permits, what its stored
            // overhang summary says — in batches, not one engine call per
            // model (`LoadFigures`), and put up together, once, only if this
            // is still the newest load. Re-judged on every load rather than
            // cached with the verdict, because the nozzle and the plate come
            // from the machines and those change.
            let figured = files
            let worked = await LoadFigures.work(
                .init(files: figured, machines: machineRows, settings: Self.settings(root),
                      orders: orderRows, nozzle: nozzleForRisk),
                engine: engine, wanted: { generation == self.loadGeneration })
            if let hook = Self.whileFiguringForTests { await hook() }
            guard let worked, !overtaken() else { return }
            // A library edit that landed while they were worked out (a licence
            // set, a model re-measured) has put its own figures up for the
            // models it touched (`showLibraryWritten`), from the newer record.
            // Those are kept, never put back as the older record had them.
            let figures = files == figured ? worked : LoadFigures.settle(
                worked, figured: figured, now: files,
                shown: ModelFigures(fits: fits, estimates: estimates, licences: licences, risks: risks))
            fits = figures.fits
            estimates = figures.estimates
            licences = figures.licences
            // Merged, as `judge` always did one model at a time: a summary
            // the rule could not judge keeps the report it had.
            risks.merge(figures.risks) { _, new in new }
            let when = try? await engine?.riskWhen(settings: Self.settings(root))
            if overtaken() { return }
            riskWhen = when
            let low = Set(((try? await engine?.lowStock(inventoryRows, settings: settingsDict)) ?? [:])
                .filter(\.value).keys)
            if overtaken() { return }
            lowSpools = low
            await warnAboutLowStock(inventoryRows, settings: Self.settings(root))
            if overtaken() { return }
            let runway = (try? await engine?.runway(spools: inventoryRows, orders: orderRows,
                                                    now: Date())) ?? [:]
            if overtaken() { return }
            spoolRunway = runway
            let dryness = (try? await engine?.dryness(spools: inventoryRows, now: Date())) ?? [:]
            if overtaken() { return }
            spoolDryness = dryness
            let projected = await Self.project(orders: orders, engine: engine,
                                               settings: settingsDict, on: day)
            if overtaken() { return }
            timeline = projected
            // Once per book rather than per right-click: the list is twenty-two
            // fixed entries and a context menu is built while a grid draws.
            let profiles = (try? await engine?.printerProfiles()) ?? []
            if overtaken() { return }
            printerProfiles = profiles
            // What kind each machine is, resolved once per book. Read in view
            // bodies, so a hop into JavaScript per machine per redraw would be
            // a hop for a constant.
            let kinds = (try? await engine?.machineKinds(machineRows)) ?? [:]
            if overtaken() { return }
            machineKinds = kinds
            // And what each shelf row is counted in. Same reason: read in view
            // bodies, and a constant per item per redraw is a hop for nothing.
            let units = (try? await engine?.inventoryUnits(
                inventoryRows, settings: settingsDict)) ?? [:]
            if overtaken() { return }
            inventoryUnits = units
            // The library's own chips, counted once per book for the same
            // reason as everything above it: the grid redraws on every
            // keystroke in the search box, and a hop into JavaScript per chip
            // per redraw is a hop for a constant.
            if libraryEpoch != readMark {
                libraryRows = libraryShownRows
            } else if case .array(let rows)? = root["printFiles"] {
                libraryRows = rows
            } else {
                libraryRows = []
            }
            // A library edit still being written stays on screen as asked,
            // not as the book held it a moment before (`Shop+LibraryWrites`).
            libraryShownRows = libraryRows
            reapplyPendingLibraryChanges()
            await readLibraryFacets()
            if overtaken() { return }
            // And the names those chips can be filed under, which is the whole
            // book rather than what the chips are currently counting.
            await readLibraryNames()
            if overtaken() { return }
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
            let erased = (try? await engine?.erasedDeposits(orders: orderRows)) ?? []
            if overtaken() { return }
            erasedDeposits = erased

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
            let owing = (try? await engine?.billsOwing(purchaseOrderRows)) ?? []
            if overtaken() { return }
            unsettledRows = owing
            let toOrder = (try? await engine?.needsOrdering(
                spools: inventoryRows, consumables: consumableRows, orders: orderRows,
                purchaseOrders: purchaseOrderRows, settings: settingsDict,
                now: Date())) ?? []
            if overtaken() { return }
            needsOrdering = toOrder
            // What one plate holds, from the packer rather than from a number
            // typed twice in Swift.
            let plate = try? await engine?.plateDefaults()
            if overtaken() { return }
            if let limits = plate {
                batchMaxHours = limits.maxHours
                batchMaxGrams = limits.maxGrams
            }
            let cardStatuses = (try? await engine?.giftCardStatuses(
                giftCardRows, today: Self.today())) ?? [:]
            if overtaken() { return }
            giftCardStatuses = cardStatuses
            wasteLog = Self.decode(root, "wasteLog", as: WasteEntry.self)
            if case .array(let rows)? = root["expenses"] { expenseRows = rows } else { expenseRows = [] }
            if case .array(let rows)? = root["wasteLog"] { wasteRows = rows } else { wasteRows = [] }
            readSnapshots(root)
            // AFTER `orderRows` is read, which it groups. A kit is several
            // print-log entries that are one physical object, and the rollup
            // is asked for here rather than in the view so that a table
            // redrawing on every keystroke does not cross into JavaScript.
            await readKits(root)
            if overtaken() { return }
            // Whether the shop has agreed to the assistant drafting a quote.
            // Asked of the shared rule — it reads the master switch, the
            // per-feature answer AND the consent migration, and a Swift copy
            // would be a fourth place for those three to disagree on the one
            // question that decides whether data leaves the building.
            let aiFeatures = (try? await engine?.aiFeatures(settings: Self.settings(root))) ?? []
            if overtaken() { return }
            aiQuoteAllowed = aiFeatures.first { $0.id == "quote" }?.enabled ?? false
            aiAssistantAllowed = aiFeatures.first { $0.id == "assistant" }?.enabled ?? false
            aiReplyAllowed = aiFeatures.first { $0.id == "reply" }?.enabled ?? false
            aiPriceAllowed = aiFeatures.first { $0.id == "price" }?.enabled ?? false
            aiLibraryAllowed = aiFeatures.first { $0.id == "library" }?.enabled ?? false
            aiPicturesAllowed = aiFeatures.first { $0.id == "pictures" }?.enabled ?? false
            let tax = await describeTax(root["settings"])
            if overtaken() { return }
            taxSummary = tax
            await readSettingsTables(root)
            if overtaken() { return }
            // What each job still owes is `order-money`'s answer, not a
            // subtraction — a credit note and a gift card both pay an order
            // down, and the title bar, the customers table and the card all
            // read this number. AFTER the settings tables: the rule resolves an
            // order's currency against them, and a book whose rows had not been
            // read yet would price a foreign job against the previous shop's.
            await resolveOwed(root)
            if overtaken() { return }
            // AFTER the catalogue, the jobs, the expenses and the settings
            // tables: it ranks the first by what the rest say they earned.
            await readProfitPerHour()
            if overtaken() { return }
            await computeDashboard(root)
            if overtaken() { return }
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
            if next.build != nil { startWatchingPlugs() } else { stopWatchingPlugs() }
            // The web store's paid orders in, and their progress back out.
            // Not for the sample, whose cloud belongs to nobody.
            if next.build != nil { startWatchingWebStoreOrders() } else { stopWatchingWebStoreOrders() }
            if next.build != nil { await restoreCloudKey() }
            if overtaken() { return }
            // After the key: the launch check seals with it. Never for the
            // sample shop, which is not a book anybody wants back.
            if next.build != nil { startOffsiteBackups() } else { stopOffsiteBackups() }
            // NOT `resetWebStore()` here. It ran on every load, so it cancelled
            // the republish `webStoreFollow` had scheduled a moment earlier in
            // this same load and forgot the store was live: a live store never
            // followed a single change. A different book was already forgotten
            // above; the same book keeps its store, and is asked about it again
            // only when nothing is known.
            if next.build != nil, anotherStore || webStoreLive == nil {
                Task { await self.refreshWebStore() }
            }
            refreshSyncStatus()
            // Move a service log a Mac alpha wrote under the wrong key. Inside
            // the write chain, because anything that reads and writes the store
            // outside it races whatever is in flight — and only for a real
            // book, which is the only kind that can have one.
            rescueStrandedServiceLog(next.build)
            // COUNTED, never repaired, on open: see `applySpoolRepair`. A
            // write here re-priced every product on a spool whose size changed,
            // without the shop seeing a single new price.
            spoolRepairPending = next.build != nil
                ? Self.spoolRepairCount(products: productRows, sizes: spoolSizes) : 0
            // What sync took and nobody has reviewed, from the copies on
            // disk — a relaunch does not count as having looked.
            reloadSyncLosses(for: next.build)
            await readSlicers()
            if overtaken() { return }
            remeasureIfDue()
            createRecurringIfDue()
            readProvenanceIfDue()
            readSlicerFiguresIfDue()
            rescanLinkedIfDue()
            rescanStorageIfDue()
            // Beside the standing orders, which is the same kind of thing: a
            // write the shop asked to have made for it. After the book has
            // loaded, because it reads what is already on order to decide.
            await autoDraftIfAsked()
            if overtaken() { return }
            // The library, in this Mac's own search. Compares before it works,
            // so a book that reloads unchanged costs one string comparison —
            // and takes the library back OUT when the sample is opened.
            Spotlight.shared.reindex(shop: self)
            // A model chosen in Spotlight before the book was open.
            answerPendingReveal()
            // What the chosen site shows, worked out again: the book may have
            // gained a job, moved a machine, or lost the site itself.
            await refreshSiteScope()
        } catch {
            // An older load's failure is not the newer book's: the newer load
            // is putting that up, and blanking the screen over it would show
            // an open book as one that would not open.
            if overtaken() { return }
            siteScope = nil
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
            consumables = []
            messageTemplates = []
            wear = [:]
            machineValue = [:]
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
        await publishLivePrinters()
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
        // Only `load` asks, and an answer about a book a newer load has
        // replaced is dropped rather than painted onto the newer rows.
        let ticket = loadGeneration
        let rows: [JSONValue]
        if case .array(let jobs)? = root["printLog"] { rows = jobs } else { rows = [] }
        let clients: [JSONValue]
        if case .array(let people)? = root["clients"] { clients = people } else { clients = [] }
        guard let owed = try? await engine.owedByOrder(
            rows, settings: Self.settings(root), clients: clients,
            currencies: Invoice.currencyTable(self)), ticket == loadGeneration else { return }
        for i in orders.indices {
            if let amount = owed[orders[i].id] { orders[i].owedResolved = amount }
        }
        // Kept whole, not just on the rows: `payment-reminder` asks what each
        // order still owes, converted, and this is the converted answer.
        owedByOrderId = owed
        // And each job's figures in its OWN currency, for the rows that print
        // money beside the job's currency mark — owed, billed, and the price
        // net of tax a margin is worked on. Same crossing pattern: once a load.
        let figures = try? await engine.orderFigures(rows, settings: Self.settings(root), clients: clients)
        guard ticket == loadGeneration else { return }
        if let figures {
            for i in orders.indices { orders[i].figures = figures[orders[i].id] }
        }
        await resolveLate(root)
    }

    /// Ask the attention engine which jobs are late, and put it on the rows.
    ///
    /// The same answer the dashboard's Late tile already showed, so the badges
    /// and the count stop being two numbers about one book.
    private func resolveLate(_ root: [String: JSONValue]) async {
        guard let engine else { return }
        let ticket = loadGeneration
        let rows: [JSONValue]
        if case .array(let jobs)? = root["printLog"] { rows = jobs } else { rows = [] }
        let fleet: [JSONValue]
        if case .array(let m)? = root["machines"] { fleet = m } else { fleet = [] }
        guard let late = try? await engine.lateOrders(
            rows, machines: fleet, settings: Self.settings(root)), ticket == loadGeneration else { return }
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
        // Only `load` asks: an answer about a book a newer load has replaced
        // is dropped, never put over the newer book's (see `load`).
        let ticket = loadGeneration
        let dashboard = try? await engine.dashboardFacts(orders: orders, machines: machines,
                                                         settings: settings,
                                                         statusCache: printers.statusCache,
                                                         inventory: shelf)
        guard ticket == loadGeneration else { return }
        facts = dashboard
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
        // What each machine is worth, BEFORE the month's row: a straight-line
        // machine's share of the month leans on its recent hours.
        let values = (try? await engine.machineValues(machines: machines, orders: orders,
                                                      today: Self.today(now))) ?? [:]
        guard ticket == loadGeneration else { return }
        machineValue = values
        let month = await Self.thisMonthsRow(
            engine: engine, orders: orders, expenses: expenses,
            settings: settings, clients: clients, currencies: Invoice.currencyTable(self),
            wasteLog: Self.rows(root, "wasteLog"), inventory: Self.rows(root, "inventory"),
            machines: machines, recentMonthlyHours: recentMonthlyHours,
            timeEntries: Self.rows(root, "timeEntries"), now: now)
        guard ticket == loadGeneration else { return }
        monthNetRevenue = month?.revenue
        // The masthead's NET is the P&L's net income for the month — revenue
        // less cost of goods, expenses and overhead, filament bought counted
        // as stock — read off the SAME row Reports prints. It was the revenue
        // net of tax, which on a month of 50.00 billed and 35.91 of material
        // put "NET 50.00" beside Reports' "NET INCOME 14.09".
        monthNetIncome = month?.net
        monthGrossRevenue = month.map { $0.revenue + $0.vatCollected }
        // The masthead's cost figure, off the same row: Reports' "Cost of
        // goods sold" for this month, so the two screens name one figure
        // one way.
        monthCostOfGoods = month.map(\.cogsValue)
        var perMachine: [String: NozzleWear] = [:]
        for machine in machines {
            guard case .object(let record) = machine,
                  case .string(let id)? = record["id"] else { continue }
            if let w = try? await engine.nozzleWear(orders: orders, machine: machine, settings: settings) {
                perMachine[id] = w
            }
        }
        guard ticket == loadGeneration else { return }
        wear = perMachine
        // What to chase. Both selectors are off unless the shop has switched
        // them on, and both return nothing on a book with no due dates — so
        // the section they feed simply does not appear.
        let invoices = (try? await engine.invoicesToChase(
            orders: orders, settings: settings, owed: owedByOrderId)) ?? []
        guard ticket == loadGeneration else { return }
        invoicesToChase = invoices
        let quotes = (try? await engine.quotesToChase(orders: orders, settings: settings)) ?? []
        guard ticket == loadGeneration else { return }
        quotesToChase = quotes
        let monthKpis = try? await engine.kpis(orders: orders, clients: clients,
                                               settings: settings, range: "month",
                                               language: words.language,
                                               inventory: Self.rows(root, "inventory"),
                                               consumables: Self.rows(root, "consumables"))
        guard ticket == loadGeneration else { return }
        thisMonthRevenue = monthKpis?.revenue ?? 0
        kpiOrders = orders
        kpiClients = clients
        kpiSettings = settings
        await recomputeKpis()
        guard ticket == loadGeneration else { return }
        // Six whole months and what the next one looks like. Not part of
        // `recomputeKpis`: that one changes with the period buttons, and the
        // trend deliberately does not — it is the same six months whichever
        // period the tiles above are showing.
        let ahead = try? await engine.revenueOutlook(orders: orders, clients: clients,
                                                     settings: settings,
                                                     now: Date().timeIntervalSince1970 * 1000)
        guard ticket == loadGeneration else { return }
        outlook = ahead
    }

    /// The shop's last six months of takings, and next month on that evidence.
    private(set) var outlook: KhaytEngine.RevenueOutlook?

    var kpiOrders: [JSONValue] = []
    private var kpiClients: [JSONValue] = []
    var kpiSettings: [String: JSONValue] = [:]

    /// One call for the whole period. Changing the range does not re-read the
    /// book — the orders are already here; only the arithmetic changes.
    private func recomputeKpis() async {
        guard let engine, !kpiOrders.isEmpty else { kpis = nil; return }
        // A load that began meanwhile works these out again from its own book.
        let ticket = loadGeneration
        let answer = try? await engine.kpis(orders: kpiOrders, clients: kpiClients,
                                            settings: kpiSettings, range: kpiRange,
                                            language: words.language, inventory: inventoryRows,
                                            consumables: consumableRows)
        guard ticket == loadGeneration else { return }
        kpis = answer
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
                guard let kept = StoreLock.beat(held, for: build) else {
                    // The other app took the book. Stop writing and say so,
                    // rather than take it back and have two apps save over
                    // each other.
                    self.ownership = nil
                    self.moveNotices.append(self.words.callIt("mac.lock_lost"))
                    return
                }
                self.ownership = kept
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

    // Stored for "Measuring the library again" (Shop+Library.swift).
    /// Which books this process has already checked. Once per book per launch:
    /// the pass reads every due 3MF and marks it, so the next launch finds
    /// nothing due — and a book whose write was refused is simply due again.
    var remeasuredBooks: Set<String> = []
    /// The same once-per-book-per-launch guard, for the provenance read.
    var provenanceReadBooks: Set<String> = []
    /// The pass in flight, so a quit — or a test — can wait for it.
    var remeasuring: Task<Void, Never>?

    /// The books whose linked folders this launch has already rescanned.
    var linkedScannedBooks: Set<String> = []
    /// That pass in flight, so the storage pass can wait its turn.
    var linkedScan: Task<Void, Never>?
    /// Whether a linked file is kept online only — `LinkedCloud.isOnlineOnly`.
    /// A test hands in its own: a dataless placeholder cannot be made in one,
    /// and a scan of ten thousand "local" files reads every one of them.
    var linkedIsOnline: @Sendable (URL) -> Bool = { LinkedCloud.isOnlineOnly($0) }
    /// The books whose own library folder this launch has already looked through.
    var storageScannedBooks: Set<String> = []
    /// That pass in flight, so Stop can cancel it.
    var storageScan: Task<Void, Never>?
    /// The Stop of the linked or storage scan running now; nil when none is.
    /// What the Stop buttons show on — a library MOVE has no Stop, because a
    /// move half-done is a library in two places. See `ScanStop`.
    var libraryScanStop: ScanStop? { didSet { libraryScanStopping = false } }
    /// Stop has been pressed and the scan is finishing the file it is on —
    /// observed, so the button greys at once (the flag itself is not).
    var libraryScanStopping = false
    /// Books whose scan the shop stopped this launch: the load-time passes
    /// do not start again by themselves on them.
    var libraryScanStoppedBooks: Set<String> = []

    /// The books whose slicer figures this launch has already read.
    var slicerFiguresReadBooks: Set<String> = []

    // Stored for "Standing orders" (Shop+Customers.swift).
    /// The books whose standing orders this launch has already made.
    var recurringBooks: Set<String> = []

    // Stored for "What a customer has agreed to pay" (Shop+Library.swift).
    /// The model the window is showing a Quick Look of, or nil.
    ///
    /// Set it and the panel opens; Quick Look puts it back to nil when the
    /// panel is dismissed, which is why this is a plain var rather than
    /// something with a close method.
    var previewing: URL?

    var groupNote: GroupNote?

    /// The library's group kinds, by path, as the book's settings hold them.
    /// See `GroupKind`.
    internal(set) var libraryGroupKinds: [String: GroupKind] = [:]
    /// The pictures the shop chose for its groups, by path. See `GroupCover`.
    internal(set) var libraryGroupCovers: [String: GroupCover] = [:]

    /// The Mac's undo stack, handed over by the window.
    ///
    /// Weak: it belongs to the window, and a Shop outliving one must not keep
    /// it alive. Nil is a supported state — the environment says so when a
    /// context has no undo — and every registration below is guarded.
    weak var undoManager: UndoManager?

    // Stored for "Moving a job" (Shop+Jobs.swift).
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

    /// The finished jobs the shop's printers still remember.
    ///
    /// Khayt freezes a print's filament and duration on the edge out of
    /// printing — the counters are per-job and reset when the next one starts —
    /// and persists them here. This app does not poll into that cache yet, so a
    /// shop running only this one gets an honest "nothing measured" and a shop
    /// running both gets the measurement.
    private(set) var printerCompletions: JSONValue = .object([:])
    /// The printer watch froze a finished job: what the sheet offers now.
    func completionsFrozen(_ merged: JSONValue) { printerCompletions = merged }

    var pendingCompletion: PendingCompletion?

    /// The customer being written down, or edited.
    var editingCustomer: Client?

    var catalogueFacets = CatalogueFacets()

    var catalogueCategory: FilterChoice? { didSet { recountCatalogueSoon() } }
    var catalogueMaterial: FilterChoice? { didSet { recountCatalogueSoon() } }
    /// Products with no price at all.
    var catalogueUnpricedOnly = false { didSet { recountCatalogueSoon() } }

    /// A row's category, which the catalogue row does not carry: it is the
    /// product's own field, read from the record the row was built from.
    var productCategories: [String: String] = [:]

    /// The same race as `libraryRecount`, for the same reason.
    var catalogueRecount = 0

    var catalogueRecountTask: Task<Void, Never>?

    // Stored for "Finding a printer" (Shop+Printers.swift).
    /// True while the find-printers sheet is up.
    var findingPrinters = false

    let finder = PrinterFinder()

    // Stored for "What a model would cost" (Shop+Library.swift).
    /// An estimate per model, worked out once when the book loads.
    ///
    /// Not per redraw: the calibration reads the whole print log, and a grid of
    /// four hundred models asking for that on every frame is four hundred trips
    /// through the runtime for one number that cannot have changed.
    internal(set) var estimates: [String: KhaytEngine.MeshEstimate] = [:]

    // Stored for "A printer that changed address" (Shop+Printers.swift).
    /// Machines whose address appears to have moved, and where to.
    var relocations: [KhaytEngine.Relocation] = []
    var relocateProblem: String?
    var relocateNote: String?
    /// True while the network is being asked where a quiet machine went.
    var lookingForMoved = false
    /// True while the subnets are being asked, which is the slow half and
    /// worth saying: mDNS answers instantly and a sweep takes seconds.
    var sweeping = false

    // Stored for "Telling a printer what to do" (Shop+Printers.swift).
    /// What went wrong the last time a machine was told something, by machine.
    /// Per machine rather than one banner: a shop with eight printers needs to
    /// know WHICH one refused.
    var printerProblem: [String: String] = [:]
    /// Machines with a command in flight, so the buttons can say so and cannot
    /// be pressed twice.
    var printerBusy: Set<String> = []

    /// A job this app is about to cancel, held for the confirmation.
    ///
    /// Cancelling throws away however many hours are already in the plate, and
    /// no printer asks twice. Pause and resume go straight through — they are
    /// each other's undo.
    var confirmingCancel: Machine?

    /// The machine whose plate is being looked at, for dropping one object.
    var droppingFrom: Machine?

    // Stored for "Sending a file to a printer" (Shop+Printers.swift).
    /// The job a file is being sent for, while the Send sheet is open.
    var pendingSend: PendingHold?
    /// What the last send said, beside the button that made it.
    var sendNote: String?

    // Stored for "What to run next" (Shop+Jobs.swift).
    /// The dispatcher's answer, recomputed when the book or the printers move.
    var dispatch: KhaytEngine.DispatchPlan?

    /// Machines the shop has held back from the dispatcher, this session.
    ///
    /// Not written to the book: "do not send this one work for the next hour"
    /// is a fact about today, and a flag that outlived the reason for it is
    /// worse than no flag.
    var dispatchHeld: Set<String> = []

    // Stored for "Writing a product down" (Shop+Catalogue.swift).
    /// The product being edited, or nil. Drives the sheet, as the customer's does.
    var editingProduct: Product?
    /// Why a product could not be made from a model, when it could not.
    var productProblem: String?
    /// What the file could not answer for — said rather than left as zeros.
    var productNote: String?

    /// One entry per language the shop's catalogue carries: the code, its name
    /// in its own script, and the two record keys it owns.
    ///
    /// Asked of the engine rather than assumed, because `fieldKey` is the rule
    /// that decides `nameEn` vs `name_de` and there must not be a second copy
    /// of it in Swift. Resolved once per book — every field in the sheet asks.
    private(set) var catalogueLanguages: [Product.LanguageKey] = []

    // Stored for "Taking a job from something the shop already makes" (Shop+Jobs.swift).
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

    // Stored for "Selling a piece off the shelf" (Shop+Catalogue.swift).
    /// Whether the shop has agreed to price advice, on this book.
    private(set) var aiPriceAllowed = false

    // Stored for "Sort linked folders" (Shop+LinkedSort.swift).
    /// Whether the shop has agreed to its assistant sorting linked folders
    /// by their names, on this book.
    private(set) var aiLibraryAllowed = false
    /// Whether the shop has agreed to "Check pictures" — its OWN switch,
    /// apart from sorting linked folders.
    private(set) var aiPicturesAllowed = false
    /// The assistant is being asked about the linked folders right now.
    var librarySortAsking = false
    /// What sorting the linked folders would do, while the sheet is open.
    var sortPreview: SortPreview?

    // Stored for "Drafting a message to a customer" (Shop+Messages.swift).
    /// Whether the shop has agreed to message drafting, on this book.
    private(set) var aiReplyAllowed = false

    /// The job a message is being drafted about, while the sheet is up.
    var draftingFor: Order?

    /// The job whose customer is being written to from a saved message.
    var messagingFor: Order?

    /// The shop's own saved messages, in the order it keeps them.
    private(set) var messageTemplates: [MessageTemplate] = []

    // Stored for "Asking about the book" (Shop+Messages.swift).
    /// Whether the shop has agreed to the assistant, on this book.
    private(set) var aiAssistantAllowed = false

    /// True while the ask-the-book sheet is up.
    var askingTheBook = false

    var asked: [AskedTurn] = []
    var asking = false

    // Stored for "Drafting a quote from a description" (Shop+Messages.swift).
    private(set) var aiQuoteAllowed = false

    // Stored for "Taking a job" (Shop+Jobs.swift).
    /// True while the new-job sheet is up.
    var takingAJob = false

    /// The job this app just created, so the table can select it.
    var lastCreated: Order.ID?

    // Stored for "A marketplace's cut" (Shop+Money.swift).
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

    /// `printFiles` as written. See `setups(for:)` and `versions(for:)`.
    internal(set) var fileRows: [JSONValue] = []

    /// The book as the LAN server's shared pages read it — `printLog`,
    /// `waitingList`, `settings` and `machines`, raw. See `LanServer`.
    ///
    /// It is also what `/api/store` hands a paired phone, so what is in it is
    /// the phone's contract — which is why the pricing inputs below are a
    /// separate book rather than two more collections in this one.
    private(set) var lanBook: [String: JSONValue] = [:]
    /// What a price is computed from: `settings`, the printer presets
    /// (`printers`), the shelf (`inventory`) and `printLog`, whose recorded
    /// actuals calibrate the estimator.
    ///
    /// THE LAN ESTIMATE PRICED NOTHING WITHOUT IT. `publicQuote` finds the
    /// preset in `store.printers` and the filament in `store.inventory`, and
    /// the server was handed `lanBook`, which has neither — so on a real shop
    /// every upload came back "not configured". The tests never saw it: their
    /// bench put `printers` straight into the server's book.
    private(set) var pricingBook: [String: JSONValue] = [:]

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
    var features: Set<String> = []

    // Stored for "Money received" (Shop+Money.swift).
    /// The job waiting for someone to say what was paid.
    var pendingPayment: PendingHold?
    /// A job being handed to a carrier, or a parcel being updated by hand.
    var pendingShipment: PendingHold?

    /// The job being edited.
    var pendingEdit: PendingHold?

    // Stored for "What the shop has on order" (Shop+Stock.swift).
    /// Purchase orders, as the book holds them.
    private(set) var purchaseOrderRows: [JSONValue] = []

    /// The shop's suppliers, with whatever they quote.
    private(set) var supplierRows: [JSONValue] = []

    /// The shop's sites (`store.locations`), as the book holds them. Read raw:
    /// the location P&L hands them to `lib/location-pl.js`, and every field a
    /// record carries — `rev`, `updatedAt`, an address — has to survive an
    /// edit made here.
    private(set) var locationRows: [JSONValue] = []

    /// The shop's staff (`store.operators`), raw: a record carries fields this
    /// app never shows — `pinHash`, `roleKey` set by the other app's lock —
    /// and every one of them has to survive an edit made here.
    var operatorRows: [JSONValue] = []

    /// Hours the staff logged against jobs (`store.timeEntries`), raw.
    private(set) var timeEntryRows: [JSONValue] = []

    /// Who is signed in on THIS Mac, by operator id — nil is nobody.
    ///
    /// Memory only, and deliberately not `settings.activeOperatorId`: that one
    /// is in the book, the other app writes it, and a field in the book is a
    /// field any copy of the book can set. Nobody signs in here by editing a
    /// file somewhere else. Gone on quit, so a relaunch asks again.
    var lockSessionId: String? {
        // EVERY change of who is at this Mac drops what the last person could
        // undo: an owner who demoted somebody and pressed Lock left an Undo
        // that put the old access level back for whoever walked up
        // (alpha.62 review). Undo is the person's, not the Mac's.
        didSet {
            guard lockSessionId != oldValue else { return }
            undoManager?.removeAllActions()
            // And every sheet or dialog the last person had open: a sheet
            // stays on screen over the sign-in screen otherwise, half filled
            // in, for whoever walks up (alpha.62 re-check).
            dismissEverySheet()
        }
    }
    /// `lib/rbac.js`'s matrix, read from the engine with the book.
    var rbac: KhaytEngine.Rbac?
    /// True once the matrix and every operator's level have been read for the
    /// book on screen. Until then a switched-on lock refuses everything: the
    /// first load published the operators before their levels were read, and
    /// for that moment the lock was not "in force" — open (alpha.62 review).
    var lockReady = false
    /// Each operator's access level under the lock: `roleKey`, else the
    /// shared `roleFromLegacy` with the lock on.
    var lockRoles: [String: String] = [:]

    /// Where this Mac keeps the wrong-PIN record. `.standard` in the app; a
    /// test gives each shop its own, so two tests never share a count.
    var lockDefaults: UserDefaults = .standard

    /// What is low and has not already been ordered.
    private(set) var needsOrdering: [KhaytEngine.ToOrder] = []

    /// Orders asking for about a thousand times what they should.
    private(set) var suspectOrders: [KhaytEngine.SuspectOrder] = []

    /// The order being received, or nil.
    var receivingGoods: PurchaseOrder?

    private(set) var unsettledRows: [JSONValue] = []

    // Stored for "Drafting what is low, without being asked" (Shop+Stock.swift).
    /// How many orders the last automatic draft made, until it is read.
    ///
    /// SAID, not silent. The other app drafts on boot and shows a toast; this
    /// app writes to the shop's book the same way and owes it the same
    /// sentence. A store that changed itself with nothing on screen to say so
    /// is the shape of every "where did that come from" question.
    var autoDrafted = 0

    // Stored for "Who the shop buys from" (Shop+Stock.swift).
    /// The supplier being written down or corrected, or nil.
    var editingSupplier: Supplier?

    /// The supplier a purchase is being written against, or nil.
    var loggingPurchaseFor: Supplier?

    /// The supplier whose log is open, or nil.
    var showingHistoryFor: Supplier?
    /// The spool whose usage log is open, if any.
    var spoolHistoryFor: Spool?
    /// The order whose supplier bill is being typed in, if any. Set when a
    /// bill turns up after the goods rather than with them.
    var billingOrder: PurchaseOrder?

    // Stored for "Money an old defect took off the book" (Shop+Money.swift).
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

    /// Whether the review sheet is open.
    var reviewingDeposits = false

    // Stored for "Paying over months" (Shop+Money.swift).
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

    // Stored for "What the customer thought" (Shop+Customers.swift).
    /// The job whose rating is being written down, or nil.
    var ratingFor: Order?

    // Stored for "Several prints that are one object" (Shop+Catalogue.swift).
    /// The kits in this book, each already totalled.
    ///
    /// A figure printed as Head, Hand, Body and Legs is four jobs and four
    /// print-log entries, and "what did that figure cost me" was arithmetic
    /// across four rows that nobody does. Grouped ACROSS orders rather than
    /// merged into one, because the actuals live on the order — folding four
    /// jobs into one would replace four measured numbers with one, and those
    /// are what the estimator calibrates from.
    var kits: [KhaytEngine.PrintKit] = []

    /// `settings.kits` as written — `[{id, name}]`. Kept raw because every
    /// rule that touches a kit name takes this list, and re-encoding a decoded
    /// Swift struct would be a second opinion about its shape.
    var kitDefs: [JSONValue] = []

    // Stored for "What is already printed and on the shelf" (Shop+Catalogue.swift).
    /// One order as the book holds it, rather than as this app decoded it.
    ///
    /// The invoice document reads fields this app has no use for on screen —
    /// the extra lines, the rush fee, the discount it was given — so it is
    /// handed the row, not the `Order`.
    var orderRows: [JSONValue] = []

    /// The customers, as the book holds them.
    ///
    /// The RAW rows, not this app's decoded `Client` re-encoded: the invoice
    /// reads fields this app has no use for on screen, and a customer's
    /// registration number vanishing from a tax document because a Swift struct
    /// did not name it is exactly the kind of loss this avoids.
    private(set) var clientRows: [JSONValue] = []

    /// The machines, as the book holds them. Kept so the fleet tile can be
    /// recomputed when the printers answer, without redoing the whole dashboard.
    var machineRows: [JSONValue] = []

    /// `machMaintTasks` as written: what each machine is due for, and when it
    /// was last done. Kept raw because the shared rule reads fields this app
    /// has no model for, and decoding to a Swift struct here would mean
    /// deciding which of them matter — a decision that belongs in the rule.
    var maintTaskRows: [JSONValue] = []

    /// Every machine's kind and what follows from it, keyed by machine id.
    /// `lib/machine-kinds.js` decides; this holds the answer.
    private(set) var machineKinds: [String: KhaytEngine.MachineKind] = [:]

    /// What each shelf row is counted in, keyed by item id.
    /// `lib/inventory-units.js` decides; this holds the answer.
    private(set) var inventoryUnits: [String: KhaytEngine.InventoryUnit] = [:]

    /// The catalogue, as the book holds it.
    ///
    /// This app does not show the catalogue — it has no products screen — but
    /// it does rank what the shop is asked for most, and that list is a column
    /// of ids without the names.
    private(set) var productRows: [JSONValue] = []

    // Stored for "What the shop spent, and what it wasted" (Shop+Stock.swift).
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

    // Stored for "Keeping the shop's data" (Shop+Cloud.swift).
    /// When the shop's last backup was taken, for the sidebar to show.
    var lastBackup: String?

    /// Why the day's backup could not be taken, when it could not.
    var backupProblem: String?

    /// What the app said as it died last time, if it did.
    ///
    /// Read once when a book opens. A crash a shop cannot see is a crash it
    /// cannot report, and the macOS report for an uncaught exception does not
    /// carry the reason.
    var lastCrash: String?

    // Stored for "Which printer takes which job" (Shop+Jobs.swift).
    /// Whether the proposal panel is up.
    var schedulingWork = false

    /// The scheduler's proposal, or nil when nobody has asked for one.
    ///
    /// Held rather than recomputed on every redraw, because it is a PROPOSAL: a
    /// panel whose rows changed underneath the person reading them would be a
    /// panel nobody could approve.
    var schedulePlan: KhaytEngine.SchedulePlan?
    /// Why there is no proposal, in the shop's own words.
    var scheduleProblem: String?
    /// Nothing is waiting for a machine — every job already has one. A state,
    /// not a fault, and kept apart from `scheduleProblem` for that reason.
    var scheduleIdle = false
    /// How many jobs the last apply moved.
    var scheduleApplied: Int?
    /// Per machine, what running its proposed jobs grouped by colour would do
    /// (`lib/swap-queue.js`). Worked out with the proposal and held with it,
    /// for the same reason. See `SwapPlanning.swift`.
    var swapPlans: [String: KhaytEngine.SwapQueue] = [:]
    /// Whether the proposal is shown in the colour-grouped order. On by
    /// default: the rule only reorders when it saves a change and breaks no
    /// promise, so there is nothing to lose by showing it.
    var groupByColour = true

    // Stored for "What can go on one plate" (Shop+Jobs.swift).
    /// Whether the batch planner is open.
    var planningBatch = false

    /// The proposed plates, or nil when nobody has asked yet.
    ///
    /// Held rather than recomputed on every redraw, for the reason the
    /// scheduler's proposal is: rows that changed underneath the person reading
    /// them cannot be acted on.
    var batchPlates: KhaytEngine.PlatePlan?
    /// Why there is no proposal — the app failing, not the shop having nothing.
    var batchProblem: String?
    /// There is no work to plan. A state, not a fault; kept apart for the same
    /// reason `scheduleIdle` is.
    var batchIdle = false

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

    // Stored for "Reading back a label this app printed" (Shop+Jobs.swift).
    /// Whether the scan sheet is open.
    var scanning = false

    // Stored for "What the cloud held, last time this app looked" (Shop+Cloud.swift).
    var cloudSeen: CloudSeen?

    @ObservationIgnored let ephemeralCloudRevisions = CloudReader.RevisionMemory(defaults: nil)

    // Stored for "The catalogue" (Shop+Catalogue.swift).
    /// What the shop sells, priced by the shared rule.
    ///
    /// Resolved once per load. Three crossings per row — the name, the price
    /// and the specs — would be three hundred for a hundred products.
    var catalogueRows: [KhaytEngine.CatalogueRow] = []

    /// The catalogue ranked by profit per printer hour — see
    /// `ProfitPerHour.swift`. Read once per load, after the rows it ranks.
    var profitPerHour: KhaytEngine.ProfitPerHour?

    // Stored for "What the cloud holds" (Shop+Cloud.swift).
    /// The comparison, once it has been asked for.
    var cloudCheck: CloudCompare.Result?
    /// Why it could not be made.
    var cloudProblem: String?
    /// True while the passphrase sheet is up.
    var checkingCloud = false
    var signingIntoCloud = false
    /// True while the Send Feedback sheet is up — see `Feedback`.
    var sendingFeedback = false
    /// The window as it was when feedback was asked for. Taken BEFORE the
    /// sheet opens, so the picture is of the screen the problem was on.
    var feedbackCapture: Feedback.Capture?
    /// True while the request is in flight.
    var cloudBusy = false
    /// What the last send put up, if there was one.
    var cloudSent: CloudWriter.Sent?
    /// Whether the last comparison found a settings change this app cannot send.
    var cloudSettingsStay = false

    // Stored for "Orders a storefront has already sent" (Shop+Cloud.swift).
    /// What is waiting in the cloud's intake queue, each read against the
    /// shelf. See `OnlineOrders.swift` — empty until the screen asks, and
    /// empty for a shop with no cloud, which is not an error.
    var onlineOrders: [OnlineOrder] = []
    /// True while the queue is being read or one of its orders written.
    var onlineBusy = false
    /// Why the last look or the last write did not work.
    var onlineProblem: String?

    // ── WEB-STORE ORDERS THAT BECAME JOBS BY THEMSELVES (WebStoreOrders.swift)
    /// What arrived since the shop last dismissed the notice, newest last.
    var webStoreArrived: [WebStoreArrival] = []
    /// Queue items this session could not record, so a failing one is not
    /// tried again every couple of minutes. Pressing its button still works.
    var webStoreGaveUp: Set<String> = []
    /// Why the last automatic pass did not work, for the Online orders sheet.
    var webStoreAutoProblem: String?
    /// True while a pass is running, so two timers cannot overlap.
    var webStoreAutoBusy = false
    var webStoreOrdersTask: Task<Void, Never>?
    /// What the last status publish said, for the Online orders sheet.
    var webStoreStatusSaid: String?
    /// Khayt Cloud answered 404: it does not take order statuses yet. Quiet
    /// until the app next starts, as the quote sheet is.
    var webStoreStatusNotOffered = false

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
    var cloudDek: Data?

    /// This Mac's printers, published to the cloud for viewers away from the
    /// shop — see `LivePrinterPublisher`.
    let livePublisher = LivePrinterPublisher()

    /// The nightly off-site backup: its settings, when it last ran and
    /// whether it is failing. See `OffsiteBackups.swift`.
    let offsite = OffsiteBackupState()

    /// Asked from the Book menu and the sidebar; the window confirms it.
    var confirmingSignOut = false

    /// The shop locked the cloud this session. Cleared by the next unlock.
    var cloudLockedByShop = false

    /// What the last pull brought down, if there was one.
    var cloudPulled: KhaytEngine.Merged?

    // Stored for "What the printers are doing" (Shop+Printers.swift).
    /// The machine whose history is being read, for the button to say so.
    var importingHistory: Machine.ID?

    // Stored for "Adding a model" (Shop+Library.swift).
    /// What the last import had to say. Cleared by the next one.
    var importNote: String?
    var importProblem: String?
    /// True while a model is being measured. A 46 MB 3MF takes a few seconds
    /// and a window that looks frozen for a few seconds is a window somebody
    /// clicks again.
    var importing = false
    /// How far a batch has got, and what it is reading right now. Nil for a
    /// single file, which is over before a progress bar would finish drawing.
    var importProgress: (done: Int, total: Int, name: String)?
    /// Set by the Stop button. A batch checks it between files, so it stops
    /// cleanly between imports rather than halfway through one.
    var importCancelled = false

    // Stored for "The shop's slicers" (Shop+Settings.swift).
    /// The slicers this shop has configured, read by the shared rule.
    var slicers: [KhaytEngine.Slicer] = []
    /// The one to reach for when nobody has said which.
    var defaultSlicer: KhaytEngine.Slicer?
    /// What the last attempt to open a model in a slicer had to say.
    var slicerProblem: String?

    // Stored for "Syncing without being asked" (Shop+Cloud.swift).
    /// What the sidebar says about sync.
    var syncStatus: AutoSync.Status = .off

    var syncTask: Task<Void, Never>?
    /// How many attempts have failed in a row, for the backoff.
    var syncFailures = 0
    /// A change arrived while a push was in flight — run once more after.
    var syncAgainAfter = false
    var syncInFlight = false
    /// When the whole book last went up, for the floor. See `AutoSync`.
    var lastWholeBookPush: Date?
    /// Set once the service has refused a delta for this shop. The desktop
    /// remembers the same 404 for the same reason: one probe per session.
    var chainIsClosed = false
    /// A backup is being put back. No sync starts until it is in place: a
    /// merge that read the book before the restore and wrote after it would
    /// put the old book back, and one that ran in between would fold the
    /// cloud's deletes into the restored one before it could be held.
    var restoreInProgress = false
    /// What the last merges took from this book, kept and not yet looked at.
    var syncLossNotice: SyncLossNotice?
    /// Why a restore is no longer being held against the cloud — it expired,
    /// or this Mac's role can never carry it up. Said once, then the ordinary
    /// sync rule applies to the restored records again.
    var restoreHoldNote: String?
    var reviewingSyncLosses = false
    /// Kept records already put back, so the sheet stops offering them.
    var syncLossesPutBack: Set<String> = []

    // Stored for "The shop's published delivery dates" (Shop+Cloud.swift).
    var leadTimeTask: Task<Void, Never>?

    /// What the last successful publish said, so a withdrawal happens ONCE.
    /// `.some(nil)` means "we published a withdrawal"; `nil` means we have not
    /// published anything this session.
    var leadTimePublished: JSONValue??

    /// What went wrong last. Never surfaced as an ALERT: a promise nobody can
    /// read is better than a shop interrupted about its storefront while it is
    /// trying to work. It is shown in Settings → Online, where a shop that
    /// wonders about its storefront is already looking.
    var leadTimeProblem: String?

    /// What this last did, and when — the answer to "did it run at all".
    ///
    /// The note below has always written this to stderr, which answers the
    /// question only for somebody holding a terminal. These two carry the same
    /// sentence to the pane, so a shop can tell a publish that has never run
    /// from one that ran and was refused.
    var leadTimeSaid: String?
    var leadTimeAt: Date?

    // Stored for "Smart plugs" (Shop+Printers.swift).
    /// What each machine's plug last said, by machine id.
    var plugStates: [String: KhaytEngine.PlugState] = [:]
    /// Why the last switch did not happen, by machine id, in the shop's words.
    var plugProblem: [String: String] = [:]
    /// When a print was last seen to end on each machine, for the auto-off.
    var printEndedAt: [String: Date] = [:]
    /// What each machine was last seen doing, to notice a print ending.
    var lastPrinterState: [String: String] = [:]
    var plugTask: Task<Void, Never>?

    /// What each print is drawing from the wall, for the book that is open.
    /// Nil for the sample shop, which has no plugs worth metering and no book
    /// to write a reading to.
    var meterForBook: (URL, EnergyMeter)?

    /// What was last sent as the quote sheet — `.some(nil)` a withdrawal, `nil`
    /// never sent. A shop that never switched public pricing on is never sent a
    /// withdrawal, every six hours, for ever.
    // ── THE WEB STORE'S CATALOGUE (WebStore.swift) ─────────────────────────
    /// The catalogue's two cloud sheets. On the shop rather than the screen,
    /// because the new shell draws the screen's buttons in its own strip
    /// (ScreenActions) and the old toolbar is only drawn in the classic one.
    var showingWebStore = false
    var showingOnlineOrders = false
    /// Whether Khayt Cloud holds a published catalogue: nil until asked.
    var webStoreLive: Bool?
    /// When the published catalogue was last replaced, by either app.
    var webStoreAt: Date?
    /// What the last publish or check said, in the shop's words.
    var webStoreSaid: String?
    /// When that was said, and what Khayt Cloud held when it was last read.
    var webStoreSaidAt: Date?
    var webStoreHeld: CatalogPublisher.Held?
    var webStoreProblem = false
    var webStoreBusy = false
    /// What the store was built from last time the book was read, so a change
    /// to it can be told apart from a re-read of the same book.
    var webStoreSeen: JSONValue?
    var webStoreRepublish: Task<Void, Never>?
    /// The book the store state above belongs to (`webStoreBookRead`), and
    /// whether any book has been read yet — nil is the sample's identity.
    var webStoreBook: URL?
    var webStoreBookKnown = false
    /// How long a change waits before it is republished. A test shortens it.
    var webStoreFollowDelay: Duration = CatalogPublisher.followDelay
    /// What a follow runs when it fires. nil is `publishWebStore(automatic:)`;
    /// a test stands in for the network here.
    var webStoreAutoPublish: (@MainActor (Shop) async -> Void)?
    /// Prices a live store would have republished on its own that the shop
    /// did not set: held, and shown for review instead (`heldPrices`). Kept
    /// across re-reads of the same book, which `resetWebStore` is not.
    var webStorePriceHold: [WebStorePriceChange] = []
    var webStoreHoldBook: URL?
    /// Product id → the listed price the shop itself saved (product sheet, or
    /// a reviewed repair) since the store was last published.
    var webStoreExplicitPrices: [String: String] = [:]
    /// Web-sized pictures already made, by file name and the file's date.
    var webStoreHeroes: [String: (Date, String)] = [:]

    var quoteSheetPublished: JSONValue??
    /// What the last attempt said, in the shop's words, for the Online pane.
    var quoteSheetSaid: String?
    var quoteSheetAt: Date?
    var quoteSheetProblem = false

    let printers = PrinterWatch()

    /// The stills from those printers' cameras, on a slower timer of their own —
    /// a picture is worth refetching every few seconds, a status every ten.
    let cameras = Camera()

    // Stored for "Putting a backup back" (Shop+Cloud.swift).
    /// The backup a shop has chosen and not yet confirmed.
    var restoring: Restore.Candidate?

    // Stored for "The shelf" (Shop+Stock.swift).
    /// The spool being written down, or corrected.
    var editingSpool: Spool?
    /// True while the sheet is for a spool that is not on the shelf yet.
    var addingSpool = false
    /// The Spoolman import sheet is open.
    var importingSpoolman = false

    // Stored for "The other shelf" (Shop+Stock.swift).
    /// Which consumable sheet is open, if any. The record rather than its id,
    /// so `sheet(item:)` presents it — the shape `editingSpool` uses.
    var editingConsumable: Consumable?
    var addingConsumable = false
    /// The shelf the list is narrowed to. Empty is all of them; the rule's
    /// NUL-prefixed sentinel is the uncategorised bucket.
    var consumableCategory = ""

    // Stored for "The machines" (Shop+Printers.swift).
    /// The machine being written down, or corrected.
    var editingMachine: Machine?
    var addingMachine = false

    /// Writing down what was spent, and what was thrown away.
    ///
    /// On the book rather than in the screen because the new shell's strip
    /// carries the "+" and the strip is not inside the screen — see
    /// `ScreenActions`. The sheets stay where they were.
    var addingExpense = false
    /// "Add from receipt…": the reader sheet, and what it read — handed to the
    /// expense sheet to fill in, never saved by itself (ReceiptQr.swift).
    var readingReceipt = false
    var receiptPrefill: KhaytEngine.ReceiptDraft?
    var loggingWaste = false
    /// The printers Khayt knows, read once per launch — the catalogue is a
    /// constant, not something a book carries.
    var catalog: [CatalogPrinter] = []

    /// The nozzle fitments, from the wear data rather than from a list here.
    var nozzleMaterials: [NozzleMaterial] = []

    // Stored for "The first-run setup" (Shop+Settings.swift).
    /// The setup sheet, open. See `ShopSetup` and `ShopSetupSheet`.
    var settingUpShop = false
    /// What the last setup did, or why it could not.
    var setupProblem: String?

    // Stored for "The shop's own settings" (Shop+Settings.swift).
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
    var currencies: [String: Currency] = [:]
    var taxPresets: [String: TaxProfile] = [:]
    var taxProfile: TaxProfile?
    var contentLanguages: [String] = ["en", "ar"]

    // Stored for "Photographs of finished work" (Shop+Photos.swift).
    var snapshots: [Snapshot] = []

    /// The job a photo is being added to, or nil.
    var photographing: Order?

    // Stored for "The printer's own photo at the end of a print" (Shop+Photos.swift).
    /// What the last test alert said, for Settings › Online.
    var testAlertSaid: String?

    /// Set when this Khayt Cloud answers 404 to events, so a shop on an older
    /// server is not asked again at every print until the app restarts.
    var eventsNotOffered = false

    /// The last print that ended on each machine, as `printFinished` saw it.
    var lastPrintEnded: [String: FinishCamera.Ended] = [:]

    // Stored for "A job's photo, on its product" (Shop+Jobs.swift).
    /// The job whose invoice is on screen.
    ///
    /// Not a question the way the others are — nothing waits on the answer and
    /// nothing is written — but it is a sheet over the same window, and it is
    /// dismissed by the same call, so it lives with them.
    var pendingInvoice: PendingHold?

    /// The label sheet waiting to be looked at, as finished HTML.
    ///
    /// Built once when the shop asks rather than per redraw: a QR code per
    /// spool is real work — CoreImage rasterises each one — and a shelf of
    /// forty would redo it on every frame of the sheet's animation.
    var pendingLabels: LabelSheetRequest?

    /// The job being dragged, or nil.
    var draggingJob: Order.ID?
    /// What each column said about that job, keyed by status.
    ///
    /// EMPTY IS NOT "EVERY COLUMN REFUSES". It is "the answer has not arrived",
    /// which is true for the first moments of every drag, and a board that
    /// greys out all seven columns while it thinks is a board that looks broken.
    var dragGates: [String: StatusGate] = [:]

    var releaseWatchers: [Any] = []

    /// What stopped a move, when something did. Cleared by the next attempt.
    var moveProblem: String?
    /// What the last move had to say — the due date it pushed out, the spools
    /// it emptied, the ones that are now low.
    var moveNotices: [String] = []

    // Stored for "The shop's saved messages" (Shop+Messages.swift).
    /// The template being edited, or a blank one being written. Nil when the
    /// editor is closed — the sheet is raised from `WindowSheets` so that both
    /// shells can raise it.
    var editingTemplate: MessageTemplate?

    // Stored for "Stopping the floor" (Shop+Jobs.swift).
    /// The reason box, open. Nil when nobody is being asked.
    var pausingProduction = false

    // Stored for "What is likely to go wrong with this print" (Shop+Printers.swift).
    /// The overhang report for each model, keyed by the model's id.
    ///
    /// Loaded from the record where one has been stored, so a shop that turned
    /// the walk on at import sees every answer immediately and one that did not
    /// sees the ones it has asked for.
    var risks: [String: KhaytEngine.PrintRiskReport] = [:]
    /// The models whose mesh is being walked right now.
    var riskRunning: Set<String> = []
    var riskProblem: String?

    /// `demand` or `import`, from the shared rule — nil until it has answered.
    ///
    /// NOT defaulted to a literal here. The shared rule owns that default, and
    /// a second copy of it in Swift is a second thing to get wrong when it
    /// changes. Nil reads as "not at import", which is the same conservative
    /// direction `lib/print-risk.js` takes for a value it does not recognise:
    /// the cost of being wrong is one click, not an hour added to an import.
    private(set) var riskWhen: String?

    // Stored for "What the table shows" (Shop+Shell.swift).
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

    /// The site the shop is looking at, if it has narrowed to one. Not
    /// persisted, for the reason `kitFilter` is not: a book that opens showing
    /// one branch's jobs with nothing saying so reads as a shop that lost the
    /// other branch's. The desktop keeps it for the session too.
    var siteFilter: String? {
        didSet {
            guard siteFilter != oldValue else { return }
            Task { await refreshSiteScope() }
        }
    }

    /// What `siteFilter` shows, as ids — `lib/site-filter.js`'s answer, asked
    /// whenever the book or the filter changes. Nil when nothing is filtered.
    var siteScope: KhaytEngine.SiteScope? {
        didSet {
            siteIds = SiteIds(orders: Set(siteScope?.orderIds ?? []),
                              machines: Set(siteScope?.machineIds ?? []),
                              spools: Set(siteScope?.spoolIds ?? []))
        }
    }

    var siteIds = SiteIds()

    /// What this run has told the phones' Live Activities, per machine — see
    /// `LiveActivityPush`. Not observed: no screen draws it.
    @ObservationIgnored let liveActivities = LiveActivityPush.Memory()
    /// How a Live Activity post reaches the cloud. A seam for tests, which
    /// must never reach a real server.
    @ObservationIgnored var liveActivityFetch: (URLRequest) async throws -> (Data, URLResponse) = LiveActivityPush.liveFetch
    /// Whether this Mac may post at all: the opt-in in Settings → Integrations,
    /// this Mac's own (UserDefaults, OFF when never set). A seam for tests.
    @ObservationIgnored var liveActivitiesOptedIn: () -> Bool = {
        UserDefaults.standard.bool(forKey: LiveActivityPush.optInKey)
    }

    // Stored for "What the shell needs to draw itself" (Shop+Shell.swift).
    /// The title the window shows for the screen now open — §7's title bar.
    /// Which question the Ledger is answering, and which row is open in the
    /// inspector. Screen state, so it lives with the screen rather than in the
    /// book — a shop reopening Khayt wants its jobs, not its last filter.
    var ledgerFilter: LedgerFilter = .needsMe
    var ledgerSelection: LedgerLine?

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
    var categoriesInUse: [String] = []
    var tagsInUse: [String] = []

    // Stored for "Where a model came from" (Shop+Library.swift).
    var libraryFacets = LibraryFacets()

    /// The library rows as they sit in the book. Kept because the counts are
    /// asked of a JavaScript rule, which reads records rather than `LibraryFile`
    /// — and re-encoding the decoded ones per keystroke would be a hop for a
    /// round trip.
    var libraryRows: [JSONValue] = []

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
    var libraryRecount = 0

    var libraryRecountTask: Task<Void, Never>?

    /// What a shop is looking at: a category, a tag, both, or neither.
    ///
    /// The GROUP axis is not here — it is the shelf, because a group is a
    /// folder now and opening one is navigating rather than filtering. Unfiled
    /// is the exception and lives here, since there is no folder to open for
    /// models that are in none.
    var libraryCategory: FilterChoice? { didSet { libraryViewChanged() } }
    var libraryTag: String? { didSet { libraryViewChanged() } }
    /// Models in no project at all — the answer to "what have I not filed yet".
    var libraryUnfiledOnly = false { didSet { libraryViewChanged() } }
    /// Models the shop has never made. See `LibraryFacets.neverPrinted`.
    var libraryNeverPrintedOnly = false { didSet { libraryViewChanged() } }

    /// Models that can start on this machine now, with what it has loaded.
    var libraryReadyOn: String? { didSet { libraryViewChanged() } }
    /// One creator's models. See `LibraryFile.creator`.
    var libraryCreator: String? { didSet { libraryViewChanged() } }
    /// The library as models (true, the default — "All models") or as
    /// folders ("Groups"). In All models a group that is one print in parts is
    /// still one tile; see `libraryEntries`.
    var libraryFlat = true {
        didSet { if libraryFlat != oldValue { pruneSelectionToVisible() } }
    }

    /// The shop's Print next list.
    var libraryPrintNextOnly = false { didSet { libraryViewChanged() } }
    /// Models that are the same file, or the same mesh, as another.
    var libraryDuplicatesOnly = false { didSet { libraryViewChanged() } }
    /// Which models are ready on which machine, from the last recount.
    var readyByMachine: [String: Set<String>] = [:]

    /// Recomputed with the facets; the grid's filter and the inspector read it.
    var duplicateOf: [String: String] = [:]

    /// Where a selection run started, and where the keyboard is standing.
    var anchor: LibraryFile.ID?
    var cursor: LibraryFile.ID?

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
    var pendingReveal: String?

    // Stored for "What the customers screen shows" (Shop+Customers.swift).
    /// What the shop calls each of its customers, in its own language.
    ///
    /// Resolved once when the book loads — thirty-one rows asking the engine
    /// one at a time would be thirty-one bridge crossings for one screen.
    private(set) var clientNames: [String: KhaytEngine.Named] = [:]
    /// What each model's licence permits, by model id. Absent for a model
    /// nobody has recorded one for, which is NOT the same as one that may not
    /// be sold — the screen says nothing rather than something wrong.
    internal(set) var licences: [String: KhaytEngine.Standing] = [:]

    /// The printers a model can be converted for, from the shared rule.
    private(set) var printerProfiles: [KhaytEngine.PrinterProfile] = []
    /// What the last conversion had to say, and whether one is running.
    var convertNote: String?
    var convertProblem: String?
    var converting = false

    /// The ids of the spools running low — the shared rule's answer, asked
    /// once for the whole shelf.
    ///
    /// A SET, not the rule's `[id: Bool]`. That map has an entry for every
    /// spool, and two screens read "has an entry" as "is low": the sidebar
    /// counted `.count` (▼3 on a shelf of three full spools) and the
    /// dashboard tinted every figure as a warning. Only the low ones are kept,
    /// so counting and asking are both right by construction.
    private(set) var lowSpools: Set<String> = []
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

    /// The month's net income — `PnlPeriod.net`, the figure Reports prints as
    /// NET INCOME. This, not `monthNetRevenue`, is what the masthead's NET is.
    private(set) var monthNetIncome: Double?

    /// The same jobs as `monthNetRevenue`, before the tax is taken out.
    ///
    /// ── IT WAS A DIFFERENT SET OF JOBS ──────────────────────────────────
    ///
    /// The masthead printed "Gross" beside the month's net, and summed it over
    /// the month's PAID-UP jobs, whatever their stage — while the net beside
    /// it is the month's FINISHED jobs, paid or not. Two populations under
    /// labels that promise one: a job finished and not yet paid for counted
    /// in the net and not the gross, and the sample shop showed 1,671.90 net
    /// beside 1,243.09 gross on 23 September 2026, which is the day
    /// `MastheadNetTests` noticed.
    ///
    /// Revenue plus the tax collected on it is what was charged for exactly
    /// those jobs: an inclusive-VAT shop gets its prices back, an exclusive
    /// one its prices with the tax on top, an unregistered one the net itself.
    /// Never below the net, by construction rather than by luck.
    private(set) var monthGrossRevenue: Double?

    /// The month's cost of goods sold — `PnlPeriod.cogs`, the figure Reports
    /// prints under that name. Nil as `monthNetIncome` is.
    private(set) var monthCostOfGoods: Double?

    /// Which machine each model fits, keyed by the model's id. Worked out once
    /// when the book loads rather than per row: a grid of four hundred models
    /// asking the runtime on every redraw is four hundred context hops.
    internal(set) var fits: [String: KhaytEngine.Fit] = [:]
    /// The cards the shop has issued, and what each one is today.
    private(set) var giftCards: [GiftCard] = []
    private(set) var giftCardRows: [JSONValue] = []

    // Stored for "Points a customer has earned" (Shop+Money.swift).
    /// The points ledger, as the book holds it.
    private(set) var loyaltyRows: [JSONValue] = []

    // Stored for "Who a message would reach" (Shop+Customers.swift).
    /// Whether the campaign sheet is open.
    var planningCampaign = false

    private(set) var giftCardStatuses: [String: String] = [:]
    /// Which state the screen is narrowed to, or nil for all of them.
    ///
    /// §4 took the Status column off this screen — three other things in the
    /// row already say it — and the three words became the way a shop ASKS
    /// instead. See `GiftCardFilterBar`.
    var giftCardState: String?
    /// True while the Issue sheet is up.
    var issuingGiftCard = false

    // Stored for "What a model is set up to print like" (Shop+Library.swift).
    /// The slicer's own settings for a model, once they have been read.
    ///
    /// Keyed by record id. `nil` means not read yet; a present entry holding
    /// `nil` facts means read and the file had nothing to say, which is a real
    /// answer and must not send the reader back to the disk on every redraw.
    var factsByFile: [String: KhaytEngine.PrintFacts?] = [:]
    var factsInFlight: Set<String> = []

    /// Products costed on a figure other than their spool's size, counted on
    /// each open. Nothing is changed until the shop reviews them.
    var spoolRepairPending = 0
    var showingSpoolRepair = false

    /// Whether the book on disk still carries the old key. Read from the copy
    /// this load decoded, so it costs nothing.
    private(set) var rawHasStrandedLog = false

    /// Which engine already holds the catalogue.
    ///
    /// Checked BEFORE the file is read. The spool sheet searches on every
    /// keystroke, and reading the resource is ~0.9 MB of UTF-8 decoding on the
    /// main actor — which the engine then threw away, because it had parsed the
    /// catalogue on the first keystroke. An engine, not a flag: a new engine
    /// starts without it.
    @ObservationIgnored var filamentCatalogEngine: ObjectIdentifier?
}
