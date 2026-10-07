import SwiftUI
import KhaytCore

/// One of the shop's sites: `store.locations[]`.
///
/// `{ id: 'LOC-…', name, address }`, written by both apps. Read from the raw
/// row so a record this app does not model the rest of — `rev`, `updatedAt` —
/// is edited in place rather than rebuilt (see `Shop.writeLocation`).
struct ShopLocation: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let address: String

    init(id: String, name: String, address: String) {
        self.id = id; self.name = name; self.address = address
    }

    init?(row: JSONValue) {
        guard case .object(let r) = row, case .string(let id)? = r["id"], !id.isEmpty else { return nil }
        func text(_ v: JSONValue?) -> String { if case .string(let s)? = v { return s }; return "" }
        self.id = id
        self.name = text(r["name"])
        self.address = text(r["address"])
    }
}

/// The shop's sites, listed on the Operations pane.
///
/// Its own Section beside the pane's settings and NOT part of their draft:
/// a location is a record, written the moment it is saved, the way a
/// supplier or a message template is. The pane's Save bar is for the
/// settings above it, and a location waiting on it would be a location the
/// machine sheet could not offer yet.
///
/// Not in a `*Sheet.swift` for the reason `TemplatesSection` gives: the
/// guard on sheets reads those files for unbounded lists, and this list is
/// inside the Settings window's scrolling `Form`.
struct LocationsSection: View {
    @Bindable var shop: Shop
    @State private var editing: ShopLocation?
    @State private var deleting: ShopLocation?

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 8) {
            Text(words.callIt("set.locations")).font(.headline)
            Text(words.callIt("mac.locations_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if shop.locations.isEmpty {
                Text(words.callIt("mac.no_locations"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(shop.locations) { loc in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc.name)
                            if !loc.address.isEmpty {
                                Text(loc.address).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.tail)
                            }
                            let here = shop.machines.filter { $0.locationId == loc.id }.map(\.name)
                            if !here.isEmpty {
                                Text(here.joined(separator: words.language == "ar" ? "، " : ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.tail)
                            }
                        }
                        Spacer()
                        Button(words.callIt("common.edit")) { editing = loc }
                            .disabled(!shop.canWrite)
                        Button(words.callIt("common.delete"), role: .destructive) { deleting = loc }
                            .disabled(!shop.canWrite)
                    }
                    Divider()
                }
            }

            // An icon, not the catalogue's "+ " prefix — see the operators'.
            Button {
                editing = ShopLocation(id: "", name: "", address: "")
            } label: {
                Label(words.callIt("mac.location_add"), systemImage: "plus")
            }
            .disabled(!shop.canWrite)
            .help(shop.canWrite ? words.callIt("mac.locations_hint") : words.callIt("mac.move_sample"))
        }
        .sheet(item: $editing) { loc in
            LocationEditor(shop: shop, location: loc)
        }
        .confirmationDialog(
            words.callIt("mac.location_delete_confirm", ["name": .string(deleting?.name ?? "")]),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { loc in
            Button(words.callIt("common.delete"), role: .destructive) {
                Task { await shop.deleteLocation(loc.id) }
            }
            Button(words.callIt("common.cancel"), role: .cancel) {}
        } message: { _ in
            Text(words.callIt("mac.location_delete_hint"))
        }
    }
}

/// Name and address. Two fields, so it fits any screen without scrolling.
struct LocationEditor: View {
    let shop: Shop
    let location: ShopLocation
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 14) {
            Text(words.callIt(location.id.isEmpty ? "mac.location_new" : "mac.location_edit"))
                .font(.headline)
            Form {
                TextField(words.callIt("set.location_name"), text: $name)
                TextField(words.callIt("set.location_addr"), text: $address)
            }
            .formStyle(.grouped)
            if let problem = shop.moveProblem {
                Text(problem).font(.callout).foregroundStyle(Khayt.late)
            }
            HStack {
                Spacer()
                Button(words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(words.callIt("common.save")) {
                    Task {
                        await shop.saveLocation(id: location.id.isEmpty ? nil : location.id,
                                                name: name, address: address)
                        if shop.moveProblem == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            name = location.name
            address = location.address
            shop.moveProblem = nil
        }
    }
}
