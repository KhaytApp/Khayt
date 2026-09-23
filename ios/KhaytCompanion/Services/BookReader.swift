import Foundation
import KhaytCore

/**
 * Reading the shop's own records, on the phone, with nothing to ask.
 *
 * ── WHY THIS IS NOT AN OPTIMISATION ───────────────────────────────────────
 *
 * The native Mac app serves four routes: `/api/status`, `/api/queue`,
 * `/api/store` and the customer-facing intake. It does NOT serve `/api/orders`,
 * `/api/inventory`, `/api/clients`, `/api/machines` or `/api/waiting-list` —
 * those exist only in `lib/lan-server.js`, which is the Electron desktop. So a
 * companion paired to the native Mac does not have slow screens, it has five
 * screens that cannot load at all.
 *
 * This is how they load. The records are already on the phone, in the book.
 *
 * ── THE ONE RULE THAT IS NOT A FIELD READ ─────────────────────────────────
 *
 * Four of these models decode a raw store record unchanged — proven, by
 * decoding the sample shop's actual records with the shipping structs. The
 * desktop's projections for them are pass-throughs.
 *
 * The queue is NOT, and finding that out by accident is the whole argument for
 * doing it this way: `priority` is a BOOLEAN in the store and a STRING on the
 * wire, so a hand-written queue projection would have compiled, run, and thrown
 * a decode error on the first shop that flagged a job as urgent. So the queue
 * goes through `KhaytEngine.lanQueueBody` — the same rule the Mac serves, run
 * locally — which decides which orders are in the queue AND normalises them.
 * The phone does not get its own opinion about either.
 */
actor BookReader {

    private let book: CompanionBook
    private var engineHandle: KhaytEngine?

    init(book: CompanionBook) {
        self.book = book
    }

    /// One engine, kept.
    ///
    /// Starting it loads the shop's business rules into JavaScriptCore, which
    /// costs about a fifth of a second. That is nothing once and everything on
    /// every scroll, and a screen that re-read the queue would pay it each time.
    /// The same engine, for work that belongs to the book but not the reader
    /// — a cloud sync folds with it.
    func sharedEngine() throws -> KhaytEngine { try engine() }

    private func engine() throws -> KhaytEngine {
        if let engineHandle { return engineHandle }
        let made = try KhaytEngine()
        engineHandle = made
        return made
    }

    /// A roll, as the shop's own rule would book it in — built here, written
    /// by `BookWriter.addSpool`. See `BookWriter.spoolRecord` for the rule.
    func newSpool(from draft: SpoolDraft, now: Date = Date()) async throws -> [String: JSONValue] {
        try await newSpools(from: draft, count: 1, now: now)[0]
    }

    /// `count` identical rolls, each its own record with its own id.
    func newSpools(from draft: SpoolDraft, count: Int, now: Date = Date()) async throws -> [[String: JSONValue]] {
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = try book.read()["settings"] { settings = s }
        let engine = try engine()
        var records: [[String: JSONValue]] = []
        for id in BookWriter.newSpoolIds(max(1, count), now: now) {
            records.append(try await BookWriter.spoolRecord(from: draft, engine: engine, settings: settings,
                                                            id: id, now: now))
        }
        return records
    }

    /// The shop's currency code from its settings, or nil when it has none.
    func shopCurrency() throws -> String? {
        guard case .object(let settings)? = try book.read()["settings"],
              case .string(let code)? = settings["currency"],
              !code.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return code
    }

    /// Take a book from upstream — the Mac's `/api/store` or the cloud — without
    /// losing what was changed here and not sent yet.
    ///
    /// ── WHY THIS IS NOT JUST `replace` ──────────────────────────────────
    ///
    /// A pull that simply replaced the book took every unsent edit with it,
    /// and the pending count with them: edit a job offline, walk back into
    /// range, open any screen, and the refresh that screen triggers wiped the
    /// edit without a word. So the outbox is measured BEFORE the swap, folded
    /// onto the incoming book by the shop's own rule (a newer rev from
    /// upstream still wins), and the baseline is set to upstream's copy alone
    /// — which keeps exactly those edits pending.
    func adopt(_ upstream: [String: JSONValue], scope: BookScope.Taken?) async throws {
        var merged = upstream
        if book.exists, let baseline = book.baseline() {
            let outbox = try await engine().changesToSend(local: try book.read(), server: baseline)
            if !outbox.isEmpty {
                merged = try await engine().foldDeltas(base: upstream, deltas: [outbox.wire]).store
            }
        }
        try book.replace(with: merged, scope: scope)
        try book.replaceBaseline(with: upstream)
    }

    /// Is there a book on this phone at all?
    ///
    /// `nonisolated` so a read path can ask without hopping onto the actor just
    /// to find out there is nothing to read.
    nonisolated var holdsAnyBook: Bool { book.exists }

    /// What this phone was told it is missing, for a screen about to show a total.
    nonisolated func holdsAll(_ collection: String) -> Bool { book.holdsAll(collection) }

    // MARK: - The queue, through the shared rule

    func queue() async throws -> [QueueOrder] {
        let store = try book.read()
        let json = try await engine().lanQueueBody(store: .object(store))
        let orders = try JSONDecoder().decode([QueueOrder].self, from: Data(json.utf8))
        // The book holds the machines as well as the jobs, so the printer can be
        // named here rather than left as an id the screens cannot render. Done
        // once, at the point the two are together, instead of threading the
        // machine list through every row that wants to draw a printer.
        let machines = (try? self.machinesUnsafe(from: store)) ?? []
        return orders.map { $0.namingMachine(from: machines) }
    }

    /// The machines out of an already-read store, so `queue()` does not read the
    /// book from disk twice for one screen.
    private func machinesUnsafe(from store: [String: JSONValue]) throws -> [MachineInfo] {
        guard case .array(let rows)? = store["machines"] else { return [] }
        let data = try JSONEncoder().encode(JSONValue.array(rows))
        return try JSONDecoder().decode([MachineInfo].self, from: data)
    }

    /// The masthead figures, also the Mac's own rule rather than a second count.
    func status(today: String = BookReader.today()) async throws -> ShopStatus {
        let store = try book.read()
        let json = try await engine().lanStatusBody(store: .object(store), today: today)
        return try JSONDecoder().decode(ShopStatus.self, from: Data(json.utf8))
    }

    /// The shop's own day, not UTC — `completedToday` means today where the shop is.
    nonisolated static func today(_ now: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }

    // MARK: - What this phone has changed and the Mac has not seen

    /// The edits made on this phone since the Mac last handed over the book.
    ///
    /// ── IT IS THE SHOP'S OWN RULE, NOT A SECOND ONE ──────────────────────
    ///
    /// `KhaytCloudOutbox.changesToSend` is what the desktop already uses to
    /// decide what to push, and it is what runs here — over the book and the
    /// baseline. The phone does not get a private theory about what counts as a
    /// change, which matters because the answer has to survive a round trip: the
    /// Mac folds this with `KhaytSync.applyDeltas`, the same pair of rules that
    /// have been moving records between devices since before the phone existed.
    ///
    /// ── WHY A PARTIAL BOOK CANNOT DELETE A SHOP'S HISTORY ────────────────
    ///
    /// The phone holds a working set — 200 finished orders out of a possible
    /// 3,140. Handing that to a rule that diffs two stores sounds alarming: the
    /// 2,940 it does not have look, at a glance, like records it deleted.
    ///
    /// They are not, and this is a property of the rule rather than caution
    /// here: `changesToSend` emits a delta only for a record PRESENT locally at
    /// a higher rev, and takes tombstones only from the store's own
    /// `tombstones` collection. Absence says nothing. Verified against the rule
    /// directly, not assumed.
    ///
    /// The consequence is that a deletion made on the phone is not expressible
    /// yet — nothing here writes a tombstone — so deleting stays a desktop
    /// action. That is a limit, stated, rather than a silent half-behaviour.
    ///
    /// Returns nil when there is no baseline: a phone that has never been given
    /// the book has not changed anything, and has nothing to say.
    func pendingChanges() async throws -> KhaytEngine.Outbox? {
        guard let baseline = book.baseline() else { return nil }
        let local = try book.read()
        return try await engine().changesToSend(local: local, server: baseline)
    }

    /// Has this phone got anything to send?
    ///
    /// Separate from `pendingChanges` so a screen can ask the cheap question —
    /// a badge, a "waiting to sync" line — without the engine crossing.
    func hasPendingChanges() async -> Bool {
        guard let outbox = try? await pendingChanges() else { return false }
        return !outbox.isEmpty
    }

    // MARK: - The collections that are records as they stand

    func recentOrders(limit: Int = 40, status: String? = nil) throws -> [OrderLogEntry] {
        var rows: [OrderLogEntry] = try decode("printLog")
        if let status, !status.isEmpty {
            rows = rows.filter { $0.status == status }
        }
        // Newest first, which is what the screen shows and what `limit` means.
        rows.sort { ($0.date ?? "") > ($1.date ?? "") }
        return Array(rows.prefix(max(0, limit)))
    }

    /// How much of the order history this phone holds, when it holds only part.
    ///
    /// `nil` when it has all of it — and also when it has no idea, because a
    /// phone that cannot say what it is missing must not claim to be complete.
    /// The screen shows nothing in either case; the difference only matters if
    /// something ever starts totalling history, which is what `holdsAll` is for.
    nonisolated func orderHistoryWindow() -> HeldWindow? {
        guard let held = book.scope()?.collections["printLog"],
              !held.whole, let available = held.available else { return nil }
        return HeldWindow(sent: held.sent, available: available)
    }

    func inventory() throws -> [InventorySpool] { try decode("inventory") }
    /// The shop's clients, each under the name the shop actually calls them.
    ///
    /// The store holds `nameEn`, `nameAr`, `nameTr` — whatever the shop writes
    /// in — and the choice between them is `lib/content-languages.js`'s, not
    /// this app's. `/api/clients` applies that rule before it sends a name; a
    /// device reading the book has to apply it itself, or fall through to
    /// showing the customer's id.
    func clients() async throws -> [Client] {
        let store = try book.read()
        var clients: [Client] = try decode("clients", from: store)
        guard case .array(let rows)? = store["clients"], rows.count == clients.count else {
            return clients
        }
        let records = rows.compactMap { row -> [String: JSONValue]? in
            guard case .object(let o) = row else { return nil }
            return o
        }
        guard records.count == clients.count else { return clients }
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = store["settings"] { settings = s }
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        guard let names = try? await engine().clientNames(records, settings: settings,
                                                          language: language) else {
            return clients
        }
        for i in clients.indices where i < names.count {
            let resolved = names[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if !resolved.isEmpty { clients[i].name = resolved }
        }
        return clients
    }
    func machines() throws -> [MachineInfo] { try decode("machines") }

    func waitingList() throws -> [WaitingListItem] {
        // The desktop drops declined requests before sending them, so a phone
        // reading the records itself has to drop them too or it shows a triage
        // list somebody already finished with. One line, and it is the only
        // piece of `lib/lan-server.js`'s projection repeated here — worth
        // knowing if that rule ever grows.
        try decode("waitingList").filter { $0.status != "declined" }
    }

    /// Decode one collection straight out of the book.
    ///
    /// Through `JSONValue` and back rather than by hand: the models already know
    /// how to read a record — `InventorySpool` has a custom decoder for
    /// `weightRemaining` precisely because that is the store's spelling — and
    /// writing a second mapping here would be the thing this whole arrangement
    /// exists to avoid.
    private func decode<T: Decodable>(_ collection: String) throws -> [T] {
        try decode(collection, from: book.read())
    }

    private func decode<T: Decodable>(_ collection: String,
                                      from store: [String: JSONValue]) throws -> [T] {
        guard case .array(let rows)? = store[collection] else { return [] }
        let data = try JSONEncoder().encode(JSONValue.array(rows))
        return try JSONDecoder().decode([T].self, from: data)
    }
}
