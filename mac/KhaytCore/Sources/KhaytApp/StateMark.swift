import SwiftUI

/// What a thing's state looks like — §4 of the design spec.
///
/// ── THE GLYPH IS THE STATE ────────────────────────────────────────────────
///
/// Every state renders a GLYPH and a WORD as well as a hue. Not because a
/// hue is unclear, but because a hue is not always received: `done` and `late`
/// sit 2.4 ΔE apart under protanopia, which is to say they are the same
/// colour to a reader with the commonest form of colour blindness. Greyscale
/// this app and every state still reads — that is the test, and
/// `StateReadsWithoutColourTests` is where it is written down.
///
/// The glyph is deliberately a CHARACTER rather than an SF Symbol: it has to
/// sit inside a line of text at label size, on navy and on paper, in both
/// directions, and a symbol image at 9.5pt aligned to a caps baseline is a
/// per-screen argument this avoids entirely.
enum ShopState: String, CaseIterable, Hashable {
    // ── ATTENTION: a KIND and a SEVERITY, from `lib/attention.js` ─────────
    //
    // The rule: the glyph names the KIND, the word carries the SEVERITY. Hue
    // is third and never load-bearing. `nozzle` is first-class — a blocked
    // nozzle stops a machine and a worn one ruins a finish, and those are
    // different sentences to a shop.
    case orderLate, orderToday
    case machineStopped, machineCheck
    case nozzleBlocked, nozzleWorn
    case stockOut, stockLow

    // ── LIFECYCLE: where a job IS ────────────────────────────────────────
    //
    // Not attention, and not from attention.js. These say where the work
    // stands and must never compete for the eye with the list above.
    case running, queued, finishing, done, quoted, offline, failedToSend

    /// One per kind, so two kinds never share a silhouette.
    var glyph: String {
        switch self {
        case .orderLate:      "▲"
        case .orderToday:     "◷"
        case .machineStopped: "■"
        case .machineCheck:   "◆"
        case .nozzleBlocked:  "⊘"
        case .nozzleWorn:     "◔"
        case .stockOut:       "▼"
        case .stockLow:       "▽"
        case .running:        "●"
        case .queued:         "◌"
        case .finishing:      "◑"
        case .done:           "✓"
        case .quoted:         "◇"
        case .offline:        "✕"
        case .failedToSend:   "✉"
        }
    }

    /// The word carries the severity: STOPPED and CHECK IT are the same kind
    /// and different sentences.
    var wordKey: String {
        switch self {
        case .orderLate:      "mac.state_late"
        case .orderToday:     "mac.state_today"
        case .machineStopped: "mac.state_stopped"
        case .machineCheck:   "mac.state_check_it"
        case .nozzleBlocked:  "mac.state_blocked"
        case .nozzleWorn:     "mac.state_worn"
        case .stockOut:       "mac.state_out"
        case .stockLow:       "mac.state_low"
        case .running:        "mac.state_running"
        case .queued:         "mac.state_queued"
        case .finishing:      "mac.state_finishing"
        case .done:           "mac.state_done"
        case .quoted:         "mac.state_quoted"
        case .offline:        "mac.state_offline"
        case .failedToSend:   "mac.state_failed_send"
        }
    }

    var tint: Color {
        switch self {
        case .orderLate, .machineStopped, .nozzleBlocked, .stockOut: Role.late
        case .orderToday, .machineCheck, .nozzleWorn, .stockLow, .finishing: Role.warn
        case .running:                     Role.ok
        case .queued, .done, .failedToSend: Role.text2
        case .quoted, .offline:            Role.text3
        }
    }

    var ground: Color? {
        switch self {
        case .orderLate, .machineStopped, .nozzleBlocked, .stockOut: Role.lateBg
        case .failedToSend:                                          Role.lateBg
        case .orderToday, .machineCheck, .nozzleWorn, .stockLow:     Role.warnBg
        case .running:                                               Role.okBg
        default:                                                     nil
        }
    }

    /// A finished job is drawn back, not away: still legible, plainly over.
    var rowOpacity: Double { self == .done ? 0.55 : 1 }

    /// The shared rule's own words, mapped.
    ///
    /// An unlisted severity is `warn` with its own word — NEVER a new colour,
    /// and never silently `crit`. Guessing `"high"` here once put the
    /// due-today glyph on nine late jobs, which is the failure §4 exists to
    /// prevent.
    static func of(kind: String, severity: String) -> ShopState {
        let critical = severity == "crit"
        switch kind {
        case "order":   return critical ? .orderLate : .orderToday
        case "machine": return critical ? .machineStopped : .machineCheck
        case "nozzle":  return critical ? .nozzleBlocked : .nozzleWorn
        case "stock":   return critical ? .stockOut : .stockLow
        default:        return .machineCheck
        }
    }

    /// True for the states that come from `attention.js` rather than from
    /// where a job happens to be. The two lists must not be mixed: lifecycle
    /// never competes for the eye.
    var isAttention: Bool {
        switch self {
        case .running, .queued, .finishing, .done, .quoted, .offline, .failedToSend: false
        default: true
        }
    }
}

/// A state, as a chip — §6's chip, and the only way a state should reach a
/// screen.
///
/// Glyph and word travel together by construction. Wanting one without the
/// other is wanting half a signal, and this type deliberately offers no way
/// to ask for it.
struct StateChip: View {
    let state: ShopState
    let words: Words
    /// Chips inside a selected (navy) row invert: the ground goes away and the
    /// ink turns white, because a paper-tinted chip on navy is a hole.
    var onNavy = false

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(state.glyph)
            Text(words.callIt(state.wordKey).uppercased())
                .tracking(0.9)
        }
        .font(TypeScale.label(10))
        .foregroundStyle(onNavy ? Role.onNavy : state.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background {
            if !onNavy, let ground = state.ground {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(ground)
            }
        }
        // The word is already on screen, so the label a screen reader reads is
        // the same sentence a sighted reader gets — not a second vocabulary
        // invented for it.
        .accessibilityElement(children: .combine)
    }
}
