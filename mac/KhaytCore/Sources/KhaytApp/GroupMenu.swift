import SwiftUI
import KhaytCore

/// Filing models into a group.
///
/// A group is a set that belongs together — the seven Saudi Kings, findable and
/// offerable as one collection. The names offered are the ones the shop already
/// uses, because the failure this design is avoiding is two chips called "Saudi
/// Kings" and "saudi kings" each holding part of one set. Typing a new name is
/// possible and deliberately second.
struct GroupMenu: View {
    @Bindable var shop: Shop
    @State private var typed = ""
    @Environment(\.stripCompact) private var compact

    private var count: Int { shop.selectedIds.count }
    /// Group TILES chosen with ⌘/⇧-click. Never at the same time as models
    /// (`Shop.fileSelection`), so the menu offers one or the other.
    private var chosenGroups: [String] { shop.selectedGroups }

    var body: some View {
        Menu {
            if !chosenGroups.isEmpty {
                // The groups themselves are being moved, so "file under" and
                // "remove from group" — which act on MODELS — are not offered.
                GroupTileActions(shop: shop, path: chosenGroups[0])
            } else if count == 0 {
                Text(shop.words.callIt("mac.pick_a_model"))
            } else {
                ForEach(shop.groups, id: \.self) { group in
                    Button {
                        Task { await shop.fileSelection(under: group) }
                    } label: {
                        // A tick against the group they are already all in, so
                        // the menu says where they are as well as offering to
                        // move them.
                        if allAlreadyIn(group) { Label(group, systemImage: "checkmark") }
                        else { Text(group) }
                    }
                }
                if !shop.groups.isEmpty { Divider() }
                Button(shop.words.callIt("mac.new_group")) { typed = ""; shop.namingGroup = true }
                if shop.selectedFiles.contains(where: { $0.groupName != nil }) {
                    Button(shop.words.callIt("mac.remove_from_group")) {
                        Task { await shop.fileSelection(under: "") }
                    }
                }
            }
        } label: {
            let title = !chosenGroups.isEmpty
                ? shop.words.callIt("mac.group_n_groups",
                                    ["groups": .string(shop.words.counting(chosenGroups.count, "mac.n_groups_of"))])
                : count > 1
                ? shop.words.callIt("mac.group_n_models", ["n": .number(Double(count))])
                : shop.words.callIt("mac.group")
            // Its symbol alone when the strip is narrow, as Provenance does:
            // at 900 points the three menus' words pushed the library's title
            // under the traffic lights. The title stays the spoken label.
            if compact {
                Label(title, systemImage: "square.stack").labelStyle(.iconOnly)
            } else {
                Label(title, systemImage: "square.stack")
            }
        }
        .disabled(!shop.canWrite || (count == 0 && chosenGroups.isEmpty))
        .help(shop.canWrite
              ? shop.words.callIt("mac.group_why")
              : shop.words.callIt("mac.group_locked"))
        .shopPopover(isPresented: $shop.namingGroup, arrowEdge: .bottom) {
            NameAGroup(words: shop.words, typed: $typed, known: shop.groups) { name, kind in
                shop.namingGroup = false
                let wanted = TypedGroupName.flatten(name, known: shop.groups)
                guard !wanted.isEmpty else { return }
                // The popover's choice is for the group being MADE. Whether
                // this makes one is not decided here: the engine may file a
                // name that matches no group as typed ("Saudi  Kings", a name
                // past 60 characters) under one that exists, and that group
                // keeps its kind. `Shop.kindForFiling` asks of the path the
                // engine wrote.
                Task { await shop.fileSelection(under: wanted, kind: kind) }
            }
        }
    }

    private func allAlreadyIn(_ group: String) -> Bool {
        let chosen = shop.selectedFiles
        return !chosen.isEmpty && chosen.allSatisfy { $0.groupName == group }
    }
}

/// A group name as the shop TYPED it, made into one level.
///
/// ── WHY A SLASH CANNOT SURVIVE THE BOX ───────────────────────────────────
///
/// A group is a PATH (`ImportGrouping.separator`), so a typed slash is a
/// level. A shop named a group "Luffy Card/Poster", meaning one set with a
/// two-part name, and got a folder "Luffy Card" holding a folder "Poster"
/// holding the one model — which read as a group of one, while the models it
/// meant to group still sat loose in "All models". Nobody typing a name into
/// a one-line box means "make two folders"; the importer makes levels from
/// real folders, and Move Folder makes them on purpose.
///
/// ── WHY " – " ─────────────────────────────────────────────────────────────
///
/// An en dash with a space each side: it still reads as the two-part name the
/// shop typed ("Luffy Card – Poster"), it cannot be mistaken for the hyphen
/// inside a word ("T-Rex", "Hi-Res" stay as they are), and it is the joiner
/// `ImportGrouping` already uses when it collapses folder levels into one
/// title, so the library has one spelling for "these were two parts". A
/// backslash is flattened the same way: a shop coming from Windows types one
/// for exactly the same reason.
///
/// A name that is ALREADY one of the shop's groups, slash and all, is kept:
/// that is the shop choosing an existing folder, not inventing a nested one.
enum TypedGroupName {
    static let joiner = " \u{2013} "

    static func flatten(_ raw: String, known: [String] = []) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("/") || trimmed.contains("\\") else { return trimmed }
        if let existing = known.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        return trimmed
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: joiner)
    }
}

/// Internal rather than private so its snapshot can be drawn.
struct NameAGroup: View {
    let words: Words
    @Binding var typed: String
    /// The shop's groups, so the preview below says what will REALLY be
    /// written — an existing path is kept as it is.
    let known: [String]
    let done: (String, GroupKind) -> Void
    /// What the new group is. Fresh each time the popover opens, at the one
    /// default (`GroupKind.assumed`).
    @State private var kind: GroupKind = .assumed

    /// What the box will file under, when that is not what was typed.
    private var flattened: String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = TypedGroupName.flatten(trimmed, known: known)
        return wanted != trimmed && !wanted.isEmpty ? wanted : nil
    }
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(words.callIt("mac.name_this_group"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            TextField(words.callIt("mac.group_example"), text: $typed)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($focused)
                .onSubmit { done(typed, kind) }
            Text(words.callIt("mac.group_name_kept"))
                .font(.caption)
                .foregroundStyle(.secondary)
            // Said BEFORE the shop presses File, so the name they get is never
            // a surprise: a slash would have made a group inside a group.
            if let flattened {
                Text(words.callIt("mac.group_slash_flattened", ["name": .string(flattened)]))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 220, alignment: .leading)
            }
            // ONE PRINT IN PARTS, OR SEPARATE PRINTS. Asked here because it
            // decides how "All models" draws the group: one tile, or each model.
            GroupKindChoice(words: words, kind: $kind)
            HStack {
                Spacer()
                Button(words.callIt("mac.file_it")) { done(typed, kind) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .onAppear { focused = true }
    }
}

/// What several selected models come to together, and what can be done to
/// all of them at once.
///
/// It offered totals, two catalogue buttons and Archive — and everything else
/// a shop does to a shelf of models (tag them, file them, quote them, share
/// them, free their space, delete them) only inside a 21-item right-click
/// menu. Each button here is the same Shop function that menu calls.
///
/// ── THE COUNT IS THE WHOLE TRUTH ──────────────────────────────────────────
///
/// Every action acts on `selectedFiles` — the models drawn as tiles — and
/// says how many in its own title. Anything selected but hidden (inside a
/// folder tile, behind a filter) is counted on its own line and touched by
/// nothing here: a shop said yes to "Delete 34 Models" on 27 Sep 2026 without
/// seeing it was a whole group.
struct ManyModels: View {
    let shop: Shop
    @State private var tagging = false
    @State private var typedTag = ""
    @State private var namingCategory = false
    @State private var typedCategory = ""
    @State private var settingMaterial = false
    @State private var typedMaterial = ""

    private var w: Words { shop.words }

    var body: some View {
        let chosen = shop.selectedFiles
        let totals = shop.selectedFiles.isEmpty ? SelectionTotals() : shop.selectionTotals(chosen)
        let n: [String: JSONValue] = ["n": .number(Double(chosen.count))]
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(w.counting(chosen.count, "mac.n_models"))
                        .font(.title3.weight(.semibold))
                    let hidden = shop.selectedButHidden
                    if hidden > 0 {
                        Label(w.callIt("mac.li_hidden_selected", ["n": .number(Double(hidden))]),
                              systemImage: "eye.slash")
                            .font(.caption).foregroundStyle(Khayt.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                totalsCard(totals)
                group(w.callIt("mac.li_group_print")) {
                    Button { Task { await shop.startJob(fromModels: chosen, asQuote: true) } } label: {
                        Label(w.counting(chosen.count, "mac.li_quote_these"), systemImage: "doc.text")
                    }
                    .disabled(!shop.canMoveJobs)
                    Button { Task { await shop.startJob(fromModels: chosen, asQuote: false) } } label: {
                        Label(w.callIt("mac.job_from_n_models", n) + "\u{2026}", systemImage: "hammer")
                    }
                    .disabled(!shop.canMoveJobs)
                    // To the catalogue, together or one each.
                    Button { Task { await shop.editingProduct = shop.productFromFiles(chosen, name: nil) } } label: {
                        Label(w.callIt("mac.li_catalogue_single"), systemImage: "tag")
                    }
                    .disabled(!shop.canWrite)
                    Button { Task { await shop.addEachToCatalogue(chosen) } } label: {
                        Label(w.callIt("mac.li_catalogue_each"), systemImage: "tag.circle")
                    }
                    .disabled(!shop.canWrite)
                    // On or off Print next, all of them — off only when
                    // every one is on already (as ⌘B and the right-click menu).
                    let allOn = chosen.allSatisfy(\.isPrintNext)
                    Button { shop.setPrintNext(Set(chosen.map(\.id)), on: !allOn) } label: {
                        Label(w.callIt(allOn ? "mac.print_next_remove" : "mac.print_next_add"),
                              systemImage: allOn ? "bookmark.fill" : "bookmark")
                    }
                    .disabled(!shop.canWrite)
                }
                group(w.callIt("mac.li_group_organise")) {
                    // Variants of one model as one tile (`LibraryStacks`).
                    Button { shop.stackSelection() } label: {
                        Label(w.callIt("mac.stk_stack_n", ["n": .number(Double(chosen.count))]), systemImage: "square.stack")
                    }
                    .disabled(!shop.canStackSelection)
                    Button { typedTag = ""; tagging = true } label: {
                        Label(w.callIt("mac.li_add_tag"), systemImage: "number")
                    }
                    .shopPopover(isPresented: $tagging, arrowEdge: .bottom) {
                        NameIt(words: w, typed: $typedTag, title: w.callIt("mac.li_add_tag_title"),
                               example: w.callIt("mac.tag_example"),
                               note: w.callIt("mac.li_add_tag_note"),
                               confirm: w.callIt("mac.li_add")) { line in
                            tagging = false
                            Task { await shop.addTagToSelection(line) }
                        }
                    }
                    categoryMenu
                        .shopPopover(isPresented: $namingCategory, arrowEdge: .bottom) {
                            NameIt(words: w, typed: $typedCategory,
                                   title: w.callIt("mac.name_this_category"),
                                   example: w.callIt("mac.category_example"),
                                   note: w.callIt("mac.group_name_kept"),
                                   confirm: w.callIt("mac.file_it")) { name in
                                namingCategory = false
                                let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !wanted.isEmpty else { return }
                                Task { await shop.fileSelection(underCategory: wanted) }
                            }
                        }
                    folderMenu
                    Button { typedMaterial = Self.common(chosen.map { $0.material ?? "" }); settingMaterial = true } label: {
                        Label(w.callIt("mac.li_set_material"), systemImage: "circle.hexagongrid")
                    }
                    .shopPopover(isPresented: $settingMaterial, arrowEdge: .bottom) {
                        NameIt(words: w, typed: $typedMaterial, title: w.callIt("mac.li_set_material_title"),
                               example: w.callIt("mac.li_material_example"),
                               note: w.callIt("mac.li_material_note"),
                               confirm: w.callIt("mac.li_set")) { line in
                            settingMaterial = false
                            shop.setMaterialOnSelection(line)
                        }
                    }
                }
                .disabled(!shop.canWrite)
                // A PRIVATE LINK, or a product sold through the vault. Absent
                // unless the library's remote IS the vault (`libraryOnVault`).
                if shop.libraryOnVault, let first = chosen.first {
                    group(w.callIt("mac.li_group_share")) {
                        Button { shop.shareByLink(first) } label: {
                            Label(w.callIt("mac.vl_share") + "\u{2026}", systemImage: "link")
                        }
                        Button { Task { await shop.sellAsProduct(first) } } label: {
                            Label(w.callIt("mac.vp_sell") + "\u{2026}", systemImage: "cart")
                        }
                    }
                    .disabled(!shop.canWrite)
                }
                if shop.libraryHasRemote { storage(chosen) }
                group(w.callIt("mac.li_group_remove")) {
                    // Put aside, or back — only the ones it would change, so a
                    // mixed selection says how many it really moves.
                    let aside = Set(chosen.filter { !$0.isArchived }.map(\.id))
                    let back = Set(chosen.filter(\.isArchived).map(\.id))
                    if !aside.isEmpty {
                        Button { shop.archive(aside) } label: {
                            Label(ModelActions.archiveTitle(restoring: false, count: aside.count, words: w),
                                  systemImage: "archivebox")
                        }
                        .disabled(!shop.canWrite)
                    }
                    if !back.isEmpty {
                        Button { shop.unarchive(back) } label: {
                            Label(ModelActions.archiveTitle(restoring: true, count: back.count, words: w),
                                  systemImage: "arrow.uturn.backward")
                        }
                        .disabled(!shop.canWrite)
                    }
                    // The count in the title is the count asked about and the
                    // count deleted: `askToDeleteFromLibrary` takes exactly
                    // these, refuses any not on screen, and its question names
                    // them and the groups they are in.
                    Button(role: .destructive) { shop.askToDeleteFromLibrary(chosen) } label: {
                        // Red only when it can be pressed: an explicit colour
                        // overrides the disabled dimming, and a greyed pane
                        // with one bright red button reads as the way out.
                        Label(Self.deleteTitle(count: chosen.count, words: w), systemImage: "trash")
                            .foregroundStyle(shop.canWrite && !chosen.isEmpty ? AnyShapeStyle(Khayt.late) : AnyShapeStyle(.secondary))
                    }
                    .disabled(!shop.canWrite || chosen.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    /// "Delete 5 Models…" — the number is the list handed to the question.
    static func deleteTitle(count: Int, words: Words) -> String {
        words.callIt("mac.delete_n_models", ["n": .number(Double(count))]) + "\u{2026}"
    }

    /// What every one of them shares, or empty.
    static func common(_ values: [String]) -> String {
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return "" }
        return first
    }

    private func totalsCard(_ t: SelectionTotals) -> some View {
        let none = "\u{2014}"
        return VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    tile(w.callIt("mac.li_print_time"),
                         t.hours > 0 ? PrintFigures.duration(hours: t.hours, w) : none, unit: nil,
                         approximate: t.anyEstimated && t.hours > 0)
                    tile(w.callIt("mac.li_filament"),
                         t.grams > 0 ? PrintFigures.weight(t.grams, w) : none, unit: nil,
                         approximate: t.anyEstimated && t.grams > 0)
                }
                GridRow {
                    // "Size", not "On disk": the sum counts every file's size,
                    // including the ones not on this Mac (said below it).
                    tile(w.callIt("set.store_size"), Format.bytes(t.bytes), unit: nil)
                    tile(w.callIt("mac.li_online_only_label"), "\(t.onlineOnly)", unit: nil,
                         dim: t.onlineOnly == 0)
                }
            }
            if t.withFigures < t.count {
                Text(w.callIt("mac.li_totals_partial", ["n": .number(Double(t.withFigures)),
                                                        "total": .number(Double(t.count))]))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if t.notHere > 0 {
                Text(w.callIt("mac.li_not_here_n", ["n": .number(Double(t.notHere))]))
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tile(_ label: String, _ value: String, unit: String?, dim: Bool = false,
                      approximate: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if approximate {
                    Text(verbatim: "\u{2248}").font(.callout).foregroundStyle(.secondary)
                }
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(dim ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Khayt.recessed, in: RoundedRectangle(cornerRadius: Radius.control))
    }

    /// A captioned run of buttons that wraps in the inspector's width.
    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            FlowLayout(spacing: 6) { content() }
                .controlSize(.small)
        }
    }

    /// The categories the shop already uses, then a new one — the toolbar's
    /// Categorise menu, here because this is where the selection is.
    private var categoryMenu: some View {
        Menu {
            ForEach(shop.categoriesInUse, id: \.self) { category in
                Button(category) { Task { await shop.fileSelection(underCategory: category) } }
            }
            if !shop.categoriesInUse.isEmpty { Divider() }
            Button(w.callIt("mac.new_category")) { typedCategory = ""; namingCategory = true }
            if shop.selectedFiles.contains(where: { !($0.category ?? "").isEmpty }) {
                Button(w.callIt("mac.remove_from_category")) {
                    Task { await shop.fileSelection(underCategory: "") }
                }
            }
        } label: {
            Label(w.callIt("mac.li_set_category"), systemImage: "tag")
        }
        .fixedSize()
    }

    /// The shop's folders, then a new one — the toolbar's Group menu.
    private var folderMenu: some View {
        Menu {
            ForEach(shop.groups, id: \.self) { group in
                Button(group) { Task { await shop.fileSelection(under: group) } }
            }
            if !shop.groups.isEmpty { Divider() }
            Button(w.callIt("mac.new_group")) { shop.namingGroup = true }
            if shop.selectedFiles.contains(where: { $0.groupName != nil }) {
                Button(w.callIt("mac.remove_from_group")) { Task { await shop.fileSelection(under: "") } }
            }
        } label: {
            Label(w.callIt("mac.li_move_folder"), systemImage: "folder")
        }
        .fixedSize()
    }

    /// Free their space, or keep them here — through the one-model paths.
    @ViewBuilder private func storage(_ chosen: [LibraryFile]) -> some View {
        let movable = chosen.filter {
            !$0.isLinked && !shop.isInCloudOnly($0) && shop.fileIsPresent($0) && !shop.isKeptOnThisMac($0)
        }
        let allKept = !chosen.isEmpty && chosen.allSatisfy { shop.isKeptOnThisMac($0) }
        group(w.callIt("mac.li_group_storage")) {
            Button { Task { await shop.freeUpSpace(models: movable) } } label: {
                Label(w.callIt("mac.li_free_up_n", ["n": .number(Double(movable.count))]),
                      systemImage: "icloud.and.arrow.up")
            }
            .disabled(movable.isEmpty || shop.cloudLibraryBusy || !shop.canWrite)
            Button { Task { await shop.keepOnThisMac(models: chosen, !allKept) } } label: {
                Label(w.callIt(allKept ? "mac.li_unkeep" : "mac.storage_keep"),
                      systemImage: allKept ? "pin.slash" : "pin")
            }
            .disabled(shop.cloudLibraryBusy || shop.syncIndex == nil)
            if shop.cloudLibraryBusy { ProgressView().controlSize(.small) }
        }
        if let note = shop.cloudLibraryNote {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        if let problem = shop.cloudLibraryProblem {
            Text(problem).font(.caption).foregroundStyle(Khayt.attention)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The two kinds of group, as the shop chooses between them.
///
/// Radio buttons rather than a menu: there are two, both always worth seeing,
/// and the line under them says what the choice does.
struct GroupKindChoice: View {
    let words: Words
    @Binding var kind: GroupKind

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: $kind) {
                ForEach(GroupKind.allCases, id: \.self) { kind in
                    // The mark in a fixed-width slot: the puzzle piece is
                    // wider than the stack, and the two names started at
                    // different places (alpha.57 snapshot).
                    Label {
                        Text(words.callIt(kind.wordKey))
                    } icon: {
                        Image(systemName: kind.symbol).frame(width: 18)
                    }
                    .tag(kind)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(words.callIt("mac.group_kind_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 220, alignment: .leading)
        }
    }
}

/// Switching a group between the two kinds, from its tile's right-click and
/// from the crumb above an open group.
struct GroupKindMenu: View {
    @Bindable var shop: Shop
    let path: String

    var body: some View {
        let current = shop.groupKind(path)
        Menu(shop.words.callIt("mac.group_kind_menu")) {
            ForEach(GroupKind.allCases, id: \.self) { kind in
                Button {
                    Task { await shop.setGroupKind(path, kind) }
                } label: {
                    if kind == current { Label(shop.words.callIt(kind.wordKey), systemImage: "checkmark") }
                    else { Text(shop.words.callIt(kind.wordKey)) }
                }
            }
        }
        .disabled(!shop.canWrite)
    }
}
