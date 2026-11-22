import Foundation
import KhaytCore

/// Grouping the proposed work by colour, per machine.
///
/// ── WHAT IS BEING SAVED ───────────────────────────────────────────────────
///
/// The shop's printer is a Snapmaker U1, a four-head toolchanger. It has no
/// purge tower, so the colour changes inside one print cost the same in any
/// order. What the ORDER changes is how often somebody walks up and swaps a
/// spool between two jobs. `lib/swap-queue.js` counts those, for the order the
/// scheduler proposed and for a colour-grouped one, and keeps every due date
/// and priority while it does. Nothing here decides anything: this file only
/// gathers what the rule needs and hands back what it said.
///
/// ── AN ADVISORY ORDER ─────────────────────────────────────────────────────
///
/// The book has no queue position — the scheduler's apply writes `machineId`
/// and nothing else, and the board orders work by priority and due date. So
/// the grouped order is what the panel SHOWS, row by row, for the shop to run
/// in; applying still assigns printers only.
extension Shop {

    /// Work out, per machine, what grouping its proposed jobs would do.
    func planSwaps(_ plan: KhaytEngine.SchedulePlan) async {
        swapPlans = [:]
        guard let engine,
              let minutes = try? await engine.swapMinutes(settings: settingsDict) else { return }
        let byId = Dictionary(orders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let library = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: KhaytEngine.SwapQueue] = [:]
        for (machineId, rows) in Self.assignmentsByMachine(plan.assignments) {
            let jobs = rows.compactMap { byId[$0.orderId] }
            guard jobs.count == rows.count, !jobs.isEmpty else { continue }
            let loaded = loadedSlots(for: machineId)
            let machine = machines.first { $0.id == machineId }
            // Work already on the machine ahead of these: where the first of
            // them would start, by the scheduler's own reckoning.
            let first = rows[0]
            let start = max(0, first.projectedFinishMins - jobs[0].printTime)
            if let answer = try? await engine.swapQueue(
                jobs: jobs.map { Self.swapJob($0, library: library) }, loaded: loaded,
                heads: Self.heads(machine, loaded: loaded), swapMinutes: minutes,
                startHours: start) {
                out[machineId] = answer
            }
        }
        swapPlans = out
    }

    /// The proposal's rows for each machine, in that machine's queue order.
    static func assignmentsByMachine(_ rows: [KhaytEngine.SchedulePlan.Assignment])
        -> [String: [KhaytEngine.SchedulePlan.Assignment]] {
        Dictionary(grouping: rows, by: \.machineId).mapValues { $0.sorted { $0.position < $1.position } }
    }

    /// How many spools a machine holds at once. A toolchanger's heads are its
    /// colours (`maxColors`); a machine that never said has as many as it
    /// reports loaded, and four — a U1 — when it reports nothing either.
    static func heads(_ machine: Machine?, loaded: [KhaytEngine.LoadedSlot]) -> Int {
        if let n = machine?.maxColors, n > 0 { return n }
        return loaded.isEmpty ? 4 : loaded.count
    }

    /// One job as the rule reads it: the colours of every model its parts
    /// print, from the library (read out of the 3MF), and a part's own colour
    /// where it is written as a hex and no model is linked.
    static func swapJob(_ job: Order, library: [String: LibraryFile]) -> JSONValue {
        var colours: [JSONValue] = []
        for part in job.parts {
            if let id = part.printFileId, let file = library[id], let list = file.colors, !list.isEmpty {
                for c in list { if let hex = c.hex, !hex.isEmpty { colours.append(.object(["hex": .string(hex)])) } }
            } else if part.colour.range(of: "^#?[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$", options: .regularExpression) != nil {
                colours.append(.object(["hex": .string(part.colour)]))
            }
        }
        var o: [String: JSONValue] = [
            "id": .string(job.id),
            "colors": .array(colours),
            "material": .string(job.parts.first { !$0.material.isEmpty }?.material ?? ""),
            "printTime": .number(job.printTime),
            "priority": .bool(job.priority),
        ]
        if let due = job.dueDate, !due.isEmpty { o["dueDate"] = .string(due) }
        if let level = job.priorityLevel, !level.isEmpty { o["priorityLevel"] = .string(level) }
        return .object(o)
    }

    /// Across every machine: how many spool changes grouping saves, and the
    /// minutes that is at the shop's estimate.
    var swapSaving: (swaps: Int, minutes: Double) {
        swapPlans.values.reduce((0, 0)) { ($0.0 + $1.saved.swaps, $0.1 + $1.saved.minutes) }
    }

    /// The shop's minutes per change, as the plans used it.
    var swapMinutesUsed: Double? { swapPlans.values.first?.swapMinutes }

    /// Whether the colour-grouped order is the one on screen.
    var showingGrouped: Bool { groupByColour && swapPlans.values.contains { $0.changed } }

    /// The rows the panel draws, in the order it draws them.
    var scheduleRowsShown: [KhaytEngine.SchedulePlan.Assignment] {
        guard let plan = schedulePlan else { return [] }
        return showingGrouped ? Self.grouped(plan.assignments, swapPlans) : plan.assignments
    }

    /// The scheduler's list with each machine's jobs put in its grouped order.
    ///
    /// Each machine keeps the SLOTS its jobs had in the list, and only which of
    /// its jobs sits in which slot changes — so the list still reads in the
    /// scheduler's rhythm across machines, and nothing moves between printers.
    static func grouped(_ rows: [KhaytEngine.SchedulePlan.Assignment],
                        _ plans: [String: KhaytEngine.SwapQueue]) -> [KhaytEngine.SchedulePlan.Assignment] {
        var queues: [String: [KhaytEngine.SchedulePlan.Assignment]] = [:]
        for (machine, list) in assignmentsByMachine(rows) {
            guard let plan = plans[machine], plan.changed else { queues[machine] = list; continue }
            let byId = Dictionary(list.map { ($0.orderId, $0) }, uniquingKeysWith: { a, _ in a })
            let ordered = plan.order.compactMap { byId[$0] }
            queues[machine] = ordered.count == list.count ? ordered : list
        }
        var next: [String: Int] = [:]
        return rows.map { row in
            let k = next[row.machineId, default: 0]
            next[row.machineId] = k + 1
            return queues[row.machineId]?[k] ?? row
        }
    }

    /// What one job adds, in the order on screen: its spool changes, or nil
    /// when it adds none or the rule could not tell.
    func swapsAdded(_ row: KhaytEngine.SchedulePlan.Assignment) -> Int? {
        guard let job = swapPlans[row.machineId]?.jobs.first(where: { $0.id == row.orderId }),
              job.known else { return nil }
        let n = showingGrouped ? job.swapsPlanned : job.swapsNow
        return n > 0 ? n : nil
    }

    /// When one job comes off, in hours, in the order on screen. The grouped
    /// order's own finish (swap time included) where that machine was
    /// regrouped; the scheduler's figure otherwise.
    func finishShown(_ row: KhaytEngine.SchedulePlan.Assignment) -> Double {
        if showingGrouped, let plan = swapPlans[row.machineId], plan.changed,
           let job = plan.jobs.first(where: { $0.id == row.orderId }) {
            return job.finishHours
        }
        return row.projectedFinishMins
    }
}
