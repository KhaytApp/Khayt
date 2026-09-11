import Foundation
import Testing
@testable import KhaytCore

/// A shop's own question, through the engine.
///
/// `test/report-builder.test.js` and `test/report-records.test.js` pin the two
/// modules. What matters here is that the Mac app asks them TOGETHER and in the
/// right order — flatten, then select — because the wiring is the part that has
/// been wrong before: a correct module with no caller reads exactly like a
/// working feature until a shop ticks a box.
@Suite struct ReportBuilderTests {

    static func job(_ id: String, status: String, date: String,
                    price: Double, paid: Double, client: String = "C1",
                    project: String = "Bracket", voided: Bool = false) -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(id), "status": .string(status), "date": .string(date),
            "projectName": .string(project), "clientId": .string(client),
            "price": .number(price), "paidAmount": .number(paid),
        ]
        if voided { row["voidedAt"] = .string("2026-09-02T00:00:00.000Z") }
        return .object(row)
    }

    static let clients: [JSONValue] = [
        .object(["id": .string("C1"), "name": .string("Al Faisal Signs")]),
    ]

    static func build(_ engine: KhaytEngine, orders: [JSONValue],
                      fields: [String] = ["id", "client", "status", "price", "paymentStatus"],
                      statusIn: [String] = [], from: String = "", to: String = "")
        async throws -> KhaytEngine.Report {
        try await engine.buildReport(orders: orders, clients: clients, machines: [],
                               settings: [:], language: "en", fields: fields,
                               statusIn: statusIn, from: from, to: to, labels: [:])
    }

    @Test("the columns on offer come from the shared module, not from this app")
    func theFieldsAreTheModulesFields() async throws {
        let engine = try KhaytEngine()
        let keys = try await engine.reportFields().map(\.key)
        #expect(keys.contains("paymentStatus"))
        #expect(keys.contains("balance"))
        // Every default has to BE a field, or a report opens asking for a
        // column that does not exist.
        for key in try await engine.reportDefaultFields() { #expect(keys.contains(key)) }
    }

    @Test("a report names the client and works out what is still owed")
    func itResolvesNamesAndMoney() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.build(engine, orders: [
            Self.job("A-1", status: "completed", date: "2026-09-01", price: 1000, paid: 1000),
        ])
        let row = try #require(report.rows.first)
        #expect(row.contains("Al Faisal Signs"))
        #expect(row.contains("paid"))
        #expect(report.total == 1)
    }

    /// The rule that only exists because `report-records` was lifted out of the
    /// other app's renderer: a voided order is not a row. It was three lines
    /// inline there, and reimplementing them here would have been the whole
    /// risk of the feature.
    @Test("a voided order is not in the report at all")
    func voidedOrdersAreDropped() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.build(engine, orders: [
            Self.job("A-1", status: "completed", date: "2026-09-01", price: 1000, paid: 1000),
            Self.job("A-2", status: "completed", date: "2026-09-01", price: 500, paid: 0, voided: true),
        ])
        #expect(report.total == 1)
        #expect(report.rows.allSatisfy { !$0.contains("A-2") })
    }

    @Test("the status chips and the dates both narrow it")
    func theFiltersFilter() async throws {
        let engine = try KhaytEngine()
        let orders = [
            Self.job("A-1", status: "completed", date: "2026-08-01", price: 100, paid: 100),
            Self.job("A-2", status: "quote", date: "2026-09-01", price: 200, paid: 0),
            Self.job("A-3", status: "completed", date: "2026-09-05", price: 300, paid: 0),
        ]
        #expect(try await Self.build(engine, orders: orders, statusIn: ["completed"]).total == 2)
        #expect(try await Self.build(engine, orders: orders, from: "2026-09-01").total == 2)
        #expect(try await Self.build(engine, orders: orders,
                               statusIn: ["completed"], from: "2026-09-01").total == 1)
        // No chips ticked means no narrowing, not nothing — an empty filter is
        // the state the screen OPENS in.
        #expect(try await Self.build(engine, orders: orders).total == 3)
    }

    /// The stage list the screen draws has to be askable. Every `Stage` the
    /// board can show must be a status this can filter on, or a shop ticks a
    /// chip and silently gets an empty table.
    @Test("every stage the board draws can be asked for")
    func everyStageIsAskable() async throws {
        let engine = try KhaytEngine()
        for stage in ["quote", "pending", "on_hold", "printing", "post",
                      "qc", "completed", "delivered", "cancelled"] {
            let report = try await Self.build(engine, orders: [
                Self.job("A-1", status: stage, date: "2026-09-01", price: 100, paid: 0),
            ], statusIn: [stage])
            #expect(report.total == 1, "stage \(stage) filtered itself out")
        }
    }

    /// Not a Swift join, and this is why.
    @Test("a cell that a spreadsheet would run as a formula is escaped")
    func theCsvIsSafe() async throws {
        let engine = try KhaytEngine()
        let csv = try await engine.reportToCsv(
            headers: ["Job", "Project"],
            rows: [["A-1", "=cmd|'/c calc'!A0"], ["A-2", "Bracket, v2 \"final\""]])
        #expect(!csv.contains("\n=cmd"))
        #expect(!csv.contains(",=cmd"))
        #expect(csv.contains("\"\"final\"\""))
    }
}

/// Reports a shop named, through the engine.
///
/// `test/saved-reports.test.js` pins the rules. What this proves is that the
/// Mac app goes THROUGH them: the re-save rule is the whole reason the module
/// exists, and a Swift screen that pushed onto an array would look identical
/// until a shop corrected a report twice.
@Suite struct SavedReportTests {

    @Test("a store with junk in it still yields a list")
    func junkIsDropped() async throws {
        let engine = try KhaytEngine()
        let list = try await engine.savedReports(settings: ["savedReports": .array([
            .object(["id": .string("R1"), "name": .string("Monthly VAT"),
                     "fields": .array([.string("id")])]),
            .object(["id": .string("R2")]),
            .string("nope"),
        ])])
        #expect(list.map(\.id) == ["R1"])
        #expect(list[0].statusIn.isEmpty)
    }

    @Test("no saved reports at all is an empty list")
    func nothingSavedIsFine() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.savedReports(settings: [:]).isEmpty)
    }

    @Test("re-saving under a name already used replaces it rather than appending")
    func aResaveReplaces() async throws {
        let engine = try KhaytEngine()
        var list = try await engine.addSavedReport([], name: "Monthly VAT",
                                                   fields: ["id"], statusIn: [],
                                                   from: "", to: "", id: "R1")
        list = try await engine.addSavedReport(list, name: "Quotes out",
                                               fields: ["id"], statusIn: ["quote"],
                                               from: "", to: "", id: "R2")
        list = try await engine.addSavedReport(list, name: "monthly vat",
                                               fields: ["id", "balance"], statusIn: [],
                                               from: "2026-01-01", to: "", id: "R9")
        #expect(list.count == 2)
        #expect(list[0].id == "R1")
        #expect(list[0].fields == ["id", "balance"])
        #expect(list[0].from == "2026-01-01")
    }

    @Test("one can be thrown away, which the other app cannot do at all")
    func oneCanBeRemoved() async throws {
        let engine = try KhaytEngine()
        var list = try await engine.addSavedReport([], name: "A", fields: ["id"],
                                                   statusIn: [], from: "", to: "", id: "R1")
        list = try await engine.addSavedReport(list, name: "B", fields: ["id"],
                                               statusIn: [], from: "", to: "", id: "R2")
        list = try await engine.removeSavedReport(list, id: "R1")
        #expect(list.map(\.id) == ["R2"])
        // Two windows can remove the same one; the second is not an error.
        #expect(try await engine.removeSavedReport(list, id: "R1").map(\.id) == ["R2"])
    }

    /// A saved report is only worth saving if it comes back as the same table.
    @Test("a saved report reproduces the report it was saved from")
    func itComesBackTheSame() async throws {
        let engine = try KhaytEngine()
        let orders = [
            ReportBuilderTests.job("A-1", status: "completed", date: "2026-08-01", price: 100, paid: 100),
            ReportBuilderTests.job("A-2", status: "quote", date: "2026-09-01", price: 200, paid: 0),
        ]
        let before = try await ReportBuilderTests.build(
            engine, orders: orders, fields: ["id", "price"],
            statusIn: ["completed"], from: "2026-07-01", to: "2026-08-31")

        let list = try await engine.addSavedReport(
            [], name: "August, finished", fields: ["id", "price"],
            statusIn: ["completed"], from: "2026-07-01", to: "2026-08-31", id: "R1")
        let saved = try #require(list.first)
        let after = try await ReportBuilderTests.build(
            engine, orders: orders, fields: saved.fields,
            statusIn: saved.statusIn, from: saved.from, to: saved.to)

        #expect(after.rows == before.rows)
        #expect(after.headers == before.headers)
        #expect(after.total == 1)
    }
}
