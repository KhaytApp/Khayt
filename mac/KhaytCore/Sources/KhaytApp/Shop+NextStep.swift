import Foundation
import KhaytCore

/// What the job inspector's one big button does: the next thing a shop does to
/// a job, named.
///
/// A job goes through about six moves on its way out of the door, and every one
/// of them used to be a trip to the Job menu (Move Along, ⌘→), a right-click on
/// the table, or a drag across the board. The inspector is where somebody is
/// already reading the job, so it offers the one move that comes next.
///
/// ── ONE RULE, THREE PLACES ────────────────────────────────────────────────
///
/// `moveAlongTarget` and `moveAlong` are what Job ▸ Move Along / Move Back
/// call, moved here out of the menu so the button cannot drift from it: what
/// the menu greys out, the button hides. `canMarkDelivered` is the rule the
/// Job menu's and the table's "Delivered" items are disabled by.
enum NextStep: Equatable, Sendable {
    /// A quote, moved along: accepted, it becomes pending work.
    case accept(Stage)
    /// Move Along to this stage.
    case move(Stage)
    /// A finished or shipped job, handed over (`markDelivered`).
    case deliver
}

extension Shop {

    /// Where Move Along (`delta` 1) or Move Back (-1) takes job `id`, or nil
    /// when it cannot go — no job, a book that is not ours, the operator lock,
    /// either end of the way work goes, or a job on hold.
    func moveAlongTarget(_ id: Order.ID?, by delta: Int) -> Stage? {
        guard canMoveJobs, let id, let job = orders.first(where: { $0.id == id }),
              let here = Stage.of(job) else { return nil }
        guard let there = here.stepped(by: delta) else { return nil }
        // The same refusal the board shows before a card is dropped. Asked
        // here so the item is greyed rather than offered and then refused.
        guard dragRefusal(there) == nil else { return nil }
        return there
    }

    /// One step, through the path a drop takes.
    ///
    /// SHIPPED IS NOT A STATUS — it is a date stamped on a job that stays
    /// `completed` — so it is performed the only way it can be, exactly as the
    /// board's drop handler does it, and before anything asks the gate.
    func moveAlong(_ id: Order.ID?, by delta: Int) {
        guard let id, let there = moveAlongTarget(id, by: delta) else { return }
        if there == .shipped {
            Task { await markShipped(id) }
            return
        }
        if let ask = questionFor(id, moving: there) { ask(); return }
        Task { await moveJob(id, to: there) }
    }

    /// Whether "Delivered" is offered for this job: finished, not yet handed
    /// over, and the book is ours to write. Shipped jobs are `completed` too.
    func canMarkDelivered(_ job: Order) -> Bool {
        canMoveJobs && job.status == "completed" && job.deliveredAt == nil
    }

    /// The inspector button's move for job `id`, or nil when it shows nothing.
    ///
    /// A finished or shipped job is handed over rather than stepped on to
    /// Shipped: most work leaves the bench in the customer's hands, and
    /// "Ship it" stays one menu item away (Job ▸ Move Along, or Shipped).
    func nextStep(for id: Order.ID) -> NextStep? {
        guard let job = orders.first(where: { $0.id == id }) else { return nil }
        if canMarkDelivered(job) { return .deliver }
        guard let there = moveAlongTarget(id, by: 1) else { return nil }
        return Stage.of(job) == .quote ? .accept(there) : .move(there)
    }

    /// The button's words.
    func nextStepTitle(_ step: NextStep) -> String {
        switch step {
        case .accept: words.callIt("mac.accept_quote")
        case .move(let stage): words.callIt("mac.next_stage", ["stage": .string(words.callIt(stage.key))])
        case .deliver: words.callIt("mac.mark_delivered")
        }
    }

    /// May "Mark printed" be offered for this job? The menu bar's finished
    /// card and row ask this, and the press is `takeNextStep` below: the
    /// inspector's own button, one step along from Printing, behind the same
    /// gates (`moveAlongTarget`: a book this Mac may write, the operator lock,
    /// the stage rules) and the same permission check in `moveJob`. Only for a
    /// job still IN Printing: once it has been moved on, by this button or in
    /// the main window, there is nothing left to mark.
    func canMarkPrinted(_ job: Order) -> Bool {
        guard Stage.of(job) == .printing, case .move? = nextStep(for: job.id) else { return false }
        return true
    }

    /// Do it — through the same calls the menus make.
    func takeNextStep(_ id: Order.ID) {
        switch nextStep(for: id) {
        case .deliver?: Task { await markDelivered(id) }
        case .accept?, .move?: moveAlong(id, by: 1)
        case nil: return
        }
    }
}
