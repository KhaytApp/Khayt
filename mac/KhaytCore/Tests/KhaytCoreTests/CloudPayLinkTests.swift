import Foundation
import Testing
@testable import KhaytCore

/// `CloudPayLink` against khayt-cloud's payment-link route, through the fetch seam.
struct CloudPayLinkTests {
    static let connection = CloudReader.Connection(url: "https://cloud.example.com", shopId: "shop_ab", storedToken: "")

    @Test("reads a link, and reads null as no link")
    func reads() async throws {
        let log = CloudTeamTests.Log()
        let link = try await CloudPayLink.get(Self.connection, token: "tok", fetch: CloudTeamTests.answering(
            200, #"{"url":"https://pay.example.com/p?a={amount}","label":"Tap","updatedAt":"2026-11-03T10:00:00Z"}"#, log: log))
        #expect(link?.url == "https://pay.example.com/p?a={amount}" && link?.label == "Tap")
        let r = try #require(log.requests.first)
        #expect(r.httpMethod == "GET" && r.url?.path == "/v1/shops/shop_ab/payment-link")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(try await CloudPayLink.get(Self.connection, token: "t", fetch: CloudTeamTests.answering(200, "null")) == nil)
        #expect(try await CloudPayLink.get(Self.connection, token: "t",
                                           fetch: CloudTeamTests.answering(200, #"{"url":null,"label":null,"updatedAt":null}"#)) == nil)
    }

    @Test("a save sends the link trimmed, and the label only when there is one")
    func saves() async throws {
        let log = CloudTeamTests.Log()
        _ = try await CloudPayLink.put(url: "  https://pay.example.com/x ", label: " ", Self.connection, token: "t",
                                       fetch: CloudTeamTests.answering(200, #"{"url":"https://pay.example.com/x","label":null,"updatedAt":null}"#, log: log))
        #expect(try JSONSerialization.jsonObject(with: log.requests[0].httpBody!) as? [String: String]
                == ["url": "https://pay.example.com/x"])
        _ = try await CloudPayLink.put(url: "https://pay.example.com/x", label: "Bank", Self.connection, token: "t",
                                       fetch: CloudTeamTests.answering(200, #"{"url":"https://pay.example.com/x","label":"Bank"}"#, log: log))
        let sent = try JSONSerialization.jsonObject(with: log.requests[1].httpBody!) as? [String: String]
        #expect(sent?["label"] == "Bank" && log.requests[1].httpMethod == "PUT")
    }

    @Test("a refused link carries the cloud's own words; a viewer's carries the reason role")
    func refusals() async throws {
        do {
            _ = try await CloudPayLink.put(url: "http://x", label: "", Self.connection, token: "t", fetch: CloudTeamTests.answering(
                400, #"{"error":"The link must start with https://","reason":"bad-pay-link"}"#))
            Issue.record("should have thrown")
        } catch let r as CloudPayLink.Refusal {
            #expect(r.status == 400 && r.reason == "bad-pay-link" && r.error == "The link must start with https://")
        }
        do {
            try await CloudPayLink.remove(Self.connection, token: "t", fetch: CloudTeamTests.answering(403, #"{"reason":"role"}"#))
            Issue.record("should have thrown")
        } catch let r as CloudPayLink.Refusal {
            #expect(r.status == 403 && r.reason == "role")
        }
    }
}
