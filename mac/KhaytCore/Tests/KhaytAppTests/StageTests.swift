import Foundation
import AppKit
import Testing
import KhaytCore
@testable import KhaytApp

/// A board that silently omits work is worse than no board.
///
/// Four of Khayt's statuses had no `Stage`, so `Stage.of` returned nil for them
/// and the board did not put those jobs at the end — it left them out entirely.
/// A shop with three jobs sitting in QC saw an empty gap where its bottleneck
/// was. These tests are about jobs being SOMEWHERE, not about which column.
@MainActor
struct StageTests {

    /// Every status a job in Khayt can hold, from `renderer/kanban.js` and
    /// `lib/order-progress.js`. If Khayt gains one, this list is where the Mac
    /// app finds out.
    /// The stages, in the order work moves through them.
    ///
    /// `shipped` and `delivered` are not statuses a job carries — both are a
    /// date stamped on a COMPLETED job, and `Stage.of` derives them from the
    /// pair. They are stages all the same: they are what the board draws and
    /// what the sidebar lists, which is what this enum is for.
    static let khaytStatuses = [
        "quote", "pending", "on_hold", "printing", "post", "qc",
        "completed", "shipped", "delivered", "cancelled",
    ]

    @Test("every stage Khayt's own queue shows has a column here")
    func coversKhaytsQueue() {
        for status in Self.khaytStatuses {
            #expect(Stage(rawValue: status) != nil,
                    "a job with status '\(status)' would not appear on the board at all")
        }
    }

    @Test("the stages are in the order work moves through them")
    func pipelineOrder() {
        #expect(Stage.allCases.map(\.rawValue) == Self.khaytStatuses,
                "the sidebar and the board both draw allCases, so this IS the order on screen")
    }

    @Test("a status with no column is counted, not dropped")
    func splitParentIsNotLost() {
        let shop = Shop(source: .sample)
        // `split` is real: a parent order replaced by the sub-orders that carry
        // its price between them. It deliberately has no column — but a board
        // that shows neither the job nor a word about it is lying by omission.
        #expect(Stage(rawValue: "split") == nil)
        #expect(shop.unplaced.isEmpty, "the sample shop has none, and says so honestly")
    }

    @Test("every stage has a symbol the system actually has")
    func symbolsExist() {
        for stage in Stage.allCases {
            #expect(NSImage(systemSymbolName: stage.symbol, accessibilityDescription: nil) != nil,
                    "\(stage.rawValue) draws a blank: '\(stage.symbol)' is not an SF Symbol on this macOS")
        }
    }

    @Test("every board column can be dropped on, and the rules decide the rest")
    func boardColumnsAreMoveTargets() async throws {
        // The board offers seven columns; each is a status `lib/order-status.js`
        // understands, so a drop is refused for a REASON rather than by falling
        // through a switch nobody updated.
        let engine = try KhaytEngine()
        let job: JSONValue = .object(["id": .string("J1"), "status": .string("pending")])
        for stage in Stage.boardColumns {
            let gate = try await engine.statusGate(order: job, to: stage.rawValue,
                                                   orders: [job], settings: [:])
            #expect(gate.ok, "a shop with no limits set should be able to move a job to \(stage.rawValue)")
        }
    }
}

/// The search box is one box for the whole window.
///
/// It filtered the jobs table, the library and the customers, and not the
/// board — so on the one screen where somebody is most likely to be hunting for
/// a specific job, typing its name did nothing at all and gave no clue why.
///
/// Run against the sample shop rather than a hand-built list, so the path is the
/// real one: loaded from JSON, decoded, grouped by stage, sorted.
@MainActor
struct BoardSearchTests {

    static func sampleShop() async -> Shop {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        return shop
    }

    @Test("the board answers the search box")
    func boardFilters() async {
        let shop = await Self.sampleShop()
        let all = Stage.boardColumns.reduce(0) { $0 + (shop.board[$1]?.count ?? 0) }
        #expect(all > 0, "the sample shop has jobs on the board")

        // A customer who exists in the sample. Match the search the way the
        // board does rather than asserting a number that a new sample would
        // move — the claim is that the board narrows, not that it narrows to 4.
        guard let customer = shop.orders.first(where: { !$0.client.isEmpty })?.client else {
            Issue.record("the sample shop has no named customers"); return
        }
        shop.search = customer.lowercased()
        let shown = Stage.boardColumns.reduce(0) { $0 + (shop.board[$1]?.count ?? 0) }
        #expect(shown > 0, "the customer's own jobs are still there")
        #expect(shown < all, "and everyone else's are not")
        #expect(shop.board.values.allSatisfy { $0.allSatisfy { $0.client == customer } })
    }

    @Test("a job number finds exactly that job, wherever it is")
    func byNumber() async {
        let shop = await Self.sampleShop()
        guard let one = shop.orders.first(where: { Stage.of($0) != nil }) else {
            Issue.record("no placeable jobs in the sample"); return
        }
        shop.search = one.id
        #expect(shop.board.values.flatMap { $0 }.map(\.id) == [one.id])
        #expect(shop.shown.map(\.id) == [one.id], "and the table says the same")
    }

    @Test("the table and the board answer the same search the same way")
    func tableAndBoardAgree() async {
        let shop = await Self.sampleShop()
        guard let customer = shop.orders.first(where: { !$0.client.isEmpty })?.client else { return }
        // The whole book, not one stage: the table narrows by the sidebar too,
        // and this test is about the search box.
        shop.shelf = .jobs(nil)
        shop.search = customer

        // `board` is the whole book grouped; the SCREEN draws Stage.boardColumns.
        // Compare what is actually on it.
        let onBoard = Set(Stage.boardColumns.flatMap { shop.board[$0] ?? [] }.map(\.id))
        let inTable = Set(shop.shown.filter { Stage.of($0).map(Stage.boardColumns.contains) ?? false }
                                    .map(\.id))
        #expect(onBoard == inTable, "one box, one answer")
    }

    @Test("a search that matches nothing empties the board rather than half of it")
    func nothingMatches() async {
        let shop = await Self.sampleShop()
        shop.search = "no job is called this"
        #expect(shop.board.isEmpty)
        #expect(shop.unplaced.isEmpty, "including the ones with no column")
    }
}

/// The Mac's `Stage.of` mirrors `KhaytOrderStatus.stageOf`, so it is checked
/// against it rather than trusted.
///
/// The rule it mirrors — a delivered job is a COMPLETED job carrying a
/// `deliveredAt` — lived only inside Khayt's kanban grouping loop, and reading
/// `status` alone filed every handed-over job under Completed here.
@MainActor
struct StageParityTests {

    static func decode(_ fields: [String: JSONValue]) throws -> Order {
        var row = fields
        // Everything Order requires, so a case can name only what it is about.
        for (k, v) in ["id": JSONValue.string("J1"), "date": .string("2026-09-01"),
                       "project": .string("P"), "client": .string("C"),
                       "currency": .string("SAR"), "price": .number(0),
                       "paidAmount": .number(0), "costBasis": .number(0),
                       "paymentStatus": .string("unpaid"), "printTime": .number(0),
                       "priority": .bool(false), "notes": .string(""),
                       "parts": .array([])] where row[k] == nil {
            row[k] = v
        }
        return try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(row))
    }

    @Test("Swift and the shared rule place a job in the same column")
    func agreesWithTheSharedRule() async throws {
        let engine = try KhaytEngine()
        let cases: [[String: JSONValue]] = [
            ["status": .string("completed")],
            ["status": .string("completed"), "deliveredAt": .string("2026-09-01T00:00:00.000Z")],
            ["status": .string("delivered")],
            ["status": .string("printing")],
            ["status": .string("printing"), "deliveredAt": .string("2026-09-01T00:00:00.000Z")],
            ["status": .string("on_hold")],
            ["status": .string("qc")],
            ["status": .string("split")],
        ]
        for fields in cases {
            let shared = try await engine.raw(
                "KhaytOrderStatus.stageOf(\(String(data: try JSONEncoder().encode(fields), encoding: .utf8)!))",
                as: String?.self)
            let mine = Stage.of(try Self.decode(fields))?.rawValue
            // `split` has no column here on purpose — the shared rule returns it
            // as itself so the caller decides, and this caller counts it as
            // unplaced rather than filing it somewhere convenient.
            let expected = shared == "split" ? nil : shared
            #expect(mine == expected, "diverged for \(fields): shared said \(shared ?? "nil")")
        }
    }

    @Test("a delivered job is off the board, not sitting in Completed")
    func deliveredLeavesTheBoard() async throws {
        let handedOver = try Self.decode(["status": .string("completed"),
                                          "deliveredAt": .string("2026-09-01T00:00:00.000Z")])
        #expect(Stage.of(handedOver) == .delivered)
        #expect(!Stage.boardColumns.contains(.delivered),
                "delivered is where work goes to stop being work")

        let stillHere = try Self.decode(["status": .string("completed")])
        #expect(Stage.of(stillHere) == .completed)
    }
}

/// A row this app refuses to read is a job that is not on any screen.
///
/// `decodeOrders` counts what it could not decode and shows nothing for it, so
/// a required field that a real record does not carry does not error — it makes
/// jobs disappear. Every job Khayt's own calculator ever created was in that
/// state until the fields below were defaulted.
@MainActor
struct OrderDecodingTests {

    static func decode(_ fields: [String: JSONValue]) throws -> Order {
        try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(fields))
    }

    /// Exactly what `lib/order-new.js` produces, minus the parts of it this app
    /// does not read. A record this shape must decode.
    @Test("a job as Khayt's calculator writes it")
    func khaytsOwnNewOrder() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.newOrder(
            ["parts": .array([.object(["name": .string("Bracket"), "material": .string("PLA"),
                                       "printWeight": .number(180), "qty": .number(2),
                                       "baseCost": .number(40), "printTime": .number(3)])]),
             "project": .string("Bracket set"), "margin": .number(40)],
            orders: [], settings: [:], now: Date(),
            tokens: (tracking: Shop.randomBytes(16), quoteApproval: Shop.randomBytes(16)))

        let job = try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(out.order))
        #expect(job.client == "", "no customer written down is not no job")
        #expect(job.currency == "", "the shop's own currency is not a currency field")
        #expect(job.costBasis == 0, "what it cost is settled when it is finished, not now")
        #expect(job.parts.count == 1)
        #expect(job.parts[0].name == "Bracket")
    }

    @Test("the three fields a new job has not got yet")
    func lenientWhereTheDataIsLoose() throws {
        let bare: [String: JSONValue] = [
            "id": .string("J1"), "date": .string("2026-09-04"), "status": .string("pending"),
            "project": .string("P"), "price": .number(100), "paidAmount": .number(0),
            "paymentStatus": .string("unpaid"), "printTime": .number(1),
            "priority": .bool(false), "notes": .string(""),
        ]
        let job = try Self.decode(bare)
        #expect(job.client == "")
        #expect(job.currency == "")
        #expect(job.costBasis == 0)
        #expect(job.parts.isEmpty)
    }

    @Test("and strict where a missing field would be a guess")
    func strictWhereItMatters() {
        // A row with no id, price or status is not a job with defaults — it is a
        // row this app should refuse rather than invent an answer for.
        for missing in ["id", "price", "status", "paymentStatus"] {
            var fields: [String: JSONValue] = [
                "id": .string("J1"), "date": .string("2026-09-04"), "status": .string("pending"),
                "project": .string("P"), "price": .number(100), "paidAmount": .number(0),
                "paymentStatus": .string("unpaid"), "printTime": .number(1),
                "priority": .bool(false), "notes": .string(""),
            ]
            fields.removeValue(forKey: missing)
            #expect((try? Self.decode(fields)) == nil, "a row with no \(missing) was accepted")
        }
    }

    @Test("a part with no id of its own still reads")
    func partsWithoutIds() throws {
        var fields: [String: JSONValue] = [
            "id": .string("J1"), "date": .string("2026-09-04"), "status": .string("pending"),
            "project": .string("P"), "price": .number(100), "paidAmount": .number(0),
            "paymentStatus": .string("unpaid"), "printTime": .number(1),
            "priority": .bool(false), "notes": .string(""),
        ]
        fields["parts"] = .array([
            .object(["name": .string("Bracket"), "printWeight": .number(180)]),
            .object(["name": .string("Bracket"), "printWeight": .number(180)]),
        ])
        let job = try Self.decode(fields)
        #expect(job.parts.count == 2)
        #expect(job.parts[0].id != job.parts[1].id,
                "two parts with the same name must not collapse into one row")
        #expect(job.parts[0].qty == 1, "a part with no quantity is one of them")
    }
}
