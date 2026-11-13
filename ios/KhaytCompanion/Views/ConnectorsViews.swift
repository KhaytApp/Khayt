import SwiftUI
import KhaytCore

/// A job's or a customer's connectors: each active one's buttons for this
/// place, and its own fields — editable for an active connector on a phone
/// that may edit, read-only otherwise. Drawn by Khayt from the manifest —
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
    @State private var editing: FieldEdit?

    struct FieldEdit: Identifiable {
        let connector: Connector
        let field: Connector.Field
        var id: String { connector.id + "/" + field.key }
    }

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
        // Again whenever a sync lands: a connector the Mac added or turned off.
        .task(id: api.syncLanded) { await load() }
        .sheet(item: $confirming) { p in
            ConnectorConfirmSheet(connector: p.connector) {
                ConnectorRules.confirm(p.connector)
                confirming = nil
                Task { await run(p.connector, p.action) }
            }
        }
        .sheet(item: $editing) { e in
            ConnectorFieldSheet(connector: e.connector, field: e.field, place: place,
                                value: ConnectorRules.fieldValue(record, pluginId: e.connector.id, key: e.field.key)) {
                Task { await load() }
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
                if ConnectorRules.canEditFields(c, canWrite: api.canWrite) {
                    Button { editing = FieldEdit(connector: c, field: f) } label: {
                        fieldRow(c, f, editable: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(L10n.tr("connectors.field.edit"))
                } else {
                    fieldRow(c, f, editable: false)
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

    private func fieldRow(_ c: Connector, _ f: Connector.Field, editable: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(f.label).font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
            Spacer(minLength: 8)
            Text(ConnectorRules.fieldValue(record, pluginId: c.id, key: f.key)
                    .map { ConnectorRules.display($0, field: f) } ?? "—")
                .font(.khayt(13.5, .medium, relativeTo: .footnote))
                .foregroundStyle(KhaytDesign.ink)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
            if editable {
                Image(systemName: "pencil")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KhaytDesign.brand)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: editable ? 32 : nil)
        .contentShape(Rectangle())
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
        case .sent(let reply, let saved):
            let said = reply.isEmpty ? L10n.tr("connectors.sent")
                : L10n.format("connectors.sent.reply", reply.joined(separator: "\n"))
            message = (saved ? said : said + "\n" + L10n.tr("connectors.reply.not_saved"), saved)
            // The reply's fields are on the record now: show them.
            if saved, !reply.isEmpty { await load() }
        case .simulated(let hosts, let reply):
            var said = L10n.format("connectors.sample.simulated", hosts.joined(separator: ", "))
            if !reply.isEmpty { said += "\n" + reply.joined(separator: "\n") }
            message = (said, true)
            if !reply.isEmpty { await load() }
        case .failed(let why):
            message = (why, false)
        }
    }
}

/// Type one of a connector's own fields on a job or a customer, by its type:
/// text, a number, yes/no, a choice from its options, or a date. Saved
/// through `KhaytAPIClient.setConnectorFields`, checked as the Mac checks it.
struct ConnectorFieldSheet: View {
    let connector: Connector
    let field: Connector.Field
    let place: KhaytAPIClient.ConnectorPlace
    let value: JSONValue?
    let onSaved: () -> Void

    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var flag = false
    @State private var choice = ""
    @State private var day = Date()
    @State private var saving = false
    @State private var failure: String?

    /// What Save would write; nil is "no value" (the key is cleared).
    private var draft: JSONValue? {
        switch field.type {
        case "bool": return .bool(flag)
        case "enum": return choice.isEmpty ? nil : .string(choice)
        case "date": return .string(BookWriter.localDay(day))
        case "number":
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            if let n = Double(t) { return .number(n) }
            let f = NumberFormatter()
            f.locale = L10n.locale
            f.numberStyle = .decimal
            return f.number(from: t).map { .number($0.doubleValue) } ?? .string(t)
        default:
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : .string(t)
        }
    }

    /// Typed, but not something the field takes (a number that isn't one),
    /// by lib's own `coerceField`.
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    editor
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let failure { Text(failure).foregroundStyle(KhaytDesign.late) }
                        Text(L10n.format("connectors.field.footer", connector.name))
                    }
                }
                if value != nil {
                    Section {
                        Button(L10n.tr("connectors.field.clear"), role: .destructive) { save(.null) }
                            .disabled(saving)
                    }
                }
            }
            .navigationTitle(field.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.save")) { save(draft ?? .null) }
                        .disabled(saving || invalid)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear(perform: fill)
        .task(id: draft) {
            guard let d = draft else { invalid = false; return }
            invalid = await api.coerceConnectorField(field, d, in: connector) == nil
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch field.type {
        case "bool":
            Toggle(field.label, isOn: $flag)
        case "enum":
            Picker(field.label, selection: $choice) {
                Text("—").tag("")
                ForEach(field.options.sorted { $0.value < $1.value }, id: \.key) { o in
                    Text(o.value).tag(o.key)
                }
            }
        case "date":
            DatePicker(field.label, selection: $day, displayedComponents: .date)
                .environment(\.calendar, Calendar(identifier: .gregorian))
        case "number":
            TextField(field.label, text: $text)
                .keyboardType(.decimalPad)
        default:
            TextField(field.label, text: $text, axis: .vertical)
                .lineLimit(1...4)
        }
    }

    private func fill() {
        switch value {
        case .string(let s)?:
            text = s
            choice = field.options[s] != nil ? s : ""
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            if field.type == "date", let d = f.date(from: String(s.prefix(10))) { day = d }
        case .number(let n)?:
            text = n.formatted(.number.locale(L10n.locale).grouping(.never))
        case .bool(let b)?:
            flag = b
        default:
            break
        }
    }

    private func save(_ v: JSONValue) {
        saving = true
        failure = nil
        Task {
            defer { saving = false }
            do {
                try await api.setConnectorFields(connector, at: place, values: [field.key: v])
                onSaved()
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
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
///
/// WITH NO CONNECTOR IN THE BOOK IT DRAWS NOTHING, heading included: the
/// Mac and desktop ship connectors switched off, and no build may show the
/// feature before khaytapp.com/privacy describes it. From launch day
/// (`ConnectorLaunch.launched`), a phone that reads its book from the cloud
/// and has never read the Mac's settings shows one line instead, saying the
/// Mac's connectors arrive once Khayt opens near it.
struct ConnectorsSettingsSection<Heading: View>: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @State private var connectors: [Connector] = []
    @State private var loaded = false
    @State private var tick = 0
    /// Connectors whose last automatic update this load is the first to show.
    @State private var freshUpdates: Set<String> = []
    @ViewBuilder var heading: () -> Heading

    /// Reloaded when the list changes here, whenever a sync lands, and when
    /// a book arrives or goes.
    private struct Reload: Equatable {
        let tick: Int
        let synced: [Date]
        let holdsBook: Bool
    }

    var body: some View {
        Group {
            if !connectors.isEmpty {
                list
            } else if loaded, ConnectorLaunch.showsMacHint(cloud: api.cloud != nil, macSettingsAt: api.macSettingsAt,
                                                           connectorsEmpty: true, holdsBook: api.holdsBook) {
                macHint
            } else {
                // Something for `.task` to hang on, taking no room. Without it
                // the Group is EMPTY until the list loads, SwiftUI never runs
                // `.task` on an empty Group, and so the list never loads: the
                // section drew nothing on every phone (Nov 9, TestFlight
                // 202611091812). `ConnectorsCard` hangs its task the same way.
                Color.clear.frame(height: 0)
            }
        }
        .task(id: Reload(tick: tick, synced: api.syncLanded, holdsBook: api.holdsBook)) {
            let list = await api.connectors()
            // "Updated to …" once per update: kept on screen for this load,
            // and remembered so the next one does not show it again.
            freshUpdates = Set(list.filter { ConnectorUpdateSeen.firstSight($0) }.map(\.id))
                .union(freshUpdates.filter { id in list.contains { $0.id == id && $0.updatedAt != nil } })
            connectors = list
            loaded = true
        }
    }

    /// One line where the list would be, for a phone that reads its book
    /// from the cloud and has not yet met its Mac (`ConnectorLaunch.showsMacHint`).
    private var macHint: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading()
            Text(L10n.tr("connectors.settings.hint_mac"))
                .font(.khayt(12, relativeTo: .caption))
                .foregroundStyle(KhaytDesign.note)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading()
            let waiting = ConnectorRules.waitingOnMac(connectors)
            if waiting > 0 {
                // Read-only: the OK is given on the Mac, never here.
                ConnectorUpdateBadge(label: L10n.format("connectors.waiting_count", waiting), tone: .pending)
                    .padding(.bottom, 8)
            }
            VStack(spacing: 0) {
                ForEach(Array(connectors.enumerated()), id: \.element.id) { i, c in
                    NavigationLink {
                        ConnectorSettingsPage(connector: c) { tick += 1 }
                    } label: {
                        ConnectorRow(connector: c, last: i == connectors.count - 1,
                                     notes: ConnectorRules.updateNotes(c, showUpdated: freshUpdates.contains(c.id)),
                                     badge: ConnectorRules.updateBadge(c, showUpdated: freshUpdates.contains(c.id)))
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
    }
}

struct ConnectorRow: View {
    let connector: Connector
    var last = true
    /// Update notes (`ConnectorRules.updateNotes`), one line each.
    var notes: [String] = []
    /// The row's update badge (`ConnectorRules.updateBadge`).
    var badge: (label: String, tone: ConnectorRules.BadgeTone)? = nil

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
                // The update state, on its own line under the name (frame
                // 21:729 sets it beside the name; with "Reviewed" there too a
                // phone would cut the name short).
                if let badge { ConnectorUpdateBadge(label: badge.label, tone: badge.tone) }
                Text([connector.publisher,
                      ConnectorRules.statusName(connector.status),
                      connector.secrets.isEmpty ? "" : L10n.tr(keysMissing ? "connectors.keys.missing" : "connectors.keys.set")]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(connector.status == .active && !keysMissing ? KhaytDesign.note : KhaytDesign.attention)
                    .lineLimit(2)
                if connector.status == .revoked, let why = ConnectorRules.disabledReason(connector) {
                    Text(why)
                        .font(.khayt(12, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .font(.khayt(12, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                .tapTarget()
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

/// Which automatic connector updates this phone has already announced, by
/// connector id and `updatedAt`: the note shows once per update.
enum ConnectorUpdateSeen {
    static let key = "khayt.connectorUpdatesSeen"

    /// True the first time this update is seen (and remembers it).
    static func firstSight(_ c: Connector, defaults: UserDefaults = .standard) -> Bool {
        guard let at = c.updatedAt else { return false }
        let mark = c.id + "@" + at
        var seen = defaults.stringArray(forKey: key) ?? []
        if seen.contains(mark) { return false }
        seen.removeAll { $0.hasPrefix(c.id + "@") }
        seen.append(mark)
        defaults.set(Array(seen.suffix(100)), forKey: key)
        return true
    }
}

/// A connector's update state as a chip (frame 21:729): steel for "waiting
/// on the Mac", amber-brown for paused, quiet for a version this build cannot
/// read, done for the one-time "Updated to". The words carry the meaning;
/// the colour only repeats it.
struct ConnectorUpdateBadge: View {
    let label: String
    let tone: ConnectorRules.BadgeTone

    private var ink: Color {
        switch tone {
        case .attention: return KhaytDesign.attention
        case .pending: return KhaytDesign.pending
        case .neutral: return KhaytDesign.note
        case .done: return KhaytDesign.done
        }
    }
    private var wash: Color {
        switch tone {
        case .attention: return KhaytDesign.warnSoft
        case .pending: return KhaytDesign.pendingWash
        case .neutral: return KhaytDesign.sunk
        case .done: return KhaytDesign.okSoft
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(ink).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(label)
                .font(.khayt(11.5, .semibold, relativeTo: .caption))
                .foregroundStyle(tone == .pending ? KhaytDesign.ink : ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(wash, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
