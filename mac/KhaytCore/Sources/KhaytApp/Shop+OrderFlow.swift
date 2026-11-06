import Foundation
import KhaytCore

/// The desktop's order-flow settings and tools, on the Mac: the
/// post-processing checklist and its ticks, post-process presets, the shop's
/// own order fields, saved job filters, and importing a spreadsheet.
///
/// ── THE DESKTOP'S KEYS, AND NOTHING RE-ENCODED ───────────────────────────
///
/// `settings.postChecklist` `[{ id, label }]`, `settings.customFields`
/// `[{ id, label, type }]`, `settings.postProcessPresets` `[{ name, amount }]`
/// and `settings.savedFilters` `[{ id, name, status, pay, tag, range, search,
/// operator }]` are lists the desktop edits in place, one add or delete at a
/// time. This does the same, on the list read INSIDE the write chain: an add
/// appends one record, a delete removes the one record the shop pointed at,
/// and every other entry goes back exactly as the book had it — a field the
/// Mac does not know (a filter's `pay` or `tag`) is never rewritten.
extension Shop {

    // MARK: - Lists in settings

    /// The settings lists this file edits.
    enum SettingsList: String, CaseIterable, Sendable {
        case postChecklist, postProcessPresets, customFields, savedFilters
    }

    /// One add or delete.
    enum ListChange: Sendable, Equatable {
        case add([String: JSONValue])
        /// Remove the entry at `index` if it is still `record`; otherwise the
        /// first entry equal to `record`; otherwise nothing — the book moved
        /// and the entry the shop pointed at is already gone.
        case remove(index: Int, record: [String: JSONValue])
    }

    /// The list as the book holds it, objects only.
    func settingsList(_ list: SettingsList) -> [[String: JSONValue]] {
        Self.listEntries(settingsDict, list)
    }

    nonisolated static func listEntries(_ settings: [String: JSONValue],
                                        _ list: SettingsList) -> [[String: JSONValue]] {
        guard case .array(let rows)? = settings[list.rawValue] else { return [] }
        return rows.compactMap(asObject)
    }

    /// `settings` with one change made to one list. Entries that are not
    /// objects, and every entry not removed, are kept as they were.
    nonisolated static func changingList(_ settings: [String: JSONValue], _ list: SettingsList,
                                         _ change: ListChange) -> [String: JSONValue] {
        var out = settings
        var rows: [JSONValue] = []
        if case .array(let r)? = settings[list.rawValue] { rows = r }
        switch change {
        case .add(let record):
            rows.append(.object(record))
        case .remove(let index, let record):
            if rows.indices.contains(index), rows[index] == .object(record) {
                rows.remove(at: index)
            } else if let at = rows.firstIndex(of: .object(record)) {
                rows.remove(at: at)
            } else {
                return settings
            }
        }
        out[list.rawValue] = .array(rows)
        return out
    }

    /// Add to, or take from, one of the lists — straight to the book, as the
    /// desktop's buttons do.
    func editSettingsList(_ list: SettingsList, _ change: ListChange) async {
        await writeOwnSettings { settings, _ in
            Self.changingList(settings, list, change)
        }
    }

    /// A checklist step as the desktop adds one: `{ id: uid('PCH'), label }`.
    nonisolated static func newPostCheck(_ label: String) -> [String: JSONValue]? {
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return l.isEmpty ? nil : ["id": .string(uid("PCH")), "label": .string(l)]
    }

    /// A custom order field as the desktop adds one: `{ id: uid('CF'), label, type: 'text' }`.
    nonisolated static func newCustomField(_ label: String) -> [String: JSONValue]? {
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return l.isEmpty ? nil : ["id": .string(uid("CF")), "label": .string(l), "type": .string("text")]
    }

    /// A preset as the desktop adds one: `{ name, amount }`, the amount never
    /// below zero.
    nonisolated static func newPostPreset(_ name: String, amount: Double) -> [String: JSONValue]? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        return ["name": .string(n), "amount": .number(amount.isFinite ? max(0, amount) : 0)]
    }

    // MARK: - Ticking the checklist on a job

    /// The steps ticked on a job: `order.postChecks[stepId]`.
    nonisolated static func postChecks(_ order: [String: JSONValue]) -> [String: Bool] {
        guard case .object(let o)? = order["postChecks"] else { return [:] }
        var out: [String: Bool] = [:]
        for (k, v) in o { if case .bool(let b) = v { out[k] = b } }
        return out
    }

    /// The job with one step ticked or unticked — `postChecks` made if it is
    /// missing, and an unticked step kept as `false`, as the desktop's card
    /// writes it.
    nonisolated static func ticking(_ order: JSONValue, step: String, done: Bool) -> JSONValue {
        guard case .object(var o) = order else { return order }
        var checks: [String: JSONValue] = [:]
        if case .object(let c)? = o["postChecks"] { checks = c }
        checks[step] = .bool(done)
        o["postChecks"] = .object(checks)
        return .object(o)
    }

    @discardableResult
    func editPostCheck(_ id: Order.ID, step: String, done: Bool) async -> Bool {
        await writeToOneOrder(id, named: words.callIt("post.checklist"), as: .person("orders", "edit")) { order, _, _ in
            OneOrderEdit(order: Self.ticking(order, step: step, done: done))
        }
    }

    // MARK: - Saved job filters

    /// One saved filter. `raw` is the stored entry, untouched.
    struct SavedFilter: Identifiable, Equatable {
        let index: Int
        let raw: [String: JSONValue]
        var id: String { (Shop.plainString(raw["id"]) ?? "") + "#\(index)" }
        var name: String { Shop.plainString(raw["name"]) ?? "" }
        var status: String { Shop.plainString(raw["status"]) ?? "" }
        var search: String { Shop.plainString(raw["search"]) ?? "" }

        /// Whether it also narrows by something this Mac's list cannot — the
        /// desktop's payment, tag, date-range or operator filter. Those parts
        /// stay in the book for the desktop; here they are not applied.
        var narrowsMore: Bool {
            let pay = Shop.plainString(raw["pay"]) ?? ""
            let tag = Shop.plainString(raw["tag"]) ?? ""
            let range = Shop.plainString(raw["range"]) ?? "all"
            let op = Shop.plainString(raw["operator"]) ?? ""
            return !pay.isEmpty || !tag.isEmpty || !(range.isEmpty || range == "all") || !op.isEmpty
        }

        /// The stage the desktop's status filter means here. Unknown → every job.
        var stage: Stage? { status.isEmpty ? nil : Stage(rawValue: status) }
    }

    var savedFilters: [SavedFilter] {
        guard case .array(let rows)? = settingsDict["savedFilters"] else { return [] }
        return rows.enumerated().compactMap { i, row in
            Self.asObject(row).map { SavedFilter(index: i, raw: $0) }
        }
    }

    /// The desktop's status value for a stage on this Mac. Shipped and
    /// delivered are not statuses — they are stamps on a completed job, and
    /// the desktop's filter compares `status` — so they save as `completed`.
    nonisolated static func filterStatus(_ stage: Stage?) -> String {
        switch stage {
        case nil: ""
        case .shipped?, .delivered?: "completed"
        case let s?: s.rawValue
        }
    }

    /// A filter entry as the desktop saves one. The four filters this Mac has
    /// no control for are written as the desktop's "off" values.
    nonisolated static func newSavedFilter(name: String, stage: Stage?, search: String,
                                           now: Date = Date()) -> [String: JSONValue]? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        let ms = Int(now.timeIntervalSince1970 * 1000)
        return ["id": .string(String(ms, radix: 36)), "name": .string(n),
                "status": .string(filterStatus(stage)), "pay": .string(""), "tag": .string(""),
                "range": .string("all"), "search": .string(search), "operator": .string("")]
    }

    /// Save the list's stage and search under a name.
    func saveFilterPreset(name: String) async {
        guard let record = Self.newSavedFilter(name: name, stage: stage, search: search) else { return }
        await editSettingsList(.savedFilters, .add(record))
    }

    /// Put a saved filter on the jobs list: its stage and its search.
    func applyFilterPreset(_ filter: SavedFilter) {
        shelf = .jobs(filter.stage)
        search = filter.search
        // Said, not silently dropped: the list showing more than the desktop
        // would for the same filter is a difference the shop should know of.
        if filter.narrowsMore { moveNotices = [words.callIt("mac.filter_narrows_more")] }
    }

    // MARK: - Importing a spreadsheet

    /// What a spreadsheet can be imported as.
    enum CsvKind: String, CaseIterable, Identifiable, Sendable {
        case spools, clients, products
        var id: String { rawValue }
        var collection: String {
            switch self { case .spools: "inventory"; case .clients: "clients"; case .products: "products" }
        }
        var titleKey: String { "csv.import_" + rawValue }
    }

    /// The book's records of `kind`, for the preview.
    func csvExisting(_ kind: CsvKind) -> [JSONValue] {
        switch kind {
        case .spools: inventoryRows
        case .clients: clientRows
        case .products: productRows
        }
    }

    /// Fresh ids for `n` records of `kind`, in the desktop's `uid()` shape.
    nonisolated static func csvIds(_ kind: CsvKind, count n: Int) -> [String] {
        let prefix = switch kind { case .spools: "S"; case .clients: "CL"; case .products: "PROD" }
        var seen = Set<String>()
        var out: [String] = []
        while out.count < n {
            let id = uid(prefix)
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    /// Import the mapped rows. The duplicate tests run again INSIDE the write
    /// chain, against the book as it is on disk — a row the preview called new
    /// that somebody added meanwhile is skipped, not written twice.
    @discardableResult
    func saveCsvImport(_ kind: CsvKind, rows: [[String]], mapping: [String: Int]) async -> KhaytEngine.CsvPlan? {
        guard permitted(Self.lockArea(ofCollection: kind.collection), "edit") else { return nil }
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return nil }
        guard let engine else { moveProblem = words.callIt("mac.move_no_engine"); return nil }
        moveProblem = nil
        let today = Self.today()
        let ids = Self.csvIds(kind, count: rows.count)
        var made: KhaytEngine.CsvPlan?
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let existing = Self.rows(root, kind.collection)
                let plan = try await engine.csvPlan(kind: kind.rawValue, rows: rows, mapping: mapping,
                                                    existing: existing, today: today,
                                                    settings: Self.settings(root), ids: ids)
                let added: [JSONValue] = plan.add.map { record in
                    guard case .object(var o) = record else { return record }
                    StoreWriter.stamp(&o)
                    return .object(o)
                }
                if !added.isEmpty { root[kind.collection] = .array(existing + added) }
                made = plan
            }
            await load(source)
            return made
        } catch {
            moveProblem = self.said(error)
            return nil
        }
    }
}
