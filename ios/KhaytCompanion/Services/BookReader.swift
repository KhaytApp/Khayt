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
    private func engine() throws -> KhaytEngine {
        if let engineHandle { return engineHandle }
        let made = try KhaytEngine()
        engineHandle = made
        return made
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

    func inventory() throws -> [InventorySpool] { try decode("inventory") }
    func clients() throws -> [Client] { try decode("clients") }
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
        let store = try book.read()
        guard case .array(let rows)? = store[collection] else { return [] }
        let data = try JSONEncoder().encode(JSONValue.array(rows))
        return try JSONDecoder().decode([T].self, from: data)
    }
}
