import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "Also tell my other computers through Khayt Cloud" on the Mac
/// (`Shop+NetworkSwitch`): the one last call when the switch is turned on,
/// the GET before turning it off, the 409 that is said and never obeyed
/// silently, and the questions that wait for a person. A fake Khayt Cloud
/// answers; nothing here reaches the network.
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
        func answerPut(_ status: Int, _ body: Data) { put = (status, body) }
        func handle(method: String, path: String, body: Data?) -> (Int, Data) {
            asked.append(.init(method: method, path: path, body: body))
            return method == "PUT" ? put : get
        }
    }

    /// The owner at a Mac signed in to the fake cloud, with its own gate and defaults.
    static func shop(option: Bool) async -> (Shop, Server) {
        let shop = await OperatorLockTests.shop(on: false)
        shop.outboundDefaults = UserDefaults(suiteName: "khayt.netswitch.test.\(UUID().uuidString)")!
        shop.outboundGate = OutboundGate()
        shop.outboundGate.update(book: .settings(.object([:])))
        let server = Server()
        shop.networkSwitchSessionForTests = (connection, "token", dek)
        shop.networkSwitchFetch = { request in
            let (status, body) = await server.handle(method: request.httpMethod ?? "", path: request.url?.path ?? "", body: request.httpBody)
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if option { shop.outboundDefaults.set(true, forKey: Shop.tellOthersKey) }
        return (shop, server)
    }

    static func network(offline: Bool, at: String = "2026-11-22T08:00:00.000Z") -> JSONValue {
        .object(["offline": .bool(offline), "keep": .array([.string("updates")]), "changedAt": .string(at), "changedBy": .string("Sara")])
    }

    static func published(_ value: NetworkSwitch.Value) throws -> Data {
        let blob = try NetworkSwitch.seal(value, shopId: shopId, dek: dek)
        return try JSONEncoder().encode(JSONValue.object([
            "changedAt": .string(value.changedAt), "receivedAt": .string(value.changedAt),
            "ciphertext": try JSONValue.decode(JSONValue.self, from: JSONEncoder().encode(blob))]))
    }

    /// Run with the shop's own gate as the one every request asks.
    static func gated<T>(_ shop: Shop, _ work: () async throws -> T) async rethrows -> T {
        try await OutboundGate.$scoped.withValue(shop.outboundGate) { try await work() }
    }

    @Test("the row is offered now that its call is wired, and is off until the owner turns it on")
    func offered() async {
        #expect(Shop.tellOthersOffered)
        let (shop, _) = await Self.shop(option: false)
        #expect(!shop.outboundTellsOthers)
    }

    @Test("turned on with the option on: one PUT of the sealed switch, and the others were told")
    func lastCall() async throws {
        let (shop, server) = await Self.shop(option: true)
        let told = await Self.gated(shop) { await shop.tellOthersSwitchedOn(Self.network(offline: true)) }
        #expect(told)
        let asked = await server.asked
        #expect(asked.map(\.method) == ["PUT"] && asked[0].path == "/v1/shops/shop_1/network-switch")
        // What was sent opens with the shop's key and says what the book says.
        let body = try #require(asked[0].body)
        guard case .object(let o) = try JSONDecoder().decode(JSONValue.self, from: body) else { Issue.record("no body"); return }
        #expect(o["changedAt"] == .string("2026-11-22T08:00:00.000Z"))
        let back = try JSONDecoder().decode(NetworkSwitch.Published.self, from: body)
        let value = try NetworkSwitch.read(back, shopId: Self.shopId, dek: Self.dek, highestSeen: nil, purposes: shop.outboundPurposeIds).get()
        #expect(value == .init(offline: true, keep: ["updates"], changedAt: "2026-11-22T08:00:00.000Z", changedBy: "Sara"))
        if case .told = shop.outboundToldOthers {} else { Issue.record("not noted as told") }
        #expect(shop.networkSwitchAsk == nil)
    }

    @Test("with the option off nothing is sent when the switch is turned on")
    func optionOffSendsNothing() async {
        let (shop, server) = await Self.shop(option: false)
        let told = await Self.gated(shop) { await shop.tellOthersSwitchedOn(Self.network(offline: true)) }
        #expect(!told)
        #expect(await server.asked.isEmpty)
        #expect(shop.outboundToldOthers == nil)
    }

    @Test("Khayt Cloud not reached, or not the owner's token: said as not told, and nothing is claimed")
    func tellFails() async {
        for status in [500, 403, 429] {
            let (shop, server) = await Self.shop(option: true)
            await server.answerPut(status, Data("{}".utf8))
            let told = await Self.gated(shop) { await shop.tellOthersSwitchedOn(Self.network(offline: true)) }
            #expect(!told, Comment(rawValue: "\(status)"))
            #expect(shop.outboundToldOthers == .failed)
        }
        let (shop, _) = await Self.shop(option: true)
        shop.networkSwitchFetch = { _ in throw URLError(.timedOut) }
        #expect(await Self.gated(shop) { await shop.tellOthersSwitchedOn(Self.network(offline: true)) } == false)
        #expect(shop.outboundToldOthers == .failed)
    }

    @Test("a 409 right after the change: said, the other value held, and nothing applied or reverted on its own")
    func changedElsewhere() async throws {
        let (shop, server) = await Self.shop(option: true)
        let theirs = "2026-11-22T08:00:05.000Z"
        await server.answerPut(409, Data(#"{"reason":"stale","changedAt":"\#(theirs)"}"#.utf8))
        let before = shop.settingsValue
        let told = await Self.gated(shop) { await shop.tellOthersSwitchedOn(Self.network(offline: true)) }
        #expect(!told)
        #expect(shop.networkSwitchAsk == .changedElsewhere(at: NetworkSwitch.date(theirs)))
        #expect(shop.outboundDefaults.string(forKey: Shop.heldStampKey) == theirs)
        #expect(shop.settingsValue == before, "the person's own change is not undone here")
        #expect(await server.asked.map(\.method) == ["PUT", "GET"], "never retried with a fresh stamp to win; one read of what the other set")
        #expect(shop.outboundToldOthers == nil, "neither told nor unreachable is claimed")
        // The next check reads that very value: it waits for the person and is not applied.
        await server.answerGet(200, try Self.published(.init(offline: false, keep: [], changedAt: theirs, changedBy: "Noura")))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(shop.networkSwitchHeld?.changedAt == theirs)
        #expect(shop.settingsValue == before)
        // "Leave this Mac as it is": not asked again, and remembered as seen.
        await shop.answerNetworkSwitch(apply: false)
        #expect(shop.networkSwitchAsk == nil && shop.networkSwitchHeld == nil)
        #expect(shop.outboundDefaults.string(forKey: Shop.heldStampKey) == nil)
        #expect(shop.networkSwitchHighestSeen == theirs)
        // A 409 with no stamp is still said.
        let (other, server2) = await Self.shop(option: true)
        await server2.answerPut(409, Data(#"{"reason":"stale"}"#.utf8))
        _ = await Self.gated(other) { await other.tellOthersSwitchedOn(Self.network(offline: true)) }
        #expect(other.networkSwitchAsk == .changedElsewhere(at: nil))
    }

    @Test("turned off: a GET first; a value published there is answered with offline:false even with this Mac's option off")
    func turningOff() async throws {
        // The option off here, and another computer published the switch.
        var (shop, server) = await Self.shop(option: false)
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: "2026-11-20T08:00:00.000Z", changedBy: nil)))
        await Self.gated(shop) { await shop.tellOthersSwitchedOff(Self.network(offline: false, at: "2026-11-22T09:00:00.000Z")) }
        var asked = await server.asked
        #expect(asked.map(\.method) == ["GET", "PUT"], "the GET comes first")
        let body = try #require(asked[1].body)
        let sent = try NetworkSwitch.read(JSONDecoder().decode(NetworkSwitch.Published.self, from: body), shopId: Self.shopId,
                                          dek: Self.dek, highestSeen: nil, purposes: shop.outboundPurposeIds).get()
        #expect(sent.offline == false && sent.changedAt == "2026-11-22T09:00:00.000Z")
        // The option off and nothing published: the shop does not share the switch.
        (shop, server) = await Self.shop(option: false)
        await Self.gated(shop) { await shop.tellOthersSwitchedOff(Self.network(offline: false)) }
        asked = await server.asked
        #expect(asked.map(\.method) == ["GET"], "nothing is sent")
        #expect(shop.outboundToldOthers == nil)
        // The option on and nothing published yet: offline:false is sent so the others come back.
        (shop, server) = await Self.shop(option: true)
        await Self.gated(shop) { await shop.tellOthersSwitchedOff(Self.network(offline: false)) }
        #expect(await server.asked.map(\.method) == ["GET", "PUT"])
    }

    @Test("the order in the switch itself: the last call before the book is written when turning on, the GET after when turning off")
    func orderInTheSwitch() throws {
        let src = try String(contentsOf: Self.sources.appending(path: "Shop+Outbound.swift"), encoding: .utf8)
        let body = try #require(src.range(of: "func setOutboundOffline("))
        let rest = src[body.upperBound...]
        let gate = try #require(rest.range(of: #"guard permitted("security", "edit")"#))
        let on = try #require(rest.range(of: "told = await tellOthersSwitchedOn(next)"))
        let write = try #require(rest.range(of: "guard await writeNetwork("))
        let off = try #require(rest.range(of: "await tellOthersSwitchedOff(next)"))
        #expect(gate.upperBound <= on.lowerBound, "only the owner sends")
        #expect(on.upperBound <= write.lowerBound, "turned on: told first, while this Mac may still call")
        #expect(write.upperBound <= off.lowerBound, "turned off: this Mac is online again before it calls")
        #expect(rest[..<off.upperBound].contains("if on, changed {") && rest[..<off.upperBound].contains("if !on, changed {"),
                "sent only when the switch itself changes")
    }

    @Test("hearing: asked only when the rule allows the one call; a 404 changes nothing; a value from another shop is ignored")
    func hearing() async throws {
        let (shop, server) = await Self.shop(option: false)
        // Offline by its own switch, nothing shared: no call at all.
        shop.outboundGate.update(book: .settings(.object(["network": Self.network(offline: true)])))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(await server.asked.isEmpty)
        // This Mac's own switch stops it too, even when the switch came through Khayt Cloud.
        var via = Self.network(offline: true)
        if case .object(var n) = via { n["via"] = .string(NetworkSwitch.viaCloud); via = .object(n) }
        shop.outboundGate.update(book: .settings(.object(["network": via])))
        shop.outboundGate.update(local: .init(offline: true))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(await server.asked.isEmpty)
        // Offline through Khayt Cloud: the one call is made.
        shop.outboundGate.update(local: .init(offline: false))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(await server.asked.map(\.method) == ["GET"])
        #expect(shop.networkSwitchAsk == nil)
        // A value sealed for another shop, or with another key, asks nobody and applies nothing.
        let foreign = try NetworkSwitch.seal(.init(offline: true, keep: [], changedAt: "2026-11-22T10:00:00.000Z", changedBy: nil),
                                             shopId: "shop_2", dek: Self.dek)
        await server.answerGet(200, try JSONEncoder().encode(JSONValue.object([
            "changedAt": .string("2026-11-22T10:00:00.000Z"),
            "ciphertext": try JSONValue.decode(JSONValue.self, from: JSONEncoder().encode(foreign))])))
        let before = shop.settingsValue
        shop.outboundGate.update(book: .settings(.object([:])))
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(shop.settingsValue == before && shop.networkSwitchAsk == nil && shop.networkSwitchHeld == nil)
    }

    @Test("a new install meeting an old offline:true asks, and applies nothing until answered")
    func oldSwitchAsks() async throws {
        let (shop, server) = await Self.shop(option: false)
        let old = StoreWriter.iso(Date().addingTimeInterval(-9 * 86_400))
        await server.answerGet(200, try Self.published(.init(offline: true, keep: [], changedAt: old, changedBy: "Sara")))
        let before = shop.settingsValue
        await Self.gated(shop) { await shop.checkNetworkSwitch() }
        #expect(shop.networkSwitchAsk == .oldSwitch(at: NetworkSwitch.date(old)))
        #expect(shop.settingsValue == before, "nothing is applied on its own")
        let said = NetworkSwitchWords.sentence(try #require(shop.networkSwitchAsk), words: shop.words)
        #expect(said.hasPrefix("Your shop turned off internet use on ") && said.hasSuffix("Apply it here?"))
    }

    @Test("the questions are the owner's to answer, and have words in every case")
    func questions() async {
        let locked = await OperatorLockTests.shop()
        locked.outboundDefaults = UserDefaults(suiteName: "khayt.netswitch.test.\(UUID().uuidString)")!
        locked.networkSwitchHeld = .init(offline: true, keep: [], changedAt: "2026-11-22T08:00:00.000Z", changedBy: nil)
        locked.networkSwitchAsk = .oldSwitch(at: nil)
        #expect(await locked.signIn("OP-m", pin: "2222") == .ok)
        await locked.answerNetworkSwitch(apply: true)
        #expect(locked.networkSwitchAsk != nil && LockReviewTests.refused(locked), "a manager's answer is refused and the question stays")
        for ask in [NetworkSwitchAsk.oldSwitch(at: Date()), .oldSwitch(at: nil), .changedElsewhere(at: Date()), .changedElsewhere(at: nil)] {
            let said = NetworkSwitchWords.sentence(ask, words: locked.words)
            #expect(!said.contains("mac.net_") && !said.contains("{"), Comment(rawValue: said))
        }
        for key in ["mac.net_ask_apply", "mac.net_ask_leave", "mac.net_t_switch-sync", "mac.net_d_switch-sync", "mac.net_need_switch-sync"] {
            #expect(locked.words.callIt(key) != key)
        }
        #expect(locked.words.callIt("mac.net_d_switch-sync").contains("every 15 minutes"))
        #expect(locked.words.callIt("mac.net_tell_on").contains("every 15 minutes"), "the option says what it keeps doing")
    }

    @Test("the switch-sync row: its tick writes dropSwitchSync, never keep; it reads Not set up for a shop that does not share")
    func row() async {
        let on = Shop.network(.object(["keep": .array([.string("updates")])]), keep: .switchSync, false)
        guard case .object(let dropped) = on else { Issue.record("not an object"); return }
        #expect(dropped["dropSwitchSync"] == .bool(true) && dropped["keep"] == .array([.string("updates")]))
        guard case .object(let kept) = Shop.network(on, keep: .switchSync, true) else { return }
        #expect(kept["dropSwitchSync"] == nil)
        guard case .object(let other) = Shop.network(.object(["keep": .array([.string("switch-sync"), .string("lan"), .string("ai")])]),
                                                    keep: .updates, true) else { return }
        #expect(other["keep"] == .array([.string("ai"), .string("updates")]), "switch-sync and lan are never in keep")
        // A change made here says whether it went through Khayt Cloud.
        let now = Date()
        guard case .object(let shared) = Shop.network(nil, offline: true, by: nil, at: now, viaCloud: true),
              case .object(let alone) = Shop.network(.object(shared), offline: true, by: nil, at: now, viaCloud: false),
              case .object(let untouched) = Shop.network(.object(shared), offline: true, by: nil, at: now) else { return }
        #expect(shared["via"] == .string("cloud") && alone["via"] == nil && untouched["via"] == .string("cloud"))
        #expect(InternetUse.order.contains(.switchSync))
        let (shop, _) = await Self.shop(option: false)
        #expect(shop.internetUseNotSetUp(makerRunLinked: true).contains(.switchSync))
    }
}
