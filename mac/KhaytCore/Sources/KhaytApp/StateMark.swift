import SwiftUI
import AppKit
import CoreText

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
    // `cancelled` is here and not above: a job the shop stopped is not
    // asking for anything. It is where the work went to stop being work, and
    // it must be as quiet on the eye as `done` is.
    case running, queued, finishing, done, cancelled, quoted, offline

    /// ── SILHOUETTE SEPARATES KINDS; FILL SEPARATES SEVERITY ─────────────
    ///
    /// And fill only ever separates severity INSIDE one kind: ■/□ for a
    /// machine, ▼/▽ for stock. Across kinds the silhouettes differ outright.
    ///
    /// `◆` is retired for exactly this reason. Filled against hollow is the
    /// hardest distinction in the app at 9.5pt, and `◆` was asking the eye to
    /// make it against `◇` in the OTHER table — to learn whether a machine
    /// needed looking at or a job was only a quote. No glyph appears in both
    /// tables now.
    ///
    /// A new kind brings a new silhouette, never a new fill of an existing
    /// one. If the silhouettes run out, the set is too big and a kind should
    /// merge.
    ///
    /// ── AND THE NOZZLE KIND HAD RUN OUT ─────────────────────────────────
    ///
    /// It was `⊘` and `◔`: two unrelated silhouettes for ONE kind, which is
    /// the rule above read backwards. The order kind was the same — `▲` and
    /// `◷` share nothing. Both are fill pairs now, the way the machine and
    /// stock kinds always were, and freeing `⊘` is what let `cancelled` have
    /// a mark at all.
    ///
    /// ── WHICH FACE EACH OF THESE IS ACTUALLY DRAWN IN ───────────────────
    ///
    /// MEASURED, and it is worse than anybody had looked: of the fifteen
    /// glyphs this set used, only seven were in the system face. The other
    /// eight fell back to SEVEN different typefaces — `◔` and `◷` and `✉` to
    /// **Menlo**, `⊘` to AppleSymbols, `◌` to SF Arabic, `◑` to Hiragino,
    /// `◇` to the CJK fallback, `✕` to Zapf Dingbats. A row of chips was set
    /// in up to eight cuts at once, which is the same defect `RiyalMark`
    /// exists for: a mark borrowed from another face reads as borrowed.
    ///
    /// So a glyph here is CHOSEN BY ASKING THE FONT, never by looking at a
    /// character map. `StateGlyphTests` holds the two rules that came out of
    /// it: every mark must draw something, and the two marks of one kind must
    /// come from ONE face — or the pair reads as two different weights, which
    /// is exactly what `⊘` beside `◔` was doing.
    ///
    /// `⊗` for a cancelled job is in the system face, and it is not a new
    /// invention either: `Stage.cancelled` has drawn `xmark.circle` since it
    /// was written.
    var glyph: String {
        switch self {
        case .orderLate:      "▲"
        case .orderToday:     "△"
        case .machineStopped: "■"
        case .machineCheck:   "□"
        case .nozzleBlocked:  "⬢"
        case .nozzleWorn:     "⬡"
        case .stockOut:       "▼"
        case .stockLow:       "▽"
        case .running:        "●"
        case .queued:         "○"
        case .finishing:      "◑"
        case .done:           "✓"
        case .cancelled:      "⊗"
        case .quoted:         "◇"
        case .offline:        "⊘"
        }
    }

    /// ── THE FACE A MARK IS DRAWN IN, CHOSEN RATHER THAN FALLEN INTO ────
    ///
    /// MEASURED: of the fifteen marks this set used, SEVEN were in the system
    /// face and the other eight fell back to SEVEN DIFFERENT TYPEFACES — `◔`,
    /// `◷` and `✉` to Menlo, a typewriter face; `⊘` to Apple Symbols; `◌` to
    /// SF Arabic; `◑` to Hiragino; `◇` to the CJK fallback; `✕` to Zapf
    /// Dingbats, which is a dingbat font. A row of chips was set in up to
    /// eight cuts at once, at eight different weights and optical sizes.
    ///
    /// Nobody chose that. A character map says a glyph EXISTS and says nothing
    /// about which face will draw it, so the fallback chain was choosing, and
    /// it chooses per character.
    ///
    /// ── TWO FACES, AND WHY NOT ONE ────────────────────────────────────────
    ///
    /// The system face carries about twenty usable geometric marks and this
    /// vocabulary needs fourteen with distinct meanings. Forcing all of them
    /// into it means assignments that are available rather than apt — a STAR
    /// standing for a quote — and a mark that has to be learnt is worse than
    /// one drawn a quarter-point light.
    ///
    /// So: the system face wherever it has the mark, and Apple Symbols for the
    /// rest, named here rather than arrived at. It was the only family
    /// measured that carries every remaining one. `StateGlyphTests` holds the
    /// set to those two.
    var face: String? {
        switch self {
        // Drawn by the system face, which is every mark this app could get
        // from it without inventing a meaning.
        case .orderLate, .orderToday, .machineStopped, .machineCheck,
             .stockOut, .stockLow, .running, .queued, .done, .cancelled:
            return nil
        // The ones it does not have. One family, so they at least agree with
        // each other — the pair `⬢`/`⬡` came from here already and `⊘`, freed
        // when the nozzle kind merged, is a better "not reachable" than the
        // Zapf Dingbats `✕` it replaces.
        case .nozzleBlocked, .nozzleWorn, .finishing, .quoted, .offline:
            return "Apple Symbols"
        }
    }

    /// ── AND THE SIZE, BECAUSE NAMING THE FACE EXPOSED THE NEXT PROBLEM ──
    ///
    /// Two faces agreeing on WHICH cut does not make them agree on how big.
    /// Measured at 10pt: the system face draws its marks at a mean height of
    /// 7.43 points and Apple Symbols draws these at 6.13 — so once every mark
    /// was in its chosen face, the five from Apple Symbols were visibly small
    /// and light beside the nine that were not. The hexagons read as dots.
    ///
    /// Found by drawing all fourteen chips in ONE picture, which nothing in
    /// this app had ever done: every chip appears beside jobs and machines and
    /// never beside the other thirteen, so a set that is wrong AS A SET looks
    /// fine everywhere. `ShellSnapshots.everyState` is that picture now.
    ///
    /// COMPUTED, not a constant. The ratio is read off the faces themselves at
    /// the size being asked for, so it cannot drift when a face is swapped or
    /// macOS reships one — and a number like `1.213` written into this file
    /// would be a measurement nobody could check.
    func markSize(_ base: CGFloat) -> CGFloat {
        guard let name = face, let mine = NSFont(name: name, size: base) else { return base }
        let system = NSFont.systemFont(ofSize: base, weight: .semibold)
        // The system face's own marks vary — a triangle is shorter than a
        // circle — so the target is their MEAN rather than any one of them.
        // Matching a diamond to the tallest would overshoot every time.
        let want = ["▲", "■", "●", "✓"].map { Self.drawnHeight($0, in: system) }
        let got = Self.drawnHeight(glyph, in: mine)
        let mean = want.reduce(0, +) / CGFloat(want.count)
        guard got > 0, mean > 0 else { return base }
        return base * mean / got
    }

    /// How tall a face actually DRAWS a character — the glyph's own bounding
    /// box, not the point size, which is the em and tells you nothing about
    /// what lands on screen.
    static func drawnHeight(_ glyph: String, in font: NSFont) -> CGFloat {
        var units = Array(glyph.utf16)
        var ids = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font as CTFont, &units, &ids, units.count) else {
            return 0
        }
        return CTFontGetBoundingRectsForGlyphs(font as CTFont, .horizontal, &ids, nil,
                                               ids.count).height
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
        // The word the whole app already uses for this, rather than a
        // second spelling of it invented for one chip.
        case .cancelled:      "mac.cancelled"
        case .quoted:         "mac.state_quoted"
        case .offline:        "mac.state_offline"
        }
    }

    var tint: Color {
        switch self {
        case .orderLate, .machineStopped, .nozzleBlocked, .stockOut: Role.late
        case .orderToday, .machineCheck, .nozzleWorn, .stockLow, .finishing: Role.warn
        case .running:                     Role.ok
        case .queued, .done:               Role.text2
        case .quoted, .offline, .cancelled: Role.text3
        }
    }

    var ground: Color? {
        switch self {
        case .orderLate, .machineStopped, .nozzleBlocked, .stockOut: Role.lateBg
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
        case .running, .queued, .finishing, .done, .cancelled,
             .quoted, .offline: false
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

    /// How wide a column of these needs to be.
    ///
    /// ── MEASURED, AND THE OLD NUMBER FITTED HALF THE VOCABULARY ──────────
    ///
    /// The ledger pinned its chip column at 78 points. EIGHT of the sixteen
    /// English words are wider than that — "DUE TODAY" is 95, "FINISHING" 91,
    /// "PRINTING" 87 — so those chips wrapped onto a second line and made
    /// their row taller than every other. It went unseen because the sample
    /// book's unsettled jobs only ever reached the short words; adding
    /// "CANCELLED", which is the widest at 100, is what put one on screen.
    ///
    /// `StateChipFitsTests` measures every word in both languages against
    /// this, so the next one that does not fit fails a test instead of
    /// reflowing a row.
    static let column: CGFloat = 104

    var body: some View {
        HStack(spacing: Space.xs) {
            // The mark in ITS face, not whichever one the fallback chain
            // reaches for — see `ShopState.face`.
            Text(state.glyph)
                .font(state.face.flatMap {
                    NSFont(name: $0, size: state.markSize(10)).map(Font.init)
                })
            Text(words.callIt(state.wordKey).uppercased())
                .tracking(0.9)
        }
        // A chip is one line. Wrapping one silently changes the height of the
        // row it is in, which is how this was invisible for as long as it was.
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
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

    /// What this chip needs, drawn. Here rather than in the test so there is
    /// ONE description of how a chip is set: a test carrying its own replica
    /// of the font, the tracking and the padding measures the replica.
    static func width(of state: ShopState, saying word: String) -> CGFloat {
        let face = NSFont.systemFont(ofSize: 10, weight: .heavy)
        let mark = NSAttributedString(string: state.glyph, attributes: [.font: face])
        let text = NSAttributedString(string: word.uppercased(),
                                      attributes: [.font: face, .kern: 0.9])
        return mark.size().width + text.size().width + Space.xs + 14
    }
}
