import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Converting a 3MF without Electron.
///
/// The decisions are `lib/mf-convert.js` and are tested where they live. What
/// is tested here is the two ends this app supplies — that it reads a container,
/// hands the rule only what a rule needs, and writes back a file whose geometry
/// is the geometry it was given.
@MainActor
struct ConverterTests {

    static let model = "<?xml version=\"1.0\"?><model unit=\"millimeter\">"
        + "<resources><object id=\"1\"/></resources></model>"

    static func temp() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-conv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A 3MF with a Prusa config, which is what a retarget rewrites.
    static func threeMF(at url: URL, meshPadding: Int = 0) throws {
        let settings = """
            {"printer_model":"Original Prusa MK4","printer_settings_id":"MK4",\
            "filament_colour":["#FF0000","#00FF00"]}
            """
        // Padding makes the mesh big enough to be passed by name rather than by
        // content, which is the path a real model takes.
        let mesh = model + String(repeating: " ", count: meshPadding)
        try ZipWrite.archive([
            .init("[Content_Types].xml", Data("<Types/>".utf8)),
            .init("_rels/.rels", Data("<Relationships/>".utf8)),
            .init("3D/3dmodel.model", Data(mesh.utf8)),
            .init("Metadata/project_settings.config", Data(settings.utf8)),
        ]).write(to: url)
    }

    static func engine() throws -> KhaytEngine { try KhaytEngine() }

    @Test("a 3MF converts, and comes back a readable 3MF")
    func roundTrip() async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "in.3mf")
        let out = dir.appending(path: "out.3mf")
        try Self.threeMF(at: source)

        let result = try await Converter.convert(
            source, into: out,
            options: ["targetId": .string("snapmaker-u1")], engine: try Self.engine())
        #expect(FileManager.default.fileExists(atPath: result.url.path))

        let entries = try Zip.entries(of: out)
        #expect(entries.contains { $0.name == "3D/3dmodel.model" })
        #expect(entries.contains { $0.name == "[Content_Types].xml" })
    }

    /// THE GUARANTEE. A conversion rewrites metadata and nothing else; the mesh
    /// that comes out is the mesh that went in, to the byte. A converted file
    /// that prints something other than the model chosen is the one failure
    /// this whole design is arranged around.
    @Test("the geometry is byte-identical, and never crosses into the engine")
    func geometryUntouched() async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "in.3mf")
        let out = dir.appending(path: "out.3mf")
        // Bigger than the inline limit, so it is passed by name — the path a
        // real mesh takes, and the one where a mistake would lose it.
        try Self.threeMF(at: source, meshPadding: Converter.inlineLimit + 1024)

        _ = try await Converter.convert(source, into: out,
                                        options: ["targetId": .string("snapmaker-u1")],
                                        engine: try Self.engine())

        let before = try Zip.entries(of: source).first { $0.name == "3D/3dmodel.model" }
        let after = try Zip.entries(of: out).first { $0.name == "3D/3dmodel.model" }
        let a = try Zip.data(of: try #require(before), in: source, limit: .max)
        let b = try Zip.data(of: try #require(after), in: out, limit: .max)
        #expect(a == b, "the mesh changed: \(a.count) bytes in, \(b.count) out")
    }

    /// The config IS rewritten, or nothing was converted and the test above
    /// would pass on a file that was merely copied.
    @Test("the config is rewritten for the target")
    func configRewritten() async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "in.3mf")
        let out = dir.appending(path: "out.3mf")
        try Self.threeMF(at: source)

        _ = try await Converter.convert(source, into: out,
                                        options: ["targetId": .string("snapmaker-u1")],
                                        engine: try Self.engine())
        let entry = try #require(try Zip.entries(of: out)
            .first { $0.name == "Metadata/project_settings.config" })
        let text = String(decoding: try Zip.data(of: entry, in: out), as: UTF8.self)
        #expect(!text.contains("Original Prusa MK4"), "the source printer survived the retarget")
    }

    /// Said plainly rather than half-done. Full Spectrum and band-swap rewrite
    /// the paint codec inside the mesh, which means the mesh would have to
    /// cross into the engine — the one thing this design exists to avoid.
    @Test("a colour plan that needs the mesh is refused before anything is read")
    func refusesPaintPlans() async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "in.3mf")
        try Self.threeMF(at: source)

        for option in ["fullSpectrum", "bandSwap"] {
            await #expect(throws: Converter.Failure.needsTheMesh) {
                _ = try await Converter.convert(
                    source, into: dir.appending(path: "out.3mf"),
                    options: ["targetId": .string("snapmaker-u1"), option: .bool(true)],
                    engine: try Self.engine())
            }
        }
    }

    @Test("something that is not a 3MF is refused, not written")
    func refusesRubbish() async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "notes.3mf")
        let out = dir.appending(path: "out.3mf")
        try Data("this is not a container".utf8).write(to: source)

        await #expect(throws: Converter.Failure.self) {
            _ = try await Converter.convert(source, into: out,
                                            options: ["targetId": .string("snapmaker-u1")],
                                            engine: try Self.engine())
        }
        #expect(!FileManager.default.fileExists(atPath: out.path), "it wrote a file anyway")
    }
}
