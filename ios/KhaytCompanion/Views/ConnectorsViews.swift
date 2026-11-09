import SwiftUI
import KhaytCore

/// A job's or a customer's connectors: each active one's buttons for this
/// place, and its own fields, read-only. Drawn by Khayt from the manifest —
/// nothing in it came from the connector but words. See `Connectors.swift`.
struct ConnectorsCard: View {
    let place: KhaytAPIClient.ConnectorPlace
    /// Space around the card when it is drawn; none when it is not.
    var outer = EdgeInsets()

    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.openURL) private var openURL
    @State private var connectors: [Connector] = []
    @State private var record: [String: JSONValue]?
    @State private var running: String?
    @State private var message: (text: String, ok: Bool)?
    @State private var confirming: Pending?

    struct Pending: Identifiable {
        let connector: Connector
        let action: Connector.Action
        var id: String { connector.id + "/" + action.id }
    }

    private var shown: [Connector] {
        // One turned off on the Mac, or unreadable, is not drawn here at all.
        connectors.filter { c in c.status != .invalid && c.status != .off && (!actions(c).isEmpty || !fields(c).isEmpty) }
    }

    var body: some View {
        Group {
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.usesArabicLayout ? L10n.tr("connectors.title") : L10n.tr("connectors.title").uppercased())
                        .font(L10n.usesArabicLayout ? .khayt(11, .bold, relativeTo: .caption2) : .khaytMono(10.5, .medium, relativeTo: .caption2))
                        .khaytTracking(0.8)
                        .foregroundStyle(KhaytDesign.note)
                    ForEach(shown) { c in connector(c) }
                    if let message {
                        Text(message.text)
                            .font(.khayt(12.5, relativeTo: .footnote))
                            .foregroundStyle(message.ok ? KhaytDesign.done : KhaytDesign.late)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .card()
                .padding(outer)
            } else {
                // Something for `.task` to hang on, taking no room.
                Color.clear.frame(height: 0)
            }
        }
        .task { await load() }
        .sheet(item: $confirming) { p in
            ConnectorConfirmSheet(connector: p.connector) {
                ConnectorRules.confirm(p.connector)
                confirming = nil
                Task { await run(p.connector, p.action) }
            }
        }
    }

    private func actions(_ c: Connector) -> [Connector.Action] {
        c.actions.filter { $0.placement == place.placement }
    }

    private func fields(_ c: Connector) -> [Connector.Field] {
        c.fields.filter { $0.attach == place.placement }
    }

    @ViewBuilder
    private func connector(_ c: Connector) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(c.name)
                .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.ink)
            if let why = ConnectorRules.disabledReason(c) {
                Text(why)
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.attention)
            }
            ForEach(fields(c), id: \.key) { f in
                HStack(alignment: .firstTextBaseline) {
                    Text(f.label).font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
                    Spacer(minLength: 8)
                    Text(ConnectorRules.fieldValue(record, pluginId: c.id, key: f.key)
                            .map { ConnectorRules.display($0, field: f) } ?? "—")
                        .font(.khayt(13.5, .medium, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.ink)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            if !actions(c).isEmpty {
                // Buttons wrap rather than squeeze: a label is the developer's
                // words and may be long.
                VStack(spacing: 8) {
                    ForEach(actions(c)) { a in
                        Button { tap(c, a) } label: {
                            HStack(spacing: 6) {
                                if running == c.id + "/" + a.id { ProgressView().controlSize(.small) }
                                Label(a.label, systemImage: a.kind == "open" ? "safari" : "paperplane")
                                    .font(.khayt(13.5, .semibold, relativeTo: .subheadline))
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(c.isActive ? KhaytDesign.brand : KhaytDesign.note)
                            .background((c.isActive ? KhaytDesign.brand : KhaytDesign.note).opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .disabled(!c.isActive || running != nil)
                    }
                }
            }
        }
    }

    private func load() async {
        connectors = await api.connectors()
        let r = api.connectorRecords(place)
        switch place {
        case .order: record = r.order
        case .customer: record = r.customer
        }
    }

    private func tap(_ c: Connector, _ a: Connector.Action) {
        guard c.isActive else { return }
        message = nil
        if ConnectorRules.isConfirmed(c) {
            Task { await run(c, a) }
        } else {
            confirming = Pending(connector: c, action: a)
        }
    }

    private func run(_ c: Connector, _ a: Connector.Action) async {
        running = c.id + "/" + a.id
        defer { running = nil }
        switch await api.runConnector(c, action: a, at: place) {
        case .open(let url):
            // Safari, never inside the app.
            openURL(url)
        case .sent(let reply):
            message = (reply.isEmpty ? L10n.tr("connectors.sent")
                       : L10n.format("connectors.sent.reply", reply.joined(separator: "\n")), true)
        case .failed(let why):
            message = (why, false)
        }
    }
}

/// This iPhone's one-time confirmation: each host, and what goes there.
struct ConnectorConfirmSheet: View {
    let connector: Connector
    let onAllow: () -> Void

    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [(host: String, fields: [String])] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.format("connectors.confirm.body", connector.name))
                        .font(.khayt(14.5, relativeTo: .body))
                        .foregroundStyle(KhaytDesign.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    ConnectorConsentList(connector: connector, rows: rows)
                    Text(L10n.tr("connectors.confirm.footer"))
                        .font(.khayt(12, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.note)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: onAllow) {
                        Text(L10n.tr("connectors.confirm.allow"))
                            .font(.khayt(15, .semibold, relativeTo: .body))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(KhaytDesign.brand)
                }
                .padding(16)
            }
            .background(KhaytDesign.ground.ignoresSafeArea())
            .navigationTitle(L10n.tr("connectors.confirm.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) { dismiss() }
                }
            }
        }
        .task { rows = await api.connectorConsentRows(connector) }
    }
}

/// "These fields → this host", in plain words.
struct ConnectorConsentList: View {
    let connector: Connector
    let rows: [(host: String, fields: [String])]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                VStack(alignment: .leading, spacing: 4) {
                    Label(row.host, systemImage: "globe")
                        .font(.khaytMono(13, .medium, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.ink)
                        .environment(\.layoutDirection, .leftToRight)
                    Text(row.fields.isEmpty
                         ? L10n.tr("connectors.consent.nothing")
                         : ListFormatter.localizedString(byJoining: row.fields.map { ConnectorRules.fieldName($0, in: connector) }))
                        .font(.khayt(13, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 10).padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    if i < rows.count - 1 { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
                }
            }
        }
        .card()
    }
}

/// Settings ▸ Connectors: the book's connectors, read-only apart from this
/// phone's own keys. Adding and approving one is the Mac's.
struct ConnectorsSettingsSection: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @State private var connectors: [Connector] = []
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                if connectors.isEmpty {
                    Text(L10n.tr("connectors.list.empty"))
                        .font(.khayt(13.5, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.note)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(connectors.enumerated()), id: \.element.id) { i, c in
                    NavigationLink {
                        ConnectorSettingsPage(connector: c) { tick += 1 }
                    } label: {
                        ConnectorRow(connector: c, last: i == connectors.count - 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .card()
            Text(L10n.tr("connectors.list.footer"))
                .font(.khayt(12, relativeTo: .caption))
                .foregroundStyle(KhaytDesign.note)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
                .padding(.top, 9)
        }
        .task(id: tick) { connectors = await api.connectors() }
    }
}

struct ConnectorRow: View {
    let connector: Connector
    var last = true

    private var keysMissing: Bool { connector.secrets.contains { !ConnectorKeys.isSet(connector.id, $0.name) } }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(connector.name)
                        .font(.khayt(14.5, .medium, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.ink)
                        .lineLimit(1)
                    if connector.reviewed { ConnectorBadge(text: L10n.tr("connectors.badge.reviewed"), tone: KhaytDesign.done) }
                }
                Text([connector.publisher,
                      ConnectorRules.statusName(connector.status),
                      connector.secrets.isEmpty ? "" : L10n.tr(keysMissing ? "connectors.keys.missing" : "connectors.keys.set")]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(connector.status == .active && !keysMissing ? KhaytDesign.note : KhaytDesign.attention)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(KhaytDesign.note)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
        }
    }
}

struct ConnectorBadge: View {
    let text: String
    let tone: Color

    var body: some View {
        Text(text)
            .font(.khayt(10.5, .semibold, relativeTo: .caption2))
            .foregroundStyle(tone)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tone.opacity(0.12), in: Capsule())
    }
}

/// One connector: who made it, its status, this phone's keys, and what it
/// sends where.
struct ConnectorSettingsPage: View {
    let connector: Connector
    let onChanged: () -> Void

    @EnvironmentObject private var api: KhaytAPIClient
    @State private var rows: [(host: String, fields: [String])] = []
    @State private var editingKey: Connector.Secret?
    @State private var tick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connector.name)
                        .font(.khaytDisplay(22, .bold, relativeTo: .title2))
                        .foregroundStyle(KhaytDesign.ink)
                    Text(L10n.format("connectors.publisher", connector.publisher))
                        .font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
                    Text(L10n.format("connectors.version", connector.version))
                        .font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
                    HStack(spacing: 6) {
                        ConnectorBadge(text: ConnectorRules.statusName(connector.status),
                                       tone: connector.isActive ? KhaytDesign.done : KhaytDesign.attention)
                        if connector.reviewed { ConnectorBadge(text: L10n.tr("connectors.badge.reviewed"), tone: KhaytDesign.done) }
                    }
                    .padding(.top, 4)
                    if let why = ConnectorRules.disabledReason(connector) {
                        Text(why)
                            .font(.khayt(12.5, relativeTo: .footnote)).foregroundStyle(KhaytDesign.attention)
                            .padding(.top, 4)
                    }
                }

                if !connector.secrets.isEmpty {
                    eyebrow(L10n.tr("connectors.keys.title"))
                    VStack(spacing: 0) {
                        ForEach(Array(connector.secrets.enumerated()), id: \.element.name) { i, s in
                            keyRow(s, last: i == connector.secrets.count - 1)
                        }
                    }
                    .card()
                    .id(tick)
                    foot(L10n.tr("connectors.key.footer"))
                }

                if !connector.settings.isEmpty {
                    eyebrow(L10n.tr("connectors.settings.title"))
                    VStack(spacing: 0) {
                        ForEach(Array(connector.settings.enumerated()), id: \.element.key) { i, st in
                            settingRow(st, last: i == connector.settings.count - 1)
                        }
                    }
                    .card()
                    let missing = ConnectorRules.missingSettings(connector)
                    if !missing.isEmpty {
                        Text(L10n.format("connectors.settings.missing", ListFormatter.localizedString(byJoining: missing)))
                            .font(.khayt(12.5, relativeTo: .footnote))
                            .foregroundStyle(KhaytDesign.attention)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 2)
                            .padding(.top, 9)
                    }
                    foot(L10n.tr("connectors.settings.footer"))
                }

                eyebrow(L10n.tr("connectors.consent.title"))
                if !rows.isEmpty { ConnectorConsentList(connector: connector, rows: rows) }
                foot(L10n.tr(ConnectorRules.isConfirmed(connector) ? "connectors.consent.confirmed" : "connectors.consent.not_confirmed"))
            }
            .padding(16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(KhaytDesign.ground.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { rows = await api.connectorConsentRows(connector) }
        .sheet(item: Binding(get: { editingKey.map(KeyEdit.init) }, set: { if $0 == nil { editingKey = nil } })) { e in
            ConnectorKeySheet(connector: connector, secret: e.secret) {
                tick += 1
                onChanged()
            }
        }
    }

    private struct KeyEdit: Identifiable {
        let secret: Connector.Secret
        var id: String { secret.name }
    }

    private func keyRow(_ s: Connector.Secret, last: Bool) -> some View {
        let isSet = ConnectorKeys.isSet(connector.id, s.name)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.label).font(.khayt(14, relativeTo: .subheadline)).foregroundStyle(KhaytDesign.ink)
                Text(L10n.tr(isSet ? "connectors.key.set" : "connectors.key.not_set"))
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(isSet ? KhaytDesign.done : KhaytDesign.attention)
            }
            Spacer(minLength: 8)
            Button(L10n.tr(isSet ? "connectors.key.replace" : "connectors.key.enter")) { editingKey = s }
                .font(.khayt(13.5, .semibold, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.brand)
            if isSet {
                Button(role: .destructive) {
                    ConnectorKeys.delete(connector.id, s.name)
                    tick += 1
                    onChanged()
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(L10n.tr("connectors.key.delete"))
                .foregroundStyle(KhaytDesign.late)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
        }
    }

    /// A shop setting, read-only: its label and the value the Mac saved,
    /// drawn like a connector's own field on a job.
    private func settingRow(_ st: Connector.Setting, last: Bool) -> some View {
        let value = ConnectorRules.settingValue(st, in: connector)
        return HStack(alignment: .firstTextBaseline) {
            Text(st.label).font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
            Spacer(minLength: 8)
            Text(value ?? L10n.tr("connectors.settings.not_set"))
                .font(.khayt(13.5, .medium, relativeTo: .footnote))
                .foregroundStyle(value == nil ? (st.required ? KhaytDesign.attention : KhaytDesign.note) : KhaytDesign.ink)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.khayt(10.5, .bold, relativeTo: .caption2))
            .khaytTracking(1.05)
            .foregroundStyle(KhaytDesign.note)
            .padding(.horizontal, 2)
            .padding(.top, 22)
            .padding(.bottom, 9)
    }

    private func foot(_ text: String) -> some View {
        Text(text)
            .font(.khayt(12, relativeTo: .caption))
            .foregroundStyle(KhaytDesign.note)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .padding(.top, 9)
    }
}

/// Type or paste a key. What is stored is never shown back.
struct ConnectorKeySheet: View {
    let connector: Connector
    let secret: Connector.Secret
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(secret.label, text: $value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.khaytMono(14, .regular, relativeTo: .body))
                } footer: {
                    Text(L10n.tr("connectors.key.footer"))
                }
            }
            .navigationTitle(secret.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.save")) {
                        ConnectorKeys.set(connector.id, secret.name, value.trimmingCharacters(in: .whitespacesAndNewlines))
                        onSaved()
                        dismiss()
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
