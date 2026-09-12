import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What a model would cost before anybody slices it.
///
/// The Mac could MEASURE a mesh from the day it could read one and could never
/// price one. A shop looking at a model it had not printed got a size and a
/// triangle count — and no answer to the only question it had.
///
/// ── AND THE CONSTANT NOBODY CAN GUESS ──────────────────────────────────────
///
/// `stl-estimate.js` needs five. Four are the shop's own settings; the fifth —
/// effective volumetric throughput including travel and acceleration — is not
/// a number anyone knows about their own printer, and it had been 8 mm³/s for
/// everyone since the estimator was written.
///
/// It does not have to be guessed. Density and throughput only ever appear
/// multiplied together in the time calculation, and that product is GRAMS PER
/// HOUR, which every job reporting both a weight and a duration has measured
/// directly. Two unguessable constants collapse into one the shop's own
/// history already contains.
///
/// So what is pinned here is the honesty of the answer as much as its
/// arithmetic: an uncalibrated estimate must SAY it is uncalibrated, and the
/// rule's refusals — one job, typed figures, apportioned figures — must survive
/// the crossing into Swift.
@MainActor
struct MeshEstimateTests {

    static let settings: [String: JSONValue] = [
        "estimator": .object([
            "densityGPerCm3": .number(1.24),
            "infillPct": .number(0.2),
            "wallThicknessMm": .number(1.2),
            "wastePct": .number(0.05),
        ]),
    ]

    /// A job that MEASURED both halves, which is the only kind the rule learns
    /// from. Took reading `allocateActuals` to get right, and every field here
    /// is load-bearing:
    ///
    ///   `actualPrintTime` / `actualWeight` sit on the ORDER, not on the part —
    ///   a printer reports one duration and one figure for a job.
    ///   ONE part, because `exact` is `parts.length === 1`. Splitting one
    ///   measurement across four parts in proportion to their estimates is an
    ///   apportionment, and feeding that back would teach the estimator its own
    ///   assumptions.
    ///   `actualsSource` must name something other than `manual`: "Both are
    ///   actuals; only one is a measurement."
    ///
    /// My first fixture put the figures in an `actuals` object with a `source`
    /// field. Nothing threw — the rule simply learned from no jobs at all and
    /// the estimate came back uncalibrated, which looked like the calibration
    /// refusing good history.
    static func measured(_ id: String, grams: Double, hours: Double,
                         machineId: String = "M1") -> JSONValue {
        .object([
            "id": .string(id),
            "status": .string("completed"),
            "machineId": .string(machineId),
            "parts": .array([.object(["printWeight": .number(grams),
                                      "printTime": .number(hours),
                                      "printFileId": .string("PF-1")])]),
            "actualPrintTime": .number(hours),
            "actualWeight": .number(grams),
            "actualsSource": .object(["time": .string("printer"),
                                      "weight": .string("printer")]),
        ])
    }

    // MARK: - The arithmetic

    @Test("a 20mm cube is priced, not merely measured")
    func estimatesACube() async throws {
        // 8,000 mm³ at 1.24 g/cm³ is 9.92 g solid. With a shell and 20% infill
        // the estimate is a fraction of that — what matters here is that it is
        // a real positive number and an hour figure to go with it.
        let engine = try KhaytEngine()
        let e = try await engine.estimateMesh(volumeMm3: 8000, areaMm2: 2400,
                                              bbox: (x: 20, y: 20, z: 20), settings: Self.settings, orders: [])
        #expect(e.grams > 0, "a 20mm cube came back weighing nothing")
        #expect(e.grams < 9.92, "the estimate is heavier than the same cube solid")
        #expect(e.hours > 0, "a cube that weighs something takes some time")
    }

    @Test("nothing measurable is zero, not a guess")
    func emptyMesh() async throws {
        let engine = try KhaytEngine()
        let e = try await engine.estimateMesh(volumeMm3: 0, areaMm2: 0,
                                              bbox: (x: 20, y: 20, z: 20), settings: Self.settings, orders: [])
        #expect(e.grams == 0)
        #expect(e.hours == 0)
    }

    @Test("where the shell came from is reported, because it cannot be checked otherwise")
    func shellProvenance() async throws {
        // "Which model produced that shell, because the two are not comparable
        // and a number nobody can attribute is a number nobody can check."
        let engine = try KhaytEngine()
        let withArea = try await engine.estimateMesh(volumeMm3: 8000, areaMm2: 2400,
                                                     bbox: (x: 20, y: 20, z: 20), settings: Self.settings, orders: [])
        #expect(withArea.shellSource == "surface-area",
                Comment(rawValue: "got \(withArea.shellSource ?? "nil")"))
        let noArea = try await engine.estimateMesh(volumeMm3: 8000, areaMm2: 0,
                                                   bbox: (x: 20, y: 20, z: 20), settings: Self.settings, orders: [])
        #expect(noArea.shellSource == "assumed",
                Comment(rawValue: "got \(noArea.shellSource ?? "nil")"))
    }

    // MARK: - The rate, and saying where it came from

    @Test("with no history the estimate says it is uncalibrated")
    func uncalibratedSaysSo() async throws {
        // An uncalibrated answer is a real answer. What it must not do is look
        // like a measured one.
        let engine = try KhaytEngine()
        let e = try await engine.estimateMesh(volumeMm3: 8000, areaMm2: 2400,
                                              bbox: (x: 20, y: 20, z: 20), settings: Self.settings, orders: [])
        #expect(!e.isCalibrated)
        #expect(e.jobs == nil || e.jobs == 0)
        #expect(e.gramsPerHour == nil || e.gramsPerHour == 0)
    }

    @Test("one job teaches it nothing")
    func oneJobIsNotARate() async throws {
        // "A single print says nothing about a machine, and a calibration
        // confident after one sample is worse than no calibration."
        let engine = try KhaytEngine()
        let e = try await engine.estimateMesh(
            volumeMm3: 8000, areaMm2: 2400, bbox: (x: 20, y: 20, z: 20), settings: Self.settings,
            orders: [Self.measured("O1", grams: 100, hours: 4)])
        #expect(!e.isCalibrated, "a rate was learned from a single job")
    }

    @Test("three agreeing jobs do, and the estimate says how many")
    func learnsFromHistory() async throws {
        let engine = try KhaytEngine()
        let orders = [Self.measured("O1", grams: 100, hours: 4),
                      Self.measured("O2", grams: 105, hours: 4.2),
                      Self.measured("O3", grams: 98, hours: 3.9)]
        let e = try await engine.estimateMesh(volumeMm3: 8000, areaMm2: 2400,
                                              bbox: (x: 20, y: 20, z: 20), settings: Self.settings, orders: orders)
        #expect(e.isCalibrated, "three measured jobs taught it nothing")
        #expect((e.jobs ?? 0) >= 3, Comment(rawValue: "learned from \(e.jobs ?? 0) jobs"))
        // ~25 g/hour in all three.
        #expect((e.gramsPerHour ?? 0) > 20 && (e.gramsPerHour ?? 0) < 30,
                Comment(rawValue: "rate came out \(e.gramsPerHour ?? 0)"))
        #expect(e.scope != nil)
    }

    @Test("the learned rate actually moves the answer")
    func calibrationChangesTheEstimate() async throws {
        // Otherwise the whole feature is a label. The default is 8 mm³/s; a
        // shop running far slower than that must get a longer time.
        let engine = try KhaytEngine()
        let slow = [Self.measured("O1", grams: 100, hours: 20),
                    Self.measured("O2", grams: 102, hours: 20.4),
                    Self.measured("O3", grams: 99, hours: 19.8)]
        let plain = try await engine.estimateMesh(volumeMm3: 8000, areaMm2: 2400,
                                                  bbox: (x: 20, y: 20, z: 20), settings: Self.settings, orders: [])
        let taught = try await engine.estimateMesh(volumeMm3: 8000, areaMm2: 2400,
                                                   bbox: (x: 20, y: 20, z: 20), settings: Self.settings, orders: slow)
        #expect(taught.isCalibrated)
        #expect(taught.hours > plain.hours,
                Comment(rawValue: "5 g/hour of history did not slow the estimate: \(plain.hours) → \(taught.hours)"))
        // The WEIGHT is not a function of the rate and must not move.
        #expect(abs(taught.grams - plain.grams) < 0.01,
                "calibrating the rate changed the weight")
    }

    @Test("a real model does NOT report itself unreliable")
    func measurableModelsAreTrusted() async throws {
        // THE BUG THIS GUARDS, and it was mine. `reliable` is false unless the
        // volume AND all three dimensions are finite — that flag guards a
        // figure shown to customers, because "an unmeasurable model was quoted
        // as free". I called the estimator without a bounding box, so every
        // model in the library reported itself unreliable and the inspector
        // explained it with the wrong reason ("mostly wall").
        //
        // A warning that always appears teaches a shop to ignore it.
        let engine = try KhaytEngine()
        let e = try await engine.estimateMesh(volumeMm3: 8000, areaMm2: 2400,
                                              bbox: (x: 20, y: 20, z: 20),
                                              settings: Self.settings, orders: [])
        #expect(!e.shellUnreliable, "a 20mm cube reported itself unreliable")
    }

    @Test("a model that is nearly all wall IS flagged")
    func mostlyWallIsFlagged() async throws {
        // The other half: the flag must still fire when it should, or moving it
        // out of the way has removed the guard rather than fixed it.
        //
        // The shell fraction is `area x wall / volume`. At 6,000 mm² of surface
        // on 8,000 mm³ with a 1.2 mm wall that is 0.9 — past the 0.85 the rule
        // trusts, where "the shell term has swallowed the part and there is no
        // infill headroom left".
        //
        // NaN dimensions were the first attempt and cannot be used: JSON has no
        // way to carry them, so the encode threw rather than the flag firing.
        let engine = try KhaytEngine()
        let e = try await engine.estimateMesh(volumeMm3: 8000, areaMm2: 6000,
                                              bbox: (x: 20, y: 20, z: 20),
                                              settings: Self.settings, orders: [])
        #expect(e.shellUnreliable, "a model that is nearly all wall was presented as sound")
        #expect(e.shellSource == "surface-area", "the shell did not come from the mesh")
    }

    @Test("a job nobody measured is not history")
    func typedFiguresAreNotLearnedFrom() async throws {
        // "A typed figure is the shop's estimate of its own past, and
        // calibrating an estimator against estimates is circular."
        let engine = try KhaytEngine()
        // Figures present and complete — but typed. Only `actualsSource`
        // separates this from the fixture above, which is the whole point.
        let typed: [JSONValue] = (1...4).map { i in
            .object([
                "id": .string("O\(i)"), "status": .string("completed"),
                "machineId": .string("M1"),
                "parts": .array([.object(["printWeight": .number(100),
                                          "printTime": .number(4)])]),
                "actualPrintTime": .number(4),
                "actualWeight": .number(100),
                "actualsSource": .object(["time": .string("manual"),
                                          "weight": .string("manual")]),
            ])
        }
        let e = try await engine.estimateMesh(volumeMm3: 8000, areaMm2: 2400,
                                              bbox: (x: 20, y: 20, z: 20), settings: Self.settings, orders: typed)
        #expect(!e.isCalibrated, "the estimator learned from its own estimates")
    }
}
