import Foundation
import KhaytCore

/// ⌘J, "Jump to in Library": what it lists, who may use it, and where a row
/// goes.
///
/// The palette is `LibraryJumpPalette`, built from ⌘K's parts
/// (`QuickPaletteFrame`, `QuickPaletteRow`); the matching is ⌘K's own
/// `GoToIndex`, ranked flat (`GoToIndex.ranked`) in `LibraryJump`'s prior. This
/// file turns the library into candidates, gates the palette like the
/// Library screen it opens, and runs each row with the moves the library
/// already makes — the reveal ⌘K uses, a folder opened as the grid opens one,
/// a tag and a saved search loaded into the bar as the sidebar loads them.
extension Shop {

    // MARK: - Who may

    /// What ⌘J may list: nothing while nobody is signed in, or for someone
    /// the Library screen is closed to — the gate its sidebar row asks.
    var libraryJumpKinds: Set<GoToIndex.Kind> {
        guard !needsSignIn, canShow(.library(nil)) else { return [] }
        return LibraryJump.kinds
    }

    /// Whether Go ▸ Jump to in Library… is enabled.
    var canJumpInLibrary: Bool { !libraryJumpKinds.isEmpty }

    /// May this action run on this row now? The menus' own gate: Quote and
    /// New Job are enabled for whoever `canMoveJobs` says (`ModelActions`).
    func libraryJumpAllows(_ action: LibraryJump.Action, on kind: GoToIndex.Kind) -> Bool {
        libraryJumpKinds.contains(kind) && LibraryJump.allows(action, on: kind, canMoveJobs: canMoveJobs)
    }

    // MARK: - The index, once per change

    /// The library's index for ⌘J, built when the book or the library has
    /// changed since the last one, and otherwise handed back as it was. The
    /// candidates are plain values copied here; the folding, which is the
    /// cost, runs off the main actor.
    func libraryJumpIndex() async -> GoToIndex {
        let revision = libraryJumpRevision
        if let cache = libraryJumpCache, cache.revision == revision { return cache.index }
        let candidates = libraryJumpCandidates()
        let index = await Task.detached(priority: .userInitiated) { LibraryJump.index(candidates) }.value
        libraryJumpBuilds += 1
        if revision == libraryJumpRevision { libraryJumpCache = (revision, index) }
        return index
    }

    /// The book and the library together: a snapshot's pretend library moves
    /// the second without the first.
    private var libraryJumpRevision: Int { bookRevision &* 1_000_003 &+ filesRevision }

    /// Everything ⌘J can jump to, as candidates. Not the models put aside —
    /// the library hides them, and ⌘K leaves them out for the same reason.
    func libraryJumpCandidates() -> [LibraryJump.Candidate] {
        var out: [LibraryJump.Candidate] = []
        var folders: [String: (last: String, prints: Int)] = [:]
        var tags: [String: (name: String, last: String, prints: Int)] = [:]
        let live = files.filter { !$0.isArchived }
        out.reserveCapacity(live.count + 64)
        for file in live {
            let last = Self.jumpDay(file)
            out.append(.init(kind: .model, id: file.id, title: file.title,
                             subtitle: file.groupName ?? file.sourceFile?.originalName ?? "",
                             fields: [file.title, file.originalName ?? "", file.sourceFile?.originalName ?? "",
                                      file.sourceFile?.filename ?? ""],
                             lastActive: last, prints: file.printCount))
            // Each level of its folder: "Kings/Busts" is in "Kings" too.
            if let group = file.groupName, !group.isEmpty {
                var path: [String] = []
                for part in group.components(separatedBy: ImportGrouping.separator) where !part.isEmpty {
                    path.append(part)
                    let key = path.joined(separator: ImportGrouping.separator)
                    let had = folders[key] ?? ("", 0)
                    folders[key] = (max(had.last, last), had.prints + file.printCount)
                }
            }
            for tag in file.tags ?? [] where !tag.isEmpty {
                let key = tag.lowercased()
                let had = tags[key] ?? (tag, "", 0)
                tags[key] = (had.name, max(had.last, last), had.prints + file.printCount)
            }
        }
        for (path, use) in folders {
            let leaf = Self.groupLeaf(path)
            let parent = path.components(separatedBy: ImportGrouping.separator).dropLast()
                .joined(separator: ImportGrouping.separator)
            if let archive = archiveName(ofGroup: path) {
                out.append(.init(kind: .archive, id: path, title: leaf,
                                 subtitle: words.callIt("mac.jump_kind_archive") + " · " + archive,
                                 fields: [leaf, archive, path], lastActive: use.last, prints: use.prints))
            } else {
                out.append(.init(kind: .folder, id: path, title: leaf,
                                 subtitle: parent.isEmpty ? words.callIt("mac.jump_kind_folder")
                                    : words.callIt("mac.jump_kind_folder") + " · " + parent,
                                 fields: [leaf, path], lastActive: use.last, prints: use.prints))
            }
        }
        for (_, tag) in tags {
            out.append(.init(kind: .tag, id: tag.name, title: "#" + tag.name,
                             subtitle: words.callIt("mac.jump_kind_tag"),
                             fields: [tag.name], lastActive: tag.last, prints: tag.prints))
        }
        // The smart folders every library has, then the shop's own — the
        // sidebar's rows, by the sidebar's ids.
        for row in librarySmartRows {
            let created = row.saved.map { LibraryJump.day($0.createdAt) } ?? ""
            out.append(.init(kind: .search, id: row.id, title: row.title,
                             subtitle: words.callIt("mac.jump_kind_search"),
                             fields: [row.title], lastActive: created))
        }
        return out
    }

    /// The day a model was last used: printed, or added if it never was —
    /// in the book's calendar.
    nonisolated static func jumpDay(_ file: LibraryFile) -> String {
        let printed = LibraryJump.day(file.lastPrinted)
        if !printed.isEmpty { return printed }
        return file.createdAt?.date.map { Calendar.book.dayString($0) } ?? ""
    }

    // MARK: - Going there

    /// Run a row. Asked of the gate again: a palette left open across a
    /// change of who is signed in must not open what the new person may not.
    func jump(to entry: GoToIndex.Entry, _ action: LibraryJump.Action = .open) {
        guard libraryJumpKinds.contains(entry.kind) else { return }
        // A quote or a job the gate refuses opens the model instead — never
        // nothing, never the sheet.
        let action = libraryJumpAllows(action, on: entry.kind) ? action : .open
        jumping = false
        switch entry.kind {
        case .model:
            // ⌘K's reveal: the search and every filter off, its folder open,
            // the model selected — and the grid asked to bring it into view.
            guard reveal(fileId: entry.id) else { return }
            libraryScrollRequest &+= 1
            if action != .open, let file = libraryFile(id: entry.id) {
                Task { await startJob(fromModels: [file], asQuote: action == .quote) }
            }
        case .folder, .archive:
            search = ""
            clearLibraryFilter()
            fileSelection = []
            shelf = .library(entry.id)
        case .tag:
            var q = LibraryQuery()
            q.tag = entry.id
            openLibraryQuery(q)
        case .search:
            if let row = librarySmartRows.first(where: { $0.id == entry.id }) { openSmartRow(row) }
        default:
            break
        }
    }
}
