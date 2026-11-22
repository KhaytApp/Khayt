import Foundation
import KhaytCore
import os

/// What a library write hands back from inside the write chain: the library
/// as it now sits in the book, read there rather than reloaded afterwards.
struct LibraryWritten: Sendable {
    /// `printFiles` as written.
    var rows: [JSONValue]
    /// `settings` as written (group kinds and covers, `notAdopted`).
    var settings: JSONValue
    /// The touched records still in the book, decoded.
    var changed: [String: LibraryFile]
    /// The book's library had moved under this app since it was last read
    /// (the other app, a sync), so patching the touched records alone would
    /// leave the screen describing a book that no longer exists.
    var moved: Bool
    /// Where this write came on the write chain. Writes land in order, but
    /// the main thread can hear about them out of order — and a write heard
    /// late must not put an older library back on screen.
    var sequence: Int

    /// Counted inside the chain, so the order is the order they were written.
    static let written = OSAllocatedUnfairLock(initialState: 0)
    static func next() -> Int { written.withLock { $0 += 1; return $0 } }
    /// The last number handed out. Read ON the chain (`Shop.load`), it says
    /// which library writes a book read straight after already holds.
    static var current: Int { written.withLock { $0 } }
}

/// One undo entry's own target, so that entry alone can be taken off the
/// stack when its write fails (`Shop.registerUndo(after:named:)`).
final class UndoTicket: Sendable {}

/// The library a write compares the book against (`Shop.libraryBase`).
struct LibraryBase: Sendable {
    var rows: [JSONValue]
    var skipping: Set<String>
}

/// A library edit shown on screen whose write has not landed yet. `change`
/// nil means the models were deleted.
struct PendingLibraryChange {
    let token: Int
    let ids: Set<LibraryFile.ID>
    let change: ((inout [String: JSONValue]) -> Void)?
}

/// ── A LIBRARY EDIT, WITHOUT FREEZING THE WINDOW ─────────────────────────
///
/// "Deleting from library freezes for a few seconds." Measured on a 10,000
/// model book (`LibraryEditPerfTests`): one delete held the main thread for
/// ~3 s at a stretch. All of it was the whole book — read and decoded,
/// changed, encoded and fsynced inside the click, then read and decoded
/// AGAIN by the reload every write ended with, all ten thousand records
/// re-decoded into `LibraryFile`s to show one missing.
///
/// Now an edit is three steps, and only the first and last are on the main
/// thread:
///
/// 1. **On screen at once.** The models leave the grid (or show their new
///    group, star, photo) before anything is written.
/// 2. **Written on the write chain** (`StoreWriter.updateOffMain`): the same
///    read-modify-write as before, inside the chain, so the change is still
///    worked out from the book on disk and never from this copy.
/// 3. **Patched in place.** The write hands back the library as written, and
///    only the records it touched are re-decoded. The rest of the book is not
///    reloaded, because a library edit does not change it — unless the
///    library had moved under this app, and then the whole book is read.
///
/// A write that fails puts the screen back by reading the book again: nothing
/// was written, so the book on disk is still the truth.
extension Shop {

    /// The library as this app last read it, for a write to compare against:
    /// the records an edit of this app's own is still changing are left out
    /// of the comparison, so two quick edits in a row are not mistaken for
    /// the other app changing the book.
    func libraryBase() -> LibraryBase {
        var skipping = Set<String>()
        for pending in pendingLibraryChanges { skipping.formUnion(pending.ids) }
        return LibraryBase(rows: libraryRows, skipping: skipping)
    }

    /// The library as written, worked out inside the write — `before` is the
    /// library the write found on disk, `base` the one this app had on
    /// screen before the edit.
    ///
    /// Read inside `mutate`, before `StoreWriter` does its bookkeeping, and
    /// that is the book as written for the two writes that use it: a delete
    /// adds and renames nothing, and an edit stamps its own records
    /// (`applyFileEdit`), so `stampChanged` leaves them as they are.
    nonisolated static func libraryWritten(_ root: [String: JSONValue], touched: Set<String>,
                                           before: [JSONValue], base: LibraryBase) -> LibraryWritten {
        let rows = Self.rows(root, "printFiles")
        let settings = root["settings"] ?? .object([:])
        let skip = base.skipping.union(touched)
        let others: (JSONValue) -> Bool = { row in !(Self.recordId(row).map(skip.contains) ?? false) }
        guard before.filter(others) == base.rows.filter(others) else {
            return LibraryWritten(rows: rows, settings: settings, changed: [:], moved: true,
                                  sequence: LibraryWritten.next())
        }
        let changed = Self.decoded(touched, in: rows)
        return LibraryWritten(rows: rows, settings: settings, changed: changed, moved: false,
                              sequence: LibraryWritten.next())
    }

    /// Step 1, remembered until its write lands — so a reload, or an earlier
    /// edit's write landing first, does not flash the model back (or the old
    /// star) for the second before this one is written.
    func beginLibraryChange(_ ids: Set<LibraryFile.ID>,
                            change: ((inout [String: JSONValue]) -> Void)?) -> Int {
        pendingLibraryToken += 1
        let pending = PendingLibraryChange(token: pendingLibraryToken, ids: ids, change: change)
        pendingLibraryChanges.append(pending)
        apply(pending)
        return pending.token
    }

    func endLibraryChange(_ token: Int) {
        pendingLibraryChanges.removeAll { $0.token == token }
    }

    /// Every edit still being written, on top of whatever was just read.
    func reapplyPendingLibraryChanges() {
        for pending in pendingLibraryChanges { apply(pending) }
    }

    private func apply(_ pending: PendingLibraryChange) {
        if let change = pending.change { showEdit(pending.ids, change: change) }
        else { removeFromScreen(pending.ids) }
    }

    /// Those records of `rows`, decoded.
    nonisolated static func decoded(_ ids: Set<String>, in rows: [JSONValue]) -> [String: LibraryFile] {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var out: [String: LibraryFile] = [:]
        for row in rows {
            guard let id = Self.recordId(row), ids.contains(id),
                  let data = try? encoder.encode(row),
                  let file = try? decoder.decode(LibraryFile.self, from: data) else { continue }
            out[id] = file
        }
        return out
    }

    /// Step 1 for a delete: off the screen now.
    func removeFromScreen(_ ids: Set<LibraryFile.ID>) {
        guard !ids.isEmpty else { return }
        showLibraryFiles(files.filter { !ids.contains($0.id) })
        let keep: (JSONValue) -> Bool = { row in !(Self.recordId(row).map(ids.contains) ?? false) }
        libraryRows = libraryRows.filter(keep)
        fileRows = fileRows.filter(keep)
        fileSelection.subtract(ids)
    }

    /// Step 1 for an edit: the change made to this app's copy, so the star,
    /// the group or the photo shows before the write lands. Only the touched
    /// records are re-decoded.
    func showEdit(_ ids: Set<LibraryFile.ID>, change: (inout [String: JSONValue]) -> Void) {
        guard !ids.isEmpty else { return }
        var edited: [String: LibraryFile] = [:]
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        func patch(_ rows: [JSONValue]) -> [JSONValue] {
            var rows = rows
            for i in rows.indices {
                guard case .object(var record) = rows[i], let id = Self.recordId(rows[i]),
                      ids.contains(id) else { continue }
                change(&record)
                rows[i] = .object(record)
                if edited[id] == nil, let data = try? encoder.encode(rows[i]),
                   let file = try? decoder.decode(LibraryFile.self, from: data) {
                    edited[id] = file
                }
            }
            return rows
        }
        libraryRows = patch(libraryRows)
        fileRows = patch(fileRows)
        guard !edited.isEmpty else { return }
        var next = files
        for i in next.indices { if let file = edited[next[i].id] { next[i] = file } }
        showLibraryFiles(next)
    }

    /// Step 3: the book as written, on screen — the touched records only.
    func showLibraryWritten(_ written: LibraryWritten, touched: Set<LibraryFile.ID>) async {
        guard !written.moved else { await load(source); return }
        var changed = written.changed
        if written.sequence > libraryShownSequence {
            libraryShownSequence = written.sequence
            libraryEpoch += 1
            libraryShownRows = written.rows
            libraryRows = written.rows
            fileRows = written.rows
            settingsValue = written.settings
        } else {
            // A later write is already on screen, and it was written on top
            // of this one: the touched records are read from THAT, never put
            // back as this write left them. The rows go back to it too —
            // this edit was still drawn over them as pending.
            libraryRows = libraryShownRows
            fileRows = libraryShownRows
            changed = Self.decoded(touched, in: libraryShownRows)
        }
        var next = files
        // Gone from the book: gone from the screen (a delete, or the other
        // app's delete of a model this app had just edited).
        next.removeAll { touched.contains($0.id) && changed[$0.id] == nil }
        for i in next.indices { if let file = changed[next[i].id] { next[i] = file } }
        showLibraryFiles(next)
        reapplyPendingLibraryChanges()
        let settings = settingsDict
        libraryGroupKinds = GroupKinds.read(settings)
        libraryGroupCovers = GroupKinds.covers(settings)

        // What `load` works out per model, for the touched ones only.
        let touchedFiles = changed.values.sorted { $0.id < $1.id }
        for id in touched where changed[id] == nil {
            fits[id] = nil; estimates[id] = nil; licences[id] = nil; risks[id] = nil
        }
        if !touchedFiles.isEmpty {
            let fitted = await Self.measureFit(touchedFiles, machines: machineRowsInUse, engine: engine)
            let priced = await Self.priceMeshes(touchedFiles, settings: settings,
                                                orders: orderRows, engine: engine)
            for file in touchedFiles {
                fits[file.id] = fitted[file.id]
                estimates[file.id] = priced[file.id]
                var standing: KhaytEngine.Standing?
                if !(file.licence ?? "").isEmpty || !(file.source ?? "").isEmpty {
                    standing = try? await engine?.licenceStanding(source: file.source,
                                                                 licence: file.licence)
                }
                licences[file.id] = standing
                if let engine, let analysis = file.riskAnalysis {
                    await judge(analysis, for: file, engine: engine)
                } else {
                    risks[file.id] = nil
                }
            }
        }
        await readLibraryFacets()
        await readLibraryNames()
        Spotlight.shared.reindex(shop: self)
    }
}
