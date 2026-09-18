import Foundation
import Network

/**
 * Finding the shop's Mac, instead of asking somebody to type its address.
 *
 * Pairing has meant reading an IP address and a port off a Settings screen on
 * one machine and typing them into a wizard on another. It is the worst five
 * minutes a shop spends with this product, and it does not stay fixed: a router
 * hands the Mac a different address next week and the phone that was working
 * stops, with an error that says the shop is unreachable rather than that its
 * number changed.
 *
 * The Mac advertises `_khayt._tcp` now, so this can offer a list of shops. The
 * address still exists — the app still connects to a host and a port — it is
 * just no longer something a person has to know.
 *
 * ── WHAT THE TXT RECORD IS FOR ────────────────────────────────────────────
 *
 * `store=1` says the Mac serves `GET /api/store`, which is the difference
 * between a companion that keeps working away from the desk and one that empties
 * the moment it loses the Mac. Only the native app serves it; the Electron
 * desktop most shops still run does not. Knowing before pairing means the screen
 * can say which kind of shop this is rather than discovering it afterwards.
 *
 * The PIN is deliberately not advertised, so nothing here guesses at it: a stale
 * "no PIN needed" is the phone confidently telling a shop something untrue, and
 * a 401 answers it accurately for the cost of one request.
 */
@MainActor
final class ShopBrowser: ObservableObject {

    struct Shop: Identifiable, Equatable {
        /// The Bonjour name, which is also what makes it unique in the list —
        /// the system already de-duplicates collisions by appending a number.
        let id: String
        var name: String { id }
        /// Whether this Mac can hand over the book. See the note above.
        let servesBook: Bool
        let endpoint: NWEndpoint
    }

    @Published private(set) var shops: [Shop] = []
    @Published private(set) var isSearching = false
    /// Set when the browser itself cannot run — most usefully when the person
    /// has refused the local-network prompt, which otherwise looks exactly like
    /// a shop that is switched off.
    @Published private(set) var failure: String?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false          // the shop's Mac is on Wi-Fi, not AirDrop
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_khayt._tcp", domain: nil),
                                using: params)
        self.browser = browser
        isSearching = true
        failure = nil

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    // The common cause is not a network fault: it is the local
                    // network permission being declined, and saying "no shops
                    // found" for that would send somebody to check their router.
                    self.failure = error.localizedDescription
                    self.isSearching = false
                case .ready:
                    self.failure = nil
                case .cancelled:
                    self.isSearching = false
                default: break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.shops = results.compactMap(Self.shop(from:))
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    nonisolated static func shop(from result: NWBrowser.Result) -> Shop? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var fields: [String: String] = [:]
        if case .bonjour(let txt) = result.metadata {
            for key in txt.dictionary.keys {
                if let value = txt[key] { fields[key] = value }
            }
        }
        return Shop(id: name, servesBook: servesBook(fields), endpoint: result.endpoint)
    }

    /// Whether this Mac serves `GET /api/store`.
    ///
    /// Absent means no, which is the answer an older Mac gives by saying
    /// nothing — and "no" is the safe direction: a phone that assumed yes would
    /// promise a shop it can work away from the desk and then fail to fill its
    /// book.
    nonisolated static func servesBook(_ txt: [String: String]) -> Bool {
        txt["store"] == "1"
    }

    /// Turn a discovered service into the host and port the API client needs.
    ///
    /// Bonjour hands over a NAME, not an address, and resolving it means opening
    /// a connection and asking what it connected to. That is the documented way
    /// and there is no cheaper one: `NWBrowser` deliberately does not resolve,
    /// because an address is only true while a connection is held.
    ///
    /// The connection is cancelled the moment the path is read. It exists to
    /// answer one question.
    func resolve(_ shop: Shop, timeout: TimeInterval = 5) async -> (host: String, port: UInt16)? {
        let connection = NWConnection(to: shop.endpoint, using: .tcp)
        defer { connection.cancel() }

        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint else {
                        if once.first() { continuation.resume(returning: nil) }
                        return
                    }
                    if once.first() {
                        continuation.resume(returning: Self.address(host: host, port: port))
                    }
                case .failed, .cancelled:
                    if once.first() { continuation.resume(returning: nil) }
                default: break
                }
            }
            connection.start(queue: .main)
            // A Mac that answers the advertisement but never completes a
            // connection would otherwise hang the pairing screen forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if once.first() { continuation.resume(returning: nil) }
            }
        }
    }

    /// How a resolved endpoint is written down.
    ///
    /// Pure, and separated from the connection above so that the part with the
    /// sharp edges can be tested without a network.
    ///
    /// ── THE SHARP EDGE IS IPv6 ────────────────────────────────────────────
    ///
    /// A Mac on a home network usually resolves to IPv4 and this is dull. It can
    /// resolve to a link-local IPv6 address instead, which arrives as
    /// `fe80::1c3d:ff:fe12:3456%en0` — and that string cannot go into a URL as
    /// it stands. It needs brackets, and the zone's `%` has to be
    /// percent-encoded as `%25` or `URL` refuses the whole thing and the shop
    /// gets "could not connect" for an address that is perfectly good.
    nonisolated static func address(host: NWEndpoint.Host, port: NWEndpoint.Port) -> (host: String, port: UInt16) {
        let text: String
        switch host {
        case .ipv4(let v4):
            text = "\(v4)"
        case .ipv6(let v6):
            // `"\(v6)"` includes the zone for a link-local address.
            let raw = "\(v6)"
            text = "[\(raw.replacingOccurrences(of: "%", with: "%25"))]"
        case .name(let name, _):
            text = name
        @unknown default:
            text = "\(host)"
        }
        return (text, port.rawValue)
    }
}

/// Resume-exactly-once, for the three paths that can finish a resolution.
///
/// A `CheckedContinuation` resumed twice is a crash, and this has a success, a
/// failure and a timeout that can all arrive.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func first() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
