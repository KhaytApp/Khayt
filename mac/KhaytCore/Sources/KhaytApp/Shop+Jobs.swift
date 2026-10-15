import Foundation
import UniformTypeIdentifiers
import AppKit
import Observation
import KhaytCore

extension Shop {

    // MARK: - Moving a job

    /// The failure categories, from `lib/qc-failure.js`. A category not on this
    /// list reaches the waste screen as a value it cannot name.
    static let failureTypes = ["bed_adhesion", "nozzle_jam", "warping", "stringing",
                               "operator_error", "design_issue", "power_failure",
                               "material_quality", "other"]

    /// Record a QC failure and send the job back to be printed again.
    ///
    /// THREE RECORDS, ONE SWAP: the fields on the order that the metrics count,
    /// the defect the analytics table is built from, and the waste row. A book
    /// where the job says it failed and the waste log has never heard of it is
    /// a shop whose scrap costs are quietly understated.
    func recordQcFailure(_ id: Order.ID, failureType: String, reason: String,
                         weight: Double) async {
        moveProblem = nil
        guard permitted("orders", "edit") else { return }
        moveNotices = []
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            moveProblem = words.callIt("mac.move_no_engine"); return
        }

        var spentAttempt: String?
        var undo: [ChangedRecord] = []
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let orders = Self.rows(root, "printLog")
                guard let target = orders.first(where: { Self.recordId($0) == id }) else {
                    throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                }
                let shelfBefore = Self.rows(root, "inventory")
                // A QC failure is a print that RAN TO THE END: the whole of its
                // time and power went into a part nobody can sell.
                let (costing, spent) = self.failedCosting(order: target, machines: Self.rows(root, "machines"),
                                                          settings: Self.settings(root), inspected: true)
                spentAttempt = spent
                let out = try await engine.recordQcFailure(
                    order: target, failureType: failureType, severity: "major",
                    reason: reason, weight: weight, inspector: nil,
                    inventory: shelfBefore, now: Date(),
                    wasteId: Self.uid("WASTE"),
                    defaultReason: self.words.callIt("ord.qc_fail"),
                    settings: Self.settings(root), machines: Self.rows(root, "machines"),
                    today: Self.today(), costing: costing)

                undo = Self.writeQcFailure(&root, order: out.order, waste: out.waste,
                                           inventory: out.inventory,
                                           ordersBefore: orders, shelfBefore: shelfBefore)
            }
            // The waste row is saved: a kept meter reading it used is spent.
            if let spentAttempt { energyMeter()?.consumeAttempt(for: spentAttempt) }
            registerMoveUndo(undo, named: words.callIt("ord.qc_fail"))
            await load(source)
            // Back to be printed again — the move Khayt and Bed Ready both make
            // after a failure, and it carries its own gate and effects.
            await moveJob(id, to: .pending)
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch {
            moveProblem = String(describing: error)
        }
    }

    /// What a failed attempt is costed from, for `lib/failed-print-cost.js`:
    /// the machine, how long the attempt ran and how far it got, and what its
    /// plug metered.
    ///
    /// The hours are the PRINTER's, from the finish seam, when the last print
    /// that ended on the job's machine was this job's; else the job's actual
    /// time for an inspected print (it ran to the end); else the rule scales
    /// the estimate by the progress at failure — 100% for an inspected print,
    /// and the printer's last reported progress for one that stopped.
    ///
    /// `spent` is the job whose kept meter attempt this costing used, for the
    /// caller to consume once its waste row is saved (`EnergyMeter.consumeAttempt`).
    func failedCosting(order: JSONValue, machines: [JSONValue], settings: [String: JSONValue],
                       inspected: Bool) -> (costing: JSONValue, spent: String?) {
        guard case .object(let o) = order else { return (.null, nil) }
        let jobId = Self.plainString(o["id"]) ?? ""
        let machineId = Self.plainString(o["machineId"]) ?? ""
        let ended = lastPrintEnded[machineId].flatMap { $0.orderId == jobId ? $0 : nil }
        let live = printers.statusCache[machineId]
        let attempt = energyMeter()?.attempt(for: jobId)
        let costing = Self.failedCosting(order: o, machines: machines, settings: settings,
                                         ended: ended, live: live,
                                         attempt: attempt, inspected: inspected)
        return (costing, Self.usesAttempt(order: o, attempt: attempt, inspected: inspected) ? jobId : nil)
    }

    /// The same, from what is handed in — pure, for the tests.
    ///
    /// `settings` is the shop's: only its tariff (`elecRate`) travels, so a
    /// failed print's electricity is charged what the shop pays rather than
    /// Khayt's 0.18 — there is no preset on this path to say otherwise.
    static func failedCosting(order o: [String: JSONValue], machines: [JSONValue],
                              settings: [String: JSONValue] = [:],
                              ended: FinishCamera.Ended?, live: JSONValue?,
                              attempt: KhaytEngine.EnergyReading?, inspected: Bool) -> JSONValue {
        let machineId = plainString(o["machineId"]) ?? ""
        var out: [String: JSONValue] = [:]
        if let machine = machines.first(where: { recordId($0) == machineId }) { out["machine"] = machine }
        if let tariff = settings["elecRate"], tariff != .null {
            out["settings"] = .object(["elecRate": tariff])
        }

        if let s = ended?.durationS, s > 0 {
            out["actualHours"] = .number(s / 3600)
        } else if inspected, let h = plainNumber(o["actualPrintTime"]), h > 0 {
            out["actualHours"] = .number(h)
        }
        if inspected {
            out["progress"] = .number(100)
        } else if ended != nil, case .object(let l)? = live, let p = plainNumber(l["progress"]), p > 0 {
            out["progress"] = .number(p)
        }

        // The attempt's own plug reading. An inspected print finished, so its
        // reading is already on the job — and that one wins: a meter attempt
        // for the same job is an EARLIER stopped print (cancelled at 40%, then
        // reprinted whole), and costing the full failed print at the stopped
        // one's 300 Wh under-costs it. A stopped print's was kept by the meter.
        if inspected, let wh = plainNumber(o["actualEnergyWh"]), wh > 0 {
            var e: [String: JSONValue] = ["wh": .number(wh)]
            if case .object(let meta)? = o["actualEnergy"], let c = meta["coverage"] { e["coverage"] = c }
            out["energy"] = .object(e)
        } else if let attempt {
            out["energy"] = attempt.json
        }
        return .object(out)
    }

    /// Whether `failedCosting` took its energy from the meter's kept attempt —
    /// in which case the attempt is spent once the waste row is saved.
    static func usesAttempt(order o: [String: JSONValue],
                            attempt: KhaytEngine.EnergyReading?, inspected: Bool) -> Bool {
        guard attempt != nil else { return false }
        if inspected, let wh = plainNumber(o["actualEnergyWh"]), wh > 0 { return false }
        return true
    }

    /// The job waiting for someone to say it passed inspection.
    ///
    /// A job leaving QC for completed is an INSPECTION, and `qcStatusOf` reads
    /// the record off the order. A completion that skipped it is not counted as
    /// failed — it is not counted at all, so the shop's pass rate would be
    /// quietly computed over a shrinking subset of its work.

    /// A job being finished, what it was quoted at, and what — if anything —
    /// the printer said it actually took.
    /// A window a machine is out of action for.
    ///
    /// `from` and `to` are written as `YYYY-MM-DDTHH:mm` local wall-clock, the
    /// shape Khayt's own `datetime-local` field writes — see `DowntimeEditor`
    /// for why both apps must write the same one. A book can also hold full
    /// ISO instants (`…T08:00:00.000Z`); those are read as they are and kept
    /// untouched unless the shop edits that end of the window.
    struct DowntimeBlock: Identifiable, Equatable, Hashable {
        var from: String
        var to: String
        var reason: String
        var id: String { from + "|" + to + "|" + reason }

        /// Does this window run forwards? The shared rule DROPS one that does
        /// not, so a sheet that cannot say so lets a shop type something and
        /// find nothing saved.
        var isReadable: Bool {
            guard let a = DowntimeEditor.parse(from), let z = DowntimeEditor.parse(to) else { return false }
            return z > a
        }
    }

    struct PendingCompletion: Identifiable, Equatable {
        let id: Order.ID
        let project: String
        let estHours: Double
        let estGrams: Double
        /// Whether this job is leaving inspection, which is the only case that
        /// also wants QC notes.
        let leavingQC: Bool
        /// Nil until the answer arrives — an engine call, and the sheet must
        /// open at once rather than after a round trip.
        var measured: KhaytEngine.ActualsPrefill?
    }

    /// Ask what the printer said, once the sheet is already up.
    func askWhatThePrinterSaid(for id: Order.ID) async {
        guard let engine, let job = orders.first(where: { $0.id == id }) else { return }
        guard let machineId = job.machineId, !machineId.isEmpty else { return }
        let pre = try? await engine.actualsPrefill(
            completions: printerCompletions, machineId: machineId,
            // The printer knows a FILENAME, and the only honest link between an
            // order and a set of figures is that name matching. A job with no
            // print file gets the machine's newest completion, which the sheet
            // then names so the shop can see whose numbers these are.
            filename: job.parts.compactMap(\.fileRef).first,
            estimateHours: job.printTime, estimateGrams: Self.quotedGrams(job),
            now: Date())
        guard var asking = pendingCompletion, asking.id == id, let pre else { return }
        asking.measured = pre
        pendingCompletion = asking
    }

    /// What the job was quoted to weigh — the sum of its parts, times their
    /// quantities.
    ///
    /// The same shape `lib/order-file-link.js` uses to allocate a finished
    /// job's real figures back to those parts, so the number the shop is asked
    /// to correct is the number everything downstream compares against. An
    /// order carries no total weight of its own; taking the first part's would
    /// under-quote every multi-part job on this screen.
    /// What the job was quoted to take off the shelf: print AND support, per
    /// piece, times the quantity — `order-deduction.partGramsConsumed`.
    ///
    /// Support was left out, so a part quoted 100 g + 30 g support pre-filled
    /// "100" in the completion sheet, and a shop confirming it told the
    /// deduction the job used 100 of its 130: the shelf kept 30 g it had lost.
    static func quotedGrams(_ job: Order) -> Double {
        job.parts.reduce(0) { $0 + ($1.printWeight + $1.supportWeight) * Double(max(1, $1.qty)) }
    }

    struct PendingHold: Identifiable, Sendable {
        let id: Order.ID
        let project: String
    }

    /// Save a customer — a new one, or changes to one the shop already has.
    ///
    /// A NAME IS THE ONLY THING REQUIRED, in either language, because that is
    /// Khayt's own rule and because a customer with a phone number and no name
    /// is not a customer anyone can find again.
    func saveCustomer(_ client: Client) async {
        moveProblem = nil
        guard permitted("clients", "edit") else { return }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        guard !client.nameEn.trimmingCharacters(in: .whitespaces).isEmpty
                || !client.nameAr.trimmingCharacters(in: .whitespaces).isEmpty else {
            moveProblem = words.callIt("ce.need_name"); return
        }

        var undo: [ChangedRecord] = []
        do {
            // The async update: `customerRecord` asks the sheet's own rules, which
            // live on the main actor. Only this closure runs here.
            try await StoreWriter.updateAsync(build) { root in
                undo = []
                var rows = Self.rows(root, "clients")
                var record = client.record
                if let at = rows.firstIndex(where: { Self.recordId($0) == client.id }) {
                    // An edit, so it is stamped like any other — and undoable.
                    guard case .object(let was) = rows[at] else { return }
                    undo.append(ChangedRecord(collection: "clients", id: client.id, was: was))
                    record = Self.customerRecord(saving: client, over: was)
                    StoreWriter.stamp(&record)
                    rows[at] = .object(record)
                } else {
                    StoreWriter.stamp(&record)
                    rows.append(.object(record))
                }
                root["clients"] = .array(rows)
                Self.sealUndo(&undo, in: root)
            }
            if !undo.isEmpty { registerMoveUndo(undo, named: words.callIt("mac.edit_customer")) }
            // No undo means no record was there before: a new customer.
            else { Telemetry.feature(.customerAdded, in: self) }
            editingCustomer = nil
            await load(source)
        } catch {
            moveProblem = String(describing: error)
        }
    }

    /// The customer record a save writes over `was`.
    ///
    /// Fields this app does not offer are the shop's and stay: the comms log,
    /// anything a newer build writes. And a field the sheet shows but was not
    /// changed stays AS THE BOOK SPELLS IT — `null` rather than `""`, `"12"`
    /// rather than `12`, a price row the other app wrote with a field of its
    /// own — because the sheet's own open→save of the stored row is the
    /// baseline every untouched value is compared with (`RoundTrip`).
    static func customerRecord(saving client: Client,
                               over was: [String: JSONValue]) -> [String: JSONValue] {
        var record = client.record
        if let stored = Client.decoding(was) {
            let baseline = CustomerSheet.saving(CustomerSheet.opening(stored)).record
            record = RoundTrip.keepUntouched(written: record, baseline: baseline, stored: was)
        }
        for (key, value) in was where record[key] == nil {
            record[key] = value
        }
        return record
    }

    /// Put rows on the catalogue without a book. FOR TESTS ONLY, and named so
    /// it cannot be mistaken for a way to write products — it changes what is
    /// on screen and nothing on disk.
    func setCatalogueForTesting(_ rows: [KhaytEngine.CatalogueRow]) { catalogueRows = rows }

    /// What the catalogue can be narrowed by.
    ///
    /// Two axes and a state, answering three different questions:
    ///
    ///   CATEGORY — what the shop files a product under, and what the other
    ///              app's catalogue chips already use. NOT `group`: products
    ///              carry `category`, and a chip on a field nothing writes is a
    ///              chip that never appears.
    ///   MATERIAL — what it is printed in. "Everything in resin" is the
    ///              question the search box was being used for.
    ///   NO PRICE — added and never priced. The catalogue's own "unfiled": a
    ///              product a shop cannot sell, sitting silently among ones it
    ///              can, and the only one of the three worth interrupting for.
    ///
    /// Counted the same way as the library's — each axis over what the others
    /// leave, by the shared folding rule. `LibraryFacets` carries the argument
    /// for both, including the bug the other app shipped by counting the whole
    /// catalogue while the grid narrowed on three things at once.
    ///
    /// A product's material is not a field `lib/organise.js` knows — it is
    /// derived from the parts — so the rows are handed over as records it does
    /// know. What is borrowed is the FOLDING, not the field name: a catalogue
    /// holding "PETG" and "petg" has one material.
    struct CatalogueFacets: Equatable {
        var categories: [KhaytEngine.GroupCount] = []
        var materials: [KhaytEngine.GroupCount] = []
        var unpriced = 0
        var isEmpty: Bool { categories.isEmpty && materials.isEmpty && unpriced == 0 }
    }

    /// Nothing typed and nothing worked out — NOT "costs zero".
    ///
    /// `lib/product-price.js` is explicit that a typed zero is a real answer:
    /// *"a giveaway, a sample, a part priced inside a bundle"*, and it goes out
    /// of its way not to re-price those at cost plus margin. A chip that swept
    /// them up with the ones nobody has got round to pricing would tell a shop
    /// its deliberate freebies are mistakes.
    static func isUnpriced(_ row: KhaytEngine.CatalogueRow) -> Bool {
        row.final <= 0 && row.source != "override"
    }

    var catalogueFilterOn: Bool {
        catalogueCategory != nil || catalogueMaterial != nil || catalogueUnpricedOnly
    }

    func clearCatalogueFilter() {
        catalogueCategory = nil
        catalogueMaterial = nil
        catalogueUnpricedOnly = false
    }

    enum CatalogueAxis { case unpriced, category, material }

    private func cataloguePool(skipping axis: CatalogueAxis) -> [KhaytEngine.CatalogueRow] {
        var rows = catalogueRows
        if axis != .unpriced, catalogueUnpricedOnly { rows = rows.filter(Self.isUnpriced) }
        if axis != .category, let category = catalogueCategory {
            rows = rows.filter { category.matches(productCategories[$0.id]) }
        }
        if axis != .material, let material = catalogueMaterial {
            rows = rows.filter { material.matches($0.material) }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { Self.catalogueMatches($0, q, category: productCategories[$0.id]) }
    }

    private static func catalogueMatches(_ row: KhaytEngine.CatalogueRow, _ q: String,
                                         category: String?) -> Bool {
        row.name.lowercased().contains(q)
            || row.description.lowercased().contains(q)
            || row.material.lowercased().contains(q)
            || row.group.lowercased().contains(q)
            || (category ?? "").lowercased().contains(q)
    }

    func readCatalogueFacets() async {
        catalogueRecount += 1
        let mine = catalogueRecount
        guard let engine, !catalogueRows.isEmpty else { catalogueFacets = CatalogueFacets(); return }
        let categoryRows = cataloguePool(skipping: .category).map {
            JSONValue.object(["category": .string(productCategories[$0.id] ?? "")])
        }
        let materialRows = cataloguePool(skipping: .material).map {
            JSONValue.object(["category": .string($0.material)])
        }
        let categories = (try? await engine.categoryCounts(categoryRows)) ?? []
        let materials = (try? await engine.categoryCounts(materialRows)) ?? []
        guard mine == catalogueRecount else { return }
        let unpriced = cataloguePool(skipping: .unpriced).count(where: Self.isUnpriced)
        catalogueFacets = CatalogueFacets(categories: categories, materials: materials,
                                          unpriced: unpriced)
    }

    func recountCatalogueSoon() { catalogueRecountTask = Task { await readCatalogueFacets() } }

    /// The same, for the catalogue's chips. See `settleLibraryFacets`.
    func settleCatalogueFacets() async {
        while let pending = catalogueRecountTask {
            catalogueRecountTask = nil
            await pending.value
        }
    }

    /// The catalogue, matching the search box and whatever chips are on.
    ///
    /// The rule `shownExpenses` states: a search field that does nothing on the
    /// screen you are looking at is worse than no search field. Every other
    /// list in this app had been held to it and the catalogue had not — the
    /// field sat above the products prompting "Job, customer or number" and
    /// narrowed nothing.
    ///
    /// Name, description, material and group: a shop hunting for "the palm one"
    /// or "everything in resin" is asking one of those four.
    var shownProducts: [KhaytEngine.CatalogueRow] {
        var rows = catalogueRows
        // Every axis narrows at once, as in the library: "the resin ones in the
        // Kings collection" is one question, not two screens.
        if catalogueUnpricedOnly { rows = rows.filter(Self.isUnpriced) }
        if let category = catalogueCategory {
            rows = rows.filter { category.matches(productCategories[$0.id]) }
        }
        if let material = catalogueMaterial { rows = rows.filter { material.matches($0.material) } }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { Self.catalogueMatches($0, q, category: productCategories[$0.id]) }
    }

    /// Whether the screen now showing has anything for the search box to narrow.
    ///
    /// ── A FIELD THAT DOES NOTHING IS WORSE THAN NO FIELD ──────────────────
    ///
    /// `.searchable` was on the window unconditionally, so every screen carried
    /// a search field — including the four that are not lists at all. On the
    /// calculator, the colour studio, the reports and the dashboard it was a
    /// control that could be typed into and did nothing, labelled "Job,
    /// customer or number" because the prompt fell through to the jobs one.
    ///
    /// Listed the positive way round, so a NEW screen gets no search box until
    /// somebody says it has one. The other order — naming the screens without
    /// search — hands every future screen a field that does nothing by default,
    /// which is the state this is fixing.
    var canSearch: Bool {
        switch shelf {
        case .jobs, .board, .library, .customers, .inventory,
             .expenses, .waste, .portfolio, .giftCards, .catalogue:
            return true
        case .dashboard, .machines, .reports, .colour, .calculator:
            return false
        }
    }

    /// What this screen's search box looks for, in its own words.
    ///
    /// Three screens fell through to the jobs prompt and were asking for a
    /// "Job, customer or number" while filtering spools, products and a board.
    /// The board keeps the jobs prompt on purpose — it IS jobs.
    ///
    /// On the book rather than in the window because both shells ask for it:
    /// the old one for its toolbar field, the new one for the strip's.
    @MainActor var searchPrompt: String {
        if shelf == .giftCards { return words.callIt("mac.gift_card_code") }
        if shelf == .portfolio { return words.callIt("pf.search_ph") }
        if showingLibrary { return words.callIt("mac.search_models") }
        if showingCustomers { return words.callIt("mac.search_people") }
        if showingExpenses { return words.callIt("mac.search_expenses") }
        if showingWaste { return words.callIt("mac.search_waste") }
        if showingInventory { return words.callIt("mac.search_filament") }
        if showingCatalogue { return words.callIt("mac.search_products") }
        return words.callIt("mac.search_jobs")
    }

    // MARK: - What to run next

    /// Accept one of the dispatcher's proposals.
    ///
    /// Sets `machineId` and NOTHING ELSE — not the status, not the queue
    /// position. The same rule `applySchedule` follows, and for the same
    /// reason: the rule proposes a printer, and moving the card is the
    /// operator's. It also re-reads inside the write, so a job assigned by hand
    /// since the panel was drawn is never overwritten by a stale suggestion.
    func accept(_ proposal: KhaytEngine.DispatchProposal) async {
        guard permitted("orders", "edit") else { return }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        do {
            let machineId = proposal.machineId
            try await StoreWriter.updateRecordOffMain(build, collection: "printLog",
                                                      id: proposal.orderId) { record in
                guard (Self.plainString(record["machineId"]) ?? "").isEmpty else { return }
                record["machineId"] = .string(machineId)
            }
            await load(source)
            await planDispatch()
        } catch {
            moveProblem = String(describing: error)
        }
    }

    /// Ask the rule what to run next.
    ///
    /// Cheap, and called whenever the fleet's readings change: the answer is a
    /// function of the queue and what the printers just said, and one that is
    /// several minutes old is an answer about a shop that has moved on.
    func planDispatch() async {
        guard let engine else { dispatch = nil; return }
        let live = dispatchLive()
        dispatch = try? await engine.dispatchPlan(
            orders: orderRows, machines: machineRows, live: live,
            lastMaterialByMachine: lastMaterialByMachine(),
            paused: Dictionary(uniqueKeysWithValues: dispatchHeld.map { ($0, JSONValue.bool(true)) }))
    }

    /// What the dispatcher is told about each printer — decided by `quiet` and
    /// `heard`, the same answer the band and the dashboard draw.
    ///
    /// The raw `statusCache` carries an `error` from the FIRST failed poll,
    /// and the rule reads any error as "not answering"; the band gave the same
    /// printer three misses. So one CORE One was "Free · 48:00" on the band
    /// and "Not answering" in Next up, on the same screen. Here a printer in
    /// its grace is handed its last good status, and one that is not answering
    /// always carries an error, whether or not it was ever polled.
    func dispatchLive() -> [String: JSONValue] {
        var live = printers.statusCache
        for machine in machines {
            let seen = printers.readings[machine.id]
            if seen?.status == nil, let status = printers.heard(machine.id) {
                live[machine.id] = .object(PrinterWatch.cacheEntry(status, at: seen?.at ?? Date()))
            } else if printers.heard(machine.id) == nil, quiet(machine) == .notAnswering,
                      live[machine.id] == nil {
                live[machine.id] = .object([
                    "state": .string("offline"),
                    "error": .string(words.callIt("mac.attn_state_offline")),
                ])
            }
        }
        return live
    }

    /// What each machine printed last, so the rule can prefer the one that
    /// needs no spool change.
    ///
    /// Khayt does not record what is LOADED in a machine — only what it has
    /// printed — so the most recent finished job is the best signal there is,
    /// and it is very often still in the machine.
    private func lastMaterialByMachine() -> [String: JSONValue] {
        var seen: [String: (day: String, material: String)] = [:]
        for order in orders {
            guard let id = order.machineId, !id.isEmpty else { continue }
            guard let finished = order.completedAt ?? order.deliveredAt else { continue }
            let material = order.parts.compactMap { $0.material.isEmpty ? nil : $0.material }.first
            guard let material else { continue }
            if let held = seen[id], held.day >= finished { continue }
            seen[id] = (day: finished, material: material)
        }
        return seen.mapValues { JSONValue.string($0.material) }
    }

    /// Say a machine's plate is empty, so the dispatcher may offer it again.
    ///
    /// THE ONE THING A PRINTER CANNOT TELL US. None of them can clear their own
    /// bed or see that it is clear, so this is a person's sentence and it is
    /// written down as one — stamped on the machine, and compared against when
    /// that machine last finished a print.
    func markBedClear(_ machine: Machine) async {
        guard permitted("orders", "edit") else { return }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        do {
            try await StoreWriter.updateRecordOffMain(build, collection: "machines", id: machine.id) { record in
                record["bedClearedAt"] = .string(StoreWriter.iso(Date()))
            }
            await load(source)
            await planDispatch()
        } catch {
            moveProblem = String(describing: error)
        }
    }

    // MARK: - Taking a job from something the shop already makes

    /// Start a job from a product: its parts, its components, its margin.
    func takeJob(from product: Product) {
        jobFromProduct = product
        takingAJob = true
    }

    // MARK: - Taking a job

    /// The margin this shop quotes at, or thirty per cent.
    ///
    /// Its own number, not a Swift opinion about what a print shop charges —
    /// and the same default the Electron calculator opens on.
    var defaultMargin: Double {
        if case .object(let s) = settingsValue, case .number(let m)? = s["defaultMargin"] { return m }
        return 30
    }

    /// One part, in the shape the cost model reads it.
    ///
    /// The spool supplies the material and what it cost — the shelf already
    /// knows, and asking a shop to retype it is asking twice.
    private func partFor(spoolId: String?, grams: Double, hours: Double, qty: Int,
                         extra: [String: JSONValue] = [:]) -> JSONValue {
        Self.costInput(spool: spoolId.flatMap { id in spools.first { $0.id == id } },
                       grams: grams, hours: hours, qty: qty, extra: extra)
    }

    /// The part the shared cost model is handed. `extra` is the part as the
    /// book holds it — its own labour, power, wear and failure figures beat
    /// the machine's defaults inside `costPart`, exactly as they do when the
    /// other app costs the same part — and the four measured fields are
    /// written over it. Static so a test can hold it to a record.
    static func costInput(spool: Spool?, grams: Double, hours: Double, qty: Int,
                          extra: [String: JSONValue] = [:]) -> JSONValue {
        CalculatorPart.single(spool: spool.map(\.costing), grams: grams, hours: hours, qty: qty, extra: extra)
    }

    /// What one part costs to make, through the shared cost model.
    ///
    /// WHAT THIS USED TO DO, AND WHY IT WAS EXPENSIVE. Wear, power, labour and
    /// the failure allowance were read from `settings.defaultWearRate` and four
    /// siblings — five keys **Khayt has never written anywhere**. The fallback
    /// branch was therefore the only branch, every one of those came out zero,
    /// and `computePartBaseCost` returned the material cost without complaint.
    /// On a real 272g / 14.9h job that is 20.40 against the 109.43 the Electron
    /// calculator quotes for the same work: a job taken here was priced at
    /// under a fifth of what it costs the shop to make.
    ///
    /// The rates now come from `lib/print-rates.js`, which holds the figures
    /// the calculator form actually opens on, tied to the HTML by a test.
    func costOfPart(spoolId: String?, grams: Double, hours: Double, qty: Int,
                    machineId: String? = nil) async -> Double {
        guard let engine else { return 0 }
        return (try? await engine.partCost(partFor(spoolId: spoolId, grams: grams,
                                                   hours: hours, qty: qty),
                                           inventory: inventoryRows, settings: settingsDict,
                                           machine: machineRow(machineId))) ?? 0
    }

    /// What a part costs, where it went, and what it was costed AT — one
    /// crossing, because all three are wanted at the same moment and the third
    /// has to be written down with the job.
    /// The parts of a product, COSTED, as the new-job sheet takes them.
    ///
    /// `Draft.from` carries the figures — grams, hours, the spool — and
    /// nothing else: what a part costs is the shared cost model's answer,
    /// asked here exactly as `addPart` asks it for a part typed by hand. It
    /// was not asked at all on this path, so a job taken from the catalogue
    /// arrived with every part at nothing and a total of nothing. That is the
    /// report behind #1254 ("I click create a job for an item in catalogue
    /// but the price is zero?"), which fixed the number parsing beside it and
    /// left the costing out. A part with nothing to cost stays at nothing and
    /// the sheet says so.
    func jobParts(from product: Product) async -> [NewJobSheet.Draft] {
        guard case .array(let rows)? = product.rest["parts"] else { return [] }
        var out: [NewJobSheet.Draft] = []
        for row in rows {
            guard var draft = NewJobSheet.Draft.from(row) else { continue }
            // AT THE PRODUCT'S OWN RATES. The part carries the labour, power,
            // wear and failure figures it was priced with in the catalogue;
            // costing it from grams and hours alone priced a 35.91 part at
            // 10.57 and opened the job at 15 where the catalogue said 50.
            if draft.isComplete,
               let costed = await costedPart(spoolId: draft.spoolId,
                                             grams: Double(draft.grams) ?? 0,
                                             hours: Double(draft.hours) ?? 0,
                                             qty: draft.qty, extra: draft.raw) {
                draft.cost = costed.cost
                draft.parts = costed.parts
                draft.rates = costed.rates
            }
            out.append(draft)
        }
        return out
    }

    /// How a product's own price reaches the job taken for it.
    ///
    /// A product priced by hand ("Your own price") sells for that figure, so
    /// the job opens with it typed in; a product rounded to a step opens
    /// rounded the same way. A product priced by its parts and margin brings
    /// only the margin, which `NewJobSheet` already takes.
    static func priceRule(of product: Product) -> PriceRule {
        var rule = PriceRule()
        if let typed = plainNumber(product.rest["priceOverride"]), typed >= 0 { rule.override = typed }
        if case .object(let r)? = product.rest["priceRound"],
           let step = plainNumber(r["step"]), step > 0 {
            rule.step = step
            rule.mode = plainString(r["mode"]) ?? "nearest"
        }
        return rule
    }

    func costedPart(spoolId: String?, grams: Double, hours: Double, qty: Int,
                    machineId: String? = nil, presetId: String? = nil,
                    extra: [String: JSONValue] = [:]) async -> KhaytEngine.CostedPart? {
        guard let engine else { return nil }
        return try? await engine.costPart(partFor(spoolId: spoolId, grams: grams,
                                                  hours: hours, qty: qty, extra: extra),
                                          inventory: inventoryRows, settings: settingsDict,
                                          machine: machineRow(machineId),
                                          preset: presetRow(presetId),
                                          consumables: consumableRows)
    }

    /// A saved preset as the book holds it.
    ///
    /// `costPart` has always taken one and this app never passed it, so the
    /// shop's own labour rate, electricity and failure allowance were saved,
    /// listed, and then ignored by the one screen they are for — a part was
    /// costed at Khayt's opening figures whatever the shop had written down.
    func presetRowFor(_ id: String?) -> JSONValue? { presetRow(id) }

    private func presetRow(_ id: String?) -> JSONValue? {
        guard let id, !id.isEmpty else { return nil }
        return presetRows.first {
            if case .object(let p) = $0 { return p["id"] == .string(id) }
            return false
        }
    }

    /// What a part WOULD be costed at, before anything is typed over it.
    ///
    /// Asked of the rule rather than worked out here: the order (defaults,
    /// then the preset, then the machine's two) belongs to
    /// `lib/print-rates.js`, and a screen that restated it would drift from
    /// the costing it is supposed to be showing.
    func resolvedRates(presetId: String?, machineId: String?) async -> [String: Double] {
        guard let engine else { return [:] }
        return (try? await engine.printRates(machine: machineRow(machineId),
                                             preset: presetRow(presetId),
                                             settings: settingsDict)) ?? [:]
    }

    /// A machine as the book holds it, for the two rates a printer knows about
    /// itself. Nil for a job on no particular machine, which is the usual case
    /// at the moment somebody is quoting it.
    ///
    /// A machine with depreciation set goes in carrying `recentMonthlyHours`
    /// — what it has actually printed a month lately. Never written back: it
    /// is a figure for this one costing, which a straight-line machine needs
    /// to turn its monthly amount into an hourly wear rate
    /// (`lib/depreciation.js`).
    func machineRow(_ id: String?) -> JSONValue? {
        guard let id, !id.isEmpty else { return nil }
        let row = machineRows.first {
            if case .object(let m) = $0 { return m["id"] == .string(id) }
            return false
        }
        guard case .object(var m)? = row, let recent = machineValue[id]?.recentMonthlyHours
        else { return row }
        m["recentMonthlyHours"] = .number(recent)
        return .object(m)
    }

    /// A failure allowance learned from this book's own QC fails and waste,
    /// for one machine and one material — `lib/failure-rate.js`. Only ever a
    /// SUGGESTION: the screens offer it beside the field and the shop decides.
    func failureSuggestion(machineId: String?, material: String?) async
        -> KhaytEngine.FailureSuggestion? {
        guard let engine else { return nil }
        return try? await engine.failureSuggestion(
            orders: orderRows, wasteLog: wasteRows, today: Self.today(),
            machineId: machineId.flatMap { $0.isEmpty ? nil : $0 },
            material: material.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// A machine's `printerApi` as the shared rules want it, with the key
    /// OPENED — for the one caller that has to send it.
    ///
    /// A snapshot from a PrusaLink or OctoPrint camera is authenticated: a
    /// correct URL that sends nothing answers 401 every time. The key is opened
    /// here, at the moment it is used, and handed straight to the request — the
    /// same rule `PrinterWatch` follows, and the reason the Telegram token bug
    /// happened when somebody passed the sealed string through instead.
    ///
    /// Safe only because the caller has already pinned the host: these headers
    /// carry the shop's printer credential and must reach the printer alone.
    func printerApiRow(_ machine: Machine) async -> JSONValue? {
        guard let api = machine.printerApi, let host = api.host, !host.isEmpty else { return nil }
        var row: [String: JSONValue] = [
            "type": .string(api.type ?? ""),
            "host": .string(host),
        ]
        if let port = api.port { row["port"] = .number(Double(port)) }
        if let sealed = api.apiKey, !sealed.isEmpty, let build = source.build,
           let opened = try? await Secrets.open(sealed, for: build) {
            row["apiKey"] = .string(opened)
        }
        return .object(row)
    }

    /// What the cart comes to, before anything is written.
    ///
    /// The same `quoteTotal` the record will use, so the figure on the screen is
    /// the figure in the book.
    /// How a job's total gets its last word: rounded to a step, or typed.
    ///
    /// The same rule and steps a product's price uses (`lib/product-price.js`);
    /// `nil` step means the arithmetic stands. A typed `override` wins over
    /// the rounding, as it does on a product.
    struct PriceRule: Equatable, Sendable {
        var step: Double = 0
        var mode: String = "nearest"
        var override: Double?

        /// The product editor's own list (`lib/product-price.js` STEPS), so a
        /// product rounded to 25 opens a job the picker can show.
        static let steps: [Double] = [0, 0.5, 1, 5, 10, 25, 50, 100]
        static let modes = ["nearest", "up", "down"]

        var isPlain: Bool { step <= 0 && override == nil }

        /// The two inputs `lib/pricing.js` reads, or nothing.
        var fields: [String: JSONValue] {
            var out: [String: JSONValue] = [:]
            if step > 0 { out["priceRound"] = .object(["step": .number(step), "mode": .string(mode)]) }
            if let override { out["priceOverride"] = .number(override) }
            return out
        }
    }

    /// A charge that is not printing: a design fee, painting, a marketplace's
    /// cut.
    ///
    /// ── WHY A PERCENTAGE IS A DIFFERENT THING FROM AN AMOUNT ──────────────
    ///
    /// `lib/pricing.js` resolves a percentage line against the EXTRAS BASE —
    /// the job's price before extras — not against the final total, and not
    /// against the parts' cost. A marketplace charging 6.5% charges it on what
    /// the customer pays, so the two kinds cannot be collapsed into one number
    /// here and handed over as an amount: the rule works the percentage out
    /// AFTER the margin, the discount and the rounding, and it is the only
    /// thing that knows the base.
    struct ExtraLine: Identifiable, Hashable, Sendable {
        /// Made here and kept for the form: a line has no id in the book, and
        /// two blank rows must still be two rows while somebody is typing.
        let id = UUID()
        var label = ""
        /// Nil for a flat amount; a percentage otherwise.
        var pct: Double?
        var amount: Double = 0
        /// The marketplace this line came from, for lines a shop did not type.
        ///
        /// It is what makes picking Etsy twice REPLACE Etsy's three charges
        /// instead of stacking a second copy of them — which a shop would only
        /// notice on the finished invoice. Nil for a line the shop wrote, and
        /// those are never touched by the picker.
        var platformId: String?

        var isPercent: Bool { pct != nil }

        /// The record, as `lib/pricing.js` and `lib/order-new.js` read it.
        ///
        /// A percentage line carries no `amount`: the resolved figure is the
        /// rule's to work out, and writing one here would be a second answer
        /// free to disagree with it.
        var row: JSONValue {
            var o: [String: JSONValue] = [
                "label": .string(label.trimmingCharacters(in: .whitespacesAndNewlines)),
            ]
            if let pct { o["pct"] = .number(max(0, pct)) } else { o["amount"] = .number(max(0, amount)) }
            // Carried onto the saved job the way the other app carries it, so
            // a quote reopened there still knows which lines are Etsy's.
            if let platformId { o["platformId"] = .string(platformId) }
            return .object(o)
        }

        /// A line nobody finished typing is not a charge.
        var isWorthKeeping: Bool {
            if let pct { return pct > 0 }
            return amount > 0
        }

        static func == (a: ExtraLine, b: ExtraLine) -> Bool {
            a.id == b.id && a.label == b.label && a.pct == b.pct && a.amount == b.amount
                && a.platformId == b.platformId
        }
    }

    // MARK: - Labels for work going out the door

    /// The shop's portal address, for a label's QR to point at.
    ///
    /// Empty when the cloud is not connected, which is what makes
    /// `ShelfLabels.orderCode` fall back to the code the shop's own phone
    /// reads rather than printing a link to nowhere.
    var cloudLabelBase: String {
        guard cloudConnected, case .object(let cloud)? = settingsDict["cloud"],
              case .string(let url)? = cloud["url"] else { return "" }
        return url
    }

    /// Build a printable sheet of ORDER labels, for the jobs given.
    ///
    /// The shelf could be labelled from this app and a job could not, so a box
    /// going out of the door had to be labelled from the other one. Same sheet
    /// builder, same QR rule, same preview before anything is printed.
    func askForOrderLabels(_ ids: [Order.ID]) async {
        let chosen = orderRows.filter { row in
            guard let id = Self.recordId(row) else { return false }
            return ids.contains(id)
        }
        guard !chosen.isEmpty, let engine else { return }
        let entries = chosen.map { ShelfLabels.entry(forOrder: $0, shop: self) }
        let heading = words.callIt("lbl.orders")
        guard let html = try? await engine.labelSheet(entries, heading: heading) else { return }
        pendingLabels = LabelSheetRequest(html: html, count: chosen.count)
    }

    // MARK: - Which printer takes which job

    /// The jobs a scheduler is allowed to place: waiting, and on no machine yet.
    ///
    /// The same filter the Electron kanban uses. A job already on a printer is
    /// left alone — the scheduler seeds each machine's load with it, but never
    /// proposes moving work somebody has already committed.
    var schedulableRows: [JSONValue] { Self.schedulable(orderRows) }

    /// Static and separate so it can be tested without opening a book — the
    /// version that lived inline returned nothing against a sample where six
    /// jobs plainly qualified, and there was no way to ask it why.
    /// What the scheduler should be HANDED: every job still to happen.
    ///
    /// Three sets were candidates and only this one is right.
    ///
    /// * Just the unassigned jobs — what the Electron kanban passes — makes
    ///   `machineLoadMins` see every printer as empty, so each proposal comes
    ///   back finishing in minutes. That is where "0.1 hrs" came from.
    /// * The whole book seeds the load correctly for in-flight work and then
    ///   adds thirteen delivered and nine completed jobs to it, because
    ///   `machineLoadMins` sums by `machineId` without looking at status. A
    ///   printer that has done a hundred jobs would look booked for a month.
    /// * The work still to happen — waiting, queued, printing — seeds each
    ///   machine with what is actually on it and nothing else. `isSchedulable`
    ///   then refuses anything already on a printer, so the proposal covers the
    ///   same jobs either way; only the finishing times change, and they become
    ///   true.
    static func stillToHappen(_ rows: [JSONValue]) -> [JSONValue] {
        rows.filter { row in
            guard case .object(let o) = row else { return false }
            let status = plainString(o["status"]) ?? ""
            return status == "pending" || status == "queued" || status == "printing"
        }
    }

    static func schedulable(_ rows: [JSONValue]) -> [JSONValue] {
        rows.filter { row in
            guard case .object(let o) = row else { return false }
            let status = plainString(o["status"]) ?? ""
            guard status == "pending" || status == "queued" else { return false }
            return (plainString(o["machineId"]) ?? "").isEmpty
        }
    }

    // MARK: - What can go on one plate

    /// The work a plate could be planned from: not finished, not a quote, not
    /// voided. The other app's filter, through the same shared rule.
    var batchCandidates: [Order] {
        Self.planCandidates(orders, voided: Self.voidedIds(orderRows))
    }

    /// The filter itself, static so it can be shown to work without a book on
    /// disk — the shape `schedulable` already uses, and for the same reason:
    /// the version that lived inline could not be asked why it had dropped a
    /// job.
    ///
    /// `finishedStatuses` is the shared vocabulary, held to `lib/order-status.js`
    /// by `FinishedStatusTests` — NOT `status == "completed"`, which would leave
    /// every delivered job sitting in the planner for ever.
    static func planCandidates(_ jobs: [Order], voided: Set<String>) -> [Order] {
        jobs.filter { job in
            job.status != "quote" && !finishedStatuses.contains(job.status)
                && !voided.contains(job.id)
        }
    }

    /// The jobs the shop has written off. `Order` does not carry `voidedAt` —
    /// nothing on screen needed it — so it is read off the raw record.
    static func voidedIds(_ rows: [JSONValue]) -> Set<String> {
        Set(rows.compactMap { row -> String? in
            guard case .object(let o) = row, let id = recordId(row),
                  let mark = o["voidedAt"], mark != .null else { return nil }
            return id
        })
    }

    /// Ask the shared packer what could run together.
    ///
    /// Reads only, and writes nothing at all — unlike the scheduler, there is
    /// no "apply": a plate is a way of running the work, not a field on a
    /// record. Khayt has never written one either.
    func planBatch() async {
        batchProblem = nil
        batchIdle = false
        batchPlates = nil
        guard let engine else {
            batchProblem = words.callIt("mac.move_no_engine"); return
        }
        let chosen = batchCandidates.filter { batchChosen.isEmpty || batchChosen.contains($0.id) }
        guard !chosen.isEmpty else { batchIdle = true; return }
        do {
            batchPlates = try await engine.planPlates(
                jobs: chosen.map(Self.plateJob),
                maxHours: max(1, batchMaxHours), maxGrams: max(1, batchMaxGrams))
        } catch {
            batchProblem = String(describing: error)
        }
    }

    /// What a job weighs and what of, for the packer.
    ///
    /// The weight is the PARTS', quantity included — a job's own record does
    /// not carry one, and a plate packed on a per-part weight would fit four
    /// copies of something in the space of one. The material is the first the
    /// job's parts name, which is the other app's reading too: a plate cannot
    /// mix filaments, so a job printed in two is planned by the first and the
    /// shop sees the rest on the row.
    static func plateJob(_ job: Order) -> KhaytEngine.PlateJob {
        let grams = job.parts.reduce(0.0) { $0 + $1.printWeight * Double(max(1, $1.qty)) }
        let material = job.parts.first(where: { !$0.material.isEmpty })?.material ?? ""
        return KhaytEngine.PlateJob(id: job.id, project: job.project.isEmpty ? job.id : job.project,
                                    hours: job.printTime, grams: grams, material: material)
    }

    /// Ask the shared scheduler where the unassigned work should go.
    ///
    /// Reads only. `lib/scheduling.js` writes nothing and neither does this;
    /// `applySchedule` is the one that touches the book.
    func proposeSchedule() async {
        scheduleProblem = nil
        scheduleIdle = false
        scheduleApplied = nil
        schedulePlan = nil
        swapPlans = [:]
        guard let engine else {
            scheduleProblem = words.callIt("mac.move_no_engine"); return
        }
        let waiting = schedulableRows
        guard !waiting.isEmpty else {
            // ── NOT A PROBLEM, AND IT WAS FILED AS ONE ───────────────────
            //
            // `scheduleProblem` is the field for "the app cannot do this":
            // no engine, a thrown error, a refusal from the rule. The sheet
            // draws it under the system's warning triangle, deliberately,
            // because those are faults.
            //
            // Every job already having a machine is the OPPOSITE of a fault.
            // It went in the same field, so a shop that had finished
            // assigning its work opened the scheduler and was shown a
            // warning sign telling it so.
            scheduleIdle = true; return
        }
        do {
            // Everything still to happen — see `stillToHappen`. Not just the
            // waiting jobs, or every printer looks empty and every proposal
            // comes back finishing in minutes.
            let plan = try await engine.proposeSchedule(
                machines: machineRows, orders: Self.stillToHappen(orderRows), now: Date())
            schedulePlan = plan
            await planSwaps(plan)
        } catch {
            scheduleProblem = String(describing: error)
        }
    }

    /// Put the proposal into the book. The only part of this that writes.
    ///
    /// Each assignment sets one job's `machineId` and nothing else — not its
    /// status, not its queue position. The scheduler proposes a printer; moving
    /// the card is still the operator's.
    func applySchedule() async {
        guard permitted("orders", "edit") else { return }
        guard let plan = schedulePlan, !plan.assignments.isEmpty else { return }
        guard let build = source.build else {
            scheduleProblem = words.callIt("mac.move_sample"); return
        }
        let wanted = Dictionary(plan.assignments.map { ($0.orderId, $0.machineId) },
                                uniquingKeysWith: { first, _ in first })
        do {
            let moved = try await StoreWriter.updateOffMain(build) { root -> Int in
                // Read INSIDE the write: the book on disk may have moved since
                // the proposal was drawn, and a job somebody assigned by hand in
                // the meantime must not be overwritten by a stale suggestion.
                var moved = 0
                let orders = Self.rows(root, "printLog")
                var out: [JSONValue] = []
                out.reserveCapacity(orders.count)
                for row in orders {
                    guard case .object(var o) = row,
                          let id = Self.plainString(o["id"]),
                          let machine = wanted[id],
                          (Self.plainString(o["machineId"]) ?? "").isEmpty else {
                        out.append(row); continue
                    }
                    o["machineId"] = .string(machine)
                    out.append(.object(o))
                    moved += 1
                }
                root["printLog"] = .array(out)
                return moved
            }
            scheduleApplied = moved
            schedulePlan = nil
            swapPlans = [:]
            await load(source)
        } catch let refusal as StoreWriter.Refusal {
            scheduleProblem = refusal.description
        } catch {
            scheduleProblem = String(describing: error)
        }
    }

    /// Put the proposal out of mind.
    func forgetSchedule() {
        schedulePlan = nil
        swapPlans = [:]
        scheduleProblem = nil
        scheduleApplied = nil
    }

    /// What a proposal row says, ready for a screen: the job, the printer, and
    /// the module's own reason.
    func scheduleRow(_ a: KhaytEngine.SchedulePlan.Assignment) -> (job: String, machine: String, why: String) {
        let job = orders.first { $0.id == a.orderId }?.project ?? a.orderId
        let machine = machines.first { $0.id == a.machineId }?.name ?? a.machineId
        return (job, machine, a.reason ?? "")
    }

    /// Take a backup now, for the shop that is about to do something it might
    /// want to undo.
    ///
    /// The day's file already exists more often than not, and overwriting it
    /// would throw away the copy taken before whatever the shop did earlier —
    /// so this writes a SECOND file for today, stamped with the time. Khayt's
    /// own rotation counts it as a day, which is right: it is one.
    /// The backup taken before a cloud merge writes to the book. THROWS: a
    /// merge that goes ahead after its safety copy failed has no safety copy,
    /// and the old path swallowed the failure and carried on.
    func safetyBackup(_ build: StoreReader.Build) async throws {
        _ = try await Backups.writeNow(for: build, engine: engine)
        lastBackup = Backups.lastBackupDay(in: Backups.directory(for: build))
        backupProblem = nil
    }

    func backUpNow() async {
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        do {
            let file = try await Backups.writeNow(for: build, engine: engine)
            lastBackup = Backups.lastBackupDay(in: Backups.directory(for: build))
            spendNote = words.callIt("mac.backed_up") + " " + file.lastPathComponent
            backupProblem = nil
            Telemetry.feature(.backupRun, in: self)
        } catch {
            backupProblem = String(describing: error)
            spendProblem = words.callIt("mac.backup_failed") + " " + String(describing: error)
        }
    }

    /// Put the last crash out of mind, once somebody has looked at it.
    func forgetLastCrash() {
        guard let build = source.build else { return }
        LastWords.clear(for: build)
        lastCrash = nil
    }

    /// Show the shop where its backups are, so it can copy one somewhere safe.
    func revealBackups() {
        guard let build = source.build else { return }
        let directory = Backups.directory(for: build)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting(
            [directory.appending(path: Backups.filename())].filter {
                FileManager.default.fileExists(atPath: $0.path)
            }.isEmpty ? [directory] : [directory.appending(path: Backups.filename())])
    }

    /// Write a copy of the book the shop can send somebody.
    ///
    /// Redacted, always — see `Export`. The panel comes up before the file is
    /// built so that a shop that changes its mind never has a redacted copy of
    /// its book sitting in a temp folder.
    func exportForSharing() async {
        spendProblem = nil
        guard permitted("settings", "view") else { spendProblem = moveProblem; return }
        spendNote = nil
        guard let build = source.build, let engine else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = Export.filename()
        panel.message = words.callIt("mac.export_redacted")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // From disk, not from what this app is holding: the screens decode
            // two collections out of thirty-three, and an export built from
            // those would be an export missing thirty-one.
            let root = try JSONValue.decode([String: JSONValue].self,
                                                from: Data(contentsOf: build.storeURL))
            try await Export.payload(from: root, engine: engine).write(to: url, options: .atomic)
            spendNote = words.callIt("mac.exported_to") + " " + url.lastPathComponent
        } catch {
            spendProblem = words.callIt("mac.export_failed") + " " + String(describing: error)
        }
    }

    /// Every collection of the book as its own spreadsheet.
    ///
    /// ── WHY THIS IS NOT THE ACCOUNTING EXPORT, OR THE JSON ONE ────────────
    ///
    /// Three exports, three different questions. `exportForSharing` writes
    /// redacted JSON for a support thread. `exportForAccounting` writes the two
    /// files a bookkeeper's software reads. This one is the shop's own copy of
    /// everything in a form it can open: orders, customers, products, the
    /// shelf, expenses, machines, suppliers and purchase orders, one CSV each.
    /// Khayt has offered it since 3.0 as "Export all data (CSV)" and this app
    /// offered nothing like it, so a shop working here could not take its own
    /// book out in a form a spreadsheet opens.
    ///
    /// READ FROM DISK, for the reason `exportForSharing` gives: the screens
    /// decode two collections out of thirty-three, and a bundle built from
    /// those would be a bundle missing thirty-one.
    ///
    /// The columns, the quoting and the formula-injection guard are all
    /// `lib/csv-bundle.js`'s. A Swift writer joining the same fields with
    /// commas would have lost the last one, which is the one that matters: a
    /// spreadsheet opens a CSV and runs what looks like a formula.
    func exportEverythingAsCsv() async {
        spendProblem = nil
        guard permitted("settings", "view") else { spendProblem = moveProblem; return }
        spendNote = nil
        guard let build = source.build, let engine else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        // A FOLDER, not a file: there are up to eight of them, and asking eight
        // times where to put a file is a dialogue nobody finishes.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = words.callIt("common.save")
        panel.message = words.callIt("mac.export_csv_where")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            let root = try JSONValue.decode([String: JSONValue].self,
                                                from: Data(contentsOf: build.storeURL))
            let files = try await engine.csvBundle(root)
            guard !files.isEmpty else {
                spendProblem = words.callIt("set.csv_export_empty"); return
            }
            for file in files {
                try Data(file.content.utf8).write(to: dir.appending(path: file.name),
                                                  options: .atomic)
            }
            spendNote = words.callIt("set.csv_exported",
                                     ["n": .number(Double(files.count))])
        } catch {
            spendProblem = words.callIt("mac.export_failed") + " " + String(describing: error)
        }
    }

    // MARK: - Reading back a label this app printed

    /// Follow a scanned code to the record it names.
    ///
    /// Returns nil when it went somewhere, or what to tell the shop.
    ///
    /// ── WHAT THIS APP DECIDES, WHICH IS WHERE TO GO ───────────────────────
    ///
    /// What the code MEANS is `lib/scan.js` — the same module that reads the
    /// labels `lib/labels.js` writes, which is why the reader and the writer
    /// cannot drift. This looks the record up and opens it.
    ///
    /// A tracking link is followed by its TOKEN, not by an id: that is what is
    /// printed on a parcel for a shop with the cloud connected, and the whole
    /// point of the link is that it names the order without exposing its id.
    func followScan(_ text: String) async -> String? {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        guard let read = try? await engine.scanCode(text) else {
            return words.callIt("mac.scan_unknown")
        }
        switch read.type {
        case "spool":
            guard let id = read.id, let spool = spools.first(where: { $0.id == id }) else {
                return words.callIt("scan.spool_missing")
            }
            shelf = .inventory
            editingSpool = spool
            return nil
        case "order", "track":
            let match: Order?
            if read.type == "order" {
                match = orders.first { $0.id == read.id }
            } else {
                // Read off the ROW, not the decoded `Order`: a tracking token
                // is not something a job screen ever shows, and putting it on
                // the model would mean carrying it through every list that has
                // no use for it — which is the reason `ShelfLabels` reads it
                // off the row too.
                let id = orderRows.first { row in
                    guard case .object(let o) = row else { return false }
                    guard let token = Self.plainString(o["trackingToken"]), !token.isEmpty
                    else { return false }
                    return token == read.token
                }.flatMap(Self.recordId)
                match = orders.first { $0.id == id }
            }
            guard let job = match else { return words.callIt("scan.order_missing") }
            // The search box narrows the table, and a job filtered out of it
            // cannot be selected — so a scan that lands on a job the shop
            // cannot see would look like a scan that did nothing.
            search = ""
            shelf = .jobs(nil)
            selection = job.id
            return nil
        case "empty":
            return words.callIt("mac.scan_unknown")
        default:
            return words.callIt("mac.scan_unknown")
        }
    }

    /// The accounting packages `lib/accounting-export.js` lays out columns for.
    ///
    /// The names are the products' own and are deliberately NOT translated —
    /// "QuickBooks" is what the software is called in every language, and a
    /// localised guess at it is a menu item nobody recognises.
    static let accountingFormats: [(String, String)] = [
        ("generic", "CSV"), ("quickbooks", "QuickBooks"),
        ("xero", "Xero"), ("zoho", "Zoho Books"),
        ("wafeq", "Wafeq"), ("daftra", "Daftra"),
    ]

    /// The two files an accountant actually wants.
    ///
    /// ── WHY NOT THE EXPORT ABOVE ──────────────────────────────────────────
    ///
    /// `exportForSharing` writes the whole book as redacted JSON, which is the
    /// right thing to hand a support thread and the wrong thing to hand a
    /// bookkeeper: nobody opens a thirty-three-collection JSON in the software
    /// that files a VAT return. This writes what that software reads — one CSV
    /// of invoices, one of expenses — and the columns are laid out the way the
    /// chosen package wants them.
    ///
    /// The arithmetic is `lib/accounting-export.js`: the VAT split, the
    /// category-to-account mapping, the four column layouts. None of it is
    /// worked out here. A quarter exported from this Mac is the same set of
    /// rows, to the halalah, as the same quarter exported from the other app —
    /// which matters more here than anywhere else in this program, because two
    /// apps disagreeing about a VAT figure is a disagreement an auditor finds.
    ///
    /// A FOLDER, not a file, because there are two of them. Asking twice for
    /// somewhere to put a pair of files is a dialogue nobody finishes.
    func exportForAccounting(format: String) async {
        spendProblem = nil
        guard permitted("settings", "view") else { spendProblem = moveProblem; return }
        spendNote = nil
        guard let engine else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = words.callIt("common.save")
        panel.message = words.callIt("mac.export_accounting_where")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            let day = Shop.today(Date())
            // The rule already puts a BOM on each file. It is asked for rather
            // than assumed, because the reason for it — Excel on Windows reads
            // a UTF-8 CSV without one as the system code page, and turns a
            // shop's Arabic customer names into mojibake — is the rule's
            // decision to make and to change.
            // THE READER'S LANGUAGE, as the other app passes it. A bilingual
            // shop's customer is written down twice and the export has to pick
            // one; picking the name stamped on the order picks English every
            // time, whoever is reading.
            let invoices = try await engine.invoiceCsv(
                orderRows, settings: settingsDict, clients: clientRows, format: format,
                language: words.language)
            let expenses = try await engine.expenseCsv(expenseRows, format: format, settings: settingsDict)
            let a = dir.appending(path: "khayt-invoices-\(day).csv")
            let b = dir.appending(path: "khayt-expenses-\(day).csv")
            try Data(invoices.utf8).write(to: a, options: .atomic)
            try Data(expenses.utf8).write(to: b, options: .atomic)
            Telemetry.feature(.accountingExport, in: self)
            spendNote = words.callIt("mac.exported_to") + " " + dir.lastPathComponent
            if format == "wafeq" { spendNote? += " — " + words.callIt("mac.export_wafeq_note") }
            if format == "daftra" { spendNote? += " — " + words.callIt("mac.export_daftra_note") }
        } catch {
            spendProblem = words.callIt("mac.export_failed") + " " + String(describing: error)
        }
    }

    /// Is this book connected to Khayt Cloud, and therefore expecting to be in
    /// step with another device?
    ///
    /// THIS APP DOES NOT SYNC. It writes to the store on this Mac and stamps
    /// every record so the Electron app's next sync picks the change up — which
    /// is the mechanism, and it only runs when that app runs. A shop that keeps
    /// its book on two machines and stops opening Khayt would have the two
    /// drift apart with nothing said, which is the one failure worth putting on
    /// screen before the feature exists.
    var cloudConnected: Bool { Self.cloudConnected(settingsDict) }

    /// Where this shop's cloud is, for the links a storefront needs pasted
    /// into it. Nil unless the connection is actually finished — a half-set-up
    /// cloud would produce a URL that looks right and serves nothing.
    var cloudAddress: (url: String, shopId: String)? {
        guard cloudConnected, case .object(let cloud)? = settingsDict["cloud"],
              case .string(let url)? = cloud["url"],
              case .string(let shopId)? = cloud["shopId"],
              !url.isEmpty, !shopId.isEmpty else { return nil }
        return (url, shopId)
    }

    // MARK: - A job's photo, on its product

    /// The product a job was made from, when it is still in the catalogue.
    func productOf(_ job: Order) -> JSONValue? {
        guard let id = job.productId, !id.isEmpty else { return nil }
        return productRows.first { Self.recordId($0) == id }
    }

    /// Whether "Use as product photo" is offered on this job at all.
    func canUseAsProductPhoto(_ job: Order) -> Bool {
        canWrite && productOf(job) != nil
    }

    /// The job's photos, newest last, as Portfolio flattened them.
    func photos(of job: Order) -> [Snapshot] {
        snapshots.filter { $0.orderId == job.id }
    }

    enum ProductPhotoResult: Equatable { case added, already, failed }

    /// Put one of a job's photos on the product it was made from, as a picture
    /// of kind `print` — "the real thing", which the web store carries straight
    /// after the primary (`storefrontPhotos`).
    ///
    /// Appended, never made primary: which picture leads a listing is the
    /// shop's decision (`addImage` in `lib/product-images.js`). The picture is
    /// re-made at the product sizes from the full file when it is on this Mac,
    /// and from the inline thumbnail when it is not — a small real photo beats
    /// none. The file goes down before the record, as everywhere else.
    @discardableResult
    func useAsProductPhoto(_ snap: Snapshot) async -> ProductPhotoResult {
        guard permitted("inventory", "edit") else { return .failed }
        guard let build = source.build, canWrite, let engine,
              let job = orders.first(where: { $0.id == snap.orderId }),
              let productId = job.productId, let row = productOf(job) else {
            writeProblem = words.callIt("mac.move_sample"); return .failed
        }
        let bytes = snap.file.flatMap { try? Data(contentsOf: $0) }
            ?? snap.thumb.flatMap(Self.dataURIBytes)
        guard let bytes, let made = OrderPhoto.encode(bytes) else {
            writeProblem = words.callIt("pe.upload_failed"); return .failed
        }
        do {
            let fields = try await ProductPhotos.addPrintPhoto(
                made, to: row, productId: productId, engine: engine) { imageId in
                try ProductPhotos.write(made.full, productId: productId, imageId: imageId, in: build)
            }
            guard let fields else { writeProblem = nil; return .already }
            guard case .object = row else { return .failed }
            // The before- and after-copies read INSIDE the write, off the book
            // on disk, so the undo puts back only the picture fields.
            let undo = try await StoreWriter.updateOffMain(build) { root -> [ChangedRecord] in
                var rows = Self.rows(root, "products")
                guard let at = rows.firstIndex(where: { Self.recordId($0) == productId }),
                      case .object(var record) = rows[at] else { return [] }
                var undo = [ChangedRecord(collection: "products", id: productId, was: record)]
                for (key, value) in fields { record[key] = value }
                StoreWriter.stamp(&record)
                rows[at] = .object(record)
                root["products"] = .array(rows)
                Self.sealUndo(&undo, in: root)
                return undo
            }
            registerMoveUndo(undo, named: words.callIt("mac.edit_product"))
            writeProblem = nil
            await load(source)
            return .added
        } catch {
            writeProblem = String(describing: error)
            return .failed
        }
    }

    /// The bytes inside a `data:…;base64,` URI.
    static func dataURIBytes(_ uri: String) -> Data? {
        guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
    }

    /// Who else has this book open, in the shop's own language.
    ///
    /// `StoreLock` hands back the application's name and — only when it is
    /// somewhere else — the machine. Everything a person reads is added here,
    /// because that file is nonisolated and has no catalogue to ask.
    func whoElseHasIt(_ build: StoreReader.Build) -> String? {
        guard let held = StoreLock.held(StoreLock.verdict(for: build)) else { return nil }
        let who = held.app ?? words.callIt("mac.lock_another")
        guard let host = held.host else {
            return words.callIt("mac.lock_held", ["who": .string(who)])
        }
        return words.callIt("mac.lock_held_on", ["who": .string(who), "where": .string(host)])
    }

    /// The shop's name, as its documents print it: `biz` in the language asked
    /// for by the shared fallback, or nil when nothing is filled in.
    static func shopName(from settings: [String: JSONValue], engine: KhaytEngine?,
                         language: String) async -> String? {
        if let engine, let name = try? await engine.shopText("biz", settings: settings, language: language),
           !name.isEmpty { return name }
        // No engine: the two keys every existing record uses, by hand.
        for key in ["bizEn", "bizAr"] {
            if let v = plainString(settings[key]), !v.isEmpty { return v }
        }
        return nil
    }

    /// The pricing convention, read the way `profileFromSettings` reads it: the
    /// profile's when there is one, inclusive otherwise — the only thing Khayt
    /// ever did before there was a profile.
    static func taxMode(_ settings: [String: JSONValue]) -> String {
        if case .object(let tax)? = settings["tax"], let mode = plainString(tax["mode"]),
           mode == "exclusive" || mode == "inclusive" { return mode }
        return "inclusive"
    }

    /// The country the tax rules were chosen for, or "" for a hand-made profile.
    static func taxCountry(_ settings: [String: JSONValue]) -> String {
        guard case .object(let tax)? = settings["tax"] else { return "" }
        return plainString(tax["country"]) ?? ""
    }

    nonisolated static func plainNumber(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let n)?: return n
        case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func plainBool(_ value: JSONValue?) -> Bool? {
        if case .bool(let b)? = value { return b }
        return nil
    }

    private var shopCurrency: String {
        if case .string(let c)? = settingsDict["currency"], !c.isEmpty { return c }
        return "SAR"
    }

    /// The shop's own currency, from a settings dictionary rather than the
    /// loaded book — `applyMove` runs against the record it read from disk.
    static func shopCurrencyOf(_ settings: [String: JSONValue]) -> String {
        if case .string(let c)? = settings["currency"], !c.isEmpty { return c }
        return "SAR"
    }

    nonisolated static func settings(_ root: [String: JSONValue]) -> [String: JSONValue] {
        if case .object(let s)? = root["settings"] { return s }
        return [:]
    }

    /// The question this move has to ask before it can happen, if any.
    ///
    /// Two moves are not just a change of column. Putting a job on hold starts a
    /// clock somebody will want explained; finishing a job that was IN QC is an
    /// inspection, and the record of it is what the shop's pass rate is computed
    /// from. Every other move is a move.
    func questionFor(_ id: Order.ID, moving to: Stage) -> (() -> Void)? {
        guard let job = orders.first(where: { $0.id == id }) else { return nil }
        let subject = PendingHold(id: id, project: job.project)
        if to == .on_hold { return { self.pendingHold = subject } }
        // EVERY completion asks what it took, not only one out of inspection.
        // `order-status.gate` sets `needsActuals` for this move and no other,
        // and nothing in this app read it — so a job finished here recorded
        // what it was quoted at and never what it cost.
        //
        // A job leaving QC is asked once, in this sheet, rather than being
        // handed a second dialog for its notes.
        // A job ALREADY finished — moved back from Shipped or Delivered — is
        // not being finished again, and the sheet would overwrite what it
        // really took. The move only takes the stamp off.
        if to == .completed, job.status == "completed" || job.status == "delivered" { return nil }
        if to == .completed {
            let finishing = PendingCompletion(
                id: id, project: job.project,
                estHours: job.printTime, estGrams: Self.quotedGrams(job),
                leavingQC: Stage.of(job) == .qc)
            return {
                self.pendingCompletion = finishing
                // The sheet opens NOW, with the estimate in the boxes, and the
                // printer's answer replaces it when it arrives. A sheet that
                // waited for a JavaScriptCore round trip would be a click that
                // does nothing for a moment, which reads as a click that missed.
                Task { await self.askWhatThePrinterSaid(for: id) }
            }
        }
        // A job leaving inspection for anywhere else FAILED it. Sending it back
        // without recording that is how a shop's scrap costs go unrecorded and
        // its pass rate is computed over the jobs that happened to pass.
        if Stage.of(job) == .qc { return { self.pendingQcFail = subject } }
        return nil
    }

    /// Show a job's invoice.
    func showInvoice(_ id: Order.ID) {
        guard let job = orders.first(where: { $0.id == id }) else { return }
        pendingInvoice = PendingHold(id: id, project: job.project)
    }

    /// Give a job that began as a quote the invoice number it is owed, the
    /// first time its invoice is drawn.
    ///
    /// For the books that already exist: until this build, a quote accepted on
    /// this Mac was never numbered, so a shop has jobs sitting at Pending or
    /// Completed with no `invoiceNumber`. Renumbering them all on open would
    /// hand out numbers in an order nobody issued them; numbering each when
    /// its invoice is ISSUED is the order a paper book would have. The rule is
    /// `KhaytOrderNew.invoiceNumberOwed` — not a quote, not cancelled, no
    /// number, and began as one — so a second look changes nothing.
    ///
    /// Asked on the book as loaded, then done again inside the write on the
    /// book as it is on disk: the counter is a read-modify-write.
    func issueInvoiceNumberIfOwed(_ id: Order.ID) async {
        guard canMoveJobs, permitted("orders", "edit"),
              let build = source.build, let engine, let row = orderRow(id) else { return }
        guard (try? await engine.invoiceNumberOwed(order: row, settings: settingsDict)) == true else { return }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var orders = Self.rows(root, "printLog")
                guard let at = orders.firstIndex(where: { Self.recordId($0) == id }) else { return }
                let numbered = try await engine.ensureInvoiceNumber(
                    order: orders[at], settings: Self.settings(root),
                    year: Calendar.book.component(.year, from: Date()))
                guard numbered.number != nil, case .object(var o) = numbered.order else { return }
                StoreWriter.stamp(&o)
                orders[at] = .object(o)
                root["printLog"] = .array(orders)
                root["settings"] = numbered.settings
            }
            await load(source)
        } catch {
            // The document still draws, under the job's id, as it always has.
        }
    }

    /// Build a printable sheet of shelf labels, for the spools given or for the
    /// whole shelf when none are.
    ///
    /// The HTML comes from `lib/labels.js` — the same builder the Electron app
    /// prints from, so a rack labelled half from one app and half from the
    /// other is one rack — and the QR images come from CoreImage. Nothing is
    /// printed here: the sheet is shown first, because a shop should see forty
    /// labels before it spends forty labels' worth of paper.
    func askForShelfLabels(_ ids: [String] = []) async {
        let chosen = ids.isEmpty ? spools : spools.filter { ids.contains($0.id) }
        guard !chosen.isEmpty, let engine else { return }
        let entries = chosen.map { ShelfLabels.entry(for: $0, shop: self) }
        let heading = words.callIt("mac.shelf_labels")
        guard let html = try? await engine.labelSheet(entries, heading: heading) else { return }
        pendingLabels = LabelSheetRequest(html: html, count: chosen.count)
    }

    func clearQuestion() {
        pendingHold = nil
        pendingCompletion = nil
        pendingPayment = nil
        pendingShipment = nil
        pendingSend = nil
        pendingEdit = nil
        pendingQcFail = nil
        pendingInvoice = nil
        pendingLabels = nil
    }

    /// Whether a job may be moved at all: a real book, held by this app, with
    /// the shared rules running. The sample shop is for looking at.
    /// May this window change jobs: a real book this app owns, AND a person the
    /// staff lock allows to edit jobs. The lock was asked by the functions
    /// behind ~150 buttons but not by this, so a viewer saw every edit button
    /// live and was refused on the click (alpha.62 re-check). The functions
    /// still ask for themselves (`LockGate`); this is what the buttons show.
    var canMoveJobs: Bool { source.isReal && ownership != nil && lockAllows("orders", "edit") }

    // ── WHICH COLUMNS WOULD TAKE THE CARD IN THE AIR ──────────────────────────
    //
    // Answered when a card is picked UP, not when it is dropped. Every column
    // lit up identically while a job was dragged over it, and a move the rules
    // refuse was refused after the drop, as an error — so a shop learnt where a
    // job could go by trying, and the board it was reading gave it no help.
    // `KhaytOrderStatus.gate` has always been able to answer this, and
    // `KhaytEngine.statusGate` was written for exactly this use and documented
    // as "what greys out a drop target before anything is dragged onto it".
    // Nothing called it.

    /// The raw rows the last load read. Named for the KPIs because that is what
    /// first needed them; every engine call that takes the whole book wants the
    /// same two, and re-reading the store to answer a drag would be a disk read
    /// for a hover.
    private var bookOrders: [JSONValue] { kpiOrders }
    private var bookSettings: [String: JSONValue] { kpiSettings }

    /// A card has been picked up: ask every column at once.
    func beganDragging(_ id: Order.ID) {
        draggingJob = id
        dragGates = [:]
        watchForDragEnd()
        guard canMoveJobs, let engine else { return }
        guard let order = bookOrders.first(where: { Self.recordId($0) == id }) else { return }
        let statuses = Stage.boardColumns.map(\.rawValue)
        let book = bookOrders
        let settings = bookSettings
        Task { [weak self] in
            let gates = try? await engine.statusGates(order: order, to: statuses,
                                                      orders: book, settings: settings)
            // The card may have been dropped, or another picked up, while this
            // was crossing into the engine. Answers about a job nobody is
            // holding would dim the columns for the next drag.
            guard let self, self.draggingJob == id else { return }
            self.dragGates = gates ?? [:]
        }
    }

    /// The card has landed, or the drag was abandoned.
    func stoppedDragging() {
        draggingJob = nil
        dragGates = [:]
        releaseWatchers.forEach { NSEvent.removeMonitor($0) }
        releaseWatchers = []
    }

    /// The mouse-up that ends a drag, wherever it happens.
    ///
    /// A DRAG THAT IS ABANDONED TELLS NOBODY. `dropDestination` fires when a
    /// card lands on a column; a card released over the sidebar, over another
    /// application, or back where it started produces no callback at all — and
    /// the board would sit there with four columns greyed out and outlined in
    /// red, about a job nobody is holding, until the next drag or the next
    /// reload. A state that can only be cleared by the happy path is a state
    /// that gets stuck.
    ///
    /// Both monitors, because either alone has a hole: the local one never sees
    /// a release outside this app, and the global one never sees one inside it.
    ///
    /// AND NOT `isTargeted`, which is the obvious-looking hook and is wrong: it
    /// goes false every time the pointer crosses from one column to the next,
    /// so clearing on it would end the drag halfway across the board — the
    /// feature would work only for the first column tried.
    /// Removed in `stoppedDragging`, always — see the menu-bar timer in
    /// `MenuBar.swift` for what an unremoved AppKit monitor costs.
    private func watchForDragEnd() {
        releaseWatchers.forEach { NSEvent.removeMonitor($0) }
        releaseWatchers = []
        let ended: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.stoppedDragging() }
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            ended(); return event
        } { releaseWatchers.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { _ in
            ended()
        }) { releaseWatchers.append(global) }
    }

    /// Why this column would refuse the card in the air — nil if it would take
    /// it, nil while the answer has not arrived, and nil when nothing is being
    /// dragged.
    ///
    /// The column the card is ALREADY IN is not a refusal. Dropping a card back
    /// where it started is not a move and the board must not draw it as barred.
    func dragRefusal(_ stage: Stage) -> String? {
        guard let id = draggingJob else { return nil }
        // Shipped takes the card by stamping a date rather than by moving the
        // status, so the rules refuse it as a DESTINATION and the column would
        // otherwise paint itself barred while a card it will happily take is in
        // the air. What it actually refuses — a job that is not finished — is
        // `markShipped`'s answer, given when the card lands.
        if stage == .shipped { return nil }
        guard let gate = dragGates[stage.rawValue] else { return nil }
        if orders.first(where: { $0.id == id }).flatMap(Stage.of) == stage { return nil }
        return gate.ok ? nil : words.gateRefusal(gate)
    }

    /// How long a notice stays once the last one arrived. Long enough to read
    /// three sentences after looking back at the screen, short enough that a
    /// confirmation is gone before it becomes furniture.
    static let noticeLifetime: Duration = .seconds(15)

    /// Close one notice, and leave the others.
    func dismissNotice(at index: Int) {
        guard moveNotices.indices.contains(index) else { return }
        moveNotices.remove(at: index)
    }

    /// Move a job to a stage, and take what it costs off the shelf.
    ///
    /// Three collections change together and are written in one swap: the job,
    /// the spools its filament came off, and the consumables it spent. A book
    /// where the job says "completed" and the spools still hold its filament
    /// has told the shop it has stock it has already used.
    ///
    /// Read `Kanban` for what a person sees; this is what happens.
    /// What a finished job really took, as the shop typed it.
    ///
    /// `source` is `manual` and nothing else, and that is not a placeholder to
    /// fill in later — these figures came off a keyboard. A margin report that
    /// cannot tell a measurement from a shop's best guess is the whole reason
    /// the field exists, and `Quoting` refuses typed figures outright: a typed
    /// actual is usually the estimate confirmed, so counting it would compare
    /// an estimate to itself.
    ///
    /// Measured figures need the printer's own completion, which means
    /// `PrinterWatch` remembering the job that just ended. It does not yet.
    struct Actuals: Equatable {
        var hours: Double
        var grams: Double
        /// Which instrument read each axis, or `manual` where the shop typed
        /// it. Per-axis because a printer can report one and not the other:
        /// PrusaLink gives a duration and no filament, so calling that record
        /// "measured" would put a fabricated variance into every report.
        ///
        /// A figure the shop CHANGED is manual whatever the printer said —
        /// correcting a measurement makes it a correction, and the record
        /// claiming otherwise is how a wrong number gets trusted twice.
        var timeSource: String = "manual"
        var weightSource: String = "manual"
    }

    func moveJob(_ id: Order.ID, to stage: Stage,
                 holdReason: String? = nil, qcNotes: String? = nil,
                 actuals: Actuals? = nil) async {
        moveProblem = nil
        moveNotices = []
        guard permitted("orders", "edit") else { return }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample")
            return
        }
        guard let engine else {
            moveProblem = words.callIt("mac.move_no_engine")
            return
        }

        // On the stack NOW, at the click: the write below suspends, and an
        // undo registered after it went on after whatever came next.
        let pending = pendingMoveUndo(named: words.callIt("mac.move_action"))
        defer { pending.drop() }
        var undoSnapshot: [ChangedRecord] = []
        var said: [String] = []
        var telegram: TelegramMessage?
        var owed: [KhaytEngine.WebhookDelivery] = []
        var mail: OrderEmail?
        var portal: PortalRefresh?
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let out = try await Self.applyMove(
                    to: &root, id: id, stage: stage, engine: engine, words: self.words,
                    holdReason: holdReason, qcNotes: qcNotes, actuals: actuals)
                undoSnapshot = out.undo; said = out.notices
                telegram = out.telegram; owed = out.webhooks
                mail = out.email; portal = out.portal
            }
            // Only once the swap has happened. The last ownership check is after
            // the mutation, so a book that changed hands mid-move throws here —
            // and a shop told which spools were emptied by a move that was
            // refused would be worse than being told nothing.
            moveNotices = said
            pending.keepUnlessEmpty(undoSnapshot)
            Telemetry.feature(.orderMoved, in: self)
            await load(source)
            // AFTER the write, and only if it succeeded. A message about a job
            // that was not saved is worse than no message. A send that fails is
            // said out loud rather than swallowed: the whole point of the app
            // refusing these moves before was that a piece of the move would
            // silently not happen.
            if let telegram { await tell(telegram) }
            if let mail { await post(mail) }
            if let portal { await refresh(portal) }
            if !owed.isEmpty { await fire(owed) }
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch {
            moveProblem = String(describing: error)
        }
    }

    /// Deliver what the move owes, and say what did not arrive.
    ///
    /// Not fatal, for the same reason a failed Telegram message is not: the job
    /// IS moved and the book says so. Undoing a correct write because a
    /// consumer was down would be the wrong trade. The shop is TOLD, which is
    /// the whole point of the app having refused these moves before.
    func fire(_ deliveries: [KhaytEngine.WebhookDelivery]) async {
        guard let engine else { return }
        var sent = 0
        for one in deliveries {
            // The HOST, not the whole URL: a webhook URL usually carries a
            // token in its path, and a sentence on screen is a sentence that
            // gets screenshotted into a support chat.
            let name = URL(string: one.url)?.host ?? one.url
            guard let url = URL(string: one.url) else {
                moveProblem = words.callIt("mac.webhook_failed", ["where": .string(name)])
                    + " " + words.callIt("mac.webhook_bad_url")
                continue
            }
            do {
                // SEALED SECRETS ARE OPENED AT THE POINT OF USE, the way the
                // Telegram token is. `settings.webhooks.secret` is a registered
                // path, and the legacy config carries it down into every
                // migrated subscription — so signing with the string as it sits
                // in the book would sign with the ciphertext and every delivery
                // would fail verification at the consumer.
                // `open` returns a value with no marker untouched, so this is
                // the same call whether the shop's secret is sealed or is from
                // a store written before sealing existed.
                let secret = try await Secrets.open(one.secret, for: source)
                let status = try await WebhookClient.deliver(
                    one.body, to: url, secret: secret, event: one.event, engine: engine)
                if (200..<300).contains(status) {
                    sent += 1
                } else {
                    moveProblem = words.callIt("mac.webhook_failed", ["where": .string(name)])
                        + " HTTP \(status)"
                }
            } catch {
                moveProblem = words.callIt("mac.webhook_failed", ["where": .string(name)])
                    + " " + ((error as? LocalizedError)?.errorDescription
                             ?? String(describing: error))
            }
        }
        if sent > 0 {
            moveNotices.append(words.callIt("mac.webhooks_sent", ["n": .number(Double(sent))]))
        }
    }

    /// Send what the shop's bot has to say, and say so if it could not.
    ///
    /// Not fatal: the job IS finished, the book says so, and undoing a correct
    /// write because a message did not go out would be the wrong trade. The
    /// shop is told, and can send it by hand.
    /// Send the customer the email this move owes them, and say so if it failed.
    ///
    /// Not fatal, for the reason `tell` is not: the job IS finished and the
    /// book says so. What is NOT acceptable is silence — the app refused these
    /// moves in the first place precisely so that no customer would go untold
    /// while a shop believed otherwise.
    /// Refresh the customer's tracking link, and say so if it did not go.
    ///
    /// Not fatal, for the reason the email and the message are not: the job IS
    /// finished and the book says so. But a stale page is the failure mode this
    /// whole refusal existed to prevent — a customer reading "Printing" about a
    /// job that was collected yesterday — so it is said out loud.
    func refresh(_ portal: PortalRefresh) async {
        guard let engine else { return }
        do {
            var cloud: [String: JSONValue] = [:]
            if case .object(let c)? = settingsDict["cloud"] { cloud = c }
            // `settings.cloud.token` is a registered sealed path, so the string
            // in the book is ciphertext. Opened here, at the point of use, and
            // never held — the same rule as the bot token and the webhook
            // secret. Sent as the bearer, it would fail every request and read
            // to a shop as a cloud that had stopped accepting its account.
            let token = try await Secrets.open(Self.plainString(cloud["token"]) ?? "", for: source)
            try await PortalClient.republish(
                portal,
                baseUrl: Self.plainString(cloud["url"]) ?? "",
                shopId: Self.plainString(cloud["shopId"]) ?? "",
                token: token, engine: engine)
            moveNotices.append(words.callIt("mac.portal_refreshed"))
        } catch let failure as PortalClient.Failure {
            moveProblem = words.callIt("mac.portal_failed") + " "
                + (failure.errorDescription ?? String(describing: failure))
        } catch let locked as Secrets.Failure {
            moveProblem = words.callIt("mac.portal_failed") + " " + locked.description
        } catch {
            moveProblem = words.callIt("mac.portal_failed") + " " + String(describing: error)
        }
    }

    func post(_ mail: OrderEmail) async {
        do {
            // OPENED AT THE POINT OF USE, like the bot token and the webhook
            // secret. `settings.emailConfig.apiKey` is a registered sealed
            // path, so the string in the book is ciphertext; handing it to a
            // provider would fail authentication on every send and read to the
            // shop as an expired key.
            var config: [String: JSONValue] = [:]
            if case .object(let c)? = settingsDict["emailConfig"] { config = c }
            let key = try await Secrets.open(Self.plainString(config["apiKey"]) ?? "", for: source)
            // THERE ARE TWO SEALED SECRETS UNDER `emailConfig`, and this opened
            // one. `settings.emailConfig.smtpPassword` is registered in
            // `store-secret-paths.js` alongside `apiKey`, so a shop on its own
            // relay held ciphertext where its password should be — which a
            // server answers with `535 authentication failed`, indistinguishable
            // from a password the shop typed wrong.
            let smtpPassword = try await Secrets.open(
                Self.plainString(config["smtpPassword"]) ?? "", for: source)
            try await EmailClient.send(mail, apiKey: key, config: config,
                                       smtpPassword: smtpPassword, engine: engine)
            moveNotices.append(words.callIt("mac.email_sent"))
        } catch let failure as EmailClient.Failure {
            moveProblem = words.callIt("mac.email_failed") + " "
                + (failure.errorDescription ?? String(describing: failure))
        } catch let locked as Secrets.Failure {
            moveProblem = words.callIt("mac.email_failed") + " " + locked.description
        } catch {
            moveProblem = words.callIt("mac.email_failed") + " " + String(describing: error)
        }
    }

    private func tell(_ message: TelegramMessage) async {
        do {
            // THE TOKEN IS ENCRYPTED ON DISK, and the rule that this app never
            // decrypts belonged to the WRITE path. Handed the `__enc__` string
            // straight through, `isBotToken` refused it and every shop with
            // Telegram configured was told its message did not go out — every
            // time, since the day this shipped. Opened here, at the point of
            // use, and never held anywhere.
            let token = try await Secrets.open(message.botToken, for: source)
            try await Telegram.send(botToken: token, chatId: message.chatId,
                                    message: message.message)
            moveNotices.append(words.callIt("mac.telegram_sent"))
        } catch let failure as Telegram.Failure {
            moveProblem = words.callIt("mac.telegram_failed") + " " + Self.describe(failure)
        } catch let locked as Secrets.Failure {
            moveProblem = words.callIt("mac.telegram_failed") + " " + locked.description
        } catch {
            moveProblem = words.callIt("mac.telegram_failed") + " " + String(describing: error)
        }
    }

    static func describe(_ failure: Telegram.Failure) -> String {
        switch failure {
        case .badToken: return "The bot token in Settings is not a Telegram token."
        case .badChatId: return "The chat ID in Settings is not one Telegram can deliver to."
        case .refused(let status, let why): return why.isEmpty ? "HTTP \(status)" : why
        case .unreachable(let why): return why
        }
    }

    /// One record as it was before a move, and where it lives.
    ///
    /// A move changes three collections, so an undo has to put three
    /// collections back — including the spools. Undoing a completion that
    /// emptied a spool without returning the filament would be an undo that
    /// lies about the shelf.
    ///
    /// Undo is FIELD-LEVEL (`FieldUndo.swift`): it needs what the action wrote
    /// (`now`) as well as what was there, so it can put back only the fields
    /// the action changed and leave whatever was written since.
    struct ChangedRecord: Sendable {
        let collection: String
        let id: String
        /// The record before the action. Empty for one the action created.
        let was: [String: JSONValue]
        /// The record as the action left it — filled in by `write` or
        /// `sealUndo`. Nil until then.
        var now: [String: JSONValue]? = nil
        var kind: UndoKind = .edited
        /// Where a deleted record sat, so putting it back puts it there.
        var at: Int? = nil
    }

    /// A move the rules refused, said in the shop's own words.
    struct MoveRefused: Error { let sentence: String }

    /// The move itself, against the book as it is ON DISK.
    ///
    /// Static and taking `root` because it runs inside the write: everything it
    /// reads — the other jobs the WIP limit counts, the spools it draws from,
    /// the settings that decide whether it deducts at all — must be what is in
    /// the file, not what this app last drew on screen.
    /// Everything one move produced: what changed, what to say, and what it
    /// owes the world outside this book.
    ///
    /// A STRUCT rather than the tuple this was. `applyMove` returned six
    /// positional values, and every new outbound channel — email, then the
    /// portal — meant editing the signature plus four test helpers plus a
    /// `let (_, _, _, owed, _, _)` that nobody could read. Twice in one day.
    /// Names also make `out.portal` mean something at the call site, where
    /// `out.5` did not.
    ///
    /// The three outbound fields are nil or empty when the move owes nothing —
    /// which is the common case, a shop with no integrations configured.
    struct MoveOutcome {
        /// Enough to put the book back as it was.
        let undo: [ChangedRecord]
        /// Sentences for the person, already in their language.
        let notices: [String]
        let telegram: TelegramMessage?
        let webhooks: [KhaytEngine.WebhookDelivery]
        let email: OrderEmail?
        let portal: PortalRefresh?
    }

    /// The customer's name as the shop writes it, for a message about their job.
    ///
    /// One resolution, used by the webhook bodies and by the email, because a
    /// customer called one thing in a webhook and another in the email about
    /// the same move is the shop speaking with two voices. Empty when the job
    /// has no customer, or the customer has no name — the email greets the
    /// address in that case, which is what the other app does.
    static func emailClientName(for order: [String: JSONValue],
                                in clients: [JSONValue]) -> String {
        guard case .string(let clientId)? = order["clientId"] else { return "" }
        for row in clients where recordId(row) == clientId {
            if case .object(let c) = row {
                return plainString(c["nameEn"]) ?? plainString(c["nameAr"])
                    ?? plainString(c["name"]) ?? ""
            }
        }
        return ""
    }

    static func applyMove(to root: inout [String: JSONValue],
                                  id: Order.ID, stage: Stage,
                                  engine: KhaytEngine, words: Words,
                                  holdReason: String? = nil, qcNotes: String? = nil,
                                  actuals: Actuals? = nil)
    async throws -> MoveOutcome {

        var orders = rows(root, "printLog")
        // The book as found, for the undo: the actuals below are written onto
        // `orders` first, and an undo whose before-copy already carried them
        // would leave a job undone from done still holding what it "took".
        var ordersAsFound = orders
        let inventory = rows(root, "inventory")
        let consumables = rows(root, "consumables")
        let machines = rows(root, "machines")
        let clients = rows(root, "clients")
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }

        guard var target = orders.first(where: { recordId($0) == id }) else {
            throw MoveRefused(sentence: words.callIt("mac.move_gone"))
        }

        // ── WHAT IT REALLY TOOK, WRITTEN BEFORE THE MOVE IS MADE ──────────
        //
        // Onto the order first, then the move — which is the order Electron
        // uses. The move hands this record to the engine and stores what comes
        // back, so actuals written afterwards would be written onto a copy the
        // book has already replaced.
        //
        // AND NOT BECAUSE THE DEDUCTION READS THEM. It does not, in either
        // app: `deductForOrder` takes an `actualGrams` — "what the PRINTER says
        // the job used" — and nobody passes it, `renderer/inventory.js`'s
        // `deductionContext()` included. So a job that used 260 g against a
        // 160 g quote still takes 160 g off the shelf. That is a gap in the
        // shared rule rather than in this app, and closing it here alone would
        // make the two disagree about a shop's shelf, so it is left alone and
        // pinned by `MoveJobTests.theShelfStillFollowsTheEstimate`.
        //
        // Both figures and their provenance travel together. A record with
        // actuals and no `actualsSource` reads as measured to anything that
        // checks the source only when it is present.
        // Already finished, the record keeps what the job really took: a move
        // back from Shipped is not a second completion (`order-status.apply`).
        let alreadyFinished: Bool = {
            if case .object(let o) = target, case .string(let st)? = o["status"] {
                return st == "completed" || st == "delivered"
            }
            return false
        }()
        if let actuals, !(stage == .completed && alreadyFinished), case .object(var fields) = target {
            fields["actualPrintTime"] = .number((actuals.hours * 100).rounded() / 100)
            fields["actualWeight"] = .number((actuals.grams * 10).rounded() / 10)
            fields["actualsSource"] = .object([
                "time": .string(actuals.timeSource),
                "weight": .string(actuals.weightSource),
                "at": .string(ISO8601DateFormatter().string(from: Date())),
            ])
            target = .object(fields)
            if let at = orders.firstIndex(where: { recordId($0) == id }) { orders[at] = target }
            root["printLog"] = .array(orders)
        }

        // Asked BEFORE anything is written. A webhook, an email or a portal
        // refresh cannot be sent from here and cannot be sent afterwards, so a
        // move that would trigger one is refused whole rather than made with a
        // piece missing.
        //
        // TELEGRAM IS THE EXCEPTION, because this app can now send it: the
        // message is the shared rule's and the sending is URLSession's. It is
        // sent AFTER the write succeeds — a message about a job that was not
        // saved is worse than no message — and a send that fails is reported
        // rather than swallowed, so a shop knows the customer was not told.
        let reaches = (try? await engine.outbound(order: target, to: stage.rawValue,
                                                  settings: settings, clients: clients)) ?? []
        // The channels this app can actually reach. Everything else is still
        // refused WHOLE rather than made with a piece missing — an email or a
        // portal refresh cannot be sent from here and cannot be sent
        // afterwards, so a half-made move would leave a customer told nothing
        // with no way to notice.
        //
        // EMAIL IS CONDITIONAL, and the condition is the provider rather than
        // the channel. So the question is not "can I email" but "can I email
        // THROUGH THIS", and `via` is what the shared rule sends along to
        // answer it. A provider added to the other app and not to this one is
        // still refused by name, which is the point of asking at all.
        let cannotSend = await Self.channelsThisAppCannotSend(
            reaches, settings: settings, engine: engine)
        if !cannotSend.isEmpty {
            throw MoveRefused(sentence: words.outboundRefusal(cannotSend))
        }
        var telegram = reaches.contains { $0.channel == "telegram" }
            ? try? await engine.telegramMessage(order: target, newStatus: stage.rawValue,
                                                settings: settings, currency: shopCurrencyOf(settings))
            : nil

        let move = try await engine.moveJob(
            order: target, to: stage.rawValue, orders: orders, settings: settings,
            inventory: inventory, consumables: consumables, machines: machines,
            now: Date(), today: localDay(), holdReason: holdReason, qcNotes: qcNotes)

        guard move.ok else {
            throw MoveRefused(sentence: words.gateRefusal(move.gate))
        }
        // An effect nobody classified is a gap, and a gap in a status change is
        // how something goes missing on this Mac and nowhere else. Refuse.
        if let unhandled = move.unhandled, !unhandled.isEmpty {
            throw MoveRefused(sentence: words.callIt("mac.move_unhandled")
                              + " (" + unhandled.joined(separator: ", ") + ")")
        }
        guard var changedOrder = move.order.flatMap(asObject) else {
            throw MoveRefused(sentence: words.callIt("mac.move_gone"))
        }

        // A completion asks for a survey token, and a random source is exactly
        // what a pure module does not have. The FORMAT is shared, so the token
        // this app mints is the token Khayt would have minted.
        if move.performed?.contains("ensure_survey_token") == true, changedOrder["surveyToken"] == nil {
            changedOrder["surveyToken"] = .string(surveyToken())
        }

        // ── A QUOTE ACCEPTED IS AN INVOICE, AND AN INVOICE HAS A NUMBER ───
        //
        // A quote is made with no invoice number, so it never spends one the
        // tax authority will ask about. Khayt gives it one when it is approved
        // (`approveQuote`, `nextInvoiceNumber`); this app never did, so a quote
        // moved to Pending here — from the board, the menu, or the portal's
        // "Check response" — was invoiced as `QUO-…`. The shared counter, in
        // this write, on the settings as they are on disk.
        if case .object(let was) = target, plainString(was["status"]) == "quote",
           stage != .quote, stage != .cancelled {
            let numbered = try await engine.ensureInvoiceNumber(
                order: .object(changedOrder), settings: settings,
                year: Calendar.book.component(.year, from: Date()))
            if numbered.number != nil, case .object(let o) = numbered.order,
               case .object(let s) = numbered.settings {
                changedOrder = o
                root["settings"] = .object(s)
                // AND THE UNDO KEEPS IT. Electron numbers the job before its
                // Undo snapshot, so undoing the approval puts the status back
                // and leaves the number on the job — the counter has no gap,
                // and approving again (`invoiceNumberOwed` is false now) takes
                // no second number. Written into the before-copy here, so the
                // field-by-field undo sees no change on these two fields.
                if let at = ordersAsFound.firstIndex(where: { recordId($0) == id }),
                   case .object(var before) = ordersAsFound[at] {
                    before["invoiceNum"] = o["invoiceNum"]
                    before["invoiceNumber"] = o["invoiceNumber"]
                    ordersAsFound[at] = .object(before)
                }
            }
        }

        // ── WHAT THE MOVE OWES OUTWARD, BUILT FROM THE MOVED JOB ──────────
        //
        // AFTER the move, because the body names the job's state and the whole
        // point of the message is that the state changed: built from the record
        // as it was before, every consumer would be told the job is still where
        // it was. The other app builds them here too, for the same reason.
        //
        // And HERE rather than after the write, because this runs inside the
        // write and the settings, the subscriptions and the customer's name are
        // the ones on disk. Sending is the caller's job; this only addresses.
        var owed: [KhaytEngine.WebhookDelivery] = []
        if let asked = move.webhookEffects, !asked.isEmpty {
            let clientName = emailClientName(for: changedOrder, in: clients)
            owed = (try? await engine.webhookDeliveries(
                order: .object(changedOrder), effects: asked, settings: settings,
                shopName: plainString(settings["bizEn"]) ?? plainString(settings["bizAr"]) ?? "Khayt",
                clientName: clientName, currency: shopCurrencyOf(settings),
                at: ISO8601DateFormatter().string(from: Date()),
                nowMs: Date().timeIntervalSince1970 * 1000)) ?? []
        }

        // ── AND WHAT IT OWES THE CUSTOMER ─────────────────────────────────
        //
        // Built from the moved job for the same reason as the webhooks, and
        // through the same module the other app builds it with, so a customer
        // whose shop has two machines is not written to twice in two voices.
        //
        // `outboundFor` has already refused the move if this could not be
        // carried, so reaching here means it can be. A nil is the ordinary
        // case: no provider, a status the shop does not announce, or no
        // address on file — none of which is an error and none of which is
        // worth a sentence.
        // ── AND WHAT IT OWES THE CUSTOMER'S LINK ──────────────────────────
        //
        // After the move, like everything else here: the page says what the job
        // is doing, and built from the record as it was the customer would be
        // shown the stage it has just left.
        let portal = try? await engine.portalRefresh(
            order: .object(changedOrder), settings: settings, clients: clients,
            shopName: plainString(settings["bizEn"]) ?? plainString(settings["bizAr"]) ?? "Khayt",
            shopAddress: plainString(settings["addrEn"]) ?? plainString(settings["addrAr"]) ?? "",
            stages: [
                words.callIt("track.received", fallback: "Received"),
                words.callIt("track.printing", fallback: "Printing"),
                words.callIt("track.finishing", fallback: "Finishing"),
                words.callIt("track.done", fallback: "Done"),
                words.callIt("track.ready", fallback: "Ready for pickup"),
            ],
            now: Date())

        var mail = try? await engine.orderEmail(
            order: .object(changedOrder), newStatus: stage.rawValue,
            settings: settings, clients: clients,
            shopName: plainString(settings["bizEn"]) ?? plainString(settings["bizAr"]) ?? "Khayt",
            clientName: emailClientName(for: changedOrder, in: clients),
            statusLabel: words.callIt("queue." + stage.rawValue, fallback: stage.rawValue))

        // ── A MOVE THAT ASKED FOR NOTHING OUTWARD SENDS NOTHING ───────────
        //
        // The message, the email and the portal refresh above are decided by
        // the settings; whether THIS move owes them is the rule's. A job moved
        // back from Shipped to Completed is no completion (`order-status`
        // returns no outbound effect for it), and the customer was being told
        // their finished job was finished again.
        var portalOwed = portal
        if (move.outbound ?? []).isEmpty {
            telegram = nil; mail = nil; portalOwed = nil
        }

        var undo: [ChangedRecord] = []
        write(&root, "printLog", changed: [.object(changedOrder)], before: ordersAsFound, into: &undo)
        write(&root, "inventory", changed: move.inventory ?? [], before: inventory, into: &undo)
        write(&root, "consumables", changed: move.consumables ?? [], before: consumables, into: &undo)

        if let text = move.activity {
            appendActivity(&root, text: text, ref: id, settings: settings, root: root)
        }

        let notices = (move.notices ?? []).map { words.sentence(for: $0) }
        return MoveOutcome(undo: undo, notices: notices, telegram: telegram,
                           webhooks: owed, email: mail, portal: portalOwed)
    }

    // MARK: - Reading and writing rows

    nonisolated static func rows(_ root: [String: JSONValue], _ collection: String) -> [JSONValue] {
        if case .array(let r)? = root[collection] { return r }
        return []
    }

    nonisolated static func asObject(_ value: JSONValue) -> [String: JSONValue]? {
        if case .object(let o) = value { return o }
        return nil
    }

    nonisolated static func recordId(_ value: JSONValue) -> String? {
        guard case .object(let o) = value, case .string(let id)? = o["id"] else { return nil }
        return id
    }

    /// Put changed rows back, stamping only the ones that actually changed.
    ///
    /// Stamping a row that did not change would push it to the cloud as an edit
    /// nobody made, and on a shop with two machines that is how the older build
    /// gets to win with a stale copy.
    static func write(_ root: inout [String: JSONValue], _ collection: String,
                              changed: [JSONValue], before: [JSONValue],
                              into undo: inout [ChangedRecord]) {
        guard !changed.isEmpty else { return }
        var byId: [String: JSONValue] = [:]
        for row in changed { if let id = recordId(row) { byId[id] = row } }

        var out = before
        var touched = false
        for i in out.indices {
            guard let id = recordId(out[i]), let next = byId[id], next != out[i] else { continue }
            guard case .object(let was) = out[i], case .object(var now) = next else { continue }
            StoreWriter.stamp(&now)
            undo.append(ChangedRecord(collection: collection, id: id, was: was, now: now))
            out[i] = .object(now)
            touched = true
        }
        guard touched else { return }
        root[collection] = .array(out)
    }

    /// The team's activity log — the same collection, shape and cap Khayt uses.
    static func appendActivity(_ root: inout [String: JSONValue], text: String,
                                       ref: String, settings: [String: JSONValue],
                                       root snapshot: [String: JSONValue],
                                       action: String = "status") {
        var log = rows(snapshot, "auditLog")
        var operatorId: JSONValue = .null
        var operatorName = ""
        if case .string(let opId)? = settings["activeOperatorId"] {
            operatorId = .string(opId)
            if let op = rows(snapshot, "operators").first(where: { recordId($0) == opId }),
               case .object(let o) = op, case .string(let name)? = o["name"] {
                operatorName = name
            }
        }
        log.append(.object([
            "id": .string(uid("AL")),
            "at": .string(StoreWriter.iso(Date())),
            "action": .string(action),
            "detail": .string(text),
            "ref": .string(ref),
            "operatorId": operatorId,
            "operatorName": .string(operatorName),
        ]))
        // Khayt keeps two thousand and drops the oldest. A log that grew for
        // ever would be the one collection that could push a book past the size
        // every backup is built to hold.
        if log.count > 2000 { log = Array(log.suffix(2000)) }
        root["auditLog"] = .array(log)
    }

    /// `YYYY-MM-DD` in this Mac's own timezone, the way `localDateStr` in
    /// renderer/util.js writes it. A spool's usage history records the local
    /// DAY a job drew from it, not an instant, so UTC would put a Riyadh
    /// evening on the wrong date.
    nonisolated static func localDay(_ date: Date = Date()) -> String {
        let c = Calendar.book.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `uid()` from renderer/util.js: prefix, base-36 milliseconds, three random
    /// base-36 characters upper-cased. Matched so an entry written here is
    /// indistinguishable from one Khayt wrote.
    nonisolated static func uid(_ prefix: String) -> String {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let stamp = String(ms, radix: 36)
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let tail = String((0..<3).map { _ in alphabet.randomElement()! }).uppercased()
        return "\(prefix)-\(stamp)\(tail)"
    }

    /// `srv-` and twelve random bytes in hex, the format `lib/order-status.js`
    /// defines and both apps read.
    static func surveyToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return "srv-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Undo

    func registerMoveUndo(_ before: [ChangedRecord], named actionName: String) {
        guard let undoManager, !before.isEmpty else { return }
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: self) { shop in
            shop.restoreMove(before, named: actionName)
        }
    }

    /// Undo what an action changed — field by field — and make THAT undoable.
    ///
    /// The deductions come back with it: undoing a completion that emptied a
    /// spool has to put the filament back, or the undo is a lie about the shelf.
    /// But ONLY what the action took (`FieldUndo.swift`): a delivery received
    /// onto the same spool since, a payment the phone recorded, another job's
    /// deduction — all of that stays, and a field someone else wrote since is
    /// left and named rather than overwritten with a stale copy.
    private func restoreMove(_ snapshot: [ChangedRecord], named actionName: String) {
        restoreMove(after: Task { snapshot }, named: actionName)
    }

    /// The undo's write, ON THE WRITE CHAIN — and its redo registered now.
    ///
    /// Written synchronously, an undo held the window for a whole-book write.
    /// Written later, its redo must still be registered INSIDE the undo, or
    /// it lands on the undo stack instead of the redo stack: so the redo is
    /// registered at once against the write still in flight, the way the
    /// library's undo is (`registerUndo(after:named:)`), and taken off again
    /// if the write turns out to have put nothing back.
    func restoreMove(after earlier: Task<[ChangedRecord]?, Never>, named actionName: String) {
        guard let build = source.build else { return }
        let write = Task { () -> [ChangedRecord]? in
            guard let snapshot = await earlier.value, !snapshot.isEmpty else { return nil }
            // An undo is a write, and it answers to the lock like the edit it
            // reverses: whoever is here must be allowed to edit every kind of
            // record it puts back (the stack is also dropped on every change of
            // who is signed in — see `lockSessionId`).
            guard self.permittedRestoring(snapshot.map(\.collection)) else { return nil }
            do {
                let outcome = try await StoreWriter.updateOffMain(build) { root in
                    Self.undoing(snapshot, in: &root)
                }
                self.moveProblem = nil
                if let partial = Self.partialUndoSentence(outcome.notUndone, words: self.words) {
                    self.moveNotices = [partial]
                }
                await self.load(self.source)
                return outcome.redo
            } catch {
                self.moveProblem = String(describing: error)
                return nil
            }
        }
        guard let undoManager else { return }
        let ticket = UndoTicket()
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: ticket) { [weak self] _ in
            // The entry holds the ticket alive for as long as it exists.
            _ = ticket
            self?.restoreMove(after: write, named: actionName)
        }
        Task { [weak undoManager] in
            let landed = await write.value
            if landed == nil || landed?.isEmpty == true {
                undoManager?.removeAllActions(withTarget: ticket)
            }
        }
    }

    /// The shared shape of every edit: check we may write, do it, re-read.
    /// `gate` is what the edit is to the staff lock, and it is required.
    /// Written on the write chain, never on the main thread: the window keeps
    /// drawing while the whole book is read and saved.
    func write(as gate: LockGate, _ change: @escaping @Sendable (inout [String: JSONValue]) -> Void) async {
        guard permitted(gate) else { writeProblem = moveProblem; return }
        guard let build = source.build else { return }
        do {
            try await StoreWriter.updateOffMain(build) { root in change(&root) }
            writeProblem = nil
            // Read the whole book back rather than patching what is on screen.
            // The screen must show what is on disk, not what this app believes
            // it just put there.
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    // MARK: - Stopping the floor

    /// Whether the shop has stopped starting new prints.
    ///
    /// ── WHY THIS HAD TO EXIST ─────────────────────────────────────────────
    ///
    /// `lib/order-status.js` REFUSES a move to printing while this is set, and
    /// this app already translates that refusal — "Production is paused —
    /// resume before starting new prints." So a shop that paused production in
    /// the other app arrived here to find every start refused, with no way to
    /// resume and nothing on screen saying production was paused at all. That
    /// is worse than a missing feature: it is a dead end that looks like a bug.
    var productionPaused: Bool {
        guard case .object(let s) = settingsValue else { return false }
        return Shop.plainBool(s["productionPaused"]) ?? false
    }

    /// Why, as the shop wrote it. Empty is allowed on purpose — a shop that
    /// just needs the floor stopped should not have to invent a reason.
    var pauseReason: String {
        guard case .object(let s) = settingsValue else { return "" }
        return Shop.plainString(s["pauseReason"]) ?? ""
    }

    /// When it was paused, as stored. Read for the banner, not for arithmetic.
    var pausedAt: String {
        guard case .object(let s) = settingsValue else { return "" }
        return Shop.plainString(s["pausedAt"]) ?? ""
    }

    func pauseProduction(reason: String) async {
        writeProblem = nil
        guard source.build != nil else { writeProblem = words.callIt("mac.move_sample"); return }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        // All three fields, the other app's own shape — `productionPaused`,
        // `pauseReason`, `pausedAt`. A pause that set only the flag would leave
        // a stale reason from the last one on the banner.
        await write(as: .person("orders", "edit")) { root in
            var settings = Self.settings(root)
            settings["productionPaused"] = .bool(true)
            settings["pauseReason"] = .string(reason)
            settings["pausedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
            root["settings"] = .object(settings)
        }
    }

    func resumeProduction() async {
        writeProblem = nil
        guard source.build != nil else { writeProblem = words.callIt("mac.move_sample"); return }
        await write(as: .person("orders", "edit")) { root in
            var settings = Self.settings(root)
            settings["productionPaused"] = .bool(false)
            settings["pauseReason"] = .string("")
            // NULL, not absent. The other app writes `pausedAt = null`, and a
            // field removed entirely is one a merge can resurrect from an older
            // copy on another machine.
            settings["pausedAt"] = .null
            root["settings"] = .object(settings)
        }
    }
}
