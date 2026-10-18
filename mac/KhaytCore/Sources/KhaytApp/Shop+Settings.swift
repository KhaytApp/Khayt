import Foundation
import UniformTypeIdentifiers
import AppKit
import Observation
import KhaytCore

extension Shop {

    // MARK: - The shop's sites

    /// The shop's locations, in the book's order — the order the other app
    /// lists them in, and the order a shop added them in.
    var locations: [ShopLocation] { locationRows.compactMap(ShopLocation.init(row:)) }

    /// A location's name, or nil for an id that names none (empty, or one
    /// deleted before deletes cleared what pointed at it).
    func locationName(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return locations.first { $0.id == id }?.name
    }

    /// Add a location, or rename one / change its address.
    ///
    /// Through the write chain like every other record, stamped so the other
    /// app's merge sees the change. An edit writes the two fields the sheet
    /// shows and nothing else, so whatever else a record carries survives.
    /// The id is `LOC-…` from the same `uid` the other app uses.
    func saveLocation(id: String?, name: String, address: String) async {
        moveProblem = nil
        guard permitted("settings", "edit") else { return }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { moveProblem = words.callIt("mach.need_name"); return }
        do {
            let (there, undo) = try await StoreWriter.updateOffMain(build) { root in
                var undo: [ChangedRecord] = []
                let there = Self.writeLocation(into: &root, id: id, name: name, address: address,
                                               newId: Self.uid("LOC"), undo: &undo)
                Self.sealUndo(&undo, in: root)
                return (there, undo)
            }
            if !there { moveProblem = words.callIt("mac.record_gone") }
            if !undo.isEmpty { registerMoveUndo(undo, named: words.callIt("set.locations")) }
            await load(source)
        } catch {
            moveProblem = self.said(error)
        }
    }

    /// The write itself, static and taking `root` so a test can drive it
    /// against a plain book.
    ///
    /// Returns false, and writes nothing, when `id` names a location that is
    /// no longer in the book — deleted by the other app or a sync while the
    /// sheet was open. Saving it as new would bring it back under another id,
    /// with none of what pointed at it.
    @discardableResult
    nonisolated static func writeLocation(into root: inout [String: JSONValue], id: String?, name: String,
                              address: String, newId: String, undo: inout [ChangedRecord]) -> Bool {
        var rows = Self.rows(root, "locations")
        if let id, !rows.contains(where: { Self.recordId($0) == id }) { return false }
        if let id, let at = rows.firstIndex(where: { Self.recordId($0) == id }),
           case .object(var record) = rows[at] {
            undo.append(ChangedRecord(collection: "locations", id: id, was: record))
            record["name"] = .string(name)
            record["address"] = .string(address)
            StoreWriter.stamp(&record)
            rows[at] = .object(record)
        } else {
            var record: [String: JSONValue] = [
                "id": .string(newId), "name": .string(name), "address": .string(address),
            ]
            StoreWriter.stamp(&record)
            rows.append(.object(record))
        }
        root["locations"] = .array(rows)
        return true
    }

    /// Take a location off the list, and unpoint everything that named it.
    ///
    /// The other app's delete dropped the row alone, so its machines, spools,
    /// expenses and jobs kept an id naming nothing — and the location P&L drew
    /// that id as a branch called `LOC-…`. Both apps now clear them, to the
    /// empty string `lib/machine-edit.js` and `lib/expense-book.js` write for
    /// "none", and an undo puts the row back and points them at it again.
    func deleteLocation(_ id: String) async {
        moveProblem = nil
        guard permitted("settings", "edit") else { return }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        // On the stack at the click, against the write below (`PendingUndo`).
        let pending: PendingUndo<([String: JSONValue], [ChangedRecord])> =
            pendingUndo(named: words.callIt("set.locations")) { shop, gone in
                shop.putBackLocation(gone.0, relinking: gone.1, in: build)
            }
        defer { pending.drop() }
        do {
            let (removed, unlinked) = try await StoreWriter.updateOffMain(build) { root
                -> ([String: JSONValue]?, [ChangedRecord]) in
                var rows = Self.rows(root, "locations")
                guard let at = rows.firstIndex(where: { Self.recordId($0) == id }),
                      case .object(let was) = rows[at] else { return (nil, []) }
                rows.remove(at: at)
                root["locations"] = .array(rows)
                return (was, Self.unpointingLocation(&root, from: id))
            }
            if let removed { pending.keep((removed, unlinked)) }
            await load(source)
        } catch {
            moveProblem = self.said(error)
        }
    }

    /// Which collections carry a `locationId`. `lib/location-pl.js` POINTERS
    /// is the same list, and `LocationsTests` holds the two together — a third
    /// collection growing the field on one side is how a delete quietly starts
    /// leaving ids behind again.
    nonisolated static let pointAtLocations = ["machines", "inventory", "expenses", "printLog"]

    /// Clear every `locationId` that names this location; say what changed.
    nonisolated static func unpointingLocation(_ root: inout [String: JSONValue],
                                   from id: String) -> [ChangedRecord] {
        var changed: [ChangedRecord] = []
        for collection in pointAtLocations {
            var records = rows(root, collection)
            var touched = false
            for i in records.indices {
                guard case .object(var record) = records[i],
                      plainString(record["locationId"]) == id else { continue }
                changed.append(ChangedRecord(collection: collection,
                                             id: recordId(records[i]) ?? "", was: record))
                record["locationId"] = .string("")
                StoreWriter.stamp(&record)
                records[i] = .object(record)
                touched = true
            }
            if touched { root[collection] = .array(records) }
        }
        return changed
    }

    /// Put a deleted location back, and point back at it what pointed at it.
    /// Only a record still unassigned is relinked: one moved to another site
    /// since is the shop's newer word.
    nonisolated static func relinkingLocation(_ root: inout [String: JSONValue], record: [String: JSONValue],
                                  id: String, unlinked: [ChangedRecord]) {
        var rows = Self.rows(root, "locations")
        guard !rows.contains(where: { Self.recordId($0) == id }) else { return }
        rows.append(.object(record))
        root["locations"] = .array(rows)
        for (collection, wanted) in Dictionary(grouping: unlinked, by: { $0.collection }) {
            var records = Self.rows(root, collection)
            let ids = Set(wanted.map { $0.id })
            var touched = false
            for i in records.indices {
                guard case .object(var r) = records[i],
                      let rid = Self.recordId(records[i]), ids.contains(rid),
                      (Self.plainString(r["locationId"]) ?? "").isEmpty else { continue }
                r["locationId"] = .string(id)
                StoreWriter.stamp(&r)
                records[i] = .object(r)
                touched = true
            }
            if touched { root[collection] = .array(records) }
        }
    }

    private func putBackLocation(_ record: [String: JSONValue],
                                      relinking unlinked: [ChangedRecord], in build: StoreReader.Build) {
        guard permitted("settings", "edit"),
              case .string(let id)? = record["id"] else { return }

        let shop = self
        // Written on the chain; the undo itself returns at once.
        Task {
            do {
                try await StoreWriter.updateOffMain(build) { root in
                    Self.relinkingLocation(&root, record: record, id: id, unlinked: unlinked)
                }
                await shop.load(shop.source)
            } catch {
                shop.moveProblem = self.said(error)
            }
        }
    }

    // MARK: - The staff

    /// The shop's operators, in the book's order — the order the other app
    /// lists them in.
    var operators: [ShopOperator] { operatorRows.compactMap(ShopOperator.init(row:)) }

    /// The ones a job or a time entry can be given to now.
    var activeOperators: [ShopOperator] { operators.filter(\.active) }

    func shopOperator(_ id: String?) -> ShopOperator? {
        guard let id, !id.isEmpty else { return nil }
        return operators.first { $0.id == id }
    }

    /// What a job's operator is called on screen: the name, marked when they
    /// are inactive, or "no longer on the list" for an id that names nobody.
    /// Nil for a job nobody was put on.
    func operatorLabel(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        guard let op = shopOperator(id) else {
            // Gone from the list — but a time entry froze their name when the
            // hours were logged, so say who it was. "An operator no longer on
            // the list" in the picker beside an entry that names them read as
            // two different answers about one job.
            let named = timeEntryRows.lazy.compactMap(Self.asObject)
                .first { Self.plainString($0["operatorId"]) == id }
                .flatMap { Self.plainString($0["operatorName"]) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            return named.isEmpty ? words.callIt("an.op_removed")
                                 : named + " · " + words.callIt("mac.op_gone")
        }
        return op.active ? op.name : op.name + " · " + words.callIt("op.inactive")
    }

    /// The hours logged against one job, newest first.
    func timeEntries(for jobId: String) -> [TimeEntry] {
        timeEntryRows.compactMap(TimeEntry.init(row:))
            .filter { $0.orderId == jobId }
            .sorted { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }
    }

    /// Add an operator, or change one.
    ///
    /// The fields the other app's editor writes — name, role, access level,
    /// hourly rate, active — and of those only the ones the shop CHANGED from
    /// what the sheet opened with (`opened`): saving an old record untouched
    /// must not stamp an access level on it that nobody chose. `pinHash` and
    /// anything this app does not know stay exactly as they were. The id is
    /// `OP-…` from the same `uid` the other app uses.
    func saveOperator(id: String?, _ fields: ShopOperator.Fields, opened: ShopOperator.Fields?) async {
        moveProblem = nil
        guard permitted("security", "edit") else { return }
        // Before anything else can answer: whether the change is allowed at
        // all is the first question, not one a read-only book gets to skip.
        if let id {
            let level = await lockLevelAfterSave(id, fields, opened: opened)
            if leavesNoOwner(id, stillOwner: fields.active && level == "owner") {
                moveProblem = words.callIt("mac.lock_last_owner"); return
            }
        }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        guard !fields.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            moveProblem = words.callIt("mach.need_name"); return
        }
        do {
            let (there, undo) = try await StoreWriter.updateOffMain(build) { root in
                var undo: [ChangedRecord] = []
                let there = Self.writeOperator(into: &root, id: id, fields, opened: opened,
                                               newId: Self.uid("OP"), undo: &undo)
                Self.sealUndo(&undo, in: root)
                return (there, undo)
            }
            if !there { moveProblem = words.callIt("mac.record_gone") }
            if !undo.isEmpty { registerMoveUndo(undo, named: words.callIt("op.title")) }
            await load(source)
        } catch {
            moveProblem = self.said(error)
        }
    }

    /// The write itself, static and taking `root` so a test can drive it
    /// against a plain book.
    ///
    /// Returns false, and writes nothing, when `id` names someone no longer
    /// in the book; see `writeLocation`. Re-created under a new id, their jobs
    /// and logged time would point at the old one.
    @discardableResult
    nonisolated static func writeOperator(into root: inout [String: JSONValue], id: String?,
                              _ fields: ShopOperator.Fields, opened: ShopOperator.Fields?,
                              newId: String, undo: inout [ChangedRecord]) -> Bool {
        var rows = Self.rows(root, "operators")
        if let id, !rows.contains(where: { Self.recordId($0) == id }) { return false }
        func cleaned(_ f: ShopOperator.Fields) -> [String: JSONValue] {
            [
                "name": .string(f.name.trimmingCharacters(in: .whitespacesAndNewlines)),
                "role": .string(f.role.trimmingCharacters(in: .whitespacesAndNewlines)),
                "roleKey": .string(ShopOperator.roles.contains(f.roleKey) ? f.roleKey : "operator"),
                "hourlyRate": .number(f.hourlyRate.isFinite ? max(0, f.hourlyRate) : 0),
                "active": .bool(f.active),
            ]
        }
        let shown = cleaned(fields)
        if let id, let at = rows.firstIndex(where: { Self.recordId($0) == id }),
           case .object(var record) = rows[at] {
            let was = record
            let before = opened.map(cleaned)
            for (key, value) in shown where before?[key] != value { record[key] = value }
            guard record != was else { return true }
            StoreWriter.stamp(&record)
            undo.append(ChangedRecord(collection: "operators", id: id, was: was))
            rows[at] = .object(record)
        } else {
            var record = shown
            record["id"] = .string(newId)
            StoreWriter.stamp(&record)
            rows.append(.object(record))
            undo.append(ChangedRecord(collection: "operators", id: newId, was: [:], kind: .created))
        }
        root["operators"] = .array(rows)
        return true
    }

    /// Delete an operator — or, when their name is on work, make them
    /// inactive. `lib/operators.js` `remove` decides, the rule the other app's
    /// delete now runs too: who did a job is history, so it is not cleared
    /// the way a deleted location is. Returns what happened, for the caller
    /// to say.
    @discardableResult
    func deleteOperator(_ id: String) async -> String? {
        moveProblem = nil
        guard permitted("security", "edit") else { return nil }
        // Removed OR made inactive, they are no longer an owner who can sign in.
        if leavesNoOwner(id, stillOwner: false) {
            moveProblem = words.callIt("mac.lock_last_owner"); return nil
        }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return nil
        }
        guard let engine else {
            moveProblem = words.callIt("mac.move_no_engine"); return nil
        }
        var undo: [ChangedRecord] = []
        var outcome: String?
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let before = Self.rows(root, "operators")
                let book: [String: JSONValue] = [
                    "operators": .array(before),
                    "printLog": .array(Self.rows(root, "printLog")),
                    "timeEntries": .array(Self.rows(root, "timeEntries")),
                ]
                let out = try await engine.removeOperator(book: book, id: id)
                outcome = out.outcome
                undo = Self.operatorRemoval(&root, before: before, after: out.operators, id: id)
            }
            if !undo.isEmpty { registerMoveUndo(undo, named: words.callIt("op.title")) }
            await load(source)
        } catch {
            moveProblem = self.said(error)
        }
        return outcome
    }

    /// Write the rule's answer: the row gone, or the row made inactive and
    /// stamped. What changed goes on the undo.
    static func operatorRemoval(_ root: inout [String: JSONValue], before: [JSONValue],
                                after: [JSONValue], id: String) -> [ChangedRecord] {
        guard let at = before.firstIndex(where: { recordId($0) == id }),
              case .object(let was) = before[at] else { return [] }
        if let kept = after.first(where: { recordId($0) == id }), case .object(var now) = kept {
            guard now != was else { return [] }
            StoreWriter.stamp(&now)
            var rows = before
            rows[at] = .object(now)
            root["operators"] = .array(rows)
            return [ChangedRecord(collection: "operators", id: id, was: was, now: now)]
        }
        var rows = before
        rows.remove(at: at)
        root["operators"] = .array(rows)
        return [ChangedRecord(collection: "operators", id: id, was: was, kind: .deleted, at: at)]
    }

    /// Put a job on an operator, or on nobody.
    ///
    /// The other app's editor writes `operatorId` and removes it for nobody;
    /// so does this.
    func setJobOperator(_ jobId: Order.ID, _ operatorId: String?) async {
        await writeToOneOrder(jobId, named: words.callIt("op.assigned"), as: .person("orders", "edit")) { order, _, _ in
            OneOrderEdit(order: Self.withOperator(order, operatorId))
        }
    }

    static func withOperator(_ order: JSONValue, _ operatorId: String?) -> JSONValue {
        guard case .object(var o) = order else { return order }
        if let operatorId, !operatorId.isEmpty { o["operatorId"] = .string(operatorId) }
        else { o.removeValue(forKey: "operatorId") }
        return .object(o)
    }

    /// Log time an operator spent on a job.
    ///
    /// The other app's shape exactly, with the rate and the cost FROZEN at the
    /// operator's rate today: a raise next year does not reprice this work.
    func logTime(jobId: String, operatorId: String, hours: Double, day: String, notes: String) async {
        moveProblem = nil
        guard permitted("logs", "create") else { return }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        guard hours.isFinite, hours > 0 else {
            moveProblem = words.callIt("shift.hours_positive"); return
        }
        do {
            let undo = try await StoreWriter.updateOffMain(build) { root in
                var undo: [ChangedRecord] = []
                Self.writeTimeEntry(into: &root, id: Self.uid("TE"), jobId: jobId,
                                    operatorId: operatorId, hours: hours, day: day, notes: notes,
                                    at: StoreWriter.iso(Date()), undo: &undo)
                Self.sealUndo(&undo, in: root)
                return undo
            }
            if !undo.isEmpty { registerMoveUndo(undo, named: words.callIt("time.log_title")) }
            await load(source)
        } catch {
            moveProblem = self.said(error)
        }
    }

    nonisolated static func writeTimeEntry(into root: inout [String: JSONValue], id: String, jobId: String,
                               operatorId: String, hours: Double, day: String, notes: String,
                               at: String, undo: inout [ChangedRecord]) {
        let op = rows(root, "operators").first { recordId($0) == operatorId }
            .flatMap(ShopOperator.init(row:))
        let rate = op?.hourlyRate ?? 0
        var record: [String: JSONValue] = [
            "id": .string(id),
            "orderId": jobId.isEmpty ? .null : .string(jobId),
            "operatorId": .string(operatorId),
            "operatorName": .string(op?.name ?? ""),
            "hours": .number(hours),
            "hourlyRate": .number(rate),
            "cost": .number(hours * rate),
            "date": .string(day),
            "notes": .string(notes.trimmingCharacters(in: .whitespacesAndNewlines)),
            "createdAt": .string(at),
        ]
        StoreWriter.stamp(&record)
        var entries = rows(root, "timeEntries")
        entries.append(.object(record))
        root["timeEntries"] = .array(entries)
        undo.append(ChangedRecord(collection: "timeEntries", id: id, was: [:], kind: .created))
    }

    /// Take a time entry off. Undo puts it back where it was.
    func deleteTimeEntry(_ id: String) async {
        moveProblem = nil
        guard permitted("logs", "delete") else { return }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        do {
            let undo = try await StoreWriter.updateOffMain(build) { root -> [ChangedRecord] in
                var entries = Self.rows(root, "timeEntries")
                guard let at = entries.firstIndex(where: { Self.recordId($0) == id }),
                      case .object(let was) = entries[at] else { return [] }
                entries.remove(at: at)
                root["timeEntries"] = .array(entries)
                return [ChangedRecord(collection: "timeEntries", id: id, was: was, kind: .deleted, at: at)]
            }
            if !undo.isEmpty { registerMoveUndo(undo, named: words.callIt("time.log_title")) }
            await load(source)
        } catch {
            moveProblem = self.said(error)
        }
    }

    // MARK: - The shop's slicers

    /// Read them when the book loads. Two crossings, once, rather than one per
    /// model in a context menu that is built while a grid of four hundred draws.
    func readSlicers() async {
        guard let engine else { slicers = []; defaultSlicer = nil; return }
        let ticket = loadGeneration
        let listed = (try? await engine.slicers(settings: settingsDict)) ?? []
        let chosen = try? await engine.defaultSlicer(settings: settingsDict)
        // Not over a newer load's answer (`Shop.load`).
        guard ticket == loadGeneration else { return }
        slicers = listed
        defaultSlicer = chosen
    }

    /// Every slicer this Mac has installed, whether or not the shop has added it.
    ///
    /// Asks the shared rule twice — once for whether a bundle may be launched at
    /// all, once for what to call it — so a slicer Khayt would offer and one
    /// this app offers are the same slicer under the same name.
    func installedSlicers() async -> [(name: String, path: String)] {
        guard let engine else { return [] }
        // The two crossings are hoisted out of the walk: a JSContext call per
        // entry in /Applications would be a hundred of them to list four.
        var allowedCache: [String: Bool] = [:]
        var nameCache: [String: String] = [:]
        let entries = SlicerFinder.searched.flatMap {
            (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []
        }
        for entry in entries where entry.lowercased().hasSuffix(".app") {
            allowedCache[entry] = (try? await engine.mayLaunchAsSlicer(path: entry)) ?? false
            if allowedCache[entry] == true {
                nameCache[entry] = (try? await engine.slicerDisplayName(path: entry)) ?? entry
            }
        }
        return SlicerFinder.installed(allowed: { allowedCache[$0] ?? false },
                                      name: { nameCache[$0] ?? $0 })
    }

    /// Write the shop's slicer list and which of them is the default.
    ///
    /// NOT through `settings-edit`. That rule maps FORM FIELDS onto settings
    /// keys and keeps every key a form does not carry — which is exactly what
    /// makes a pane safe, and exactly why a list cannot go through it: it has no
    /// form field, so it would be kept rather than replaced, and Save would do
    /// nothing at all. Two named keys, written explicitly, is the same
    /// narrowness by another route.
    /// The settings keys the slicer list is written as.
    ///
    /// The legacy single slicer is kept in step. `lib/slicers.js` says it is
    /// mirrored to the default "so existing consumers keep working unchanged"
    /// — the kanban print, machine slice-and-print and the quote slice all
    /// still read it, in the app next to this one.
    nonisolated static func slicerFields(_ list: [KhaytEngine.Slicer], defaultId: String) -> [String: JSONValue] {
        var out: [String: JSONValue] = [
            "slicers": .array(list.map { slicer in
                .object(["id": .string(slicer.id), "name": .string(slicer.name),
                         "path": .string(slicer.path), "args": .string(slicer.args)])
            }),
            "defaultSlicerId": .string(defaultId),
        ]
        if let chosen = list.first(where: { $0.id == defaultId }) ?? list.first {
            out["slicer"] = .object(["path": .string(chosen.path), "args": .string(chosen.args)])
        }
        return out
    }

    /// Settings keys an editor rewrites, laid over `settings` keeping what it
    /// did not change as the book spells it (`RoundTrip`). A slicer the other
    /// app stored with a field of its own keeps it; so does a saved report.
    nonisolated static func settingsKeys(_ written: [String: JSONValue], opened: [String: JSONValue]?,
                             over settings: [String: JSONValue]) -> [String: JSONValue] {
        var out = settings
        var keys = written
        if let opened {
            let stored = settings.filter { written[$0.key] != nil || opened[$0.key] != nil }
            keys = RoundTrip.keepUntouched(written: written, baseline: opened, stored: stored)
        }
        for key in written.keys { out[key] = keys[key] }
        return out
    }

    /// `opened` is the list as the pane opened it.
    func saveSlicers(_ list: [KhaytEngine.Slicer], defaultId: String,
                     opened: (list: [KhaytEngine.Slicer], defaultId: String)?) async {
        guard permitted("settings", "edit") else { return }
        settingsProblem = nil
        settingsNote = nil
        guard let build = source.build else {
            settingsProblem = words.callIt("mac.settings_sample"); return
        }
        do {
            try await StoreWriter.updateOffMain(build) { root in
                let settings = Self.settingsKeys(
                    Self.slicerFields(list, defaultId: defaultId),
                    opened: opened.map { Self.slicerFields($0.list, defaultId: $0.defaultId) },
                    over: Self.settings(root))
                root["settings"] = .object(settings)
            }
            await load(source)
            settingsNote = words.callIt("mac.settings_saved")
        } catch {
            settingsProblem = self.said(error)
        }
    }

    /// Whether the shop can take another job, and when it would start.
    ///
    /// SEVEN DAYS, the same window the other app uses. The load is not clamped
    /// at 100 — a machine three weeks behind is a different answer from one
    /// exactly full, and that difference is the whole point of the card.
    func capacity() async -> KhaytEngine.Capacity? {
        guard let engine else { return nil }
        return try? await engine.capacity(
            machines: machineRows, orders: orderRows, days: 7,
            unassigned: words.callIt("dash.unassigned"))
    }

    /// Which machine scraps the most of what it prints.
    ///
    /// The whole book, no window. A scrap rate over one month of a small shop
    /// is two or three failures, which is not a rate — and the question this
    /// answers, whether a machine is worth keeping, is not a monthly one.
    func machineReliability() async -> KhaytEngine.MachineReliability? {
        guard let engine else { return nil }
        return try? await engine.machineReliability(
            machines: machineRows, orders: orderRows, waste: wasteRows,
            from: "", to: "", unassigned: words.callIt("dash.unassigned"))
    }

    /// What the shelf costs, and whether that has moved.
    ///
    /// The RAW inventory rows: `materialCost` reads `spoolWeight` and the unit,
    /// and `Spool` carries neither — re-encoding the decoded shelf would price
    /// every sheet good as if it were filament.
    func materialCost() async -> KhaytEngine.MaterialCost? {
        guard let engine else { return nil }
        return try? await engine.materialCost(inventory: inventoryRows, minimum: 2)
    }

    /// What the shop has PAID for a material, from the supplier purchase log.
    ///
    /// ── WHY THIS IS NOT THE CARD ABOVE ────────────────────────────────────
    ///
    /// `materialCost` reads the SHELF: what the spools on it cost, which is
    /// what the shop owns. This reads the LOG: what was actually paid, when,
    /// and to whom — which is what a shop takes to a supplier when it asks for
    /// a better rate. A shop with no purchases logged has the first and not
    /// the second, which is why this returns an empty list rather than a card
    /// full of dashes.
    ///
    /// Grouped by material AND unit family by the rule, and this app never
    /// flattens that: a spool of PLA and a kilogram of PLA are two answers.
    func supplierPrices() async -> [KhaytEngine.PriceGroup] {
        guard let engine, !supplierRows.isEmpty else { return [] }
        return (try? await engine.supplierPriceGroups(
            supplierRows, untagged: words.callIt("sup.untagged"))) ?? []
    }

    /// Keep the shop's saved reports.
    ///
    /// The same narrowness as `saveSlicers` and for the same reason: one named
    /// key, written explicitly, rather than through `settings-edit` — which
    /// keeps every key no form field carries, so a list would be kept rather
    /// than replaced and Save would do nothing.
    ///
    /// The LIST is computed by `lib/saved-reports.js` before it gets here. This
    /// only writes it, so the rule about what a re-save under one name does
    /// lives in one place and both apps obey it.
    /// The saved reports, as settings holds them.
    nonisolated static func reportFields(_ list: [KhaytEngine.SavedReport]) -> [String: JSONValue] {
        ["savedReports": .array(list.map { r in
            .object(["id": .string(r.id), "name": .string(r.name),
                     "fields": .array(r.fields.map { .string($0) }),
                     "statusIn": .array(r.statusIn.map { .string($0) }),
                     "from": .string(r.from), "to": .string(r.to)])
        })]
    }

    /// `opened` is the list before this change.
    func saveReports(_ list: [KhaytEngine.SavedReport], opened: [KhaytEngine.SavedReport]?) async {
        guard permitted("settings", "edit") else { return }
        settingsProblem = nil
        settingsNote = nil
        guard let build = source.build else {
            settingsProblem = words.callIt("mac.settings_sample"); return
        }
        do {
            try await StoreWriter.updateOffMain(build) { root in
                let settings = Self.settingsKeys(Self.reportFields(list),
                                                 opened: opened.map(Self.reportFields),
                                                 over: Self.settings(root))
                root["settings"] = .object(settings)
            }
            await load(source)
        } catch {
            settingsProblem = self.said(error)
        }
    }

    /// Open a model in a named slicer.
    func openInSlicer(_ url: URL, slicer: KhaytEngine.Slicer) async {
        clearLastOutcome()
        guard let engine else { return }
        let allowed = (try? await engine.mayLaunchAsSlicer(path: slicer.path)) ?? false
        let refusal = FileActions.openInSlicer(url, slicerPath: slicer.path) { _ in allowed }
        switch refusal {
        case nil: return
        case "notAllowed":
            // Named as a refusal rather than a failure. A shop whose settings
            // arrived from somewhere else deserves to know this was a decision.
            slicerProblem = words.callIt("mac.slicer_not_allowed", ["name": .string(slicer.name)])
        default:
            slicerProblem = words.callIt("mac.slicer_missing", ["name": .string(slicer.name)])
        }
    }

    // MARK: - The first-run setup

    /// Is there a real book on this Mac at all?
    var aRealBookExists: Bool { Self.available.contains(where: \.isReal) }

    /// Can the setup do anything from here? On the shop's own writable book,
    /// or on a Mac with no book yet — where Finish starts one. Not on the
    /// sample while a real book exists: that is somebody looking around, and
    /// the answers belong in the book they are not looking at.
    var canRunSetup: Bool {
        source.isReal ? canWrite : !aRealBookExists
    }

    /// Where the shop's answer to "not now" is kept.
    ///
    /// ── IN THIS MAC'S DEFAULTS, NOT IN THE BOOK ───────────────────────────
    ///
    /// Two reasons. Skipping must write NOTHING to the book: it is shared with
    /// the other app and synced, and a flag written on a dismissal is a change
    /// and a stamp for nothing. And the book's own `settings.firstRunDone` is
    /// the other app's WIZARD flag — setting it from a Mac "Skip" would
    /// silently cancel an onboarding the shop has not seen. Once the book has
    /// a machine or a job the setup stops offering itself anyway, so this only
    /// has to remember the empty case. Keyed by the book's path (lower-cased:
    /// `khayt` and `Khayt` are one folder on a default Mac), or by "no book".
    static func setupKey(for build: StoreReader.Build?) -> String {
        "setup.dismissed." + (build.map { $0.storeURL.path.lowercased() } ?? "no-book")
    }

    var setupDismissed: Bool {
        UserDefaults.standard.bool(forKey: Self.setupKey(for: source.build))
    }

    func rememberSetupDismissed() {
        UserDefaults.standard.set(true, forKey: Self.setupKey(for: source.build))
    }

    /// Open the setup by itself, once, when the book calls for it. Called by
    /// the window after the first load — never by `load`, so tests and the
    /// snapshot runner, which load books all day, are never interrupted.
    func offerSetupIfNew() {
        guard ProcessInfo.processInfo.environment["KHAYT_SNAPSHOT_DIR"] == nil,
              !setupDismissed,
              ShopSetup.offers(isReal: source.isReal, canWrite: canWrite,
                               machines: machines.count, orders: orders.count,
                               aRealBookExists: aRealBookExists)
        else { return }
        settingUpShop = true
    }

    /// "Try the sample shop instead": nothing written, and not asked again.
    func setupChoseSample() async {
        rememberSetupDismissed()
        settingUpShop = false
        if source.isReal { await load(.sample) }
    }

    /// Closed or skipped without an answer: nothing written, not asked again.
    func setupSkipped() {
        rememberSetupDismissed()
        settingUpShop = false
    }

    /// Write what the setup was told, through the seams the sheets use, in
    /// one write. Nothing at all when nothing was answered.
    ///
    /// On a Mac with no book this is where the shop's book is STARTED — the
    /// sheet's first step says so on the button, so nobody gets a book they
    /// did not ask for.
    @discardableResult
    func finishSetup(_ setup: ShopSetup) async -> Bool {
        guard permitted("settings", "edit") else { return false }
        setupProblem = nil
        let held = ShopSetup.settingsReading(settingsDict)
        guard setup.writesAnything(currentCurrency: held.currency, currentlyChargesVat: held.chargesVat,
                                   currentVatRate: held.vatRate) else {
            setupSkipped()
            return true
        }
        if !source.isReal {
            guard !aRealBookExists else {
                setupProblem = words.callIt("mac.move_sample"); return false
            }
            do {
                try Self.startEmptyBook(at: StoreReader.Build.shipped.storeURL)
            } catch {
                setupProblem = words.setupFailure(error, startingBook: true); return false
            }
            await load(.store(.shipped))
        }
        guard let build = source.build, canWrite else {
            setupProblem = words.callIt("mac.move_sample"); return false
        }
        guard let engine else {
            setupProblem = words.callIt("mac.move_no_engine"); return false
        }
        let presetName = words.callIt("mac.setup_preset_name")
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                try await ShopSetup.apply(setup, to: &root, engine: engine, presetName: presetName)
            }
        } catch {
            setupProblem = words.setupFailure(error, startingBook: false)
            return false
        }
        rememberSetupDismissed()
        settingUpShop = false
        await load(source)
        spendNote = words.callIt("mac.setup_saved")
        return true
    }

    /// A new, empty book where there is none.
    ///
    /// REFUSES if anything is already there — including the `.prev` an
    /// interrupted save leaves, which `StoreReader` puts back on open. Starting
    /// a book over a shop's real one would be the worst thing this app could
    /// do, so the check is here, at the only place that creates one, and not in
    /// the caller. The book is `{}`: every collection is absent, which both
    /// apps read as empty, and the other app merges its default settings over
    /// whatever `settings` is there.
    ///
    /// AND THE REFUSAL IS ATOMIC. The first version checked `fileExists` and
    /// then wrote with `StoreWriter.atomicWrite`, whose rename(2) REPLACES
    /// whatever is at the path — so a book that appeared between the check and
    /// the write (the other app's first save, a restore, a sync) was replaced
    /// by `{}`. Now the empty book is written to a temporary file and moved in
    /// with `renamex_np(RENAME_EXCL)`, which the kernel refuses with EEXIST if
    /// anything is there by then; where the volume does not support that, a
    /// hard link, which refuses the same way. Created 0600: a book is the
    /// shop's customers and prices, and nobody else on this Mac needs it.
    /// The `.prev` check stays a check — `.prev` is never written by this.
    static func startEmptyBook(at url: URL) throws {
        let fm = FileManager.default
        let prev = url.appendingPathExtension("prev")
        guard !fm.fileExists(atPath: url.path), !fm.fileExists(atPath: prev.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createNew(Data("{}".utf8), at: url)
    }

    /// Write `body` to `url` only if nothing is there, decided by the kernel at
    /// the moment the file appears — never a check followed by a write. Mode
    /// 0600. Throws `fileWriteFileExists` when something is there.
    static func createNew(_ body: Data, at url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appending(path: ".\(url.lastPathComponent).creating.\(UUID().uuidString)")
        let fd = Darwin.open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.unlink(tmp.path) }
        let wrote = body.withUnsafeBytes { bytes -> Bool in
            var at = 0
            while at < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress! + at, bytes.count - at)
                if n < 0 { if errno == EINTR { continue }; return false }
                at += n
            }
            return true
        }
        let synced = Darwin.fsync(fd)
        Darwin.close(fd)
        guard wrote, synced == 0 else { throw POSIXError(.EIO) }
        if Darwin.renamex_np(tmp.path, url.path, UInt32(RENAME_EXCL)) == 0 { return }
        let failed = errno
        if failed == EEXIST { throw CocoaError(.fileWriteFileExists) }
        guard failed == ENOTSUP || failed == EINVAL else {
            throw POSIXError(POSIXErrorCode(rawValue: failed) ?? .EIO)
        }
        // No RENAME_EXCL on this volume: link(2) never replaces either.
        guard Darwin.link(tmp.path, url.path) == 0 else {
            if errno == EEXIST { throw CocoaError(.fileWriteFileExists) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // MARK: - The shop's own settings

    func readSettingsTables(_ root: [String: JSONValue]) async {
        guard let engine else { return }
        let settings = Self.settings(root)
        let ticket = loadGeneration
        let table = (try? await engine.currencies()) ?? [:]
        let presets = (try? await engine.taxPresets()) ?? [:]
        let profile = try? await engine.taxProfile(settings: settings)
        let languages = (try? await engine.contentLanguages(settings: settings)) ?? ["en", "ar"]
        // Together, and not over a newer load's answer (`Shop.load`).
        guard ticket == loadGeneration else { return }
        currencies = table
        taxPresets = presets
        taxProfile = profile
        contentLanguages = languages
    }

    /// What the shared product-pricing rule is handed on a save: the parts,
    /// the margin, the components — AND the shop's rounding and typed price,
    /// which `lib/product-price.js` reads off the same record. Without those
    /// two a product rounded up to 5 saved here as its unrounded base, and a
    /// typed price was replaced by cost plus margin. Pulled out so a test can
    /// hold it to the record without a store.
    static func pricingInput(for product: Product, parts: [JSONValue]) -> [String: JSONValue] {
        var forPricing: [String: JSONValue] = ["parts": .array(parts)]
        if let margin = product.margin { forPricing["defaultMargin"] = .number(margin) }
        if let components = product.rest["components"] { forPricing["components"] = components }
        for key in ["priceRound", "priceOverride"] {
            if let value = product.rest[key] { forPricing[key] = value }
        }
        return forPricing
    }

    /// Save what one Settings pane showed.
    ///
    /// `form` carries only that pane's keys, and `lib/settings-edit.js` keeps
    /// every other setting as it finds it — the Business pane saving a phone
    /// number must not zero the WIP limits it never displayed. A country chosen
    /// for tax rules is applied first, the way Khayt's picker applies it on the
    /// change, so name, registration label, convention and rate arrive together.
    ///
    /// The whole record is re-read from disk inside the write and the window
    /// reloads from the file afterwards: what the screen shows is what was
    /// written, not what was hoped.
    ///
    /// `opened` is the same pane's form as it was when the pane was filled —
    /// what saving would send had nobody touched anything. Everything the
    /// shared rule writes the same for both is put back as the book had it
    /// (`RoundTrip`), so a pane that reads `vatRate: "15"` or no `currency`
    /// at all does not re-spell them the day the shop changes its phone
    /// number. Nil only for a caller with no form of its own to compare with.
    func saveSettings(_ form: [String: JSONValue], opened: [String: JSONValue]?,
                      country: String? = nil) async {
        settingsProblem = nil
        settingsNote = nil
        // The operator lock: a manager reads Settings and changes nothing.
        guard lockAllows("settings", "edit") else {
            settingsProblem = words.callIt(needsSignIn ? "mac.lock_sign_in_first" : "mac.lock_not_allowed")
            return
        }
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
                try await Self.applySettings(to: &root, form: form, opened: opened,
                                             country: country, engine: engine)
            }
            await load(source)
            settingsNote = words.callIt("mac.settings_saved")
        } catch {
            settingsProblem = self.said(error)
        }
    }

    /// The settings write, on a book already read: the seam the tests use.
    static func applySettings(to root: inout [String: JSONValue], form: [String: JSONValue],
                              opened: [String: JSONValue]? = nil,
                              country: String?, engine: KhaytEngine) async throws {
        let stored = Self.settings(root)
        let year = Calendar.book.component(.year, from: Date())
        var settings = stored
        if let country, country != Self.taxCountry(settings) {
            settings = try await engine.chooseTaxCountry(settings, code: country)
        }
        settings = try await engine.applySettings(settings, form: form, year: year)
        if let opened {
            let baseline = try await engine.applySettings(stored, form: opened, year: year)
            // `fillingGaps`: a key the book lacks is written as the rule
            // fills it — `firstRunDone`, the invoice counter's year — as any
            // settings save always has. Only what the book already HAS is
            // kept in its own spelling.
            settings = RoundTrip.keepUntouched(written: settings, baseline: baseline, stored: stored,
                                               fillingGaps: true)
        }
        // THE SHOP'S TARIFF CHANGED: the preset an earlier setup made carries
        // the old one and would beat it wherever it is picked. Only on a real
        // change — a save that leaves the stored value as it was (a junk value
        // the pane could not show, untouched) writes no preset.
        if form["elecRate"] != nil, settings["elecRate"] != stored["elecRate"] {
            keepSetupPresetInStep(&root, tariff: plainNumber(settings["elecRate"]))
        }
        root["settings"] = .object(settings)
    }

    // MARK: - The shop's own mark

    /// The logo as the book holds it, or empty.
    var bizLogo: String {
        guard case .object(let s) = settingsValue else { return "" }
        let stored = Shop.plainString(s["bizLogo"]) ?? ""
        // Read through the SAME test the document applies. A picture Settings
        // showed and the invoice refused would be the worst of both.
        return stored.hasPrefix("data:image/") ? stored : ""
    }

    /// Put a picture on the shop's documents.
    ///
    /// Written straight onto `settings.bizLogo` rather than through a form:
    /// `settings-edit.js` keeps `out.bizLogo = s.bizLogo || ''`, so it
    /// preserves what it finds and takes none from a form.
    func setLogo(from url: URL) async {
        writeProblem = nil
        guard source.build != nil else { writeProblem = words.callIt("mac.move_sample"); return }
        let uri: String
        do { uri = try ShopLogo.dataURI(of: url) }
        catch let refused as ShopLogo.Refused {
            // The refusal's own sentence — too big, or not a picture — because
            // each of them tells the shop something different to do.
            writeProblem = words.callIt(refused.errorDescription ?? "")
            return
        } catch {
            writeProblem = self.said(error)
            return
        }
        await write(as: .person("settings", "edit")) { root in
            var settings = Self.settings(root)
            settings["bizLogo"] = .string(uri)
            root["settings"] = .object(settings)
        }
    }

    /// Take it off again, back to Khayt's own mark on the document.
    func clearLogo() async {
        writeProblem = nil
        guard source.build != nil else { writeProblem = words.callIt("mac.move_sample"); return }
        await write(as: .person("settings", "edit")) { root in
            var settings = Self.settings(root)
            // The EMPTY STRING, which is what `settings-edit` writes for an
            // absent one — not a removed key, which a merge could resurrect
            // from an older copy on another machine.
            settings["bizLogo"] = .string("")
            root["settings"] = .object(settings)
        }
    }

    /// Ask for a picture, then put it on the documents.
    func pickLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = words.callIt("set.logo")
        panel.prompt = words.callIt("set.logo_upload")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await setLogo(from: url) }
    }

    // MARK: - How much of the app the shop wants

    /// The two modes Khayt offers. `enthusiast` exists in the book and is NOT
    /// on this list on purpose: it is Bed Ready's only mode and was retired as
    /// a Khayt one, so a book carrying it is read as Simple and re-saving would
    /// pin it there rather than offering it back.
    static let modes = ["simple", "professional"]

    /// What the shop is on now, with `enthusiast` resolved the way every reader
    /// resolves it and an absent mode read as Professional — which is what a
    /// book written before modes existed means.
    var mode: String { Self.modeOf(settingsValue) }

    /// Static so it can be shown to agree with `KhaytEngine.featureEnabled`,
    /// which makes the same two decisions on the other side of the bridge. A
    /// picker that showed one mode while the shelves obeyed another would be
    /// the Simple-mode bug again, from the other end.
    static func modeOf(_ settings: JSONValue) -> String {
        guard case .object(let s) = settings, case .string(let m)? = s["mode"],
              !m.isEmpty else { return "professional" }
        return m == "enthusiast" ? "simple" : m
    }

    /// Switch between Simple and Professional.
    ///
    /// ── WHY THIS HAD TO EXIST ─────────────────────────────────────────────
    ///
    /// This app has HONOURED the mode since the shells were fixed — Simple
    /// hides Expenses and Reports — and had no way to set one. A shop that
    /// wanted its Mac simpler had to open the other app to say so, which is a
    /// gap rather than a difference.
    ///
    /// Written straight onto `settings.mode`, exactly as the other app's mode
    /// pills do it, and NOT through the settings form: `settings-edit.js` keeps
    /// `out.mode = s.mode || 'professional'` — it preserves what it finds and
    /// takes no mode from a form — so a pane saving through it could never
    /// change this.
    func chooseMode(_ wanted: String) async {
        writeProblem = nil
        guard Self.modes.contains(wanted) else {
            writeProblem = words.callIt("mac.mode_unknown"); return
        }
        guard source.build != nil else { writeProblem = words.callIt("mac.move_sample"); return }
        guard wanted != mode else { return }
        await write(as: .person("settings", "edit")) { root in
            var settings = Self.settings(root)
            settings["mode"] = .string(wanted)
            root["settings"] = .object(settings)
        }
    }
}
