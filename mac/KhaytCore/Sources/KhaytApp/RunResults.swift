import Foundation
import KhaytCore

/// One result for each print run: finished, failed or cancelled (P4,
/// `lib/run-result.js`). When a print ends on a job the book names, the
/// printer's word for how it ended is written on that run, ONCE: a second
/// poll, a restart, or the desktop finding the same completion change
/// nothing, and a mark the shop made itself is never replaced.
extension Shop {

    /// The printer's results a run can carry.
    nonisolated static let runResults: Set<String> = ["finished", "failed", "cancelled"]

    /// How this print ended, for the run's record. The shared rule is asked
    /// first, with the state and fault the printer last gave, so a Bambu print
    /// the shop cancelled is `cancelled` and not a failure against the
    /// printer. When it does not say, what Khayt saw (`ended.outcome`) stands,
    /// if that is one of the three; "unknown" records nothing.
    func runResult(for ended: FinishCamera.Ended) async -> String? {
        var state: String?, fault: String?
        if case .object(let live)? = printers.statusCache[ended.machineId] {
            if case .string(let s)? = live["state"] { state = s }
            if case .string(let f)? = live["fault"] { fault = f }
        }
        if let engine, let said = try? await engine.printEndedAs(state: state, fault: fault) {
            // The rule's word wins only when it turns a failure into a cancel
            // or agrees: an idle printer says nothing about the print before.
            if said == "cancelled" || said == ended.outcome { return said }
        }
        return Self.runResults.contains(ended.outcome) ? ended.outcome : nil
    }

    /// Write the result on the run it belongs to. False when nothing was
    /// written.
    @discardableResult
    func noteRunResult(_ ended: FinishCamera.Ended) async -> Bool {
        guard let jobId = ended.orderId, let result = await runResult(for: ended) else { return false }
        return await writeRunResult(jobId: jobId, machineId: ended.machineId, at: ended.finishedAt ?? Date(), result: result)
    }

    @discardableResult
    func writeRunResult(jobId: String, machineId: String, at: Date, result: String) async -> Bool {
        guard let engine, let build = source.build, canWrite,
              let row = orderRows.first(where: { Self.recordId($0) == jobId }),
              case .array(let runs)? = try? await engine.runsWithResult(order: row, machineId: machineId, at: at,
                                                                         result: result, source: "printer") else { return false }
        let asked: JSONValue? = { if case .object(let o) = row { return o["printRuns"] }; return nil }()
        // lock: system — the printer said how its own run ended, as the poll's completion record does
        let wrote = (try? await StoreWriter.updateRecordOffMain(build, collection: "printLog", id: jobId) { job -> Bool in
            // Only onto the runs the rule was asked about: if the other app
            // wrote meanwhile, the next completion is asked again instead.
            guard job["printRuns"] == asked else { return false }
            job["printRuns"] = .array(runs)
            return true
        }) ?? nil
        guard wrote == true else { return false }
        await load(source)
        return true
    }
}
