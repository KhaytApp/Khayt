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

    // ── A PHONE THAT KEEPS NO BOOK (a floor phone, #2640) ──────────────
    //
    // It has no `settings` to read, so the paired Mac tells it the shop's
    // switch on `/api/status`: `network: {offline, keep}`, only for a request
    // whose device signature verified, signed back with `x-khayt-reply-mac`.
    // The phone believes the block ONLY when that signature verifies under its
    // own key. A missing block, an unsigned answer or a signature that does
    // not verify is "no answer": the last verified block stands (or, before
    // any, `.unread`: everything but `lan` held), and is NEVER read as
    // "online". A block that is present but malformed goes to the rule as it
    // came, which reads it as offline (`outbound-vectors.json`).

    /// What one signed status answer said about the switch.
    enum StatusNetwork: Equatable, Sendable {
        /// Nothing the phone may believe: no block, no signature, or a
        /// signature that is not the Mac's.
        case noAnswer
        /// The Mac's verified `network` value, exactly as sent.
        case network(JSONValue)

        static func read(_ credential: DeviceKey.Credential, nonce: String, status: Int, body: Data,
                         replyMac: String?) -> StatusNetwork {
            guard DeviceKey.verifiesReply(credential, nonce: nonce, status: status, body: body, replyMac: replyMac),
                  case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: body),
                  let network = o["network"] else { return .noAnswer }
            return .network(network)
        }
    }

    /// The last verified status block, for the next launch.
    static let statusKey = "khayt.outbound.statusNetwork"

    /// The gate's view for a phone with no book (review of #2638):
    /// - a verified block on record is followed whatever else is known: it is
    ///   cleared only by `forgotten()`, so losing the device credential (a
    ///   sign-out, or a forged `device-revoked` on the Wi-Fi) never turns it
    ///   into "online";
    /// - a FLOOR phone (operator or viewer), paired and never told: `.unread`
    ///   (everything but `lan` held) until its Mac says. Floor roles exist
    ///   only with a Mac that has #2631, which ships with #2640, so its Mac
    ///   always has the signed field to say it with (Dev Hub, Nov 22);
    /// - an owner or manager phone with no book (against an older Mac, or a
    ///   Windows/Linux desktop, which has no switch to tell it): `.none`, as
    ///   before, never held for good waiting for an answer that cannot come;
    /// - the phone's own records unreadable (launched before the first
    ///   unlock): `.unread`, read again when the data becomes available;
    /// - not paired: `.none`, nobody to ask, as every app without a book.
    static func bookless(paired: Bool, floor: Bool = false, dataAvailable: Bool = true) -> OutboundGate.Book {
        if let data = defaults.data(forKey: statusKey),
           let network = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return .settings(.object(["network": network]))
        }
        guard dataAvailable else { return .unread }
        return paired && floor ? .unread : .none
    }

    /// Whether the gate is following a book right now. While it is, a status
    /// answer is ignored: the book's settings (telemetry included) win, even
    /// when a book arrived during the status request (review of #2638).
    nonisolated(unsafe) private(set) static var bookHeld = false

    /// One signed status answer, for a phone that keeps no book.
    static func statusAnswer(_ answer: StatusNetwork) {
        guard !bookHeld, case .network(let network) = answer else { return }
        if let data = try? JSONEncoder().encode(network) { defaults.set(data, forKey: statusKey) }
        tell(.settings(.object(["network": network])))
    }

    private nonisolated(unsafe) static var observers: [NSObjectProtocol] = []

    /// At launch: the book on disk, and this phone's own install-count switch.
    /// A book that could not be read (launched before the first unlock, its
    /// file still protected) is read again when the data becomes available
    /// and each time the app comes forward, so the gate is never left held.
    static func start(book: CompanionBook?, countInstall: Bool, paired: @escaping () -> Bool = { false },
                      floor: @escaping () -> Bool = { false }) {
        // A test host must not take the simulator's book as the app's switch:
        // the suites ask their own scoped gates.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        Self.paired = paired
        Self.floor = floor
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

    /// Asked at each read, not captured once: a phone paired later in the
    /// same session counts as paired.
    nonisolated(unsafe) private static var paired: () -> Bool = { false }
    /// Whether this phone's role is below manager (operator, viewer), asked
    /// at each read like `paired`. The app passes the pairing's role once the
    /// role lives on this phone (#2630); on a build without roles no phone is
    /// a floor phone, which is what `false` says.
    nonisolated(unsafe) private static var floor: () -> Bool = { false }

    private static func read(_ book: CompanionBook?) {
        let exists = book?.exists == true
        bookHeld = exists
        let available = MainActor.assumeIsolated { UIApplication.shared.isProtectedDataAvailable }
        tell(exists ? Self.book(exists: true, store: try? book?.read())
                    : bookless(paired: paired(), floor: floor(), dataAvailable: available))
    }

    /// Called with every book the phone writes.
    static func changed(_ store: [String: JSONValue]) {
        bookHeld = true
        tell(.settings(effective(store["settings"] ?? .object([:]))))
    }

    /// The book went away (unpairing): no settings to follow, nothing remembered.
    static func forgotten() {
        defaults.removeObject(forKey: rememberedKey)
        defaults.removeObject(forKey: statusKey)
        bookHeld = false
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

// ── THE WORDS FOR A REFUSED CALL (signed off by Turki, Nov 22) ───────────
//
// The desktop's sentences (#2633, `outbound.blocked.*`), so a shop reads the
// same words on every app: "Khayt is set to make no internet calls. This
// needs Khayt Cloud." and, before the switch is read, "Khayt is starting.
// Try again in a moment." Never "network error": a refused call was never
// tried.
extension PhoneOutbound {
    /// The sentence for one refusal. `settings-unknown` is the app still
    /// reading the switch; every other reason the phone can meet means the
    /// shop's switch is on.
    static func words(purpose: OutboundPurpose, reason: String) -> String {
        if reason == "settings-unknown" { return L10n.tr("outbound.blocked.settings-unknown") }
        return L10n.format("outbound.blocked.offline", purposeName(purpose))
    }

    /// What a purpose is called in the sentence: the desktop's `iu.in.*`
    /// names for the purposes this phone calls.
    static func purposeName(_ purpose: OutboundPurpose) -> String {
        switch purpose {
        case .cloud: return L10n.tr("outbound.purpose.cloud")
        case .lookups: return L10n.tr("outbound.purpose.lookups")
        case .webhooks: return L10n.tr("outbound.purpose.webhooks")
        default: return L10n.tr("outbound.purpose.cloud")
        }
    }
}

/// So every place that shows `error.localizedDescription` says why in words.
extension OutboundBlocked: @retroactive LocalizedError {
    public var errorDescription: String? { PhoneOutbound.words(purpose: purpose, reason: reason) }
}
