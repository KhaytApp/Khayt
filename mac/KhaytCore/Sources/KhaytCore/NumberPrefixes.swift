import Foundation

/// The two number prefixes a shop sets, and when Settings shows them as one.
///
/// `lib/number-prefixes.js`, ported so a settings field can ask synchronously
/// (and so the phone has it too — this is KhaytCore). `NumberPrefixesParityTests`
/// holds it to the JavaScript.
///
/// `invPrefix` starts a JOB's number; `invNumPrefix` starts the formal TAX
/// INVOICE number, off its own counter. Both stay — a reprint must show the
/// number that was issued — and nothing here renames or renumbers anything.
/// While they are equal as used (trimmed, blank read as `INV`), Settings shows
/// one "Invoice number prefix" that writes both; when they differ, "Job number
/// prefix" and "Tax invoice prefix". Decided Nov 9 2026.
public enum NumberPrefixes {
    public static let fallback = "INV"
    /// The longest prefix either app keeps.
    public static let max = 10

    public enum View: Equatable, Sendable {
        case shared(String)
        case split(job: String, taxInvoice: String)
    }

    /// As a numbering rule reads it: a string, trimmed; anything else is blank.
    static func used(_ v: JSONValue?) -> String {
        guard case .string(let s)? = v else { return fallback }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : t
    }

    /// As it is kept: trimmed, cut to `max` UTF-16 units (one back when the cut
    /// would leave half of a surrogate pair), `INV` when blank.
    public static func clean(_ v: String) -> String {
        var t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.utf16.count > max {
            var units = Array(t.utf16.prefix(max))
            if let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
            t = String(decoding: units, as: UTF16.self)
        }
        return t.isEmpty ? fallback : t
    }

    public static func view(_ settings: [String: JSONValue]) -> View {
        let job = used(settings["invPrefix"])
        let taxInvoice = used(settings["invNumPrefix"])
        return job == taxInvoice ? .shared(job) : .split(job: job, taxInvoice: taxInvoice)
    }

    /// The keys to write: both for the shared field, each given one when split.
    /// Never the counter, the format or anything already issued.
    public static func patch(shared: String) -> [String: JSONValue] {
        let v = clean(shared)
        return ["invPrefix": .string(v), "invNumPrefix": .string(v)]
    }

    public static func patch(job: String?, taxInvoice: String?) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if let job { out["invPrefix"] = .string(clean(job)) }
        if let taxInvoice { out["invNumPrefix"] = .string(clean(taxInvoice)) }
        return out
    }
}
