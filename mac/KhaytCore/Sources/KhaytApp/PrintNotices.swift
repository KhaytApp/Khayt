import Foundation
import KhaytCore

/// The print notifications the Mac did not send yet: a print FINISHED, a print
/// FAILED, a print PAUSED.
///
/// ── WHAT WAS ALREADY THERE ────────────────────────────────────────────────
///
/// `PrinterWatch.raiseAlerts` notifies, on this Mac, a printer that faults, one
/// that runs out of filament and one that stops answering — `lib/printer-alerts.js`
/// decides, with its own thresholds and cooldowns. Those are left exactly as
/// they were. What it never said is the ordinary news: the print is done, or
/// the print stopped and is waiting for somebody. The iPhone hears a finish
/// through Khayt Cloud (`sendPrintFinishedEvent`); the Mac in the same room
/// heard nothing.
///
/// ── ONCE PER PRINT, NEVER PER TICK ────────────────────────────────────────
///
/// A printer sits on `paused` for an hour and is asked every ten seconds. The
/// ledger remembers, per machine, which kinds it has already told about THIS
/// print, and a print is a run of in-job readings (printing or paused) — a new
/// run starts the next time the machine goes into a job from out of one. The
/// FIRST reading of a machine only sets the baseline, so a printer that was
/// already paused when the app opened is not news on every launch.
///
/// A finish and a failure come from the finish seam (`Shop.printFinished`),
/// which `print-finish-photo` already calls once per print. A failure the
/// fault alert has already told about is not told twice.
enum PrintNoticeKind: String, CaseIterable, Sendable {
    case finished, failed, paused

    /// Mac-local, like `mac.menuBar`: which notices this Mac's owner wants is
    /// not the shop's business and does not follow the book around.
    var defaultsKey: String { "mac.notify." + rawValue }

    /// On unless switched off.
    var wanted: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    var toggleKey: String {
        switch self {
        case .finished: "mac.mbp_notify_finished"
        case .failed: "mac.mbp_notify_failed"
        case .paused: "mac.mbp_notify_paused"
        }
    }

    var titleKey: String {
        switch self {
        case .finished: "mac.mbp_notice_finished"
        case .failed: "mac.mbp_notice_failed"
        case .paused: "mac.mbp_notice_paused"
        }
    }
}

@MainActor
struct PrintNoticeLedger {

    private struct Seen: Sendable {
        var inJob: Bool
        /// What has been said about the current (or last) print.
        var told: Set<String>
    }

    private var seen: [String: Seen] = [:]

    /// One answered reading. Returns the kinds to tell about now (only ever
    /// `.paused`; a finish is the seam's).
    mutating func observe(_ machineId: String, state: String, filamentOut: Bool?) -> [PrintNoticeKind] {
        let paused = FloorRead.isPaused(state)
        let inJob = paused || PrinterWatch.isPrinting(state)
        guard var was = seen[machineId] else {
            // The baseline. Already paused is not news; mark it told.
            seen[machineId] = Seen(inJob: inJob, told: paused ? [PrintNoticeKind.paused.rawValue] : [])
            return []
        }
        if inJob && !was.inJob { was.told = [] }
        was.inJob = inJob
        var out: [PrintNoticeKind] = []
        if paused, !was.told.contains(PrintNoticeKind.paused.rawValue) {
            was.told.insert(PrintNoticeKind.paused.rawValue)
            // A runout pauses the printer, and the runout alert already says
            // so — with what to fetch. Marked told, not told twice.
            if filamentOut != true { out.append(.paused) }
        }
        seen[machineId] = was
        return out
    }

    /// The fault alert fired for this machine: a failure of the same print
    /// is not news again.
    mutating func faultTold(_ machineId: String) {
        var was = seen[machineId] ?? Seen(inJob: false, told: [])
        was.told.insert("fault")
        seen[machineId] = was
    }

    /// The finish seam's outcome ("finished" | "failed" | "cancelled").
    /// Returns what to tell, at most once per print. A cancel is somebody's
    /// own doing and is not news.
    mutating func ended(_ machineId: String, outcome: String) -> PrintNoticeKind? {
        var was = seen[machineId] ?? Seen(inJob: false, told: [])
        defer { seen[machineId] = was }
        switch outcome {
        case "finished":
            guard !was.told.contains(PrintNoticeKind.finished.rawValue) else { return nil }
            was.told.insert(PrintNoticeKind.finished.rawValue)
            return .finished
        case "failed":
            guard !was.told.contains(PrintNoticeKind.failed.rawValue), !was.told.contains("fault") else { return nil }
            was.told.insert(PrintNoticeKind.failed.rawValue)
            return .failed
        default:
            return nil
        }
    }

    /// A machine no longer watched starts from nothing, as a new one does.
    mutating func forget(_ machineId: String) { seen[machineId] = nil }
}

extension PrinterWatch {

    /// After a sweep: a print that has just been paused, told once.
    func raisePrintNotices(shop: Shop) {
        for machine in shop.machinesInUse {
            guard let status = readings[machine.id]?.status else { continue }
            for kind in notices.ledger.observe(machine.id, state: status.state, filamentOut: status.filamentOut)
            where kind.wanted {
                notices.raise(PrinterNotice.Notice(
                    machineId: machine.id, machine: machine.name, kind: kind.rawValue,
                    title: shop.words.callIt(kind.titleKey, ["machine": .string(machine.name)]),
                    body: Self.noticeBody(filename: status.filename, progress: status.progress, shop: shop),
                    at: Date()))
            }
        }
    }

    static func noticeBody(filename: String, progress: Int, shop: Shop, project: String? = nil) -> String {
        var parts: [String] = []
        if let project, !project.isEmpty { parts.append(project) }
        if !filename.isEmpty { parts.append(filename) }
        if progress > 0, progress < 100 { parts.append(shop.words.numeral(progress) + "%") }
        return parts.joined(separator: " · ")
    }
}

extension Shop {

    /// The finish seam's notice. A finish is good news, so it is delivered
    /// but not kept in "Printer trouble"; a failure is trouble and is kept.
    func noticePrintEnded(_ ended: FinishCamera.Ended) {
        guard let kind = printers.notices.ledger.ended(ended.machineId, outcome: ended.outcome), kind.wanted
        else { return }
        // The job's title only, never the customer: a banner shows on a
        // locked screen and in Notification Centre.
        let project = goToKinds.contains(.job)
            ? ended.orderId.flatMap { id in orders.first { $0.id == id } }?.project : nil
        let notice = PrinterNotice.Notice(
            machineId: ended.machineId, machine: ended.machineName, kind: kind.rawValue,
            title: words.callIt(kind.titleKey, ["machine": .string(ended.machineName)]),
            body: PrinterWatch.noticeBody(filename: ended.filename, progress: 0, shop: self, project: project),
            at: Date())
        if kind == .finished { printers.notices.announce(notice) } else { printers.notices.raise(notice) }
    }
}
