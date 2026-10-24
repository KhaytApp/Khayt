import SwiftUI
import KhaytCore

/// ── ONE MENU FOR CHANGING THE SELECTION ───────────────────────────────────
///
/// The title strip carried three menus — Group, Category, Where it came from
/// — beside the sort order. All three CHANGED the selected models, and all
/// three looked exactly like the filters in the row below: a shop reaching
/// for "show me the dental models" pulled down Category and was offered to
/// re-file what it had selected. They are one menu now, "Edit", greyed until
/// something is selected and saying how many when it is, with the three as
/// submenus holding the same choices, ticks and typed names as before.
///
/// The naming popovers hang from this menu. "New Group…" on a model's right
/// click (`FileActions`) still sets `Shop.namingGroup`, and this is the view
/// that answers it — so it stays on the strip whenever the library is shown,
/// selection or not.
struct EditSelectionMenu: View {
    @Bindable var shop: Shop
    @State private var typedGroup = ""
    @State private var namingCategory = false
    @State private var typedCategory = ""
    @State private var tagging = false
    @State private var typedTags = ""
    @State private var typingSource = false
    @State private var typedSource = ""
    @Environment(\.stripCompact) private var compact

    private var count: Int { shop.selectedIds.count }
    private var chosenGroups: [String] { shop.selectedGroups }

    /// "Edit", or "Edit 3 Models" — the menu says what it will act on.
    static func title(models: Int, groups: Int, words: Words) -> String {
        if groups > 0 {
            return words.callIt("mac.lg_edit_n", ["what": .string(words.counting(groups, "mac.n_groups_of"))])
        }
        if models > 1 {
            return words.callIt("mac.lg_edit_n", ["what": .string(words.counting(models, "mac.n_models"))])
        }
        return words.callIt("mac.lg_edit")
    }

    var body: some View {
        Menu {
            if !chosenGroups.isEmpty {
                GroupTileActions(shop: shop, path: chosenGroups[0])
            } else if count == 0 {
                Text(shop.words.callIt("mac.pick_a_model"))
            } else {
                groupMenu
                categoryMenu
                provenanceMenu
            }
        } label: {
            let title = Self.title(models: count, groups: chosenGroups.count, words: shop.words)
            if compact {
                Label(title, systemImage: "pencil.and.list.clipboard").labelStyle(.iconOnly)
            } else {
                Label(title, systemImage: "pencil.and.list.clipboard")
            }
        }
        .disabled(!shop.canWrite || (count == 0 && chosenGroups.isEmpty))
        .help(shop.canWrite ? shop.words.callIt("mac.lg_edit_help") : shop.words.callIt("mac.group_locked"))
        .shopPopover(isPresented: $shop.namingGroup, arrowEdge: .bottom) {
            NameAGroup(words: shop.words, typed: $typedGroup, known: shop.groups) { name, kind in
                shop.namingGroup = false
                let wanted = TypedGroupName.flatten(name, known: shop.groups)
                guard !wanted.isEmpty else { return }
                Task { await shop.fileSelection(under: wanted, kind: kind) }
            }
        }
        .onChange(of: shop.namingGroup) { _, now in if now { typedGroup = "" } }
        .shopPopover(isPresented: $namingCategory, arrowEdge: .bottom) {
            NameIt(words: shop.words, typed: $typedCategory,
                   title: shop.words.callIt("mac.name_this_category"),
                   example: shop.words.callIt("mac.category_example"),
                   note: shop.words.callIt("mac.group_name_kept"),
                   confirm: shop.words.callIt("mac.file_it")) { name in
                namingCategory = false
                let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !wanted.isEmpty else { return }
                Task { await shop.fileSelection(underCategory: wanted) }
            }
        }
        .shopPopover(isPresented: $tagging, arrowEdge: .bottom) {
            NameIt(words: shop.words, typed: $typedTags,
                   title: shop.words.callIt("mac.tags"),
                   example: shop.words.callIt("mac.tag_example"),
                   note: shop.words.callIt("mac.group_name_kept") + " " + shop.words.callIt("mac.tags_replaced"),
                   confirm: shop.words.callIt("mac.file_it")) { line in
                tagging = false
                Task { await shop.tagSelection(line) }
            }
        }
        .shopPopover(isPresented: $typingSource, arrowEdge: .bottom) {
            NameIt(words: shop.words, typed: $typedSource,
                   title: shop.words.callIt("plib.source"),
                   example: shop.words.callIt("plib.source_ph"),
                   note: shop.words.callIt("mac.source_replaced"),
                   confirm: shop.words.callIt("mac.file_it")) { line in
                typingSource = false
                Task { await shop.setSourceOnSelection(line) }
            }
        }
    }

    // MARK: The three submenus — the old menus' contents, unchanged

    private var groupMenu: some View {
        Menu {
            ForEach(shop.groups, id: \.self) { group in
                Button {
                    Task { await shop.fileSelection(under: group) }
                } label: {
                    if allIn(group: group) { Label(group, systemImage: "checkmark") } else { Text(group) }
                }
            }
            if !shop.groups.isEmpty { Divider() }
            Button(shop.words.callIt("mac.new_group")) { typedGroup = ""; shop.namingGroup = true }
            if shop.selectedFiles.contains(where: { $0.groupName != nil }) {
                Button(shop.words.callIt("mac.remove_from_group")) {
                    Task { await shop.fileSelection(under: "") }
                }
            }
        } label: {
            Label(shop.words.callIt("mac.group"), systemImage: "square.stack")
        }
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(shop.categoriesInUse, id: \.self) { category in
                Button {
                    Task { await shop.fileSelection(underCategory: category) }
                } label: {
                    if allIn(category: category) { Label(category, systemImage: "checkmark") } else { Text(category) }
                }
            }
            if !shop.categoriesInUse.isEmpty { Divider() }
            Button(shop.words.callIt("mac.new_category")) { typedCategory = ""; namingCategory = true }
            if shop.selectedFiles.contains(where: { !($0.category ?? "").isEmpty }) {
                Button(shop.words.callIt("mac.remove_from_category")) {
                    Task { await shop.fileSelection(underCategory: "") }
                }
            }
            Divider()
            Button(shop.words.callIt("mac.tags") + "\u{2026}") {
                typedTags = shop.tagsOnSelection.joined(separator: ", ")
                tagging = true
            }
        } label: {
            Label(shop.words.callIt("mac.category"), systemImage: "tag")
        }
    }

    private var provenanceMenu: some View {
        Menu {
            ForEach(ModelLicence.all) { licence in
                Button {
                    Task { await shop.fileSelection(licence: licence.id) }
                } label: {
                    if shop.licenceOnSelection == licence.id {
                        Label(licenceName(licence.id), systemImage: "checkmark")
                    } else {
                        Text(licenceName(licence.id))
                    }
                }
            }
            Divider()
            Button {
                Task { await shop.fileSelection(licence: "") }
            } label: {
                if shop.licenceOnSelection == "" {
                    Label(shop.words.callIt("plib.licence_unknown"), systemImage: "checkmark")
                } else {
                    Text(shop.words.callIt("plib.licence_unknown"))
                }
            }
            Divider()
            Button(shop.words.callIt("plib.source") + "\u{2026}") {
                typedSource = shop.sourceOnSelection
                typingSource = true
            }
        } label: {
            Label(shop.words.callIt("plib.provenance"), systemImage: "signature")
        }
    }

    private func allIn(group: String) -> Bool {
        let chosen = shop.selectedFiles
        return !chosen.isEmpty && chosen.allSatisfy { $0.groupName == group }
    }

    private func allIn(category: String) -> Bool {
        let chosen = shop.selectedFiles
        return !chosen.isEmpty && chosen.allSatisfy { ($0.category ?? "").lowercased() == category.lowercased() }
    }

    private func licenceName(_ id: String) -> String {
        shop.words.callIt("plib.licence_" + id.replacingOccurrences(of: "-", with: "_"))
    }
}
