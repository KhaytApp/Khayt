import Foundation
import KhaytCore

// Shared by the app and the KhaytAlerts notification service extension.
//
// The extension runs in its own process, so it never sees the app's
// `OutboundGate.shared`. Its one internet call is Khayt Cloud's
// `GET /v1/shops/{id}/events`, for a push whose sealed details did not fit in
// it. The shop's "Make no internet calls" switch must stop that call too
// (follow-up to #2638). The app writes what its gate follows here, in the App
// Group, every time it tells the gate; the extension reads it into a gate of
// its own and asks `cloud` before fetching. A refused fetch leaves Apple's
// generic "A print finished", which is still true.
//
// Only the keys the rule reads (`OutboundGate.settingsRead`: `network`,
// `telemetry`) are written, never the rest of the shop's settings: the App
// Group is readable by the extension and the widget, and settings hold
// integration keys.
enum OutboundMirror {
    static let group = "group.com.khaytapp.companion"
    static let key = "khayt.outbound.mirror"

    /// What is stored: which kind of book the gate follows, and for a book
    /// with settings, only the keys the rule reads.
    private struct Stored: Codable {
        var book: String
        var settings: JSONValue?
    }

    static func encode(_ book: OutboundGate.Book) -> Data? {
        switch book {
        case .none: return try? JSONEncoder().encode(Stored(book: "none"))
        case .unread: return try? JSONEncoder().encode(Stored(book: "unread"))
        case .settings(let s):
            // Settings that are not an object hold everything in the app's
            // gate (`lib/outbound.js`: not a plain object is `settings-unknown`),
            // so they hold everything here too, never read as "no switch".
            guard case .object(let o) = s else { return try? JSONEncoder().encode(Stored(book: "unread")) }
            var kept: [String: JSONValue] = [:]
            for k in OutboundGate.settingsRead { if let v = o[k] { kept[k] = v } }
            return try? JSONEncoder().encode(Stored(book: "settings", settings: .object(kept)))
        }
    }

    /// The book a stored mirror describes. Nothing stored, or something that
    /// does not read, is `.unread`: everything but `lan` held. An extension
    /// updated before the app has run once more fails closed, and the alert
    /// stays Apple's generic one, which is never wrong.
    static func decode(_ data: Data?) -> OutboundGate.Book {
        guard let data, let s = try? JSONDecoder().decode(Stored.self, from: data) else { return .unread }
        switch s.book {
        case "none": return .none
        case "settings":
            guard let settings = s.settings, case .object = settings else { return .unread }
            return .settings(settings)
        default: return .unread
        }
    }

    static func write(_ book: OutboundGate.Book, to defaults: UserDefaults?) {
        guard let defaults, let data = encode(book) else { return }
        defaults.set(data, forKey: key)
    }

    /// A gate of its own, following what the app last wrote.
    static func gate(from defaults: UserDefaults?) -> OutboundGate {
        let gate = OutboundGate()
        gate.update(book: decode(defaults?.data(forKey: key)))
        return gate
    }
}
