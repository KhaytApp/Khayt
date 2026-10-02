import SwiftUI
import AppKit
import KhaytCore

/// Moving several groups under one parent at once, and renaming a group.
///
/// ── WHAT IT IS FOR ───────────────────────────────────────────────────────
///
/// The shop's oldest imports filed a project's sub-folders as top-level
/// groups: "pose 1", "pose 2" and "tete multipart" belong under "Baby
/// Grendizer"; eight colour folders under "Grendizer by Santome"; eight more
/// under "Iron Man Helmet MK 4-6-7". Move Folder (`Shop.moveFolder`) fixes
/// them one at a time — twenty-odd right-clicks. Here the shop ⌘-clicks the
/// group tiles, chooses "Move into Group…" once, and names the parent.
///
/// ── THE SAME WRITE AS MOVE FOLDER ────────────────────────────────────────
///
/// Each chosen group keeps its own name and lands at `parent/name`, every
/// file keeping its depth below it (`folderMoveTargets`), the record changed
/// the way `moveRecord` changes it, the kinds carried (`GroupKinds.carry`),
/// all in ONE `editFiles` — one store write, one Undo. Rename is the same
/// write with the destination beside the group instead of under a parent.
///
/// ── A NAME THAT IS ALREADY TAKEN: MERGE, AND SAY SO ──────────────────────
///
/// When `parent/name` already holds models, the moving group's models JOIN
/// it rather than the move being refused. A library imported flat is exactly
/// where half of a sub-folder sits under its project and the other half was
/// filed at the top, and refusing would leave no way in the app to put the
/// two halves back together. Joining is safe to undo: Undo restores every
/// record moved, whole, and the kind entries it touched (`LibraryUndo`), and
/// the models that were already there are never written. It is never
/// silent: the confirmation names each group that will join another before
/// the button is pressed, and the existing group keeps its own kind.
///
/// Two CHOSEN groups with the same name (`A/Blue` and `B/Blue` under one
/// parent) are refused instead: that is two projects' folders about to be
/// mixed by one click, never a repair the shop meant. Rename one first.
struct GroupMovePlan: Equatable {
    struct Move: Equatable, Identifiable {
        let from: String
        let to: String
        /// The files that move with it — the ids `carry` is told about.
        let ids: Set<String>
        /// `to` already held other models; these join them.
        let joins: Bool
        var id: String { from }
    }

    enum Refusal: Equatable {
        /// The destination is the group itself or inside it.
        case intoItself(String)
        /// Two chosen groups would land on the same path.
        case sameName(String)
        /// A path written would pass `normalise`'s 60-unit cut.
        case tooLong(String)
        /// A rename to nothing.
        case emptyName
    }

    var moves: [Move] = []
    /// Chosen groups inside another chosen group: they go with it, as Move
    /// Folder takes a subtree, and are not moved a second time.
    var riding: [String] = []
    /// Chosen groups already where they were asked to go.
    var alreadyThere: [String] = []
    var refusal: Refusal?
    /// Every moving file's new path, by id.
    var wanted: [String: String] = [:]

    var ids: Set<String> { Set(wanted.keys) }
    var canMove: Bool { refusal == nil && !moves.isEmpty }
}

/// What "Move into Group…" or "Rename Group…" was asked of, while the sheet
/// is up.
struct GroupMoveRequest: Identifiable, Equatable {
    let id = UUID()
    let paths: [String]
    let renaming: Bool
}

extension Shop {
    // MARK: - The plan, without a shop around it

    /// A group path survives `lib/organise.js normalise` only up to 60 UTF-16
    /// units (`ImportGrouping.fitting` explains the cut). Longer, and the
    /// models are filed under the first 60 characters — possibly ANOTHER
    /// group's path — so a move that would write one is refused.
    nonisolated static let groupPathLimit = 60

    /// Moving `paths` under `parent` (nil: to the top level), against the
    /// library's files as `(id, group)`.
    nonisolated static func planGroupMove(_ paths: [String], under parent: String?,
                                          files: [(id: String, group: String?)]) -> GroupMovePlan {
        let parent = (parent?.isEmpty == false) ? parent : nil
        var plan = GroupMovePlan()
        let chosen = Array(Set(paths.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        // A group inside another chosen group rides with it.
        let tops = chosen.filter { p in !chosen.contains { $0 != p && isUnder(p, $0) } }
        plan.riding = chosen.filter { !tops.contains($0) }
        var targets: [(from: String, to: String)] = []
        for path in tops {
            if let parent, isUnder(parent, path) { plan.refusal = .intoItself(path); return plan }
            let target = parent.map { $0 + ImportGrouping.separator + groupLeaf(path) } ?? groupLeaf(path)
            if target == path { plan.alreadyThere.append(path); continue }
            targets.append((path, target))
        }
        return finish(plan, targets, files: files)
    }

    /// Renaming the group at `path` to `typed` — one level, so a typed slash
    /// is flattened the way New Group flattens it (`TypedGroupName`).
    nonisolated static func planGroupRename(_ path: String, to typed: String,
                                            files: [(id: String, group: String?)]) -> GroupMovePlan {
        var plan = GroupMovePlan()
        let leaf = TypedGroupName.flatten(typed)
        guard !leaf.isEmpty else { plan.refusal = .emptyName; return plan }
        var levels = path.components(separatedBy: ImportGrouping.separator)
        levels.removeLast()
        let target = (levels + [leaf]).joined(separator: ImportGrouping.separator)
        guard target != path else { plan.alreadyThere = [path]; return plan }
        return finish(plan, [(path, target)], files: files)
    }

    nonisolated private static func finish(_ start: GroupMovePlan, _ targets: [(from: String, to: String)],
                                           files: [(id: String, group: String?)]) -> GroupMovePlan {
        var plan = start
        var seen: [String: String] = [:]
        for t in targets {
            if seen[t.to] != nil { plan.refusal = .sameName(groupLeaf(t.to)); return plan }
            seen[t.to] = t.from
        }
        for t in targets {
            let wanted = folderMoveTargets(t.from, to: t.to, files: files)
            guard !wanted.isEmpty else { continue }
            plan.wanted.merge(wanted) { a, _ in a }
            plan.moves.append(.init(from: t.from, to: t.to, ids: Set(wanted.keys), joins: false))
        }
        // Whether a destination is already a group is asked of the files
        // that are NOT moving: a group's own models do not make it "taken".
        let moving = plan.ids
        let staying = files.filter { !moving.contains($0.id) }.compactMap(\.group)
        plan.moves = plan.moves.map { m in
            .init(from: m.from, to: m.to, ids: m.ids,
                  joins: staying.contains { isUnder($0, m.to) })
        }
        if let long = plan.wanted.values.sorted().first(where: { $0.utf16.count > groupPathLimit }) {
            plan.refusal = .tooLong(long)
        }
        return plan
    }

    /// The change to the rest of the book a plan's write makes, in the same
    /// store write as the files: the kinds go with their groups, and a NEW
    /// parent gets the kind the shop chose for it.
    static func groupMoveRoot(_ plan: GroupMovePlan,
                              newKinds: [String: GroupKind]) -> (inout [String: JSONValue]) -> Void {
        let moves = plan.moves.map { (from: $0.from, to: $0.to) }
        let ids = plan.ids
        return { root in
            GroupKinds.carry(moves, moving: ids, in: &root)
            if !newKinds.isEmpty { GroupKinds.write(newKinds, into: &root) }
        }
    }

    /// A typed destination, as the group it names: an existing group spelled
    /// the shop's way when it matches one ignoring case and runs of spaces —
    /// "baby  grendizer" is "Baby Grendizer", never a second group beside it
    /// — otherwise one level, slashes flattened like New Group.
    nonisolated static func resolveGroupDestination(_ typed: String, known: [String]) -> String {
        func squeeze(_ s: String) -> String {
            s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let wanted = squeeze(typed)
        if let existing = known.first(where: { squeeze($0).caseInsensitiveCompare(wanted) == .orderedSame }) {
            return existing
        }
        return squeeze(TypedGroupName.flatten(typed, known: known))
    }

    // MARK: - Choosing group tiles

    /// The group tiles drawn right now, in the order they are drawn.
    var visibleGroupPaths: [String] {
        shownEntries.compactMap { entry in
            if case .folder(_, let path, _, _) = entry { return path }
            return nil
        }
    }

    /// Drop from the group selection any tile no longer drawn — the same
    /// rule the model selection follows (#1691).
    func pruneGroupSelectionToVisible() {
        guard !groupSelection.isEmpty || groupAnchor != nil else { return }
        let visible = Set(visibleGroupPaths)
        let kept = groupSelection.intersection(visible)
        if kept != groupSelection { groupSelection = kept }
        if let a = groupAnchor, !visible.contains(a) { groupAnchor = nil }
    }

    /// ⌘-click toggles a group tile, ⇧-click extends a run of them. A plain
    /// click still OPENS the group, so this is never reached without a
    /// modifier.
    func selectGroup(_ path: String, modifiers: SelectionModifier) {
        // Choosing a group lets go of the models: one kind at a time.
        if !fileSelection.isEmpty { fileSelection = [] }
        switch modifiers {
        case .replace:
            groupSelection = [path]
            groupAnchor = path
        case .toggle:
            if groupSelection.contains(path) { groupSelection.remove(path) }
            else { groupSelection.insert(path); groupAnchor = path }
        case .extend:
            let rows = visibleGroupPaths
            guard let end = rows.firstIndex(of: path) else { return }
            let start = groupAnchor.flatMap { rows.firstIndex(of: $0) } ?? end
            groupSelection.formUnion(rows[(min(start, end))...(max(start, end))])
            if groupAnchor == nil { groupAnchor = path }
        }
    }

    /// The groups an action on this tile acts on: the whole group selection
    /// when the tile is part of it, the tile alone when it is not — the way
    /// a Finder right-click reads.
    func groupsActedOn(from path: String) -> [String] {
        guard groupSelection.contains(path) else { return [path] }
        let order = visibleGroupPaths
        return order.filter(groupSelection.contains)
    }

    /// The chosen group tiles, in the order drawn.
    var selectedGroups: [String] { visibleGroupPaths.filter(groupSelection.contains) }

    // MARK: - Doing it

    var fileGroups: [(id: String, group: String?)] { files.map { ($0.id, $0.groupName) } }

    func planGroupMove(_ paths: [String], under parent: String?) -> GroupMovePlan {
        Self.planGroupMove(paths, under: parent, files: fileGroups)
    }

    func planGroupRename(_ path: String, to typed: String) -> GroupMovePlan {
        Self.planGroupRename(path, to: typed, files: fileGroups)
    }

    /// Where the chosen groups may go: any group that is not one of them or
    /// inside one of them.
    func groupDestinations(excluding paths: [String]) -> [String] {
        folderPaths.filter { dest in !paths.contains { Self.isUnder(dest, $0) } }
    }

    /// What a refusal says, by name.
    func say(_ refusal: GroupMovePlan.Refusal) -> String {
        switch refusal {
        case .intoItself(let p):
            return words.callIt("mac.move_group_into_itself", ["name": .string(Self.groupLeaf(p))])
        case .sameName(let n):
            return words.callIt("mac.move_groups_same_name", ["name": .string(n)])
        case .tooLong(let p):
            return words.callIt("mac.group_path_too_long", ["path": .string(p),
                                                            "n": .number(Double(Self.groupPathLimit))])
        case .emptyName:
            return words.callIt("mac.rename_group_empty")
        }
    }

    /// Move the chosen groups under `parent` (nil: the top level), in one
    /// store write and one Undo. `kind` is for the parent only when this
    /// makes it — a group that exists keeps its own (`kindForFiling`).
    /// True when the write happened.
    @discardableResult
    func moveGroups(_ paths: [String], under parent: String?, kind: GroupKind? = nil) -> Bool {
        guard canMoveJobs else { return false }
        // Planned again from the book as it is NOW, not from what the sheet
        // drew: a sync may have landed while it was open.
        let plan = planGroupMove(paths, under: parent)
        if let refusal = plan.refusal { writeProblem = say(refusal); return false }
        guard plan.canMove else { return false }
        let kinds = parent.map { Self.kindForFiling(kind, into: $0, existing: files.map(\.groupName)) } ?? [:]
        let name = words.callIt("mac.moved_groups_into",
                                ["name": .string(parent.map(Self.groupLeaf) ?? words.callIt("mac.move_to_top"))])
        return write(plan, named: name, newKinds: kinds)
    }

    /// Rename one group, through the same write as a move. True when written.
    @discardableResult
    func renameGroup(_ path: String, to typed: String) -> Bool {
        guard canMoveJobs else { return false }
        let plan = planGroupRename(path, to: typed)
        if let refusal = plan.refusal { writeProblem = say(refusal); return false }
        guard plan.canMove else { return false }
        return write(plan, named: words.callIt("mac.rename_group_undo"), newKinds: [:])
    }

    private func write(_ plan: GroupMovePlan, named: String, newKinds: [String: GroupKind]) -> Bool {
        let wanted = plan.wanted
        let wrote = editFiles(plan.ids, named: named,
                              alsoRoot: Self.groupMoveRoot(plan, newKinds: newKinds)) { record in
            Self.moveRecord(&record, wanted: wanted)
        }
        if wrote { groupSelection = []; groupAnchor = nil }
        return wrote
    }
}

// MARK: - Where the shop asks for it

/// A group tile's right-click: move it (or every chosen group, when it is
/// one of them) into another group, and rename it.
struct GroupTileActions: View {
    @Bindable var shop: Shop
    let path: String

    var body: some View {
        let acted = shop.groupsActedOn(from: path)
        Button(acted.count > 1
               ? shop.words.callIt("mac.move_n_groups_into", ["groups": .string(shop.words.counting(acted.count, "mac.n_groups"))])
               : shop.words.callIt("mac.move_into_group")) {
            shop.movingGroups = GroupMoveRequest(paths: acted, renaming: false)
        }
        .disabled(!shop.canMoveJobs)
        // One group at a time, as Finder renames one item at a time.
        if acted.count == 1 {
            Button(shop.words.callIt("mac.rename_group")) {
                shop.movingGroups = GroupMoveRequest(paths: [path], renaming: true)
            }
            .disabled(!shop.canMoveJobs)
        }
    }
}

/// The confirmation: where the groups go, and what moves where.
///
/// The plan is drawn live as the destination is chosen or typed, so what the
/// button will do is on screen BEFORE it is pressed — each group's old path
/// and new one, a warning on each that joins a group already there, and the
/// reason when the move is refused.
struct GroupMoveSheet: View {
    @Bindable var shop: Shop
    let request: GroupMoveRequest

    static let width: CGFloat = 440

    enum Into: Hashable { case new, top, existing(String) }
    @State private var into: Into = .new
    @State private var typed = ""
    @State private var kind: GroupKind = .assumed
    @FocusState private var focused: Bool

    /// `typed` starts empty in the app (a rename fills in the old name on
    /// appear); a snapshot passes one to photograph a plan.
    init(shop: Shop, request: GroupMoveRequest, typed: String = "") {
        self.shop = shop
        self.request = request
        _typed = State(initialValue: typed)
    }

    /// Where the groups go: nil the top level; "" nothing chosen yet.
    private var destination: String? {
        switch into {
        case .top: return nil
        case .existing(let p): return p
        case .new: return Shop.resolveGroupDestination(typed, known: shop.folderPaths)
        }
    }

    private var plan: GroupMovePlan {
        if request.renaming {
            return shop.planGroupRename(request.paths.first ?? "", to: typed)
        }
        if into == .new, destination?.isEmpty != false { return GroupMovePlan() }
        return shop.planGroupMove(request.paths, under: destination)
    }

    /// The parent will be made by this move, so its kind is asked.
    private var makesNewParent: Bool {
        guard !request.renaming, into == .new, let d = destination, !d.isEmpty else { return false }
        return !shop.files.contains { Shop.isUnder($0.groupName, d) }
    }

    var body: some View {
        let plan = plan
        SheetFrame(width: Self.width) {
            Text(request.renaming
                 ? shop.words.callIt("mac.rename_group_title")
                 : shop.words.callIt("mac.move_groups_title",
                                     ["groups": .string(shop.words.counting(request.paths.count, "mac.n_groups"))]))
                .font(.headline)
            if request.renaming { renameField } else { destinationChoice }
            if makesNewParent { GroupKindChoice(words: shop.words, kind: $kind) }
            planList(plan)
        } footer: {
            HStack {
                if let problem = shop.writeProblem, plan.refusal == nil {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.movingGroups = nil }
                    .keyboardShortcut(.cancelAction)
                Button(request.renaming ? shop.words.callIt("mac.rename_do") : shop.words.callIt("mac.move_do")) {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!plan.canMove || !shop.canMoveJobs)
            }
        }
        .onAppear {
            if request.renaming, typed.isEmpty { typed = Shop.groupLeaf(request.paths.first ?? "") }
            focused = true
        }
    }

    private var renameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(shop.words.callIt("mac.group_new_name"), text: $typed)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { commit() }
            Text(shop.words.callIt("mac.rename_group_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var destinationChoice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(shop.words.callIt("mac.move_groups_into"), selection: $into) {
                Text(shop.words.callIt("mac.move_groups_new")).tag(Into.new)
                if request.paths.contains(where: { $0.contains(ImportGrouping.separator) }) {
                    Text(shop.words.callIt("mac.move_to_top")).tag(Into.top)
                }
                Divider()
                ForEach(shop.groupDestinations(excluding: request.paths), id: \.self) { path in
                    Text(path).tag(Into.existing(path))
                }
            }
            .pickerStyle(.menu)
            if into == .new {
                TextField(shop.words.callIt("mac.move_groups_type"), text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { commit() }
                // Said BEFORE the button, as New Group says it: a slash
                // would have made a group inside a group, and a name that
                // matches one the shop has is that group.
                if let d = destination, !d.isEmpty, d != typed.trimmingCharacters(in: .whitespacesAndNewlines) {
                    Text(shop.folderPaths.contains(d)
                         ? shop.words.callIt("mac.move_groups_is_existing", ["name": .string(d)])
                         : shop.words.callIt("mac.group_slash_flattened", ["name": .string(d)]))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func planList(_ plan: GroupMovePlan) -> some View {
        if let refusal = plan.refusal {
            Label(shop.say(refusal), systemImage: "exclamationmark.octagon")
                .font(.callout)
                .foregroundStyle(Khayt.late)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !plan.moves.isEmpty || !plan.riding.isEmpty || !plan.alreadyThere.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(shop.words.callIt("mac.move_groups_plan"))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                ForEach(plan.moves) { move in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(move.from).fontWeight(.medium)
                            // `arrow.forward` turns round in a right-to-left
                            // window, so the arrow always points at the new
                            // path.
                            Image(systemName: "arrow.forward").font(.caption).foregroundStyle(.secondary)
                            Text(move.to)
                            Spacer(minLength: 0)
                            Text(shop.words.counting(move.ids.count, "mac.n_models"))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        if move.joins {
                            // The words in the text colour, the mark in
                            // the attention colour: as text that colour is too pale
                            // to read.
                            Label {
                                Text(shop.words.callIt("mac.move_groups_joins", ["name": .string(move.to)]))
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Khayt.attention)
                            }
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                ForEach(plan.riding, id: \.self) { path in
                    note(shop.words.callIt("mac.move_groups_riding", ["name": .string(path)]))
                }
                ForEach(plan.alreadyThere, id: \.self) { path in
                    note(shop.words.callIt("mac.move_groups_already", ["name": .string(path)]))
                }
                if plan.canMove {
                    Text(shop.words.callIt("mac.move_groups_undo_hint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func commit() {
        guard plan.canMove else { return }
        let wrote = request.renaming
            ? shop.renameGroup(request.paths.first ?? "", to: typed)
            : shop.moveGroups(request.paths, under: destination, kind: makesNewParent ? kind : nil)
        if wrote { shop.movingGroups = nil }
    }
}
