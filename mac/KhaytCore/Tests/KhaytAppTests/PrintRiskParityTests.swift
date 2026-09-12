import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// `Mesh.Overhangs` against `analyzeTriangles`, on the same triangles.
///
/// This is the only rule the Mac app implements twice, and the reason does not
/// go away: `analyzeTriangles` takes the triangle list, and this shop's models
/// are eight to sixteen million facets — there is no crossing those into
/// JavaScriptCore. So the COUNTING is transcribed into Swift and the JUDGING
/// stays in `assessModel`, which is the half with the thresholds in it.
///
/// A transcription drifts unless something is watching. This watches.
///
/// Every expected figure below was computed by running the shared rule and
/// reading the answer, then checked against the shape by hand — 100mm² is a
/// 10mm square, 141.42 is 10 × 10√2. Three of the first draft's fixtures were
/// wrong in ways that looked like bugs in the module, and were not.
@MainActor
struct PrintRiskParityTests {

    /// (a, b, c), each a point. Wound so normals point outward.
    typealias Tri = [[Double]]

    // MARK: - Shapes whose answers are known

    /// A closed axis-aligned box.
    static func box(_ w: Double, _ d: Double, _ h: Double, z0: Double = 0) -> [Tri] {
        let (x0, y0, x1, y1, z1) = (0.0, 0.0, w, d, z0 + h)
        return [
            // bottom, facing -Z
            [[x0, y0, z0], [x1, y1, z0], [x1, y0, z0]], [[x0, y0, z0], [x0, y1, z0], [x1, y1, z0]],
            // top, facing +Z
            [[x0, y0, z1], [x1, y0, z1], [x1, y1, z1]], [[x0, y0, z1], [x1, y1, z1], [x0, y1, z1]],
            [[x0, y0, z0], [x1, y0, z0], [x1, y0, z1]], [[x0, y0, z0], [x1, y0, z1], [x0, y0, z1]],
            [[x0, y1, z0], [x1, y1, z1], [x1, y1, z0]], [[x0, y1, z0], [x0, y1, z1], [x1, y1, z1]],
            [[x1, y0, z0], [x1, y1, z0], [x1, y1, z1]], [[x1, y0, z0], [x1, y1, z1], [x1, y0, z1]],
            [[x0, y0, z0], [x0, y0, z1], [x0, y1, z1]], [[x0, y0, z0], [x0, y1, z1], [x0, y1, z0]],
        ]
    }

    /// A zero-thickness plate — a ceiling, when something else is lower.
    static func plate(_ w: Double, _ d: Double, at z: Double) -> [Tri] {
        [[[0, 0, z], [w, d, z], [w, 0, z]], [[0, 0, z], [0, d, z], [w, d, z]],
         [[0, 0, z], [w, 0, z], [w, d, z]], [[0, 0, z], [w, d, z], [0, d, z]]]
    }

    /// A closed prism whose long face slopes down at 45°.
    ///
    /// CLOSED, because an open surface has no determinable winding: the first
    /// version of this was two loose triangles, the volume was meaningless, and
    /// the rule fell back to bed contact and picked the other side. It reported
    /// zero overhang on a ramp, which looked like a bug in the module.
    static func slope45() -> [Tri] {
        let a = [0.0, 0, 20], b = [10.0, 0, 10], c = [10.0, 0, 20]
        let a2 = [0.0, 10, 20], b2 = [10.0, 10, 10], c2 = [10.0, 10, 20]
        return [[a, c, b], [a2, b2, c2],
                [a, b, b2], [a, b2, a2],
                [b, c, c2], [b, c2, b2],
                [c, a, a2], [c, a2, c2]]
    }

    // MARK: - Running both sides

    static func swift(_ tris: [Tri], layerHeight: Double = 0.2) -> [String: JSONValue] {
        let minZ = tris.flatMap { $0 }.map { $0[2] }.min() ?? 0
        var acc = Mesh.Overhangs(minZ: minZ, layerHeight: layerHeight)
        for t in tris {
            acc.add(t[0][0], t[0][1], t[0][2], t[1][0], t[1][1], t[1][2],
                    t[2][0], t[2][1], t[2][2])
        }
        return acc.analysis()
    }

    static func js(_ tris: [Tri], layerHeight: Double = 0.2) async throws -> [String: JSONValue] {
        let payload = JSONValue.array(tris.map { t in
            .array(t.map { p in .array(p.map { JSONValue.number($0) }) })
        })
        return try await KhaytEngine().analyzeTriangles(payload, layerHeight: layerHeight)
    }

    static func num(_ v: JSONValue?) -> Double {
        if case .number(let n)? = v { return n } else { return .nan }
    }

    static func hist(_ o: [String: JSONValue]) -> [Double] {
        guard case .array(let rows)? = o["histogram"] else { return [] }
        return rows.map { if case .number(let n) = $0 { return n } else { return .nan } }
    }

    /// Both sides, field by field and bucket by bucket.
    ///
    /// Areas carry a tolerance — they are sums of square roots taken in a
    /// different order — but the histogram is compared bucket by bucket,
    /// because a one-degree shift is precisely the drift this file exists to
    /// catch and a tolerance would hide it.
    static func agree(_ tris: [Tri], _ what: String, layerHeight: Double = 0.2) async throws {
        let a = Self.swift(tris, layerHeight: layerHeight)
        let b = try await Self.js(tris, layerHeight: layerHeight)

        for key in ["triangleCount", "degenerateTriangles", "totalAreaMm2",
                    "downwardAreaMm2", "bedContactAreaMm2", "volumeMm3"] {
            let x = num(a[key]), y = num(b[key])
            #expect(abs(x - y) < 1e-6, Comment(rawValue: "\(what): \(key) — Swift \(x), JS \(y)"))
        }
        // The winding decision has to match too: disagreeing here turns every
        // wall of a reversed model into an overhang on one side only.
        #expect(a["windingFlipped"] == b["windingFlipped"],
                Comment(rawValue: "\(what): the two sides chose different orientations"))

        let ha = hist(a), hb = hist(b)
        #expect(ha.count == 91, Comment(rawValue: "\(what): Swift histogram is \(ha.count) buckets"))
        #expect(hb.count == 91, Comment(rawValue: "\(what): JS histogram is \(hb.count) buckets"))
        for i in 0..<min(ha.count, hb.count) where abs(ha[i] - hb[i]) >= 1e-6 {
            Issue.record(Comment(rawValue: "\(what): bucket \(i)° — Swift \(ha[i]), JS \(hb[i])"))
        }
    }

    // MARK: - The cases

    @Test("a box on the bed has no overhang at any angle")
    func boxOnBed() async throws {
        let tris = Self.box(10, 10, 10)
        try await Self.agree(tris, "box on bed")

        let a = Self.swift(tris)
        #expect(abs(Self.num(a["volumeMm3"]) - 1000) < 1e-6, "a 10mm cube is 1000mm³")
        #expect(abs(Self.num(a["bedContactAreaMm2"]) - 100) < 1e-6, "its floor is 10×10")
        #expect(Self.hist(a).allSatisfy { $0 == 0 },
                "the four walls are exactly vertical and belong in no bucket")
    }

    @Test("lifting the whole model changes nothing")
    func lifted() async throws {
        // The bed is the MODEL's lowest point, not z=0 — a slicer drops it onto
        // the plate. Expecting a lifted box to report its floor as a bridge was
        // the second fixture that looked like a bug and was not.
        let onBed = Self.swift(Self.box(10, 10, 10, z0: 0))
        let lifted = Self.swift(Self.box(10, 10, 10, z0: 5))
        try await Self.agree(Self.box(10, 10, 10, z0: 5), "lifted box")
        #expect(Self.num(onBed["bedContactAreaMm2"]) == Self.num(lifted["bedContactAreaMm2"]))
        #expect(Self.hist(lifted).allSatisfy { $0 == 0 })
    }

    @Test("a flat ceiling above something is 90°, not 89 or 91")
    func bridge() async throws {
        let tris = Self.box(10, 10, 4) + Self.plate(8, 8, at: 12)
        try await Self.agree(tris, "ceiling above a box")

        let h = Self.hist(Self.swift(tris))
        #expect(abs(h[90] - 64) < 1e-6, "the 8×8 underside is 64mm² at 90°")
        #expect(h[89] == 0 && h[88] == 0, "a flat face landed beside 90° rather than on it")
    }

    @Test("a 45° underside lands in the 45° bucket and nowhere else")
    func fortyFive() async throws {
        let tris = Self.slope45()
        try await Self.agree(tris, "45° prism")

        let h = Self.hist(Self.swift(tris))
        // 10 long × 10√2 down the slope.
        #expect(abs(h[45] - 141.4213562) < 1e-5, "the sloping face is 10 × 10√2 at 45°")
        #expect(h[44] == 0 && h[46] == 0, "the angle rounded into a neighbouring bucket")
    }

    @Test("winding cannot change the answer")
    func winding() async throws {
        // A mesh wound inside out still prints, and both sides have to resolve
        // it the same way — from the volume's sign where there is one.
        let forward = Self.slope45()
        let reversed = forward.map { [$0[0], $0[2], $0[1]] }
        try await Self.agree(reversed, "reversed prism")

        let a = Self.swift(forward), b = Self.swift(reversed)
        #expect(abs(Self.num(a["downwardAreaMm2"]) - Self.num(b["downwardAreaMm2"])) < 1e-6,
                "reversing the winding changed how much of it faces down")
        #expect(abs(Self.hist(a)[45] - Self.hist(b)[45]) < 1e-6)
    }

    @Test("a degenerate triangle is counted, not crashed on")
    func degenerate() async throws {
        // Zero-area slivers are ordinary in exported meshes.
        var tris = Self.box(10, 10, 10)
        tris.append([[0, 0, 0], [0, 0, 0], [0, 0, 0]])
        tris.append([[1, 1, 1], [2, 2, 2], [3, 3, 3]])   // collinear
        try await Self.agree(tris, "with degenerates")
        #expect(Self.num(Self.swift(tris)["degenerateTriangles"]) == 2)
    }

    @Test("the layer height moves the bed band on both sides")
    func bedBand() async throws {
        // The epsilon is `max(layerHeight, 0.05)`, and getting it wrong on one
        // side only ever shows up here.
        let tris = Self.box(10, 10, 4) + Self.plate(8, 8, at: 12)
        try await Self.agree(tris, "0.4mm layers", layerHeight: 0.4)
        try await Self.agree(tris, "0.05mm layers", layerHeight: 0.05)
        try await Self.agree(tris, "0.01mm layers", layerHeight: 0.01)
    }

    @Test("nothing at all agrees too")
    func empty() async throws {
        try await Self.agree([], "no triangles")
    }
}
