import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What actually goes on the wire when this Mac publishes the shop's promise.
///
/// Every case here runs through the `fetch` seam, so none of them has a shop's
/// credentials and none of them speaks to the service.
@MainActor
struct LeadTimePublisherTests {

    static let connection = CloudReader.Connection(url: "https://cloud.khaytapp.com",
                                                   shopId: "shop_abc_123",
                                                   storedToken: "__enc__whatever")

    static let snapshot: JSONValue = .object([
        "computedAt": .string("2026-09-05T09:00:00Z"),
        "availableFrom": .string("2026-09-09"),
        "dailyHours": .number(8),
        "workingDaysPerWeek": .number(5),
        "handlingDays": .number(3),
        "staleAfterHours": .number(24),
    ])

    @Test("it PUTs the snapshot to the shop's lead-time route")
    func theRequest() async throws {
        var seen: URLRequest?
        try await LeadTimePublisher.publish(Self.connection, token: "tok",
                                            snapshot: Self.snapshot) { request in
            seen = request
            return (Data(#"{"ok":true}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        }
        let request = try #require(seen)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString
                == "https://cloud.khaytapp.com/v1/shops/shop_abc_123/lead-time")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        // Announced on this route as on every other: `recordDeviceCap` runs for
        // whatever the device calls, and a request that omits it marks this Mac
        // unable to read a delta chain and shuts the shop's gate.
        #expect(request.value(forHTTPHeaderField: "x-delta-capable") == "1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    /// The body is PLAIN JSON, and that is the point of the route.
    ///
    /// Everything else this app sends is sealed with the shop's DEK. A
    /// storefront reading this holds no key, so if this ever starts arriving
    /// encrypted the shop simply stops being quotable — with no error anywhere.
    @Test("the snapshot travels unencrypted, under `leadTime`")
    func thePlainBody() async throws {
        var seen: URLRequest?
        try await LeadTimePublisher.publish(Self.connection, token: "tok",
                                            snapshot: Self.snapshot) { request in
            seen = request
            return (Data(#"{"ok":true}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        }
        let body = try #require(seen?.httpBody)
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: body)
        #expect(decoded == ["leadTime": Self.snapshot])
        // Said explicitly: the availability date is readable in the bytes.
        #expect(String(decoding: body, as: UTF8.self).contains("2026-09-09"))
    }

    /// Withdrawal is a value, not an omission.
    ///
    /// A shop that turns publishing off must take down the date it last
    /// published. Sending `{}` — or nothing — would leave a frozen promise on a
    /// public URL for ever, which is worse than never having published one.
    @Test("nil withdraws the last promise, as an explicit null")
    func withdrawal() async throws {
        var seen: URLRequest?
        try await LeadTimePublisher.publish(Self.connection, token: "tok",
                                            snapshot: nil) { request in
            seen = request
            return (Data(#"{"ok":true}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        }
        let body = try #require(seen?.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == "{\"leadTime\":null}")
        #expect(try JSONDecoder().decode([String: JSONValue].self, from: body)
                == ["leadTime": .null])
    }

    @Test("a refused token is named as one")
    func unauthorised() async throws {
        await #expect(throws: LeadTimePublisher.Failure.unauthorised) {
            try await LeadTimePublisher.publish(Self.connection, token: "tok",
                                                snapshot: Self.snapshot) { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 401,
                                               httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        }
    }

    @Test("any other answer carries the code and what it said")
    func otherFailures() async throws {
        await #expect(throws: LeadTimePublisher.Failure.http(503, "busy")) {
            try await LeadTimePublisher.publish(Self.connection, token: "tok",
                                                snapshot: Self.snapshot) { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 503,
                                               httpVersion: nil, headerFields: nil)!
                return (Data("busy".utf8), response)
            }
        }
    }

    /// The shop's LOCAL day, not the UTC one.
    ///
    /// `lib/lead-time.js` anchors its arithmetic to `T00:00:00Z` and never asks
    /// a clock, so this one conversion decides the timezone for the whole
    /// promise. A +03:00 shop publishing the UTC day late in the evening
    /// publishes yesterday — a promise that has already partly expired.
    @Test("the day is read in the shop's own timezone")
    func localDayIsLocal() {
        // 2026-09-05T22:30Z — already the 6th in Riyadh.
        let instant = Date(timeIntervalSince1970: 1_788_647_400)

        var riyadh = Calendar(identifier: .gregorian)
        riyadh.timeZone = TimeZone(identifier: "Asia/Riyadh")!
        #expect(LeadTimePublisher.localDay(instant, calendar: riyadh) == "2026-09-06")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(LeadTimePublisher.localDay(instant, calendar: utc) == "2026-09-05")
    }

    /// Zero-padded, because the cloud and `lead-time.js` both parse it as
    /// `YYYY-MM-DD` and `2026-9-5` is not that.
    @Test("single-digit months and days keep their zeros")
    func padding() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        // 2026-01-02T12:00Z
        #expect(LeadTimePublisher.localDay(Date(timeIntervalSince1970: 1_767_355_200),
                                           calendar: utc) == "2026-01-02")
    }
}
