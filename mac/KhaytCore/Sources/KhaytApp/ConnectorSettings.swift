import SwiftUI
import UniformTypeIdentifiers
import KhaytCore

/// Settings ▸ Integrations ▸ Connectors: the connectors this shop installed,
/// each one's state and keys, and installing one from a file Khayt signed.
///
/// The words are the desktop's (`plg.*`, nine languages), so the two apps
/// describe a connector — and what it sends — in the same sentences.
struct ConnectorSettings: View {
    let shop: Shop

    @State private var rows: [ConnectorRow] = []
    @State private var importing = false
    @State private var result: String?
    @State private var keys: [String: [String: String]] = [:]
    @State private var removing: ConnectorRow?

    private var mayWrite: Bool { shop.lockAllows("settings", "edit") && shop.source.build != nil }

    var body: some View {
        Section(shop.words.callIt("plg.title")) {
            Text(shop.words.callIt("plg.hint")).font(.callout).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(shop.words.callIt("plg.none")).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in connector(row) }
            HStack {
                Button(shop.words.callIt("plg.install")) { importing = true }
                if let result { Text(result).font(.callout).foregroundStyle(.secondary) }
                Spacer()
            }
        }
        .disabled(!mayWrite)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { picked in
            guard case .success(let url) = picked else { return }
            Task { result = await offer(url) }
        }
        .shopSheet(item: Binding(get: { shop.connectorOffer }, set: { if $0 == nil { shop.connectorOffer = nil } })) { offer in
            ConnectorConsentSheet(shop: shop, offer: offer) { said in
                result = said
                Task { await reload() }
            }
        }
        .confirmationDialog(
            removing.map { shop.words.callIt("plg.remove_q").replacingOccurrences(of: "{name}", with: $0.name) } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button(shop.words.callIt("plg.remove"), role: .destructive) {
                guard let row = removing else { return }
                Task {
                    await shop.removeConnector(row.id)
                    result = shop.words.callIt("plg.removed")
                    await reload()
                }
            }
        }
        .task(id: shop.settingsValue) { await reload() }
    }

    @ViewBuilder
    private func connector(_ row: ConnectorRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.name).font(.body.weight(.medium))
                Text(row.version).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(shop.words.callIt("plg.state_" + row.state))
                    .font(.caption)
                    .foregroundStyle(row.state == "on" ? Khayt.done : row.state == "off" ? Khayt.note : Khayt.attention)
            }
            if row.state == "on" || row.state == "off" {
                if row.keysMissing {
                    Text(shop.words.callIt("plg.keys_missing")).font(.caption).foregroundStyle(Khayt.attention)
                }
                ForEach(row.secrets) { secret in
                    SecureField(secret.label, text: keyBinding(row.id, secret.name),
                                prompt: Text(secret.held ? "••••••••" : shop.words.callIt("plg.secret_ph")))
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack(spacing: 12) {
                if !row.secrets.isEmpty, row.state == "on" || row.state == "off" {
                    Button(shop.words.callIt("plg.save_keys")) {
                        Task {
                            if await shop.saveConnectorKeys(row.id, keys[row.id] ?? [:]) {
                                keys[row.id] = nil
                                result = shop.words.callIt("plg.keys_saved")
                                await reload()
                            }
                        }
                    }
                    .disabled((keys[row.id] ?? [:]).values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                }
                if row.state == "on" || row.state == "off" {
                    Button(shop.words.callIt(row.state == "on" ? "plg.turn_off" : "plg.turn_on")) {
                        Task { await shop.setConnector(row.id, enabled: row.state != "on") }
                    }
                }
                if row.state == "paused", let manifest = manifest(row.id) {
                    // Asks for more than was agreed: show it again and ask.
                    Button(shop.words.callIt("plg.review_agree")) {
                        Task { result = await offer(manifest) }
                    }
                }
                Button(shop.words.callIt("plg.remove"), role: .destructive) { removing = row }
                    .buttonStyle(.link)
                    .foregroundStyle(Khayt.late)
                Spacer()
            }
            .font(.callout)
        }
        .padding(.vertical, 2)
    }

    private func keyBinding(_ id: String, _ name: String) -> Binding<String> {
        Binding(get: { keys[id]?[name] ?? "" }, set: { keys[id, default: [:]][name] = $0 })
    }

    private func manifest(_ id: String) -> JSONValue? {
        shop.connectorEntries.first { Shop.object($0)["id"] == .string(id) }.map { Shop.object($0)["manifest"] ?? .null }
    }

    private func offer(_ url: URL) async -> String? {
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        // A manifest is small; anything big is not one.
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 256 * 1024,
              let data = try? Data(contentsOf: url) else { return shop.words.callIt("plg.err_invalid") }
        return await shop.offerConnector(data)
    }

    private func offer(_ manifest: JSONValue) async -> String? {
        guard let data = try? JSONEncoder().encode(manifest) else { return shop.words.callIt("plg.err_invalid") }
        return await shop.offerConnector(data)
    }

    private func reload() async { rows = await shop.connectorRows() }
}

/// What a connector will send, and where, before it is installed: one row per
/// address with the fields that go there and the kind of data each is.
struct ConnectorConsentSheet: View {
    let shop: Shop
    let offer: ConnectorOffer
    let done: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var installing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(offer.name).font(.title3.weight(.semibold))
                Text(offer.version).foregroundStyle(.secondary)
                Spacer()
                Label(shop.words.callIt("plg.reviewed_by_khayt"), systemImage: "checkmark.seal")
                    .font(.callout).foregroundStyle(Khayt.done)
            }
            Text(shop.words.callIt("plg.consent_lead")).font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(offer.rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.host).font(.body.monospaced().weight(.medium))
                            if row.fields.isEmpty {
                                Text(shop.words.callIt("plg.consent_link_only")).font(.callout).foregroundStyle(.secondary)
                            } else {
                                ForEach(row.fields, id: \.self) { f in
                                    Text("• " + f).font(.callout)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 320)
            if !offer.scopes.isEmpty {
                Text(shop.words.callIt("plg.consent_scopes") + ": "
                     + offer.scopes.map { shop.words.callIt("plg.scope." + $0) }.joined(separator: ", "))
                    .font(.callout)
            }
            Text(shop.words.callIt("plg.consent_keys_here")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.connectorOffer = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("plg.agree_install")) {
                    installing = true
                    Task {
                        let said = await shop.installOfferedConnector()
                        installing = false
                        done(said)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(installing)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
