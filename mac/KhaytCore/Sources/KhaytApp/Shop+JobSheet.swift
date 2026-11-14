import Foundation
import KhaytCore

/// Saving the job sheet (S1 B3b): everything the sheet can change — the
/// customer, the name, the due date, the priority, the notes, the discount,
/// a typed total, the parts, and the Not business mark — as ONE write.
///
/// The Edit Job sheet saved its fields and its Not business box in one
/// write, Order details saved the customer and the details in another, and a
/// part was a third, in a sheet of its own. One sheet now, and so one write:
/// one undo puts the whole job back, and a refusal anywhere — a locked
/// customer, a finished job's parts, a bill that would fall below what was
/// paid — leaves the job exactly as it was (`lib/order-edit.js applyJobEdit`
/// runs on a copy).
@MainActor
extension Shop {

    /// What the sheet is asking to change. Only what the shop touched.
    struct JobSave: Sendable {
        /// Fields `applyDetails` and `applyEdit` understand: `project`,
        /// `dueDate`, `priorityLevel`, `notes`, `discountPct`, `price`, …
        var fields: [String: JSONValue] = [:]
        /// `.some(id)` gives the job that customer, `.some(nil)` takes the
        /// customer off, `.none` leaves it.
        var customer: String?? = .none
        /// The whole new parts list, each part costed; nil leaves the parts.
        var parts: [JSONValue]? = nil
        /// The Not business box, when the shop moved it.
        var nonBusiness: Bool? = nil
        /// Where the customer has seen the price: keep it though the parts changed.
        var keepPrice = false

        var isEmpty: Bool { fields.isEmpty && customer == nil && parts == nil && nonBusiness == nil }
    }

    /// Save the job sheet. Returns false when nothing was written;
    /// `moveProblem` says why.
    @discardableResult
    func saveJob(_ id: Order.ID, _ save: JobSave) async -> Bool {
        guard !save.isEmpty else { return true }
        guard permitted("orders", "edit") else { return false }
        let refusals = Self.jobSaveRefusalWords(words)
        return await writeToOneOrder(id, named: words.callIt("mac.edit_job"), as: .person("orders", "edit")) { order, engine, root in
            OneOrderEdit(order: try await Self.jobSaved(
                order, save, clients: Self.rows(root, "clients"), settings: Self.settings(root),
                engine: engine, refusals: refusals, now: Date()))
        }
    }

    /// The job as the sheet leaves it. With nothing changed the order comes
    /// back untouched, so the write path stamps nothing and syncs nothing.
    nonisolated static func jobSaved(_ order: JSONValue, _ save: JobSave, clients: [JSONValue],
                                     settings: [String: JSONValue], engine: KhaytEngine,
                                     refusals: [String: String], now: Date) async throws -> JSONValue {
        var fields = save.fields
        if case .some(let to) = save.customer { fields["clientId"] = to.map(JSONValue.string) ?? .null }
        if let parts = save.parts { fields["parts"] = .array(parts) }
        var out = order
        if !fields.isEmpty {
            let r = try await engine.applyJobEdit(
                order: order, fields: fields, clients: clients, settings: settings, keepPrice: save.keepPrice,
                newPartIds: uids("PRT", count: save.parts?.count ?? 0),
                now: now, editId: uid("edit"), priceId: uid("edit"))
            guard r.ok else {
                // The customer already being this one is not a refusal.
                if r.reason == "same", r.step == "customer" {
                    var rest = save
                    rest.customer = .none
                    return try await jobSaved(order, rest, clients: clients, settings: settings,
                                              engine: engine, refusals: refusals, now: now)
                }
                let key = (r.step == "customer" ? "customer." : "") + (r.reason ?? "")
                throw MoveRefused(sentence: refusals[key] ?? refusals[r.reason ?? ""] ?? refusals["unknown"]!,
                                  code: r.reason)
            }
            if r.changed { out = r.order }
        }
        if let mark = save.nonBusiness { out = try await engine.setNonBusiness(out, on: mark) }
        return out
    }

    /// Every reason the combined edit can refuse with, in the shop's words:
    /// the parts rule's, the customer rule's (`customer.` prefixed, since
    /// `zatca` means a different sentence there), and the paid guard.
    static func jobSaveRefusalWords(_ words: Words) -> [String: String] {
        var out = partsRefusalWords(words)
        for (reason, said) in customerLockWords(words) { out["customer." + reason] = said }
        return out
    }

    // MARK: - The sheet's parts, as the book will hold them

    /// The parts the sheet is showing, as records: a stored part the shop did
    /// not touch as the book has it, an edited one re-costed exactly as Edit
    /// Part does it (`partEditCost`, its own rates and spool rule), and a new
    /// one costed and written as a new job's parts are (`partRows`). A part
    /// taken off in the sheet is simply not in `drafts`.
    func partsForSave(_ orderId: Order.ID, drafts: [JobSheet.PartDraft]) async -> [JSONValue] {
        var out: [JSONValue] = []
        for d in drafts {
            let now = d.fields
            if let stored = d.storedId, let raw = rawPart(orderId, partId: stored) {
                guard now != d.opened else { out.append(.object(raw)); continue }
                let recost = d.opened.map {
                    $0.grams != now.grams || $0.hours != now.hours || $0.qty != now.qty || $0.spoolId != now.spoolId
                } ?? true
                let (spool, costed): (Spool?, KhaytEngine.CostedPart?) = recost
                    ? await partEditCost(raw: raw, now, opened: d.opened) : (nil, nil)
                let one = JSONValue.object(["parts": .array([.object(raw)])])
                let edited = Self.orderWithPartEdited(one, partId: stored, now, opened: d.opened,
                                                      spool: spool, costed: costed, reclaimsTax: reclaimsTax)
                if case .array(let rows)? = Self.asObject(edited)?["parts"], let first = rows.first { out.append(first) }
            } else {
                let costed = await costedPart(spoolId: d.spoolId, grams: TypedNumber.parse(d.grams) ?? 0,
                                              hours: TypedNumber.parse(d.hours) ?? 0, qty: d.qty)
                var fresh = NewJobSheet.Draft()
                fresh.name = d.name; fresh.spoolId = d.spoolId
                fresh.grams = d.grams; fresh.hours = d.hours; fresh.qty = d.qty
                fresh.cost = costed?.cost ?? 0
                fresh.rates = costed?.rates
                out += Self.partRows([fresh], spools: spools, reclaimsTax: reclaimsTax,
                                     unnamed: words.callIt("mac.a_part"))
            }
        }
        return out
    }

    /// What the sheet's save WOULD do, without writing: the job as it would
    /// be left, or the sentence it would be refused with. The sheet's pinned
    /// total and its refusal line are this, so what is on screen is what Save
    /// does.
    func previewJobSave(_ id: Order.ID, _ save: JobSave) async -> Result<JSONValue, MoveRefused>? {
        guard let engine, let row = orderRow(id) else { return nil }
        do {
            return .success(try await Self.jobSaved(row, save, clients: clientRows, settings: settingsDict,
                                                    engine: engine, refusals: Self.jobSaveRefusalWords(words),
                                                    now: Date()))
        } catch let refused as MoveRefused {
            return .failure(refused)
        } catch {
            return nil
        }
    }
}
