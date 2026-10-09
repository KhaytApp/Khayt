import ActivityKit
import Combine
import Foundation

/// What the Live Activities should do, given what the printers say now.
///
/// Pure, so it can be tested without ActivityKit: the readings and the
/// activities already running go in, a list of steps comes out.
///
/// ── THE SAME RULES AS THE PRINT-FINISHED ALERT ──────────────────────────
///
/// A machine that drops out of the readings has NOT finished — the phone
/// simply stopped hearing about it, so its activity is left alone. A paused
/// print is still a print. Only a machine seen printing and then seen not
/// printing has ended, with the outcome `FinishDetector` would give it.
enum PrintActivityPlan {
    typealias State = PrintActivityAttributes.ContentState

    enum Step: Equatable {
        case start(machineId: String, name: String, State)
        case update(machineId: String, State)
        case end(machineId: String, State)
    }

    static func steps(readings: [String: MachineLiveStatus], running: [String: State],
                      now: Date = Date()) -> [Step] {
        var steps: [Step] = []
        for (id, r) in readings.sorted(by: { $0.key < $1.key }) {
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
                let phase: State.Phase = r.hasError || st.contains("error") || st.contains("fail") ? .failed
                    : st.contains("cancel") ? .cancelled : .finished
                steps.append(.end(machineId: id, State(phase: phase, job: was.job,
                                                       progress: phase == .finished ? 100 : was.progress,
                                                       startedAt: was.startedAt, endsAt: now)))
            }
        }
        return steps
    }

    /// Updates are budgeted by the system, and the countdown runs itself, so
    /// only a change a person would notice is sent: a new phase, a new job,
    /// a whole percent, or the finish moving by more than a minute.
    static func worthSending(from a: State, to b: State) -> Bool {
        if a.phase != b.phase || a.job != b.job || a.progress != b.progress { return true }
        switch (a.endsAt, b.endsAt) {
        case let (x?, y?): return abs(x.timeIntervalSince(y)) > 60
        case (nil, nil): return false
        default: return true
        }
    }
}

/// Starts, updates and ends one Live Activity per printing machine, from the
/// live readings the app already receives.
///
/// Apple lets an app START a Live Activity only while it is in the
/// foreground, which is also when readings arrive. Updating one while the
/// app is closed needs ActivityKit pushes from Khayt Cloud; until then the
/// self-running countdown carries it.
@MainActor
final class PrintActivities {
    private var watching: AnyCancellable?
    private var switchedOff: AnyCancellable?
    private let settings: ConnectionSettings

    init(printers: LivePrinters, settings: ConnectionSettings) {
        self.settings = settings
        watching = printers.$byMachine.dropFirst().sink { [weak self, weak printers] readings in
            guard let self, printers?.isLive == true else { return }
            Task { await self.apply(readings) }
        }
        switchedOff = settings.$liveActivities.dropFirst().filter { !$0 }.sink { [weak self] _ in
            Task { await self?.endAll() }
        }
    }

    private func running() -> [String: Activity<PrintActivityAttributes>] {
        var out: [String: Activity<PrintActivityAttributes>] = [:]
        for a in Activity<PrintActivityAttributes>.activities where a.activityState == .active {
            out[a.attributes.machineId] = a
        }
        return out
    }

    func apply(_ readings: [String: MachineLiveStatus], now: Date = Date()) async {
        guard settings.liveActivities, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let live = running()
        for step in PrintActivityPlan.steps(readings: readings, running: live.mapValues(\.content.state), now: now) {
            switch step {
            case let .start(id, name, state):
                // Refused when Live Activities are off for the app or the
                // system's limit is reached; the print carries on regardless.
                _ = try? Activity.request(attributes: PrintActivityAttributes(machineId: id, machineName: name),
                                          content: ActivityContent(state: state, staleDate: state.endsAt))
            case let .update(id, state):
                await live[id]?.update(ActivityContent(state: state, staleDate: state.endsAt))
            case let .end(id, state):
                // Left on the Lock Screen a while, so the result is seen.
                await live[id]?.end(ActivityContent(state: state, staleDate: nil),
                                    dismissalPolicy: .after(now.addingTimeInterval(30 * 60)))
            }
        }
    }

    /// Switched off in Settings: every running one goes at once.
    func endAll() async {
        for a in Activity<PrintActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
