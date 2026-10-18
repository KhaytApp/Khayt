import Foundation
import KhaytCore

/// A question about deleting jobs or customers, held until the shop answers.
///
/// The title and the message are worked out when it is ASKED and frozen in
/// the request: a book that reloads under the dialog must not change what it
/// says, and `askFirst` holds the item, so the records the shop confirmed are
/// the ones deleted.
struct RecordDeleteRequest: Identifiable, Equatable {
    let id = UUID()
    /// What the confirmation deletes — only records the rule allows.
    let ids: [String]
    let title: String
    let message: String
}

/// Deleting a job or a customer.
///
/// ── NEVER A JOB WITH AN INVOICE NUMBER OR A PAYMENT ──────────────────────
///
/// The rule is `lib/record-delete.js`, the one the desktop's `deleteLog` asks:
/// a quote nobody accepted, or a job that was never numbered and never paid,
/// may go. Anything invoiced or paid is CANCELLED instead (`cancelInstead`,
/// the status path), so the invoice sequence keeps every number it handed
/// out. A customer may go only with no job in any status and no gift card.
///
/// The verdicts are read with the book (`deleteVerdicts`), so a menu greys
/// itself and says why without asking the engine per row; the write asks the
/// rule again, inside the store write, on the newest book — a job paid on the
/// phone a second ago is skipped, not deleted.
///
/// ── NOTHING GOES BUT THE JOB ─────────────────────────────────────────────
///
/// The job goes, with its print runs and photos (fields on it). Money spent
/// and filament used are real either way, so the expenses booked to it, the
/// spool usage rows that name it, and its waste, time and points rows all
/// STAY, unlinked — the P&L's expenses and a spool's remaining (its stored
/// `weight`) do not move. Payments are never touched — a job with one cannot
/// be deleted. A job whose customer link is up has the link taken down, as
/// Unpublish would.
///
/// Undoable, through `PendingUndo`: Undo puts the job back and relinks its
/// rows (`restoreOrders`). The write chain gives a put-back record a fresh id
/// (`StoreWriter.reviveUnderNewIds`), so a deleted quote returns under a new
/// one — a delete has already been synced as final.
extension Shop {

    // MARK: - What may be deleted

    /// Whoever is here may delete jobs from this book at all: a book this Mac
    /// writes, the role allows it, and the rule has been read.
    var mayDeleteJobs: Bool {
        canMoveJobs && lockAllows("orders", "delete") && deleteVerdicts != nil
    }

    /// The same, for customers.
    var mayDeleteCustomers: Bool {
        canMoveJobs && lockAllows("clients", "delete") && deleteVerdicts != nil
    }

    /// Why the rule refuses to delete this job — "Invoiced: cancel instead" —
    /// or nil when it may go.
    func jobDeleteRefusal(_ id: Order.ID) -> String? {
        guard let reason = deleteVerdicts?.orders[id] else { return nil }
        return words.callIt(reason == "paid" ? "mac.delete_job_paid" : "mac.delete_job_invoiced")
    }

    /// Why this customer may not be deleted — "Has 3 jobs" — or nil.
    ///
    /// The count is the larger of what this screen shows (`Customer.orders`,
    /// which also matches unlinked jobs by name) and what the rule counted, so
    /// the sentence never says fewer jobs than the row beside it. A customer
    /// with no record exists only as a name on jobs, so always has some.
    func customerDeleteRefusal(_ person: Customer) -> String? {
        let verdict = deleteVerdicts?.clients[person.id]
        let jobs = max(person.jobCount, verdict?.jobs ?? 0)
        if jobs > 0 || person.record == nil {
            return words.counting(max(jobs, 1), "mac.customer_has_jobs")
        }
        if let verdict, verdict.giftCards > 0 {
            return words.callIt("mac.customer_has_cards", ["n": .number(Double(verdict.giftCards))])
        }
        return nil
    }

    /// The jobs list's chosen rows, in the order the book holds them.
    func selectJobs(_ ids: Set<Order.ID>) {
        jobSelection = ids
        if ids.isEmpty { selection = nil; return }
        if let s = selection, ids.contains(s) { return }
        selection = orders.first { ids.contains($0.id) }?.id ?? ids.first
    }

    /// The customers list's chosen rows.
    func selectCustomers(_ ids: Set<Customer.ID>) {
        customerSelections = ids
        if ids.isEmpty { customerSelection = nil; return }
        if let s = customerSelection, ids.contains(s) { return }
        customerSelection = shownCustomers.first { ids.contains($0.id) }?.id ?? ids.first
    }

    /// The jobs Delete… would be asked about on the screen in front: every row
    /// chosen in the jobs list, or the card selected on the board.
    var frontJobIds: [Order.ID] {
        guard showingJobWork else { return [] }
        let chosen: Set<Order.ID> = showingBoard ? Set([selection].compactMap { $0 })
                                                 : (jobSelection.isEmpty ? Set([selection].compactMap { $0 }) : jobSelection)
        return orders.map(\.id).filter { chosen.contains($0) }
    }

    /// The customers chosen in the customers list.
    var frontCustomerIds: [Customer.ID] {
        guard showingCustomers else { return [] }
        let chosen = customerSelections.isEmpty ? Set([customerSelection].compactMap { $0 }) : customerSelections
        return shownCustomers.map(\.id).filter { chosen.contains($0) }
    }

    // MARK: - File ▸ Delete… (⌘⌫), for whatever is in front

    enum DeleteTarget: Equatable {
        case library
        case jobs([Order.ID])
        case customers([Customer.ID])
    }

    /// What ⌘⌫ would ask about: the library's visible selection, the chosen
    /// jobs, or the chosen customers — and only when at least one of them may
    /// go. Nil greys the menu item.
    var deleteTarget: DeleteTarget? {
        if showingLibrary { return librarySelectionToDelete.isEmpty ? nil : .library }
        if showingJobWork {
            let ids = frontJobIds
            guard mayDeleteJobs, ids.contains(where: { jobDeleteRefusal($0) == nil }) else { return nil }
            return .jobs(ids)
        }
        if showingCustomers {
            let ids = frontCustomerIds
            guard mayDeleteCustomers,
                  ids.contains(where: { id in shownCustomers.first { $0.id == id }.map { customerDeleteRefusal($0) == nil } ?? false })
            else { return nil }
            return .customers(ids)
        }
        return nil
    }

    /// ⌫ or ⌘⌫: ask about what is in front. Unlike the menu, a key pressed on
    /// a job the rule refuses is ANSWERED — it says why, rather than beeping.
    func askToDeleteFrontmost() {
        if showingLibrary { askToDeleteLibrarySelection(); return }
        if showingJobWork { askToDeleteJobs(frontJobIds); return }
        if showingCustomers { askToDeleteCustomers(frontCustomerIds) }
    }

    // MARK: - Jobs

    /// Ask to delete these jobs: the deletable ones go to the question, which
    /// names them, what goes with them and how many were left out. When none
    /// may go, the shop is told why instead.
    func askToDeleteJobs(_ ids: [Order.ID]) {
        moveProblem = nil
        let chosen = orders.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return }
        guard canMoveJobs else { moveProblem = lockedReason; return }
        guard permitted("orders", "delete") else { return }
        guard deleteVerdicts != nil else { moveProblem = words.callIt("mac.move_no_engine"); return }
        let free = chosen.filter { jobDeleteRefusal($0.id) == nil }
        guard !free.isEmpty else {
            if chosen.count == 1, let why = jobDeleteRefusal(chosen[0].id) {
                moveProblem = words.callIt("mac.delete_refused",
                                           ["name": .string(shownTitle(of: chosen[0])), "why": .string(why)])
            } else {
                moveProblem = words.callIt("mac.delete_jobs_none")
            }
            return
        }
        let title = free.count == 1
            ? words.callIt("mac.delete_product_q", ["name": .string(shownTitle(of: free[0]))])
            : words.counting(free.count, "mac.delete_jobs_title")
        let names = free.map { shownTitle(of: $0) }
        pendingJobDelete = RecordDeleteRequest(
            ids: free.map(\.id), title: title,
            message: Self.jobDeleteLines(ids: free.map(\.id), names: names,
                                         skipped: chosen.count - free.count,
                                         inventory: inventoryRows, expenses: expenseRows,
                                         unlinked: [wasteRows, timeEntryRows, loyaltyRows],
                                         words: words).joined(separator: "\n"))
    }

    /// What the job question says under its title: which jobs, what goes with
    /// them, what stays, what was left out, and that Undo brings it back.
    static func jobDeleteLines(ids: [String], names: [String], skipped: Int,
                               inventory: [JSONValue], expenses: [JSONValue],
                               unlinked: [[JSONValue]], words: Words) -> [String] {
        let wanted = Set(ids)
        func pointsAt(_ row: JSONValue) -> Bool {
            guard let o = asObject(row), let id = plainString(o["orderId"]) else { return false }
            return wanted.contains(id)
        }
        let usage = inventory.compactMap(asObject).reduce(0) { sum, spool in
            guard case .array(let h)? = spool["usageHistory"] else { return sum }
            return sum + h.count(where: pointsAt)
        }
        let booked = expenses.count(where: pointsAt)
        let kept = unlinked.reduce(0) { $0 + $1.count(where: pointsAt) }

        var lines: [String] = []
        if names.count > 1 {
            lines += names.prefix(deleteNamesShown).map { "\u{2022} " + $0 }
            if names.count > deleteNamesShown {
                lines.append(words.callIt("mac.delete_and_more",
                                          ["n": .number(Double(names.count - deleteNamesShown))]))
            }
            lines.append("")
        }
        lines.append(words.callIt("mac.delete_jobs_goes"))
        if usage + booked + kept > 0 {
            lines.append(words.callIt("mac.delete_jobs_unlinked", ["n": .number(Double(usage + booked + kept))]))
        }
        if skipped > 0 {
            lines.append("")
            lines.append(words.callIt("mac.delete_jobs_skipped", ["n": .number(Double(skipped))]))
        }
        lines.append("")
        lines.append(words.callIt("mac.undo_after"))
        return lines
    }

    /// The collections a job's delete reads and may change.
    nonisolated static let jobDeleteCollections =
        ["printLog", "inventory", "expenses", "wasteLog", "timeEntries", "loyaltyLedger"]

    /// The delete, inside the store write: the rule picks which of `ids` may
    /// go (on THIS book, the newest), takes them out and tidies what pointed
    /// at them; the collections it changed are written back, no others.
    static func applyJobDeletes(to root: inout [String: JSONValue], ids: [String],
                                engine: KhaytEngine) async throws -> KhaytEngine.Deleted {
        var book: [String: JSONValue] = [:]
        for c in jobDeleteCollections { book[c] = .array(rows(root, c)) }
        let out = try await engine.deleteOrders(book: book, ids: ids)
        guard !out.deleted.isEmpty else { return out }
        for c in jobDeleteCollections {
            guard let next = out.book[c], next != book[c] else { continue }
            root[c] = next
        }
        return out
    }

    /// Undo's half of `applyJobDeletes`.
    static func applyJobRestore(to root: inout [String: JSONValue], deleted: [JSONValue],
                                engine: KhaytEngine) async throws {
        var book: [String: JSONValue] = [:]
        for c in jobDeleteCollections { book[c] = .array(rows(root, c)) }
        let back = try await engine.restoreOrders(book: book, deleted: deleted)
        for c in jobDeleteCollections {
            guard let next = back[c], next != book[c] else { continue }
            root[c] = next
        }
    }

    /// Delete the jobs the shop confirmed. Each is asked about again inside
    /// the write, and any the rule now refuses is left and counted.
    func deleteJobs(_ ids: [Order.ID]) async {
        moveProblem = nil
        moveNotices = []
        guard permitted("orders", "delete") else { return }
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return }
        guard let engine else { moveProblem = words.callIt("mac.move_no_engine"); return }
        // The links that are up, read BEFORE the records go.
        let published = ids.filter { isPortalPublished($0) }.compactMap { id in portalToken(id).map { (id, $0) } }
        // On the stack at the click, against the write below (`PendingUndo`).
        let pending: PendingUndo<[JSONValue]> =
            pendingUndo(named: words.callIt("mac.delete_jobs_action")) { shop, gone in
                shop.putBackJobs(gone, in: build)
            }
        defer { pending.drop() }
        var outcome: KhaytEngine.Deleted?
        do {
            try await StoreWriter.updateAsync(build) { root in
                outcome = try await Self.applyJobDeletes(to: &root, ids: ids, engine: engine)
            }
            guard let outcome else { return }
            let gone = Set(outcome.deletedIds)
            // A link taken down below comes back down: Undo restores the job
            // without claiming a page that is no longer there.
            let downed = Set(published.map(\.0)).intersection(gone)
            pending.keepUnlessEmpty(outcome.deleted.map { Self.unpublished($0, downed) })
            if let s = selection, gone.contains(s) { selection = nil }
            jobSelection.subtract(gone)
            await load(source)
            var said: [String] = []
            if !gone.isEmpty { said.append(words.counting(gone.count, "mac.deleted_jobs")) }
            if !outcome.skipped.isEmpty {
                said.append(words.callIt("mac.delete_jobs_skipped", ["n": .number(Double(outcome.skipped.count))]))
            }
            moveNotices = said
            await takeDownLinks(published.filter { downed.contains($0.0) }.map(\.1), engine: engine)
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch {
            moveProblem = self.said(error)
        }
    }

    /// One deleted job's undo record, with `cloudPublished` off when its link
    /// is being taken down.
    nonisolated static func unpublished(_ item: JSONValue, _ downed: Set<String>) -> JSONValue {
        guard case .object(var d) = item, case .string(let id)? = d["id"], downed.contains(id),
              case .object(var order)? = d["order"] else { return item }
        order["cloudPublished"] = .bool(false)
        d["order"] = .object(order)
        return .object(d)
    }

    /// Put deleted jobs back, with everything that went with them.
    private func putBackJobs(_ gone: [JSONValue], in build: StoreReader.Build) {
        guard permitted("orders", "edit"), let engine else { return }
        let shop = self
        Task { do {
            try await StoreWriter.updateAsync(build) { root in
                try await Self.applyJobRestore(to: &root, deleted: gone, engine: engine)
            }
            await shop.load(shop.source)
        } catch {
            shop.moveProblem = self.said(error)
        } }
    }

    /// The job menus' "Cancel Job": the status path, offered where Delete is
    /// refused, so an invoiced job leaves the work without leaving the book.
    func cancelInstead(_ id: Order.ID) async {
        if let ask = questionFor(id, moving: .cancelled) { ask(); return }
        await moveJob(id, to: .cancelled)
    }

    // MARK: - Customers

    /// Ask to delete these customers — the ones with nothing in the book.
    func askToDeleteCustomers(_ ids: [Customer.ID]) {
        moveProblem = nil
        let chosen = shownCustomers.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return }
        guard canMoveJobs else { moveProblem = lockedReason; return }
        guard permitted("clients", "delete") else { return }
        guard deleteVerdicts != nil else { moveProblem = words.callIt("mac.move_no_engine"); return }
        let free = chosen.filter { customerDeleteRefusal($0) == nil }
        guard !free.isEmpty else {
            if chosen.count == 1, let why = customerDeleteRefusal(chosen[0]) {
                moveProblem = words.callIt("mac.delete_refused",
                                           ["name": .string(chosen[0].name), "why": .string(why)])
            } else {
                moveProblem = words.callIt("mac.delete_customers_none")
            }
            return
        }
        let title = free.count == 1
            ? words.callIt("mac.delete_product_q", ["name": .string(free[0].name)])
            : words.counting(free.count, "mac.delete_customers_title")
        var lines: [String] = []
        if free.count > 1 {
            lines += free.prefix(Self.deleteNamesShown).map { "\u{2022} " + $0.name }
            if free.count > Self.deleteNamesShown {
                lines.append(words.callIt("mac.delete_and_more",
                                          ["n": .number(Double(free.count - Self.deleteNamesShown))]))
            }
            lines.append("")
        }
        lines.append(words.callIt("mac.delete_customers_goes"))
        if chosen.count > free.count {
            lines.append("")
            lines.append(words.callIt("mac.delete_customers_skipped",
                                      ["n": .number(Double(chosen.count - free.count))]))
        }
        lines.append("")
        lines.append(words.callIt("mac.undo_after"))
        pendingCustomerDelete = RecordDeleteRequest(ids: free.map(\.id), title: title,
                                                    message: lines.joined(separator: "\n"))
    }

    /// The customer delete, inside the store write. Only `clients` is written:
    /// the rule reads the jobs and the gift cards, and changes neither.
    static func applyCustomerDeletes(to root: inout [String: JSONValue], ids: [String],
                                     engine: KhaytEngine) async throws -> KhaytEngine.Deleted {
        let book: [String: JSONValue] = ["clients": .array(rows(root, "clients")),
                                         "printLog": .array(rows(root, "printLog")),
                                         "giftCards": .array(rows(root, "giftCards"))]
        let out = try await engine.deleteClients(book: book, ids: ids)
        if !out.deleted.isEmpty, let next = out.book["clients"] { root["clients"] = next }
        return out
    }

    /// Delete the customers the shop confirmed, each asked about again.
    func deleteCustomers(_ ids: [Customer.ID]) async {
        moveProblem = nil
        moveNotices = []
        guard permitted("clients", "delete") else { return }
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return }
        guard let engine else { moveProblem = words.callIt("mac.move_no_engine"); return }
        let pending: PendingUndo<[JSONValue]> =
            pendingUndo(named: words.callIt("mac.delete_customers_action")) { shop, gone in
                shop.putBackCustomers(gone, in: build)
            }
        defer { pending.drop() }
        var outcome: KhaytEngine.Deleted?
        do {
            try await StoreWriter.updateAsync(build) { root in
                outcome = try await Self.applyCustomerDeletes(to: &root, ids: ids, engine: engine)
            }
            guard let outcome else { return }
            pending.keepUnlessEmpty(outcome.deleted)
            let gone = Set(outcome.deletedIds)
            if let s = customerSelection, gone.contains(s) { customerSelection = nil }
            customerSelections.subtract(gone)
            await load(source)
            var said: [String] = []
            if !gone.isEmpty {
                said.append(words.callIt("mac.deleted_customers", ["n": .number(Double(gone.count))]))
            }
            if !outcome.skipped.isEmpty {
                said.append(words.callIt("mac.delete_customers_skipped",
                                         ["n": .number(Double(outcome.skipped.count))]))
            }
            moveNotices = said
            if !gone.isEmpty { await customersChangedOnCloud() }
        } catch {
            moveProblem = self.said(error)
        }
    }

    /// Put deleted customers back, each where it was.
    private func putBackCustomers(_ gone: [JSONValue], in build: StoreReader.Build) {
        guard permitted("clients", "edit"), let engine else { return }
        let shop = self
        Task { do {
            try await StoreWriter.updateAsync(build) { root in
                let back = try await engine.restoreClients(book: ["clients": .array(Self.rows(root, "clients"))],
                                                           deleted: gone)
                if let next = back["clients"] { root["clients"] = next }
            }
            await shop.load(shop.source)
            await shop.customersChangedOnCloud()
        } catch {
            shop.moveProblem = self.said(error)
        } }
    }
}
