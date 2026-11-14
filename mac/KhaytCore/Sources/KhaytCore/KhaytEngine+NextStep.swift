import Foundation

/// The one next step for a job, asked of the shared rule.
///
/// `lib/order-next-step.js` decides what a job page pins — Start printing,
/// Mark printed, Resume, Hand over, Record payment — for the Mac, the iPhone
/// and the desktop alike (S1, Nov 2026). It replaces two Swift copies that
/// disagreed: the Mac's `Stage.progression` walk and the phone's
/// `OrderStatus.nextInQueue`. Here, in KhaytCore, so the phone asks the same
/// engine the Mac does; the apps only word the answer.
extension KhaytEngine {

    /// What the rule says about one job.
    public struct NextSteps: Decodable, Sendable, Equatable {
        public struct Blocked: Decodable, Sendable, Equatable {
            /// `production_paused`, `wip_blocked`, `assembly_not_assembled`,
            /// `assembly_parts`, `read_only`, `stage_not_a_status`.
            public let code: String
            public let params: [String: JSONValue]
        }

        public struct Step: Decodable, Sendable, Equatable {
            /// `send_quote`, `take_job`, `start_printing`, `mark_printed`,
            /// `send_to_check`, `mark_ready`, `resume`, `hand_over`,
            /// `record_payment`, `hold`, `fail_check`, `ship`.
            public let code: String
            /// The status the step moves the job to, or nil when it is not a
            /// move (a hand-over stamps a date; a payment opens a sheet).
            public let to: String?
            /// What must be asked first: `hold`, `actuals`, `qc_fail`, `send`,
            /// `payment`, or nil.
            public let asks: String?
            /// Why it cannot be done now, said at the control; nil when it can.
            public let blocked: Blocked?
        }

        public struct Pill: Decodable, Sendable, Equatable {
            /// The stage, or `paid` for a job handed over and settled.
            public let stage: String?
            /// `steel`, `amber`, `green`, `purple` or `grey`.
            public let tone: String
        }

        public struct TrackNode: Decodable, Sendable, Equatable, Identifiable {
            public var id: String { stage }
            public let stage: String
            /// `done`, `current` or `todo`.
            public let state: String
            /// When it was reached, as the book wrote it; "" when it was not.
            public let at: String
        }

        /// `stageOf`'s answer.
        public let stage: String?
        public let pill: Pill
        public let late: Bool
        /// Still to pay, in the job's own currency.
        public let owed: Double
        /// On hold only: the stage Resume goes back to.
        public let heldFrom: String?
        public let primary: Step?
        public let secondary: [Step]
        public let track: [TrackNode]
    }

    /// Every job's next step in one crossing: id → answer.
    ///
    /// `lateIds` is the attention rule's own late list (`lateOrders`), so the
    /// page and the dashboard agree about which jobs are late; `canWrite`
    /// false marks every step `read_only`. The rule reads only the gate's
    /// settings (production paused, WIP limits) and the tax profile, so it is
    /// handed the trimmed settings.
    public func orderNextSteps(_ orders: [JSONValue], settings: [String: JSONValue],
                               lateIds: [String], canWrite: Bool = true) throws -> [String: NextSteps] {
        try runtime.call2(
            "globalThis.KhaytOrderNextStep.nextStepsAll(ARG0, { settings: ARG1, lateIds: ARG2, canWrite: ARG3 })",
            [.array(orders), .object(ruleSettings(settings)), .array(lateIds.map(JSONValue.string)), .bool(canWrite)],
            as: [String: NextSteps].self)
    }
}
