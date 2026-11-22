import Foundation
import KhaytCore

/// ── STACKS, ON THE MAC ──────────────────────────────────────────────────
///
/// The rules are `LibraryStacks` (KhaytCore): two fields on each member
/// record, `stackId` and `stackTop`, and no container. This is the plumbing:
///
///   Drawing  — `stacked` folds the drawn entries AFTER the one matcher has
///              chosen the models, so every count (sidebar, facets, the grid's
///              own) is still a count of models and nothing changes because
///              models were stacked. A stack shows when any member is shown;
///              its badge counts the members shown, of the members it has.
///   Writing  — every change goes through `editFiles`: gated by the staff
///              lock, on the write chain, and undoable field by field. Undo
///              of an Unstack puts the two fields back on every member.
///   Choosing — a tile the shop can see is the only thing a selection holds
///              (27 Sep 2026): a closed stack is its cover, so Delete on it
///              deletes the cover alone, never the hidden variants.
extension Shop {

    /// Who is in which stack, across the book.
    struct StackIndex {
        /// Each stacked model's stack (only stacks of two or more).
        var stackOf: [LibraryFile.ID: String] = [:]
        /// Each stack's members, in book order.
        var members: [String: [LibraryFile.ID]] = [:]
        /// The members marked to wear the tile.
        var tops: Set<LibraryFile.ID> = []
    }

    /// The library's models as the stack rules read them.
    func stackMembers() -> [LibraryStacks.Member] {
        files.map { f in
            LibraryStacks.Member(id: f.id, title: f.title, group: f.groupName, stackId: f.stack,
                                 stackTop: f.isStackTop, contentHash: f.contentHash,
                                 geometryKey: f.geometryKey, archived: f.isArchived)
        }
    }

    /// `StackIndex`, once per change to the book.
    func libraryStacks() -> StackIndex {
        let memo = libraryMemo
        _ = files.count
        if memo.stacksRevision == filesRevision { return memo.stacks }
        let members = stackMembers()
        let index = LibraryStacks.index(members)
        var out = StackIndex(members: index)
        for (s, ids) in index { for id in ids { out.stackOf[id] = s } }
        out.tops = Set(members.lazy.filter { $0.stackTop && out.stackOf[$0.id] != nil }.map(\.id))
        memo.stacksRevision = filesRevision
        memo.stacks = out
        return out
    }

    /// The drawn entries with each stack folded into its cover's tile — and
    /// an open stack's members inline after it. Folders are left as they are.
    func stacked(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        let index = libraryStacks()
        let memo = libraryMemo
        guard !index.members.isEmpty else { memo.stackTiles = [:]; return entries }
        var byId: [LibraryFile.ID: LibraryFile] = [:]
        var order: [LibraryFile.ID] = []
        for case .file(let f) in entries {
            byId[f.id] = f
            order.append(f.id)
        }
        let tiles = LibraryStacks.collapse(order, stackOf: index.stackOf, members: index.members,
                                           tops: index.tops, expanded: libraryOpenStacks)
        // Where each stack's run of tiles goes: at its first shown member.
        var firstShown: [String: LibraryFile.ID] = [:]
        for id in order { if let s = index.stackOf[id], firstShown[s] == nil { firstShown[s] = id } }
        var runs: [String: [LibraryStacks.Tile]] = [:]
        for tile in tiles { if let s = tile.stackId { runs[s, default: []].append(tile) } }
        var out: [LibraryEntry] = []
        var drawn: [LibraryFile.ID: LibraryStacks.Tile] = [:]
        for entry in entries {
            guard case .file(let f) = entry, let s = index.stackOf[f.id], let run = runs[s] else {
                out.append(entry); continue
            }
            guard firstShown[s] == f.id else { continue }
            for tile in run {
                guard let file = byId[tile.id] else { continue }
                out.append(.file(file))
                drawn[tile.id] = tile
            }
        }
        memo.stackTiles = drawn
        return out
    }

    /// The stack a drawn tile stands for or sits inside; nil for a plain
    /// model. From the last draw — never worked out per tile.
    func libraryStackTile(_ id: LibraryFile.ID) -> LibraryStacks.Tile? {
        _ = memoEntries()
        return libraryMemo.stackTiles[id]
    }

    /// The stack a model is in, whether or not it is drawn.
    func stackOf(_ file: LibraryFile) -> String? { libraryStacks().stackOf[file.id] }

    /// A stack's members, as models, cover first.
    func stackMembers(_ stackId: String) -> [LibraryFile] {
        let index = libraryStacks()
        guard let ids = index.members[stackId] else { return [] }
        let top = LibraryStacks.cover(of: ids, tops: index.tops)
        let ordered = ([top].compactMap { $0 }) + ids.filter { $0 != top }
        return ordered.compactMap(libraryFile(id:))
    }

    // MARK: - Open and closed

    func isStackOpen(_ stackId: String) -> Bool { libraryOpenStacks.contains(stackId) }

    func toggleStackOpen(_ stackId: String) {
        if libraryOpenStacks.contains(stackId) { libraryOpenStacks.remove(stackId) }
        else { libraryOpenStacks.insert(stackId) }
    }

    // MARK: - Suggestions

    /// Every suggestion in the book, once per change to it.
    func stackSuggestions() -> [LibraryStacks.Suggestion] {
        let memo = libraryMemo
        _ = files.count
        if memo.stackSuggestionsRevision == filesRevision { return memo.stackSuggestions }
        let out = LibraryStacks.suggestions(stackMembers())
        memo.stackSuggestionsRevision = filesRevision
        memo.stackSuggestions = out
        return out
    }

    /// The suggestion that holds this model, if any.
    func stackSuggestion(for file: LibraryFile) -> LibraryStacks.Suggestion? {
        stackSuggestions().first { $0.ids.contains(file.id) }
    }

    /// What a suggestion's reason is called.
    static func stackReasonKey(_ reason: LibraryStacks.Reason) -> String {
        switch reason {
        case .sameFile: "mac.stk_why_file"
        case .sameName: "mac.stk_why_name"
        case .sameShape: "mac.stk_why_shape"
        }
    }

    // MARK: - Writing

    /// The two fields, as one patch says, on one record.
    nonisolated static func applyStack(_ record: inout [String: JSONValue], _ patch: LibraryStacks.Patch) {
        guard let id = patch.stackId else {
            record.removeValue(forKey: LibraryStacks.idKey)
            record.removeValue(forKey: LibraryStacks.topKey)
            return
        }
        record[LibraryStacks.idKey] = .string(id)
        if patch.top { record[LibraryStacks.topKey] = .bool(true) }
        else { record.removeValue(forKey: LibraryStacks.topKey) }
    }

    /// One write for every record a stack change touches, undoable. The
    /// patches are worked out from the models on screen; each record gets
    /// its own. False when refused or there is nothing to do.
    @discardableResult
    private func writeStacks(_ patches: [String: LibraryStacks.Patch]?, named key: String) -> Bool {
        guard let patches, !patches.isEmpty else { return false }
        return editFiles(Set(patches.keys), named: words.callIt(key)) { record in
            guard case .string(let id)? = record["id"], let patch = patches[id] else { return }
            Self.applyStack(&record, patch)
        }
    }

    /// Stack these models, `cover` on top — when nil, the cover of the stack
    /// they join, or else the first of them.
    @discardableResult
    func stackModels(_ ids: [LibraryFile.ID], cover: LibraryFile.ID? = nil) -> Bool {
        let newId = "ST-" + UUID().uuidString.prefix(8).lowercased()
        let patches = LibraryStacks.stacking(ids, cover: cover, all: stackMembers(), newId: newId)
        guard writeStacks(patches, named: "mac.stk_stack") else { return false }
        // The variants now behind the cover leave the selection, which holds
        // only what is drawn; the cover stays chosen if any of them was.
        let chosen = Set(ids)
        if !fileSelection.isDisjoint(with: chosen) {
            let top = patches?.first(where: { $0.value.top })?.key ?? cover ?? ids.first
            fileSelection = fileSelection.subtracting(chosen).union(top.map { [$0] } ?? [])
        }
        return true
    }

    /// Model ▸ Stack: the visible selection, the first selected on top.
    func stackSelection() {
        let chosen = selectedFiles
        guard chosen.count >= 2 else { return }
        stackModels(chosen.map(\.id), cover: chosen.first?.id)
    }

    /// Can the selection be stacked: two or more models, not all in one stack.
    var canStackSelection: Bool {
        let chosen = selectedFiles
        guard canWrite, chosen.count >= 2 else { return false }
        let index = libraryStacks()
        // All in one stack already is nothing to do.
        return Set(chosen.map { index.stackOf[$0.id] ?? "\u{0}" + $0.id }).count >= 2
    }

    /// The stacks the selection's tiles stand for or sit in.
    var selectedStacks: [String] {
        let index = libraryStacks()
        var seen: Set<String> = []
        return selectedFiles.compactMap { index.stackOf[$0.id] }.filter { seen.insert($0).inserted }
    }

    /// Take a stack apart. Undoable: ⌘Z puts it back together.
    @discardableResult
    func unstack(_ stackId: String) -> Bool {
        let wrote = writeStacks(LibraryStacks.unstacking(stackId, all: stackMembers()), named: "mac.stk_unstack")
        if wrote { libraryOpenStacks.remove(stackId) }
        return wrote
    }

    /// Model ▸ Unstack: every stack the selection is in.
    func unstackSelection() {
        let stacks = selectedStacks
        guard !stacks.isEmpty else { return }
        var patches: [String: LibraryStacks.Patch] = [:]
        let all = stackMembers()
        for s in stacks { LibraryStacks.unstacking(s, all: all)?.forEach { patches[$0.key] = $0.value } }
        if writeStacks(patches, named: "mac.stk_unstack") { libraryOpenStacks.subtract(stacks) }
    }

    /// Take these models out of their stacks; the rest stay stacked.
    @discardableResult
    func removeFromStack(_ ids: Set<LibraryFile.ID>) -> Bool {
        writeStacks(LibraryStacks.removing(ids, all: stackMembers()), named: "mac.stk_remove")
    }

    /// Put this member on top of its stack.
    @discardableResult
    func makeStackCover(_ id: LibraryFile.ID) -> Bool {
        writeStacks(LibraryStacks.choosingCover(id, all: stackMembers()), named: "mac.stk_make_cover")
    }

    /// Accept a suggestion: those models stacked, this one on top if it is
    /// not joining a stack that already has a cover.
    @discardableResult
    func acceptStackSuggestion(_ suggestion: LibraryStacks.Suggestion, cover: LibraryFile.ID?) -> Bool {
        stackModels(suggestion.ids, cover: suggestion.joins == nil ? cover : nil)
    }
}
