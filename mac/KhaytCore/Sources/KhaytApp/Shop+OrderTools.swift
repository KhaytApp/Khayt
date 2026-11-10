import Foundation
import AppKit
import KhaytCore

/// The order tools the desktop had and this app did not: the whole order
/// editor, voiding an invoice, a credit note, a customer's RMA, a manual
/// reprint, and the job intake waiting list.
///
/// Every rule is a shared one — `lib/order-edit.js applyDetails`,
/// `lib/invoice-reversal.js`, `lib/reprint.js openRma` / `create`,
/// `lib/intake-queue.js` — so a record written here is the record the other
/// app writes, field for field. Here is only the write and the undo.
@MainActor
extension Shop {

    /// May this window void an invoice or credit one: what moving a job
    /// needs, and the invoicing area of the staff lock.
    var canReverseInvoices: Bool { canMoveJobs && lockAllows("invoicing", "edit") }

    /// The job is a quote, or has no invoice to take back.
    static func hasInvoice(_ job: Order) -> Bool {
        job.status != "quote" && job.status != "cancelled" && job.price > 0
    }

    // MARK: - The whole order editor

    /// Save the order editor. `fields` holds only what the shop changed
    /// (`OrderDetailsSheet.fields`); the rule leaves every other field alone.
    ///
    /// `customer`, when set, gives the job that customer first (`.some(nil)`
    /// takes the customer off) by `lib/order-edit.js changeCustomer` —
    /// Turki's rule of Nov 10: changeable until the invoice is submitted to
    /// ZATCA, voided, credited or paid; a job with no customer can always be
    /// given one. A refused change saves nothing, and says why.
    @discardableResult
    func editOrderDetails(_ id: Order.ID, fields: [String: JSONValue],
                          customer: String?? = .none) async -> Bool {
        guard !fields.isEmpty || customer != nil else { return true }
        guard permitted("orders", "edit") else { return false }
        let reasons = Self.customerLockWords(words)
        return await writeToOneOrder(id, named: words.callIt("oe.title"), as: .person("orders", "edit")) { order, engine, root in
            var current = order
            var moved = false
            if case .some(let to) = customer {
                let change = try await engine.changeCustomer(
                    order: order, clientId: to, clients: Self.rows(root, "clients"),
                    settings: Self.settings(root), now: Date(), editId: Self.uid("edit"))
                if !change.ok {
                    if change.reason == "same" { /* nothing to do */ } else {
                        throw MoveRefused(sentence: reasons[change.reason ?? ""] ?? reasons["unknown"]!)
                    }
                } else {
                    current = change.order
                    moved = true
                }
            }
            guard !fields.isEmpty else { return OneOrderEdit(order: current) }
            let out = try await engine.editOrderDetails(
                order: current, fields: fields, settings: Self.settings(root), now: Date(),
                editId: Self.uid("edit"), priceId: Self.uid("edit"))
            return OneOrderEdit(order: out.changed || moved ? out.order : order)
        }
    }

    /// Why a job's customer cannot be changed, in the shop's words — keyed by
    /// `lib/order-edit.js`'s reasons.
    static func customerLockWords(_ words: Words) -> [String: String] {
        ["zatca": words.callIt("mac.job_customer_locked_zatca"),
         "voided": words.callIt("mac.job_customer_locked_voided"),
         "credited": words.callIt("mac.job_customer_locked_credited"),
         "paid": words.callIt("mac.job_customer_locked_paid"),
         "unknown": words.callIt("mac.job_customer_unknown"),
         "missing": words.callIt("mac.move_gone")]
    }

    /// Why this job's customer is locked, or nil — for the editor to say
    /// before the shop tries.
    func customerLock(_ id: Order.ID) async -> String? {
        guard let engine, let row = orderRow(id) else { return nil }
        return (try? await engine.customerLocked(row)) ?? nil
    }

    /// The raw record, as a dictionary — what the editors open on.
    func orderFields(_ id: Order.ID) -> [String: JSONValue] {
        orderRow(id).flatMap(Self.asObject) ?? [:]
    }

    // MARK: - Voiding an invoice

    /// What a void of this job could book as waste.
    func voidMaterial(_ id: Order.ID) async -> VoidMaterial? {
        guard let engine, let row = orderRow(id) else { return nil }
        return try? await engine.voidMaterial(row)
    }

    /// Void the job's invoice, and book its material as waste if asked.
    ///
    /// The job keeps its status: a void is about the invoice, not about where
    /// the work is. Every money figure in lib/ already leaves a voided job
    /// out, so this is the whole of what it takes.
    @discardableResult
    func voidInvoice(_ id: Order.ID, reason: String, logWaste: Bool) async -> Bool {
        moveProblem = nil
        guard permitted("invoicing", "edit") else { return false }
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return false }
        guard let engine else { moveProblem = words.callIt("mac.move_no_engine"); return false }
        let note = words.callIt("waste.voided_order")
        let refused = words.callIt("inv.already_voided")
        let gone = words.callIt("mac.move_gone")
        var undo: [ChangedRecord] = []
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                undo = try await Self.applyVoid(&root, id: id, reason: reason, logWaste: logWaste,
                                                engine: engine, now: Date(), wasteId: Self.uid("W"),
                                                today: Self.localDay(), wasteNote: note,
                                                refused: refused, gone: gone)
            }
            registerMoveUndo(undo, named: words.callIt("inv.void_btn"))
            await load(source)
            return true
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch {
            moveProblem = self.said(error)
        }
        return false
    }

    /// The void's write, on a book in memory — the job stamped and, when
    /// asked for, the waste row at the top of `wasteLog`. Returns the undo.
    static func applyVoid(_ root: inout [String: JSONValue], id: String, reason: String, logWaste: Bool,
                          engine: KhaytEngine, now: Date, wasteId: String, today: String,
                          wasteNote: String, refused: String, gone: String) async throws -> [ChangedRecord] {
        let orders = rows(root, "printLog")
        guard let target = orders.first(where: { recordId($0) == id }) else {
            throw MoveRefused(sentence: gone)
        }
        let out = try await engine.voidInvoice(target, reason: reason, now: now, logWaste: logWaste,
                                               wasteId: wasteId, today: today, wasteNote: wasteNote)
        guard out.ok else { throw MoveRefused(sentence: refused) }
        var undo: [ChangedRecord] = []
        write(&root, "printLog", changed: [out.order], before: orders, into: &undo)
        if let waste = out.waste, case .object(var row) = waste {
            StoreWriter.stamp(&row)
            var log = rows(root, "wasteLog")
            log.insert(.object(row), at: 0)
            root["wasteLog"] = .array(log)
            if let wid = recordId(.object(row)) {
                undo.append(ChangedRecord(collection: "wasteLog", id: wid, was: [:], kind: .created))
            }
        }
        sealUndo(&undo, in: root)
        return undo
    }

    // MARK: - Credit notes

    /// The most a new credit note on this job can be for.
    func creditRoom(_ id: Order.ID) async -> Double {
        guard let engine, let row = orderRow(id) else { return 0 }
        return (try? await engine.creditRoom(row)) ?? 0
    }

    /// Issue a credit note, then show it to save or print.
    @discardableResult
    func issueCreditNote(_ id: Order.ID, amount: Double, reason: String) async -> Bool {
        moveProblem = nil
        guard permitted("invoicing", "edit") else { return false }
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return false }
        guard let engine else { moveProblem = words.callIt("mac.move_no_engine"); return false }
        let nothing = words.callIt("cn.nothing_left")
        let gone = words.callIt("mac.move_gone")
        var undo: [ChangedRecord] = []
        var issued: JSONValue?
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let out = try await Self.applyCredit(&root, id: id, amount: amount, reason: reason,
                                                     engine: engine, now: Date(), noteId: Self.creditNoteId(),
                                                     nothing: nothing, gone: gone)
                undo = out.undo
                issued = out.note
            }
            registerMoveUndo(undo, named: words.callIt("cn.title"))
            await load(source)
            if let issued { await showCreditNote(id, note: issued) }
            return true
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch {
            moveProblem = self.said(error)
        }
        return false
    }

    /// `'CN-' + Date.now().toString(36)`, the id the desktop gives a note.
    nonisolated static func creditNoteId(_ now: Date = Date()) -> String {
        "CN-" + String(Int(now.timeIntervalSince1970 * 1000), radix: 36)
    }

    /// The credit note's write, on a book in memory.
    static func applyCredit(_ root: inout [String: JSONValue], id: String, amount: Double, reason: String,
                            engine: KhaytEngine, now: Date, noteId: String,
                            nothing: String, gone: String) async throws -> (undo: [ChangedRecord], note: JSONValue?) {
        let orders = rows(root, "printLog")
        guard let target = orders.first(where: { recordId($0) == id }) else {
            throw MoveRefused(sentence: gone)
        }
        let out = try await engine.creditNote(target, amount: amount, reason: reason, now: now, id: noteId)
        guard out.ok else { throw MoveRefused(sentence: nothing) }
        var undo: [ChangedRecord] = []
        write(&root, "printLog", changed: [out.order], before: orders, into: &undo)
        return (undo, out.note)
    }

    /// Build the credit note's document and open it.
    func showCreditNote(_ id: Order.ID, note: JSONValue) async {
        guard let engine, let row = orderRow(id), let job = orders.first(where: { $0.id == id }) else { return }
        let code = job.currency.isEmpty ? currency : job.currency
        var symbol = code
        if case .object(let entry)? = Invoice.currencyTable(self)[code], case .string(let s)? = entry["symbol"] {
            symbol = s
        }
        var invoiceNumber = job.reference
        if case .number(let n)? = await invoiceNumbering(of: row) { invoiceNumber = n }
        let client = job.clientId.flatMap { cid in clients.first { $0.id == cid } }
        let sub = [client?.phone ?? "", client?.email ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let name = job.project.trimmingCharacters(in: .whitespaces)
        guard let doc = try? await engine.creditNoteHtml(
            order: row, note: note, settings: settingsDict, language: words.language,
            shopName: shopName, currencySymbol: symbol, invoiceNumber: invoiceNumber,
            jobRef: job.reference, clientName: name.isEmpty ? words.callIt("inv.walk_in") : name,
            clientSub: sub, today: Self.localDay()) else {
            moveProblem = words.callIt("mac.no_document"); return
        }
        creditPaper = CreditPaperRequest(document: doc, number: "CN-" + job.id, project: job.project)
    }

    /// A credit note on screen.
    struct CreditPaperRequest: Identifiable {
        let id = UUID()
        let document: InvoiceDocument
        let number: String
        let project: String
    }

    // MARK: - What happened to a job

    /// A job's stage timeline and edit history, on screen. `edits` picks
    /// which of the two the sheet opens on.
    struct HistoryRequest: Identifiable {
        let id: Order.ID
        let project: String
        var edits = false
    }

    func jobEdits(_ id: Order.ID) async -> [OrderEditEntry] {
        guard let engine, let row = orderRow(id) else { return [] }
        return (try? await engine.editLog(row)) ?? []
    }

    func timeline(_ id: Order.ID) async -> OrderTimeline? {
        guard let engine, let row = orderRow(id) else { return nil }
        return try? await engine.orderTimeline(row, now: Date())
    }

    /// The word for a tracked field in the edit history.
    static func historyFieldKey(_ field: String) -> String? {
        switch field {
        case "dueDate": "doc.due"
        case "discountPct": "oe.discount_pct"
        case "shippingCost": "oe.shipping"
        case "priority", "priorityLevel": "oe.priority"
        case "price": "common.total"
        case "project": "mac.job"
        case "clientId", "client": "mac.customer"
        default: nil
        }
    }

    // MARK: - A customer came back (RMA), and reprints

    /// The shop's warranty, in days (`settings.qc.warrantyDays`), or nil.
    var warrantyDays: Double? {
        guard case .object(let qc)? = settingsDict["qc"] else { return nil }
        return Self.plainNumber(qc["warrantyDays"])
    }

    /// Whether the job is still in its warranty window.
    func withinWarranty(_ job: Order) async -> Bool {
        guard let engine else { return false }
        return (try? await engine.withinWarranty(deliveredAt: job.deliveredAt, warrantyDays: warrantyDays,
                                                 now: Date())) ?? false
    }

    /// Record a customer-reported defect. A reprint resolution makes the
    /// linked replacement in the same write, as the desktop does — free to
    /// the customer within warranty — and goes to it. A refund opens the
    /// credit note, which is how money goes back on a job.
    func openRma(_ id: Order.ID, reason: String, resolution: String, withinWarranty within: Bool) async {
        moveProblem = nil
        guard permitted("orders", "edit") else { return }
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return }
        guard let engine else { moveProblem = words.callIt("mac.move_no_engine"); return }
        let gone = words.callIt("mac.move_gone")
        let who = Self.plainString(settingsDict["activeOperatorId"])
        var made: String?
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                made = try await Self.applyRma(&root, id: id, reason: reason, resolution: resolution,
                                               within: within, reportedBy: who, engine: engine,
                                               now: Date(), gone: gone)
            }
            await load(source)
            if let made { goToJob(made) }
            else if resolution == "refund", let job = orders.first(where: { $0.id == id }) {
                pendingCredit = PendingHold(id: id, project: job.project)
            }
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch {
            moveProblem = self.said(error)
        }
    }

    /// The RMA's write, on a book in memory. Returns the reprint's id, if one
    /// was made.
    static func applyRma(_ root: inout [String: JSONValue], id: String, reason: String, resolution: String,
                         within: Bool, reportedBy: String?, engine: KhaytEngine, now: Date,
                         gone: String) async throws -> String? {
        var orders = rows(root, "printLog")
        guard let i = orders.firstIndex(where: { recordId($0) == id }) else { throw MoveRefused(sentence: gone) }
        let out = try await engine.openRma(orders[i], reason: reason, resolution: resolution,
                                           withinWarranty: within, reportedBy: reportedBy, now: now)
        var undo: [ChangedRecord] = []
        write(&root, "printLog", changed: [out.order], before: orders, into: &undo)
        guard let cost = out.reprintCost else { return nil }
        orders = rows(root, "printLog")
        return try await linkReprint(&root, of: id, orders: orders, reason: "rma", cost: cost,
                                     engine: engine, now: now)
    }

    /// A manual reprint — the same work again, as a new linked job.
    /// `cost` is `billable` (the desktop's default: the customer pays) or
    /// `shop`. Goes to the new job, where its price can be changed.
    func reprintJob(_ id: Order.ID, cost: String) async {
        moveProblem = nil
        guard permitted("orders", "create") else { return }
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return }
        guard let engine else { moveProblem = words.callIt("mac.move_no_engine"); return }
        let gone = words.callIt("mac.move_gone")
        var made: String?
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let orders = Self.rows(root, "printLog")
                guard orders.contains(where: { Self.recordId($0) == id }) else { throw MoveRefused(sentence: gone) }
                made = try await Self.linkReprint(&root, of: id, orders: orders, reason: "manual",
                                                  cost: cost == "shop" ? "shop" : "billable",
                                                  engine: engine, now: Date())
            }
            await load(source)
            if let made { goToJob(made) }
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch {
            moveProblem = self.said(error)
        }
    }

    /// The linked reprint through `lib/reprint.js create`, written into the
    /// book with the settings it advanced (the invoice counter).
    static func linkReprint(_ root: inout [String: JSONValue], of id: String, orders: [JSONValue],
                            reason: String, cost: String, engine: KhaytEngine, now: Date) async throws -> String? {
        guard let made = try await engine.linkedReprint(
            of: id, printLog: orders, settings: settings(root), now: now,
            tokens: (tracking: randomBytes(16), quoteApproval: randomBytes(16)),
            inventory: rows(root, "inventory"), consumables: rows(root, "consumables"),
            clients: rows(root, "clients"), reason: reason, cost: cost,
            partIdBase: uid("PRT")) else { return nil }
        root["printLog"] = .array(made.printLog.map { row in
            guard case .object(var o) = row, let rid = recordId(row),
                  rid == recordId(made.order) || rid == id else { return row }
            StoreWriter.stamp(&o)
            return .object(o)
        })
        root["settings"] = .object(made.settings)
        return plainString(asObject(made.order)?["id"])
    }

    // MARK: - The job intake waiting list

    /// The enquiries as the list shows them: declined left out, the most
    /// urgent first.
    func intakeShown() async -> [JSONValue] {
        guard let engine else { return [] }
        return (try? await engine.intakeVisible(intakeRows)) ?? []
    }

    /// The badge: enquiries still wanting an answer.
    var intakeOpenCount: Int {
        intakeRows.filter {
            guard case .string(let s)? = Self.asObject($0)?["status"] else { return false }
            return s == "active" || s == "reminded"
        }.count
    }

    func intakeFunnel() async -> IntakeFunnel? {
        try? await engine?.intakeFunnel(list: intakeRows, history: intakeHistoryRows)
    }

    /// Add an enquiry (`id` nil) or save changes to one. Returns what to say
    /// when it could not be saved, or nil.
    func saveIntake(_ id: String?, fields: [String: JSONValue]) async -> String? {
        let gate = id == nil ? "create" : "edit"
        let required = words.callIt("waiting.project_required")
        let gone = words.callIt("mac.move_gone")
        return await writeIntake(named: words.callIt(id == nil ? "waiting.add" : "waiting.edit"),
                                 action: gate) { root, engine in
            let out = try await engine.intakeSave(list: Self.rows(root, "waitingList"), fields: fields,
                                                  id: id, newId: Self.uid("WAIT"), now: Date())
            guard out.ok, let list = out.list else {
                throw MoveRefused(sentence: out.error == "project_required" ? required : gone)
            }
            return Self.writeIntakeLists(&root, list: list, history: nil)
        }
    }

    /// The customer was reminded on WhatsApp: WhatsApp opens on `phone` with
    /// `text` typed in, and the enquiry is marked reminded. Returns what to
    /// say when WhatsApp could not be opened.
    func remindIntake(_ id: String, phone: String, text: String) async -> String? {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        guard lockAllows("orders", "edit") else { return words.callIt("mac.lock_not_allowed") }
        guard let chat = try? await engine.whatsAppChat(phone: phone, text: text),
              chat.ok, let url = URL(string: chat.link) else {
            let why = (try? await engine.whatsAppChat(phone: phone, text: ""))?.reason ?? "no_phone"
            return whatsAppReason(why)
        }
        NSWorkspace.shared.open(url)
        return await writeIntake(named: words.callIt("waiting.remind"), action: "edit") { root, engine in
            let list = try await engine.intakeReminded(list: Self.rows(root, "waitingList"), id: id, now: Date())
            return Self.writeIntakeLists(&root, list: list, history: nil)
        }
    }

    func declineIntake(_ id: String) async {
        _ = await writeIntake(named: words.callIt("waiting.decline"), action: "edit") { root, engine in
            let list = try await engine.intakeDeclined(list: Self.rows(root, "waitingList"), id: id)
            return Self.writeIntakeLists(&root, list: list, history: nil)
        }
    }

    func deleteIntake(_ id: String) async {
        _ = await writeIntake(named: words.callIt("common.delete"), action: "delete") { root, _ in
            let list = Self.rows(root, "waitingList").filter { Self.recordId($0) != id }
            return Self.writeIntakeLists(&root, list: list, history: nil)
        }
    }

    /// Turn an enquiry into a quote: it leaves the list for the history as
    /// converted, the customer it names is found or added, and the job sheet
    /// opens on it — as a quote, with what the enquiry said as its note.
    func promoteIntake(_ id: String) async {
        guard canMoveJobs else { moveProblem = words.callIt("mac.move_sample"); return }
        var promoted: IntakePromoted?
        let gone = words.callIt("mac.move_gone")
        let problem = await writeIntake(named: words.callIt("waiting.promote"), action: "create") { root, engine in
            guard let out = try await engine.intakePromote(
                list: Self.rows(root, "waitingList"), history: Self.rows(root, "waitingListHistory"),
                clients: Self.rows(root, "clients"), id: id, newClientId: Self.uid("CLI"), now: Date()) else {
                throw MoveRefused(sentence: gone)
            }
            promoted = out
            var undo = Self.writeIntakeLists(&root, list: out.list, history: out.history)
            if case .object(var client)? = out.createdClient, let cid = Self.recordId(.object(client)) {
                StoreWriter.stamp(&client)
                var book = Self.rows(root, "clients")
                book.append(.object(client))
                root["clients"] = .array(book)
                undo.append(ChangedRecord(collection: "clients", id: cid, was: [:], kind: .created))
            }
            return undo
        }
        if let problem { moveProblem = problem; return }
        guard let promoted else { return }
        showingIntake = false
        let project = Self.plainString(Self.asObject(promoted.item)?["project"]) ?? ""
        var carried: [String: JSONValue] = [:]
        if !promoted.note.isEmpty { carried["notes"] = .string(promoted.note) }
        takeJob(JobFromModel(project: String(project.prefix(120)), parts: [], margin: defaultMargin,
                             asQuote: true, clientId: promoted.clientId, carried: carried))
    }

    /// One write to the waiting list. Returns what to say when it was
    /// refused, or nil when it landed.
    private func writeIntake(named actionName: String, action: String,
                             change: @escaping (inout [String: JSONValue], KhaytEngine) async throws -> [ChangedRecord])
    async -> String? {
        moveProblem = nil
        guard permitted("orders", action) else { return moveProblem }
        guard let build = source.build else { return words.callIt("mac.move_sample") }
        guard let engine else { return words.callIt("mac.move_no_engine") }
        var undo: [ChangedRecord] = []
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                undo = try await change(&root, engine)
            }
            registerMoveUndo(undo, named: actionName)
            await load(source)
            return nil
        } catch let refusal as MoveRefused {
            return refusal.sentence
        } catch {
            return self.said(error)
        }
    }

    /// Put the waiting list (and its history, when given) back, stamping only
    /// the rows that changed and recording each as edited, created or
    /// deleted for the undo.
    nonisolated static func writeIntakeLists(_ root: inout [String: JSONValue], list: [JSONValue],
                                             history: [JSONValue]?) -> [ChangedRecord] {
        var undo: [ChangedRecord] = []
        func put(_ collection: String, _ next: [JSONValue]) {
            let before = rows(root, collection)
            var was: [String: (Int, [String: JSONValue])] = [:]
            for (i, row) in before.enumerated() {
                if let id = recordId(row), case .object(let o) = row { was[id] = (i, o) }
            }
            var out: [JSONValue] = []
            var seen = Set<String>()
            for row in next {
                guard let id = recordId(row), case .object(var now) = row else { out.append(row); continue }
                seen.insert(id)
                if let (_, old) = was[id] {
                    if now != old {
                        StoreWriter.stamp(&now)
                        undo.append(ChangedRecord(collection: collection, id: id, was: old, now: now))
                    }
                } else {
                    StoreWriter.stamp(&now)
                    undo.append(ChangedRecord(collection: collection, id: id, was: [:], now: now, kind: .created))
                }
                out.append(.object(now))
            }
            for (id, (at, old)) in was where !seen.contains(id) {
                undo.append(ChangedRecord(collection: collection, id: id, was: old, kind: .deleted, at: at))
            }
            root[collection] = .array(out)
        }
        put("waitingList", list)
        if let history { put("waitingListHistory", history) }
        return undo
    }
}
