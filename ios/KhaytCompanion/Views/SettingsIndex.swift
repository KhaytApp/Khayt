import Foundation

/// Settings' rows, apart from any screen: which group each sits in, its
/// label, the words its page holds (so a search for "PIN" finds the Mac),
/// and where it goes. The screen draws these; the tests read them.
enum SettingsRoute: String, CaseIterable, Hashable, Identifiable {
    case appearance, notifications, privacy
    case shop
    case mac, cloud, connectors
    case help, diagnostics

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case thisPhone = "this_phone", shop, connected, about
        var titleKey: String { "settings.group.\(rawValue)" }
    }

    /// Where a row goes: its own page, or (Help) the website.
    enum Destination: Equatable {
        case page
        case link(URL)
    }

    static let helpURL = URL(string: "https://khaytapp.com/")!
    static let privacyURL = URL(string: "https://khaytapp.com/privacy/")!

    var group: Group {
        switch self {
        case .appearance, .notifications, .privacy: return .thisPhone
        case .shop: return .shop
        case .mac, .cloud, .connectors: return .connected
        case .help, .diagnostics: return .about
        }
    }

    var destination: Destination {
        switch self {
        case .help: return .link(Self.helpURL)
        default: return .page
        }
    }

    /// The row's label. Where the row is also one of the shared Settings panes
    /// (Mac 91:435), it has that pane's name: Shop details, Phones & Wi-Fi,
    /// Khayt Cloud, Connectors. Phone-only rows keep their own.
    var titleKey: String {
        switch self {
        case .appearance: return "settings.appearance"
        case .notifications: return "settings.notifications"
        case .privacy: return "settings.privacy"
        case .shop: return "settings.shop_details"
        case .mac: return "settings.phones_wifi"
        case .cloud: return "cloud.title"
        case .connectors: return "connectors.title"
        case .help: return "settings.help"
        case .diagnostics: return "diag.title"
        }
    }

    /// The labels on the row's page, so a search finds the page that holds them.
    var searchKeys: [String] {
        switch self {
        case .appearance: return ["settings.language", "lang.system"]
        case .notifications:
            return ["settings.notify.print_done", "settings.live_activities", "settings.notify.queue",
                    "settings.notify.low_stock", "settings.notify.overdue", "settings.notify.connection",
                    "settings.notifications.allow"]
        case .privacy: return ["settings.count_install", "settings.privacy_policy"]
        case .shop: return ["settings.shop_name", "settings.shop.readonly"]
        case .mac:
            return ["settings.mac_in_reach", "settings.connection", "settings.host", "settings.pin", "settings.retest",
                    "settings.unpair", "settings.secure.button"]
        case .cloud: return ["cloud.sign_in", "cloud.sync_now", "cloud.sign_out", "settings.cloud.sub"]
        case .connectors: return []
        case .help: return []
        case .diagnostics: return ["settings.holds", "settings.diag.sub"]
        }
    }

    /// Every label a search reads for this row, in the app's language.
    /// `extra` is what only the screen knows (the shop's name, the languages).
    func searchLabels(extra: [String] = []) -> [String] {
        [L10n.tr(titleKey)] + searchKeys.map(L10n.tr) + extra
    }

    /// The rows a screen draws, group by group, in order.
    static func rows(in group: Group, showsConnectors: Bool) -> [SettingsRoute] {
        allCases.filter { $0.group == group && ($0 != .connectors || showsConnectors) }
    }
}

/// Settings' search: which rows have a label holding what was typed. Case,
/// accents and Arabic marks (harakat, hamza seats, tatweel) do not count,
/// so "notif" finds Notifications, "resume" finds "Résumé", and "اشعارات"
/// finds "الإشعارات".
enum SettingsSearch {
    static func matches<ID: Hashable>(_ query: String, in rows: [(id: ID, labels: [String])]) -> [ID] {
        let q = fold(query)
        guard !q.isEmpty else { return rows.map(\.id) }
        return rows.filter { row in row.labels.contains { fold($0).contains(q) } }.map(\.id)
    }

    /// Foundation's diacritic folding leaves Arabic alone (an alef with a
    /// hamza stays a different letter), so the Arabic is folded by hand:
    /// harakat, superscript alef and tatweel go, and every alef seat is one alef.
    static func fold(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            switch scalar.value {
            case 0x064B...0x065F, 0x0670, 0x0640: continue           // harakat, dagger alef, tatweel
            case 0x0622, 0x0623, 0x0625, 0x0671: out.append("\u{0627}") // آ أ إ ٱ → ا
            default: out.append(scalar)
            }
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
