import Foundation
import KhaytCore

/// What a 3MF is printed in: the slots the print USES, read the way the
/// desktop reads them (`lib/thumbnail-extract.js` reader 2, #2500; reader 3
/// for the stub-slice fix).
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
/// read, one member at a time (`slotsByMember`), each bounded by the
/// converter's paint budget (`Converter.paintInlineLimit`).
/// A painted model past it, or one that will not read, is `{unread:true}`, and
/// the rule then names no colours rather than the loaded list.
enum ColourRead {

    /// How much `.model` text the paint check inflates, over every member of
    /// one file together. A file that would take more is not scanned on: it
    /// is "unread", and the rule then names no colours rather than guess. A
    /// zip can point many entries at the same data, so a cap per member is no
    /// cap at all (beta.38 review).
    nonisolated(unsafe) static var scanBudget = 1 << 30

    /// Whether any `.model` member carries paint. Nil when one cannot be read,
    /// or the scan would pass `scanBudget`.
    nonisolated static func painted(_ entries: [Zip.Entry], in url: URL) -> Bool? {
        let needles: [[UInt8]] = [Array("paint_color=".utf8), Array("mmu_segmentation=".utf8)]
        let keep = needles.map(\.count).max()! - 1
        var left = scanBudget
        for entry in entries where entry.name.lowercased().hasSuffix(".model") {
            guard left > 0 else { return nil }
            var found = false
            var carry: [UInt8] = []
            var seen = 0
            do {
                try Zip.stream(entry, in: url, totalLimit: left) { chunk in
                    seen += chunk.count
                    var buffer = carry
                    buffer.append(contentsOf: chunk.bindMemory(to: UInt8.self))
                    if needles.contains(where: { contains(buffer, $0) }) { found = true; return false }
                    carry = Array(buffer.suffix(keep))
                    return true
                }
            } catch { return nil }
            if found { return true }
            left -= seen
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
    ///
    /// An unread answer past this Mac's budget also says so (`overBudget`,
    /// the budget in bytes): a Mac with more memory can read it, and the
    /// re-read records it for one (`ColoursReread`). `studio` is the engine to
    /// decode on; nil is the studio's shared one.
    static func paint(_ url: URL, entries: [Zip.Entry], engine: KhaytEngine,
                      studio given: StudioEngine? = nil) async -> JSONValue {
        let unread: JSONValue = .object(["unread": .bool(true)])
        let overBudget: JSONValue = .object(["unread": .bool(true),
                                             "overBudget": .number(Double(Converter.paintInlineLimit))])
        guard let isPainted = await PinWork.run({ painted(entries, in: url) }) else { return unread }
        guard isPainted else { return .object(["slots": .array([])]) }
        // On the studio's engine, not the shop's: seconds of decoding must not
        // hold the actor every screen's rules wait on.
        guard let studio = await Self.studioOr(given) else { return unread }
        let slots: [Int]?
        if entries.contains(where: { $0.name.lowercased().hasSuffix("slic3r_pe_model.config") }) {
            // A PrusaSlicer multi-volume project: its paint is worked out
            // across members, so it is read whole or not at all.
            let read: (entries: [Zip.Entry], described: [JSONValue], meshes: [String: String])
            do { read = try await Converter.describeOffMain(url, bindMeshes: true) }
            catch Converter.Failure.meshTooBig { return overBudget }
            catch { return unread }
            slots = try? await studio.paintSlots(read.described, meshes: read.meshes)
        } else {
            if Self.pastBudget(entries) { return overBudget }
            slots = await slotsByMember(url, entries: entries, studio: studio)
        }
        guard let slots else { return unread }
        return .object(["slots": .array(slots.map { .number(Double($0)) })])
    }

    private static func studioOr(_ given: StudioEngine?) async -> StudioEngine? {
        if let given { return given }
        return await Studio.engine()
    }

    /// Whether `slotsByMember` would refuse this file on size: a member past
    /// `memberLimit`, or all of them past `totalLimit`, each counted at the
    /// larger of its two sizes.
    nonisolated static func pastBudget(_ entries: [Zip.Entry],
                                       memberLimit: Int = Converter.paintInlineLimit,
                                       totalLimit: Int = Converter.rebuildLimit) -> Bool {
        var total = 0
        for entry in entries where entry.name.lowercased().hasSuffix(".model") {
            let cost = max(entry.size, entry.compressedSize)
            if cost > memberLimit { return true }
            total = total > Int.max - cost ? Int.max : total + cost
            if total > totalLimit { return true }
        }
        return false
    }

    /// The painted slots, read one `.model` member at a time.
    ///
    /// ── WHY NOT THE WHOLE FILE ───────────────────────────────────────────────
    ///
    /// Read whole, every member's XML is in memory together, and the budget
    /// (`Converter.paintInlineLimit`, about 900 MB on a 32 GB Mac) is on their
    /// SUM. A painted project of nineteen parts held 1.3 GB and was refused:
    /// 7 of one shop's 662 local 3MFs kept the wrong dots after beta.39. Which
    /// slots a print uses needs a few numbers per object, not the geometry, so
    /// each member is read, digested (`StudioEngine.paintDigest`) and let go,
    /// and the budget is now on the LARGEST member. The digests are resolved
    /// by one rule (`lib/mf-mesh.js slotsUsedFromDigests`), proven to name the
    /// slots the whole-file read names.
    ///
    /// Nil when a member is past the budget, will not come out as text, or
    /// the rule cannot tell (past the triangle cap).
    ///
    /// `memberLimit` and `totalLimit` are parameters so a test can prove the
    /// refusals without writing gigabytes or touching the shared budgets.
    /// The total is what `Converter.describe` allows a whole file
    /// (`rebuildLimit`): a zip can point many entries at the same bytes, so a
    /// cap per member alone would bound the memory and not the work.
    static func slotsByMember(_ url: URL, entries: [Zip.Entry], studio: StudioEngine,
                              memberLimit: Int = Converter.paintInlineLimit,
                              totalLimit: Int = Converter.rebuildLimit) async -> [Int]? {
        var digests: [JSONValue] = []
        var total = 0
        for entry in entries where entry.name.lowercased().hasSuffix(".model") {
            // What a member COSTS is the larger of the two sizes its
            // directory entry claims, not the declared one alone: a stored
            // member is read at its compressed size whatever it declares, so
            // an entry saying "1 byte" over 20 MB of data, a thousand times
            // at one offset, passed every budget and was read in full
            // (beta.40 pre-release review).
            let cost = max(entry.size, entry.compressedSize)
            guard cost <= memberLimit else { return nil }
            total = total > Int.max - cost ? Int.max : total + cost
            guard total <= totalLimit else { return nil }
            let text: String? = await PinWork.run {
                // `Zip.data` refuses on either size too, before reading.
                guard let data = try? Zip.data(of: entry, in: url, limit: memberLimit) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            guard let text, let digest = try? await studio.paintDigest(name: entry.name, mesh: text) else { return nil }
            digests.append(digest)
        }
        let settings: String = await PinWork.run {
            guard let e = entries.first(where: { ($0.name.lowercased().split(separator: "/").last ?? "") == "model_settings.config" }),
                  let d = try? Zip.data(of: e, in: url) else { return "" }
            return String(decoding: d, as: UTF8.self)
        }
        return (try? await studio.paintSlots(digests: digests, modelSettings: settings)) ?? nil
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

    /// A 3MF's colours, under today's reader: the configs and the paint.
    static func colours(_ url: URL, entries: [Zip.Entry], engine: KhaytEngine) async -> KhaytEngine.Colours? {
        await read(url, entries: entries, engine: engine)?.colours
    }

    /// What a colour read found, and whether the paint was left unread.
    struct Read: Sendable {
        var colours: KhaytEngine.Colours
        /// The paint was painted and could not be read (the rule then names
        /// no colours).
        var paintUnread = false
        /// …because a model file was past this Mac's budget, in bytes.
        var overBudget: Int?
    }

    /// The same read, saying why the paint was not read where it was not.
    static func read(_ url: URL, entries: [Zip.Entry], engine: KhaytEngine,
                     studio: StudioEngine? = nil) async -> Read? {
        let c = await PinWork.run { configs(entries, in: url) }
        // A sliced file names its colours from the slice; the paint is not needed.
        if let sliced = await slice(c, engine: engine) { return Read(colours: sliced) }
        let paint = await paint(url, entries: entries, engine: engine, studio: studio)
        guard let colours = try? await engine.coloursFromConfigs(
            sliceInfo: c.sliceInfo, projectSettings: c.project, modelSettings: c.model,
            prusa: c.prusa, layerRanges: c.layerRanges, paint: paint) else { return nil }
        var out = Read(colours: colours)
        if case .object(let p) = paint, p["unread"] == .bool(true) {
            out.paintUnread = true
            if case .number(let b)? = p["overBudget"] { out.overBudget = Int(b) }
        }
        return out
    }

    /// The colours a SLICE names, or nil when the file is not sliced.
    ///
    /// Asked of the rule, not read off whether `slice_info.config` exists: an
    /// unsliced Orca/Bambu project carries one too, a stub with a header and
    /// no `<filament>`. Beta.38 took the stub for a slice and skipped the
    /// paint, so a painted model kept only its base filament: one dot for a
    /// print in five, on 206 of the shop's 660 local 3MFs (reader 3). The rule
    /// says a file is sliced when the slice names a filament it printed
    /// (`swapsKnown`), and that is the answer used here.
    static func slice(_ c: Configs, engine: KhaytEngine) async -> KhaytEngine.Colours? {
        guard !c.sliceInfo.isEmpty,
              let read = try? await engine.coloursFromConfigs(
                sliceInfo: c.sliceInfo, projectSettings: c.project, modelSettings: c.model,
                prusa: c.prusa, layerRanges: c.layerRanges, paint: .object(["slots": .array([])])),
              read.swapsKnown == true else { return nil }
        return read
    }

    /// The slots an unsliced project uses, for `printFacts`' materials. Nil
    /// when they cannot be named (painted and unread): the facts then list
    /// what the file says, as before.
    static func usedSlots(_ url: URL, entries: [Zip.Entry], configs c: Configs,
                          engine: KhaytEngine) async -> [Int]? {
        guard !c.project.isEmpty, await slice(c, engine: engine) == nil else { return nil }
        guard case .object(let p) = await paint(url, entries: entries, engine: engine),
              case .array(let raw)? = p["slots"] else { return nil }
        let painted = raw.compactMap { v -> Int? in if case .number(let n) = v { return Int(n) } else { return nil } }
        guard let slots = try? await engine.usedSlots(modelSettings: c.model, layerRanges: c.layerRanges,
                                                      paintSlots: painted), !slots.isEmpty else { return nil }
        return slots
    }
}
