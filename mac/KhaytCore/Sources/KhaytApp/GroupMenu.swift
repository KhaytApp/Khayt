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

    private var count: Int { shop.selectedIds.count }

    var body: some View {
        Menu {
            if count == 0 {
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
            Label(count > 1
                  ? shop.words.callIt("mac.group_n_models", ["n": .number(Double(count))])
                  : shop.words.callIt("mac.group"),
                  systemImage: "square.stack")
        }
        .disabled(!shop.canWrite || count == 0)
        .help(shop.canWrite
              ? shop.words.callIt("mac.group_why")
              : shop.words.callIt("mac.group_locked"))
        .popover(isPresented: $shop.namingGroup, arrowEdge: .bottom) {
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

/// What several selected models have in common, and what can be done to them.
struct ManyModels: View {
    let shop: Shop

    var body: some View {
        let chosen = shop.selectedFiles
        VStack(alignment: .leading, spacing: 16) {
            Text(shop.words.counting(chosen.count, "mac.n_models"))
                .font(.title3.weight(.semibold))
            DetailSection(shop.words.callIt("mac.together")) {
                DetailLine(shop.words.callIt("mac.on_disk"), Format.bytes(chosen.compactMap(\.size).reduce(0, +)))
                DetailLine(shop.words.callIt("mac.printed"), "\(chosen.reduce(0) { $0 + $1.printCount })×", dim: true)
                let groups = Set(chosen.compactMap(\.groupName))
                DetailLine(shop.words.callIt("mac.group"),
                           groups.isEmpty ? shop.words.callIt("mac.none")
                           : groups.count == 1 ? groups.first!
                           : shop.words.callIt("mac.n_different",
                                               ["n": .number(Double(groups.count))]),
                           dim: groups.isEmpty)
                let missing = chosen.filter { !shop.fileIsPresent($0) }.count
                if missing > 0 { DetailLine(shop.words.callIt("mac.not_on_this_mac"), "\(missing)", warn: true) }
            }
            Text(shop.words.callIt("mac.group_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
            // To the catalogue, together or one each.
            VStack(alignment: .leading, spacing: 6) {
                let n: [String: JSONValue] = ["n": .number(Double(chosen.count))]
                Button { Task { await shop.editingProduct = shop.productFromFiles(chosen, name: nil) } } label: {
                    Label(shop.words.callIt("mac.catalogue_add_as_one", n), systemImage: "tag")
                }
                Button { Task { await shop.addEachToCatalogue(chosen) } } label: {
                    Label(shop.words.callIt("mac.catalogue_add_each", n), systemImage: "tag.circle")
                }
            }
            .controlSize(.small)
            .disabled(!shop.canWrite)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
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
