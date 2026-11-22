import Foundation
import Testing
import CryptoKit
import KhaytCore
@testable import KhaytApp

/// A paired phone's role on the Mac (`lib/device-roles.js`; phone pairing
/// design, decided Nov 22 2026): the role is stored on the device, read by
/// the shared rule, and enforced on every request the phone signs.
@MainActor
@Suite(.serialized)
struct PhoneRolesTests {

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { return o }; return [:] }
    static func vectors() throws -> [String: JSONValue] {
        obj(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appending(path: "test/fixtures/device-roles-vectors.json"))))
    }
    static let pin = LanConnectorScopeTests.pin
    typealias Peer = LanConnectorRoutesTests.Peer

    // MARK: - The shared rule, through the Mac's engine

    @Test("the shared vectors: every case, roleOf, scopesFor, grantable and the phone's own paths")
    func sharedVectors() async throws {
        let v = try Self.vectors()
        let engine = OperatorLockTests.sharedEngine
        guard case .array(let cases)? = v["cases"], case .array(let roleOf)? = v["roleOf"],
              case .array(let paths)? = v["phonePaths"] else { Issue.record("no vectors"); return }
        #expect(cases.count >= 43 && roleOf.count >= 12 && paths.count >= 31)
        for value in cases {
            let c = Self.obj(value), want = Self.obj(c["want"])
            guard case .string(let role)? = c["role"], case .string(let path)? = c["path"], case .string(let method)? = c["method"] else { continue }
            let why: Comment = { if case .string(let s)? = c["why"] { return Comment(rawValue: s) }; return "?" }()
            let got = try await engine.deviceAllows(.object(["role": .string(role), "rolesVersion": .number(1)]), path: path, method: method)
            #expect(JSONValue.bool(got.ok) == want["ok"], why)
            let required: JSONValue = got.required.map(JSONValue.string) ?? .null
            #expect(required == (want["required"] ?? .null), why)
        }
        for value in roleOf {
            let c = Self.obj(value)
            #expect(JSONValue.string(try await engine.deviceRole(c["device"] ?? .null)) == c["want"], "\(String(describing: c["device"]))")
        }
        for (role, want) in Self.obj(v["scopesFor"]) {
            #expect(JSONValue.array(try await engine.deviceScopes(role: role).map(JSONValue.string)) == want, Comment(rawValue: role))
        }
        for (role, want) in Self.obj(v["grantable"]) {
            #expect(JSONValue.array(try await engine.deviceRolesGrantable(by: role).map(JSONValue.string)) == want, Comment(rawValue: role))
        }
        #expect(try await engine.deviceDefaultRole() == "operator")
        // What the servers call: the request with its body and the stored job.
        guard case .array(let requests)? = v["requests"], case .array(let settable)? = v["settableRoles"] else {
            Issue.record("no request vectors"); return
        }
        #expect(requests.count >= 22 && settable.count >= 5)
        for value in requests {
            let c = Self.obj(value), want = Self.obj(c["want"])
            guard case .string(let role)? = c["role"], case .string(let path)? = c["path"], case .string(let method)? = c["method"] else { continue }
            let why: Comment = { if case .string(let s)? = c["why"] { return Comment(rawValue: s) }; return "?" }()
            let got = try await engine.deviceAllowsRequest(role: role, path: path, method: method, body: c["body"] ?? .null, job: c["job"] ?? .null)
            #expect(JSONValue.bool(got.ok) == want["ok"], why)
            let required: JSONValue = got.required.map(JSONValue.string) ?? .null
            #expect(required == (want["required"] ?? .null), why)
        }
        for value in settable {
            let c = Self.obj(value)
            guard case .string(let approver)? = c["approver"] else { continue }
            let got = try await engine.deviceRolesSettable(on: c["device"] ?? .null, by: approver)
            #expect(JSONValue.array(got.map(JSONValue.string)) == c["want"], "\(String(describing: c["why"]))")
        }
    }

    // MARK: - The device store

    static func phoneKey() -> (mine: Curve25519.KeyAgreement.PrivateKey, server: Curve25519.KeyAgreement.PrivateKey) {
        (.init(), .init())
    }

    /// A phone paired by code with `role`, and the key it signs with.
    static func codePaired(_ devices: LanDevices, role: String, name: String = "Floor phone", pin: String = pin) throws -> Peer {
        let k = phoneKey()
        let id = LanDevices.freshId()
        try devices.admitPhone(phonePublic: k.mine.publicKey.rawRepresentation.base64EncodedString(), serverKey: k.server,
                               deviceId: id, name: name, role: role, pin: pin, now: LanServerTests.Bench.start)
        return Peer(id: id, key: try #require(LanDevices.derive(k.mine, k.server.publicKey, deviceId: id)))
    }

    static func verdict(_ devices: LanDevices, _ peer: Peer, pin: String) -> LanDevices.Verdict {
        let headers = peer.headers("GET", "/api/queue")
        return devices.verify(headers: headers, method: "GET", target: "/api/queue", body: Data(), pin: pin,
                              now: Date(timeIntervalSince1970: TimeInterval(LanConnectorRoutesTests.now)))
    }

    @Test("a phone paired with the owner PIN before roles is the owner; a code-paired one holds what it was given")
    func legacyIsOwner() async throws {
        let devices = LanDevices.inMemory()
        let legacy = try LanConnectorScopeTests.enrol(devices, kind: nil, name: "Owner's phone")
        let floor = try Self.codePaired(devices, role: "viewer")
        let engine = OperatorLockTests.sharedEngine
        func role(_ id: String) async throws -> String {
            let r = try #require(devices.rulesRecord(id))
            return try await engine.deviceRole(KhaytEngine.deviceRecord(kind: r["kind"], role: r["role"],
                                                                         rolesVersion: r["rolesVersion"].flatMap(Int.init)))
        }
        #expect(devices.rulesRecord(legacy.id) == [:], "no role, no rolesVersion: stored as it always was")
        #expect(try await role(legacy.id) == "owner")
        #expect(devices.rulesRecord(floor.id) == ["role": "viewer", "rolesVersion": "1"])
        #expect(try await role(floor.id) == "viewer")
        // A role this build does not know is kept as written and read as a viewer, never dropped to "no role".
        #expect(devices.setRole(floor.id, "superuser"))
        #expect(devices.rulesRecord(floor.id)?["role"] == "superuser")
        #expect(try await role(floor.id) == "viewer")
        // A phone paired with the PIN holds the PIN, so it cannot be held to a lesser role:
        // it stays the owner (or is removed). Naming it the owner is allowed.
        #expect(!devices.setRole(legacy.id, "manager"))
        #expect(!devices.setRole(legacy.id, "viewer"))
        #expect(try await role(legacy.id) == "owner")
        #expect(devices.rulesRecord(legacy.id) == [:], "left exactly as it was stored")
        #expect(devices.setRole(legacy.id, "owner"))
        #expect(try await role(legacy.id) == "owner")
        // A connector is never given a phone's role.
        let slicer = try LanConnectorScopeTests.enrol(devices, kind: LanDevices.kindConnector, name: "Orca")
        #expect(!devices.setRole(slicer.id, "owner"))
        #expect(try await role(slicer.id) == "viewer")
        #expect(devices.list().first { $0.id == floor.id }?.codePaired == true)
        #expect(devices.list().first { $0.id == legacy.id }?.codePaired == false)
    }

    @Test("a PIN change signs out phones paired with the PIN, not ones paired by code; Remove signs out either (D-P7)")
    func pinChange() throws {
        let devices = LanDevices.inMemory()
        let byPin = try LanConnectorScopeTests.enrol(devices, kind: nil, name: "PIN phone")
        let byCode = try Self.codePaired(devices, role: "operator")
        let pinPeer = Peer(id: byPin.id, key: byPin.key)
        #expect(Self.verdict(devices, pinPeer, pin: Self.pin) == .pass)
        #expect(Self.verdict(devices, byCode, pin: Self.pin) == .pass)
        // The PIN changes.
        #expect(Self.verdict(devices, pinPeer, pin: "97531975") == .refused("device-unknown", now: nil))
        #expect(Self.verdict(devices, byCode, pin: "97531975") == .pass, "pairing by code never depended on the PIN")
        // A new phone enrolling under the new PIN does not push the code-paired one out either.
        _ = try devices.enrol(phonePublic: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
                              name: "New", pin: "97531975", identity: .init(), now: LanServerTests.Bench.start)
        #expect(devices.rulesRecord(byCode.id) != nil)
        // Remove signs it out, and says so.
        #expect(devices.remove(byCode.id))
        #expect(Self.verdict(devices, byCode, pin: "97531975") == .refused("device-revoked", now: nil))
    }

    // MARK: - The server enforces the role

    static func bench(code: Bool = false) async throws -> LanServerTests.Bench {
        try await LanServerTests.Bench(pin: pin, rest: true, phoneCodePairing: code)
    }

    static func status(_ bench: LanServerTests.Bench, _ peer: Peer, _ method: String, _ path: String,
                       body: Data = Data()) async throws -> (Int, [String: Any]) {
        let reply = try await LanConnectorRoutesTests.call(bench, peer, method, path, body: body)
        return (reply.status, reply.json)
    }

    @Test("each role opens what the table says and is refused the rest, with the scope it lacked")
    func serverEnforces() async throws {
        let bench = try await Self.bench()
        let viewer = try Self.codePaired(bench.devices, role: "viewer", name: "V")
        let op = try Self.codePaired(bench.devices, role: "operator", name: "O")
        let manager = try Self.codePaired(bench.devices, role: "manager", name: "M")
        let owner = try Self.codePaired(bench.devices, role: "owner", name: "W")
        let legacy = try LanConnectorRoutesTests.enrol(bench, kind: nil, name: "Legacy")

        // Reading the queue: everyone.
        for peer in [viewer, op, manager, owner, legacy] {
            #expect(try await Self.status(bench, peer, "GET", "/api/queue").0 == 200)
        }
        // The whole book: manager and up (`book:read`).
        for (peer, want) in [(viewer, 403), (op, 403), (manager, 200), (owner, 200), (legacy, 200)] {
            let (status, json) = try await Self.status(bench, peer, "GET", "/api/store")
            #expect(status == want)
            if want == 403 {
                #expect(json["reason"] as? String == "role-scope")
                #expect(json["required"] as? String == "book:read")
            }
        }
        // Writing the book: the owner only (`book:write`).
        for (peer, allowed) in [(viewer, false), (op, false), (manager, false), (owner, true), (legacy, true)] {
            let (status, json) = try await Self.status(bench, peer, "POST", "/api/store/deltas", body: Data("{}".utf8))
            #expect((status != 403) == allowed, "\(status)")
            if !allowed { #expect(json["required"] as? String == "book:write") }
        }
        // Clients: a manager reads them; an operator does not.
        #expect(try await Self.status(bench, op, "GET", "/api/clients").0 == 403)
        #expect(try await Self.status(bench, manager, "GET", "/api/clients").0 == 200)
        // A real route the table does not name is the owner's: the identity
        // key, which only somebody holding the PIN or an owner's phone reads.
        let engine = OperatorLockTests.sharedEngine
        let unlisted = try await engine.deviceAllows(.object(["role": .string("manager"), "rolesVersion": .number(1)]),
                                                     path: "/api/files/local", method: "POST")
        #expect(!unlisted.ok && unlisted.required == "owner")
        // This bench's shop has the staff lock OFF: the roles above held anyway (D-P5).
        #expect(!bench.shop.lockInForce)
    }

    @Test("an operator cannot approve a quote by spelling the path another way: the write that matters, refused")
    func encodedWrite() async throws {
        let bench = try await Self.bench()
        let op = try Self.codePaired(bench.devices, role: "operator")
        let manager = try Self.codePaired(bench.devices, role: "manager", name: "M")
        let job = bench.shop.orders.first?.id ?? "J1"
        for path in ["/api/orders/\(job)/approve", "/api/orders/\(job)%2Fapprove"] {
            let (status, json) = try await Self.status(bench, op, "POST", path, body: Data("{}".utf8))
            #expect(status == 403, Comment(rawValue: "\(path) → \(status)"))
            #expect(json["reason"] as? String == "role-scope", Comment(rawValue: path))
        }
        // A manager holds quote:write, so the same request is not refused for its role.
        let (status, json) = try await Self.status(bench, manager, "POST", "/api/orders/\(job)/approve", body: Data("{}".utf8))
        #expect(!(status == 403 && json["reason"] as? String == "role-scope"), "\(status)")
    }

    @Test("pricing through a job update is the manager's: an operator may move a job, not set a price or accept a quote")
    func pricingThroughJobRoutes() async throws {
        let bench = try await Self.bench()
        let op = try Self.codePaired(bench.devices, role: "operator")
        let manager = try Self.codePaired(bench.devices, role: "manager", name: "M")
        guard case .array(let orders)? = bench.book.value["printLog"] else { Issue.record("no jobs"); return }
        func id(where test: ([String: JSONValue]) -> Bool) -> String? {
            for o in orders { if case .object(let f) = o, test(f), case .string(let id)? = f["id"] { return id } }
            return nil
        }
        let quote = id { $0["status"] == .string("quote") }
        let job = try #require(id { $0["status"] != .string("quote") })
        func refusedForRole(_ peer: Peer, _ method: String, _ path: String, _ body: String) async throws -> Bool {
            let (status, json) = try await Self.status(bench, peer, method, path, body: Data(body.utf8))
            return status == 403 && json["reason"] as? String == "role-scope" && json["required"] as? String == "quote:write"
        }
        // A price, on a new job or an existing one.
        #expect(try await refusedForRole(op, "POST", "/api/orders", #"{"project":"x","price":1}"#))
        #expect(try await refusedForRole(op, "PATCH", "/api/orders/\(job)", #"{"price":1}"#))
        #expect(try await refusedForRole(op, "POST", "/api/orders", #"{"project":"x","status":"quote"}"#))
        // Accepting a quote by moving it on.
        if let quote {
            #expect(try await refusedForRole(op, "PATCH", "/api/orders/\(quote)", #"{"status":"pending"}"#))
            #expect(try await !refusedForRole(manager, "PATCH", "/api/orders/\(quote)", #"{"notes":"seen"}"#))
        }
        // A body that cannot be read is not waved through.
        #expect(try await refusedForRole(op, "PATCH", "/api/orders/\(job)", "not json"))
        // What an operator is for: notes and moving a job that is not a quote.
        #expect(try await !refusedForRole(op, "PATCH", "/api/orders/\(job)", #"{"notes":"on the bench"}"#))
        #expect(try await !refusedForRole(op, "PATCH", "/api/orders/\(job)", #"{"status":"printing"}"#))
        // A manager holds quote:write.
        #expect(try await !refusedForRole(manager, "PATCH", "/api/orders/\(job)", #"{"price":1}"#))
    }

    @Test("the code path shuts with Pair a phone: a PIN pairing, or the window closing, ends it")
    func codeWindowFollowsThePairWindow() async throws {
        let bench = try await Self.bench(code: true)
        bench.pairing.open()
        bench.phonePairing.open()
        let commit = Data(repeating: 9, count: 32).base64EncodedString()
        let ask = try JSONEncoder().encode(JSONValue.object(["v": .number(2), "commit": .string(commit), "name": .string("x")]))
        #expect(try await bench.send("POST", "/api/devices/pair", body: ask).status == 200)
        // The Pair a phone window shuts (as when a phone pairs with the PIN).
        bench.pairing.close()
        #expect(try await bench.send("POST", "/api/devices/pair", body: ask).status == 403)
        #expect(!bench.phonePairing.isOpenNow && bench.phonePairing.pending == nil, "the waiting offer went with it")
    }

    @Test("a path that decodes to another route is the owner's, however it is spelled")
    func encodedPaths() async throws {
        let bench = try await Self.bench()
        let op = try Self.codePaired(bench.devices, role: "operator")
        for path in ["/api/orders/x%2Fapprove", "/api/orders/..%2F..%2Fstore", "/api/orders/%2e%2e/store", "/api/store%2Fsettings"] {
            let (status, json) = try await Self.status(bench, op, "GET", path)
            #expect(status == 403 || status == 404, Comment(rawValue: "\(path) → \(status)"))
            if status == 403 { #expect(json["reason"] as? String == "role-scope") }
        }
        // The same checks hold under /v1.
        #expect(try await Self.status(bench, op, "GET", "/v1/store").0 == 403)
        #expect(try await Self.status(bench, op, "GET", "/v1/queue").0 == 200)
    }

    @Test("GET /api/devices/self says the role and its scopes, to the device that signed and nobody else")
    func deviceSelf() async throws {
        let bench = try await Self.bench()
        let op = try Self.codePaired(bench.devices, role: "operator")
        let (status, json) = try await Self.status(bench, op, "GET", "/api/devices/self")
        #expect(status == 200)
        #expect(json["deviceId"] as? String == op.id && json["role"] as? String == "operator")
        let scopes = (json["scopes"] as? [String]) ?? []
        #expect(scopes.contains("machines:control") && !scopes.contains("book:read"))
        // The owner PIN is not a device; no headers is nobody.
        #expect(try await bench.get("/api/devices/self", headers: ["x-khayt-pin": Self.pin]).status == 403)
        #expect([401, 403].contains(try await bench.get("/api/devices/self").status))
        // A role change takes effect on the next request, with nothing re-keyed.
        #expect(bench.devices.setRole(op.id, "viewer"))
        #expect(try await Self.status(bench, op, "GET", "/api/devices/self").1["role"] as? String == "viewer")
        // Removed: revoked.
        bench.devices.remove(op.id)
        let gone = try await Self.status(bench, op, "GET", "/api/devices/self")
        #expect(gone.0 == 401 && gone.1["reason"] as? String == "device-revoked")
    }

    @Test("/api/status tells a paired phone the shop's switch, signed; nobody else is told anything new")
    func statusCarriesTheSwitch() async throws {
        let bench = try await Self.bench()
        func network(_ json: [String: Any]) -> (offline: Bool?, keep: [String]?) {
            let n = json["network"] as? [String: Any]
            return (n?["offline"] as? Bool, n?["keep"] as? [String])
        }
        for role in ["operator", "viewer", "manager", "owner"] {
            let phone = try Self.codePaired(bench.devices, role: role, name: "Phone \(role)")
            let headers = phone.headers("GET", "/api/status?format=json")
            let reply = try await bench.send("GET", "/api/status?format=json", headers: headers, timeout: 30)
            #expect(reply.status == 200, Comment(rawValue: role))
            #expect(network(reply.json).offline == false && network(reply.json).keep == [], Comment(rawValue: role))
            #expect(reply.json["queued"] != nil, "the public counts are still there")
            #expect(reply.headers["x-khayt-reply-mac"] == LanServer.replyMac(key: phone.key, nonce: headers["x-khayt-nonce"] ?? "",
                                                                             status: 200, body: reply.body), Comment(rawValue: role))
        }
        // The shop turns it on and keeps updates; `lan` and a made-up id are not kept.
        var settings: [String: JSONValue] = { if case .object(let s)? = bench.book.value["settings"] { return s }; return [:] }()
        settings["network"] = .object(["offline": .bool(true), "keep": .array([.string("updates"), .string("lan"), .string("nonsense")])])
        bench.book.value["settings"] = .object(settings)
        let op = try Self.codePaired(bench.devices, role: "operator", name: "Floor")
        var on = try await bench.send("GET", "/api/status?format=json", headers: op.headers("GET", "/api/status?format=json"), timeout: 30)
        #expect(network(on.json).offline == true && network(on.json).keep == ["updates"])
        // A malformed block fails closed, with nothing kept.
        settings["network"] = .string("x")
        bench.book.value["settings"] = .object(settings)
        on = try await bench.send("GET", "/api/status?format=json", headers: op.headers("GET", "/api/status?format=json"), timeout: 30)
        #expect(network(on.json).offline == true && network(on.json).keep == [])
        // Nobody else: no headers, the PIN, and a signature that is not the phone's own.
        let open = try await bench.get("/api/status?format=json")
        #expect(open.status == 200 && open.json["network"] == nil && open.headers["x-khayt-reply-mac"] == nil)
        let pin = try await bench.get("/api/status?format=json", headers: ["x-khayt-pin": Self.pin])
        #expect(pin.status == 200 && pin.json["network"] == nil && pin.headers["x-khayt-reply-mac"] == nil)
        var forged = op.headers("GET", "/api/status?format=json")
        forged["x-khayt-mac"] = Data(repeating: 1, count: 32).base64EncodedString()
        let bad = try await bench.send("GET", "/api/status?format=json", headers: forged, timeout: 30)
        #expect(bad.status == 200 && bad.json["network"] == nil && bad.headers["x-khayt-reply-mac"] == nil)
        // The counts are still whole numbers after the block is added.
        let text = String(decoding: on.body, as: UTF8.self)
        #expect(!text.contains(".0") && text.contains("\"queued\":"), Comment(rawValue: text))
        #expect(on.headers["Cache-Control"] == "no-store" || on.headers["cache-control"] == "no-store")
        // A phone that was removed is told nothing new, and nothing is signed for it.
        #expect(bench.devices.remove(op.id))
        let gone = try await bench.send("GET", "/api/status?format=json", headers: op.headers("GET", "/api/status?format=json"), timeout: 30)
        #expect(gone.status == 200 && gone.json["network"] == nil && gone.headers["x-khayt-reply-mac"] == nil)
        // The public answer is byte for byte what it was.
        let expected = try await bench.engine.lanStatusBody(store: .object(bench.book.value), today: LanServer.localDay(bench.box.now))
        #expect(String(decoding: open.body, as: UTF8.self) == expected)
    }

    @Test("the role answers are signed back to the phone, and only to a request that verified")
    func replyMacs() async throws {
        let bench = try await Self.bench()
        let op = try Self.codePaired(bench.devices, role: "operator")
        func ask(_ path: String, headers: [String: String]) async throws -> LanServerTests.Bench.Reply {
            try await bench.send("GET", path, headers: headers, timeout: 30)
        }
        func expected(_ reply: LanServerTests.Bench.Reply, nonce: String) -> String {
            LanServer.replyMac(key: op.key, nonce: nonce, status: reply.status, body: reply.body)
        }
        // What the phone is.
        var headers = op.headers("GET", "/api/devices/self")
        var reply = try await ask("/api/devices/self", headers: headers)
        #expect(reply.status == 200)
        #expect(reply.headers["x-khayt-reply-mac"] == expected(reply, nonce: headers["x-khayt-nonce"] ?? ""))
        // A refusal for its role.
        headers = op.headers("GET", "/api/store")
        reply = try await ask("/api/store", headers: headers)
        #expect(reply.status == 403)
        #expect(reply.headers["x-khayt-reply-mac"] == expected(reply, nonce: headers["x-khayt-nonce"] ?? ""))
        // A request naming the phone with a signature that is not its own gets
        // no signed answer: nothing to replay at the real phone.
        headers = op.headers("GET", "/api/devices/self")
        headers["x-khayt-mac"] = Data(repeating: 1, count: 32).base64EncodedString()
        reply = try await ask("/api/devices/self", headers: headers)
        #expect(reply.status == 401)
        #expect(reply.headers["x-khayt-reply-mac"] == nil)
        headers = op.headers("GET", "/api/store")
        headers["x-khayt-mac"] = Data(repeating: 1, count: 32).base64EncodedString()
        reply = try await ask("/api/store", headers: headers)
        #expect(reply.status == 401 && reply.headers["x-khayt-reply-mac"] == nil)
    }

    @Test("the owner PIN and a connector are unchanged by roles")
    func othersUnchanged() async throws {
        let bench = try await Self.bench()
        #expect(try await bench.get("/api/store", headers: ["x-khayt-pin": Self.pin]).status == 200)
        let slicer = try LanConnectorRoutesTests.enrol(bench)
        let (status, json) = try await Self.status(bench, slicer, "GET", "/api/queue")
        #expect(status == 403 && json["reason"] as? String == "connector-scope")
    }

    // MARK: - Pairing by code

    @Test("off by default: the pairing route does not exist")
    func codePairingOff() async throws {
        let bench = try await Self.bench(code: false)
        bench.pairing.open()
        bench.phonePairing.open()
        #expect(try await bench.send("POST", "/api/devices/pair", body: Data(#"{"v":2,"commit":"x"}"#.utf8)).status == 404)
        #expect(try await bench.get("/api/devices/pair/abcdefabcdef").status == 404)
    }

    @Test("a phone pairs by code: commit, reveal, the same number on both sides, approve with a role, then its key works")
    func pairsByCode() async throws {
        let bench = try await Self.bench(code: true)
        let window = bench.phonePairing
        // Closed until a person opens it.
        let closed = try await bench.send("POST", "/api/devices/pair", body: Data(#"{"v":2,"commit":"AAAA"}"#.utf8))
        #expect(closed.status == 403)
        bench.pairing.open()
        window.open()
        let mine = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = mine.publicKey.rawRepresentation.base64EncodedString()
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let commit = LanConnectorPairing.commitment(pluginPublic: publicKey, nonce: nonce, flavor: .phone).base64EncodedString()
        let ask: JSONValue = .object(["v": .number(2), "commit": .string(commit), "name": .string("Reem's iPhone"),
                                      "app": .string("Khayt iPhone"), "version": .string("1.2.0")])
        let offered = try await bench.send("POST", "/api/devices/pair", body: try JSONEncoder().encode(ask))
        #expect(offered.status == 200)
        let offer = offered.json
        let pairId = try #require(offer["pairId"] as? String), secret = try #require(offer["pollSecret"] as? String)
        let deviceId = try #require(offer["deviceId"] as? String), serverPublic = try #require(offer["publicKey"] as? String)
        let identity = try #require(offer["identity"] as? String)
        #expect(window.pending?.check == nil, "no number before the reveal")
        let shown: JSONValue = .object(["publicKey": .string(publicKey), "nonce": .string(nonce)])
        let revealed = try await bench.send("POST", "/api/devices/pair/\(pairId)/reveal", body: try JSONEncoder().encode(shown),
                                            headers: ["x-khayt-poll": secret])
        #expect(revealed.status == 200)
        // Both sides work the number out for themselves, with the PHONE's prefix.
        let phoneSees = LanConnectorPairing.check(deviceId: deviceId, identityPublic: identity, serverPublic: serverPublic,
                                                  pluginPublic: publicKey, nonce: nonce, flavor: .phone)
        #expect(window.pending?.check == phoneSees && phoneSees.count == 6)
        #expect(try await bench.get("/api/devices/pair/\(pairId)", headers: ["x-khayt-poll": secret]).json["state"] as? String == "waiting")
        // The person approves, as an operator.
        let devices = bench.devices
        try window.approve { asked in
            try devices.admitPhone(phonePublic: try #require(asked.pluginPublic), serverKey: asked.serverKey, deviceId: asked.deviceId,
                                   name: asked.name, role: "operator", pin: Self.pin, now: LanServerTests.Bench.start)
        }
        #expect(try await bench.get("/api/devices/pair/\(pairId)", headers: ["x-khayt-poll": secret]).json["state"] as? String == "approved")
        let serverKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: try #require(Data(base64Encoded: serverPublic)))
        let phone = Peer(id: deviceId, key: try #require(LanDevices.derive(mine, serverKey, deviceId: deviceId)))
        #expect(try await Self.status(bench, phone, "GET", "/api/queue").0 == 200)
        #expect(try await Self.status(bench, phone, "GET", "/api/store").0 == 403, "an operator, as approved")
        #expect(bench.devices.list().first { $0.id == deviceId }?.name == "Reem's iPhone")
    }

    @Test("a slicer's commitment cannot pair as a phone: the prefixes differ, so the reveal fails")
    func kindsDoNotCross() async throws {
        let bench = try await Self.bench(code: true)
        bench.pairing.open()
        bench.phonePairing.open()
        let mine = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = mine.publicKey.rawRepresentation.base64EncodedString()
        let nonce = Data(repeating: 7, count: 16).base64EncodedString()
        #expect(LanConnectorPairing.commitment(pluginPublic: publicKey, nonce: nonce, flavor: .phone)
                != LanConnectorPairing.commitment(pluginPublic: publicKey, nonce: nonce, flavor: .connector))
        #expect(LanConnectorPairing.offerMessage(deviceId: "d", serverPublic: "s", commitment: "c", flavor: .phone)
                != LanConnectorPairing.offerMessage(deviceId: "d", serverPublic: "s", commitment: "c", flavor: .connector))
        // Committed the connector's way, offered to the phone route.
        let commit = LanConnectorPairing.commitment(pluginPublic: publicKey, nonce: nonce, flavor: .connector).base64EncodedString()
        let ask: JSONValue = .object(["v": .number(2), "commit": .string(commit), "name": .string("x")])
        let offer = try await bench.send("POST", "/api/devices/pair", body: try JSONEncoder().encode(ask)).json
        let pairId = try #require(offer["pairId"] as? String), secret = try #require(offer["pollSecret"] as? String)
        let shown: JSONValue = .object(["publicKey": .string(publicKey), "nonce": .string(nonce)])
        let revealed = try await bench.send("POST", "/api/devices/pair/\(pairId)/reveal", body: try JSONEncoder().encode(shown),
                                            headers: ["x-khayt-poll": secret])
        #expect(revealed.status == 403)
        #expect(bench.phonePairing.pending == nil, "the offer expired; no number was ever shown")
    }

    /// A phone that has asked and revealed, so its number is on the Mac's screen.
    static func waitingPhone(_ shop: Shop) throws -> (deviceId: String, pairId: String, check: String) {
        shop.lanPhonePairing = LanConnectorPairing(enabled: true, flavor: .phone)
        shop.lanPairing.open()
        shop.lanPhonePairing.open()
        let mine = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = mine.publicKey.rawRepresentation.base64EncodedString()
        let nonce = Data(repeating: 3, count: 16).base64EncodedString()
        let commit = LanConnectorPairing.commitment(pluginPublic: publicKey, nonce: nonce, flavor: .phone).base64EncodedString()
        let offer = try shop.lanPhonePairing.request(commitment: commit, name: "Reem's iPhone", app: "Khayt iPhone", version: "1",
                                                     address: "192.168.1.47", identity: .init(), pollSecret: "s3cret")
        #expect(shop.lanPhonePairing.reveal(pairId: offer.pairId, secret: "s3cret", publicKey: publicKey, nonce: nonce) == .accepted)
        let check = try #require(shop.lanPhonePairing.pending?.check)
        return (offer.deviceId, offer.pairId, check)
    }

    @Test("with a phone waiting and its number shown: an operator approves nothing, a manager not an owner, and the approval enrols the role chosen")
    func approvingAWaitingPhone() async throws {
        let shop = await OperatorLockTests.shop()
        let devices = LanDevices.inMemory()
        shop.lanDevicesForTests = devices
        let shown = try Self.waitingPhone(shop)
        let deviceId = shown.deviceId
        for who in [nil, ("OP-v", "4444"), ("OP-x", "3333")] as [(String, String)?] {
            shop.lockNow()
            if let who { #expect(await shop.signIn(who.0, pin: who.1) == .ok) }
            #expect(await shop.approvePhone(role: "viewer", pairId: shown.pairId, check: shown.check) == .notAllowed, Comment(rawValue: who?.0 ?? "nobody"))
            #expect(devices.rulesRecord(deviceId) == nil)
        }
        shop.lockNow()
        #expect(await shop.signIn("OP-m", pin: "2222") == .ok)
        #expect(await shop.approvePhone(role: "owner", pairId: shown.pairId, check: shown.check) == .roleNotGrantable)
        #expect(devices.rulesRecord(deviceId) == nil, "a manager made nobody an owner")
        // The approval is for the request that was shown: another id, or another number, enrols nothing.
        #expect(await shop.approvePhone(role: "operator", pairId: "zzzzzzzzzzzz", check: shown.check) == .notTheOneShown)
        #expect(await shop.approvePhone(role: "operator", pairId: shown.pairId, check: "000000") == .notTheOneShown)
        #expect(devices.rulesRecord(deviceId) == nil)
        #expect(shop.lanPhonePairing.pending?.check != nil, "the request still waits for somebody who may")
        // The manager approves it as an operator. On the sample book the PIN
        // may not be readable; then nothing is enrolled and the window says why.
        let result = await shop.approvePhone(role: "operator", pairId: shown.pairId, check: shown.check)
        #expect(result == nil || result == .pinUnreadable, "\(String(describing: result))")
        if result == nil {
            #expect(devices.rulesRecord(deviceId) == ["role": "operator", "rolesVersion": "1"])
            #expect(devices.list().first { $0.id == deviceId }?.codePaired == true)
            #expect(!shop.lanPairing.isOpen(), "Pair a phone shut once the phone was paired")
        } else {
            #expect(devices.rulesRecord(deviceId) == nil)
        }
        // Once Pair a phone is shut, nothing can be approved.
        let again = try Self.waitingPhone(shop)
        shop.lanPairing.close()
        #expect(await shop.approvePhone(role: "viewer", pairId: again.pairId, check: again.check) == .nothingToApprove)
    }

    // MARK: - The shared phone-pairing vectors (docs/phone-pair.vectors.json)

    static func pairVectors() throws -> [String: JSONValue] {
        obj(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appending(path: "docs/phone-pair.vectors.json"))))
    }
    static func text(_ c: [String: JSONValue], _ key: String) -> String {
        if case .string(let s)? = c[key] { return s }
        return ""
    }

    @Test("the phone's prefixes are the vectors' own, spelled out here")
    func prefixes() throws {
        let p = Self.obj(try Self.pairVectors()["prefixes"])
        #expect(p["commit"] == .string("khayt-phone-commit-v1"))
        #expect(p["offer"] == .string("khayt-enrol-phone-v1"))
        #expect(p["check"] == .string("khayt-phone-check-v1"))
        #expect(LanConnectorPairing.Flavor.phone.commit == "khayt-phone-commit-v1")
        #expect(LanConnectorPairing.Flavor.phone.offer == "khayt-enrol-phone-v1")
        #expect(LanConnectorPairing.Flavor.phone.check == "khayt-phone-check-v1")
    }

    @Test("commitment, signed offer, check number and derived key match the shared phone vectors, and the window reaches the same number")
    func phonePairVectors() throws {
        guard case .array(let cases)? = try Self.pairVectors()["cases"] else { Issue.record("no cases"); return }
        #expect(cases.count >= 9)
        let hex = LanConnectorPairingTests.hex
        for value in cases {
            let c = Self.obj(value)
            let name = Comment(rawValue: Self.text(c, "name"))
            let identity = try Curve25519.Signing.PrivateKey(rawRepresentation: hex(Self.text(c, "identitySeedHex")))
            let server = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(Self.text(c, "serverPrivateHex")))
            let phone = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(Self.text(c, "pluginPrivateHex")))
            let phonePublic = Self.text(c, "pluginPublic"), nonce = Self.text(c, "nonce")
            let deviceId = Self.text(c, "deviceId"), serverPublic = Self.text(c, "serverPublic")
            #expect(identity.publicKey.rawRepresentation.base64EncodedString() == Self.text(c, "identityPublic"), name)
            #expect(server.publicKey.rawRepresentation.base64EncodedString() == serverPublic, name)
            #expect(phone.publicKey.rawRepresentation.base64EncodedString() == phonePublic, name)
            let commit = LanConnectorPairing.commitment(pluginPublic: phonePublic, nonce: nonce, flavor: .phone).base64EncodedString()
            #expect(commit == Self.text(c, "commit"), name)
            let message = LanConnectorPairing.offerMessage(deviceId: deviceId, serverPublic: serverPublic, commitment: commit, flavor: .phone)
            #expect(String(decoding: message, as: UTF8.self) == Self.text(c, "offerMessage"), name)
            #expect(identity.publicKey.isValidSignature(try #require(Data(base64Encoded: Self.text(c, "sig"))), for: message), name)
            #expect(LanConnectorPairing.check(deviceId: deviceId, identityPublic: Self.text(c, "identityPublic"), serverPublic: serverPublic,
                                              pluginPublic: phonePublic, nonce: nonce, flavor: .phone) == Self.text(c, "check"), name)
            // The key both sides keep.
            let derived = try #require(LanDevices.derive(server, phone.publicKey, deviceId: deviceId))
            #expect(derived.base64EncodedString() == Self.text(c, "derivedKey"), name)
            // The same case through the Mac's own window, with the vector's keys.
            let window = LanConnectorPairing(enabled: true, flavor: .phone)
            window.open()
            let offer = try window.request(commitment: commit, name: "Phone", app: "Khayt iPhone", version: "1", address: "192.168.1.9",
                                           identity: identity, freshKey: { server }, deviceId: deviceId, pollSecret: "poll")
            #expect(offer.publicKey == serverPublic, name)
            #expect(identity.publicKey.isValidSignature(try #require(Data(base64Encoded: offer.sig)), for: message), name)
            #expect(window.reveal(pairId: offer.pairId, secret: "poll", publicKey: phonePublic, nonce: nonce) == .accepted, name)
            #expect(window.pending?.check == Self.text(c, "check"), name)
        }
    }

    @Test("the vectors' three reveals the Mac must refuse: a short nonce, a key that was not committed, an all-zero key")
    func refusedReveals() throws {
        guard case .array(let all)? = try Self.pairVectors()["refuse"] else { Issue.record("no refusals"); return }
        let mine = all.map(Self.obj).filter { $0["refusedBy"] == .string("mac") }
        #expect(Set(mine.map { Self.text($0, "name") }) == ["short-nonce", "reveal-mismatch", "all-zero-phone-key"])
        for c in mine {
            let name = Comment(rawValue: Self.text(c, "name"))
            let window = LanConnectorPairing(enabled: true, flavor: .phone)
            window.open()
            let offer = try window.request(commitment: Self.text(c, "commit"), name: "Phone", app: "Khayt iPhone", version: "1",
                                           address: "192.168.1.9", identity: .init(), pollSecret: "poll")
            #expect(window.reveal(pairId: offer.pairId, secret: "poll", publicKey: Self.text(c, "revealPublic"),
                                  nonce: Self.text(c, "revealNonce")) == .refused, name)
            #expect(window.pending == nil, name)
            #expect(window.poll(pairId: offer.pairId, secret: "poll") == .expired, name)
        }
    }

    @Test("the phone cancels its own request: the Mac stops waiting on it, only its poll secret can, and an answer already given stays")
    func phoneCancels() throws {
        let commit = Data(repeating: 7, count: 32).base64EncodedString()
        let window = LanConnectorPairing(enabled: true, flavor: .phone)
        window.open()
        let offer = try window.request(commitment: commit, name: "Phone", app: "Khayt iPhone", version: "1",
                                       address: "192.168.1.9", identity: .init(), pollSecret: "poll")
        // Somebody else on the Wi-Fi who saw the id cannot cancel it.
        #expect(window.cancel(pairId: offer.pairId, secret: "guess") == .unknown)
        #expect(window.cancel(pairId: "aaaaaaaaaaaa", secret: "poll") == .unknown)
        #expect(window.pending?.pairId == offer.pairId)
        #expect(window.cancel(pairId: offer.pairId, secret: "poll") == .cancelled)
        #expect(window.pending == nil, "the owner's screen is back to waiting")
        #expect(window.isOpen(), "the window itself stays open for the next phone")
        #expect(window.poll(pairId: offer.pairId, secret: "poll") == .expired)
        // Twice is harmless, and says how it ended.
        #expect(window.cancel(pairId: offer.pairId, secret: "poll") == .answered(.expired))
        // Nothing was enrolled, and approving now approves nothing.
        var enrolled = 0
        window.approve { _ in enrolled += 1 }
        #expect(enrolled == 0)
        // A second phone can ask in the same window.
        let next = try window.request(commitment: commit, name: "Phone 2", app: "Khayt iPhone", version: "1",
                                      address: "192.168.1.10", identity: .init(), pollSecret: "poll2")
        window.deny()
        #expect(window.cancel(pairId: next.pairId, secret: "poll2") == .answered(.denied), "a denial is not rewritten")
    }

    @Test("DELETE /api/devices/pair/<id>: 200 with the poll secret, 404 without, and 404 while the code path is off")
    func cancelRoute() async throws {
        let bench = try await Self.bench(code: true)
        bench.pairing.open(); bench.phonePairing.open()
        let ask: JSONValue = .object(["v": .number(2), "commit": .string(Data(repeating: 7, count: 32).base64EncodedString()),
                                      "name": .string("Phone"), "app": .string("Khayt iPhone"), "version": .string("1")])
        let offer = try await bench.send("POST", "/api/devices/pair", body: try JSONEncoder().encode(ask)).json
        let pairId = try #require(offer["pairId"] as? String), secret = try #require(offer["pollSecret"] as? String)
        #expect(try await bench.send("DELETE", "/api/devices/pair/\(pairId)", body: Data(), headers: ["x-khayt-poll": "guess"]).status == 404)
        #expect(bench.phonePairing.pending?.pairId == pairId)
        let done = try await bench.send("DELETE", "/api/devices/pair/\(pairId)", body: Data(), headers: ["x-khayt-poll": secret])
        #expect(done.status == 200 && done.json["state"] as? String == "cancelled")
        #expect(bench.phonePairing.pending == nil)
        #expect(try await bench.get("/api/devices/pair/\(pairId)", headers: ["x-khayt-poll": secret]).json["state"] as? String == "expired")
        let again = try await bench.send("DELETE", "/api/devices/pair/\(pairId)", body: Data(), headers: ["x-khayt-poll": secret])
        #expect(again.status == 409 && again.json["state"] as? String == "expired")
    }

    // MARK: - Who may give which role

    @Test("the owner gives any role, a manager up to manager, anyone else none; the lock off is the owner (D-P3)")
    func whoMayGrant() async throws {
        let shop = await OperatorLockTests.shop()
        shop.lanDevicesForTests = LanDevices.inMemory()
        for (who, want) in [(nil, []), (("OP-v", "4444"), []), (("OP-x", "3333"), []),
                            (("OP-m", "2222"), ["manager", "operator", "viewer"]),
                            (("OP-o", "1111"), ["owner", "manager", "operator", "viewer"])] as [((String, String)?, [String])] {
            shop.lockNow()
            if let who { #expect(await shop.signIn(who.0, pin: who.1) == .ok) }
            #expect(await shop.phoneRolesGrantable() == want, Comment(rawValue: who?.0 ?? "nobody"))
        }
        // Operator is the default where it may be given.
        #expect(await shop.phoneDefaultRole() == "operator")
        let open = await OperatorLockTests.shop(on: false)
        #expect(await open.phoneRolesGrantable() == ["owner", "manager", "operator", "viewer"])
    }

    @Test("a manager may open Pair a phone, as the owner may; an operator, a viewer and nobody may not (Turki, Nov 22)")
    func whoMayOpenPairing() async throws {
        let shop = await OperatorLockTests.shop()
        shop.lanDevicesForTests = LanDevices.inMemory()
        let engine = try #require(shop.engine)
        // The opener set is the rule's: exactly the roles that may give a phone a role.
        for role in ["owner", "manager", "operator", "viewer", "nobody"] {
            let gives = try await engine.deviceRolesGrantable(by: role)
            #expect(Shop.pairingOpeners.contains(role) == !gives.isEmpty, Comment(rawValue: role))
        }
        for (who, may) in [(nil, false), (("OP-v", "4444"), false), (("OP-x", "3333"), false),
                           (("OP-m", "2222"), true), (("OP-o", "1111"), true)] as [((String, String)?, Bool)] {
            shop.lockNow()
            shop.closePairing()
            if let who { #expect(await shop.signIn(who.0, pin: who.1) == .ok) }
            let name = Comment(rawValue: who?.0 ?? "nobody")
            #expect(shop.mayOpenPairing == may, name)
            shop.moveProblem = nil
            shop.openPairing()
            #expect(shop.lanPairing.isOpenNow == may, name)
            #expect(LockReviewTests.refused(shop) == !may, name)
            // Opening changes nothing about what this person may approve.
            #expect((await shop.phoneRolesGrantable()).isEmpty == !may, name)
        }
        // A manager who opened the window still cannot give Owner, nor change settings.
        shop.lockNow()
        #expect(await shop.signIn("OP-m", pin: "2222") == .ok)
        #expect(!(await shop.phoneRolesGrantable()).contains("owner"))
        #expect(!shop.lockAllows("settings", "edit"))
        shop.closePairing()
        // The staff lock off: whoever is at the Mac opens it, as before.
        let open = await OperatorLockTests.shop(on: false)
        #expect(open.mayOpenPairing)
        // The button asks without saying.
        let view = try LockRound3Tests.source("Shop+PairedPhones.swift")
        #expect(view.contains(".disabled(!shop.mayOpenPairing || !reachable)"))
    }

    @Test("changing a paired phone's role is the owner's alone; a manager cannot lift a phone or lower the owner's")
    func roleChangeIsTheOwners() async throws {
        let shop = await OperatorLockTests.shop()
        let devices = LanDevices.inMemory()
        shop.lanDevicesForTests = devices
        let phone = try Self.codePaired(devices, role: "viewer")
        for who in [nil, ("OP-v", "4444"), ("OP-x", "3333"), ("OP-m", "2222")] as [(String, String)?] {
            shop.lockNow()
            if let who { #expect(await shop.signIn(who.0, pin: who.1) == .ok) }
            #expect(await shop.setPhoneRole(phone.id, "manager") == .notAllowed)
            #expect(devices.rulesRecord(phone.id)?["role"] == "viewer")
            #expect(await shop.approvePhone(role: "owner", pairId: "x", check: "0") != nil, "nobody below the owner approves an owner phone")
            if who?.0 != "OP-m" { #expect(await shop.approvePhone(role: "viewer", pairId: "x", check: "0") == .notAllowed, "may give no role at all") }
        }
        shop.lockNow()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        #expect(await shop.setPhoneRole(phone.id, "manager") == nil)
        #expect(devices.rulesRecord(phone.id)?["role"] == "manager")
        #expect(await shop.setPhoneRole(phone.id, "root") == .roleNotGrantable, "only a role on the ladder")
        #expect(await shop.setPhoneRole("dev_nobody0000000000", "viewer") == .nothingToApprove)
        // A PIN-paired phone is not demoted: it would send the PIN instead.
        let byPin = try LanConnectorScopeTests.enrol(devices, kind: nil, name: "PIN phone")
        #expect(await shop.setPhoneRole(byPin.id, "viewer") == .pairedWithPin)
        #expect(devices.rulesRecord(byPin.id) == [:])
        // A manager approving: nothing waits, and an owner grant is refused before that.
        shop.lockNow()
        #expect(await shop.signIn("OP-m", pin: "2222") == .ok)
        #expect(await shop.approvePhone(role: "owner", pairId: "x", check: "0") == .roleNotGrantable)
        #expect(await shop.approvePhone(role: "operator", pairId: "x", check: "0") == .nothingToApprove)
    }
}
