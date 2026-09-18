import Foundation

/// A shop's own report: pick columns, filter, and render a table it can export.
///
/// The records are already flattened by `report-records` — client and machine
/// names resolved, money converted — so nothing here looks anything up. This
/// selects columns, applies the filters, and escapes the CSV.
public enum ReportBuilder {

    /// A column a report can carry. `key` matches the flattened record field;
    /// `label` is the default English header, which a caller may localise.
    public struct Field: Sendable, Equatable, Hashable, Identifiable {
        public let key: String
        public let label: String
        public var id: String { key }
    }

    public static let fields: [Field] = [
        .init(key: "id", label: "Order #"),
        .init(key: "date", label: "Date"),
        .init(key: "project", label: "Project"),
        .init(key: "client", label: "Client"),
        .init(key: "status", label: "Status"),
        .init(key: "material", label: "Material"),
        .init(key: "printTime", label: "Print Time (h)"),
        .init(key: "machine", label: "Machine"),
        .init(key: "price", label: "Price"),
        .init(key: "paidAmount", label: "Paid"),
        .init(key: "balance", label: "Balance"),
        .init(key: "paymentStatus", label: "Payment"),
        .init(key: "dueDate", label: "Due Date"),
        .init(key: "tags", label: "Tags"),
    ]

    public static let fieldKeys: [String] = fields.map(\.key)

    public static let defaultFields = ["id", "date", "client", "status", "price", "paymentStatus"]

    /// `String(d ?? '').slice(0, 10)` — a date key, by which two records are
    /// compared and a range is applied.
    ///
    /// `slice` counts UTF-16 code units, not characters, so this does too. A
    /// date is ASCII and the two agree; a field holding something else might
    /// be cut mid-pair, and a lone surrogate is what JavaScript would carry
    /// forward.
    static func dateKey(_ value: JSONValue?) -> String {
        let units = Array(JSSemantics.text(value).utf16.prefix(10))
        return String(decoding: units, as: UTF16.self)
    }

    /// `a < b` on two JavaScript strings — a comparison of UTF-16 code units,
    /// NOT Swift's `<`, which orders by Unicode canonical equivalence. Date
    /// keys are ASCII and the two agree there, but the rule is what it is and
    /// a report filtered on some other field should filter the same way.
    static func less(_ a: String, _ b: String) -> Bool {
        var l = a.utf16.makeIterator(), r = b.utf16.makeIterator()
        while true {
            switch (l.next(), r.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case (let x?, let y?):
                if x != y { return x < y }
            }
        }
    }

    public struct Report: Sendable, Equatable {
        public let headers: [String]
        /// The field each column IS, in the same order. A table that knows a
        /// column holds money can print it as money; one that only has the
        /// header has to guess from a translated word.
        public let keys: [String]
        public let rows: [[JSONValue]]
        public var count: Int { rows.count }
    }

    public static func build(records: [JSONValue], fields wanted: [String] = [],
                             statusIn: [JSONValue] = [], from: String = "", to: String = "",
                             labels: [String: JSONValue] = [:]) -> Report {
        let asked = wanted.isEmpty ? defaultFields : wanted
        let keys = asked.filter { fieldKeys.contains($0) }
        let from = from.isEmpty ? "" : dateKey(.string(from))
        let to = to.isEmpty ? "" : dateKey(.string(to))
        // An empty list means "every status", not "no statuses".
        let wantedStatus: Set<JSONValue>? = statusIn.isEmpty ? nil : Set(statusIn)

        var rows: [[JSONValue]] = []
        for record in records {
            // `r.date` on a primitive reads as undefined and the row comes out
            // empty; on `null` the original throws and takes the whole report
            // with it. A crash is not worth reproducing, so a null row is
            // skipped — the one deliberate divergence here.
            var r: [String: JSONValue] = [:]
            switch record {
            case .object(let o): r = o
            case .null: continue
            default: break
            }
            let d = dateKey(r["date"])
            if !from.isEmpty && less(d, from) { continue }
            if !to.isEmpty && less(to, d) { continue }
            // A record with no `status` at all reads as `undefined`, which a
            // Set built from the shop's chosen statuses can never hold — and
            // `undefined` is NOT `null` to `Set.has`. So a missing status is
            // filtered out rather than matching a filter of `[null]`.
            if let wantedStatus {
                guard let status = r["status"], wantedStatus.contains(status) else { continue }
            }
            rows.append(keys.map { key in
                switch r[key] {
                case .array(let items):
                    // `v.join(', ')`, which prints null and undefined as empty
                    // rather than as their names.
                    return .string(items.map { item in
                        if case .null = item { return "" }
                        return JSSemantics.text(item)
                    }.joined(separator: ", "))
                case .none, .null: return .string("")
                case .some(let v): return v
                }
            })
        }

        // `(spec.labels && spec.labels[k]) || … || k` — a label that is empty
        // falls through to the built-in one, because `||` tests truthiness and
        // an empty header is not a header.
        func labelOf(_ key: String) -> String {
            if let given = labels[key], JSSemantics.truthy(given) { return JSSemantics.text(given) }
            if let field = fields.first(where: { $0.key == key }), !field.label.isEmpty {
                return field.label
            }
            return key
        }

        return Report(headers: keys.map(labelOf), keys: keys, rows: rows)
    }

    // MARK: - Spreadsheet-safe CSV

    /// One cell: BOM-free, quoted, and formula-neutralised.
    ///
    /// A cell beginning `=`, `+`, `-`, `@`, a tab or a carriage return is a
    /// FORMULA to a spreadsheet, and a shop's project names are exactly the
    /// sort of free text that starts with one. The leading apostrophe is what
    /// stops Excel running it.
    static func cell(_ value: JSONValue?) -> String {
        // A NUMBER RETURNS EARLY, before the formula guard — `-1` is a
        // negative number, not a formula, and quoting it with a leading
        // apostrophe would make a spreadsheet read the shop's money as text.
        // The original's early return says the same thing by doing it; the
        // parity harness caught this port neutralising `-0.5`.
        if case .number(let n)? = value { return "\"" + JSSemantics.string(n) + "\"" }
        let text = JSSemantics.text(value)
        let unsafe = text.unicodeScalars.first.map { "=+-@\t\r".unicodeScalars.contains($0) } ?? false
        let safe = (unsafe ? "'" : "") + text
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The whole table. A byte-order mark so Excel reads it as UTF-8, and CRLF
    /// line endings because that is what a spreadsheet expects.
    public static func csv(headers: [JSONValue], rows: [[JSONValue]]) -> String {
        var lines = [headers.map(cell).joined(separator: ",")]
        for row in rows { lines.append(row.map(cell).joined(separator: ",")) }
        return "\u{FEFF}" + lines.joined(separator: "\r\n")
    }

    public static func csv(headers: [String], rows: [[String]]) -> String {
        csv(headers: headers.map(JSONValue.string), rows: rows.map { $0.map(JSONValue.string) })
    }
}
