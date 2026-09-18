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
        return try JSONDecoder().decode([QueueOrder].self, from: Data(json.utf8))
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
