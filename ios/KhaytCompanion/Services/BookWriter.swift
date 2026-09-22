import Foundation
import KhaytCore

/**
 * Changing the shop's records on the phone, with the Mac switched off.
 *
 * ── WHAT THESE WRITES ARE, AND DELIBERATELY ARE NOT ───────────────────────
 *
 * Each of these sets fields on one record and stamps it. None of them runs the
 * shop's status rules — no `moveJob`, no filament deduction, no customer email
 * — and that is parity rather than a shortcut.
 *
 * Advancing a job from the phone has never done those things. `lib/lan-server.js`
 * answers `PATCH /api/orders/:id` with `updated.status = status` and writes the
 * record back; the renderer's `lan-order-updated` handler does the same
 * in memory to keep its screen in step. A plain field set, on both sides, since
 * the endpoint existed.
 *
 * So writing the same field locally and letting the delta carry it produces the
 * same book as being online does. Running `moveJob` here instead would be a
 * change in what the product does — a shop would start seeing stock drop for
 * jobs advanced from the phone, which it never has — and that is a decision
 * about the product, not a detail of working offline.
 *
 * ── WHY EVERY WRITE GOES THROUGH `updateRecord` ───────────────────────────
 *
 * It stamps `rev` and `updatedAt`. That stamp is the entire reason an edit made
 * here can ever reach the Mac: `changesToSend` compares revisions, and the Mac's
 * fold keeps the higher one. An unstamped edit is invisible to the first and
 * loses to the second — it would sit on the phone looking saved and never
 * arrive.
 */
struct BookWriter {

    let book: CompanionBook

    /// Advance or set a job's stage.
    func setOrderStatus(orderId: String, to status: String) throws {
        try book.updateRecord(collection: "printLog", id: orderId) { record in
            record["status"] = .string(status)
        }
    }

    /// Put a job on a printer, or take it off one.
    ///
    /// Writes the NAME as well as the id, because that is what the server does
    /// — it looks the machine up and stores both — and a record carrying only
    /// the id reads as "Unassigned" on every screen that has not been handed a
    /// machine list.
    func assignMachine(orderId: String, machineId: String?, machines: [MachineInfo]) throws {
        // Taking a job off a printer clears both fields — a name left behind
        // outlives the assignment and reads as a job still on that machine.
        guard let machineId, !machineId.isEmpty else {
            try book.updateRecord(collection: "printLog", id: orderId) { record in
                record["machineId"] = .null
                record["machine"] = .null
            }
            return
        }
        // The endpoint answers 404 for a machine the shop does not have, and so
        // does this: writing an id nothing resolves puts a job on a printer
        // that is not there, and the row would read as unassigned for ever
        // after because no name can be found for it.
        guard let machine = machines.first(where: { $0.id == machineId }) else {
            throw Refusal.noSuchMachine
        }
        try book.updateRecord(collection: "printLog", id: orderId) { record in
            record["machineId"] = .string(machineId)
            if let name = machine.name, !name.isEmpty { record["machine"] = .string(name) }
        }
    }

    enum Refusal: Error, LocalizedError, Equatable {
        case noSuchMachine
        /// Declining moves the request to `waitingListHistory` and removes it
        /// from `waitingList` — a deletion, which this phone cannot express.
        case declineNeedsTheMac

        var errorDescription: String? {
            switch self {
            case .noSuchMachine:
                return "That printer is not in the shop's list."
            case .declineNeedsTheMac:
                return "Declining a request needs the Mac."
            }
        }
    }

    /// Correct what is left on a spool.
    ///
    /// ── ALL THREE NAMES, BECAUSE THE SHOP HAS THREE ──────────────────────
    ///
    /// What is left lives under `weight` in the store, `remaining` in the
    /// companion's vocabulary, and `weightRemaining` on the wire.
    /// `PATCH /api/inventory/:id` writes every one of them, and its own comment
    /// says why it has to: it used to write `remaining` alone, so "a shop that
    /// weighed a part-used roll at the shelf saw its correction on the shelf
    /// and nowhere else. The next print deducted from the figure it had just
    /// replaced."
    ///
    /// Writing fewer of them here would put that back, quietly, for any shop
    /// whose records carry a name this did not update — `InventorySpool` reads
    /// `remaining ?? weightRemaining ?? weight`, so one stale name is enough to
    /// show the old figure.
    ///
    /// The clamp is the endpoint's, to the gram: a correction of half a tonne
    /// is a typo, and a negative one is not a spool.
    func setSpoolRemaining(spoolId: String, grams: Int) throws {
        let clamped = Double(min(50_000, max(0, grams)))
        try book.updateRecord(collection: "inventory", id: spoolId) { record in
            record["weight"] = .number(clamped)
            record["remaining"] = .number(clamped)
            record["weightRemaining"] = .number(clamped)
        }
    }

    /// Triage a walk-in request.
    ///
    /// ── DECLINING IS NOT A STATUS CHANGE ─────────────────────────────────
    ///
    /// `PATCH /api/waiting-list/:id` treats `declined` differently from the
    /// rest: it appends the request to `waitingListHistory` with a `declinedAt`
    /// and REMOVES it from `waitingList`. That is a move between collections,
    /// and the second half of it is a deletion.
    ///
    /// This phone cannot express a deletion. Nothing here writes a tombstone,
    /// so `changesToSend` would carry the declined record as an ordinary edit
    /// and the Mac would fold it straight back into `waitingList` — leaving a
    /// request the shop declined sitting in its queue, and its history without
    /// the entry. Setting the field would look like it worked and quietly
    /// produce a different book from the one being online produces.
    ///
    /// So it is refused, and the caller falls through to the desktop, which
    /// fails honestly when the Mac is away.
    func setWaitingStatus(id: String, to status: String) throws {
        guard status != "declined" else { throw Refusal.declineNeedsTheMac }
        try book.updateRecord(collection: "waitingList", id: id) { record in
            record["status"] = .string(status)
        }
    }
}
