import Foundation
import KhaytCore

/// Money, stock and settings the desktop already had and this app did not.
///
/// Every rule here is a `lib/` module the desktop calls too — the copy a
/// recurring expense files, how a transfer splits a spool, what an
/// adjustment row holds, how the invoice counter and the exchange-rate table
/// are set, what a loyalty tier may say. This file only reads the book, asks
/// the rule, and writes the answer back, so a record made here is the one the
/// other app would have made.
///
/// Each write has a static seam (`answeringRecurring`, `adjustingStock`, …)
/// that works on a book already read, which is what the tests drive.
extension Shop {

    // MARK: - Recurring expenses that have come round

    /// The standing costs due on or before today, as `KhaytExpenseBook.due`
    /// picks them. Empty without an engine: a prompt is a convenience.
    func dueRecurringExpenses(today: String = Shop.today()) async -> [Expense] {
        guard let engine, !expenseRows.isEmpty else { return [] }
        guard let due = try? await engine.expensesDue(expenseRows, today: today) else { return [] }
        return due.compactMap { row in
            guard let data = try? JSONEncoder().encode(row) else { return nil }
            return try? JSONDecoder().decode(Expense.self, from: data)
        }
    }

    /// The write, on a book already read. False when the expense is no longer
    /// due — answered on the other computer, or a moment ago here.
    static func answeringRecurring(_ root: inout [String: JSONValue], id: String, add: Bool,
                                   engine: KhaytEngine, newId: String, today: String) async throws -> Bool {
        let before = rows(root, "expenses")
        guard let after = try await engine.expenseComeRound(before, id: id, add: add,
                                                            newId: newId, today: today) else { return false }
        var stamped = stamping(after, against: before)
        // The copy is a new row, which `stamping` leaves alone.
        if add, let at = stamped.firstIndex(where: { recordId($0) == newId }),
           case .object(var copy) = stamped[at] {
            StoreWriter.stamp(&copy)
            stamped[at] = .object(copy)
        }
        root["expenses"] = .array(stamped)
        return true
    }

    /// Add this cycle's copy of a recurring expense, or skip the cycle. The
    /// desktop asks the same question in a toast with the same two answers.
    func answerRecurring(_ id: String, add: Bool) async {
        guard permitted("invoicing", add ? "create" : "edit") else { return }
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
                _ = try await Self.answeringRecurring(&root, id: id, add: add, engine: engine,
                                                      newId: Self.uid("EXP"), today: Self.today())
            }
            await load(source)
            if add { spendNote = words.callIt("exp.recurring_added") }
        } catch let refusal as MoveRefused {
            spendProblem = refusal.sentence
        } catch {
            spendProblem = self.said(error)
        }
    }

    // MARK: - The shelf: adjust, transfer, dry

    /// A spool's raw record, for the parts of it `Spool` does not model —
    /// `adjustments`, `dryingLog`.
    func spoolRow(_ id: String) -> [String: JSONValue]? {
        for row in inventoryRows {
            if case .object(let r) = row, Self.recordId(row) == id { return r }
        }
        return nil
    }

    /// One row of a spool's history list, read leniently: a field the other
    /// app left out is blank rather than a row that vanishes.
    struct SpoolLogRow: Identifiable, Hashable, Sendable {
        let id: String
        let date: String
        let fields: [String: JSONValue]

        func text(_ key: String) -> String { Shop.plainString(fields[key]) ?? "" }
        func number(_ key: String) -> Double? { Shop.plainNumber(fields[key]) }
    }

    /// `adjustments` or `dryingLog` off a spool, newest first.
    func spoolLog(_ id: String, _ key: String) -> [SpoolLogRow] {
        guard case .array(let list)? = spoolRow(id)?[key] else { return [] }
        let read = list.enumerated().compactMap { at, row -> SpoolLogRow? in
            guard case .object(let r) = row else { return nil }
            return SpoolLogRow(id: Self.plainString(r["id"]) ?? "\(key)-\(at)",
                               date: Self.plainString(r["date"]) ?? "", fields: r)
        }
        return read.sorted { $0.date > $1.date }
    }

    /// The adjustment written onto the shelf. Throws the rule's refusal in the
    /// shop's words.
    static func adjustingStock(_ root: inout [String: JSONValue], spoolId: String,
                               input: [String: JSONValue], engine: KhaytEngine, words: Words,
                               newId: String, today: String) async throws {
        var shelf = rows(root, "inventory")
        guard let at = shelf.firstIndex(where: { recordId($0) == spoolId }) else {
            throw MoveRefused(sentence: words.callIt("mac.move_gone"))
        }
        let made = try await engine.adjustStock(shelf[at], input: input, id: newId, today: today)
        guard case .object(var record)? = made.spool else {
            throw MoveRefused(sentence: words.callIt("sup.amount_required"))
        }
        StoreWriter.stamp(&record)
        shelf[at] = .object(record)
        root["inventory"] = .array(shelf)
    }

    /// Put grams on a spool or take them off by hand, with a reason — the
    /// desktop's Adjust. Nil when written, else what went wrong.
    func adjustStock(_ spoolId: String, add: Bool, amount: Double, reason: String) async -> String? {
        guard permitted("inventory", "edit") else { return moveProblem }
        guard let build = source.build, StoreLock.weOwnIt(build) else { return words.callIt("mac.read_only") }
        guard let engine else { return words.callIt("mac.move_no_engine") }
        let words = self.words
        let input: [String: JSONValue] = ["type": .string(add ? "add" : "remove"),
                                          "amount": .number(amount), "reason": .string(reason)]
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                try await Self.adjustingStock(&root, spoolId: spoolId, input: input, engine: engine,
                                              words: words, newId: Self.uid("ADJ"), today: Self.today())
            }
        } catch let refusal as MoveRefused {
            return refusal.sentence
        } catch {
            return self.said(error)
        }
        await load(source)
        spendNote = words.callIt("inv.adj_saved")
        return nil
    }

    /// What a transfer refusal says.
    static func transferRefusal(_ code: String) -> String {
        switch code {
        case "same_location": "inv.transfer_same"
        case "qty_invalid": "inv.transfer_qty_invalid"
        default: "inv.transfer_qty_over"
        }
    }

    /// The transfer written onto the shelf: the spool moved, or the source
    /// and its split, the split after the source as the desktop pushes it.
    static func transferring(_ root: inout [String: JSONValue], spoolId: String, dest: String,
                             qty: Double, engine: KhaytEngine, words: Words, newId: String) async throws {
        var shelf = rows(root, "inventory")
        guard let at = shelf.firstIndex(where: { recordId($0) == spoolId }) else {
            throw MoveRefused(sentence: words.callIt("mac.move_gone"))
        }
        let moved = try await engine.transferStock(shelf[at], dest: dest, qty: qty, newId: newId)
        if let refused = moved.refused {
            throw MoveRefused(sentence: words.callIt(transferRefusal(refused)))
        }
        guard let spools = moved.spools, case .object(var source)? = spools.first else { return }
        StoreWriter.stamp(&source)
        shelf[at] = .object(source)
        if spools.count > 1, case .object(var split) = spools[1] {
            // A new record: none of the source's sync stamps are its own.
            split["rev"] = nil
            StoreWriter.stamp(&split)
            shelf.append(.object(split))
        }
        root["inventory"] = .array(shelf)
    }

    /// Move stock to another of the shop's locations; less than all of it
    /// splits the spool. Nil when written, else what went wrong.
    func transferStock(_ spoolId: String, to dest: String, qty: Double) async -> String? {
        guard permitted("inventory", "edit") else { return moveProblem }
        guard let build = source.build, StoreLock.weOwnIt(build) else { return words.callIt("mac.read_only") }
        guard let engine else { return words.callIt("mac.move_no_engine") }
        let words = self.words
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                try await Self.transferring(&root, spoolId: spoolId, dest: dest, qty: qty,
                                            engine: engine, words: words, newId: Self.uid("INV"))
            }
        } catch let refusal as MoveRefused {
            return refusal.sentence
        } catch {
            return self.said(error)
        }
        await load(source)
        spendNote = words.callIt("inv.transfer_done")
        return nil
    }

    /// One drying session taken off a spool's log. `driedAt` is left as it
    /// is, as the desktop's delete leaves it: a later drying is still the one
    /// the shelf counts from.
    func deleteDrying(_ spoolId: String, entryId: String) async -> String? {
        guard permitted("inventory", "edit") else { return moveProblem }
        guard let build = source.build, StoreLock.weOwnIt(build) else { return words.callIt("mac.read_only") }
        do {
            try await StoreWriter.updateOffMain(build) { root in
                var shelf = Self.rows(root, "inventory")
                guard let at = shelf.firstIndex(where: { Self.recordId($0) == spoolId }),
                      case .object(var record) = shelf[at],
                      case .array(let log)? = record["dryingLog"] else { return }
                let kept = log.filter { row in
                    guard case .object(let r) = row else { return true }
                    return Self.plainString(r["id"]) != entryId
                }
                guard kept.count != log.count else { return }
                record["dryingLog"] = .array(kept)
                StoreWriter.stamp(&record)
                shelf[at] = .object(record)
                root["inventory"] = .array(shelf)
            }
        } catch {
            return self.said(error)
        }
        await load(source)
        return nil
    }

    // MARK: - Settings the desktop keeps in sections of their own

    /// Write settings keys a section owns — not through `settings-edit.apply`,
    /// which preserves these and takes none from a form. `change` is asked of
    /// the settings ON DISK, so a key the other app moved meanwhile is read
    /// fresh, and it returns the settings to store.
    private func writeOwnSettings(
        _ change: @escaping @Sendable ([String: JSONValue], KhaytEngine) async throws -> [String: JSONValue]
    ) async {
        guard permitted("settings", "edit") else {
            settingsProblem = moveProblem; return
        }
        settingsProblem = nil
        settingsNote = nil
        guard let build = source.build else {
            settingsProblem = words.callIt("mac.settings_sample"); return
        }
        guard let engine else {
            settingsProblem = words.callIt("mac.move_no_engine"); return
        }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let next = try await change(Self.settings(root), engine)
                root["settings"] = .object(next)
            }
            await load(source)
            settingsNote = words.callIt("mac.settings_saved")
        } catch {
            settingsProblem = self.said(error)
        }
    }

    /// The invoice counter: prefix, next number and format, or `reset` for a
    /// new year's count from 1.
    func saveInvoiceNumbering(_ form: [String: JSONValue]) async {
        let year = Calendar.book.component(.year, from: Date())
        await writeOwnSettings { settings, engine in
            try await engine.invoiceNumbering(settings, form: form, year: year)
        }
    }

    /// The numbers missing from the book's invoice sequence.
    func invoiceNumberGaps() async -> [Int] {
        guard let engine else { return [] }
        return (try? await engine.invoiceNumberGaps(orderRows)) ?? []
    }

    /// Exchange rates as typed: `{ CODE: rate }`, a blank or zero taking the
    /// code off the table.
    func saveExchangeRates(_ edits: [String: Double?]) async {
        let base = currency
        let typed = edits.mapValues { $0.map(JSONValue.number) ?? .null }
        await writeOwnSettings { settings, engine in
            try await engine.exchangeRates(settings, edits: typed, base: base, fetchedAt: nil)
        }
    }

    /// Where the live rates come from — the desktop's main process asks the
    /// same free, keyless feed.
    nonisolated static func ratesURL(base: String) -> URL? {
        let code = String(base.uppercased().filter { $0.isASCII && $0.isLetter }.prefix(3))
        guard code.count == 3 else { return nil }
        return URL(string: "https://open.er-api.com/v6/latest/\(code)")
    }

    /// Fetch today's rates and store them for every currency Khayt knows.
    /// Nil when stored (and `settingsNote` says how many), else the reason.
    func fetchExchangeRates() async -> String? {
        let base = currency
        guard let url = Self.ratesURL(base: base) else { return words.callIt("xr.fetch_failed") }
        guard let engine else { return words.callIt("mac.move_no_engine") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: JSONValue
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            body = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            return words.callIt("xr.fetch_failed") + ": " + self.said(error)
        }
        let known = Invoice.currencyTable(self)
        guard let feed = try? await engine.ratesFromFeed(body, base: base, known: known) else {
            return words.callIt("xr.fetch_failed")
        }
        if let error = feed.error { return words.callIt("xr.fetch_failed") + ": " + error }
        let rates = (feed.rates ?? [:]).mapValues(JSONValue.number)
        let stamp = feed.updatedAt ?? StoreWriter.iso(Date())
        await writeOwnSettings { settings, engine in
            try await engine.exchangeRates(settings, edits: rates, base: base, fetchedAt: stamp)
        }
        if settingsProblem != nil { return settingsProblem }
        settingsNote = words.callIt("xr.fetched", ["n": .string(words.numeral(rates.count)), "base": .string(base)])
        return nil
    }

    /// The loyalty tiers, through the rule both apps save them with.
    func saveLoyaltyTiers(_ tiers: [[String: JSONValue]]) async {
        let rows = tiers.map(JSONValue.object)
        await writeOwnSettings { settings, engine in
            var out = settings
            out["loyaltyTiers"] = .array(try await engine.cleanLoyaltyTiers(rows))
            return out
        }
    }

    // MARK: - The month against its goal

    /// This month and last as book days, today's day of the month and the
    /// month's length — in the book's calendar, never the Mac's.
    nonisolated static func goalSpan(_ now: Date) -> (from: String, to: String,
                                                     lastFrom: String, lastTo: String,
                                                     day: Int, days: Int) {
        let cal = Calendar.book
        let y = cal.component(.year, from: now)
        let m = cal.component(.month, from: now)
        func day(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%04d-%02d-%02d", y, m, d) }
        func length(_ y: Int, _ m: Int) -> Int {
            guard let first = cal.date(from: DateComponents(year: y, month: m, day: 1)) else { return 30 }
            return cal.range(of: .day, in: .month, for: first)?.count ?? 30
        }
        let (ly, lm) = m == 1 ? (y - 1, 12) : (y, m - 1)
        return (day(y, m, 1), day(y, m, length(y, m)), day(ly, lm, 1), day(ly, lm, length(ly, lm)),
                cal.component(.day, from: now), length(y, m))
    }

    // MARK: - Waste against revenue

    /// The period the Waste screen shows, as revenue bounds: empty for All.
    func wasteRevenueSpan() -> (from: String, to: String) {
        if period == .all { return ("", "") }
        return Self.periodSpan(period, now: now)
    }

    /// The period's trade revenue, on the rule the goal bar reads.
    func tradeRevenue(from: String, to: String) async -> Double? {
        guard let engine else { return nil }
        return try? await engine.tradeRevenue(orders: orderRows, settings: settingsDict,
                                              clients: clientRows, currencies: Invoice.currencyTable(self),
                                              from: from, to: to)
    }
}
