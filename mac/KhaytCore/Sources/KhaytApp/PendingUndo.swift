import Foundation

/// An undo put on the stack AT THE CLICK, for a write still on its way to the
/// book — kept when the write lands, taken off again when it does not.
///
/// ── WHY NOT "REGISTER IT WHEN THE WRITE IS BACK" ─────────────────────────
///
/// Since the saves stopped holding the window (#1865, #1866), a write takes a
/// second or two with the window live. An undo registered when it came back
/// went on the stack after whatever the shop did meanwhile, and ⌘Z pressed
/// during the write undid the shop's PREVIOUS change instead of this one.
/// So the entry is registered first, against `landed`, the way the library's
/// own edits do it (`Shop.registerUndo(after:named:)`), and Undo waits for the
/// write when it has to.
///
/// ── A WRITE THAT FAILS TAKES ITS UNDO WITH IT ─────────────────────────────
///
/// `drop()` — on a refusal, an error, or nothing to put back — takes exactly
/// this entry off the stack, synchronously, so ⌘Z is never swallowed by an
/// entry that does nothing. Every path out of the write must end in `keep` or
/// `drop`; a `defer { pending.drop() }` makes that so (a second call is a
/// no-op).
@MainActor
final class PendingUndo<Value: Sendable> {
    /// What Undo puts back, once the write has landed; nil if it never did.
    let landed: Task<Value?, Never>
    /// This entry's own target, so it alone can be taken off the stack.
    let ticket = UndoTicket()
    private let continuation: AsyncStream<Value>.Continuation
    private weak var undoManager: UndoManager?
    private var open = true

    init(_ undoManager: UndoManager?) {
        let (stream, continuation) = AsyncStream<Value>.makeStream()
        self.continuation = continuation
        self.undoManager = undoManager
        landed = Task {
            for await value in stream { return value }
            return nil
        }
    }

    /// The write landed and `value` is what Undo puts back.
    func keep(_ value: Value) {
        guard open else { return }
        open = false
        continuation.yield(value)
        continuation.finish()
    }

    /// The write did not land, or changed nothing: no undo.
    func drop() {
        guard open else { return }
        open = false
        undoManager?.removeAllActions(withTarget: ticket)
        continuation.finish()
    }
}

extension Shop {

    /// `registerMoveUndo`, registered now for a write still running: Undo
    /// waits for the write, then restores what it changed (and registers its
    /// Redo, inside the undo, as `restoreMove` always does).
    func pendingMoveUndo(named actionName: String) -> PendingUndo<[ChangedRecord]> {
        let pending = PendingUndo<[ChangedRecord]>(undoManager)
        guard let undoManager else { return pending }
        let landed = pending.landed, ticket = pending.ticket
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: ticket) { [weak self] _ in
            // The entry holds the ticket alive for as long as it exists.
            _ = ticket
            self?.restoreMove(after: landed, named: actionName)
        }
        return pending
    }

    /// A delete's undo, registered now for a write still running: Undo waits
    /// for the write, then `putBack` restores what it took. `putBack` asks
    /// the staff lock itself, at undo time, like every other write.
    func pendingUndo<Value: Sendable>(named actionName: String,
                                      putBack: @escaping @MainActor (Shop, Value) -> Void) -> PendingUndo<Value> {
        let pending = PendingUndo<Value>(undoManager)
        guard let undoManager else { return pending }
        let landed = pending.landed, ticket = pending.ticket
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: ticket) { [weak self] _ in
            _ = ticket
            guard let self else { return }
            Task { @MainActor in
                if let value = await landed.value { putBack(self, value) }
            }
        }
        return pending
    }
}

extension PendingUndo where Value: Collection {
    /// `keep`, or `drop` when there is nothing to put back.
    func keepUnlessEmpty(_ value: Value) {
        if value.isEmpty { drop() } else { keep(value) }
    }
}
