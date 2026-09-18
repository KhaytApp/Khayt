import Foundation

/// How long a spool stays print-ready after drying — ported to Swift.
///
/// Filaments are hygroscopic: they reabsorb atmospheric moisture and then
/// print wet — stringing, popping, brittle parts. How fast depends on the
/// polymer and how it is stored. These intervals are conservative rules of
/// thumb with drying temperatures below each material's glass transition, and
/// they exist to nudge "dry this again soon". They are guidance, not a spec,
/// and the module's own note says so.
public enum FilamentDryness {

    public struct Spec: Sendable, Equatable {
        /// Re-dry interval spooled in open room air.
        public let openDays: Double
        /// In a sealed box or bag WITH active desiccant — a drybox.
        public let sealedDays: Double
        /// A safe default drying recipe for the add form.
        public let dryTempC: Double
        public let dryHours: Double
    }

    public static let materials: [String: Spec] = [
        "PLA":   Spec(openDays: 14, sealedDays: 90,  dryTempC: 45, dryHours: 6),
        "PETG":  Spec(openDays: 10, sealedDays: 75,  dryTempC: 65, dryHours: 6),
        "TPU":   Spec(openDays: 3,  sealedDays: 30,  dryTempC: 50, dryHours: 8),
        "NYLON": Spec(openDays: 1,  sealedDays: 20,  dryTempC: 70, dryHours: 12),
        "PA":    Spec(openDays: 1,  sealedDays: 20,  dryTempC: 70, dryHours: 12),
        "ABS":   Spec(openDays: 20, sealedDays: 120, dryTempC: 65, dryHours: 4),
        "ASA":   Spec(openDays: 20, sealedDays: 120, dryTempC: 65, dryHours: 4),
        "PC":    Spec(openDays: 4,  sealedDays: 30,  dryTempC: 80, dryHours: 8),
        "PVA":   Spec(openDays: 1,  sealedDays: 14,  dryTempC: 45, dryHours: 8),
    ]

    public static let fallback = Spec(openDays: 10, sealedDays: 60, dryTempC: 55, dryHours: 6)

    public struct Status: Sendable, Equatable {
        /// `good`, `due`, `overdue` or `unknown`.
        public let state: String
        /// Nil when the spool has never been dried — which is not the same as
        /// dried a long time ago.
        public let daysSince: Double?
        public let intervalDays: Double
        public let pct: Double
    }

    /// Free text to a material key: "PLA Matte" → PLA, "PA6-CF" → PA.
    ///
    /// ── THE NYLON TEST COMES FIRST, AND IT IS A REGEX ─────────────────────
    ///
    /// `/NYLON|\bPA\d*\b|\bPA-|\bPA\b/` — word boundaries, so "PA6" and
    /// "PA-CF" are nylon while "SPAGHETTI" and "PAINT" are not. Checked before
    /// the substring loop because that loop would otherwise find "PA" inside
    /// nothing but would find "PC" inside "PC-ABS" — the ORDER of that list is
    /// load-bearing too, and it is the original's order.
    public static func materialKey(_ material: JSONValue?) -> String? {
        let s = JSSemantics.truthy(material) ? JSSemantics.text(material).uppercased() : ""
        if isNylon(s) { return "PA" }
        for key in ["PETG", "PLA", "TPU", "ABS", "ASA", "PVA", "PC"] where s.contains(key) {
            return key
        }
        return nil
    }

    /// The word-boundary test, written out rather than run as a regex.
    ///
    /// `\b` is a boundary between a word character — letter, digit or
    /// underscore — and anything else, including the ends of the string.
    static func isNylon(_ s: String) -> Bool {
        if s.contains("NYLON") { return true }
        let chars = Array(s)
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < chars.count else { return false }
            let c = chars[i]
            return c == "_" || (c.isASCII && (c.isLetter || c.isNumber))
        }
        var i = 0
        while i + 1 < chars.count {
            defer { i += 1 }
            guard chars[i] == "P", chars[i + 1] == "A", !isWord(i - 1) else { continue }
            // `\bPA-` — a hyphen straight after needs no closing boundary.
            var end = i + 2
            if end < chars.count && chars[end] == "-" { return true }
            // `\bPA\d*\b` — any digits, then a boundary.
            while end < chars.count, chars[end].isASCII, chars[end].isNumber { end += 1 }
            if !isWord(end) { return true }
        }
        return false
    }

    public static func spec(for material: JSONValue?) -> Spec {
        guard let key = materialKey(material), let spec = materials[key] else { return fallback }
        return spec
    }

    /// Storage kinds that keep filament dry. Anything else is room air.
    public static func isSealed(_ storage: JSONValue?) -> Bool {
        guard case .string(let s)? = storage else { return false }
        return s == "drybox" || s == "sealed"
    }

    /// Where a tracked spool stands now.
    ///
    /// `unknown` when it has never been dried, which is deliberately not the
    /// same as overdue: a spool nobody has recorded a drying for is a spool
    /// nobody knows about, and calling that overdue would fill the screen with
    /// alarms about shelves the shop has not started tracking.
    public static func status(of record: JSONValue?, now: Double) -> Status {
        let spec = spec(for: { if case .object(let r)? = record { return r["material"] }
                               return nil }())
        let storage: JSONValue? = { if case .object(let r)? = record { return r["storage"] }
                                    return nil }()
        let interval = isSealed(storage) ? spec.sealedDays : spec.openDays

        let driedAt: JSONValue? = { if case .object(let r)? = record { return r["driedAt"] }
                                    return nil }()
        // `new Date(rec.driedAt)` takes a NUMBER as milliseconds and a string
        // through the date parser — the book holds both.
        var dried: Double?
        if JSSemantics.truthy(driedAt) {
            if case .number(let ms)? = driedAt { dried = ms }
            else { dried = JSDate.parse(JSSemantics.text(driedAt)) }
        }
        guard let dried, dried.isFinite else {
            return Status(state: "unknown", daysSince: nil, intervalDays: interval, pct: 0)
        }
        // Never negative: a drying recorded in the future is a typo, and a
        // negative age would read as freshly dried for ever.
        let daysSince = Swift.max(0, (now - dried) / 86_400_000)
        let pct = interval > 0 ? daysSince / interval : 1
        let state = pct < 0.75 ? "good" : (pct < 1 ? "due" : "overdue")
        return Status(state: state, daysSince: daysSince, intervalDays: interval, pct: pct)
    }
}
