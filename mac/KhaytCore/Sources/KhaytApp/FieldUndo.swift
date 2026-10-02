import Foundation
import KhaytCore

/// Undo, one FIELD at a time.
///
/// ── WHY NOT THE WHOLE RECORD ──────────────────────────────────────────────
///
/// Undo used to put back the record as it was before the action — every
/// field — and bump `rev`, so the stale copy won everywhere, including on
/// every other machine. Anything written to that record in between that was
/// not on this Mac's undo stack was lost: a phone's fold, a cloud merge, a
/// LAN payment, a remeasure, another job's deduction from the same spool.
///
/// The case that found it: complete a job (spool 1000 → 800), receive a
/// 1000 g delivery onto the same spool (→ 1800), ⌘Z. The spool read 1000 —
/// the delivery was gone, while the purchase order still said received.
///
/// So an undo now knows what the action wrote (`now`) as well as what was
/// there before (`was`), and for each field the action changed:
///
/// - if the field still holds what the action wrote, the old value goes back;
/// - if someone has written it since, it is LEFT, and the undo says so;
/// - a quantity (a spool's grams, a consumable's stock) is put back by the
///   inverse DELTA — what the action took is added back to whatever is there
///   now — so a delivery or another job's deduction in between survives;
/// - an array the action appended to (a spool's usage history, a supplier's
///   purchase log) has just those entries taken out again.
///
/// A record the action CREATED is removed only if nobody has changed it
/// since; a record the action DELETED is put back if it is still absent.
extension Shop {

    /// What an action did to one record.
    enum UndoKind: Sendable, Equatable {
        /// The record was there before and after; `was` and `now` are both.
        case edited
        /// The action made it; `now` is what it wrote. Undo removes it.
        case created
        /// The action removed it; `was` is what it was. Undo puts it back.
        case deleted
    }

    /// The fields an undo never compares or restores: they are the record's
    /// own bookkeeping and are stamped forward on every write.
    nonisolated static let undoBookkeeping: Set<String> = ["rev", "updatedAt"]

    /// Quantities undone by the inverse delta rather than by value, per
    /// collection. These are the fields `lib/order-deduction.js` subtracts
    /// from — the ones another action is most likely to have moved since.
    nonisolated static let undoByDelta: [String: Set<String>] = [
        "inventory": ["weight"],
        "consumables": ["stock"],
    ]

    /// What an undo did, and what it could not.
    struct UndoOutcome {
        /// What Redo needs — itself a field-level change set.
        var redo: [ChangedRecord] = []
        /// Fields (and records) left alone because they had changed since,
        /// in a form a person can read: `weight (INV-1)`.
        var notUndone: [String] = []
    }

    /// Fill in what the action wrote, from the book as the write left it.
    ///
    /// Called at the END of each write closure — after every stamp — so the
    /// after-copy is exactly what reached the file. A record already carrying
    /// its after-copy (`write(_:_:changed:before:into:)` fills it in itself)
    /// is left as it is.
    static func sealUndo(_ undo: inout [ChangedRecord], in root: [String: JSONValue]) {
        for i in undo.indices where undo[i].now == nil && undo[i].kind != .deleted {
            let id = undo[i].id
            if let row = rows(root, undo[i].collection).first(where: { recordId($0) == id }),
               case .object(let now) = row {
                undo[i].now = now
            }
        }
    }

    /// Undo one record's fields. `current` is the record as the book has it
    /// now. Returns the record to write, whether anything changed, and the
    /// fields left alone because someone wrote them since.
    nonisolated static func undoFields(current: [String: JSONValue],
                                       was: [String: JSONValue],
                                       now: [String: JSONValue],
                                       byDelta: Set<String>)
    -> (record: [String: JSONValue], changed: Bool, kept: [String]) {
        var out = current
        var changed = false
        var kept: [String] = []
        for key in Set(was.keys).union(now.keys).subtracting(undoBookkeeping).sorted() {
            let before = was[key], after = now[key], present = current[key]
            guard before != after else { continue }

            // A quantity: add back what the action took (or take back what it
            // added), onto whatever is there NOW.
            if byDelta.contains(key), let b = number(before), let a = number(after) {
                guard let c = number(present) else { kept.append(key); continue }
                let restored = ((c + (b - a)) * 1_000_000).rounded() / 1_000_000
                if out[key] != .number(restored) {
                    out[key] = .number(restored)
                    changed = true
                }
                continue
            }

            // Untouched since: the old value goes back.
            if present == after {
                out[key] = before            // nil removes a field the action added
                changed = true
                continue
            }

            // An array the action added entries to, written since: take out
            // just the entries it added, if every one of them is still there.
            // A list the action started (absent before) counts as empty then;
            // if nothing else is left in it, it goes away as it came.
            let wasList: [JSONValue]? = {
                if case .array(let l)? = before { return l }
                return before == nil ? [] : nil
            }()
            if let wasList, case .array(let nowList)? = after,
               case .array(let curList)? = present {
                let added = subtracting(wasList, from: nowList)
                if !added.isEmpty, let trimmed = removing(added, from: curList) {
                    out[key] = (before == nil && trimmed.isEmpty) ? nil : .array(trimmed)
                    changed = true
                    continue
                }
            }

            // Someone else wrote it: theirs stands.
            if present != before { kept.append(key) }
        }
        return (out, changed, kept)
    }

    /// Undo a whole change set on a book in memory. Pure, so a test can drive
    /// it with a plain book; `restoreMove` runs it inside the write.
    static func undoing(_ snapshot: [ChangedRecord],
                        in root: inout [String: JSONValue]) -> UndoOutcome {
        var outcome = UndoOutcome()
        // Collections in the order the action first touched them, so a redo
        // lists its records the same way.
        var order: [String] = []
        for r in snapshot where !order.contains(r.collection) { order.append(r.collection) }

        for collection in order {
            var records = rows(root, collection)
            var touched = false
            let deltas = undoByDelta[collection] ?? []
            for change in snapshot where change.collection == collection {
                let at = records.firstIndex(where: { recordId($0) == change.id })
                switch change.kind {
                case .created:
                    guard let at, case .object(let current) = records[at] else { continue }
                    if let now = change.now,
                       stripped(current) == stripped(now) {
                        records.remove(at: at)
                        touched = true
                        outcome.redo.append(ChangedRecord(collection: collection, id: change.id,
                                                          was: current, kind: .deleted, at: at))
                    } else {
                        outcome.notUndone.append(label(change.id, nil))
                    }

                case .deleted:
                    guard at == nil else { continue }   // already back
                    let slot = min(change.at ?? records.count, records.count)
                    records.insert(.object(change.was), at: slot)
                    touched = true
                    outcome.redo.append(ChangedRecord(collection: collection, id: change.id,
                                                      was: [:], now: change.was, kind: .created))

                case .edited:
                    guard let at, case .object(let current) = records[at] else {
                        outcome.notUndone.append(label(change.id, nil))
                        continue
                    }
                    guard let now = change.now else {
                        // No after-copy: nothing can be compared, so nothing
                        // is put back rather than a stale whole record.
                        outcome.notUndone.append(label(change.id, nil))
                        continue
                    }
                    var (next, changed, kept) = undoFields(current: current, was: change.was,
                                                           now: now, byDelta: deltas)
                    outcome.notUndone += kept.map { label(change.id, $0) }
                    guard changed else { continue }
                    // `rev` carries on from where the record is NOW: a revision
                    // that went backwards would read to the next sync as the
                    // change never having happened.
                    next["rev"] = current["rev"]
                    StoreWriter.stamp(&next)
                    records[at] = .object(next)
                    touched = true
                    outcome.redo.append(ChangedRecord(collection: collection, id: change.id,
                                                      was: current, now: next))
                }
            }
            if touched { root[collection] = .array(records) }
        }
        return outcome
    }

    /// The sentence a partial undo is reported with, or nil when it was whole.
    static func partialUndoSentence(_ notUndone: [String], words: Words) -> String? {
        guard !notUndone.isEmpty else { return nil }
        return words.callIt("mac.undo_partial", ["fields": .string(notUndone.joined(separator: ", "))])
    }

    // MARK: - Helpers

    nonisolated private static func number(_ value: JSONValue?) -> Double? {
        if case .number(let n)? = value { return n }
        return nil
    }

    nonisolated private static func stripped(_ record: [String: JSONValue]) -> [String: JSONValue] {
        record.filter { !undoBookkeeping.contains($0.key) }
    }

    nonisolated private static func label(_ id: String, _ field: String?) -> String {
        guard let field else { return id }
        return "\(field) (\(id))"
    }

    /// `list` with one of each of `taken` removed — a multiset difference.
    nonisolated static func subtracting(_ taken: [JSONValue], from list: [JSONValue]) -> [JSONValue] {
        var counts: [JSONValue: Int] = [:]
        for v in taken { counts[v, default: 0] += 1 }
        var out: [JSONValue] = []
        for v in list {
            if let n = counts[v], n > 0 { counts[v] = n - 1 } else { out.append(v) }
        }
        return out
    }

    /// `list` without `entries`, or nil when any of them is no longer there.
    nonisolated static func removing(_ entries: [JSONValue], from list: [JSONValue]) -> [JSONValue]? {
        var out = list
        for v in entries {
            guard let i = out.firstIndex(of: v) else { return nil }
            out.remove(at: i)
        }
        return out
    }
}
