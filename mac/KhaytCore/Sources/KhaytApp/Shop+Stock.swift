import Foundation
import UniformTypeIdentifiers
import AppKit
import Observation
import KhaytCore

extension Shop {

    // MARK: - What the shop has on order

    // ── THE OPERATOR LOCK (see OperatorLock.swift) ───────────────────────

    /// TESTS ONLY: the lock's inputs without a book on disk. The sample book
    /// has staff and no PINs, and must not be given any; the real book is
    /// never a test's to write. Nothing in the app calls this.
    /// Tests: hand this shop an engine already built, so `load` skips
    /// building its own. Starting an engine loads ~190 modules on the main
    /// actor; a suite that builds a Shop per test paid that dozens of times,
    /// and on CI's three cores the main actor it shares with the in-process
    /// LAN server stalled that server's tests (alpha.62 CI). Only before the
    /// first load — a shop never swaps engines under itself.
    func useEngine(_ shared: KhaytEngine) {
        if engine == nil { engine = shared }
    }

    func useLockFixture(operators: [JSONValue], settings: [String: JSONValue]) async {
        operatorRows = operators
        settingsValue = .object(settings)
        await refreshLock()
    }

    /// Everything still to arrive, worst-waited first.
    ///
    /// A received order is history; what a shop looking at a thin shelf wants
    /// to know is what is COMING. `received` orders are left out for that
    /// reason, not hidden.
    /// Orders whose goods are here and whose bill is not settled.
    ///
    /// Either no invoice has been recorded, or one has and nobody has said it
    /// was paid. `lib/supplier-invoice.js` decides which — the same rule that
    /// decides whether a bill matches — so a list this app shows and a figure
    /// the other app totals cannot drift apart.
    ///
    /// This is deliberately NOT the other app's AP aging filter, which also
    /// counts money committed on orders that have not arrived. That answers
    /// "what have we taken on"; this answers "whose bill is sitting here".
    var billsToSettle: [PurchaseOrder] { unsettledRows.compactMap(PurchaseOrder.init(row:)) }

    var openOrders: [PurchaseOrder] {
        purchaseOrderRows.compactMap(PurchaseOrder.init(row:))
            .filter { $0.status != "received" }
            .sorted { a, b in
                // Oldest first: the one waited on longest is the one to chase.
                if a.orderedAt != b.orderedAt { return a.orderedAt < b.orderedAt }
                return a.id < b.id
            }
    }

    /// Draft an order for everything that is low and not already coming.
    ///
    /// ONE WRITE, not one per item. A shop that pressed this and got four of
    /// six orders because the fifth item had been deleted underneath would have
    /// a book it cannot reason about; the whole batch lands or none of it does.
    ///
    /// The list is re-read INSIDE the write for the same reason every other
    /// write here re-reads: what was low a minute ago may be on its way now.
    ///
    /// Returns the number drafted, or nil with `moveProblem` set.
    func draftWhatIsLow() async -> Int? {
        guard permitted("inventory", "create") else { return nil }
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            moveProblem = words.callIt("mac.read_only"); return nil
        }
        guard let engine else { moveProblem = words.callIt("mac.move_no_engine"); return nil }

        var drafted = 0
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let wanted = try await engine.needsOrdering(
                    spools: Self.rows(root, "inventory"),
                    consumables: Self.rows(root, "consumables"),
                    orders: Self.rows(root, "printLog"),
                    purchaseOrders: Self.rows(root, "purchaseOrders"),
                    settings: Self.settings(root), now: Date())
                guard !wanted.isEmpty else { throw NothingWasLow() }

                var orders = Self.rows(root, "purchaseOrders")
                let suppliers = Self.rows(root, "suppliers")
                let today = Self.localDay()
                for want in wanted {
                    let shelf = Self.rows(root, want.consumable ? "consumables" : "inventory")
                    guard let item = shelf.first(where: { Self.recordId($0) == want.id }) else { continue }
                    var ask: [String: JSONValue] = [
                        "status": .string("draft"),
                        // The RULE's figure for how much to buy, not a default:
                        // it is what covers the days of cover the shop asked
                        // for, and a spool's own reorder quantity would ignore
                        // how fast this one is actually going.
                        "qty": .number(want.quantity),
                    ]
                    var supplierName = ""
                    if want.consumable {
                        ask["kind"] = .string("consumable")
                    } else {
                        let price = try await engine.perGramPrice(item: item, suppliers: suppliers)
                        if price.perG > 0 { ask["unitPrice"] = .number(price.perG) }
                        if let id = price.supplierId, !id.isEmpty { ask["supplierId"] = .string(id) }
                        supplierName = price.supplierName
                    }
                    orders.insert(try await engine.draftOrder(
                        item: item, ask: ask, id: Self.uid("PO"),
                        today: today, supplierName: supplierName), at: 0)
                    drafted += 1
                }
                root["purchaseOrders"] = .array(orders)
            }
        } catch is NothingWasLow {
            moveProblem = words.callIt("po.none_needed"); return nil
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence; return nil
        } catch {
            moveProblem = self.said(error); return nil
        }
        await load(source)
        return drafted
    }

    /// Nothing was low by the time the write opened. Not a fault.
    private struct NothingWasLow: Error {}

    /// Order more of something.
    ///
    /// ── WHAT THIS APP DECIDES, WHICH IS ALMOST NOTHING ────────────────────
    ///
    /// How much to ask for, what to call the order, whether it is counted in
    /// grams or the shop's own unit, and what a gram costs are all decided by
    /// `lib/purchase-orders.js` and `lib/reorder.js`. This finds the record,
    /// asks them, and writes what comes back.
    ///
    /// The price is the one worth naming: a per-SPOOL cost against a quantity
    /// measured in GRAMS is what made auto-drafted orders about a thousand
    /// times too expensive, and it is why `po-audit` exists. That division is
    /// the shared rule's, not this app's.
    ///
    /// Drafted, never ordered. A purchase order is something a shop sends to a
    /// supplier, and an app that sent one because somebody chose a menu item
    /// would be doing something on their behalf that they cannot take back.
    ///
    /// Returns nil when it worked, or what to tell the shop.
    func draftOrder(for itemId: String, consumable: Bool) async -> String? {
        guard permitted("inventory", "create") else { return moveProblem }
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            return words.callIt("mac.read_only")
        }
        guard let engine else { return words.callIt("mac.move_no_engine") }

        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let shelf = Self.rows(root, consumable ? "consumables" : "inventory")
                guard let item = shelf.first(where: { Self.recordId($0) == itemId }) else {
                    throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                }
                var ask: [String: JSONValue] = ["status": .string("draft")]
                var supplierName = ""
                if consumable {
                    ask["kind"] = .string("consumable")
                } else {
                    // A material nothing prices carries NO price, rather than a
                    // price of nothing: `draft` leaves `unitPrice` out when the
                    // caller asks for none, and a receipt against an order with
                    // no price books no expense instead of one for zero.
                    let price = try await engine.perGramPrice(item: item,
                                                              suppliers: Self.rows(root, "suppliers"))
                    if price.perG > 0 { ask["unitPrice"] = .number(price.perG) }
                    if let id = price.supplierId, !id.isEmpty { ask["supplierId"] = .string(id) }
                    supplierName = price.supplierName
                }
                let drafted = try await engine.draftOrder(
                    item: item, ask: ask, id: Self.uid("PO"),
                    today: Self.localDay(), supplierName: supplierName)

                var orders = Self.rows(root, "purchaseOrders")
                orders.insert(drafted, at: 0)
                root["purchaseOrders"] = .array(orders)
            }
        } catch let refusal as MoveRefused {
            return refusal.sentence
        } catch {
            return self.said(error)
        }
        await load(source)
        return nil
    }

    /// Book goods in against an order.
    ///
    /// ── FOUR RECORDS, ONE WRITE ───────────────────────────────────────────
    ///
    /// The order, the spool or the consumable, that spool's history line, and
    /// an expense. The shared rule returns all four and this writes all four in
    /// ONE swap — both faults this chain has carried were one of them going
    /// missing on its own: a consumable order that restocked nothing and marked
    /// itself received, and a filament receipt that booked no expense at all.
    ///
    /// Returns nil when it worked, or what to tell the shop.
    /// `invoice` is the supplier's own bill, when it arrived with the goods —
    /// which is the usual way it arrives. Empty means none was typed, and the
    /// order is booked in exactly as before.
    ///
    /// It is recorded HERE rather than from a list of received orders because
    /// this app deliberately has no such list: `OnOrderCard` answers what is
    /// still to come, and a received order is history. The moment the box is
    /// opened is also the moment somebody is holding the invoice.
    ///
    /// `lot` is the manufacturer's lot printed on what arrived, optional. A lot
    /// different from the spool's own, onto a spool that still holds filament,
    /// is booked in as a NEW spool (`newItem`) — see LOT in
    /// `lib/purchase-orders.js` — so a recall can tell the two apart.
    func receiveGoods(_ id: String, quantity: Double, notes: String,
                      invoice: Bill = Bill(), lot: String = "") async -> String? {
        guard permitted("inventory", "edit") else { return moveProblem }
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            return words.callIt("mac.read_only")
        }
        guard let engine else { return words.callIt("mac.move_no_engine") }
        guard quantity > 0 else { return words.callIt("exp.amount_required") }

        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                // Read INSIDE the write: a receipt computed from the in-memory
                // copy would put a stale shelf back. `StoreWriter` says so.
                var orders = Self.rows(root, "purchaseOrders")
                guard let at = orders.firstIndex(where: { Self.recordId($0) == id }) else {
                    throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                }
                let order = orders[at]
                let consumable = try await engine.isConsumableOrder(order)
                let itemId = Self.itemId(of: order)

                var shelf = Self.rows(root, "inventory")
                var bits = Self.rows(root, "consumables")
                let spoolAt = consumable ? nil : shelf.firstIndex { Self.recordId($0) == itemId }
                let bitAt = consumable ? bits.firstIndex { Self.recordId($0) == itemId } : nil
                // The spools an earlier part delivery of a new lot was booked
                // into, so a second delivery of that lot tops one up rather
                // than making another.
                var into = Set<String>()
                if case .object(let o) = order, case .array(let ids)? = o["receivedInto"] {
                    for case .string(let x) in ids { into.insert(x) }
                }
                let earlier = consumable || into.isEmpty ? []
                    : shelf.filter { Self.recordId($0).map(into.contains) ?? false }

                let done = try await engine.receiveGoods(
                    order: order,
                    item: spoolAt.map { shelf[$0] },
                    consumable: bitAt.map { bits[$0] },
                    quantity: quantity, notes: notes, today: Self.localDay(),
                    expenseId: Self.uid("EXP"),
                    expenseLabel: self.words.callIt("po.receive"),
                    lot: lot, newSpoolId: Self.uid("INV"), receivedSpools: earlier)
                guard done.ok, let written = done.po else {
                    // A spool or consumable deleted after the order was raised
                    // has nowhere for the goods to land — say THAT, not "enter
                    // an amount" to someone who typed one.
                    throw MoveRefused(sentence: self.words.callIt(
                        done.reason == "no_item" ? "po.item_gone" : "exp.amount_required"))
                }

                orders[at] = written
                // The bill, if one came with the goods. Merged onto the row the
                // receipt just wrote — never onto a copy read before it — and
                // merged rather than replacing, because an order carries plenty
                // neither this app nor the rule knows about.
                if invoice.isWorthRecording, case .object(var row) = written {
                    let bill = try await engine.recordSupplierInvoice(
                        on: written, number: invoice.number,
                        amount: invoice.amount, date: invoice.day)
                    for (key, value) in bill.fields { row[key] = value }
                    orders[at] = .object(row)
                }
                root["purchaseOrders"] = .array(orders)
                // By the returned spool's OWN id: it is not always the one the
                // order points at (see `receivedSpools` in the rule).
                if let item = done.item,
                   let at = shelf.firstIndex(where: { Self.recordId($0) == Self.recordId(item) }) {
                    shelf[at] = item
                    root["inventory"] = .array(shelf)
                }
                // A different lot is its own spool, placed beside the one the
                // order was raised for. The old spool is left exactly as it was.
                if let fresh = done.newItem {
                    shelf.insert(fresh, at: spoolAt.map { $0 + 1 } ?? shelf.endIndex)
                    root["inventory"] = .array(shelf)
                }
                if let bitAt, let bit = done.consumable {
                    bits[bitAt] = bit
                    root["consumables"] = .array(bits)
                }
                if let expense = done.expense {
                    var spend = Self.rows(root, "expenses")
                    spend.append(expense)
                    root["expenses"] = .array(spend)
                }
            }
        } catch let refusal as MoveRefused {
            return refusal.sentence
        } catch {
            return self.said(error)
        }
        await load(source)
        return nil
    }

    /// Every job that drew from `lot`, put on the clipboard as CSV for a
    /// recall. The rule is `lib/lot-trace.js`; returns what to tell the shop.
    func copyLotRecall(_ lot: String) async -> String {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        do {
            let recall = try await engine.lotRecall(lot: lot, printLog: orderRows,
                                                    wasteLog: wasteRows, inventory: inventoryRows)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(recall.csv, forType: .string)
            return recall.jobs.count == 1 ? words.callIt("mac.lot_copied_one")
                : words.callIt("mac.lot_copied", ["n": .number(Double(recall.jobs.count))])
        } catch {
            return self.said(error)
        }
    }

    /// What a supplier charged, as the shop typed it off the invoice.
    struct Bill: Hashable, Sendable {
        var number = ""
        var amount: Double = 0
        var day = ""

        /// A bill nobody typed is not a bill.
        ///
        /// A NUMBER ALONE IS ENOUGH. A shop that files the invoice and records
        /// only its reference has recorded something worth keeping, and
        /// refusing it until an amount is typed would lose that.
        var isWorthRecording: Bool {
            !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || amount > 0
        }
    }

    /// Whether this order restocks a consumable rather than a spool, by the
    /// rule's reading (absent `kind` is filament). False when the order or the
    /// engine is not there, which is the reading every older order takes.
    func ordersAConsumable(_ id: String) async -> Bool {
        guard let engine,
              let row = purchaseOrderRows.first(where: { Self.recordId($0) == id }) else { return false }
        return (try? await engine.isConsumableOrder(row)) ?? false
    }

    /// Does this bill agree with what the order said it would cost?
    ///
    /// "matched", "mismatch", or "none" when nothing has been typed yet —
    /// three words rather than a boolean, because a screen drawing two states
    /// out of `false` has to guess which one it means.
    func billVerdict(on order: PurchaseOrder, bill: Shop.Bill) async -> String {
        guard let engine, bill.isWorthRecording else { return "none" }
        let row = JSONValue.object(["qty": .number(order.qty),
                                    "unitPrice": .number(order.unitPrice ?? 0),
                                    "status": .string(order.status)])
        guard let recorded = try? await engine.recordSupplierInvoice(
            on: row, number: bill.number, amount: bill.amount, date: bill.day)
        else { return "none" }
        return recorded.invoiceDiscrepancy ? "mismatch" : "matched"
    }

    // MARK: - Drafting what is low, without being asked

    /// Draft for what is low, if the shop asked to have that done for it.
    ///
    /// ── WHY IT IS SAFE TO DO WITHOUT ASKING ───────────────────────────────
    ///
    /// Three reasons, and it needs all three. It is OPT-IN and off by default.
    /// It writes DRAFTS, which are not orders — a shop reviews and sends them.
    /// And the rule refuses anything already on its way: `itemsNeedingDraftPo`
    /// reads the open purchase orders, so running twice does not order twice.
    ///
    /// Only when this app owns the book. A second copy drafting against the
    /// same shelf is how one shortage becomes two orders.
    func autoDraftIfAsked() async {
        guard case .bool(true)? = settingsDict["autoDraftPo"],
              let build = source.build, StoreLock.weOwnIt(build),
              !needsOrdering.isEmpty
        else { return }
        // The same path the button takes, so there is one way an order gets
        // drafted rather than a quiet second one beside it.
        if let made = await draftWhatIsLow(), made > 0 { autoDrafted = made }
    }

    /// Write down that a spool was dried today.
    ///
    /// ── THE APP NAGGED AND COULD NOT BE ANSWERED ──────────────────────────
    ///
    /// The shelf draws `due` and `overdue` from `lib/filament-dryness.js`,
    /// which reads `driedAt` and nothing else. This app had no field for it
    /// and no action, so a spool it called overdue stayed overdue for ever —
    /// an app asking for something it will not accept.
    ///
    /// Through `spool-edit.js` like every other change to a spool, so the one
    /// rule that decides what a spool record may hold keeps deciding it.
    func markDried(_ id: String, on day: String? = nil) async -> String? {
        guard permitted("inventory", "edit") else { return moveProblem }
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            return words.callIt("mac.read_only")
        }
        guard let engine else { return words.callIt("mac.move_no_engine") }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var shelf = Self.rows(root, "inventory")
                guard let at = shelf.firstIndex(where: { Self.recordId($0) == id }),
                      case .object(let was) = shelf[at] else {
                    throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                }
                let when = day ?? Self.localDay()
                let out = try await engine.editSpool(
                    shelf[at],
                    input: ["material": .string(Self.plainString(was["material"]) ?? ""),
                            "driedAt": .string(when)],
                    settings: Self.settings(root), today: Self.today())
                guard case .object(var record) = out.spool else { return }
                // AND the log row, through the drying-log rule, as the other
                // app's drying form writes it. `driedAt` alone cleared the nag
                // but left the spool's drying history with no record of it.
                let logged = FilamentDryness.recordDrying(
                    .object(record),
                    entry: ["id": .string(Self.uid("DRY")), "date": .string(when)])
                record["dryingLog"] = .array(logged.dryingLog)
                if let newest = logged.driedAt { record["driedAt"] = .string(newest) }
                StoreWriter.stamp(&record)
                shelf[at] = .object(record)
                root["inventory"] = .array(shelf)
            }
        } catch let refusal as MoveRefused {
            return refusal.sentence
        } catch {
            return self.said(error)
        }
        await load(source)
        return nil
    }

    /// Say a supplier's bill has been paid — or that it has not, after all.
    ///
    /// Merged onto the order rather than replacing it, like every other write
    /// to one: a purchase order carries plenty this does not know about.
    func settleBill(_ id: String, paid: Bool) async -> String? {
        await writeToOnePurchaseOrder(id) { order, engine in
            guard case .object(var row) = order else { return order }
            for (key, value) in try await engine.settleBill(paid) { row[key] = value }
            return .object(row)
        }
    }

    /// Record a supplier's bill against an order whose goods already arrived.
    ///
    /// The receive sheet takes one at the moment the box is opened, which is
    /// when it usually arrives. This is the other case: a bill that turns up a
    /// week later, against an order that has left the "still to come" card.
    func recordBill(_ id: String, _ bill: Bill) async -> String? {
        guard bill.isWorthRecording else { return nil }
        return await writeToOnePurchaseOrder(id) { order, engine in
            guard case .object(var row) = order else { return order }
            let recorded = try await engine.recordSupplierInvoice(
                on: order, number: bill.number, amount: bill.amount, date: bill.day)
            for (key, value) in recorded.fields { row[key] = value }
            return .object(row)
        }
    }

    /// Close an order by hand: the goods are all in, whatever was counted.
    func closeOrder(_ id: String) async -> String? {
        await writeToOnePurchaseOrder(id) { order, engine in
            try await engine.closeOrder(order, today: Self.localDay())
        }
    }

    /// Correct one order priced per spool where a per-gram rate was expected.
    ///
    /// The rule decides the figure and refuses an order that no longer looks
    /// affected — which is what makes a list read a minute ago harmless.
    func correctOrderPrice(_ id: String) async -> String? {
        guard permitted("invoicing", "edit") else { return moveProblem }
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            return words.callIt("mac.read_only")
        }
        guard let engine else { return words.callIt("mac.move_no_engine") }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var orders = Self.rows(root, "purchaseOrders")
                let out = try await engine.correctOrderPrice(
                    orders: orders, inventory: Self.rows(root, "inventory"), orderId: id)
                guard out.ok, let fixed = out.po,
                      let at = orders.firstIndex(where: { Self.recordId($0) == id }) else {
                    throw MoveRefused(sentence: self.words.callIt("mac.order_not_suspect"))
                }
                orders[at] = fixed
                root["purchaseOrders"] = .array(orders)
            }
        } catch let refusal as MoveRefused {
            return refusal.sentence
        } catch {
            return self.said(error)
        }
        await load(source)
        return nil
    }

    /// One purchase order changed by a rule, written through the same swap.
    private func writeToOnePurchaseOrder(
        _ id: String,
        change: @escaping (JSONValue, KhaytEngine) async throws -> JSONValue
    ) async -> String? {
        // Every purchase-order change is stock: one area, asked here for all
        // of them (the staff lock — see OperatorLock.swift).
        guard permitted("inventory", "edit") else { return moveProblem }
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            return words.callIt("mac.read_only")
        }
        guard let engine else { return words.callIt("mac.move_no_engine") }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var orders = Self.rows(root, "purchaseOrders")
                guard let at = orders.firstIndex(where: { Self.recordId($0) == id }) else {
                    throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                }
                orders[at] = try await change(orders[at], engine)
                root["purchaseOrders"] = .array(orders)
            }
        } catch let refusal as MoveRefused {
            return refusal.sentence
        } catch {
            return self.said(error)
        }
        await load(source)
        return nil
    }

    /// Which shelf record an order restocks.
    static func itemId(of order: JSONValue) -> String {
        guard case .object(let o) = order else { return "" }
        return plainString(o["itemId"]) ?? ""
    }

    // MARK: - Who the shop buys from

    /// The suppliers, as a screen reads them, by name.
    ///
    /// Sorted rather than left in book order because the book's order is the
    /// order they were added in, which nobody remembers.
    var suppliers: [Supplier] {
        supplierRows.compactMap(Supplier.init(row:))
            .sorted { a, b in
                a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// Write down something bought from a supplier.
    ///
    /// ── WHY THIS IS NOT AN EXPENSE ────────────────────────────────────────
    ///
    /// It looks like one and is not. An expense is what the shop's books say it
    /// spent; a supplier purchase is what a PRICE was, kept so the price
    /// history can compare it with the next one. The other app keeps them apart
    /// for exactly that reason and so does this: logging a purchase here writes
    /// no expense, and recording an expense writes no purchase.
    ///
    /// Newest first, as the other app writes it (`purchases.unshift`) — the log
    /// is read top-down and the last thing bought is the thing being looked
    /// for.
    func logPurchase(_ entry: [String: JSONValue], against supplierId: String) async {
        moveProblem = nil
        guard permitted("inventory", "edit") else { return }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        guard (Self.plainNumber(entry["amount"]) ?? 0) > 0 else {
            moveProblem = words.callIt("sup.amount_required"); return
        }

        let gone = words.callIt("mac.move_gone")
        do {
            let undo = try await StoreWriter.updateOffMain(build) { root -> [ChangedRecord] in
                var rows = Self.rows(root, "suppliers")
                guard let at = rows.firstIndex(where: { Self.recordId($0) == supplierId }),
                      case .object(var record) = rows[at] else {
                    throw MoveRefused(sentence: gone)
                }
                var undo = [ChangedRecord(collection: "suppliers", id: supplierId, was: record)]
                var log: [JSONValue] = []
                if case .array(let existing)? = record["purchases"] { log = existing }
                var written = entry
                written["id"] = .string(Self.uid("pch"))
                log.insert(.object(written), at: 0)
                record["purchases"] = .array(log)
                StoreWriter.stamp(&record)
                rows[at] = .object(record)
                root["suppliers"] = .array(rows)
                Self.sealUndo(&undo, in: root)
                return undo
            }
            registerMoveUndo(undo, named: words.callIt("sup.log_purchase"))
            await load(source)
            moveNotices = [words.callIt("sup.purchase_saved")]
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch {
            moveProblem = self.said(error)
        }
    }

    /// Write a supplier down, or correct one.
    ///
    /// ── WHAT IS MERGED, AND WHY IT IS NOT A REPLACEMENT ───────────────────
    ///
    /// Only the fields this form offers are written; everything else on the row
    /// stays. A supplier carries `purchases` — the log the other app writes —
    /// and a save that re-encoded the whole record from a form that has never
    /// heard of it would empty the shop's purchase history, which is exactly
    /// how a Mac product save once dropped a product's part costs and re-priced
    /// it at a quarter of what it was worth.
    /// The supplier record a save writes over `was`: the sheet's fields laid
    /// over the stored row, with every field the shop did not change kept as
    /// the book spells it — a price row with fields of its own, a lead time of
    /// 2.5 days, a supplier with no name — because the sheet's own open→save
    /// of the stored row is the baseline (`RoundTrip`). Before, a quote at 0,
    /// a quote with a note, or `leadDays: 0` was rewritten or dropped by
    /// opening the supplier and pressing Save.
    static func supplierRecord(saving supplier: Supplier,
                               over was: [String: JSONValue]) -> [String: JSONValue] {
        var record = was
        var edits = supplier.edits
        if let stored = Supplier(row: .object(was)) {
            let baseline = SupplierSheet.saving(stored, lead: SupplierSheet.leadText(stored)).edits
            edits = RoundTrip.keepUntouched(written: edits, baseline: baseline, stored: was)
        }
        for key in supplier.edits.keys { record[key] = edits[key] }
        return record
    }

    func saveSupplier(_ supplier: Supplier) async {
        moveProblem = nil
        guard permitted("inventory", "edit") else { return }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        guard !supplier.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            moveProblem = words.callIt("sup.name_required"); return
        }

        var undo: [ChangedRecord] = []
        do {
            // The async update: `supplierRecord` asks the sheet's own rules,
            // which live on the main actor. Only this closure runs here.
            try await StoreWriter.updateAsync(build) { root in
                undo = []
                var rows = Self.rows(root, "suppliers")
                let edits = supplier.edits
                if let at = rows.firstIndex(where: { Self.recordId($0) == supplier.id }),
                   case .object(let was) = rows[at] {
                    undo.append(ChangedRecord(collection: "suppliers", id: supplier.id,
                                              was: was))
                    var record = Self.supplierRecord(saving: supplier, over: was)
                    StoreWriter.stamp(&record)
                    rows[at] = .object(record)
                } else {
                    var record = edits
                    record["id"] = .string(Self.uid("sup"))
                    // The other app creates one with an empty log rather than
                    // no log, and every reader of it — the price history chart,
                    // the total-spent column — walks the array without
                    // checking. Writing the field makes the row the same shape
                    // whichever app made it.
                    record["purchases"] = .array([])
                    StoreWriter.stamp(&record)
                    rows.append(.object(record))
                }
                root["suppliers"] = .array(rows)
                Self.sealUndo(&undo, in: root)
            }
            if !undo.isEmpty { registerMoveUndo(undo, named: words.callIt("sup.edit")) }
            // No undo means no record was there before: a new supplier.
            else { Telemetry.feature(.supplierAdded, in: self) }
            editingSupplier = nil
            await load(source)
            moveNotices = [words.callIt("sup.saved")]
        } catch {
            moveProblem = self.said(error)
        }
    }

    /// Take a supplier off the list, and unpoint everything that pointed at it.
    ///
    /// ── WHAT A DELETE HAS TO DO BESIDES DELETING ──────────────────────────
    ///
    /// A spool and a purchase order can each carry a `supplierId`, and dropping
    /// the supplier row on its own leaves both pointing at a record that is not
    /// there. `renderer/inventory.js` has always nulled those out and relinked
    /// them on undo; this app dropped the row and nothing else, so a book
    /// tidied on the Mac came out different from one tidied in the other
    /// window — and the dangling id is the kind of thing that surfaces months
    /// later as a screen that cannot draw.
    ///
    /// WHAT IS NOT TOUCHED is `supplierName` on the order. That is what the
    /// shop actually bought from at the time, and tidying a contact list is
    /// not permission to rewrite what happened — which is why the name is
    /// written onto the order rather than looked up through the id.
    func deleteSupplier(_ id: String) async {
        moveProblem = nil
        guard permitted("inventory", "delete") else { return }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        // On the stack at the click, against the write below (`PendingUndo`).
        let pending: PendingUndo<([String: JSONValue], [ChangedRecord])> =
            pendingUndo(named: words.callIt("sup.deleted")) { shop, gone in
                shop.putBackSupplier(gone.0, relinking: gone.1, in: build)
            }
        defer { pending.drop() }
        do {
            let (removed, unlinked) = try await StoreWriter.updateOffMain(build) { root
                -> ([String: JSONValue]?, [ChangedRecord]) in
                var rows = Self.rows(root, "suppliers")
                guard let at = rows.firstIndex(where: { Self.recordId($0) == id }),
                      case .object(let was) = rows[at] else { return (nil, []) }
                rows.remove(at: at)
                root["suppliers"] = .array(rows)
                return (was, Self.unpointing(&root, from: id))
            }
            if let removed { pending.keep((removed, unlinked)) }
            await load(source)
            moveNotices = [words.callIt("sup.deleted")]
        } catch {
            moveProblem = self.said(error)
        }
    }

    /// Which collections carry a pointer to a supplier.
    ///
    /// The other app's delete walks exactly these two, and a third one growing
    /// the field on either side is the way this quietly stops being true.
    nonisolated static let pointAtSuppliers = ["inventory", "purchaseOrders"]

    /// Null out every `supplierId` that names this supplier, and say what was
    /// changed so an undo can point them back.
    ///
    /// Static and taking `root` so it can be driven by a test with a plain
    /// book: the write path around it is an atomic swap against a real file,
    /// which is not a thing a test can assert one field of.
    nonisolated static func unpointing(_ root: inout [String: JSONValue],
                           from id: String) -> [ChangedRecord] {
        var changed: [ChangedRecord] = []
        for collection in pointAtSuppliers {
            var records = rows(root, collection)
            var touched = false
            for i in records.indices {
                guard case .object(var record) = records[i],
                      plainString(record["supplierId"]) == id else { continue }
                changed.append(ChangedRecord(collection: collection,
                                             id: recordId(records[i]) ?? "",
                                             was: record))
                // NULL, not absent: the other app writes `= null`, and a field
                // two apps spell differently is a field that reads differently
                // depending on which one saved last.
                record["supplierId"] = .null
                StoreWriter.stamp(&record)
                records[i] = .object(record)
                touched = true
            }
            if touched { root[collection] = .array(records) }
        }
        return changed
    }

    /// Put a deleted supplier back, with its purchase log intact — and point
    /// back at it everything that pointed at it before.
    ///
    /// An undo that returned the row and left the spools unlinked would be a
    /// half-undo, and the half it left out is the half nobody would notice
    /// until a drafted order was priced without the quote it should have had.
    private func putBackSupplier(_ record: [String: JSONValue],
                                      relinking unlinked: [ChangedRecord], in build: StoreReader.Build) {
        guard permitted("inventory", "edit"),
              case .string(let id)? = record["id"] else { return }

        let shop = self
        // Written on the chain; the undo itself returns at once.
        Task { do {
            try await StoreWriter.updateOffMain(build) { root in
                var rows = Self.rows(root, "suppliers")
                guard !rows.contains(where: { Self.recordId($0) == id }) else { return }
                rows.append(.object(record))
                root["suppliers"] = .array(rows)
                for (collection, wanted) in Dictionary(grouping: unlinked, by: \.collection) {
                    var records = Self.rows(root, collection)
                    let ids = Set(wanted.map(\.id))
                    var touched = false
                    for i in records.indices {
                        guard case .object(var r) = records[i],
                              let rid = Self.recordId(records[i]), ids.contains(rid),
                              Self.plainString(r["supplierId"]) == nil else { continue }
                        r["supplierId"] = .string(id)
                        StoreWriter.stamp(&r)
                        records[i] = .object(r)
                        touched = true
                    }
                    if touched { root[collection] = .array(records) }
                }
            }
            // Read back, or the supplier is in the book and not on screen
            // until something else reloads it.
            await shop.load(shop.source)
        } catch {
            shop.moveProblem = self.said(error)
        } }
    }

    // MARK: - What the shop spent, and what it wasted

    /// The expenses in the chosen period, newest first, matching the search.
    ///
    /// The search box is on the window, so it is on these screens too — and a
    /// search field that does nothing on the screen you are looking at is
    /// worse than no search field. What a shop looks for here is a note or a
    /// category: "nozzles", "electricity", the job a cost was booked to.
    var shownExpenses: [Expense] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return expenses
            .filter { inPeriod($0.date) }
            .filter {
                q.isEmpty || $0.note.lowercased().contains(q)
                    || words.callIt("exp.cat." + $0.category).lowercased().contains(q)
                    || ($0.orderId ?? "").lowercased().contains(q)
            }
            .sorted { $0.date > $1.date }
    }

    /// The waste entries in the chosen period, newest first, matching the
    /// search — by material, by what went wrong, or by the words somebody
    /// wrote about it.
    var shownWaste: [WasteEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return wasteLog
            .filter { inPeriod($0.date) }
            .filter {
                q.isEmpty || $0.material.lowercased().contains(q)
                    || $0.reason.lowercased().contains(q)
                    || words.callIt("waste.ft." + $0.failureType).lowercased().contains(q)
            }
            .sorted { $0.date > $1.date }
    }

    /// Whether a date falls in the chosen period.
    ///
    /// Swift, not the engine, and deliberately: this decides whether to draw a
    /// row, so it is asked once per record while a list lays out — a bridge
    /// crossing each time would be thousands of them. `PeriodTests` runs it
    /// against `lib/date-range.js` over every range and a year of dates, so the
    /// two cannot answer differently.

    /// Everything the machine P&L needs, filtered to the chosen period — ALL
    /// FOUR THE SAME WAY.
    ///
    /// That symmetry is the whole care here. `renderer/analytics.js` carries a
    /// note about the version that got it wrong: maintenance was filtered by
    /// calendar YEAR while revenue and material were filtered by the chosen
    /// range, so picking "This month" charged January's nozzle-and-belt
    /// overhaul against July's revenue — and a profitable printer read as
    /// loss-making, which is the exact figure an owner uses to decide whether
    /// to retire a machine.
    ///
    /// `lib/machine-pl.js` does not know what a range is, deliberately. It is
    /// decided once, here.
    /// The two spellings of finished, as `lib/order-status.js` names them.
    ///
    /// Held here rather than asked per row — this filters every order in the
    /// book — and `FinishedStatusTests` holds the list to the rule's own, so
    /// it cannot drift from the shared vocabulary the way the comparison it
    /// replaces did. That comparison was `status == "completed"` alone, which
    /// left every job a shop had marked delivered out of what its printers had
    /// earned, in this app and the other one both.
    static let finishedStatuses: Set<String> = ["completed", "delivered"]

    func completedInPeriod() async -> (orders: [JSONValue],
                                       expenses: [JSONValue],
                                       maintenance: [JSONValue]) {
        let orders = orderRows.filter { row in
            guard case .object(let o) = row,
                  case .string(let status)? = o["status"], Self.finishedStatuses.contains(status),
                  case .string(let date)? = o["date"] else { return false }
            return inPeriod(date)
        }
        // An expense with no order behind it is a shop cost, not a machine's —
        // the shop's own P&L has it, and charging it to a printer would count
        // it twice.
        let spend = expenseRows.filter { row in
            guard case .object(let e) = row, case .string(let id)? = e["orderId"], !id.isEmpty,
                  case .string(let date)? = e["date"] else { return false }
            return inPeriod(date)
        }
        let serviced = maintenanceRows.filter { row in
            guard case .object(let m) = row, case .string(let date)? = m["date"] else { return false }
            return inPeriod(date)
        }
        return (orders, spend, serviced)
    }

    func inPeriod(_ date: String, now: Date? = nil) -> Bool {
        Self.inPeriod(date, period: period, now: now ?? self.now)
    }

    /// How long the chosen period is, in days.
    ///
    /// The denominator under "hours run against hours wanted". It has to match
    /// what the other app's `analyticsRangeDays` answers or the same machine
    /// reads at two utilisations depending on which app is open — which is the
    /// whole class of fault the shared rules exist to end, arriving through the
    /// back door as an argument rather than as arithmetic.
    ///
    /// A WHOLE month, not the days elapsed in it. Mid-month that makes every
    /// machine look under-worked, and it is still the right answer: the target
    /// is a rate for the month, the figure is what has been done against it so
    /// far, and a shop reading 40% on the 12th is reading something true.
    func periodDays(now pinned: Date? = nil, dates: [String] = []) -> Int {
        let now = pinned ?? self.now
        let cal = Calendar.book
        switch period {
        case .month:
            return cal.range(of: .day, in: .month, for: now)?.count ?? 30
        case .last_month:
            guard let lm = cal.date(byAdding: .month, value: -1, to: now) else { return 30 }
            return cal.range(of: .day, in: .month, for: lm)?.count ?? 30
        case .quarter: return 91
        case .year: return 365
        case .all:
            // Span the data itself, as the other app does. A shop six weeks old
            // is not running against a year.
            let days = dates.map { String($0.prefix(10)) }.filter { !$0.isEmpty }.sorted()
            guard let first = days.first, let last = days.last,
                  let from = Order.day(first), let to = Order.day(last) else { return 30 }
            return max(1, Int((to.timeIntervalSince(from) / 86_400).rounded()) + 1)
        }
    }

    /// The chosen period as book days, `YYYY-MM-DD` both ends inclusive, with
    /// the end cut to today for a period still running — what a straight-line
    /// machine's depreciation is pro-rated over in the machine P&L, so "This
    /// month" on the 12th charges twelve days of it, not thirty.
    ///
    /// "All time" starts at the book's first order — `dates`, every job's
    /// date — which is what the other app's `analyticsRangeSpan` answers, so a
    /// straight-line machine bought before the shop's first job is charged
    /// from the same day in both. The rule then clips to the day each machine
    /// was bought. With no dates it falls back to the epoch, which the rule
    /// clips to the purchase date.
    static func periodSpan(_ period: Period, now: Date = Date(),
                           dates: [String] = []) -> (from: String, to: String) {
        let cal = Calendar.book
        let today = Self.today(now)
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        func day(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%04d-%02d-%02d", y, m, d) }
        func lastDay(_ y: Int, _ m: Int) -> Int {
            guard let first = cal.date(from: DateComponents(year: y, month: m, day: 1)) else { return 28 }
            return cal.range(of: .day, in: .month, for: first)?.count ?? 28
        }
        switch period {
        case .month:
            return (day(year, month, 1), today)
        case .last_month:
            let (y, m) = month == 1 ? (year - 1, 12) : (year, month - 1)
            return (day(y, m, 1), day(y, m, lastDay(y, m)))
        case .quarter:
            return (day(year, ((month - 1) / 3) * 3 + 1, 1), today)
        case .year:
            return (day(year, 1, 1), today)
        case .all:
            let first = dates.map { String($0.prefix(10)) }
                .filter { Order.day($0) != nil }.min()
            return (first ?? "1970-01-01", today)
        }
    }

    static func inPeriod(_ date: String, period: Period, now: Date = Date()) -> Bool {
        if period == .all { return true }
        guard !date.isEmpty else { return false }
        let ds = String(date.prefix(10))
        guard ds.count == 10, Order.day(ds) != nil else { return false }
        let cal = Calendar.book
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        switch period {
        case .month:
            return ds.hasPrefix(String(format: "%04d-%02d", year, month))
        case .last_month:
            let lm = cal.date(byAdding: .month, value: -1, to: cal.date(from: DateComponents(year: year, month: month, day: 1))!)!
            return ds.hasPrefix(String(format: "%04d-%02d", cal.component(.year, from: lm), cal.component(.month, from: lm)))
        case .quarter:
            guard let dsYear = Int(ds.prefix(4)), let dsMonth = Int(ds.dropFirst(5).prefix(2)) else { return false }
            return dsYear == year && (dsMonth - 1) / 3 == (month - 1) / 3
        case .year:
            return ds.hasPrefix(String(format: "%04d", year))
        case .all:
            return true
        }
    }

    /// What the shown expenses come to, and what each category came to.
    var expenseTotals: (total: Double, byCategory: [String: Double]) {
        var byCategory: [String: Double] = [:]
        for category in Self.expenseCategories { byCategory[category] = 0 }
        var total = 0.0
        for e in shownExpenses {
            byCategory[e.category, default: 0] += e.amount
            total += e.amount
        }
        return (total, byCategory)
    }

    /// What THIS CALENDAR MONTH's expenses came to, per category — whatever the
    /// period picker is showing.
    ///
    /// A BUDGET IS A MONTHLY THING. `lib/expense-book.js`'s `overBudget` filters
    /// on `date.startsWith(month)` and the toast after an overspend says "this
    /// month", so a budget compared against anything else is comparing two
    /// different periods. The panel used the SHOWN totals, which the period
    /// picker moves: on "All time" a shop with 1,240 of filament against a 1,500
    /// budget was told it was over by 2,130, and every category eventually goes
    /// over a monthly budget if you total enough months into it. Two of the
    /// sample book's three "Over budget" warnings were false.
    ///
    /// The shop's own calendar day, like `today()` — not UTC's. See
    /// `overBudget`'s note about a month boundary being local.
    var expenseTotalsThisMonth: [String: Double] {
        Self.totals(of: expenses, inMonth: String(Self.today().prefix(7)))   // "2026-09"
    }

    /// The filtering on its own, so it can be asked about a month that is not
    /// today's — `BudgetIsMonthlyTests`.
    static func totals(of expenses: [Expense], inMonth month: String) -> [String: Double] {
        var byCategory: [String: Double] = [:]
        for category in expenseCategories { byCategory[category] = 0 }
        for e in expenses where e.date.hasPrefix(month) {
            byCategory[e.category, default: 0] += e.amount
        }
        return byCategory
    }

    /// A shop that has not sold anything yet — as opposed to one that sold
    /// nothing this month.
    ///
    /// The difference matters on the dashboard: a shop with a quiet September
    /// genuinely earned 0.00 and should be told so, while a shop that opened
    /// yesterday has nothing to total and a row of zeros tells it only that the
    /// app can count to zero. Asked of the WHOLE book, not the period, so
    /// changing the picker cannot turn the front door into an empty state.
    var hasNotTradedYet: Bool { Self.hasNotTraded(orders: orders) }

    /// Separated so it can be asked without a loaded shop — `FirstRunTests`.
    static func hasNotTraded(orders: [Order]) -> Bool { orders.isEmpty }

    /// Khayt's own categories, in its own order.
    static let expenseCategories = ExpenseCategory.known

    /// Record an expense.
    ///
    /// What the note on a receipt line reads like, or nil.
    ///
    /// The whole answer is `lib/expense-categorize.js` — the keyword list, the
    /// Arabic terms, and the "most distinct hits wins" tie-break are all the
    /// shared rule's, so a receipt filed on the Mac is filed where Khayt would
    /// have filed it. A second keyword list in Swift would have drifted from
    /// that one the first time somebody added a word to either.
    ///
    /// Nil when nothing matches, which is most notes, and nil when there is no
    /// engine: a suggestion is a convenience and its absence must never stop a
    /// shop recording what it spent.
    func categoryFor(_ note: String) async -> String? {
        guard let engine, !note.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return try? await engine.suggestedCategory(for: note)
    }

    /// The record is `lib/expense-book.js`'s, so this app and Khayt write the
    /// same one. A budget the month has now gone past is said afterwards, by
    /// the same rule the Electron page says it with — a warning, not a refusal:
    /// the money has already been spent.
    func addExpense(_ input: [String: JSONValue]) async {
        guard permitted("invoicing", "create") else { return }
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            spendProblem = words.callIt("mac.move_no_engine"); return
        }
        var overspend: (category: String, over: Overspend)?
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let made = try await engine.newExpense(input, id: Self.uid("EXP"), today: Self.today())
                guard let record = made.expense, case .object(let fields) = record else {
                    throw MoveRefused(sentence: self.words.callIt("exp.amount_required"))
                }
                var rows = Self.rows(root, "expenses")
                rows.insert(record, at: 0)
                root["expenses"] = .array(rows)
                // Asked with the expense already in, on the shop's own calendar
                // month — a UTC month counts the wrong one for the first hours
                // of the 1st east of London.
                if let category = Self.plainString(fields["category"]),
                   let over = try await engine.overBudget(rows, category: category,
                                                          month: String(Self.today().prefix(7)),
                                                          budgets: Self.settings(root)["expBudgets"].flatMap {
                                                              if case .object(let b) = $0 { return b } else { return nil }
                                                          } ?? [:]) {
                    overspend = (category, over)
                }
            }
            Telemetry.feature(.expenseAdded, in: self)
            await load(source)
            if let overspend {
                spendNote = words.callIt("exp.budget_exceeded", [
                    "cat": .string(words.callIt("exp.cat." + overspend.category)),
                    "spent": .string(Money.figure(overspend.over.spent)),
                    "budget": .string(Money.figure(overspend.over.budget)),
                ])
            } else {
                spendNote = words.callIt("exp.added")
            }
        } catch let refusal as MoveRefused {
            spendProblem = refusal.sentence
        } catch {
            spendProblem = self.said(error)
        }
    }

    /// Log a failed print.
    ///
    /// Two collections in one swap: the log and the shelf. A log saying a print
    /// wasted 200g while the spool still holds them has told the shop it has
    /// filament it has already thrown away.
    func logWaste(_ input: [String: JSONValue]) async {
        guard permitted("inventory", "create") else { return }
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            spendProblem = words.callIt("mac.move_no_engine"); return
        }
        var spentAttempt: String?
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                // A failure logged against a JOB is costed whole: its machine
                // time and power beside the filament (`failed-print-cost`).
                let job: JSONValue? = Self.plainString(input["orderId"]).flatMap { id in
                    id.isEmpty ? nil : Self.rows(root, "printLog").first { Self.recordId($0) == id }
                }
                let costed = job.map {
                    self.failedCosting(order: $0, machines: Self.rows(root, "machines"),
                                       settings: Self.settings(root), inspected: false)
                }
                let costing = costed?.costing
                spentAttempt = costed?.spent
                // With a job, the grams come off THAT job's spools (`forOrder`),
                // as the other app's waste form takes them.
                let made = try await engine.newWasteEntry(
                    input, id: Self.uid("W"), today: Self.today(),
                    inventory: Self.rows(root, "inventory"), order: job, costing: costing,
                    settings: Self.settings(root), machines: Self.rows(root, "machines"),
                    reclaimsTax: self.reclaimsTax)
                guard let entry = made.entry else {
                    throw MoveRefused(sentence: self.words.callIt("waste.err_material"))
                }
                var log = Self.rows(root, "wasteLog")
                log.insert(entry, at: 0)
                root["wasteLog"] = .array(log)
                // The shelf as the deduction left it — stamped, because those
                // spools are edits to existing records and the cloud's sync
                // baseline reads the stamp.
                root["inventory"] = .array(Self.stamping(made.inventory,
                                                         against: Self.rows(root, "inventory")))
            }
            // Saved: the kept meter reading this row used is spent, so a second
            // failure logged against the job does not carry it again.
            if let spentAttempt { energyMeter()?.consumeAttempt(for: spentAttempt) }
            await load(source)
            spendNote = words.callIt("waste.saved")
        } catch let refusal as MoveRefused {
            spendProblem = refusal.sentence
        } catch {
            spendProblem = self.said(error)
        }
    }

    /// Take a waste entry out, and put its grams back on the spool it came off.
    ///
    /// An entry written before the spool was recorded (anything logged by hand
    /// before #971) restores nothing, because nothing knows where the filament
    /// came from. It is deleted anyway: leaving a row a shop cannot remove is
    /// worse than a shelf figure it can correct.
    func deleteWaste(_ id: String) async {
        guard permitted("inventory", "delete") else { return }
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            spendProblem = words.callIt("mac.move_no_engine"); return
        }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let before = Self.rows(root, "inventory")
                let out = try await engine.removeWasteEntry(
                    Self.rows(root, "wasteLog"), id: id, inventory: before)
                guard out.removed else { throw MoveRefused(sentence: self.words.callIt("mac.move_gone")) }
                root["wasteLog"] = .array(out.wasteLog)
                root["inventory"] = .array(Self.stamping(out.inventory, against: before))
            }
            await load(source)
            spendNote = words.callIt("waste.deleted")
        } catch let refusal as MoveRefused {
            spendProblem = refusal.sentence
        } catch {
            spendProblem = self.said(error)
        }
    }

    /// Stamp the rows a rule actually changed, and leave the rest alone.
    ///
    /// `rev` and `updatedAt` are what the cloud's sync baseline reads, so an
    /// unstamped edit never leaves this Mac — and stamping a row nothing
    /// touched sends the whole shelf up on every deletion.
    static func stamping(_ after: [JSONValue], against before: [JSONValue]) -> [JSONValue] {
        let was = Dictionary(before.compactMap { row -> (String, JSONValue)? in
            guard let id = recordId(row) else { return nil }
            return (id, row)
        }, uniquingKeysWith: { a, _ in a })
        return after.map { row in
            guard case .object(var fields) = row, let id = recordId(row),
                  let previous = was[id], previous != row else { return row }
            StoreWriter.stamp(&fields)
            return .object(fields)
        }
    }

    /// Today, as the book writes a day: Gregorian, in the shop's time zone —
    /// see `Calendar.book`.
    nonisolated static func today(_ now: Date = Date()) -> String {
        let c = Calendar.book.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - The shelf

    /// Bring every spool across from Spoolman that is not already on the
    /// shelf. Returns the sentence to show, or throws what went wrong —
    /// fetching first, then one write for the whole import, so a network
    /// failure halfway leaves the shelf untouched.
    func importFromSpoolman(_ address: String) async throws -> String {
        guard permitted("inventory", "create") else { throw MoveRefused(sentence: moveProblem ?? "") }
        guard let build = source.build else { throw MoveRefused(sentence: words.callIt("mac.move_sample")) }
        guard let engine else { throw MoveRefused(sentence: words.callIt("mac.move_no_engine")) }
        let base = try await SpoolmanImport.base(address, engine: engine)
        let spools = try await SpoolmanImport.fetchAll(base, engine: engine)
        var plan: KhaytEngine.SpoolmanPlan?
        try await StoreWriter.update(
            storeURL: build.storeURL,
            owns: { StoreLock.weOwnIt(build) },
            whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
        ) { root in
            plan = try await Self.addFromSpoolman(into: &root, spools: spools, engine: engine, today: Self.today())
        }
        await load(source)
        guard let plan else { return "" }
        return words.callIt("mac.spoolman_done", [
            "added": .number(Double(plan.add.count)),
            "already": .number(Double(plan.skipped.already)),
            "skipped": .number(Double(plan.skipped.archived + plan.skipped.unnamed)),
        ])
    }

    /// The mutation the import runs INSIDE the write, on the newest shelf —
    /// so a spool added a moment ago by another window is still seen as
    /// already imported. Each new spool is stamped. Separate so a test can run
    /// exactly this against a real file.
    static func addFromSpoolman(into root: inout [String: JSONValue], spools: [JSONValue],
                                engine: KhaytEngine, today: String) async throws -> KhaytEngine.SpoolmanPlan {
        let shelf = rows(root, "inventory")
        let ids = (0..<spools.count).map { _ in uid("INV") }
        let plan = try await engine.spoolmanPlan(spools: spools, inventory: .array(shelf), ids: ids, today: today)
        guard !plan.add.isEmpty else { return plan }
        var next = shelf
        for row in plan.add {
            guard case .object(var record) = row else { continue }
            StoreWriter.stamp(&record)
            next.append(.object(record))
        }
        root["inventory"] = .array(next)
        return plan
    }

    /// Put a spool on the shelf, or correct one that is already there.
    ///
    /// A NEW spool is a new record and is not stamped; an edit is stamped like
    /// every other, because the cloud's sync baseline reads the stamp. The
    /// settings go with it when a colour variant taught the shop's library
    /// something — one swap, or the library forgets what was just typed.
    /// A rule's edit of `stored`, with every field the shop did not change
    /// put back as the book spells it.
    ///
    /// `written` is the rule's answer to the save; `baseline` its answer to
    /// the form exactly as it opened. Both start from the same stored record,
    /// so wherever they agree the difference from the book is the FORM's
    /// re-spelling — `"150"` read as 150, an ISO stamp read as a day, a colour
    /// name read as grey — and not anything the shop did (`RoundTrip`).
    static func keptEdit(_ stored: JSONValue, written: JSONValue?,
                         baseline: JSONValue?) -> JSONValue? {
        guard case .object(let w)? = written, case .object(let b)? = baseline,
              case .object(let s) = stored else { return written }
        return .object(RoundTrip.keepUntouched(written: w, baseline: b, stored: s))
    }

    /// A spool edited by the shared rule, keeping what the shop did not touch.
    static func editedSpool(_ stored: JSONValue, input: [String: JSONValue],
                            opened: [String: JSONValue]?, settings: [String: JSONValue],
                            today: String, engine: KhaytEngine) async throws -> SpoolEdited {
        let out = try await engine.editSpool(stored, input: input, settings: settings, today: today)
        guard let opened, out.refused == nil else { return out }
        let base = try await engine.editSpool(stored, input: opened, settings: settings, today: today)
        var spool = keptEdit(stored, written: out.spool, baseline: base.spool) ?? out.spool
        // A price the shop CHANGED is a price-history entry, whatever the
        // baseline did. The rule compares numerically now, but a baseline that
        // logged a phantom change (a stored `"85"` re-saved as 85) used to
        // carry the very entry the real edit wrote, and the round trip then
        // put the stored list back — the old price silently gone from history.
        if plainNumber(input["cost"]) != plainNumber(opened["cost"]),
           case .object(var kept) = spool, case .object(let written) = out.spool {
            if let history = written["priceHistory"] { kept["priceHistory"] = history }
            spool = .object(kept)
        }
        return SpoolEdited(spool: spool,
                           settings: out.settings, refused: out.refused, colourAdded: out.colourAdded)
    }

    /// A new spool on the shelf, against the book as it is on disk — the
    /// Spool sheet's Add and the first-run setup's filament both land here,
    /// through `lib/spool-edit.js`. A NEW record: nothing was opened, so
    /// there is nothing to keep untouched. False when the rule refused it (no
    /// material), in which case nothing was changed.
    static func writeNewSpool(into root: inout [String: JSONValue], input: [String: JSONValue],
                              engine: KhaytEngine, newId: String, today: String) async throws -> Bool {
        let made = try await engine.newSpool(input, id: newId, today: today)
        guard var record = made.spool else { return false }
        // EVERYTHING ELSE THE FORM SAID. `newSpool` writes the roll itself —
        // material, price, weight, colour, lot, branch — and nothing more, so
        // the unit, the colour variant, the reorder point and quantity and the
        // print settings were dropped: a 10-sheet pack of ply saved as 10 g and
        // was flagged low at once. The edit rule writes the rest, as Edit
        // would; the keys `newSpool` already wrote are left out because the
        // edit rule clamps some of them differently (a weight of nothing).
        let alreadyWritten: Set<String> = ["material", "cost", "vatAmount", "weight", "color",
                                           "materialType", "lot", "locationId"]
        let rest = input.filter { !alreadyWritten.contains($0.key) }
        if !rest.isEmpty {
            let out = try await engine.editSpool(record, input: rest, settings: settings(root),
                                                 today: today)
            record = out.spool
            // The colour library learns the variant in the same swap, or the
            // next editor offers a list that has forgotten it.
            if out.colourAdded != nil { root["settings"] = .object(out.settings) }
        }
        root["inventory"] = .array(rows(root, "inventory") + [record])
        return true
    }

    /// `opened` is the sheet's input for the spool as it opened — see
    /// `keptEdit`. Nil for a new spool.
    func saveSpool(_ input: [String: JSONValue], id: Spool.ID?,
                   opened: [String: JSONValue]?) async {
        guard permitted("inventory", "edit") else { return }
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            spendProblem = words.callIt("mac.move_no_engine"); return
        }
        var undo: [ChangedRecord] = []
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                undo = []  // the book moved and this runs again: one entry, not two
                var shelf = Self.rows(root, "inventory")
                if let id {
                    guard let at = shelf.firstIndex(where: { Self.recordId($0) == id }),
                          case .object(let was) = shelf[at] else {
                        throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                    }
                    let out = try await Self.editedSpool(shelf[at], input: input, opened: opened,
                                                         settings: Self.settings(root),
                                                         today: Self.today(), engine: engine)
                    if out.refused != nil {
                        throw MoveRefused(sentence: self.words.callIt("inv.material_ph"))
                    }
                    guard case .object(var record) = out.spool else { return }
                    undo.append(ChangedRecord(collection: "inventory", id: id, was: was))
                    StoreWriter.stamp(&record)
                    shelf[at] = .object(record)
                    root["settings"] = .object(out.settings)
                } else {
                    root["inventory"] = .array(shelf)
                    guard try await Self.writeNewSpool(into: &root, input: input, engine: engine,
                                                       newId: Self.uid("INV"), today: Self.today())
                    else { throw MoveRefused(sentence: self.words.callIt("inv.material_ph")) }
                    return
                }
                root["inventory"] = .array(shelf)
                Self.sealUndo(&undo, in: root)
            }
            if !undo.isEmpty { registerMoveUndo(undo, named: words.callIt("mac.edit_spool")) }
            editingSpool = nil
            addingSpool = false
            await load(source)
            spendNote = words.callIt(id == nil ? "inv.added" : "inv.updated")
            if id == nil { Telemetry.feature(.spoolAdded, in: self) }
        } catch let refusal as MoveRefused {
            spendProblem = refusal.sentence
        } catch {
            spendProblem = self.said(error)
        }
    }

    /// Take a spool off the shelf.
    ///
    /// Undoable, because it is a whole record: a spool deleted by mistake takes
    /// its price history and its usage with it, and nothing else in the book
    /// can reconstruct them.
    func deleteSpool(_ id: Spool.ID) async {
        guard permitted("inventory", "delete") else { return }
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        // On the stack at the click, against the write below (`PendingUndo`).
        let pending: PendingUndo<[String: JSONValue]> =
            pendingUndo(named: words.callIt("inv.removed")) { shop, gone in shop.putBackSpool(gone, in: build) }
        defer { pending.drop() }
        do {
            let removed = try await StoreWriter.updateOffMain(build) { root -> [String: JSONValue]? in
                var shelf = Self.rows(root, "inventory")
                guard let at = shelf.firstIndex(where: { Self.recordId($0) == id }),
                      case .object(let was) = shelf[at] else { return nil }
                shelf.remove(at: at)
                root["inventory"] = .array(shelf)
                return was
            }
            if let removed { pending.keep(removed) }
            await load(source)
            spendNote = words.callIt("inv.removed")
        } catch {
            spendProblem = self.said(error)
        }
    }

    // MARK: - The other shelf

    /// Add one, or correct one.
    ///
    /// The same shape as `saveSpool`, and for the same reasons: read the shelf
    /// INSIDE the write (the in-memory copy lags every in-flight write), and
    /// hand the record to the rule rather than rebuilding it, so the fields
    /// neither this app nor the rule knows about survive.
    /// A consumable edited by the shared rule, keeping what the shop did not
    /// touch — see `keptEdit`.
    static func editedConsumable(_ stored: JSONValue, input: [String: JSONValue],
                                 opened: [String: JSONValue]?,
                                 engine: KhaytEngine) async throws -> ConsumableEdited {
        let out = try await engine.editConsumable(stored, input: input)
        guard let opened, out.refused == nil else { return out }
        let base = try await engine.editConsumable(stored, input: opened)
        return ConsumableEdited(
            consumable: keptEdit(stored, written: out.consumable, baseline: base.consumable) ?? out.consumable,
            refused: out.refused)
    }

    /// `opened` is the sheet's input for the item as it opened. Nil for a new one.
    func saveConsumable(_ input: [String: JSONValue], id: Consumable.ID?,
                        opened: [String: JSONValue]?) async {
        guard permitted("inventory", "edit") else { return }
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            spendProblem = words.callIt("mac.move_no_engine"); return
        }
        var undo: [ChangedRecord] = []
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                undo = []  // the book moved and this runs again: one entry, not two
                var shelf = Self.rows(root, "consumables")
                if let id {
                    guard let at = shelf.firstIndex(where: { Self.recordId($0) == id }),
                          case .object(let was) = shelf[at] else {
                        throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                    }
                    let out = try await Self.editedConsumable(shelf[at], input: input,
                                                              opened: opened, engine: engine)
                    if out.refused != nil {
                        throw MoveRefused(sentence: self.words.callIt("cons.name_ph"))
                    }
                    guard case .object(var record) = out.consumable else { return }
                    undo.append(ChangedRecord(collection: "consumables", id: id, was: was))
                    StoreWriter.stamp(&record)
                    shelf[at] = .object(record)
                } else {
                    let made = try await engine.newConsumable(input, id: Self.uid("CNS"))
                    guard let record = made.consumable else {
                        throw MoveRefused(sentence: self.words.callIt("cons.name_ph"))
                    }
                    shelf.append(record)
                }
                root["consumables"] = .array(shelf)
                Self.sealUndo(&undo, in: root)
            }
            if !undo.isEmpty { registerMoveUndo(undo, named: words.callIt("cons.edit_title")) }
            editingConsumable = nil
            addingConsumable = false
            await load(source)
            spendNote = words.callIt("cons.saved")
        } catch let refusal as MoveRefused {
            spendProblem = refusal.sentence
        } catch {
            spendProblem = self.said(error)
        }
    }

    /// Undo a consumable delete: put the row back. It returns under a new id
    /// (see `StoreWriter.reviveUnderNewIds`), because the delete's tombstone
    /// may already have reached the cloud, where it wins over the old one.
    private func putBackConsumable(_ record: [String: JSONValue], in build: StoreReader.Build) {
        guard permitted("inventory", "edit"),
              case .string(let id)? = record["id"] else { return }

        let shop = self
        // Written on the chain; the undo itself returns at once.
        Task {
            do {
                try await StoreWriter.updateOffMain(build) { root in
                    var shelf = Self.rows(root, "consumables")
                    guard !shelf.contains(where: { Self.recordId($0) == id }) else { return }
                    shelf.append(.object(record))
                    root["consumables"] = .array(shelf)
                }
                await shop.load(shop.source)
            } catch {
                shop.spendProblem = self.said(error)
            }
        }
    }

    /// Take one off the shelf.
    ///
    /// Nothing else points at a consumable the way an order points at a spool,
    /// so this really is just the row — but the deduction paths have spent it,
    /// and those records name it by id. They keep the id they were written
    /// with, which reads back as an item no longer on the shelf rather than as
    /// a changed history.
    func deleteConsumable(_ id: Consumable.ID) async {
        guard permitted("inventory", "delete") else { return }
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        // On the stack at the click, against the write below (`PendingUndo`).
        let pending: PendingUndo<[String: JSONValue]> =
            pendingUndo(named: words.callIt("cons.title")) { shop, gone in shop.putBackConsumable(gone, in: build) }
        defer { pending.drop() }
        do {
            let undo = try await StoreWriter.updateOffMain(build) { root -> [ChangedRecord] in
                var shelf = Self.rows(root, "consumables")
                guard let at = shelf.firstIndex(where: { Self.recordId($0) == id }),
                      case .object(let was) = shelf[at] else { return [] }
                shelf.remove(at: at)
                root["consumables"] = .array(shelf)
                return [ChangedRecord(collection: "consumables", id: id, was: was)]
            }
            // NOT registerMoveUndo: that puts back rows that are still there,
            // and a deleted row is not, so Undo did nothing at all.
            if let gone = undo.first { pending.keep(gone.was) }
            await load(source)
            spendNote = words.callIt("inv.removed")
        } catch {
            spendProblem = self.said(error)
        }
    }

    /// The shelves the consumables are on, each with its count — and the
    /// selection to actually use, which the rule drops when the chosen shelf
    /// has been emptied.
    func consumableShelves() async -> (categories: [KhaytEngine.ConsumableCategory],
                                       selected: String, uncategorised: String) {
        guard let engine, !consumableRows.isEmpty else { return ([], "", "") }
        let cats = (try? await engine.consumableCategories(consumableRows)) ?? []
        let chosen = (try? await engine.consumableSelection(consumableRows,
                                                            selected: consumableCategory)) ?? ""
        let none = (try? await engine.consumableUncategorised()) ?? ""
        return (cats, chosen, none)
    }

    /// The categories this shop already uses, for the editor to offer.
    func consumableCategorySuggestions() async -> [String] {
        guard let engine, !consumableRows.isEmpty else { return [] }
        return (try? await engine.consumableSuggestions(consumableRows)) ?? []
    }

    /// The ids on one shelf. Ids rather than records, because the rows are the
    /// raw truth and the screen draws the decoded `consumables`.
    func consumableIds(inCategory selected: String) async -> [String]? {
        guard let engine, !selected.isEmpty else { return nil }
        guard let rows = try? await engine.consumablesInCategory(consumableRows,
                                                                 selected: selected) else { return nil }
        return rows.compactMap { Self.recordId($0) }
    }
}
