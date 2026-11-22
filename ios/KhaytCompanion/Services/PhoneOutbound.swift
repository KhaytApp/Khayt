import Foundation
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
    /// The gate's view of a book: its settings when there is one, `.none`
    /// when there is none. `.unread` (everything but `lan` held) for a book
    /// that exists but could not be read: a shop that switched the internet
    /// off is not leaked to because its book failed to parse.
    static func book(exists: Bool, store: [String: JSONValue]?) -> OutboundGate.Book {
        guard exists else { return .none }
        guard let store else { return .unread }
        return .settings(store["settings"] ?? .object([:]))
    }

    /// At launch: the book on disk, and this phone's own install-count switch.
    static func start(book: CompanionBook?, countInstall: Bool) {
        let exists = book?.exists == true
        tell(Self.book(exists: exists, store: exists ? try? book?.read() : nil))
        local(countInstall: countInstall)
    }

    /// Called with every book the phone writes.
    static func changed(_ store: [String: JSONValue]) {
        tell(.settings(store["settings"] ?? .object([:])))
    }

    /// The book went away (unpairing): no settings to follow.
    static func forgotten() { tell(.none) }

    /// The phone has no switch of its own to go offline; it can only stop
    /// counting itself (Settings › Count this install), which is per device.
    static func local(countInstall: Bool) {
        OutboundGate.shared.update(local: .init(offline: false, installCountOff: !countInstall))
    }

    private static func tell(_ book: OutboundGate.Book) {
        OutboundGate.shared.update(book: book)
    }
}
