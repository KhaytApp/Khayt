import ActivityKit
import Foundation

/// A print on one machine, as a Live Activity: on the Lock Screen, in the
/// Dynamic Island, and on iPhone Duo's outer display.
///
/// Compiled into BOTH the app (which starts, updates and ends it) and the
/// widget extension (which draws it) — the folder is shared the way
/// `KhaytAlerts` is, so there is one definition rather than two copies.
///
/// ── THE COUNTDOWN RUNS ITSELF ─────────────────────────────────────────────
///
/// The state carries when the print ends, not how long is left. The system
/// draws `Text(timerInterval:)` and `ProgressView(timerInterval:)` from those
/// dates, so the Lock Screen keeps counting with the app closed and no update
/// arriving — which, until Khayt Cloud sends ActivityKit pushes, is the only
/// way it can stay right.
struct PrintActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable { case printing, paused, finished, failed, cancelled }
        var phase: Phase
        /// The file on the printer, as the printer names it.
        var job: String?
        var progress: Int
        var startedAt: Date?
        var endsAt: Date?
    }

    let machineId: String
    let machineName: String
}
