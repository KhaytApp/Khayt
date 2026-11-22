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
    static let engine = OperatorLockTests.sharedEngine
    /// A row whose printer answered at `ok`.
    static func answered(_ id: String, _ ok: Date, progress: Double = 42) -> JSONValue {
        guard case .object(var o) = row(id, progress: progress, at: StoreWriter.iso(ok)) else { return .null }
        o["lastOkAt"] = .string(StoreWriter.iso(ok))
        return .object(o)
    }
    /// A row whose printer has not answered since `ok` (nil: never).
    static func silent(_ id: String, since ok: Date?, asked: Date) -> JSONValue {
        guard case .object(var o) = row(id, at: StoreWriter.iso(asked)) else { return .null }
        o["state"] = .null; o["progress"] = .null
        o["error"] = .string("No answer"); o["errorCode"] = .string("unreachable")
        o["lastOkAt"] = ok.map { .string(StoreWriter.iso($0)) } ?? .null
        return .object(o)
    }

    @Test("the plaintext is { v: 1, at, printers } with both stamps in epoch MILLISECONDS, by the shared rule")
    func plaintext() async throws {
        let ok = Date(timeIntervalSince1970: 1_790_331_302)
        let snaps = try await Self.engine.liveSnapshots(rows: [Self.answered("m1", ok)], at: "2026-09-25T10:15:02Z")
        #expect(snaps.count == 2, "whole, then without filename and error")
        let snap = snaps[0]
        #expect(snap["v"] == .number(1) && snap["at"] == .string("2026-09-25T10:15:02Z"))
        guard case .array(let rows)? = snap["printers"], case .object(let o) = rows[0] else { Issue.record("shape"); return }
        #expect(o["lastUpdated"] == .number(1_790_331_302_000))
        #expect(o["lastOkAt"] == .number(1_790_331_302_000), "one ISO string beside one number emptied a phone's list once")
        #expect(o["progress"] == .number(42) && o["state"] == .string("Printing") && o["filename"] == .string("bracket.3mf"))
        guard case .array(let slim)? = snaps[1]["printers"], case .object(let s) = slim[0] else { Issue.record("shape"); return }
        #expect(s["filename"] == .null && s["error"] == .null && s["progress"] == .number(42))
    }

    @Test("the body is { ciphertext: <envelope>, at }, and the shop's key opens it")
    func sealed() async throws {
        let plain = try await Self.engine.liveSnapshots(rows: [Self.row("m1")], at: "2026-09-25T10:15:02.000Z")
        let body = try #require(try LivePrinters.body(plaintexts: plain, at: "2026-09-25T10:15:02.000Z", dek: Self.dek))
        let outer = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(outer["at"] as? String == "2026-09-25T10:15:02.000Z")
        let envelope = try #require(outer["ciphertext"] as? [String: Any])
        #expect(envelope["z"] as? String == "gzip" && envelope["iv"] is String && envelope["tag"] is String,
                "the store's envelope, as an object — not a string of it")
        let blob = try JSONDecoder().decode(SyncCrypto.Blob.self,
                                            from: JSONSerialization.data(withJSONObject: envelope))
        let opened = try SyncCrypto.store(blob, dek: Self.dek)
        #expect(opened["v"] == .number(1))
    }

    @Test("over 64 KB, filename and error go before any printer")
    func trimmed() async throws {
        // Filenames of incompressible noise so gzip cannot hide the size.
        var rng = SystemRandomNumberGenerator()
        let noise = { (0..<6000).map { _ in String(UInt8.random(in: 0...255, using: &rng), radix: 16) }.joined() }
        let rows = (0..<12).map { Self.row("m\($0)", filename: noise()) }
        let plain = try await Self.engine.liveSnapshots(rows: rows, at: "2026-09-25T10:15:02Z")
        let body = try #require(try LivePrinters.body(plaintexts: plain, at: "2026-09-25T10:15:02Z", dek: Self.dek))
        let outer = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let blob = try JSONDecoder().decode(SyncCrypto.Blob.self,
                                            from: JSONSerialization.data(withJSONObject: outer["ciphertext"]!))
        let opened = try SyncCrypto.store(blob, dek: Self.dek)
        guard case .array(let printers)? = opened["printers"] else { Issue.record("no printers"); return }
        #expect(printers.count == 12, "every printer kept")
        #expect(printers.allSatisfy { if case .object(let o) = $0 { o["filename"] == .null } else { false } })
        // Nothing that fits: nil, not a truncated list.
        #expect(try LivePrinters.body(plaintexts: [], at: "x", dek: Self.dek) == nil)
    }

    @Test("sent on a change after 2 s, otherwise only as a 30–60 s heartbeat, never before a 429 allows: the shared rule")
    func cadence() async throws {
        let e = Self.engine
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(try await e.liveDue(changed: true, now: t0, lastSent: nil, notBefore: nil))
        #expect(try await !e.liveDue(changed: true, now: t0.addingTimeInterval(1), lastSent: t0, notBefore: nil))
        #expect(try await e.liveDue(changed: true, now: t0.addingTimeInterval(2), lastSent: t0, notBefore: nil))
        #expect(try await !e.liveDue(changed: false, now: t0.addingTimeInterval(30), lastSent: t0, notBefore: nil))
        #expect(try await e.liveDue(changed: false, now: t0.addingTimeInterval(45), lastSent: t0, notBefore: nil))
        #expect(try await !e.liveDue(changed: true, now: t0.addingTimeInterval(5), lastSent: t0, notBefore: t0.addingTimeInterval(10)))
        // Neither stamp moving is a change a person could see; progress is, and so is a printer that stops answering.
        let a = try await e.liveSignature(rows: [Self.answered("m1", t0)])
        let b = try await e.liveSignature(rows: [Self.answered("m1", t0.addingTimeInterval(10))])
        #expect(a == b, "a snapshot every sweep instead of every 45 s")
        #expect(try await e.liveSignature(rows: [Self.answered("m1", t0, progress: 43)]) != a)
        #expect(try await e.liveSignature(rows: [Self.silent("m1", since: t0, asked: t0.addingTimeInterval(10))]) != a)
        #expect(try await e.liveMaxRetryAfter() == 300)
    }

    @Test("only a computer hearing from a printer speaks for the shop: three minutes, by the shared rule")
    func freshPoll() async throws {
        let e = Self.engine
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(try await e.liveHasFreshPoll(rows: [Self.answered("m1", now.addingTimeInterval(-10))], now: now))
        #expect(try await e.liveHasFreshPoll(rows: [Self.answered("m1", now.addingTimeInterval(-180))], now: now))
        #expect(try await !e.liveHasFreshPoll(rows: [Self.answered("m1", now.addingTimeInterval(-181))], now: now), "a frozen cache")
        #expect(try await !e.liveHasFreshPoll(rows: [Self.silent("m1", since: nil, asked: now), Self.silent("m2", since: nil, asked: now)], now: now),
                "the laptop at home: nothing ever answered")
        // One printer answering is enough: the others are honestly unreachable.
        #expect(try await e.liveHasFreshPoll(rows: [Self.silent("m1", since: nil, asked: now), Self.answered("m2", now)], now: now))
        // A row with no lastOkAt at all (an older shape) does not count as heard.
        #expect(try await !e.liveHasFreshPoll(rows: [Self.row("m1")], now: now))
        #expect(try await !e.liveHasFreshPoll(rows: [], now: now))
        // A stamp far in the future is not "lately".
        #expect(try await !e.liveHasFreshPoll(rows: [Self.answered("m1", now.addingTimeInterval(3600))], now: now))
    }

    @Test("the publisher: PUT once, quiet while nothing changes, silent when no printer answers, stops for good on a 403")
    @MainActor
    func publisher() async {
        let e = Self.engine
        let p = LivePrinterPublisher()
        var calls: [(String, String)] = []
        var status = 200
        p.fetch = { r in
            calls.append((r.httpMethod ?? "", r.url?.path ?? ""))
            return (Data("{\"ok\":true}".utf8), HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let conn = CloudReader.Connection(url: "https://cloud.example", shopId: "shop_1", storedToken: "x")
        let now = Date()
        let rows = [Self.answered("m1", now.addingTimeInterval(-5))]
        await p.publishIfDue(rows: rows, engine: e, connection: conn, dek: Self.dek, canWrite: true, now: now, token: { "t" })
        #expect(calls.count == 1 && calls[0].0 == "PUT" && calls[0].1 == "/v1/shops/shop_1/live/printers")
        await p.publishIfDue(rows: rows, engine: e, connection: conn, dek: Self.dek, canWrite: true, now: now, token: { "t" })
        #expect(calls.count == 1, "nothing changed and no heartbeat due")
        await p.publishIfDue(rows: rows, engine: e, connection: conn, dek: nil, canWrite: true, now: now, token: { "t" })
        await p.publishIfDue(rows: rows, engine: e, connection: conn, dek: Self.dek, canWrite: false, now: now, token: { "t" })
        await p.publishIfDue(rows: rows, engine: nil, connection: conn, dek: Self.dek, canWrite: true, now: now, token: { "t" })
        #expect(calls.count == 1, "locked, a viewer, or a rule that cannot be asked: never")

        // THE LAPTOP AT HOME. Every row unreachable, never heard: nothing is sent, however long it waits.
        let home = LivePrinterPublisher()
        home.fetch = p.fetch
        let deaf = [Self.silent("m1", since: nil, asked: now), Self.silent("m2", since: nil, asked: now)]
        for minutes in [0.0, 1, 5, 60] {
            let at = now.addingTimeInterval(minutes * 60)
            await home.publishIfDue(rows: deaf, engine: e, connection: conn, dek: Self.dek, canWrite: true, now: at, token: { "t" })
        }
        #expect(calls.count == 1, "a computer that hears no printer replaced the shop's picture")

        // A FROZEN CACHE. It published while it heard; when polling stops it goes quiet, heartbeat included.
        let frozen = LivePrinterPublisher()
        frozen.fetch = p.fetch
        let stale = [Self.answered("m1", now)]
        await frozen.publishIfDue(rows: stale, engine: e, connection: conn, dek: Self.dek, canWrite: true, now: now, token: { "t" })
        #expect(calls.count == 2)
        await frozen.publishIfDue(rows: stale, engine: e, connection: conn, dek: Self.dek, canWrite: true,
                                  now: now.addingTimeInterval(60), token: { "t" })
        #expect(calls.count == 3, "a heartbeat while the answer is under three minutes old")
        await frozen.publishIfDue(rows: stale, engine: e, connection: conn, dek: Self.dek, canWrite: true,
                                  now: now.addingTimeInterval(4 * 60), token: { "t" })
        await frozen.publishIfDue(rows: stale, engine: e, connection: conn, dek: Self.dek, canWrite: true,
                                  now: now.addingTimeInterval(30 * 60), token: { "t" })
        #expect(calls.count == 3, "“Printing 42%” was still being published from a cache nothing refreshes")
        // It hears again: it speaks again.
        await frozen.publishIfDue(rows: [Self.answered("m1", now.addingTimeInterval(31 * 60))], engine: e, connection: conn,
                                  dek: Self.dek, canWrite: true, now: now.addingTimeInterval(31 * 60), token: { "t" })
        #expect(calls.count == 4)

        let q = LivePrinterPublisher()
        status = 403
        q.fetch = p.fetch
        await q.publishIfDue(rows: rows, engine: e, connection: conn, dek: Self.dek, canWrite: true, now: now, token: { "t" })
        await q.publishIfDue(rows: [Self.answered("m1", now, progress: 99)], engine: e, connection: conn, dek: Self.dek,
                             canWrite: true, now: now, token: { "t" })
        #expect(calls.count == 5, "a 403 is not asked again every sweep")
    }

    @Test("Swift keeps no copy of the snapshot's rules")
    func noCopies() throws {
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
        let live = try String(contentsOf: core.appending(path: "KhaytCore/LivePrinters.swift"), encoding: .utf8)
        for gone in ["func signature(", "func due(", "func cloudRow(", "func epochMs(", "func slim(", "func snapshot("] {
            #expect(!live.contains(gone), Comment(rawValue: gone))
        }
        let publisher = try String(contentsOf: core.appending(path: "KhaytApp/LivePrinterPublisher.swift"), encoding: .utf8)
        for asked in ["liveHasFreshPoll", "liveSignature", "liveDue", "liveSnapshots"] {
            #expect(publisher.contains("engine." + asked), Comment(rawValue: asked))
        }
    }
}
