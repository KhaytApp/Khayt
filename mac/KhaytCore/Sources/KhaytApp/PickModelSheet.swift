import SwiftUI

/// Choose a model from the library, for a part.
///
/// Reported from the running app: *"in Catalogue I should be able to load the
/// print file to calculate the price"*. The product sheet could only be typed
/// into — grams and hours by hand — while the library already knew both for
/// every model the shop had sliced, and could estimate them for the rest. The
/// other direction existed (make a product FROM a selected model); this is the
/// same rule, `Shop.partFields(from:)`, reached from the sheet instead.
///
/// A sheet rather than a menu: a hundred and fifty models is a list to search,
/// not a menu to scroll. The order is the library's own — favourites, then
/// most recently added — so the model a shop just imported is at the top.
struct PickModelSheet: View {
    @Bindable var shop: Shop
    let choose: (LibraryFile) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var chosen: LibraryFile.ID?
    @FocusState private var focused: Bool

    static let width: CGFloat = 460

    private var shown: [LibraryFile] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        return shop.files
            .filter { term.isEmpty || $0.title.lowercased().contains(term)
                      || ($0.originalName ?? "").lowercased().contains(term) }
            .sorted(by: LibrarySort.khayt.order)
    }

    var body: some View {
        SheetFrame(width: Self.width) {
            Text(shop.words.callIt("link.from_library")).font(.headline)
            TextField(shop.words.callIt("mac.search_models"), text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            if shown.isEmpty {
                // The library's own two sentences, not a third pair.
                Text(shop.files.isEmpty
                     ? shop.words.callIt("mac.no_models")
                     : shop.words.callIt("mac.nothing_matches", ["q": .string(search)]))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                List(shown, selection: $chosen) { file in
                    HStack(spacing: 8) {
                        Text(file.title).lineLimit(1)
                        Spacer()
                        // What choosing it will fill in, said before the choice.
                        if let mesh = file.mesh {
                            Text(Format.mm(mesh.x) + " × " + Format.mm(mesh.y) + " × " + Format.mm(mesh.z))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .tag(file.id)
                    // Double-click is the choice, as it is in the library.
                    .onTapGesture(count: 2) { pick(file) }
                }
                .frame(minHeight: 220)
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.choose")) {
                    if let file = shown.first(where: { $0.id == chosen }) { pick(file) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil)
            }
        }
        .onAppear { focused = true }
    }

    private func pick(_ file: LibraryFile) {
        choose(file)
        dismiss()
    }
}
