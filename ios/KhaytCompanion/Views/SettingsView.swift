import SwiftUI
import UIKit

/// Settings, in four groups (This phone, Shop, Connected, About), each row a
/// page of its own (`SettingsRoute`). A search on top finds a row by its
/// label or by what its page holds. Nothing here is saved by a button: every
/// control takes effect as it changes.
struct SettingsView: View {
    /// A sheet (from Home's gear) draws Close; the regular-width tab does not.
    var showsClose = false

    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var health: ConnectionHealth
    @Environment(\.dismiss) private var dismiss

    @State private var path: [SettingsRoute] = []
    @State private var query = ""
    @State private var connectors: [Connector] = []
    @State private var connectorsLoaded = false
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack(path: $path) {
            SettingsPage {
                KhaytSearchField(text: $query, prompt: L10n.tr("settings.search"))
                    .padding(.bottom, 4)
                if SettingsSearch.fold(query).isEmpty {
                    ForEach(SettingsRoute.Group.allCases, id: \.self) { group in
                        let rows = SettingsRoute.rows(in: group, showsConnectors: showsConnectors)
                        if !rows.isEmpty {
                            SettingsPieces.eyebrow(L10n.tr(group.titleKey))
                            card(rows)
                        }
                    }
                } else {
                    searchResults
                }
                versionLine
            }
            .scrollDismissesKeyboard(.interactively)
            .khaytScreen(title: L10n.tr("tab.settings"))
            .background(KhaytDesign.ground.ignoresSafeArea())
            .toolbar {
                if showsClose {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.tr("common.close")) { dismiss() }
                            .foregroundStyle(KhaytDesign.brand)
                    }
                }
            }
            .navigationDestination(for: SettingsRoute.self) { page(for: $0) }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsSheet() }
            .task(id: ConnectorsReload(synced: api.syncLanded, holdsBook: api.holdsBook)) {
                connectors = await api.connectors()
                connectorsLoaded = true
            }
            #if DEBUG
            .onAppear {
                // `-KhaytSettingsPage mac`: straight to a page, for screenshots.
                if path.isEmpty, let v = UserDefaults.standard.string(forKey: "KhaytSettingsPage"),
                   let route = SettingsRoute(rawValue: v) {
                    path = [route]
                }
            }
            #endif
        }
    }

    private struct ConnectorsReload: Equatable {
        let synced: [Date]
        let holdsBook: Bool
    }

    /// The Connectors row is there when its page would draw something: a
    /// connector, or the one line saying they come from the Mac.
    private var showsConnectors: Bool {
        guard api.holdsBook else { return false }
        return !connectors.isEmpty
            || (connectorsLoaded && ConnectorLaunch.showsMacHint(cloud: api.cloud != nil, macSettingsAt: api.macSettingsAt,
                                                                  connectorsEmpty: true, holdsBook: api.holdsBook))
    }

    // MARK: - Rows

    private func card(_ rows: [SettingsRoute]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element) { i, route in
                link(route, last: i == rows.count - 1)
            }
        }
        .card()
    }

    @ViewBuilder
    private func link(_ route: SettingsRoute, last: Bool) -> some View {
        let row = SettingsRow(title: L10n.tr(route.titleKey), subtitle: subtitle(route), state: state(route),
                              external: route.destination != .page, last: last)
        switch route.destination {
        case .page:
            NavigationLink(value: route) { row }.buttonStyle(.plain)
        case .link(let url):
            Link(destination: url) { row }.buttonStyle(.plain)
        }
    }

    private var searchResults: some View {
        let shown = SettingsRoute.allCases.filter { $0 != .connectors || showsConnectors }
        let found = SettingsSearch.matches(query, in: shown.map { (id: $0, labels: $0.searchLabels(extra: extraLabels($0))) })
        return Group {
            if found.isEmpty {
                Text(L10n.format("settings.search.none", query.trimmingCharacters(in: .whitespacesAndNewlines)))
                    .font(.khayt(13, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2).padding(.top, 18)
            } else {
                card(found).padding(.top, 14)
            }
        }
    }

    /// What only the screen knows: the shop's name, the language names.
    private func extraLabels(_ route: SettingsRoute) -> [String] {
        switch route {
        case .shop: return [settings.shopLabel, settings.host]
        case .appearance: return AppLanguage.allCases.map(\.label)
        case .connectors: return connectors.map(\.name)
        default: return []
        }
    }

    private func subtitle(_ route: SettingsRoute) -> String? {
        switch route {
        case .appearance: return settings.appLanguage.label
        case .notifications:
            let on = [(settings.notifyPrintDone, "settings.notify.print_done"), (settings.liveActivities, "settings.live_activities"),
                      (settings.notifyQueueChanges, "settings.notify.queue"), (settings.notifyLowStock, "settings.notify.low_stock"),
                      (settings.notifyOverdue, "settings.notify.overdue"), (settings.notifyConnection, "settings.notify.connection")]
                .filter(\.0).map { L10n.tr($0.1) }
            return on.isEmpty ? L10n.tr("state.off") : ListFormatter.localizedString(byJoining: on)
        case .privacy:
            return ActiveCountSender.ready ? nil : L10n.tr("settings.privacy_policy")
        case .shop:
            return [settings.shopLabel, L10n.tr("settings.shop.readonly")].filter { !$0.isEmpty }.joined(separator: " · ")
        case .mac:
            return settings.macAddress
        case .cloud: return L10n.tr("settings.cloud.sub")
        case .connectors:
            let names = connectors.map(\.name)
            return names.isEmpty ? nil : ListFormatter.localizedString(byJoining: names)
        case .help: return "khaytapp.com"
        case .diagnostics: return L10n.tr("settings.diag.sub")
        }
    }

    private func state(_ route: SettingsRoute) -> SettingsState? {
        switch route {
        case .privacy:
            return ActiveCountSender.ready ? (settings.countInstall ? .on : .off) : nil
        case .mac:
            return SettingsState.mac(paired: settings.isPaired && (settings.isConfigured || settings.isSampleShop),
                                     inReach: health.macInReach || settings.isSampleShop)
        case .cloud:
            return SettingsState.cloud(signedIn: api.cloud != nil, needsSignIn: api.cloudNeedsSignIn)
        case .connectors:
            return connectors.isEmpty ? nil : .count(connectors.count)
        default: return nil
        }
    }

    /// The app's version. A long press opens Diagnostics' sync sheet, as before;
    /// the Diagnostics row is the way most people get there.
    private var versionLine: some View {
        Text(L10n.format("settings.version", DiagnosticsSheet.version, DiagnosticsSheet.build))
            .font(.khayt(11.5, relativeTo: .caption2))
            .foregroundStyle(KhaytDesign.note)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .padding(.horizontal, 2).padding(.top, 12)
            .contentShape(Rectangle())
            .onLongPressGesture { showDiagnostics = true }
            .accessibilityAction(named: L10n.tr("diag.title")) { showDiagnostics = true }
    }

    // MARK: - Pages

    @ViewBuilder
    private func page(for route: SettingsRoute) -> some View {
        switch route {
        case .appearance: SettingsAppearancePage()
        case .notifications: SettingsNotificationsPage()
        case .privacy: SettingsPrivacyPage()
        case .shop: SettingsShopPage()
        case .mac: SettingsMacPage()
        case .cloud: SettingsCloudPage()
        case .connectors:
            SettingsPage { ConnectorsSettingsSection { EmptyView() }.padding(.top, 8) }
                .settingsPageTitle(L10n.tr("connectors.title"))
        case .help: EmptyView()   // a link, never pushed
        case .diagnostics: SettingsDiagnosticsPage()
        }
    }
}

extension ConnectionSettings {
    /// The Mac's address as a row says it, or nothing: `displayURL` draws
    /// "—" for a phone with no address (the sample shop, a cloud-only phone).
    var macAddress: String? {
        let a = displayURL
        return a.isEmpty || a == "—" ? nil : a
    }
}

// MARK: - States

/// A row's state, in the same words and colours everywhere: Connected / On /
/// Paired green, Needs sign-in steel, Off and Away neutral. Amber is never a
/// setting's state.
enum SettingsState: Equatable {
    case paired, away, notPaired
    case signedIn, needsSignIn
    case on, off
    case count(Int)

    enum Tone { case good, waiting, neutral }

    static func mac(paired: Bool, inReach: Bool) -> SettingsState {
        !paired ? .notPaired : (inReach ? .paired : .away)
    }

    static func cloud(signedIn: Bool, needsSignIn: Bool) -> SettingsState {
        needsSignIn ? .needsSignIn : (signedIn ? .signedIn : .off)
    }

    var label: String {
        switch self {
        case .paired: return L10n.tr("state.paired")
        case .away: return L10n.tr("state.away")
        case .notPaired: return L10n.tr("state.not_paired")
        case .signedIn: return L10n.tr("state.signed_in")
        case .needsSignIn: return L10n.tr("state.needs_sign_in")
        case .on: return L10n.tr("state.on")
        case .off: return L10n.tr("state.off")
        case .count(let n): return n.formatted(.number.locale(L10n.locale))
        }
    }

    var tone: Tone {
        switch self {
        case .paired, .signedIn, .on: return .good
        case .needsSignIn: return .waiting
        case .away, .notPaired, .off, .count: return .neutral
        }
    }
}

struct SettingsStateChip: View {
    let state: SettingsState

    /// Waiting on someone else: steel (the design's `pending`).
    static let steel = Color(light: 0x5E6C84, dark: 0xA9B8CF)
    static let steelWash = Color(light: 0xEDF0F4, dark: 0x3A4658)

    private var colors: (text: Color, dot: Color, wash: Color) {
        switch state.tone {
        case .good: return (KhaytDesign.done, KhaytDesign.done, KhaytDesign.done.opacity(0.14))
        case .waiting: return (Self.steel, Self.steel, Self.steelWash)
        case .neutral: return (KhaytDesign.note, KhaytDesign.note.opacity(0.7), KhaytDesign.sunk)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if case .count = state {} else {
                Circle().fill(colors.dot).frame(width: 6, height: 6)
            }
            Text(state.label)
                .font(.khayt(12, .semibold, relativeTo: .caption))
                .lineLimit(1)
        }
        .foregroundStyle(colors.text)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(colors.wash, in: Capsule())
        .fixedSize()
    }
}

// MARK: - Pieces

/// One row of the groups: label, a line under it, a state chip, a chevron.
struct SettingsRow: View {
    let title: String
    var subtitle: String?
    var state: SettingsState?
    var external = false
    var last = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.khayt(15.5, .semibold, relativeTo: .body))
                    .foregroundStyle(KhaytDesign.ink)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.khayt(12.5, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.note)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let state { SettingsStateChip(state: state) }
            Image(systemName: external ? "arrow.up.forward" : "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(KhaytDesign.note)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A Settings page: the ground, the 640 pt reading width (a toggle a full
/// 7.6-inch width from its label, iPhone Duo unfolded, is hard to pair with it).
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(KhaytDesign.ground.ignoresSafeArea())
    }
}

extension View {
    func settingsPageTitle(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .background(KhaytDesign.ground.ignoresSafeArea())
    }
}

enum SettingsPieces {
    static func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.khayt(10.5, .bold, relativeTo: .caption2))
            .khaytTracking(1.05)
            .foregroundStyle(KhaytDesign.note)
            .padding(.horizontal, 2)
            .padding(.top, 20)
            .padding(.bottom, 9)
    }

    static func foot(_ text: String) -> some View {
        Text(text)
            .font(.khayt(12, relativeTo: .caption))
            .foregroundStyle(KhaytDesign.note)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .padding(.top, 9)
    }

    static func row<V: View>(_ label: String, last: Bool = false, @ViewBuilder value: () -> V) -> some View {
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

    static func toggle(_ label: String, _ isOn: Binding<Bool>, last: Bool = false) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .font(.khayt(14.5, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.ink)
        }
        .tint(KhaytDesign.done)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
        }
    }

    static func value(_ text: String) -> some View {
        Text(text)
            .font(.khayt(14, .medium, relativeTo: .subheadline))
            .foregroundStyle(KhaytDesign.note)
            .lineLimit(1)
    }

    static var chevron: some View {
        Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(KhaytDesign.note)
    }
}

// MARK: - This phone

struct SettingsAppearancePage: View {
    @EnvironmentObject private var settings: ConnectionSettings

    var body: some View {
        SettingsPage {
            SettingsPieces.eyebrow(L10n.tr("settings.language"))
            // One row that opens a menu, not a segmented strip: the strip was
            // three choices (System, English, Arabic) and held them; at ten
            // (#2181) every name broke across three lines.
            Menu {
                Picker(selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.label).tag(lang)
                    }
                } label: { EmptyView() }
            } label: {
                SettingsPieces.row(settings.appLanguage.label, last: true) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(KhaytDesign.note)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("settings.language"))
            .accessibilityValue(settings.appLanguage.label)
            .card()
        }
        .settingsPageTitle(L10n.tr("settings.appearance"))
    }
}

struct SettingsNotificationsPage: View {
    @EnvironmentObject private var settings: ConnectionSettings

    var body: some View {
        SettingsPage {
            VStack(spacing: 0) {
                SettingsPieces.toggle(L10n.tr("settings.notify.print_done"), $settings.notifyPrintDone)
                SettingsPieces.toggle(L10n.tr("settings.live_activities"), $settings.liveActivities)
                SettingsPieces.toggle(L10n.tr("settings.notify.queue"), $settings.notifyQueueChanges)
                SettingsPieces.toggle(L10n.tr("settings.notify.low_stock"), $settings.notifyLowStock)
                SettingsPieces.toggle(L10n.tr("settings.notify.overdue"), $settings.notifyOverdue)
                SettingsPieces.toggle(L10n.tr("settings.notify.connection"), $settings.notifyConnection)
                Button {
                    Task { await CompanionNotifications.shared.requestAuthorizationIfNeeded() }
                } label: {
                    SettingsPieces.row(L10n.tr("settings.notifications.allow"), last: true) { SettingsPieces.chevron }
                }
                .buttonStyle(.plain)
            }
            .card()
            .padding(.top, 12)
            if settings.liveActivities {
                // The Mac sends print progress for a closed app only when
                // its owner opts in there, off by default (matches /privacy).
                SettingsPieces.foot(L10n.tr("settings.live_activities.mac"))
            }
        }
        .settingsPageTitle(L10n.tr("settings.notifications"))
    }
}

struct SettingsPrivacyPage: View {
    @EnvironmentObject private var settings: ConnectionSettings

    var body: some View {
        SettingsPage {
            if ActiveCountSender.ready {
                VStack(spacing: 0) {
                    SettingsPieces.toggle(L10n.tr("settings.count_install"), $settings.countInstall, last: true)
                }
                .card()
                .padding(.top, 12)
                SettingsPieces.foot(L10n.tr("settings.count_install.hint"))
            }
            // One page for both languages: each section has its Arabic beside it.
            Link(destination: SettingsRoute.privacyURL) {
                SettingsPieces.row(L10n.tr("settings.privacy_policy"), last: true) {
                    Image(systemName: "arrow.up.forward").font(.caption.weight(.semibold)).foregroundStyle(KhaytDesign.note)
                }
            }
            .buttonStyle(.plain)
            .card()
            .padding(.top, 16)
        }
        .settingsPageTitle(L10n.tr("settings.privacy"))
    }
}

// MARK: - Shop

struct SettingsShopPage: View {
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var health: ConnectionHealth

    var body: some View {
        SettingsPage {
            connectionCard.padding(.top, 12)
            SettingsPieces.foot(L10n.tr("settings.shop.readonly"))
        }
        .settingsPageTitle(L10n.tr("settings.shop_details"))
    }

    /// The connection, said once: green when the Mac is in reach, quiet when it
    /// is away and the phone has its book, red only when it has neither.
    private var connectionCard: some View {
        let tone = health.macInReach ? KhaytDesign.done : (api.holdsBook ? KhaytDesign.note : KhaytDesign.late)
        let headline: String
        if health.macInReach {
            headline = L10n.tr("settings.mac_in_reach")
        } else if let asOf = api.bookAsOf {
            headline = L10n.format("settings.mac_away_since", asOf.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)))
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
}

// MARK: - Connected

struct SettingsMacPage: View {
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var health: ConnectionHealth

    @State private var testResult: String?
    @State private var isTesting = false
    @State private var testOK = false
    @State private var showConnection = false
    @State private var securing = false
    @State private var secureAnswer: String?
    @State private var confirmUnpair = false

    var body: some View {
        SettingsPage {
            macCard.padding(.top, 12)
            if api.lastEnrolment == .closed || api.lastEnrolment == .locked, settings.device == nil, settings.isPaired, !settings.isSampleShop {
                secureCard
            }
            unpairButton
            SettingsPieces.foot(L10n.tr("settings.unpair.footer"))
        }
        .settingsPageTitle(L10n.tr("settings.phones_wifi"))
        .confirmationDialog(L10n.tr("settings.unpair"), isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button(L10n.tr("settings.unpair"), role: .destructive) { api.unpair() }
        } message: {
            Text(L10n.tr("settings.unpair.footer"))
        }
    }

    /// The Mac's address and PIN, folded away: set once at pairing, and only
    /// opened when the shop's network changes.
    private var macCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation { showConnection.toggle() } } label: {
                SettingsPieces.row(settings.macAddress ?? L10n.tr("settings.host"),
                                   last: !showConnection) {
                    SettingsStateChip(state: SettingsState.mac(paired: settings.isPaired && (settings.isConfigured || settings.isSampleShop),
                                                               inReach: health.macInReach || settings.isSampleShop))
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
                    // A port is part of an address, written as the IP beside it is: Western digits.
                    Stepper(String(format: L10n.tr("settings.port"), locale: Locale(identifier: "en_US_POSIX"), settings.port), value: $settings.port, in: 1024...65535)
                    SecureField(L10n.tr("settings.pin"), text: $settings.pin)
                        .pinEntry()
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

    /// A phone that still signs in with the owner PIN, because the Mac's
    /// "Pair a phone" window was shut when it tried: how to give it a key.
    private var secureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.tr("settings.secure.body"), systemImage: "lock.open")
                .font(.khayt(13.5, relativeTo: .footnote)).foregroundStyle(KhaytDesign.ink)
            if let secureAnswer {
                Text(secureAnswer).font(.khayt(12.5, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
            }
            Button {
                Task {
                    securing = true
                    defer { securing = false }
                    switch await api.secureThisPhone(name: settings.nameToSend) {
                    case .enrolled: secureAnswer = L10n.tr("settings.secure.done")
                    case .closed: secureAnswer = L10n.tr("settings.secure.closed")
                    case .locked: secureAnswer = L10n.tr("pair.window_locked")
                    case .unsupported, .failed: secureAnswer = L10n.tr("settings.secure.failed")
                    }
                }
            } label: {
                Text(L10n.tr("settings.secure.button")).font(.khayt(15, .semibold, relativeTo: .body))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered).tint(KhaytDesign.brand)
            .disabled(securing)
        }
        .padding(14).card().padding(.top, 10)
    }

    private var unpairButton: some View {
        Button(role: .destructive) { confirmUnpair = true } label: {
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

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let status = try await api.validatePairing()
            testOK = true
            testResult = L10n.format("pair.verify.ok", status.queued)
            await health.refresh()
        } catch {
            testOK = false
            testResult = error.localizedDescription
        }
    }
}

/// Khayt Cloud: how this phone keeps in step when the Mac is elsewhere.
struct SettingsCloudPage: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @State private var showCloudSignIn = false
    @State private var cloudSyncing = false

    var body: some View {
        SettingsPage {
            VStack(spacing: 0) {
                if let session = api.cloud {
                    SettingsPieces.row(L10n.tr("cloud.shop")) { SettingsPieces.value(session.shopId) }
                    SettingsPieces.row(L10n.tr("cloud.role")) { SettingsPieces.value(session.role) }
                    if let mark = api.lastSync {
                        SettingsPieces.row(L10n.tr("cloud.last_sync")) {
                            SettingsPieces.value(L10n.format(mark.route == .cloud ? "cloud.via_cloud" : "cloud.via_mac", mark.at.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))))
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
                            SettingsPieces.row(L10n.tr("cloud.sign_in_again")) {
                                SettingsStateChip(state: .needsSignIn)
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
                        SettingsPieces.row(L10n.tr("cloud.sync_now")) {
                            if cloudSyncing { ProgressView() }
                        }
                        .foregroundStyle(KhaytDesign.brand)
                    }
                    .buttonStyle(.plain)
                    .disabled(cloudSyncing)
                    Button { api.signOutOfCloud() } label: {
                        SettingsPieces.row(L10n.tr("cloud.sign_out"), last: true) { EmptyView() }
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { showCloudSignIn = true } label: {
                        SettingsPieces.row(L10n.tr("cloud.sign_in"), last: true) { SettingsPieces.chevron }
                    }
                    .buttonStyle(.plain)
                }
            }
            .card()
            .padding(.top, 12)
            SettingsPieces.foot(L10n.tr(api.cloud == nil ? "cloud.footer.off" : "cloud.footer.on"))
        }
        .settingsPageTitle(L10n.tr("cloud.title"))
        .sheet(isPresented: $showCloudSignIn) { CloudSignInSheet() }
    }
}

// MARK: - About

/// What this phone holds, collection by collection, and the way to what its
/// syncs last did (`DiagnosticsSheet`).
struct SettingsDiagnosticsPage: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @State private var showSheet = false

    var body: some View {
        SettingsPage {
            SettingsPieces.eyebrow(L10n.tr("settings.holds"))
            holdsCard
            if let line = omittedLine {
                SettingsPieces.foot(line)
            }
            Button { showSheet = true } label: {
                SettingsPieces.row(L10n.tr("settings.diag.syncs"), last: true) { SettingsPieces.chevron }
            }
            .buttonStyle(.plain)
            .card()
            .padding(.top, 20)
        }
        .settingsPageTitle(L10n.tr("diag.title"))
        .sheet(isPresented: $showSheet) { DiagnosticsSheet() }
    }

    /// A windowed collection reads "200 / 3,140" in the attention colour:
    /// the phone has the newest, not all.
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
                    SettingsPieces.row(row.1, last: i == shown.count - 1) {
                        Text(held.whole || held.available == nil
                             ? held.sent.formatted(.number.locale(L10n.locale))
                             : "\(held.sent.formatted(.number.locale(L10n.locale))) / \(held.available!.formatted(.number.locale(L10n.locale)))")
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
        return L10n.format("settings.not_sent", ListFormatter.localizedString(byJoining: names))
    }
}
