import Foundation

/// How many times each library model has been printed, and when last, read
/// off the JOBS — ported from `lib/print-history.js`, which is the
/// specification (and says why; `PrintHistoryParityTests` holds the two
/// together).
///
/// In short: a record's own `timesPrinted`/`lastPrinted` were only ever written
/// by the desktop's manual "log a print" button, so on the Mac — which has no
/// such button — every model read "never printed". A FINISHED job (`completed`,
/// or a legacy literal `delivered`), not voided, whose part names the model in
/// `printFileId`, is one print of it, whatever the part's quantity (that is
/// `copies`). `merge` takes the larger of the record's counter and the jobs',
/// so a desktop shop's logged prints are neither lost nor counted twice.
///
/// O(jobs). Worked out once per book read, never per draw.
public enum PrintHistory {

    public struct Entry: Sendable, Hashable, Codable {
        public var timesPrinted = 0
        public var copies = 0
        public var timesFailed = 0
        /// As the job wrote it (`completedAt`, else `deliveredAt`, `shippedAt`,
        /// `date`); nil when none of those reads as an instant.
        public var lastPrinted: String?
        public var lastJobId: String?
        public init(timesPrinted: Int = 0, copies: Int = 0, timesFailed: Int = 0,
                    lastPrinted: String? = nil, lastJobId: String? = nil) {
            self.timesPrinted = timesPrinted; self.copies = copies; self.timesFailed = timesFailed
            self.lastPrinted = lastPrinted; self.lastJobId = lastJobId
        }
    }

    public struct Merged: Sendable, Hashable, Codable {
        public let timesPrinted: Int
        public let timesFailed: Int
        public let lastPrinted: String?
        public init(timesPrinted: Int, timesFailed: Int, lastPrinted: String?) {
            self.timesPrinted = timesPrinted; self.timesFailed = timesFailed; self.lastPrinted = lastPrinted
        }
    }

    static let finished: Set<String> = ["completed", "delivered"]
    static let when = ["completedAt", "deliveredAt", "shippedAt", "date"]

    /// `instant(v)`: only text is read.
    static func instant(_ v: JSONValue?) -> Double? {
        guard case .string(let s)? = v, !s.isEmpty else { return nil }
        return JSDate.parse(s)
    }
    static func instant(_ s: String?) -> Double? {
        guard let s, !s.isEmpty else { return nil }
        return JSDate.parse(s)
    }

    /// When a finished job printed, as the book wrote it.
    public static func printedAt(_ order: [String: JSONValue]) -> String? {
        for k in when where instant(order[k]) != nil {
            if case .string(let s)? = order[k] { return s }
        }
        return nil
    }

    static func failures(_ order: [String: JSONValue]) -> Int {
        var defects = 0
        if case .array(let list)? = order["defects"] {
            defects = list.count { if case .object = $0 { true } else { false } }
        }
        let flagged: Bool
        if JSSemantics.truthy(order["qcStatus"]) {
            if case .string("fail")? = order["qcStatus"] { flagged = true } else { flagged = false }
        } else {
            flagged = JSSemantics.truthy(order["qcFailedAt"]) && !JSSemantics.truthy(order["qcPassedAt"])
        }
        return max(defects, flagged ? 1 : 0)
    }

    static func qty(_ part: [String: JSONValue]) -> Int {
        let q = JSSemantics.number(part["qty"])
        guard q.isFinite, q >= 1 else { return 1 }
        return q >= Double(Int.max) ? Int.max : Int(q.rounded(.down))
    }

    /// Every model's history, keyed by print-file id. A model no job has
    /// printed or failed is absent.
    public static func byFile(_ orders: [JSONValue]) -> [String: Entry] {
        var out: [String: Entry] = [:]
        for row in orders {
            guard case .object(let order) = row, !JSSemantics.truthy(order["voidedAt"]) else { continue }
            // Ids in the order the job lists them, each with its copies.
            var ids: [String] = []
            var copies: [String: Int] = [:]
            if case .array(let parts)? = order["parts"] {
                for case .object(let p) in parts {
                    guard case .string(let id)? = p["printFileId"], !id.isEmpty else { continue }
                    if copies[id] == nil { ids.append(id) }
                    copies[id, default: 0] &+= qty(p)
                }
            }
            guard !ids.isEmpty else { continue }
            var done = false
            if case .string(let s)? = order["status"] { done = finished.contains(s) }
            let failed = failures(order)
            guard done || failed > 0 else { continue }
            let at = done ? printedAt(order) : nil
            let atMs = instant(at)
            var jobId: String?
            if case .string(let s)? = order["id"], !s.isEmpty { jobId = s }
            for id in ids {
                var e = out[id] ?? Entry()
                e.timesFailed &+= failed
                if done {
                    e.timesPrinted &+= 1
                    e.copies &+= copies[id] ?? 1
                    if let atMs, e.lastPrinted == nil || atMs > (instant(e.lastPrinted) ?? -.infinity) {
                        e.lastPrinted = at
                        e.lastJobId = jobId
                    }
                }
                out[id] = e
            }
        }
        return out
    }

    /// A stored counter: a whole number, or 0.
    static func count(_ v: JSONValue?) -> Int {
        guard case .number(let n)? = v, n.isFinite, n > 0 else { return 0 }
        return n >= Double(Int.max) ? Int.max : Int(n.rounded(.down))
    }

    /// What a record shows: the larger of its own counters and the jobs', and
    /// the later of the two last-printed instants.
    public static func merge(timesPrinted: JSONValue?, timesFailed: JSONValue?, lastPrinted: JSONValue?,
                             entry: Entry?) -> Merged {
        var own: String?
        if case .string(let s)? = lastPrinted, !s.isEmpty { own = s }
        let derived = entry?.lastPrinted.flatMap { $0.isEmpty ? nil : $0 }
        var last = own
        if let b = instant(derived) {
            // A stored value that will not parse loses to one that does.
            if let a = instant(own) { if b > a { last = derived } } else { last = derived }
        }
        return Merged(timesPrinted: max(count(timesPrinted), entry?.timesPrinted ?? 0),
                      timesFailed: max(count(timesFailed), entry?.timesFailed ?? 0),
                      lastPrinted: last)
    }

    /// `merge` for a record as a `JSONValue` row.
    public static func merge(record: JSONValue?, entry: Entry?) -> Merged {
        guard case .object(let r)? = record else {
            return merge(timesPrinted: nil, timesFailed: nil, lastPrinted: nil, entry: entry)
        }
        return merge(timesPrinted: r["timesPrinted"], timesFailed: r["timesFailed"],
                     lastPrinted: r["lastPrinted"], entry: entry)
    }
}
