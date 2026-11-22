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
        #expect(cases.count >= 39 && roleOf.count >= 12 && paths.count >= 29)
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
        // The owner's own phone given a role keeps it, with the mark that it was set.
        #expect(devices.setRole(legacy.id, "manager"))
        #expect(try await role(legacy.id) == "manager")
        #expect(devices.rulesRecord(legacy.id)?["rolesVersion"] == "1")
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
        // A route the table does not name is the owner's.
        let (unlisted, why) = try await Self.status(bench, manager, "GET", "/api/identity/extra")
        #expect(unlisted == 403 || unlisted == 404)
        if unlisted == 403 { #expect(why["required"] as? String == "owner") }
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
            #expect(await shop.approvePhone(role: "owner") != nil, "nobody below the owner approves an owner phone")
            if who?.0 != "OP-m" { #expect(await shop.approvePhone(role: "viewer") == .notAllowed, "may give no role at all") }
        }
        shop.lockNow()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        #expect(await shop.setPhoneRole(phone.id, "manager") == nil)
        #expect(devices.rulesRecord(phone.id)?["role"] == "manager")
        #expect(await shop.setPhoneRole(phone.id, "root") == .roleNotGrantable, "only a role on the ladder")
        #expect(await shop.setPhoneRole("dev_nobody0000000000", "viewer") == .nothingToApprove)
        // A manager approving: nothing waits, and an owner grant is refused before that.
        shop.lockNow()
        #expect(await shop.signIn("OP-m", pin: "2222") == .ok)
        #expect(await shop.approvePhone(role: "owner") == .roleNotGrantable)
        #expect(await shop.approvePhone(role: "operator") == .nothingToApprove)
    }
}
