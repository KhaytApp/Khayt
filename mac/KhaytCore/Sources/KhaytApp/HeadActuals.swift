import Foundation
import KhaytCore

/// Filament used per head, for a print a Snapmaker U1 just finished (U1 idea
/// 4; `lib/printer-actuals.js perHeadActuals` and `perHeadPatch`).
///
/// The printer's history holds the slicer's grams per head and the measured
/// total. The shared rule splits the measured total across the heads in
/// proportion to their estimates and says so (`basis: proportional`): no head's
/// figure is called measured on its own. The Mac only fetches the history (a
/// read) and writes what the rule returns.
///
/// ── ONE RECORD PER PRINT ─────────────────────────────────────────────────
///
/// The printer's own job id is the key (`actualHeadsJobId`). A job that
/// already holds a split is left alone, whether this Mac, the desktop or a
/// second look wrote it, so a print is never counted twice.
@MainActor
enum HeadActuals {
    /// When to look after a print finishes: history is written as it ends.
    static let tries: [Duration] = [.seconds(20), .seconds(90)]
    static let historyLimit = 5
    /// How far the history row's end may be from when Khayt saw the print
    /// end. An older run of the same file is not this print.
    static let window: TimeInterval = 20 * 60

    /// The history row for the print that just ended under `filename`: the
    /// newest completed run of that file that ended near `endedAt`.
    static func job(in history: [String: JSONValue], filename: String, endedAt: Date) -> JSONValue? {
        guard case .object(let result)? = history["result"], case .array(let jobs)? = result["jobs"] else { return nil }
        return jobs.first { row in
            guard case .object(let o) = row, o["filename"] == .string(filename), o["status"] == .string("completed"),
                  case .number(let end)? = o["end_time"] else { return false }
            return abs(end - endedAt.timeIntervalSince1970) <= window
        }
    }
}

extension Shop {

    /// After a finished Moonraker print on a job the book names: read how
    /// much each head used and note it on the job. Best-effort and silent: a
    /// printer whose history does not say per head simply has none.
    func noteHeadActuals(_ ended: FinishCamera.Ended, machine: Machine) async {
        guard ended.outcome == "finished", let jobId = ended.orderId, !ended.filename.isEmpty,
              machine.printerApi?.type == "moonraker", let engine else { return }
        let endedAt = ended.finishedAt ?? Date()
        for wait in HeadActuals.tries {
            try? await Task.sleep(for: wait)
            if Task.isCancelled { return }
            guard source.build != nil, canWrite,
                  case .object(let row)? = orderRows.first(where: { Self.recordId($0) == jobId }) else { return }
            if row["actualHeadsJobId"] != nil { return }
            guard let current = machines.first(where: { $0.id == machine.id }),
                  let base = try? await PrinterWatch.baseURL(current, engine: engine) else { return }
            var key = ""
            if let sealed = current.printerApi?.apiKey, !sealed.isEmpty, let build = source.build {
                key = (try? await Secrets.open(sealed, for: build)) ?? ""
            }
            guard let history = try? await PrinterWatch.get(base, path: "/server/history/list?limit=\(HeadActuals.historyLimit)",
                                                            key: key, type: "moonraker", timeout: 10),
                  let job = HeadActuals.job(in: history, filename: ended.filename, endedAt: endedAt) else { continue }
            _ = await writeHeadActuals(historyJob: job, jobId: jobId)
            return
        }
    }

    /// Put the rule's split on the job, through the write chain. False when
    /// nothing was written: the history says nothing per head, the job
    /// already holds a split, or this Mac may not write.
    @discardableResult
    func writeHeadActuals(historyJob: JSONValue, jobId: String) async -> Bool {
        // THE PRINTER'S OWN RECORD, NOT A PERSON'S EDIT. This runs after a
        // print ends, with whoever is or is not at the Mac: asked as a
        // person's edit it was refused whenever the lock was on and nobody
        // was signed in, which is how this Mac starts, and an overnight
        // print's figures were dropped for good (the tries end after two
        // minutes). The lock gates people, not the bookkeeping.
        guard let engine, let build = source.build, canWrite, permitted(.system("the printer's own record")),
              let row = orderRows.first(where: { Self.recordId($0) == jobId }),
              case .object(let patch)? = try? await engine.perHeadPatch(order: row, historyJob: historyJob) else { return false }
        let wrote = (try? await StoreWriter.updateRecordOffMain(build, collection: "printLog", id: jobId) { job -> Bool in
            // Asked again on the record as it is on disk: the other app may
            // have written this print's split since the rule was asked.
            guard job["actualHeadsJobId"] == nil else { return false }
            for (key, value) in patch where Self.headActualKeys.contains(key) { job[key] = value }
            return true
        }) ?? nil
        guard wrote == true else { return false }
        await load(source)
        return true
    }

    /// The only keys a split writes.
    nonisolated static let headActualKeys: Set<String> = ["actualHeads", "actualHeadsJobId", "actualHeadsBasis"]
}
