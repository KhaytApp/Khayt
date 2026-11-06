import Foundation
import JavaScriptCore

/// The Bed Ready tools' rules — HueForge, the Calibration Assistant and the
/// Orca filament presets — on a JavaScriptCore context and a thread of their
/// own.
///
/// ── WHY NOT `KhaytEngine` ─────────────────────────────────────────────────
///
/// One HueForge plan takes seconds: `planPainting` learns a per-layer filament
/// sequence over the whole picture. `KhaytEngine` is the shop's engine, and its
/// threads are shared (`EngineThread`): a plan on one of them would stall every
/// figure on every screen behind it. So this one gets a thread nobody else uses
/// (`EngineThread.dedicated`) and its own context, loaded with only the modules
/// these tools read. Every call is an `await` from the app — never the main
/// thread, and never Swift's cooperative pool.
///
/// ── WHAT IS SHARED AND WHAT IS NOT ────────────────────────────────────────
///
/// The arithmetic is `lib/hueforge.js`, `lib/hueforge-flat.js`,
/// `lib/hueforge-3mf.js`, `lib/orca-presets.js` and `lib/calibration-models.js`
/// — the files the desktop runs. What JavaScriptCore cannot do is Swift's: the
/// photo is decoded with ImageIO (the app), the 3MF zip is `ZipWrite` (the
/// app), and the slicer's folders are walked by `FileManager`. The rules never
/// see a file.
///
/// ── THE PICTURE CROSSES ONCE ──────────────────────────────────────────────
///
/// A 640-pixel photo is 1.6 MB of RGBA. It is bound as a Latin-1 string (one
/// character per byte, no escaping) and rebuilt as a `Uint8ClampedArray` in the
/// context, then KEPT there: every re-plan after a slider moves reads the copy
/// already inside. The solved relief stays inside too, and the export reads it
/// from there, so a heightfield never crosses at all.
public actor StudioEngine {
    private let runtime: JSRuntime
    private let thread: EngineThread

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        thread.asUnownedSerialExecutor()
    }

    static let modules = ["color-mix", "hueforge", "hueforge-flat", "hueforge-3mf",
                          "orca-presets", "calibration-models"]

    /// The U1's build plate, which `planTiles` cuts a relief to fit — the
    /// figure the desktop's export handler uses.
    public static let u1Bed = 270.0

    public init(bundle: Bundle? = nil) throws {
        let thread = EngineThread.dedicated(name: "khayt.studio")
        self.thread = thread
        runtime = try thread.sync {
            let runtime = try JSRuntime(modules: Self.modules, bundle: bundle)
            let resources = bundle ?? BundledResources.javaScript
            guard let url = resources.url(forResource: "hueforge-u1-template", withExtension: "json", subdirectory: "JS") else {
                throw KhaytJSError.moduleMissing("hueforge-u1-template.json")
            }
            let template = try String(contentsOf: url, encoding: .utf8)
            _ = try runtime.withBoundStrings(["__hfTemplateText": template]) {
                try runtime.evaluate("globalThis.KhaytHueForgeU1Template = JSON.parse(globalThis.__hfTemplateText); true")
            }
            try runtime.evaluate(Self.glue)
            return runtime
        }
    }

    isolated deinit {}

    // MARK: - The picture

    /// RGBA, 8 bits a channel, row by row — the `ImageData` shape the desktop's
    /// canvas hands the same rules.
    public struct Picture: Sendable {
        public let width: Int
        public let height: Int
        public let rgba: Data
        public init(width: Int, height: Int, rgba: Data) {
            self.width = width; self.height = height; self.rgba = rgba
        }
    }

    /// Hand the engine the photo every later call reads. Once per photo.
    public func setPicture(_ picture: Picture) throws {
        guard picture.width > 0, picture.height > 0, picture.rgba.count == picture.width * picture.height * 4,
              let text = String(data: picture.rgba, encoding: .isoLatin1) else {
            throw KhaytJSError.unexpectedResult("a picture whose size and pixels disagree")
        }
        _ = try runtime.withBoundStrings(["__hfPixels": text]) {
            try runtime.evaluate("__studio.setPicture(\(picture.width), \(picture.height)); true")
        }
    }

    // MARK: - HueForge

    /// One filament in the stack, bottom to top. `td` is the Transmission
    /// Distance in mm; `name` is the spool it snapped to, when it did.
    public struct Filament: Codable, Sendable, Hashable {
        public var hex: String
        public var td: Double
        public var name: String?
        public init(hex: String, td: Double, name: String? = nil) {
            self.hex = hex; self.td = td; self.name = name
        }
    }

    /// The stack the picture asks for: `suggestFilaments`, snapped to the
    /// shop's own spools when it has coloured ones. `owned` is the
    /// inventory's records as the book holds them (`color`, `weight`,
    /// `material`, `colourVariant`, `brand`).
    public func suggest(owned: [JSONValue], maxColors: Int) throws -> [Filament] {
        try runtime.call2("__studio.suggest(ARG0, ARG1)", [.array(owned), .number(Double(maxColors))],
                          as: [Filament].self)
    }

    /// The default Transmission Distance for a colour, the engine's guess.
    public func defaultTd(_ hex: String) throws -> Double {
        try runtime.call2("KhaytHueForge.defaultTd(ARG0)", [.string(hex)], as: Double.self)
    }

    /// The settings a relief is planned with — the desktop panel's fields.
    public struct ReliefSettings: Codable, Sendable, Hashable {
        public var layerH = 0.08
        public var heightMm = 2.4
        public var widthMm = 120.0
        public var baseLayers = 5
        /// 1–10. The desktop maps it to the front-lit TD scale.
        public var vivid = 9
        public var smooth = 0
        /// "", "hole" or "loop".
        public var hang = ""
        public var holeMm = 4.0
        public init() {}
    }

    public struct Band: Codable, Sendable, Hashable {
        public let z0: Double
        public let z1: Double
        public let head: Int
        public let hex: String
    }

    /// A planned relief, for the screen. The heights stay in the engine.
    public struct ReliefPlan: Sendable {
        public let width: Int
        public let height: Int
        /// The colours the print can reach, pixel by pixel (RGBA).
        public let preview: Data
        public let meanDeltaE: Double
        public let bands: [Band]
        /// The four slot colours, by head.
        public let slots: [String]
        public let distinct: Int
        public let swaps: Int
        public let totalLayers: Int
        public let automatic: Bool
        public let tileCols: Int
        public let tileRows: Int
        public var tiled: Bool { tileCols * tileRows > 1 }
    }

    private struct ReliefFacts: Decodable {
        let ok: Bool
        let width: Int?, height: Int?
        let meanDeltaE: Double?
        let bands: [Band]?
        let slots: [String]?
        let distinct: Int?, swaps: Int?, totalLayers: Int?
        let automatic: Bool?
        let tileCols: Int?, tileRows: Int?
    }

    /// Plan the relief for the picture set last. Nil when nothing printable
    /// comes of it — no valid filament, or a degenerate picture.
    public func planRelief(_ filaments: [Filament], _ s: ReliefSettings) throws -> ReliefPlan? {
        let opts = try JSONValue.decode(JSONValue.self, from: JSONEncoder().encode(s))
        let fils = try JSONValue.decode(JSONValue.self, from: JSONEncoder().encode(filaments))
        let facts = try runtime.call2("__studio.planRelief(ARG0, ARG1, ARG2)",
                                      [fils, opts, .number(Self.u1Bed)], as: ReliefFacts.self)
        guard facts.ok, let w = facts.width, let h = facts.height else { return nil }
        return ReliefPlan(width: w, height: h, preview: try previewBytes(),
                          meanDeltaE: facts.meanDeltaE ?? 0, bands: facts.bands ?? [],
                          slots: facts.slots ?? [], distinct: facts.distinct ?? 0,
                          swaps: facts.swaps ?? 0, totalLayers: facts.totalLayers ?? 0,
                          automatic: facts.automatic ?? false,
                          tileCols: facts.tileCols ?? 1, tileRows: facts.tileRows ?? 1)
    }

    /// A flat plan: solid colour regions, one part per colour.
    public struct FlatPlan: Sendable {
        public let width: Int
        public let height: Int
        public let preview: Data
        public let palette: [String]
        public let parts: Int
        public let sizeMm: [Double]
    }

    private struct FlatFacts: Decodable {
        let ok: Bool
        let width: Int?, height: Int?
        let palette: [String]?
        let parts: Int?
        let sizeMm: [Double]?
    }

    public func planFlat(colors: Int, widthMm: Double, heightMm: Double, filaments: [String]) throws -> FlatPlan? {
        let facts = try runtime.call2("__studio.planFlat(ARG0)", [.object([
            "colors": .number(Double(colors)), "widthMm": .number(widthMm), "heightMm": .number(heightMm),
            "filaments": .array(filaments.map { .string($0) }),
        ])], as: FlatFacts.self)
        guard facts.ok, let w = facts.width, let h = facts.height else { return nil }
        return FlatPlan(width: w, height: h, preview: try previewBytes(), palette: facts.palette ?? [],
                        parts: facts.parts ?? 0, sizeMm: facts.sizeMm ?? [])
    }

    private func previewBytes() throws -> Data {
        let value = try runtime.evaluate("__studio.previewLatin1()")
        guard let text = value.toString(), let data = text.data(using: .isoLatin1) else {
            throw KhaytJSError.unexpectedResult("no preview")
        }
        return data
    }

    /// One member of a 3MF, as `hueforge-3mf` lays it out. A thumbnail member
    /// carries no bytes: the app puts in the PNG it drew (`thumbnail`).
    public struct Member: Sendable {
        public let name: String
        public let text: String?
        public let thumbnail: Bool
    }

    /// One file to write: a whole relief, or one tile of it (`tag` "-r1c2").
    public struct Piece: Sendable {
        public let tag: String?
        public let members: [Member]
    }

    /// The 3MF(s) for the relief planned last, tile by tile when it is bigger
    /// than the bed — exactly the desktop's `hub:hf-export-3mf`. Empty when
    /// nothing was planned.
    public func reliefPieces(name: String, settings s: ReliefSettings, thumbnail: Bool) throws -> [Piece] {
        let opts = try JSONValue.decode(JSONValue.self, from: JSONEncoder().encode(s))
        _ = try runtime.call2("__studio.reliefPieces(ARG0, ARG1, ARG2, ARG3)",
                              [.string(name), opts, .bool(thumbnail), .number(Self.u1Bed)], as: Bool.self)
        return try readPieces()
    }

    /// The flat plan's 3MF — the desktop's `hub:hf-export-flat-3mf`.
    public func flatPieces(name: String, layerH: Double, widthMm: Double, heightMm: Double, thumbnail: Bool) throws -> [Piece] {
        _ = try runtime.call2("__studio.flatPieces(ARG0, ARG1, ARG2)",
                              [.string(name), .object(["layerH": .number(layerH), "widthMm": .number(widthMm),
                                                       "heightMm": .number(heightMm)]),
                               .bool(thumbnail)], as: Bool.self)
        return try readPieces()
    }

    /// The pieces the last export call left in `__studio.out`, read value by
    /// value: a mesh member is megabytes of XML, and `JSON.stringify` would
    /// escape and copy all of it a second time.
    private func readPieces() throws -> [Piece] {
        let out = try runtime.evaluate("(function () { var o = __studio.out; __studio.out = null; return o || []; })()")
        let count = Int(out.objectForKeyedSubscript("length")?.toInt32() ?? 0)
        var pieces: [Piece] = []
        for i in 0..<count {
            guard let p = out.atIndex(i) else { continue }
            let tagValue = p.objectForKeyedSubscript("tag")
            let tag = (tagValue?.isString ?? false) ? tagValue?.toString() : nil
            let ms = p.objectForKeyedSubscript("members")
            let n = Int(ms?.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            var members: [Member] = []
            for j in 0..<n {
                guard let m = ms?.atIndex(j), let name = m.objectForKeyedSubscript("name")?.toString() else { continue }
                let thumb = m.objectForKeyedSubscript("thumbnail")?.toBool() ?? false
                let text = thumb ? nil : m.objectForKeyedSubscript("text")?.toString()
                members.append(Member(name: name, text: text, thumbnail: thumb))
            }
            pieces.append(Piece(tag: tag, members: members))
        }
        return pieces
    }

    /// The relief planned last as one binary STL (no tiles, no colour) — the
    /// desktop's "Export STL". Nil when nothing was planned.
    public func reliefStl(settings s: ReliefSettings) throws -> Data? {
        let opts = try JSONValue.decode(JSONValue.self, from: JSONEncoder().encode(s))
        _ = try runtime.call2("__studio.stashStl(ARG0)", [opts], as: Bool.self)
        let value = try runtime.evaluate("(function () { var s = __studio.stl; __studio.stl = null; return s; })()")
        guard value.isString, let text = value.toString(), !text.isEmpty else { return nil }
        return text.data(using: .isoLatin1)
    }

    // MARK: - Orca filament presets

    public struct Slicer: Decodable, Sendable, Hashable, Identifiable {
        public let id: String
        public let label: String
        public let dirs: [String]
        public let version: String?
    }

    public struct Printer: Codable, Sendable, Hashable, Identifiable {
        public let label: String
        public let machines: [String]
        public var id: String { label }
    }

    /// The Orca-family slicers the installer knows, by their folder names.
    public func slicers() throws -> [Slicer] {
        try runtime.call2("KhaytOrcaPresets.SLICERS", [], as: [Slicer].self)
    }

    public func userProfileName(subdirs: [String], hasDefault: Bool) throws -> String {
        try runtime.call2("KhaytOrcaPresets.userProfileName(ARG0, ARG1)",
                          [.array(subdirs.map { .string($0) }), .bool(hasDefault)], as: String.self)
    }

    public func groupPrinters(_ machineNames: [String]) throws -> [Printer] {
        try runtime.call2("KhaytOrcaPresets.groupPrinters(ARG0)", [.array(machineNames.map { .string($0) })],
                          as: [Printer].self)
    }

    public func defaultPrinter(_ printers: [Printer]) throws -> String? {
        let list = try JSONValue.decode(JSONValue.self, from: JSONEncoder().encode(printers))
        return try runtime.call2("(function (p) { var d = KhaytOrcaPresets.defaultPrinter(p); return d ? d.label : null; })(ARG0)",
                                 [list], as: String?.self)
    }

    public func pickVersion(_ versions: [String?], fallback: String?) throws -> String? {
        try runtime.call2("KhaytOrcaPresets.pickVersion(ARG0, ARG1)",
                          [.array(versions.map { $0.map(JSONValue.string) ?? .null }), fallback.map(JSONValue.string) ?? .null],
                          as: String?.self)
    }

    public func safeFileBase(_ name: String) throws -> String {
        try runtime.call2("KhaytOrcaPresets.safeFileBase(ARG0)", [.string(name)], as: String.self)
    }

    public func validProfileRef(_ file: String) throws -> Bool {
        try runtime.call2("KhaytOrcaPresets.validProfileRef(ARG0)", [.string(file)], as: Bool.self)
    }

    /// A fetched library preset retargeted to a printer and a version, as the
    /// text the desktop writes to disk. Nil when it is not a filament preset.
    public func retarget(preset: JSONValue, printer: Printer, version: String?) throws -> String? {
        let p = try JSONValue.decode(JSONValue.self, from: JSONEncoder().encode(printer))
        return try runtime.call2("""
            (function (preset, printer, version) {
              if (!preset || preset.type !== 'filament' || !preset.name) return null;
              return KhaytOrcaPresets.presetText(KhaytOrcaPresets.retarget(preset, printer, version));
            })(ARG0, ARG1, ARG2)
            """, [preset, p, version.map(JSONValue.string) ?? .null], as: String?.self)
    }

    public struct Current: Decodable, Sendable, Hashable {
        public let nozzleTemp: String
        public let flowRatio: String
        public let pressureAdvance: String
        public let retractionLength: String
        public let maxVolSpeed: String
    }

    public struct UserFilament: Decodable, Sendable, Hashable, Identifiable {
        public let name: String
        public let file: String
        public let type: String
        public let current: Current
        public var id: String { file }
    }

    public func userFilament(_ preset: JSONValue, file: String) throws -> UserFilament? {
        try runtime.call2("KhaytOrcaPresets.userFilament(ARG0, ARG1)", [preset, .string(file)], as: UserFilament?.self)
    }

    public struct Tuned: Decodable, Sendable {
        public let ok: Bool
        public let error: String?
        public let text: String?
        public let name: String?
        public let applied: [String]?
    }

    /// A tuned preset from a base one. The refusal ("enter at least one
    /// measured value") comes back as `error`, in the desktop's words.
    public func tunedPreset(base: JSONValue, values: [String: String], name: String,
                            printer: Printer?, version: String?) throws -> Tuned {
        let p = try printer.map { try JSONValue.decode(JSONValue.self, from: JSONEncoder().encode($0)) } ?? .null
        return try runtime.call2("""
            (function (preset, values, name, printer, version) {
              try {
                var t = KhaytOrcaPresets.tunedPreset(preset, values, name, printer, version);
                return { ok: true, text: KhaytOrcaPresets.presetText(t.preset), name: t.name, applied: t.applied };
              } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
            })(ARG0, ARG1, ARG2, ARG3, ARG4)
            """, [base, .object(values.mapValues(JSONValue.string)), .string(name), p,
                  version.map(JSONValue.string) ?? .null], as: Tuned.self)
    }

    // MARK: - Calibration

    public struct CalibrationTest: Decodable, Sendable, Hashable {
        public let test: String
        public let material: String
        public let name: String
        public let blurb: String
        public let sweep: String
        public let steps: [String]
        public let plan: String
        public let fileName: String
    }

    public func calibrationTests() throws -> [String] {
        try runtime.call2("KhaytCalibrationModels.tests", [], as: [String].self)
    }

    public func calibrationMaterials() throws -> [String] {
        try runtime.call2("KhaytCalibrationModels.materials", [], as: [String].self)
    }

    public func describeCalibration(test: String, material: String) throws -> CalibrationTest {
        try runtime.call2("KhaytCalibrationModels.describe(ARG0, ARG1)", [.string(test), .string(material)],
                          as: CalibrationTest.self)
    }

    /// The test model as ASCII STL text.
    public func calibrationModel(test: String, material: String) throws -> String {
        try runtime.call2("KhaytCalibrationModels.modelFor(ARG0, ARG1)", [.string(test), .string(material)],
                          as: String.self)
    }

    /// The row the result log keeps, in the shape the desktop writes.
    public func calibrationLogEntry(test: String, material: String, result: String, now: Date) throws -> JSONValue {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ms = (now.timeIntervalSince1970 * 1000).rounded(.down)
        return try runtime.call2("KhaytCalibrationModels.logEntry(ARG0, ARG1, ARG2, ARG3, ARG4)",
                                 [.string(test), .string(material), .string(result), .string(iso.string(from: now)),
                                  .number(ms)], as: JSONValue.self)
    }

    // MARK: - The glue

    /// What this context holds between calls, and the shapes that cross.
    ///
    /// Every rule called here is the desktop's, with the desktop's arguments:
    /// `planRelief` is `renderer/hueforge.js recompute()` (the same
    /// `planPainting` options, vividness to TD scale included), and the two
    /// export functions are `main.js`'s `hub:hf-export-3mf` and
    /// `hub:hf-export-flat-3mf` with the zip left out.
    static let glue = #"""
    (function () {
      var HF = globalThis.KhaytHueForge, FLAT = globalThis.KhaytHueForgeFlat, HF3 = globalThis.KhaytHueForge3mf;
      var S = { img: null, paint: null, flat: null };
      function latin1(bytes) {
        var out = '', CH = 8192;
        for (var i = 0; i < bytes.length; i += CH) out += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(bytes.length, i + CH)));
        return out;
      }
      function membersOut(members) {
        return (members || []).map(function (m) {
          return m.store ? { name: m.name, thumbnail: true } : { name: m.name, text: String(m.data) };
        });
      }
      var api = {
        out: null, stl: null,
        setPicture: function (w, h) {
          var s = globalThis.__hfPixels, a = new Uint8ClampedArray(s.length);
          for (var i = 0; i < s.length; i++) a[i] = s.charCodeAt(i);
          S.img = { width: w, height: h, data: a };
          S.paint = null; S.flat = null;
        },
        suggest: function (owned, maxColors) {
          if (!S.img) return [];
          var inv = (owned || []).filter(function (i) { return i && i.color && globalThis.KhaytColor.hexToRgb(i.color) && (i.weight == null || i.weight > 0); });
          return HF.suggestFilaments(S.img, inv, maxColors).map(function (f) { return { hex: f.hex, td: f.td, name: f.name || null }; });
        },
        planRelief: function (fils, o, bed) {
          S.paint = null; S.flat = null;
          if (!S.img || !fils || !fils.length) return { ok: false };
          var paint = HF.planPainting(S.img, fils, {
            layerH: o.layerH, heightMm: o.heightMm, widthMm: o.widthMm,
            baseLayers: o.baseLayers, dither: false,
            tdScale: Math.max(0.1, 1.1 - (o.vivid || 9) * 0.1),
            smooth: o.smooth || 0, fixes: [],
          });
          if (!paint || !paint.bands.length) return { ok: false };
          S.paint = paint;
          var distinct = {}; paint.seq.forEach(function (x) { distinct[x] = 1; });
          var n = Object.keys(distinct).length;
          var tp = HF.planTiles(paint.solve.width, paint.solve.height, o.widthMm, { x: bed, y: bed });
          return {
            ok: true, width: paint.solve.width, height: paint.solve.height, meanDeltaE: paint.solve.meanDeltaE || 0,
            bands: paint.bands, slots: paint.filaments.map(function (f) { return f.hex; }),
            distinct: n, swaps: paint.swaps, totalLayers: paint.totalLayers, automatic: n <= HF.U1_HEADS,
            tileCols: tp.tiles.length > 1 ? tp.cols : 1, tileRows: tp.tiles.length > 1 ? tp.rows : 1,
          };
        },
        planFlat: function (o) {
          S.paint = null; S.flat = null;
          if (!S.img) return { ok: false };
          var f = FLAT.planFlat(S.img, { colors: o.colors, widthMm: o.widthMm, heightMm: o.heightMm, filaments: o.filaments });
          if (!f || !f.parts.length) return { ok: false };
          S.flat = f;
          return { ok: true, width: f.width, height: f.height, palette: f.palette.map(function (p) { return p.hex; }),
                   parts: f.parts.length, sizeMm: [f.sizeMm.x, f.sizeMm.y, f.sizeMm.z] };
        },
        previewLatin1: function () {
          var src = S.flat || (S.paint && S.paint.solve);
          return src && src.preview ? latin1(src.preview) : '';
        },
        reliefPieces: function (name, o, thumb, bed) {
          api.out = [];
          var p = S.paint;
          if (!p) return false;
          var solve = { heights: Uint16Array.from(p.solve.heights), width: p.solve.width, height: p.solve.height };
          var filaments = p.filaments.map(function (f) { return f.hex; });
          var thumbs = thumb ? { thumbnailPng: new Uint8Array(1), thumbnailSmallPng: new Uint8Array(1) } : {};
          var plan = HF.planTiles(solve.width, solve.height, o.widthMm, { x: bed, y: bed });
          if (plan && plan.tiles.length > 1) {
            plan.tiles.forEach(function (t) {
              var tag = '-r' + (t.row + 1) + 'c' + (t.col + 1);
              var m = HF.heightfieldToMesh(HF.tileSolve(solve, t), { layerH: p.layerH, widthMm: t.widthMm });
              if (!m.triangleCount) return;
              var members = HF3.u1Members(Object.assign({
                triangles: m.triangles, bands: p.bands, filaments: filaments, layerH: p.layerH,
                name: String(name || 'hueforge') + tag, sizeMm: m.sizeMm, bed: { x: bed, y: bed },
              }, thumbs));
              if (members) api.out.push({ tag: tag, members: membersOut(members) });
            });
            return true;
          }
          var mesh = HF.heightfieldToMesh(solve, { layerH: p.layerH, widthMm: o.widthMm, hang: o.hang, holeMm: o.holeMm, baseLayers: o.baseLayers });
          if (!mesh.triangleCount) return false;
          var members = HF3.u1Members(Object.assign({
            triangles: mesh.triangles, bands: p.bands, filaments: filaments, layerH: p.layerH,
            name: name, sizeMm: mesh.sizeMm, bed: { x: bed, y: bed },
          }, thumbs));
          if (members) api.out.push({ tag: null, members: membersOut(members) });
          return true;
        },
        flatPieces: function (name, o, thumb) {
          api.out = [];
          var f = S.flat;
          if (!f || !f.parts.length) return false;
          var built = FLAT.buildFlatParts({ labels: Array.from(f.labels), palette: f.palette, width: f.width, height: f.height },
                                          { widthMm: o.widthMm, heightMm: o.heightMm });
          if (!built || !built.parts.length) return false;
          var members = HF3.flatU1Members(Object.assign({
            parts: built.parts,
            filaments: (f.filaments && f.filaments.length) ? f.filaments : built.filaments,
            sizeMm: built.sizeMm, baseHead: Number.isInteger(f.baseHead) ? f.baseHead : built.baseHead,
            layerH: o.layerH, name: name, bed: { x: 270, y: 270 },
          }, thumb ? { thumbnailPng: new Uint8Array(1), thumbnailSmallPng: new Uint8Array(1) } : {}));
          if (members) api.out.push({ tag: null, members: membersOut(members) });
          return true;
        },
        stashStl: function (o) {
          api.stl = null;
          var p = S.paint;
          if (!p) return false;
          var mesh = HF.heightfieldToMesh(p.solve, { layerH: p.layerH, widthMm: o.widthMm, hang: o.hang, holeMm: o.holeMm, baseLayers: o.baseLayers });
          if (!mesh.triangleCount) return false;
          api.stl = latin1(HF.meshToStlBinary(mesh.triangles));
          return true;
        },
      };
      globalThis.__studio = api;
    })();
    """#
}
