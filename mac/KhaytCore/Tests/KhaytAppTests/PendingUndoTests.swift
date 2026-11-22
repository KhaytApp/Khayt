import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// An undo goes on the stack at the click, for a write still running, and a
/// write that lands nothing takes its entry off again (`PendingUndo`).
///
/// Since the saves stopped holding the window, a write takes a second or two
/// with the window live. A delete or a job move that registered its undo
/// when the write came back put it on the stack after whatever the shop did
/// meanwhile — and ⌘Z pressed during the write undid the previous change.
@MainActor
struct PendingUndoTests {

    static func manager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    @Test("the entry is there at once, and a dropped write takes it off at once")
    func droppedTakesItOff() {
        let shop = Shop()
        let undo = Self.manager()
        shop.undoManager = undo
        undo.beginUndoGrouping()
        let pending: PendingUndo<[String]> = shop.pendingUndo(named: "x") { _, _ in }
        undo.endUndoGrouping()
        #expect(undo.canUndo, "the undo waited for the write")
        pending.drop()
        #expect(!undo.canUndo, "a write that failed left an entry that does nothing")
        pending.keep(["late"])  // after a drop: nothing
        #expect(!undo.canUndo)
        shop.undoManager = nil
    }

    @Test("Undo pressed before the write lands waits for it, then puts back what it took")
    func undoWaitsForTheWrite() async throws {
        let shop = Shop()
        let undo = Self.manager()
        shop.undoManager = undo
        var putBack: [String] = []
        undo.beginUndoGrouping()
        let pending: PendingUndo<[String]> = shop.pendingUndo(named: "x") { _, value in putBack = value }
        undo.endUndoGrouping()
        undo.undo()
        await Task.yield()
        #expect(putBack.isEmpty, "Undo put back something the write had not taken yet")
        pending.keepUnlessEmpty(["S1"])
        for _ in 0..<60_000 where putBack.isEmpty { try await Task.sleep(for: .milliseconds(10)) }  // a hang guard (10 min), not a speed limit: the runner is shared
        #expect(putBack == ["S1"])
        shop.undoManager = nil
    }

    /// `removeAllActions(withTarget:)` does not reach into an open group, so a
    /// write refused before its click's group closed left a dead entry.
    @Test("a write dropped while its group is still open is taken off once the group closes")
    func droppedInsideAnOpenGroup() async throws {
        let shop = Shop()
        let undo = Self.manager()
        shop.undoManager = undo
        var ran = false
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: shop) { _ in ran = true }
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        let pending: PendingUndo<[String]> = shop.pendingUndo(named: "x") { _, _ in }
        pending.drop()
        undo.endUndoGrouping()
        // The removal waits for the group to close; give it a moment, then ONE ⌘Z.
        try await Task.sleep(for: .milliseconds(300))
        undo.undo()
        #expect(ran, "⌘Z was swallowed by the dropped entry instead of reaching the change before it")
        shop.undoManager = nil
    }

    @Test("keeping nothing is dropping")
    func keepingNothing() {
        let shop = Shop()
        let undo = Self.manager()
        shop.undoManager = undo
        undo.beginUndoGrouping()
        let pending = shop.pendingMoveUndo(named: "move")
        undo.endUndoGrouping()
        #expect(undo.canUndo)
        pending.keepUnlessEmpty([])
        #expect(!undo.canUndo, "a move that changed nothing left an undo")
        shop.undoManager = nil
    }
}

extension LibraryEditPerfTests {

    /// A move the book refuses — the job is not there — leaves no undo behind,
    /// though its entry went on the stack at the click.
    @Test("a job move that fails leaves nothing on the undo stack")
    func failedMoveLeavesNoUndo() async throws {
        try await withPerfBook(Self.shopBook(models: 10)) { shop, _ in
            let undo = UndoManager()
            undo.groupsByEvent = false
            shop.undoManager = undo
            undo.beginUndoGrouping()
            await shop.moveJob("NO-SUCH-JOB", to: .printing)
            undo.endUndoGrouping()
            // Dropped while the move's own group was still open, so taken off
            // once it closed (`PendingUndo.drop`).
            for _ in 0..<30_000 where undo.canUndo { try await Task.sleep(for: .milliseconds(20)) }  // a hang guard (10 min), not a speed limit: the runner is shared
            #expect(!undo.canUndo, "a dead entry swallows the next ⌘Z")
            shop.undoManager = nil
        }
    }

    /// The delete's undo is on the stack before the write is back, and Undo
    /// puts the spool back in the book AND on screen (it used not to reload).
    @Test("undoing a spool delete puts it back on disk and on screen")
    func spoolDeleteUndo() async throws {
        var book = Self.shopBook(models: 10)
        book["inventory"] = .array([
            .object(["id": .string("SPERF1"), "material": .string("PLA"), "weight": .number(800),
                     "cost": .number(90), "rev": .number(1)]),
        ])
        try await withPerfBook(book) { shop, url in
            let undo = UndoManager()
            undo.groupsByEvent = false
            shop.undoManager = undo
            #expect(shop.spools.contains { $0.id == "SPERF1" })
            undo.beginUndoGrouping()
            await shop.deleteSpool("SPERF1")
            undo.endUndoGrouping()
            #expect(shop.spendProblem == nil)
            #expect(try Self.onDisk(url, "inventory", "SPERF1") == nil, "the delete never reached the book")
            #expect(!shop.spools.contains { $0.id == "SPERF1" })
            #expect(undo.canUndo)

            undo.undo()
            var back = false
            for _ in 0..<600 {
                back = shop.spools.contains { $0.material == "PLA" && $0.weight == 800 }
                if back { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(back, "the spool came back to the book but not to the screen")
            let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
            #expect(Shop.rows(root, "inventory").count == 1, "the spool never came back to the book")
            shop.undoManager = nil
        }
    }
}
