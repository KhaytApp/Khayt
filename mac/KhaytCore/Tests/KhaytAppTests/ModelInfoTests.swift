import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Reading a slicer's `--info` output.
///
/// The parsing is tested and the launching is not, because the parsing is where
/// everything that can be wrong is wrong, and because a test that spawns
/// PrusaSlicer passes only on a machine that has it. The one test that does
/// reach for a real slicer says so and skips when there is none.
@MainActor
struct ModelInfoTests {

    /// PrusaSlicer's own words, on a 10 mm cube. Captured, not invented.
    static let cube = """
    [cube-ascii.stl]
    size_x = 10.000000
    size_y = 10.000000
    size_z = 10.000000
    min_x = 0.000000
    min_y = 0.000000
    min_z = 0.000000
    max_x = 10.000000
    max_y = 10.000000
    max_z = 10.000000
    number_of_facets = 12
    manifold = yes
    number_of_parts =  1
    volume = 1000.000061
    """

    @Test("a single object: the numbers come back as they were printed")
    func oneObject() throws {
        let g = try #require(ModelInfo.parse(Self.cube))
        #expect(g.triangleCount == 12)
        #expect(abs(g.volumeMm3 - 1000.000061) < 0.0001)
        #expect(abs(g.x - 10) < 0.0001)
        #expect(abs(g.y - 10) < 0.0001)
        #expect(abs(g.z - 10) < 0.0001)
        #expect(g.objects == 1)
    }

    /// THE ONE THAT MATTERS.
    ///
    /// A 3MF holding twenty parts prints twenty blocks, and a reader that takes
    /// the first — or the last — reports one part's geometry for the whole
    /// model. This shop's Hulk helmet is exactly that file: twenty objects, and
    /// the first block says 104,060 facets against a true total of 4,295,525.
    ///
    /// The total is what Khayt computed for the same file, to the triangle.
    @Test("twenty objects are summed, not sampled")
    func manyObjects() throws {
        // Three blocks with round numbers, standing for the twenty.
        let output = """
        [model.3mf]
        min_x = -10
        max_x = 10
        min_y = 0
        max_y = 5
        min_z = 0
        max_z = 2
        number_of_facets = 100
        volume = 1000
        [model.3mf]
        min_x = 20
        max_x = 30
        min_y = -5
        max_y = 0
        min_z = 0
        max_z = 8
        number_of_facets = 250
        volume = 2500.5
        [model.3mf]
        min_x = 0
        max_x = 1
        min_y = 1
        max_y = 2
        min_z = -3
        max_z = 0
        number_of_facets = 4
        volume = 0.5
        """
        let g = try #require(ModelInfo.parse(output))
        #expect(g.objects == 3)
        #expect(g.triangleCount == 354, "facets must be summed")
        #expect(abs(g.volumeMm3 - 3501.0) < 0.0001, "volume must be summed")
        // The box is over all of them together: -10…30, -5…5, -3…8.
        #expect(abs(g.x - 40) < 0.0001)
        #expect(abs(g.y - 10) < 0.0001)
        #expect(abs(g.z - 11) < 0.0001)
    }

    /// Decimals are C-locale whatever the Mac is set to.
    ///
    /// `Double("117687.71")` is locale-independent; a reader using a
    /// `NumberFormatter` on the Mac's own locale would read that as 11,768,771
    /// in a country that groups with a full stop, and silently report a model a
    /// hundred times its size.
    @Test("a decimal point is a decimal point, whatever the Mac's locale says")
    func cLocale() throws {
        let g = try #require(ModelInfo.parse("""
        [x.3mf]
        min_x = 0
        max_x = 1141.57
        min_y = 0
        max_y = 757.09
        min_z = 0
        max_z = 207.37
        number_of_facets = 4295525
        volume = 3487958.9
        """))
        #expect(g.triangleCount == 4_295_525)
        #expect(abs(g.volumeMm3 - 3_487_958.9) < 0.01)
        #expect(abs(g.x - 1141.57) < 0.01)
    }

    @Test("output with nothing measurable in it is nothing, not a zero-sized model")
    func nothingUseful() {
        #expect(ModelInfo.parse("") == nil)
        #expect(ModelInfo.parse("Loading of a model file failed.") == nil)
        // Facets but no volume, and volume but no facets: a key built from
        // either would be an identity two unrelated models could share, and
        // `geometryKey` refuses both — so this refuses them first.
        #expect(ModelInfo.parse("[a]\nnumber_of_facets = 12\nvolume = 0") == nil)
        #expect(ModelInfo.parse("[a]\nnumber_of_facets = 0\nvolume = 100") == nil)
        // A slicer's own chatter, with numbers in it.
        #expect(ModelInfo.parse("[a]\nmanifold = no\nnumber_of_parts =  3") == nil)
    }

    @Test("a model with no bounds reported is still measured, with a flat box")
    func noBounds() throws {
        let g = try #require(ModelInfo.parse("[a]\nnumber_of_facets = 8\nvolume = 5"))
        #expect(g.triangleCount == 8)
        // Zero, not infinity: an infinite span would print as "inf" in the key.
        #expect(g.x == 0 && g.y == 0 && g.z == 0)
    }

    // MARK: - Against a real slicer

    /// Runs only where a slicer that advertises `--info` is installed.
    ///
    /// It is the one thing the captured fixtures above cannot check: that the
    /// flag still exists and still prints what it printed. A slicer updates
    /// itself without asking.
    @Test("a real slicer measures a real cube")
    func realSlicer() throws {
        let candidates = [
            "/Applications/PrusaSlicer.app/Contents/MacOS/PrusaSlicer",
            "/Applications/OrcaSlicer.app/Contents/MacOS/OrcaSlicer",
        ].filter { FileManager.default.isExecutableFile(atPath: $0) }
        guard let path = candidates.first else { return }
        let slicer = KhaytEngine.Slicer(id: "t", name: "test", path: path)
        guard ModelInfo.canMeasure(slicer) else { return }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-info-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A 10 mm cube, written here so the expected answer is arithmetic.
        let stl = dir.appending(path: "cube.stl")
        try Data(Self.asciiCube.utf8).write(to: stl)

        let g = try ModelInfo.measure(stl, with: slicer, allowed: true, timeout: 60)
        #expect(g.triangleCount == 12)
        #expect(abs(g.volumeMm3 - 1000) < 1, "a 10 mm cube is 1000 mm³")
        #expect(abs(g.x - 10) < 0.01 && abs(g.y - 10) < 0.01 && abs(g.z - 10) < 0.01)
    }

    /// The allowlist is asked before anything is launched, and a refusal is a
    /// refusal rather than a silent nil.
    @Test("a program the allowlist refused is never run")
    func refusedIsNotRun() {
        let slicer = KhaytEngine.Slicer(id: "x", name: "awk", path: "/usr/bin/awk")
        #expect(throws: ModelInfo.Failure.notAllowed("awk")) {
            _ = try ModelInfo.measure(URL(fileURLWithPath: "/tmp/nothing.stl"),
                                      with: slicer, allowed: false)
        }
    }

    static let asciiCube: String = {
        let v = [(0.0,0.0,0.0),(10.0,0.0,0.0),(10.0,10.0,0.0),(0.0,10.0,0.0),
                 (0.0,0.0,10.0),(10.0,0.0,10.0),(10.0,10.0,10.0),(0.0,10.0,10.0)]
        let faces = [(0,3,2),(0,2,1),(4,5,6),(4,6,7),(0,1,5),(0,5,4),
                     (1,2,6),(1,6,5),(2,3,7),(2,7,6),(3,0,4),(3,4,7)]
        var out = ["solid cube"]
        for (a, b, c) in faces {
            out.append("  facet normal 0 0 0")
            out.append("    outer loop")
            for i in [a, b, c] {
                out.append("      vertex \(v[i].0) \(v[i].1) \(v[i].2)")
            }
            out.append("    endloop")
            out.append("  endfacet")
        }
        out.append("endsolid cube")
        return out.joined(separator: "\n") + "\n"
    }()
}
