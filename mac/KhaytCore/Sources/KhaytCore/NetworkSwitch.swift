import Foundation

/// The shop's "make no internet calls" switch, carried between its computers
/// through Khayt Cloud, for a shop that opted in (khayt-cloud
/// `GET/PUT/DELETE /v1/shops/{id}/network-switch`, docs/api-contract.md).
///
/// ── SEALED, AND CHECKED BEFORE IT IS OBEYED ──────────────────────────────
///
/// The server relays a value it cannot read: `settings.network` sealed with
/// the shop's key in the store's own envelope. A computer applies a value only
/// when ALL of the contract's checks hold (`read`), and otherwise ignores it:
/// this must never be a way to switch a shop's computers off from outside.
///
/// What it does NOT prove: any member who signed in holds the shop key, so
/// against a compromised server a manager's or a viewer's computer could make
/// a value the others obey. Owner-only is enforced by the server on the write,
/// not by a signature a computer can check (accepted, Nov 22: an owner signing
/// key comes later). `changedBy` is whatever the sending computer typed: show
/// it as text, never as a verified identity.
///
/// Pure: no network, no clock of its own. In KhaytCore so the phone reads a
/// value by the same checks.
public enum NetworkSwitch {

    public static let kind = "khayt-network-switch"
    public static let version = 1
    /// The route's tail on `/v1/shops/{id}`.
    public static let tail = "/network-switch"
    /// A fresh install does not apply an `offline: true` older than this on
    /// its own: it asks.
    public static let askAfter: TimeInterval = 7 * 86_400
    /// How often a computer that is offline through this route asks whether
    /// the switch was turned off.
    public static let checkEvery: TimeInterval = 15 * 60
    /// The cap on the one last call when the switch is turned on.
    public static let lastCallCap: TimeInterval = 10
    public static let maxChangedBy = 80
    /// How far ahead of this computer's clock a stamp may be: the server's
    /// own limit. A stamp further ahead is not applied and not remembered.
    public static let aheadAllowed: TimeInterval = 10 * 60
    /// Never in a `keep` list: `lan` is always allowed, and the switch-sync
    /// call is each computer's own choice, kept by the rule's own test.
    public static let neverKept: Set<String> = ["lan", "switch-sync"]

    /// The shop's switch, as it travels.
    public struct Value: Sendable, Equatable {
        public var offline: Bool
        /// Purposes kept while offline: only ids the rule knows, never `lan`.
        public var keep: [String]
        /// Strict UTC, `yyyy-MM-ddTHH:mm:ss.SSSZ`: the moment the switch changed.
        public var changedAt: String
        public var changedBy: String?
        public init(offline: Bool, keep: [String], changedAt: String, changedBy: String?) {
            self.offline = offline; self.keep = keep; self.changedAt = changedAt; self.changedBy = changedBy
        }
    }

    /// What the server answers a GET with.
    public struct Published: Decodable, Sendable {
        public let changedAt: String
        public let ciphertext: SyncCrypto.Blob
    }

    /// Why a published value was not applied. Logged as
    /// `network switch: ignored, <why>`, with no content.
    public enum Ignored: String, Error, Sendable, Equatable {
        /// It does not open with this shop's key.
        case key
        /// Not this kind, this version or this shop.
        case shape
        /// The sealed stamp is not the one the server returned.
        case stamp
        /// Not newer than the newest this computer has seen, applied or set.
        case old
        /// `offline` is not a boolean, or a stamp is not a strict UTC stamp.
        case malformed
        /// Stamped more than ten minutes ahead of this computer's clock.
        case future
    }

    // MARK: - The stamp

    /// A strict UTC stamp, `YYYY-MM-DDTHH:MM:SS[.f{1,3}]Z`, as a date; nil for
    /// anything else (an offset, no zone, Feb 31, 24:00).
    public static func date(_ stamp: String) -> Date? {
        let s = Array(stamp.utf8)
        guard s.count >= 20, s.count <= 24, s.last == UInt8(ascii: "Z") else { return nil }
        func digits(_ range: Range<Int>) -> Int? {
            var n = 0
            for i in range { guard s[i] >= 48, s[i] <= 57 else { return nil }; n = n * 10 + Int(s[i] - 48) }
            return n
        }
        guard s[4] == UInt8(ascii: "-"), s[7] == UInt8(ascii: "-"), s[10] == UInt8(ascii: "T"),
              s[13] == UInt8(ascii: ":"), s[16] == UInt8(ascii: ":"),
              let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10),
              let hour = digits(11..<13), let minute = digits(14..<16), let second = digits(17..<19) else { return nil }
        var millis = 0
        if s.count > 20 {
            guard s[19] == UInt8(ascii: "."), s.count >= 22, let f = digits(20..<(s.count - 1)) else { return nil }
            let places = s.count - 21
            millis = f * (places == 1 ? 100 : places == 2 ? 10 : 1)
        }
        guard year >= 2020, (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute; c.second = second
        guard let date = calendar.date(from: c) else { return nil }
        // A real date: Feb 31 would have rolled over into March.
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date.addingTimeInterval(Double(millis) / 1000)
    }

    // MARK: - Sealing

    /// The plaintext the contract names, sealed with the shop's key.
    public static func seal(_ value: Value, shopId: String, dek: Data) throws -> SyncCrypto.Blob {
        var plain: [String: JSONValue] = [
            "kind": .string(kind), "v": .number(Double(version)), "shopId": .string(shopId),
            "offline": .bool(value.offline), "keep": .array(value.keep.map(JSONValue.string)),
            "changedAt": .string(value.changedAt),
        ]
        if let by = value.changedBy, !by.isEmpty { plain["changedBy"] = .string(String(by.prefix(maxChangedBy))) }
        return try SyncCrypto.seal(plain, dek: dek)
    }

    /// The body of a PUT: the sealed value and the same stamp in the clear,
    /// which is only for the server's ordering.
    public static func putBody(_ value: Value, shopId: String, dek: Data) throws -> Data {
        let blob = try seal(value, shopId: shopId, dek: dek)
        var envelope: [String: JSONValue] = ["v": .number(Double(blob.v ?? SyncCrypto.storeBlobVersion)),
                                             "iv": .string(blob.iv), "ct": .string(blob.ct), "tag": .string(blob.tag)]
        if let z = blob.z { envelope["z"] = .string(z) }
        return try JSONEncoder().encode(JSONValue.object(["ciphertext": .object(envelope), "changedAt": .string(value.changedAt)]))
    }

    // MARK: - Reading

    /// A published value, if every check holds (the contract's 1 to 5).
    ///
    /// - `highestSeen`: the newest stamp this computer has seen, applied or
    ///   set itself. Kept on the computer and never lowered.
    /// - `purposes`: the rule's purpose ids. Unknown `keep` entries are
    ///   dropped, and `lan` is never listed.
    public static func read(_ published: Published, shopId: String, dek: Data, highestSeen: String?,
                            purposes: Set<String>) -> Result<Value, Ignored> {
        // 1. It opens with this shop's key.
        guard let plain = try? SyncCrypto.store(published.ciphertext, dek: dek) else { return .failure(.key) }
        // 2. This kind, this version, this shop.
        guard plain["kind"] == .string(kind), plain["v"] == .number(Double(version)),
              plain["shopId"] == .string(shopId), !shopId.isEmpty else { return .failure(.shape) }
        // 5. (asked before the stamps are compared) a boolean, and stamps that are stamps.
        guard case .bool(let offline)? = plain["offline"], case .string(let sealedAt)? = plain["changedAt"],
              let when = date(sealedAt), date(published.changedAt) != nil else { return .failure(.malformed) }
        // 3. The sealed stamp is the one the server returned.
        guard sealedAt == published.changedAt else { return .failure(.stamp) }
        // 4. Newer than the newest this computer has seen.
        if let highestSeen, let seen = date(highestSeen), when <= seen { return .failure(.old) }
        var keep: [String] = []
        if case .array(let list)? = plain["keep"] {
            for case .string(let id) in list where purposes.contains(id) && !neverKept.contains(id) && !keep.contains(id) { keep.append(id) }
        }
        var by: String?
        if case .string(let name)? = plain["changedBy"] {
            let shown = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(maxChangedBy))
            by = shown.isEmpty ? nil : shown
        }
        return .success(Value(offline: offline, keep: keep, changedAt: sealedAt, changedBy: by))
    }

    /// The age rule: a computer with no stamp of its own yet (a new install, a
    /// reinstall, a first sign-in) does not apply an `offline: true` older
    /// than seven days on its own. It asks. `offline: false`, and anything
    /// newer, applies as usual.
    public static func asksFirst(_ value: Value, hasOwnStamp: Bool, now: Date) -> Bool {
        guard value.offline, !hasOwnStamp, let when = date(value.changedAt) else { return false }
        return now.timeIntervalSince(when) > askAfter
    }

    /// What a published value leads to on this computer.
    public enum Hearing: Sendable, Equatable {
        /// Every check holds: put it in the book.
        case apply(Value)
        /// A new install met an old `offline: true`: ask before applying.
        case askOld(Value)
        /// The value the server answered a change made here with (a 409),
        /// still waiting for the person's answer: never applied on its own.
        case askChangedElsewhere(Value)
        /// Not applied, and why. `.old` is the everyday case and is not logged.
        case ignore(Ignored)
    }

    /// `read`, then the two cases that wait for a person.
    ///
    /// - `ownStamp`: the stamp in this computer's own book, if it has one.
    /// - `heldStamp`: a published stamp already waiting for an answer.
    public static func hearing(_ published: Published, shopId: String, dek: Data, highestSeen: String?, ownStamp: String?,
                               heldStamp: String?, purposes: Set<String>, now: Date) -> Hearing {
        let seen = later(highestSeen, ownStamp)
        switch read(published, shopId: shopId, dek: dek, highestSeen: seen, purposes: purposes) {
        case .failure(let why): return .ignore(why)
        case .success(let value):
            // The server refuses a stamp more than ten minutes ahead; one that
            // is, here, did not come through an honest server and clock.
            if isAhead(value, now: now) { return .ignore(.future) }
            if let heldStamp, heldStamp == value.changedAt { return .askChangedElsewhere(value) }
            if asksFirst(value, hasOwnStamp: seen != nil, now: now) { return .askOld(value) }
            return .apply(value)
        }
    }

    /// When the switch is turned OFF here: whether `offline: false` is sent.
    /// Yes when a value is published there, whatever this computer's own
    /// option says (another computer published it, and an `offline: true`
    /// left there would keep reaching every computer that starts); yes when
    /// this computer's option is on; otherwise nothing is sent.
    public static func sendsOff(publishedThere: Bool, optionOn: Bool) -> Bool { publishedThere || optionOn }

    /// Whether a value is stamped further ahead of `now` than is allowed.
    public static func isAhead(_ value: Value, now: Date) -> Bool {
        guard let when = date(value.changedAt) else { return true }
        return when > now.addingTimeInterval(aheadAllowed)
    }

    /// The later of two stamps: how `highestSeen` only ever goes up.
    public static func later(_ a: String?, _ b: String?) -> String? {
        guard let a, let da = date(a) else { return b.flatMap { date($0) != nil ? $0 : nil } }
        guard let b, let db = date(b) else { return a }
        return db > da ? b : a
    }

    /// `settings.network` with a value applied: the shop's switch, its keep
    /// list and its stamp, exactly as they travelled. Anything else the book
    /// holds there stays.
    public static func applied(_ value: Value, to network: JSONValue?) -> JSONValue {
        var n: [String: JSONValue] = { if case .object(let o)? = network { return o }; return [:] }()
        n["offline"] = .bool(value.offline)
        n["keep"] = .array(value.keep.map(JSONValue.string))
        n["changedAt"] = .string(value.changedAt)
        n["changedBy"] = value.changedBy.map(JSONValue.string) ?? .null
        // It came through Khayt Cloud: the rule keeps the one call that hears
        // it turned off (`lib/outbound.js switchSyncKept`).
        n["via"] = .string(viaCloud)
        return .object(n)
    }

    /// `settings.network.via` for a switch that came through Khayt Cloud:
    /// applied from the route, or sent there by this computer.
    public static let viaCloud = "cloud"

    /// `settings.network` saying whether the switch came through Khayt Cloud.
    public static func marked(_ network: JSONValue?, viaCloud on: Bool) -> JSONValue {
        var n: [String: JSONValue] = { if case .object(let o)? = network { return o }; return [:] }()
        if on { n["via"] = .string(viaCloud) } else { n["via"] = nil }
        return .object(n)
    }

    /// The value a book's `settings.network` holds, for sending. Nil when it
    /// has no usable stamp: nothing is sent that could not be ordered.
    public static func value(of network: JSONValue?, purposes: Set<String>) -> Value? {
        guard case .object(let n)? = network, case .string(let at)? = n["changedAt"], date(at) != nil else { return nil }
        let offline: Bool = { guard let v = n["offline"] else { return false }; return v != .bool(false) && v != .null }()
        var keep: [String] = []
        if case .array(let list)? = n["keep"] {
            for case .string(let id) in list where purposes.contains(id) && !neverKept.contains(id) && !keep.contains(id) { keep.append(id) }
        }
        var by: String?
        if case .string(let name)? = n["changedBy"], !name.isEmpty { by = name }
        return Value(offline: offline, keep: keep, changedAt: at, changedBy: by)
    }
}
