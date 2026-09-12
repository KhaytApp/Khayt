import Foundation
import KhaytCore

/// Measuring a mesh: how many triangles, what volume, what box.
///
/// ── WHY THIS IS OURS AND NOT A SLICER'S ──────────────────────────────────
///
/// Every slicer computes exactly this on load and will print it with `--info`,
/// and `ModelInfo.swift` uses that. But PrusaSlicer, OrcaSlicer, Snapmaker Orca
/// and Bambu Studio all descend from Slic3r and are **AGPL-3.0**: linking any
/// of their code in would put Khayt under the same licence, network clause and
/// all. Spawning one is arm's length and fine; carrying one is not.
///
/// So this is written here. It is worth being clear that the arithmetic was
/// never the hard part — it is one cross product per triangle — and that what
/// made the mesh unreachable was the CONTAINER: `lib/mf-convert.js` reads it
/// with Node's `Buffer`, which JavaScriptCore does not have.
///
/// ── THE VOLUME ───────────────────────────────────────────────────────────
///
/// Signed tetrahedron sum: every triangle makes a tetrahedron with the origin,
/// `a · (b × c) / 6` is its signed volume, and on a closed consistently-wound
/// mesh the outside faces cancel and what is left is what the mesh encloses.
/// The origin need not be inside; that is the point of the sign.
///
/// It is `abs`'d at the end because a mesh wound inside-out — which happens, and
/// which a slicer will still print — gives the right magnitude with the wrong
/// sign, and a negative volume in a library record is worse than a mesh nobody
/// noticed was inverted.
///
/// Checked against PrusaSlicer, which does the same thing: a 10 mm cube is
/// 1000.000061 mm³ to it and 1000.0 here, the difference being that it
/// accumulates in Float and this in Double.
enum Mesh {

    /// What a measurement adds up to. The same three things `geometryKey` wants.
    struct Measurement: Equatable, Sendable {
        var triangleCount = 0
        /// Signed while accumulating; made positive by `finished`.
        var volumeMm3 = 0.0
        var minX = Double.infinity, minY = Double.infinity, minZ = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity, maxZ = -Double.infinity

        var x: Double { minX.isFinite && maxX.isFinite ? max(0, maxX - minX) : 0 }
        var y: Double { minY.isFinite && maxY.isFinite ? max(0, maxY - minY) : 0 }
        var z: Double { minZ.isFinite && maxZ.isFinite ? max(0, maxZ - minZ) : 0 }

        /// One triangle.
        ///
        /// Inlined and taking scalars rather than a vector type: this runs six
        /// million times for one of this shop's files, and the cost of it is
        /// the cost of the whole measurement.
        @inline(__always)
        mutating func add(_ ax: Double, _ ay: Double, _ az: Double,
                          _ bx: Double, _ by: Double, _ bz: Double,
                          _ cx: Double, _ cy: Double, _ cz: Double) {
            triangleCount += 1
            volumeMm3 += (ax * (by * cz - bz * cy)
                        + ay * (bz * cx - bx * cz)
                        + az * (bx * cy - by * cx)) / 6
            minX = min(minX, ax, bx, cx); maxX = max(maxX, ax, bx, cx)
            minY = min(minY, ay, by, cy); maxY = max(maxY, ay, by, cy)
            minZ = min(minZ, az, bz, cz); maxZ = max(maxZ, az, bz, cz)
        }

        /// The measurement as a caller should read it, or nil when nothing was
        /// measured — an empty file, or one this could not understand. Nil
        /// rather than zeros, so an unmeasured model never gets an identity
        /// another unmeasured one would share.
        func finished() -> Measurement? {
            guard triangleCount > 0 else { return nil }
            var out = self
            out.volumeMm3 = abs(volumeMm3)
            return out
        }
    }

    // MARK: - Which way the surfaces face

    /// The overhang histogram `lib/print-risk.js` judges a model from.
    ///
    /// ── WHY THIS IS HERE AND NOT IN THE SHARED RULE ────────────────────────
    ///
    /// `analyzeTriangles` takes the triangle list, and this shop's files are
    /// eight to sixteen million facets — there is no crossing them into
    /// JavaScriptCore. What DOES cross is this summary: ninety-one buckets and
    /// a handful of scalars. So the counting is here and the JUDGEMENT stays in
    /// `assessModel`, which is the part with the thresholds in it and the part
    /// two implementations could disagree about.
    ///
    /// `PrintRiskParityTests` runs both on the same triangles and fails if they
    /// differ, because this is a transcription and transcriptions drift.
    ///
    /// ── IT IS NOT FREE, WHICH IS WHY IT IS A SECOND PASS ───────────────────
    ///
    /// `Measurement.add` computes the scalar triple product for volume. That is
    /// NOT the facet normal — this needs `(b-a)×(c-a)` and its length, which is
    /// six more multiplies and a square root per triangle. On six million
    /// facets that is real work, so it is not folded into the import: the shop
    /// asks for it.
    ///
    /// Two passes, because the bed is the model's lowest point and no triangle
    /// can be judged against it until every triangle has been seen. `minZ`
    /// comes from the measurement that already happened.
    struct Overhangs {
        /// Downward area by angle from vertical, 0…90°, one bucket per degree.
        /// Both windings are accumulated because the correct one is not known
        /// until the volume's sign settles.
        private var negHist = [Double](repeating: 0, count: 91)
        private var posHist = [Double](repeating: 0, count: 91)
        private var negArea = 0.0, posArea = 0.0
        private var negBed = 0.0, posBed = 0.0
        private var vol6 = 0.0
        private(set) var totalAreaMm2 = 0.0
        private(set) var degenerate = 0
        private(set) var triangleCount = 0

        /// The model's floor, and a first layer's worth above it.
        let minZ: Double
        let bedEps: Double

        init(minZ: Double, layerHeight: Double = 0.2) {
            self.minZ = minZ
            // A first layer's worth. Anything within it is sitting on the
            // plate, which is the one downward surface that is never a problem
            // — and usually the largest, so counting it would drown every real
            // overhang.
            self.bedEps = max(layerHeight, 0.05)
        }

        /// A face this close to vertical belongs to neither side. A box's four
        /// walls have nz of exactly 0, and putting them on the positive side
        /// would make a reversed box report all four as downward-facing.
        private static let verticalEps = 1e-9

        @inline(__always)
        mutating func add(_ ax: Double, _ ay: Double, _ az: Double,
                          _ bx: Double, _ by: Double, _ bz: Double,
                          _ cx: Double, _ cy: Double, _ cz: Double) {
            triangleCount += 1
            vol6 += ax * (by * cz - bz * cy)
                  - ay * (bx * cz - bz * cx)
                  + az * (bx * cy - by * cx)

            let ux = bx - ax, uy = by - ay, uz = bz - az
            let vx = cx - ax, vy = cy - ay, vz = cz - az
            let nx = uy * vz - uz * vy
            let ny = uz * vx - ux * vz
            let nz = ux * vy - uy * vx
            let len = (nx * nx + ny * ny + nz * nz).squareRoot()
            // A zero-area sliver has no normal to speak of.
            guard len > 0 else { degenerate += 1; return }

            let area = len / 2
            totalAreaMm2 += area
            let unit = nz / len
            guard unit <= -Self.verticalEps || unit >= Self.verticalEps else { return }

            let down = unit < 0
            let topZ = max(az, bz, cz)
            if topZ <= minZ + bedEps {
                if down { negArea += area; negBed += area } else { posArea += area; posBed += area }
                return
            }
            if down { negArea += area } else { posArea += area }

            // `-n.z` is the sine of the angle the SURFACE makes with vertical:
            // a wall is 0°, a 45° underside is 45°, a flat ceiling is 90°.
            let sine = min(1, down ? -unit : unit)
            let deg = Int((asin(sine) * 180 / .pi).rounded())
            let bucket = min(90, max(0, deg))
            if down { negHist[bucket] += area } else { posHist[bucket] += area }
        }

        /// The summary, in the shape `assessModel` reads.
        ///
        /// Which orientation is "down" is decided by the volume's sign where
        /// there is one, and by which side has more bed contact where there is
        /// not — a mesh wound inside out is still a mesh a slicer will print.
        func analysis() -> [String: JSONValue] {
            let volume = abs(vol6) / 6
            let trustworthy = volume > 1e-6
            let flipped = trustworthy ? vol6 < 0 : posBed > negBed
            let hist = flipped ? posHist : negHist
            let area = flipped ? posArea : negArea
            let bed = flipped ? posBed : negBed
            // The field names are `analyzeTriangles`' own. `assessModel` and
            // `overhangAreaAbove` read them by name, so a near-miss here —
            // `hist` for `histogram` — is a risk report of zero overhang on a
            // model covered in them, with nothing to say anything was wrong.
            return [
                "triangleCount": .number(Double(triangleCount)),
                "degenerateTriangles": .number(Double(degenerate)),
                "totalAreaMm2": .number(totalAreaMm2),
                "downwardAreaMm2": .number(area),
                "bedContactAreaMm2": .number(bed),
                "histogram": .array(hist.map { JSONValue.number($0) }),
                "bedZ": .number(minZ),
                "windingFlipped": .bool(flipped),
                "windingFromVolume": .bool(trustworthy),
                "volumeMm3": .number(volume),
            ]
        }
    }

    /// English, like `Zip.Failure` and `StoreWriter.Refusal` beside it.
    ///
    /// These describe a FILE — a header that does not add up, an archive with no
    /// model in it — and they are read by whoever is working out why an import
    /// refused, not by a shop going about its day. The wording a shop sees when
    /// an import fails belongs in `Words`, at the point it is shown, and this is
    /// deliberately not that. Same gap the cloud readers carry, and named in
    /// `AssembledSentenceTests` so it stays a decision.
    enum Failure: Error, CustomStringConvertible, Equatable {
        case unreadable(String)
        case notAMesh(String)
        case tooManyTriangles(Int)

        var description: String {
            switch self {
            case .unreadable(let why): return "Could not read the model: \(why)"
            case .notAMesh(let what): return "That does not look like a mesh: \(what)"
            case .tooManyTriangles(let n):
                return "The model claims \(n) triangles, more than this reads."
            }
        }
    }

    /// A ceiling on what will be counted.
    ///
    /// Not a memory bound — nothing here holds the mesh — but a bound on a
    /// header that claims something absurd. This shop's largest real model is
    /// 6.3 million triangles; two hundred million is far past any real part and
    /// still finishes.
    static let mostTriangles = 200_000_000

    // MARK: - 3MF

    /// Measure every mesh in a 3MF.
    ///
    /// The model lives as XML inside the zip — `<vertex x= y= z=/>` then
    /// `<triangle v1= v2= v3=/>` indexing into them — and on this shop's files
    /// that XML is 436 MB uncompressed. It is therefore STREAMED: inflated a
    /// megabyte at a time and scanned as it arrives, so what is resident is the
    /// vertex table and nothing else.
    ///
    /// TRANSFORMS ARE NOT APPLIED, and that is a compatibility decision rather
    /// than a shortcut. A 3MF's `<build>` places each object with a matrix, and
    /// a slicer reports the placed result — which is why PrusaSlicer measures
    /// this shop's Hulk helmet as 229 × 231 mm and Khayt records it as 1141 ×
    /// 757. Khayt measures the raw mesh envelope, the key is compared against
    /// records Khayt wrote, so this measures the raw mesh envelope too. The
    /// slicer's answer is the more useful one about a plate; Khayt's is the one
    /// that has to match.
    /// A 3MF's placement matrix: 3×3 then a translation, row-vector convention.
    struct Placement: Equatable {
        var m = [1.0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]

        /// `"1 0 0 0 1 0 0 0 1 781.8 -184.4 8.1"` — twelve numbers or nothing.
        init?(_ text: String) {
            let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                .compactMap { Double($0) }
            guard parts.count == 12 else { return nil }
            m = parts
        }
        init() {}

        /// `self` applied after `inner` — the item's placement on top of the
        /// component's.
        func composed(with inner: Placement) -> Placement {
            var out = Placement()
            for row in 0..<3 {
                for col in 0..<3 {
                    out.m[row * 3 + col] = inner.m[row * 3 + 0] * m[col]
                                         + inner.m[row * 3 + 1] * m[3 + col]
                                         + inner.m[row * 3 + 2] * m[6 + col]
                }
            }
            for col in 0..<3 {
                out.m[9 + col] = inner.m[9] * m[col] + inner.m[10] * m[3 + col]
                               + inner.m[11] * m[6 + col] + m[9 + col]
            }
            return out
        }

        @inline(__always)
        func apply(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
            (x * m[0] + y * m[3] + z * m[6] + m[9],
             x * m[1] + y * m[4] + z * m[7] + m[10],
             x * m[2] + y * m[5] + z * m[8] + m[11])
        }

        var isIdentity: Bool { self == Placement() }
    }

    static func measure3MF(_ url: URL) throws -> Measurement? {
        var m = Measurement()
        try each3MFTriangle(url) { ax, ay, az, bx, by, bz, cx, cy, cz in
            m.add(ax, ay, az, bx, by, bz, cx, cy, cz)
        }
        return m.finished()
    }

    /// Every triangle of a 3MF, placed where the build puts it.
    ///
    /// Factored out of `measure3MF` rather than written beside it. The overhang
    /// pass needs the same triangles at the same coordinates, and a second
    /// traversal that read `<build>` even slightly differently would report
    /// overhangs for a model in a position Khayt never measured — the quiet
    /// kind of wrong, since both answers would look plausible.
    ///
    /// Returns how many triangles it emitted.
    @discardableResult
    static func each3MFTriangle(_ url: URL,
                                _ body: (Double, Double, Double, Double, Double,
                                         Double, Double, Double, Double) -> Void) throws -> Int {
        let entries = try Zip.entries(of: url)
        let models = entries.filter { $0.name.lowercased().hasSuffix(".model") }
        guard !models.isEmpty else { throw Failure.notAMesh("no model part in the archive") }

        var emitted = 0
        func sink(_ ax: Double, _ ay: Double, _ az: Double,
                  _ bx: Double, _ by: Double, _ bz: Double,
                  _ cx: Double, _ cy: Double, _ cz: Double) {
            emitted += 1
            body(ax, ay, az, bx, by, bz, cx, cy, cz)
        }

        // THE BUILD PLACES THE OBJECTS, and where they are placed is part of
        // what Khayt measures.
        //
        // A Bambu/Orca 3MF keeps each object in its own `3D/Objects/*.model`
        // part and the root lists them as `<item objectid= transform=>` under
        // `<build>`. Measuring the parts where they lie in their own files
        // gives a box that is right about the meshes and wrong about the model:
        // on this shop's Hulk helmet — twenty parts — that is 229 × 221 × 244
        // against the 1141 × 757 × 207 Khayt recorded, because the items are
        // placed hundreds of millimetres apart.
        //
        // The triangle count and the volume are the same either way, which is
        // why they matched before this existed and why the box did not.
        if let plan = try buildPlan(entries, in: url), !plan.isEmpty {
            for (path, placement) in plan {
                guard let entry = entries.first(where: { equalPath($0.name, path) }) else { continue }
                try streamModelPart(entry, in: url, placement: placement, body: sink)
            }
            if emitted > 0 { return emitted }
            // A build that named nothing this could find. Fall through and
            // read the parts rather than report an empty model.
        }

        for entry in models.sorted(by: { $0.name < $1.name }) {
            try streamModelPart(entry, in: url, placement: Placement(), body: sink)
        }
        return emitted
    }

    // MARK: - The second pass

    /// The overhang summary for a file on disk, in the four formats Khayt reads.
    ///
    /// TWO PASSES OVER THE SAME FILE, and the second cannot be folded into the
    /// first: the bed is the model's own lowest point, so no triangle can be
    /// judged against it until every triangle has been seen. `minZ` therefore
    /// has to come from a measurement that already finished.
    ///
    /// Reusing the same `each*Triangle` readers the measurement uses, rather
    /// than its own parsers, is the point — a file measured one way and judged
    /// another is the bug this shop already had when the preview renderer knew
    /// only binary STL and sixteen CAD exports came back as grey cubes.
    ///
    /// Returns nil when nothing could be read, which is the same answer
    /// `measure*` gives for the same file.
    ///
    /// There is no facet ceiling here, and the Electron path has two. `main.js`
    /// caps the analysis at 150 MB and `lib/model-intake.js` at four million
    /// facets, because that one has to BUILD the triangle list — about 810
    /// bytes a facet, so four million is already some three gigabytes.
    ///
    /// Measured against this shop's library: 83 readable meshes, of which two
    /// are past that ceiling — a 6.6M-facet multi-colour poster and a 4.3M-facet
    /// model — and get no report at all from the other app. This streams and
    /// holds ninety-one buckets, so the size of the file stops being the
    /// question.
    static func overhangs(of url: URL, layerHeight: Double = 0.2) throws -> [String: JSONValue]? {
        let ext = url.pathExtension.lowercased()
        guard let measured = try readGeometry(url, ext: ext) else { return nil }

        var acc = Overhangs(minZ: measured.minZ, layerHeight: layerHeight)
        let walked = try eachTriangle(url, ext: ext) { ax, ay, az, bx, by, bz, cx, cy, cz in
            acc.add(ax, ay, az, bx, by, bz, cx, cy, cz)
        }
        guard walked else { return nil }
        return acc.analysis()
    }

    /// The measurement for a file, dispatched by extension. Nil for a format
    /// that carries no mesh — a gcode is a list of moves, not a model.
    static func readGeometry(_ url: URL, ext: String? = nil) throws -> Measurement? {
        switch ext ?? url.pathExtension.lowercased() {
        case "3mf": return try measure3MF(url)
        case "stl": return try measureSTL(url)
        case "obj": return try measureOBJ(url)
        default: return nil
        }
    }

    /// Every triangle of a file, whichever of the four readers understands it.
    /// False when none of them does, so a caller can tell "no triangles" from
    /// "not a mesh".
    static func eachTriangle(_ url: URL, ext: String? = nil,
                             _ body: (Double, Double, Double, Double, Double,
                                      Double, Double, Double, Double) -> Void) throws -> Bool {
        switch ext ?? url.pathExtension.lowercased() {
        case "3mf":
            return try each3MFTriangle(url, body) > 0
        case "obj":
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            eachOBJTriangle(text, body)
            return true
        case "stl":
            // Binary first, then the text form — the same order and the same
            // arithmetic test `measureSTL` uses, because a file it measures as
            // binary and this reads as text would be judged on nothing.
            if try eachSTLTriangle(url, body) { return true }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            eachAsciiSTLTriangle(text, body)
            return true
        default:
            return false
        }
    }

    /// `[(part path, placement)]` from the root part's `<build>`, or nil when
    /// there is no root or no build in it.
    private static func buildPlan(_ entries: [Zip.Entry], in url: URL)
        throws -> [(String, Placement)]? {
        guard let root = entries.first(where: { equalPath($0.name, "3D/3dmodel.model") })
        else { return nil }
        // The root is small — ten kilobytes on the file above — so unlike the
        // mesh parts it is read whole.
        guard let data = try? Zip.data(of: root, in: url) else { return nil }
        let xml = String(decoding: data, as: UTF8.self)

        // objectid → (part it lives in, the component's own placement)
        var componentOf: [String: (String, Placement)] = [:]
        var currentObject: String?
        for tag in tags(in: xml) {
            if tag.hasPrefix("<object") {
                currentObject = value(of: "id", in: tag)
            } else if tag.hasPrefix("<component"), let object = currentObject,
                      let path = value(of: "p:path", in: tag) ?? value(of: "path", in: tag) {
                let placement = value(of: "transform", in: tag).flatMap(Placement.init) ?? Placement()
                componentOf[object] = (path, placement)
            }
        }

        var plan: [(String, Placement)] = []
        for tag in tags(in: xml) where tag.hasPrefix("<item") {
            guard let object = value(of: "objectid", in: tag),
                  let (path, inner) = componentOf[object] else { continue }
            let item = value(of: "transform", in: tag).flatMap(Placement.init) ?? Placement()
            plan.append((path, item.composed(with: inner)))
        }
        return plan
    }

    /// `/3D/Objects/x.model` and `3D/Objects/x.model` are the same member: the
    /// root writes package paths with a leading slash and the zip does not.
    private static func equalPath(_ a: String, _ b: String) -> Bool {
        func strip(_ s: String) -> String {
            var out = s
            while out.hasPrefix("/") || out.hasPrefix("./") {
                out = out.hasPrefix("./") ? String(out.dropFirst(2)) : String(out.dropFirst())
            }
            return out.lowercased()
        }
        return strip(a) == strip(b)
    }

    private static func tags(in xml: String) -> [String] {
        var out: [String] = []
        var current: String?
        for ch in xml {
            if ch == "<" { current = "<" }
            else if ch == ">" { if let c = current { out.append(c) }; current = nil }
            else if current != nil { current?.append(ch) }
        }
        return out
    }

    private static func value(of name: String, in tag: String) -> String? {
        guard let at = tag.range(of: "\(name)=\"") else { return nil }
        let rest = tag[at.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// One `.model` part, streamed.
    private static func streamModelPart(_ entry: Zip.Entry, in url: URL,
                                        placement: Placement,
                                        body: (Double, Double, Double, Double, Double,
                                               Double, Double, Double, Double) -> Void) throws {
        // Vertices, flat: x,y,z,x,y,z… Reserved generously because growing a
        // 30-million-element array by doubling is most of the cost otherwise.
        var vertices: [Double] = []
        vertices.reserveCapacity(min(entry.size / 40, 30_000_000))
        // A tag can land across a chunk boundary, so the tail after the last
        // complete `>` is carried into the next chunk.
        var carry = [UInt8]()

        func consume(_ bytes: UnsafeRawBufferPointer) -> Bool {
            var buffer = carry
            buffer.append(contentsOf: bytes.bindMemory(to: UInt8.self))
            carry.removeAll(keepingCapacity: true)

            var i = 0
            var lastComplete = 0
            while i < buffer.count {
                guard buffer[i] == UInt8(ascii: "<") else { i += 1; continue }
                guard let close = index(of: UInt8(ascii: ">"), in: buffer, from: i) else { break }
                let tag = buffer[i..<close]
                if starts(tag, with: "<mesh") {
                    // A `.model` part holds one object per model, and every
                    // one of them numbers its vertices FROM ZERO. Accumulating
                    // them into a single table makes each object after the
                    // first index into the previous object's vertices: some
                    // triangles land on the wrong points and the ones whose
                    // indices run past the end are dropped.
                    //
                    // Measured on this shop's Hulk helmet, which holds twenty
                    // objects: 4,200,865 triangles against a true 4,295,525,
                    // and a volume 16% low. Both wrong in the quiet direction —
                    // a plausible number, not an error.
                    vertices.removeAll(keepingCapacity: true)
                } else if starts(tag, with: "<vertex") {
                    if let x = attribute("x", in: tag), let y = attribute("y", in: tag),
                       let z = attribute("z", in: tag) {
                        vertices.append(contentsOf: [x, y, z])
                    }
                } else if starts(tag, with: "<triangle") {
                    if let a = attribute("v1", in: tag), let b = attribute("v2", in: tag),
                       let c = attribute("v3", in: tag) {
                        let ia = Int(a) * 3, ib = Int(b) * 3, ic = Int(c) * 3
                        // An index past the table is a malformed part, not a
                        // crash: the triangle is dropped and the rest is read.
                        if ia >= 0, ic >= 0, ib >= 0,
                           ia + 2 < vertices.count, ib + 2 < vertices.count, ic + 2 < vertices.count {
                            if placement.isIdentity {
                                body(vertices[ia], vertices[ia + 1], vertices[ia + 2],
                                     vertices[ib], vertices[ib + 1], vertices[ib + 2],
                                     vertices[ic], vertices[ic + 1], vertices[ic + 2])
                            } else {
                                let p = placement.apply(vertices[ia], vertices[ia + 1], vertices[ia + 2])
                                let q = placement.apply(vertices[ib], vertices[ib + 1], vertices[ib + 2])
                                let r = placement.apply(vertices[ic], vertices[ic + 1], vertices[ic + 2])
                                body(p.0, p.1, p.2, q.0, q.1, q.2, r.0, r.1, r.2)
                            }
                        }
                    }
                }
                i = close + 1
                lastComplete = i
            }
            if lastComplete < buffer.count { carry = Array(buffer[lastComplete...]) }
            return true
        }

        try Zip.stream(entry, in: url, onChunk: consume)
    }

    // MARK: - Reading a tag

    private static func index(of byte: UInt8, in bytes: [UInt8], from: Int) -> Int? {
        var i = from
        while i < bytes.count { if bytes[i] == byte { return i }; i += 1 }
        return nil
    }

    private static func isSpace(_ b: UInt8) -> Bool {
        b == UInt8(ascii: " ") || b == UInt8(ascii: "\t")
            || b == UInt8(ascii: "\n") || b == UInt8(ascii: "\r")
    }

    private static func starts(_ tag: ArraySlice<UInt8>, with text: String) -> Bool {
        let want = Array(text.utf8)
        guard tag.count > want.count else { return false }
        var i = tag.startIndex
        for w in want {
            if tag[i] != w { return false }
            i = tag.index(after: i)
        }
        // `<triangle` must not match `<trianglesets`, and `<vertex` must not
        // match a longer name either: the next byte has to end the name.
        //
        // ANY whitespace, not just a space. A slicer that wraps a long element
        // onto several lines puts a newline there, which is legal XML and was
        // read as "this is not a vertex" — so the whole part measured as
        // nothing at all.
        //
        // And `>`, for a tag with no attributes at all. `<mesh>` is one, and
        // leaving it out meant the per-mesh reset below never fired: the
        // numbers came back byte-identical to the run before it was added,
        // which is what gave it away.
        //
        // `<triangle` still does not match `<triangles>`: the byte after
        // "triangle" there is "s".
        let next = tag[i]
        return next == UInt8(ascii: "/") || next == UInt8(ascii: ">") || isSpace(next)
    }

    /// `name="value"` inside a tag, as a number.
    ///
    /// Hand-rolled rather than an XML parser because this runs tens of millions
    /// of times: `XMLParser` on 436 MB of `<vertex>` elements is minutes, and
    /// the shape here is fixed by the 3MF spec.
    private static func attribute(_ name: String, in tag: ArraySlice<UInt8>) -> Double? {
        let want = Array((name + "=\"").utf8)
        var i = tag.startIndex
        let end = tag.endIndex
        outer: while i < end {
            guard tag[i] == want[0] else { i = tag.index(after: i); continue }
            // The character before must not be a name character, or `y=` would
            // match inside `vy=`.
            if i > tag.startIndex {
                let before = tag[tag.index(before: i)]
                if !isSpace(before) && before != UInt8(ascii: "<") {
                    i = tag.index(after: i); continue
                }
            }
            var j = i
            for w in want {
                guard j < end, tag[j] == w else { i = tag.index(after: i); continue outer }
                j = tag.index(after: j)
            }
            var digits = [UInt8]()
            while j < end, tag[j] != UInt8(ascii: "\"") {
                digits.append(tag[j])
                j = tag.index(after: j)
            }
            return Double(String(decoding: digits, as: UTF8.self))
        }
        return nil
    }

    // MARK: - STL

    /// Measure an STL, binary or ASCII, without loading it.
    ///
    /// Read in chunks. A binary STL of six million facets is 300 MB and there is
    /// no reason for any of it to be resident: each facet is fifty bytes, read,
    /// added, and forgotten.
    static func measureSTL(_ url: URL) throws -> Measurement? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw Failure.unreadable(error.localizedDescription) }
        defer { try? handle.close() }

        let size = Int(try handle.seekToEnd())
        guard size >= 84 else { return try measureAsciiSTL(url) }
        try handle.seek(toOffset: 80)
        guard let header = try handle.read(upToCount: 4), header.count == 4 else { return nil }
        let claimed = Int(UInt32(header[header.startIndex])
                        | UInt32(header[header.startIndex + 1]) << 8
                        | UInt32(header[header.startIndex + 2]) << 16
                        | UInt32(header[header.startIndex + 3]) << 24)

        // A binary STL that says it holds nothing, and is exactly the size of
        // saying so. Empty is a real answer and not a failure — nil, because
        // `finished()` would give nil anyway and an exception here would make
        // an empty export look like a broken one.
        if claimed == 0, size == 84 { return nil }

        // THE FORMATS ARE TOLD APART BY ARITHMETIC, not by the word "solid".
        // An ASCII STL starts with "solid" and so do plenty of binary ones,
        // because the exporter wrote a name into the 80-byte header. The length
        // is the honest test: a binary file is exactly 84 + 50n bytes.
        guard claimed > 0, claimed <= mostTriangles, size == 84 + claimed * 50 else {
            return try measureAsciiSTL(url)
        }

        var m = Measurement()
        try streamBinarySTL(handle, size: size) { ax, ay, az, bx, by, bz, cx, cy, cz in
            m.add(ax, ay, az, bx, by, bz, cx, cy, cz)
        }
        return m.finished()
    }

    /// Every facet of a binary STL, one at a time, in file order.
    ///
    /// SHARED, because there are two readers now — the measurement above, and
    /// the preview renderer, which needs the same triangles to draw. Two copies
    /// of a parser that reads a shop's geometry is two ways to read it wrong.
    ///
    /// Generic over the body and non-escaping, so the optimiser can specialise
    /// and inline it: this runs six million times for one of this shop's files
    /// and the cost of the call IS the cost of the read.
    @inline(__always)
    static func streamBinarySTL(_ handle: FileHandle, size: Int,
                                _ body: (Double, Double, Double, Double, Double,
                                         Double, Double, Double, Double) -> Void) throws {
        // A multiple of 50 so a facet is never split across two reads.
        let chunkFacets = 20_000
        var offset = 84
        while offset < size {
            let want = min(chunkFacets * 50, size - offset)
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else { break }
            chunk.withUnsafeBytes { raw in
                let base = raw.baseAddress!
                var at = 0
                while at + 50 <= chunk.count {
                    // Little-endian Float32, and `loadUnaligned` because a facet
                    // starts every 50 bytes and 50 is not a multiple of 4.
                    func f(_ o: Int) -> Double {
                        Double(Float(bitPattern: UInt32(littleEndian:
                            base.loadUnaligned(fromByteOffset: at + o, as: UInt32.self))))
                    }
                    // Bytes 0–11 are the normal, which is ignored: it is
                    // derivable, frequently zero, and frequently wrong.
                    body(f(12), f(16), f(20), f(24), f(28), f(32), f(36), f(40), f(44))
                    at += 50
                }
            }
            offset += (chunk.count / 50) * 50
            if chunk.count < 50 { break }
        }
    }

    /// The same file, opened and streamed for a caller that has no handle.
    /// Returns false when it is not a binary STL, so a caller can fall back.
    static func eachSTLTriangle(_ url: URL,
                                _ body: (Double, Double, Double, Double, Double,
                                         Double, Double, Double, Double) -> Void) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        guard size >= 84 else { return false }
        try handle.seek(toOffset: 80)
        guard let header = try handle.read(upToCount: 4), header.count == 4 else { return false }
        let claimed = Int(UInt32(header[header.startIndex])
                        | UInt32(header[header.startIndex + 1]) << 8
                        | UInt32(header[header.startIndex + 2]) << 16
                        | UInt32(header[header.startIndex + 3]) << 24)
        guard claimed > 0, claimed <= mostTriangles, size == 84 + claimed * 50 else { return false }
        try streamBinarySTL(handle, size: size, body)
        return true
    }

    /// An OBJ's triangle count and the box it sits in.
    static func measureOBJ(_ url: URL) throws -> Measurement? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure.notAMesh("it is not UTF-8 text")
        }
        var m = Measurement()
        eachOBJTriangle(text) { ax, ay, az, bx, by, bz, cx, cy, cz in
            m.add(ax, ay, az, bx, by, bz, cx, cy, cz)
        }
        return m.finished()
    }

    /// The text form. Rare from a slicer, common out of a CAD package.
    static func measureAsciiSTL(_ url: URL) throws -> Measurement? {
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) }
        catch { throw Failure.notAMesh("it is neither binary STL nor UTF-8 text") }
        guard text.contains("facet") || text.contains("solid") else {
            throw Failure.notAMesh("no facets in it")
        }

        var m = Measurement()
        eachAsciiSTLTriangle(text) { ax, ay, az, bx, by, bz, cx, cy, cz in
            m.add(ax, ay, az, bx, by, bz, cx, cy, cz)
        }
        return m.finished()
    }

    /// Every triangle of an OBJ, from text already read.
    ///
    /// ── WHY OBJ AT ALL ────────────────────────────────────────────────────
    ///
    /// It is the third format a shop's library holds, and the one the mesh
    /// reader knew nothing about — so an OBJ was never measured and, once the
    /// renderer arrived, never drawn. Twenty-seven of one shop's models were
    /// OBJ and every one of them stayed a grey cube while four hundred others
    /// gained a picture.
    ///
    /// ── WHAT IT READS, AND WHAT IT IGNORES ────────────────────────────────
    ///
    /// `v` and `f`, and nothing else. An OBJ can carry normals, texture
    /// coordinates, materials, smoothing groups and named objects; none of them
    /// change where a triangle is, which is the only question here.
    ///
    /// A face index is 1-BASED and may be NEGATIVE, meaning "counting back from
    /// the vertices seen so far" — a relative form that several exporters use
    /// and that reads as a wild index if taken literally. A face may also be a
    /// quad or larger, and is fanned into triangles from its first corner,
    /// which is correct for the convex faces an exporter writes.
    ///
    /// `f 1/2/3` carries the vertex index before the first slash; the rest is
    /// texture and normal and is dropped.
    static func eachOBJTriangle(_ text: String,
                                _ body: (Double, Double, Double, Double, Double,
                                         Double, Double, Double, Double) -> Void) {
        var xs: [Double] = [], ys: [Double] = [], zs: [Double] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("v ") {
                let parts = t.dropFirst(2).split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 3,
                      let x = Double(parts[0]), let y = Double(parts[1]), let z = Double(parts[2])
                else { continue }
                xs.append(x); ys.append(y); zs.append(z)
            } else if t.hasPrefix("f ") {
                let corners = t.dropFirst(2).split(separator: " ", omittingEmptySubsequences: true)
                    .compactMap { field -> Int? in
                        guard let first = field.split(separator: "/", omittingEmptySubsequences: false).first,
                              let n = Int(first), n != 0 else { return nil }
                        // Negative is relative to the end, and 1-based either way.
                        let at = n > 0 ? n - 1 : xs.count + n
                        return (at >= 0 && at < xs.count) ? at : nil
                    }
                guard corners.count >= 3 else { continue }
                for i in 1..<(corners.count - 1) {
                    let a = corners[0], b = corners[i], c = corners[i + 1]
                    body(xs[a], ys[a], zs[a], xs[b], ys[b], zs[b], xs[c], ys[c], zs[c])
                }
            }
        }
    }

    /// Every facet of a text STL, from text already read.
    ///
    /// Shared with the preview renderer for the same reason the binary one is:
    /// one parser, so a model cannot be measured one way and drawn another.
    /// Sixteen of this shop's models are this format — a CAD package's default
    /// — and they were the ones that came back as grey cubes after the
    /// renderer only learned to read the binary form.
    @inline(__always)
    static func eachAsciiSTLTriangle(_ text: String,
                                     _ body: (Double, Double, Double, Double, Double,
                                              Double, Double, Double, Double) -> Void) {
        var corner: [Double] = []
        // SPLIT ON NEWLINES, not on "\n" — and the difference is not pedantry.
        //
        // In Swift a String is a sequence of grapheme clusters, and CR-LF is
        // ONE of them. So `split(separator: "\n")` finds no separator at all in
        // a file written on Windows: the whole mesh comes back as a single
        // line, no line starts with "vertex", and the reader returns nothing at
        // all. Not a truncated model — nothing.
        //
        // Fifteen of this shop's models were exactly that, measured as nothing
        // and drawn as nothing, and every one of them opens perfectly in any
        // editor. CATIA and several CAD exporters write CR-LF as a matter of
        // course. `isNewline` is true for the cluster, so this splits where a
        // person would say the lines are.
        for line in text.split(whereSeparator: \.isNewline) {
            // A lone CR, which is neither of the above and still ends a line on
            // some very old exports.
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("vertex") else { continue }
            let parts = t.dropFirst(6).split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let x = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let y = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let z = Double(parts[2].trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }
            corner.append(contentsOf: [x, y, z])
            if corner.count == 9 {
                body(corner[0], corner[1], corner[2], corner[3], corner[4],
                     corner[5], corner[6], corner[7], corner[8])
                corner.removeAll(keepingCapacity: true)
            }
        }
    }
}
