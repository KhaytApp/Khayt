import ActivityKit
import Combine
import Foundation
import KhaytCore

/// What the Live Activities should do, given what the printers say now.
///
/// The RULE is KhaytCore's `LiveActivityPlan`, the one the Mac's pushes use
/// too (`LiveActivityPush`, through Khayt Cloud). If the phone and the push
/// decided apart, the Lock Screen would say one thing while the app is open
/// and another once it closes. This is only the translation between the
/// phone's types and the shared ones, so the tests here hold the shared rule.
///
/// The rules themselves, briefly: a machine that drops out of the readings, or
/// whose poll failed (no state), has not ended; a paused print is still a
/// print; only one seen printing and then seen not printing has ended, with
/// the outcome `FinishDetector` would give it.
enum PrintActivityPlan {
    typealias State = PrintActivityAttributes.ContentState

    enum Step: Equatable {
        case start(machineId: String, name: String, State)
        case update(machineId: String, State)
        case end(machineId: String, State)
    }

    static func steps(readings: [String: MachineLiveStatus], running: [String: State],
                      now: Date = Date()) -> [Step] {
        LiveActivityPlan.steps(readings: readings.mapValues(shared), running: running.mapValues(shared), now: now)
            .map { step in
                switch step {
                case let .start(id, name, s): return .start(machineId: id, name: name, phone(s))
                case let .update(id, s): return .update(machineId: id, phone(s))
                case let .end(id, s): return .end(machineId: id, phone(s))
                }
            }
    }

    static func worthSending(from a: State, to b: State) -> Bool {
        LiveActivityPlan.worthSending(from: shared(a), to: shared(b))
    }

    // MARK: - Translation

    static func shared(_ r: MachineLiveStatus) -> LiveActivityPlan.Reading {
        .init(name: r.name, state: r.state, progress: r.progress, filename: r.filename,
              timeRemaining: r.timeRemaining, error: r.error)
    }

    static func shared(_ s: State) -> LiveActivityPlan.State {
        .init(phase: LiveActivityPlan.Phase(rawValue: s.phase.rawValue) ?? .printing, job: s.job,
              progress: s.progress, startedAt: s.startedAt, endsAt: s.endsAt)
    }

    static func phone(_ s: LiveActivityPlan.State) -> State {
        State(phase: State.Phase(rawValue: s.phase.rawValue) ?? .printing, job: s.job,
              progress: s.progress, startedAt: s.startedAt, endsAt: s.endsAt)
    }
}

/// Starts, updates and ends one Live Activity per printing machine, from the
/// live readings the app already receives.
///
/// Apple lets an app START a Live Activity only while it is in the
/// foreground, which is also when readings arrive. While the app is closed,
/// Khayt Cloud moves them by ActivityKit push (`LiveActivityPush`), when the
/// phone is signed in to it. Otherwise the self-running countdown carries them.
@MainActor
final class PrintActivities {
    private var watching: AnyCancellable?
    private var switchedOff: AnyCancellable?
    private let settings: ConnectionSettings
    let push: LiveActivityPush

    init(printers: LivePrinters, settings: ConnectionSettings, api: KhaytAPIClient) {
        self.settings = settings
        push = LiveActivityPush(api: api, enabled: { [weak settings] in settings?.liveActivities ?? false })
        api.liveActivityPush = push
        push.begin()
        watching = printers.$byMachine.dropFirst().sink { [weak self, weak printers] readings in
            guard let self, printers?.isLive == true else { return }
            Task { await self.apply(readings) }
        }
        switchedOff = settings.$liveActivities.dropFirst().removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            Task {
                if on { await self.push.sendAll() } else { await self.push.withdrawStart(); await self.endAll() }
            }
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
                // `.token`: the cloud can then move it with the app closed.
                if let started = try? Activity.request(attributes: PrintActivityAttributes(machineId: id, machineName: name),
                                                       content: ActivityContent(state: state, staleDate: state.endsAt),
                                                       pushType: .token) {
                    push.watch(started)
                }
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
