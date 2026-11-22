import Foundation
import Testing
@testable import KhaytApp

/// A mesh whose numbers are not numbers, and a text mesh too big to read whole.
///
/// One NaN corner used to trap the preview: `min(inf, nan)` is inf in Swift, so
/// the measured box stayed finite, the picture went ahead, and `Int(nan)`
/// stopped the app — at every launch, for a file sitting in a linked folder.
@MainActor
struct MeshCorruptTests {

    static func cubeWithNaN() -> String {
        OBJTests.cubeOBJ(20) + "v nan 0 0\nf 1 2 9\n"
    }

    @Test("an OBJ with a NaN vertex draws its good faces and does not trap")
    func nanOBJ() throws {
        let dir = MeshPreviewTests.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "nan.obj")
        try Self.cubeWithNaN().write(to: url, atomically: true, encoding: .utf8)

        let m = try #require(try Mesh.measureOBJ(url))
        #expect(m.triangleCount == 12, "the NaN face was counted")
        #expect(m.x == 20 && m.y == 20 && m.z == 20)
        #expect(try MeshPreview.png(of: url, size: 64) != nil)
    }

    @Test("a binary STL with a NaN corner draws its good facets and does not trap")
    func nanBinarySTL() throws {
        let dir = MeshPreviewTests.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "nan.stl")
        var corners = MeshTests.boxFacets(20, 20, 20)
        corners += [(.nan, 0, 0), (1, 0, 0), (0, 1, 0)]
        corners += [(.infinity, 0, 0), (1, 0, 0), (0, 1, 0)]
        try MeshTests.binarySTL(corners).write(to: url)

        let m = try #require(try Mesh.measureSTL(url))
        #expect(m.triangleCount == 12)
        #expect(m.x == 20)
        #expect(try MeshPreview.png(of: url, size: 64) != nil)
        // The overhang pass reads the same triangles and must not choke either.
        #expect(try Mesh.overhangs(of: url) != nil)
    }

    @Test("a text STL with a NaN vertex is read around it")
    func nanAsciiSTL() throws {
        let dir = MeshPreviewTests.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "nan-ascii.stl")
        let text = AsciiPreviewTests.asciiCube(20).replacingOccurrences(
            of: "endsolid cube",
            with: "facet normal 0 0 0\nouter loop\nvertex nan 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid cube")
        try text.write(to: url, atomically: true, encoding: .utf8)

        let m = try #require(try Mesh.measureSTL(url))
        #expect(m.triangleCount == 12)
        #expect(try MeshPreview.png(of: url, size: 64) != nil)
    }

    /// The streamed reader meets a line split across two of its megabyte
    /// reads, and CR-LF, and still reads exactly what the in-memory one does.
    @Test("a text mesh is streamed a line at a time and reads the same")
    func streamedMatchesWhole() throws {
        let dir = MeshPreviewTests.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Comment padding pushes the faces past the first megabyte, so lines
        // straddle a read boundary somewhere in them.
        let padding = String(repeating: "# padding line for the chunk boundary\r\n", count: 30_000)
        var text = padding
        for i in 0..<2_000 {
            let o = Double(i) * 30
            text += "v \(o) 0 0\r\nv \(o + 1) 0 0\r\nv \(o) 1 2\r\nf -3 -2 -1\r\n"
        }
        let url = dir.appending(path: "big.obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        #expect(text.utf8.count > 1 << 20)

        var whole = Mesh.Measurement(), streamed = Mesh.Measurement()
        Mesh.eachOBJTriangle(text) { whole.add($0, $1, $2, $3, $4, $5, $6, $7, $8) }
        #expect(Mesh.eachOBJTriangle(url) { streamed.add($0, $1, $2, $3, $4, $5, $6, $7, $8) })
        #expect(whole.triangleCount == 2_000)
        #expect(streamed == whole)
    }

    /// `String(contentsOf:)` dropped a UTF-8 byte-order mark; the streamed
    /// reader must too, or an OBJ starting with a vertex loses it and every
    /// face after it points one corner off.
    @Test("a byte-order mark changes nothing")
    func byteOrderMark() throws {
        let dir = MeshPreviewTests.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bom = Data([0xEF, 0xBB, 0xBF])
        let obj = OBJTests.cubeOBJ(20).replacingOccurrences(of: "# a cube\n", with: "")
        let plainOBJ = dir.appending(path: "plain.obj"), bomOBJ = dir.appending(path: "bom.obj")
        try Data(obj.utf8).write(to: plainOBJ)
        try (bom + Data(obj.utf8)).write(to: bomOBJ)
        let a = try #require(try Mesh.measureOBJ(plainOBJ)), b = try #require(try Mesh.measureOBJ(bomOBJ))
        #expect(a.triangleCount == 12 && b == a)

        let stl = AsciiPreviewTests.asciiCube(20)
        let plainSTL = dir.appending(path: "plain.stl"), bomSTL = dir.appending(path: "bom.stl")
        try Data(stl.utf8).write(to: plainSTL)
        try (bom + Data(stl.utf8)).write(to: bomSTL)
        let c = try #require(try Mesh.measureSTL(plainSTL)), d = try #require(try Mesh.measureSTL(bomSTL))
        #expect(c.triangleCount == 12 && d == c)
    }

    /// A binary file named .obj has no line ends to stop at; the reader gives
    /// up rather than gathering the whole file into one "line".
    @Test("a file with no line ends is not read as a text mesh")
    func noLineEnds() throws {
        let dir = MeshPreviewTests.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "blob.obj")
        try Data(repeating: UInt8(ascii: "a"), count: 3 << 20).write(to: url)
        #expect(throws: Mesh.Failure.self) { try Mesh.measureOBJ(url) }

        let latin = dir.appending(path: "latin.obj")
        try Data([0x76, 0x20, 0xFF, 0xFE, 0x0A]).write(to: latin)
        #expect(throws: Mesh.Failure.self) { try Mesh.measureOBJ(latin) }
    }
}
