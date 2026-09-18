import Foundation

/// What a shop spent keeping each machine running — ported to Swift.
///
/// ── THE CHART READ A FIELD NOTHING HAS EVER WRITTEN ───────────────────────
///
/// "Maintenance Cost by Machine" read `machine.machMaintLog` — a per-machine
/// property Khayt has never written. It was always undefined, always became an
/// empty list, so every machine totalled zero and was filtered out, and the
/// chart said "No data yet" however many services a shop had logged — while
/// the machine screen listed those same services correctly from the real list.
///
/// The log is the book's own flat `machMaintLog`. (Which is itself worth
/// knowing twice: the Mac wrote it under the wrong key until recently, so the
/// same chart had two separate reasons to be empty.)
public enum MaintenanceCost {

    public struct Row: Sendable, Equatable {
        public let machineId: String
        public let name: String
        /// True when the entry's machine is no longer in the book.
        public let orphan: Bool
        public let total: Double
    }

    /// The year an entry falls in, read off the FRONT OF ITS DATE STRING.
    ///
    /// Not through a date. `new Date("2026-01-01").getFullYear()` parses as
    /// midnight UTC and then answers in the reader's own timezone — so west of
    /// UTC that is the 31st of December, and a shop in New York would have
    /// seen its new year's maintenance counted against the year before.
    ///
    /// Empty for anything that is not a `YYYY-MM-DD` date, which keeps a
    /// malformed entry out of EVERY year rather than filed into one by
    /// accident.
    public static func year(of date: JSONValue?) -> String {
        let s = JSSemantics.text(date)
        return DateRange.startsWithADay(s) ? String(s.prefix(4)) : ""
    }

    /// Total maintenance cost per machine, biggest spender first.
    ///
    /// Machines with nothing spent on them are left out: a bar chart of
    /// zero-height bars is noise rather than information.
    ///
    /// Costs for a machine the shop has since deleted are KEPT, labelled by
    /// the id the entry carries. The money left the shop; a chart of what
    /// maintenance cost should not quietly shrink because a printer was sold.
    public static func byMachine(machines: [JSONValue], entries: [JSONValue],
                                 year wanted: String? = nil) -> [Row] {
        let year = (wanted?.isEmpty == false) ? wanted : nil

        var names: [String: String] = [:]
        for row in machines {
            guard case .object(let m) = row, JSSemantics.truthy(m["id"]) else { continue }
            let id = JSSemantics.text(m["id"])
            let name = JSSemantics.truthy(m["name"]) ? m["name"]
                : (JSSemantics.truthy(m["model"]) ? m["model"] : m["id"])
            names[id] = JSSemantics.text(name)
        }

        // Insertion order is kept because the sort below is STABLE in
        // JavaScript, and two machines that cost the same and sort equal by
        // name would otherwise swap places between renders.
        var order: [String] = []
        var totals: [String: Double] = [:]
        for row in entries {
            guard case .object(let e) = row, JSSemantics.truthy(e["machineId"]) else { continue }
            if let year, self.year(of: e["date"]) != year { continue }
            let id = JSSemantics.text(e["machineId"])
            if totals[id] == nil { order.append(id) }
            let n = JSSemantics.number(e["cost"])
            totals[id, default: 0] += n.isFinite ? n : 0
        }

        var rows: [Row] = []
        for id in order {
            guard let total = totals[id], total > 0 else { continue }
            rows.append(Row(machineId: id, name: names[id] ?? id,
                            orphan: names[id] == nil, total: total))
        }

        // ── AND THE TIE-BREAK IS `localeCompare`, NOT `<` ──────────────────
        //
        // `(b.total - a.total) || a.name.localeCompare(b.name)` — a
        // locale-aware collation, so "apple" sorts before "Banana" where a
        // plain comparison of code points puts every capital first. A machine
        // list is the shop's own names, often mixed case and often Arabic, so
        // the difference is visible on a real book rather than theoretical.
        return rows.enumerated().sorted { lhs, rhs in
            if lhs.element.total != rhs.element.total { return lhs.element.total > rhs.element.total }
            let byName = lhs.element.name.localizedCompare(rhs.element.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
