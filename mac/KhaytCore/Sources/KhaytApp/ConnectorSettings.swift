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
    /// The open-file panel is for a `.khaytplugin` (developer mode), not a signed file.
    @State private var importingDev = false
    @AppStorage(DevConnectors.modeKey) private var devMode = false
    @State private var result: String?
    @State private var keys: [String: [String: String]] = [:]
    @State private var removing: ConnectorRow?
    /// Settings being typed, per connector: key → text ("true"/"" for a box).
    @State private var drafts: [String: [String: String]] = [:]

    private var mayWrite: Bool { shop.lockAllows("settings", "edit") && shop.source.build != nil }

    var body: some View {
        Section(shop.words.callIt("plg.title")) {
            Text(shop.words.callIt("plg.hint")).font(.callout).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(shop.words.callIt("plg.none")).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in connector(row) }
            HStack {
                Button(shop.words.callIt("plg.install")) { importingDev = false; importing = true }
                if devMode {
                    Button(shop.words.callIt("plg.dev_load")) { importingDev = true; importing = true }
                }
                if let result { Text(result).font(.callout).foregroundStyle(.secondary) }
                Spacer()
            }
            Toggle(shop.words.callIt("plg.dev_mode"), isOn: $devMode)
            Text(shop.words.callIt("plg.dev_hint")).font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!mayWrite)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: importingDev ? Self.devTypes : [.json]) { picked in
            guard case .success(let url) = picked else { return }
            let dev = importingDev
            Task { result = await offer(url, dev: dev) }
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
        .onChange(of: shop.devConnectorsRev) { Task { await reload() } }
        .onChange(of: devMode) { Task { await reload() } }
    }

    /// A `.khaytplugin`, or the plain `.json` it was written as.
    static var devTypes: [UTType] {
        [UTType(filenameExtension: DevConnectors.fileExtension, conformingTo: .json), .json].compactMap { $0 }
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
            if row.dev {
                Label(shop.words.callIt("plg.dev_badge"), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Khayt.attention)
            }
            // Events this connector's service turned down: kept, with its words,
            // until the shop retries or dismisses them (`withFailed`).
            ConnectorFailedEvents(shop: shop, pluginId: row.id)
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
            if row.state == "on" || row.state == "off", !row.settings.isEmpty {
                ForEach(row.settings) { st in setting(row, st) }
                HStack(spacing: 12) {
                    Button(shop.words.callIt("common.save")) {
                        Task {
                            let draft = drafts[row.id] ?? [:]
                            var texts: [String: String] = [:], ticks: [String: Bool] = [:]
                            for st in row.settings {
                                guard let v = draft[st.key] else { continue }
                                if st.type == "bool" { ticks[st.key] = v == "true" } else { texts[st.key] = v }
                            }
                            if await shop.saveConnectorSettings(row.id, texts, ticks: ticks) {
                                drafts[row.id] = nil
                                result = shop.words.callIt("plib.saved")
                                await reload()
                            }
                        }
                    }
                    .disabled((drafts[row.id] ?? [:]).isEmpty)
                    if let missing = row.settings.first(where: { $0.required && $0.value.isEmpty }) {
                        Text(shop.words.callIt("plg.err_setting", ["name": .string(missing.label)]))
                            .font(.caption).foregroundStyle(Khayt.attention)
                    }
                    Spacer()
                }
                .font(.callout)
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
                        Task { result = await offer(manifest, dev: row.dev) }
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

    @ViewBuilder
    private func setting(_ row: ConnectorRow, _ st: ConnectorRow.Setting) -> some View {
        let text = Binding<String>(get: { drafts[row.id]?[st.key] ?? st.value },
                                   set: { drafts[row.id, default: [:]][st.key] = $0 })
        let title = st.required ? "\(st.label) (\(shop.words.callIt("common.required")))" : st.label
        switch st.type {
        case "bool":
            Toggle(title, isOn: Binding(get: { text.wrappedValue == "true" }, set: { text.wrappedValue = $0 ? "true" : "" }))
        case "enum":
            Picker(title, selection: text) {
                Text("").tag("")
                ForEach(st.options, id: \.value) { Text($0.label).tag($0.value) }
            }
        default:
            TextField(title, text: text, prompt: Text(st.label))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func keyBinding(_ id: String, _ name: String) -> Binding<String> {
        Binding(get: { keys[id]?[name] ?? "" }, set: { keys[id, default: [:]][name] = $0 })
    }

    private func manifest(_ id: String) -> JSONValue? {
        shop.anyConnectorEntry(id).map { Shop.object($0)["manifest"] ?? .null }
    }

    private func offer(_ url: URL, dev: Bool) async -> String? {
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        // A manifest is small; anything big is not one.
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 256 * 1024,
              let data = try? Data(contentsOf: url) else { return shop.words.callIt("plg.err_invalid") }
        return await shop.offerConnector(data, dev: dev)
    }

    private func offer(_ manifest: JSONValue, dev: Bool) async -> String? {
        guard let data = try? JSONEncoder().encode(manifest) else { return shop.words.callIt("plg.err_invalid") }
        return await shop.offerConnector(data, dev: dev)
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
                if offer.dev {
                    Label(shop.words.callIt("plg.dev_badge"), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Khayt.attention)
                } else {
                    Label(shop.words.callIt("plg.reviewed_by_khayt"), systemImage: "checkmark.seal")
                        .font(.callout).foregroundStyle(Khayt.done)
                }
            }
            if offer.dev {
                Text(shop.words.callIt("plg.dev_warning")).font(.callout).foregroundStyle(Khayt.attention)
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
            if let line = offer.refreshLine {
                Label(line, systemImage: "arrow.triangle.2.circlepath").font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
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

/// Connectors stay hidden from shops until v1 ships on all three apps the same
/// day as the /privacy page that describes them. The desktop's switch is
/// `KHAYT_CONNECTORS=1`; the Mac takes the same variable, or
/// `defaults write <bundle id> KhaytConnectors -bool YES` for a build opened
/// from Finder. Remove this gate on launch day.
enum ConnectorsSwitch {
    nonisolated static func isOn(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 defaults: UserDefaults = .standard) -> Bool {
        environment["KHAYT_CONNECTORS"] == "1" || defaults.bool(forKey: "KhaytConnectors")
    }
}

/// The events a connector's service turned down (`success: false`), each with
/// what the service said, Retry and Dismiss. Never retried on their own: the
/// same request would be turned down the same way until the shop fixes why.
struct ConnectorFailedEvents: View {
    let shop: Shop
    let pluginId: String
    @State private var items: [(delivery: String, event: String, orderId: String, at: String, message: String)] = []

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shop.words.callIt("plg.failed_title")).font(.caption.weight(.semibold))
                        .foregroundStyle(Khayt.attention)
                    ForEach(items, id: \.delivery) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.event + " · " + item.orderId).font(.caption)
                                Text(item.message.isEmpty ? shop.words.callIt("plg.failed_nomsg") : item.message)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button(shop.words.callIt("plg.failed_retry")) {
                                Task { await shop.retryFailedConnectorEvent(delivery: item.delivery); await reload() }
                            }
                            Button(shop.words.callIt("plg.failed_dismiss")) {
                                Task { await shop.dismissFailedConnectorEvent(delivery: item.delivery); await reload() }
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .task(id: shop.settingsValue) { await reload() }
    }

    private func reload() async { items = await shop.failedConnectorEvents(pluginId: pluginId) }
}
