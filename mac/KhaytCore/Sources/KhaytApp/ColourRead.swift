import Foundation
import KhaytCore

/// What a 3MF is printed in: the slots the print USES, read the way the
/// desktop reads them (`lib/thumbnail-extract.js` reader 2, #2500).
///
/// ── WHY THE PAINT HAS TO BE READ ─────────────────────────────────────────
///
/// An unsliced Orca/Bambu project names its colours in `project_settings`'
/// `filament_colour`, and that list is the printer's LOADED spools: a U1
/// project lists four whatever the model needs, and Turki's vegueta showed
/// eight dots for a print in five. Which slots the print really uses comes
/// from three places: each object's and part's extruder (`model_settings`),
/// height ranges (`layer_config_ranges.xml`), and the paint on the mesh. The
/// first two are config text; the paint is in the `.model` XML, encoded per
/// triangle, and only `lib/mf-mesh.js` decodes it. So the Mac hands the mesh
/// to that one codec (`StudioEngine.paintSlots`, the studio's own JavaScript
/// context, so seconds of decoding never hold the shop's engine) rather than
/// keeping a second decoder in Swift.
///
/// ── THE CHEAP CASE FIRST ─────────────────────────────────────────────────
///
/// Most models are not painted. The `.model` members are streamed and
/// searched for a paint attribute first; only a painted model has its mesh
/// read, bounded by the converter's paint budget (`Converter.paintInlineLimit`).
/// A painted model past it, or one that will not read, is `{unread:true}`, and
/// the rule then names no colours rather than the loaded list.
enum ColourRead {

    /// Whether any `.model` member carries paint. Nil when one cannot be read.
    nonisolated static func painted(_ entries: [Zip.Entry], in url: URL) -> Bool? {
        let needles: [[UInt8]] = [Array("paint_color=".utf8), Array("mmu_segmentation=".utf8)]
        let keep = needles.map(\.count).max()! - 1
        for entry in entries where entry.name.lowercased().hasSuffix(".model") {
            var found = false
            var carry: [UInt8] = []
            do {
                try Zip.stream(entry, in: url) { chunk in
                    var buffer = carry
                    buffer.append(contentsOf: chunk.bindMemory(to: UInt8.self))
                    if needles.contains(where: { contains(buffer, $0) }) { found = true; return false }
                    carry = Array(buffer.suffix(keep))
                    return true
                }
            } catch { return nil }
            if found { return true }
        }
        return false
    }

    /// `needle` anywhere in `hay`.
    nonisolated static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        let first = needle[0]
        var i = 0
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < needle.count && hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    /// The paint, as `colorsFromConfigs` takes it: `{slots:[]}` for an
    /// unpainted model, `{slots:[…]}` from the mesh, `{unread:true}` when a
    /// painted model's mesh could not be read.
    static func paint(_ url: URL, entries: [Zip.Entry], engine: KhaytEngine) async -> JSONValue {
        let unread: JSONValue = .object(["unread": .bool(true)])
        guard let isPainted = await PinWork.run({ painted(entries, in: url) }) else { return unread }
        guard isPainted else { return .object(["slots": .array([])]) }
        // On the studio's engine, not the shop's: seconds of decoding must not
        // hold the actor every screen's rules wait on.
        guard let studio = await Studio.engine(),
              let read = try? await Converter.describeOffMain(url, bindMeshes: true),
              let slots = try? await studio.paintSlots(read.described, meshes: read.meshes) else { return unread }
        return .object(["slots": .array(slots.map { .number(Double($0)) })])
    }

    /// The config texts a colour read and the print facts both take.
    struct Configs: Sendable {
        var sliceInfo = "", project = "", model = "", prusa = "", layerRanges = ""
        var isEmpty: Bool { sliceInfo.isEmpty && project.isEmpty && model.isEmpty && prusa.isEmpty }
    }

    nonisolated static func configs(_ entries: [Zip.Entry], in url: URL) -> Configs {
        func text(_ name: String) -> String {
            guard let e = entries.first(where: { $0.name.lowercased() == name.lowercased() }),
                  let d = try? Zip.data(of: e, in: url) else { return "" }
            return String(decoding: d, as: UTF8.self)
        }
        var c = Configs()
        c.sliceInfo = text("Metadata/slice_info.config")
        c.project = text("Metadata/project_settings.config")
        c.model = text("Metadata/model_settings.config")
        // Either spelling, depending on how old the PrusaSlicer was.
        c.prusa = text("Metadata/Slic3r_PE.config")
        if c.prusa.isEmpty { c.prusa = text("Metadata/Prusa_Slicer.config") }
        c.layerRanges = text("Metadata/layer_config_ranges.xml")
        return c
    }

    /// A 3MF's colours, under reader 2: the configs and the paint.
    static func colours(_ url: URL, entries: [Zip.Entry], engine: KhaytEngine) async -> KhaytEngine.Colours? {
        let c = await PinWork.run { configs(entries, in: url) }
        // A sliced file names its colours from the slice; the paint is not needed.
        let paint: JSONValue = c.sliceInfo.isEmpty
            ? await paint(url, entries: entries, engine: engine)
            : .object(["slots": .array([])])
        return try? await engine.coloursFromConfigs(
            sliceInfo: c.sliceInfo, projectSettings: c.project, modelSettings: c.model,
            prusa: c.prusa, layerRanges: c.layerRanges, paint: paint)
    }

    /// The slots an unsliced project uses, for `printFacts`' materials. Nil
    /// when they cannot be named (painted and unread): the facts then list
    /// what the file says, as before.
    static func usedSlots(_ url: URL, entries: [Zip.Entry], configs c: Configs,
                          engine: KhaytEngine) async -> [Int]? {
        guard c.sliceInfo.isEmpty, !c.project.isEmpty else { return nil }
        guard case .object(let p) = await paint(url, entries: entries, engine: engine),
              case .array(let raw)? = p["slots"] else { return nil }
        let painted = raw.compactMap { v -> Int? in if case .number(let n) = v { return Int(n) } else { return nil } }
        guard let slots = try? await engine.usedSlots(modelSettings: c.model, layerRanges: c.layerRanges,
                                                      paintSlots: painted), !slots.isEmpty else { return nil }
        return slots
    }
}
