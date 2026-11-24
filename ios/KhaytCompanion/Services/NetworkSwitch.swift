import Foundation
import KhaytCore

/// The shop's "Make no internet calls" switch as the book holds it
/// (`settings.network`, `lib/outbound.js`): what the phone shows, and what it
/// tells the Mac it was showing when the owner taps.
struct ShopNetwork: Equatable, Sendable {
    var offline: Bool
    var keep: [String]
    var changedAt: String?
    var changedBy: String?

    /// From a `network` value. Nil when it is not an object with a Boolean
    /// `offline`: the phone then has nothing it can truthfully say it saw.
    init?(_ value: JSONValue?) {
        guard case .object(let o)? = value, case .bool(let offline)? = o["offline"] else { return nil }
        self.offline = offline
        if case .array(let rows)? = o["keep"] {
            keep = rows.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        } else { keep = [] }
        if case .string(let at)? = o["changedAt"], !at.isEmpty { changedAt = at }
        if case .string(let by)? = o["changedBy"], !by.isEmpty { changedBy = by }
    }

    init(offline: Bool, keep: [String] = [], changedAt: String? = nil, changedBy: String? = nil) {
        self.offline = offline; self.keep = keep; self.changedAt = changedAt; self.changedBy = changedBy
    }

    /// The switch in the settings the gate follows now, if it follows a book.
    static func current(_ book: OutboundGate.Book) -> ShopNetwork? {
        guard case .settings(.object(let s)) = book else { return nil }
        return ShopNetwork(s["network"])
    }
}

/// An owner's phone flipping the shop's switch through the Mac
/// (`POST /api/network/switch`, docs/LAN_API.md; iPhone frame 1B, Turki's yes
/// of Nov 22). The Mac makes the change, by the same path as its own screen;
/// the phone asks, signed, and believes only a signed answer.
/// Named apart from KhaytCore's `NetworkSwitch` (the stamp rule), which a file
/// importing both modules would otherwise find ambiguous.
enum PhoneNetworkSwitch {
    static let path = "/api/network/switch"
    /// What `GET /api/devices/self` lists in `can` when this Mac serves the
    /// route for this phone.
    static let capability = "network-switch"

    /// `can` from a `/api/devices/self` answer: a missing or malformed list is
    /// empty, so an older Mac offers nothing.
    static func can(_ answer: JSONValue?) -> Set<String> {
        guard case .object(let o)? = answer, case .array(let rows)? = o["can"] else { return [] }
        return Set(rows.compactMap { if case .string(let s) = $0 { return s } else { return nil } })
    }

    /// Whether this phone shows the owner's control (1B) rather than the
    /// read-only page (1A): the owner, the Mac in reach on the shop's Wi-Fi,
    /// and the Mac saying it serves the route. The Mac checks the role itself.
    static func mayChange(role: String, can: Set<String>, macInReach: Bool, sampleShop: Bool) -> Bool {
        role == "owner" && macInReach && !sampleShop && can.contains(capability)
    }

    /// What the phone was showing, read the way the Mac shows a phone the
    /// switch (`networkForPhone`): the keep list holds only purposes a shop
    /// can keep that this build knows (never `lan` or `switch-sync`, never an
    /// id from a newer app), each once. Read from the raw block, so a
    /// malformed `offline` beside a real keep list still says what was kept.
    /// Otherwise `seenKeep` could never equal the Mac's list, and every tap
    /// would be answered "changed" (review of #2690).
    struct Showing: Equatable, Sendable {
        var seen: String?
        var keep: [String]

        static let none = Showing(seen: nil, keep: [])

        init(seen: String?, keep: [String]) { self.seen = seen; self.keep = keep }

        init(network: JSONValue?) {
            guard case .object(let o)? = network else { self = .none; return }
            var seen: String?
            if case .string(let at)? = o["changedAt"], !at.isEmpty { seen = at }
            var keep: [String] = []
            if case .array(let rows)? = o["keep"] {
                for case .string(let id) in rows where PhoneNetworkSwitch.keepable(id) && !keep.contains(id) { keep.append(id) }
            }
            self.init(seen: seen, keep: keep)
        }

        init(_ network: ShopNetwork) {
            self.init(seen: network.changedAt, keep: network.keep.filter(PhoneNetworkSwitch.keepable))
        }

        /// From the settings the gate follows now.
        static func current(_ book: OutboundGate.Book) -> Showing {
            guard case .settings(.object(let s)) = book else { return .none }
            return Showing(network: s["network"])
        }
    }

    /// A purpose a shop can keep, that this build knows.
    static func keepable(_ id: String) -> Bool {
        guard let purpose = OutboundPurpose(rawValue: id) else { return false }
        return purpose != .lan && purpose != .switchSync
    }

    /// The request: the switch, and what the phone was showing, so two people
    /// flipping it at once never overwrite each other blind.
    /// - `seen`: the `changedAt` shown; left out when none was seen.
    /// - `seenKeep`: the keep list shown, ALWAYS sent. `changedAt` moves only
    ///   when the switch is flipped, so a Keep ticked at the computer since is
    ///   invisible to `seen`; the person confirmed against this list.
    /// - `keep` is never sent: the phone does not edit the list, and leaving
    ///   it out leaves the shop's list as it is.
    static func body(offline: Bool, showing: Showing) -> Data {
        var o: [String: JSONValue] = ["offline": .bool(offline), "seenKeep": .array(showing.keep.map(JSONValue.string))]
        if let seen = showing.seen { o["seen"] = .string(seen) }
        return (try? JSONEncoder().encode(JSONValue.object(o))) ?? Data()
    }

    enum Outcome: Equatable, Sendable {
        /// The Mac saved it; this is the switch now.
        case done(ShopNetwork)
        /// Someone changed it meanwhile; nothing was changed. The value now, when sent.
        case changed(ShopNetwork?)
        case notSaved(ShopNetwork?)
        case readOnly
        case busy
        /// The Mac says this phone is not the owner.
        case notOwner
        /// This computer does not serve the route (404).
        case unsupported
        /// An answer the Mac did not sign: never shown as done.
        case unverified
        case failed
    }

    /// What one answer means. `verified` is the reply MAC over this request's
    /// nonce: without it nothing the body says is believed, except a 404 (an
    /// older computer signs nothing and serves no route).
    static func outcome(status: Int, body: Data, verified: Bool) -> Outcome {
        if status == 404 { return .unsupported }
        guard verified else { return .unverified }
        let o: [String: JSONValue]
        if case .object(let parsed)? = try? JSONDecoder().decode(JSONValue.self, from: body) { o = parsed } else { o = [:] }
        var reason: String?
        if case .string(let r)? = o["reason"] { reason = r }
        switch status {
        case 200:
            guard o["ok"] == .bool(true), let network = ShopNetwork(o["network"]) else { return .failed }
            return .done(network)
        case 403:
            return reason == "role-scope" ? .notOwner : .failed
        case 409:
            switch reason {
            case "changed": return .changed(ShopNetwork(o["network"]))
            case "not-saved": return .notSaved(ShopNetwork(o["network"]))
            case "read-only": return .readOnly
            default: return .failed
            }
        case 503:
            return .busy
        default:
            return .failed
        }
    }

    /// The sentence shown after a tap. Nil for done: the switch itself says it.
    static func words(_ outcome: Outcome) -> String? {
        switch outcome {
        case .done: return nil
        case .changed: return L10n.tr("internet.result.changed")
        case .notSaved: return L10n.tr("internet.result.not_saved")
        case .readOnly: return L10n.tr("internet.result.read_only")
        case .busy: return L10n.tr("internet.result.busy")
        case .notOwner: return L10n.tr("internet.result.not_owner")
        case .unsupported: return L10n.tr("internet.result.failed")
        // No signed answer: the Mac may or may not have made the change, so
        // the phone never says "nothing was changed" (review of #2690).
        case .unverified, .failed: return L10n.tr("internet.result.unconfirmed")
        }
    }
}

/// What Settings › Internet use shows (frames 1A and 1B), worked out from the
/// gate's own answers so the page never decides anything itself.
struct InternetUseModel: Equatable {
    enum State: String { case allowed, kept, blocked, off, on }
    struct Line: Equatable, Identifiable {
        let id: String
        let title: String
        let sub: String
        let state: State
    }

    let switchOn: Bool
    let lines: [Line]

    /// `rows` and `blocked` are the gate's (`OutboundGate.rows()`,
    /// `blockedCounts()`); `clock` writes "last at 14:12".
    static func make(shopOffline: Bool, rows: [OutboundGate.Row], blocked: [OutboundPurpose: OutboundGate.Blocked],
                     countInstall: Bool, countReady: Bool, clock: (Date) -> String) -> InternetUseModel {
        func state(_ purpose: OutboundPurpose) -> State {
            guard let row = rows.first(where: { $0.purpose == purpose.rawValue }) else {
                // No answer from the rule: never claim a call is allowed.
                return shopOffline ? .blocked : .allowed
            }
            if !row.allowed { return .blocked }
            // `kept` on a row is the shop's list, whatever the switch says;
            // the reason says whether that is why the call goes through now.
            return row.reason == "kept" ? .kept : .allowed
        }
        func sub(_ purpose: OutboundPurpose, _ s: State, kept: String, allowed: String, blockedWords: String) -> String {
            switch s {
            case .kept: return kept
            case .blocked:
                if let b = blocked[purpose], b.count > 0 {
                    return L10n.format("internet.blocked_times", L10n.count("internet.blocked_count", b.count), clock(b.last))
                }
                return blockedWords
            default: return allowed
            }
        }
        let cloud = state(.cloud), lookups = state(.lookups)
        var lines = [
            Line(id: "cloud", title: L10n.tr("outbound.purpose.cloud"),
                 sub: sub(.cloud, cloud, kept: L10n.tr("internet.cloud.kept"), allowed: L10n.tr("internet.cloud.allowed"),
                          blockedWords: L10n.tr("internet.cloud.blocked")), state: cloud),
            Line(id: "lookups", title: L10n.tr("internet.lookups"),
                 sub: sub(.lookups, lookups, kept: L10n.tr("internet.lookups.sub"), allowed: L10n.tr("internet.lookups.sub"),
                          blockedWords: L10n.tr("internet.lookups.blocked")), state: lookups),
        ]
        if countReady {
            lines.append(Line(id: "install-count", title: L10n.tr("internet.install"), sub: L10n.tr("internet.install.sub"),
                              // On, but held by the shop's switch: say blocked, not on.
                              state: !countInstall ? .off : (state(.installCount) == .blocked ? .blocked : .on)))
        }
        return InternetUseModel(switchOn: shopOffline, lines: lines)
    }
}
