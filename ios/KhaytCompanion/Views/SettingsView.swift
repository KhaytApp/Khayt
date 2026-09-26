import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var health: ConnectionHealth

    @State private var testResult: String?
    @State private var isTesting = false
    @State private var showCloudSignIn = false
    @State private var cloudSyncing = false
    @State private var testOK = false

    @State private var showConnection = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    connectionCard
                    eyebrow(L10n.tr("settings.holds"))
                    holdsCard
                    if let line = omittedLine {
                        foot(line)
                    }
                    eyebrow(L10n.tr("settings.language"))
                    languagePicker
                    eyebrow(L10n.tr("settings.notifications"))
                    notificationsCard
                    eyebrow(L10n.tr("cloud.title"))
                    cloudCard
                    eyebrow(L10n.tr("settings.connection"))
                    macCard
                    unpairButton
                    foot(L10n.tr("settings.unpair.footer"))
                    Link(L10n.tr("settings.docs"),
                         destination: URL(string: "https://github.com/khaytapp/Khayt/blob/main/docs/LAN_API.md")!)
                        .font(.khayt(13, .medium, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.note)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.top, 14)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .khaytScreen(title: L10n.tr("tab.settings"))
            .background(KhaytDesign.ground.ignoresSafeArea())
            .sheet(isPresented: $showCloudSignIn) { CloudSignInSheet() }
        }
    }

    // MARK: - The design's sections

    /// The connection, said once: green when the Mac is in reach, quiet when it
    /// is away and the phone has its book, red only when it has neither.
    private var connectionCard: some View {
        let tone = health.macInReach ? KhaytDesign.done : (api.holdsBook ? KhaytDesign.note : KhaytDesign.late)
        let headline: String
        if health.macInReach {
            headline = L10n.tr("settings.mac_in_reach")
        } else if let asOf = api.bookAsOf {
            headline = String(format: L10n.tr("settings.mac_away_since"), asOf.formatted(date: .omitted, time: .shortened))
        } else {
            headline = L10n.tr("settings.mac_away")
        }
        let shop = settings.shopLabel.isEmpty ? settings.host : settings.shopLabel
        let detail = [shop, L10n.tr(api.holdsBook ? "settings.from_book" : "connection.live_only")]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 4) {
            Text(headline)
                .font(.khayt(15.5, .semibold, relativeTo: .headline))
                .foregroundStyle(tone)
            Text(detail)
                .font(.khayt(13, relativeTo: .footnote))
                .foregroundStyle(KhaytDesign.note)
        }
        .padding(.vertical, 14).padding(.leading, 18).padding(.trailing, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KhaytDesign.surface)
        .overlay(alignment: .leading) { Rectangle().fill(tone).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    /// What this phone holds, collection by collection. A windowed one reads
    /// "200 / 3,140" in amber: the phone has the newest, not all.
    @ViewBuilder
    private var holdsCard: some View {
        let rows: [(String, String)] = [
            ("printLog", L10n.tr("tab.orders")), ("clients", L10n.tr("tab.clients")),
            ("inventory", L10n.tr("tab.inventory")), ("machines", L10n.tr("tab.machines")),
            ("waitingList", L10n.tr("intake.title")),
        ]
        if let scope = api.bookScope {
            let shown = rows.filter { scope.collections[$0.0] != nil }
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, row in
                    let held = scope.collections[row.0]!
                    settingRow(row.1, last: i == shown.count - 1) {
                        Text(held.whole || held.available == nil
                             ? held.sent.formatted()
                             : "\(held.sent.formatted()) / \(held.available!.formatted())")
                            .font(.khayt(14, .medium, relativeTo: .subheadline).monospacedDigit())
                            .foregroundStyle(held.whole ? KhaytDesign.ink : KhaytDesign.attention)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
            .card()
        } else {
            Text(L10n.tr("connection.live_only"))
                .font(.khayt(13, relativeTo: .footnote))
                .foregroundStyle(KhaytDesign.note)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
    }

    /// "Not sent: expenses, print files, products…" — the collections the
    /// book left on the Mac, named in the shop's language where the app knows
    /// the name, and plainly where it does not.
    private var omittedLine: String? {
        guard let omitted = api.bookScope?.omitted, !omitted.isEmpty else { return nil }
        let names = omitted.map { key -> String in
            let k = "book.collection.\(key)"
            let t = L10n.tr(k)
            if t != k { return t }
            return key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
        }
        return String(format: L10n.tr("settings.not_sent"), ListFormatter.localizedString(byJoining: names))
    }

    private var languagePicker: some View {
        HStack(spacing: 3) {
            ForEach(AppLanguage.allCases) { lang in
                let on = settings.appLanguage == lang
                Button { settings.appLanguage = lang } label: {
                    Text(lang.label)
                        .font(.khayt(13.5, .semibold, relativeTo: .subheadline))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(on ? KhaytDesign.ink : KhaytDesign.note)
                        .background(on ? KhaytDesign.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(KhaytDesign.sunk, in: RoundedRectangle(cornerRadius: 10))
    }

    private var notificationsCard: some View {
        VStack(spacing: 0) {
            toggleRow(L10n.tr("settings.notify.print_done"), $settings.notifyPrintDone)
            toggleRow(L10n.tr("settings.notify.queue"), $settings.notifyQueueChanges)
            toggleRow(L10n.tr("settings.notify.low_stock"), $settings.notifyLowStock)
            toggleRow(L10n.tr("settings.notify.overdue"), $settings.notifyOverdue)
            toggleRow(L10n.tr("settings.notify.connection"), $settings.notifyConnection)
            Button {
                Task { await CompanionNotifications.shared.requestAuthorizationIfNeeded() }
            } label: {
                settingRow(L10n.tr("settings.notifications.allow"), last: true) {
                    Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(KhaytDesign.note)
                }
            }
            .buttonStyle(.plain)
        }
        .card()
    }

    private func toggleRow(_ label: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .font(.khayt(14.5, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.ink)
        }
        .tint(KhaytDesign.done)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
    }

    /// The Mac's address and PIN, folded away: set once at pairing, and only
    /// opened when the shop's network changes.
    private var macCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation { showConnection.toggle() } } label: {
                settingRow(settings.displayURL.isEmpty ? L10n.tr("settings.host") : settings.displayURL,
                           last: !showConnection) {
                    Image(systemName: showConnection ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(KhaytDesign.note)
                }
            }
            .buttonStyle(.plain)
            if showConnection {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(L10n.tr("settings.shop_name"), text: $settings.shopLabel)
                    TextField(L10n.tr("settings.host"), text: $settings.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if let err = settings.hostValidationError {
                        Text(err).font(.khayt(12, relativeTo: .caption)).foregroundStyle(KhaytDesign.late)
                    }
                    Stepper(String(format: L10n.tr("settings.port"), settings.port), value: $settings.port, in: 1024...65535)
                    SecureField(L10n.tr("settings.pin"), text: $settings.pin)
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text(L10n.tr("settings.retest"))
                            Spacer()
                            if isTesting { ProgressView() }
                        }
                        .foregroundStyle(KhaytDesign.brand)
                        .frame(minHeight: 44)
                    }
                    if let testResult {
                        Text(testResult)
                            .font(.khayt(12.5, relativeTo: .footnote))
                            .foregroundStyle(testOK ? KhaytDesign.done : KhaytDesign.late)
                    }
                    Text(L10n.tr("settings.connection.footer"))
                        .font(.khayt(12, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.note)
                }
                .font(.khayt(15, relativeTo: .body))
                .textFieldStyle(.roundedBorder)
                .padding(16)
            }
        }
        .card()
    }

    private var unpairButton: some View {
        Button(role: .destructive) { settings.unpair() } label: {
            Text(L10n.tr("settings.unpair"))
                .font(.khayt(15.5, .semibold, relativeTo: .body))
                .foregroundStyle(KhaytDesign.late)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(KhaytDesign.late.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(KhaytDesign.late.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.top, 22)
    }

    // MARK: - Pieces

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.khayt(10.5, .bold, relativeTo: .caption2))
            .tracking(1.05)
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

    private func settingRow<V: View>(_ label: String, last: Bool = false, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.khayt(14.5, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.ink)
                .lineLimit(1)
            Spacer(minLength: 12)
            value()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
        }
    }

    /// Khayt Cloud: how this phone keeps in step when the Mac is elsewhere.
    @ViewBuilder
    private var cloudCard: some View {
        VStack(spacing: 0) {
            if let session = api.cloud {
                settingRow(L10n.tr("cloud.shop")) { value(session.shopId) }
                settingRow(L10n.tr("cloud.role")) { value(session.role) }
                if let mark = api.lastSync {
                    settingRow(L10n.tr("cloud.last_sync")) {
                        value(String(format: L10n.tr(mark.route == .cloud ? "cloud.via_cloud" : "cloud.via_mac"),
                                     mark.at.formatted(date: .omitted, time: .shortened)))
                    }
                }
                if let problem = api.cloudProblem {
                    Text(problem)
                        .font(.khayt(12.5, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.attention)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
                }
                if api.cloudNeedsSignIn {
                    Button { showCloudSignIn = true } label: {
                        settingRow(L10n.tr("cloud.sign_in_again")) {
                            Image(systemName: "chevron.forward").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(KhaytDesign.brand)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    Task {
                        cloudSyncing = true
                        await api.syncThroughCloud()
                        cloudSyncing = false
                    }
                } label: {
                    settingRow(L10n.tr("cloud.sync_now")) {
                        if cloudSyncing { ProgressView() }
                    }
                    .foregroundStyle(KhaytDesign.brand)
                }
                .buttonStyle(.plain)
                .disabled(cloudSyncing)
                Button { api.signOutOfCloud() } label: {
                    settingRow(L10n.tr("cloud.sign_out"), last: true) { EmptyView() }
                }
                .buttonStyle(.plain)
            } else {
                Button { showCloudSignIn = true } label: {
                    settingRow(L10n.tr("cloud.sign_in"), last: true) {
                        Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(KhaytDesign.note)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .card()
        foot(L10n.tr(api.cloud == nil ? "cloud.footer.off" : "cloud.footer.on"))
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.khayt(14, .medium, relativeTo: .subheadline))
            .foregroundStyle(KhaytDesign.note)
            .lineLimit(1)
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let status = try await api.validatePairing()
            testOK = true
            testResult = String(format: L10n.tr("pair.verify.ok"), status.queued)
            await health.refresh()
        } catch {
            testOK = false
            testResult = error.localizedDescription
        }
    }
}
