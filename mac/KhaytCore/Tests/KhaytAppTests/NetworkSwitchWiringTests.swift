import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "Also tell my other computers through Khayt Cloud" on the Mac
/// (`Shop+NetworkSwitch`): the one last call when the switch is turned on,
/// the GET before turning it off, the 409 that is said and never obeyed
/// silently, the questions that wait for a person, and what is and is not
/// applied to the book. A fake Khayt Cloud answers and the book is in memory;
/// nothing here reaches the network or a file.
@Suite(.serialized) @MainActor
struct NetworkSwitchWiringTests {

    static let dek = Data(repeating: 5, count: 32)
    static let shopId = "shop_1"
    static let connection = CloudReader.Connection(url: "https://cloud.example.test", shopId: shopId, storedToken: "")
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/KhaytApp")

    /// What the fake server was asked, and what it answers next.
    actor Server {
        struct Asked: Sendable { let method: String; let path: String; let body: Data? }
        var asked: [Asked] = []
        var get: (Int, Data) = (404, Data(#"{"reason":"none"}"#.utf8))
        var put: (Int, Data) = (200, Data(#"{"ok":true}"#.utf8))
        func answerGet(_ status: Int, _ body: Data) { get = (status, body) }
        /// Answers for the next GETs, in order, before `get` is used again.
        var nextGets: [(Int, Data)] = []
        func answerNextGet(_ status: Int, _ body: Data) { nextGets.append((status, body)) }
        func answerPut(_ status: Int, _ body: Data) { put = (status, body) }
        func forget() { asked = [] }
        func handle(method: String, path: String, body: Data?) -> (Int, Data) {
            asked.append(.init(method: method, path: path, body: body))
            if method != "PUT", !nextGets.isEmpty { return nextGets.removeFirst() }
            return method == "PUT" ? put : get
        }
    }

    /// The owner at a Mac signed in to the fake cloud, with its own gate, its
    /// own defaults and a book in memory that the gate follows.
    static func shop(option: Bool, network: JSONValue? = nil) async -> (Shop, Server, NetworkBookForTests) {
        let shop = await OperatorLockTests.shop(on: false)
        shop.outboundDefaults = UserDefaults(suiteName: "khayt.netswitch.test.\(UUID().uuidString)")!
        shop.outboundGate = OutboundGate()
        let book = NetworkBookForTests(network)
        shop.networkBookForTests = book
        shop.feedsOutboundGate = true
        var settings = shop.settingsDict
        settings["network"] = network
        shop.settingsValue = .object(settings)
        shop.tellOutboundGate()
        let server = Server()
        shop.networkSwitchSessionForTests = (connection, "token", dek)
        shop.networkSwitchFetch = { request in
            let (status, body) = await server.handle(method: request.httpMethod ?? "", path: request.url?.path ?? "", body: request.httpBody)
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if option { shop.outboundDefaults.set(true, forKey: Shop.tellOthersKey) }
        return (shop, server, book)
    }

    static func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { return o }; return [:] }

    static func published(_ value: NetworkSwitch.Value, shopId: String = shopId) throws -> Data {
        let blob = try NetworkSwitch.seal(value, shopId: shopId, dek: dek)
        return try JSONEncoder().encode(JSONValue.object([
            "changedAt": .string(value.changedAt), "receivedAt": .string(value.changedAt),
            "ciphertext": try JSONValue.decode(JSONValue.self, from: JSONEncoder().encode(blob))]))
    }

    static func sent(_ body: Data?, _ shop: Shop) throws -> NetworkSwitch.Value {
        let p = try JSONDecoder().decode(NetworkSwitch.Published.self, from: try #require(body))
        return try NetworkSwitch.read(p, shopId: shopId, dek: dek, highestSeen: nil, purposes: shop.outboundPurposeIds).get()
    }

    /// Run with the shop's own gate as the one every request asks.
    static func gated<T>(_ shop: Shop, _ work: () async throws -> T) async rethrows -> T {
        try await OutboundGate.$scoped.withValue(shop.outboundGate) { try await work() }
    }

    static func stamp(_ secondsAgo: TimeInterval) -> String { StoreWriter.iso(Date().addingTimeInterval(-secondsAgo)) }

    // MARK: - Sending

    @Test("the row is offered now that its call is wired, and is off until the owner turns it on")
    func offered() async {
        #expect(Shop.tellOthersOffered)
        let (shop, _, _) = await Self.shop(option: false)
        #expect(!shop.outboundTellsOthers)
    }

    @Test("turned on with the option on: one PUT of the sealed switch, then the book says offline and from Khayt Cloud, and the gate stops")
    func turnedOnShared() async throws {
        let (shop, server, book) = await Self.shop(option: true)
        let ok = await Self.gated(shop) { await shop.setOutboundOffline(true) }
        #expect(ok)
        let asked = await server.asked
        #expect(asked.map(\.method) == ["PUT"] && asked[0].path == "/v1/shops/shop_1/network-switch")
        let n = Self.obj(book.network)
        #expect(n["offline"] == .bool(true) && n["via"] == .string("cloud"))
        // What was sent is what the book now holds, stamp for stamp.
        let value = try Self.sent(asked[0].body, shop)
        #expect(value.offline && JSONValue.string(value.changedAt) == n["changedAt"])
        if case .told = shop.outboundToldOthers {} else { Issue.record("not noted as told") }
        #expect(shop.networkSwitchHighestSeen == value.changedAt)
        // Stopped: Khayt Cloud is refused, and only the one call is kept.
        #expect(shop.outboundGate.isOffline && !shop.outboundGate.verdict(.cloud).allowed)
        #expect(shop.outboundGate.verdict(.switchSync).allowed)
    }

    @Test("turned on with the option off: nothing is sent, and no call is kept")
    func turnedOnAlone() async {
        let (shop, server, book) = await Self.shop(option: false)
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(true) })
        #expect(await server.asked.isEmpty)
        #expect(Self.obj(book.network)["offline"] == .bool(true) && Self.obj(book.network)["via"] == nil)
        #expect(!shop.outboundGate.verdict(.switchSync).allowed, "offline by its own switch: no call at all")
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(await server.asked.isEmpty)
    }

    @Test("Khayt Cloud not reached, or not the owner's token: the switch still goes on here, said as not told, with no call kept")
    func tellFails() async {
        for status in [500, 403, 429] {
            let (shop, server, book) = await Self.shop(option: true)
            await server.answerPut(status, Data("{}".utf8))
            #expect(await Self.gated(shop) { await shop.setOutboundOffline(true) }, Comment(rawValue: "\(status)"))
            #expect(shop.outboundToldOthers == .failed)
            #expect(Self.obj(book.network)["offline"] == .bool(true) && Self.obj(book.network)["via"] == nil)
        }
        let (shop, _, book) = await Self.shop(option: true)
        shop.networkSwitchFetch = { _ in throw URLError(.timedOut) }
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(true) })
        #expect(shop.outboundToldOthers == .failed && Self.obj(book.network)["via"] == nil)
    }

    @Test("the ten seconds are a real limit: an answer that never comes is not waited for")
    func capIsReal() async {
        let request = URLRequest(url: URL(string: "https://cloud.example.test/x")!)
        let started = Date()
        let answer = await Shop.capped(request, fetch: { _ in
            try await Task.sleep(for: .seconds(30))
            throw URLError(.timedOut)
        }, cap: 0.3)
        #expect(answer == nil && Date().timeIntervalSince(started) < 5)
        #expect(NetworkSwitch.lastCallCap == 10)
    }

    @Test("turned off: a GET first; a value published there is answered with offline:false even with this Mac's option off")
    func turningOff() async throws {
        let on: JSONValue = .object(["offline": .bool(true), "changedAt": .string(Self.stamp(3600))])
        // The option off here, and another computer published the switch.
        var (shop, server, book) = await Self.shop(option: false, network: on)
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: Self.stamp(7200), changedBy: nil)))
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        var asked = await server.asked
        #expect(asked.map(\.method) == ["GET", "PUT"], "the GET comes first, once this Mac is online again")
        let value = try Self.sent(asked[1].body, shop)
        #expect(value.offline == false && JSONValue.string(value.changedAt) == Self.obj(book.network)["changedAt"])
        #expect(Self.obj(book.network)["offline"] == .bool(false) && Self.obj(book.network)["via"] == nil)
        // The option off and nothing published: the shop does not share the switch.
        (shop, server, book) = await Self.shop(option: false, network: on)
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        asked = await server.asked
        #expect(asked.map(\.method) == ["GET"], "nothing is sent")
        #expect(shop.outboundToldOthers == nil)
        // The option on and nothing published (the owner stopped sharing, or
        // never shared): nothing is sent either. Turning a switch off
        // publishes nothing new (Dev Hub, Nov 22).
        (shop, server, book) = await Self.shop(option: true, network: on)
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        #expect(await server.asked.map(\.method) == ["GET"], "after the route's 404 nothing is sent")
        #expect(shop.networkSwitchUnsentOff == nil, "and nothing is left to retry")
        // This Mac's own switch on: it makes no call at all, even to say "off".
        (shop, server, book) = await Self.shop(option: true, network: on)
        shop.outboundDefaults.set(true, forKey: Shop.offlineHereKey)
        shop.tellOutboundGate()
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        #expect(await server.asked.isEmpty)
    }

    @Test("the order in the switch itself: only the owner, told before the book is written when turning on, the GET after when turning off")
    func orderInTheSwitch() throws {
        let src = try String(contentsOf: Self.sources.appending(path: "Shop+Outbound.swift"), encoding: .utf8)
        let body = try #require(src.range(of: "func setOutboundOffline("))
        let rest = src[body.upperBound...]
        let gate = try #require(rest.range(of: #"guard permitted("security", "edit")"#))
        let on = try #require(rest.range(of: "told = await tellOthersSwitchedOn(next)"))
        let write = try #require(rest.range(of: "guard await writeNetwork("))
        let off = try #require(rest.range(of: "await tellOthersSwitchedOff(next, seenBefore: seenBefore)"))
        #expect(gate.upperBound <= on.lowerBound && on.upperBound <= write.lowerBound && write.upperBound <= off.lowerBound)
    }

    @Test("a manager cannot send: the switch is refused before anything is asked of Khayt Cloud")
    func ownerOnly() async {
        let locked = await OperatorLockTests.shop()
        locked.outboundDefaults = UserDefaults(suiteName: "khayt.netswitch.test.\(UUID().uuidString)")!
        locked.outboundDefaults.set(true, forKey: Shop.tellOthersKey)
        locked.networkBookForTests = NetworkBookForTests()
        let server = Server()
        locked.networkSwitchSessionForTests = (Self.connection, "token", Self.dek)
        locked.networkSwitchFetch = { request in
            let (status, body) = await server.handle(method: request.httpMethod ?? "", path: "", body: nil)
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await locked.signIn("OP-m", pin: "2222") == .ok)
        #expect(await locked.setOutboundOffline(true) == false && LockReviewTests.refused(locked))
        #expect(await server.asked.isEmpty && locked.networkBookForTests?.network == nil)
    }

    // MARK: - A change made at another computer at the same moment (409)

    @Test("a 409: said, the other computer's value held, this Mac keeps what was set here, and nothing is retried")
    func changedElsewhere() async throws {
        let (shop, server, book) = await Self.shop(option: true)
        let theirs = Self.stamp(-2)   // two seconds after now: at or after this change
        await server.answerPut(409, Data(#"{"reason":"stale","changedAt":"\#(theirs)"}"#.utf8))
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: theirs, changedBy: "Noura")))
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(true) })
        #expect(await server.asked.map(\.method) == ["PUT", "GET"], "never retried with a fresh stamp; one read of what the other set")
        #expect(shop.networkSwitchAsk == .changedElsewhere(at: NetworkSwitch.date(theirs), turningOn: true))
        #expect(shop.networkSwitchHeld?.changedAt == theirs && shop.networkSwitchHeldStamp == theirs)
        #expect(shop.networkSwitchAsk?.choices.map(\.key) == ["mac.net_ask_newer", "mac.net_ask_here_only"])
        #expect(Self.obj(book.network)["offline"] == .bool(true), "what the person set here stands")
        #expect(Self.obj(book.network)["via"] == nil, "not shared, so no call is kept")
        #expect(shop.outboundToldOthers == nil, "neither told nor unreachable is claimed")
    }

    @Test("turning ON beaten by another computer's OFF: \"Keep it on this Mac only\" turns this Mac's own switch on and lets the shop's follow")
    func keepOnThisMacOnly() async throws {
        let (shop, server, book) = await Self.shop(option: true)
        let theirs = Self.stamp(-2)
        await server.answerPut(409, Data(#"{"reason":"stale","changedAt":"\#(theirs)"}"#.utf8))
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: theirs, changedBy: "Noura")))
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(true) })
        await shop.answerNetworkSwitch(apply: false)
        #expect(shop.outboundOfflineHere, "this Mac alone makes no internet calls")
        #expect(Self.obj(book.network)["offline"] == .bool(false) && Self.obj(book.network)["changedAt"] == .string(theirs),
                "the shop's switch follows the newer setting")
        #expect(shop.outboundGate.isOffline && !shop.outboundGate.verdict(.cloud).allowed && !shop.outboundGate.verdict(.switchSync).allowed)
        #expect(shop.networkSwitchAsk == nil && shop.networkSwitchHeldStamp == nil)
        // "Use the newer setting" instead: the shop's switch is off here too, and this Mac's own is untouched.
        let (other, server2, book2) = await Self.shop(option: true)
        await server2.answerPut(409, Data(#"{"reason":"stale","changedAt":"\#(theirs)"}"#.utf8))
        await server2.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: theirs, changedBy: "Noura")))
        #expect(await Self.gated(other) { await other.setOutboundOffline(true) })
        await other.answerNetworkSwitch(apply: true)
        #expect(Self.obj(book2.network)["offline"] == .bool(false) && !other.outboundOfflineHere && !other.outboundGate.isOffline)
    }

    @Test("turning OFF beaten by another computer's ON: the only choice is the newer setting; this Mac is never left online against the shop")
    func turningOffLoses() async throws {
        let on: JSONValue = .object(["offline": .bool(true), "via": .string("cloud"), "changedAt": .string(Self.stamp(3600))])
        let (shop, server, book) = await Self.shop(option: true, network: on)
        let theirs = Self.stamp(-2)
        // A value is published there, so the "off" is sent; it is beaten (409),
        // and the GET that would read the other value fails at first.
        await server.answerNextGet(200, try Self.published(.init(offline: true, keep: [], changedAt: Self.stamp(3600), changedBy: nil)))
        await server.answerGet(500, Data())
        await server.answerPut(409, Data(#"{"reason":"stale","changedAt":"\#(theirs)"}"#.utf8))
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        #expect(shop.networkSwitchAsk == .changedElsewhere(at: NetworkSwitch.date(theirs), turningOn: false) && shop.networkSwitchHeld == nil)
        #expect(shop.networkSwitchAsk?.choices.map(\.key) == ["mac.net_ask_newer"], "no \"keep\" when it would loosen the shop's switch")
        // Even an answer of "no" is read as the newer setting: nothing here can leave the Mac online for good.
        // The value is not held, so the answer reads it; the read fails, and the question stays.
        await server.forget()
        await Self.gated(shop) { await shop.answerNetworkSwitch(apply: false) }
        #expect(await server.asked.map(\.method) == ["GET"])
        #expect(shop.networkSwitchAsk == .changedElsewhere(at: NetworkSwitch.date(theirs), turningOn: false), "never cleared with nothing applied")
        #expect(!shop.outboundOfflineHere && shop.networkSwitchAnswerProblem == shop.words.callIt("mac.net_ask_unreached"))
        #expect(shop.networkSwitchHighestSeen != theirs, "not marked seen")
        // Khayt Cloud answers: the same answer now applies the newer setting.
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: theirs, changedBy: "Noura")))
        await Self.gated(shop) { await shop.answerNetworkSwitch(apply: false) }
        #expect(shop.networkSwitchAsk == nil && shop.networkSwitchAnswerProblem == nil)
        #expect(Self.obj(book.network)["offline"] == .bool(true) && Self.obj(book.network)["via"] == .string("cloud"))
        #expect(shop.outboundGate.isOffline)
    }

    @Test("an old switch left as it is stays left: a later check does not apply it behind the person's back")
    func leaveHolds() async throws {
        let (shop, server, book) = await Self.shop(option: false)
        let old = Self.stamp(9 * 86_400)
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: old, changedBy: nil)))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(shop.networkSwitchAsk?.choices.map(\.key) == ["mac.net_ask_apply", "mac.net_ask_leave"])
        await shop.answerNetworkSwitch(apply: false)
        #expect(shop.networkSwitchHighestSeen == old && book.network == nil)
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(book.network == nil && shop.networkSwitchAsk == nil, "not asked again, not applied")
    }

    @Test("an old value replayed behind a 409 is not offered")
    func replayBehind409() async throws {
        let before = Self.stamp(3600)
        let (shop, server, _) = await Self.shop(option: true, network: .object(["offline": .bool(false), "changedAt": .string(before)]))
        shop.sawNetworkSwitchStamp(before)
        await server.answerPut(409, Data(#"{"reason":"stale"}"#.utf8))
        // Validly sealed, but older than what this Mac had already seen.
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: Self.stamp(86_400), changedBy: nil)))
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(true) })
        #expect(shop.networkSwitchHeld == nil, "nothing old is held to be applied")
        #expect(shop.networkSwitchAsk == .changedElsewhere(at: nil, turningOn: true), "the 409 itself is still said")
    }

    // MARK: - Hearing and applying

    @Test("a value from another computer is applied to the book: offline, kept purposes, stamp, and marked as from Khayt Cloud")
    func applies() async throws {
        let (shop, server, book) = await Self.shop(option: false, network: .object(["offline": .bool(false), "changedAt": .string(Self.stamp(86_400))]))
        let theirs = Self.stamp(60)
        await server.answerGet(200, try Self.published(.init(offline: true, keep: ["updates", "lan", "nonsense"], changedAt: theirs, changedBy: "Sara")))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        let n = Self.obj(book.network)
        #expect(n["offline"] == .bool(true) && n["keep"] == .array([.string("updates")]))
        #expect(n["changedAt"] == .string(theirs) && n["changedBy"] == .string("Sara") && n["via"] == .string("cloud"))
        #expect(shop.networkSwitchHighestSeen == theirs && shop.networkSwitchAsk == nil)
        #expect(shop.outboundGate.isOffline && shop.outboundGate.verdict(.updates).allowed && !shop.outboundGate.verdict(.cloud).allowed)
        #expect(shop.outboundGate.verdict(.switchSync).allowed, "the one call that hears it turned off")
        #expect(!shop.outboundOfflineHere, "this Mac's own switch is never touched")
        // The same value again changes nothing; an older one is ignored.
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: Self.stamp(7200), changedBy: nil)))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(Self.obj(book.network)["offline"] == .bool(true), "a replayed older \"off\" does not bring this Mac back online")
        // Turned off elsewhere: this Mac comes back online, through the one call it kept.
        let back = Self.stamp(1)
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: back, changedBy: "Sara")))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(Self.obj(book.network)["offline"] == .bool(false) && !shop.outboundGate.isOffline)
    }

    @Test("ignored without a word: another shop's value, another key, a stamp far ahead, an answer that is not one")
    func ignored() async throws {
        let (shop, server, book) = await Self.shop(option: false)
        let before = book.network
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: Self.stamp(60), changedBy: nil), shopId: "shop_2"))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        let ahead = Self.stamp(-3600)
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: ahead, changedBy: nil)))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        await server.answerGet(200, Data("not json".utf8))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(book.network == before && shop.networkSwitchAsk == nil && shop.networkSwitchHeld == nil)
        #expect(shop.networkSwitchHighestSeen == nil, "a stamp far ahead is not remembered either")
        // A clock that was wrong once does not poison what is remembered.
        shop.sawNetworkSwitchStamp(ahead)
        #expect(shop.networkSwitchHighestSeen == nil)
    }

    @Test("a 404 that is the route's own ends the one call; any other 404 does not")
    func stopsSharing() async throws {
        let shared: JSONValue = .object(["offline": .bool(true), "via": .string("cloud"), "changedAt": .string(Self.stamp(3600))])
        let (shop, server, book) = await Self.shop(option: false, network: shared)
        await server.answerGet(404, Data("<html>Not Found</html>".utf8))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(Self.obj(book.network)["via"] == .string("cloud"), "a proxy's 404 is not the shop stopping sharing")
        await server.answerGet(404, Data(#"{"reason":"none"}"#.utf8))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(Self.obj(book.network)["via"] == nil && Self.obj(book.network)["offline"] == .bool(true), "the call ends; the switch stays as it was")
        await server.forget()
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(await server.asked.isEmpty, "and nothing more is asked")
    }

    @Test("this Mac's own switch stops even the one call")
    func ownSwitchStopsIt() async {
        let shared: JSONValue = .object(["offline": .bool(true), "via": .string("cloud"), "changedAt": .string(Self.stamp(3600))])
        let (shop, server, _) = await Self.shop(option: false, network: shared)
        shop.outboundDefaults.set(true, forKey: Shop.offlineHereKey)
        shop.tellOutboundGate()
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(await server.asked.isEmpty)
    }

    // MARK: - The old switch on a new install

    @Test("a new install meeting an old offline:true asks, applies nothing until answered, and then applies it")
    func oldSwitchAsks() async throws {
        let (shop, server, book) = await Self.shop(option: false)
        let old = Self.stamp(9 * 86_400)
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: old, changedBy: "Sara")))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(shop.networkSwitchAsk == .oldSwitch(at: NetworkSwitch.date(old)))
        #expect(book.network == nil, "nothing is applied on its own")
        let said = NetworkSwitchWords.sentence(try #require(shop.networkSwitchAsk), there: shop.networkSwitchHeld?.offline, words: shop.words)
        #expect(said.hasPrefix("Your shop turned off internet use on ") && said.hasSuffix("Apply it here?"))
        await shop.answerNetworkSwitch(apply: true)
        #expect(Self.obj(book.network)["offline"] == .bool(true) && Self.obj(book.network)["via"] == .string("cloud"))
        #expect(shop.networkSwitchAsk == nil && shop.networkSwitchHighestSeen == old)
    }

    @Test("an old question answered late never puts the older value back over a newer one")
    func oldQuestionOvertaken() async throws {
        let (shop, server, book) = await Self.shop(option: false)
        let old = Self.stamp(9 * 86_400), newer = Self.stamp(60)
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: old, changedBy: nil)))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(shop.networkSwitchAsk != nil)
        // Before anyone answers, the shop turns the switch off again.
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: newer, changedBy: nil)))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(shop.networkSwitchAsk == nil && shop.networkSwitchHeld == nil, "the question is about a switch the shop has since changed")
        #expect(Self.obj(book.network)["offline"] == .bool(false))
        // And if the old value were still offered and accepted, the write itself refuses it.
        shop.networkSwitchHeld = .init(offline: true, keep: [], changedAt: old, changedBy: nil)
        shop.networkSwitchAsk = .oldSwitch(at: nil)
        await shop.answerNetworkSwitch(apply: true)
        #expect(Self.obj(book.network)["offline"] == .bool(false), "not stuck offline while the shop is online")
        #expect(await shop.applyNetworkSwitch(.init(offline: true, keep: [], changedAt: old, changedBy: nil), shopId: Self.shopId) == false)
        #expect(await shop.applyNetworkSwitch(.init(offline: true, keep: [], changedAt: Self.stamp(1), changedBy: nil), shopId: "shop_2") == false,
                "nor a value for another shop")
    }

    @Test("after a restart, a question that was waiting is asked again, and what is published now waits with it")
    func restart() async throws {
        let (shop, server, book) = await Self.shop(option: false, network: .object(["offline": .bool(true), "changedAt": .string(Self.stamp(600))]))
        let theirs = Self.stamp(300)
        shop.outboundDefaults.set(theirs, forKey: Shop.heldStampKey(Self.shopId))
        // As at launch, without the loop: the question comes back.
        shop.startNetworkSwitchChecks()
        shop.networkSwitchTask?.cancel()
        #expect(shop.networkSwitchAsk == .changedElsewhere(at: NetworkSwitch.date(theirs), turningOn: false))
        // Online again for the test's sake, a newer value is published: it waits too.
        var settings = shop.settingsDict
        settings["network"] = .object(["offline": .bool(false), "changedAt": .string(Self.stamp(600))])
        shop.settingsValue = .object(settings)
        book.network = settings["network"]
        let newer = Self.stamp(30)
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: newer, changedBy: nil)))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(Self.obj(book.network)["offline"] == .bool(false), "not applied while the question stands")
        #expect(shop.networkSwitchHeld?.changedAt == newer)
    }

    // MARK: - "Use the newer setting" when the newer setting is not held (Dev Hub, Nov 22)

    /// The owner turned the switch ON, another computer won (409), and the
    /// read of what it set failed: the question waits with only a stamp.
    static func beatenUnread() async throws -> (Shop, Server, NetworkBookForTests, theirs: String) {
        let (shop, server, book) = await Self.shop(option: true)
        let theirs = Self.stamp(-2)
        await server.answerPut(409, Data(#"{"reason":"stale","changedAt":"\#(theirs)"}"#.utf8))
        await server.answerGet(500, Data())
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(true) })
        #expect(shop.networkSwitchAsk == .changedElsewhere(at: NetworkSwitch.date(theirs), turningOn: true))
        #expect(shop.networkSwitchHeld == nil && shop.networkSwitchHeldStamp == theirs)
        #expect(Self.obj(book.network)["offline"] == .bool(true) && Self.obj(book.network)["via"] == nil)
        #expect(!shop.hearsNetworkSwitch, "offline by a switch that did not come through Khayt Cloud: no check may ask")
        await server.forget()
        return (shop, server, book, theirs)
    }

    @Test("the answer reads the newer setting once, even while offline, and applies it")
    func answerReadsAndApplies() async throws {
        let (shop, server, book, theirs) = try await Self.beatenUnread()
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: theirs, changedBy: "Noura")))
        await Self.gated(shop) { await shop.answerNetworkSwitch(apply: true) }
        #expect(await server.asked.map(\.method) == ["GET"], "one read, the answer's own")
        #expect(Self.obj(book.network)["offline"] == .bool(false) && Self.obj(book.network)["changedAt"] == .string(theirs))
        #expect(!shop.outboundGate.isOffline && !shop.outboundOfflineHere)
        #expect(shop.networkSwitchAsk == nil && shop.networkSwitchHeldStamp == nil && shop.networkSwitchAnswerProblem == nil)
        #expect(!shop.networkSwitchAnswering)
    }

    @Test("the read fails: the question stays, nothing is applied, and it says Khayt Cloud could not be reached; asked again, it works")
    func answerKeepsTheQuestion() async throws {
        let (shop, server, book, theirs) = try await Self.beatenUnread()
        await Self.gated(shop) { await shop.answerNetworkSwitch(apply: true) }
        #expect(await server.asked.map(\.method) == ["GET"], "one read, not a retry loop")
        #expect(shop.networkSwitchAsk == .changedElsewhere(at: NetworkSwitch.date(theirs), turningOn: true), "never cleared with nothing applied")
        #expect(shop.networkSwitchHeldStamp == theirs && shop.networkSwitchHeldTurningOn)
        #expect(shop.networkSwitchAnswerProblem == shop.words.callIt("mac.net_ask_unreached"))
        #expect(Self.obj(book.network)["offline"] == .bool(true) && shop.outboundGate.isOffline, "this Mac is as it was")
        #expect(!shop.networkSwitchAnswering)
        // Khayt Cloud is back: the same button now reads it and applies it.
        await server.forget()
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: theirs, changedBy: nil)))
        await Self.gated(shop) { await shop.answerNetworkSwitch(apply: true) }
        #expect(Self.obj(book.network)["offline"] == .bool(false))
        #expect(shop.networkSwitchAsk == nil && shop.networkSwitchAnswerProblem == nil)
    }

    @Test("Khayt Cloud holds nothing, a replayed older value, or this Mac's own switch: the question stays and nothing is applied")
    func answerEdges() async throws {
        // Nothing published there any more.
        var (shop, server, book, theirs) = try await Self.beatenUnread()
        await server.answerGet(404, Data(#"{"reason":"none"}"#.utf8))
        await Self.gated(shop) { await shop.answerNetworkSwitch(apply: true) }
        #expect(shop.networkSwitchAsk != nil && shop.networkSwitchAnswerProblem == shop.words.callIt("mac.net_ask_nothing_there"))
        #expect(Self.obj(book.network)["offline"] == .bool(true))

        // A value older than the one the 409 spoke of is not the newer setting.
        (shop, server, book, theirs) = try await Self.beatenUnread()
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: Self.stamp(3600), changedBy: nil)))
        await Self.gated(shop) { await shop.answerNetworkSwitch(apply: true) }
        #expect(shop.networkSwitchAsk == .changedElsewhere(at: NetworkSwitch.date(theirs), turningOn: true))
        #expect(shop.networkSwitchAnswerProblem == shop.words.callIt("mac.net_ask_unreached"))
        #expect(Self.obj(book.network)["offline"] == .bool(true), "an old value replayed is not applied")

        // Under this Mac's own switch no call is made at all.
        (shop, server, book, theirs) = try await Self.beatenUnread()
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: theirs, changedBy: nil)))
        _ = shop.setOutboundOfflineHere(true)
        await server.forget()
        await Self.gated(shop) { await shop.answerNetworkSwitch(apply: true) }
        #expect(await server.asked.isEmpty, "this Mac's own switch is stricter than the owner's answer")
        #expect(shop.networkSwitchAsk != nil && Self.obj(book.network)["offline"] == .bool(true))
    }

    @Test("after a restart only the stamp is kept: the answer still reads and applies; a held value makes no call")
    func answerAfterRestart() async throws {
        let mine = Self.stamp(600)
        let (shop, server, book) = await Self.shop(option: false, network: .object(["offline": .bool(true), "changedAt": .string(mine)]))
        let theirs = Self.stamp(300)
        shop.outboundDefaults.set(theirs, forKey: Shop.heldStampKey(Self.shopId))
        shop.outboundDefaults.set(true, forKey: Shop.heldTurningOnKey(Self.shopId))
        shop.startNetworkSwitchChecks()
        shop.networkSwitchTask?.cancel()
        #expect(shop.networkSwitchAsk == .changedElsewhere(at: NetworkSwitch.date(theirs), turningOn: true) && shop.networkSwitchHeld == nil)
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: theirs, changedBy: nil)))
        await server.forget()
        await Self.gated(shop) { await shop.answerNetworkSwitch(apply: true) }
        #expect(await server.asked.map(\.method) == ["GET"])
        #expect(Self.obj(book.network)["offline"] == .bool(false) && shop.networkSwitchAsk == nil)

        // With the value held (the usual 409), the answer asks nothing.
        let (held, server2, book2) = await Self.shop(option: true)
        let at = Self.stamp(-2)
        await server2.answerPut(409, Data(#"{"reason":"stale","changedAt":"\#(at)"}"#.utf8))
        await server2.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: at, changedBy: nil)))
        #expect(await Self.gated(held) { await held.setOutboundOffline(true) })
        await server2.forget()
        await Self.gated(held) { await held.answerNetworkSwitch(apply: true) }
        #expect(await server2.asked.isEmpty && Self.obj(book2.network)["offline"] == .bool(false))
    }

    @Test("the owner's answer is the shared rule's token: one switch-sync call, then spent; no other purpose, never under this Mac's own switch")
    func answerToken() throws {
        let off: JSONValue = .object(["network": .object(["offline": .bool(true), "changedAt": .string(Self.stamp(60))])])
        let gate = OutboundGate()
        gate.update(book: .settings(off))
        #expect(throws: (any Error).self) { try gate.require(.switchSync) }
        let answer = try #require(gate.answerToken())
        #expect(gate.answerLive(answer))
        try OutboundGate.$answer.withValue(answer) {
            // Asking without calling does not use it.
            #expect(!gate.verdict(.switchSync).allowed, "a screen that only asks is not the person's call")
            #expect(gate.answerLive(answer))
            // No other purpose is opened by it.
            #expect(throws: (any Error).self) { try gate.require(.cloud) }
            #expect(!gate.allows(.updates))
            #expect(gate.answerLive(answer), "a refused call for another purpose does not use it")
            // The one call.
            try gate.require(.switchSync)
            #expect(!gate.answerLive(answer), "spent by the gate when the rule said once")
            #expect(throws: (any Error).self) { try gate.require(.switchSync) }
        }
        // Never under this Mac's own switch, and it is not used up by the refusal.
        let here = OutboundGate()
        here.update(book: .settings(off))
        here.update(local: .init(offline: true))
        let unused = try #require(here.answerToken())
        OutboundGate.$answer.withValue(unused) {
            #expect(throws: (any Error).self) { try here.require(.switchSync) }
        }
        #expect(here.answerLive(unused))
        // A book not read yet waits, with or without the answer.
        let unread = OutboundGate()
        unread.update(book: .unread)
        let waiting = try #require(unread.answerToken())
        OutboundGate.$answer.withValue(waiting) {
            #expect(throws: (any Error).self) { try unread.require(.switchSync) }
        }
        // Live for the rule's 20 seconds, by the gate's clock, and no longer.
        let clock = Clock()
        let timed = OutboundGate(clock: { clock.now })
        timed.update(book: .settings(off))
        let old = try #require(timed.answerToken())
        clock.now = clock.now.addingTimeInterval(19)
        #expect(timed.answerLive(old))
        clock.now = clock.now.addingTimeInterval(2)
        #expect(!timed.answerLive(old))
        OutboundGate.$answer.withValue(old) {
            #expect(throws: (any Error).self) { try timed.require(.switchSync) }
        }
        // With the shop online the call is allowed anyway, and the token is kept.
        let online = OutboundGate()
        online.update(book: .settings(.object([:])))
        let spare = try #require(online.answerToken())
        try OutboundGate.$answer.withValue(spare) { try online.require(.switchSync) }
        #expect(online.answerLive(spare), "nothing to spend when the rule allowed it without the answer")
        // Nothing in the app sets the old local exception any more.
        let gateSource = try String(contentsOf: Self.sources.deletingLastPathComponent().appending(path: "KhaytCore/OutboundGate.swift"), encoding: .utf8)
        #expect(!gateSource.contains("ownersSwitchAnswer"))
        #expect(gateSource.contains("KhaytOutbound.answerToken(ARG0)") && gateSource.contains("KhaytOutbound.spend(ARG0)"))
    }

    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_795_000_000) }

    @Test("an \"off\" that could not be sent is sent again with the same stamp, until sent or superseded")
    func unsentOffIsRetried() async throws {
        let on: JSONValue = .object(["offline": .bool(true), "changedAt": .string(Self.stamp(3600)), "via": .string("cloud")])
        let there = try Self.published(.init(offline: true, keep: [], changedAt: Self.stamp(3600), changedBy: nil))

        // The PUT is refused (Khayt Cloud is down): remembered, with the change's own stamp.
        var (shop, server, book) = await Self.shop(option: true, network: on)
        await server.answerGet(200, there)
        await server.answerPut(503, Data())
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        let stamp = try #require(shop.networkSwitchUnsentOff)
        #expect(JSONValue.string(stamp) == Self.obj(book.network)["changedAt"])
        #expect(Self.obj(book.network)["offline"] == .bool(false), "this Mac is online; only the telling failed")
        // Still down at the next check: still remembered.
        await server.forget()
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == .unsent)
        #expect(shop.networkSwitchUnsentOff == stamp)
        // Back: the SAME change goes, with the same stamp, and is forgotten.
        await server.answerPut(200, Data(#"{"ok":true}"#.utf8))
        await server.forget()
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        let asked = await server.asked
        #expect(asked.prefix(2).map(\.method) == ["GET", "PUT"], "the check sends it before it listens")
        let resent = try Self.sent(asked[1].body, shop)
        #expect(resent.offline == false && resent.changedAt == stamp, "never a fresh stamp")
        #expect(shop.networkSwitchUnsentOff == nil)
        await server.forget()
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == nil, "sent once, not again")
        #expect(await server.asked.isEmpty)

        // The GET fails (not known whether anything is published): also remembered.
        (shop, server, book) = await Self.shop(option: false, network: on)
        await server.answerGet(500, Data())
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        #expect(shop.networkSwitchUnsentOff != nil)
        #expect(await server.asked.map(\.method) == ["GET"], "nothing is sent on a guess")
        // The owner stopped sharing meanwhile: the route's 404 ends it, nothing is sent.
        await server.answerGet(404, Data(#"{"reason":"none"}"#.utf8))
        await server.forget()
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == .nothingPublished)
        #expect(shop.networkSwitchUnsentOff == nil)
        #expect(await server.asked.map(\.method) == ["GET"])

        // Superseded by turning the switch on again here: the old "off" is dropped, never sent late.
        (shop, server, book) = await Self.shop(option: true, network: on)
        await server.answerGet(200, there)
        await server.answerPut(503, Data())
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        #expect(shop.networkSwitchUnsentOff != nil)
        await server.answerPut(200, Data(#"{"ok":true}"#.utf8))
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(true) })
        #expect(shop.networkSwitchUnsentOff == nil)
        await server.forget()
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == nil)
        #expect(await server.asked.isEmpty, "an off the shop has since undone is not sent")

        // Superseded by a newer value seen from Khayt Cloud.
        (shop, server, book) = await Self.shop(option: true, network: on)
        await server.answerGet(200, there)
        await server.answerPut(503, Data())
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        let waiting = try #require(shop.networkSwitchUnsentOff)
        shop.sawNetworkSwitchStamp(StoreWriter.iso(Date().addingTimeInterval(30)))
        #expect(!shop.unsentOffStillStands(waiting))
        await server.forget()
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == nil)
        #expect(shop.networkSwitchUnsentOff == nil)
        #expect(await server.asked.isEmpty)

        // A 409 on the retry: beaten by something newer. The old "off" is dropped and
        // NOTHING is asked: a question here would hold the newer value back (review).
        (shop, server, book) = await Self.shop(option: true, network: on)
        await server.answerGet(200, there)
        await server.answerPut(503, Data())
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        // (between this retry's GET and its PUT, another computer published a newer value)
        let newer = StoreWriter.iso(Date().addingTimeInterval(5))
        await server.answerNextGet(200, there)
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: newer, changedBy: nil)))
        await server.answerPut(409, Data(#"{"changedAt":"\#(newer)"}"#.utf8))
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == .superseded)
        #expect(shop.networkSwitchUnsentOff == nil)
        #expect(shop.networkSwitchAsk == nil && shop.networkSwitchHeld == nil, "a retry never asks")
    }

    @Test("a retried off never goes over a newer setting: the other computer's ON is heard and applied, with no question")
    func retryNeverBeatsNewer() async throws {
        let on: JSONValue = .object(["offline": .bool(true), "changedAt": .string(Self.stamp(3600)), "via": .string("cloud")])
        let old = try Self.published(.init(offline: true, keep: [], changedAt: Self.stamp(3600), changedBy: nil))
        let (shop, server, book) = await Self.shop(option: true, network: on)
        await server.answerGet(200, old)
        await server.answerPut(503, Data())
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        let mine = try #require(shop.networkSwitchUnsentOff)
        #expect(Self.obj(book.network)["offline"] == .bool(false))
        // Another computer turns the switch ON after that, and publishes it.
        let theirs = StoreWriter.iso(try #require(NetworkSwitch.date(mine)).addingTimeInterval(1))
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: theirs, changedBy: "Noura")))
        await server.answerPut(200, Data(#"{"ok":true}"#.utf8))
        await server.forget()
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        let asked = await server.asked
        #expect(!asked.contains { $0.method == "PUT" }, "the older off is not sent over the newer on")
        #expect(shop.networkSwitchUnsentOff == nil)
        #expect(shop.networkSwitchAsk == nil, "nothing is asked: the shop's newer word is simply followed")
        #expect(Self.obj(book.network)["offline"] == .bool(true), "this Mac follows the shop offline at this very check")
        #expect(shop.outboundGate.isOffline)
    }

    @Test("an off that did arrive (its answer was lost) is not sent again, and the owner is not asked about their own change")
    func lostAnswerIsNotAConflict() async throws {
        let on: JSONValue = .object(["offline": .bool(true), "changedAt": .string(Self.stamp(3600)), "via": .string("cloud")])
        let old = try Self.published(.init(offline: true, keep: [], changedAt: Self.stamp(3600), changedBy: nil))
        let (shop, server, _) = await Self.shop(option: true, network: on)
        await server.answerGet(200, old)
        await server.answerPut(503, Data())   // as this Mac saw it; the server had stored it
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        let mine = try #require(shop.networkSwitchUnsentOff)
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: mine, changedBy: nil)))
        await server.answerPut(409, Data(#"{"changedAt":"\#(mine)"}"#.utf8))
        await server.forget()
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == .sent)
        #expect(await server.asked.map(\.method) == ["GET"], "found there with its own stamp: nothing is sent")
        #expect(shop.networkSwitchUnsentOff == nil && shop.networkSwitchAsk == nil)
        #expect(shop.outboundToldOthers != nil, "the others were told")
    }

    @Test("a refusal that will never pass ends the retry; one that may pass keeps it; never under this Mac's own switch")
    func retryStops() async throws {
        let on: JSONValue = .object(["offline": .bool(true), "changedAt": .string(Self.stamp(3600)), "via": .string("cloud")])
        let old = try Self.published(.init(offline: true, keep: [], changedAt: Self.stamp(3600), changedBy: nil))
        for (status, kept) in [(403, false), (400, false), (413, false), (429, true), (500, true), (408, true)] {
            #expect(Shop.refusalMayPass(status) == kept)
            let (shop, server, _) = await Self.shop(option: true, network: on)
            await server.answerGet(200, old)
            await server.answerPut(status, Data())
            #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
            #expect((shop.networkSwitchUnsentOff != nil) == kept, Comment(rawValue: "\(status)"))
            if !kept {
                await server.forget()
                #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == nil)
                #expect(await server.asked.isEmpty, "not asked again at every check")
            }
        }
        // This Mac's own switch: the retry makes no call and keeps the change for later.
        let (shop, server, _) = await Self.shop(option: true, network: on)
        await server.answerGet(200, old)
        await server.answerPut(503, Data())
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        shop.outboundDefaults.set(true, forKey: Shop.offlineHereKey)
        shop.tellOutboundGate()
        await server.forget()
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == .unsent)
        #expect(await server.asked.isEmpty && shop.networkSwitchUnsentOff != nil)
        // One at a time.
        shop.outboundDefaults.set(false, forKey: Shop.offlineHereKey)
        shop.tellOutboundGate()
        shop.networkSwitchRetrying = true
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == nil)
        #expect(await server.asked.isEmpty)
    }

    @Test("the owner's read applies BOTH floors: older than the 409's stamp is not it; older than a later change here ends the question")
    func bothFloors() async throws {
        // Offline here by the shop's switch, set at `own`; a question waits from a 409 that named `conflict`.
        let own = Self.stamp(60), conflict = Self.stamp(600)
        let on: JSONValue = .object(["offline": .bool(true), "changedAt": .string(own)])
        func asking() async -> (Shop, Server, NetworkBookForTests) {
            let (shop, server, book) = await Self.shop(option: true, network: on)
            shop.outboundDefaults.set(conflict, forKey: Shop.heldStampKey(Self.shopId))
            // The question was asked about an EARLIER change; the owner has changed the switch here since (`own`).
            shop.noteAskedAbout(Self.stamp(700))
            shop.networkSwitchAsk = .changedElsewhere(at: NetworkSwitch.date(conflict), turningOn: true)
            return (shop, server, book)
        }
        // Older than the 409's stamp: an old value replayed. Not it; the question stays.
        var (shop, server, book) = await asking()
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: Self.stamp(900), changedBy: nil)))
        #expect(await Self.gated(shop) { await shop.readNewerSetting() } == .unreached)
        // At or after the 409's stamp, but older than the change made here since: overtaken.
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: Self.stamp(300), changedBy: nil)))
        #expect(await Self.gated(shop) { await shop.readNewerSetting() } == .overtaken)
        await Self.gated(shop) { await shop.answerNetworkSwitch(apply: true) }
        #expect(shop.networkSwitchAsk == nil && shop.networkSwitchAnswerProblem == nil, "ended, and not as \"could not be reached\"")
        #expect(Self.obj(book.network)["offline"] == .bool(true) && Self.obj(book.network)["changedAt"] == .string(own),
                "the older value is not applied over the owner's later change")
        // Newer than both: read.
        (shop, server, book) = await asking()
        let newer = Self.stamp(5)
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: newer, changedBy: nil)))
        if case .read(let value) = await Self.gated(shop, { await shop.readNewerSetting() }) { #expect(value.changedAt == newer) }
        else { Issue.record("a value newer than both floors was not read") }
        // With no stamp from the 409, this Mac's own change is still a floor.
        (shop, server, book) = await asking()
        shop.outboundDefaults.removeObject(forKey: Shop.heldStampKey(Self.shopId))
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: Self.stamp(300), changedBy: nil)))
        #expect(await Self.gated(shop) { await shop.readNewerSetting() } == .overtaken)
        // NOT overtaken when this Mac's switch is still the very change the 409 refused: a value
        // older than it contradicts the 409 (a replay, a stale read). The question stays.
        (shop, server, book) = await asking()
        shop.noteAskedAbout(own)
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: Self.stamp(300), changedBy: nil)))
        #expect(await Self.gated(shop) { await shop.readNewerSetting() } == .unreached)
        await Self.gated(shop) { await shop.answerNetworkSwitch(apply: true) }
        #expect(shop.networkSwitchAsk != nil, "never ended with nothing applied and nothing changed here")
        // And when it is not known which change the question was about, the careful answer.
        shop.noteAskedAbout(nil)
        #expect(await Self.gated(shop) { await shop.readNewerSetting() } == .unreached)
    }

    @Test("a 409 remembers which change the question is about")
    func askedAboutIsRemembered() async throws {
        let (shop, server, book) = await Self.shop(option: true)
        await server.answerPut(409, Data(#"{"reason":"stale","changedAt":"\#(Self.stamp(-2))"}"#.utf8))
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(true) })
        #expect(shop.networkSwitchAsk != nil)
        #expect(JSONValue.string(try #require(shop.networkSwitchAskedAbout)) == Self.obj(book.network)["changedAt"])
    }

    @Test("a retry touches only its own unsent off: a newer one the owner made meanwhile is neither forgotten nor written over")
    func retryKeepsANewerUnsentOff() async throws {
        let on: JSONValue = .object(["offline": .bool(true), "changedAt": .string(Self.stamp(3600)), "via": .string("cloud")])
        let old = try Self.published(.init(offline: true, keep: [], changedAt: Self.stamp(3600), changedBy: nil))
        let (shop, server, book) = await Self.shop(option: true, network: on)
        await server.answerGet(200, old)
        await server.answerPut(503, Data())
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        let first = try #require(shop.networkSwitchUnsentOff)
        let firstNetwork = try #require(book.network)
        // The owner turns it on, then off again; that newer off cannot be sent either.
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(true) })
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        let second = try #require(shop.networkSwitchUnsentOff)
        #expect(second != first)
        // The OLD send comes back now, every way it can: the newer unsent off is still there.
        for (get, put) in [((200, old), (503, Data())), ((200, old), (200, Data(#"{"ok":true}"#.utf8))),
                           ((200, old), (409, Data(#"{"changedAt":"\#(second)"}"#.utf8))), ((500, Data()), (200, Data())),
                           ((404, Data(#"{"reason":"none"}"#.utf8)), (200, Data()))] {
            await server.answerGet(get.0, get.1)
            await server.answerPut(put.0, put.1)
            _ = await Self.gated(shop) { await shop.tellOthersSwitchedOff(firstNetwork, seenBefore: nil, retry: true) }
            #expect(shop.networkSwitchUnsentOff == second, Comment(rawValue: "GET \(get.0) PUT \(put.0)"))
        }
        #expect(shop.networkSwitchAsk == nil)
        shop.forgetUnsentOff(ifStamp: first)
        #expect(shop.networkSwitchUnsentOff == second)
        shop.forgetUnsentOff(ifStamp: second)
        #expect(shop.networkSwitchUnsentOff == nil)
    }

    @Test("the shortcuts read the VALUE, not the server's outer stamp: a same-instant ON is a tie for the owner, an unreadable value supersedes nothing")
    func shortcutsReadTheValue() async throws {
        let on: JSONValue = .object(["offline": .bool(true), "changedAt": .string(Self.stamp(3600)), "via": .string("cloud")])
        let old = try Self.published(.init(offline: true, keep: [], changedAt: Self.stamp(3600), changedBy: nil))
        func unsent() async -> (Shop, Server, String) {
            let (shop, server, _) = await Self.shop(option: true, network: on)
            await server.answerGet(200, old)
            await server.answerPut(503, Data())
            _ = await Self.gated(shop) { await shop.setOutboundOffline(false) }
            return (shop, server, shop.networkSwitchUnsentOff ?? "")
        }
        // Another computer's ON at the very same instant is NOT "my off arrived".
        var (shop, server, mine) = await unsent()
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: mine, changedBy: "Noura")))
        await server.answerPut(409, Data(#"{"changedAt":"\#(mine)"}"#.utf8))
        await server.forget()
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == .changedElsewhere, "a tie only the owner can break")
        #expect(await server.asked.contains { $0.method == "PUT" }, "it was not taken as already sent")
        #expect(shop.networkSwitchAsk != nil && shop.outboundToldOthers == nil)
        // A later value that cannot be opened with the shop's key supersedes nothing: the off is still sent.
        (shop, server, mine) = await unsent()
        let later = StoreWriter.iso(try #require(NetworkSwitch.date(mine)).addingTimeInterval(1))
        // As a real server answers: the PUT is older than what it holds, so 409 with the later stamp.
        // The value is read again, still cannot be opened, and the off is KEPT: not dropped, not asked.
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: later, changedBy: nil), shopId: "another_shop"))
        await server.answerPut(409, Data(#"{"changedAt":"\#(later)"}"#.utf8))
        await server.forget()
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == .unsent)
        #expect(await server.asked.map(\.method) == ["GET", "PUT", "GET"], "the 409's stamp alone drops nothing: the value is read")
        #expect(shop.networkSwitchUnsentOff == mine && shop.networkSwitchAsk == nil)
        // The same 409, and now the value there opens and IS later: superseded.
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: later, changedBy: nil)))
        // (the first GET would already supersede; make it fail to open once, so the 409 path is the one that decides)
        await server.answerNextGet(200, try Self.published(.init(offline: true, keep: [], changedAt: later, changedBy: nil), shopId: "another_shop"))
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == .superseded)
        #expect(shop.networkSwitchUnsentOff == nil && shop.networkSwitchAsk == nil)
        // A later value stamped ahead of this Mac's clock cannot be followed here: kept as well.
        (shop, server, mine) = await unsent()
        let ahead = StoreWriter.iso(Date().addingTimeInterval(3600))
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: ahead, changedBy: nil)))
        await server.answerPut(409, Data(#"{"changedAt":"\#(ahead)"}"#.utf8))
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == .unsent)
        #expect(shop.networkSwitchUnsentOff == mine && shop.networkSwitchAsk == nil)
        // A 409 that names nothing newer is not understood: kept for the next retry, nothing asked.
        for body in [#"{"reason":"stale"}"#, #"{"changedAt":"\#(Self.stamp(7200))"}"#] {
            (shop, server, mine) = await unsent()
            await server.answerPut(409, Data(body.utf8))
            #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == .unsent)
            #expect(shop.networkSwitchUnsentOff == mine && shop.networkSwitchAsk == nil)
        }
        // A 409 at this very stamp, and the value there IS this off (it arrived late): sent, not a conflict.
        (shop, server, mine) = await unsent()
        await server.answerNextGet(200, old)
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: mine, changedBy: nil)))
        await server.answerPut(409, Data(#"{"changedAt":"\#(mine)"}"#.utf8))
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == .sent)
        #expect(shop.networkSwitchUnsentOff == nil && shop.networkSwitchAsk == nil)
        // A session that ran out (401) is kept: signing in again sends it.
        #expect(Shop.refusalMayPass(401))
        (shop, server, mine) = await unsent()
        await server.answerPut(401, Data())
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == .unsent)
        #expect(shop.networkSwitchUnsentOff == mine)
    }

    @Test("\"could not tell the others\" is cleared when there is nothing left to tell")
    func failedFlagIsCleared() async throws {
        let on: JSONValue = .object(["offline": .bool(true), "changedAt": .string(Self.stamp(3600)), "via": .string("cloud")])
        let old = try Self.published(.init(offline: true, keep: [], changedAt: Self.stamp(3600), changedBy: nil))
        // The owner stopped sharing: nothing published.
        var (shop, server, _) = await Self.shop(option: true, network: on)
        await server.answerGet(500, Data())
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        #expect(shop.outboundDefaults.bool(forKey: Shop.tellFailedKey), "it could not be told")
        await server.answerGet(404, Data(#"{"reason":"none"}"#.utf8))
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == .nothingPublished)
        #expect(!shop.outboundDefaults.bool(forKey: Shop.tellFailedKey))
        // Superseded by a newer value there.
        (shop, server, _) = await Self.shop(option: true, network: on)
        await server.answerGet(200, old)
        await server.answerPut(503, Data())
        #expect(await Self.gated(shop) { await shop.setOutboundOffline(false) })
        #expect(shop.outboundDefaults.bool(forKey: Shop.tellFailedKey))
        let mine = try #require(shop.networkSwitchUnsentOff)
        let later = StoreWriter.iso(try #require(NetworkSwitch.date(mine)).addingTimeInterval(1))
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: later, changedBy: nil)))
        #expect(await Self.gated(shop) { await shop.retryUnsentOff() } == .superseded)
        #expect(!shop.outboundDefaults.bool(forKey: Shop.tellFailedKey))
    }

    @Test("a token's read, ask and spend are one step: many calls at once, one gets through")
    func tokenIsUsedOnceUnderLoad() async throws {
        let off: JSONValue = .object(["network": .object(["offline": .bool(true), "changedAt": .string(Self.stamp(60))])])
        for _ in 0..<5 {
            let gates = [OutboundGate(), OutboundGate()]
            for gate in gates { gate.update(book: .settings(off)) }
            let answer = try #require(gates[0].answerToken())
            let through = await withTaskGroup(of: Bool.self) { group -> Int in
                for i in 0..<16 {
                    let gate = gates[i % 2]
                    group.addTask { OutboundGate.$answer.withValue(answer) { (try? gate.require(.switchSync)) != nil } }
                }
                var n = 0
                for await ok in group where ok { n += 1 }
                return n
            }
            #expect(through == 1, "\(through) calls got through on one answer")
        }
    }

    @Test("only the handler of the owner's answer asks the gate for a token")
    func oneTokenCallSite() throws {
        var sites: [String] = []
        let files = try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
        for url in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains(".answerToken()") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                sites.append(url.lastPathComponent)
            }
        }
        #expect(sites == ["Shop+NetworkSwitch.swift"], "\(sites)")
        let src = try String(contentsOf: Self.sources.appending(path: "Shop+NetworkSwitch.swift"), encoding: .utf8)
        let read = try #require(src.range(of: "func readNewerSetting("))
        let token = try #require(src.range(of: "outboundGate.answerToken()"))
        #expect(token.lowerBound > read.lowerBound, "made inside the answer's own read")
    }

    @Test("the three sentences are said in words, and the question's buttons wait while the answer reads")
    func answerWords() async throws {
        let (shop, _, _) = await Self.shop(option: true)
        for key in ["mac.net_ask_unreached", "mac.net_ask_nothing_there", "mac.net_ask_not_saved"] {
            let said = shop.words.callIt(key)
            #expect(!said.hasPrefix("mac.") && said.count > 30, Comment(rawValue: key))
        }
        let src = try String(contentsOf: Self.sources.appending(path: "NetworkSwitchQuestion.swift"), encoding: .utf8)
        #expect(src.contains(".disabled(!mayAnswer || shop.networkSwitchAnswering)"))
        #expect(src.contains("if let problem = shop.networkSwitchAnswerProblem"))
    }

    @Test("stamps are remembered per shop")
    func perShop() async {
        let (shop, _, _) = await Self.shop(option: false)
        let s = Self.stamp(60)
        shop.sawNetworkSwitchStamp(s)
        #expect(shop.outboundDefaults.string(forKey: Shop.highestSeenKey("shop_1")) == s)
        #expect(shop.outboundDefaults.string(forKey: Shop.highestSeenKey("shop_2")) == nil)
        shop.networkSwitchSessionForTests = (CloudReader.Connection(url: "https://cloud.example.test", shopId: "shop_2", storedToken: ""), "t", Self.dek)
        #expect(shop.networkSwitchHighestSeen == nil, "another shop starts with nothing seen")
    }

    // MARK: - Questions, words and the row

    @Test("the questions are the owner's to answer, and have words in every case")
    func questions() async {
        let locked = await OperatorLockTests.shop()
        locked.outboundDefaults = UserDefaults(suiteName: "khayt.netswitch.test.\(UUID().uuidString)")!
        locked.networkSwitchHeld = .init(offline: true, keep: [], changedAt: Self.stamp(60), changedBy: nil)
        locked.networkSwitchAsk = .oldSwitch(at: nil)
        #expect(await locked.signIn("OP-m", pin: "2222") == .ok)
        await locked.answerNetworkSwitch(apply: true)
        #expect(locked.networkSwitchAsk != nil && LockReviewTests.refused(locked), "a manager's answer is refused and the question stays")
        for ask in [NetworkSwitchAsk.oldSwitch(at: Date()), .oldSwitch(at: nil), .changedElsewhere(at: Date(), turningOn: true),
                    .changedElsewhere(at: nil, turningOn: false)] {
            for there in [Bool?.none, true, false] {
                let said = NetworkSwitchWords.sentence(ask, there: there, words: locked.words)
                #expect(!said.contains("mac.net_") && !said.contains("{"), Comment(rawValue: said))
            }
            let said = NetworkSwitchWords.sentence(ask, there: nil, words: locked.words)
            #expect(!said.contains("mac.net_") && !said.contains("{"), Comment(rawValue: said))
        }
        for key in ["mac.net_ask_apply", "mac.net_ask_leave", "mac.net_ask_newer", "mac.net_ask_here_only", "mac.net_t_switch-sync", "mac.net_d_switch-sync", "mac.net_need_switch-sync"] {
            #expect(locked.words.callIt(key) != key)
        }
        #expect(locked.words.callIt("mac.net_d_switch-sync").contains("every 15 minutes"))
        #expect(locked.words.callIt("mac.net_tell_on").contains("every 15 minutes"), "the option says what it keeps doing")
    }

    @Test("the switch-sync row: its tick writes dropSwitchSync, never keep, and unticking it ends the one call")
    func row() async {
        let on = Shop.network(.object(["keep": .array([.string("updates")])]), keep: .switchSync, false)
        #expect(Self.obj(on)["dropSwitchSync"] == .bool(true) && Self.obj(on)["keep"] == .array([.string("updates")]))
        #expect(Self.obj(Shop.network(on, keep: .switchSync, true))["dropSwitchSync"] == nil)
        let other = Shop.network(.object(["keep": .array([.string("switch-sync"), .string("lan"), .string("ai")])]), keep: .updates, true)
        #expect(Self.obj(other)["keep"] == .array([.string("ai"), .string("updates")]), "switch-sync and lan are never in keep")
        // A change made here says whether it went through Khayt Cloud.
        let now = Date()
        let shared = Shop.network(nil, offline: true, by: nil, at: now, viaCloud: true)
        #expect(Self.obj(shared)["via"] == .string("cloud"))
        #expect(Self.obj(Shop.network(shared, offline: true, by: nil, at: now, viaCloud: false))["via"] == nil)
        #expect(Self.obj(Shop.network(shared, offline: true, by: nil, at: now))["via"] == .string("cloud"))
        #expect(InternetUse.order.contains(.switchSync))
        // Unticked through the owner's own write: the rule stops keeping the call.
        let (shop, _, book) = await Self.shop(option: false, network: .object(["offline": .bool(true), "via": .string("cloud"),
                                                                               "changedAt": .string(Self.stamp(60))]))
        #expect(shop.outboundGate.verdict(.switchSync).allowed)
        #expect(await shop.setOutboundKeep(.switchSync, false))
        #expect(Self.obj(book.network)["dropSwitchSync"] == .bool(true) && !shop.outboundGate.verdict(.switchSync).allowed)
        // Not signed in to Khayt Cloud: the row says Not set up.
        #expect(shop.internetUseNotSetUp(makerRunLinked: true).contains(.switchSync))
    }
}
