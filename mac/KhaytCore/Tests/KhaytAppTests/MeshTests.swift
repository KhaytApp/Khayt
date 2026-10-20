import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Measuring a mesh.
///
/// Every case here has an answer known from arithmetic rather than from running
/// the code — a cube of side 10 is 1000 mm³ whatever any program says — and the
/// last one checks that against a real slicer, which computes the same thing by
/// the same method and is therefore a genuine second opinion.
@MainActor
struct MeshTests {

    static func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-mesh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A box, as 12 triangles wound outwards.
    static func boxFacets(_ w: Double, _ d: Double, _ h: Double,
                          originX: Double = 0, originY: Double = 0, originZ: Double = 0)
        -> [(Double, Double, Double)] {
        let v: [(Double, Double, Double)] = [
            (originX, originY, originZ), (originX + w, originY, originZ),
            (originX + w, originY + d, originZ), (originX, originY + d, originZ),
            (originX, originY, originZ + h), (originX + w, originY, originZ + h),
            (originX + w, originY + d, originZ + h), (originX, originY + d, originZ + h),
        ]
        let faces = [(0,3,2),(0,2,1),(4,5,6),(4,6,7),(0,1,5),(0,5,4),
                     (1,2,6),(1,6,5),(2,3,7),(2,7,6),(3,0,4),(3,4,7)]
        return faces.flatMap { [v[$0.0], v[$0.1], v[$0.2]] }
    }

    static func binarySTL(_ corners: [(Double, Double, Double)], header: String = "") -> Data {
        var out = Data(count: 80)
        if !header.isEmpty {
            let bytes = Array(header.utf8.prefix(80))
            out.replaceSubrange(0..<bytes.count, with: bytes)
        }
        let count = UInt32(corners.count / 3)
        withUnsafeBytes(of: count.littleEndian) { out.append(contentsOf: $0) }
        for i in stride(from: 0, to: corners.count, by: 3) {
            for _ in 0..<3 { withUnsafeBytes(of: Float(0).bitPattern.littleEndian) { out.append(contentsOf: $0) } }
            for c in [corners[i], corners[i + 1], corners[i + 2]] {
                for value in [c.0, c.1, c.2] {
                    withUnsafeBytes(of: Float(value).bitPattern.littleEndian) { out.append(contentsOf: $0) }
                }
            }
            out.append(contentsOf: [0, 0])
        }
        return out
    }

    static func asciiSTL(_ corners: [(Double, Double, Double)]) -> String {
        var out = ["solid thing"]
        for i in stride(from: 0, to: corners.count, by: 3) {
            out.append("  facet normal 0 0 0")
            out.append("    outer loop")
            for c in [corners[i], corners[i + 1], corners[i + 2]] {
                out.append("      vertex \(c.0) \(c.1) \(c.2)")
            }
            out.append("    endloop")
            out.append("  endfacet")
        }
        out.append("endsolid thing")
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - The arithmetic

    @Test("a 10 mm cube is twelve triangles, a thousand cubic millimetres, and 10 by 10 by 10")
    func binaryCube() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "cube.stl")
        try Self.binarySTL(Self.boxFacets(10, 10, 10)).write(to: url)

        let m = try #require(try Mesh.measureSTL(url))
        #expect(m.triangleCount == 12)
        #expect(abs(m.volumeMm3 - 1000) < 0.01)
        #expect(abs(m.x - 10) < 0.001 && abs(m.y - 10) < 0.001 && abs(m.z - 10) < 0.001)
    }

    @Test("the text form measures the same as the binary one")
    func asciiMatchesBinary() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let facets = Self.boxFacets(30, 20, 5)
        let bin = dir.appending(path: "b.stl")
        let txt = dir.appending(path: "a.stl")
        try Self.binarySTL(facets).write(to: bin)
        try Data(Self.asciiSTL(facets).utf8).write(to: txt)

        let a = try #require(try Mesh.measureSTL(bin))
        let b = try #require(try Mesh.measureSTL(txt))
        #expect(a.triangleCount == b.triangleCount)
        #expect(abs(a.volumeMm3 - b.volumeMm3) < 0.01)
        #expect(abs(a.volumeMm3 - 3000) < 0.01, "30 × 20 × 5 is 3000 mm³")
    }

    /// THE TRAP.
    ///
    /// An ASCII STL starts with "solid", and so do plenty of binary ones,
    /// because the exporter wrote a name into the 80-byte header. A reader that
    /// sniffs for the word reads a binary file as text, finds no `vertex` lines
    /// and reports a model with no triangles at all — silently, since an empty
    /// mesh is a plausible answer.
    ///
    /// The length is the honest test: a binary STL is exactly 84 + 50n bytes.
    @Test("a binary STL whose header says 'solid' is still read as binary")
    func binaryHeaderSayingSolid() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "tricky.stl")
        try Self.binarySTL(Self.boxFacets(10, 10, 10), header: "solid exported by something")
            .write(to: url)

        let m = try #require(try Mesh.measureSTL(url))
        #expect(m.triangleCount == 12, "read as text, this would be zero")
        #expect(abs(m.volumeMm3 - 1000) < 0.01)
    }

    /// Materialise Magics writes "COLOR=… MATERIAL=…" into the header and
    /// then MORE bytes than its count says: two models on a shop's Drive
    /// (Oct 2026), 2,450 and 62,800 bytes over, both "not a mesh" here and so
    /// never priced. The facets the header counts are read; the tail is not.
    @Test("a binary STL with bytes after its facets is read for the facets it counts")
    func binaryWithATail() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "magics.stl")
        var data = Self.binarySTL(Self.boxFacets(10, 10, 10), header: "COLOR=\u{7f}\u{7f}\u{7f} MATERIAL=\u{7f}\u{7f}\u{7f}")
        data.append(Data((0..<2450).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 200) }))
        try data.write(to: url)

        let m = try #require(try Mesh.measureSTL(url))
        #expect(m.triangleCount == 12)
        #expect(abs(m.volumeMm3 - 1000) < 0.01)
        var drawn = 0
        #expect(try Mesh.eachSTLTriangle(url) { _, _, _, _, _, _, _, _, _ in drawn += 1 })
        #expect(drawn == 12, "the preview reads the same facets")

        // SHORTER than its count is not binary: facets would be missing.
        let short = dir.appending(path: "short.stl")
        try Self.binarySTL(Self.boxFacets(10, 10, 10)).dropLast(50).write(to: short)
        #expect(try !Mesh.eachSTLTriangle(short) { _, _, _, _, _, _, _, _, _ in })
    }

    /// The origin is not inside this box, and the answer is the same.
    /// That is what the SIGNED sum buys: the outside faces cancel.
    @Test("a mesh far from the origin measures the same as one around it")
    func offsetFromOrigin() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let near = dir.appending(path: "n.stl")
        let far = dir.appending(path: "f.stl")
        try Self.binarySTL(Self.boxFacets(10, 10, 10)).write(to: near)
        try Self.binarySTL(Self.boxFacets(10, 10, 10, originX: 500, originY: -300, originZ: 40))
            .write(to: far)

        let a = try #require(try Mesh.measureSTL(near))
        let b = try #require(try Mesh.measureSTL(far))
        #expect(abs(a.volumeMm3 - b.volumeMm3) < 0.01)
        #expect(abs(b.x - 10) < 0.001 && abs(b.y - 10) < 0.001 && abs(b.z - 10) < 0.001)
    }

    /// A mesh wound inside out has the right magnitude and the wrong sign, and
    /// a negative volume in a library record is worse than an inverted mesh
    /// nobody noticed.
    @Test("an inside-out mesh still measures positive")
    func invertedWinding() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "inv.stl")
        // Every triangle reversed.
        var flipped: [(Double, Double, Double)] = []
        let facets = Self.boxFacets(10, 10, 10)
        for i in stride(from: 0, to: facets.count, by: 3) {
            flipped.append(contentsOf: [facets[i + 2], facets[i + 1], facets[i]])
        }
        try Self.binarySTL(flipped).write(to: url)

        let m = try #require(try Mesh.measureSTL(url))
        #expect(m.volumeMm3 > 0)
        #expect(abs(m.volumeMm3 - 1000) < 0.01)
    }

    @Test("nothing measurable is nil rather than a model of size zero")
    func nothingThere() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appending(path: "empty.stl")
        try Self.binarySTL([]).write(to: empty)
        #expect(try Mesh.measureSTL(empty) == nil)

        let junk = dir.appending(path: "junk.stl")
        try Data(repeating: 0x7F, count: 500).write(to: junk)
        // Not 84 + 50n and not text: refused, not reported as an empty model.
        #expect(throws: (any Error).self) { _ = try Mesh.measureSTL(junk) }
    }

    /// Many triangles, read in chunks. The chunking is where a facet gets split
    /// across two reads and the mesh quietly loses one.
    @Test("a mesh larger than one read still counts every triangle")
    func chunking() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 25,000 boxes = 300,000 triangles, well past the 20,000-facet chunk.
        var facets: [(Double, Double, Double)] = []
        for i in 0..<25_000 {
            facets.append(contentsOf: Self.boxFacets(1, 1, 1, originX: Double(i) * 2))
        }
        let url = dir.appending(path: "many.stl")
        try Self.binarySTL(facets).write(to: url)

        let m = try #require(try Mesh.measureSTL(url))
        #expect(m.triangleCount == 300_000)
        #expect(abs(m.volumeMm3 - 25_000) < 1, "25,000 unit cubes")
        // The last box starts at x = 49,998 and is 1 wide.
        #expect(abs(m.x - 49_999) < 0.01)
    }

    // MARK: - Against a slicer

    /// The second opinion.
    ///
    /// PrusaSlicer computes the same three numbers by the same method, so it is
    /// a real check rather than a restatement — and it is the check that would
    /// catch a sign convention, a byte order or an off-by-one in the facet
    /// stride. Skipped where no slicer is installed.
    @Test("a slicer measures the same mesh the same way")
    func agreesWithASlicer() throws {
        let candidates = [
            "/Applications/PrusaSlicer.app/Contents/MacOS/PrusaSlicer",
            "/Applications/OrcaSlicer.app/Contents/MacOS/OrcaSlicer",
        ].filter { FileManager.default.isExecutableFile(atPath: $0) }
        guard let path = candidates.first else { return }
        let slicer = KhaytEngine.Slicer(id: "t", name: "test", path: path)
        guard ModelInfo.canMeasure(slicer) else { return }

        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Deliberately not a cube: an odd box off the origin, so a wrong sign or
        // a swapped axis shows up.
        let facets = Self.boxFacets(37.5, 12.25, 8, originX: -20, originY: 5, originZ: -3)
        let url = dir.appending(path: "odd.stl")
        try Self.binarySTL(facets).write(to: url)

        let mine = try #require(try Mesh.measureSTL(url))
        let theirs = try ModelInfo.measure(url, with: slicer, allowed: true, timeout: 60)

        #expect(mine.triangleCount == theirs.triangleCount)
        // Within a thousandth of a percent: the slicer accumulates in Float.
        #expect(abs(mine.volumeMm3 - theirs.volumeMm3) / theirs.volumeMm3 < 0.00001)
        #expect(abs(mine.x - theirs.x) < 0.001)
        #expect(abs(mine.y - theirs.y) < 0.001)
        #expect(abs(mine.z - theirs.z) < 0.001)
        // And the arithmetic both of them should agree with.
        #expect(abs(mine.volumeMm3 - 37.5 * 12.25 * 8) < 0.01)
    }
}
