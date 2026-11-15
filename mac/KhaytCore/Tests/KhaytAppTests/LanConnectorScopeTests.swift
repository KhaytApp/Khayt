import Foundation
import Testing
import CryptoKit
@testable import KhaytApp

/// A connector (the Khayt for OrcaSlicer plugin) signs like a phone but opens
/// `/api/connectors/*` only. A phone's key opens whatever the PIN opens, the
/// whole book included; a key that lives inside somebody's slicer must not.
/// Every route the server knows is asked, read out of `LanServer.swift` itself,
/// so a route added later is covered without anyone remembering this file.
@MainActor
@Suite(.serialized)
struct LanConnectorScopeTests {

    static let pin = "24682468"

    /// A device enrolled straight into the bench's store, and a signer for it.
    struct Signer {
        let id: String
        let key: Data
        var count = 0
        mutating func headers(_ method: String, _ target: String, _ body: Data, time: Int) -> [String: String] {
            count += 1
            let nonce = String(format: "%032x", count)
            let canonical = LanDevices.canonical(method: method, target: target, time: String(time),
                                                 nonce: nonce, body: body)
            return ["x-khayt-device": id, "x-khayt-time": String(time), "x-khayt-nonce": nonce,
                    "x-khayt-mac": LanDevices.mac(key: key, canonical: canonical).base64EncodedString()]
        }
    }

    static func enrol(_ devices: LanDevices, kind: String?, name: String) throws -> Signer {
        let mine = Curve25519.KeyAgreement.PrivateKey()
        let server = Curve25519.KeyAgreement.PrivateKey()
        let enrolled = try devices.enrol(phonePublic: mine.publicKey.rawRepresentation.base64EncodedString(),
                                         name: name, pin: pin, identity: .init(),
                                         now: LanServerTests.Bench.start, serverKey: server, kind: kind)
        let key = try #require(LanDevices.derive(mine, server.publicKey, deviceId: enrolled.deviceId))
        return Signer(id: enrolled.deviceId, key: key)
    }

    /// Every literal route in the server's switch, plus the REST surface
    /// (`LanServer+Rest`) and the `/v1` spelling of the book.
    static func everyRoute() throws -> [(method: String, path: String)] {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/KhaytApp/LanServer.swift"), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"case \("(/[^"]*)", (true|false)\)"#)
        var routes: [(String, String)] = []
        for m in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let path = String(source[Range(m.range(at: 1), in: source)!])
            let get = source[Range(m.range(at: 2), in: source)!] == "true"
            routes.append((get ? "GET" : "POST", path))
        }
        #expect(routes.count >= 20, "the route list was read out of LanServer.swift")
        #expect(routes.contains { $0.1 == "/api/store" })
        let rest = ["/api/orders", "/api/orders/o_1", "/api/inventory", "/api/clients", "/api/waiting-list",
                    "/api/waste", "/api/machines", "/api/quote", "/api/expense", "/api/orders/o_1/photos",
                    "/api/printers/m_1/pause", "/v1/store", "/v1/queue", "/api/library", "/",
                    "/api/files/local", "/v1/files/local", "/api/version"]
        for path in rest {
            routes.append(("GET", path))
            routes.append(("POST", path))
        }
        routes.append(("PATCH", "/api/orders/o_1"))
        routes.append(("DELETE", "/api/orders/o_1"))
        return routes.filter { !$0.1.hasPrefix(LanDevices.connectorPrefix) }
    }

    @Test("a connector's key is refused on every route outside /api/connectors, the book first")
    func connectorIsRefusedEverywhereElse() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        var connector = try Self.enrol(bench.devices, kind: LanDevices.kindConnector, name: "OrcaSlicer on the PC")
        var phone = try Self.enrol(bench.devices, kind: nil, name: "Bench phone")
        let now = Int(LanServerTests.Bench.start.timeIntervalSince1970)

        // The control: the same signing, by a phone, opens the book.
        let book = try await bench.get("/api/store", headers: phone.headers("GET", "/api/store", Data(), time: now))
        #expect(book.status == 200, "a phone's signature opens the book (got \(book.status))")

        let refusedBook = try await bench.get("/api/store",
                                              headers: connector.headers("GET", "/api/store", Data(), time: now))
        #expect(refusedBook.status == 403 && refusedBook.text.contains("connector-scope"))
        #expect(!refusedBook.text.contains("orders"), "nothing of the book comes back")

        for (method, path) in try Self.everyRoute() {
            let body = method == "GET" || method == "DELETE" ? Data() : Data(#"{"x":1}"#.utf8)
            let headers = connector.headers(method, path, body, time: now)
            let reply = method == "GET" ? try await bench.get(path, headers: headers)
                                        : try await bench.send(method, path, body: body, headers: headers)
            #expect(reply.status == 403 && reply.text.contains("connector-scope"),
                    "\(method) \(path) answered \(reply.status) to a connector")
        }
    }

    @Test("its key with the owner PIN beside it is still a connector")
    func pinBesideItChangesNothing() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        var connector = try Self.enrol(bench.devices, kind: LanDevices.kindConnector, name: "Orca")
        var headers = connector.headers("GET", "/api/store", Data(), time: Int(LanServerTests.Bench.start.timeIntervalSince1970))
        headers["x-khayt-pin"] = Self.pin
        let reply = try await bench.get("/api/store", headers: headers)
        #expect(reply.status == 403 && reply.text.contains("connector-scope"))
        let dotted = try await bench.get("/api/connectors/../store", headers: headers)
        #expect(dotted.status != 200, "a dotted path does not climb out of /api/connectors")
        let encoded = try await bench.get("/api/connectors/%2e%2e/store", headers: headers)
        #expect(encoded.status != 200, "nor an encoded one")
        // Unsigned but naming a connector: refused all the same (fail closed).
        let bare = try await bench.get("/api/store", headers: ["x-khayt-device": connector.id, "x-khayt-pin": Self.pin])
        #expect(bare.status == 403 && bare.text.contains("connector-scope"))
    }

    @Test("a large upload is refused from its head, before the body is read")
    func largeUploadHead() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        var connector = try Self.enrol(bench.devices, kind: LanDevices.kindConnector, name: "Orca")
        let body = Data(repeating: 0x41, count: LanServer.maxBody + 1024)
        for path in ["/api/expense", "/api/orders/o_1/photos"] {
            let headers = connector.headers("POST", path, body, time: Int(LanServerTests.Bench.start.timeIntervalSince1970))
            let reply = try await bench.send("POST", path, body: body, headers: headers, timeout: 300)
            #expect(reply.status == 403 && reply.text.contains("connector-scope"), "\(path) answered \(reply.status)")
        }
    }

    /// The answer to a request refused from its head has to REACH the client.
    ///
    /// The server answered at once and closed with the body still arriving;
    /// the kernel met the unread bytes with a reset, and the reset could
    /// destroy the answer first. Measured before the fix: 6 of 40 URLSession
    /// uploads got -1005 instead of the 403, and on CI the same race was a
    /// 15-minute -1001 in `largeUploadHead` (3 of 5 main runs after #2484).
    /// The server now closes its side and drains (`LanServer.linger`).
    ///
    /// 300 s per request, not the session's 900: a loaded CI shard can keep a
    /// request waiting minutes for the main actor (`LanServerTests.session`),
    /// so seconds would fail a healthy server, but a hang now ends a run in
    /// five minutes instead of fifteen. The 40 outcomes are the real check.
    @Test("a refused oversized upload gets its answer every time, never a reset")
    func refusalSurvivesTheBodyStillArriving() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        let connector = try Self.enrol(bench.devices, kind: LanDevices.kindConnector, name: "Orca")
        let body = Data(repeating: 0x41, count: LanServer.maxBody + 1024)
        var outcomes: [String: Int] = [:]
        for _ in 0..<40 {
            do {
                let reply = try await bench.send("POST", "/api/expense", body: body,
                                                 headers: ["x-khayt-device": connector.id, "x-khayt-pin": Self.pin],
                                                 timeout: 300)
                outcomes["\(reply.status)", default: 0] += 1
            } catch let error as URLError {
                outcomes["URLError \(error.code.rawValue)", default: 0] += 1
            }
        }
        #expect(outcomes == ["403": 40], "\(outcomes)")
    }

    @Test("every refusal decided from the head lingers before the connection closes")
    func everyHeadRefusalLingers() {
        let server = EmptyStateTests.source("LanServer.swift")
        let catches = server.components(separatedBy: "\n        } catch ").dropFirst()
            .filter { $0.hasPrefix("ReadRefusal.") || $0.hasPrefix("let error as URLError where error.code == .dataLengthExceedsMaximum") }
        #expect(catches.count == 5)
        for branch in catches {
            #expect(branch.contains("await Self.linger(connection, on: queue)"), "\(branch.prefix(60))")
        }
    }

    @Test("its own routes are not refused for scope (none exist yet, so they are not found)")
    func ownRoutesPassTheScope() async throws {
        let bench = try await LanServerTests.Bench(pin: Self.pin)
        defer { bench.stop() }
        var connector = try Self.enrol(bench.devices, kind: LanDevices.kindConnector, name: "Orca")
        let now = Int(LanServerTests.Bench.start.timeIntervalSince1970)
        for path in ["/api/connectors/queue", "/v1/connectors/queue"] {
            let reply = try await bench.get(path, headers: connector.headers("GET", path, Data(), time: now))
            #expect(!reply.text.contains("connector-scope"), "\(path) answered \(reply.status) \(reply.text)")
        }
    }

    @Test("a full store makes room within a kind: a connector never unpairs a phone")
    func evictionStaysWithinAKind() throws {
        let devices = LanDevices.inMemory()
        var phones: [Signer] = []
        for i in 0..<LanDevices.maxDevices { phones.append(try Self.enrol(devices, kind: nil, name: "Phone \(i)")) }
        let connector = try Self.enrol(devices, kind: LanDevices.kindConnector, name: "Orca")
        let now = LanServerTests.Bench.start
        for var phone in phones {
            let h = phone.headers("GET", "/api/store", Data(), time: Int(now.timeIntervalSince1970))
            #expect(devices.verify(headers: h, method: "GET", target: "/api/store", body: Data(),
                                   pin: Self.pin, now: now) == .pass, "\(phone.id) still verifies")
        }
        #expect(devices.kind(of: connector.id) == LanDevices.kindConnector)
        // And the other way: a 33rd phone pushes out a phone, not the connector.
        _ = try Self.enrol(devices, kind: nil, name: "Phone 33")
        #expect(devices.kind(of: connector.id) == LanDevices.kindConnector)
        #expect(devices.list().filter { $0.kind == nil }.count == LanDevices.maxDevices)
    }

    @Test("kinds: a phone saved before kinds existed is a phone; an unknown kind fails closed; Paired phones lists phones only")
    func kinds() throws {
        let old = #"{"salt":"AAAA","devices":[{"id":"dev_oldPhone000001","name":"Old","key":"AAAA","pinTag":"AAAA","createdAt":0,"lastSeenAt":0}]}"#
        let store = LanDevices(loaded: Data(old.utf8), persist: nil)
        #expect(store.count == 1)
        #expect(store.kind(of: "dev_oldPhone000001") == nil)
        #expect(!LanDevices.isRestricted(kind: nil))
        #expect(LanDevices.isRestricted(kind: LanDevices.kindConnector))
        #expect(LanDevices.isRestricted(kind: "something-newer"))

        let devices = LanDevices.inMemory()
        _ = try Self.enrol(devices, kind: nil, name: "Phone")
        _ = try Self.enrol(devices, kind: LanDevices.kindConnector, name: "Orca")
        #expect(devices.list().count == 2)
        #expect(devices.list().filter { $0.kind == nil }.map(\.name) == ["Phone"])
    }
}
