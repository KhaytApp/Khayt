import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// S4 part 2 on the Mac: what Simple draws SMALLER (Figma Qqxg4imtKVgC3TfNGcRGOk
/// page 09, card 6) — the four-column board and the customer's five fields.
@MainActor
struct SimpleReducedTests {

    static func shop(mode: String?) async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        if let mode { shop.pretendMode(mode) }
        await shop.readFeatures()
        await shop.readSimpleFiling()
        return shop
    }

    @Test("Simple: four columns, every open job filed by the shared rule")
    func board() async {
        let simple = await Self.shop(mode: "simple")
        #expect(simple.engineProblem == nil, "no engine means this proves nothing")
        #expect(simple.reducedInSimple("queue") && simple.reducedInSimple("customers"))
        #expect(simple.boardColumns == [.quote, .pending, .printing, .completed])
        let lanes = simple.board
        #expect(Set(lanes.keys).isSubset(of: Set(Shop.simpleBoardColumns)), "nothing outside the four")
        // Every job the rule files is on the board, in the column it names.
        for order in simple.orders where simple.inSite(order) {
            guard let col = simple.simpleColumn(order) else { continue }
            #expect(lanes[col]?.contains { $0.id == order.id } == true, "\(order.id)")
        }
        // A job on hold is under Queued, with a note.
        if let held = simple.orders.first(where: { Stage.of($0) == .on_hold }) {
            #expect(simple.simpleColumn(held) == .pending)
            #expect(Kanban.simpleNote(simple.simpleFiling[held.id], words: simple.words) != nil)
        }
        // Ready is the newest first.
        let ready = (lanes[.completed] ?? []).compactMap(\.completedAt)
        #expect(ready == ready.sorted(by: >))
        #expect(Kanban.titleKey(.pending, simple: true) == "sm.col_queued")
        #expect(Kanban.titleKey(.pending, simple: false) == Stage.pending.key)
    }

    @Test("Professional: every stage is a column, and nothing is filed")
    func professional() async {
        let pro = await Self.shop(mode: nil)
        #expect(!pro.reducedInSimple("queue"))
        #expect(pro.boardColumns == Stage.boardColumns)
        #expect(pro.simpleFiling.isEmpty)
    }

    @Test("the customer form in Simple hides the business rows and keeps what is saved")
    func customerForm() {
        let code = MenuCoverageTests.source("CustomerSheet.swift")
        #expect(code.contains("private var simple: Bool { shop.reducedInSimple(\"customers\") }"))
        #expect(code.contains("if !simple || !draft.currency.isEmpty {"))
        #expect(code.contains("sm.cust_business"))
        // Hidden rows still edit the draft, so a save writes them back unchanged.
        #expect(code.contains("TextField(\"\", text: binding(\\.cr))"))
    }
}
