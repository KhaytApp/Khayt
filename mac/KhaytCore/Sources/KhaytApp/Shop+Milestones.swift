import Foundation
import KhaytCore

/// Milestones of a job: "Deposit 50%", then "On delivery 50%".
///
/// Each one prints as a PROFORMA asking for that part — no tax-invoice number,
/// no ZATCA QR. The job's single real tax invoice is issued for the whole job
/// exactly as before; nothing here numbers anything or moves the tax point.
///
/// Every write goes through `writeToOneOrder`, the swap every other job edit
/// takes: the ownership check, the staff lock, the stamp, the field-level undo
/// and the reload. The edit itself is `Milestones.adding / removing /
/// stamping`, which change the stored array in place so a key this app does
/// not know about survives.
extension Shop {

    /// Whether the Milestones sheet may be offered for a job: the same gate as
    /// Generate Proforma (priced, accepted, not finished or cancelled).
    static func offersMilestones(_ job: Order) -> Bool { offersProforma(job) }

    /// The milestones the book holds for a job.
    func milestones(of id: Order.ID) -> [Milestone] { Milestones.read(orderRow(id)) }

    func showMilestones(_ id: Order.ID) {
        guard let job = orders.first(where: { $0.id == id }), Self.offersMilestones(job) else { return }
        pendingMilestones = PendingHold(id: id, project: job.project)
    }

    /// Add a milestone. `amount` is what the shop confirmed — it starts at
    /// `percentage × price` and may have been typed over.
    @discardableResult
    func addMilestone(to id: Order.ID, label: String, percentage: Double, amount: Double) async -> Bool {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, percentage > 0, amount > 0 else { return false }
        let made = Milestone(id: Milestones.newId(), label: label, percentage: percentage, amount: amount)
        return await writeToOneOrder(id, named: words.callIt("mac.milestone_added"),
                                     as: .person("orders", "edit")) { order, _, _ in
            OneOrderEdit(order: Milestones.adding(made, to: order))
        }
    }

    /// Give a milestone a due date, or take it away (`day` nil). The payment
    /// reminder chases a milestone that is past it and not yet paid.
    @discardableResult
    func setMilestoneDue(on id: Order.ID, milestone: String, day: Date?) async -> Bool {
        let stamp = day.map { Calendar.book.dayString($0) }
        return await writeToOneOrder(id, named: words.callIt("ord.milestone_due"),
                                     as: .person("orders", "edit")) { order, _, _ in
            OneOrderEdit(order: Milestones.settingDue(milestone, to: stamp, in: order))
        }
    }

    @discardableResult
    func deleteMilestone(from id: Order.ID, milestone: String) async -> Bool {
        await writeToOneOrder(id, named: words.callIt("mac.milestone_removed"),
                              as: .person("orders", "edit")) { order, _, _ in
            OneOrderEdit(order: Milestones.removing(milestone, from: order))
        }
    }

    /// Show a milestone's proforma, and stamp the day it was produced.
    ///
    /// The stamp is written first: a proforma that was shown but not recorded
    /// would be a request for money the book does not know was made. If the
    /// write is refused (sample book, staff lock, another app holds the book)
    /// nothing is shown and `moveProblem` says why.
    func showMilestoneProforma(_ id: Order.ID, milestone: String) async {
        guard let job = orders.first(where: { $0.id == id }), Self.offersMilestones(job),
              milestones(of: id).contains(where: { $0.id == milestone }) else { return }
        let day = Calendar.book.dayString(Date())
        let wrote = await writeToOneOrder(id, named: words.callIt("mac.milestone_proforma"),
                                          as: .person("orders", "edit")) { order, _, _ in
            OneOrderEdit(order: Milestones.stamping(milestone, on: day, in: order))
        }
        guard wrote else { return }
        // One sheet at a time over a window: put the list away, then the paper.
        pendingMilestones = nil
        try? await Task.sleep(for: .milliseconds(350))
        pendingInvoice = PendingHold(id: id, project: job.project, proforma: true, milestone: milestone)
    }
}
