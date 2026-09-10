import Foundation
import Testing
@testable import KhaytCore

/// The figures a printer reported, offered for the job about to be closed.
///
/// A printer's filament and duration counters are per-JOB and reset when the
/// next print begins, so "read them when the shop gets round to marking the
/// order done" is not a plan. Khayt freezes them on the edge out of printing
/// and persists them under `printerCompletions`; this app reads that.
///
/// Everything here is about NOT LYING with a confident number: the right job's
/// figures rather than the newest, one axis measured and the other not, and an
/// honest refusal when the measurement is too old to trust.
@Suite struct ActualsPrefillTests {

    /// The store's `printerCompletions`, as `completionsToPersist` writes it:
    /// machine id → a LIST of finished jobs, newest first. Not an object with a
    /// `completions` key — that is the in-memory cache entry, and the two are
    /// easy to confuse because `restoreCompletions` turns one into the other.
    static func saved(_ machineId: String, _ entries: [JSONValue]) -> JSONValue {
        .object([machineId: .array(entries)])
    }

    static func completion(at: Date, filename: String,
                           durationS: Double?, filamentG: Double?,
                           source: String = "moonraker") -> JSONValue {
        var actuals: [String: JSONValue] = ["source": .string(source)]
        if let durationS { actuals["durationS"] = .number(durationS) }
        if let filamentG { actuals["filamentGrams"] = .number(filamentG) }
        return .object([
            "at": .number(at.timeIntervalSince1970 * 1000),
            "filename": .string(filename),
            "actuals": .object(actuals),
        ])
    }

    @Test("a job's own figures, not the newest print's")
    func theRightJob() async throws {
        let engine = try KhaytEngine()
        let now = Date()
        // Two prints finished on one machine. The shop is closing the FIRST.
        let cache = Self.saved("M1", [
            Self.completion(at: now.addingTimeInterval(-600), filename: "lantern.gcode",
                            durationS: 3600, filamentG: 240),
            Self.completion(at: now.addingTimeInterval(-7200), filename: "falcon.gcode",
                            durationS: 86_000, filamentG: 226),
        ])
        let pre = try await engine.actualsPrefill(completions: cache, machineId: "M1",
                                                  filename: "falcon.gcode",
                                                  estimateHours: 18.6, estimateGrams: 197, now: now)
        #expect(pre.weightG == 226, "got the other print's filament")
        #expect(pre.measured)
        #expect(pre.filename == "falcon.gcode")
    }

    /// Without a filename there is no honest link, so the newest is offered —
    /// which is right when a shop closes a job as it finishes and wrong the
    /// moment two printers are busy. That is why the sheet shows the name.
    @Test("with no filename to match on, the newest is offered and named")
    func newestWhenUnmatched() async throws {
        let engine = try KhaytEngine()
        let now = Date()
        let cache = Self.saved("M1", [
            Self.completion(at: now.addingTimeInterval(-600), filename: "lantern.gcode",
                            durationS: 3600, filamentG: 240),
        ])
        let pre = try await engine.actualsPrefill(completions: cache, machineId: "M1",
                                                  filename: nil,
                                                  estimateHours: 18.6, estimateGrams: 197, now: now)
        #expect(pre.weightG == 240)
        #expect(pre.filename == "lantern.gcode", "the shop cannot tell which print this was")
    }

    /// PrusaLink reports a duration and no filament. Reporting the estimate as
    /// measured on the axis it never read would put a fabricated variance into
    /// every report that reads the source.
    @Test("one axis measured and one estimated is reported as exactly that")
    func mixedAnswer() async throws {
        let engine = try KhaytEngine()
        let now = Date()
        let cache = Self.saved("M1", [
            Self.completion(at: now.addingTimeInterval(-300), filename: "hood.gcode",
                            durationS: 7200, filamentG: nil, source: "prusalink"),
        ])
        let pre = try await engine.actualsPrefill(completions: cache, machineId: "M1",
                                                  filename: "hood.gcode",
                                                  estimateHours: 1.5, estimateGrams: 197, now: now)
        #expect(pre.timeMeasured, "a reported duration was not counted as measured")
        #expect(pre.timeH == 2)
        #expect(!pre.weightMeasured, "filament nobody reported was called a measurement")
        #expect(pre.weightG == 197, "the unmeasured axis should fall back to the estimate")
        #expect(pre.source == "prusalink")
    }

    /// A measurement older than the window is not offered. A shop that finished
    /// a print on Monday and closes the job on Thursday would otherwise be
    /// handed Monday's numbers under a confident label.
    @Test("a measurement too old to trust is refused, and says why")
    func tooOld() async throws {
        let engine = try KhaytEngine()
        let now = Date()
        let cache = Self.saved("M1", [
            Self.completion(at: now.addingTimeInterval(-60 * 60 * 96), filename: "hood.gcode",
                            durationS: 7200, filamentG: 200),
        ])
        let pre = try await engine.actualsPrefill(completions: cache, machineId: "M1",
                                                  filename: "hood.gcode",
                                                  estimateHours: 1.5, estimateGrams: 197, now: now)
        #expect(!pre.measured)
        #expect(pre.staleReason == "too-old")
        #expect(pre.timeH == 1.5, "the estimate is what is left when a measurement is refused")
    }

    /// The ordinary case for a shop with no printer linked, and for this app
    /// today: nothing at all, answered rather than thrown.
    @Test("an empty cache answers with the estimate rather than failing")
    func nothingKnown() async throws {
        let engine = try KhaytEngine()
        let pre = try await engine.actualsPrefill(completions: .object([:]), machineId: "M1",
                                                  filename: "hood.gcode",
                                                  estimateHours: 3, estimateGrams: 120, now: Date())
        #expect(!pre.measured)
        #expect(pre.staleReason == "nothing-measured")
        #expect(pre.timeH == 3)
        #expect(pre.weightG == 120)
    }

    /// A machine the shop has never polled must not be handed another
    /// machine's numbers.
    @Test("one machine's completions are not another's")
    func perMachine() async throws {
        let engine = try KhaytEngine()
        let now = Date()
        let cache = Self.saved("M1", [
            Self.completion(at: now.addingTimeInterval(-300), filename: "hood.gcode",
                            durationS: 7200, filamentG: 200),
        ])
        let pre = try await engine.actualsPrefill(completions: cache, machineId: "M2",
                                                  filename: "hood.gcode",
                                                  estimateHours: 3, estimateGrams: 120, now: now)
        #expect(!pre.measured, "M2 was handed M1's measurement")
    }
}
