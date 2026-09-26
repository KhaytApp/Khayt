import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// SMSA, Aramex and Saudi Post telling the shop where a parcel is.
///
/// The rule is `lib/carrier-webhook.js`, held to the Node route over real
/// HTTP by `test/carrier-webhook.test.js`. This holds the Mac's route to the
/// same answers in the same order, and the write to a real file.
@MainActor
struct CarrierWebhookTests {

    static let secret = "smsa-secret"
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor final class Bench {
        let server: LanServer
        let port: UInt16
        let book = LanServerTests.Book()
        let writes = LanServerTests.Counter()

        init(secrets: [String: String] = ["smsa": CarrierWebhookTests.secret], replayFile: URL? = nil) async throws {
            let shop = Shop()
            await shop.load(.sample)
            let engine = try #require(shop.engine)
            let book = self.book
            book.value = [
                "printLog": .array([
                    .object(["id": .string("J-1"), "status": .string("completed"), "trackingNumber": .string("SM123"),
                             "shippingStatus": .string("label_created"), "rev": .number(3)]),
                    .object(["id": .string("J-2"), "status": .string("completed"), "trackingNumber": .string("SM999"),
                             "shippingStatus": .string("delivered"), "rev": .number(5)]),
                ]),
                "settings": .object(["shipping": .object(["smsa": .object(["enabled": .bool(true)])])]),
            ]
            var host = LanServer.Host(store: { book.value }, pin: "2468", engine: engine,
                                      now: { CarrierWebhookTests.start }, nowText: { "09:16" })
            host.carrierSecrets = secrets
            host.replayFile = replayFile
            let writes = self.writes
            host.carrierEvent = { event, at in
                writes.n += 1
                var root = book.value
                let moved = try await Shop.applyCarrierEvent(into: &root, engine: engine, event: event, at: at)
                book.value = root
                return moved
            }
            let server = LanServer(host: host)
            self.server = server
            port = try await server.start(port: 0, bind: .loopback)
        }

        func send(_ body: String, carrier: String = "smsa", secret: String = CarrierWebhookTests.secret,
                  header: String = "X-Khayt-Signature") async throws -> LanServerTests.Bench.Reply {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/webhook/\(carrier)")!)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue(LanServer.webhookSignature(Data(body.utf8), secret: secret), forHTTPHeaderField: header)
            let (data, response) = try await LanServerTests.NoRedirect.session.data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            return .init(status: http.statusCode, headers: [:], body: data)
        }

        func job(_ id: String) -> [String: JSONValue]? { book.job(id) }
        func stop() { server.stop() }
    }

    @Test("a signed event moves the parcel on, adds a line of trail, and stamps the job")
    func advances() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let reply = try await bench.send(#"{"awb":"SM123","status":"out for delivery"}"#)
        #expect(reply.status == 200)
        let job = try #require(bench.job("J-1"))
        #expect(job["shippingStatus"] == .string("out_for_delivery"))
        #expect(job["shippedAt"] == .string(StoreWriter.iso(Self.start)))
        #expect(job["rev"] == .number(4), "a moved job the cloud never hears of")
        guard case .array(let trail)? = job["shippingHistory"] else { Issue.record("no trail"); return }
        #expect(trail.count == 1)
        #expect(bench.writes.n == 1)
    }

    @Test("an unknown parcel and an out-of-order event are 200, and neither reaches the writer")
    func nothingToMove() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        #expect(try await bench.send(#"{"awb":"NOPE","status":"delivered"}"#).status == 200,
                "a different answer would tell the sender which parcels this shop holds")
        #expect(try await bench.send(#"{"awb":"SM999","status":"in transit"}"#).status == 200)
        #expect(bench.writes.n == 0)
        #expect(bench.job("J-2")?["rev"] == .number(5))
    }

    @Test("an unreadable signed payload is 422 and names the carrier")
    func unreadable() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let reply = try await bench.send(#"{"hello":"world"}"#)
        #expect(reply.status == 422)
        #expect(reply.text.contains(#""carrier":"smsa""#))
    }

    @Test("no secret is 403, a wrong one 401, the X-Signature spelling works, and a replay is 409")
    func refusals() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        #expect(try await bench.send(#"{"awb":"SM123","status":"delivered"}"#, carrier: "aramex").status == 403)
        #expect(try await bench.send(#"{"awb":"SM123","status":"delivered"}"#, secret: "wrong").status == 401)
        let body = #"{"awb":"SM123","status":"in transit"}"#
        #expect(try await bench.send(body, header: "X-Signature").status == 200)
        #expect(try await bench.send(body).status == 409)
        #expect(bench.writes.n == 1)
    }

    /// SEC-010. Ten minutes in memory was the whole defence, so a restart
    /// forgot every delivery it had taken.
    @Test("a replay is refused after the app restarts, and the file holds no signature")
    func replayRefusedAcrossARestart() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "seen-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let body = #"{"awb":"SM123","status":"in transit"}"#
        let first = try await Bench(replayFile: file)
        #expect(try await first.send(body).status == 200)
        first.stop()

        let second = try await Bench(replayFile: file)
        defer { second.stop() }
        #expect(try await second.send(body).status == 409)

        let saved = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        let signature = LanServer.webhookSignature(Data(body.utf8), secret: CarrierWebhookTests.secret)
        #expect(!saved.contains(signature), "the file stores a replayable signature")
        #expect(saved.contains(LanServer.seenKey(signature)))
    }

    @Test("the window is thirty days and ten thousand deliveries")
    func window() {
        #expect(LanServer.seenSignatureTTL == 30 * 24 * 60 * 60)
        #expect(LanServer.seenSignatureMax == 10_000)
    }

    @Test("only the three carriers are routed, and the 404 does not advertise them")
    func routes() {
        #expect(LanServer.carrierHookId("/api/webhook/smsa") == "smsa")
        #expect(LanServer.carrierHookId("/api/webhook/spl") == "spl")
        #expect(LanServer.carrierHookId("/api/webhook/manual") == nil)
        #expect(LanServer.carrierHookId("/api/webhook/salla") == nil)
        #expect(!LanServer.endpoints.contains { $0.contains("webhook") })
    }

    @Test("into a real book on disk, and the same event again changes nothing")
    func intoARealFile() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "carrier-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "khayt-store.json")
        try JSONEncoder().encode(JSONValue.object(["printLog": .array([
            .object(["id": .string("J-1"), "status": .string("completed"), "trackingNumber": .string("SM123"),
                     "shippingStatus": .string("in_transit"), "rev": .number(2)]),
            .object(["id": .string("J-2"), "status": .string("printing"), "rev": .number(7)]),
        ])])).write(to: url)
        let event = try #require(try await engine.carrierEvent(
            carrier: "smsa", payload: .object(["awb": .string("SM123"), "status": .string("delivered")]),
            config: .object([:])))
        let at = StoreWriter.iso(Self.start)
        var results: [JSONValue?] = []
        for _ in 1...2 {
            try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
                results.append(try await Shop.applyCarrierEvent(into: &root, engine: engine, event: event, at: at))
            }
        }
        #expect(results[0] != nil)
        #expect(results[1] == nil, "the same event moved the parcel twice")
        let written = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        guard case .array(let log)? = written["printLog"], case .object(let one) = log[0],
              case .object(let two) = log[1] else { Issue.record("no log"); return }
        #expect(one["shippingStatus"] == .string("delivered"))
        #expect(one["deliveredAt"] == .string(at))
        #expect(one["rev"] == .number(3))
        #expect(two["rev"] == .number(7), "a job nobody touched was re-stamped")
    }

    @Test("the app hands the server its carrier secrets and its writer")
    func wired() {
        let source = MenuCoverageTests.source("LanServer.swift")
        #expect(source.contains("host.carrierEvent = {"),
                "nothing assigns host.carrierEvent, so every carrier update fails to write")
        #expect(source.contains("self.recordCarrierEvent(event, at: at)"))
        #expect(source.contains("host.carrierSecrets = carrierSecrets"),
                "nothing hands the server the secrets, so every carrier update is refused 403")
        #expect(source.contains("carrierSecrets: carrierSecretsStored"),
                "a changed carrier secret would not restart the server that opened the old one")
    }
}
