import Foundation
import Testing
@testable import KhaytApp
@testable import KhaytCore

/// Grouping the proposed queue by colour: `lib/swap-queue.js` through the
/// engine, and what the Mac hands it and does with the answer.
@MainActor
struct SwapPlanningTests {

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static func job(_ id: String, _ colours: [String], hours: Double = 1, due: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "material": .string("PLA"), "printTime": .number(hours),
            "colors": .array(colours.map { .object(["hex": .string($0)]) }),
        ]
        if let due { o["dueDate"] = .string(due) }
        return .object(o)
    }

    static let u1: [KhaytEngine.LoadedSlot] = ["#D32F2F", "#1565C0", "#FFFFFF", "#111111"]
        .enumerated().map { KhaytEngine.LoadedSlot(slot: $0.offset, hex: $0.element, material: "PLA") }

    @Test("the engine groups a U1's queue by what is loaded, and says what it saves")
    func throughTheEngine() async throws {
        let engine = try KhaytEngine()
        let other = ["#2E7D32", "#F9A825", "#EF6C00", "#8C9099"]
        let plan = try await engine.swapQueue(
            jobs: [Self.job("flag", other), Self.job("mug", ["#D32F2F", "#1565C0", "#FFFFFF", "#111111"]),
                   Self.job("sign", other), Self.job("key", ["#D32F2F", "#FFFFFF"])],
            loaded: Self.u1, heads: 4, swapMinutes: 3, startHours: 0)
        #expect(plan.order == ["mug", "key", "flag", "sign"])
        #expect(plan.changed)
        #expect(plan.current.swaps == 14)
        #expect(plan.proposed.swaps == 4)
        #expect(plan.saved.swaps == 10)
        #expect(plan.saved.minutes == 30)
        let flag = try #require(plan.jobs.first { $0.id == "flag" })
        #expect(flag.swapsPlanned == 4)
        let mug = try #require(plan.jobs.first { $0.id == "mug" })
        #expect(mug.swapsNow == 4 && mug.swapsPlanned == 0 && mug.delta == -4)
    }

    @Test("a job due today is not pushed late to save changes")
    func deadlinesFirst() async throws {
        let engine = try KhaytEngine()
        let other = ["#2E7D32", "#F9A825", "#EF6C00", "#8C9099"]
        // Midnight at the start of the due day, in the zone the JavaScript
        // reads `dueDate` in (the process's own), so the test holds anywhere.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone.current
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let due = "2026-09-26"
        let start = try #require(local.date(from: due + "T00:00:00"))
        // A 22-hour job ends before midnight only if it goes first (22 h +
        // 12 min, against 3 h more behind a loaded-colour job).
        let plan = try await engine.swapQueue(
            jobs: [Self.job("rush", other, hours: 22, due: due),
                   Self.job("mug", ["#D32F2F", "#1565C0"], hours: 3)],
            loaded: Self.u1, heads: 4, swapMinutes: 3, startHours: 0, now: start)
        #expect(plan.order == ["rush", "mug"])
        #expect(!plan.changed)
        // And it is the due date doing that: without one, the loaded-colour
        // job goes first.
        let free = try await engine.swapQueue(
            jobs: [Self.job("rush", other, hours: 22), Self.job("mug", ["#D32F2F", "#1565C0"], hours: 3)],
            loaded: Self.u1, heads: 4, swapMinutes: 3, startHours: 0, now: start)
        #expect(free.order == ["mug", "rush"])
    }

    @Test("the settings field starts where the rule does, and the shop's figure wins")
    func minutesSetting() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.swapMinutes(settings: [:]) == OperationsPane.swapMinutesDefault)
        #expect(try await engine.swapMinutes(settings: ["swapMinutes": .number(5)]) == 5)
        #expect(try await engine.swapMinutes(settings: ["swapMinutes": .number(500)]) == 60)
        let draft = OperationsPane.Draft.read([:], shop: Shop())
        #expect(draft.swapMinutes == OperationsPane.swapMinutesDefault)
        #expect(draft.form()["swapMinutes"] == .number(OperationsPane.swapMinutesDefault))
    }

    @Test("a job's colours come from its models, and a hex written on a part")
    func whatAJobNeeds() throws {
        let file = try Self.decode(LibraryFile.self, """
        {"id":"PF-1","name":"Flag","colors":[{"hex":"#FF0000","grams":3},{"hex":"#00FF00"},{"grams":1}]}
        """)
        let job = try Self.decode(Order.self, """
        {"id":"J-1","date":"2026-09-20","project":"Flags","status":"pending","printTime":2.5,"priority":true,
         "price":100,"paidAmount":0,"paymentStatus":"unpaid","notes":"",
         "priorityLevel":"high","dueDate":"2026-09-30",
         "parts":[{"id":"p1","name":"flag","material":"PLA","qty":1,"printFileId":"PF-1","colour":"red"},
                  {"id":"p2","name":"base","material":"PLA","qty":1,"colour":"#0000FF"},
                  {"id":"p3","name":"tag","material":"PLA","qty":1,"colour":"white"}]}
        """)
        guard case .object(let o) = Shop.swapJob(job, library: ["PF-1": file]) else {
            Issue.record("not an object"); return
        }
        #expect(o["colors"] == .array([.object(["hex": .string("#FF0000")]),
                                       .object(["hex": .string("#00FF00")]),
                                       .object(["hex": .string("#0000FF")])]))
        #expect(o["material"] == .string("PLA"))
        #expect(o["printTime"] == .number(2.5))
        #expect(o["dueDate"] == .string("2026-09-30"))
        #expect(o["priorityLevel"] == .string("high"))
        #expect(o["priority"] == .bool(true))
    }

    @Test("a toolchanger has as many heads as colours, and a U1's four when nothing says")
    func heads() throws {
        #expect(Shop.heads(nil, loaded: []) == 4)
        #expect(Shop.heads(nil, loaded: Array(Self.u1.prefix(2))) == 2)
        let single = try Self.decode(Machine.self, #"{"id":"M","name":"Mini","maxColors":1}"#)
        #expect(Shop.heads(single, loaded: Self.u1) == 1)
    }

    @Test("grouping reorders jobs within a machine and keeps each machine's slots")
    func groupedKeepsSlots() async throws {
        let rows = try Self.decode([KhaytEngine.SchedulePlan.Assignment].self, """
        [{"orderId":"a","machineId":"U1","position":0,"projectedFinishMins":1,"reason":"x"},
         {"orderId":"x","machineId":"X1","position":0,"projectedFinishMins":1,"reason":"x"},
         {"orderId":"b","machineId":"U1","position":1,"projectedFinishMins":2,"reason":"x"},
         {"orderId":"c","machineId":"U1","position":2,"projectedFinishMins":3,"reason":"x"}]
        """)
        let engine = try KhaytEngine()
        let plan = try await engine.swapQueue(
            jobs: [Self.job("a", ["#2E7D32"]), Self.job("b", ["#D32F2F"]), Self.job("c", ["#2E7D32"])],
            loaded: [KhaytEngine.LoadedSlot(slot: 0, hex: "#D32F2F", material: "PLA")],
            heads: 1, swapMinutes: 3, startHours: 0)
        #expect(plan.order == ["b", "a", "c"])
        let shown = Shop.grouped(rows, ["U1": plan])
        #expect(shown.map(\.orderId) == ["b", "x", "a", "c"])
        #expect(shown.map(\.machineId) == ["U1", "X1", "U1", "U1"])
        // Nothing to change: the list is the scheduler's.
        #expect(Shop.grouped(rows, [:]).map(\.orderId) == ["a", "x", "b", "c"])
    }

    @Test("every word the panel says is in both languages")
    func words() async throws {
        for key in ["mac.swap_changes", "mac.swap_changes_one", "mac.swap_saves", "mac.swap_adds",
                    "mac.swap_adds_one", "mac.swap_group", "mac.swap_estimate",
                    "mac.swap_minutes", "mac.swap_minutes_hint"] {
            #expect(Words.own[key]?["en"]?.isEmpty == false, "\(key) en")
            #expect(Words.own[key]?["ar"]?.isEmpty == false, "\(key) ar")
        }
        let en = Words()
        await en.load("en", engine: try KhaytEngine())
        #expect(en.counting(1, "mac.swap_adds") == "adds 1 colour change")
        #expect(en.counting(3, "mac.swap_adds") == "adds 3 colour changes")
        let ar = Words()
        await ar.load("ar", engine: try KhaytEngine())
        #expect(ar.counting(1, "mac.swap_changes") == "تبديل لون واحد")
        let line = ar.callIt("mac.swap_saves", ["changes": .string(ar.counting(3, "mac.swap_changes")),
                                                  "min": .number(9)])
        #expect(!line.contains("{"), "a placeholder was left in: \(line)")
    }
}
