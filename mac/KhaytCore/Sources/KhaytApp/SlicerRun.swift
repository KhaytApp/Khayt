import Foundation
import KhaytCore

/// Slicing a model to find out what it really takes.
///
/// ── WHY A GUESS IS NOT ENOUGH ─────────────────────────────────────────────
///
/// `Mesh` measures a model's geometry and `lib/stl-estimate.js` turns that
/// into a weight and a time. It is an estimate and says so: scored against a
/// real slicer, geometry in this range lands between +58% and -66%.
///
/// Measured on the shop's own articulated dragon, 2026-09-16: the mesh is
/// 19.79 cm³, so about 24.5 g solid, and the estimator said 12.7 g. The
/// slicer said 57.18 g across four colours. The difference is purge — every
/// colour change on a toolchanger flushes filament, and geometry cannot know
/// that. No estimator ever will.
///
/// So where the shop has a slicer, ask it. This runs the shop's own slicer
/// with the shop's own argument template, reads the G-code it produced, and
/// takes the slicer's figures — the same thing `runSlice` in `main.js` does,
/// through the same shared rules, so the two apps cannot disagree about what
/// a model costs.
///
/// ── WHAT IS SHARED AND WHAT IS HERE ───────────────────────────────────────
///
/// Shared, because both are security decisions on untrusted settings: which
/// binaries may be launched (`isAllowedSlicerBinary`) and how the argument
/// template is split (`sliceArgv`). Here, because it is plumbing: spawning,
/// the temporary directory, the timeout, and finding the file afterwards.
enum SlicerRun {

    /// A slice takes real time on a real model. Three minutes is what
    /// `main.js` allows, and this matches it rather than inventing a second
    /// patience.
    static let patience: TimeInterval = 180

    /// How much of the G-code is read. The slicer writes its totals in the
    /// header and the footer; the middle is a million moves nobody needs.
    static let window = 65_536

    enum Failure: Error, CustomStringConvertible, Equatable {
        case notAllowed(String)
        case noSlicer
        case missingModel
        case producedNothing(String)
        case tookTooLong(String)
        case failed(String)

        var description: String {
            switch self {
            case .notAllowed(let name): "That program is not allowed as a slicer: \(name)"
            case .noSlicer: "No slicer is set up."
            case .missingModel: "That model file is not there."
            case .producedNothing(let why): "The slicer produced no G-code. \(why)"
            case .tookTooLong(let name): "\(name) took too long."
            case .failed(let why): why
            }
        }
    }

    /// What the slicer said about the model.
    struct Sliced: Sendable, Equatable {
        var grams: Double?
        var hours: Double?
        /// Whether the weight is the slicer's own or was derived from the
        /// volume it reported and the shop's density. Carried out so nothing
        /// downstream shows a derived figure as one the slicer stood behind.
        var weighedBySlicer = true
        var slicer: String?
        var material: String?
    }

    /// Slice `model`. The G-code lands wherever `argv` told the slicer to put
    /// it — the caller's own scratch directory, which the caller removes.
    ///
    /// `allowed` is the caller's answer from `isAllowedSlicerBinary`, asked
    /// through the engine — passed in rather than asked here so this stays
    /// free of the runtime and testable on its own.
    ///
    /// BLOCKING for as long as the slicer runs (up to `timeout`): a caller on
    /// the main actor goes through `Task.detached`.
    ///
    /// It used to make a scratch directory of its own and hand it back, but the
    /// slicer never wrote there — `argv` already named the caller's directory —
    /// and nobody removed it, so every customer upload left an empty
    /// `khayt-slice-…` folder behind in the temporary directory.
    static func slice(_ model: URL, with slicer: KhaytEngine.Slicer, argv: [String],
                      allowed: Bool, timeout: TimeInterval = patience) throws {
        guard allowed else { throw Failure.notAllowed(slicer.name) }
        guard !slicer.path.isEmpty, FileManager.default.isExecutableFile(atPath: slicer.path) else {
            throw Failure.noSlicer
        }
        guard FileManager.default.fileExists(atPath: model.path) else { throw Failure.missingModel }
        try run(slicer.path, argv, timeout: timeout, name: slicer.name)
    }

    /// A directory of our own to slice into, so nothing lands beside the model.
    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-slice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The G-code the slicer wrote: the name we asked for, else the newest one
    /// it chose for itself. Slicers rename output on their own more often than
    /// they admit, so "there is a .gcode in the directory" is the real test.
    static func gcode(in outDir: URL, expected: URL) -> URL? {
        if FileManager.default.fileExists(atPath: expected.path) { return expected }
        // Names, then rebuilt onto the caller's own base. `contentsOfDirectory`
        // hands back RESOLVED urls — the Mac's temporary directory is a symlink
        // into `/private`, so a url from the listing is not equal to one the
        // caller built even when both name the same file, and a caller
        // comparing them would quietly decide nothing was produced.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []
        guard let latest = names.filter({ $0.lowercased().hasSuffix(".gcode") }).sorted().last else {
            return nil
        }
        return outDir.appending(path: latest)
    }

    /// The head and the tail of a G-code file, which is where the totals are.
    ///
    /// Read as two windows rather than whole: a sliced plate is tens of
    /// megabytes of movement, and holding all of it to find two comment lines
    /// is how an app runs a shop's machine out of memory.
    static func totalsText(of gcode: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: gcode)
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: gcode.path))
            .flatMap { $0[.size] as? Int } ?? 0
        let head = try handle.read(upToCount: window) ?? Data()
        var tail = Data()
        if size > window {
            try handle.seek(toOffset: UInt64(max(0, size - window)))
            tail = try handle.readToEnd() ?? Data()
        }
        return String(decoding: head, as: UTF8.self) + "\n" + String(decoding: tail, as: UTF8.self)
    }

    /// Run it, bounded, with no shell anywhere.
    ///
    /// `Process` with an argument ARRAY — never a command string — so a file
    /// name with a space, a quote or a semicolon in it is one argument and not
    /// an instruction. The same reasoning as `ModelInfo.run`, and the same
    /// library full of names like `Remb Studios - Articulated Dragon.3mf`.
    private static func run(_ path: String, _ arguments: [String],
                            timeout: TimeInterval, name: String) throws {
        // Both pipes drained while it runs and the deadline enforced on the
        // slicer itself — see `BoundedProcess` for the hang this used to be.
        // The TAIL of stdout is kept: an Orca or Bambu Studio fork prints why
        // it failed there, as an `[error]` line ("File Version 2.3.0.4 not
        // supported by current cli version"), and its stderr is only a usage
        // dump. Which line is the reason is `lib/slicers.js`
        // `sliceFailureReason` (`KhaytEngine.sliceFailureReason`); both tails
        // travel in the failure so a caller with the engine can ask it.
        let outcome: BoundedProcess.Outcome
        do {
            outcome = try BoundedProcess.run(path, arguments, timeout: timeout,
                                             keepOut: 16 << 10, tailOut: true)
        } catch { throw Failure.failed(error.localizedDescription) }
        if outcome.timedOut { throw Failure.tookTooLong(name) }
        if outcome.status != 0 {
            let err = String(decoding: outcome.stderr.suffix(400), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let out = String(decoding: outcome.stdout.suffix(400), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let why = [err, out].filter { !$0.isEmpty }.joined(separator: "\n")
            throw Failure.producedNothing(why.isEmpty ? "exit \(outcome.status)" : why)
        }
    }
}
