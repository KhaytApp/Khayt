import Foundation
import UniformTypeIdentifiers
import AppKit
import Observation
import KhaytCore

extension Shop {

    // MARK: - Measuring the library again

    /// Reads again the 3MFs an older reader measured, and rewrites the keys
    /// that come out different. The rule and the reasons are on `Remeasure`;
    /// this is the wiring: after the book loads, off the main thread at a
    /// priority below the screen's, one write at the end, and a note when a
    /// number the shop was shown has changed. Nothing for the sample book,
    /// whose files are nobody's.
    func remeasureIfDue() {
        guard case .store(let build) = source, let roots = libraryRoots, let engine,
              !remeasuredBooks.contains(build.rawValue) else { return }
        remeasuredBooks.insert(build.rawValue)
        let files = self.files
        let vault = URL(fileURLWithPath: roots.primary)
        remeasuring = Task { [weak self] in
            let due = await Remeasure.due(files, engine: engine)
            guard !due.isEmpty else { return }
            let report = await Task.detached(priority: .utility) {
                await Remeasure.measure(due, vault: vault, engine: engine)
            }.value
            guard !report.measured.isEmpty, let self else { return }
            await self.recordRemeasure(report, build: build, engine: engine)
        }
    }

    /// Ask the model files who made them, once per book per launch.
    ///
    /// Wired the way `remeasureIfDue` is, and for the same reason: a rule with
    /// no caller is this repo's recurring bug, and a menu item a shop has to
    /// find is barely a caller. Background and best-effort — nothing on any
    /// screen waits for it, and a book where every model has already been
    /// asked does no work at all, because `readProvenanceFromFiles` looks only
    /// at records with BOTH fields still blank.
    ///
    /// The cost on a book where the files say nothing is one bounded header
    /// read per model — the part before `<resources`, not the geometry — which
    /// is why this can run again on the next launch rather than needing a
    /// marker written into the book.
    /// Should this record's slicer figures be (re)read? When it has none; or,
    /// for a 3MF, when they were read before plates were read one by one.
    ///
    /// `platesRead` is a VERSION, not a flag. `true` (Sep 2026) was plates
    /// summed; 2 (Oct 2026) adds each plate's name and filaments and each
    /// spool's grams over the whole project — which the library's colour list
    /// was missing: it kept plate 1's grams per colour (a tester: "it only
    /// shows the filament data and time for one"). A record read at 1 is read
    /// once more so the data already on disk gets them too.
    nonisolated static let platesReadVersion = 2.0

    nonisolated static func slicerFiguresDue(_ parsed: JSONValue?, ext: String) -> Bool {
        guard case .object(let o)? = parsed, !o.isEmpty else { return true }
        guard ext == "3mf" else { return false }
        if case .number(let v)? = o["platesRead"] { return v < platesReadVersion }
        return true
    }

    /// The record's colour list with each colour's grams taken from the
    /// slicer's per-spool totals (`parsed.filaments`, summed over every plate),
    /// matched by colour. Nil when there is nothing to change. A colour the
    /// slicer did not list keeps what it had.
    nonisolated static func coloursWithProjectGrams(_ colours: JSONValue?, filaments: JSONValue?) -> JSONValue? {
        guard case .array(let list)? = colours, !list.isEmpty,
              case .array(let spools)? = filaments, !spools.isEmpty else { return nil }
        func key(_ v: JSONValue?) -> String? {
            guard case .string(let h)? = v else { return nil }
            let t = h.trimmingCharacters(in: .whitespaces).uppercased()
            let bare = t.hasPrefix("#") ? String(t.dropFirst()) : t
            return bare.count >= 6 ? String(bare.prefix(6)) : nil
        }
        var grams: [String: Double] = [:]
        for case .object(let f) in spools {
            guard let k = key(f["color"]), case .number(let g)? = f["grams"] else { continue }
            grams[k, default: 0] += g
        }
        var changed = false
        let out: [JSONValue] = list.map { v in
            guard case .object(var c) = v, let k = key(c["hex"]), let g = grams[k] else { return v }
            let rounded = (g * 100).rounded() / 100
            if c["grams"] != .number(rounded) { c["grams"] = .number(rounded); changed = true }
            return .object(c)
        }
        return changed ? .array(out) : nil
    }

    /// Write what the slicer said onto the records it was read for.
    ///
    /// ── A RE-READ IS NOT AN EDIT ─────────────────────────────────────────
    ///
    /// `platesReadVersion` 2 re-read every 3MF already in the library, and
    /// each one was STAMPED — a new `rev` and `updatedAt` on every model. With
    /// sync merging whole records last-writer-wins, that re-read could beat an
    /// edit another machine had made to the same model (a rename, a price)
    /// and not yet pulled here: the newer stamp won and the edit was lost, for
    /// figures the other machine works out for itself from the same file.
    ///
    /// So only a FIRST read is stamped — a record that had no slicer figures
    /// before, where the figures are new facts worth sending. A re-read writes
    /// its derived fields (plates, per-spool grams, the colour list's grams)
    /// with `rev` and `updatedAt` untouched: each machine re-reads by version
    /// on its own, and an edit made elsewhere still wins the merge.
    nonisolated static func applySlicerFigures(_ found: [String: [String: JSONValue]],
                                   extOf: [String: String],
                                   to root: inout [String: JSONValue]) {
        guard case .array(var rows)? = root["printFiles"] else { return }
        for i in rows.indices {
            guard case .object(var r) = rows[i], case .string(let id)? = r["id"],
                  let parsed = found[id] else { continue }
            guard slicerFiguresDue(r["parsed"], ext: extOf[id] ?? "") else { continue }
            // MERGED, never replaced. A re-read that found figures
            // wins where it has them; one that found nothing adds
            // only its mark. Keys this reader does not write (a
            // cost another app recorded) stay as they were.
            var merged: [String: JSONValue] = [:]
            if case .object(let had)? = r["parsed"] { merged = had }
            let hadFigures = (plainNumber(merged["printTimeMins"]) ?? 0) > 0
                || (plainNumber(merged["filamentGrams"]) ?? 0) > 0
            let readSomething = (plainNumber(parsed["printTimeMins"]) ?? 0) > 0
                || (plainNumber(parsed["filamentGrams"]) ?? 0) > 0
            if readSomething { for (k, v) in parsed { merged[k] = v } }
            else { merged["platesRead"] = .number(platesReadVersion) }
            r["parsed"] = .object(merged)
            // The colour list was written at import with plate 1's
            // grams per colour; the per-spool totals fix it here,
            // on the data already on disk.
            if let fixed = coloursWithProjectGrams(r["colors"], filaments: parsed["filaments"]) {
                r["colors"] = fixed
            }
            if !hadFigures && readSomething { StoreWriter.stamp(&r) }
            rows[i] = .object(r)
        }
        root["printFiles"] = .array(rows)
    }

    /// New models in the linked folders, picked up once when the book opens.
    func rescanLinkedIfDue() {
        guard case .store(let build) = source, !linkedScannedBooks.contains(build.rawValue),
              !linkedFolders.isEmpty else { return }
        linkedScannedBooks.insert(build.rawValue)
        linkedScan = Task { [weak self] in await self?.rescanLinkedFolders(byPerson: false) }
    }

    /// Read the slicer's own time, weight and material off every sliced file
    /// the library has none for — once per book per launch, in the background.
    ///
    /// ── THE DATA ALREADY ON DISK ─────────────────────────────────────────
    ///
    /// Until Sep 2026 the Mac imported models without these, so a shop's whole
    /// library — 247 models in this one — carried no slicer figures, and a
    /// product made from a U1 3MF that says 4 h 37 min was priced at a 0.97 h
    /// geometry guess. Fixing the import alone would have left every model
    /// already there wrong, so the ones there are read too. Only an EMPTY
    /// `parsed` is filled; nothing the shop or the other app wrote is replaced,
    /// no undo is registered, and products already made are left alone — a
    /// price does not change behind the shop's back.
    func readSlicerFiguresIfDue() {
        guard case .store(let build) = source, let engine,
              !slicerFiguresReadBooks.contains(build.rawValue) else { return }
        slicerFiguresReadBooks.insert(build.rawValue)
        // Each record found by its id ONCE: `row(for:)` walks the whole
        // library, and asking it once per model was ten thousand walks of ten
        // thousand records on the main actor at every launch (Oct 2026).
        var rowsById: [String: [String: JSONValue]] = [:]
        for case .object(let rec) in fileRows {
            if case .string(let id)? = rec["id"], rowsById[id] == nil { rowsById[id] = rec }
        }
        let wanted: [(id: String, url: URL, ext: String, linked: Bool)] = files.compactMap { file in
            guard let rec = rowsById[file.id], let url = modelFile(for: file) else { return nil }
            let ext = url.pathExtension.lowercased()
            guard ["3mf", "gcode", "gco"].contains(ext) else { return nil }
            // Empty, or a 3MF read before plates were read one by one (its
            // time was one plate's and its grams every plate's).
            guard Self.slicerFiguresDue(rec["parsed"], ext: ext) else { return nil }
            return (file.id, url, ext, file.isLinked)
        }
        guard !wanted.isEmpty else { return }
        let isOnline = linkedIsOnline
        Task { [weak self] in
            // Not a file the cloud would have to download to be read: a
            // linked Drive's online models are read when they are here. Asked
            // off the main actor — a cloud drive answers slowly.
            let due = await PinWork.run {
                wanted.filter { !($0.linked && isOnline($0.url)) }.map { (id: $0.id, url: $0.url, ext: $0.ext) }
            }
            guard !due.isEmpty else { return }
            var found: [String: [String: JSONValue]] = [:]
            let extOf = Dictionary(due.map { ($0.id, $0.ext) }, uniquingKeysWith: { a, _ in a })
            for item in due {
                if let parsed = await SlicerFigures.read(item.url, engine: engine) { found[item.id] = parsed }
                // Nothing read (an unsliced 3MF, or a file this reader cannot
                // open): only the mark, so it is not opened again every launch
                // — merged below, so figures already there are KEPT.
                else if item.ext == "3mf" { found[item.id] = ["platesRead": .number(Self.platesReadVersion)] }
            }
            guard let self, !found.isEmpty else { return }
            let figures = found
            do {
                // `recordingDeletes: false`: nothing is deleted here, and the
                // automatic stamp must not run — see `applySlicerFigures`.
                // Off the main actor: the whole book is read and written.
                // lock: system — background: the slicer's own figures read out of files already in the library.
                try await StoreWriter.updateOffMain(build, recordingDeletes: false) { root in
                    Shop.applySlicerFigures(figures, extOf: extOf, to: &root)
                }
                await self.load(self.source)
                FileHandle.standardError.write(Data("slicer figures: \(found.count) model(s) filled\n".utf8))
            } catch {}
        }
    }

    func readProvenanceIfDue() {
        guard case .store(let build) = source,
              !provenanceReadBooks.contains(build.rawValue) else { return }
        provenanceReadBooks.insert(build.rawValue)
        Task { [weak self] in
            guard let self else { return }
            let filled = await self.readProvenanceFromFiles()
            if filled > 0 {
                FileHandle.standardError.write(Data(
                    "provenance: \(filled) model(s) now name their designer\n".utf8))
            }
        }
    }

    private func recordRemeasure(_ report: Remeasure.Report, build: StoreReader.Build,
                                 engine: KhaytEngine) async {
        guard let reader = try? await engine.geometryReader() else { return }
        do {
            // lock: system — background: files re-measured because the measuring rule changed.
            // On the write chain: nobody asked for this, so nobody should
            // wait for it.
            try await StoreWriter.updateOffMain(build) { root in
                Remeasure.apply(report, reader: reader, to: &root)
            }
        } catch {
            // Somebody else has the book, or the disk refused: nothing was
            // marked, so the same files are due at the next launch.
            return
        }
        guard !report.changed.isEmpty else { return }
        await load(source)
        importNote = words.callIt("mac.remeasured", ["n": .number(Double(report.changed.count))])
    }

    // MARK: - What a customer has agreed to pay

    /// The agreed price for each named part, or nil. Empty answers — no
    /// customer, no record, no agreements, no engine — are all "nothing
    /// applies", so a caller never has to tell them apart.
    func agreedPrices(for names: [String], clientId: String?) async -> [Double?] {
        let none = names.map { _ in Double?.none }
        guard let clientId, let engine,
              let client = clients.first(where: { $0.id == clientId }),
              !client.priceList.isEmpty else { return none }
        let list = client.priceList.map { JSONValue.object($0.raw) }
        return (try? await engine.agreedPrices(names: names, priceList: list)) ?? none
    }

    func open(_ next: Source) { Task { await load(next) } }

    var canEditSelection: Bool { canWrite && !selectedFiles.isEmpty }

    var selectionIsOnThisMac: Bool {
        guard let one = selectedFile else { return false }
        return modelFile(for: one) != nil
    }

    func toggleFavouriteOnSelection() {
        guard let one = selectedFile else { return }
        toggleFavourite(one)
    }

    func revealSelection() {
        guard let one = selectedFile, let url = modelFile(for: one) else { return }
        FileActions.reveal(url)
    }

    func openSelection() {
        guard let one = selectedFile, let url = modelFile(for: one) else { return }
        FileActions.open(url)
    }

    /// Space in the library, and ⌘Y in the menu — Finder's own two gestures.
    ///
    /// A print-file library where you cannot look at the file without launching
    /// a slicer is a filing cabinet. This costs nothing: macOS already knows how
    /// to draw an STL, an OBJ, a USDZ and a PDF, and for anything it does not it
    /// shows the file's own icon and details rather than failing.
    func quickLookSelection() {
        guard let one = selectedFile, let url = modelFile(for: one) else { return }
        quickLook(url)
    }

    /// Show one file in Quick Look.
    ///
    /// ── A SECOND QUICK LOOK USED TO TAKE THE APP WITH IT ──────────────────
    ///
    /// Silently: no crash report from macOS, no `last-crash.txt`, nothing on
    /// stderr, and not even an orderly `terminate:` in the log. The app was
    /// simply gone, which reads to the person using it as a crash and leaves
    /// nothing at all to look at.
    ///
    /// What the log shows, three reproductions running:
    ///
    ///     [PlugInKit:lifecycle] all extension sessions ended     <- dismissed
    ///     (AppKit) perform action for menu item                  <- second ⌘Y
    ///     [quicklook] QLPreviewPanel called while the panel has no controller
    ///
    /// `.quickLookPreview` does NOT put its binding back to nil when the panel
    /// is dismissed. So `previewing` still held the first file, and the next
    /// selection was a url → url change rather than a fresh one.
    ///
    /// THAT TRANSITION IS THE FATAL PART, not the warning above it. The
    /// "no controller" line is still logged after this fix — nineteen times
    /// across fifteen Quick Looks in the run that proved it, with the app
    /// staying up throughout. So it is a symptom that appears either way, and
    /// a comment blaming it would send the next person after the wrong thing.
    /// What changed is only the shape of the binding change.
    ///
    /// Clearing it first makes every Quick Look a fresh nil → url, which is
    /// the only transition the modifier is reliable for. The set is deferred to
    /// the next turn of the main loop because both halves inside one update are
    /// coalesced into no change at all.
    ///
    /// BOTH CALLERS COME THROUGH HERE. The menu's ⌘Y and the file row's
    /// context menu each used to assign `previewing` themselves, so a fix in
    /// one would have left the other still doing it.
    func quickLook(_ url: URL) {
        guard previewing != nil else { previewing = url; return }
        previewing = nil
        Task { @MainActor in self.previewing = url }
    }

    /// Mark a model a favourite, or stop. The first thing this app ever wrote.
    func toggleFavourite(_ file: LibraryFile) {
        let wanted = !file.isFavourite
        editFiles([file.id],
                  named: words.callIt(wanted ? "mac.add_to_favourites" : "mac.remove_from_favourites")) { record in
            record["favorite"] = .bool(wanted)
        }
    }

    /// File every selected model under one name, or clear it.
    ///
    /// One write for the whole selection, not one per model. Seven kings filed
    /// one at a time is seven read-modify-writes, seven `.prev` generations, and
    /// six windows in which a crash leaves the collection half made.
    ///
    /// `kind` is what the group is IF this filing makes it (the naming popover
    /// asks); a group that already exists keeps the kind it has, and nil never
    /// writes one. Written in the same store write as the files, so a group
    /// never exists for a moment with the wrong kind. Whether the group is new
    /// is decided HERE, on the path the engine resolved — see `kindForFiling`.
    func fileSelection(under name: String, kind: GroupKind? = nil) async {
        clearLastOutcome()
        let ids = selectedIds
        guard !ids.isEmpty else { return }
        // Through the engine, so a name matching one the shop already uses
        // adopts that spelling rather than becoming a second chip holding part
        // of the same collection.
        guard let engine, let patch = try? await engine.fileUnderGroup(name, known: groups) else {
            writeProblem = words.callIt("mac.group_unknown")
            return
        }
        let named = name.isEmpty
            ? words.callIt("mac.remove_from_group")
            : words.callIt("mac.file_in", ["name": .string(name)])
        // The name the engine WROTE, which is the shop's existing spelling
        // when `unify` adopted one — and so the path the kind belongs to.
        var written = name
        if case .string(let g)? = patch["group"], !g.isEmpty { written = g }
        let kinds = Self.kindForFiling(kind, into: written, existing: files.map(\.groupName))
        var alsoRoot: (@Sendable (inout [String: JSONValue]) -> Void)?
        if !kinds.isEmpty { alsoRoot = { root in GroupKinds.write(kinds, into: &root) } }
        let wrote = editFiles(ids, named: named, alsoRoot: alsoRoot) { record in
            for (key, value) in patch { record[key] = value }
        }
        // SAY WHERE THEY WENT, with the way there. From "All models" a
        // collection's models stay where they were, so filing changed nothing
        // on screen and a shop cannot tell it worked (reported: "the group I
        // created still appears as single models"). Only when the write
        // happened: a book this app cannot write leaves `editFiles` doing
        // nothing, and a note would claim otherwise.
        guard wrote, !name.isEmpty else { return }
        groupNote = GroupNote(
            text: words.callIt("mac.filed_in_group", [
                "models": .string(words.counting(ids.count, "mac.n_models")),
                "name": .string(Self.groupLeaf(written))]),
            path: written)
    }

    /// The kind filing writes: `kind` for `written`, only when no model sits
    /// at or beneath that path yet.
    ///
    /// ── WHY ON THE RESOLVED PATH, NOT THE TYPED NAME ──────────────────────
    ///
    /// The popover used to decide "new" by comparing the name as typed (only
    /// trimmed) with the shop's groups. The engine's `unify` does more: it
    /// collapses runs of spaces and cuts at 60 characters (`lib/organise.js`
    /// `normalise`). "Saudi  Kings", with two spaces, matched no group in the
    /// popover, so it was "new" and carried the popover's default — parts —
    /// while the engine filed it under the existing "Saudi Kings", and the
    /// shop's collection silently became parts. `written` is the path the
    /// engine actually wrote, so the question is asked of the group the
    /// models really landed in.
    nonisolated static func kindForFiling(_ kind: GroupKind?, into written: String,
                                          existing: [String?]) -> [String: GroupKind] {
        guard let kind, !written.isEmpty,
              !existing.contains(where: { isUnder($0, written) }) else { return [:] }
        return [written: kind]
    }

    /// What filing models into a group had to say, and the group to show.
    struct GroupNote: Equatable {
        let text: String
        let path: String
    }

    func groupKind(_ path: String) -> GroupKind { GroupKinds.kind(of: path, in: libraryGroupKinds) }

    /// Say what a group is: one print in parts, or separate prints.
    func setGroupKind(_ path: String, _ kind: GroupKind) async {
        guard permitted("inventory", "edit") else { return }
        guard let build = source.build, !path.isEmpty, groupKind(path) != kind else { return }
        do {
            // On the write chain: a whole book written on the main thread
            // froze the window for seconds at 10,000 models.
            let covers = try await StoreWriter.updateOffMain(build) { root -> GroupCoverChange in
                var covers = GroupCoverChange()
                covers.before = GroupKinds.covers(Self.settings(root))
                GroupKinds.write([path: kind], into: &root)
                covers.after = GroupKinds.covers(Self.settings(root))
                return covers
            }
            writeProblem = nil
            settleGroupPictures(covers)
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// The last level of a group path — what a shop calls the group it is
    /// looking at. `MyProject/pose 1` is "pose 1"; the whole path is for the
    /// tooltip, where there is room for it.
    nonisolated static func groupLeaf(_ path: String) -> String {
        path.components(separatedBy: ImportGrouping.separator).last(where: { !$0.isEmpty }) ?? path
    }

    /// Open a group in the library, from anywhere that names one: a model's
    /// group label in "All models", or the note that says models were filed.
    ///
    /// Opening it also ends a search and the filters. The label is mostly
    /// met on a search's flat list of matches, and a search left on would
    /// narrow the group to the one model that matched — the group the shop
    /// asked to see would never appear whole.
    func showGroup(_ path: String) {
        groupNote = nil
        search = ""
        clearLibraryFilter()
        shelf = .library(path)
    }

    /// Change some print files, and be able to put them back.
    ///
    /// The Edit menu has always shown Undo and Redo; until now they did
    /// nothing, which is worse than their being absent — a menu item that is
    /// enabled and inert teaches people not to trust the menu.
    ///
    /// What is captured is the WHOLE record as it was, not the fields about to
    /// change. An undo then restores everything, including a field some later
    /// version of this method starts touching and forgets to snapshot.
    ///
    /// What is NOT restored is `rev`. An undo is an edit like any other: it
    /// stamps a new revision, because a record that went backwards would look
    /// to the next sync like the change never happened and the other machine's
    /// copy would win.
    /// Move a whole folder — and everything under it — somewhere else.
    ///
    /// ── WHY A FOLDER AND NOT A SELECTION ──────────────────────────────────
    ///
    /// Filing models into a group has always worked on a SELECTION, which is
    /// right when a shop is picking out six of forty. It is the wrong tool for
    /// repairing a library: a project that was imported flat is twenty-three
    /// folders holding hundreds of files, and putting them back by hand means
    /// opening each one, selecting all of it, and typing a path exactly.
    ///
    /// This is the same write, addressed by PATH. The subtree moves with it,
    /// so `Blue` going under `Helmet/pose 1` takes anything below `Blue` too.
    ///
    /// `under` is nil to move a folder out to the top level.
    func moveFolder(_ path: String, under newParent: String?) async {
        let leaf = path.components(separatedBy: ImportGrouping.separator).last ?? path
        let parent = (newParent?.isEmpty == false) ? newParent : nil
        let destination = parent.map { $0 + ImportGrouping.separator + leaf } ?? leaf
        guard destination != path else { return }
        // A folder cannot be moved inside itself: `Helmet` under `Helmet/pose 1`
        // would write a path that contains its own prefix and the folder would
        // vanish from the level it was on.
        guard !Self.isUnder(destination, path) else {
            writeProblem = words.callIt("mac.move_into_itself"); return
        }
        let moving = files.filter { Self.isUnder($0.groupName, path) }
        guard !moving.isEmpty else { return }

        // Each file keeps its own depth BELOW the folder being moved, so a
        // three-level project arrives as a three-level project.
        let wanted = Self.folderMoveTargets(path, to: destination,
                                            files: moving.map { ($0.id, $0.groupName) })
        // A group path is read back through `lib/organise.js normalise`, which
        // cuts it at 60 UTF-16 units. A move that writes a longer one files the
        // models under the first 60 characters — which can be ANOTHER folder's
        // path, and the two merge with nothing said. Refused, by name.
        guard Self.folderMoveFits(wanted) else {
            writeProblem = words.callIt("mac.move_path_too_long"); return
        }
        // The folder's kind, and every kind beneath it, go with it — or a
        // collection moved under a new parent would read as parts there.
        let ids = Set(wanted.keys)
        editFiles(ids,
                  named: words.callIt("mac.file_in", ["name": .string(destination)]),
                  alsoRoot: { root in GroupKinds.carry(from: path, to: destination, moving: ids, in: &root) }) { record in
            Self.moveRecord(&record, wanted: wanted)
        }
    }

    /// Where each file under `path` lands when that folder moves to
    /// `destination`, by id: its own depth below the folder kept.
    nonisolated static func folderMoveTargets(_ path: String, to destination: String,
                                              files: [(id: String, group: String?)]) -> [String: String] {
        var wanted: [String: String] = [:]
        for file in files where isUnder(file.group, path) {
            wanted[file.id] = destination + (file.group ?? "").dropFirst(path.count)
        }
        return wanted
    }

    /// Does every path a folder move would write survive `normalise`'s
    /// 60-unit cut intact? (`groupPathLimit`; "Move into Group…" asks the
    /// same question of every group it moves — `planGroupMove`.)
    nonisolated static func folderMoveFits(_ wanted: [String: String]) -> Bool {
        wanted.values.allSatisfy { $0.utf16.count <= groupPathLimit }
    }

    /// One file's record, moved to where `folderMoveTargets` put it.
    nonisolated static func moveRecord(_ record: inout [String: JSONValue], wanted: [String: String]) {
        guard case .string(let id)? = record["id"], let to = wanted[id] else { return }
        // BOTH fields, as `KhaytOrganise.assign` writes them — the older
        // build's dialog writes only `folder`, and sync merges whole
        // records last-writer-wins.
        record["group"] = .string(to)
        record["folder"] = .string(to)
    }

    /// What an edit to the library changed, to put back on Undo: each file
    /// record whole, and each group-kind entry (`settings.libraryGroups`) it
    /// touched — nil for an entry that was not there.
    ///
    /// The kinds are part of it because a folder move MOVES them
    /// (`GroupKinds.carry`): without them an undone move would put the files
    /// back under paths whose kinds had gone.
    ///
    /// FIELD-LEVEL, like every undo (`FieldUndo.swift`): each record and kind
    /// entry is kept as it was AND as the edit left it, so Undo puts back only
    /// what the edit changed and leaves whatever was written since — a
    /// remeasure, a phone's rename, a cloud merge.
    struct LibraryUndo {
        var files: [String: [String: JSONValue]] = [:]
        var groupEntries: [String: JSONValue?] = [:]
        /// Each file record as the edit left it.
        var after: [String: [String: JSONValue]] = [:]
        /// Each kind entry the edit changed, as it left it (nil: removed).
        var groupAfter: [String: JSONValue?] = [:]
        /// What an Undo producing this could not put back. Only set on a redo.
        var notUndone: [String] = []
        var isEmpty: Bool { files.isEmpty && groupEntries.isEmpty }
    }

    /// The entries of the kind map that differ between two readings, as the
    /// FIRST had them.
    nonisolated static func groupEntriesChanged(from old: [String: JSONValue],
                                                to new: [String: JSONValue]) -> [String: JSONValue?] {
        var out: [String: JSONValue?] = [:]
        for key in Set(old.keys).union(new.keys) where old[key] != new[key] {
            out[key] = .some(old[key])
        }
        return out
    }

    /// The store write `editFiles` makes, on a book in memory: change those
    /// records, then `alsoRoot`. Returns what Undo needs.
    nonisolated static func applyFileEdit(_ root: inout [String: JSONValue], ids: Set<String>,
                              alsoRoot: ((inout [String: JSONValue]) -> Void)?,
                              change: (inout [String: JSONValue]) -> Void) -> LibraryUndo {
        var undo = LibraryUndo()
        guard case .array(var rows)? = root["printFiles"] else { return undo }
        let kindsBefore = GroupKinds.entries(root)
        for i in rows.indices {
            guard case .object(var record) = rows[i],
                  case .string(let id)? = record["id"], ids.contains(id) else { continue }
            undo.files[id] = record
            change(&record)
            StoreWriter.stamp(&record)
            undo.after[id] = record
            rows[i] = .object(record)
        }
        root["printFiles"] = .array(rows)
        alsoRoot?(&root)
        let kindsAfter = GroupKinds.entries(root)
        undo.groupEntries = groupEntriesChanged(from: kindsBefore, to: kindsAfter)
        for key in undo.groupEntries.keys { undo.groupAfter[key] = .some(kindsAfter[key]) }
        return undo
    }

    /// The store write an Undo makes, on a book in memory: the FIELDS the
    /// edit changed put back on each record, and the kind entries it changed
    /// — each only where it still holds what the edit wrote. Returns what
    /// Redo needs, with `notUndone` naming what had changed since.
    nonisolated static func applyRestore(_ root: inout [String: JSONValue], _ snapshot: LibraryUndo) -> LibraryUndo {
        var redo = LibraryUndo()
        guard case .array(var rows)? = root["printFiles"] else { return redo }
        let kindsBefore = GroupKinds.entries(root)
        var seen: Set<String> = []
        for i in rows.indices {
            guard case .object(let current) = rows[i],
                  case .string(let id)? = current["id"],
                  let wanted = snapshot.files[id] else { continue }
            seen.insert(id)
            guard let now = snapshot.after[id] else {
                // No after-copy: nothing can be compared, so nothing is put
                // back rather than a stale whole record.
                redo.notUndone.append(id)
                continue
            }
            var (next, changed, kept) = undoFields(current: current, was: wanted,
                                                   now: now, byDelta: [])
            redo.notUndone += kept.map { "\($0) (\(id))" }
            guard changed else { continue }
            next["rev"] = current["rev"]
            StoreWriter.stamp(&next)
            redo.files[id] = current
            redo.after[id] = next
            rows[i] = .object(next)
        }
        for id in snapshot.files.keys.sorted() where !seen.contains(id) { redo.notUndone.append(id) }
        root["printFiles"] = .array(rows)

        // A kind entry goes back only if it still reads what the edit wrote.
        var entries: [String: JSONValue?] = [:]
        for (key, before) in snapshot.groupEntries {
            let wrote: JSONValue? = snapshot.groupAfter[key] ?? nil
            if snapshot.groupAfter[key] == nil || kindsBefore[key] == wrote {
                entries[key] = before
            } else if kindsBefore[key] != before {
                redo.notUndone.append(key)
            }
        }
        GroupKinds.restore(entries, into: &root)
        let kindsAfter = GroupKinds.entries(root)
        redo.groupEntries = groupEntriesChanged(from: kindsBefore, to: kindsAfter)
        for key in redo.groupEntries.keys { redo.groupAfter[key] = .some(kindsAfter[key]) }
        return redo
    }

    /// True when the change was accepted: it is on screen at once and written
    /// on the write chain (`Shop+LibraryWrites.swift`). A write that then
    /// fails says so in `writeProblem` and puts the screen back.
    ///
    /// `alsoRoot` is a change to the rest of the book made in the SAME write —
    /// a group's kind, which lives in settings and must not land a write apart
    /// from the files it describes. What it changes in the kind map is undone
    /// with the files (`LibraryUndo`).
    @discardableResult
    func editFiles(_ ids: Set<LibraryFile.ID>, named actionName: String,
                           alsoRoot: (@Sendable (inout [String: JSONValue]) -> Void)? = nil,
                           change: @escaping @Sendable (inout [String: JSONValue]) -> Void) -> Bool {
        guard permitted("inventory", "edit") else { return false }
        guard let build = source.build, !ids.isEmpty else { return false }
        writeProblem = nil
        let base = libraryBase()
        let pending = beginLibraryChange(ids, change: change)
        // The write, and what Undo needs from it. Started now and registered
        // now, so the undo stack holds this edit in the order it was made —
        // a ⌘Z pressed before the write lands waits for it.
        let written = Task { () -> LibraryUndo? in
            defer { self.libraryWrites[pending] = nil }
            do {
                let (undo, covers, library) = try await StoreWriter.updateOffMain(build) { root in
                    let before = Self.rows(root, "printFiles")
                    var covers = GroupCoverChange()
                    covers.before = GroupKinds.covers(Self.settings(root))
                    let undo = Self.applyFileEdit(&root, ids: ids, alsoRoot: alsoRoot, change: change)
                    covers.after = GroupKinds.covers(Self.settings(root))
                    return (undo, covers, Self.libraryWritten(root, touched: ids, before: before, base: base))
                }
                self.endLibraryChange(pending)
                self.settleGroupPictures(covers)
                await self.showLibraryWritten(library, touched: ids)
                return undo
            } catch {
                self.writeProblem = String(describing: error)
                self.endLibraryChange(pending)
                // Nothing was written: the screen goes back to the book.
                await self.load(self.source)
                return nil
            }
        }
        registerUndo(after: written, named: actionName)
        libraryWrites[pending] = written
        return true
    }

    /// Put those records back exactly as they were, and make THAT undoable too.
    func registerUndo(of before: LibraryUndo, named actionName: String) {
        guard let undoManager, !before.isEmpty else { return }
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: self) { shop in
            shop.restore(after: Task { () -> LibraryUndo? in before }, named: actionName)
        }
    }

    /// The same, for an edit whose write is still running: the undo waits for
    /// it. Registered at once rather than when the write lands, because an
    /// undo registered later goes on the stack after whatever the shop did
    /// next — and a redo registered later than its undo goes on the UNDO
    /// stack instead.
    ///
    /// ── A WRITE THAT FAILS TAKES ITS UNDO WITH IT ─────────────────────────
    ///
    /// Registered before the write is known to land, so a write that then
    /// fails (another app took the book, the disk refused) left an entry on
    /// the stack that did nothing: ⌘Z was swallowed by it instead of
    /// reaching the shop's previous real change. Each entry is registered
    /// against a target of its own, so exactly that entry can be taken off
    /// again — from the undo stack, or the redo stack for an undo's redo —
    /// once its write says there is nothing to undo.
    func registerUndo(after write: Task<LibraryUndo?, Never>, named actionName: String) {
        guard let undoManager else { return }
        let ticket = UndoTicket()
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: ticket) { [weak self] _ in
            // The entry holds the ticket alive for as long as it exists.
            _ = ticket
            self?.restore(after: write, named: actionName)
        }
        Task { [weak undoManager] in
            let landed = await write.value
            if landed == nil || landed?.isEmpty == true {
                undoManager?.removeAllActions(withTarget: ticket)
            }
        }
    }

    private func restore(after write: Task<LibraryUndo?, Never>, named actionName: String) {
        guard permitted("inventory", "edit") else { return }
        guard let build = source.build else { return }
        pendingLibraryToken += 1
        let token = pendingLibraryToken
        let undone = Task { () -> LibraryUndo? in
            defer { self.libraryWrites[token] = nil }
            guard let snapshot = await write.value, !snapshot.isEmpty else { return nil }
            return await self.restoreWritten(snapshot, build: build)
        }
        // Now, inside the undo, so it is the REDO.
        registerUndo(after: undone, named: actionName)
        libraryWrites[token] = undone
    }

    /// An Undo's write, on the write chain. Returns what Redo needs.
    private func restoreWritten(_ snapshot: LibraryUndo, build: StoreReader.Build) async -> LibraryUndo? {
        guard permitted("inventory", "edit") else { return nil }
        let ids = Set(snapshot.files.keys)
        let base = libraryBase()
        do {
            let (redo, covers, library) = try await StoreWriter.updateOffMain(build) { root in
                let before = Self.rows(root, "printFiles")
                var covers = GroupCoverChange()
                covers.before = GroupKinds.covers(Self.settings(root))
                let redo = Self.applyRestore(&root, snapshot)
                covers.after = GroupKinds.covers(Self.settings(root))
                return (redo, covers, Self.libraryWritten(root, touched: ids, before: before, base: base))
            }
            // A picture an undone change had sent to the Trash comes back
            // with the entry that names it.
            settleGroupPictures(covers)
            writeProblem = Self.partialUndoSentence(redo.notUndone, words: words)
            await showLibraryWritten(library, touched: ids)
            return redo
        } catch {
            // An undo that cannot be applied — the book changed hands while the
            // menu was open — must say so rather than fail quietly.
            writeProblem = String(describing: error)
            return nil
        }
    }

    /// Wait for every library write started so far — for a test, and for
    /// anything that must read the book after an edit has landed.
    func settleLibraryWrites() async {
        while let write = libraryWrites.values.first { _ = await write.value }
    }

    /// The QC failure's write, on a book in memory: the order, the waste row
    /// and the shelf, in one swap. Returns what Undo needs — including the
    /// waste row as a record this action CREATED, so undoing the failure takes
    /// it away again (if nobody has changed it since).
    static func writeQcFailure(_ root: inout [String: JSONValue], order: JSONValue,
                               waste wasteRow: JSONValue, inventory: [JSONValue],
                               ordersBefore orders: [JSONValue],
                               shelfBefore: [JSONValue]) -> [ChangedRecord] {
        var undo: [ChangedRecord] = []
        Self.write(&root, "printLog", changed: [order], before: orders, into: &undo)

        // Newest first, the way the waste screen reads it. A new row is
        // not an edit to an existing one, so nothing is stamped.
        var waste = Self.rows(root, "wasteLog")
        waste.insert(wasteRow, at: 0)
        root["wasteLog"] = .array(waste)
        // Made by this action, so undoing it takes the row away again — a
        // failure undone whose scrap stayed on the waste screen would
        // overstate the shop's waste.
        if let wasteId = Self.recordId(wasteRow) {
            undo.append(ChangedRecord(collection: "wasteLog", id: wasteId, was: [:], kind: .created))
        }

        // THE SHELF, in the same swap. A failed print takes its filament off
        // the spools it was printing from — a book saying a print failed and
        // wasted 200g while the spool still holds them has told the shop it
        // has filament it has already burned. Only the spools it actually
        // touched are stamped, and they go into the undo so putting the
        // failure back puts the grams back.
        Self.write(&root, "inventory", changed: inventory, before: shelfBefore, into: &undo)
        Self.sealUndo(&undo, in: root)
        return undo
    }

    // MARK: - What a model would cost

    static func priceMeshes(_ files: [LibraryFile], settings: [String: JSONValue],
                            orders: [JSONValue], engine: KhaytEngine?) async
        -> [String: KhaytEngine.MeshEstimate] {
        guard let engine else { return [:] }
        // THE SURFACE AREA, WHERE THE SHOP HAS ALREADY PAID FOR IT.
        //
        // The shell fraction is `area x wallThickness / volume`, and with no
        // area the estimator keeps a flat assumed constant — honest, and
        // weaker. The geometry key holds triangles, volume and dimensions
        // but no area, and measuring every file on every load would mean
        // reading the whole library.
        //
        // But a model the shop has checked for print risks ALREADY has its
        // area measured and stored. So a mesh that has been walked gets a
        // real shell fraction, and one that has not keeps the assumption —
        // and `shellSource` says which, because "a number nobody can
        // attribute is a number nobody can check". (`LoadFigures.meshInputs`.)
        //
        // ONE crossing for all of them, not one per model: each per-model
        // call carried the whole settings (a megabyte, with the logo) and the
        // print log across, and learned the rate again (`estimateMeshes`).
        let meshes = LoadFigures.meshInputs(files)
        guard !meshes.isEmpty else { return [:] }
        let answers = (try? await engine.estimateMeshes(meshes.map(\.input), settings: settings,
                                                       orders: orders)) ?? []
        var out: [String: KhaytEngine.MeshEstimate] = [:]
        for (k, answer) in answers.enumerated() { if let answer { out[meshes[k].id] = answer } }
        return out
    }

    // MARK: - Adding a model

    /// Clear the answer to the LAST thing the shop asked for.
    ///
    /// The library's banner area answers one question — what happened when you
    /// last asked for something — and four gestures write there: a move, an
    /// import, a conversion, opening a slicer. Each used to clear only its own
    /// line, so they piled up: a conversion that failed appeared UNDERNEATH a
    /// green "1 moved in · 0 failed" from an import minutes earlier, which
    /// together say something that never happened. Reported from the running
    /// app, with a TypeError sitting below a tick.
    ///
    /// A gesture is what supersedes a gesture, so every one of them starts
    /// here. `LibraryOutcomeTests` holds all four to it.
    func clearLastOutcome() {
        moveProblem = nil
        importNote = nil
        importProblem = nil
        convertNote = nil
        convertProblem = nil
        slicerProblem = nil
        groupNote = nil
    }

    /// Ask for a file and add it.
    func addModelToLibrary() async {
        clearLastOutcome()
        // Adding to the library is adding stock (the staff lock).
        guard permitted("inventory", "create") else { importProblem = moveProblem; return }
        guard source.build != nil else {
            importProblem = words.callIt("mac.move_sample"); return
        }
        let panel = NSOpenPanel()
        // MANY, AND FOLDERS. A shop importing what it has downloaded has
        // hundreds of files in nested folders, and one trip through this panel
        // per file is not an import, it is an afternoon.
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = words.callIt("mac.add_model")
        // Archives too: a zip is not a model, but the models come out of it —
        // see ArchiveImport. Offering only model types meant a shop that had
        // just downloaded one could not even select it.
        panel.allowedContentTypes = LibraryImport.kinds.union(ArchiveImport.kinds).compactMap {
            UTType(filenameExtension: $0)
        }
        // A slicer's own type is not always registered on a Mac that has no
        // slicer, and a panel that will open nothing is worse than one that
        // opens too much.
        panel.allowsOtherFileTypes = true
        // WHAT HAPPENS TO THE ORIGINALS, asked in the same panel, LABELLED,
        // and warning about iCloud Drive and Dropbox when Move is chosen —
        // see `ImportOriginalsChoice`. It starts at Settings › Library's
        // answer and applies to THIS import only: it used to be remembered,
        // and a Move chosen here once then silently trashed the originals
        // of every folder dragged onto the library afterwards.
        let choice = ImportOriginalsChoice(words: words, moves: importMovesOriginals)
        panel.accessoryView = choice.view
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        await addModelsToLibrary(panel.urls, movesOriginals: choice.moves)
    }

    /// Where the shop's answer to "keep my original files?" is remembered —
    /// this Mac's own defaults, not the book: it is about this Mac's folders.
    static let importMovesOriginalsKey = "libraryImportMovesOriginals"

    /// Adding models MOVES the originals in (they go to the Trash) only when
    /// the shop chose that. Absent is keep.
    ///
    /// ── WHY KEEP IS THE DEFAULT ───────────────────────────────────────────
    ///
    /// Every import used to trash its source. For a model in iCloud Drive or
    /// Dropbox that is a delete on every device the folder syncs to — the
    /// shop's other Mac, a partner's laptop — for a file it only meant to add
    /// here. A duplicate in Downloads is the recoverable half of that trade.
    var importMovesOriginals: Bool {
        UserDefaults.standard.bool(forKey: Self.importMovesOriginalsKey)
    }

    /// Every model under what was chosen, in a stable order.
    ///
    /// A folder is walked; a file is taken as it is. Anything that is not a
    /// kind the library holds is passed over silently — a folder of models has
    /// READMEs and slicer projects in it, and a summary that reported each of
    /// them as a failure would bury the ones that matter.
    ///
    /// The library's own root is skipped. Importing the vault into itself would
    /// refuse every file as a duplicate, which is harmless, and take a very long
    /// time to do it.
    static func modelsUnder(_ chosen: [URL], skipping root: String?) -> [LibraryImport.Incoming] {
        modelsUnder(chosen, skippingAll: root.map { [$0] } ?? [])
    }

    /// The same, skipping EVERY folder the library has lived in — the current
    /// one, the built-in vault, the mirror and every past location. Skipping
    /// only the current one meant importing from an old library folder moved
    /// out files that existing records still point at, and they then read as
    /// missing. And by folder boundary, so `/a/lib` does not also skip
    /// `/a/library2`. Found by a file-safety scan.
    nonisolated static func modelsUnder(_ chosen: [URL], skippingAll roots: [String]) -> [LibraryImport.Incoming] {
        let fm = FileManager.default
        var found: [LibraryImport.Incoming] = []
        let vaults = roots.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        func isInVault(_ u: URL) -> Bool {
            let path = u.standardizedFileURL.path
            return vaults.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
        for url in chosen where !isInVault(url) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let walker = fm.enumerator(at: url, includingPropertiesForKeys: LibraryImport.fileKeys,
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])
                var here: [URL] = []
                while let next = walker?.nextObject() as? URL {
                    // Regular files only: a symlink named `x.stl` in a folder
                    // the shop picked is a pointer to somewhere else on this
                    // Mac (or to `/dev/zero`, which hashes for ever), not a
                    // model that lives in that folder.
                    if LibraryImport.kinds.contains(next.pathExtension.lowercased()),
                       LibraryImport.isRegularFile(next),
                       !isInVault(next) {
                        here.append(next)
                    }
                }
                // Where it sat on disk IS the shop's grouping, but judged over
                // the WHOLE folder at once: a folder of several models is a
                // project, a folder of one names its model — see
                // `ImportGrouping.placements`.
                // And the photo that came with each — see `ModelPhoto`.
                let photos = ModelPhoto.candidates(for: here, everyModel: here, boundary: url)
                found += ImportGrouping.incoming(here, chosen: url).map {
                    var file = $0
                    file.photos = photos[$0.url] ?? []
                    return file
                }
            } else if LibraryImport.kinds.contains(url.pathExtension.lowercased()) {
                // Picked on its own: no group. The shop chose one file, not a set.
                // Its photo only by its own name: the folder it sits in is not
                // a project the shop chose.
                var file = LibraryImport.Incoming(url: url, group: nil)
                file.photos = ModelPhoto.candidates(for: [url], everyModel: [url], boundary: nil)[url] ?? []
                found.append(file)
            }
        }
        // Sorted so a run is repeatable and a person watching can follow it.
        return found.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    /// Import everything under what was chosen.
    ///
    /// ONE reload at the end rather than one per file. `LibraryImport.add(_:shop:)`
    /// re-reads the whole book after each import, which is right for a single
    /// file and quadratic for three thousand — a megabyte of JSON parsed once
    /// per model. This calls the lower seam directly and reloads once.
    ///
    /// `known` grows as it goes, so two copies of the same model inside one
    /// selection do not both get in.
    func addModelsToLibrary(_ chosen: [URL], movesOriginals: Bool? = nil) async {
        let keepOriginal = !(movesOriginals ?? importMovesOriginals)
        clearLastOutcome()
        guard permitted("inventory", "create") else { importProblem = moveProblem; return }
        importCancelled = false
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            importProblem = LibraryImport.Failure.notOurs.description; return
        }
        guard let roots = libraryRoots else {
            importProblem = LibraryImport.Failure.noLibrary.description; return
        }
        guard let engine else { importProblem = "the engine is not loaded"; return }

        // ARCHIVES FIRST, so what comes out of them is imported like anything
        // else. A shop downloads a model as a zip because that is how every
        // model site hands one over, and dropping one here used to do nothing
        // at all — the walk below looks for models and a `.zip` is not one, so
        // it was skipped in silence.
        //
        // The archive itself is never consumed: it stays where the shop put it,
        // and only copies of the models inside are moved into the vault.
        // Linked folders too: their files are indexed WHERE THEY ARE, and an
        // import from inside one would pull a file out from under its record.
        var files = Self.modelsUnder(chosen, skippingAll: roots.roots + [roots.primary] + linkedFolders)
        var scratches: [URL] = []
        var refusals: [String] = []
        for url in chosen where ArchiveImport.kinds.contains(url.pathExtension.lowercased()) {
            do {
                let out = try await ArchiveImport.expand(url, engine: engine)
                scratches.append(out.scratch)
                // Grouped by the archive's own name, the way a folder of models
                // is grouped by the folder — see `ImportGrouping`.
                files += ImportGrouping.incoming(archive: out.models, group: out.group,
                                                 documents: out.documents)
            } catch let refusal as ArchiveImport.Failure {
                refusals.append(refusal.description)
            } catch {
                refusals.append(String(describing: error))
            }
        }
        // The scratch copies are consumed by the import (it MOVES them in), but
        // a refusal or a duplicate leaves some behind, and they are in the
        // system temp directory either way.
        defer { for dir in scratches { try? FileManager.default.removeItem(at: dir) } }

        guard !files.isEmpty else {
            // A refused archive is a reason, not an absence. "Nothing to
            // import" beside a zip the shop can see is the unhelpful half of
            // this, and it is what the old code would have said.
            importProblem = refusals.isEmpty
                ? words.callIt("mac.import_nothing")
                : refusals.joined(separator: "\n")
            return
        }
        if !refusals.isEmpty { importProblem = refusals.joined(separator: "\n") }

        importing = true
        defer { importing = false; importProgress = nil }

        let titles = Dictionary(self.files.compactMap { f in
            f.contentHash.map { ($0, f.title) }
        }, uniquingKeysWith: { a, _ in a })

        // The loop itself is `LibraryImport.addMany`, shared with `--import`.
        // What is left here is only how a WINDOW says what happened: a banner
        // per file, and a sentence at the end.
        let report = await LibraryImport.addMany(
            files,
            storeURL: build.storeURL,
            libraryRoot: URL(fileURLWithPath: roots.primary),
            knownHashes: Set(self.files.compactMap(\.contentHash)),
            nameOfExisting: { titles[$0] },
            engine: engine,
            keepOriginal: keepOriginal,
            analyseRisk: analysesRiskAtImport,
            owns: { StoreLock.weOwnIt(build) },
            whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
            shouldStop: { [weak self] in self?.importCancelled ?? false },
            progress: { [weak self] done, total, file in
                self?.importProgress = (done: done, total: total, name: file.lastPathComponent)
            })

        await load(source)
        importProgress = nil
        // Into the bucket too, when the shop backs its library up there. In
        // the background: an import is not made to wait on the network.
        if !report.addedIds.isEmpty {
            // One import, however many models it brought in.
            Telemetry.feature(.libraryImport, in: self)
            let ids = report.addedIds
            Task { [weak self] in await self?.backUpToCloud(ids: ids) }
        }
        importNote = words.callIt(keepOriginal ? "mac.import_done_kept" : "mac.import_done", [
            "moved": .number(Double(report.moved)),
            "duplicates": .number(Double(report.duplicates)),
            "failed": .number(Double(report.failures.count)),
        ]) + Self.trashedNote(report.trashed, scratches: scratches, words: words)
        if !report.failures.isEmpty {
            importProblem = report.failures.prefix(10).joined(separator: "\n")
                + (report.failures.count > 10
                   ? "\n" + "… and \(report.failures.count - 10) more" : "")
        }
    }

    /// Which of the shop's machines each measured model goes on.
    ///
    /// Only the models that were measured: a model with no `geometryKey` has no
    /// bounds, and guessing at one would put a warning on a screen about a fact
    /// nobody has.
    static func measureFit(_ files: [LibraryFile], machines: [JSONValue],
                           engine: KhaytEngine?) async -> [String: KhaytEngine.Fit] {
        guard engine != nil, !machines.isEmpty else { return [:] }
        // The rule is Swift (`PrintFit`): asked directly, not one engine hop
        // per model.
        var out: [String: KhaytEngine.Fit] = [:]
        for file in files {
            guard let mesh = file.mesh else { continue }
            out[file.id] = KhaytEngine.fit((x: mesh.x, y: mesh.y, z: mesh.z), among: machines)
        }
        return out
    }

    // MARK: - Converting a model

    /// Convert a model for another printer, and put the result where the shop
    /// says. `nil` target means normalise: strip the vendor's settings and
    /// leave a clean standard 3MF that any slicer opens.
    ///
    /// The save panel first, deliberately. A conversion that runs and then asks
    /// where to put it has already spent the time before the shop can change
    /// its mind, and a shop that cancels should have cost nothing.
    func convertModel(_ file: LibraryFile, targetId: String?) async {
        guard permitted("inventory", "create") else { return }
        clearLastOutcome()
        guard let source = modelFile(for: file) else {
            convertProblem = words.callIt("mac.not_found"); return
        }
        guard let engine else { convertProblem = "the engine is not loaded"; return }

        let target = printerProfiles.first { $0.id == targetId }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedConvertName(file, target: target)
        panel.allowedContentTypes = [UTType(filenameExtension: "3mf")].compactMap { $0 }
        panel.canCreateDirectories = true

        // ASKED HERE, WITH EVERYTHING ELSE ABOUT WHERE IT GOES.
        //
        // In the same panel as the name and the folder, because it is the same
        // question — what this conversion is FOR. A shop converting a model to
        // move to a new printer wants the old one out of the way; a shop
        // keeping both wants both. Asking afterwards would be asking about work
        // already done.
        //
        // OFF by default. Keeping both is the answer that loses nothing.
        let replace = NSButton(checkboxWithTitle: words.callIt("mac.replace_original"),
                               target: nil, action: nil)
        replace.state = .off
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        replace.frame = NSRect(x: 12, y: 5, width: 296, height: 20)
        holder.addSubview(replace)
        panel.accessoryView = holder

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let replaceOriginal = replace.state == .on

        converting = true
        defer { converting = false }
        var options: [String: JSONValue] = [:]
        if let targetId { options["targetId"] = .string(targetId) }
        else { options["mode"] = .string("normalize") }

        do {
            _ = try await Converter.convert(source, into: destination,
                                            options: options, engine: engine)

            // AND INTO THE LIBRARY.
            //
            // A conversion used to end at a file in a folder. The shop then had
            // to go and import the thing it had just made, in the one app whose
            // whole job is knowing what models it has — so the converted file
            // was the only model in the building Khayt did not know about.
            //
            // `keepOriginal: true` because the shop chose that folder in a save
            // panel a moment ago. The import copies the bytes in and would
            // otherwise take the file away from where it was just asked to put
            // it. The library ends up with its own copy, which is what the
            // library is.
            //
            // A failed import is NOT a failed conversion: the file exists and is
            // correct, and saying otherwise would send a shop looking for a
            // problem with a conversion that worked. It is said separately.
            var landed = false
            do {
                _ = try await LibraryImport.add(destination, shop: self, keepOriginal: true)
                landed = true
            } catch let refusal as LibraryImport.Failure {
                convertProblem = refusal.description
            } catch {
                convertProblem = String(describing: error)
            }

            // Only once the replacement is IN the library. Putting the
            // original aside in favour of a file the library does not have
            // would leave the shop with neither.
            if replaceOriginal, landed,
               let replacement = files.first(where: { $0.name == destination.lastPathComponent })
                                 ?? files.first(where: { $0.title == destination.deletingPathExtension().lastPathComponent }) {
                await supersede(file, with: replacement.id)
            }

            convertNote = words.callIt(landed ? "mac.converted_into_library" : "mac.converted", [
                "name": .string(destination.lastPathComponent),
                "target": .string(target?.name ?? words.callIt("mac.standard_3mf")),
            ])
        } catch let refusal as Converter.Failure {
            convertProblem = refusal.description
        } catch {
            convertProblem = String(describing: error)
        }
    }

    /// Put a model aside because another has taken its place.
    ///
    /// ARCHIVED, NOT DELETED. A job printed from this model months ago was
    /// printed from THESE bytes. Deleting them so the converted file could take
    /// the record's place would make that job appear to have been printed from
    /// a file it never saw, and a book that misreports its own history is worse
    /// than a library with one extra thing in it.
    ///
    /// So the record keeps everything it had, gains the date and the id of what
    /// replaced it, and stops being offered. The file stays where it is.
    func supersede(_ original: LibraryFile, with replacement: String) async {
        guard permitted("inventory", "edit") else { return }
        guard let build = source.build else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            try await StoreWriter.updateRecordOffMain(build, collection: "printFiles", id: original.id) { record in
                record["archivedAt"] = .string(now)
                record["supersededBy"] = .string(replacement)
            }
        } catch {
            convertProblem = String(describing: error)
            return
        }
        await load(source)
    }

    /// Bring a model back into the library.
    ///
    /// The other half, because a one-way door is not a decision a shop should
    /// have to be sure about before it makes it.
    func unarchive(_ file: LibraryFile) async {
        guard permitted("inventory", "edit") else { return }
        guard let build = source.build else { return }
        do {
            try await StoreWriter.updateRecordOffMain(build, collection: "printFiles", id: file.id) { record in
                record.removeValue(forKey: "archivedAt")
                record.removeValue(forKey: "supersededBy")
            }
        } catch {
            convertProblem = String(describing: error)
            return
        }
        await load(source)
    }

    /// `Falcon hood — Snapmaker U1.3mf`. The target in the name, because a
    /// folder of conversions of one model is otherwise a folder of the same
    /// filename with numbers after it.
    func suggestedConvertName(_ file: LibraryFile,
                              target: KhaytEngine.PrinterProfile?) -> String {
        let base = file.title.isEmpty ? "model" : file.title
        let suffix = target?.name ?? words.callIt("mac.standard_3mf")
        return "\(base) — \(suffix).3mf"
    }

    // MARK: - What the library shows

    /// The groups a shop has actually made, in the order it reads them.
    var groups: [String] {
        var seen = Set<String>(), out: [String] = []
        for g in files.compactMap(\.groupName) where !seen.contains(g) {
            seen.insert(g); out.append(g)
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var ungroupedCount: Int { files.count { $0.groupName == nil } }

    /// Every folder in the library, including the levels between — so a file
    /// filed under `A/B/C` offers `A`, `A/B` and `A/B/C` as places to move to,
    /// not only the leaf it happens to sit in.
    var folderPaths: [String] {
        var seen = Set<String>()
        for group in files.compactMap(\.groupName) {
            var parts: [String] = []
            for level in group.components(separatedBy: ImportGrouping.separator) {
                parts.append(level)
                seen.insert(parts.joined(separator: ImportGrouping.separator))
            }
        }
        return seen.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Where a model came from

    /// Record what a model's licence is, on everything selected.
    ///
    /// ── WHY THIS HAD TO EXIST ─────────────────────────────────────────────
    ///
    /// The inspector has always READ a licence and nothing on this Mac could
    /// write one, so on a real book the panel was blank on every model and the
    /// only way to fill it in was to open the other app. A library holds work
    /// the shop made and models it downloaded, they look identical in a grid,
    /// and the difference decides whether a print can be SOLD.
    ///
    /// An empty string CLEARS it, back to "nobody has recorded one" — which is
    /// not the same as "may not be sold" and must stay reachable, because a
    /// licence set by mistake is worse than no licence at all.
    func fileSelection(licence: String) async {
        let ids = selectedIds
        guard !ids.isEmpty else { return }
        // Through `ModelLicence`, so a value this app cannot name never reaches
        // the book: the id stored is the module's own spelling of it.
        let id = ModelLicence.find(licence)?.id ?? ""
        guard !licence.isEmpty == !id.isEmpty else {
            writeProblem = words.callIt("mac.licence_unknown"); return
        }
        let named = id.isEmpty ? words.callIt("mac.licence_cleared")
                               : words.callIt("mac.licence_set")
        editFiles(ids, named: named) { record in
            record["licence"] = .string(id)
        }
    }

    /// Record the proof behind a bought licence — code, verification page, last
    /// day covered. Blank clears a field. A link must be an http(s) address and
    /// a date must be a real `YYYY-MM-DD`, or nothing is written: a proof the
    /// shop cannot click, or a date `lib/model-licence.js` cannot read, is a
    /// proof that silently never expires.
    func setLicenceProof(_ fileId: LibraryFile.ID, code: String, url: String, expires: String) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let expires = expires.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty {
            guard let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
                  u.host() != nil else { writeProblem = words.callIt("mac.licence_bad_link"); return }
        }
        if !expires.isEmpty {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            guard f.date(from: expires).map({ f.string(from: $0) == expires }) == true else {
                writeProblem = words.callIt("mac.licence_bad_date"); return
            }
        }
        editFiles([fileId], named: words.callIt("mac.licence_proof")) { record in
            for (key, value) in [("licenceCode", code), ("licenceUrl", url), ("licenceExpires", expires)] {
                if value.isEmpty { record.removeValue(forKey: key) } else { record[key] = .string(value) }
            }
        }
    }

    /// The models behind a job or a product that may not be sold TODAY —
    /// non-commercial, or a bought licence past its last day. Unknown licences
    /// are not in it: unknown is not no. `ModelLicence.saleProblems`.
    func saleProblems(_ printFileIds: [String]) -> [ModelLicence.SaleProblem] {
        ModelLicence.saleProblems(printFileIds, records: libraryRows, today: Self.today())
    }

    /// Read provenance out of the model files a shop ALREADY has.
    ///
    /// ── A FIX ONLY ON NEW IMPORTS STRANDS THE WHOLE LIBRARY ───────────────
    ///
    /// Reading the designer and the licence at import time fixes every model
    /// added from now on and nothing a shop has. This book holds ninety 3MFs;
    /// twenty-one of them name a designer in the file and three are
    /// non-commercial, and not one of those records was written by an import
    /// that knew to look. So the same read runs over what is on disk.
    ///
    /// ── IT ONLY EVER FILLS A BLANK ────────────────────────────────────────
    ///
    /// Never overwrites. A shop that typed "my own design" over a file whose
    /// metadata still names the creator it was remixed from has said something
    /// this must not undo — and a licence a person CHOSE outranks one a slicer
    /// copied. So a record with either field already set is left entirely
    /// alone, which also makes running this twice free.
    ///
    /// Returns how many records gained something, so the shop is told rather
    /// than left to go and look.
    @discardableResult
    func readProvenanceFromFiles() async -> Int {
        let candidates = files.filter {
            ($0.source ?? "").isEmpty && ($0.licence ?? "").isEmpty
        }
        guard !candidates.isEmpty else { return 0 }

        // Read first, write once, and read OFF the main thread: this opens
        // up to a few hundred model zips, and doing that on the MainActor
        // froze the window just after launch.
        let jobs: [(id: LibraryFile.ID, url: URL, linked: Bool)] = candidates.compactMap { file in
            guard let url = modelFile(for: file) else { return nil }
            return (file.id, url, file.isLinked)
        }
        let isOnline = linkedIsOnline
        // On a dispatch queue, not a detached task holding a cooperative
        // thread for a few hundred zips.
        let read: [LibraryFile.ID: (designer: String, licence: String)] = await PinWork.run {
            var out: [LibraryFile.ID: (designer: String, licence: String)] = [:]
            for job in jobs {
                // Never a linked file the cloud would have to download first.
                if job.linked, isOnline(job.url) { continue }
                guard let said = Mesh.provenance(of: job.url) else { continue }
                out[job.id] = (said.designer, said.licence)
            }
            return out
        }
        var found: [LibraryFile.ID: (source: String, licence: String)] = [:]
        for (id, said) in read {
            let licence = ModelLicence.fromFile(said.licence)?.id ?? ""
            guard !said.designer.isEmpty || !licence.isEmpty else { continue }
            found[id] = (said.designer, licence)
        }
        guard !found.isEmpty, let build = source.build else { return 0 }

        // NOT `editFiles`: that registers an Undo, and the first Cmd-Z after
        // launch then undid a change the shop never made. And each field is
        // filled only if it is STILL blank in the book as it is now — a
        // source typed while the zips were being read is the shop's, and
        // wins. Found by the September 2026 scan.
        let filled = found
        do {
            // lock: system — background: where a model came from, read out of the files themselves.
            // Off the main actor: the whole book is read and written.
            try await StoreWriter.updateOffMain(build) { root in
                let found = filled
                guard case .array(var rows)? = root["printFiles"] else { return }
                for i in rows.indices {
                    guard case .object(var record) = rows[i],
                          case .string(let id)? = record["id"], let said = found[id] else { continue }
                    var changed = false
                    if !said.source.isEmpty, (Self.plainString(record["source"]) ?? "").isEmpty {
                        record["source"] = .string(said.source); changed = true
                    }
                    if !said.licence.isEmpty, (Self.plainString(record["licence"]) ?? "").isEmpty {
                        record["licence"] = .string(said.licence); changed = true
                    }
                    guard changed else { continue }
                    StoreWriter.stamp(&record)
                    rows[i] = .object(record)
                }
                root["printFiles"] = .array(rows)
            }
        } catch {
            return 0
        }
        await load(source)
        return found.count
    }

    /// Record where a model came from — a model-site URL, or the shop's own
    /// name for it. Free text on purpose: it is a note to a person.
    func setSourceOnSelection(_ typed: String) async {
        let ids = selectedIds
        guard !ids.isEmpty else { return }
        // Trimmed and capped at the other app's own `maxlength`, so a source
        // typed here is one it will show back.
        let source = String(typed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        editFiles(ids, named: words.callIt("mac.source_set")) { record in
            record["source"] = .string(source)
        }
    }

    /// The licence everything selected already carries, or nil when they
    /// disagree — the same reasoning as `tagsOnSelection`: showing one model's
    /// answer and writing it to the rest would hand them one they never had.
    var licenceOnSelection: String? {
        let chosen = selectedFiles
        guard let first = chosen.first else { return nil }
        let id = ModelLicence.find(first.licence)?.id ?? ""
        return chosen.allSatisfy { (ModelLicence.find($0.licence)?.id ?? "") == id } ? id : nil
    }

    /// The source shared by everything selected, or empty when they disagree.
    var sourceOnSelection: String {
        let chosen = selectedFiles
        guard let first = chosen.first?.source else { return "" }
        return chosen.allSatisfy { ($0.source ?? "") == first } ? first : ""
    }

    /// What the tag box starts with: the tags shared by everything selected.
    ///
    /// Not the first one's tags. With several chosen, showing one model's tags
    /// and then writing them to all of them would quietly hand the rest a set
    /// they never had.
    var tagsOnSelection: [String] {
        let chosen = selectedFiles
        guard let first = chosen.first else { return [] }
        var shared = first.tags ?? []
        for file in chosen.dropFirst() {
            let theirs = Set((file.tags ?? []).map { $0.lowercased() })
            shared = shared.filter { theirs.contains($0.lowercased()) }
        }
        return shared
    }

    /// What the library grid shows: projects as folders, then loose files.
    ///
    /// Only at the TOP of the library. Inside a folder the shelf already
    /// carries the group, and the grid is the files in it — a folder within a
    /// folder is a different feature and this is not pretending to be it.
    /// Is this file's group the folder being looked at, or somewhere beneath
    /// it?
    ///
    /// The separator matters: `MyProject` must not swallow `MyProjectile`, so
    /// a deeper match has to be on `MyProject/` and never on the bare prefix.
    nonisolated static func isUnder(_ group: String?, _ folder: String) -> Bool {
        guard let group else { return false }
        return group == folder || group.hasPrefix(folder + ImportGrouping.separator)
    }

    var shownEntries: [LibraryEntry] {
        // THE ONE BUILDER of what the grid draws: the selection
        // (`visibleFiles`) is read from this list, so a new way of drawing
        // the library belongs here and nowhere else. See `libraryShowsFlat`.
        guard !libraryShowsFlat, case .library(let group) = shelf else {
            return shownFiles.map { LibraryEntry.file($0) }
        }
        return Self.libraryEntries(shownFiles, under: group, flat: libraryFlat,
                                   showingMatches: libraryShowsMatches, kinds: libraryGroupKinds,
                                   order: librarySort.order)
    }

    /// The library's tiles, without a shop around it, so it can be tested on
    /// a library with groups in it (the sample book has none).
    ///
    /// - Inside a folder, either view: that folder's own levels. A project
    ///   with levels shows its sub-folders when it is opened; before that it
    ///   showed a flat list of everything beneath it, which was as hard to
    ///   read as the flat import it replaced.
    /// - Groups view at the top: every group a tile, loose models as models.
    /// - All models, searching or filtering: the matches flat, wherever they
    ///   live, the way a Finder search is — each tile names its group
    ///   (`Cell.groupShown`) with a way into it.
    /// - All models otherwise: a group that is one print in parts is one
    ///   tile, a collection's models are models (`LibraryEntry.allModels`).
    ///   Before the kinds existed this was every model flat, and a group the
    ///   shop had just made was nowhere to be seen — reported as *"the group I
    ///   created still appears as single models in All models"*.
    static func libraryEntries(_ files: [LibraryFile], under group: String?, flat: Bool,
                               showingMatches: Bool, kinds: [String: GroupKind],
                               order: (LibraryFile, LibraryFile) -> Bool) -> [LibraryEntry] {
        if showsFlat(under: group, flat: flat, showingMatches: showingMatches) {
            return files.map { LibraryEntry.file($0) }
        }
        if group != nil || !flat { return LibraryEntry.top(of: files, under: group, order: order) }
        return LibraryEntry.allModels(of: files, kinds: kinds, order: order)
    }

    /// Is every shown model its own tile? Only in All models, at the top, while
    /// a search or filter is on. Plain All models is NOT flat any more: a
    /// group that is one print in parts collapses to one tile.
    nonisolated static func showsFlat(under group: String?, flat: Bool, showingMatches: Bool) -> Bool {
        group == nil && flat && showingMatches
    }

    /// One axis of the library filter: a name, or the things that have none.
    ///
    /// "Unfiled" is a CASE rather than a sentinel string. The other app used a
    /// magic value and it went through a `data-` attribute, where a NUL became
    /// U+FFFD and the chip quietly matched nothing — the Unfiled chip was dead
    /// for weeks. A case cannot be mangled on the way to a comparison.
    enum FilterChoice: Hashable {
        case named(String)
        case unfiled

        /// Does a record's value for this axis match? Case-insensitively,
        /// because the shop's own spellings are folded everywhere else too.
        func matches(_ value: String?) -> Bool {
            switch self {
            case .unfiled: return (value ?? "").isEmpty
            case .named(let want):
                return (value ?? "").lowercased() == want.lowercased()
            }
        }
    }

    /// The chips the library filter bar offers.
    ///
    /// ── EVERY AXIS IS COUNTED OVER WHAT THE OTHERS LEAVE ──────────────────
    ///
    /// A chip says a number, a shop decides whether to press it on that number,
    /// and a count describing a different population from the grid under it is
    /// a lie the shop cannot see. The other app shipped exactly that and its own
    /// note records the symptom: *"these counted the whole catalogue while the
    /// grid narrows on three things at once, so with a category on, a group
    /// chip said 7 and pressing it showed 2."*
    ///
    /// So each axis is counted over the rows the OTHER axes leave — the shelf,
    /// the search box and the two chips that are not this one. Counting a chip
    /// against its own axis would instead narrow the row to whatever is already
    /// on and the shop could never press a second value.
    ///
    /// ── AND FROM THE SHARED RULE, NOT FROM SWIFT ──────────────────────────
    ///
    /// The arithmetic is the easy half. What matters is the FOLDING: a shop that
    /// typed "Wall art" once and "wall art" twice has one category holding
    /// three, not two holding some each. `Dictionary(grouping:)` would get the
    /// sum right and the shop's own idea of its library wrong.
    struct LibraryFacets: Equatable {
        var categories: [KhaytEngine.GroupCount] = []
        var tags: [KhaytEngine.GroupCount] = []
        /// Models in no project at all — the answer to "what have I not filed
        /// yet". Zero inside a folder, where nothing can be unfiled, which is
        /// how that chip disappears when it would teach the wrong thing.
        var unfiled = 0
        /// Models this shop has never actually made.
        ///
        /// The other library tools in this category carry a printed FLAG a
        /// person ticks. Khayt has the real answer — `timesPrinted` is written
        /// by the jobs — so this is a fact rather than a reminder, and the
        /// question it answers is the one a shop with a big library asks:
        /// what have I collected and never printed.
        var neverPrinted = 0
        /// Per machine that says what it has loaded: how many models could
        /// start on it now, without a spool swap.
        var ready: [Ready] = []
        /// Creators, busiest first; see `LibraryFile.creator`.
        var creators: [CreatorCount] = []
        var printNext = 0
        var duplicates = 0
        struct Ready: Equatable, Identifiable {
            let machineId: String
            let machineName: String
            let count: Int
            var id: String { machineId }
        }
        var isEmpty: Bool {
            categories.isEmpty && tags.isEmpty && unfiled == 0 && neverPrinted == 0 && ready.isEmpty
                && creators.isEmpty && printNext == 0 && duplicates == 0
        }
    }

    enum LibraryAxis { case unfiled, category, tag, neverPrinted, ready, creator, printNext, duplicates }

    /// What one axis counts: the shelf, the search, and the other two chips.
    private func libraryPool(skipping axis: LibraryAxis) -> [JSONValue] {
        var rows = libraryRows
        if case .library(let group) = shelf, let group {
            rows = rows.filter { Self.isUnder(Self.rowGroup($0), group) }
        }
        if axis != .unfiled, libraryUnfiledOnly {
            rows = rows.filter { Self.rowGroup($0) == nil }
        }
        if axis != .neverPrinted, libraryNeverPrintedOnly {
            rows = rows.filter { Self.rowPrintCount($0) == 0 }
        }
        if axis != .category, let category = libraryCategory {
            rows = rows.filter { category.matches(Self.rowText($0, "category")) }
        }
        if axis != .tag, let tag = libraryTag {
            rows = rows.filter { Self.rowTags($0).contains { $0.lowercased() == tag.lowercased() } }
        }
        if axis != .ready, let machine = libraryReadyOn {
            let ready = readyByMachine[machine] ?? []
            rows = rows.filter { ready.contains(Self.rowText($0, "id")) }
        }
        if axis != .creator, let creator = libraryCreator {
            rows = rows.filter {
                LibraryFile.creator(of: Self.rowText($0, "source"))?.lowercased() == creator.lowercased()
            }
        }
        if axis != .printNext, libraryPrintNextOnly {
            rows = rows.filter { !Self.rowText($0, "printNextAt").isEmpty }
        }
        if axis != .duplicates, libraryDuplicatesOnly {
            rows = rows.filter { duplicateOf[Self.rowText($0, "id")] != nil }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { row in
            Self.rowText(row, "title").lowercased().contains(q)
                || Self.rowText(row, "material").lowercased().contains(q)
                || Self.rowTags(row).contains { $0.lowercased().contains(q) }
        }
    }

    /// How many times a record says it has been printed.
    ///
    /// `timesPrinted` is the field; absent means none, which is the same
    /// answer a record written before the field existed gives.
    private static func rowPrintCount(_ row: JSONValue) -> Int {
        guard case .object(let o) = row, case .number(let n)? = o["timesPrinted"] else { return 0 }
        return Int(n)
    }

    /// The group a record is in, by the rule the grid files it under —
    /// `folder` if the key is there at all, then `group`. Splitting on `group`
    /// alone would count a model under one project and draw it in another.
    private static func rowGroup(_ row: JSONValue) -> String? {
        guard case .object(let o) = row else { return nil }
        let text: (String) -> String? = { key in
            if case .string(let v)? = o[key] { return v }
            return o[key] == nil ? nil : ""
        }
        return LibraryFile.groupName(folder: text("folder"), group: text("group"))
    }

    private static func rowText(_ row: JSONValue, _ key: String) -> String {
        guard case .object(let o) = row, case .string(let v)? = o[key] else { return "" }
        return v
    }

    private static func rowTags(_ row: JSONValue) -> [String] {
        guard case .object(let o) = row, case .array(let rows)? = o["tags"] else { return [] }
        return rows.compactMap { if case .string(let t) = $0 { t } else { nil } }
    }

    func readLibraryFacets() async {
        libraryRecount += 1
        let mine = libraryRecount
        guard let engine, !libraryRows.isEmpty else { libraryFacets = LibraryFacets(); return }
        let categories = (try? await engine.categoryCounts(libraryPool(skipping: .category))) ?? []
        let tags = (try? await engine.tagCounts(libraryPool(skipping: .tag))) ?? []
        guard mine == libraryRecount else { return }
        let unfiled = libraryPool(skipping: .unfiled).count { Self.rowGroup($0) == nil }
        let never = libraryPool(skipping: .neverPrinted).count { Self.rowPrintCount($0) == 0 }
        // Across the whole book, once per machine that reports what it has
        // loaded; the chip's count is that set within what the other chips and
        // the search have left.
        var byMachine: [String: Set<String>] = [:]
        var ready: [LibraryFacets.Ready] = []
        for machine in machines {
            let loaded = loadedSlots(for: machine.id)
            guard !loaded.isEmpty else { continue }
            let ids = Set((try? await engine.readyToPrint(libraryRows, loaded: loaded)) ?? [])
            byMachine[machine.id] = ids
            let count = libraryPool(skipping: .ready).count { ids.contains(Self.rowText($0, "id")) }
            ready.append(.init(machineId: machine.id, machineName: machine.name, count: count))
        }
        guard mine == libraryRecount else { return }
        readyByMachine = byMachine
        // The three counted in Swift, over the same pool: the ids the other
        // axes leave, each skipping its own.
        duplicateOf = Self.duplicateGroups(files)
        func ids(_ axis: LibraryAxis) -> Set<String> {
            Set(libraryPool(skipping: axis).map { Self.rowText($0, "id") })
        }
        let byId = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var creatorCounts: [String: (name: String, n: Int)] = [:]
        for id in ids(.creator) {
            guard let c = byId[id]?.creator else { continue }
            creatorCounts[c.lowercased(), default: (c, 0)].n += 1
        }
        let creators = creatorCounts.values.map { CreatorCount(name: $0.name, count: $0.n) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        let printNext = ids(.printNext).count { byId[$0]?.isPrintNext == true }
        let dupes = ids(.duplicates).count { duplicateOf[$0] != nil }
        libraryFacets = LibraryFacets(categories: categories, tags: tags,
                                      unfiled: unfiled, neverPrinted: never, ready: ready,
                                      creators: creators, printNext: printNext, duplicates: dupes)
    }

    func recountLibrarySoon() { libraryRecountTask = Task { await readLibraryFacets() } }

    /// Wait for the chips to catch up with what was last asked of them.
    ///
    /// The recounts are started by the setters, so nothing on screen has to
    /// remember to ask — but that leaves no moment at which they are known to be
    /// finished, and a test that reads them right after changing the shelf is
    /// reading whatever happened to land. Draining in a loop rather than
    /// awaiting once, because a change made WHILE one is in flight starts
    /// another.
    func settleLibraryFacets() async {
        while let pending = libraryRecountTask {
            libraryRecountTask = nil
            await pending.value
        }
    }

    /// Is the shop LOOKING for something — a search typed, or any filter on?
    /// Then All models shows the matching models flat, parts and all; see
    /// `libraryEntries`.
    var libraryShowsMatches: Bool {
        libraryFilterOn || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Does the library draw every shown model as a tile (true), or the tiles
    /// `libraryEntries` builds — folders, parts groups, models (false)?
    ///
    /// THE ONE PLACE that decides it. `shownEntries` draws from it and
    /// `visibleFiles` — which every selection reads — is derived from the same
    /// entries, so what can be selected can never drift from what is drawn.
    /// Outside the library everything shown is a plain row.
    var libraryShowsFlat: Bool {
        guard case .library(let group) = shelf else { return true }
        return Self.showsFlat(under: group, flat: libraryFlat, showingMatches: libraryShowsMatches)
    }

    /// A filter axis changed: recount the chips, and drop from the selection
    /// anything the change has taken off the screen.
    func libraryViewChanged() {
        recountLibrarySoon()
        pruneSelectionToVisible()
    }

    /// What a machine has loaded: as it last reported it, or, for a printer
    /// that cannot say, what the shop typed on the machine. The printer's own
    /// reading wins whenever it has one — it is the thing that was swapped.
    func loadedSlots(for machineId: String) -> [KhaytEngine.LoadedSlot] {
        let reported = printers.readings[machineId]?.status?.loaded ?? []
        if !reported.isEmpty { return reported }
        return machines.first { $0.id == machineId }?.loadedByHand ?? []
    }

    /// Can this model start on that machine now, with what it has loaded?
    func isReady(_ file: LibraryFile, on machineId: String) -> Bool {
        readyByMachine[machineId]?.contains(file.id) ?? false
    }

    /// A machine's loaded spools changed: the ready counts are stale.
    func loadedChanged() { recountLibrarySoon() }

    var libraryFilterOn: Bool {
        libraryCategory != nil || libraryTag != nil || libraryUnfiledOnly
            || libraryNeverPrintedOnly || libraryReadyOn != nil
            || libraryCreator != nil || libraryPrintNextOnly || libraryDuplicatesOnly
    }

    func clearLibraryFilter() {
        libraryCategory = nil
        libraryTag = nil
        libraryUnfiledOnly = false
        libraryNeverPrintedOnly = false
        libraryReadyOn = nil
        libraryCreator = nil
        libraryPrintNextOnly = false
        libraryDuplicatesOnly = false
    }

    /// ── DUPLICATES, in the library already there ─────────────────────────
    ///
    /// An import refuses a file whose bytes are already in the library, but a
    /// library that grew before that rule — or through the other app, or two
    /// re-exports of one model — holds copies nobody can see. Two kinds, as
    /// `lib/model-identity.js` draws them: the SAME FILE (`contentHash`,
    /// certain) and the SAME MESH (`geometryKey`, a strong hint — a model
    /// re-saved from another slicer). Each id maps to the key it shares.
    static func duplicateGroups(_ files: [LibraryFile]) -> [String: String] {
        var byKey: [String: [String]] = [:]
        for f in files where !f.isArchived {
            if let h = f.contentHash, !h.isEmpty { byKey["file:" + h, default: []].append(f.id) }
            if let g = f.geometryKey, let tris = Int(g.split(separator: ":").first ?? ""), tris > 0 {
                byKey["mesh:" + g, default: []].append(f.id)
            }
        }
        var out: [String: String] = [:]
        for (key, ids) in byKey where Set(ids).count > 1 {
            for id in ids where out[id] == nil || key.hasPrefix("file:") { out[id] = key }
        }
        return out
    }

    /// The other models this one is a duplicate of.
    func duplicates(of file: LibraryFile) -> [LibraryFile] {
        guard let key = duplicateOf[file.id] else { return [] }
        return files.filter { $0.id != file.id && duplicateOf[$0.id] == key }
    }

    /// The creators in the library, busiest first.
    struct CreatorCount: Equatable, Identifiable { let name: String; let count: Int; var id: String { name } }

    /// Put these models on the Print next list, or take them off.
    func setPrintNext(_ ids: Set<LibraryFile.ID>, on: Bool) {
        let at = StoreWriter.iso(Date())
        editFiles(ids, named: words.callIt(on ? "mac.print_next_add" : "mac.print_next_remove")) { record in
            if on { if record["printNextAt"] == nil { record["printNextAt"] = .string(at) } }
            else { record.removeValue(forKey: "printNextAt") }
        }
    }

    var shownFiles: [LibraryFile] {
        var rows = files
        // A model a conversion has replaced is put aside rather than deleted —
        // see `LibraryFile.archivedAt`. It is still in the book, still on disk
        // and still what a past job was printed from; it is simply not one of
        // the things the shop is choosing between today.
        if !libraryShowArchived { rows = rows.filter { !$0.isArchived } }
        if case .library(let group) = shelf, let group {
            rows = rows.filter { Self.isUnder($0.groupName, group) }
        }
        // Every axis narrows at once, deliberately: "the busts in the Saudi
        // Kings" is the question a library of hundreds is actually asked — the
        // same reasoning renderer/printfiles.js gives for its own chips.
        if libraryUnfiledOnly { rows = rows.filter { ($0.groupName ?? "").isEmpty } }
        if libraryNeverPrintedOnly { rows = rows.filter { $0.printCount == 0 } }
        if let machine = libraryReadyOn {
            let ready = readyByMachine[machine] ?? []
            rows = rows.filter { ready.contains($0.id) }
        }
        if let category = libraryCategory { rows = rows.filter { category.matches($0.category) } }
        if let tag = libraryTag {
            rows = rows.filter { ($0.tags ?? []).contains { $0.lowercased() == tag.lowercased() } }
        }
        if let creator = libraryCreator {
            rows = rows.filter { $0.creator?.lowercased() == creator.lowercased() }
        }
        if libraryPrintNextOnly { rows = rows.filter(\.isPrintNext) }
        if libraryDuplicatesOnly { rows = rows.filter { duplicateOf[$0.id] != nil } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            // The file's name too, and folded — see `LibraryFile.matches`.
            let folded = SearchText.fold(q)
            rows = rows.filter { $0.matches(folded: folded) }
        }
        // Side by side: the copies of one model together, oldest first.
        if libraryDuplicatesOnly {
            return rows.sorted { (duplicateOf[$0.id] ?? "", $0.id) < (duplicateOf[$1.id] ?? "", $1.id) }
        }
        // The list, in the order it was made.
        if libraryPrintNextOnly {
            return rows.sorted { ($0.printNextAt ?? "") < ($1.printNextAt ?? "") }
        }
        return librarySort.sorted(rows)
    }

    /// The inspector shows one model. More than one selected is a different
    /// screen — what they have in common, and what can be done to all of them.
    ///
    /// ── ONLY WHAT IS ON SCREEN ────────────────────────────────────────────
    ///
    /// Both read through `visibleFiles`, never `files` or `shownFiles`. In the
    /// grouped view `shownFiles` also holds every model INSIDE the folder
    /// tiles, and a selection read from it acted on models nobody could see:
    /// ⌘A, a ⇧-click range and a ⇧-arrow all reached into the folders, and a
    /// right-click "Delete 34 Models…" deleted a whole group the shop never
    /// chose (27 Sep 2026). A folder tile is not a selected model.
    var selectedFile: LibraryFile? {
        guard fileSelection.count == 1 else { return nil }
        let chosen = selectedFiles
        return chosen.count == 1 ? chosen[0] : nil
    }
    var selectedFiles: [LibraryFile] {
        let chosen = fileSelection
        guard !chosen.isEmpty else { return [] }
        return visibleFiles.filter { chosen.contains($0.id) }
    }
    /// The ids every "these models" action writes to. See `selectedFiles`.
    var selectedIds: Set<LibraryFile.ID> { Set(selectedFiles.map(\.id)) }

    /// The models drawn as model tiles right now, in the order they are drawn.
    ///
    /// ALWAYS derived from `shownEntries` — the very list the grid draws —
    /// and never from `shownFiles`. Grouped: the models loose at this level;
    /// whatever sits inside a folder tile is not here. Flat: every shown
    /// model. Whatever `shownEntries` comes to draw (a group shown as one tile
    /// in the flat view, say), this follows without being told.
    var visibleFiles: [LibraryFile] { Self.modelTiles(shownEntries) }

    /// The `.file` entries of a drawn list — the only things a selection may
    /// hold. A folder tile is not a selected model.
    static func modelTiles(_ entries: [LibraryEntry]) -> [LibraryFile] {
        entries.compactMap { entry in
            if case .file(let f) = entry { return f }
            return nil
        }
    }

    /// Drop from the selection anything no longer drawn as a model tile.
    func pruneSelectionToVisible() {
        guard !fileSelection.isEmpty || anchor != nil || cursor != nil else {
            pruneGroupSelectionToVisible(); return
        }
        let visible = Set(visibleFiles.map(\.id))
        let kept = fileSelection.intersection(visible)
        if kept != fileSelection { fileSelection = kept }
        if let a = anchor, !visible.contains(a) { anchor = nil }
        if let c = cursor, !visible.contains(c) { cursor = nil }
        pruneGroupSelectionToVisible()
    }

    /// Nothing selected, and the keyboard standing nowhere.
    func clearLibrarySelection() {
        if !fileSelection.isEmpty { fileSelection = [] }
        if !groupSelection.isEmpty { groupSelection = [] }
        groupAnchor = nil
        anchor = nil
        cursor = nil
    }

    /// Click, ⌘-click, ⇧-click. Written out because a grid is not a `List` and
    /// gets none of this for free — and a Mac app where ⌘-click does not extend
    /// a selection is one that reads as a web page however it is drawn.
    func select(_ file: LibraryFile, modifiers: SelectionModifier) {
        switch modifiers {
        case .replace:
            fileSelection = [file.id]
            anchor = file.id
            cursor = file.id
        case .toggle:
            if fileSelection.contains(file.id) { fileSelection.remove(file.id) }
            else { fileSelection.insert(file.id); anchor = file.id }
            cursor = file.id
        case .extend:
            let rows = visibleFiles
            guard let end = rows.firstIndex(where: { $0.id == file.id }) else { return }
            let start = anchor.flatMap { a in rows.firstIndex { $0.id == a } } ?? end
            let range = start <= end ? start...end : end...start
            fileSelection.formUnion(rows[range].map(\.id))
            cursor = file.id
        }
    }

    enum SelectionModifier { case replace, toggle, extend }

    /// Move the selection by `step` places in reading order.
    ///
    /// Reading order, not screen order: in a mirrored window the next model is
    /// to the LEFT. The caller has already turned the key into a direction;
    /// this only counts.
    ///
    /// TWO POSITIONS, NOT ONE. `anchor` is where a selection run started and
    /// `cursor` is where the keyboard is standing. Computing the next place from
    /// the anchor — which is what this did first — means a second shift-arrow
    /// lands where the first one did and the selection never grows past two.
    ///
    /// Returns whether it moved, so a key at either end is left unhandled and
    /// the system beep can do its job.
    @discardableResult
    func moveSelection(by step: Int, extending: Bool) -> Bool {
        let rows = visibleFiles
        guard !rows.isEmpty else { return false }

        guard let here = cursor.flatMap({ c in rows.firstIndex { $0.id == c } }) else {
            // Nothing chosen yet: the first press picks an end rather than doing
            // nothing, which is what a Finder window does.
            let landing = step >= 0 ? rows.first! : rows.last!
            fileSelection = [landing.id]
            anchor = landing.id
            cursor = landing.id
            return true
        }

        let next = here + step
        guard rows.indices.contains(next) else { return false }
        cursor = rows[next].id
        if extending {
            let start = anchor.flatMap { a in rows.firstIndex { $0.id == a } } ?? here
            let range = start <= next ? start...next : next...start
            fileSelection = Set(rows[range].map(\.id))
        } else {
            fileSelection = [rows[next].id]
            anchor = rows[next].id
        }
        return true
    }

    /// ⌘A: every model tile on screen — never what is inside a folder tile.
    func selectAllShown() {
        let rows = visibleFiles
        fileSelection = Set(rows.map(\.id))
        anchor = rows.first?.id
        cursor = anchor
    }

    /// The one the keyboard is standing on, for scrolling into view.
    var focusedFile: LibraryFile.ID? { cursor ?? fileSelection.first }

    /// Show a model now if the book is open, and as soon as it is if not.
    func revealWhenLoaded(fileId: String) {
        if reveal(fileId: fileId) { return }
        // Not found YET is not the same as not there. If the library has rows
        // and this is not one of them, the model is genuinely gone and holding
        // the request would make the next load jump somewhere unasked.
        pendingReveal = files.isEmpty ? fileId : nil
    }

    /// Answer a held request, once there is a library to answer it from.
    func answerPendingReveal() {
        guard let wanted = pendingReveal else { return }
        pendingReveal = nil
        reveal(fileId: wanted)
    }

    /// Returns whether the model was found at all. A book that has moved on
    /// since Spotlight last heard about it is a real state, and the caller
    /// needs to know rather than leave the window sitting on an empty library.
    @discardableResult
    func reveal(fileId: String) -> Bool {
        guard let file = files.first(where: { $0.id == fileId }) else { return false }
        search = ""
        // Every axis, not some: a filter left on (ready on a machine, a
        // creator, Print next, duplicates) can hide the model, and a model not
        // on screen cannot be the selection — see `selectedFiles`.
        clearLibraryFilter()
        if file.isArchived { libraryShowArchived = true }
        // Into its own project if it has one: that is where the model lives,
        // and opening the library at the top with one tile selected somewhere
        // below is not showing it to anybody.
        shelf = .library(file.groupName)
        fileSelection = [file.id]
        cursor = file.id
        return true
    }

    // MARK: - What a model is set up to print like

    /// What the file says about how it prints, or nil until it has been read.
    ///
    /// READ FROM THE FILE, NOT FROM THE RECORD. These could have been captured
    /// at import and stored, and then every model imported before today would
    /// have none — and a model re-sliced for a different machine would keep
    /// saying what it used to be. The configs are two small members of the zip;
    /// finding them costs the central directory, not the 436 MB in front of it.
    /// Stand up a farm, for a snapshot that has no farm to photograph.
    ///
    /// A ten-printer shop is the case the band's compact density exists for, and
    /// nothing in this repo has ten printers — so without this the layout that
    /// only appears above four machines would ship having been reviewed by
    /// nobody. It is the same concession as `setReadingForTesting`: the runner
    /// cannot put nine more printers on this Mac's network.
    ///
    /// Copies the shop's own machines and the jobs on them, so the picture is of
    /// this app drawing real rows rather than of a fixture.
    /// Give one of the book's machines a printer connection, for a test that
    /// needs a WATCHED machine — the sample shop's machines have none. Decoded
    /// the way `standUpFarmForSnapshot` decodes, for the same reason.
    func connectMachineForTesting(_ id: String, type: String) {
        guard let i = machineRows.firstIndex(where: { Self.recordId($0) == id }),
              case .object(var row) = machineRows[i] else { return }
        row["printerApi"] = .object(["type": .string(type), "host": .string("192.0.2.1")])
        let copy = JSONValue.object(row)
        guard let data = try? JSONEncoder().encode(copy),
              let machine = try? JSONDecoder().decode(Machine.self, from: data),
              let j = machines.firstIndex(where: { $0.id == id }) else { return }
        machines[j] = machine
        machineRows[i] = copy
    }

    /// Take the book's printing jobs off one machine, in memory only, so a
    /// test can reach the band's IDLE path — every filament printer in the
    /// sample shop has a job on it.
    func clearPrintingForTesting(on machineId: String) {
        orderRows = orderRows.map { row in
            guard case .object(var o) = row,
                  case .string(let m)? = o["machineId"], m == machineId,
                  case .string("printing")? = o["status"] else { return row }
            o["status"] = .string("pending")
            o["machineId"] = .null
            return .object(o)
        }
    }

    func standUpFarmForSnapshot(_ n: Int) {
        guard !machines.isEmpty, machines.count < n else { return }
        var grown = machines
        var rows = machineRows
        var i = machines.count
        while grown.count < n, i < n {
            guard case .object(var row) = machineRows[i % machineRows.count] else { break }
            row["id"] = .string(String(format: "FARM-%02d", i + 1))
            row["name"] = .string(String(format: "Printer %02d", i + 1))
            let copy = JSONValue.object(row)
            // Decoded rather than copied field by field: a `Machine` built here
            // by hand would drift from the one the store produces the moment
            // anybody adds a field, and this is the only place that would not
            // notice.
            if let data = try? JSONEncoder().encode(copy),
               let machine = try? JSONDecoder().decode(Machine.self, from: data) {
                grown.append(machine)
                rows.append(copy)
            }
            i += 1
        }
        machines = grown
        machineRows = rows
    }

    /// The next `hours` on the machines.
    ///
    /// Recomputed rather than cached: it depends on the printers' answers and on
    /// the time, and a band that is five minutes stale draws its now-line in the
    /// wrong place — which is the one mark on it that has to be right.
    ///
    /// ── WHICH MACHINES GET A READING ───────────────────────────────────────
    ///
    /// Only the ones whose printer says it is PRINTING. A failed poll carries a
    /// `problem` and no status, so it is already absent — but an idle printer
    /// answers perfectly well with `progress: 0`, and a job still marked
    /// printing in the book against an idle machine would then be drawn as
    /// starting now and running its whole estimate. That is a confident picture
    /// of something that is not happening. Left out, the row says the end is
    /// unknown, which is true and is what a shop should go and look at.
    func machineBand(hours: Double = 48) async -> KhaytEngine.MachineBand? {
        guard let engine else { return nil }
        // ── ONE STATUS SOURCE ─────────────────────────────────────────────
        //
        // Every machine is asked `quiet` — the test the dashboard tile and
        // Next up read — and nothing else. It went wrong twice: first a
        // printer with NO reading was drawn free while the other screens said
        // not answering; then (alpha.51) one with a failed reading and fewer
        // than three misses was drawn "Free · 48:00" and counted into the
        // total, because the band granted the three-poll grace to a printer
        // that had never answered at all. `heard` decides the grace now, for
        // all three. A machine Khayt has no protocol for, or one not set up,
        // is still counted as free: the shop plans those by hand.
        return try? await engine.machineBand(machines: machineRows, orders: orderRows,
                                             inventory: inventoryRows, live: liveReadings(),
                                             now: Date(), hours: hours)
    }

    /// What the printers said, in the shape `lib/machine-band.js` and
    /// `lib/kiosk.js` both read: a reading only for a machine that is
    /// PRINTING (see `machineBand` for why an idle answer is left out), an
    /// `error` for one that is not answering.
    private func liveReadings() -> [String: JSONValue] {
        var live: [String: JSONValue] = [:]
        for machine in machines {
            if let status = printers.heard(machine.id) {
                guard PrinterWatch.isPrinting(status.state) else { continue }
                var seen: [String: JSONValue] = ["progress": .number(Double(status.progress))]
                if let left = status.timeRemaining { seen["timeRemaining"] = .number(left) }
                live[machine.id] = .object(seen)
            } else if quiet(machine) == .notAnswering {
                let why = printers.readings[machine.id]?.problem ?? words.callIt("mac.attn_state_offline")
                live[machine.id] = .object(["error": .string(why)])
            }
        }
        return live
    }

    /// The kiosk's cards: one per machine, from the same readings as the band,
    /// so the screen across the room cannot disagree with the Machines screen
    /// about which printer is printing.
    func kiosk() async -> [KhaytEngine.KioskCard]? {
        guard let engine else { return nil }
        return try? await engine.kiosk(machines: machineRows, orders: orderRows,
                                       live: liveReadings(), mode: mode, now: Date())
    }

    /// What one machine is due for.
    ///
    /// Recomputed rather than cached, like the band: the hour meter climbs with
    /// every job that finishes, and a card still showing "40h remaining" after
    /// the meter passed it is the one thing this screen exists to prevent.
    ///
    /// Nil when the machine has no tasks at all, so the card can leave the
    /// section out entirely rather than drawing an empty heading — most shops
    /// have not set any up, and a permanent "No tasks" on every printer is
    /// noise on the screen a shop looks at most.
    func maintenance(for machine: Machine) async -> KhaytEngine.MaintenanceCard? {
        guard let engine, !maintTaskRows.isEmpty else { return nil }
        let card = try? await engine.maintenance(
            machineId: machine.id, tasks: maintTaskRows, jobs: orderRows,
            machine: .object(["id": .string(machine.id)]), now: Date())
        guard let card, !card.tasks.isEmpty else { return nil }
        return card
    }

    /// Record a task as done, at the meter's current reading.
    ///
    /// The patch is the shared rule's, not one assembled here — which fields a
    /// completion writes is part of the maintenance contract, and the Electron
    /// app reads these same records back.
    ///
    /// The hours written are the meter as it reads NOW, which is the whole
    /// point: the next interval is counted from this moment, and writing the
    /// figure the card happened to be showing would count any job that finished
    /// while the card was open twice.
    /// Put back the spool SIZE a product was costed on — when the shop says so.
    ///
    /// ── WHAT WAS WRONG ─────────────────────────────────────────────────────
    ///
    /// Five places copied a spool's `weight` (grams LEFT) into a part's
    /// `spoolWeight`, which `calculator-cost.js` divides the spool's price by.
    /// A product costed from a spool with 859 g left paid 75/859 a gram, not
    /// 75/1000: 16% too much for the plastic, and more as the spool empties.
    /// The code is fixed; this fixes what it already wrote.
    ///
    /// ── WHY IT NO LONGER RUNS ON ITS OWN ──────────────────────────────────
    ///
    /// It used to run on EVERY open, and every write reopens the book. "A part
    /// whose figure differs from its spool's size" is not only the old bug: it
    /// is also every product costed on a spool whose size the shop has since
    /// edited, or that a sync merged a different record of. So changing one
    /// spool's size silently re-priced every product made from it — and a live
    /// web store then followed. That is the shape of the Sep 2026 catalogue
    /// price incident (a save re-priced a product 50 → 13.74 without asking).
    ///
    /// A price is a promise the shop makes to customers. Nothing here changes
    /// one without the shop seeing the before and after first: an open only
    /// COUNTS the products that would change (`spoolRepairPending`), the
    /// catalogue offers a review, `spoolRepairPreview` says what each price
    /// would become, and `applySpoolRepair` writes only what was shown.
    ///
    /// A spool with no recorded size is 1000 g, as everywhere.
    /// The parts with each spool's SIZE in place, or nil when none differed.
    static func spoolSizesFixed(_ parts: [JSONValue], sizes: [String: Double]) -> [JSONValue]? {
        var changed = false
        let fixed: [JSONValue] = parts.map { part in
            guard case .object(var p) = part, case .string(let spool)? = p["filamentId"],
                  let size = sizes[spool] else { return part }
            if case .number(let had)? = p["spoolWeight"], had == size { return part }
            p["spoolWeight"] = .number(size)
            changed = true
            return .object(p)
        }
        return changed ? fixed : nil
    }

    /// Each spool's size as the cost model reads it: at least a gram, 1000
    /// when none is recorded.
    var spoolSizes: [String: Double] {
        var sizes: [String: Double] = [:]
        for spool in spools { sizes[spool.id] = max(1, spool.spoolWeight ?? 1000) }
        return sizes
    }

    /// How many products are costed on a figure other than their spool's
    /// size. Pure and cheap, so an open can afford it — and it WRITES NOTHING.
    static func spoolRepairCount(products: [JSONValue], sizes: [String: Double]) -> Int {
        products.reduce(0) { n, row in
            guard case .object(let p) = row, case .array(let parts)? = p["parts"] else { return n }
            return spoolSizesFixed(parts, sizes: sizes) == nil ? n : n + 1
        }
    }

    /// One product the repair would change, and what its price would become.
    struct SpoolRepairChange: Identifiable, Equatable {
        let id: String
        let name: String
        /// The record as it was read, so a product edited since the preview
        /// was shown is left alone rather than overwritten.
        let was: JSONValue
        /// The record as it would be written.
        let now: [String: JSONValue]
        let priceWas: Double?
        let priceNow: Double?
    }

    /// The price a product is listed at: its typed price, else the base.
    static func listedPrice(_ record: [String: JSONValue]) -> Double? {
        for key in ["price", "basePrice"] {
            switch record[key] {
            case .number(let n)?: return n
            case .string(let s)?: if let n = Double(s.trimmingCharacters(in: .whitespaces)) { return n }
            default: continue
            }
        }
        return nil
    }

    /// What the repair WOULD do, priced by the same rule the product editor
    /// saves with. Reads only.
    func spoolRepairPreview() async -> [SpoolRepairChange] {
        guard let engine else { return [] }
        let inventory = inventoryRows, settings = settingsDict, consumables = consumableRows
        return await Self.spoolRepairPlan(products: productRows, sizes: spoolSizes) { input in
            try? await engine.productPricingFields(.object(input), inventory: inventory,
                                                   settings: settings, consumables: consumables)
        }
    }

    /// The plan, given the catalogue, the spools' sizes and the pricing rule.
    /// Static so a test can hold it to the sample book with a size changed.
    static func spoolRepairPlan(products: [JSONValue], sizes: [String: Double],
                                price: ([String: JSONValue]) async -> [String: JSONValue]?) async -> [SpoolRepairChange] {
        var out: [SpoolRepairChange] = []
        for row in products {
            guard case .object(let product) = row, case .string(let id)? = product["id"],
                  case .array(let parts)? = product["parts"],
                  let fixed = spoolSizesFixed(parts, sizes: sizes) else { continue }
            var input: [String: JSONValue] = ["parts": .array(fixed)]
            for key in ["defaultMargin", "components", "priceRound", "priceOverride"] {
                if let v = product[key] { input[key] = v }
            }
            var next = product
            next["parts"] = .array(fixed)
            if let priced = await price(input) {
                for (key, value) in priced { next[key] = value }
            }
            var name = ""
            for key in ["name", "nameEn", "nameAr"] where name.isEmpty {
                if case .string(let s)? = product[key] { name = s.trimmingCharacters(in: .whitespaces) }
            }
            out.append(SpoolRepairChange(id: id, name: name, was: row, now: next,
                                         priceWas: listedPrice(product),
                                         priceNow: listedPrice(next)))
        }
        return out
    }

    /// Write the reviewed changes into a book. A product is written only if it
    /// is still exactly as the preview read it. Returns the ids written.
    nonisolated static func applySpoolRepair(_ changes: [SpoolRepairChange], to root: inout [String: JSONValue]) -> [String] {
        let byId = Dictionary(changes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rows = rows(root, "products")
        var done: [String] = []
        for i in rows.indices {
            guard let id = recordId(rows[i]), let fix = byId[id], rows[i] == fix.was else { continue }
            var record = fix.now
            StoreWriter.stamp(&record)
            rows[i] = .object(record)
            done.append(id)
        }
        if !done.isEmpty { root["products"] = .array(rows) }
        return done
    }

    /// The shop confirmed the preview: write it. Each product re-priced here
    /// is a price the shop chose, so a live web store may follow it.
    func applySpoolRepair(_ changes: [SpoolRepairChange]) async {
        guard permitted("inventory", "edit") else { return }
        guard let build = source.build, canMoveJobs, !changes.isEmpty else { return }
        let done: [String]
        do {
            done = try await StoreWriter.updateOffMain(build) { root in
                Self.applySpoolRepair(changes, to: &root)
            }
        } catch {
            moveProblem = String(describing: error)
            return
        }
        guard !done.isEmpty else { return }
        FileHandle.standardError.write(Data("khayt: spool size repair — re-priced \(done.count) product(s) on the shop's say-so\n".utf8))
        moveNotices.append(words.counting(done.count, "mac.spool_repair_done"))
        await load(source)
        for id in done { noteExplicitPrice(id) }
    }

    /// Move a service log written under the old key into the right one.
    ///
    /// ── WHY THIS RUNS AT ALL, AND WHY IT RUNS ONCE ────────────────────────
    ///
    /// A fix verified only on newly-created data strands what a shop already
    /// has. Alphas 21 through 23 wrote every repair into `hub_maint_log_v1`,
    /// which nothing reads, so those rows are a shop's own work sitting in a
    /// field that has no meaning. They are moved, not dropped.
    ///
    /// It is a no-op the second time: the stray key is removed by the same
    /// write, so there is nothing left to find.
    func rescueStrandedServiceLog(_ build: StoreReader.Build?) {
        guard let build, canWrite else { return }
        // Asked before writing, so an ordinary load of an ordinary book does
        // not open the store for writing at all.
        guard rawHasStrandedLog else { return }
        // lock: system — migration: a service log stranded by an old build, moved where the app reads it.
        try? StoreWriter.update(build) { root in
            _ = ServiceLogEdit.rescueStranded(&root)
        }
    }

    func markMaintenanceDone(_ taskId: String, on machine: Machine) async {
        guard permitted("inventory", "edit") else { return }
        guard let engine, let build = source.build, canMoveJobs else { return }
        guard let task = maintTaskRows.first(where: {
            if case .object(let o) = $0, case .string(let id)? = o["id"] { return id == taskId }
            return false
        }) else { return }
        guard let card = try? await engine.maintenance(
            machineId: machine.id, tasks: maintTaskRows, jobs: orderRows,
            machine: .object(["id": .string(machine.id)]), now: Date()),
              let patch = try? await engine.markMaintenanceDone(
                task: task, hours: card.hours, at: Date())
        else { return }

        // What the task is called, for the line this writes in the log.
        var taskName = ""
        if case .object(let o) = task, case .string(let n)? = o["name"] { taskName = n }

        let machineId = machine.id, noted = taskName
        do {
            try await StoreWriter.updateOffMain(build) { root in
                guard case .array(var rows)? = root["machMaintTasks"] else { return }
                for i in rows.indices {
                    guard case .object(var record) = rows[i],
                          case .string(let id)? = record["id"], id == taskId else { continue }
                    for (key, value) in patch { record[key] = value }
                    // Without the stamp the other machine's older copy wins the
                    // next merge and the task goes back to overdue.
                    StoreWriter.stamp(&record)
                    rows[i] = .object(record)
                }
                root["machMaintTasks"] = .array(rows)

                // ── AND THE SERVICE ITSELF ────────────────────────────────
                //
                // The schedule says a nozzle is due; the log says one was
                // changed. Only the second is a history, and this app used to
                // write only the first — so a shop that did its servicing here
                // and read it in Khayt found no record of any of it, and the
                // maintenance figures totalled nothing however much work had
                // been done. The other app has always written both.
                //
                // At no cost. Marking a task done is one click and the shop is
                // standing at the machine, not holding a receipt; what it cost
                // is typed into the entry afterwards, which is also how Khayt
                // does it.
                var log: [JSONValue] = []
                if case .array(let had)? = root[ServiceLogEdit.collection] { log = had }
                var entry = ServiceLogEdit.entry(machineId: machineId, day: Self.localDay(),
                                                 note: noted, cost: 0,
                                                 id: Self.uid("MAINT"))
                StoreWriter.stamp(&entry)
                root[ServiceLogEdit.collection] = .array(ServiceLogEdit.appending(entry, to: log))
            }
            writeProblem = nil
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// The machine's hours meter, as the shared rule counts it.
    ///
    /// A new task is counted from this reading, so a schedule set up today does
    /// not open overdue on a printer that has been running for two years.
    private func machineHours(_ machineId: String) async -> Double {
        guard let engine else { return 0 }
        let card = try? await engine.maintenance(
            machineId: machineId, tasks: maintTaskRows, jobs: orderRows,
            machine: .object(["id": .string(machineId)]), now: Date())
        return card?.hours ?? 0
    }

    /// Set up a recurring maintenance task.
    ///
    /// The schedule half of maintenance, which this app could show and tick off
    /// but never write. A shop whose only app is this one had no way to create
    /// a task at all, so it had no schedule.
    func addMaintenanceTask(machineId: String, name: String,
                            intervalHours: Double, intervalDays: Double) async {
        writeProblem = nil
        guard permitted("inventory", "edit") else { return }
        guard let build = source.build, canMoveJobs else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        if let problem = MaintenanceTaskEdit.problem(name: name, intervalHours: intervalHours,
                                                     intervalDays: intervalDays) {
            writeProblem = words.callIt(problem); return
        }
        let hours = await machineHours(machineId)
        let record = MaintenanceTaskEdit.record(
            machineId: machineId, name: name, intervalHours: intervalHours,
            intervalDays: intervalDays, hours: hours,
            nowIso: StoreWriter.iso(Date()), id: Self.uid("MTASK"))
        do {
            try await StoreWriter.updateOffMain(build) { root in
                var rows: [JSONValue] = []
                if case .array(let had)? = root[MaintenanceTaskEdit.collection] { rows = had }
                var stamped = record
                StoreWriter.stamp(&stamped)
                rows.append(.object(stamped))
                root[MaintenanceTaskEdit.collection] = .array(rows)
            }
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// Change what a task is called and how often it comes round.
    ///
    /// Deliberately does NOT restamp when it was last done: changing "every 100
    /// hours" to "every 80" says something about the schedule, not that the work
    /// was just carried out. Restamping would quietly clear a task that is
    /// overdue at this moment.
    func editMaintenanceTask(_ taskId: String, name: String,
                             intervalHours: Double, intervalDays: Double,
                             opened: MaintenanceTaskEdit.Opened?) async {
        writeProblem = nil
        guard permitted("inventory", "edit") else { return }
        guard let build = source.build, canMoveJobs else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        if let problem = MaintenanceTaskEdit.problem(name: name, intervalHours: intervalHours,
                                                     intervalDays: intervalDays) {
            writeProblem = words.callIt(problem); return
        }
        do {
            try await StoreWriter.updateOffMain(build) { root in
                guard case .array(var rows)? = root[MaintenanceTaskEdit.collection] else { return }
                for i in rows.indices {
                    guard case .object(let task) = rows[i],
                          case .string(let id)? = task["id"], id == taskId else { continue }
                    var next = MaintenanceTaskEdit.edited(task, name: name,
                                                          intervalHours: intervalHours,
                                                          intervalDays: intervalDays,
                                                          opened: opened)
                    // Without the stamp the other machine's older copy wins the
                    // next merge and the interval goes back.
                    StoreWriter.stamp(&next)
                    rows[i] = .object(next)
                }
                root[MaintenanceTaskEdit.collection] = .array(rows)
            }
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// Stop tracking a task. The services already logged against the machine
    /// stay: a schedule is a plan, and deleting a plan does not unmake the work.
    func deleteMaintenanceTask(_ taskId: String) async {
        writeProblem = nil
        guard permitted("inventory", "delete") else { return }
        guard let build = source.build, canMoveJobs else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        do {
            try await StoreWriter.updateOffMain(build) { root in
                guard case .array(let rows)? = root[MaintenanceTaskEdit.collection] else { return }
                root[MaintenanceTaskEdit.collection] =
                    .array(MaintenanceTaskEdit.removing(taskId, from: rows))
            }
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// Write down a service: what was done, when, and what it cost.
    ///
    /// The one thing this app could not record about its machines. A shop can
    /// see what its printers are due for and tick them off, and until now none
    /// of that reached the figures — because the figures come from this log and
    /// nothing here wrote to it.
    func addServiceEntry(machineId: String, date: Date, note: String, cost: Double,
                         alsoAnExpense: Bool) async {
        writeProblem = nil
        guard permitted("inventory", "edit") else { return }
        guard let build = source.build, canMoveJobs else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        let said = note.trimmingCharacters(in: .whitespaces)
        guard !said.isEmpty else {
            writeProblem = words.callIt("maint.need_note"); return
        }
        let day = Self.localDay(date)
        let paid = max(0, cost)
        let name = machines.first { $0.id == machineId }?.name ?? machineId
        do {
            try await StoreWriter.updateOffMain(build) { root in
                var log: [JSONValue] = []
                if case .array(let had)? = root[ServiceLogEdit.collection] { log = had }
                var entry = ServiceLogEdit.entry(machineId: machineId, day: day,
                                                 note: said, cost: paid,
                                                 id: Self.uid("MAINT"))
                StoreWriter.stamp(&entry)
                root[ServiceLogEdit.collection] = .array(ServiceLogEdit.appending(entry, to: log))

                // ── AND, IF ASKED, THE EXPENSE ────────────────────────────
                //
                // OPT IN, never automatic, and this is the reason: a machine's
                // profit already has its servicing subtracted from it, so a
                // shop that also books the repair as an expense has charged
                // itself twice. Which of the two a shop wants is a question
                // about how it keeps its books, so it is asked rather than
                // decided here — the other app asks it the same way.
                guard alsoAnExpense, paid > 0 else { return }
                var expenses: [JSONValue] = []
                if case .array(let had)? = root["expenses"] { expenses = had }
                var expense: [String: JSONValue] = [
                    "id": .string(Self.uid("EXP")),
                    "date": .string(day),
                    "category": .string("maintenance"),
                    "amount": .number(paid),
                    "note": .string("\(name): \(said)"),
                ]
                StoreWriter.stamp(&expense)
                expenses.insert(.object(expense), at: 0)
                root["expenses"] = .array(expenses)
            }
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// Take one service out of the log.
    ///
    /// The entry only. An expense written beside it is left alone: it is a
    /// record of money that left the shop, the shop's accountant may already
    /// have seen it, and deleting a line from a maintenance history is not a
    /// statement that the money was never spent.
    func deleteServiceEntry(_ entryId: String) async {
        writeProblem = nil
        guard permitted("inventory", "delete") else { return }
        guard let build = source.build, canMoveJobs else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        do {
            try await StoreWriter.updateOffMain(build) { root in
                guard case .array(let log)? = root[ServiceLogEdit.collection] else { return }
                root[ServiceLogEdit.collection] = .array(ServiceLogEdit.removing(entryId, from: log))
            }
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// Whether the shop's invoices have been reported to ZATCA.
    ///
    /// Recomputed rather than cached: it moves when a job completes and when
    /// the Electron app submits one, and a stale "not submitted" against an
    /// invoice that has been reported is worse than no answer at all.
    func zatcaReporting() async -> KhaytEngine.ZatcaReporting? {
        guard let engine else { return nil }
        return try? await engine.zatcaReporting(settings: settingsDict, orders: orderRows)
    }

    /// One print file's raw record, for the rules that read more of it than
    /// `LibraryFile` models.
    func row(for id: LibraryFile.ID) -> JSONValue? {
        fileRows.first {
            if case .object(let rec) = $0, case .string(let known)? = rec["id"] { return known == id }
            return false
        }
    }

    /// The files this print is made of.
    func parts(for id: LibraryFile.ID) async -> KhaytEngine.PrintParts? {
        guard let engine, let rec = row(for: id) else { return nil }
        return try? await engine.printParts(rec)
    }

    /// The settings this file is known to work at, and which to reach for.
    func setups(for id: LibraryFile.ID) async -> KhaytEngine.PrintSetups? {
        guard let engine, let rec = row(for: id) else { return nil }
        return try? await engine.printSetups(rec)
    }

    /// The alternatives this file exists as.
    func versions(for id: LibraryFile.ID) async -> KhaytEngine.PrintVersions? {
        guard let engine, let rec = row(for: id) else { return nil }
        return try? await engine.printVersions(rec)
    }

    /// Filaments in the bundled catalogue matching what has been typed.
    ///
    /// The catalogue is handed to the engine on first use rather than found by
    /// it: the file belongs to this target, and `AppResources` is what knows
    /// where this target's resources are.
    func filamentSearch(_ query: String, limit: Int = 8) async -> [KhaytEngine.FilamentHit] {
        guard let engine, query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        guard await handFilamentCatalog(to: engine) else { return [] }
        return (try? await engine.filamentSearch(query, limit: limit)) ?? []
    }

    private func handFilamentCatalog(to engine: KhaytEngine) async -> Bool {
        if filamentCatalogEngine == ObjectIdentifier(engine) { return true }
        guard let json = AppResources.filamentCatalogJSON else { return false }
        guard (try? await engine.useFilamentCatalog(json)) != nil else { return false }
        filamentCatalogEngine = ObjectIdentifier(engine)
        return true
    }

    /// The spool fields a catalogue entry can speak for — and only those.
    func filamentFields(brand: String, name: String, colour: String,
                        weight: Double?) async -> [String: JSONValue] {
        guard let engine, await handFilamentCatalog(to: engine) else { return [:] }
        return (try? await engine.filamentAsSpool(brand: brand, name: name,
                                                  colour: colour, weight: weight)) ?? [:]
    }

    /// How old the bundled catalogue is, in days.
    func filamentCatalogAge() async -> Double? {
        guard let engine, await handFilamentCatalog(to: engine) else { return nil }
        return (try? await engine.filamentCatalogAge()) ?? nil
    }

    /// The consumables worth ordering, most urgent first.
    ///
    /// Recomputed rather than cached: the rate is measured over a trailing
    /// window, so what is urgent changes as jobs finish even when nobody has
    /// touched the shelf.
    func consumableNeeds() async -> [KhaytEngine.ConsumableNeed] {
        guard let engine, !consumableRows.isEmpty else { return [] }
        return (try? await engine.consumableNeeds(
            consumables: consumableRows, orders: orderRows, now: Date())) ?? []
    }

    /// What that list was computed FROM.
    ///
    /// The shelf changes when stock moves; the rate changes when a job
    /// finishes. Counting the finished jobs is enough for the second — the
    /// window is trailing, so the answer moves when the set of jobs in it does.
    var consumableSignature: String {
        let shelf = consumableRows.compactMap { row -> String? in
            guard case .object(let c) = row, case .string(let id)? = c["id"] else { return nil }
            var have = "-"
            if case .number(let n)? = c["stock"] { have = String(n) }
            return id + ":" + have
        }
        let done = orderRows.reduce(into: 0) { total, row in
            if case .object(let job) = row, case .string(let state)? = job["status"],
               state == "completed" { total += 1 }
        }
        return "\(done)|" + shelf.sorted().joined(separator: ",")
    }

    /// What one machine's maintenance card was computed FROM.
    ///
    /// Same job as `bandSignature`: a `.task(id:)` needs something cheap that
    /// changes exactly when the answer would. That is the task records
    /// themselves — a completion rewrites `lastDoneHours` — and the hours this
    /// machine has run, because the meter climbing is what moves a task from
    /// ok to due without anybody touching it.
    func maintenanceSignature(for machine: Machine) -> String {
        var meter = 0.0
        for row in orderRows {
            guard case .object(let job) = row,
                  case .string(let on)? = job["machineId"], on == machine.id,
                  case .string(let state)? = job["status"], state == "completed",
                  case .number(let hours)? = job["printTime"] else { continue }
            meter += hours
        }
        let marks = maintTaskRows.compactMap { row -> String? in
            guard case .object(let task) = row,
                  case .string(let on)? = task["machineId"], on == machine.id,
                  case .string(let id)? = task["id"] else { return nil }
            var done = "-"
            if case .number(let h)? = task["lastDoneHours"] { done = String(h) }
            if case .string(let at)? = task["lastDoneAt"] { done += "@" + at }
            // ── AND WHAT THE TASK SAYS, NOT ONLY WHEN IT WAS LAST DONE ────
            //
            // The name and the intervals are here because they can now be
            // EDITED. While the schedule could only be written in the other
            // app, an id and a last-done stamp caught everything this app could
            // change; the moment it could rename a task or tighten an interval,
            // a signature blind to both meant the card carried on drawing the
            // old one until something unrelated moved.
            var says = ""
            if case .string(let name)? = task["name"] { says += name }
            if case .number(let h)? = task["intervalHours"] { says += "/h" + String(h) }
            if case .number(let d)? = task["intervalDays"] { says += "/d" + String(d) }
            return id + ":" + done + ":" + says
        }
        return "\(machine.id)|\(meter)|" + marks.sorted().joined(separator: ",")
    }

    /// What the band was computed FROM, as one string.
    ///
    /// A `.task(id:)` needs something cheap that changes exactly when the answer
    /// would. The readings change on every sweep and most sweeps change nothing,
    /// so this is the progress and the time left, which are the only two things
    /// the band reads out of a printer.
    var bandSignature: String {
        printers.readings.keys.sorted().map { id in
            guard let s = printers.readings[id]?.status, PrinterWatch.isPrinting(s.state) else { return "\(id):-" }
            return "\(id):\(s.progress):\(s.timeRemaining.map { String(Int(saturating: $0 / 60)) } ?? "-")"
        }.joined(separator: "|")
    }

    func printFacts(for file: LibraryFile) -> KhaytEngine.PrintFacts? {
        if let known = factsByFile[file.id] { return known }
        loadPrintFacts(for: file)
        return nil
    }

    /// True once the answer is in, whatever the answer was. The inspector uses
    /// it to tell "still reading" from "this file says nothing".
    func printFactsAreIn(for file: LibraryFile) -> Bool { factsByFile[file.id] != nil }

    private func loadPrintFacts(for file: LibraryFile) {
        guard !factsInFlight.contains(file.id), let engine else { return }
        guard let url = modelFile(for: file),
              url.pathExtension.lowercased() == "3mf" else {
            factsByFile[file.id] = .some(nil)
            return
        }
        // Not by SELECTING a linked model its drive has not downloaded:
        // reading the zip is downloading the model, and arrowing down a
        // linked Drive's list fetched every model passed over (alpha.66
        // review). Not remembered either, so the facts are read once the
        // shop opens or brings it down.
        if file.isLinked, LinkedCloud.isOnlineOnly(url) { return }
        factsInFlight.insert(file.id)
        let id = file.id
        Task { [weak self] in
            // The zip is read off the main thread; the RULE runs on the engine's
            // own actor, which is where the one JavaScriptCore context lives.
            // What goes to a background thread is the file, not the interpreter.
            let configs = await Task.detached(priority: .userInitiated) {
                () -> (project: String, model: String, prusa: String)? in
                guard let entries = try? Zip.entries(of: url) else { return nil }
                func text(_ name: String) -> String {
                    guard let e = entries.first(where: { $0.name.lowercased() == name.lowercased() }),
                          let d = try? Zip.data(of: e, in: url) else { return "" }
                    return String(decoding: d, as: UTF8.self)
                }
                let project = text("Metadata/project_settings.config")
                let model = text("Metadata/model_settings.config")
                // Either spelling, depending on how old the PrusaSlicer was.
                var prusa = text("Metadata/Slic3r_PE.config")
                if prusa.isEmpty { prusa = text("Metadata/Prusa_Slicer.config") }
                if project.isEmpty && model.isEmpty && prusa.isEmpty { return nil }
                return (project, model, prusa)
            }.value
            guard let self else { return }
            self.factsInFlight.remove(id)
            guard let configs else { self.factsByFile[id] = .some(nil); return }
            self.factsByFile[id] = .some(try? await engine.printFacts(
                projectSettings: configs.project,
                modelSettings: configs.model,
                prusa: configs.prusa))
        }
    }

    /// A photograph the shop took beats a generated thumbnail: it is the print
    /// as it came off the bed, which is what someone is trying to recognise.
    func thumbnail(for file: LibraryFile) -> ThumbnailSource? {
        if let photo = file.userPhoto, photo.hasPrefix("data:") { return .inlineData(photo) }
        guard let dir = directory(for: file) else { return nil }
        let name = file.thumbFile ?? "thumb.jpg"
        let url = dir.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? .file(url) : nil
    }

    /// Does ANY job name a customer, or promise a date?
    ///
    /// The jobs table drops those columns when nothing in the book fills them:
    /// a shop whose work is auto-logged from its printers has neither, and a
    /// column of dashes is not a column. Asked of the whole book rather than of
    /// what is on screen, so filtering to one stage cannot make a column vanish
    /// and reappear as the shop types in the search box.
    var anyJobHasAClient: Bool { orders.contains { !$0.client.isEmpty } }
    var anyJobHasADueDate: Bool { orders.contains { !($0.dueDate ?? "").isEmpty } }

    /// The picture of what a job printed.
    ///
    /// A job is a row of text in a table of rows of text, and the shop is
    /// looking for the one it made last Tuesday. It already knows what that
    /// looked like — the model is in the library with a thumbnail — and the
    /// table was the only place not showing it.
    ///
    /// Only where the job SAYS which model it was: a job auto-logged from a
    /// printer's history knows a filename and nothing about the library, and
    /// guessing by name would eventually put the wrong picture on a job.
    /// Nothing rather than the wrong thing.
    func modelThumbnail(for job: Order) -> ThumbnailSource? {
        for part in job.parts {
            guard let id = part.printFileId,
                  let file = files.first(where: { $0.id == id }) else { continue }
            if let source = thumbnail(for: file) { return source }
        }
        return nil
    }

    /// The colours a job was printed in, as the shop wrote them down.
    ///
    /// Words, not swatches. "bone", "sand" and "natural" are a shop's own
    /// names for filament it owns, and nothing in Khayt maps a word to a
    /// colour — so a swatch here would be this app's guess at what "sand"
    /// looks like, painted next to a photograph of the real thing.
    func partColours(of job: Order) -> [String] {
        var seen = Set<String>()
        return job.parts.compactMap { part in
            let word = part.colour.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { return nil }
            return word
        }
    }

    /// What the shop is owed across everything still open. The one number an
    /// owner looks for, so it is on screen without being asked for.
    var owed: Double { orders.filter { !$0.isSettled }.reduce(0) { $0 + $1.owed } }
    var overdueCount: Int { orders.count { $0.isOverdue() } }

    var selected: Order? { orders.first { $0.id == selection } }
}
