import Foundation
import Testing
@testable import KhaytCore

/// The shop's switch as it travels through Khayt Cloud (`NetworkSwitch`,
/// khayt-cloud docs/api-contract.md): sealed with the shop's key, and obeyed
/// only when every one of the contract's checks holds.
@Suite struct NetworkSwitchTests {

    static let dek = Data(repeating: 7, count: 32)
    static let otherDek = Data(repeating: 9, count: 32)
    static let shop = "shop_1"
    static let purposes: Set<String> = Set(OutboundPurpose.allCases.map(\.rawValue))
    static let at = "2026-11-22T08:00:00.000Z"

    static func value(offline: Bool = true, keep: [String] = ["updates"], at: String = at, by: String? = "Sara") -> NetworkSwitch.Value {
        .init(offline: offline, keep: keep, changedAt: at, changedBy: by)
    }

    static func published(_ value: NetworkSwitch.Value, shopId: String = shop, dek: Data = dek, plainAt: String? = nil) throws -> NetworkSwitch.Published {
        let blob = try NetworkSwitch.seal(value, shopId: shopId, dek: dek)
        let json = try JSONEncoder().encode(JSONValue.object([
            "changedAt": .string(plainAt ?? value.changedAt), "receivedAt": .string("2026-11-22T08:00:01.000Z"),
            "ciphertext": try JSONValue.decode(JSONValue.self, from: JSONEncoder().encode(blob))]))
        return try JSONDecoder().decode(NetworkSwitch.Published.self, from: json)
    }

    static func sealed(_ plain: [String: JSONValue], at: String = at, dek: Data = dek) throws -> NetworkSwitch.Published {
        let blob = try SyncCrypto.seal(plain, dek: dek)
        let json = try JSONEncoder().encode(JSONValue.object([
            "changedAt": .string(at), "ciphertext": try JSONValue.decode(JSONValue.self, from: JSONEncoder().encode(blob))]))
        return try JSONDecoder().decode(NetworkSwitch.Published.self, from: json)
    }

    @Test("a stamp is strict UTC, a real date, 2020 or later, with up to three decimals")
    func stamps() {
        for good in ["2026-11-22T08:00:00Z", "2026-11-22T08:00:00.1Z", "2026-11-22T08:00:00.12Z", "2026-11-22T08:00:00.123Z",
                     "2024-02-29T23:59:59.999Z", "2020-01-01T00:00:00Z"] {
            #expect(NetworkSwitch.date(good) != nil, Comment(rawValue: good))
        }
        for bad in ["", "2026-11-22", "2026-11-22T08:00:00", "2026-11-22T08:00:00+03:00", "2026-11-22 08:00:00Z",
                    "2026-02-31T08:00:00Z", "2026-11-22T24:00:00Z", "2026-11-22T08:60:00Z", "2026-11-22T08:00:60Z",
                    "2026-13-01T08:00:00Z", "2019-12-31T23:59:59Z", "0000-01-01T00:00:00Z", "2026-11-22T08:00:00.Z",
                    "2026-11-22T08:00:00.1234Z", "2026-11-22T08:00:00.123456Z", "2026-11-22T08:00:00.12\u{0}Z",
                    "2025-02-29T00:00:00Z", "2026-11-22T08:00:00z", "٢٠٢٦-11-22T08:00:00Z"] {
            #expect(NetworkSwitch.date(bad) == nil, Comment(rawValue: bad))
        }
        let a = NetworkSwitch.date("2026-11-22T08:00:00.100Z")!, b = NetworkSwitch.date("2026-11-22T08:00:00.1Z")!
        #expect(a == b)
        #expect(NetworkSwitch.date("2026-11-22T08:00:00.123Z")!.timeIntervalSince(NetworkSwitch.date("2026-11-22T08:00:00Z")!) > 0.12)
        // What this app writes is one.
        #expect(NetworkSwitch.date(StoreWriter.iso(Date())) != nil)
    }

    @Test("a sealed value comes back as it was sent, and only with this shop's key")
    func roundTrip() throws {
        let sent = Self.value(keep: ["updates", "cloud"])
        let got = NetworkSwitch.read(try Self.published(sent), shopId: Self.shop, dek: Self.dek, highestSeen: nil, purposes: Self.purposes)
        #expect(got == .success(sent))
        #expect(NetworkSwitch.read(try Self.published(sent), shopId: Self.shop, dek: Self.otherDek, highestSeen: nil, purposes: Self.purposes) == .failure(.key))
        // The body a PUT carries: the store's envelope and the same stamp in the clear, small.
        let body = try NetworkSwitch.putBody(sent, shopId: Self.shop, dek: Self.dek)
        guard case .object(let o) = try JSONDecoder().decode(JSONValue.self, from: body), case .object(let c)? = o["ciphertext"] else {
            Issue.record("not the body"); return
        }
        #expect(o["changedAt"] == .string(Self.at) && Set(o.keys) == ["ciphertext", "changedAt"])
        #expect(Set(c.keys) == ["v", "z", "iv", "ct", "tag"] && c["v"] == .number(1) && c["z"] == .string("gzip"))
        #expect(body.count < 4096)
        #expect(!String(decoding: body, as: UTF8.self).contains("Sara"), "the name travels sealed, never in the clear")
    }

    @Test("each check refuses on its own: not this kind, version or shop; a stamp that is not the server's; nothing newer; not a boolean")
    func checks() throws {
        func read(_ p: NetworkSwitch.Published, seen: String? = nil) -> Result<NetworkSwitch.Value, NetworkSwitch.Ignored> {
            NetworkSwitch.read(p, shopId: Self.shop, dek: Self.dek, highestSeen: seen, purposes: Self.purposes)
        }
        let good: [String: JSONValue] = ["kind": .string(NetworkSwitch.kind), "v": .number(1), "shopId": .string(Self.shop),
                                         "offline": .bool(true), "keep": .array([]), "changedAt": .string(Self.at)]
        #expect(try read(Self.sealed(good)) == .success(.init(offline: true, keep: [], changedAt: Self.at, changedBy: nil)))
        // 2. A sealed store, a printer snapshot or another shop's switch replayed here.
        for (key, wrong) in [("kind", JSONValue.string("khayt-store")), ("v", .number(2)), ("shopId", .string("shop_2")), ("kind", .null)] {
            var p = good; p[key] = wrong
            #expect(try read(Self.sealed(p)) == .failure(.shape), Comment(rawValue: key))
        }
        #expect(NetworkSwitch.read(try Self.published(Self.value(), shopId: "shop_2"), shopId: Self.shop, dek: Self.dek,
                                   highestSeen: nil, purposes: Self.purposes) == .failure(.shape))
        // 3. The plain stamp is only for the server's ordering; the sealed one is the truth.
        #expect(try read(Self.published(Self.value(), plainAt: "2026-11-23T08:00:00.000Z")) == .failure(.stamp))
        #expect(try read(Self.published(Self.value(at: "2026-11-22T08:00:00.000Z"), plainAt: "2026-11-22T08:00:00Z")) == .failure(.stamp),
                "the same instant spelled differently is not the same stamp")
        // 4. Newer than the newest this computer has seen: a replayed old value is ignored.
        #expect(try read(Self.published(Self.value()), seen: Self.at) == .failure(.old))
        #expect(try read(Self.published(Self.value()), seen: "2026-11-22T09:00:00.000Z") == .failure(.old))
        #expect(try read(Self.published(Self.value()), seen: "2026-11-22T07:59:59.999Z") == .success(Self.value()))
        // 5. `offline` is a boolean; a stamp is a stamp.
        for (key, wrong) in [("offline", JSONValue.string("true")), ("offline", .number(1)), ("offline", .null),
                             ("changedAt", .string("yesterday")), ("changedAt", .number(1))] {
            var p = good; p[key] = wrong
            #expect(try read(Self.sealed(p)) == .failure(.malformed), Comment(rawValue: key))
        }
        var missing = good; missing["offline"] = nil
        #expect(try read(Self.sealed(missing)) == .failure(.malformed))
        #expect(try read(Self.sealed(good, at: "not a stamp")) == .failure(.malformed))
    }

    @Test("keep holds only purposes the rule knows, never lan or the switch-sync call; the name is text, cut to 80")
    func keepAndName() throws {
        var plain: [String: JSONValue] = ["kind": .string(NetworkSwitch.kind), "v": .number(1), "shopId": .string(Self.shop),
                                          "offline": .bool(true), "changedAt": .string(Self.at)]
        plain["keep"] = .array([.string("updates"), .string("lan"), .string("switch-sync"), .string("everything"),
                                .number(3), .string("updates"), .string("cloud"), .string("__proto__")])
        plain["changedBy"] = .string(String(repeating: "n", count: 200) + "\u{7}")
        let got = try NetworkSwitch.read(Self.sealed(plain), shopId: Self.shop, dek: Self.dek, highestSeen: nil, purposes: Self.purposes).get()
        #expect(got.keep == ["updates", "cloud"])
        #expect(got.changedBy?.count == 80)
        plain["keep"] = .string("updates")
        plain["changedBy"] = .number(4)
        let odd = try NetworkSwitch.read(Self.sealed(plain), shopId: Self.shop, dek: Self.dek, highestSeen: nil, purposes: Self.purposes).get()
        #expect(odd.keep.isEmpty && odd.changedBy == nil)
    }

    @Test("the age rule: a computer with no stamp of its own asks before an offline:true more than seven days old")
    func ageRule() throws {
        let now = NetworkSwitch.date("2026-11-30T08:00:00.001Z")!
        #expect(NetworkSwitch.asksFirst(Self.value(), hasOwnStamp: false, now: now), "eight days old")
        #expect(!NetworkSwitch.asksFirst(Self.value(), hasOwnStamp: true, now: now), "this computer has a stamp of its own")
        #expect(!NetworkSwitch.asksFirst(Self.value(offline: false), hasOwnStamp: false, now: now), "offline:false applies as usual")
        #expect(!NetworkSwitch.asksFirst(Self.value(), hasOwnStamp: false, now: NetworkSwitch.date("2026-11-29T07:59:59Z")!), "under seven days")
        // The same through `hearing`, with the two waits and the plain apply.
        let p = try Self.published(Self.value())
        func hear(seen: String? = nil, own: String? = nil, held: String? = nil, at when: Date = now) -> NetworkSwitch.Hearing {
            NetworkSwitch.hearing(p, shopId: Self.shop, dek: Self.dek, highestSeen: seen, ownStamp: own, heldStamp: held,
                                  purposes: Self.purposes, now: when)
        }
        #expect(hear() == .askOld(Self.value()))
        #expect(hear(own: "2026-11-01T00:00:00.000Z") == .apply(Self.value()))
        #expect(hear(seen: "2026-11-01T00:00:00.000Z") == .apply(Self.value()))
        #expect(hear(at: NetworkSwitch.date("2026-11-22T09:00:00Z")!) == .apply(Self.value()), "a fresh install, a fresh value")
        #expect(hear(own: Self.at) == .ignore(.old), "this computer's own change, read back")
        #expect(hear(own: "2026-11-01T00:00:00.000Z", held: Self.at) == .askChangedElsewhere(Self.value()),
                "the value a 409 named waits for the person, however often it is read")
        #expect(NetworkSwitch.hearing(p, shopId: Self.shop, dek: Self.otherDek, highestSeen: nil, ownStamp: nil, heldStamp: nil,
                                      purposes: Self.purposes, now: now) == .ignore(.key))
        // A stamp more than ten minutes ahead of this computer's clock is not applied.
        #expect(hear(own: "2026-11-01T00:00:00.000Z", at: NetworkSwitch.date("2026-11-22T07:49:59Z")!) == .ignore(.future))
        #expect(hear(own: "2026-11-01T00:00:00.000Z", at: NetworkSwitch.date("2026-11-22T07:50:01Z")!) == .apply(Self.value()))
    }

    @Test("the book: a value applied as it travelled and marked as from Khayt Cloud; the highest stamp only goes up")
    func book() {
        let before: JSONValue = .object(["offline": .bool(false), "keep": .array([.string("ai")]), "dropSwitchSync": .bool(true),
                                         "shareViaCloud": .bool(true), "changedAt": .string("2026-11-01T00:00:00.000Z")])
        guard case .object(let n) = NetworkSwitch.applied(Self.value(), to: before) else { Issue.record("not an object"); return }
        #expect(n["offline"] == .bool(true) && n["keep"] == .array([.string("updates")]))
        #expect(n["changedAt"] == .string(Self.at) && n["changedBy"] == .string("Sara") && n["via"] == .string("cloud"))
        #expect(n["dropSwitchSync"] == .bool(true) && n["shareViaCloud"] == .bool(true), "this computer's own choices stay")
        guard case .object(let cleared) = NetworkSwitch.marked(.object(n), viaCloud: false) else { return }
        #expect(cleared["via"] == nil && cleared["offline"] == .bool(true))
        #expect(NetworkSwitch.value(of: .object(n), purposes: Self.purposes) == Self.value())
        #expect(NetworkSwitch.value(of: .object(["offline": .bool(true)]), purposes: Self.purposes) == nil, "no stamp, nothing to order it by")
        #expect(NetworkSwitch.later(nil, Self.at) == Self.at && NetworkSwitch.later(Self.at, nil) == Self.at)
        #expect(NetworkSwitch.later(Self.at, "2026-11-22T07:00:00.000Z") == Self.at)
        #expect(NetworkSwitch.later(Self.at, "2026-11-22T09:00:00.000Z") == "2026-11-22T09:00:00.000Z")
        #expect(NetworkSwitch.later(Self.at, "garbage") == Self.at && NetworkSwitch.later(nil, "garbage") == nil)
    }

    @Test("the route is its own purpose, and the rule keeps its one call only when the switch came through Khayt Cloud")
    func purposeAndRule() {
        #expect(CloudReader.purpose(forTail: "/network-switch") == .switchSync)
        #expect(CloudReader.purpose(forTail: "/network-switch?x=1") == .switchSync)
        #expect(CloudReader.purpose(forTail: "/network-switches") == .cloud)
        #expect(CloudReader.purpose(forTail: "/store") == .cloud)
        func gate(_ network: [String: JSONValue], here: Bool = false) -> OutboundGate {
            let g = OutboundGate()
            g.update(local: .init(offline: here))
            g.update(book: .settings(.object(["network": .object(network)])))
            return g
        }
        let via: JSONValue = .string(NetworkSwitch.viaCloud)
        #expect(gate(["offline": .bool(false)]).verdict(.switchSync).allowed, "online: every signed-in computer may ask")
        #expect(gate(["offline": .bool(true), "via": via]).verdict(.switchSync).allowed, "the one call that is kept")
        #expect(!gate(["offline": .bool(true)]).verdict(.switchSync).allowed, "offline by its own switch: no call at all")
        #expect(!gate(["offline": .bool(true), "keep": .array([.string("switch-sync")])]).verdict(.switchSync).allowed, "never kept by a Keep tick")
        #expect(!gate(["offline": .bool(true), "keep": .array([.string("cloud")])]).verdict(.switchSync).allowed, "never kept by cloud")
        #expect(!gate(["offline": .bool(true), "via": via, "keep": .array([])]).verdict(.cloud).allowed, "and it keeps nothing else")
        #expect(!gate(["offline": .bool(true), "via": via, "dropSwitchSync": .bool(true)]).verdict(.switchSync).allowed, "the row unticked")
        #expect(!gate(["offline": .bool(true), "via": via], here: true).verdict(.switchSync).allowed, "this computer's own switch stops it too")
        #expect(!gate(["offline": .bool(true), "via": .string("lan")]).verdict(.switchSync).allowed)
    }

    @Test("a change is stamped by the shared rule: the clock, or one millisecond after the newest stamp seen")
    func monotonicStamp() async throws {
        let engine = try KhaytEngine()
        let now = try #require(NetworkSwitch.date("2026-11-22T10:00:00.000Z"))
        // Nothing seen, something older, or not a stamp: the clock.
        #expect(try await engine.networkSwitchStampAfter(now: now, seen: []) == "2026-11-22T10:00:00.000Z")
        #expect(try await engine.networkSwitchStampAfter(now: now, seen: [nil, "2026-11-22T09:59:59.999Z", "not a stamp"]) == "2026-11-22T10:00:00.000Z")
        // Seen at this very millisecond, or ahead (another computer's clock): one millisecond after the newest.
        #expect(try await engine.networkSwitchStampAfter(now: now, seen: ["2026-11-22T10:00:00.000Z"]) == "2026-11-22T10:00:00.001Z")
        #expect(try await engine.networkSwitchStampAfter(now: now, seen: ["2026-11-22T10:05:00.000Z", "2026-11-22T10:04:00.000Z"]) == "2026-11-22T10:05:00.001Z")
        #expect(try await engine.networkSwitchStampAfter(now: now, seen: ["2026-11-22T10:05:00Z"]) == "2026-11-22T10:05:00.001Z")
        // What it says is a stamp the Mac's own reader takes, and it survives being written and read.
        for seen in ["2026-11-22T10:05:00.123Z", "2026-11-22T10:04:59.999Z"] {
            let stamped = try await engine.networkSwitchStampAfter(now: now, seen: [seen])
            let seenAt = try #require(NetworkSwitch.date(seen)), at = try #require(NetworkSwitch.date(stamped))
            #expect(at > seenAt && StoreWriter.iso(at) == stamped, Comment(rawValue: "\(seen) → \(stamped) → \(StoreWriter.iso(at))"))
        }
        // Many in a row stay strictly increasing.
        var last = "2026-11-22T10:05:00.000Z"
        for _ in 0..<50 {
            let next = try await engine.networkSwitchStampAfter(now: now, seen: [last])
            #expect(try #require(NetworkSwitch.date(next)) > (try #require(NetworkSwitch.date(last))))
            last = next
        }
        // The rule itself ignores a seen stamp further ahead than the route accepts (ten minutes):
        // exactly ten minutes still counts, a millisecond more does not.
        #expect(try await engine.networkSwitchStampAfter(now: now, seen: ["2026-11-22T10:10:00.000Z"]) == "2026-11-22T10:10:00.001Z")
        #expect(try await engine.networkSwitchStampAfter(now: now, seen: ["2026-11-22T10:10:00.001Z"]) == "2026-11-22T10:00:00.000Z")
        #expect(try await engine.networkSwitchStampAfter(now: now, seen: ["2027-06-01T00:00:00.000Z", "2026-11-22T10:03:00.000Z"]) == "2026-11-22T10:03:00.001Z")
        #expect(try await engine.networkSwitchJustBefore("2026-11-22T10:05:00.000Z") == "2026-11-22T10:04:59.999Z")
        #expect(try await engine.networkSwitchJustBefore("junk") == nil)
    }
}
