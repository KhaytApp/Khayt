import Foundation
import KhaytCore

/// Developer mode: a connector someone is BUILDING, loaded from a
/// `.khaytplugin` file (the same JSON manifest Khayt signs, signature or not)
/// on this Mac only.
///
/// ── WHY IT IS NOT IN THE BOOK ────────────────────────────────────────────
///
/// Everything in `settings.plugins[]` syncs, and every other device runs only
/// what Khayt signed. A connector nobody reviewed must never reach the phone
/// or the desktop, so its entry lives here, in this Mac's own defaults, and
/// nowhere else: not the book, not the LAN server, not a backup. What it
/// fills in on a job is the shop's data like any other connector's, and is
/// written to the record as usual.
///
/// It runs only while BOTH switches are on: connectors (`ConnectorsSwitch`)
/// and developer mode. Turning developer mode off keeps the entries, shown
/// as not reviewed and not run, so they can still be removed.
///
/// Its events are sent once and never queued: the retry queue is
/// `settings.pluginOutbox`, in the book, and a dev connector's id has no
/// business there.
enum DevConnectors {
    /// Developer mode itself (Settings ▸ Connectors).
    static let modeKey = "KhaytConnectorDevMode"
    /// The dev entries: a JSON array in the shape of `settings.plugins[]`.
    static let storeKey = "KhaytDevConnectors"
    static let fileExtension = "khaytplugin"

    nonisolated static func isOn(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 defaults: UserDefaults = .standard) -> Bool {
        ConnectorsSwitch.isOn(environment: environment, defaults: defaults) && defaults.bool(forKey: modeKey)
    }

    /// Every dev entry kept on this Mac, running or not.
    nonisolated static func entries(defaults: UserDefaults = .standard) -> [JSONValue] {
        guard let data = defaults.data(forKey: storeKey),
              case .array(let rows)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        return rows
    }

    nonisolated static func save(_ plugins: JSONValue, defaults: UserDefaults = .standard) {
        guard case .array(let rows) = plugins, !rows.isEmpty else { defaults.removeObject(forKey: storeKey); return }
        if let data = try? JSONEncoder().encode(plugins) { defaults.set(data, forKey: storeKey) }
    }

    /// The dev entries that may run alongside `book`: none with developer
    /// mode off, and never one whose id the shop installed for real (that
    /// one wins).
    nonisolated static func running(besides book: [JSONValue],
                                    environment: [String: String] = ProcessInfo.processInfo.environment,
                                    defaults: UserDefaults = .standard) -> [JSONValue] {
        guard isOn(environment: environment, defaults: defaults) else { return [] }
        let taken = Set(book.compactMap { Shop.plainString(Shop.object($0)["id"]) })
        return entries(defaults: defaults).filter { e in
            guard let id = Shop.plainString(Shop.object(e)["id"]) else { return false }
            return !taken.contains(id)
        }
    }

    /// The settings a move's deliveries are worked out from, with this Mac's
    /// running dev connectors added, so one listening to an event hears it
    /// (`KhaytEngine.webhookDeliveries`). Never written back: only read.
    nonisolated static func withDev(_ settings: [String: JSONValue],
                                    environment: [String: String] = ProcessInfo.processInfo.environment,
                                    defaults: UserDefaults = .standard) -> [String: JSONValue] {
        var book: [JSONValue] = []
        if case .array(let rows)? = settings["plugins"] { book = rows }
        let dev = running(besides: book, environment: environment, defaults: defaults)
        guard !dev.isEmpty else { return settings }
        var out = settings
        out["plugins"] = .array(book + dev)
        return out
    }
}
