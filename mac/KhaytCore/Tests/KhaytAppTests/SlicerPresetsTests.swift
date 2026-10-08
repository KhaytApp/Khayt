import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A bare model sliced by an Orca fork gets the slicer's own presets (#1778).
///
/// Which presets is `lib/slicer-presets.js`'s, pinned by `test/slicer-presets.test.js`.
/// What is worth testing HERE is the crossing: that the rule, which reads files,
/// can read them through the engine — lazily, below the slicer's own folders
/// and nowhere else — and that the Mac's glue hands the slicer what the
/// desktop's does.
struct SlicerPresetsTests {

    /// A preset tree on disk, the shape a fork keeps:
    /// `<cfg>/Snapmaker_Orca/{Snapmaker_Orca.conf,user,system}` and the app's
    /// bundled `profiles/<Vendor>/<kind>/<name>.json`.
    static func tree() throws -> (root: URL, cfg: URL, bundled: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "khayt-presets-\(UUID().uuidString)")
        let cfg = root.appending(path: "cfg")
        let bundled = root.appending(path: "app/profiles")
        func put(_ rel: URL, _ name: String, _ json: [String: Any]) throws {
            try FileManager.default.createDirectory(at: rel, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: json).write(to: rel.appending(path: name + ".json"))
        }
        let vendor = bundled.appending(path: "Snapmaker")
        let printer = "Snapmaker U1 (0.4 nozzle)"
        try put(vendor.appending(path: "machine"), "fdm_machine_common", ["gcode_flavor": "klipper"])
        try put(vendor.appending(path: "machine"), printer,
                ["inherits": "fdm_machine_common",
                 "default_print_profile": "0.20mm Standard @Snapmaker U1 (0.4 nozzle)",
                 "default_filament_profile": ["Generic PLA @U1"]])
        try put(vendor.appending(path: "process"), "0.20mm Standard @Snapmaker U1 (0.4 nozzle)",
                ["layer_height": "0.2", "compatible_printers": [printer]])
        try put(vendor.appending(path: "filament"), "Generic PLA @U1",
                ["filament_type": ["PLA"], "compatible_printers": [printer]])
        try FileManager.default.createDirectory(at: cfg.appending(path: "user"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cfg.appending(path: "system"), withIntermediateDirectories: true)
        // Outside every root: the rule must never be able to read it.
        try #"{"secret": "outside"}"#.write(to: root.appending(path: "outside.json"), atomically: true, encoding: .utf8)
        return (root, cfg, bundled)
    }

    static func conf(machine: String) -> String {
        let presets = ["machine": machine]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: ["app": [:], "presets": presets]),
                          as: UTF8.self)
        return json + "\n# MD5 checksum 0123456789ABCDEF\n"
    }

    @Test("the rule reads the slicer's presets through the engine, flattened along inherits")
    func choosesThroughTheEngine() async throws {
        let t = try Self.tree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let engine = try KhaytEngine()
        let r = try await engine.choosePresets(conf: Self.conf(machine: "Snapmaker U1 (0.4 nozzle)"),
                                               user: t.cfg.appending(path: "user").path,
                                               system: t.cfg.appending(path: "system").path,
                                               bundled: t.bundled.path)
        #expect(r.ok, Comment(rawValue: r.error ?? ""))
        guard case .object(let m)? = r.machine, case .object(let p)? = r.process,
              case .object(let f)? = r.filament else {
            Issue.record("a preset did not come back"); return
        }
        #expect(m["name"] == .string("Snapmaker U1 (0.4 nozzle)"))
        #expect(m["gcode_flavor"] == .string("klipper"), "flattened along inherits")
        #expect(p["name"] == .string("0.20mm Standard @Snapmaker U1 (0.4 nozzle)"))
        #expect(f["name"] == .string("Generic PLA @U1"))

        // And written as the file the slicer loads: typed, complete, "system".
        let text = try await engine.presetFileJson(kind: "process", preset: try #require(r.process))
        let back = try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))
        #expect(back["type"] == .string("process"))
        #expect(back["from"] == .string("system"))
    }

    @Test("a printer the slicer has never been set to is a reason, not a crash")
    func noPrinter() async throws {
        let t = try Self.tree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let engine = try KhaytEngine()
        let none = try await engine.choosePresets(conf: "", user: t.cfg.appending(path: "user").path,
                                                  system: "", bundled: t.bundled.path)
        #expect(!none.ok)
        #expect(none.code == "no-printer")
        let gone = try await engine.choosePresets(conf: Self.conf(machine: "A printer nobody has"),
                                                  user: "", system: "", bundled: t.bundled.path)
        #expect(gone.code == "printer-missing")
    }

    @Test("the engine's file access stops at the roots it was given")
    func readsOnlyBelowTheRoots() async throws {
        let t = try Self.tree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let engine = try KhaytEngine()
        // A "printer" whose file would be outside every root, reached by a path
        // and by a parent-directory walk. The rule refuses unsafe names itself;
        // this is the floor under it — the host will not read the file either.
        for name in ["../../outside", t.root.appending(path: "outside").path] {
            let r = try await engine.choosePresets(conf: Self.conf(machine: name),
                                                   user: "", system: "", bundled: t.bundled.path)
            #expect(!r.ok, Comment(rawValue: name))
        }
    }

    @Test("a symlink inside the presets folder cannot reach a file outside it, and a FIFO is not a file")
    func linksAndFifos() async throws {
        let t = try Self.tree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let machines = t.bundled.appending(path: "Snapmaker/machine")
        // A "printer" that is a link to a file outside every root: the text of
        // its path is inside, the file is not.
        try FileManager.default.createSymbolicLink(atPath: machines.appending(path: "Linked.json").path,
                                                   withDestinationPath: t.root.appending(path: "outside.json").path)
        // A FIFO named like a preset: opening it to read would block for good.
        #expect(mkfifo(machines.appending(path: "Fifo.json").path, 0o600) == 0)
        let engine = try KhaytEngine()
        for name in ["Linked", "Fifo"] {
            let r = try await engine.choosePresets(conf: Self.conf(machine: name),
                                                   user: "", system: "", bundled: t.bundled.path)
            #expect(!r.ok, Comment(rawValue: name))
            #expect(r.code == "printer-missing", Comment(rawValue: name))
        }
        // A link that stays INSIDE the roots is still followed.
        try FileManager.default.createSymbolicLink(
            atPath: machines.appending(path: "Alias.json").path,
            withDestinationPath: machines.appending(path: "Snapmaker U1 (0.4 nozzle).json").path)
        let alias = try await engine.choosePresets(conf: Self.conf(machine: "Alias"),
                                                   user: "", system: "", bundled: t.bundled.path)
        #expect(alias.code != "printer-missing", Comment(rawValue: alias.error ?? ""))
    }

    @Test("the glue hands an Orca fork the presets, and the argv loads them first")
    func glueAndArgv() async throws {
        let t = try Self.tree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let engine = try KhaytEngine()
        // `presetRoots` derives the folders from the slicer's path and home; the
        // test can only steer `bundled` that way, so it drives the rule with
        // the tree's own roots and checks the argv the glue's output makes.
        let r = try await engine.choosePresets(conf: Self.conf(machine: "Snapmaker U1 (0.4 nozzle)"),
                                               user: "", system: "", bundled: t.bundled.path)
        #expect(r.ok)
        let presets: JSONValue = .object(["settings": .array([.string("/s/m.json"), .string("/s/p.json")]),
                                          "filaments": .array([.string("/s/f.json")])])
        let orca = "/Applications/OrcaSlicer.app/Contents/MacOS/OrcaSlicer"
        let argv = try await engine.sliceArgv(template: "", model: "m.stl", output: "o.gcode",
                                              outdir: "/d", slicer: orca, presets: presets)
        #expect(argv == ["--load-settings", "/s/m.json;/s/p.json", "--load-filaments", "/s/f.json",
                         "--slice", "0", "--outputdir", "/d", "m.stl"])
        // A shop's own arguments already say what to load: untouched.
        let own = try await engine.sliceArgv(template: "--slice 1 {model}", model: "m.stl", output: "",
                                             outdir: "", slicer: orca, presets: presets)
        #expect(own == ["--slice", "1", "m.stl"])
        // A 3MF that carries its own settings needs nothing; a bare mesh does.
        #expect(try await engine.needsPresets(model: "a.stl", entries: nil))
        #expect(!(try await engine.needsPresets(model: "a.3mf", entries: ["Metadata/project_settings.config"])))
        // PrusaSlicer is never handed them.
        let glue = await SlicerRun.bareModelPresets(
            engine: engine,
            slicer: try SlicerRunTests.slicer("/Applications/PrusaSlicer.app/Contents/MacOS/PrusaSlicer"),
            template: "", model: URL(fileURLWithPath: "/tmp/m.stl"), outDir: t.root)
        #expect(glue.presets == .null)
    }

    @Test("a slicer killed by a signal is said to have crashed")
    func crashIsSaid() async throws {
        let engine = try KhaytEngine()
        let why = try await engine.sliceFailureReason(stderr: "", stdout: "", code: 11, signal: "SIGSEGV")
        #expect(why.contains("crashed"), Comment(rawValue: why))
    }
}
