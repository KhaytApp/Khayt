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

        init(phase: Phase, job: String?, progress: Int, startedAt: Date?, endsAt: Date?) {
            self.phase = phase; self.job = job; self.progress = progress
            self.startedAt = startedAt; self.endsAt = endsAt
        }

        /// A PUSHED state is decoded by the system, with the default strategies,
        /// from what Khayt Cloud relays. Printers report fractional percents, and
        /// a `42.5` sent to a synthesised `Int` does not round. It fails the
        /// whole decode, and the update is dropped without a word. So the
        /// number is read either way and rounded. This changes the TYPE's own
        /// decoding, not the decoder's strategy, which is what Apple forbids.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            phase = try c.decode(Phase.self, forKey: .phase)
            job = try c.decodeIfPresent(String.self, forKey: .job)
            if let whole = try? c.decode(Int.self, forKey: .progress) {
                progress = whole
            } else {
                progress = Int(try c.decode(Double.self, forKey: .progress).rounded())
            }
            startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
            endsAt = try c.decodeIfPresent(Date.self, forKey: .endsAt)
        }
    }

    let machineId: String
    let machineName: String
}
