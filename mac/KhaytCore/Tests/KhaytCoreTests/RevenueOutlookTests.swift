import Foundation
import Testing
@testable import KhaytCore

/// The numbers behind the dashboard's revenue chart.
///
/// The point of bridging `lib/forecast.js` rather than adding up months in
/// Swift is that Khayt's analytics screen draws from this same call with this
/// same money function. Two opinions about revenue is the one thing this whole
/// project exists to avoid, so the test that matters is the one against Node.
struct RevenueOutlookTests {

    static var repoRoot: URL { BundledLogicIsNotAForkTests.repoRoot }

    /// 2026-09-05T12:00:00Z, so the six complete months are Mar–Aug.
    static let now: Double = 1_788_609_600_000

    static let settings: [String: JSONValue] = ["currency": .string("SAR")]

    /// Orders across several months, in the shape the book holds them: a
    /// `completedAt`, a status that counts, and one that does not.
    static func book() -> [JSONValue] {
        func order(_ id: String, _ iso: String, _ price: Double,
                   _ status: String = "completed") -> JSONValue {
            .object(["id": .string(id), "status": .string(status),
                     "completedAt": .string(iso), "date": .string(String(iso.prefix(10))),
                     "price": .number(price), "paidAmount": .number(price),
                     "paymentStatus": .string("paid")])
        }
        return [
            order("A", "2026-04-08T10:00:00Z", 1200),
            order("B", "2026-04-20T10:00:00Z", 800),
            order("C", "2026-05-02T10:00:00Z", 2400),
            order("D", "2026-06-14T10:00:00Z", 1500),
            order("E", "2026-07-01T10:00:00Z", 3100),
            order("F", "2026-08-09T10:00:00Z", 2750),
            // Not finished, so not revenue.
            order("G", "2026-08-11T10:00:00Z", 9999, "printing"),
            // This month — deliberately outside the six COMPLETE months.
            order("H", "2026-09-02T10:00:00Z", 5000),
        ]
    }

    static func node(_ expression: String) throws -> JSONValue {
        let script = """
        require('./lib/order-money.js'); require('./lib/forecast.js');
        process.stdout.write(String(JSON.stringify(\(expression))));
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", script]
        process.currentDirectoryURL = repoRoot
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw KhaytJSError.evaluationFailed("node exited \(process.terminationStatus)")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test("the Mac's revenue months are the ones Khayt's analytics draws")
    func matchesNode() async throws {
        let engine = try KhaytEngine()
        let mine = try await engine.revenueOutlook(orders: Self.book(), clients: [],
                                                   settings: Self.settings, now: Self.now)

        let orders = String(decoding: try JSONEncoder().encode(JSONValue.array(Self.book())),
                            as: UTF8.self)
        let theirs = try Self.node("""
        (function () {
          var ctx = { settings: { currency: 'SAR' }, clients: [] };
          var M = globalThis.KhaytOrderMoney;
          return globalThis.KhaytForecast.forecast(\(orders), {
            now: \(Self.now), months: 6, periods: 1,
            revenueOf: function (o) { return M.orderNetRevenueBase(o, ctx); }
          });
        })()
        """)
        // Node's answer is decoded through the SAME Swift type, which is the
        // stronger comparison: it proves the struct actually fits the module's
        // real shape, not just that two JSON blobs match. A field the module
        // returns and this type does not name would slip past a blob compare.
        let theirsDecoded = try JSONDecoder().decode(
            KhaytEngine.RevenueOutlook.self, from: try JSONEncoder().encode(theirs))
        #expect(mine == theirsDecoded)
    }

    /// Six complete months, and NOT the current partial one.
    ///
    /// A dashboard that includes the month in progress shows a bar that grows
    /// all month and is always short — which reads as a collapse in trade every
    /// first of the month.
    @Test("the month in progress is left out")
    func excludesThisMonth() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.revenueOutlook(orders: Self.book(), clients: [],
                                                  settings: Self.settings, now: Self.now)
        #expect(out.history.count == 6)
        // The module labels a month `YYYY-MM` — not a month NAME, which is a
        // presentation choice and belongs on the side that knows the reader's
        // language. The Mac formats from `key` for that reason.
        #expect(out.history.map(\.label)
                == ["2026-03", "2026-04", "2026-05", "2026-06", "2026-07", "2026-08"])
        // Order H is September, worth 5,000, and must appear nowhere.
        #expect(out.history.allSatisfy { $0.revenue != 5000 })
    }

    /// Unfinished work is not revenue, and a 9,999 job in the printer would be
    /// the largest month on the chart if it were counted.
    @Test("only finished work counts")
    func onlyFinishedCounts() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.revenueOutlook(orders: Self.book(), clients: [],
                                                  settings: Self.settings, now: Self.now)
        let august = try #require(out.history.first { $0.label == "2026-08" })
        #expect(august.revenue == 2750)
    }

    /// A shop with almost no history gets no forecast rather than a confident
    /// line through two points.
    @Test("too little history says so instead of guessing")
    func notEnoughToSay() async throws {
        let engine = try KhaytEngine()
        let empty = try await engine.revenueOutlook(orders: [], clients: [],
                                                    settings: Self.settings, now: Self.now)
        #expect(empty.method == "none")
        #expect(empty.history.count == 6)
        #expect(empty.history.allSatisfy { $0.revenue == 0 })
        #expect(empty.trendPct == nil)
    }
}
