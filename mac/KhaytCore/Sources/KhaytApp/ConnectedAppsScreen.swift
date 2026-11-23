import SwiftUI
import KhaytCore

/// ── CONNECTED APPS: A SECTION OF ITS OWN ──────────────────────────────────
///
/// Slicer plugins (Khayt for OrcaSlicer) paired with this Mac, pairing a new
/// one, what they sent, and how to get the plugin. It was a row inside
/// Settings ▸ Online; Turki asked for it to have its own place (Nov 16 2026).
/// Figma Qqxg4imtKVgC3TfNGcRGOk, page 16 (frames A–E, approved).
///
/// Dark while "Pair a slicer" is off: no sidebar row, no pointer, and the
/// shelf does not restore (`canShow`). The From slicer inbox is reachable by
/// its banner and sheet either way.
///
/// ── NO CUSTOMER DATA ON THIS SCREEN ──────────────────────────────────────
///
/// Nothing here is read from the book's jobs or clients. The only text from
/// outside the app is what a slicer sent: its name and file names, shown as
/// sent and never matched to clients.
struct ConnectedAppsScreen: View {
    @Bindable var shop: Shop
    /// Read the paired slicers and the inbox again on appearing. Off only for
    /// a snapshot of the sample, whose slicers and files are in memory.
    var refreshes = true
    /// In a scroll view, as the window shows it. A snapshot draws the content
    /// alone: an offscreen render of a scroll view comes back empty.
    var scrolls = true
    @State private var removing: LanDevices.Listed?

    var body: some View {
        Group {
            if scrolls { ScrollView { page } } else { page }
        }
        .task {
            guard refreshes else { return }
            shop.refreshConnectedApps()
            shop.refreshConnectorPrices()
            shop.refreshSlicerInbox()
        }
        .askFirst($removing,
                  title: { shop.words.callIt("mac.apps_remove_q", ["name": .string(ConnectedApps.name($0.name, shop.words))]) },
                  message: { Self.removeNote(for: $0, shop: shop) },
                  confirm: shop.words.callIt("mac.apps_remove"),
                  cancel: shop.words.callIt("common.cancel")) { app in
            shop.removeConnector(app.id)
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            prices
            slicers
            inbox
            plugin
        }
        .padding(28)
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shop.words.callIt("mac.apps_title")).font(.title2.weight(.semibold))
            Text(shop.words.callIt("mac.apps_screen_sub"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Show prices in OrcaSlicer (page 24)

    private var prices: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { shop.connectorPricesOn }, set: { shop.setConnectorPrices($0) })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(shop.words.callIt("mac.apps_prices")).font(.body.weight(.medium))
                    Text(shop.words.callIt(shop.connectorPricesOn ? "mac.apps_prices_on" : "mac.apps_prices_off"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .disabled(!shop.mayChangeConnectorPrices)
            if !shop.mayChangeConnectorPrices {
                Text(shop.words.callIt("mac.apps_prices_owner")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }

    /// One slicer's grant: None, Price, or Price and cost, each saying what
    /// the device learns. Shown only while the switch is on.
    private func grantPicker(_ app: LanDevices.Listed) -> some View {
        HStack(spacing: 6) {
            Text(shop.words.callIt("mac.apps_grant_label")).font(.caption).foregroundStyle(.secondary)
            Menu {
                ForEach(Self.grants, id: \.self) { grant in
                    Button {
                        shop.setConnectorPriceGrant(app.id, grant)
                    } label: {
                        Text(Shop.connectorGrantName(grant, words: shop.words))
                        Text(shop.words.callIt(Self.grantNote(grant)))
                    }
                    .disabled(grant == "cost" && !shop.mayGrantConnectorCost)
                }
            } label: {
                Text(Shop.connectorGrantName(app.priceGrant, words: shop.words))
            }
            .fixedSize()
            .disabled(!shop.mayChangeConnectorPrices)
        }
    }

    /// The picker's three choices, in the frame's order.
    static let grants: [String?] = [nil, "price", "cost"]

    /// What each choice lets a device learn, said under it. "Price" says the
    /// part a shop would not guess: by trying plates, a device can estimate
    /// material costs from the prices alone (release security review, LOW 3).
    static func grantNote(_ grant: String?) -> String {
        switch grant {
        case "price": "mac.apps_grant_price_note"
        case "cost": "mac.apps_grant_cost_note"
        default: "mac.apps_grant_none_note"
        }
    }

    // MARK: - Paired slicers, and pairing one

    private var slicers: some View {
        Card(title: shop.words.callIt("mac.apps_slicers"),
             note: shop.connectedApps.isEmpty ? nil : String(shop.connectedApps.count)) {
            if shop.connectedApps.isEmpty {
                Text(shop.words.callIt("mac.apps_none")).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
            ForEach(shop.connectedApps) { app in
                Divider()
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: ConnectedApps.name(app.name, shop.words))
                            .font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text(shop.words.callIt("mac.phones_seen", ["date": .string(
                            shop.words.say(app.lastSeenAt, .dateTime.day().month(.abbreviated).year()))]))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(Shop.connectorDoes(grant: app.priceGrant, pricesOn: shop.connectorPricesOn, words: shop.words))
                            .font(.caption).foregroundStyle(.secondary)
                        let waiting = Self.filesFrom(app.id, shop: shop)
                        if waiting > 0 {
                            Text(shop.words.counting(waiting, "mac.apps_files_from"))
                                .font(.caption).foregroundStyle(Khayt.brand)
                        }
                    }
                    Spacer(minLength: 0)
                    if shop.connectorPricesOn { grantPicker(app) }
                    Button(shop.words.callIt("mac.apps_remove") + "\u{2026}") { removing = app }
                        .disabled(!shop.lockAllows("settings", "edit"))
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            Divider()
            PairASlicer(shop: shop)
                .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    // MARK: - The From slicer inbox, inline

    private var inbox: some View {
        Card(title: shop.words.callIt("mac.su_title"),
             note: shop.slicerUploads.isEmpty ? nil : shop.words.counting(shop.slicerUploads.count, "mac.su_waiting")) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let problem = shop.slicerInboxProblem {
                    Text(problem).font(.caption).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let said = shop.slicerInboxSaid {
                    Label(said, systemImage: "checkmark.circle").font(.caption).foregroundStyle(Khayt.done)
                }
                if shop.slicerUploads.isEmpty {
                    Text(shop.words.callIt("mac.su_none")).foregroundStyle(.secondary)
                } else {
                    SlicerInboxRows(shop: shop)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    // MARK: - Getting the plugin

    private var plugin: some View {
        Card(title: shop.words.callIt("mac.apps_get_title"), note: "Khayt for OrcaSlicer") {
            ForEach(Array(["mac.apps_get_step1", "mac.apps_get_step2", "mac.apps_get_step3"].enumerated()),
                    id: \.offset) { i, key in
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: String(i + 1)).font(.body.monospaced()).foregroundStyle(.secondary)
                    Text(shop.words.callIt(key)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
            }
            Divider()
            // No link until there is a release to point at: no promise the
            // site cannot keep (the plugin is not available yet).
            Text(shop.words.callIt("mac.apps_get_soon")).font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 9)
        }
    }

    // MARK: - Rules, for the tests

    /// Files waiting in the inbox that this slicer sent.
    @MainActor static func filesFrom(_ connectorId: String, shop: Shop) -> Int {
        shop.slicerUploads.count(where: { $0.connectorId == connectorId })
    }

    /// Removing a slicer never discards what it sent: they are the shop's
    /// files now, and the confirm says how many stay (Dev Hub, Nov 16).
    @MainActor static func removeNote(for app: LanDevices.Listed, shop: Shop) -> String {
        let note = shop.words.callIt("mac.apps_remove_note")
        let staying = filesFrom(app.id, shop: shop)
        guard staying > 0 else { return note }
        return note + " " + shop.words.counting(staying, "mac.apps_remove_keeps")
    }

    /// A titled card: the page-16 frames' look, in the app's own colours.
    private struct Card<Content: View>: View {
        let title: String
        var note: String?
        @ViewBuilder var content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.headline)
                    if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
                content
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

/// Settings ▸ Online keeps only a pointer to the section.
struct ConnectedAppsPointer: View {
    let shop: Shop

    var body: some View {
        LabeledContent(shop.words.callIt("mac.apps_title")) {
            HStack(spacing: 8) {
                Text(shop.connectedApps.isEmpty
                     ? shop.words.callIt("mac.apps_none")
                     : shop.words.counting(shop.connectedApps.count, "mac.apps_pointer"))
                    .foregroundStyle(.secondary)
                Button(shop.words.callIt("mac.apps_open")) { shop.shelf = .connectedApps }
            }
        }
        .task { shop.refreshConnectedApps() }
    }
}
