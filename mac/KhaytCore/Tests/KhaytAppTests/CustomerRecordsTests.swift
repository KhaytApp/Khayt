import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The plaintext copy of a shop's customers for its own storefront.
///
/// Every request here runs through the `fetch` seam: none has a shop's
/// credentials and none speaks to the service.
@MainActor
struct CustomerRecordsTests {

    static let connection = CloudReader.Connection(url: "https://cloud.khaytapp.com",
                                                   shopId: "shop_abc_123",
                                                   storedToken: "__enc__whatever")

    static func answer(_ code: Int, _ headers: [String: String]? = nil)
        -> (URLRequest) -> (Data, URLResponse) {
        { request in
            (Data(#"{"ok":true}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!)
        }
    }

    @Test("held: this build cannot turn it on until the privacy policy covers it")
    func held() async throws {
        let engine = try KhaytEngine()
        let state = try await engine.customerRecordsState(
            settings: ["customerRecords": .object(["enabled": .bool(true)])])
        #expect(state.ready == false)
        #expect(state.on == false, "a book with the switch on publishes nothing while held")
    }

    @Test("on: the whole set is PUT, as plain JSON, to the shop's customers route")
    func put() async throws {
        let body: JSONValue = .object(["customers": .array([.object(["email": .string("a@b.co")])])])
        var seen: URLRequest?
        try await CustomerRecordsPublisher.publish(Self.connection, token: "tok", body: body) {
            seen = $0; return Self.answer(200)($0)
        }
        let request = try #require(seen)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://cloud.khaytapp.com/v1/shops/shop_abc_123/customers")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sent = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(sent == body)
    }

    @Test("off: a DELETE with no body takes the whole copy down")
    func delete() async throws {
        var seen: URLRequest?
        try await CustomerRecordsPublisher.publish(Self.connection, token: "tok", body: nil) {
            seen = $0; return Self.answer(200)($0)
        }
        #expect(seen?.httpMethod == "DELETE")
        #expect(seen?.httpBody == nil)
    }

    @Test("a 429 says when to try again; 403 is a viewer; 404 is a cloud without the route")
    func failures() async throws {
        let body: JSONValue = .object(["customers": .array([])])
        await #expect(throws: CustomerRecordsPublisher.Failure.limited(retryAfter: 120)) {
            try await CustomerRecordsPublisher.publish(Self.connection, token: "t", body: body,
                                                       fetch: Self.answer(429, ["Retry-After": "120"]))
        }
        await #expect(throws: CustomerRecordsPublisher.Failure.readOnly) {
            try await CustomerRecordsPublisher.publish(Self.connection, token: "t", body: body,
                                                       fetch: Self.answer(403))
        }
        await #expect(throws: CustomerRecordsPublisher.Failure.notOffered) {
            try await CustomerRecordsPublisher.publish(Self.connection, token: "t", body: body,
                                                       fetch: Self.answer(404))
        }
        await #expect(throws: CustomerRecordsPublisher.Failure.tooLarge) {
            try await CustomerRecordsPublisher.publish(Self.connection, token: "t", body: body,
                                                       fetch: Self.answer(413))
        }
    }

    @Test("the same set always has the same fingerprint, whatever order its keys came in")
    func fingerprint() throws {
        let a: JSONValue = .object(["email": .string("a@b.co"), "name": .string("A")])
        let b: JSONValue = .object(["name": .string("A"), "email": .string("a@b.co")])
        #expect(try CustomerRecordsPublisher.fingerprint(a) == CustomerRecordsPublisher.fingerprint(b))
        let c: JSONValue = .object(["name": .string("B"), "email": .string("a@b.co")])
        #expect(try CustomerRecordsPublisher.fingerprint(a) != CustomerRecordsPublisher.fingerprint(c))
    }

    @Test("this Mac's memory of its sends is per shop, and forgetting it clears it")
    func memory() throws {
        let defaults = try #require(UserDefaults(suiteName: "khayt.test.customerRecords"))
        defaults.removePersistentDomain(forName: "khayt.test.customerRecords")
        #expect(CustomerRecordsPublisher.memory("s1", defaults) == nil)
        CustomerRecordsPublisher.remember(.init(fingerprint: "f", at: "2026-10-18T00:00:00Z"), "s1", defaults)
        #expect(CustomerRecordsPublisher.memory("s1", defaults)?.fingerprint == "f")
        #expect(CustomerRecordsPublisher.memory("s2", defaults) == nil)
        CustomerRecordsPublisher.remember(nil, "s1", defaults)
        #expect(CustomerRecordsPublisher.memory("s1", defaults) == nil)
    }

    @Test("the sample book builds a set: customers with an email, their own jobs only")
    func sampleBuild() async throws {
        let shop = Shop()
        await shop.load(.sample, asOf: try #require(SampleBook.anchor))
        let engine = try #require(shop.engine)
        let built = try await engine.customerRecords(clients: shop.clientRows, printLog: shop.orderRows,
                                                     settings: shop.settingsDict)
        guard case .object(let body) = built.body, case .array(let customers)? = body["customers"] else {
            Issue.record("no customers array"); return
        }
        #expect(customers.count == built.published)
        let text = String(decoding: try JSONEncoder().encode(built.body), as: UTF8.self)
        for never in ["\"notes\"", "\"cost\"", "\"paidAmount\"", "\"files\""] {
            #expect(!text.contains(never), "\(never) is the shop's, not the storefront's")
        }
    }

    @Test("every new string is in English and Arabic")
    func strings() async {
        for lang in ["en", "ar"] {
            let w = Words()
            await w.load(lang, engine: try? KhaytEngine())
            for key in ["mac.cr_title", "mac.cr_enable", "mac.cr_hint", "mac.cr_held",
                        "mac.cr_needs_cloud", "mac.cr_published", "mac.cr_deleted", "mac.cr_failed", "mac.cr_trimmed",
                        "mac.cr_err_unauthorised", "mac.cr_err_read_only", "mac.cr_err_not_offered",
                        "mac.cr_err_too_large", "mac.cr_err_limited", "mac.cloud_err_http"] {
                #expect(w.callIt(key) != key, "\(key) has no \(lang)")
            }
        }
    }

    @Test("a Retry-After is held to a second..a day; inf would have stopped the switch's delete")
    func retryAfterClamped() {
        #expect(CustomerRecordsPublisher.retryAfter("120") == 120)
        #expect(CustomerRecordsPublisher.retryAfter("inf") == nil)
        #expect(CustomerRecordsPublisher.retryAfter("1e308") == 86_400)
        #expect(CustomerRecordsPublisher.retryAfter("0") == 1)
        #expect(CustomerRecordsPublisher.retryAfter(nil) == nil)
    }

    @Test("a book holding 'on' from elsewhere shows on while held, so the switch can turn it off")
    func heldBookShowsOn() async {
        let shop = Shop()
        await shop.load(.sample)
        var settings = shop.settingsDict
        settings["customerRecords"] = .object(["enabled": .bool(true)])
        shop.settingsValue = .object(settings)
        #expect(shop.customerRecordsOn)
        #expect(!shop.customerRecordsReady)
    }

    @Test("failures are said in the shop's language, and a reached cloud is not 'could not reach'")
    func saidInArabic() async {
        let w = Words()
        await w.load("ar", engine: try? KhaytEngine())
        for failure in [CustomerRecordsPublisher.Failure.readOnly, .tooLarge, .http(500, "boom")] {
            let said = failure.said(w)
            #expect(!said.contains("Khayt Cloud"), "English in the Arabic pane: \(said)")
            #expect(!said.contains("boom"), "the cloud's own English stays out")
            #expect(!said.contains(w.callIt("mac.cr_failed")))
        }
    }
}
