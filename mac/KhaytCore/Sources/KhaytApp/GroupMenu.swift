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
    @State private var naming = false
    @State private var typed = ""

    private var count: Int { shop.fileSelection.count }

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
                Button(shop.words.callIt("mac.new_group")) { typed = ""; naming = true }
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
        .popover(isPresented: $naming, arrowEdge: .bottom) {
            NameAGroup(words: shop.words, typed: $typed) { name in
                naming = false
                let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !wanted.isEmpty else { return }
                Task { await shop.fileSelection(under: wanted) }
            }
        }
    }

    private func allAlreadyIn(_ group: String) -> Bool {
        let chosen = shop.selectedFiles
        return !chosen.isEmpty && chosen.allSatisfy { $0.groupName == group }
    }
}

private struct NameAGroup: View {
    let words: Words
    @Binding var typed: String
    let done: (String) -> Void
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
                .onSubmit { done(typed) }
            Text(words.callIt("mac.group_name_kept"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(words.callIt("mac.file_it")) { done(typed) }
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
            Text(shop.words.callIt("mac.n_models", ["n": .number(Double(chosen.count))]))
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
