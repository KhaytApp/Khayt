import Foundation

/// How much of the shop's work passes inspection first time — ported to Swift.
///
/// Pass rate is the easy figure and the less useful one: a shop that reprints
/// until it passes has a pass rate near 100% and a quality problem.
/// FIRST-PASS YIELD is the honest number — of the jobs that went through QC,
/// how many were right the first time — and a reprint chain collapses to its
/// root, so a job reprinted three times counts once.
public enum QcMetrics {

    public struct Defect: Sendable, Equatable {
        public let type: String
        public let count: Int
    }

    public struct Metrics: Sendable, Equatable {
        public let qcd: Int
        public let passed: Int
        public let failed: Int
        /// NULL, not nought. Nought renders as "everything failed" about a
        /// shop that has simply never inspected anything.
        public let passRate: Double?
        public let roots: Int
        public let firstPass: Int
        public let firstPassYield: Double?
        public let defectsByType: [String: Int]
        /// The commonest defect — the actionable half. A shop can go and do
        /// something about "layer shift" and nothing about a percentage.
        public let worstDefect: Defect?
        public let rmaCount: Int
        public let rmaCost: Double
    }

    /// Where an order stands with QC, from whichever field recorded it.
    ///
    /// `qcStatus` first, then the timestamps, then the stage. A job sitting AT
    /// the QC stage is `pending`, which is neither a pass nor a fail and must
    /// not be counted as either.
    ///
    /// Whatever `qcStatus` holds is returned as-is when it is truthy — the
    /// original does not check that it is one of the words it knows, so a
    /// misspelled status is neither a pass nor a fail rather than being
    /// coerced into one.
    public static func status(of order: JSONValue?) -> String? {
        guard case .object(let o)? = order else { return nil }
        if JSSemantics.truthy(o["qcStatus"]) { return JSSemantics.text(o["qcStatus"]) }
        if JSSemantics.truthy(o["qcPassedAt"]) { return "pass" }
        if JSSemantics.truthy(o["qcFailedAt"]) { return "fail" }
        if case .string("qc")? = o["status"] { return "pending" }
        return nil
    }

    public static func metrics(_ orders: [JSONValue]) -> Metrics {
        let list = orders.filter(JSSemantics.truthy)
        let inspected = list.filter { status(of: $0) == "pass" || status(of: $0) == "fail" }
        let passed = inspected.count { status(of: $0) == "pass" }

        // A reprint chain is ONE job for yield. A job reprinted three times and
        // passing on the fourth is one job that failed first time, not three
        // passes and a fail.
        //
        // The key is `o.reprintChain || o.id` and it goes into a `Set`, which
        // compares by VALUE AND TYPE — so a chain named `7` and one named `"7"`
        // are two roots. Kept by tagging the text with its type rather than
        // folding both to a string.
        var roots = Set<String>()
        for order in inspected {
            guard case .object(let o) = order else { continue }
            let key = JSSemantics.truthy(o["reprintChain"]) ? o["reprintChain"] : o["id"]
            roots.insert(typed(key))
        }
        let firstPass = list.count { row in
            guard case .object(let o) = row else { return false }
            return !JSSemantics.truthy(o["reprintOf"]) && status(of: row) == "pass"
        }

        // Insertion order is kept because `Object.entries` is ordered, and the
        // sort below is stable — so two defect types on the same count come
        // out in the order the book first mentioned them.
        var defectOrder: [String] = []
        var defects: [String: Int] = [:]
        for row in list {
            guard case .object(let o) = row, case .array(let found)? = o["defects"] else { continue }
            for defect in found {
                var kind = "other"
                if case .object(let d) = defect, JSSemantics.truthy(d["type"]) {
                    kind = JSSemantics.text(d["type"])
                }
                if defects[kind] == nil { defectOrder.append(kind) }
                defects[kind, default: 0] += 1
            }
        }

        let rmaCount = list.count { row in
            guard case .object(let o) = row else { return false }
            return JSSemantics.truthy(o["rma"])
        }
        // What the shop ate putting a warranty job right — the cost of the
        // replacement, not what the customer was charged, which was nothing.
        let rmaCost = list.reduce(0.0) { total, row in
            guard case .object(let o) = row, case .string("rma")? = o["reprintReason"]
            else { return total }
            let n = JSSemantics.number(o["costBasis"])
            return total + (n.isFinite ? n : 0)
        }

        return Metrics(
            qcd: inspected.count,
            passed: passed,
            failed: inspected.count - passed,
            passRate: inspected.isEmpty ? nil : Double(passed) / Double(inspected.count),
            roots: roots.count,
            firstPass: firstPass,
            firstPassYield: roots.isEmpty ? nil : Double(firstPass) / Double(roots.count),
            defectsByType: defects,
            worstDefect: worst(defects, order: defectOrder),
            rmaCount: rmaCount,
            rmaCost: JSSemantics.round(rmaCost * 100) / 100)
    }

    /// The heaviest defect, by `Object.entries(...).sort((a, b) => b[1] - a[1])`.
    ///
    /// ── AND `Object.entries` IS NOT INSERTION ORDER ───────────────────────
    ///
    /// A JavaScript object lists its ARRAY-INDEX-LIKE keys first, in ascending
    /// numeric order, and only then the rest in insertion order. So a shop
    /// whose defect list happens to contain `"2"` — a type named for a nozzle,
    /// say — has it enumerated before `"layer shift"` however late it was
    /// added. With a stable sort that changes which defect is called the worst
    /// on a tie.
    ///
    /// Reproduced rather than assumed: the parity test puts numeric-looking
    /// type names in the corpus for exactly this.
    static func worst(_ counts: [String: Int], order: [String]) -> Defect? {
        let enumerated = jsKeyOrder(order)
        guard !enumerated.isEmpty else { return nil }
        let best = enumerated.enumerated()
            .min { lhs, rhs in
                let a = counts[lhs.element] ?? 0, b = counts[rhs.element] ?? 0
                if a != b { return a > b }
                return lhs.offset < rhs.offset     // stable
            }
        guard let key = best?.element else { return nil }
        return Defect(type: key, count: counts[key] ?? 0)
    }

    /// The order a JavaScript object enumerates these keys in.
    ///
    /// Array indices — a canonical decimal integer below 2³²−1, written with
    /// no sign, no leading zero and no fractional part — come first in
    /// ascending numeric order; everything else follows in insertion order.
    static func jsKeyOrder(_ inserted: [String]) -> [String] {
        var indices: [(UInt32, String)] = []
        var rest: [String] = []
        for key in inserted {
            if let n = arrayIndex(key) { indices.append((n, key)) } else { rest.append(key) }
        }
        return indices.sorted { $0.0 < $1.0 }.map(\.1) + rest
    }

    /// `key` as an array index, or nil if it is not one.
    static func arrayIndex(_ key: String) -> UInt32? {
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        // "01" is not an array index; "0" is. The canonical spelling is the
        // only one that counts.
        if key.count > 1 && key.hasPrefix("0") { return nil }
        guard let n = UInt32(key), n != UInt32.max else { return nil }
        return n
    }

    /// A value tagged with its type, so a `Set` separates `7` from `"7"` the
    /// way JavaScript's does.
    private static func typed(_ value: JSONValue?) -> String {
        switch value {
        case .string(let s): return "s:" + s
        case .number(let n): return "n:" + JSSemantics.string(n)
        case .bool(let b): return "b:\(b)"
        case .array, .object: return "o:" + JSSemantics.text(value)
        case .none, .null: return "u:"
        }
    }
}
