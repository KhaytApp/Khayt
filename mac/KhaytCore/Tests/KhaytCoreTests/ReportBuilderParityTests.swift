import Foundation
import Testing
@testable import KhaytCore

/// A shop's own report, against the JavaScript it came from.
///
/// The CSV half matters more than it looks: a cell beginning `=` is a formula
/// to a spreadsheet, and a shop's project names are exactly the free text that
/// contains a comma, a quote or a newline.
@MainActor
struct ReportBuilderParityTests {

    private func js() throws -> JSModule { try JSModule(["report-builder"]) }

    private func theirs(_ js: JSModule, _ records: [JSONValue], _ spec: JSONValue)
        throws -> ReportBuilder.Report {
        let v = try js.value("KhaytReportBuilder.buildReport(ARG0, ARG1)", [.array(records), spec])
        guard case .object(let o) = v else { Issue.record("not an object"); throw CancellationError() }
        func texts(_ k: String) -> [String] {
            guard case .array(let rows)? = o[k] else { return ["<missing>"] }
            return rows.map { if case .string(let s) = $0 { return s } else { return "<not text>" } }
        }
        var rows: [[JSONValue]] = []
        if case .array(let raw)? = o["rows"] {
            rows = raw.map { row in if case .array(let cells) = row { return cells } else { return [] } }
        }
        return .init(headers: texts("headers"), keys: texts("keys"), rows: rows)
    }

    private func check(_ records: [JSONValue], _ spec: JSONValue, _ what: String,
                       _ js: JSModule) throws {
        var fields: [String] = [], statusIn: [JSONValue] = [], from = "", to = ""
        var labels: [String: JSONValue] = [:]
        if case .object(let s) = spec {
            if case .array(let f)? = s["fields"] {
                fields = f.map { if case .string(let k) = $0 { return k } else { return "\($0)" } }
            }
            if case .array(let st)? = s["statusIn"] { statusIn = st }
            if case .string(let f)? = s["from"] { from = f }
            if case .string(let t)? = s["to"] { to = t }
            if case .object(let l)? = s["labels"] { labels = l }
        }
        let mine = ReportBuilder.build(records: records, fields: fields, statusIn: statusIn,
                                       from: from, to: to, labels: labels)
        let theirs = try theirs(js, records, spec)
        #expect(mine == theirs, Comment(rawValue: """
            \(what)
              swift \(mine.headers) \(mine.rows)
              js    \(theirs.headers) \(theirs.rows)
            """))
    }

    private func order(_ id: String, date: String, status: String,
                       price: Double, tags: [String] = []) -> JSONValue {
        .object(["id": .string(id), "date": .string(date), "status": .string(status),
                 "price": .number(price), "client": .string("Salem"),
                 "paymentStatus": .string("paid"),
                 "tags": .array(tags.map(JSONValue.string))])
    }

    private var book: [JSONValue] {
        [order("A-1", date: "2026-09-01", status: "completed", price: 240, tags: ["resin", "mini"]),
         order("A-2", date: "2026-09-15T10:00:00Z", status: "printing", price: 0),
         order("A-3", date: "2026-08-31", status: "completed", price: 1200.5),
         order("A-4", date: "2026-10-01", status: "cancelled", price: 75),
         .object(["id": .string("A-5")])]
    }

    @Test("the columns a report starts with are the same list")
    func fieldsMatch() throws {
        let js = try js()
        let v = try js.value("KhaytReportBuilder.FIELDS", [])
        guard case .array(let rows) = v else { Issue.record("not an array"); return }
        #expect(rows.count == ReportBuilder.fields.count)
        for (row, mine) in zip(rows, ReportBuilder.fields) {
            guard case .object(let o) = row else { Issue.record("row"); continue }
            #expect(o["key"] == .string(mine.key))
            #expect(o["label"] == .string(mine.label), Comment(rawValue: "label of \(mine.key)"))
        }
        #expect(try js.value("KhaytReportBuilder.DEFAULT_FIELDS", [])
                == .array(ReportBuilder.defaultFields.map(JSONValue.string)))
        #expect(try js.value("KhaytReportBuilder.FIELD_KEYS", [])
                == .array(ReportBuilder.fieldKeys.map(JSONValue.string)))
    }

    @Test("a report of everything, and one of nothing")
    func wholeBook() throws {
        let js = try js()
        try check(book, .object([:]), "no spec at all", js)
        try check(book, .object(["fields": .array([])]), "an empty field list", js)
        try check([], .object([:]), "no records", js)
        try check(book, .object(["fields": .array(ReportBuilder.fieldKeys.map(JSONValue.string))]),
                  "every column", js)
    }

    @Test("a column that is not a column is dropped, and one asked twice is drawn twice")
    func unknownFields() throws {
        let js = try js()
        try check(book, .object(["fields": .array([.string("id"), .string("nope"),
                                                   .string("price"), .string("id")])]),
                  "one unknown, one twice", js)
        try check(book, .object(["fields": .array([.string("nope")])]),
                  "nothing but unknowns", js)
    }

    @Test("the date range is inclusive at both ends and reads only the first ten characters")
    func dateRange() throws {
        let js = try js()
        for (from, to) in [("2026-09-01", ""), ("", "2026-09-01"),
                           ("2026-09-01", "2026-09-30"), ("2026-09-15", "2026-09-15"),
                           ("2026-10-02", "2026-01-01"), ("", ""),
                           ("2026-09-15T23:00:00Z", "2026-09-15T01:00:00Z")] {
            try check(book, .object(["from": .string(from), "to": .string(to)]),
                      "\(from.debugDescription)…\(to.debugDescription)", js)
        }
    }

    @Test("a status filter of nothing means every status")
    func statusFilter() throws {
        let js = try js()
        try check(book, .object(["statusIn": .array([])]), "an empty filter", js)
        try check(book, .object(["statusIn": .array([.string("completed")])]), "one status", js)
        try check(book, .object(["statusIn": .array([.string("completed"), .string("cancelled")])]),
                  "two statuses", js)
        try check(book, .object(["statusIn": .array([.string("nope")])]), "a status nobody has", js)
        try check(book, .object(["statusIn": .array([.null])]), "a filter of null", js)
    }

    @Test("a header the shop renamed, and one it blanked")
    func labels() throws {
        let js = try js()
        try check(book, .object(["fields": .array([.string("id"), .string("price")]),
                                 "labels": .object(["id": .string("رقم الطلب")])]),
                  "one renamed", js)
        // An empty label is not a header, so the built-in one stands.
        try check(book, .object(["fields": .array([.string("id"), .string("price")]),
                                 "labels": .object(["id": .string(""), "price": .null])]),
                  "blanked", js)
        try check(book, .object(["fields": .array([.string("id")]),
                                 "labels": .object(["id": .number(0)])]), "a zero label", js)
    }

    @Test("a list of tags becomes one cell")
    func tagsJoin() throws {
        let js = try js()
        try check([.object(["tags": .array([.string("a"), .string("b")])]),
                   .object(["tags": .array([])]),
                   .object(["tags": .array([.null, .string("b"), .number(3)])]),
                   .object(["tags": .string("not a list")]),
                   .object([:])],
                  .object(["fields": .array([.string("tags")])]), "tags", js)
    }

    @Test("records that are not records")
    func degenerateRecords() throws {
        let js = try js()
        // `null` is left out: the original throws on it and takes the whole
        // report with it, which is the one thing this port refuses to copy.
        try check([.string("x"), .number(1), .bool(true), .array([]), .object([:])],
                  .object([:]), "primitives", js)
        #expect(ReportBuilder.build(records: [.null, .object(["id": .string("A")])],
                                    fields: ["id"]).rows.count == 1)
    }

    // MARK: - CSV

    private func checkCsv(_ headers: [JSONValue], _ rows: [[JSONValue]],
                          _ what: String, _ js: JSModule) throws {
        let mine = ReportBuilder.csv(headers: headers, rows: rows)
        let theirs = try js.value("KhaytReportBuilder.reportToCsv({headers: ARG0, rows: ARG1})",
                                  [.array(headers), .array(rows.map(JSONValue.array))])
        #expect(.string(mine) == theirs, Comment(rawValue: "\(what)\n  swift \(mine.debugDescription)"))
    }

    @Test("a cell that would run as a formula is neutralised")
    func formulaCells() throws {
        let js = try js()
        try checkCsv([.string("Project")],
                     [[.string("=1+1")], [.string("+1")], [.string("-1")], [.string("@SUM(A1)")],
                      [.string("\tstart")], [.string("\rstart")], [.string("\nstart")],
                      [.string("normal")], [.string("")], [.string("a=b")]],
                     "formulas", js)
    }

    @Test("free text with the characters that break a CSV")
    func awkwardText() throws {
        let js = try js()
        try checkCsv([.string("a"), .string("b")],
                     [[.string("one, two"), .string("he said \"hi\"")],
                      [.string("line\nbreak"), .string("crlf\r\nhere")],
                      [.string("\"\"\""), .string("زهرة, ورد")],
                      [.string("emoji 🌸"), .string("tab\there")]],
                     "awkward text", js)
    }

    @Test("a number prints the way JavaScript prints one")
    func numberCells() throws {
        let js = try js()
        try checkCsv([.string("n")],
                     [[.number(1)], [.number(1.5)], [.number(0)], [.number(-0.5)],
                      [.number(1e21)], [.number(1e-7)], [.number(1234567.25)],
                      [.bool(true)], [.bool(false)], [.null], [.string("7")],
                      [.array([.string("a"), .string("b")])], [.object([:])]],
                     "numbers and the rest", js)
    }

    @Test("an empty table is still a header line with a byte-order mark")
    func emptyCsv() throws {
        let js = try js()
        try checkCsv([], [], "nothing at all", js)
        try checkCsv([.string("a")], [], "headers only", js)
        #expect(ReportBuilder.csv(headers: [String](), rows: []).hasPrefix("\u{FEFF}"))
    }
}
