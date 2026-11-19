import Foundation
import Testing
import CryptoKit
import KhaytCore
@testable import KhaytApp

/// The queue a paired slicer plugin's Khayt tab reads (`GET /api/connectors/queue`):
/// the shared rule (`lib/connector-queue.js`) run by the engine through the
/// real route, sealed to the plugin's key, signed back, with an ETag. Turki's
/// rule: the tab NEVER shows customer data — and a job's title can hold a
/// client's name, so no title leaves either.
@MainActor
@Suite(.serialized)
struct LanConnectorQueueTests {

    static let path = "/api/connectors/queue"
    typealias R = LanConnectorRoutesTests

    static func queue(_ bench: LanServerTests.Bench, _ peer: R.Peer, ifNoneMatch: String? = nil)
        async throws -> (LanServerTests.Bench.Reply, [String: Any]?, String) {
        var headers = peer.headers("GET", path)
        if let ifNoneMatch { headers["If-None-Match"] = ifNoneMatch }
        let reply = try await bench.send("GET", path, headers: headers, timeout: 30)
        let nonce = headers["x-khayt-nonce"] ?? ""
        guard reply.status == 200 else { return (reply, nil, nonce) }
        let key = LanServer.sealKey(peer.key, connectorId: peer.id)
        let plain = try #require(LanServer.unseal(reply.body, key: key, aad: LanServer.sealAad(method: "GET", path: path)))
        return (reply, try JSONSerialization.jsonObject(with: plain) as? [String: Any], nonce)
    }

    /// Every customer-ish string the sample book holds, from the jobs and the clients.
    static func secrets(_ bench: LanServerTests.Bench) -> [String] {
        var out = Set(bench.shop.customers.map(\.name))
        if case .array(let log)? = bench.book.value["printLog"] {
            for case .object(let o) in log {
                for key in ["clientName", "clientPhone", "clientEmail", "title", "project", "notes",
                            "internalNotes", "shippingAddress", "trackingUrl", "portalToken"] {
                    if case .string(let s)? = o[key] { out.insert(s) }
                }
            }
        }
        return out.filter { $0.count >= 4 }.sorted()
    }

    @Test("the queue is sealed to the plugin's key and its route, signed back, and carries no customer data")
    func sealedAndRedacted() async throws {
        let (bench, root) = try await R.bench()
        defer { bench.stop(); try? FileManager.default.removeItem(at: root) }
        let peer = try R.enrol(bench)
        // A job named after its client, sent by this plugin: the title stays home, the file name goes.
        let client = bench.shop.customers.first?.name ?? "Sample Client"
        bench.book.put(["id": .string("J-9001-zz99"), "jobNumber": .string("J-9001"), "status": .string("pending"),
                        "title": .string("Keychains for \(client)"), "clientName": .string(client),
                        "clientPhone": .string("+966500000009"), "price": .number(4321.5),
                        "fromSlicer": .object(["connectorId": .string(peer.id), "name": .string("Keychain_PLA.gcode")])])

        let (reply, snap, nonce) = try await Self.queue(bench, peer)
        #expect(reply.status == 200, "\(reply.text)")
        #expect(R.signedBy(reply, peer, nonce: nonce))
        #expect(reply.headers["etag"] != nil)
        #expect(!reply.text.contains("J-9001"), "sealed: nothing readable on the Wi-Fi")
        let s = try #require(snap)
        let jobs = try #require(s["jobs"] as? [[String: Any]])
        #expect(!jobs.isEmpty, "the sample book's open jobs are in the queue")
        for job in jobs { #expect(Set(job.keys) == ["id", "number", "stage", "machine", "file"], "\(job.keys)") }
        let mine = try #require(jobs.first { $0["id"] as? String == "J-9001-zz99" })
        #expect(mine["number"] as? String == "J-9001")
        #expect(mine["file"] as? String == "Keychain_PLA.gcode")
        #expect(Set(s.keys).isSubset(of: ["v", "at", "shop", "jobs", "machines", "inbox", "more"]))

        let text = String(decoding: try JSONSerialization.data(withJSONObject: s), as: UTF8.self)
        let numbers = Set(jobs.compactMap { $0["number"] as? String } + jobs.compactMap { $0["id"] as? String })
        for secret in Self.secrets(bench) + [client, "+966500000009", "4321.5"] where !numbers.contains(secret) {
            #expect(!text.contains(secret), "leaked: \(secret)")
        }

        // Another plugin sees the same jobs, but not this plugin's file name.
        let other = try R.enrol(bench, name: "Plugin B")
        let (_, theirs, _) = try await Self.queue(bench, other)
        let seen = try #require((theirs?["jobs"] as? [[String: Any]])?.first { $0["id"] as? String == "J-9001-zz99" })
        #expect(seen["file"] is NSNull)

        // Opened against another route, the same bytes do not open.
        #expect(LanServer.unseal(reply.body, key: LanServer.sealKey(peer.key, connectorId: peer.id),
                                 aad: LanServer.sealAad(method: "GET", path: "/api/connectors/self")) == nil)
        #expect(LanServer.unseal(reply.body, key: LanServer.sealKey(other.key, connectorId: other.id),
                                 aad: LanServer.sealAad(method: "GET", path: Self.path)) == nil)
    }

    @Test("an unchanged queue is a signed 304; a change is a new ETag; one ask per ten seconds")
    func etagAndRate() async throws {
        let (bench, root) = try await R.bench()
        defer { bench.stop(); try? FileManager.default.removeItem(at: root) }
        let peer = try R.enrol(bench)
        let (first, _, _) = try await Self.queue(bench, peer)
        let etag = try #require(first.headers["etag"])
        let (soon, _, _) = try await Self.queue(bench, peer, ifNoneMatch: etag)
        #expect(soon.status == 429, "\(soon.text)")
        #expect(Int(soon.headers["retry-after"] ?? "") ?? 0 > 0)

        bench.advance(seconds: 11)   // inside the device check's two minutes
        let (same, _, nonce) = try await Self.queue(bench, peer, ifNoneMatch: etag)
        #expect(same.status == 304, "the time moved, the queue did not")
        #expect(same.body.isEmpty)
        #expect(R.signedBy(same, peer, nonce: nonce))

        bench.advance(seconds: 11)
        bench.book.put(["id": .string("J-9002-yy88"), "status": .string("pending")])
        let (changed, snap, _) = try await Self.queue(bench, peer, ifNoneMatch: etag)
        #expect(changed.status == 200)
        #expect(changed.headers["etag"] != etag)
        #expect((snap?["jobs"] as? [[String: Any]])?.contains { $0["id"] as? String == "J-9002-yy88" } == true)
    }

    @Test("the ETag is keyed: no plain hash of the queue in the clear, none shared between plugins")
    func etagIsKeyed() {
        let content = #"{"v":1,"jobs":[{"number":"J-1001","stage":"printing"}]}"#
        let k1 = Data(repeating: 1, count: 32), k2 = Data(repeating: 2, count: 32)
        let a = LanServer.queueEtag(content, key: k1, connectorId: "dev_SampleStudioPC0001")
        #expect(a == LanServer.queueEtag(content, key: k1, connectorId: "dev_SampleStudioPC0001"), "stable for one plugin")
        #expect(a.count == 34 && a.hasPrefix("\"") && a.hasSuffix("\""))
        let plain = "\"" + String(LanServer.hex(SHA256.hash(data: Data(content.utf8))).prefix(32)) + "\""
        #expect(a != plain, "a plain SHA-256 lets an eavesdropper confirm a guessed queue")
        #expect(a != LanServer.queueEtag(content, key: k2, connectorId: "dev_SampleStudioPC0001"), "another key")
        #expect(a != LanServer.queueEtag(content, key: k1, connectorId: "dev_SampleStudioPC0002"), "another plugin")
        #expect(a != LanServer.queueEtag(content + " ", key: k1, connectorId: "dev_SampleStudioPC0001"), "another queue")
    }

    @Test("dark while off, and only a connector may ask")
    func gate() async throws {
        let (off, offRoot) = try await R.bench(enabled: false)
        defer { off.stop(); try? FileManager.default.removeItem(at: offRoot) }
        #expect(try await Self.queue(off, try R.enrol(off)).0.status == 404)

        let (bench, root) = try await R.bench()
        defer { bench.stop(); try? FileManager.default.removeItem(at: root) }
        let phone = try R.enrol(bench, kind: nil, name: "Bench phone")
        let asPhone = try await R.call(bench, phone, "GET", Self.path)
        #expect(asPhone.status == 403 && asPhone.text.contains("connector-only"))
        #expect(try await bench.send("GET", Self.path).status == 401)
        #expect(try await bench.send("GET", Self.path, headers: ["x-khayt-pin": R.pin]).status == 403)
        #expect(try await R.call(bench, try R.enrol(bench), "POST", Self.path, body: Data("{}".utf8)).status == 405)
    }
}
