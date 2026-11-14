import Foundation
import KhaytCore

/// What a job page offers next, as the SHARED rule says it
/// (`lib/order-next-step.js`, through `KhaytEngine.orderNextSteps`): the same
/// answer the Mac and the desktop give, so the phone has no opinion of its own
/// about a job's next step (S1, Nov 2026). This file only words the answer and
/// makes the one phone-side adjustment below.
enum JobSteps {
    typealias Rule = KhaytEngine.NextSteps
    typealias Step = KhaytEngine.NextSteps.Step
    typealias Blocked = KhaytEngine.NextSteps.Blocked

    /// The steps as the bar shows them.
    ///
    /// The ONE adjustment the phone makes: the rule leads an unshared quote
    /// with `send_quote`, and the phone sends a quote by sharing its customer
    /// page link. A quote with no customer link (no page token, or no cloud
    /// to serve it) cannot be sent from here, so `take_job` — the rule's
    /// first secondary — leads instead, and `send_quote` is not offered.
    static func arranged(_ rule: Rule, hasCustomerLink: Bool) -> (primary: Step?, secondary: [Step]) {
        guard !hasCustomerLink, let primary = rule.primary, primary.code == "send_quote",
              let take = rule.secondary.first(where: { $0.code == "take_job" }) else {
            let secondary = hasCustomerLink ? rule.secondary : rule.secondary.filter { $0.code != "send_quote" }
            return (rule.primary, secondary)
        }
        return (take, rule.secondary.filter { $0.code != "take_job" && $0.code != "send_quote" })
    }

    /// The verb for a step's code, as a string key; nil for a code this build
    /// does not know (the step is then not offered).
    static func verbKey(_ code: String) -> String? {
        switch code {
        case "send_quote": return "job.next.send_quote"
        case "take_job": return "job.next.take_job"
        case "start_printing": return "job.next.start_printing"
        case "mark_printed": return "job.next.mark_printed"
        case "send_to_check": return "job.next.send_to_qc"
        case "mark_ready": return "job.next.mark_ready"
        case "resume": return "job.next.resume"
        case "hand_over": return "job.next.hand_over"
        case "record_payment": return "pay.modal_title"
        case "hold": return "job.next.hold"
        case "fail_check": return "job.next.fail_check"
        case "ship": return "ship.open"
        default: return nil
        }
    }

    static func verb(_ step: Step) -> String? { verbKey(step.code).map(L10n.tr) }

    /// Why a step cannot be done now, said at the control.
    static func blockedText(_ b: Blocked) -> String {
        switch b.code {
        case "read_only": return L10n.tr("cloud.read_only.line")
        case "production_paused": return L10n.tr("job.blocked.production_paused")
        case "wip_blocked":
            let col = b.params["col"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? ""
            let n = b.params["n"].flatMap { v -> String? in
                if case .number(let x) = v { return String(Int(x)) }
                if case .string(let s) = v { return s }
                return nil
            } ?? ""
            return L10n.format("job.blocked.wip", n, JobStageLook.name(col))
        case "assembly_not_assembled": return L10n.tr("job.blocked.assembly_not_assembled")
        case "assembly_parts":
            let parts = b.params["parts"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? ""
            return L10n.format("job.blocked.assembly_parts", parts)
        default: return L10n.tr("job.blocked.other")
        }
    }

    /// The stage the track rings: the rule's `current` node (a held job stands
    /// where it was held; a shipped job at the last node).
    static func trackCurrent(_ rule: Rule) -> OrderStatus? {
        guard let node = rule.track.first(where: { $0.state == "current" }) else { return nil }
        if node.stage == "shipped" || node.stage == "delivered" { return .completed }
        return OrderStatus(rawValue: node.stage)
    }

    /// Only a share the sheet reports as done stamps a quote as sent — a send,
    /// or Copy Link (which reports done too). A cancelled sheet stamps nothing.
    static func shareCounts(completed: Bool) -> Bool { completed }
}
