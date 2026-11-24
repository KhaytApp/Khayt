import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// `POST /api/network/switch`: an owner's phone turning the shop's "Make no
/// internet calls" on or off (iPhone frame 1B). Signed, owner only, a signed
/// answer, and the change itself is the Mac's own path.
@MainActor
@Suite(.serialized)
struct PhoneNetworkSwitchTests {
    static let path = "/api/network/switch"
    static func body(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Who may call it (the route)

    @Test("the PIN alone, nothing at all, and a GET never reach the switch")
    func pinIsNotEnough() async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let withPin = try await bench.post(Self.path, json: #"{"offline":true}"#, headers: ["x-khayt-pin": PhoneRolesTests.pin])
        #expect(withPin.status == 403 && withPin.text.contains("device-key-required"))
        #expect(withPin.headers["x-khayt-reply-mac"] == nil)
        #expect(try await bench.post(Self.path, json: #"{"offline":true}"#).status == 401)
        #expect(try await bench.get(Self.path, headers: ["x-khayt-pin": PhoneRolesTests.pin]).status == 404)
        #expect(bench.switchCalls.calls.isEmpty)
    }

    @Test("a viewer's phone is refused, signed, with owner as what it lacked")
    func viewer() async throws { try await refused("viewer") }
    @Test("an operator's phone is refused")
    func `operator`() async throws { try await refused("operator") }
    @Test("a manager's phone is refused: this is the owner's switch")
    func manager() async throws { try await refused("manager") }

    func refused(_ role: String) async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let phone = try PhoneRolesTests.codePaired(bench.devices, role: role, name: role)
        let sent = Self.body(#"{"offline":true}"#)
        let headers = phone.headers("POST", Self.path, body: sent)
        let reply = try await bench.send("POST", Self.path, body: sent, headers: headers, timeout: 30)
        #expect(reply.status == 403, Comment(rawValue: role))
        #expect(reply.json["reason"] as? String == "role-scope" && reply.json["required"] as? String == "owner")
        #expect(reply.headers["x-khayt-reply-mac"] == LanServer.replyMac(key: phone.key, nonce: headers["x-khayt-nonce"] ?? "",
                                                                         status: 403, body: reply.body), "the refusal is signed")
        #expect(bench.switchCalls.calls.isEmpty, Comment(rawValue: role))
        // And the route is not advertised to a phone that cannot use it.
        let me = try await PhoneRolesTests.status(bench, phone, "GET", "/api/devices/self")
        #expect((me.1["can"] as? [String]) == [], Comment(rawValue: role))
    }

    @Test("the owner's phone reaches it, once per request, with its name, and the answer is signed")
    func owner() async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        for phone in [try PhoneRolesTests.codePaired(bench.devices, role: "owner", name: "Owner phone"),
                      try LanConnectorRoutesTests.enrol(bench, kind: nil, name: "Legacy phone")] {
            let sent = Self.body(#"{"offline":true,"keep":["cloud"]}"#)
            let headers = phone.headers("POST", Self.path, body: sent)
            let before = bench.switchCalls.calls.count
            let reply = try await bench.send("POST", Self.path, body: sent, headers: headers, timeout: 30)
            #expect(reply.status == 200 && reply.json["ok"] as? Bool == true)
            #expect(reply.headers["x-khayt-reply-mac"] == LanServer.replyMac(key: phone.key, nonce: headers["x-khayt-nonce"] ?? "",
                                                                             status: 200, body: reply.body))
            #expect(bench.switchCalls.calls.count == before + 1)
            #expect(bench.switchCalls.calls.last?.hasSuffix(#"{"offline":true,"keep":["cloud"]}"#) == true)
            // The same signed request again is a replay and flips nothing twice.
            let replay = try await bench.send("POST", Self.path, body: sent, headers: headers, timeout: 30)
            #expect(replay.status == 401 && bench.switchCalls.calls.count == before + 1)
            // Advertised to the owner, so the phone offers the control only where it works.
            let me = try await PhoneRolesTests.status(bench, phone, "GET", "/api/devices/self")
            #expect((me.1["can"] as? [String]) == ["network-switch"])
        }
        #expect(bench.switchCalls.calls.first?.hasPrefix("Owner phone ") == true, "who changed it is the device's own name")
        // A paired slicer is not a phone.
        let slicer = try LanConnectorRoutesTests.enrol(bench)
        let (status, _) = try await PhoneRolesTests.status(bench, slicer, "POST", Self.path, body: Self.body(#"{"offline":false}"#))
        #expect(status == 401 || status == 403)
        #expect(bench.switchCalls.calls.count == 2)
    }

    // MARK: - What it does (the Mac's own change)

    static func network(_ shop: Shop) -> [String: JSONValue] { shop.networkSettings }
    static func json(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:] }

    @Test("it turns the switch on and off through the Mac's own path: stamped, named, the gate told at once")
    func flips() async throws {
        let (shop, _, book) = await NetworkSwitchWiringTests.shop(option: false)
        let t0 = Date(timeIntervalSince1970: 1_795_100_000)
        var (status, text) = await shop.phoneSetOutbound(body: Self.body(#"{"offline":true,"keep":["cloud","updates"]}"#),
                                                         deviceName: "Turki's iPhone", now: t0)
        #expect(status == 200, Comment(rawValue: text))
        var n = Self.json(text)["network"] as? [String: Any]
        #expect(n?["offline"] as? Bool == true && n?["changedBy"] as? String == "Turki's iPhone")
        #expect(Set(n?["keep"] as? [String] ?? []) == ["cloud", "updates"])
        #expect(n?["changedAt"] as? String == StoreWriter.iso(t0))
        // In the book, and this Mac's gate already follows it.
        guard case .object(let stored)? = book.network else { Issue.record("nothing written"); return }
        #expect(stored["offline"] == .bool(true) && stored["changedBy"] == .string("Turki's iPhone"))
        #expect(shop.outboundGate.isOffline, "the Mac did not stop at once")

        // Off again, with what the phone saw. `keep` omitted: left as it is.
        let seen = try #require(n?["changedAt"] as? String)
        (status, text) = await shop.phoneSetOutbound(body: Self.body(#"{"offline":false,"seen":"\#(seen)"}"#),
                                                     deviceName: "Turki's iPhone", now: t0.addingTimeInterval(60))
        #expect(status == 200, Comment(rawValue: text))
        n = Self.json(text)["network"] as? [String: Any]
        #expect(n?["offline"] as? Bool == false && Set(n?["keep"] as? [String] ?? []) == ["cloud", "updates"])
        #expect(!shop.outboundGate.isOffline)
        // The stamp only ever moves forward, by the shared rule.
        #expect((n?["changedAt"] as? String ?? "") > seen)
    }

    @Test("a stale `seen` changes nothing and says what is true now")
    func stale() async throws {
        let now = Date(timeIntervalSince1970: 1_795_100_000)
        let (shop, _, book) = await NetworkSwitchWiringTests.shop(option: false, network: .object([
            "offline": .bool(false), "keep": .array([]), "changedAt": .string("2026-11-22T14:12:00.000Z"), "changedBy": .string("Sara")]))
        let before = book.network
        let (status, text) = await shop.phoneSetOutbound(body: Self.body(#"{"offline":true,"seen":"2026-11-22T09:00:00.000Z"}"#),
                                                         deviceName: "Phone", now: now)
        #expect(status == 409)
        let j = Self.json(text)
        #expect(j["ok"] as? Bool == false && j["reason"] as? String == "changed")
        let n = j["network"] as? [String: Any]
        #expect(n?["offline"] as? Bool == false && n?["changedAt"] as? String == "2026-11-22T14:12:00.000Z" && n?["changedBy"] as? String == "Sara")
        #expect(book.network == before && !shop.outboundGate.isOffline, "a stale tap changed the switch")
        // The right `seen` goes through.
        #expect(await shop.phoneSetOutbound(body: Self.body(#"{"offline":true,"seen":"2026-11-22T14:12:00.000Z"}"#),
                                            deviceName: "Phone", now: now).0 == 200)
        // The switch was never changed before: a phone that saw no stamp sends none; one that sends one is stale.
        let (fresh, _, _) = await NetworkSwitchWiringTests.shop(option: false)
        #expect(await fresh.phoneSetOutbound(body: Self.body(#"{"offline":true,"seen":"2026-11-22T14:12:00.000Z"}"#),
                                             deviceName: "Phone", now: now).0 == 409)
        #expect(await fresh.phoneSetOutbound(body: Self.body(#"{"offline":true}"#), deviceName: "Phone", now: now).0 == 200)
    }

    @Test("a body that is not exactly the shape, or a purpose this Mac does not know, changes nothing")
    func badBodies() async throws {
        let (shop, _, book) = await NetworkSwitchWiringTests.shop(option: false)
        func ask(_ json: String) async -> (Int, String?) {
            let (status, text) = await shop.phoneSetOutbound(body: Self.body(json), deviceName: "Phone")
            return (status, Self.json(text)["reason"] as? String)
        }
        for bad in ["", "[]", "{}", #"{"offline":"yes"}"#, #"{"offline":1}"#, #"{"offline":true,"keep":"cloud"}"#,
                    #"{"offline":true,"seen":5}"#, #"{"offline":true,"keep":[1]}"#.replacingOccurrences(of: "[1]", with: "{}")] {
            let got = await ask(bad)
            #expect(got.0 == 400 && got.1 == "bad-body", Comment(rawValue: bad))
        }
        // Unknown, never-kept and non-string entries are refused, not dropped.
        for keep in [#"["nonsense"]"#, #"["lan"]"#, #"["switch-sync"]"#, #"["cloud",7]"#] {
            let got = await ask(#"{"offline":true,"keep":\#(keep)}"#)
            #expect(got.0 == 400 && got.1 == "bad-keep", Comment(rawValue: keep))
        }
        // A body far too large to be this request.
        let huge = #"{"offline":true,"pad":""# + String(repeating: "x", count: 5000) + #""}"#
        #expect(await ask(huge).0 == 400)
        #expect(book.network == nil && !shop.outboundGate.isOffline, "a refused request changed the switch")
        // An empty keep list is a real answer: keep nothing.
        #expect(await ask(#"{"offline":true,"keep":[]}"#).0 == 200)
        guard case .object(let n)? = book.network else { Issue.record("not written"); return }
        #expect(n["keep"] == .array([]))
    }

    @Test("what another app ticked is neither refused nor wiped: the tunnel, and a purpose only a newer app knows")
    func othersKeeps() async throws {
        // The Windows/Linux app kept the tunnel; a newer one kept a purpose this Mac has never heard of.
        let (shop, _, book) = await NetworkSwitchWiringTests.shop(option: false, network: .object([
            "offline": .bool(false), "keep": .array([.string("tunnel"), .string("cloud"), .string("from-the-future")]),
            "changedAt": .string("2026-11-22T14:12:00.000Z")]))
        // The phone is shown what this Mac knows, the tunnel included, and not the unknown id.
        guard case .object(let shown) = shop.networkForPhone(), case .array(let keep)? = shown["keep"] else { Issue.record("shape"); return }
        #expect(Set(keep) == [.string("tunnel"), .string("cloud")])
        // It sends back the list it showed: accepted, not `bad-keep`.
        var (status, text) = await shop.phoneSetOutbound(body: Self.body(#"{"offline":true,"keep":["tunnel","cloud"]}"#), deviceName: "Phone")
        #expect(status == 200, Comment(rawValue: text))
        // It unticks cloud: the tunnel stays because the phone kept it, the unknown one because it was never the phone's to untick.
        (status, text) = await shop.phoneSetOutbound(body: Self.body(#"{"offline":true,"keep":["tunnel"]}"#), deviceName: "Phone")
        #expect(status == 200, Comment(rawValue: text))
        guard case .object(let n)? = book.network, case .array(let stored)? = n["keep"] else { Issue.record("not written"); return }
        #expect(Set(stored) == [.string("tunnel"), .string("from-the-future")], "another app's tick was wiped: \(stored)")
    }

    @Test("a Keep ticked at the Mac meanwhile is not wiped by a phone that says what it was showing")
    func keepIsNotLost() async throws {
        let (shop, _, book) = await NetworkSwitchWiringTests.shop(option: false, network: .object([
            "offline": .bool(true), "keep": .array([.string("cloud")]), "changedAt": .string("2026-11-22T14:12:00.000Z")]))
        // The owner ticks Keep on updates at the Mac. `changedAt` does not move: the switch was not flipped.
        #expect(await shop.setOutboundKeep(.updates, true))
        // The phone, still showing ["cloud"], sends its list with the right `seen`.
        let stale = await shop.phoneSetOutbound(
            body: Self.body(#"{"offline":true,"keep":["cloud"],"seen":"2026-11-22T14:12:00.000Z","seenKeep":["cloud"]}"#), deviceName: "Phone")
        #expect(stale.0 == 409 && stale.1.contains(#""reason":"changed""#), Comment(rawValue: stale.1))
        guard case .object(let n)? = book.network, case .array(let keep)? = n["keep"] else { Issue.record("shape"); return }
        #expect(Set(keep) == [.string("cloud"), .string("updates")], "the Mac's tick was wiped")
        // Showing what is true now, it goes through.
        let ok = await shop.phoneSetOutbound(
            body: Self.body(#"{"offline":true,"keep":["cloud"],"seen":"2026-11-22T14:12:00.000Z","seenKeep":["updates","cloud"]}"#), deviceName: "Phone")
        #expect(ok.0 == 200, Comment(rawValue: ok.1))
        #expect(await shop.phoneSetOutbound(body: Self.body(#"{"offline":true,"seenKeep":"cloud"}"#), deviceName: "Phone").0 == 400)
    }

    @Test("a purpose the phone knows and this Mac does not is not a reason to refuse every request")
    func seenKeepWithAnIdThisMacDoesNotShow() async throws {
        // A newer desktop ticked a purpose this Mac has never heard of; a newer phone was shown it there.
        let (shop, _, book) = await NetworkSwitchWiringTests.shop(option: false, network: .object([
            "offline": .bool(true), "keep": .array([.string("cloud"), .string("from-the-future")]),
            "changedAt": .string("2026-11-22T14:12:00.000Z")]))
        let ok = await shop.phoneSetOutbound(
            body: Self.body(#"{"offline":false,"seen":"2026-11-22T14:12:00.000Z","seenKeep":["cloud","from-the-future"]}"#), deviceName: "Phone")
        #expect(ok.0 == 200, Comment(rawValue: ok.1))
        // The tick this Mac does not know is still in the book.
        guard case .object(let n)? = book.network, case .array(let keep)? = n["keep"] else { Issue.record("shape"); return }
        #expect(Set(keep) == [.string("cloud"), .string("from-the-future")], "another app's tick was wiped: \(keep)")
        // What this Mac DOES show is still compared: a list that is not what it holds is refused.
        let changedAt: String = { if case .string(let s)? = shop.networkSettings["changedAt"] { return s }; return "" }()
        let wrong = #"{"offline":true,"seen":"STAMP","seenKeep":["updates","from-the-future"]}"#.replacingOccurrences(of: "STAMP", with: changedAt)
        let stale = await shop.phoneSetOutbound(body: Self.body(wrong), deviceName: "Phone")
        #expect(stale.0 == 409 && stale.1.contains(#""reason":"changed""#), Comment(rawValue: stale.1))
    }

    @Test("`seen` is the same moment however it is written, and a failure is the phone's to hear, not the Mac's screen")
    func seenIsAnInstant() async throws {
        let (shop, _, _) = await NetworkSwitchWiringTests.shop(option: false, network: .object([
            "offline": .bool(false), "keep": .array([]), "changedAt": .string("2026-11-22T14:12:00.000Z")]))
        // Without its milliseconds, as a phone's date formatter writes it.
        #expect(await shop.phoneSetOutbound(body: Self.body(#"{"offline":true,"seen":"2026-11-22T14:12:00Z"}"#), deviceName: "Phone").0 == 200)
        // A refused change leaves whatever the Mac's screen was showing as it was.
        shop.moveProblem = "something the person at the Mac was reading"
        shop.outboundChanging = true          // another change is in flight
        let busy = await shop.phoneSetOutbound(body: Self.body(#"{"offline":false}"#), deviceName: "Phone")
        shop.outboundChanging = false
        #expect(busy.0 == 409 && busy.1.contains("not-saved"))
        #expect(shop.moveProblem == "something the person at the Mac was reading")
    }

    @Test("an API token never reaches the switch, with or without made-up device headers")
    func tokenIsNotAPhone() async throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let server = try String(contentsOf: app.appending(path: "LanServer.swift"), encoding: .utf8)
        let at = try #require(server.range(of: "path == Self.networkSwitchPath:"))
        let route = server[at.upperBound...].prefix(900)
        #expect(route.contains("guard !request.tokenScoped, LanDevices.isSigned(request.headers)"),
                "a token-scoped request skips the signature check in pinGate; the route must refuse it itself")
        // And over the wire: a bearer token with a made-up device id is not let in.
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let owner = try PhoneRolesTests.codePaired(bench.devices, role: "owner", name: "Owner")
        let reply = try await bench.post(Self.path, json: #"{"offline":false}"#,
                                         headers: ["authorization": "Bearer khayt_made_up_token", "x-khayt-device": owner.id,
                                                   "x-khayt-nonce": String(repeating: "ab", count: 16), "x-khayt-time": "1", "x-khayt-mac": "AAAA"])
        #expect(reply.status != 200 && bench.switchCalls.calls.isEmpty, "\(reply.status)")
        #expect(reply.headers["x-khayt-reply-mac"] == nil, "an answer was signed for a request nobody verified")
    }

    @Test("the sample book is not changed, and a long device name is cut")
    func edges() async throws {
        let sample = Shop()
        sample.useEngine(OperatorLockTests.sharedEngine)
        await sample.load(.sample)
        let (status, text) = await sample.phoneSetOutbound(body: Self.body(#"{"offline":true}"#), deviceName: "Phone")
        #expect(status == 409 && text.contains("read-only"))
        let (shop, _, book) = await NetworkSwitchWiringTests.shop(option: false)
        #expect(await shop.phoneSetOutbound(body: Self.body(#"{"offline":true}"#),
                                            deviceName: "  " + String(repeating: "n", count: 300) + "  ").0 == 200)
        guard case .object(let n)? = book.network, case .string(let by)? = n["changedBy"] else { Issue.record("no name"); return }
        #expect(by.count == 80)
        // No control or direction-changing characters reach the book, where other computers show the name.
        let (other, _, otherBook) = await NetworkSwitchWiringTests.shop(option: false)
        #expect(await other.phoneSetOutbound(body: Self.body(#"{"offline":true}"#), deviceName: "Sara\u{202E}enohPi\u{0007}\n").0 == 200)
        guard case .object(let m)? = otherBook.network else { Issue.record("not written"); return }
        #expect(m["changedBy"] == .string("SaraenohPi"))
    }

    @Test("with “tell my other computers” on, a flip from the phone is told to Khayt Cloud like one made at the Mac")
    func toldLikeTheMacs() async throws {
        let (shop, server, _) = await NetworkSwitchWiringTests.shop(option: true)
        #expect(await shop.phoneSetOutbound(body: Self.body(#"{"offline":true}"#), deviceName: "Phone").0 == 200)
        let asked = await server.asked
        #expect(asked.contains { $0.method == "PUT" }, "the one last call was not made: the phone's flip is a second, quieter path")
    }

    @Test("the route is wired to the real change, takes no second gate of its own, and is documented")
    func wiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appending(path: "Sources/KhaytApp")
        let server = try String(contentsOf: app.appending(path: "LanServer.swift"), encoding: .utf8)
        #expect(server.contains("await self?.phoneSetOutbound(body: body, deviceName: name)"))
        let phone = try String(contentsOf: app.appending(path: "Shop+PhoneNetworkSwitch.swift"), encoding: .utf8)
        #expect(phone.contains("await changeOutboundOffline(offline, by:"), "the phone's flip is not the Mac's own change")
        #expect(!phone.contains("writeNetworkSettings(") && !phone.contains("StoreWriter."), "a second write path")
        let doc = try String(contentsOf: root.deletingLastPathComponent().deletingLastPathComponent().appending(path: "docs/LAN_API.md"), encoding: .utf8)
        for said in ["### `POST /api/network/switch`", "bad-keep", "`can`", "network-switch"] { #expect(doc.contains(said), Comment(rawValue: said)) }
    }
}
