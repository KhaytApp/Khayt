import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A part file of many components is inflated once, not once per component.
///
/// A slicer files every object of an assembly in one `3D/Objects/*.model`, and
/// the build plan names that file once per component: a 20-part assembly was
/// inflated and walked twenty times to measure it, and twenty more for the
/// overhang pass. The shared read must hand over the very same doubles, in
/// the very same order — a measurement that moved would write a different
/// geometryKey for a file the shop already has.
@MainActor
struct Mesh3MFSharedPartTests {

    /// `count` boxes as objects 1…count in one part, with an object the plan
    /// never names between them, a malformed triangle, and a root that uses
    /// object 1 twice (an instance) across two plates.
    static func assembly(in dir: URL, count: Int, boxesPerObject: Int = 1) throws -> URL {
        func object(_ id: Int, offset: Double) -> String {
            var x = "<object id=\"\(id)\" type=\"model\"><mesh><vertices>"
            for b in 0..<boxesPerObject {
                let o = offset + Double(b) * 1.37
                for p in [(o, 0.0, 0.0), (o + 1.1, 0.0, 0.0), (o + 1.1, 1.3, 0.0), (o, 1.3, 0.0),
                          (o, 0.0, 0.7), (o + 1.1, 0.0, 0.7), (o + 1.1, 1.3, 0.9), (o, 1.3, 0.7)] {
                    x += "\n<vertex x=\"\(p.0)\" y=\"\(p.1)\" z=\"\(p.2)\"/>"
                }
            }
            x += "</vertices><triangles>"
            let f = [(0,3,2),(0,2,1),(4,5,6),(4,6,7),(0,1,5),(0,5,4),
                     (1,2,6),(1,6,5),(2,3,7),(2,7,6),(3,0,4),(3,4,7)]
            for b in 0..<boxesPerObject {
                for t in f {
                    x += "\n<triangle v1=\"\(b * 8 + t.0)\" v2=\"\(b * 8 + t.1)\" v3=\"\(b * 8 + t.2)\"/>"
                }
            }
            // One index past the table: dropped by both readers, the same way.
            x += "<triangle v1=\"0\" v2=\"1\" v3=\"\(boxesPerObject * 8)\"/>"
            return x + "</triangles></mesh></object>"
        }
        var resources = ""
        for id in 1...count {
            resources += object(id, offset: Double(id) * 3.3)
            if id == 2 { resources += object(999, offset: 500) }   // never named
        }
        let part = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <resources>\(resources)</resources><build/>
        </model>
        """
        var components = ""
        for id in 1...count {
            let z = Double(id % 4) * 2.25
            components += "<component p:path=\"/3D/Objects/part.model\" objectid=\"\(id)\" "
                + "transform=\"0.8660254 0.5 0 -0.5 0.8660254 0 0 0 1 1.5 -2.75 \(z)\"/>"
        }
        let root = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06">
         <resources>
          <object id="100" type="model"><components>\(components)</components></object>
          <object id="101" type="model"><components>
           <component p:path="/3D/Objects/part.model" objectid="1"/>
          </components></object>
         </resources>
         <build>
          <item objectid="100" transform="1 0 0 0 1 0 0 0 1 100.123 80.5 0"/>
          <item objectid="101"/>
         </build>
        </model>
        """
        let config = """
        <?xml version="1.0" encoding="UTF-8"?>
        <config><plate><metadata key="object_id" value="100"/></plate>
        <plate><metadata key="object_id" value="101"/></plate></config>
        """
        let staging = dir.appending(path: "staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging.appending(path: "3D/Objects"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging.appending(path: "Metadata"),
                                                withIntermediateDirectories: true)
        try Data(root.utf8).write(to: staging.appending(path: "3D/3dmodel.model"))
        try Data(part.utf8).write(to: staging.appending(path: "3D/Objects/part.model"))
        try Data(config.utf8).write(to: staging.appending(path: "Metadata/model_settings.config"))
        let archive = dir.appending(path: "assembly-\(count).3mf")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", archive.path, "."]
        zip.currentDirectoryURL = staging
        zip.standardOutput = Pipe(); zip.standardError = Pipe()
        try zip.run(); zip.waitUntilExit()
        return archive
    }

    /// Every triangle as its plate and nine doubles' bit patterns, in order.
    static func stream(_ url: URL, sharing: Bool,
                       reads: inout [String]) throws -> [UInt64] {
        var out: [UInt64] = []
        var seen: [String] = []
        try Mesh.each3MFTriangle(url, sharingParts: sharing, inflated: { seen.append($0) }) {
            plate, ax, ay, az, bx, by, bz, cx, cy, cz in
            out.append(UInt64(plate))
            for v in [ax, ay, az, bx, by, bz, cx, cy, cz] { out.append(v.bitPattern) }
        }
        reads = seen
        return out
    }

    @Test("a part of twenty components is inflated once, and hands over the same doubles")
    func oneReadSameTriangles() throws {
        let dir = try Mesh3MFTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.assembly(in: dir, count: 20)

        var sharedReads: [String] = [], oldReads: [String] = []
        let shared = try Self.stream(url, sharing: true, reads: &sharedReads)
        let old = try Self.stream(url, sharing: false, reads: &oldReads)
        #expect(oldReads.count == 21, "one inflate per component, as before")
        #expect(sharedReads.count == 1, "\(sharedReads.count) inflates of one part")
        // 21 components × 12 triangles; the malformed one dropped by both.
        #expect(shared.count == 21 * 12 * 10)
        #expect(shared == old, "the shared read must be the per-component read, bit for bit")
    }

    @Test("the measurement and the overhang report are unchanged by the shared read")
    func measurementUnchanged() throws {
        let dir = try Mesh3MFTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.assembly(in: dir, count: 7)

        var shared = Mesh.Measurement(), old = Mesh.Measurement()
        try Mesh.each3MFTriangle(url) { _, ax, ay, az, bx, by, bz, cx, cy, cz in
            shared.add(ax, ay, az, bx, by, bz, cx, cy, cz)
        }
        try Mesh.each3MFTriangle(url, sharingParts: false) { _, ax, ay, az, bx, by, bz, cx, cy, cz in
            old.add(ax, ay, az, bx, by, bz, cx, cy, cz)
        }
        let a = try #require(shared.finished()), b = try #require(old.finished())
        #expect(a.volumeMm3.bitPattern == b.volumeMm3.bitPattern)
        #expect(a.triangleCount == b.triangleCount)
        #expect([a.minX, a.maxX, a.minY, a.maxY, a.minZ, a.maxZ].map(\.bitPattern)
                == [b.minX, b.maxX, b.minY, b.maxY, b.minZ, b.maxZ].map(\.bitPattern))
        // Two plates, read from the plan: the box is the larger plate's.
        let measured = try #require(try Mesh.measure3MF(url))
        #expect(measured.plates == 2)
        #expect(try Mesh.overhangs(of: url) != nil)
    }

    @Test("timing: a heavy 20-component part, shared against per-component (reported, not asserted)")
    func timing() throws {
        let dir = try Mesh3MFTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.assembly(in: dir, count: 20, boxesPerObject: 400)
        let clock = ContinuousClock()
        var r: [String] = []
        let t0 = clock.now
        let a = try Self.stream(url, sharing: true, reads: &r)
        let t1 = clock.now
        let b = try Self.stream(url, sharing: false, reads: &r)
        let t2 = clock.now
        #expect(a == b)
        print("MESH-TIMING shared \(t1 - t0) per-component \(t2 - t1) triangles \(a.count / 10)")
    }
}
