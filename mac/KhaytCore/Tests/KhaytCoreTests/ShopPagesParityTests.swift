import Foundation
import Testing
@testable import KhaytCore

/// The Nov 2026 parity batch, against the JavaScript the desktop runs: the
/// satisfaction card (`rating-trend summary`), closure dates (`working-week
/// holidays`), the environment log (`env-log`), the storefront's visitors and
/// reviews (`storefront-insights`), the AI spend panel (`ai-usage`), and the
/// cloud calls that fetch them.
@MainActor
struct ShopPagesParityTests {

    nonisolated private static func rated(_ r: JSONValue) -> JSONValue { .object(["survey": .object(["rating": r])]) }

    // MARK: - The satisfaction card

    @Test("the summary agrees with lib/rating-trend.js, field for field",
          arguments: [
            [JSONValue](),
            [5, 5, 5, 4, 3, 1].map { rated(.number($0)) },
            [rated(.string("5")), rated(.number(4)), rated(.number(0)), rated(.null), .object([:])],
            [rated(.number(4.5)), rated(.number(3.4)), rated(.number(2.5)), rated(.number(6))],
            // A negative NPS that lands on a half: JavaScript rounds -16.5 to -16.
            [1, 1, 1, 5, 5, 4].map { rated(.number($0)) }
                + [rated(.number(3)), rated(.number(5)), rated(.number(5)), rated(.number(2)),
                   rated(.number(2)), rated(.number(4))],
          ])
    func summaryParity(_ orders: [JSONValue]) throws {
        let js = try JSModule(["rating-trend"])
        let theirs = try js.value("KhaytRatingTrend.summary(ARG0)", [.array(orders)])
        let mine = RatingTrend.summary(orders: orders)
        guard case .object(let o) = theirs, case .array(let spread)? = o["spread"] else {
            Issue.record("not a summary"); return
        }
        #expect(mine.responses == Int(JSSemantics.number(o["responses"])))
        var avg: Double?; if case .number(let n)? = o["average"] { avg = n }
        #expect(mine.average == avg)
        var nps: Int?; if case .number(let n)? = o["nps"] { nps = Int(n) }
        #expect(mine.nps == nps)
        #expect(mine.promoters == Int(JSSemantics.number(o["promoters"])))
        #expect(mine.passives == Int(JSSemantics.number(o["passives"])))
        #expect(mine.detractors == Int(JSSemantics.number(o["detractors"])))
        let theirBars: [RatingTrend.Bar] = spread.map { b in
            guard case .object(let r) = b else { return .init(stars: -1, count: -1, pct: -1) }
            return .init(stars: Int(JSSemantics.number(r["stars"])), count: Int(JSSemantics.number(r["count"])),
                         pct: Int(JSSemantics.number(r["pct"])))
        }
        #expect(mine.spread == theirBars)
    }

    @Test("the bars add up to the responses, even with half stars")
    func barsAddUp() {
        let s = RatingTrend.summary(orders: [Self.rated(.number(4.5)), Self.rated(.number(3.4)), Self.rated(.number(1))])
        #expect(s.spread.reduce(0) { $0 + $1.count } == s.responses)
        #expect(s.spread.map(\.stars) == [5, 4, 3, 2, 1])
    }

    // MARK: - Closure dates

    @Test("holidays agree with lib/working-week.js", arguments: [
        JSONValue.object([:]), .null,
        .object(["holidays": .string("2026-01-01")]),
        .object(["holidays": .array([.string("2026-12-02"), .string("2026-09-23"), .string("soon"),
                                     .string("2026-13-01"), .number(42), .string("2026-09-23"),
                                     .string("2026-2-1"), .string("2026-09-24\n"), .string("٢٠٢٦-٠٩-٢٣")])]),
    ])
    func holidaysParity(_ settings: JSONValue) throws {
        let js = try JSModule(["working-week"])
        let theirs = try js.value("KhaytWorkingWeek.holidays(ARG0)", [settings])
        let mine = WorkingWeek.holidays(settings: settings)
        #expect(JSONValue.array(mine.map(JSONValue.string)) == theirs)
        for day in ["2026-09-23", "2026-09-24", ""] {
            let t = try js.value("KhaytWorkingWeek.isHoliday(ARG0, ARG1)", [settings, .string(day)])
            #expect(JSONValue.bool(WorkingWeek.isHoliday(settings: settings, day: day)) == t)
        }
    }

    // MARK: - Through the engine

    @Test("a reading is the desktop's record, and the checks say why")
    func envLog() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.envLogCheck(temperature: "", humidity: " ") == "env.need_value")
        #expect(try await engine.envLogCheck(temperature: "150", humidity: "") == "env.temp_range")
        #expect(try await engine.envLogCheck(temperature: "", humidity: "120") == "env.humidity_range")
        #expect(try await engine.envLogCheck(temperature: "21.5", humidity: "") == nil)

        let at = Date(timeIntervalSince1970: 1_793_000_000)
        let record = try await engine.envLogEntry(temperature: "21.5", humidity: "", machineId: "M1",
                                                  notes: " door open ", id: "ENV-x", now: at)
        guard case .object(let o) = record else { Issue.record("no record"); return }
        #expect(Set(o.keys) == ["id", "timestamp", "temperature", "humidity", "machineId", "notes"])
        #expect(o["temperature"] == .number(21.5) && o["humidity"] == .null)
        #expect(o["machineId"] == .string("M1") && o["notes"] == .string("door open"))
        #expect(o["timestamp"] == .string(StoreWriter.iso(at)))
        #expect(try await engine.envLogEntry(temperature: "", humidity: "", machineId: nil, notes: "",
                                             id: "x", now: at) == .null)
    }

    @Test("the log reads newest first and draws the last readings oldest first")
    func envLogView() async throws {
        let engine = try KhaytEngine()
        let rows: [JSONValue] = (1...4).map { i in
            .object(["id": .string("E\(i)"), "timestamp": .string("2026-11-0\(i)T09:00:00.000Z"),
                     "temperature": .number(Double(18 + i)), "humidity": .null, "machineId": .null,
                     "notes": .string("")])
        } + [.object(["id": .string("E5"), "timestamp": .string("2026-11-05T09:00:00.000Z"),
                      "temperature": .string("25"), "humidity": .number(40)])]
        let view = try await engine.envLogView(rows)
        #expect(view.recent.map(\.id) == ["E5", "E4", "E3", "E2", "E1"])
        #expect(view.recent.first?.temperature == 25, "a number written as text still reads")
        #expect(view.trend?.readings == [19, 20, 21, 22, 25])
        #expect(view.trend?.min == 19 && view.trend?.max == 25)
        #expect(try await engine.envLogView([]).trend == nil)
    }

    @Test("the funnel, the reviews and the link come from lib/storefront-insights.js")
    func storefront() async throws {
        let engine = try KhaytEngine()
        let stats: JSONValue = .object([
            "views": .number(300), "carts": .number(20), "orders": .number(7),
            "items": .array([
                .object(["id": .string("p1"), "name": .string("Vase"), "orders": .number(3), "carts": .number(5)]),
                .object(["id": .string("p2"), "orders": .number(0), "carts": .number(0)]),
                .object(["id": .string("p3"), "carts": .number(2)]),
            ]),
        ])
        let s = try await engine.storefrontInsights(stats)
        #expect(!s.empty && s.conversionPct == 2.3)
        #expect(s.top.map(\.id) == ["p1", "p3"] && s.top[1].name == "p3")
        #expect(try await engine.storefrontInsights(.object([:])).empty)

        let rows = try await engine.reviewRows(.array([
            .object(["id": .number(7), "rating": .number(4.6), "comment": .string("Great"),
                     "name": .string(" Sara "), "createdAt": .string("2026-11-02T08:00:00Z"), "verified": .bool(true)]),
            .object(["rating": .number(5)]),
        ]))
        #expect(rows == [KhaytEngine.ReviewRow(id: "7", stars: 5, comment: "Great", name: "Sara",
                                               day: "2026-11-02", verified: true)])
        #expect(try await engine.reviewLink(baseUrl: "https://cloud.example.com/", shopId: "shop_ab")
                == "https://cloud.example.com/review/shop_ab")
    }

    @Test("this month's AI spend, per feature, from the ledger the Mac records into")
    func aiSpend() async throws {
        let engine = try KhaytEngine()
        let now = Date()
        var ledger: JSONValue = .object([:])
        ledger = try await engine.aiUsageRecord(ledger: ledger, task: "library", model: "claude-opus-4-1",
                                                usage: .object(["input_tokens": .number(10_000),
                                                                "output_tokens": .number(2_000)]), now: now)
        ledger = try await engine.aiUsageRecord(ledger: ledger, task: "library", model: "claude-opus-4-1",
                                                usage: .object(["input_tokens": .number(1),
                                                                "output_tokens": .number(1)]), now: now)
        let spend = try await engine.aiSpend(settings: ["aiUsage": ledger], now: now)
        #expect(spend.rows.count == 1)
        #expect(spend.rows.first?.calls == 2)
        #expect(spend.rows.first?.task == "library")
        #expect(spend.total.hasPrefix("$"))
        #expect(try await engine.aiSpend(settings: [:], now: now).rows.isEmpty)
    }
}

/// The cloud calls behind the reviews, the funnel and the web address,
/// through the fetch seam.
struct CloudShopPagesTests {
    static let connection = CloudReader.Connection(url: "https://cloud.example.com", shopId: "shop_ab", storedToken: "")

    @Test("reviews: the owner's list, a delete by id, and the public summary")
    func reviews() async throws {
        let log = CloudTeamTests.Log()
        let list = try await CloudShopPages.reviews(Self.connection, token: "tok", fetch: CloudTeamTests.answering(
            200, #"{"reviews":[{"id":"r1","rating":5}]}"#, log: log))
        #expect(list == .array([.object(["id": .string("r1"), "rating": .number(5)])]))
        let r = try #require(log.requests.first)
        #expect(r.httpMethod == "GET" && r.url?.path == "/v1/shops/shop_ab/reviews/all")
        #expect(r.url?.query == "limit=50")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")

        try await CloudShopPages.deleteReview("r 1", Self.connection, token: "t",
                                              fetch: CloudTeamTests.answering(200, "{}", log: log))
        #expect(log.requests[1].httpMethod == "DELETE")
        #expect(log.requests[1].url?.absoluteString.hasSuffix("/v1/shops/shop_ab/reviews/r%201") == true)

        let summary = await CloudShopPages.reviewSummary(Self.connection, token: "t", fetch: CloudTeamTests.answering(
            200, #"{"count":12,"avg":4.6,"recent":[]}"#))
        #expect(summary == CloudShopPages.Summary(count: 12, average: 4.6))
        #expect(await CloudShopPages.reviewSummary(Self.connection, token: "t",
                                                   fetch: CloudTeamTests.answering(500, "{}")) == nil)
    }

    @Test("a refused list carries the cloud's own words")
    func refused() async throws {
        do {
            _ = try await CloudShopPages.reviews(Self.connection, token: "t", fetch: CloudTeamTests.answering(
                403, #"{"error":"Owner only","reason":"role"}"#))
            Issue.record("should have thrown")
        } catch let r as CloudShopPages.Refusal {
            #expect(r.status == 403 && r.error == "Owner only" && r.reason == "role")
        }
    }

    @Test("the funnel, and the web address read and claimed")
    func statsAndSlug() async throws {
        let log = CloudTeamTests.Log()
        let stats = try await CloudShopPages.storefrontStats(Self.connection, token: "t", fetch: CloudTeamTests.answering(
            200, #"{"views":3,"carts":1,"orders":0,"items":[]}"#, log: log))
        #expect(log.requests[0].url?.path == "/v1/shops/shop_ab/sfstats")
        if case .object(let o) = stats { #expect(o["views"] == .number(3)) } else { Issue.record("no stats") }

        let none = try await CloudShopPages.slug(Self.connection, token: "t",
                                                 fetch: CloudTeamTests.answering(200, #"{"slug":null}"#))
        #expect(none == CloudShopPages.Slug(slug: nil, graceDays: 90))
        let set = try await CloudShopPages.setSlug("  My-Shop ", Self.connection, token: "t",
                                                   fetch: CloudTeamTests.answering(200, #"{"slug":"my-shop"}"#, log: log))
        #expect(set == "my-shop")
        #expect(log.requests[1].httpMethod == "PUT" && log.requests[1].url?.path == "/v1/shops/shop_ab/slug")
        #expect(try JSONSerialization.jsonObject(with: log.requests[1].httpBody!) as? [String: String] == ["slug": "my-shop"])
        do {
            _ = try await CloudShopPages.setSlug("admin", Self.connection, token: "t", fetch: CloudTeamTests.answering(
                400, #"{"error":"That name is reserved."}"#))
            Issue.record("should have thrown")
        } catch let r as CloudShopPages.Refusal {
            #expect(r.error == "That name is reserved.")
        }
    }
}
