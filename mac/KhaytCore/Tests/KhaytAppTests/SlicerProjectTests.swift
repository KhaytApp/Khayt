import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A bare model goes to an Orca fork as a PROJECT, never with preset flags
/// (`SlicerProject`, `lib/slicer-project.js`).
///
/// Snapmaker Orca 2.4.1's command line segfaults on `--load-settings`, with or
/// without `--load-filaments` (reproduced Nov 27 2026: exit 139, no G-code, on
/// every U1 STL sent from Khayt). The same presets inside a project 3MF slice.
/// These hold the Mac to that: the writer streams the mesh exactly as the rule
/// writes it, a plain 3MF keeps every member it had, and nothing in the app
/// hands a slicer preset flags any more.
@Suite(.serialized)
struct SlicerProjectTests {

    static let machine: JSONValue = .object([
        "name": .string("Snapmaker U1 (0.4 nozzle)"), "type": .string("machine"),
        "printable_area": .array(["0x0", "270x0", "270x270", "0x270"].map(JSONValue.string)),
    ])
    static let process: JSONValue = .object(["name": .string("0.20mm"), "type": .string("process"), "layer_height": .string("0.2")])
    static let filament: JSONValue = .object(["name": .string("Generic PLA"), "type": .string("filament"),
                                              "filament_type": .array([.string("PLA")])])

    /// Triangles that exercise the rule: negative coordinates, a value that
    /// sits on a rounding half, shared corners, and one face that collapses.
    static let triangles: [[[Double]]] = [
        [[-10, -5, 2], [10, -5, 2], [0, 7.25, 2]],
        [[-10, -5, 2], [0, 7.25, 2], [0, 0, 12.00005]],
        [[1.23456, 2.5, 3], [1.23456, 2.5, 3], [4, 5, 6]],
        [[0, 0, 12.00005], [10, -5, 2], [0, 7.25, 2]],
    ]

    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A binary STL of these triangles.
    static func stl(_ tris: [[[Double]]], at url: URL) throws {
        var d = Data(count: 80)
        var n = UInt32(tris.count).littleEndian
        d.append(Data(bytes: &n, count: 4))
        for t in tris {
            d.append(Data(count: 12))
            for v in t { for c in v { var f = Float32(c).bitPattern.littleEndian; d.append(Data(bytes: &f, count: 4)) } }
            d.append(Data(count: 2))
        }
        try d.write(to: url)
    }

    @Test("the Swift writer writes the mesh exactly as the shared rule does")
    func parity() async throws {
        let engine = try KhaytEngine()
        // As an STL stores them: Float32, then read back as Double.
        let tris = Self.triangles.map { $0.map { $0.map { Double(Float32($0)) } } }
        let rule = try await engine.slicerProjectModelXml(triangles: tris, centre: [135, 135])
        let flat = tris.flatMap { $0 }
        let min = (0..<3).map { a in flat.map { $0[a] }.min()! }, max = (0..<3).map { a in flat.map { $0[a] }.max()! }
        let offset = try await engine.slicerProjectOffset(min: min, max: max, machine: Self.machine)
        let writer = SlicerProject.MeshWriter(offset: offset)
        for t in tris { writer.add(t[0][0], t[0][1], t[0][2], t[1][0], t[1][1], t[1][2], t[2][0], t[2][1], t[2][2]) }
        let mine = String(decoding: writer.xml(head: SlicerProject.modelHead, tail: SlicerProject.modelTail), as: UTF8.self)
        #expect(mine == rule)
        #expect(writer.triangleCount == 3, "the collapsed face is dropped")
        // And with nothing in it: the fixed head and tail are the rule's own.
        let empty = try await engine.slicerProjectModelXml(triangles: [], centre: [0, 0])
        let none = String(decoding: SlicerProject.MeshWriter(offset: [0, 0, 0])
            .xml(head: SlicerProject.modelHead, tail: SlicerProject.modelTail), as: UTF8.self)
        #expect(none == empty)
    }

    @Test("numbers round as JavaScript does: half up, four places, no -0")
    func numbers() {
        #expect(SlicerProject.num(1.23456) == "1.2346")
        #expect(SlicerProject.num(2.5) == "2.5")
        #expect(SlicerProject.num(10) == "10")
        #expect(SlicerProject.num(-0.00001) == "0")
    }

    @Test("an STL becomes a project: its mesh on the bed, the shop's presets inside, nothing else")
    func stlProject() async throws {
        let engine = try KhaytEngine()
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appending(path: "part.stl")
        try Self.stl(Self.triangles, at: model)
        let done = await SlicerProject.prepare(model, plan: "stl", machine: Self.machine, process: Self.process,
                                               filament: Self.filament, engine: engine, outDir: dir)
        #expect(done.problem == nil)
        #expect(done.model.lastPathComponent == "khayt-project.3mf")
        let names = try Zip.entries(of: done.model).map(\.name)
        #expect(names == ["[Content_Types].xml", "_rels/.rels", "3D/3dmodel.model", "Metadata/project_settings.config"])
        let entries = try Zip.entries(of: done.model)
        let conf = try JSONDecoder().decode(JSONValue.self, from: try Zip.data(of: entries[3], in: done.model))
        guard case .object(let c) = conf else { Issue.record("settings are not an object"); return }
        #expect(c["from"] == .string("project"))
        #expect(c["printer_settings_id"] == .string("Snapmaker U1 (0.4 nozzle)"))
        #expect(c["layer_height"] == .string("0.2"))
        // The mesh is the rule's, for the same triangles as the STL stores them.
        let tris = Self.triangles.map { $0.map { $0.map { Double(Float32($0)) } } }
        let rule = try await engine.slicerProjectModelXml(triangles: tris, centre: [135, 135])
        #expect(String(decoding: try Zip.data(of: entries[2], in: done.model), as: UTF8.self) == rule)
    }

    @Test("a plain 3MF keeps every member byte for byte and gains only the settings")
    func addConfig() async throws {
        let engine = try KhaytEngine()
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appending(path: "plain.3mf")
        let kept: [(String, Data)] = [("[Content_Types].xml", Data("types".utf8)), ("_rels/.rels", Data("rels".utf8)),
                                      ("3D/3dmodel.model", Data("<model/>".utf8)), ("Metadata/plate_1.png", Data([0, 1, 2, 3]))]
        try ZipWrite.archive(kept.map { ZipWrite.Member($0.0, $0.1) }).write(to: plain)
        let done = await SlicerProject.prepare(plain, plan: "add-config", machine: Self.machine, process: Self.process,
                                               filament: Self.filament, engine: engine, outDir: dir)
        #expect(done.problem == nil)
        let entries = try Zip.entries(of: done.model)
        #expect(entries.map(\.name) == kept.map(\.0) + ["Metadata/project_settings.config"])
        for (i, member) in kept.enumerated() {
            #expect(try Zip.data(of: entries[i], in: done.model) == member.1, Comment(rawValue: member.0))
        }
    }

    @Test("what the rule plans: STL, a plain 3MF, a project, anything else")
    func plan() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.slicerProjectPlan(model: "/a/Part.STL", entries: nil) == "stl")
        #expect(try await engine.slicerProjectPlan(model: "/a/p.3mf", entries: ["3D/3dmodel.model"]) == "add-config")
        #expect(try await engine.slicerProjectPlan(model: "/a/p.3mf", entries: ["Metadata/project_settings.config"]) == "as-is")
        #expect(try await engine.slicerProjectPlan(model: "/a/p.obj", entries: nil) == "unsupported")
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let obj = dir.appending(path: "p.obj")
        try Data("v 0 0 0".utf8).write(to: obj)
        let said = await SlicerProject.prepare(obj, plan: "unsupported", machine: Self.machine, process: Self.process,
                                               filament: Self.filament, engine: engine, outDir: dir)
        #expect(said.model == obj)
        #expect(said.problem?.contains("STL or a 3MF") == true)
    }

    /// By hand only (`KHAYT_LIVE_SLICE_MODEL=<stl> KHAYT_LIVE_SLICE_OUT=<dir>`):
    /// the project this app would hand Snapmaker Orca for a real model, with
    /// the presets read from this Mac's own Snapmaker Orca folder, written to
    /// `<dir>` to be sliced by the real slicer. Never runs in CI.
    @Test("by hand: the project for a real model, from this Mac's own Snapmaker Orca presets",
          .enabled(if: ProcessInfo.processInfo.environment["KHAYT_LIVE_SLICE_MODEL"] != nil))
    @MainActor func liveProject() async throws {
        let env = ProcessInfo.processInfo.environment
        let model = URL(fileURLWithPath: try #require(env["KHAYT_LIVE_SLICE_MODEL"]))
        let out = URL(fileURLWithPath: try #require(env["KHAYT_LIVE_SLICE_OUT"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let slicer = try SlicerRunTests.slicer("/Applications/Snapmaker Orca.app/Contents/MacOS/Snapmaker_Orca")
        let input = await SlicerRun.sliceInput(engine: try KhaytEngine(), slicer: slicer, template: "", model: model, outDir: out)
        #expect(input.problem == nil, Comment(rawValue: input.problem ?? ""))
        #expect(input.model.lastPathComponent == "khayt-project.3mf")
        print("live project: \(input.model.path)")
    }

    /// THE GOLDEN TEST. A project is sliced with the plain template, and no
    /// source in the app hands a slicer preset flags.
    @Test("no preset flags: a project's argv is the plain --slice 0, and no source writes --load-settings")
    func noPresetFlags() async throws {
        let engine = try KhaytEngine()
        for slicer in ["/Applications/Snapmaker Orca.app/Contents/MacOS/Snapmaker_Orca",
                       "/Applications/OrcaSlicer.app/Contents/MacOS/OrcaSlicer"] {
            let argv = try await engine.sliceArgv(template: "", model: "/d/khayt-project.3mf", output: "/d/out.gcode",
                                                  outdir: "/d", slicer: slicer, presets: .null)
            #expect(argv == ["--slice", "0", "--outputdir", "/d", "/d/khayt-project.3mf"], Comment(rawValue: slicer))
        }
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        for file in try FileManager.default.contentsOfDirectory(atPath: app.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: app.appending(path: file), encoding: .utf8)
            #expect(!text.contains("\"--load-settings\"") && !text.contains("\"--load-filaments\""), Comment(rawValue: file))
            #expect(!text.contains("presets: presets"), Comment(rawValue: "\(file) hands a slice presets again"))
        }
    }
}
