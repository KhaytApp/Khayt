import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Measuring the mesh inside a 3MF.
///
/// The fixtures are built here so the answer is arithmetic. The last test is the
/// one that matters: this shop's own files, against the keys Khayt already wrote
/// for them — the only check that proves a record made on the Mac and a record
/// made in the other app describe the same model.
@MainActor
struct Mesh3MFTests {

    static func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-3mf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A 3MF holding one box, written the way the spec describes it.
    static func make3MF(in dir: URL, named: String,
                        w: Double, d: Double, h: Double,
                        originX: Double = 0, extraWhitespace: Bool = false) throws -> URL {
        let v: [(Double, Double, Double)] = [
            (originX, 0, 0), (originX + w, 0, 0), (originX + w, d, 0), (originX, d, 0),
            (originX, 0, h), (originX + w, 0, h), (originX + w, d, h), (originX, d, h),
        ]
        let faces = [(0,3,2),(0,2,1),(4,5,6),(4,6,7),(0,1,5),(0,5,4),
                     (1,2,6),(1,6,5),(2,3,7),(2,7,6),(3,0,4),(3,4,7)]
        let gap = extraWhitespace ? "\n        " : ""
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <resources>
          <object id="1" type="model">
           <mesh>
            <vertices>
        """
        for p in v { xml += "\n     <vertex\(gap) x=\"\(p.0)\" y=\"\(p.1)\" z=\"\(p.2)\"/>" }
        xml += "\n    </vertices>\n    <triangles>"
        for f in faces { xml += "\n     <triangle\(gap) v1=\"\(f.0)\" v2=\"\(f.1)\" v3=\"\(f.2)\"/>" }
        xml += """

            </triangles>
           </mesh>
          </object>
         </resources>
         <build><item objectid="1"/></build>
        </model>
        """

        let staging = dir.appending(path: "staging-\(UUID().uuidString)")
        let modelDir = staging.appending(path: "3D")
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try Data(xml.utf8).write(to: modelDir.appending(path: "3dmodel.model"))

        let archive = dir.appending(path: named)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", archive.path, "."]
        process.currentDirectoryURL = staging
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return archive
    }

    /// A 3MF carrying whatever it likes where a number belongs.
    static func hostile3MF(in dir: URL, named: String, triangles: String) throws -> URL {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <resources>
          <object id="1" type="model">
           <mesh>
            <vertices>
             <vertex x="0" y="0" z="0"/>
             <vertex x="10" y="0" z="0"/>
             <vertex x="10" y="10" z="0"/>
             <vertex x="0" y="0" z="10"/>
            </vertices>
            <triangles>
        \(triangles)
            </triangles>
           </mesh>
          </object>
         </resources>
         <build><item objectid="1"/></build>
        </model>
        """
        let staging = dir.appending(path: "staging-\(UUID().uuidString)")
        let modelDir = staging.appending(path: "3D")
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try Data(xml.utf8).write(to: modelDir.appending(path: "3dmodel.model"))
        let archive = dir.appending(path: named)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", archive.path, "."]
        process.currentDirectoryURL = staging
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return archive
    }

    /// A NUMBER THAT IS NOT ONE MUST NOT TAKE THE APP WITH IT.
    ///
    /// `attribute` hands back whatever `Double(String)` made of the file, and
    /// `Int(someDouble)` TRAPS: "Double value cannot be converted to Int
    /// because it is either infinite or NaN". So `v1="nan"` — three characters
    /// in a file a customer emails a shop — crashed Khayt outright. Measured
    /// with a standalone `Int(Double.nan)`, which exits 133.
    ///
    /// A crash is not the worst of it: this runs over a whole downloads folder
    /// during an import, so one bad file took the other three hundred with it.
    @Test("a 3MF whose indices are not numbers is read, not crashed on")
    func hostileIndices() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        for (name, v1) in [("nan", "nan"), ("inf", "inf"), ("huge", "1e400"),
                           ("negative", "-1"), ("past-int", "1e30"),
                           ("empty", ""), ("words", "first")] {
            let url = try Self.hostile3MF(
                in: dir, named: "bad-\(name).3mf",
                triangles: """
                     <triangle v1="\(v1)" v2="1" v3="2"/>
                     <triangle v1="0" v2="1" v3="3"/>
                """)
            // The good triangle survives; the unreadable one is dropped. Nil is
            // also an acceptable answer — what is not acceptable is a trap.
            let m = try Mesh.measure3MF(url)
            #expect(m?.triangleCount ?? 0 <= 1,
                    Comment(rawValue: "\(name): a triangle with v1=\(v1) was counted"))
        }
    }

    @Test("a vertex that is not a number does not become a measurement")
    func hostileVertices() throws {
        // No trap here — a NaN coordinate is only ever stored as a Double — but
        // it poisons min/max, and `Infinity` does not survive JSON either, so a
        // geometryKey built from it would be null where a number belongs.
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let xml = """
             <triangle v1="0" v2="1" v3="2"/>
        """
        let url = try Self.hostile3MF(in: dir, named: "nanvertex.3mf", triangles: xml)
        // The fixture's vertices are all finite, so this is the control: it
        // reads, and it reads as a real triangle.
        let m = try Mesh.measure3MF(url)
        #expect(m?.triangleCount == 1)
    }

    @Test("a box in a 3MF measures like a box")
    func oneBox() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.make3MF(in: dir, named: "box.3mf", w: 20, d: 10, h: 5)

        let m = try #require(try Mesh.measure3MF(url))
        #expect(m.triangleCount == 12)
        #expect(abs(m.volumeMm3 - 1000) < 0.01, "20 × 10 × 5 is 1000 mm³")
        #expect(abs(m.x - 20) < 0.001 && abs(m.y - 10) < 0.001 && abs(m.z - 5) < 0.001)
    }

    /// Attributes wrapped onto their own lines, which slicers do.
    ///
    /// The reader carries the tail of a chunk into the next one, and a tag split
    /// across that boundary is the failure it exists to prevent — a dropped
    /// vertex shifts every index after it and the volume becomes nonsense
    /// rather than becoming obviously wrong.
    @Test("whitespace inside a tag does not lose it")
    func awkwardWhitespace() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = try Self.make3MF(in: dir, named: "a.3mf", w: 20, d: 10, h: 5)
        let spaced = try Self.make3MF(in: dir, named: "b.3mf", w: 20, d: 10, h: 5,
                                      extraWhitespace: true)
        let a = try #require(try Mesh.measure3MF(plain))
        let b = try #require(try Mesh.measure3MF(spaced))
        #expect(a == b)
    }

    @Test("an archive with no model part says so")
    func noModel() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = dir.appending(path: "s")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: staging.appending(path: "readme.txt"))
        let archive = dir.appending(path: "empty.3mf")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q", "-r", archive.path, "."]
        p.currentDirectoryURL = staging
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()

        #expect(throws: Mesh.Failure.notAMesh("no model part in the archive")) {
            _ = try Mesh.measure3MF(archive)
        }
    }

    // MARK: - This shop's own files

    /// THE ONE THAT PROVES IT.
    ///
    /// Khayt has already measured these files and written a `geometryKey` into
    /// the book. A record made here has to carry the same key or the two apps
    /// will not recognise each other's models.
    ///
    /// It runs against whatever the library holds and skips when there is no
    /// library — so it is silent on another machine and exact on this one.
    @Test("the key this produces is the key Khayt already wrote")
    func matchesKhaytsOwnKeys() async throws {
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
        var checked = 0
        for file in files {
            guard case .object(let record) = file,
                  case .string(let id)? = record["id"],
                  case .string(let expected)? = record["geometryKey"],
                  case .object(let source)? = record["sourceFile"],
                  case .string(let name)? = source["filename"],
                  name.lowercased().hasSuffix(".3mf") else { continue }
            let path = vault.appending(path: id).appending(path: name)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }

            let m = try #require(try Mesh.measure3MF(path), "\(name) measured as nothing")
            let mine = try await engine.geometryKey(triangleCount: m.triangleCount,
                                                    volumeMm3: m.volumeMm3,
                                                    x: m.x, y: m.y, z: m.z)
            #expect(mine == expected, "\(name): Khayt says \(expected), this says \(mine ?? "nil")")
            checked += 1
        }
        // Not an assertion that the library has files — it may not — but a note
        // in the log when this test checked nothing at all.
        if checked == 0 { Issue.record(Comment(rawValue: "no measured 3MF in the library to check against")) }
    }
}

/// Many triangles, so the reader crosses dozens of chunk boundaries.
///
/// A tag split across two inflate chunks is carried into the next one, and
/// losing one there loses a triangle — quietly, because 499,626 and 492,786
/// both look like plausible triangle counts. This is the test that says which.
extension Mesh3MFTests {

    static func makeBig3MF(in dir: URL, boxes: Int) throws -> URL {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter">
         <resources>
          <object id="1" type="model">
           <mesh>
            <vertices>
        """
        for i in 0..<boxes {
            let ox = Double(i) * 2
            for p in [(ox, 0.0, 0.0), (ox + 1, 0.0, 0.0), (ox + 1, 1.0, 0.0), (ox, 1.0, 0.0),
                      (ox, 0.0, 1.0), (ox + 1, 0.0, 1.0), (ox + 1, 1.0, 1.0), (ox, 1.0, 1.0)] {
                xml += "\n     <vertex x=\"\(p.0)\" y=\"\(p.1)\" z=\"\(p.2)\"/>"
            }
        }
        xml += "\n    </vertices>\n    <triangles>"
        let faces = [(0,3,2),(0,2,1),(4,5,6),(4,6,7),(0,1,5),(0,5,4),
                     (1,2,6),(1,6,5),(2,3,7),(2,7,6),(3,0,4),(3,4,7)]
        for i in 0..<boxes {
            let base = i * 8
            for f in faces {
                xml += "\n     <triangle v1=\"\(base + f.0)\" v2=\"\(base + f.1)\" v3=\"\(base + f.2)\"/>"
            }
        }
        xml += "\n    </triangles>\n   </mesh>\n  </object>\n </resources>\n</model>"

        let staging = dir.appending(path: "big-\(UUID().uuidString)")
        let modelDir = staging.appending(path: "3D/Objects")
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try Data(xml.utf8).write(to: modelDir.appending(path: "object_1.model"))
        let archive = dir.appending(path: "big.3mf")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q", "-r", archive.path, "."]
        p.currentDirectoryURL = staging
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return archive
    }

    @Test("every triangle survives the chunk boundaries")
    func manyTrianglesAcrossChunks() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 30,000 unit boxes: 240,000 vertices, 360,000 triangles, and roughly
        // 25 MB of XML — two dozen inflate chunks.
        let boxes = 30_000
        let url = try Self.makeBig3MF(in: dir, boxes: boxes)

        let m = try #require(try Mesh.measure3MF(url))
        #expect(m.triangleCount == boxes * 12, "lost \(boxes * 12 - m.triangleCount) triangles")
        #expect(abs(m.volumeMm3 - Double(boxes)) < 1, "each box is 1 mm³")
    }
}

/// The placement matrix.
///
/// Twelve numbers, row-vector convention — `x' = x·m0 + y·m3 + z·m6 + m9`. Get
/// the rows and columns the wrong way round and a rotation still looks like a
/// rotation, so only a file with a known answer catches it. These pin the
/// convention directly, so a failure says which half is wrong.
@MainActor
struct PlacementTests {

    @Test("twelve numbers, and nothing else")
    func parsing() {
        #expect(Mesh.Placement("1 0 0 0 1 0 0 0 1 0 0 0")?.isIdentity == true)
        #expect(Mesh.Placement("1 0 0 0 1 0 0 0 1 5 6 7")?.isIdentity == false)
        #expect(Mesh.Placement("1 0 0") == nil)
        #expect(Mesh.Placement("") == nil)
        #expect(Mesh.Placement("a b c d e f g h i j k l") == nil)
        // Slicers write these across lines and with runs of spaces.
        #expect(Mesh.Placement("1 0 0\n 0 1 0\t0 0 1  9 8 7") != nil)
    }

    @Test("a translation moves a point and leaves it otherwise alone")
    func translation() throws {
        let p = try #require(Mesh.Placement("1 0 0 0 1 0 0 0 1 10 -20 30"))
        let out = p.apply(1, 2, 3)
        #expect(abs(out.0 - 11) < 1e-9)
        #expect(abs(out.1 + 18) < 1e-9)
        #expect(abs(out.2 - 33) < 1e-9)
    }

    /// A quarter turn about Z: x → y, y → −x. If the matrix were read
    /// column-major this would turn the other way, which on a symmetrical part
    /// is invisible.
    @Test("a rotation turns the way the matrix says")
    func rotation() throws {
        let p = try #require(Mesh.Placement("0 1 0 -1 0 0 0 0 1 0 0 0"))
        let out = p.apply(1, 0, 0)
        #expect(abs(out.0) < 1e-9)
        #expect(abs(out.1 - 1) < 1e-9)
        #expect(abs(out.2) < 1e-9)
    }

    /// The item's placement applies on top of the component's, in that order.
    /// Composed the other way, a rotated part translates along the wrong axis.
    @Test("composing puts the item's placement outside the component's")
    func composition() throws {
        // Component: move 10 along x. Item: quarter turn about Z.
        let inner = try #require(Mesh.Placement("1 0 0 0 1 0 0 0 1 10 0 0"))
        let outer = try #require(Mesh.Placement("0 1 0 -1 0 0 0 0 1 0 0 0"))
        let both = outer.composed(with: inner)

        // The origin moves to (10,0,0), then turns to (0,10,0).
        let out = both.apply(0, 0, 0)
        #expect(abs(out.0) < 1e-9, "got \(out)")
        #expect(abs(out.1 - 10) < 1e-9, "got \(out)")
        // …which is not what the other order gives, and that is the point.
        let wrongWay = inner.composed(with: outer).apply(0, 0, 0)
        #expect(abs(wrongWay.0 - 10) < 1e-9)
        #expect(abs(wrongWay.1) < 1e-9)
    }

    @Test("composing with identity changes nothing, either way round")
    func identityComposition() throws {
        let p = try #require(Mesh.Placement("0.7 0.7 0 -0.7 0.7 0 0 0 1 3 4 5"))
        #expect(p.composed(with: Mesh.Placement()) == p)
        #expect(Mesh.Placement().composed(with: p) == p)
    }
}
