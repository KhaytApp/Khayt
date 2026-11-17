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
        /// The shop was asked, and agreed, to move a price the customer has
        /// already seen (a new markup; `applyMarkup`'s 'ask_price').
        var priceSeenOk = false

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
                marginPct: await Self.markupForAddedParts(order, settings: settings, engine: engine),
                priceSeenOk: save.priceSeenOk,
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

    /// The markup a costed part added to this job is priced at, where the job
    /// itself cannot say: a job priced WHOLLY from agreed prices has no
    /// cost-plus share to take a markup from, and with none passed the rule
    /// charged a costed part at its bare cost (beta.40 review). The shop's
    /// default markup, then.
    ///
    /// ONLY for such a job. Passed for any other, it would override #2523's
    /// rule that a price nothing explains (parts with no cost on record)
    /// stays as it is: a 200 job given a 50 part would drop to 65. A job
    /// that has any part with no agreed price gets none, and the rule judges
    /// it as before.
    nonisolated static func markupForAddedParts(_ order: JSONValue, settings: [String: JSONValue],
                                                engine: KhaytEngine) async -> Double? {
        guard case .array(let parts)? = asObject(order)?["parts"], !parts.isEmpty else { return nil }
        let allAgreed = parts.allSatisfy { row in
            guard case .object(let p) = row, let v = p["agreedPrice"] else { return false }
            switch v {
            case .number(let n): return n >= 0
            case .string(let s): return TypedNumber.parse(s).map { $0 >= 0 } ?? false
            default: return false
            }
        }
        guard allAgreed else { return nil }
        // …and the agreements explain the WHOLE price. One agreed at 100 on a
        // job priced 300 (an old typed or imported record) is a price nothing
        // explains in part; given a markup, the rule would drop it to 165
        // when a 50 part is added (beta.40 re-review). Asked of the rule; a
        // rule that cannot say counts as unexplained.
        guard let share = try? await engine.unexplainedShare(order), share <= 0.005 else { return nil }
        if case .number(let m)? = settings["defaultMargin"], m >= 0 { return m }
        return 30
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
    ///
    /// A part ADDED here takes the price the job's customer agreed for it
    /// (`clientId`: the customer the sheet shows, which may be one chosen in
    /// this same edit), as New Job does; before, it was billed at cost plus
    /// markup (beta.40 review). The agreement is in the shop's currency and a
    /// job in another one holds its figures in its own, so it is divided by
    /// the job's rate, as `newOrder` does (`lib/order-new.js priced`).
    func partsForSave(_ orderId: Order.ID, drafts: [JobSheet.PartDraft],
                      clientId: String? = nil) async -> [JSONValue] {
        var out: [JSONValue] = []
        let added = drafts.filter { d in !(d.storedId.map { rawPart(orderId, partId: $0, at: d.storedIndex) != nil } ?? false) }
        let agreements = await agreedPrices(for: added.map(\.name), clientId: clientId)
        var agreedByName: [String: Double] = [:]
        for (d, price) in zip(added, agreements) { if let price { agreedByName[d.name] = price } }
        let fx: Double = {
            guard let row = orderRow(orderId), case .number(let r)? = Self.asObject(row)?["fxRate"], r > 0 else { return 1 }
            return r
        }()
        for d in drafts {
            let now = d.fields
            if let stored = d.storedId, var raw = rawPart(orderId, partId: stored, at: d.storedIndex) {
                // UNTOUCHED GOES BACK AS THE BOOK HOLDS IT, id or no id. A part
                // with no id (the desktop calculator's) was not found by id,
                // fell through to "a part added here", and was costed again at
                // today's rates from 0 hours, losing its colour and its model.
                guard now != d.opened else { out.append(.object(raw)); continue }
                // Edited: the edit is made by id, so one without is lent this
                // read's id for the edit and handed back without it; the rule
                // gives a changed id-less part a real id of its own.
                let lent = Self.plainString(raw["id"]) == nil
                if lent { raw["id"] = .string(stored) }
                let recost = d.opened.map {
                    $0.grams != now.grams || $0.hours != now.hours || $0.qty != now.qty || $0.spoolId != now.spoolId
                } ?? true
                let (spool, costed): (Spool?, KhaytEngine.CostedPart?) = recost
                    ? await partEditCost(raw: raw, now, opened: d.opened) : (nil, nil)
                let one = JSONValue.object(["parts": .array([.object(raw)])])
                let edited = Self.orderWithPartEdited(one, partId: stored, now, opened: d.opened,
                                                      spool: spool, costed: costed, reclaimsTax: reclaimsTax)
                if case .array(let rows)? = Self.asObject(edited)?["parts"], case .object(var first)? = rows.first {
                    if lent { first.removeValue(forKey: "id") }
                    out.append(.object(first))
                }
            } else {
                let costed = await costedPart(spoolId: d.spoolId, grams: TypedNumber.parse(d.grams) ?? 0,
                                              hours: TypedNumber.parse(d.hours) ?? 0, qty: d.qty)
                var fresh = NewJobSheet.Draft()
                fresh.name = d.name; fresh.spoolId = d.spoolId
                fresh.grams = d.grams; fresh.hours = d.hours; fresh.qty = d.qty
                fresh.cost = costed?.cost ?? 0
                fresh.rates = costed?.rates
                if let agreed = agreedByName[d.name] {
                    fresh.agreedPrice = Self.inJobCurrency(agreed, fxRate: fx)
                }
                out += Self.partRows([fresh], spools: spools, reclaimsTax: reclaimsTax,
                                     unnamed: words.callIt("mac.a_part"))
            }
        }
        return out
    }

    /// A shop-currency figure as the job holds it: divided by its rate, to
    /// the cent (`lib/order-new.js toJob`).
    nonisolated static func inJobCurrency(_ amount: Double, fxRate: Double) -> Double {
        guard fxRate > 0, fxRate != 1 else { return amount }
        return ((amount / fxRate) * 100).rounded() / 100
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
