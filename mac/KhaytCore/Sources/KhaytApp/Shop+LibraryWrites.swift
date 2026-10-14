import Foundation
import KhaytCore

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

    /// The library as written, worked out inside the write — `before` is the
    /// library the write found on disk, `base` the one this app had on
    /// screen before the edit.
    ///
    /// Read inside `mutate`, before `StoreWriter` does its bookkeeping, and
    /// that is the book as written for the two writes that use it: a delete
    /// adds and renames nothing, and an edit stamps its own records
    /// (`applyFileEdit`), so `stampChanged` leaves them as they are.
    nonisolated static func libraryWritten(_ root: [String: JSONValue], touched: Set<String>,
                                           before: [JSONValue], base: [JSONValue]) -> LibraryWritten {
        let rows = Self.rows(root, "printFiles")
        let settings = root["settings"] ?? .object([:])
        guard before == base else {
            return LibraryWritten(rows: rows, settings: settings, changed: [:], moved: true)
        }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var changed: [String: LibraryFile] = [:]
        for row in rows {
            guard let id = Self.recordId(row), touched.contains(id),
                  let data = try? encoder.encode(row),
                  let file = try? decoder.decode(LibraryFile.self, from: data) else { continue }
            changed[id] = file
        }
        return LibraryWritten(rows: rows, settings: settings, changed: changed, moved: false)
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

    /// Step 1 for a delete: off the screen now.
    func removeFromScreen(_ ids: Set<LibraryFile.ID>) {
        guard !ids.isEmpty else { return }
        files.removeAll { ids.contains($0.id) }
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
        files = next
    }

    /// Step 3: the book as written, on screen — the touched records only.
    func showLibraryWritten(_ written: LibraryWritten, touched: Set<LibraryFile.ID>) async {
        guard !written.moved else { await load(source); return }
        libraryRows = written.rows
        fileRows = written.rows
        var next = files
        // Gone from the book: gone from the screen (a delete, or the other
        // app's delete of a model this app had just edited).
        next.removeAll { touched.contains($0.id) && written.changed[$0.id] == nil }
        for i in next.indices { if let file = written.changed[next[i].id] { next[i] = file } }
        files = next
        reapplyPendingLibraryChanges()
        let settings: [String: JSONValue]
        if case .object(let s) = written.settings { settings = s } else { settings = [:] }
        settingsValue = written.settings
        libraryGroupKinds = GroupKinds.read(settings)
        libraryGroupCovers = GroupKinds.covers(settings)

        // What `load` works out per model, for the touched ones only.
        let touchedFiles = written.changed.values.sorted { $0.id < $1.id }
        for id in touched where written.changed[id] == nil {
            fits[id] = nil; estimates[id] = nil; licences[id] = nil; risks[id] = nil
        }
        if !touchedFiles.isEmpty {
            let fitted = await Self.measureFit(touchedFiles, machines: machineRows, engine: engine)
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
