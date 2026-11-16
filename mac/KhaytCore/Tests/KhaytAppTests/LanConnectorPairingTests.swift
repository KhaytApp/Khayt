import Foundation
import Testing
import CryptoKit
@testable import KhaytApp

/// A slicer plugin pairs over the shop's network without the PIN: it commits
/// to its key, the Mac answers with a fresh signed key, the plugin reveals,
/// both screens show the same check number, and the owner approves
/// (`LanConnectorPairing`, v2). Played here the way the plugin plays it, over
/// HTTP against a real server, plus the grind test the commitment exists for.
@MainActor
@Suite(.serialized)
struct LanConnectorPairingTests {

    static let pin = "24682468"

    /// Pairing is off in beta.38 (`LanConnectorPairing.enabled`); these tests
    /// are about the protocol, so they turn it on.
    init() { LanConnectorPairing.enabledForTests = true }

    @Test("off by default: no window opens, so a plugin is told pairing-closed")
    func offByDefault() throws {
        LanConnectorPairing.enabledForTests = false
        defer { LanConnectorPairing.enabledForTests = true }
        guard !UserDefaults.standard.bool(forKey: "connectorPairing") else { return }
        let window = LanConnectorPairing()
        window.open()
        #expect(!window.isOpen())
        #expect(window.deadline == nil)
        var drawn = 0
        #expect(throws: LanConnectorPairing.Refusal.closed) {
            _ = try window.request(commitment: Plugin().commit, name: "x", app: "OrcaSlicer", version: "1",
                                   address: "192.168.1.9", identity: Curve25519.Signing.PrivateKey(),
                                   freshKey: { drawn += 1; return .init() })
        }
        #expect(drawn == 0, "no key is drawn while pairing is off")
    }


    /// The plugin's side: its key, its nonce, and what it sends.
    struct Plugin {
        let key = Curve25519.KeyAgreement.PrivateKey()
        var nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
        var commit: String { LanConnectorPairing.commitment(pluginPublic: publicKey, nonce: nonce).base64EncodedString() }
        func body(name: String = "OrcaSlicer on Studio iMac") -> Data {
            Data(#"{"v":2,"commit":"\#(commit)","name":"\#(name)","app":"OrcaSlicer","version":"2.5.1"}"#.utf8)
        }
        func revealBody(publicKey: String? = nil, nonce: String? = nil) -> Data {
            Data(#"{"publicKey":"\#(publicKey ?? self.publicKey)","nonce":"\#(nonce ?? self.nonce)"}"#.utf8)
        }
    }

    struct Offer: Decodable { let pairId, pollSecret, deviceId, publicKey, sig, identity: String }

    static func ask(_ bench: LanServerTests.Bench, _ plugin: Plugin) async throws -> (LanServerTests.Bench.Reply, Offer?) {
        let reply = try await bench.send("POST", "/api/connectors/pair", body: plugin.body())
        return (reply, try? JSONDecoder().decode(Offer.self, from: reply.body))
    }

    static func reveal(_ bench: LanServerTests.Bench, _ offer: Offer, _ body: Data,
                       secret: String? = nil) async throws -> LanServerTests.Bench.Reply {
        try await bench.send("POST", "/api/connectors/pair/\(offer.pairId)/reveal", body: body,
                             headers: ["x-khayt-poll": secret ?? offer.pollSecret])
    }

    /// Ask and reveal, as the plugin does when nothing is wrong.
    static func askAndReveal(_ bench: LanServerTests.Bench, _ plugin: Plugin) async throws -> Offer {
        let offer = try #require(try await ask(bench, plugin).1)
        let shown = try await reveal(bench, offer, plugin.revealBody())
        #expect(shown.status == 200, "\(shown.text)")
        return offer
    }

    static func poll(_ bench: LanServerTests.Bench, _ offer: Offer, secret: String? = nil) async throws -> LanServerTests.Bench.Reply {
        try await bench.get("/api/connectors/pair/\(offer.pairId)", headers: ["x-khayt-poll": secret ?? offer.pollSecret])
    }

    static func approve(_ bench: LanServerTests.Bench) throws {
        try bench.connectorPairing.approve { asked in
            try bench.devices.admitConnector(pluginPublic: try #require(asked.pluginPublic), serverKey: asked.serverKey,
                                             deviceId: asked.deviceId, name: asked.name, pin: pin,
                                             now: LanServerTests.Bench.start)
        }
    }

    // MARK: - The shared vectors

    struct Vectors: Decodable {
        struct Case: Decodable {
            let name, identitySeedHex, serverPrivateHex, pluginPrivateHex, nonceHex, deviceId: String
            let identityPublic, serverPublic, pluginPublic, nonce, commit, offerMessage, sig, check: String
        }
        let cases: [Case]
    }

    static func hex(_ s: String) -> Data {
        Data(stride(from: 0, to: s.count, by: 2).map { i in
            UInt8(s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: i + 2)], radix: 16)!
        })
    }

    @Test("commitment, signed offer and check number match the shared vectors, byte for byte")
    func checkVectors() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/connector-pair.vectors.json")
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        #expect(vectors.cases.count >= 8)
        #expect(vectors.cases.filter { $0.check.hasPrefix("0") }.count >= 2, "a check with a leading zero keeps it")
        for c in vectors.cases {
            let identity = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.hex(c.identitySeedHex))
            #expect(identity.publicKey.rawRepresentation.base64EncodedString() == c.identityPublic, "\(c.name)")
            let server = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.hex(c.serverPrivateHex))
            let plugin = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.hex(c.pluginPrivateHex))
            #expect(server.publicKey.rawRepresentation.base64EncodedString() == c.serverPublic, "\(c.name)")
            #expect(plugin.publicKey.rawRepresentation.base64EncodedString() == c.pluginPublic, "\(c.name)")
            #expect(Self.hex(c.nonceHex).count >= LanConnectorPairing.minNonce)
            #expect(Self.hex(c.nonceHex).base64EncodedString() == c.nonce, "\(c.name)")
            #expect(LanConnectorPairing.commitment(pluginPublic: c.pluginPublic, nonce: c.nonce).base64EncodedString()
                    == c.commit, "\(c.name)")
            let message = LanConnectorPairing.offerMessage(deviceId: c.deviceId, serverPublic: c.serverPublic,
                                                           commitment: c.commit)
            #expect(String(decoding: message, as: UTF8.self) == c.offerMessage, "\(c.name)")
            #expect(identity.publicKey.isValidSignature(try #require(Data(base64Encoded: c.sig)),
                                                        for: message), "\(c.name)")
            #expect(LanConnectorPairing.check(deviceId: c.deviceId, identityPublic: c.identityPublic,
                                              serverPublic: c.serverPublic, pluginPublic: c.pluginPublic,
                                              nonce: c.nonce) == c.check, "\(c.name)")
        }
        let checks = Set(vectors.cases.map(\.check))
        #expect(checks.count == vectors.cases.count, "the id, the identity, the keys' order and the nonce change the number")
    }

    // MARK: - Over the network

    @Test("closed until the owner clicks Pair a slicer, and no PIN is ever asked for")
    func closedUntilOpened() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        let (reply, _) = try await Self.ask(bench, Plugin())
        #expect(reply.status == 403 && reply.text.contains("pairing-closed"))
        // The phone's window being open does not open the slicer's.
        bench.pairing.open()
        let (still, _) = try await Self.ask(bench, Plugin())
        #expect(still.status == 403 && still.text.contains("pairing-closed"))
        #expect(bench.devices.list().isEmpty)
    }

    @Test("commit, signed offer, reveal, same number, approved: the key opens its own routes and not the book")
    func approvedPairing() async throws {
        let identity = Curve25519.Signing.PrivateKey()
        let bench = try await LanServerTests.Bench(pin: Self.pin, identity: identity)
        defer { bench.stop() }
        bench.connectorPairing.open()
        let plugin = Plugin()
        let (reply, maybe) = try await Self.ask(bench, plugin)
        #expect(reply.status == 200, "\(reply.text)")
        let offer = try #require(maybe)

        // The plugin checks the Mac's fresh key against the identity it was
        // handed and the commitment it sent, before it reveals anything.
        #expect(offer.identity == identity.publicKey.rawRepresentation.base64EncodedString())
        let macIdentity = try Curve25519.Signing.PublicKey(
            rawRepresentation: try #require(Data(base64Encoded: offer.identity)))
        let sig = try #require(Data(base64Encoded: offer.sig))
        #expect(macIdentity.isValidSignature(sig, for: LanConnectorPairing.offerMessage(
            deviceId: offer.deviceId, serverPublic: offer.publicKey, commitment: plugin.commit)))

        // No number, and nothing to approve, before the reveal.
        let before = try #require(bench.connectorPairing.pending)
        #expect(before.check == nil && before.pluginPublic == nil)
        try Self.approve(bench)
        #expect(bench.devices.list().isEmpty, "Approve before the reveal does nothing")
        #expect(try await Self.poll(bench, offer).text.contains("waiting"))

        let shown = try await Self.reveal(bench, offer, plugin.revealBody())
        #expect(shown.status == 200 && shown.text.contains("waiting"), "\(shown.text)")
        let pending = try #require(bench.connectorPairing.pending)
        #expect(LanConnectorPairing.check(deviceId: offer.deviceId, identityPublic: offer.identity,
                                          serverPublic: offer.publicKey, pluginPublic: plugin.publicKey,
                                          nonce: plugin.nonce) == pending.check)
        #expect(pending.name == "OrcaSlicer on Studio iMac" && pending.app == "OrcaSlicer" && pending.version == "2.5.1")
        #expect(try await Self.reveal(bench, offer, plugin.revealBody()).status == 409, "one reveal per offer")

        // Nothing is enrolled while the owner looks.
        #expect(bench.devices.list().isEmpty)
        try Self.approve(bench)
        #expect(try await Self.poll(bench, offer).text.contains("approved"))
        #expect(!bench.connectorPairing.isOpenNow, "the window closes once a slicer is paired")
        #expect(bench.connectorPairing.lastClosed == .paired(name: "OrcaSlicer on Studio iMac"))
        #expect(bench.devices.kind(of: offer.deviceId) == LanDevices.kindConnector)

        // The key both sides derived signs; it opens /api/connectors only.
        let serverPublic = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: try #require(Data(base64Encoded: offer.publicKey)))
        let key = try #require(LanDevices.derive(plugin.key, serverPublic, deviceId: offer.deviceId))
        var signer = LanConnectorScopeTests.Signer(id: offer.deviceId, key: key)
        let now = Int(LanServerTests.Bench.start.timeIntervalSince1970)
        let book = try await bench.get("/api/store", headers: signer.headers("GET", "/api/store", Data(), time: now))
        #expect(book.status == 403 && book.text.contains("connector-scope"))
        let own = try await bench.get("/api/connectors/queue",
                                      headers: signer.headers("GET", "/api/connectors/queue", Data(), time: now))
        #expect(!own.text.contains("connector-scope"), "its own routes pass the scope (\(own.status))")
    }

    @Test("a reveal that does not match the commitment, or is malformed, expires the offer with no number")
    func badReveal() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        let plugin = Plugin()
        let other = Plugin()
        let short = Data(repeating: 7, count: 8).base64EncodedString()
        var shortNonce = Plugin()
        shortNonce.nonce = short   // committed honestly, but only 8 bytes
        let tries: [(String, Plugin, Data)] = [
            ("another key", plugin, plugin.revealBody(publicKey: other.publicKey)),
            ("another nonce", plugin, plugin.revealBody(nonce: other.nonce)),
            ("a short nonce", shortNonce, shortNonce.revealBody()),
            ("an all-zero key", plugin, plugin.revealBody(publicKey: Data(count: 32).base64EncodedString())),
            ("no body", plugin, Data()),
        ]
        for (why, asker, body) in tries {
            bench.connectorPairing.open()
            let offer = try #require(try await Self.ask(bench, asker).1)
            let refused = try await Self.reveal(bench, offer, body)
            #expect(refused.status == 403 && refused.text.contains("expired"), "\(why): \(refused.text)")
            #expect(bench.connectorPairing.pending == nil, "\(why): no number was ever worked out")
            #expect(try await Self.poll(bench, offer).text.contains("expired"), "\(why)")
            #expect(bench.connectorPairing.offersLeft == LanConnectorPairing.maxOffers - 1, "\(why): it counted")
        }
    }

    @Test("a reveal later than 30 s expires the offer and frees the slot")
    func lateReveal() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        bench.connectorPairing.open()
        let plugin = Plugin()
        let offer = try #require(try await Self.ask(bench, plugin).1)
        bench.advance(seconds: LanConnectorPairing.revealWithin + 1)
        let late = try await Self.reveal(bench, offer, plugin.revealBody())
        #expect(late.status == 403 && late.text.contains("expired"), "\(late.text)")
        #expect(bench.connectorPairing.pending == nil)
        // An offer never revealed at all frees the slot too, without a poll.
        let quiet = try #require(try await Self.ask(bench, Plugin()).1)
        bench.advance(seconds: LanConnectorPairing.revealWithin + 1)
        #expect(try await Self.ask(bench, Plugin()).0.status == 200, "the abandoned offer no longer holds the slot")
        #expect(try await Self.poll(bench, quiet).text.contains("expired"))
    }

    @Test("three offers per window, whatever became of them; then the owner must click again")
    func offersAreCapped() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        bench.connectorPairing.open()
        // One denied after its reveal, one with a bad reveal, one abandoned.
        _ = try await Self.askAndReveal(bench, Plugin())
        bench.connectorPairing.deny()
        let plugin = Plugin()
        let second = try #require(try await Self.ask(bench, plugin).1)
        _ = try await Self.reveal(bench, second, plugin.revealBody(nonce: Plugin().nonce))
        _ = try #require(try await Self.ask(bench, Plugin()).1)
        #expect(bench.connectorPairing.offersLeft == 0)
        bench.advance(seconds: LanConnectorPairing.revealWithin + 1)
        let (fourth, _) = try await Self.ask(bench, Plugin())
        #expect(fourth.status == 403 && fourth.text.contains("pairing-closed"), "\(fourth.text)")
        #expect(bench.connectorPairing.lastClosed == .offersUsed)
        bench.connectorPairing.open()
        #expect(bench.connectorPairing.offersLeft == LanConnectorPairing.maxOffers)
        #expect(try await Self.ask(bench, Plugin()).0.status == 200, "a fresh click gives a fresh three")
    }

    @Test("a v1 ask is told to upgrade, and no key is drawn for a bad commitment")
    func v1IsRefused() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        bench.connectorPairing.open()
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        for body in [#"{"publicKey":"\#(key)","name":"Orca"}"#, #"{"v":1,"commit":"\#(Plugin().commit)"}"#,
                     #"{"commit":"\#(Plugin().commit)"}"#] {
            let reply = try await bench.send("POST", "/api/connectors/pair", body: Data(body.utf8))
            #expect(reply.status == 400 && reply.text.contains("pairing-upgrade"), "\(body) → \(reply.text)")
        }
        for commit in ["", "not-base64", Data(repeating: 1, count: 16).base64EncodedString()] {
            let reply = try await bench.send("POST", "/api/connectors/pair", body: Data(#"{"v":2,"commit":"\#(commit)"}"#.utf8))
            #expect(reply.status == 400, "\(commit) answered \(reply.status)")
        }
        #expect(bench.connectorPairing.pending == nil)
        #expect(bench.connectorPairing.offersLeft == LanConnectorPairing.maxOffers, "a refused ask uses no offer")
        var drawn = 0
        #expect(throws: LanConnectorPairing.Refusal.badCommit) {
            _ = try bench.connectorPairing.request(commitment: "short", name: "", app: "", version: "", address: "",
                                                   identity: .init(), freshKey: { drawn += 1; return .init() })
        }
        #expect(drawn == 0, "no key is drawn for a commitment that is not one")
    }

    @Test("one request at a time; Deny tells that plugin and keeps the window open for the real one")
    func busyThenDenied() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        bench.connectorPairing.open()
        let stranger = try await Self.askAndReveal(bench, Plugin())
        let (busy, _) = try await Self.ask(bench, Plugin())
        #expect(busy.status == 409 && busy.text.contains("pairing-busy"))

        bench.connectorPairing.deny()
        #expect(try await Self.poll(bench, stranger).text.contains("denied"))
        #expect(bench.connectorPairing.isOpenNow)

        let real = try await Self.askAndReveal(bench, Plugin())
        try Self.approve(bench)
        #expect(try await Self.poll(bench, real).text.contains("approved"))
        #expect(try await Self.poll(bench, stranger).text.contains("denied"), "the denied one stays denied")
        #expect(bench.devices.list().count == 1)
    }

    @Test("only the plugin that asked hears the answer, or may reveal")
    func pollNeedsItsSecret() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        bench.connectorPairing.open()
        let plugin = Plugin()
        let offer = try #require(try await Self.ask(bench, plugin).1)
        #expect(try await Self.reveal(bench, offer, plugin.revealBody(), secret: "wrong").status == 404)
        #expect(bench.connectorPairing.pending != nil, "a stranger's reveal does not spend the plugin's offer")
        #expect(try await Self.reveal(bench, offer, plugin.revealBody()).status == 200)
        #expect(try await Self.poll(bench, offer, secret: "wrong").status == 404)
        #expect(try await Self.poll(bench, offer, secret: "").status == 404)
        try Self.approve(bench)
        #expect(try await Self.poll(bench, offer, secret: "wrong").status == 404, "nor after it is answered")
        let unknown = try await bench.get("/api/connectors/pair/abcdefghijkl", headers: ["x-khayt-poll": offer.pollSecret])
        #expect(unknown.status == 404)
    }

    @Test("a request still waiting when the window runs out expires, and nothing is enrolled")
    func timesOut() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        bench.connectorPairing.open()
        let offer = try await Self.askAndReveal(bench, Plugin())
        bench.advance(seconds: LanConnectorPairing.length + 1)
        #expect(try await Self.poll(bench, offer).text.contains("expired"))
        #expect(bench.connectorPairing.lastClosed == .timedOut)
        try Self.approve(bench)
        #expect(bench.devices.list().isEmpty, "an approval after the window shut does nothing")
        let (late, _) = try await Self.ask(bench, Plugin())
        #expect(late.status == 403 && late.text.contains("pairing-closed"))
    }

    @Test("an oversized ask is answered 413 and closed cleanly, and holds no slot")
    func oversizedAsk() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        bench.connectorPairing.open()
        // Over a megabyte: refused from the head (not a large-body route), the
        // answer must reach the client rather than be lost to a reset (#2497).
        var body = Plugin().body()
        body.append(Data(repeating: 0x20, count: LanServer.maxBody + 1024))
        let reply = try await bench.send("POST", "/api/connectors/pair", body: body)
        #expect(reply.status == 413, "answered \(reply.status) \(reply.text)")
        #expect(bench.connectorPairing.pending == nil)
        #expect(bench.connectorPairing.isOpenNow, "the window stays open for a proper ask")
        #expect(try await Self.ask(bench, Plugin()).0.status == 200)
    }

    // MARK: - Grinding (why the commitment exists)

    /// A device in the middle steers the number it controls by grinding the
    /// device id it hands the plugin (any input it chooses would do; a string
    /// is cheapest). Played at modulus 100 so a blind guess hits 1 in 100.
    static func random32() -> String { Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString() }
    static func value(_ d: String, _ i: String, _ s: String, _ p: String, _ n: String, _ m: UInt32) -> UInt32 {
        LanConnectorPairing.checkValue(deviceId: d, identityPublic: i, serverPublic: s, pluginPublic: p, nonce: n) % m
    }
    static func grind(toward target: UInt32, _ i: String, _ s: String, _ p: String, _ n: String, _ m: UInt32) -> String? {
        for k in 0..<20 * Int(m) {
            let d = "dev_Grind\(k)"
            if value(d, i, s, p, n, m) == target { return d }
        }
        return nil
    }

    @Test("a device in the middle that sees everything on the wire hits the check no better than chance")
    func grindingDoesNotHelp() {
        let m: UInt32 = 100
        let (identity, attackerIdentity) = (Self.random32(), Self.random32())

        // Without a commitment (v1's order) every input is known before the
        // attacker picks its own, so grinding wins every time.
        var v1Hits = 0
        for _ in 0..<50 {
            let (pluginPub, nonce) = (Self.random32(), Self.random32())
            let macNumber = Self.value("dev_Mac", identity, Self.random32(), Self.random32(), Self.random32(), m)
            let s = Self.random32()
            if let d = Self.grind(toward: macNumber, attackerIdentity, s, pluginPub, nonce, m),
               Self.value(d, attackerIdentity, s, pluginPub, nonce, m) == macNumber { v1Hits += 1 }
        }
        #expect(v1Hits == 50, "the test can catch a grind: \(v1Hits)/50")

        // With it, in either order, one side's number is fixed by randomness
        // drawn after the attacker had to choose.
        let trials = 1000
        var pluginFirst = 0, macFirst = 0
        for _ in 0..<trials {
            // Mac first: the attacker commits to (m1, nM), the Mac then draws
            // a fresh key, so the Mac's number is known; the plugin's key and
            // nonce are only a hash when the attacker must send its offer.
            let macNumber = Self.value("dev_Mac", identity, Self.random32(), Self.random32(), Self.random32(), m)
            let (pluginPub, nonce) = (Self.random32(), Self.random32())
            let commit = LanConnectorPairing.commitment(pluginPublic: pluginPub, nonce: nonce).base64EncodedString()
            let s = Self.random32()
            let d = Self.grind(toward: macNumber, attackerIdentity, s, commit, "", m) ?? "dev_Guess"
            if Self.value(d, attackerIdentity, s, pluginPub, nonce, m) == macNumber { macFirst += 1 }

            // Plugin first: the attacker learns the plugin's key and nonce, so
            // the plugin's number is known; but it must commit to the Mac
            // before the Mac draws its fresh key.
            let pluginNumber = Self.value("dev_Attacker", attackerIdentity, s, pluginPub, nonce, m)
            let (m1, nM) = (Self.random32(), Self.random32())
            let freshMacKey = Self.random32()
            if Self.value("dev_Mac", identity, freshMacKey, m1, nM, m) == pluginNumber { pluginFirst += 1 }
        }
        // Chance is 1 in 100 (10 of 1,000); 3 in 100 is far outside it.
        #expect(macFirst < 30, "talking to the Mac first: \(macFirst)/\(trials)")
        #expect(pluginFirst < 30, "talking to the plugin first: \(pluginFirst)/\(trials)")
    }

    // MARK: - Units

    @Test("a PIN change signs a connector out, as it does a phone")
    func pinChangeSignsOut() throws {
        let devices = LanDevices.inMemory()
        let plugin = Curve25519.KeyAgreement.PrivateKey()
        let server = Curve25519.KeyAgreement.PrivateKey()
        let id = LanDevices.freshId()
        try devices.admitConnector(pluginPublic: plugin.publicKey.rawRepresentation.base64EncodedString(),
                                   serverKey: server, deviceId: id, name: "Orca", pin: Self.pin,
                                   now: LanServerTests.Bench.start)
        let key = try #require(LanDevices.derive(plugin, server.publicKey, deviceId: id))
        var signer = LanConnectorScopeTests.Signer(id: id, key: key)
        let now = LanServerTests.Bench.start
        let h = signer.headers("GET", "/api/connectors/queue", Data(), time: Int(now.timeIntervalSince1970))
        #expect(devices.verify(headers: h, method: "GET", target: "/api/connectors/queue", body: Data(),
                               pin: Self.pin, now: now) == .pass)
        let h2 = signer.headers("GET", "/api/connectors/queue", Data(), time: Int(now.timeIntervalSince1970))
        #expect(devices.verify(headers: h2, method: "GET", target: "/api/connectors/queue", body: Data(),
                               pin: "13571357", now: now) == .refused("device-unknown", now: nil))
    }

    @Test("names are trimmed, cut short and stripped of control characters")
    func fields() {
        #expect(LanConnectorPairing.field("  Orca\n\u{0007}Slicer  ") == "OrcaSlicer")
        #expect(LanConnectorPairing.field(String(repeating: "x", count: 200)).count == LanConnectorPairing.maxField)
        #expect(LanConnectorPairing.spaced("028159") == "028\u{2009}159")
        #expect(LanConnectorPairing.plausiblePairId("abcdefghij12"))
        #expect(!LanConnectorPairing.plausiblePairId("../store"))
        #expect(!LanConnectorPairing.plausiblePairId("ABCDEFGHIJ12"))
    }
}
