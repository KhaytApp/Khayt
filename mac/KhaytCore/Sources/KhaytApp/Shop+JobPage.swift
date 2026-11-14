import Foundation
import KhaytCore

/// What the job page (S1) does: the steps `lib/order-next-step.js` names,
/// worded and performed here, and the stamp that says a quote has gone out.
///
/// WHAT comes next is the shared rule's, read into `nextSteps` at each load —
/// the iPhone and the desktop get the same answer. This file only decides
/// what a press DOES on the Mac, through the calls the menus already make:
/// `moveJob` (with the hold, actuals and QC-fail questions), `markDelivered`,
/// `markShipped`, the payment sheet, the quote's paper.
@MainActor
extension Shop {

    /// The rule's answer for the job AS IT IS NOW, or nil. Between a move and
    /// the reload that follows it the answer on hand is the old stage's, and a
    /// button for a stage the job has left would be a wrong button.
    func pageSteps(for job: Order) -> KhaytEngine.NextSteps? {
        guard let steps = nextSteps[job.id], steps.stage == Stage.of(job)?.rawValue else { return nil }
        return steps
    }

    /// A step's verb. Nil for a code this build has no word for (a newer
    /// rule): the page then offers nothing rather than a raw code.
    nonisolated static func stepTitleKey(_ code: String) -> String? {
        switch code {
        case "send_quote": "mac.jp_send_quote"
        case "take_job": "mac.jp_take_job"
        case "start_printing": "mac.jp_start_printing"
        case "mark_printed": "mac.jp_mark_printed"
        case "send_to_check": "mac.jp_send_to_check"
        case "mark_ready": "mac.jp_mark_ready"
        case "resume": "mac.jp_resume"
        case "hand_over": "mac.jp_hand_over"
        case "record_payment": "mac.jp_record_payment"
        case "hold": "ord.hold_btn"
        case "ship": "queue.mark_shipped"
        case "fail_check": "qc.failed"
        default: nil
        }
    }

    /// Why a step cannot be done now, said at the control; nil when it can.
    /// This person and this book first (`canMoveJobs`: the sample, a book
    /// another computer holds, the staff lock), then the gate's own refusal.
    func stepRefusal(_ step: KhaytEngine.NextSteps.Step) -> String? {
        if !canMoveJobs { return words.callIt("mac.jp_read_only") }
        guard let blocked = step.blocked else { return nil }
        switch blocked.code {
        case "production_paused": return words.callIt("prod.paused_block")
        case "wip_blocked": return words.callIt("wip.limit_blocked", blocked.params)
        case "assembly_not_assembled": return words.callIt("asm.gate_not_assembled")
        case "assembly_parts": return words.callIt("asm.gate_parts", blocked.params)
        case "read_only": return words.callIt("mac.jp_read_only")
        default: return words.callIt("mac.move_refused")
        }
    }

    /// Do a step — through the same calls the Job menu makes, so the lock,
    /// the gate and the questions (why on hold, what it took, what failed)
    /// are theirs. A refused step does nothing: its button is disabled and
    /// says why.
    func takeStep(_ step: KhaytEngine.NextSteps.Step, on job: Order) {
        guard stepRefusal(step) == nil else { return }
        switch step.code {
        case "hand_over":
            Task { await markDelivered(job.id) }
        case "ship":
            Task { await markShipped(job.id) }
        case "record_payment":
            pendingPayment = PendingHold(id: job.id, project: job.project)
        case "send_quote":
            // The quote's paper, with Share; the customer link and WhatsApp
            // are on the page below. Each of them stamps `quoteSharedAt`.
            showInvoice(job.id)
        default:
            guard let there = step.to.flatMap(Stage.init(rawValue:)) else { return }
            if let ask = questionFor(job.id, moving: there) { ask(); return }
            Task { await moveJob(job.id, to: there) }
        }
    }

    // MARK: - A quote that has gone out

    /// The customer has been sent this quote: stamp `quoteSharedAt`, once.
    ///
    /// Called where a quote really leaves — its link copied or published, a
    /// WhatsApp or an email opened with it, a follow-up sent, its paper
    /// shared. From then on the rule leads with "Take the job" instead of
    /// "Send quote" (Turki, Nov 11). `quoteSentAt` is not this: it is written
    /// on every quote when it is created.
    ///
    /// Only a quote, only the first time, and only by somebody who may edit
    /// jobs; anything else returns without a write.
    func noteQuoteShared(_ id: Order.ID, now: Date = Date()) async {
        guard let row = orderRows.first(where: { Self.recordId($0) == id }),
              case .object(let o) = row, o["status"] == .string("quote"),
              Self.plainString(o["quoteSharedAt"]) == nil else { return }
        let at = Self.isoNow(now)
        await write(as: .person("orders", "edit")) { root in
            guard case .array(var jobs)? = root["printLog"],
                  let i = jobs.firstIndex(where: { Shop.recordId($0) == id }),
                  case .object(var job) = jobs[i], job["status"] == .string("quote"),
                  Shop.plainString(job["quoteSharedAt"]) == nil else { return }
            job["quoteSharedAt"] = .string(at)
            jobs[i] = .object(job)
            root["printLog"] = .array(jobs)
        }
    }
}
