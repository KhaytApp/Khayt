import Foundation
import KhaytCore

/// Every part in the book has an id: given once, at load, and written back.
///
/// ── WHAT WAS WRONG ───────────────────────────────────────────────────────
///
/// Parts the desktop calculator wrote before it minted ids have none, and
/// `Order.Part` made one up with `UUID()` on every read. A sheet opened on
/// such a part held an id the next reload no longer knew, so the Mac had to
/// find the part again by its place (`rawPart(at:)`, `lendingPartId`), which
/// a reload or a reorder breaks.
///
/// ── WHAT HAPPENS NOW ─────────────────────────────────────────────────────
///
/// At load, a cheap scan (`KhaytEngine.hasPartsWithoutIds`) asks whether any
/// part lacks an id. If one does, `lib/part-ids.js` gives each the id it is
/// owed, made from the job's id, the part's place and its content, never from
/// a clock, so every computer gives the same one, and the jobs are decoded
/// again from those rows. So the ids on screen are the ids the book will
/// hold, whether or not this Mac may write.
///
/// Then, ONLY when this Mac owns the book, the ids are written: one swap,
/// each changed job stamped (rev and updatedAt) by `Shop.write` so the ids
/// sync. Two machines doing it at once write the same content, which sync
/// reads as one record sent twice. A book this Mac does not own is never
/// written: the other app has it, and the ids stay in memory, the same ids.
extension Shop {

    /// The rows with every id-less part given its id, or nil when none
    /// lacked one (or the rule could not be asked).
    nonisolated static func rowsWithPartIds(_ rows: [JSONValue],
                                            engine: KhaytEngine) async -> KhaytEngine.PartIds? {
        guard KhaytEngine.hasPartsWithoutIds(rows),
              let given = try? await engine.assignPartIds(rows), !given.given.isEmpty else { return nil }
        return given
    }

    /// The write itself, on a book as read: each job with a part that has no
    /// id gets the ids, stamped; no other record is touched. Returns how many
    /// parts were given one. What `writeMissingPartIds` runs inside the swap,
    /// and what the proof on a copy of a real book runs (`PartIdsLoadTests`).
    static func givePartIds(_ root: inout [String: JSONValue], engine: KhaytEngine) async -> Int {
        let before = rows(root, "printLog")
        guard let made = await rowsWithPartIds(before, engine: engine) else { return 0 }
        let jobs = writable(made, in: before)
        guard !jobs.isEmpty else { return 0 }
        let changed = made.orders.filter { jobs.contains(recordId($0) ?? "") }
        var undo: [ChangedRecord] = []
        write(&root, "printLog", changed: changed, before: before, into: &undo)
        return made.given.filter { jobs.contains($0.orderId) }.count
    }

    /// The jobs whose ids can be written: those the book keys by a STRING id.
    /// The rule gives a part of a job with a numeric or missing id an id too
    /// (it reads `String(o.id)`), but `Shop.write` finds rows by string id, so
    /// such a job is never written, and counting it had every load rewrite the
    /// whole book for nothing (beta.38 review).
    nonisolated static func writable(_ made: KhaytEngine.PartIds, in rows: [JSONValue]) -> Set<String> {
        let keyed = Set(rows.compactMap(recordId))
        return Set(made.given.map(\.orderId)).intersection(keyed)
    }

    /// Write the ids the book's id-less parts are owed. Nothing happens unless
    /// this Mac owns the book; the rule runs again on the book as read inside
    /// the write, so a change that landed since the load is not undone.
    /// True when ids were written.
    @discardableResult
    func writeMissingPartIds() async -> Bool {
        guard let build = source.build, ownership != nil, let engine, !partIdsWriting else { return false }
        partIdsWriting = true
        defer { partIdsWriting = false }
        var wrote = 0
        do {
            // lock: system — background: ids for parts that have none, given at load; no person's action.
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                wrote = await Self.givePartIds(&root, engine: engine)
                // Nothing that can be written: leave the file as it is.
                if wrote == 0 { throw NothingToWrite() }
            }
        } catch is NothingToWrite {
            return false
        } catch {
            // Not owned any more, or the disk said no: the ids stay in memory
            // and the next load that owns the book tries again.
            return false
        }
        if wrote > 0 { await load(source) }
        return wrote > 0
    }
}
