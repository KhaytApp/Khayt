import Foundation
import Testing
@testable import KhaytCore

/// The Bed Ready tools' engine: HueForge, the Orca preset rules and the
/// calibration models, run from the bundled `lib/` modules.
///
/// HueForge's outputs are still being tuned in Bed Ready (bedready#91), so
/// these check STRUCTURE only — a plan comes back, the 3MF has its members, the
/// stack fits the U1's four heads — and never an exact pick or height.
struct StudioEngineTests {

    /// A gradient with a bit of everything, deterministic.
    static func picture(_ w: Int = 120, _ h: Int = 80) -> StudioEngine.Picture {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            bytes[i] = UInt8((x * 2) % 256); bytes[i + 1] = UInt8((y * 3) % 256); bytes[i + 2] = UInt8((x * y) % 256)
        } }
        return StudioEngine.Picture(width: w, height: h, rgba: Data(bytes))
    }

    @Test("the U1 template it builds on is lib/'s, byte for byte")
    func templateIsNotAFork() throws {
        let lib = BundledLogicIsNotAForkTests.repoRoot.appending(path: "lib/hueforge-u1-template.json")
        let copy = BundledLogicIsNotAForkTests.repoRoot.appending(path: "mac/KhaytCore/Sources/KhaytCore/JS/hueforge-u1-template.json")
        #expect(try Data(contentsOf: lib) == Data(contentsOf: copy), "run mac/sync-js.sh")
    }

    @Test("a photo becomes a relief plan the U1 can print")
    func reliefPlan() async throws {
        let engine = try StudioEngine()
        try await engine.setPicture(Self.picture())
        let fils = try await engine.suggest(owned: [], maxColors: 4)
        #expect((2...4).contains(fils.count), "picked \(fils.count)")
        #expect(fils.allSatisfy { $0.hex.hasPrefix("#") && $0.td > 0 })
        var s = StudioEngine.ReliefSettings()
        s.widthMm = 100
        let plan = try #require(try await engine.planRelief(fils, s))
        #expect(plan.width > 0 && plan.height > 0)
        #expect(plan.preview.count == plan.width * plan.height * 4)
        #expect(!plan.bands.isEmpty)
        #expect(plan.bands.allSatisfy { (0..<4).contains($0.head) && $0.z1 > $0.z0 })
        #expect(plan.slots.count <= 4)
        #expect(plan.totalLayers == Int((3.2 / 0.08).rounded()))
        #expect(!plan.tiled)
    }

    @Test("the relief defaults are Bed Ready's approved ones: 3.2 mm, vividness 8 / 6, chromaWeight 0.5 / 1")
    func approvedDefaults() throws {
        var s = StudioEngine.ReliefSettings()
        #expect(s.heightMm == 3.2 && s.vivid == 8 && s.chromaWeight == 0.5)
        // vividness 8 is the approved colour TD scale 0.3, and 6 the black-and-white 0.5
        #expect(abs((1.1 - Double(StudioEngine.ReliefSettings.colourVivid) * 0.1) - 0.3) < 1e-9)
        #expect(abs((1.1 - Double(StudioEngine.ReliefSettings.neutralVivid) * 0.1) - 0.5) < 1e-9)
        s.fit(neutral: true, keepVivid: false)
        #expect(s.vivid == 6 && s.chromaWeight == 1)
        s.fit(neutral: false, keepVivid: false)
        #expect(s.vivid == 8 && s.chromaWeight == 0.5)
        s.vivid = 10
        s.fit(neutral: true, keepVivid: true)
        #expect(s.vivid == 10 && s.chromaWeight == 1)
        // the settings cross to the engine with the matching in them
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        #expect(json["chromaWeight"] as? Double == 1)
    }

    @Test("black and white means every filament is neutral, by Lab chroma")
    func blackAndWhite() throws {
        typealias R = StudioEngine.ReliefSettings
        // Bed Ready's black-and-white set
        #expect(R.isBlackAndWhite(["#161616", "#3A3A3C", "#5A5B5D", "#8B8C8E", "#BDBEC0", "#F4F4F2"]))
        #expect(R.isBlackAndWhite(["#000000", "#FFFFFF"]))
        #expect(!R.isBlackAndWhite(["#161616", "#C04040", "#F4F4F2"]))
        #expect(!R.isBlackAndWhite(["#161616", "#C99B27"]))
        #expect(!R.isBlackAndWhite([]))
        #expect(!R.isBlackAndWhite(["#161616", "nope"]))
        #expect(try #require(R.labChroma("#808080")) < 0.01)
        // the Swift Lab is lib/color-mix.js's: #C04040 is a = 51.10, b = 28.67 there (chroma 58.59)
        #expect(abs(try #require(R.labChroma("#C04040")) - 58.59) < 0.01)
    }

    @Test("the engine plans with the settings' chromaWeight")
    func chromaWeightReachesTheEngine() async throws {
        let engine = try StudioEngine()
        try await engine.setPicture(Self.picture())
        let fils = try await engine.suggest(owned: [], maxColors: 4)
        var s = StudioEngine.ReliefSettings()
        s.chromaWeight = 1
        let plain = try #require(try await engine.planRelief(fils, s))
        s.chromaWeight = 0.5
        let weighted = try #require(try await engine.planRelief(fils, s))
        #expect(plain.preview != weighted.preview || plain.bands != weighted.bands)
    }

    @Test("the 3MF carries the members a U1 project needs, thumbnails left to the app")
    func reliefPieces() async throws {
        let engine = try StudioEngine()
        try await engine.setPicture(Self.picture())
        let fils = try await engine.suggest(owned: [], maxColors: 3)
        let s = StudioEngine.ReliefSettings()
        _ = try #require(try await engine.planRelief(fils, s))
        let pieces = try await engine.reliefPieces(name: "test", settings: s, thumbnail: true)
        #expect(pieces.count == 1)
        let names = pieces[0].members.map(\.name)
        for needed in ["[Content_Types].xml", "3D/3dmodel.model", "3D/Objects/object_1.model",
                       "Metadata/project_settings.config", "Metadata/layer_config_ranges.xml",
                       "Metadata/plate_1.png", "Metadata/plate_1_small.png"] {
            #expect(names.contains(needed), "no \(needed)")
        }
        #expect(pieces[0].members.filter(\.thumbnail).map(\.name) == ["Metadata/plate_1.png", "Metadata/plate_1_small.png"])
        let config = try #require(pieces[0].members.first { $0.name == "Metadata/project_settings.config" }?.text)
        let parsed = try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any]
        #expect((parsed?["filament_colour"] as? [String])?.count == 4, "four slots, one per head")
        #expect(parsed?["layer_height"] as? String == "0.08")
        let mesh = try #require(pieces[0].members.first { $0.name == "3D/Objects/object_1.model" }?.text)
        #expect(mesh.contains("<triangle "))
    }

    @Test("a relief wider than the bed comes out as tiles")
    func tiles() async throws {
        let engine = try StudioEngine()
        try await engine.setPicture(Self.picture(300, 100))
        let fils = try await engine.suggest(owned: [], maxColors: 2)
        var s = StudioEngine.ReliefSettings()
        s.widthMm = 500
        let plan = try #require(try await engine.planRelief(fils, s))
        #expect(plan.tiled)
        let pieces = try await engine.reliefPieces(name: "wide", settings: s, thumbnail: false)
        #expect(pieces.count == plan.tileCols * plan.tileRows)
        #expect(pieces.allSatisfy { $0.tag?.hasPrefix("-r") == true && !$0.members.contains(where: \.thumbnail) })
    }

    @Test("flat mode: solid regions, one part per colour, no layer ranges")
    func flat() async throws {
        let engine = try StudioEngine()
        try await engine.setPicture(Self.picture())
        let plan = try #require(try await engine.planFlat(colors: 3, widthMm: 100, heightMm: 2, filaments: []))
        #expect((2...3).contains(plan.palette.count))
        #expect(plan.preview.count == plan.width * plan.height * 4)
        let pieces = try await engine.flatPieces(name: "f", layerH: 0.08, widthMm: 100, heightMm: 2, thumbnail: false)
        let names = try #require(pieces.first).members.map(\.name)
        #expect(!names.contains("Metadata/layer_config_ranges.xml"))
        #expect(names.contains("Metadata/model_settings.config"))
    }

    @Test("an STL of the relief is a binary STL of whole triangles")
    func stl() async throws {
        let engine = try StudioEngine()
        try await engine.setPicture(Self.picture(60, 40))
        let fils = try await engine.suggest(owned: [], maxColors: 2)
        let s = StudioEngine.ReliefSettings()
        _ = try #require(try await engine.planRelief(fils, s))
        let data = try #require(try await engine.reliefStl(settings: s))
        let count = data.subdata(in: 80..<84).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(count > 0 && data.count == 84 + Int(count) * 50)
    }

    @Test("Orca presets: printers fold, versions pick, a tuned preset is a user preset")
    func orcaRules() async throws {
        let engine = try StudioEngine()
        #expect(try await engine.slicers().contains { $0.id == "snapmaker" })
        let printers = try await engine.groupPrinters(["Snapmaker U1 0.4 nozzle", "Snapmaker U1 (0.6 nozzle)", "fdm_x", "MyKlipper"])
        #expect(printers.map(\.label) == ["Snapmaker U1"])
        #expect(try await engine.defaultPrinter(printers) == "Snapmaker U1")
        #expect(try await engine.pickVersion(["2", "1", "2", nil], fallback: nil) == "2")
        #expect(try await engine.safeFileBase("a/b:c") == "a-b-c")
        #expect(try await engine.validProfileRef("profiles/x.json"))
        #expect(try await engine.validProfileRef("../x.json") == false)
        let base: JSONValue = .object(["type": .string("filament"), "name": .string("Base"), "setting_id": .string("S1")])
        let tuned = try await engine.tunedPreset(base: base, values: ["nozzleTemp": "212"], name: "",
                                                 printer: printers.first, version: "02.03.01.10")
        #expect(tuned.ok && tuned.name == "Base (tuned)")
        let text = try #require(tuned.text)
        #expect(text.contains("\"nozzle_temperature\": [\n    \"212\""))
        #expect(!text.contains("setting_id"))
        let refused = try await engine.tunedPreset(base: base, values: [:], name: "x", printer: nil, version: nil)
        #expect(!refused.ok && refused.error != nil)
        let retargeted = try #require(try await engine.retarget(preset: base, printer: printers[0], version: nil))
        #expect(retargeted.contains("compatible_printers"))
        #expect(try await engine.retarget(preset: .object(["type": .string("machine")]), printer: printers[0], version: nil) == nil)
    }

    @Test("calibration: every test has steps and a model, and the log row is the desktop's shape")
    func calibration() async throws {
        let engine = try StudioEngine()
        let tests = try await engine.calibrationTests()
        #expect(tests == ["temp", "flow", "retraction", "firstlayer", "xyz"])
        for t in tests {
            let d = try await engine.describeCalibration(test: t, material: "PETG")
            #expect(!d.steps.isEmpty && d.fileName.hasSuffix(".stl"))
            let stl = try await engine.calibrationModel(test: t, material: "PETG")
            #expect(stl.hasPrefix("solid ") && stl.contains("endsolid"))
        }
        let row = try await engine.calibrationLogEntry(test: "flow", material: "PLA", result: " 0.98 ",
                                                       now: Date(timeIntervalSince1970: 1_762_336_800))
        guard case .object(let o) = row else { Issue.record("not an object"); return }
        #expect(Set(o.keys) == ["id", "test", "material", "result", "date"])
        #expect(o["id"] == .string("CAL1762336800000"))
        #expect(o["date"] == .string("2025-11-05T10:00:00.000Z"))
        #expect(o["result"] == .string("0.98"))
    }
}
