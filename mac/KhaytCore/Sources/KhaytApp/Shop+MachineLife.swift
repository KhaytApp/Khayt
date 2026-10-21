import Foundation
import KhaytCore

/// One question about a printer's working life, held until the shop answers.
///
/// The machine's id and name are taken at the click, so a book that reloads
/// under the dialog cannot change which printer the answer is about. `jobs` is
/// how many unfinished jobs retiring it would unassign — asked of the rule
/// before the question is put, so the number in the sentence is the rule's.
struct MachineAsk: Identifiable, Equatable {
    enum Kind: Equatable { case underService, retire, delete }
    let id = UUID()
    let kind: Kind
    let machineId: String
    let name: String
    var jobs: Int = 0
}

/// A printer in service, under service, retired — and deleted, but only when
/// nothing in the book remembers it.
///
/// ── THE RULE IS `lib/machine-status.js` ─────────────────────────────────
///
/// Every write below goes through it, inside the store write, against the
/// book ON DISK. Deleting a printer with history would rewrite the past — its
/// depreciation gone from every earlier month, its jobs fallen into
/// "Unassigned", its service costs off the machine P&L — so `canDelete`
/// decides, again, inside the write, and anything it refuses is retired
/// instead. The menu greys Delete from the verdicts read with the book
/// (`machineDeleteVerdicts`) and says what still names the printer.
///
/// Gated like every machine write: `permitted("inventory", …)`, the area
/// `saveMachine` asks.
extension Shop {

    // MARK: - Which machines a screen offers

    /// Every machine that has not been retired — the lists, tiles and counts.
    var machinesInUse: [Machine] { machines.filter { !$0.isRetired } }

    /// The retired ones, for the Machines screen's disclosure and nowhere else.
    var retiredMachines: [Machine] { machines.filter(\.isRetired) }

    /// In service: neither retired nor under service. What may be sent a file,
    /// switched off by a plug, or polled.
    var workingMachines: [Machine] { machines.filter(\.inService) }

    /// The machine rows as the book holds them, without the retired ones —
    /// for the rules that lay out the floor (the band, the kiosk, capacity,
    /// what fits on which bed) and do not know about retirement themselves.
    var machineRowsInUse: [JSONValue] {
        let retired = Set(machines.lazy.filter(\.isRetired).map(\.id))
        guard !retired.isEmpty else { return machineRows }
        return machineRows.filter { row in Self.recordId(row).map { !retired.contains($0) } ?? true }
    }

    /// The machines a picker offers: every one in use, plus the one the record
    /// already names even if it has since been retired — a job printed on a
    /// sold printer still says which one, and a picker that dropped it would
    /// silently re-point the job the moment it was saved.
    func machineChoices(keeping chosen: String?) -> [Machine] {
        let kept = chosen.flatMap { id in machines.first { $0.id == id && $0.isRetired } }
        return machinesInUse + (kept.map { [$0] } ?? [])
    }

    /// A machine's name as a picker shows it, with "(retired)" or "(under
    /// service)" after it in words — never colour alone.
    func machineChoiceLabel(_ machine: Machine) -> String {
        if machine.isRetired { return machine.name + " " + words.callIt("mac.life_retired_suffix") }
        if machine.isUnderService { return machine.name + " " + words.callIt("mac.life_service_suffix") }
        return machine.name
    }

    /// What a record that names a machine calls it: its name, or "Deleted
    /// printer" when the id no longer matches one — never the raw id, which
    /// is a string like `MACH-lq3x9ABC` that means nothing to anybody.
    func machineName(forId id: String) -> String {
        machines.first { $0.id == id }?.name ?? words.callIt("mac.life_deleted_printer")
    }

    /// The fleet as the dashboard counts it. A retired printer is not part of
    /// the shop any more, so it leaves the total (and the attention list); an
    /// under-service one is part of it and is DOWN, so it is handed to the
    /// shared count as offline — it is not polled, so there is no reading of
    /// its own to say so.
    nonisolated static func fleetForDashboard(_ rows: [JSONValue], cache: [String: JSONValue])
        -> (machines: [JSONValue], cache: [String: JSONValue]) {
        var kept: [JSONValue] = []
        var out = cache
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        for row in rows {
            guard let data = try? encoder.encode(row),
                  let m = try? decoder.decode(Machine.self, from: data) else { kept.append(row); continue }
            if m.isRetired { out.removeValue(forKey: m.id); continue }
            if m.isUnderService { out[m.id] = .object(["state": .string("offline")]) }
            kept.append(row)
        }
        return (kept, out)
    }

    // MARK: - Why Delete is not offered

    /// The sentence a greyed Delete carries: "Used by 12 jobs and 3 service
    /// entries". Built from the rule's `by`, each collection counted in the
    /// shop's language, the biggest first; collections without a word of their
    /// own are summed as "other records".
    func cannotDeleteSentence(_ verdict: KhaytEngine.MachineDeleteVerdict) -> String {
        if verdict.reason == "missing" { return words.callIt("mac.life_delete_missing") }
        var parts: [(n: Int, text: String)] = []
        var other = 0
        for (collection, n) in verdict.by where n > 0 {
            if let key = Self.referenceKeys[collection] {
                parts.append((n, words.counting(n, key)))
            } else {
                other += n
            }
        }
        parts.sort { $0.n != $1.n ? $0.n > $1.n : $0.text < $1.text }
        if other > 0 { parts.append((other, words.counting(other, "mac.life_ref_other"))) }
        // In the shop's language and digits (`Digits`), never the Mac's.
        let joined = parts.map(\.text).formatted(.list(type: .and).locale(words.locale))
        return words.callIt("mac.life_delete_blocked", ["what": .string(joined)])
    }

    /// The collections that name a machine and have a word of their own.
    nonisolated static let referenceKeys: [String: String] = [
        "printLog": "mac.life_ref_jobs",
        "machMaintLog": "mac.life_ref_service",
        "machMaintTasks": "mac.life_ref_tasks",
        "wasteLog": "mac.life_ref_waste",
        "expenses": "mac.life_ref_expenses",
        "timeEntries": "mac.life_ref_time",
        "printerCompletions": "mac.life_ref_completions",
    ]

    /// Read with the book: whether each machine may be deleted. One crossing
    /// for the whole floor, and only when there is a machine to ask about.
    func readMachineDeleteVerdicts(_ root: [String: JSONValue]) async {
        guard let engine else { machineDeleteVerdicts = [:]; return }
        let ids = Self.rows(root, "machines").compactMap(Self.recordId)
        guard !ids.isEmpty else { machineDeleteVerdicts = [:]; return }
        let ticket = loadGeneration
        let verdicts = (try? await engine.machineDeleteVerdicts(book: root, ids: ids)) ?? [:]
        guard ticket == loadGeneration else { return }
        machineDeleteVerdicts = verdicts
    }

    // MARK: - Asking first

    /// Put the question. Retire asks the rule first how many unfinished jobs
    /// would lose their printer, so the sentence can say.
    func ask(_ kind: MachineAsk.Kind, about machine: Machine) async {
        pendingMachineAsk = await question(kind, about: machine)
    }

    /// The question itself, for a host that holds its own (the machine sheet).
    func question(_ kind: MachineAsk.Kind, about machine: Machine) async -> MachineAsk {
        var asked = MachineAsk(kind: kind, machineId: machine.id, name: machine.name)
        if kind == .retire { asked.jobs = await unfinishedJobs(on: machine.id) }
        return asked
    }

    /// How many unfinished jobs `retire` would take this printer off — the
    /// rule run on a copy, so "unfinished" is `order-status`'s word for it.
    func unfinishedJobs(on machineId: String) async -> Int {
        guard let engine else { return 0 }
        let out = try? await engine.retireMachine(machines: machineRows, printLog: orderRows, id: machineId,
                                                  at: Self.today(), reason: nil)
        return out?.unassigned.count ?? 0
    }

    // MARK: - The actions

    /// Under service (with an optional reason, dated today), or back in it.
    func setUnderService(_ machineId: String, on: Bool, reason: String? = nil) async {
        guard permitted("inventory", "edit") else { return }
        let named = on ? "mac.life_mark_service_action" : "mac.life_back_in_service"
        await lifeWrite(named: named, notice: on ? "mac.life_now_service" : "mac.life_now_in_service",
                        machineId: machineId) { root, engine in
            try await Self.writeUnderService(into: &root, id: machineId, on: on, reason: reason,
                                             since: Self.today(), engine: engine)
        }
    }

    /// Retire it, today, off every unfinished job.
    func retireMachine(_ machineId: String, reason: String? = nil) async {
        guard permitted("inventory", "edit") else { return }
        var unassigned = 0
        await lifeWrite(named: "mac.life_retire_action", notice: "mac.life_now_retired", machineId: machineId,
                        after: { [words] in
                            unassigned > 0 ? words.counting(unassigned, "mac.life_jobs_unassigned") : nil
                        }) { root, engine in
            let out = try await Self.writeRetire(into: &root, id: machineId, at: Self.today(),
                                                 reason: reason, engine: engine)
            unassigned = out.unassigned
            return out.undo
        }
    }

    /// Return a retired printer to service, its history untouched.
    func returnToService(_ machineId: String) async {
        guard permitted("inventory", "edit") else { return }
        await lifeWrite(named: "mac.life_unretire", notice: "mac.life_now_returned", machineId: machineId) { root, engine in
            try await Self.writeUnretire(into: &root, id: machineId, engine: engine)
        }
    }

    /// Delete it — only when the rule, asked again on the book as it is now,
    /// finds nothing that names it.
    func deleteMachine(_ machineId: String) async {
        guard permitted("inventory", "delete") else { return }
        await lifeWrite(named: "mac.life_delete_action", notice: "mac.life_now_deleted", machineId: machineId) { root, engine in
            try await Self.writeDelete(into: &root, id: machineId, engine: engine)
        }
        if editingMachine?.id == machineId { editingMachine = nil }
    }

    /// The shared shape: write inside the store write, register the undo,
    /// reload, and say what happened.
    private func lifeWrite(named action: String, notice: String, machineId: String,
                           after: (() -> String?)? = nil,
                           _ change: (inout [String: JSONValue], KhaytEngine) async throws -> [ChangedRecord]) async {
        moveProblem = nil
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return }
        guard let engine else { moveProblem = words.callIt("mac.move_no_engine"); return }
        let name = machines.first { $0.id == machineId }?.name ?? ""
        var undo: [ChangedRecord] = []
        do {
            // lock: callers — setUnderService, retireMachine, returnToService, deleteMachine
            try await StoreWriter.updateAsync(build) { root in
                undo = []
                undo = try await change(&root, engine)
                Self.sealUndo(&undo, in: root)
            }
            registerMoveUndo(undo, named: words.callIt(action))
            await load(source)
            moveNotices = [words.callIt(notice, ["name": .string(name)])] + (after?().map { [$0] } ?? [])
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch let refusal as LifeRefused {
            switch refusal {
            case .gone: moveProblem = words.callIt("mac.move_gone")
            case .hasHistory(let verdict):
                moveProblem = words.callIt("mac.life_delete_refused_now") + " " + cannotDeleteSentence(verdict)
            }
        } catch {
            moveProblem = self.said(error)
        }
    }

    /// Why a lifecycle write did not happen, before it has words.
    enum LifeRefused: Error {
        case gone
        /// Something came to name the printer between the menu and the write.
        case hasHistory(KhaytEngine.MachineDeleteVerdict)
    }

    // MARK: - The writes, against the book on disk

    /// Static and taking `root`, so a test can hold each to a book of its own.

    nonisolated static func machineIndex(_ root: [String: JSONValue], _ id: String) throws -> (Int, [String: JSONValue]) {
        let floor = rows(root, "machines")
        guard let i = floor.firstIndex(where: { recordId($0) == id }),
              case .object(let m) = floor[i] else { throw LifeRefused.gone }
        return (i, m)
    }

    /// Replace one machine with `next`, stamped. Returns its undo record.
    nonisolated static func putMachine(_ next: JSONValue, at i: Int, was: [String: JSONValue],
                                       into root: inout [String: JSONValue]) -> ChangedRecord? {
        guard case .object(var fields) = next, fields != was else { return nil }
        StoreWriter.stamp(&fields)
        var floor = rows(root, "machines")
        floor[i] = .object(fields)
        root["machines"] = .array(floor)
        return ChangedRecord(collection: "machines", id: recordId(.object(was)) ?? "", was: was)
    }

    nonisolated static func writeUnderService(into root: inout [String: JSONValue], id: String, on: Bool,
                                              reason: String?, since: String,
                                              engine: KhaytEngine) async throws -> [ChangedRecord] {
        let (i, was) = try machineIndex(root, id)
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = try await engine.setUnderService(.object(was), on: on,
                                                    reason: reason?.isEmpty == false ? reason : nil,
                                                    since: since)
        return putMachine(next, at: i, was: was, into: &root).map { [$0] } ?? []
    }

    nonisolated static func writeRetire(into root: inout [String: JSONValue], id: String, at: String,
                                        reason: String?, engine: KhaytEngine) async throws
        -> (undo: [ChangedRecord], unassigned: Int) {
        let (_, was) = try machineIndex(root, id)
        let jobsBefore = rows(root, "printLog")
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = try await engine.retireMachine(machines: rows(root, "machines"), printLog: jobsBefore,
                                                 id: id, at: at,
                                                 reason: reason?.isEmpty == false ? reason : nil)
        guard out.ok, let machine = out.machine else { throw LifeRefused.gone }
        // The machine: the rule wrote it into its copy of the list; this puts
        // that one record back, stamped, and leaves every other machine alone.
        let (i, _) = try machineIndex(root, id)
        var undo: [ChangedRecord] = []
        if let changed = putMachine(machine, at: i, was: was, into: &root) { undo.append(changed) }
        // The jobs it took the printer off: only those rows change.
        if !out.unassigned.isEmpty {
            let gone = Set(out.unassigned)
            let byId = Dictionary(out.printLog.compactMap { row in recordId(row).map { ($0, row) } },
                                  uniquingKeysWith: { a, _ in a })
            var jobs = jobsBefore
            for j in jobs.indices {
                guard let jid = recordId(jobs[j]), gone.contains(jid),
                      case .object(let before) = jobs[j],
                      case .object(var after)? = byId[jid] else { continue }
                StoreWriter.stamp(&after)
                jobs[j] = .object(after)
                undo.append(ChangedRecord(collection: "printLog", id: jid, was: before))
            }
            root["printLog"] = .array(jobs)
        }
        return (undo, out.unassigned.count)
    }

    nonisolated static func writeUnretire(into root: inout [String: JSONValue], id: String,
                                          engine: KhaytEngine) async throws -> [ChangedRecord] {
        let (i, was) = try machineIndex(root, id)
        let next = try await engine.unretireMachine(.object(was))
        return putMachine(next, at: i, was: was, into: &root).map { [$0] } ?? []
    }

    /// The delete. Refused, with what still names the printer, when anything
    /// in the book does.
    nonisolated static func writeDelete(into root: inout [String: JSONValue], id: String,
                                        engine: KhaytEngine) async throws -> [ChangedRecord] {
        _ = try machineIndex(root, id)
        let out = try await engine.removeMachine(book: root, id: id)
        guard out.ok, case .object(let gone)? = out.removed else {
            if out.reason == "missing" { throw LifeRefused.gone }
            throw LifeRefused.hasHistory(KhaytEngine.MachineDeleteVerdict(
                ok: false, reason: out.reason, total: out.total, by: out.by))
        }
        root["machines"] = .array(out.machines)
        return [ChangedRecord(collection: "machines", id: id, was: gone, kind: .deleted, at: out.index)]
    }
}
