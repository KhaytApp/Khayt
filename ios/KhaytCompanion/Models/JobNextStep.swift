import Foundation

// ── TEMPORARY STAND-IN ───────────────────────────────────────────────────
// The next-step rule is moving into lib/ (shared with the Mac and the
// desktop). Once it lands, the phone reads the next step from that shared
// rule and this mapping goes. Until then it is a thin, phone-only copy of
// the rule as Turki set it (Nov 11) — keep it small, and change the lib, not
// this, when the rule changes.

/// The ONE thing a job page offers next, pinned at the bottom of the phone's
/// job page ("Rules every app keeps" 2, Figma R9W19Jakt19nKs1yM5GEde 39:265).
///
/// Every case maps onto a write the page already makes — nothing here is a new
/// backend action:
/// - `approveQuote` is the quote's Approve (`QuoteAnswer.approve`);
/// - `advance` is the stage move the page always had (`updateOrderStatus`);
/// - `handOver` opens the Ship sheet (carrier and tracking);
/// - `recordPayment` opens the Record payment sheet;
/// - `resume` takes a held job back to the stage it was in (Pending when that
///   is not known), by the same status update.
///
/// A finished, paid job, a cancelled job and a voided one have no next step:
/// `next` returns nil and the bar says so.
enum JobNextStep: Equatable, Sendable {
    case approveQuote
    case advance(to: OrderStatus)
    case handOver
    case recordPayment
    case resume(to: OrderStatus)

    /// The stages a job is worked through, and so the ones a held job can
    /// go back to.
    private static let working: [OrderStatus] = [.pending, .printing, .post, .qc]

    /// - Parameters:
    ///   - status: the job's stage as the book writes it.
    ///   - voided: a voided job is not worked on or collected.
    ///   - owed: what is still to be paid (`PaymentState.owed`), 0 when unknown.
    ///   - canHandOver: the job is finished and not yet sent (the page has
    ///     carriers to ship with).
    ///   - heldFrom: for a job on hold, the stage it was in before.
    static func next(status: String, voided: Bool = false, owed: Double = 0,
                     canHandOver: Bool = false, heldFrom: OrderStatus? = nil) -> JobNextStep? {
        if voided { return nil }
        guard let stage = OrderStatus(rawValue: status) else { return nil }
        switch stage {
        case .quote:
            return .approveQuote
        case .pending, .printing, .post, .qc:
            return stage.nextInQueue.map { .advance(to: $0) }
        case .completed, .delivered, .shipped:
            if canHandOver { return .handOver }
            if owed > 0.005 { return .recordPayment }
            return nil
        case .on_hold:
            let back = heldFrom.flatMap { working.contains($0) ? $0 : nil }
            return .resume(to: back ?? .pending)
        }
    }

    /// The verb, as a string key.
    var verbKey: String {
        switch self {
        case .approveQuote: return "quote.approve"
        case .advance(let to):
            switch to {
            case .printing: return "job.next.start_printing"
            case .post: return "job.next.mark_printed"
            case .qc: return "job.next.send_to_qc"
            case .completed: return "job.next.mark_ready"
            default: return "order.detail.move_to"
            }
        case .handOver: return "job.next.hand_over"
        case .recordPayment: return "pay.modal_title"
        case .resume: return "job.next.resume"
        }
    }

    /// The working stage a job was in before its last move onto hold, from
    /// its `statusHistory` statuses, oldest first. Nil when the history does
    /// not say (the caller resumes to Pending).
    static func stageBeforeHold(history: [String]) -> OrderStatus? {
        guard let held = history.lastIndex(of: OrderStatus.on_hold.rawValue) else { return nil }
        for st in history[..<held].reversed() where st != OrderStatus.on_hold.rawValue {
            guard let stage = OrderStatus(rawValue: st), working.contains(stage) else { return nil }
            return stage
        }
        return nil
    }

    /// Whole calendar days a due date has gone by, on the Gregorian calendar;
    /// nil when it has not (or there is none).
    static func daysLate(due: String?, today: Date = Date()) -> Int? {
        guard let raw = due, let day = DueDateParser.parse(raw) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: day), to: cal.startOfDay(for: today)).day ?? 0
        return n > 0 ? n : nil
    }

    /// Owing is red only when it is overdue: money still owed on a job whose
    /// due date has gone by.
    static func owingIsOverdue(owed: Double, due: String?, today: Date = Date()) -> Bool {
        owed > 0.005 && daysLate(due: due, today: today) != nil
    }
}
