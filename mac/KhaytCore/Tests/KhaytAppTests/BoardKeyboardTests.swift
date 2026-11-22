import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Walking the board with the arrow keys.
///
/// The board had no keyboard at all — `onKeyPress` appeared on exactly one
/// screen in this app, the library — and a board is the screen people use with
/// one hand while the other is holding a part.
///
/// The movement is tested here rather than through the view, because a
/// `KeyPress` cannot be synthesised and a SwiftUI body cannot be asked what it
/// would do. What the view owns is the mapping from a key to a direction and
/// the mirrored-layout correction; what `Shop` owns is where the selection
/// lands, which is everything that can be got wrong silently.
@MainActor
struct BoardKeyboardTests {

    /// Two columns with two jobs and one, and a gap between them — the empty
    /// column is the case that decides whether walking across a board with
    /// seven columns and three in use takes one press or four.
    static func shop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    /// ONLY the stages the board actually draws.
    ///
    /// `shop.board` is keyed by whatever stage a job is in, and `delivered`
    /// and `cancelled` are not columns. A fixture that picked one of those
    /// looked like a two-card column and was invisible to the walk, which
    /// sent it down the "nothing selected" path and made the movement look
    /// broken when it was the test that was wrong.
    static func drawn(_ shop: Shop) -> [(Stage, [Order])] {
        Stage.boardColumns.compactMap { stage in
            let jobs = shop.board[stage] ?? []
            return jobs.isEmpty ? nil : (stage, jobs)
        }
    }

    @Test("with nothing selected, the first press picks a card rather than doing nothing")
    func firstPressPicks() async {
        let shop = await Self.shop()
        shop.selection = nil
        #expect(shop.moveBoardSelection(dx: 1, dy: 0), "the sample board is empty — the test proves nothing")
        #expect(shop.selection != nil, "the first press must land somewhere")
    }

    @Test("down moves within a column and stops at its end")
    func downWalksAColumn() async {
        let shop = await Self.shop()
        // A column with at least two cards in it.
        guard let (_, jobs) = Self.drawn(shop).first(where: { $0.1.count >= 2 }) else {
            Issue.record("the sample book has no column with two jobs — fixture is wrong"); return
        }
        shop.selection = jobs[0].id
        #expect(shop.moveBoardSelection(dx: 0, dy: 1))
        #expect(shop.selection == jobs[1].id)

        // And the end stops, rather than wrapping to the top or to the next
        // column — a wrap reads as the selection vanishing.
        shop.selection = jobs[jobs.count - 1].id
        #expect(!shop.moveBoardSelection(dx: 0, dy: 1), "the last card must refuse, so the beep means something")
        #expect(shop.selection == jobs[jobs.count - 1].id, "a refused move must not move anything")
    }

    @Test("up from the first card refuses, and leaves the selection alone")
    func upFromTheTopRefuses() async {
        let shop = await Self.shop()
        guard let (_, jobs) = Self.drawn(shop).first else {
            Issue.record("empty board"); return
        }
        shop.selection = jobs[0].id
        #expect(!shop.moveBoardSelection(dx: 0, dy: -1))
        #expect(shop.selection == jobs[0].id)
    }

    /// The case the skip exists for.
    @Test("walking sideways crosses empty columns instead of stopping in one")
    func sidewaysSkipsEmptyColumns() async {
        let shop = await Self.shop()
        let filled = Stage.boardColumns.filter { !(shop.board[$0] ?? []).isEmpty }
        guard filled.count >= 2 else { Issue.record("need two occupied columns"); return }
        // Start at the leftmost occupied column.
        guard let first = shop.board[filled[0]]?.first else { Issue.record("no card"); return }
        shop.selection = first.id
        #expect(shop.moveBoardSelection(dx: 1, dy: 0))
        // It must land on a card, never on an empty column — the selection
        // going nil is the failure this guards.
        #expect(shop.selection != nil, "walking right landed on nothing")
        #expect(shop.selection != first.id, "walking right did not move")
        let landed = Stage.boardColumns.first { (shop.board[$0] ?? []).contains { $0.id == shop.selection } }
        #expect(landed != nil, "the selection is not on the board any more")
    }

    @Test("the far edge refuses rather than wrapping round")
    func edgesRefuse() async {
        let shop = await Self.shop()
        let filled = Stage.boardColumns.filter { !(shop.board[$0] ?? []).isEmpty }
        guard let last = filled.last, let card = shop.board[last]?.first else {
            Issue.record("empty board"); return
        }
        shop.selection = card.id
        #expect(!shop.moveBoardSelection(dx: 1, dy: 0), "the rightmost column must refuse")
        #expect(shop.selection == card.id)
    }

    /// ⌘ belongs to the menu's Move Along; a bare arrow must not move a job.
    ///
    /// Read as source, because the modifier check lives in the view and a
    /// `KeyPress` cannot be made in a test.
    @Test("a bare arrow navigates and never moves a job")
    func bareArrowDoesNotMoveAJob() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/Kanban.swift")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(!text.isEmpty, "Kanban.swift was not read — this would pass vacuously")
        #expect(text.contains("guard !press.modifiers.contains(.command) else { return .ignored }"),
                "the board swallows ⌘-arrow, so the menu's Move Along would move the job AND the selection")
        #expect(text.contains("moveBoardSelection"), "the board's arrows are not wired")
        // And the mirrored correction, which is invisible in an English window.
        #expect(text.contains("layout == .rightToLeft"),
                "a right arrow walks backwards in an Arabic window")
    }
}
