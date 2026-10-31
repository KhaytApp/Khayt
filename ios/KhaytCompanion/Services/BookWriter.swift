import Foundation
import KhaytCore

/**
 * Changing the shop's records on the phone, with the Mac switched off.
 *
 * ── A STATUS MOVE RUNS THE SHOP'S RULE; EVERY OTHER WRITE IS A FIELD SET ──
 *
 * Most of these set fields on one record and stamp it. Moving a job is the
 * exception: `setOrderStatus` runs the shop's own status rule — `gate` and
 * `apply` from `lib/order-status.js`, and the deductions in
 * `lib/order-deduction.js` — through the engine, the same expression the Mac
 * runs (`KhaytEngine.moveJob`).
 *
 * It used to be a plain field set, for parity with `lib/lan-server.js`'s
 * `PATCH /api/orders/:id`. That was superseded on 2026-10-30 (Turki): a job
 * finished on the phone kept its filament on the shelf and had no
 * `completedAt`, so the stock was wrong and the job was missing from every
 * figure that counts finished work by the day it was finished. Moving it on
 * the Mac did both. So the phone now moves a job as the Mac does — the stage,
 * `statusHistory`, `completedAt`, the quote and cancel days, the grams off the
 * spools and the packaging off the consumables — and writes the job, the
 * spools and the consumables in ONE write, so the shelf and the job can never
 * disagree about whether it was finished.
 *
 * WHAT IT STILL DOES NOT DO is reach anybody. The rule asks for a webhook, a
 * Telegram message, an email and a portal refresh on every move; this phone
 * sends none of them, exactly as before. Nor does it number an invoice (see
 * `Invoice.swift`), write the activity log, or take a model off Print next —
 * those stay with the Mac and the PC.
 *
 * The no-book path — a LAN PATCH to an older desktop — is unchanged: the
 * desktop decides what that move does.
 *
 * ── WHY EVERY WRITE GOES THROUGH `updateRecord` ───────────────────────────
 *
 * It stamps `rev` and `updatedAt`. That stamp is the entire reason an edit made
 * here can ever reach the Mac: `changesToSend` compares revisions, and the Mac's
 * fold keeps the higher one. An unstamped edit is invisible to the first and
 * loses to the second — it would sit on the phone looking saved and never
 * arrive.
 *
 * A status move is the one write that does not: it changes rows in three
 * collections at once, so it stamps each row it changed itself (`putBack`, the
 * Mac's `Shop.write`) and swaps the whole book in one `CompanionBook.update`.
 */
struct BookWriter {

    let book: CompanionBook

    /// Advance or set a job's stage, by the shop's own status rule.
    ///
    /// `KhaytEngine.moveJob` is the Mac's expression: `gate`, then `apply`,
    /// then the deductions `apply` asks for, on the spools and consumables it
    /// is handed. Everything it decides comes from the rule, so it matches the
    /// Mac by construction: a quote leaving the Quote column is stamped
    /// accepted on the LOCAL day (once, not for a cancellation); a cancel is
    /// dated and a job brought back loses the date; a completion stamps
    /// `completedAt`, appends `statusHistory` and takes its filament and
    /// packaging off the shelf; a finished job moved back gives back what its
    /// completion took (`returnMaterial`, as the Mac asks), except into
    /// Cancelled, where the piece was made and the filament is gone.
    ///
    /// Worked out against the book as read, and written only if the book is
    /// still that book — otherwise worked out again. The engine is async and
    /// a write is not, so this is the compare-and-swap the Mac's async
    /// `StoreWriter.update` does: a change computed from a stale copy would
    /// put the stale copy back.
    ///
    /// A move the rule refuses throws `MoveRefused`, NOT a `Refusal`: a
    /// `Refusal` falls through to the desktop, and a move the shop's rule
    /// refuses must not be made by another route. Returns the rule's notices
    /// (filament taken, a spool running low), by code.
    @discardableResult
    func setOrderStatus(orderId: String, to status: String,
                        engine: KhaytEngine, now: Date = Date()) async throws -> [Notice] {
        struct Moved: Error {}
        for _ in 0..<5 {
            let store = try book.read()
            let orders = Self.rows(store, "printLog")
            guard let order = orders.first(where: { Self.rowId($0) == orderId }) else {
                throw Refusal.noSuchOrder
            }
            var settings: [String: JSONValue] = [:]
            if case .object(let s)? = store["settings"] { settings = s }
            let inventory = Self.rows(store, "inventory")
            let consumables = Self.rows(store, "consumables")

            let move = try await engine.moveJob(
                order: order, to: status, orders: orders, settings: settings,
                inventory: inventory, consumables: consumables,
                machines: Self.rows(store, "machines"),
                now: now, today: Self.localDay(now))
            guard move.ok else { throw MoveRefused(gate: move.gate) }
            guard case .object(var moved)? = move.order else { throw Refusal.noSuchOrder }
            // A completion asks for a survey token, minted by the host because
            // a pure module has no random source. The format is the shared one.
            if move.performed?.contains("ensure_survey_token") == true, moved["surveyToken"] == nil {
                moved["surveyToken"] = .string(Self.surveyToken())
            }
            // Everything else the move asked for — the webhooks, the Telegram
            // message, the email, the portal refresh, the activity log, the
            // redraws — is not done here. See the top of this file.

            var next = store
            Self.putBack(&next, "printLog", changed: [.object(moved)])
            Self.putBack(&next, "inventory", changed: move.inventory ?? [])
            Self.putBack(&next, "consumables", changed: move.consumables ?? [])
            // Nothing changed — a job moved to where it already is. No write,
            // no stamp: a stamp would outrank a real edit made on the Mac.
            guard next != store else { return move.notices ?? [] }
            do {
                try book.update { root in
                    guard root == store else { throw Moved() }
                    root = next
                }
                return move.notices ?? []
            } catch is Moved {
                continue
            }
        }
        throw StoreWriter.Refusal.unreadable("the book kept changing while this change was being made; try again")
    }

    /// A move the shop's status rule refused (`order-status.gate`), said in
    /// the person's language. The code is the rule's; the sentence is ours.
    struct MoveRefused: Error, LocalizedError, Equatable {
        let code: String?
        let params: [String: JSONValue]

        init(gate: StatusGate) {
            code = gate.block?.code
            params = gate.block?.params ?? [:]
        }

        var errorDescription: String? {
            switch code {
            case "production_paused":
                return L10n.tr("move.refused.production_paused")
            case "wip_blocked":
                let col: String = { if case .string(let c)? = params["col"] { return c } else { return "" } }()
                let n: Int = { if case .number(let v)? = params["n"] { return Int(v) } else { return 0 } }()
                let named = L10n.tr("status." + col)
                return L10n.format("move.refused.wip_blocked", named == "status." + col ? col : named, n)
            case "assembly_not_assembled":
                return L10n.tr("move.refused.assembly_not_assembled")
            case "assembly_parts":
                let parts: String = { if case .string(let p)? = params["parts"] { return p } else { return "" } }()
                return L10n.format("move.refused.assembly_parts", parts)
            case "stage_not_a_status":
                return L10n.tr("move.refused.stage_not_a_status")
            default:
                return L10n.tr("move.refused")
            }
        }
    }

    /// What a move's notice says, in the person's language — the Mac's
    /// `Words.sentence(for:)`. The codes come from `lib/order-status.js` and
    /// `lib/order-deduction.js`. A code with no sentence here is shown as the
    /// code: it reads as wrong, which is the point — a notice that renders as
    /// nothing was never delivered.
    static func sentence(for notice: Notice) -> String {
        let p = notice.params
        func int(_ k: String) -> Int { if case .number(let v)? = p[k] { return Int(v) } else { return 0 } }
        func text(_ k: String) -> String { if case .string(let v)? = p[k] { return v } else { return "" } }
        switch notice.code {
        case "due_extended":
            return L10n.format("move.note.due_extended", int("days"), text("date"))
        case "filament_deducted":
            return L10n.format("move.note.filament_deducted", L10n.grams(int("weight")), int("spools"))
        case "filament_deducted_low":
            return L10n.format("move.note.filament_deducted_low", L10n.grams(int("weight")), int("spools"), int("low"))
        case "filament_returned":
            return L10n.format("move.note.filament_returned", L10n.grams(int("weight")))
        case "packaging_deducted":
            return L10n.tr("move.note.packaging_deducted")
        case "consumable_low", "packaging_low":
            return L10n.format("move.note.low", text("name"))
        default:
            return notice.code
        }
    }

    /// Put moved rows back where they were, stamping only the ones that
    /// changed — the Mac's `Shop.write`. A row stamped without a change is an
    /// edit nobody made, and on a phone a sync behind it would win.
    private static func putBack(_ root: inout [String: JSONValue], _ collection: String,
                                changed: [JSONValue]) {
        guard !changed.isEmpty, case .array(var rows)? = root[collection] else { return }
        var byId: [String: JSONValue] = [:]
        for row in changed { if let id = rowId(row) { byId[id] = row } }
        var touched = false
        for i in rows.indices {
            guard let id = rowId(rows[i]), let next = byId[id], next != rows[i],
                  case .object(var now) = next else { continue }
            StoreWriter.stamp(&now)
            rows[i] = .object(now)
            touched = true
        }
        if touched { root[collection] = .array(rows) }
    }

    private static func rows(_ store: [String: JSONValue], _ collection: String) -> [JSONValue] {
        if case .array(let r)? = store[collection] { return r }
        return []
    }

    private static func rowId(_ row: JSONValue) -> String? {
        if case .object(let o) = row, case .string(let id)? = o["id"] { return id }
        return nil
    }

    /// `srv-` and twelve random bytes in hex — the format `lib/order-status.js`
    /// defines and the Mac's `Shop.surveyToken` mints.
    static func surveyToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return "srv-" + bytes.map { String(format: "%02x", $0) }.joined()
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
        /// A new record the shop's rule would not make — a spool with no
        /// material, which no job can ever be matched to.
        case noMaterial
        /// An order with no project name, which the endpoint answers 400.
        case noProject
        case recordHasNoId
        case idTaken
        /// A spool this book does not hold — gone already, or never sent.
        case noSuchSpool
        case noSuchOrder
        /// Recording it would owe a webhook or an email this phone cannot send.
        case paymentWouldReach([String])
        /// An expense of nothing, which the endpoint answers 400.
        case noAmount

        var errorDescription: String? {
            switch self {
            case .noSuchMachine:
                return L10n.tr("error.no_such_machine")
            case .noMaterial:
                return L10n.tr("error.material_required")
            case .noProject:
                return L10n.tr("error.project_required")
            case .recordHasNoId, .idTaken:
                return L10n.tr("error.record_not_added")
            case .noSuchSpool:
                return L10n.tr("error.no_such_spool")
            case .noSuchOrder:
                return L10n.tr("alert.print.no_order")
            case .paymentWouldReach(let channels):
                let names = Set(channels.map { $0 == "email" ? L10n.tr("pay.reach.email") : L10n.tr("pay.reach.webhook") })
                return L10n.format("pay.refused", ListFormatter.localizedString(byJoining: names.sorted()))
            case .noAmount:
                return L10n.tr("error.amount_required")
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
    /// ── DECLINING IS A MOVE, AND THE PHONE CAN MAKE IT ───────────────────
    ///
    /// `PATCH /api/waiting-list/:id` treats `declined` differently from the
    /// rest: the request goes into `waitingListHistory` (same id, `status:
    /// "declined"`, a `declinedAt`) and OUT of `waitingList`. A move between
    /// collections, whose second half is a deletion.
    ///
    /// This used to be refused, on the grounds that the phone could not
    /// express a deletion — and without one, the Mac would fold the declined
    /// record straight back into the queue. It can: a deletion travels as a
    /// TOMBSTONE, which `changesToSend` sends and `applyDeltas` on the Mac (and
    /// every other device) removes the record by, reporting a conflict if the
    /// record had been edited there since. So the three writes the endpoint
    /// makes are made here, in one write: the history entry, the removal, and
    /// the tombstone that carries the removal home — carrying the rev the
    /// phone saw, which is what the conflict check measures against.
    ///
    /// `converted` is the same move with the other word — what the desktop's
    /// `promoteWaitingItem` writes when a request becomes an order.
    func setWaitingStatus(id: String, to status: String, now: Date = Date()) throws {
        guard status == "declined" || status == "converted" else {
            try book.updateRecord(collection: "waitingList", id: id) { record in
                record["status"] = .string(status)
            }
            return
        }
        try book.update { root in
            guard case .array(var queue)? = root["waitingList"],
                  let at = queue.firstIndex(where: {
                      if case .object(let o) = $0, o["id"] == .string(id) { return true }
                      return false
                  }),
                  case .object(let item) = queue[at] else { return }   // gone already: nothing to decline
            let when = StoreWriter.iso(now)

            var entry = item
            entry["status"] = .string(status)
            entry[status == "declined" ? "declinedAt" : "convertedAt"] = .string(when)
            // A new record in its own collection, so it starts its own history.
            entry["rev"] = nil
            StoreWriter.stamp(&entry)
            var history: [JSONValue] = []
            if case .array(let had)? = root["waitingListHistory"] { history = had }
            history.append(.object(entry))
            root["waitingListHistory"] = .array(history)

            queue.remove(at: at)
            root["waitingList"] = .array(queue)

            var rev = 0.0
            if case .number(let n)? = item["rev"] { rev = n }
            var tombs: [JSONValue] = []
            if case .array(let had)? = root["tombstones"] { tombs = had }
            tombs.append(.object(["id": .string(id), "collection": .string("waitingList"),
                                  "rev": .number(rev), "deletedAt": .string(when)]))
            root["tombstones"] = .array(tombs)
        }
    }

    // MARK: - Taking a roll off the shelf

    /// Delete a spool, as `DELETE /api/inventory/:id` does.
    ///
    /// ── THE TOMBSTONE IS WRITTEN FOR US, AND THAT IS THE POINT ───────────
    ///
    /// `StoreWriter.update` records a tombstone for every record a write
    /// removes (#1609), carrying the rev the phone last saw. So removing the
    /// row is the whole of it: `changesToSend` sends the tombstone, and the
    /// Mac's `applyDeltas` takes the spool off — or, if someone edited it
    /// there since, keeps the edit and reports the conflict.
    ///
    /// This used to be a network call only, and the native Mac serves no
    /// `DELETE /api/inventory` at all — so for a shop on the Mac app the
    /// button answered 404 every time.
    ///
    /// A spool that is not in the book is not "deleted": nothing is written,
    /// and the caller is told, rather than a tombstone being minted for a
    /// record this phone has never seen.
    func deleteSpool(id: String) throws {
        var found = false
        try book.update { root in
            guard case .array(var rows)? = root["inventory"],
                  let at = rows.firstIndex(where: {
                      if case .object(let o) = $0, o["id"] == .string(id) { return true }
                      return false
                  }) else { return }
            rows.remove(at: at)
            root["inventory"] = .array(rows)
            found = true
        }
        if !found { throw Refusal.noSuchSpool }
    }

    // MARK: - Waste and expenses

    /// Log a failed print, as `POST /api/waste` does — the record, the shop's
    /// calendar day, and the optional deduction, in ONE write.
    ///
    /// ── THE DEDUCTION IS THE ENDPOINT'S, PLUS THE OTHER TWO NAMES ────────
    ///
    /// The endpoint takes the grams off the FIRST spool of that material, from
    /// `weight`, floored at zero. Same here, inside the same write as the
    /// entry, so the two cannot land apart. What it does not do is write
    /// `remaining` and `weightRemaining` — and on this phone `InventorySpool`
    /// reads those first, so a deduction written to `weight` alone would show
    /// the old figure on the shelf. All three are set, as
    /// `setSpoolRemaining` sets them.
    ///
    /// `wasteLog` is not part of the phone's working set. That does not matter
    /// for sending — `changesToSend` sends any record the baseline has never
    /// seen, and the Mac's fold accepts a collection by name — and once the
    /// Mac has it, the next pull simply does not bring it back.
    @discardableResult
    func logWaste(_ entry: WasteEntry, now: Date = Date()) throws -> (entry: [String: JSONValue], deducted: String?) {
        let material = String(entry.material.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !material.isEmpty else { throw Refusal.noMaterial }
        func text(_ s: String, _ max: Int = 500) -> String {
            String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
        }
        func pos(_ v: Double) -> Double { v.isFinite ? max(0, v) : 0 }
        let failure = text(entry.failureType, 60)
        let machine = text(entry.machineId ?? "", 128)
        let record: [String: JSONValue] = [
            "id": .string(Self.lanId("w", now: now)),
            "date": .string(Self.localDay(now)),
            "material": .string(material),
            "failureType": .string(failure.isEmpty ? "other" : failure),
            "weight": .number(pos(entry.weight)),
            "cost": .number(pos(entry.cost)),
            "reason": .string(text(entry.reason)),
            "notes": .string(text(entry.notes)),
            "orderId": .null,
            "machineId": machine.isEmpty ? .null : .string(machine),
        ]
        let grams = pos(entry.weight)
        var deducted: String?
        try book.update { root in
            var log: [JSONValue] = []
            if case .array(let had)? = root["wasteLog"] { log = had }
            var stamped = record
            StoreWriter.stamp(&stamped)
            log.insert(.object(stamped), at: 0)
            root["wasteLog"] = .array(log)

            guard entry.deduct, grams > 0, case .array(var shelf)? = root["inventory"],
                  let at = shelf.firstIndex(where: {
                      if case .object(let o) = $0, o["material"] == .string(material) { return true }
                      return false
                  }),
                  case .object(var spool) = shelf[at] else { return }
            var had = 0.0
            if case .number(let w)? = spool["weight"] { had = w }
            let left = JSONValue.number(max(0, had - grams))
            spool["weight"] = left
            spool["remaining"] = left
            spool["weightRemaining"] = left
            shelf[at] = .object(spool)
            root["inventory"] = .array(shelf)
            if case .string(let sid)? = spool["id"] { deducted = sid }
        }
        return (record, deducted)
    }

    /// File an expense, as `POST /api/expense` does — WITHOUT a receipt.
    ///
    /// A receipt is a file on the desk's disk, named by the desk, and the
    /// record points at it by path. Nothing the phone could write would be a
    /// path that exists there, so an expense with a photo still goes over the
    /// wire (and needs a desktop that serves `/api/expense`). One without is
    /// just a record, and is written here like any other.
    @discardableResult
    func addExpense(_ draft: ExpenseDraft, now: Date = Date()) throws -> [String: JSONValue] {
        let amount = draft.amount.isFinite ? max(0, draft.amount) : 0
        guard amount > 0 else { throw Refusal.noAmount }
        let category = String(draft.category.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        // A receipt's own day, when it was read off one — never a future day,
        // and never anything that is not a plain yyyy-MM-dd.
        let today = Self.localDay(now)
        let day: String = {
            guard let d = draft.date, d.count == 10, d.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                  d <= today else { return today }
            return d
        }()
        var record: [String: JSONValue] = [
            "id": .string(Self.lanId("EXP", now: now)),
            "date": .string(day),
            "category": .string(category.isEmpty ? "other" : category),
            "amount": .number(amount),
            "note": .string(String(draft.note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))),
            "orderId": .null,
            "receiptPath": .null,
            "recurring": .null,
            "nextDue": .null,
            "locationId": .string(""),
        ]
        // As the Mac's sheet writes them: never more VAT than was paid, never
        // negative, and the receipt's identity for the duplicate check.
        if let vat = draft.vatAmount, vat.isFinite {
            record["vatAmount"] = .number(min(max(0, vat), amount))
        }
        if let ref = draft.receiptRef?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
            record["receiptRef"] = .string(String(ref.prefix(300)))
        }
        try book.insertRecord(collection: "expenses", atFront: true) { _ in record }
        return record
    }

    // MARK: - Suppliers

    /// Keep a receipt's seller as a supplier: the row the Mac's "Add as
    /// supplier" writes (`Shop.saveSupplier`) and the other app's
    /// (`renderer/expenses.js`). The number goes in `vat`, the field
    /// `lib/zatca-qr.js` matches on, so the next receipt from this seller
    /// names it. `purchases` is written empty rather than left out, because
    /// every reader of it walks the array unchecked.
    ///
    /// A number the book already holds is not added again. Two rows for one
    /// seller would split its purchases between them. That case returns nil.
    @discardableResult
    func addSupplier(name: String, vatNumber: String, now: Date = Date()) throws -> [String: JSONValue]? {
        let vat = vatNumber.filter(\.isNumber).map { $0.wholeNumberValue.map(String.init) ?? "" }.joined()
        let named = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        struct AlreadyHeld: Error {}
        var added: [String: JSONValue]?
        do {
            try book.insertRecord(collection: "suppliers", atFront: false) { rows in
                // Inside the write, so two taps cannot both find no such row.
                let held = rows.contains {
                    guard !vat.isEmpty, case .object(let o) = $0, case .string(let v)? = o["vat"] else { return false }
                    return v == vat
                }
                if held { throw AlreadyHeld() }
                let record: [String: JSONValue] = [
                    "id": .string(Self.lanId("sup", now: now)),
                    "name": .string(named.isEmpty ? vat : named),
                    "vat": .string(vat),
                    "category": .string("other"),
                    "phone": .string(""),
                    "website": .string(""),
                    "notes": .string(""),
                    "priceList": .array([]),
                    "leadDays": .null,
                    "purchases": .array([]),
                ]
                added = record
                return record
            }
        } catch is AlreadyHeld {
            return nil
        }
        return added
    }

    /// `uniqueLanId(prefix)` in `lib/lan-server.js`: prefix, milliseconds, four
    /// random hex digits — so a record reads the same wherever it was made.
    static func lanId(_ prefix: String, now: Date = Date()) -> String {
        let ms = Int(now.timeIntervalSince1970 * 1000)
        return "\(prefix)-\(ms)-\(String(format: "%04x", UInt16.random(in: .min ... .max)))"
    }

    // MARK: - Money received

    /// Where an order stands, from the shop's own `cashDue` — computed WITH the
    /// settings, so a shop that adds tax on top is judged against price + tax.
    /// (`KhaytEngine.paymentStatus(of:)` takes no settings and would judge the
    /// same order against the bare price.) Paid in full is the comparison
    /// `statusOf` makes: what was paid reaches what is left for cash.
    struct PaymentState: Equatable {
        let billed: Double
        let cashDue: Double
        let paid: Double
        var owed: Double { max(0, ((cashDue - paid) * 100).rounded() / 100) }
        var status: String { paid >= cashDue - 0.005 ? "paid" : paid > 0 ? "partial" : "unpaid" }
    }

    /// `gross` and `cash` are `KhaytEngine.CashDue`'s figures.
    static func paymentState(order: [String: JSONValue], gross: Double, cash: Double) -> PaymentState? {
        // A voided or credited job is not collected, and a free one never was.
        if order["voidedAt"].map({ $0 != .null }) == true || order["creditedAt"].map({ $0 != .null }) == true { return nil }
        guard gross > 0 else { return nil }
        var paid = 0.0
        if case .number(let n)? = order["paidAmount"] { paid = n }
        return PaymentState(billed: gross, cashDue: cash, paid: paid)
    }

    /// Record what a customer has paid, by the shop's own rule
    /// (`KhaytOrderPayment.recordPayment`).
    ///
    /// ── THE TOTAL, NOT THE INSTALMENT ────────────────────────────────────
    ///
    /// The rule sets `paidAmount` to the figure it is given, capped at what the
    /// order bills. So `totalPaid` is everything the customer has paid on this
    /// job, as on the Mac's sheet; the caller adds the money in hand to what was
    /// already paid.
    ///
    /// ── A PAYMENT THAT WOULD REACH SOMEBODY IS REFUSED HERE ──────────────
    ///
    /// The rule can owe a `payment_received` webhook, a `paid` order webhook and
    /// a receipt email. This phone sends none of them, and the Mac's fold of the
    /// phone's change sends none either — so recording it here would be a
    /// payment the customer and the shop's integrations never hear about. The
    /// Mac refuses a payment it cannot announce; so does this, and says where.
    func recordPayment(orderId: String, totalPaid: Double, method: String,
                       engine: KhaytEngine, now: Date = Date()) async throws {
        let store = try book.read()
        guard case .array(let rows)? = store["printLog"],
              let order = rows.first(where: {
                  if case .object(let o) = $0, o["id"] == .string(orderId) { return true }
                  return false
              }) else { throw Refusal.noSuchOrder }
        var settings: [String: JSONValue] = [:]
        if case .object(let st)? = store["settings"] { settings = st }
        var clients: [JSONValue] = []
        if case .array(let c)? = store["clients"] { clients = c }

        let reaches = try await engine.paymentOutbound(order: order, settings: settings, clients: clients)
        if !reaches.isEmpty { throw Refusal.paymentWouldReach(reaches.map(\.channel)) }

        let day = Self.localDay(now)
        let done = try await engine.recordPayment(order: order, amount: max(0, totalPaid), method: method,
                                                  paidAt: day, today: day, settings: settings)
        guard case .object(let paid) = done.order else { throw Refusal.noSuchOrder }
        try book.updateRecord(collection: "printLog", id: orderId) { record in
            for key in ["paidAmount", "paidGross", "paymentMethod", "paidAt", "paymentStatus"] {
                record[key] = paid[key] ?? .null
            }
        }
    }

    /// The Mac's list and order (`Shop.paymentMethods`, from
    /// `renderer/order-flows.js`), so the two apps offer one set of choices.
    static let paymentMethods = ["cash", "mada", "transfer", "stcpay", "applepay", "visa", "other"]

    // MARK: - The customer's log

    /// Append a line to a customer's communications log (`commLog`), stamped
    /// so it travels. The entry is built by the shared rule — see
    /// `KhaytAPIClient.logWhatsApp`.
    func addCommEntry(clientId: String, entry: JSONValue) throws {
        try book.updateRecord(collection: "clients", id: clientId) { record in
            var log: [JSONValue] = []
            if case .array(let had)? = record["commLog"] { log = had }
            log.append(entry)
            record["commLog"] = .array(log)
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
        if let p = PhoneCalculator.wholeNumber(draft.printTemp), p > 0 { edit["printTemp"] = .number(Double(p)) }
        if let b = PhoneCalculator.wholeNumber(draft.bedTemp), b > 0 { edit["bedTemp"] = .number(Double(b)) }
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

    // MARK: - Raising an order

    /// Raise an order or a quote, as `POST /api/orders` would.
    ///
    /// ── NOTHING HERE NEEDS THE MAC ───────────────────────────────────────
    ///
    /// The endpoint takes no number from a shop counter. Its id is the shop's
    /// prefix, the year, the time and four random hex digits — nothing two
    /// devices could hand out twice — and every other field is copied or
    /// defaulted. So the record built here is the one the endpoint writes, and
    /// the Mac folds it in like any other new row. The native Mac serves no
    /// `POST /api/orders` at all, so for a shop on it this is the only way an
    /// order raised on the phone reaches the queue.
    ///
    /// Written at the FRONT of `printLog`, as the endpoint does. The fold on
    /// the Mac appends a record it has not seen, so there it lands at the end;
    /// screens order by date and `queuePos`, not by position in the array.
    func addOrder(_ draft: NewOrderDraft, machines: [MachineInfo], now: Date = Date()) throws -> [String: JSONValue] {
        var made: [String: JSONValue] = [:]
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = try book.read()["settings"] { settings = s }
        try book.insertRecord(collection: "printLog", atFront: true) { rows in
            made = try Self.orderRecord(from: draft, settings: settings, machines: machines,
                                        existing: rows, now: now)
            return made
        }
        return made
    }

    static func orderRecord(from draft: NewOrderDraft, settings: [String: JSONValue],
                            machines: [MachineInfo], existing: [JSONValue],
                            now: Date = Date(), zone: TimeZone = .current) throws -> [String: JSONValue] {
        let project = String(draft.project.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !project.isEmpty else { throw Refusal.noProject }

        let asQuote = draft.isQuote
        let status = asQuote ? "quote" : "pending"
        func setting(_ key: String) -> String? {
            if case .string(let v)? = settings[key], !v.isEmpty { return v }
            return nil
        }
        // The desk's own prefix — `invPrefix`, not an `orderPrefix` that never
        // existed; the endpoint's comment is about exactly that mistake.
        let prefix = asQuote ? (setting("quotePrefix") ?? "QUO") : (setting("invPrefix") ?? "INV")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let year = calendar.component(.year, from: now)
        let ms = Int(now.timeIntervalSince1970 * 1000)
        let id = "\(prefix)-\(year)-\(ms)-\(String(format: "%04x", UInt16.random(in: .min ... .max)))"

        // A machine the shop does not have is refused, as the endpoint's 404.
        var machineId: JSONValue = .null
        var machineName: JSONValue = .null
        if let wanted = draft.machineId, !wanted.isEmpty {
            guard let machine = machines.first(where: { $0.id == wanted }) else { throw Refusal.noSuchMachine }
            machineId = .string(wanted)
            machineName = machine.name.map(JSONValue.string) ?? .null
        }

        let client = String(draft.client.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let material = String(draft.material.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let price = ((SpoolDraft.price(draft.price) ?? 0) * 100).rounded() / 100
        let pending = existing.filter {
            if case .object(let o) = $0, o["status"] == .string("pending") { return true }
            return false
        }.count
        let day = localDay(now, in: zone)
        let stamp = StoreWriter.iso(now)

        var order: [String: JSONValue] = [
            "id": .string(id),
            "date": .string(day),
            "timestamp": .string(stamp),
            "project": .string(project),
            "client": client.isEmpty ? .null : .string(client),
            "clientId": .null,
            "material": material.isEmpty ? .null : .string(material),
            "price": .number(price),
            "status": .string(status),
            "statusHistory": .array([.object(["status": .string(status), "at": .string(stamp)])]),
            "queuePos": .number(Double(pending + 1)),
            "machineId": machineId,
            "machine": machineName,
            "notes": .string(""),
            "dueDate": draft.dueDate.isEmpty ? .null : .string(draft.dueDate),
            "paymentStatus": .string("unpaid"),
            "parts": .array([]),
        ]
        if asQuote {
            var days = 7.0
            if case .number(let n)? = settings["quoteValidityDays"], n > 0 { days = n }
            order["quoteSentAt"] = .string(day)
            order["quoteExpiresAt"] = .string(localDay(now.addingTimeInterval(days * 86_400), in: zone))
            order["quoteVersion"] = .number(1)
        }
        return order
    }
}
