import Foundation
import Testing
import CryptoKit
@testable import KhaytApp

/// A slicer plugin pairs over the shop's network without the PIN: it asks
/// while the owner has clicked Pair a slicer, both screens show the same check
/// number, and the owner approves (`LanConnectorPairing`). Played here the way
/// the plugin plays it, over HTTP against a real server.
@MainActor
@Suite(.serialized)
struct LanConnectorPairingTests {

    static let pin = "24682468"

    /// The plugin's side: its key, and what it asks with.
    struct Plugin {
        let key = Curve25519.KeyAgreement.PrivateKey()
        var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
        func body(name: String = "OrcaSlicer on Studio iMac") -> Data {
            Data(#"{"publicKey":"\#(publicKey)","name":"\#(name)","app":"OrcaSlicer","version":"2.5.1"}"#.utf8)
        }
    }

    struct Offer: Decodable { let pairId, pollSecret, deviceId, publicKey, sig, identity: String }

    static func ask(_ bench: LanServerTests.Bench, _ plugin: Plugin) async throws -> (LanServerTests.Bench.Reply, Offer?) {
        let reply = try await bench.send("POST", "/api/connectors/pair", body: plugin.body())
        return (reply, try? JSONDecoder().decode(Offer.self, from: reply.body))
    }

    static func poll(_ bench: LanServerTests.Bench, _ offer: Offer, secret: String? = nil) async throws -> LanServerTests.Bench.Reply {
        try await bench.get("/api/connectors/pair/\(offer.pairId)", headers: ["x-khayt-poll": secret ?? offer.pollSecret])
    }

    static func approve(_ bench: LanServerTests.Bench) throws {
        try bench.connectorPairing.approve { asked in
            try bench.devices.admitConnector(pluginPublic: asked.pluginPublic, serverKey: asked.serverKey,
                                             deviceId: asked.deviceId, name: asked.name, pin: pin,
                                             now: LanServerTests.Bench.start)
        }
    }

    // MARK: - The check number

    struct Vectors: Decodable {
        struct Case: Decodable {
            let name, identitySeedHex, serverPrivateHex, pluginPrivateHex, deviceId: String
            let identityPublic, serverPublic, pluginPublic, check: String
        }
        let cases: [Case]
    }

    static func hex(_ s: String) -> Data {
        Data(stride(from: 0, to: s.count, by: 2).map { i in
            UInt8(s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: i + 2)], radix: 16)!
        })
    }

    @Test("the check number matches the shared vectors the plugin is tested against")
    func checkVectors() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/connector-pair.vectors.json")
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        #expect(vectors.cases.count >= 4)
        #expect(vectors.cases.contains { $0.check.hasPrefix("0") }, "a check with a leading zero keeps it")
        for c in vectors.cases {
            let identity = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.hex(c.identitySeedHex))
            #expect(identity.publicKey.rawRepresentation.base64EncodedString() == c.identityPublic, "\(c.name)")
            let server = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.hex(c.serverPrivateHex))
            let plugin = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.hex(c.pluginPrivateHex))
            #expect(server.publicKey.rawRepresentation.base64EncodedString() == c.serverPublic, "\(c.name)")
            #expect(plugin.publicKey.rawRepresentation.base64EncodedString() == c.pluginPublic, "\(c.name)")
            #expect(LanConnectorPairing.check(deviceId: c.deviceId, identityPublic: c.identityPublic,
                                              serverPublic: c.serverPublic, pluginPublic: c.pluginPublic) == c.check,
                    "\(c.name)")
        }
        let checks = Set(vectors.cases.map(\.check))
        #expect(checks.count == vectors.cases.count, "the id, the identity and the order of the keys change the number")
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

    @Test("asked, checked on both screens, approved: the plugin's key opens its own routes and not the book")
    func approvedPairing() async throws {
        let identity = Curve25519.Signing.PrivateKey()
        let bench = try await LanServerTests.Bench(pin: Self.pin, identity: identity)
        defer { bench.stop() }
        bench.connectorPairing.open()
        let plugin = Plugin()
        let (reply, maybe) = try await Self.ask(bench, plugin)
        #expect(reply.status == 200, "\(reply.text)")
        let offer = try #require(maybe)

        // The plugin checks the Mac's X25519 key against the identity key it
        // was handed, then works out the number over all three.
        #expect(offer.identity == identity.publicKey.rawRepresentation.base64EncodedString())
        let macIdentity = try Curve25519.Signing.PublicKey(
            rawRepresentation: try #require(Data(base64Encoded: offer.identity)))
        let sig = try #require(Data(base64Encoded: offer.sig))
        #expect(macIdentity.isValidSignature(sig, for: LanDevices.enrolMessage(
            deviceId: offer.deviceId, serverPublic: offer.publicKey, phonePublic: plugin.publicKey)))
        let pending = try #require(bench.connectorPairing.pending)
        #expect(LanConnectorPairing.check(deviceId: offer.deviceId, identityPublic: offer.identity,
                                          serverPublic: offer.publicKey, pluginPublic: plugin.publicKey) == pending.check)
        #expect(pending.name == "OrcaSlicer on Studio iMac" && pending.app == "OrcaSlicer" && pending.version == "2.5.1")

        // Nothing is enrolled while the owner looks.
        #expect(bench.devices.list().isEmpty)
        #expect(try await Self.poll(bench, offer).text.contains("waiting"))

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

    @Test("one request at a time; Deny tells that plugin and keeps the window open for the real one")
    func busyThenDenied() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        bench.connectorPairing.open()
        let (_, first) = try await Self.ask(bench, Plugin())
        let stranger = try #require(first)
        let (busy, _) = try await Self.ask(bench, Plugin())
        #expect(busy.status == 409 && busy.text.contains("pairing-busy"))

        bench.connectorPairing.deny()
        #expect(try await Self.poll(bench, stranger).text.contains("denied"))
        #expect(bench.connectorPairing.isOpenNow)

        let (again, second) = try await Self.ask(bench, Plugin())
        #expect(again.status == 200)
        let real = try #require(second)
        try Self.approve(bench)
        #expect(try await Self.poll(bench, real).text.contains("approved"))
        #expect(try await Self.poll(bench, stranger).text.contains("denied"), "the denied one stays denied")
        #expect(bench.devices.list().count == 1)
    }

    @Test("only the plugin that asked hears the answer")
    func pollNeedsItsSecret() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        bench.connectorPairing.open()
        let offer = try #require(try await Self.ask(bench, Plugin()).1)
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
        let offer = try #require(try await Self.ask(bench, Plugin()).1)
        bench.advance(seconds: LanConnectorPairing.length + 1)
        #expect(try await Self.poll(bench, offer).text.contains("expired"))
        #expect(bench.connectorPairing.lastClosed == .timedOut)
        try Self.approve(bench)
        #expect(bench.devices.list().isEmpty, "an approval after the window shut does nothing")
        let (late, _) = try await Self.ask(bench, Plugin())
        #expect(late.status == 403 && late.text.contains("pairing-closed"))
    }

    @Test("a key that is not a usable X25519 key is refused, and does not hold the slot")
    func badKey() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        bench.connectorPairing.open()
        let zero = Data(repeating: 0, count: 32).base64EncodedString()
        for key in ["", "not-base64", Data(repeating: 1, count: 16).base64EncodedString(), zero] {
            let reply = try await bench.send("POST", "/api/connectors/pair", body: Data(#"{"publicKey":"\#(key)"}"#.utf8))
            #expect(reply.status == 400, "\(key) answered \(reply.status)")
        }
        #expect(bench.connectorPairing.pending == nil)
        #expect(try await Self.ask(bench, Plugin()).0.status == 200)
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
