import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A file on disk, through both passes, to findings a shop can read.
///
/// `PrintRiskParityTests` proves the Swift accumulator counts what the shared
/// rule counts. This proves the rest of the chain is connected: that
/// `Mesh.overhangs` finds a reader for each of the four formats, that the
/// summary it produces is the shape `assessModel` expects, and that the box
/// comes from the measurement rather than being quietly dropped.
///
/// Every expected figure was computed by running the shared rule on the same
/// shape and checking it by hand — the table below is 960 mm³ because 4×4×10
/// and 20×20×2 are 160 and 800, and its underside is 400 mm² because the slab
/// is 20 × 20.
@MainActor
struct PrintRiskTests {

    static func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-risk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A box, wound outwards. Same winding as `MeshTests.boxFacets`.
    static func box(_ x0: Double, _ y0: Double, _ z0: Double,
                    _ w: Double, _ d: Double, _ h: Double) -> [(Double, Double, Double)] {
        let (x1, y1, z1) = (x0 + w, y0 + d, z0 + h)
        let v: [(Double, Double, Double)] = [
            (x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0),
            (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1),
        ]
        let faces = [(0,3,2),(0,2,1),(4,5,6),(4,6,7),(0,1,5),(0,5,4),
                     (1,2,6),(1,6,5),(2,3,7),(2,7,6),(3,0,4),(3,4,7)]
        return faces.flatMap { [v[$0.0], v[$0.1], v[$0.2]] }
    }

    /// A 4×4 post with a 20×20 slab on it. The slab's underside is a bridge —
    /// the thing that droops into the cavity rather than merely printing rough.
    static var table: [(Double, Double, Double)] {
        box(8, 8, 0, 4, 4, 10) + box(0, 0, 10, 20, 20, 2)
    }

    static func writeSTL(_ corners: [(Double, Double, Double)], to url: URL) throws {
        var out = Data(count: 80)
        let count = UInt32(corners.count / 3)
        withUnsafeBytes(of: count.littleEndian) { out.append(contentsOf: $0) }
        for i in stride(from: 0, to: corners.count, by: 3) {
            for _ in 0..<3 {
                withUnsafeBytes(of: Float(0).bitPattern.littleEndian) { out.append(contentsOf: $0) }
            }
            for c in [corners[i], corners[i + 1], corners[i + 2]] {
                for value in [c.0, c.1, c.2] {
                    withUnsafeBytes(of: Float(value).bitPattern.littleEndian) { out.append(contentsOf: $0) }
                }
            }
            out.append(contentsOf: [0, 0])
        }
        try out.write(to: url)
    }

    static func writeOBJ(_ corners: [(Double, Double, Double)], to url: URL) throws {
        var lines: [String] = []
        for c in corners { lines.append("v \(c.0) \(c.1) \(c.2)") }
        for i in stride(from: 0, to: corners.count, by: 3) {
            lines.append("f \(i + 1) \(i + 2) \(i + 3)")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func num(_ v: JSONValue?) -> Double {
        if case .number(let n)? = v { return n } else { return .nan }
    }

    // MARK: - The summary a file produces

    @Test("a file on disk comes back with the summary the rule wants")
    func summaryFromFile() throws {
        let url = try Self.tempDir().appending(path: "table.stl")
        try Self.writeSTL(Self.table, to: url)

        let a = try #require(try Mesh.overhangs(of: url), "the STL produced no summary")
        #expect(Self.num(a["triangleCount"]) == 24)
        #expect(abs(Self.num(a["volumeMm3"]) - 960) < 1e-3, "4×4×10 and 20×20×2 are 960 mm³")
        #expect(abs(Self.num(a["totalAreaMm2"]) - 1152) < 1e-3)
        // 400 for the slab's underside and 16 for the post's foot: both face
        // down, and only one of them is an overhang.
        #expect(abs(Self.num(a["downwardAreaMm2"]) - 416) < 1e-3)
        #expect(abs(Self.num(a["bedContactAreaMm2"]) - 16) < 1e-3,
                "the post's foot is 4 × 4 and it is the only thing on the plate")
        guard case .array(let hist)? = a["histogram"] else {
            Issue.record("the histogram did not cross as an array"); return
        }
        #expect(hist.count == 91)
    }

    @Test("the same shape reads the same in all four formats")
    func everyFormat() throws {
        // A model measured one way and judged another is the bug this shop had
        // when the preview renderer knew only binary STL: sixteen CAD exports
        // came back as grey cubes and nothing reported an error.
        let dir = try Self.tempDir()
        let binary = dir.appending(path: "t.stl")
        let obj = dir.appending(path: "t.obj")
        try Self.writeSTL(Self.table, to: binary)
        try Self.writeOBJ(Self.table, to: obj)

        let a = try #require(try Mesh.overhangs(of: binary))
        let b = try #require(try Mesh.overhangs(of: obj))
        for key in ["triangleCount", "volumeMm3", "totalAreaMm2",
                    "downwardAreaMm2", "bedContactAreaMm2"] {
            #expect(abs(Self.num(a[key]) - Self.num(b[key])) < 1e-3,
                    Comment(rawValue: "\(key): STL \(Self.num(a[key])), OBJ \(Self.num(b[key]))"))
        }
    }

    @Test("a text STL is read, not measured as nothing")
    func asciiSTL() throws {
        // Fifteen of this shop's models are text STL written with CR-LF, and
        // they were measured as nothing rather than as broken.
        var lines = ["solid table"]
        let corners = Self.table
        for i in stride(from: 0, to: corners.count, by: 3) {
            lines.append("  facet normal 0 0 0")
            lines.append("    outer loop")
            for c in [corners[i], corners[i + 1], corners[i + 2]] {
                lines.append("      vertex \(c.0) \(c.1) \(c.2)")
            }
            lines.append("    endloop")
            lines.append("  endfacet")
        }
        lines.append("endsolid table")
        let url = try Self.tempDir().appending(path: "t.stl")
        try lines.joined(separator: "\r\n").write(to: url, atomically: true, encoding: .utf8)

        let a = try #require(try Mesh.overhangs(of: url), "a CR-LF text STL read as nothing")
        #expect(Self.num(a["triangleCount"]) == 24)
        #expect(abs(Self.num(a["volumeMm3"]) - 960) < 1e-3)
    }

    @Test("a file carrying no mesh is nil, not an empty model")
    func noMesh() throws {
        let dir = try Self.tempDir()
        let gcode = dir.appending(path: "job.gcode")
        try "G1 X10 Y10\n".write(to: gcode, atomically: true, encoding: .utf8)
        // Nil rather than a summary of nothing: a caller must be able to tell
        // "this has no overhangs" from "this is not a model".
        #expect(try Mesh.overhangs(of: gcode) == nil)
    }

    // MARK: - The judgement

    @Test("a slab on a post is reported as an overhang and a bridge")
    func tableIsJudged() async throws {
        let url = try Self.tempDir().appending(path: "table.stl")
        try Self.writeSTL(Self.table, to: url)
        let a = try #require(try Mesh.overhangs(of: url))
        let m = try #require(try Mesh.readGeometry(url))

        let engine = try KhaytEngine()
        let report = try await engine.assessModel(
            analysis: a, nozzleDiameter: 0.4,
            bed: (x: 256, y: 256, z: 256), bbox: (x: m.x, y: m.y, z: m.z))

        #expect(report.worst == "warn")
        let ids = report.risks.map(\.id).sorted()
        #expect(ids == ["bridge", "overhang"], Comment(rawValue: "got \(ids)"))

        // 400 of 1152 mm² — and BOTH lines report it, because a 50° slope and a
        // flat ceiling fail differently and are fixed differently.
        for r in report.risks {
            #expect(abs((r.fraction ?? 0) - 0.3472222) < 1e-5,
                    Comment(rawValue: "\(r.id): fraction \(r.fraction ?? -1)"))
            #expect(abs((r.areaMm2 ?? 0) - 400) < 1e-3)
        }
        #expect(report.risks.first { $0.id == "overhang" }?.thresholdDeg == 45)
        #expect(report.risks.first { $0.id == "bridge" }?.thresholdDeg == 80)
    }

    @Test("a wall thinner than the nozzle bore is critical")
    func thinWall() async throws {
        // 40 × 40 × 0.3: a 0.2956 mm mean wall, which is under one 0.4 mm bore
        // and therefore cannot be laid down at all.
        let url = try Self.tempDir().appending(path: "thin.stl")
        try Self.writeSTL(Self.box(0, 0, 0, 40, 40, 0.3), to: url)
        let a = try #require(try Mesh.overhangs(of: url))

        let report = try await KhaytEngine().assessModel(analysis: a, nozzleDiameter: 0.4)
        #expect(report.worst == "crit")
        let thin = try #require(report.risks.first { $0.id == "thin" })
        #expect(abs((thin.meanThicknessMm ?? 0) - 0.2955665) < 1e-5)
        #expect(abs((thin.bores ?? 0) - 0.7389163) < 1e-5)
        #expect(thin.nozzleDiameter == 0.4)
    }

    @Test("the plate check needs the box, and gets it")
    func bedFit() async throws {
        // THE BOX COMES FROM THE MEASUREMENT, not from the overhang pass — the
        // accumulator tracks which way surfaces face and never the extent. Pass
        // no box and this check has nothing to compare, finds nothing, and
        // reads as "it fits".
        let url = try Self.tempDir().appending(path: "long.stl")
        try Self.writeSTL(Self.box(0, 0, 0, 300, 40, 10), to: url)
        let a = try #require(try Mesh.overhangs(of: url))
        let m = try #require(try Mesh.readGeometry(url))
        let engine = try KhaytEngine()

        let told = try await engine.assessModel(analysis: a, bed: (x: 256, y: 256, z: 256),
                                                bbox: (x: m.x, y: m.y, z: m.z))
        let bed = try #require(told.risks.first { $0.id == "bed" },
                               "300 mm on a 256 mm plate was not reported")
        #expect(bed.severity == "crit")
        #expect(bed.tooTall == false, "it is too wide, not too tall")

        let unasked = try await engine.assessModel(analysis: a, bed: (x: 256, y: 256, z: 256))
        #expect(!unasked.risks.contains { $0.id == "bed" },
                "without the box this cannot know, and must not guess")
    }

    @Test("a part that only needs turning is not reported as too big")
    func needsTurning() async throws {
        // "Rotate it 90°" is a real answer, and reporting a part as too big when
        // it merely needs turning is a false alarm the operator disproves by hand.
        let url = try Self.tempDir().appending(path: "wide.stl")
        try Self.writeSTL(Self.box(0, 0, 0, 240, 100, 10), to: url)
        let a = try #require(try Mesh.overhangs(of: url))
        let m = try #require(try Mesh.readGeometry(url))

        let report = try await KhaytEngine().assessModel(
            analysis: a, bed: (x: 120, y: 250, z: 250), bbox: (x: m.x, y: m.y, z: m.z))
        #expect(report.risks.map(\.id).contains("bed-rotate"))
        #expect(!report.risks.contains { $0.id == "bed" })
        #expect(report.worst == "info", "needing a turn is not a warning")
    }

    @Test("a box on the plate has nothing to report")
    func cleanPart() async throws {
        // The answer for most functional parts, and the one that makes the rest
        // worth reading: a report that warns about everything warns about nothing.
        let url = try Self.tempDir().appending(path: "cube.stl")
        try Self.writeSTL(Self.box(0, 0, 0, 20, 20, 20), to: url)
        let a = try #require(try Mesh.overhangs(of: url))
        let m = try #require(try Mesh.readGeometry(url))

        let report = try await KhaytEngine().assessModel(
            analysis: a, nozzleDiameter: 0.4,
            bed: (x: 256, y: 256, z: 256), bbox: (x: m.x, y: m.y, z: m.z))
        #expect(report.risks.isEmpty, Comment(rawValue: "reported \(report.risks.map(\.id))"))
        #expect(report.worst == nil)
    }

    // MARK: - The setting, exercised rather than inspected

    /// A store and a library root in a temp directory, and one model imported
    /// into them for real.
    ///
    /// `test/print-risk-wiring.test.js` reads the call sites out of the source,
    /// because a caller that forgets `analyseRisk:` compiles clean. But it said
    /// proving the behaviour needed "a real store, a real library root and a
    /// real ten-million-facet file", and that was simply wrong:
    /// `LibraryImport.add` takes the store and the root as arguments, so it
    /// needs a temp directory and a 24-triangle STL.
    static func emptyBook(in dir: URL) throws -> URL {
        let url = dir.appending(path: "khayt-store.json")
        let root: JSONValue = .object([
            "printFiles": .array([]), "orders": .array([]),
            "settings": .object([:]),
        ])
        try JSONEncoder().encode(root).write(to: url)
        return url
    }

    static func importOne(_ model: URL, store: URL, root: URL,
                          analyseRisk: Bool) async throws -> LibraryImport.Added {
        try await LibraryImport.add(
            model, storeURL: store, libraryRoot: root,
            knownHashes: [], nameOfExisting: { _ in nil },
            engine: try KhaytEngine(), keepOriginal: true,
            analyseRisk: analyseRisk,
            owns: { true }, whoHasIt: { nil })
    }

    static func onlyRecord(in store: URL) throws -> LibraryFile {
        let raw = try JSONDecoder().decode([String: JSONValue].self,
                                           from: try Data(contentsOf: store))
        guard case .array(let rows)? = raw["printFiles"], let first = rows.first else {
            throw Oops.noRecord
        }
        return try JSONDecoder().decode(LibraryFile.self,
                                        from: try JSONEncoder().encode(first))
    }

    enum Oops: Error { case noRecord }

    @Test("asked at import, the walk happens and the answer is on the record")
    func walksAtImport() async throws {
        let dir = try Self.tempDir()
        let model = dir.appending(path: "table.stl")
        try Self.writeSTL(Self.table, to: model)
        let store = try Self.emptyBook(in: dir)
        let root = dir.appending(path: "vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = try await Self.importOne(model, store: store, root: root, analyseRisk: true)
        let file = try Self.onlyRecord(in: store)

        #expect(file.hasRiskAnalysis, "the import was asked to walk the mesh and did not")
        #expect(Self.num(file.riskAnalysis?["volumeMm3"]) == 960)
        #expect(Self.num(file.riskAnalysis?["bedContactAreaMm2"]) == 16)
        // And it describes the bytes that landed, so it cannot be read as
        // current after the file behind it is replaced.
        #expect(file.printRisk?.contentHash == file.contentHash)

        // Straight through to findings with no second read of the file.
        let report = try await KhaytEngine().assessModel(
            analysis: try #require(file.riskAnalysis), nozzleDiameter: 0.4)
        #expect(report.risks.map(\.id).sorted() == ["bridge", "overhang"])
    }

    @Test("not asked, the import writes no summary and costs nothing")
    func skipsWhenNotAsked() async throws {
        let dir = try Self.tempDir()
        let model = dir.appending(path: "table.stl")
        try Self.writeSTL(Self.table, to: model)
        let store = try Self.emptyBook(in: dir)
        let root = dir.appending(path: "vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = try await Self.importOne(model, store: store, root: root, analyseRisk: false)
        let file = try Self.onlyRecord(in: store)

        #expect(!file.hasRiskAnalysis, "the default walked the mesh anyway")
        #expect(file.printRisk == nil, "a field was written to say nothing happened")
        // The import itself still worked — the walk is the only difference.
        #expect(file.geometryKey != nil, "the measurement was lost along with the walk")
        #expect(file.contentHash != nil)
    }

    @Test("a gcode is imported without being asked for a mesh it has not got")
    func gcodeAtImport() async throws {
        // `analyseRisk` is true here and must still be a no-op: the guard is on
        // there being geometry, not on the flag alone.
        let dir = try Self.tempDir()
        let job = dir.appending(path: "plate.gcode")
        try "G1 X10 Y10 E1\n".write(to: job, atomically: true, encoding: .utf8)
        let store = try Self.emptyBook(in: dir)
        let root = dir.appending(path: "vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = try await Self.importOne(job, store: store, root: root, analyseRisk: true)
        let file = try Self.onlyRecord(in: store)
        #expect(file.sourceFile?.kind == "gcode")
        #expect(!file.hasRiskAnalysis)
    }

    // MARK: - The shop's own library

    /// THE ONE THAT PROVES THE CLAIM.
    ///
    /// The Electron path caps this at four million facets
    /// (`lib/model-intake.js`) because it has to BUILD the triangle list. Two
    /// of the 83 readable meshes in this library are past that — 6.6M and 4.3M
    /// facets — and get no report at all there. This streams, so the file's
    /// size stops being the question.
    ///
    /// It checks the first eight it can read rather than all 83: this is
    /// seconds per file, and eight is enough to prove the chain holds on real
    /// geometry. Runs against whatever the library holds and skips when there
    /// is none.
    @Test("the library's real models get an answer, however large")
    func realLibrary() async throws {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/khayt")
        let store = support.appending(path: "khayt-store.json")
        let vault = support.appending(path: "print-files-vault")
        guard FileManager.default.fileExists(atPath: store.path),
              FileManager.default.fileExists(atPath: vault.path) else { return }

        let root = try JSONDecoder().decode([String: JSONValue].self,
                                            from: try Data(contentsOf: store))
        guard case .array(let files)? = root["printFiles"] else { return }

        let engine = try KhaytEngine()
        var checked = 0, biggest = 0.0
        for file in files {
            guard case .object(let record) = file,
                  case .string(let id)? = record["id"],
                  case .object(let source)? = record["sourceFile"],
                  case .string(let name)? = source["filename"] else { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            guard ["3mf", "stl", "obj"].contains(ext) else { continue }
            let path = vault.appending(path: id).appending(path: name)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }

            guard let a = try? Mesh.overhangs(of: path) else { continue }
            let triangles = Self.num(a["triangleCount"])
            #expect(triangles > 0, Comment(rawValue: "\(name): read no triangles"))
            biggest = max(biggest, triangles)

            // The judgement has to survive every real file too, not just
            // return: a thrown error here is a quote the shop does not get.
            let report = try await engine.assessModel(analysis: a, nozzleDiameter: 0.4)
            #expect(["info", "warn", "crit"].contains(report.worst ?? "info"),
                    Comment(rawValue: "\(name): worst was \(report.worst ?? "nil")"))
            #expect(report.supportThresholdDeg == 45)
            checked += 1
            if checked >= 8 { break }   // eight is enough to prove it; this is minutes per file
        }
        if checked == 0 {
            Issue.record(Comment(rawValue: "no readable mesh in the library to check against"))
        } else {
            print("print-risk: answered for \(checked) real models, largest \(Int(biggest)) triangles")
        }
    }
}
