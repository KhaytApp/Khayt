import Foundation

/// Which machine is costing the shop, and what it keeps doing wrong.
///
/// Neither app has answered this. Waste is charted by failure type over time —
/// which says the shop has a warping problem — and never by MACHINE, which is
/// what says WHICH printer has it. "Replace the old one" is a decision worth
/// thousands, and until now there was nothing to make it on.
///
/// ── AGAINST WHAT THE MACHINE PRINTED, NOT IN ISOLATION ────────────────────
///
/// A printer that ran nine hundred hours and scrapped two kilos is doing better
/// than one that ran ninety and scrapped one — so the rate is scrap against
/// what that machine actually put out, and the raw grams are reported beside it
/// rather than instead of it. Ranking by grams alone would always name the
/// busiest machine, which is the wrong printer to sell.
public enum MachineReliability {

    public static let finished = ["completed", "delivered"]

    /// The key scrap that names no machine is gathered under.
    public static let noMachine = "__none__"

    static func num(_ value: JSONValue?) -> Double {
        let n = JSSemantics.number(value)
        return n.isFinite ? n : 0
    }

    static func day(_ value: JSONValue?) -> String {
        String(decoding: Array(JSSemantics.text(value).utf16.prefix(10)), as: UTF16.self)
    }

    /// `a < b` on two JavaScript strings — UTF-16 code units.
    static func less(_ a: String, _ b: String) -> Bool {
        var l = a.utf16.makeIterator(), r = b.utf16.makeIterator()
        while true {
            switch (l.next(), r.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case (let x?, let y?): if x != y { return x < y }
            }
        }
    }

    /// The default `gramsOf`: every part's printed and support weight, times
    /// its quantity — `Math.max(1, qty || 1)`, so a part with no quantity
    /// counts once rather than none.
    public static func grams(of order: JSONValue) -> Double {
        parts(of: order).reduce(0) { sum, p in
            guard case .object(let part) = p else { return sum }
            return sum + (num(part["printWeight"]) + num(part["supportWeight"]))
                * Swift.max(1, num(part["qty"]) == 0 ? 1 : num(part["qty"]))
        }
    }

    public static func hours(of order: JSONValue) -> Double {
        parts(of: order).reduce(0) { sum, p in
            guard case .object(let part) = p else { return sum }
            return sum + num(part["printTime"])
                * Swift.max(1, num(part["qty"]) == 0 ? 1 : num(part["qty"]))
        }
    }

    private static func parts(of order: JSONValue) -> [JSONValue] {
        guard case .object(let o) = order, case .array(let list)? = o["parts"] else { return [] }
        return list
    }

    public struct Fault: Sendable, Equatable {
        public let type: String
        public let grams: Double
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public let machineId: String
        public let name: String
        public let color: String
        public let jobs: Int
        public let grams: Double
        public let hours: Double
        public let scraps: Int
        public let scrapGrams: Double
        public let scrapCost: Double
        /// Nil for a machine that has handled nothing — which is not a machine
        /// with a perfect record.
        public let scrapRate: Double?
        /// What it keeps doing wrong, which is the actionable half: "warping"
        /// sends somebody to the chamber temperature, and a number does not.
        public let worstFault: Fault?
        public var id: String { machineId }
    }

    public struct Totals: Sendable, Equatable {
        public let jobs: Int
        public let grams: Double
        public let scrapGrams: Double
        public let scraps: Int
        public let scrapCost: Double
        public let scrapRate: Double?
        /// The machine to look at — worst rate, and only once it has printed
        /// enough for a rate to mean anything. One scrapped print on a machine
        /// that has run twice is not evidence of anything.
        public let worst: Row?
    }

    public struct Report: Sendable, Equatable {
        public let rows: [Row]
        public let totals: Totals
    }

    public static func report(machines: [JSONValue], orders: [JSONValue],
                              waste: [JSONValue], from: String = "", to: String = "",
                              unassigned: String = "",
                              gramsOf: ((JSONValue) -> Double)? = nil,
                              hoursOf: ((JSONValue) -> Double)? = nil) -> Report {
        let gramsOf = gramsOf ?? grams(of:)
        let hoursOf = hoursOf ?? hours(of:)
        let from = day(.string(from)), to = day(.string(to))
        func inWindow(_ at: JSONValue?) -> Bool {
            let when = day(at)
            guard !when.isEmpty else { return false }
            if !from.isEmpty && less(when, from) { return false }
            if !to.isEmpty && less(to, when) { return false }
            return true
        }

        // Insertion-ordered, because the sort is stable in the original.
        var order: [String] = []
        var rows: [String: (name: String, color: String, jobs: Int, grams: Double,
                            hours: Double, scraps: Int, scrapGrams: Double,
                            scrapCost: Double)] = [:]
        var faults: [String: [(type: String, grams: Double)]] = [:]

        for machine in machines {
            guard case .object(let m) = machine, let id = m["id"],
                  JSSemantics.truthy(id) else { continue }
            let key = JSSemantics.text(id)
            guard rows[key] == nil else { continue }
            rows[key] = (JSSemantics.truthy(m["name"]) ? JSSemantics.text(m["name"]) : "",
                         JSSemantics.truthy(m["color"]) ? JSSemantics.text(m["color"]) : "#888888",
                         0, 0, 0, 0, 0, 0)
            faults[key] = []
            order.append(key)
        }
        // Scrap that names no machine is still scrap. A shop cannot act on it,
        // but hiding it makes the shop's total look better than it is.
        if rows[noMachine] == nil {
            rows[noMachine] = (unassigned, "#888888", 0, 0, 0, 0, 0, 0)
            faults[noMachine] = []
            order.append(noMachine)
        }

        for job in orders {
            guard JSSemantics.truthy(job), case .object(let o) = job,
                  !JSSemantics.truthy(o["voidedAt"]),
                  finished.contains(JSSemantics.text(o["status"])),
                  inWindow(o["date"]) else { continue }
            let named = JSSemantics.truthy(o["machineId"]) ? JSSemantics.text(o["machineId"]) : ""
            let key = rows[named] != nil ? named : noMachine
            rows[key]!.jobs += 1
            rows[key]!.grams += num(.number(gramsOf(job)))
            rows[key]!.hours += num(.number(hoursOf(job)))
        }

        for entry in waste {
            guard JSSemantics.truthy(entry), case .object(let w) = entry,
                  inWindow(w["date"]) else { continue }
            let named = JSSemantics.truthy(w["machineId"]) ? JSSemantics.text(w["machineId"]) : ""
            let key = rows[named] != nil ? named : noMachine
            rows[key]!.scraps += 1
            rows[key]!.scrapGrams += num(w["weight"])
            rows[key]!.scrapCost += num(w["cost"])
            let fault = JSSemantics.truthy(w["failureType"])
                ? JSSemantics.text(w["failureType"]) : "other"
            if let at = faults[key]!.firstIndex(where: { $0.type == fault }) {
                faults[key]![at].grams += num(w["weight"])
            } else {
                faults[key]!.append((fault, num(w["weight"])))
            }
        }

        let built: [Row] = order.compactMap { key in
            guard let r = rows[key] else { return nil }
            // The denominator is everything the machine CONSUMED — what it put
            // out plus what it scrapped — so a machine that scrapped half its
            // filament reads as 50% rather than 100%.
            let handled = r.grams + r.scrapGrams
            let ranked = (faults[key] ?? []).enumerated().sorted { lhs, rhs in
                if lhs.element.grams != rhs.element.grams {
                    return lhs.element.grams > rhs.element.grams
                }
                return lhs.offset < rhs.offset   // Swift's sort is not stable
            }
            return Row(machineId: key, name: r.name, color: r.color, jobs: r.jobs,
                       grams: r.grams, hours: r.hours, scraps: r.scraps,
                       scrapGrams: r.scrapGrams, scrapCost: r.scrapCost,
                       scrapRate: handled > 0 ? r.scrapGrams / handled : nil,
                       worstFault: ranked.first.map { Fault(type: $0.element.type,
                                                            grams: $0.element.grams) })
        }

        let kept = built.enumerated().filter { $0.element.jobs > 0 || $0.element.scraps > 0 }
        // WORST RATE FIRST, not most grams — ranking by grams always names the
        // busiest machine, which is the wrong printer to sell.
        let ranked = kept.sorted { lhs, rhs in
            let a = lhs.element.scrapRate ?? -1, b = rhs.element.scrapRate ?? -1
            if a != b { return a > b }
            if lhs.element.scrapGrams != rhs.element.scrapGrams {
                return lhs.element.scrapGrams > rhs.element.scrapGrams
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        let grams = ranked.reduce(0) { $0 + $1.grams }
        let scrapGrams = ranked.reduce(0) { $0 + $1.scrapGrams }
        let handled = grams + scrapGrams
        return Report(rows: ranked, totals: Totals(
            jobs: ranked.reduce(0) { $0 + $1.jobs },
            grams: grams, scrapGrams: scrapGrams,
            scraps: ranked.reduce(0) { $0 + $1.scraps },
            scrapCost: ranked.reduce(0) { $0 + $1.scrapCost },
            scrapRate: handled > 0 ? scrapGrams / handled : nil,
            worst: ranked.first { $0.scrapRate != nil && $0.scraps > 0 && $0.jobs >= 2 }))
    }
}
