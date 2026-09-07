import Foundation
import AppKit
import Testing
@testable import KhaytApp

/// Drawing a model that carries no picture of its own.
@MainActor
struct MeshPreviewTests {

    static func temp() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A box, which is the shape whose picture can be checked by eye in words:
    /// it must cover a good part of the frame and nothing outside it.
    @Test("a cube comes back as a picture of a cube")
    func drawsACube() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stl = dir.appending(path: "cube.stl")
        try MeshTests.binarySTL(MeshTests.boxFacets(20, 20, 20)).write(to: stl)

        let png = try #require(try MeshPreview.png(of: stl, size: 64))
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == 64 && rep.pixelsHigh == 64)

        // Ink where the model is, none in the corners: turned to a three-quarter
        // view and scaled to 90% of the frame, a cube cannot reach them.
        var opaque = 0
        for y in 0..<64 {
            for x in 0..<64 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { opaque += 1 }
        }
        #expect(opaque > 64 * 64 / 8, "the cube covers almost nothing: \(opaque) px")
        #expect(opaque < 64 * 64, "it filled the whole frame, so it was not scaled to fit")
        #expect((rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.5, "drew into the corner")
    }

    /// Three faces of a cube are lit differently, or it reads as a flat
    /// hexagon rather than a solid. This is the whole point of shading it.
    @Test("the faces are not all the same grey")
    func shadesTheFaces() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stl = dir.appending(path: "cube.stl")
        try MeshTests.binarySTL(MeshTests.boxFacets(20, 20, 20)).write(to: stl)

        let png = try #require(try MeshPreview.png(of: stl, size: 96))
        let rep = try #require(NSBitmapImageRep(data: png))
        var tones = Set<Int>()
        for y in 0..<96 {
            for x in 0..<96 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      c.alphaComponent > 0.9 else { continue }
                tones.insert(Int(c.redComponent * 255) / 8)   // banded, to ignore edge noise
            }
        }
        #expect(tones.count >= 3, "only \(tones.count) tone(s) — the faces are unlit")
    }

    /// Nothing rather than an empty square. A caller writes what it gets, and
    /// a blank thumbnail on a model is worse than the placeholder it replaces:
    /// the placeholder says "no picture", a blank one says the model is empty.
    @Test("a file with no triangles draws nothing at all")
    func refusesTheEmpty() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appending(path: "empty.stl")
        try MeshTests.binarySTL([]).write(to: empty)
        #expect(try MeshPreview.png(of: empty) == nil)

        let notAMesh = dir.appending(path: "notes.stl")
        try Data("this is not a mesh".utf8).write(to: notAMesh)
        let drawn = (try? MeshPreview.png(of: notAMesh)) ?? nil
        #expect(drawn == nil)
    }

    /// A flat plate is the case that catches a projection scaled to the wrong
    /// box: turned three-quarters, a zero-height model still has extent, and
    /// dividing by its height would be a divide by zero.
    @Test("a flat plate still draws")
    func flatPlate() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stl = dir.appending(path: "plate.stl")
        try MeshTests.binarySTL(MeshTests.boxFacets(40, 40, 0.4)).write(to: stl)
        let png = try #require(try MeshPreview.png(of: stl, size: 64))
        #expect(png.count > 0)
    }
}

/// The text form of an STL, which a CAD package writes by default.
///
/// Sixteen of the shop's own models are one, and they were exactly the models
/// the renderer left as grey cubes when it could only read the binary form —
/// found by running the backfill over a real library and reading the skips,
/// not by thinking about it.
@MainActor
struct AsciiPreviewTests {
    static func asciiCube(_ side: Double) -> String {
        // `boxFacets` is a flat list of vertices, three to a facet.
        let vertices = MeshTests.boxFacets(side, side, side)
        var out = "solid cube\n"
        for facet in stride(from: 0, to: vertices.count - 2, by: 3) {
            out += "  facet normal 0 0 0\n    outer loop\n"
            for v in vertices[facet..<(facet + 3)] {
                out += "      vertex \(v.0) \(v.1) \(v.2)\n"
            }
            out += "    endloop\n  endfacet\n"
        }
        return out + "endsolid cube\n"
    }

    @Test("a text STL draws the same as a binary one")
    func drawsAscii() throws {
        let dir = MeshPreviewTests.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ascii = dir.appending(path: "cube-ascii.stl")
        let binary = dir.appending(path: "cube-binary.stl")
        try Self.asciiCube(20).write(to: ascii, atomically: true, encoding: .utf8)
        try MeshTests.binarySTL(MeshTests.boxFacets(20, 20, 20)).write(to: binary)

        let a = try #require(try MeshPreview.png(of: ascii, size: 64))
        let b = try #require(try MeshPreview.png(of: binary, size: 64))
        // The same cube from the same angle: the same picture, byte for byte.
        // If they ever differ, the two parsers have drifted, which is the whole
        // reason they were made one.
        #expect(a == b, "the text and binary readers drew different pictures")
    }
}

/// A text STL written on Windows.
///
/// FOUND ON REAL FILES, not imagined: fifteen of the shop's own models measured
/// as nothing and drew as nothing, and every one of them opened perfectly well
/// in an editor. Splitting on LF leaves the CR on the end of the line, and
/// `CharacterSet.whitespaces` is space and tab — so the LAST coordinate of
/// every vertex parsed as "3.0\r", `Double` returned nil, and the line was
/// dropped. Every line. CATIA and several CAD exporters write exactly this.
@MainActor
struct WindowsLineEndingTests {
    @Test("a text STL with CR-LF line endings is read, not silently skipped")
    func crlf() throws {
        let unix = AsciiPreviewTests.asciiCube(20)
        let windows = unix.replacingOccurrences(of: "\n", with: "\r\n")

        var unixCount = 0, windowsCount = 0
        Mesh.eachAsciiSTLTriangle(unix) { _, _, _, _, _, _, _, _, _ in unixCount += 1 }
        Mesh.eachAsciiSTLTriangle(windows) { _, _, _, _, _, _, _, _, _ in windowsCount += 1 }

        #expect(unixCount == 12, "a cube is twelve triangles")
        #expect(windowsCount == unixCount, "CR-LF dropped \(unixCount - windowsCount) of them")
    }

    /// And it measures to the same box, which is what the library shows and
    /// what `fits` compares against a printer's bed.
    @Test("and it measures the same either way")
    func measuresTheSame() throws {
        let dir = MeshPreviewTests.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unix = dir.appending(path: "unix.stl")
        let windows = dir.appending(path: "windows.stl")
        try AsciiPreviewTests.asciiCube(20).write(to: unix, atomically: true, encoding: .utf8)
        try AsciiPreviewTests.asciiCube(20).replacingOccurrences(of: "\n", with: "\r\n")
            .write(to: windows, atomically: true, encoding: .utf8)

        let a = try #require(try Mesh.measureAsciiSTL(unix))
        let b = try #require(try Mesh.measureAsciiSTL(windows))
        #expect(a.triangleCount == b.triangleCount)
        #expect(a.x == b.x && a.y == b.y && a.z == b.z)
        #expect(b.x == 20)
    }
}
