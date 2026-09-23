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
        /// A new record the shop's rule would not make — a spool with no
        /// material, which no job can ever be matched to.
        case noMaterial
        case recordHasNoId
        case idTaken

        var errorDescription: String? {
            switch self {
            case .noSuchMachine:
                return L10n.tr("error.no_such_machine")
            case .declineNeedsTheMac:
                return L10n.tr("error.decline_needs_mac")
            case .noMaterial:
                return L10n.tr("error.material_required")
            case .recordHasNoId, .idTaken:
                return L10n.tr("error.record_not_added")
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

    // MARK: - Booking a roll in

    /// Put a roll on the shelf.
    func addSpool(_ record: [String: JSONValue]) throws {
        try book.appendRecord(collection: "inventory", record: record)
    }

    /// Several identical rolls, in one write.
    func addSpools(_ records: [[String: JSONValue]]) throws {
        try book.appendRecords(collection: "inventory", records: records)
    }

    /// The id the desk's own endpoint would have given it — `uniqueLanId`'s
    /// shape, so a roll reads the same wherever it was booked in.
    static func newSpoolId(now: Date = Date()) -> String {
        let ms = Int(now.timeIntervalSince1970 * 1000)
        return "spool-\(ms)-\(String(format: "%04x", UInt16.random(in: .min ... .max)))"
    }

    /// `count` ids, all different. Minted in the same millisecond, so the
    /// random tail is all that separates them — and 1 in 65,536 is too often
    /// to leave to chance when a shop books in fifty boxes.
    static func newSpoolIds(_ count: Int, now: Date = Date()) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        while ids.count < count {
            let id = newSpoolId(now: now)
            if seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    /// A roll, built the way `POST /api/inventory` builds one.
    ///
    /// ── THE SAME TWO RULES, IN THE SAME ORDER ────────────────────────────
    ///
    /// `KhaytSpoolEdit.newSpool` makes the record from what it arrived as,
    /// then `applyEdit` sets what is left and the numbers off the label. Both
    /// run in KhaytCore here, as they do in the endpoint, so a roll booked in
    /// on a phone in a car park is the record the desk would have written —
    /// what follows `applyEdit` is the endpoint's own field work, copied line
    /// for line. `SpoolBookingTests` pins the record that comes out; if the
    /// endpoint's field work changes, this has to change with it.
    ///
    /// ── TWO THINGS THAT ARE THE SHOP'S, NOT THE PHONE'S ─────────────────
    ///
    /// The DAY is the local calendar day. The endpoint's comment is about
    /// exactly this phone: it once dated rolls with `ISO8601DateFormatter`,
    /// which is UTC, and "a roll booked in at 02:00 in Riyadh was shelved
    /// under yesterday". The phone is in the shop's time zone for the same
    /// reason the shop is.
    ///
    /// The BRANCH is the one the book's settings say the desk is showing,
    /// which is what the endpoint uses when a caller names none.
    ///
    /// ── AND ONE THING DELIBERATELY NOT DONE ──────────────────────────────
    ///
    /// The colour library is not taught. That lives in `settings`, and the fold
    /// on the Mac carries records and tombstones, never settings — a variant
    /// learned here would vanish on the way. The endpoint hands `applyEdit` a
    /// scratch settings object too, and nothing on this phone names a variant.
    static func spoolRecord(from draft: SpoolDraft, engine: KhaytEngine,
                            settings: [String: JSONValue], id: String,
                            now: Date = Date()) async throws -> [String: JSONValue] {
        let material = draft.material.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !material.isEmpty else { throw Refusal.noMaterial }
        let grams = Double(min(50_000, max(1, draft.weightGrams)))
        let today = localDay(now)

        var input: [String: JSONValue] = [
            "material": .string(InputLimits.clamp(material, max: InputLimits.maxMaterial)),
            "weight": .number(grams),
            "color": .string(InputLimits.clamp(draft.colorHex.isEmpty ? "#888888" : draft.colorHex, max: 32)),
            "materialType": .string("fdm"),
        ]
        if let cost = draft.costValue { input["cost"] = .number(cost) }
        let lot = InputLimits.clamp(draft.lot.trimmingCharacters(in: .whitespacesAndNewlines))
        if !lot.isEmpty { input["lot"] = .string(lot) }
        if case .string(let branch)? = settings["activeLocationId"], !branch.isEmpty {
            input["locationId"] = .string(branch)
        }

        let made = try await engine.newSpool(input, id: id, today: today)
        guard case .object? = made.spool, let spool = made.spool else { throw Refusal.noMaterial }

        var edit: [String: JSONValue] = ["weight": .number(grams)]
        if let p = Int(draft.printTemp.trimmingCharacters(in: .whitespaces)), p > 0 { edit["printTemp"] = .number(Double(p)) }
        if let b = Int(draft.bedTemp.trimmingCharacters(in: .whitespaces)), b > 0 { edit["bedTemp"] = .number(Double(b)) }
        let edited = try await engine.editSpool(spool, input: edit, settings: [:], today: today)
        guard case .object(var record) = edited.spool else { throw Refusal.noMaterial }

        // The record's own fields, which the shelf's rule has never owned.
        let brand = InputLimits.clamp(draft.brand.trimmingCharacters(in: .whitespacesAndNewlines))
        if !brand.isEmpty { record["brand"] = .string(brand) }
        let sku = InputLimits.clamp(draft.sku.trimmingCharacters(in: .whitespacesAndNewlines))
        if !sku.isEmpty { record["sku"] = .string(sku) }
        if let code = ProductBarcode.normalize(draft.barcode) { record["barcode"] = .string(code) }

        // All three names for what is left, as the endpoint writes them.
        let left = record["weight"] ?? .number(grams)
        record["remaining"] = left
        record["weightRemaining"] = left
        if case .number(let w) = left, case .number(let arrived)? = record["spoolWeight"], w > arrived {
            record["spoolWeight"] = .number(w)
        }
        record["weightTotal"] = record["spoolWeight"]
        record["addedAt"] = .string(StoreWriter.iso(now))
        return record
    }

    /// `localDay()` in `lib/lan-server.js`: the calendar day where the shop is.
    static func localDay(_ date: Date, in zone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
