import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What can run together on one plate.
///
/// The packer itself is `lib/plate-nesting.js` and is tested in Node; what is
/// checked here is everything between it and the shop — that the module is in
/// the bundle at all, that a job is handed over as the weight it really is, and
/// that the work offered for planning is the work that could actually be
/// printed.
@MainActor
struct BatchPlannerTests {

    static func job(_ id: String, status: String = "pending", hours: Double = 1,
                    parts: [(Double, Int, String)] = []) throws -> Order {
        let row: [String: JSONValue] = [
            "id": .string(id), "date": .string("2026-09-01"), "status": .string(status),
            "project": .string("P-" + id), "client": .string("Acme"), "price": .number(100),
            "paidAmount": .number(0), "paymentStatus": .string("unpaid"),
            "printTime": .number(hours), "priority": .bool(false), "notes": .string(""),
            "parts": .array(parts.map { grams, qty, material in
                .object(["id": .string("PT"), "name": .string("part"),
                         "material": .string(material), "qty": .number(Double(qty)),
                         "printWeight": .number(grams), "unitCost": .number(1),
                         "colour": .string("")])
            }),
        ]
        return try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(row))
    }

    // MARK: - The packer, through the bundle

    @Test("the packer is in the bundle and groups by material")
    func materialsAreNotMixed() async throws {
        // A plate cannot carry two filaments, and the whole feature is worthless
        // if this app's copy of the bundle does not carry the module at all —
        // which is exactly what it did not, until now.
        let engine = try KhaytEngine()
        let plan = try await engine.planPlates(jobs: [
            .init(id: "A", project: "A", hours: 2, grams: 100, material: "PLA"),
            .init(id: "B", project: "B", hours: 2, grams: 100, material: "PETG"),
            .init(id: "C", project: "C", hours: 2, grams: 100, material: "PLA"),
        ], maxHours: 24, maxGrams: 1000)

        #expect(plan.totalJobs == 3)
        #expect(plan.totalPlates == 2, "PLA and PETG cannot share a plate")
        let pla = try #require(plan.plates.first { $0.material == "PLA" })
        #expect(pla.jobs.count == 2)
        #expect(pla.hours == 4)
        #expect(pla.grams == 200)
    }

    @Test("a plate is filled to its limits and then a second one is opened")
    func platesFillThenSpill() async throws {
        let engine = try KhaytEngine()
        let plan = try await engine.planPlates(jobs: [
            .init(id: "A", project: "A", hours: 8, grams: 100, material: "PLA"),
            .init(id: "B", project: "B", hours: 8, grams: 100, material: "PLA"),
            .init(id: "C", project: "C", hours: 8, grams: 100, material: "PLA"),
        ], maxHours: 20, maxGrams: 1000)
        #expect(plan.totalPlates == 2, "24 hours of work does not fit a 20-hour plate")
        #expect(plan.plates.map(\.jobs.count).sorted() == [1, 2])
    }

    @Test("a job too big for a plate gets one of its own, and says so")
    func oversizeIsFlaggedNotDropped() async throws {
        // The rule flags it rather than dropping it, and that is the behaviour
        // worth keeping: a planner that quietly loses a job is worse than none.
        let engine = try KhaytEngine()
        let plan = try await engine.planPlates(jobs: [
            .init(id: "BIG", project: "Big", hours: 40, grams: 100, material: "PLA"),
            .init(id: "A", project: "A", hours: 2, grams: 100, material: "PLA"),
        ], maxHours: 24, maxGrams: 1000)
        #expect(plan.totalJobs == 2, "nothing was dropped")
        let big = try #require(plan.plates.first { $0.oversize })
        #expect(big.jobs.map(\.id) == ["BIG"])
        #expect(plan.plates.filter { !$0.oversize }.count == 1)
    }

    @Test("the weight limit packs as well as the clock")
    func gramsAreALimitToo() async throws {
        let engine = try KhaytEngine()
        let plan = try await engine.planPlates(jobs: [
            .init(id: "A", project: "A", hours: 1, grams: 600, material: "PLA"),
            .init(id: "B", project: "B", hours: 1, grams: 600, material: "PLA"),
        ], maxHours: 24, maxGrams: 1000)
        #expect(plan.totalPlates == 2, "1,200 g does not go on a 1,000 g plate")
    }

    // MARK: - What a job is handed over as

    @Test("a job's weight is its parts', quantity included")
    func weightCountsEveryCopy() throws {
        // A job's own record carries no weight. Packing on a per-part figure
        // fits four copies of something in the space of one.
        let job = try Self.job("J1", hours: 3, parts: [(120, 4, "PLA"), (30, 1, "PLA")])
        let handed = Shop.plateJob(job)
        #expect(handed.grams == 510)
        #expect(handed.hours == 3)
        #expect(handed.material == "PLA")
        #expect(handed.project == "P-J1")
    }

    @Test("a part with no material named does not become the job's material")
    func materialIsTheFirstOneNamed() throws {
        let job = try Self.job("J1", parts: [(10, 1, ""), (10, 1, "PETG")])
        #expect(Shop.plateJob(job).material == "PETG")
    }

    @Test("a job with no parts is planned as nothing, not refused")
    func partlessJobsStillPlan() throws {
        let job = try Self.job("J1", hours: 2, parts: [])
        let handed = Shop.plateJob(job)
        #expect(handed.grams == 0)
        #expect(handed.hours == 2)
        #expect(handed.material == "")
    }

    // MARK: - What is offered for planning

    @Test("finished work, quotes and written-off jobs are not planned")
    func candidatesAreWorkStillToPrint() throws {
        let jobs = [
            try Self.job("A", status: "pending"),
            try Self.job("B", status: "printing"),
            try Self.job("C", status: "completed"),
            // `delivered` is PAST completed and stays out — testing only for
            // "completed" left every delivered job in the planner for ever.
            try Self.job("D", status: "delivered"),
            try Self.job("E", status: "quote"),
            try Self.job("F", status: "pending"),
        ]
        let out = Shop.planCandidates(jobs, voided: ["F"])
        #expect(out.map(\.id) == ["A", "B"])
    }

    @Test("a written-off job is found by its mark, not by its status")
    func voidedIsReadOffTheRecord() {
        let rows: [JSONValue] = [
            .object(["id": .string("A"), "voidedAt": .string("2026-09-01")]),
            .object(["id": .string("B"), "voidedAt": .null]),
            .object(["id": .string("C")]),
        ]
        #expect(Shop.voidedIds(rows) == ["A"])
    }

    @Test("what a plate holds is the rule's number, not a Swift copy of it")
    func limitsComeFromTheRule() async throws {
        // 24 hours and 1,000 g were typed into the Swift as well as read from
        // the packer. Two copies of one constant is one that goes stale.
        let engine = try KhaytEngine()
        let limits = try await engine.plateDefaults()
        #expect(limits.maxHours > 0)
        #expect(limits.maxGrams > 0)

        // And a plate really is packed to them: a job an hour over the limit
        // gets a plate of its own.
        let plan = try await engine.planPlates(jobs: [
            .init(id: "A", project: "A", hours: limits.maxHours + 1, grams: 10, material: "PLA"),
        ], maxHours: limits.maxHours, maxGrams: limits.maxGrams)
        #expect(plan.plates.first?.oversize == true)
    }

    // MARK: - Wiring    // MARK: - Wiring

    @Test("the app actually offers it")
    func theAppReachesTheRule() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let menus = try String(contentsOf: sources.appending(path: "Menus.swift"), encoding: .utf8)
        let window = try String(contentsOf: sources.appending(path: "ShopWindow.swift"), encoding: .utf8)
        #expect(menus.contains("shop.planningBatch = true"), "no menu item opens the planner")
        #expect(window.contains("BatchSheet(shop: shop)"), "the sheet is never presented")
    }
}
