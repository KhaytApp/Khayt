import Foundation
import Testing
@testable import KhaytApp
@testable import KhaytCore

/// Publishing the printers to Khayt Cloud (`PUT /live/printers`), as its
/// contract (`docs/api-contract.md`, "Live channel & live printers") says.
struct LivePrintersTests {
    static let dek = Data(repeating: 7, count: 32)
    static func row(_ id: String, progress: Double = 42, at: String = "2026-09-25T10:15:02.000Z",
                    filename: String = "bracket.3mf") -> JSONValue {
        .object(["id": .string(id), "name": .string(id), "hasPrinterApi": .bool(true), "apiType": .string("bambu"),
                 "state": .string("Printing"), "progress": .number(progress), "filename": .string(filename),
                 "timeRemaining": .number(3600), "tempNozzle": .number(220), "tempBed": .number(60),
                 "error": .null, "lastUpdated": .string(at)])
    }

    @Test("the plaintext is { v: 1, at, printers } with lastUpdated in epoch MILLISECONDS")
    func plaintext() {
        let snap = LivePrinters.snapshot(rows: [Self.row("m1")], at: "2026-09-25T10:15:02Z")
        #expect(snap["v"] == .number(1) && snap["at"] == .string("2026-09-25T10:15:02Z"))
        guard case .array(let rows)? = snap["printers"], case .object(let o) = rows[0] else { Issue.record("shape"); return }
        #expect(o["lastUpdated"] == .number(1_790_331_302_000))
        #expect(o["progress"] == .number(42) && o["state"] == .string("Printing"))
    }

    @Test("the body is { ciphertext: <envelope>, at }, and the shop's key opens it")
    func sealed() throws {
        let body = try #require(try LivePrinters.body(rows: [Self.row("m1")], at: "2026-09-25T10:15:02.000Z", dek: Self.dek))
        let outer = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(outer["at"] as? String == "2026-09-25T10:15:02.000Z")
        let envelope = try #require(outer["ciphertext"] as? [String: Any])
        #expect(envelope["z"] as? String == "gzip" && envelope["iv"] is String && envelope["tag"] is String,
                "the store's envelope, as an object — not a string of it")
        let blob = try JSONDecoder().decode(SyncCrypto.Blob.self,
                                            from: JSONSerialization.data(withJSONObject: envelope))
        let plain = try SyncCrypto.store(blob, dek: Self.dek)
        #expect(plain["v"] == .number(1))
    }

    @Test("over 64 KB, filename and error go before any printer")
    func trimmed() throws {
        // Filenames of incompressible noise so gzip cannot hide the size.
        var rng = SystemRandomNumberGenerator()
        let noise = { (0..<6000).map { _ in String(UInt8.random(in: 0...255, using: &rng), radix: 16) }.joined() }
        let rows = (0..<12).map { Self.row("m\($0)", filename: noise()) }
        let body = try #require(try LivePrinters.body(rows: rows, at: "2026-09-25T10:15:02Z", dek: Self.dek))
        let outer = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let blob = try JSONDecoder().decode(SyncCrypto.Blob.self,
                                            from: JSONSerialization.data(withJSONObject: outer["ciphertext"]!))
        let plain = try SyncCrypto.store(blob, dek: Self.dek)
        guard case .array(let printers)? = plain["printers"] else { Issue.record("no printers"); return }
        #expect(printers.count == 12, "every printer kept")
        #expect(printers.allSatisfy { if case .object(let o) = $0 { o["filename"] == .null } else { false } })
    }

    @Test("sent on a change after 2 s, otherwise only as a 30–60 s heartbeat, never before a 429 allows")
    func timing() {
        let t0 = Date()
        #expect(LivePrinters.due(changed: true, now: t0, lastSent: nil, notBefore: nil))
        #expect(!LivePrinters.due(changed: true, now: t0.addingTimeInterval(1), lastSent: t0, notBefore: nil))
        #expect(LivePrinters.due(changed: true, now: t0.addingTimeInterval(2), lastSent: t0, notBefore: nil))
        #expect(!LivePrinters.due(changed: false, now: t0.addingTimeInterval(30), lastSent: t0, notBefore: nil))
        #expect(LivePrinters.due(changed: false, now: t0.addingTimeInterval(45), lastSent: t0, notBefore: nil))
        #expect(!LivePrinters.due(changed: true, now: t0.addingTimeInterval(5), lastSent: t0,
                                  notBefore: t0.addingTimeInterval(10)))
        // lastUpdated moving is not a change a person could see.
        #expect(LivePrinters.signature([Self.row("m1", at: "2026-09-25T10:15:02Z")])
                == LivePrinters.signature([Self.row("m1", at: "2026-09-25T10:15:09Z")]))
        #expect(LivePrinters.signature([Self.row("m1", progress: 42)]) != LivePrinters.signature([Self.row("m1", progress: 43)]))
    }

    @Test("the publisher: PUT once, quiet while nothing changes, stops for good on a 403")
    @MainActor
    func publisher() async {
        let p = LivePrinterPublisher()
        var calls: [(String, String)] = []
        var status = 200
        p.fetch = { r in
            calls.append((r.httpMethod ?? "", r.url?.path ?? ""))
            return (Data("{\"ok\":true}".utf8), HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let conn = CloudReader.Connection(url: "https://cloud.example", shopId: "shop_1", storedToken: "x")
        let rows = [Self.row("m1")]
        await p.publishIfDue(rows: rows, connection: conn, dek: Self.dek, canWrite: true, token: { "t" })
        #expect(calls.count == 1 && calls[0].0 == "PUT" && calls[0].1 == "/v1/shops/shop_1/live/printers")
        await p.publishIfDue(rows: rows, connection: conn, dek: Self.dek, canWrite: true, token: { "t" })
        #expect(calls.count == 1, "nothing changed and no heartbeat due")
        await p.publishIfDue(rows: rows, connection: conn, dek: nil, canWrite: true, token: { "t" })
        await p.publishIfDue(rows: rows, connection: conn, dek: Self.dek, canWrite: false, token: { "t" })
        #expect(calls.count == 1, "locked, or a viewer: never")

        let q = LivePrinterPublisher()
        status = 403
        q.fetch = p.fetch
        await q.publishIfDue(rows: rows, connection: conn, dek: Self.dek, canWrite: true, token: { "t" })
        await q.publishIfDue(rows: [Self.row("m1", progress: 99)], connection: conn, dek: Self.dek, canWrite: true, token: { "t" })
        #expect(calls.count == 2, "a 403 is not asked again every sweep")
    }
}
