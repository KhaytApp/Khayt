import SwiftUI
import KhaytCore

/// The checks a file gets against its printer before it goes (C8; Figma
/// Qqxg4imtKVgC3TfNGcRGOk, page 23, frames 1 and 1b).
///
/// The findings are the shared rule's (`lib/send-checks.js`, through
/// `KhaytEngine.sendChecks`): a `block` holds the send, a `warn` is said and
/// the button becomes "Send anyway", an `info` is a head the printer did not
/// report, which is never counted as a mismatch. This file reads the part of
/// the file the rule needs and says each finding in the shop's language.
@MainActor
enum SendChecks {

    /// How much of each end of a G-code file is read: slicers write their
    /// comments in the first lines and in a block at the very end.
    nonisolated static let headBytes = 256 * 1024
    nonisolated static let tailBytes = 768 * 1024

    /// The file's comment text, or nil when it is not plain G-code (a
    /// `.gcode.3mf` is a zip) or cannot be read. Off the main thread.
    nonisolated static func gcodeText(_ url: URL) async -> String? {
        let name = url.lastPathComponent.lowercased()
        guard name.hasSuffix(".gcode") || name.hasSuffix(".gco") || name.hasSuffix(".g") else { return nil }
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(returning: read(url))
            }
        }
    }

    /// A file up to this size is read whole, so its bed fit can be judged from
    /// the moves when its slicer wrote no object list. The reader takes 8 MB
    /// in about 70 ms; larger files are read at both ends only.
    nonisolated static let wholeBytes = 32 * 1024 * 1024

    /// The file's text and whether it is all of it.
    nonisolated static func gcode(_ url: URL) async -> (text: String, whole: Bool)? {
        let name = url.lastPathComponent.lowercased()
        guard name.hasSuffix(".gcode") || name.hasSuffix(".gco") || name.hasSuffix(".g") else { return nil }
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
                if size <= wholeBytes, let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                    done.resume(returning: (String(decoding: data, as: UTF8.self), true))
                } else if let text = read(url) {
                    done.resume(returning: (text, false))
                } else {
                    done.resume(returning: nil)
                }
            }
        }
    }

    /// The frame's green first row: the models were measured from the
    /// slicer's own outlines and no bed finding was raised.
    static func fitsLine(_ check: KhaytEngine.SendCheck, bed: KhaytEngine.SendFinding.Size?, words: Words) -> Line? {
        guard check.boundsSource == "placed-extents", let b = check.bounds, let bed,
              let bw = bed.x, let bd = bed.y, bw > 0, bd > 0, b.x != nil, b.y != nil,
              !check.findings.contains(where: { $0.code.hasPrefix("bed-") }) else { return nil }
        return Line(title: words.callIt("mac.sc_bed_fits", [
            "w": .string(mm(b.x, words)), "d": .string(mm(b.y, words)),
            "bw": .string(mm(bw, words)), "bd": .string(mm(bd, words))]))
    }

    nonisolated static func read(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: 0)
        if size <= UInt64(headBytes + tailBytes) {
            guard let all = try? handle.readToEnd() else { return nil }
            return String(decoding: all, as: UTF8.self)
        }
        guard let head = try? handle.read(upToCount: headBytes) else { return nil }
        try? handle.seek(toOffset: size - UInt64(tailBytes))
        guard let tail = try? handle.readToEnd() else { return nil }
        // A line cut in half at either join is a comment the reader skips.
        return String(decoding: head, as: UTF8.self) + "\n" + String(decoding: tail, as: UTF8.self)
    }

    /// One finding as the sheet says it: a line, and what to do about it.
    struct Line: Equatable {
        let title: String
        var hint: String?
    }

    static func mm(_ v: Double?, _ words: Words) -> String { words.numeral(Int((v ?? 0).rounded())) }

    /// "PETG White": the material, and the colour as written (a hex).
    nonisolated static func loadedWord(_ have: KhaytEngine.SendFinding.Have) -> String {
        [have.material, have.colour].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    nonisolated static func wantWord(_ want: KhaytEngine.SendFinding.Want?) -> String {
        [want?.type, want?.colour].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The sentence for a finding. `printer` is the machine's name; `bounds`
    /// and `bed` are what the rule was given, for the sizes it compares.
    static func line(_ f: KhaytEngine.SendFinding, printer: String, bounds: KhaytEngine.SendFinding.Size?,
                     bed: KhaytEngine.SendFinding.Size?, words: Words) -> Line? {
        let tool = JSONValue.string(words.numeral(f.slot ?? 0))
        switch f.code {
        case "bed-footprint":
            return Line(title: words.callIt("mac.sc_bed_footprint", [
                "w": .string(mm(bounds?.x, words)), "d": .string(mm(bounds?.y, words)),
                "bw": .string(mm(bed?.x, words)), "bd": .string(mm(bed?.y, words))]),
                        hint: words.callIt("mac.sc_bed_hint", ["name": .string(printer)]))
        case "bed-height":
            return Line(title: words.callIt("mac.sc_bed_height", [
                "h": .string(mm(bounds?.z, words)), "bh": .string(mm(bed?.z, words))]),
                        hint: words.callIt("mac.sc_bed_hint", ["name": .string(printer)]))
        case "bed-rotate":
            return Line(title: words.callIt("mac.sc_bed_rotate"), hint: words.callIt("mac.sc_bed_rotate_hint"))
        case "sliced-for-other":
            if let model = f.model, !model.isEmpty {
                return Line(title: words.callIt("mac.sc_sliced_for", ["model": .string(model)]),
                            hint: words.callIt("mac.sc_sliced_hint", ["name": .string(printer)]))
            }
            return Line(title: words.callIt("mac.sc_sliced_bed", [
                "w": .string(mm(f.bed?.x, words)), "d": .string(mm(f.bed?.y, words))]),
                        hint: words.callIt("mac.sc_sliced_hint", ["name": .string(printer)]))
        case "material-mismatch":
            let want = wantWord(f.want)
            guard let have = f.have else {
                return Line(title: words.callIt("mac.sc_no_such_tool", ["n": tool, "want": .string(want)]),
                            hint: words.callIt("mac.sc_sliced_hint", ["name": .string(printer)]))
            }
            return Line(title: words.callIt("mac.sc_material", ["n": tool, "have": .string(loadedWord(have)), "want": .string(want)]),
                        hint: words.callIt("mac.sc_load_hint", ["n": tool, "want": .string(want)]))
        case "colour-far":
            let want = wantWord(f.want)
            return Line(title: words.callIt("mac.sc_colour", ["n": tool, "have": .string(f.have.map(loadedWord) ?? ""), "want": .string(want)]),
                        hint: words.callIt("mac.sc_load_hint", ["n": tool, "want": .string(want)]))
        case "head-not-reported":
            return Line(title: words.callIt("mac.sc_not_reported", ["n": tool]), hint: words.callIt("mac.sc_not_checked"))
        default:
            // `type-unsupported` is the sheet's own refusal line (the upload
            // rule's reason), and a code this build does not know says nothing.
            return nil
        }
    }

    /// Whether any finding holds the send.
    nonisolated static func holds(_ findings: [KhaytEngine.SendFinding]) -> Bool { findings.contains(where: \.blocks) }

    /// Whether the button should read "Send anyway": something to look at,
    /// and nothing holding the send.
    nonisolated static func asksAnyway(_ findings: [KhaytEngine.SendFinding]) -> Bool {
        !holds(findings) && findings.contains { $0.severity == "warn" }
    }
}

/// The rows, under "Checked against this printer".
struct SendChecksRows: View {
    let findings: [KhaytEngine.SendFinding]
    /// The model fits the bed and was measured: the frame's green first row.
    let fits: SendChecks.Line?
    let printer: String
    let bounds: KhaytEngine.SendFinding.Size?
    let bed: KhaytEngine.SendFinding.Size?
    let words: Words

    var body: some View {
        let lines = findings.compactMap { f in
            SendChecks.line(f, printer: printer, bounds: bounds, bed: bed, words: words).map { (f, $0) }
        }
        if fits != nil || !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(words.callIt("mac.sc_title")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let fits { row(symbol: "checkmark.circle.fill", tint: Khayt.done, fits) }
                ForEach(lines, id: \.0.id) { f, line in
                    row(symbol: Self.symbol(f.severity), tint: Self.tint(f.severity), line)
                }
            }
        }
    }

    static func symbol(_ severity: String) -> String {
        switch severity {
        case "block": "xmark.octagon.fill"
        case "warn": "exclamationmark.triangle.fill"
        default: "questionmark.circle"
        }
    }

    static func tint(_ severity: String) -> Color {
        switch severity {
        case "block": Khayt.late
        case "warn": Khayt.attention
        default: .secondary
        }
    }

    private func row(symbol: String, tint: Color, _ line: SendChecks.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let hint = line.hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
