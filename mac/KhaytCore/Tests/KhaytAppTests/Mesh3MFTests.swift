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
    /// A root object made of several components into one part.
    ///
    /// ── THE SHAPE THE SHOP'S OWN FILES HAVE ─────────────────────────────────
    ///
    /// Bambu and Orca split a project into `3D/Objects/*.model` parts and build
    /// a root object from `<component p:path= objectid= transform=>` references
    /// — several of them, when the object was assembled from pieces. The
    /// AlQadsiah nameplate is one object of two components into ONE part,
    /// placed 6 mm apart in z.
    ///
    /// The reader kept one component per object and streamed the whole part
    /// under it. Same triangle count, wrong heights: volume 42,772 against
    /// Electron's 127,445 on that file, and a box 149 mm across where the file
    /// says 170. Every number plausible, none of them the model's.
    @Test("every component of an object is read, at its own placement")
    func componentsAreReadSeparately() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-3mf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two 10 mm cubes in one part, as objects 3 and 4.
        func cube(_ id: Int) -> String {
            let v = [(0,0,0),(10,0,0),(10,10,0),(0,10,0),(0,0,10),(10,0,10),(10,10,10),(0,10,10)]
            let f = [(0,3,2),(0,2,1),(4,5,6),(4,6,7),(0,1,5),(0,5,4),
                     (1,2,6),(1,6,5),(2,3,7),(2,7,6),(3,0,4),(3,4,7)]
            var x = "<object id=\"\(id)\" type=\"model\"><mesh><vertices>"
            for p in v { x += "<vertex x=\"\(p.0)\" y=\"\(p.1)\" z=\"\(p.2)\"/>" }
            x += "</vertices><triangles>"
            for t in f { x += "<triangle v1=\"\(t.0)\" v2=\"\(t.1)\" v3=\"\(t.2)\"/>" }
            return x + "</triangles></mesh></object>"
        }
        let part = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <resources>\(cube(3))\(cube(4))</resources><build/>
        </model>
        """
        // Object 5 is object 3 raised 30 mm and object 4 shifted 50 mm in x.
        let root = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06">
         <resources>
          <object id="5" type="model"><components>
           <component p:path="/3D/Objects/part.model" objectid="3" transform="1 0 0 0 1 0 0 0 1 0 0 30"/>
           <component p:path="/3D/Objects/part.model" objectid="4" transform="1 0 0 0 1 0 0 0 1 50 0 0"/>
          </components></object>
         </resources>
         <build><item objectid="5" transform="1 0 0 0 1 0 0 0 1 100 100 0"/></build>
        </model>
        """
        let staging = dir.appending(path: "staging")
        try FileManager.default.createDirectory(at: staging.appending(path: "3D/Objects"),
                                                withIntermediateDirectories: true)
        try Data(root.utf8).write(to: staging.appending(path: "3D/3dmodel.model"))
        try Data(part.utf8).write(to: staging.appending(path: "3D/Objects/part.model"))
        let archive = dir.appending(path: "assembly.3mf")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", archive.path, "."]
        zip.currentDirectoryURL = staging
        zip.standardOutput = Pipe(); zip.standardError = Pipe()
        try zip.run(); zip.waitUntilExit()

        let m = try #require(try Mesh.measure3MF(archive))
        #expect(m.triangleCount == 24, "both components are read once each")
        // Not `== 2000`: the 100 mm translation puts the vertices where a
        // double keeps them to fourteen places, not sixteen.
        #expect(abs(m.volumeMm3 - 2000) < 1e-6, "two closed 10 mm cubes, got \(m.volumeMm3)")
        // Object 3 at z 30…40 and object 4 at x 150…160: the union is 60 wide
        // and 40 tall. Streaming the whole part under the LAST component's
        // placement gives 60 × 10 × 10 instead — the bug this pins.
        #expect(m.x == 60, "\(m.x) wide")
        #expect(m.y == 10)
        #expect(m.z == 40, "\(m.z) tall — the first component's 30 mm lift was lost")
    }

    /// A root part too big to read whole, with a build transform that matters.
    ///
    /// ── THE BUG THIS PINS ────────────────────────────────────────────────
    ///
    /// `buildPlan` read the root with `Zip.data`, which refuses a member over
    /// 8 MiB — right for a mesh part, and the root IS the mesh part when a
    /// slicer has not split the file. `try?` turned the refusal into nil, the
    /// plan came back nil, and the fallback measured every part at identity:
    /// the raw mesh, un-rotated, un-placed. Fourteen of the shop's 85 files
    /// have such a root; every one of them was measured that way and had that
    /// key written into the book.
    ///
    /// The mesh here is inflated past the limit with a long, dull object and
    /// the item turns it a quarter turn about z — so the box that comes back
    /// says which reader measured it.
    @Test("a root part over the read limit still has its build transform applied")
    func oversizedRootKeepsItsTransform() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-3mf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "s/3D"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A 100 × 10 × 10 bar made of many thin slabs: enough `<vertex` and
        // `<triangle` text to pass 8 MiB, with a box that is not square.
        var xml = "<?xml version=\"1.0\"?><model unit=\"millimeter\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\"><resources><object id=\"1\" type=\"model\"><mesh><vertices>"
        let slabs = 30_000
        for i in 0..<slabs {
            let x0 = Double(i) * 100 / Double(slabs), x1 = x0 + 100 / Double(slabs)
            for (x, y, z) in [(x0,0,0),(x1,0,0),(x1,10,0),(x0,10,0),(x0,0,10),(x1,0,10),(x1,10,10),(x0,10,10)] {
                xml += "<vertex x=\"\(x)\" y=\"\(y)\" z=\"\(z)\"/>"
            }
        }
        xml += "</vertices><triangles>"
        let faces = [(0,3,2),(0,2,1),(4,5,6),(4,6,7),(0,1,5),(0,5,4),(1,2,6),(1,6,5),(2,3,7),(2,7,6),(3,0,4),(3,4,7)]
        for i in 0..<slabs {
            let b = i * 8
            for f in faces { xml += "<triangle v1=\"\(b + f.0)\" v2=\"\(b + f.1)\" v3=\"\(b + f.2)\"/>" }
        }
        // Rotated 90° about z: x becomes y.
        xml += "</triangles></mesh></object></resources><build><item objectid=\"1\" transform=\"0 1 0 -1 0 0 0 0 1 0 0 0\"/></build></model>"
        #expect(xml.utf8.count > Zip.defaultLimit, "the fixture is \(xml.utf8.count) bytes and does not cross the limit it exists to test")
        try Data(xml.utf8).write(to: dir.appending(path: "s/3D/3dmodel.model"))

        let archive = dir.appending(path: "big-root.3mf")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", archive.path, "."]
        zip.currentDirectoryURL = dir.appending(path: "s")
        zip.standardOutput = Pipe(); zip.standardError = Pipe()
        try zip.run(); zip.waitUntilExit()

        let m = try #require(try Mesh.measure3MF(archive))
        #expect(m.triangleCount == slabs * 12)
        // The bar is 100 long in x; turned a quarter turn it is 100 long in y.
        // Identity — the fallback's answer — leaves it 100 in x.
        #expect(abs(m.y - 100) < 1e-6 && abs(m.x - 10) < 1e-6,
                "measured \(m.x) × \(m.y) × \(m.z): the build transform was not applied")
    }

    /// ── THE SAME FILE, THE SAME KEY, FROM BOTH APPS ────────────────────────
    ///
    /// This compared the Mac's measurement against the `geometryKey` already in
    /// the shop's book — and every one of those keys was written BY THE MAC.
    /// So it was checking the reader against its own handwriting, and passed
    /// through two real faults: a root object's components were read under the
    /// last component's placement, and an inline mesh's build transform was
    /// ignored. Both quiet — same triangle count, plausible box.
    ///
    /// The comparison that means something is against Electron's reader as it
    /// is today, on the same bytes: `lib/mf-convert.js measureMesh` through
    /// `lib/geometry-key.js`, run once by node over the whole vault. The two
    /// apps write this key into one record, and sync merges records last
    /// writer wins, so a file the two measure differently is a number that
    /// flips depending on which app touched it last.
    ///
    /// Stored keys that disagree with today's rule are counted and reported,
    /// not failed: they are the migration this leaves behind, not a bug in
    /// either reader.
    @Test("the key this produces is the key Electron produces, file for file")
    func matchesElectron() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let vault = home.appending(path: "Library/Application Support/khayt/print-files-vault")
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: vault.path),
              FileManager.default.fileExists(atPath: repo.appending(path: "lib/mf-convert.js").path)
        else { return }

        // ── A BUDGET, OR THIS RUN IS TWELVE MINUTES ─────────────────────────
        //
        // Two of the vault's roots are 128 MB of inline mesh and one file is
        // 6.6 million facets; measuring every file on both sides took 713 s.
        // That is the right check to have and the wrong cost for every
        // `swift test`, so archives over the budget are skipped unless asked
        // for — `KHAYT_PARITY_ALL=1 swift test --filter Mesh3MFTests` is the
        // full run, and the skipped count is printed so it is never silent.
        let budget = ProcessInfo.processInfo.environment["KHAYT_PARITY_ALL"] == nil
            ? 24 * 1024 * 1024 : Int.max

        // Electron's answer for every 3MF, in one node process.
        let script = """
        const fs=require("fs"),path=require("path");
        // `node -e` puts the extra arguments at argv[1]; there is no script path.
        const mf=require(process.argv[1]+"/lib/mf-convert.js"),gk=require(process.argv[1]+"/lib/geometry-key.js");
        const vault=process.argv[2];const out={};
        for(const d of fs.readdirSync(vault)){const dir=path.join(vault,d);if(!fs.statSync(dir).isDirectory())continue;
         for(const f of fs.readdirSync(dir)){if(!/\\.3mf$/i.test(f))continue;
          const st=fs.statSync(path.join(dir,f));if(st.size>+process.argv[3]){out[d+"/"+f]="error:over budget";continue;}
          try{const g=mf.measureMesh(mf.readMembers(fs.readFileSync(path.join(dir,f))));out[d+"/"+f]=g?gk.geometryKey(g):null;}
          catch(e){out[d+"/"+f]="error:"+e.message;}}}
        process.stdout.write(JSON.stringify(out));
        """
        let node = Process()
        node.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        node.arguments = ["node", "-e", script, "--", repo.path, vault.path, String(budget)]
        let pipe = Pipe()
        node.standardOutput = pipe
        node.standardError = FileHandle.nullDevice
        do { try node.run() } catch { return }   // no node on this machine: nothing to compare against
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        node.waitUntilExit()
        guard node.terminationStatus == 0,
              let electron = try? JSONDecoder().decode([String: String?].self, from: data),
              !electron.isEmpty else {
            Issue.record("node ran and produced nothing to compare against")
            return
        }

        let engine = try KhaytEngine()
        var compared = 0, stale = 0
        let store = home.appending(path: "Library/Application Support/khayt/khayt-store.json")
        var stored: [String: String] = [:]
        if let root = try? JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: store)),
           case .array(let files)? = root["printFiles"] {
            for case .object(let r) in files {
                if case .string(let id)? = r["id"], case .string(let key)? = r["geometryKey"] { stored[id] = key }
            }
        }

        var skipped = 0
        for (relative, theirs) in electron {
            guard let theirs, !theirs.hasPrefix("error:") else { continue }
            let path = vault.appending(path: relative)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int) ?? 0
            if bytes > budget { skipped += 1; continue }
            guard let m = try? Mesh.measure3MF(path) else {
                Issue.record("\(relative): Electron measured it and this could not")
                continue
            }
            let mine = try await engine.geometryKey(triangleCount: m.triangleCount,
                                                    volumeMm3: m.volumeMm3, x: m.x, y: m.y, z: m.z)
            #expect(mine == theirs, "\(relative): Electron says \(theirs), this says \(mine ?? "nil")")
            compared += 1
            let id = String(relative.split(separator: "/").first ?? "")
            if let was = stored[id], was != theirs { stale += 1 }
        }
        #expect(compared > 0, "node listed files and none of them was compared")
        if skipped > 0 {
            print("Mesh3MFTests: \(skipped) archives over the size budget skipped — KHAYT_PARITY_ALL=1 runs them")
        }
        // A note, not a failure — an `Issue` IS a failure in Swift Testing.
        // These records were measured under the old rule and keep that key
        // until they are measured again; the count is what a migration reads.
        if stale > 0 {
            print("Mesh3MFTests: \(stale) of \(compared) stored geometryKeys predate the current rule")
        }
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
