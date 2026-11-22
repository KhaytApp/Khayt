import Foundation
import UIKit
import KhaytCore

/// The shop's "Make no internet calls" switch, on the phone (P8: #2626's
/// `lib/outbound.js`, asked through the Mac's `OutboundGate` in KhaytCore,
/// #2637). The desktop's screen tells a shop that "every computer and the
/// phone follow it": this is the phone following it.
///
/// ── WHERE THE PHONE LEARNS THE SWITCH ────────────────────────────────────
///
/// From the book it already holds: `settings.network` (and `telemetry`) as the
/// Mac's `/api/store` or Khayt Cloud handed it over. The Mac never syncs
/// settings to the cloud, so on a paired phone this is the Mac's word. The
/// gate is told at launch (one read of the book on disk) and again on every
/// change to the book (`CompanionBook.writeAlertIndex`, which already holds
/// the whole book in hand, so nothing is read twice). The rule itself decides
/// everything, including that a malformed `settings.network` reads as offline.
///
/// ── WHAT IT NEVER BLOCKS ─────────────────────────────────────────────────
///
/// The phone's own requests to the paired Mac on the shop's network are not
/// asked: Dev Hub's call (Nov 22), "LAN to the Mac always works". Nor are
/// links a person opens in Safari (WhatsApp, help, privacy): those are the
/// person's, not the app's.
///
/// ── WHAT IS NOT COVERED YET ──────────────────────────────────────────────
///
/// A phone that keeps no book (a floor phone, a cloud sign-in before its first
/// pull) has no settings to read, so its gate reads `.none` (as every app
/// without a book does). The notification extension runs in its own process
/// and asks no gate.
enum PhoneOutbound {
    /// The last `settings.network` the phone saw (review of #2638). A whole
    /// pull from Khayt Cloud can bring a copy of the book whose `settings`
    /// carry no `network` (the Mac never syncs settings to the cloud), and
    /// reading that as "never set" would turn a shop's switch off on this
    /// phone. A shop that turns the switch OFF writes `offline: false`, so a
    /// block that is present always wins; only an absent one is filled in.
    static let rememberedKey = "khayt.outbound.network"
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// The settings the gate is given for a book's settings: the book's own,
    /// with the remembered `network` block when the book has none.
    static func effective(_ settings: JSONValue?) -> JSONValue {
        guard case .object(var s)? = settings else { return settings ?? .object([:]) }
        if let network = s["network"], network != .null {
            if let data = try? JSONEncoder().encode(network) { defaults.set(data, forKey: rememberedKey) }
        } else if let data = defaults.data(forKey: rememberedKey),
                  let network = try? JSONDecoder().decode(JSONValue.self, from: data) {
            s["network"] = network
        }
        return .object(s)
    }

    /// The gate's view of a book: its settings when there is one, `.none`
    /// when there is none. `.unread` (everything but `lan` held) for a book
    /// that exists but could not be read: a shop that switched the internet
    /// off is not leaked to because its book failed to parse.
    static func book(exists: Bool, store: [String: JSONValue]?) -> OutboundGate.Book {
        guard exists else { return .none }
        guard let store else { return .unread }
        return .settings(effective(store["settings"] ?? .object([:])))
    }

    private nonisolated(unsafe) static var observers: [NSObjectProtocol] = []

    /// At launch: the book on disk, and this phone's own install-count switch.
    /// A book that could not be read (launched before the first unlock, its
    /// file still protected) is read again when the data becomes available
    /// and each time the app comes forward, so the gate is never left held.
    static func start(book: CompanionBook?, countInstall: Bool) {
        // A test host must not take the simulator's book as the app's switch:
        // the suites ask their own scoped gates.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        read(book)
        local(countInstall: countInstall)
        guard observers.isEmpty else { return }
        for name in [UIApplication.protectedDataDidBecomeAvailableNotification,
                     UIApplication.willEnterForegroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                if OutboundGate.shared.currentBook == .unread { read(book) }
            })
        }
    }

    private static func read(_ book: CompanionBook?) {
        let exists = book?.exists == true
        tell(Self.book(exists: exists, store: exists ? try? book?.read() : nil))
    }

    /// Called with every book the phone writes.
    static func changed(_ store: [String: JSONValue]) {
        tell(.settings(effective(store["settings"] ?? .object([:]))))
    }

    /// The book went away (unpairing): no settings to follow, nothing remembered.
    static func forgotten() {
        defaults.removeObject(forKey: rememberedKey)
        tell(.none)
    }

    /// The phone has no switch of its own to go offline; it can only stop
    /// counting itself (Settings › Count this install), which is per device.
    static func local(countInstall: Bool) {
        OutboundGate.shared.update(local: .init(offline: false, installCountOff: !countInstall))
    }

    private static func tell(_ book: OutboundGate.Book) {
        OutboundGate.shared.update(book: book)
    }
}
