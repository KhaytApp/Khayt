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
///   but only while the draw is still this action's to give back: if the
///   job's deduction marks or the spool's usage line have moved since (a
///   phone re-opened the job and returned the grams, a sync took another
///   copy of the spool), the quantity is LEFT and reported — added back
///   again it counted the same grams twice;
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

    /// The fields on a JOB that say whether its draw on the shelf stands —
    /// `lib/order-deduction.js` sets them when it takes stock and clears them
    /// when `returnForOrder` gives it back.
    nonisolated static let undoDeductionMarks: Set<String> = [
        "materialDeducted", "materialDrawn", "packagingDeducted",
    ]

    /// The collection jobs live in.
    nonisolated static let undoJobsCollection = "printLog"

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
    ///
    /// `deltasStand: false` means the stock this action moved has already been
    /// moved back by somebody else (see `deductionStillStands`): a quantity is
    /// then LEFT and reported, never added back a second time.
    nonisolated static func undoFields(current: [String: JSONValue],
                                       was: [String: JSONValue],
                                       now: [String: JSONValue],
                                       byDelta: Set<String>,
                                       deltasStand: Bool = true)
    -> (record: [String: JSONValue], changed: Bool, kept: [String]) {
        var out = current
        var changed = false
        var kept: [String] = []
        // ── A QUANTITY IS ONLY PUT BACK WHILE ITS DRAW IS STILL THERE ───────
        //
        // The action's usage-history lines are the spool's own record of the
        // draw. If they have gone (a phone re-opened the job and
        // `returnForOrder` took them out with the grams), or a line the action
        // took out is back (somebody re-drew it), the grams have already been
        // settled elsewhere — and adding the delta again counted them twice.
        // So did a sync tie that took another machine's copy of the spool,
        // which never had the draw at all.
        let historyStands = Self.historyStillStands(current: current, was: was, now: now)
        for key in Set(was.keys).union(now.keys).subtracting(undoBookkeeping).sorted() {
            let before = was[key], after = now[key], present = current[key]
            guard before != after else { continue }

            // A quantity: add back what the action took (or take back what it
            // added), onto whatever is there NOW.
            if byDelta.contains(key), let b = number(before), let a = number(after) {
                guard deltasStand, historyStands else { kept.append(key); continue }
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

    /// Whether the usage history the action wrote is still as it left it:
    /// every line it added is still there, and no line it removed is back.
    /// A record whose history the action did not touch always stands.
    nonisolated static func historyStillStands(current: [String: JSONValue],
                                               was: [String: JSONValue],
                                               now: [String: JSONValue]) -> Bool {
        let key = "usageHistory"
        func list(_ v: JSONValue?) -> [JSONValue] {
            if case .array(let l)? = v { return l }
            return []
        }
        let before = list(was[key]), after = list(now[key]), present = list(current[key])
        guard before != after else { return true }
        let added = subtracting(before, from: after)
        if !added.isEmpty, removing(added, from: present) == nil { return false }
        let removed = subtracting(after, from: before)
        if !removed.isEmpty {
            // Back again as many times as before the action: re-drawn since.
            var counts: [JSONValue: Int] = [:]
            for v in present { counts[v, default: 0] += 1 }
            var had: [JSONValue: Int] = [:]
            for v in before { had[v, default: 0] += 1 }
            if removed.contains(where: { (counts[$0] ?? 0) >= (had[$0] ?? 0) }) { return false }
        }
        return true
    }

    /// Whether the stock this change set moved is still this action's to give
    /// back: every job it changed still holds the deduction marks the action
    /// wrote. A job whose marks have moved since — re-opened on a phone, its
    /// material returned through the shared `returnForOrder`, then merged in by
    /// sync — has had its stock settled ALREADY, and the spool's and the
    /// consumables' deltas in the same snapshot are left alone.
    static func deductionStillStands(_ snapshot: [ChangedRecord],
                                     in root: [String: JSONValue]) -> Bool {
        let jobs = rows(root, undoJobsCollection)
        for change in snapshot where change.collection == undoJobsCollection && change.kind == .edited {
            guard let now = change.now else { continue }
            let moved = undoDeductionMarks.filter { change.was[$0] != now[$0] }
            guard !moved.isEmpty else { continue }
            guard let row = jobs.first(where: { recordId($0) == change.id }),
                  case .object(let current) = row else { return false }
            if moved.contains(where: { current[$0] != now[$0] }) { return false }
        }
        return true
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
        // Asked of the book BEFORE anything is put back: the jobs are undone
        // in the same pass.
        let deltasStand = deductionStillStands(snapshot, in: root)

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
                                                           now: now, byDelta: deltas,
                                                           deltasStand: deltasStand)
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
