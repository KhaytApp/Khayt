import Foundation
import KhaytCore

/// Measuring a model by asking a slicer, instead of parsing the mesh.
///
/// ── WHY ───────────────────────────────────────────────────────────────────
///
/// A library record carries a `geometryKey` — triangle count, volume, bounding
/// box — and getting it meant reading the mesh. `lib/mf-convert.js` does that
/// in Node with `Buffer`, and this shop's meshes run to 6.3 million facets and
/// 436 MB uncompressed, so porting it is a project.
///
/// Every slicer already does exactly this on load, and says so:
///
///     --info    Write information about the model to the console.
///
/// PrusaSlicer, OrcaSlicer and Snapmaker Orca all carry it. On this Mac it
/// answers in about six seconds for a 46 MB, 6.3-million-facet 3MF, and its
/// triangle count is EXACT against what Khayt computed for the same file —
/// 4,295,525 on this shop's Hulk helmet, to the triangle.
///
/// ── WHAT IT IS NOT ───────────────────────────────────────────────────────
///
/// Not the exact-duplicate check. That is `contentHash`, a SHA-256 of the
/// bytes, and `lib/model-identity.js` is explicit that the two are different
/// claims: the hash is "certain. Same file", and the geometry key is "a STRONG
/// HINT and nothing more". So a model measured this way is as identifiable as
/// one measured any other way, and the geometry only feeds the softer "this
/// looks like a part you already have".
///
/// Volume comes back within 0.0004% of Khayt's, and the bounding box differs by
/// convention — Khayt measures the raw mesh envelope, a slicer measures the
/// parts where they are placed. Both are defensible and they are not the same
/// number, so a key from here will not always match a key from there for a
/// multi-part model. That costs some fuzzy matching and no correctness.
enum ModelInfo {

    /// English, like the readers beside it — with one to fix when this is
    /// wired to a screen: `notAllowed` says the same thing as
    /// `mac.slicer_not_allowed`, which IS translated, and the shop should see
    /// that one rather than this.
    enum Failure: Error, CustomStringConvertible, Equatable {
        case notAllowed(String)
        case cannotMeasure(String)
        case tookTooLong(String)
        case saidNothingUseful(String)
        case failed(String)

        var description: String {
            switch self {
            case .notAllowed(let name):
                return "Khayt will not launch \(name): it does not look like a slicer."
            case .cannotMeasure(let name):
                return "\(name) cannot measure a model from the command line."
            case .tookTooLong(let name):
                return "\(name) did not finish measuring in time."
            case .saidNothingUseful(let name):
                return "\(name) did not report a triangle count or a volume."
            case .failed(let why):
                return "Measuring the model failed: \(why)"
            }
        }
    }

    /// What a slicer reports, summed over every object in the file.
    struct Geometry: Equatable, Sendable {
        let triangleCount: Int
        let volumeMm3: Double
        let x: Double, y: Double, z: Double
        /// How many objects the file turned out to hold. Not part of the key —
        /// kept because "20 objects" is the thing that explains a surprising
        /// bounding box, and a shop looking at one deserves the explanation.
        let objects: Int
    }

    /// Long enough for a mesh far larger than any this shop has, short enough
    /// that a slicer which opened its own window instead of answering does not
    /// sit there for ever. Six seconds is the measured cost of a 46 MB file.
    static let patience: TimeInterval = 180

    // MARK: - Reading what it said

    /// Parse `--info` output.
    ///
    /// PURE, and separated from the launching for that reason: everything that
    /// can be wrong about this — a file with twenty objects, a locale that
    /// writes decimals with a comma, a slicer that adds a field — is wrong in
    /// the text, and text is the thing a test can hold.
    ///
    /// A file with several objects prints one block per object. They are SUMMED
    /// for the count and the volume, and the bounding box is taken over all of
    /// them together, because a 3MF holding twenty parts is one model as far as
    /// a library record is concerned.
    static func parse(_ output: String) -> Geometry? {
        var triangles = 0
        var volume = 0.0
        var objects = 0
        var minX = Double.infinity, minY = Double.infinity, minZ = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity, maxZ = -Double.infinity
        var sawGeometry = false

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = line.trimmingCharacters(in: .whitespaces)
            // `[name]` opens each object's block.
            if text.hasPrefix("["), text.hasSuffix("]") { objects += 1; continue }
            guard let equals = text.firstIndex(of: "=") else { continue }
            let key = text[text.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            let rest = text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces)

            if key == "number_of_facets", let n = Int(rest) {
                triangles += n
                sawGeometry = true
                continue
            }
            // `Double(_:)` is locale-independent and that is what is wanted: the
            // slicer prints C-locale decimals whatever the Mac is set to, and a
            // reader that honoured the Mac's locale would read 117687.71 as
            // 11768771 in a country that groups with a full stop.
            guard let value = Double(rest) else { continue }
            switch key {
            case "volume": volume += value; sawGeometry = true
            case "min_x": minX = min(minX, value)
            case "min_y": minY = min(minY, value)
            case "min_z": minZ = min(minZ, value)
            case "max_x": maxX = max(maxX, value)
            case "max_y": maxY = max(maxY, value)
            case "max_z": maxZ = max(maxZ, value)
            default: break
            }
        }

        guard sawGeometry, triangles > 0, volume > 0 else { return nil }
        // A file that reported facets but no bounds is still measurable; the box
        // is zero rather than infinite, and `geometryKey` refuses it upstream.
        let span: (Double, Double) -> Double = { lo, hi in
            lo.isFinite && hi.isFinite ? max(0, hi - lo) : 0
        }
        return Geometry(triangleCount: triangles, volumeMm3: volume,
                        x: span(minX, maxX), y: span(minY, maxY), z: span(minZ, maxZ),
                        objects: max(objects, 1))
    }

    // MARK: - Asking

    /// Does this slicer answer `--info` at all?
    ///
    /// ASKED, not assumed from the name. Every slicer in the PrusaSlicer family
    /// carries the flag and the others may not, and a list of which is a second
    /// list of slicer names — the thing `isAllowedSlicerBinary` exists to avoid
    /// having two of. `--help` is cheap and it is the program's own answer.
    static func canMeasure(_ slicer: KhaytEngine.Slicer) -> Bool {
        guard let help = try? run(slicer.path, ["--help"], timeout: 20) else { return false }
        return help.contains("--info")
    }

    /// Measure a model. The caller has already asked the allowlist.
    static func measure(_ file: URL, with slicer: KhaytEngine.Slicer,
                        allowed: Bool, timeout: TimeInterval = patience) throws -> Geometry {
        guard allowed else { throw Failure.notAllowed(slicer.name) }
        guard canMeasure(slicer) else { throw Failure.cannotMeasure(slicer.name) }
        let output = try run(slicer.path, ["--info", file.path], timeout: timeout,
                             name: slicer.name)
        guard let geometry = parse(output) else { throw Failure.saidNothingUseful(slicer.name) }
        return geometry
    }

    /// Run it, bounded, with no shell anywhere.
    ///
    /// `Process` with an argument array — never a command string — so a file
    /// name with a space, a quote or a semicolon in it is one argument and not
    /// an instruction. The library is full of names like
    /// `Remb Studios - Articulated Forest Dragon - 3MF.3mf`.
    @discardableResult
    private static func run(_ path: String, _ arguments: [String],
                            timeout: TimeInterval, name: String = "") throws -> String {
        // Kept apart. A slicer writes warnings to stderr on files that load
        // perfectly well, and folding them into the output would have the
        // parser reading a warning's numbers as a model's. BOTH are drained
        // while it runs, and the deadline is enforced on the program — the
        // old loop read stdout to the end first, so a slicer that hung (or
        // filled stderr, which nobody read) hung the caller with it.
        let outcome: BoundedProcess.Outcome
        do { outcome = try BoundedProcess.run(path, arguments, timeout: timeout) }
        catch { throw Failure.failed(error.localizedDescription) }
        if outcome.timedOut { throw Failure.tookTooLong(name.isEmpty ? path : name) }
        return String(decoding: outcome.stdout, as: UTF8.self)
    }
}
