import AppKit
import KhaytCore
import Foundation
import Testing
@testable import KhaytApp

/// A chip is one line, and the column is wide enough for the widest word.
///
/// ── WHAT THIS EXISTS FOR ──────────────────────────────────────────────────
///
/// The ledger pinned its state column at 78 points, and EIGHT of the sixteen
/// English words are wider than that — "DUE TODAY" at 95, "FINISHING" at 91,
/// "PRINTING" at 87, "CANCELLED" at 100. Those chips wrapped onto a second
/// line, which made their row taller than every other row on the screen.
///
/// It went unseen for as long as it did because of what the sample book can
/// reach: its unsettled jobs only ever produced LATE, QUEUED and QUOTED, all
/// of which fit. The first long word to appear on that screen made it obvious
/// in one photograph — which is the argument `SampleShopTests` opens with,
/// arriving at the same conclusion from the other direction.
///
/// The measurement is `StateChip.width(of:saying:)`, which belongs to the view
/// rather than to this file. A test carrying its own copy of the font, the
/// tracking and the padding measures its own copy.
@MainActor
struct StateChipFitsTests {

    /// The states a JOB can be in — which is what the ledger's column has to
    /// hold.
    ///
    /// `failedToSend` is left out, and finding out why was worth the detour:
    /// it says "Not delivered", it is the widest chip in the set at 120pt, and
    /// **nothing in this app draws it**. Not one file outside `ShopState`
    /// mentions it. It is a MESSAGE's state sitting in a job's vocabulary with
    /// no caller — so widening every ledger row by twenty points to fit a chip
    /// that has never appeared would be paying for something that does not
    /// exist. Whatever screen eventually shows it sizes its own box.
    static let aJobCanBe = ShopState.allCases.filter { $0 != .failedToSend }

    @Test("every state's chip fits its column, in both languages")
    func everyChipFits() async throws {
        for language in Words.supported {
            let words = Words()
            await words.load(language, engine: try KhaytEngine())
            for state in Self.aJobCanBe {
                let said = words.callIt(state.wordKey)
                let width = StateChip.width(of: state, saying: said)
                #expect(width <= StateChip.column, Comment(rawValue: """
                    \(state) says "\(said)" in \(language), which needs \
                    \(Int(width.rounded()))pt in a \(Int(StateChip.column))pt column — \
                    the chip wraps and the row it is in gets taller than its neighbours
                    """))
            }
        }
    }

    /// And not so wide that the column is mostly air: a state column that
    /// could hold two of the longest word is space taken off the job's name,
    /// which is the thing a shop is actually scanning for.
    @Test("the column is not wider than the widest word needs")
    func theColumnIsNotPaddedOut() async throws {
        var widest: CGFloat = 0
        for language in Words.supported {
            let words = Words()
            await words.load(language, engine: try KhaytEngine())
            for state in Self.aJobCanBe {
                widest = max(widest, StateChip.width(of: state, saying: words.callIt(state.wordKey)))
            }
        }
        #expect(StateChip.column - widest < 20, """
            the column is \(Int(StateChip.column))pt and the widest chip needs \
            \(Int(widest.rounded()))pt — the difference is space taken off the job's name
            """)
    }
}
