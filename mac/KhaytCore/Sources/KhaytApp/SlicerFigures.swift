import Foundation
import KhaytCore

/// What the slicer said a print file will take, read off the file — so a
/// model's weight, time and material come from the slicer that made it, not
/// from a guess at its shape.
///
/// Reported by the shop (Sep 2026): "I just tried it but it didn't get the
/// info from the file". A Snapmaker U1 3MF said 4 h 37 min; the catalogue got
/// 0.97 h, a geometry estimate, because the Mac never read the slicer's own
/// figures at import. The parsing is the shared rule's (`slicerFigures`).
enum SlicerFigures {
    /// G-code summaries sit at the head (Bambu/Orca) or the tail (Prusa and
    /// friends), so both ends are read — the same windows the other app reads.
    static let head = 32 * 1024
    static let tail = 64 * 1024
    /// A slicer config is a few kilobytes; anything past this is not one.
    static let configLimit = 4 << 20

    /// The `parsed` fields for this file, or nil when it carries none.
    static func read(_ url: URL, engine: KhaytEngine) async -> [String: JSONValue]? {
        // The configs first; the embedded G-code only if they said nothing.
        if let found = await read(url, engine: engine, wantGcode: false) { return found }
        guard url.pathExtension.lowercased() == "3mf" else { return nil }
        return await read(url, engine: engine, wantGcode: true)
    }

    private static func read(_ url: URL, engine: KhaytEngine, wantGcode: Bool) async -> [String: JSONValue]? {
        let ext = url.pathExtension.lowercased()
        let bits: (configs: [String: String], gcode: String?)? = await Task.detached {
            if ext == "gcode" || ext == "gco" { return ([:], ends(of: url)) }
            guard ext == "3mf", let entries = try? Zip.entries(of: url) else { return nil }
            var configs: [String: String] = [:]
            for e in entries where e.name.lowercased().hasPrefix("metadata/")
                && (e.name.lowercased().hasSuffix(".config") || e.name.lowercased().hasSuffix(".txt")) {
                if let d = try? Zip.data(of: e, in: url, limit: configLimit) {
                    configs[e.name] = String(decoding: d, as: UTF8.self)
                }
            }
            // A 3MF that carries its sliced G-code: its summary, head and tail —
            // read only when the configs cannot answer (see below), because
            // streaming a whole embedded G-code for a figure `slice_info`
            // already holds cost every launch of a big library dearly.
            var gcode: String?
            if !configs.isEmpty, !wantGcode { return (configs, nil) }
            if let g = entries.first(where: { $0.name.lowercased().hasSuffix(".gcode") }) {
                var first = Data(), last = Data()
                try? Zip.stream(g, in: url) { chunk in
                    if first.count < head { first.append(contentsOf: chunk.prefix(head - first.count)) }
                    last.append(contentsOf: chunk)
                    if last.count > tail * 2 { last = last.suffix(tail) }
                    return true
                }
                gcode = String(decoding: first, as: UTF8.self) + "\n" + String(decoding: last.suffix(tail), as: UTF8.self)
            }
            return (configs, gcode)
        }.value
        guard let bits else { return nil }
        return try? await engine.slicerFigures(configs: bits.configs, gcodeText: bits.gcode)
    }

    /// The first and last kilobytes of a G-code file, as text.
    nonisolated static func ends(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: 0)
        if size <= UInt64(head + tail) {
            return (try? h.readToEnd()).map { String(decoding: $0, as: UTF8.self) }
        }
        let first = (try? h.read(upToCount: head)) ?? Data()
        try? h.seek(toOffset: size - UInt64(tail))
        let last = (try? h.read(upToCount: tail)) ?? Data()
        return String(decoding: first, as: UTF8.self) + "\n" + String(decoding: last, as: UTF8.self)
    }
}
