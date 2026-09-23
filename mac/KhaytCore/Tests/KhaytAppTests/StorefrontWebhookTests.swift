import CryptoKit
import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Salla and Zid telling the shop it has an order.
///
/// ── WHAT A MAC-ONLY SHOP COULD NOT DO ─────────────────────────────────────
///
/// Take one. The Mac could show a storefront's orders once they were in the
/// book, and nothing on this Mac put them there: `/api/webhook/salla` answered
/// 404, and the secret it would be signed with could only be typed into the
/// other app. The rule — the row an order becomes, the platform's id that stops
/// a retry being a second order, the shelf it takes from — is
/// `lib/storefront-webhook.js`, and `test/storefront-webhook.test.js` holds it
/// to what the Node server did. This holds the ROUTE to the Node server's
/// answers, and the write to a real file.
@MainActor
struct StorefrontWebhookTests {

    static let secret = "salla-secret"
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor final class Bench {
        let engine: KhaytEngine
        let server: LanServer
        let port: UInt16
        let book = LanServerTests.Book()
        let writes = LanServerTests.Counter()

        init(secrets: [String: String] = ["salla": StorefrontWebhookTests.secret,
                                          "zid": StorefrontWebhookTests.secret]) async throws {
            let shop = Shop()
            await shop.load(.sample)
            let engine = try #require(shop.engine)
            self.engine = engine
            let book = self.book
            book.value = [
                "printLog": .array([]),
                "products": .array([
                    .object(["id": .string("PRD-A"), "nameEn": .string("Flexi Dragon")]),
                ]),
                "settings": .object([
                    "storefront": .object(["stockQty": .object(["PRD-A": .number(12)])]),
                ]),
            ]
            var host = LanServer.Host(store: { book.value }, pin: "2468", engine: engine,
                                      now: { StorefrontWebhookTests.start }, nowText: { "09:16" })
            host.storefrontSecrets = secrets
            let writes = self.writes
            // The same mutation the app runs inside its write, on the bench's
            // book instead of a file.
            host.storefrontOrder = { platform, payload in
                writes.n += 1
                var root = book.value
                let order = try await Shop.recordStorefront(
                    into: &root, engine: engine, platform: platform, payload: payload,
                    id: "\(platform)-fixed-\(writes.n)", now: StorefrontWebhookTests.start)
                book.value = root
                return order
            }
            let server = LanServer(host: host)
            self.server = server
            port = try await server.start(port: 0, bind: .loopback)
        }

        func deliver(_ platform: String, _ body: String, signature: String? = nil,
                     secret: String = StorefrontWebhookTests.secret) async throws -> LanServerTests.Bench.Reply {
            let sig = signature ?? LanServer.webhookSignature(Data(body.utf8), secret: secret)
            let header = platform == "salla" ? "X-Salla-Signature" : "X-Zid-Signature"
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/webhook/\(platform)")!)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(sig, forHTTPHeaderField: header)
            let (data, response) = try await LanServerTests.NoRedirect.session.data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            return .init(status: http.statusCode, headers: [:], body: data)
        }

        var orders: [[String: JSONValue]] {
            guard case .array(let log)? = book.value["printLog"] else { return [] }
            return log.compactMap { if case .object(let o) = $0 { o } else { nil } }
        }
        var dragons: Double? {
            guard case .object(let s)? = book.value["settings"], case .object(let f)? = s["storefront"],
                  case .object(let q)? = f["stockQty"], case .number(let n)? = q["PRD-A"] else { return nil }
            return n
        }
        func stop() { server.stop() }
    }

    static func salla(_ ref: String, items: String = #"[{"name":"Custom bracket","quantity":1}]"#) -> String {
        #"{"event":"order.created","data":{"reference_id":"\#(ref)","customer":{"first_name":"Nora","last_name":"A"},"amounts":{"total":{"amount":380,"currency":"SAR"}},"items":\#(items)}}"#
    }

    // MARK: - The signature is the storefront's

    @Test("the signature is the one Salla and the Node server compute")
    func signatureIsHmacHex() {
        // Computed independently of `webhookSignature`, with CryptoKit's own
        // verifier, so this is not the function agreeing with itself.
        let body = Data(#"{"a":1}"#.utf8)
        let sig = LanServer.webhookSignature(body, secret: "k")
        #expect(sig.hasPrefix("sha256="))
        let hex = String(sig.dropFirst("sha256=".count))
        #expect(hex.count == 64)
        let bytes = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
            let a = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[a...hex.index(after: a)], radix: 16) ?? 0
        }
        #expect(HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: body,
                                                        using: SymmetricKey(data: Data("k".utf8))))
        // The value Node's `crypto.createHmac('sha256', 'k').update('{"a":1}')`
        // gives — the Node server's own check, byte for byte.
        #expect(sig == "sha256=c3a92ff9e274cdcce27a58c15a78ec6dcbbdbd0038a87e7a11baef2028fd8bff")
    }

    // MARK: - An order

    @Test("a signed Salla order is recorded at the top of the log, stamped, with its own id")
    func recordsAnOrder() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let reply = try await bench.deliver("salla", Self.salla("SL-1"))
        #expect(reply.status == 200)
        #expect(reply.text == #"{"ok":true}"#)
        let order = try #require(bench.orders.first)
        #expect(order["id"] == .string("salla-fixed-1"))
        #expect(order["project"] == .string("Salla: Custom bracket"))
        #expect(order["client"] == .string("Nora A"))
        #expect(order["status"] == .string("pending"))
        #expect(order["price"] == .number(380))
        #expect(order["source"] == .string("salla"))
        #expect(order["sourceOrderId"] == .string("SL-1"))
        #expect(order["date"] == .string(LanServer.localDay(Self.start)))
        #expect(order["rev"] == .number(1), "a new record the cloud never hears of is not synced")
    }

    @Test("the same order delivered again is one order, and the writer is not reached")
    func retryIsNotASecondOrder() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        _ = try await bench.deliver("salla", Self.salla("SL-2"))
        // A different body — so a different signature, past the replay cache —
        // for the same order: a provider retry with a field that moved.
        let again = try await bench.deliver("salla", Self.salla("SL-2", items: "[]"))
        #expect(again.status == 200, "a retry answered non-2xx is retried until the platform gives up")
        #expect(again.text.contains(#""duplicate":true"#))
        #expect(bench.orders.count == 1)
        #expect(bench.writes.n == 1, "a duplicate the book already showed went to the writer anyway")
    }

    @Test("a byte-identical replay is refused before anything is read")
    func replayRefused() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let body = Self.salla("SL-3")
        #expect(try await bench.deliver("salla", body).status == 200)
        let replay = try await bench.deliver("salla", body)
        #expect(replay.status == 409)
        #expect(bench.writes.n == 1)
    }

    @Test("an order for something on the shelf comes off it")
    func takesFromTheShelf() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let reply = try await bench.deliver("salla", Self.salla("SL-4", items: #"[{"name":"Flexi Dragon","quantity":2}]"#))
        #expect(reply.status == 200)
        #expect(bench.dragons == 10, "twelve on the shelf, two sold, and the shop still publishes twelve")
        #expect(bench.orders.first?["status"] == .string("completed"))
        #expect(bench.orders.first?["fromStock"] == .bool(true))
    }

    @Test("Zid is signed under its own header and recorded under its own name")
    func zid() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let reply = try await bench.deliver("zid", #"{"order":{"reference_id":"ZD-9","id":9,"total":120}}"#)
        #expect(reply.status == 200)
        #expect(bench.orders.first?["source"] == .string("zid"))
        #expect(bench.orders.first?["sourceOrderId"] == .string("ZD-9"))
        // A Salla signature header on a Zid delivery is no signature at all.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(bench.port)/api/webhook/zid")!)
        request.httpMethod = "POST"
        let body = Data(#"{"order":{"reference_id":"ZD-10"}}"#.utf8)
        request.httpBody = body
        request.setValue(LanServer.webhookSignature(body, secret: Self.secret), forHTTPHeaderField: "X-Salla-Signature")
        let (_, response) = try await LanServerTests.NoRedirect.session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 401)
    }

    // MARK: - The refusals

    @Test("no secret configured is 403, and nothing is written")
    func noSecret() async throws {
        let bench = try await Bench(secrets: ["zid": Self.secret])
        defer { bench.stop() }
        let reply = try await bench.deliver("salla", Self.salla("SL-5"))
        #expect(reply.status == 403)
        #expect(reply.text.contains("Salla webhook secret not configured"))
        #expect(bench.writes.n == 0)
    }

    @Test("a wrong signature is 401, ten of them lock the channel, and the PIN is not locked with it")
    func wrongSignatureLocks() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        for i in 0..<10 {
            let reply = try await bench.deliver("salla", Self.salla("SL-x\(i)"), secret: "wrong")
            #expect(reply.status == 401)
        }
        let locked = try await bench.deliver("salla", Self.salla("SL-6"))
        #expect(locked.status == 429, "a right signature after ten wrong ones got through the lockout")
        #expect(bench.writes.n == 0)
        // Another channel, and the owner's PIN, are their own buckets.
        #expect(try await bench.deliver("zid", #"{"order":{"reference_id":"ZD-1"}}"#).status == 200)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(bench.port)/api/queue?pin=2468")!)
        request.httpMethod = "GET"
        let (_, response) = try await LanServerTests.NoRedirect.session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200,
                "a storefront hammering a wrong secret locked the owner out of the queue")
    }

    @Test("a GET is not a delivery")
    func getIsNotRouted() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let (_, response) = try await LanServerTests.NoRedirect.session.data(
            from: URL(string: "http://127.0.0.1:\(bench.port)/api/webhook/salla")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("the 404 does not advertise the storefront addresses to a stranger")
    func notAdvertised() {
        // Which storefront a shop sells through is not the business of whoever
        // mistyped a path on its Wi‑Fi. See `LanServer.endpoints`.
        #expect(!LanServer.endpoints.contains { $0.contains("webhook") })
    }

    // MARK: - The file

    @Test("recorded into a real book on disk: the order, the shelf, and a retry that changes nothing")
    func intoARealFile() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "storefront-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "khayt-store.json")
        let book: JSONValue = .object([
            "printLog": .array([.object(["id": .string("old"), "status": .string("completed"), "rev": .number(4)])]),
            "products": .array([.object(["id": .string("PRD-A"), "nameEn": .string("Flexi Dragon")])]),
            "settings": .object(["storefront": .object(["stockQty": .object(["PRD-A": .number(3)])])]),
        ])
        try JSONEncoder().encode(book).write(to: url)
        let payload = try JSONDecoder().decode(JSONValue.self,
                                               from: Data(Self.salla("SL-7", items: #"[{"name":"Flexi Dragon","quantity":1}]"#).utf8))

        for attempt in 1...2 {
            try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
                _ = try await Shop.recordStorefront(into: &root, engine: engine, platform: "salla",
                                                    payload: payload, id: "salla-\(attempt)", now: Self.start)
            }
        }

        let written = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        guard case .array(let log)? = written["printLog"] else { Issue.record("no printLog"); return }
        #expect(log.count == 2, "the retry wrote a second order")
        guard case .object(let top) = log[0] else { Issue.record("no order"); return }
        #expect(top["id"] == .string("salla-1"))
        #expect(top["rev"] == .number(1))
        guard case .object(let old) = log[1] else { return }
        #expect(old["rev"] == .number(4), "an order nobody touched was re-stamped")
        guard case .object(let s)? = written["settings"], case .object(let f)? = s["storefront"],
              case .object(let q)? = f["stockQty"] else { Issue.record("no shelf"); return }
        #expect(q["PRD-A"] == .number(2), "the retry took a second dragon off the shelf")
    }

    // MARK: - The wiring

    @Test("the app hands the server its secrets and its writer")
    func wired() throws {
        // A route whose writer is the default — which throws — answers every
        // genuine order 400, and the shop hears nothing. Correct code with no
        // caller is the bug this repo keeps finding, so the assignment is read
        // from the source: delete it and this fails.
        let source = MenuCoverageTests.source("LanServer.swift")
        #expect(source.contains("host.storefrontOrder = {"),
                "nothing assigns host.storefrontOrder, so every Salla and Zid order fails to write")
        #expect(source.contains("self.recordStorefrontOrder(platform, payload: payload)"))
        #expect(source.contains("host.storefrontSecrets = secrets"),
                "nothing hands the server the secrets, so every delivery is refused 403")
        // And a changed secret restarts the server, because it is opened once.
        #expect(source.contains("storefrontSecrets: [\"salla\": lan.text(\"sallaWebhookSecret\")"))
    }
}
