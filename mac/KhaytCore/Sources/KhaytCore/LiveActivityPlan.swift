import Foundation

/// What a print's Live Activity should do, given what the printers say now.
///
/// ── ONE RULE, TWO SENDERS ─────────────────────────────────────────────────
///
/// The phone starts, updates and ends its own Live Activities while it is in
/// the foreground (`ios/KhaytCompanion/Services/PrintActivities.swift`,
/// `PrintActivityPlan`). While it is closed only a push can move one, and the
/// Mac sends those through Khayt Cloud (`POST /v1/shops/{id}/live-activity`,
/// khayt-cloud `docs/api-contract.md`, "Live Activities"). Both must decide the
/// same way, or the Lock Screen says one thing from the phone and another from
/// the push — so this is the phone's plan, ported line for line, in the
/// package both apps link. `LiveActivityPlanTests` holds it to the phone's
/// cases.
///
/// The rules, as the phone has them:
/// - A machine that drops out of the readings has NOT finished — nobody heard
///   from it, so it is left alone. Nor has one whose poll failed (`state`
///   nil, `isUnheard`); a real fault arrives WITH a state and still ends
///   `failed`.
/// - A paused print is still a print.
/// - Only a machine seen printing and then seen not printing has ended:
///   `failed` on an error, `cancelled` when it says so, otherwise `finished`.
/// - Progress is a whole percent, 0–100. Phones on the TestFlight build of
///   October 2026 decode it as `Int`, and 42.5 fails the whole push.
///
/// Pure: readings and what is already running go in, steps come out.
public enum LiveActivityPlan {

    public enum Phase: String, Codable, Sendable, Equatable {
        case printing, paused, finished, failed, cancelled
    }

    /// The activity's content state: `PrintActivityAttributes.ContentState`.
    public struct State: Sendable, Equatable {
        public var phase: Phase
        /// The file on the printer, as the printer names it.
        public var job: String?
        public var progress: Int
        public var startedAt: Date?
        public var endsAt: Date?

        public init(phase: Phase, job: String?, progress: Int, startedAt: Date?, endsAt: Date?) {
            self.phase = phase; self.job = job; self.progress = progress
            self.startedAt = startedAt; self.endsAt = endsAt
        }
    }

    /// One machine's reading, as `/api/machines/live` gives it to the phone.
    public struct Reading: Sendable, Equatable {
        public var name: String?
        public var state: String?
        public var progress: Int?
        public var filename: String?
        /// Seconds left.
        public var timeRemaining: Int?
        public var error: String?

        public init(name: String?, state: String?, progress: Int?, filename: String?,
                    timeRemaining: Int?, error: String?) {
            self.name = name; self.state = state; self.progress = progress
            self.filename = filename; self.timeRemaining = timeRemaining; self.error = error
        }

        // `MachineLiveStatus`'s own three questions, word for word.
        public var isPrinting: Bool { (state ?? "").lowercased().contains("print") }
        public var isPaused: Bool { (state ?? "").lowercased().contains("pause") }
        public var hasError: Bool { !(error ?? "").isEmpty }
        /// No state at all: the Mac's last poll of this printer failed (an
        /// unreachable printer comes back as `state: null` plus the poll's error).
        /// That is NOT HEARD, not "stopped printing". Read it as a print ending
        /// and one missed poll ends a Live Activity as failed, raises a false
        /// "Print failed" alert, and the next good poll starts it all over again.
        public var isUnheard: Bool { state == nil }
    }

    public enum Step: Sendable, Equatable {
        case start(machineId: String, name: String, State)
        case update(machineId: String, State)
        case end(machineId: String, State)

        public var machineId: String {
            switch self {
            case let .start(id, _, _), let .update(id, _), let .end(id, _): return id
            }
        }
    }

    public static func steps(readings: [String: Reading], running: [String: State],
                             now: Date = Date()) -> [Step] {
        var steps: [Step] = []
        for (id, r) in readings.sorted(by: { $0.key < $1.key }) {
            // A missed poll is the phone not hearing, like a machine that drops out.
            if r.isUnheard { continue }
            let was = running[id]
            if r.isPrinting || r.isPaused {
                let ends = r.timeRemaining.flatMap { $0 > 0 ? now.addingTimeInterval(TimeInterval($0)) : nil }
                let state = State(phase: r.isPaused ? .paused : .printing, job: r.filename,
                                  progress: min(100, max(0, r.progress ?? 0)),
                                  startedAt: was?.startedAt ?? now, endsAt: ends)
                guard let was else {
                    if r.isPrinting { steps.append(.start(machineId: id, name: r.name ?? id, state)) }
                    continue
                }
                if worthSending(from: was, to: state) { steps.append(.update(machineId: id, state)) }
            } else if let was {
                let st = (r.state ?? "").lowercased()
                let phase: Phase = r.hasError || st.contains("error") || st.contains("fail") ? .failed
                    : st.contains("cancel") ? .cancelled : .finished
                steps.append(.end(machineId: id, State(phase: phase, job: was.job,
                                                       progress: phase == .finished ? 100 : was.progress,
                                                       startedAt: was.startedAt, endsAt: now)))
            }
        }
        return steps
    }

    /// Only a change a person would notice: a new phase, a new job, a whole
    /// percent, or the finish moving by more than a minute.
    public static func worthSending(from a: State, to b: State) -> Bool {
        if a.phase != b.phase || a.job != b.job || a.progress != b.progress { return true }
        switch (a.endsAt, b.endsAt) {
        case let (x?, y?): return abs(x.timeIntervalSince(y)) > 60
        case (nil, nil): return false
        default: return true
        }
    }

    // MARK: - What the Mac adds: the cloud's 15-second floor

    /// The cloud refuses (429) a routine update for a machine within this long
    /// of the last one (`LA_MIN_UPDATE_MS`). A start, an end or a change of
    /// phase always goes through.
    public static let minUpdateInterval: TimeInterval = 15

    /// Should this step go now? A routine update inside the floor waits for a
    /// later reading rather than spending a request on a certain 429.
    public static func due(_ step: Step, running: [String: State], lastSent: [String: Date],
                           now: Date) -> Bool {
        guard case let .update(id, state) = step else { return true }
        if let was = running[id], was.phase != state.phase { return true }
        guard let last = lastSent[id] else { return true }
        return now.timeIntervalSince(last) >= minUpdateInterval
    }
}
