import Foundation
import AppKit
import KhaytCore

/// Care plans, "Not needed", and the parts buy list (`lib/care-plans.js`,
/// `lib/maintenance.js`).
///
/// ── THE RULES ARE SHARED ──────────────────────────────────────────────────
///
/// Which tasks a plan adds, which existing task is "the same task", when a
/// task falls due and when its parts must be ordered are all the shared
/// module's answers. This file asks them and writes the result, so the other
/// app — which wires the same module — reads one book the same way.
///
/// Hours are the jobs': the rule sums finished jobs' print time, and the rate
/// it projects with is the same jobs over the last thirty days. Nothing here
/// asks the shop to type a meter reading.
///
/// Every write is gated like the other maintenance writes,
/// `permitted("inventory", "edit")`.
extension Shop {

    // MARK: - Words for the catalogue

    /// The shop's name for each catalogue task, so a task added from the
    /// starter menu (named `mac.mt_t_<id>`) is recognised as the same task.
    func careTaskNames(_ plans: [KhaytEngine.CarePlan]) -> [String: String] {
        var out: [String: String] = [:]
        for plan in plans { for task in plan.tasks { out[task.id] = careTaskName(task.id) } }
        return out
    }

    func careTaskName(_ id: String) -> String { words.callIt("mac.mt_t_" + id) }

    func carePartName(_ id: String) -> String { words.callIt("mac.cp_part_" + id) }

    // MARK: - Applying a plan

    /// The machine's hours meter, the shared rule's.
    func careMeter(_ machineId: String) async -> Double {
        guard let engine else { return 0 }
        let card = try? await engine.maintenance(
            machineId: machineId, tasks: [], jobs: orderRows,
            machine: .object(["id": .string(machineId)]), now: Date())
        return card?.hours ?? 0
    }

    /// Add a plan's tasks to one machine. `confirm` is the existing records
    /// whose interval the shop agreed to change; every other existing task
    /// keeps its own. Nothing is marked done.
    func applyCarePlan(_ planId: String, to machine: Machine, confirm: [String]) async {
        writeProblem = nil
        guard permitted("inventory", "edit") else { return }
        guard let engine, let build = source.build, canMoveJobs else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        guard let plans = try? await engine.carePlans(),
              let plan = plans.first(where: { $0.id == planId }) else { return }
        let names = careTaskNames([plan])
        var ids: [String: String] = [:]
        for task in plan.tasks { ids[task.id] = Self.uid("MTASK") + "-" + task.id }
        let meter = await careMeter(machine.id)
        let machineId = machine.id, now = Date()
        var added = 0, changed = 0
        do {
            try await StoreWriter.updateAsync(build) { root in
                var rows: [JSONValue] = []
                if case .array(let had)? = root[MaintenanceTaskEdit.collection] { rows = had }
                let out = try await engine.applyCarePlan(
                    tasks: rows, machineId: machineId, planId: planId, names: names, ids: ids,
                    confirm: confirm, meter: meter, at: now)
                let touched = Set(out.added + out.changed)
                root[MaintenanceTaskEdit.collection] = .array(out.tasks.map { row in
                    // Stamped, or the other machine's older copy wins the next
                    // merge and the plan quietly disappears.
                    guard case .object(var r) = row, case .string(let id)? = r["id"],
                          touched.contains(id) else { return row }
                    StoreWriter.stamp(&r)
                    return .object(r)
                })
                added = out.added.count
                changed = out.changed.count
            }
            await load(source)
            importNote = added + changed == 0
                ? words.callIt("mac.cp_nothing")
                : words.callIt("mac.cp_applied", ["added": .number(Double(added)),
                                                 "changed": .number(Double(changed))])
        } catch {
            writeProblem = self.said(error)
        }
    }

    // MARK: - Not needed

    /// Inspected, and the part does not need replacing yet: push the task out
    /// without marking it done. No service is logged — nothing was serviced.
    func deferMaintenanceTask(_ taskId: String, on machine: Machine) async {
        writeProblem = nil
        guard permitted("inventory", "edit") else { return }
        guard let engine, let build = source.build, canMoveJobs else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        guard let task = maintTaskRows.first(where: { Self.recordId($0) == taskId }) else { return }
        let meter = await careMeter(machine.id)
        guard let patch = try? await engine.deferMaintenance(task: task, hours: meter, at: Date())
        else { return }
        do {
            try await StoreWriter.updateOffMain(build) { root in
                guard case .array(var rows)? = root[MaintenanceTaskEdit.collection] else { return }
                for i in rows.indices {
                    guard case .object(var record) = rows[i],
                          case .string(let id)? = record["id"], id == taskId else { continue }
                    for (key, value) in patch { record[key] = value }
                    StoreWriter.stamp(&record)
                    rows[i] = .object(record)
                }
                root[MaintenanceTaskEdit.collection] = .array(rows)
            }
            await load(source)
        } catch {
            writeProblem = self.said(error)
        }
    }

    // MARK: - The parts buy list

    /// Every care-plan part falling due in the next ninety days, with the date
    /// to order it by. A read, so asked under the view permission.
    func askForPartsList() async {
        guard permitted("inventory", "view") else { return }
        guard let engine else { moveProblem = words.callIt("mac.move_sample"); return }
        let title = words.callIt("mac.pb_title") + " \u{2014} " + (shopName.isEmpty ? "Khayt" : shopName)
        do {
            let rows = try await engine.partsBuyList(machines: machineRows, tasks: maintTaskRows,
                                                     jobs: orderRows, now: Date())
            if rows.isEmpty {
                importNote = words.callIt("mac.pb_none")
                return
            }
            pendingPartsList = PartsBuyListRequest(rows: rows, title: title)
        } catch {
            moveProblem = self.said(error)
        }
    }

    /// The list on the clipboard as plain text.
    func copyPartsList(_ request: PartsBuyListRequest) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PartsBuyListText.text(request, shop: self), forType: .string)
    }
}

struct PartsBuyListRequest: Identifiable {
    let id = UUID()
    let rows: [KhaytEngine.PartsBuyRow]
    let title: String
}

/// The words and dates the sheet, the copy and the print share.
@MainActor
enum PartsBuyListText {
    static func date(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    /// "12 Nov 2026" in the shop's language and calendar.
    static func day(_ iso: String, _ words: Words) -> String {
        guard let d = date(iso) else { return iso }
        return "\u{2068}" + words.say(d, .dateTime.day().month(.abbreviated).year()) + "\u{2069}"
    }

    static func quantity(_ qty: Double) -> String {
        "\u{00D7}" + Money.quantity(qty, decimals: qty.rounded() == qty ? 0 : 1)
    }

    /// "Order by 12 Nov 2026", or "Order now" once that date has passed.
    static func orderBy(_ row: KhaytEngine.PartsBuyRow, _ words: Words) -> String {
        row.late ? words.callIt("mac.pb_late")
                 : words.callIt("mac.pb_order_by", ["date": .string(day(row.orderBy, words))])
    }

    static func due(_ row: KhaytEngine.PartsBuyRow, _ words: Words) -> String {
        words.callIt("mac.pb_due", ["date": .string(day(row.dueAt, words))])
    }

    static func task(_ row: KhaytEngine.PartsBuyRow, shop: Shop) -> String {
        row.taskName.isEmpty ? (row.careTaskId.map(shop.careTaskName) ?? shop.words.callIt("mac.unnamed"))
                             : row.taskName
    }

    static func text(_ request: PartsBuyListRequest, shop: Shop) -> String {
        let w = shop.words
        var lines = [request.title, ""]
        for row in request.rows {
            let dash = " \u{2014} "
            let part = shop.carePartName(row.partId) + " " + quantity(row.qty)
            let where_ = row.machineName + ", " + task(row, shop: shop)
            lines.append(part + dash + where_ + dash + orderBy(row, w) + "; " + due(row, w))
        }
        return lines.joined(separator: "\n")
    }

    static func html(_ request: PartsBuyListRequest, shop: Shop) -> String {
        let w = shop.words
        func e(_ s: String) -> String { Labels.escape(s) }
        var body = "<table>"
        for row in request.rows {
            body += "<tr><td>\(e(shop.carePartName(row.partId)))</td>"
                + "<td class=\"n\">\(e(quantity(row.qty)))</td>"
                + "<td>\(e(row.machineName))<br><small>\(e(task(row, shop: shop)))</small></td>"
                + "<td class=\"n\">\(e(orderBy(row, w)))<br><small>\(e(due(row, w)))</small></td></tr>"
        }
        body += "</table><p><small>\(e(w.callIt("mac.pb_hint")))</small></p>"
        let rtl = w.language == "ar"
        return """
        <!doctype html><html lang="\(e(w.language))" dir="\(rtl ? "rtl" : "ltr")"><head><meta charset="utf-8">
        <title>\(e(request.title))</title><style>
        @page { size: A4; margin: 16mm; }
        body { margin: 0; padding: 16px; background: #fff; color: #111;
               font: 12px -apple-system, system-ui, sans-serif; }
        h1 { font-size: 18px; margin: 0 0 14px; }
        table { width: 100%; border-collapse: collapse; }
        td { border-bottom: 1px solid #eee; padding: 5px 4px; vertical-align: top; }
        td.n { text-align: end; font-variant-numeric: tabular-nums; white-space: nowrap; }
        small { color: #666; }
        </style></head><body>
        <h1>\(e(request.title))</h1>
        \(body)
        </body></html>
        """
    }
}
