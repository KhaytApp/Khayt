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
    case late, dueToday, running, queued, finishing, done, blocked, quoted, offline

    /// The mark. One per state, and no two alike in silhouette — round, ring,
    /// triangle, diamond, half, tick, cross — so they separate by shape before
    /// colour is considered at all.
    var glyph: String {
        switch self {
        case .late:      "▲"
        case .dueToday:  "◷"
        case .running:   "●"
        case .queued:    "◌"
        case .finishing: "◑"
        case .done:      "✓"
        case .blocked:   "◆"
        case .quoted:    "◇"
        case .offline:   "✕"
        }
    }

    /// The word's locale key. A key rather than a string because these are
    /// read by a shop in two languages, and §9 is explicit that the Arabic
    /// copy is still to come — a literal here would be the thing that has to
    /// be hunted down later.
    var wordKey: String {
        switch self {
        case .late:      "mac.state_late"
        case .dueToday:  "mac.state_today"
        case .running:   "mac.state_running"
        case .queued:    "mac.state_queued"
        case .finishing: "mac.state_finishing"
        case .done:      "mac.state_done"
        case .blocked:   "mac.state_blocked"
        case .quoted:    "mac.state_quoted"
        case .offline:   "mac.state_offline"
        }
    }

    /// The hue — the third of the three signals, never the only one.
    var tint: Color {
        switch self {
        case .late, .blocked:      Role.late
        case .dueToday, .finishing: Role.warn
        case .running:             Role.ok
        case .queued, .done:       Role.text2
        case .quoted, .offline:    Role.text3
        }
    }

    /// The tinted ground behind a row or chip in this state, where it has one.
    /// Most states do not: a table where every row is tinted has no tinted
    /// rows, only stripes.
    var ground: Color? {
        switch self {
        case .late, .blocked: Role.lateBg
        case .dueToday:       Role.warnBg
        case .running:        Role.okBg
        default:              nil
        }
    }

    /// A finished job is drawn back, not away: still legible, plainly over.
    var rowOpacity: Double { self == .done ? 0.55 : 1 }
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
