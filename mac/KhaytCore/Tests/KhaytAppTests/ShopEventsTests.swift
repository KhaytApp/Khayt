import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A print that ends is told to the shop's iPhones through Khayt Cloud,
/// sealed, in the shape the companion decrypts.
@MainActor
struct ShopEventsTests {

    static let connection = CloudReader.Connection(url: "https://cloud.khaytapp.com",
                                                   shopId: "shop_abc_123", storedToken: "__enc__x")
    static let dek = Data(repeating: 7, count: 32)
    static let ended = FinishCamera.Ended(machineId: "M1", machineName: "U1", orderId: "ORD-1",
                                          outcome: "finished", durationS: 11_520.4, photoTaken: true,
                                          filename: "bracket.gcode")

    @Test("payload v1: the agreed fields, advancedTo null, and nothing else in the clear")
    func payload() {
        let p = ShopEventPublisher.printFinishedPayload(Self.ended, at: "2026-09-26T10:00:00Z",
                                                        project: "Bracket", client: "")
        #expect(p["v"] == .number(1))
        #expect(p["kind"] == .string("print-finished"))
        #expect(p["orderId"] == .string("ORD-1"))
        #expect(p["project"] == .string("Bracket"))
        #expect(p["client"] == .null)
        #expect(p["durationS"] == .number(11_520))
        #expect(p["photo"] == .bool(true))
        #expect(p["advancedTo"] == .null)
    }

    @Test("it POSTs {kind, at, ciphertext} to /events, and the ciphertext opens with the shop's key")
    func request() async throws {
        var seen: URLRequest?
        let payload = ShopEventPublisher.printFinishedPayload(Self.ended, at: "2026-09-26T10:00:00Z",
                                                              project: nil, client: nil)
        let outcome = try await ShopEventPublisher.send(
            Self.connection, token: "tok", dek: Self.dek, kind: "print-finished",
            at: "2026-09-26T10:00:00Z", payload: payload) { request in
            seen = request
            return (Data(#"{"ok":true,"id":"e1"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(outcome == .sent)
        let request = try #require(seen)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://cloud.khaytapp.com/v1/shops/shop_abc_123/events")
        let body = try JSONDecoder().decode([String: JSONValue].self, from: try #require(request.httpBody))
        #expect(body["kind"] == .string("print-finished"))
        #expect(body["at"] == .string("2026-09-26T10:00:00Z"))
        let text = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(!text.contains("bracket.gcode"), "the details went up in the clear")
        let blob = try JSONDecoder().decode(SyncCrypto.Blob.self,
                                            from: JSONEncoder().encode(try #require(body["ciphertext"])))
        let opened = try JSONDecoder().decode([String: JSONValue].self,
                                              from: try SyncCrypto.openStore(blob, dek: Self.dek))
        #expect(opened["filename"] == JSONValue.string("bracket.gcode"))
    }

    @Test("the cloud's refusals are outcomes, not errors")
    func refusals() async throws {
        for (code, want) in [(429, ShopEventPublisher.Outcome.rateLimited), (403, .readOnly),
                             (404, .notOffered), (413, .tooLarge), (500, .failed(500))] {
            let got = try await ShopEventPublisher.send(
                Self.connection, token: "tok", dek: Self.dek, kind: "print-finished",
                at: "2026-09-26T10:00:00Z", payload: ["v": .number(1)]) { request in
                (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            #expect(got == want)
        }
    }

    @Test("the finish edge sends it")
    func wired() throws {
        let shop = try QuoteSheetStatusTests.source("Shop.swift")
        #expect(shop.contains("await sendPrintFinishedEvent(ended)"))
        #expect(ShopEventPublisher.stamp(Date(timeIntervalSince1970: 1_790_000_000)) == "2026-09-21T14:13:20Z")
    }
}
