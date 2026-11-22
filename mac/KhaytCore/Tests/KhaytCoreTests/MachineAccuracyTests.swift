import Foundation
import Testing
@testable import KhaytCore

/// How far each machine runs from the time it was quoted at.
///
/// The unit is the MACHINE, which is the one `estimate-variance` cannot answer:
/// it groups by model, so a shop with one slow printer sees every model on it
/// read long and has no way to tell the printer from the prices.
///
/// These prove the JOIN as much as the arithmetic. `machine-accuracy` does none
/// of its own comparing, rounding or judging: the per-job percentage comes from
/// `printer-actuals.compareToEstimate`, and the median and the confidence words
/// come from `estimate-variance`, all injected. Three modules have to be
/// bundled and reachable from JavaScriptCore for any of this to return a row,
/// and a missing one would hand back an empty array rather than raising — which
/// is exactly the failure that looks like "this shop has no data".
@Suite struct MachineAccuracyTests {

    /// A finished print whose duration a PRINTER timed.
    ///
    /// The estimate is `printTime` on the order and the actual is
    /// `actualPrintTime` beside it — no parts and no allocation, because a job
    /// ran on one machine whole and there is nothing to divide.
    static func job(_ id: String, machine: String, estH: Double, actH: Double,
                    at: String = "2026-09-01T00:00:00Z",
                    status: String = "completed",
                    measured: Bool = true) -> JSONValue {
        .object([
            "id": .string(id),
            "status": .string(status),
            "machineId": .string(machine),
            "completedAt": .string(at),
            "printTime": .number(estH),
            "actualPrintTime": .number(actH),
            "actualsSource": .object([
                "time": .string(measured ? "moonraker" : "manual"),
                "weight": .string(measured ? "moonraker" : "manual"),
            ]),
        ])
    }

    @Test("the machine running furthest over its quote is reported first")
    func worstFirst() async throws {
        let engine = try KhaytEngine()
        let rows = try await engine.machineAccuracy(orders: [
            Self.job("a", machine: "quick", estH: 4, actH: 3),
            Self.job("b", machine: "quick", estH: 4, actH: 3, at: "2026-09-02T00:00:00Z"),
            Self.job("c", machine: "slow", estH: 4, actH: 6),
            Self.job("d", machine: "slow", estH: 4, actH: 6, at: "2026-09-02T00:00:00Z"),
        ])
        #expect(rows.count == 2)
        #expect(rows[0].machineId == "slow")
        #expect(rows[0].hoursDeltaPct == 50)
        #expect(rows[1].machineId == "quick")
        // Under is reported, and is not a fault. A machine that finishes early
        // sorted to the top beside one running 50% long says they are equally
        // worth attention.
        #expect(rows[1].hoursDeltaPct == -25)
    }

    @Test("a typed actual is not evidence, and leaves the panel empty")
    func typedActualsAreRefused() async throws {
        let engine = try KhaytEngine()
        // The completion dialog pre-fills the ESTIMATE, so a shop that hits
        // confirm records the estimate under a second name. Counting these would
        // compare an estimate to itself and report every machine as perfect.
        let rows = try await engine.machineAccuracy(orders: [
            Self.job("a", machine: "m1", estH: 4, actH: 4, measured: false),
            Self.job("b", machine: "m1", estH: 4, actH: 4, measured: false),
        ])
        #expect(rows.isEmpty)
        #expect(try await engine.shopAccuracy(orders: []) == nil)
    }

    @Test("nothing measured is nil, never a confident zero")
    func nothingMeasuredIsNil() async throws {
        let engine = try KhaytEngine()
        // "Every print landed on its estimate" and "no printer has ever told us
        // anything" are opposite states. A headline of +0% for the second is the
        // failure the whole module exists to end, one level up.
        let all = try await engine.shopAccuracy(orders: [
            Self.job("a", machine: "m1", estH: 4, actH: 4, measured: false),
        ])
        #expect(all == nil)
    }

    @Test("a delivered print is a finished print")
    func deliveredCounts() async throws {
        let engine = try KhaytEngine()
        // `order-status.js` derives the delivered STAGE from completed plus a
        // deliveredAt, so a handed-over job keeps the status `completed` — but
        // the bundled sample and older books store the literal `delivered`.
        // Testing only for `completed` dropped five of the sample's six
        // measured prints.
        let rows = try await engine.machineAccuracy(orders: [
            Self.job("a", machine: "m1", estH: 4, actH: 5, status: "delivered"),
        ])
        #expect(rows.count == 1)
        #expect(rows[0].hoursDeltaPct == 25)
    }

    @Test("one long print does not outvote a dozen short ones")
    func medianNotRatioOfTotals() async throws {
        let engine = try KhaytEngine()
        // Analytics summed the hours and divided, so a single forty-hour job
        // decided a machine's verdict.
        var orders: [JSONValue] = (1...12).map {
            Self.job("s\($0)", machine: "m1", estH: 3, actH: 3,
                     at: String(format: "2026-09-%02dT00:00:00Z", $0))
        }
        orders.append(Self.job("long", machine: "m1", estH: 10, actH: 40,
                               at: "2026-09-20T00:00:00Z"))
        let rows = try await engine.machineAccuracy(orders: orders)
        #expect(rows.count == 1)
        #expect(rows[0].sampled == 13)
        #expect(rows[0].hoursDeltaPct == 0)   // the twelve, not the one
    }

    @Test("the shop's figure and the machine rows come off the same readings")
    func headlineAgreesWithBreakdown() async throws {
        let engine = try KhaytEngine()
        // Before, the two panels were computed separately — one averaged across
        // every job, the other averaged per machine and never rolled up — and
        // nothing made them agree.
        let orders = (1...5).map {
            Self.job("j\($0)", machine: "m1", estH: 4, actH: 4.4,
                     at: String(format: "2026-09-%02dT00:00:00Z", $0))
        }
        let rows = try await engine.machineAccuracy(orders: orders)
        let all = try #require(try await engine.shopAccuracy(orders: orders))
        #expect(rows.count == 1)
        #expect(rows[0].hoursDeltaPct == all.hoursDeltaPct)
        #expect(rows[0].estHours == all.estHours)
        #expect(rows[0].actHours == all.actHours)
        #expect(all.sampled == 5)
    }

    @Test("a job on no machine counts for the shop and not for a machine")
    func unassignedCountsOnce() async throws {
        let engine = try KhaytEngine()
        let orders = [
            Self.job("a", machine: "m1", estH: 4, actH: 4),
            Self.job("b", machine: "", estH: 4, actH: 8),
        ]
        let rows = try await engine.machineAccuracy(orders: orders)
        #expect(rows.count == 1)
        #expect(rows[0].sampled == 1)
        let all = try #require(try await engine.shopAccuracy(orders: orders))
        #expect(all.sampled == 2)
    }

    @Test("confidence is the shared judgement, not a second one")
    func confidenceComesFromTheSharedRule() async throws {
        let engine = try KhaytEngine()
        // `estimate-variance.js` owns where the lines are so the model panel and
        // this one cannot disagree about what counts as enough evidence.
        let two = (1...2).map { Self.job("j\($0)", machine: "m1", estH: 4, actH: 4,
                                         at: String(format: "2026-09-%02dT00:00:00Z", $0)) }
        let five = (1...5).map { Self.job("k\($0)", machine: "m2", estH: 4, actH: 4,
                                          at: String(format: "2026-09-%02dT00:00:00Z", $0)) }
        let rows = try await engine.machineAccuracy(orders: two + five)
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.machineId, $0) })
        #expect(byId["m1"]?.confidence == "thin")
        #expect(byId["m2"]?.confidence == "good")
    }
}
