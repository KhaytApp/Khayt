import Foundation
import Testing
@testable import KhaytCore

/// `CloudCheckout` against khayt-cloud's digest and checkout routes, with the
/// cloud stubbed: no network, no browser, no waiting.
struct CloudCheckoutTests {

    static let connection = CloudReader.Connection(url: "https://cloud.example.com", shopId: "shop_ab", storedToken: "")

    final class Cloud: @unchecked Sendable {
        var requests: [URLRequest] = []
        var polls = 0
        var routes: [(String, (URLRequest) -> (Int, String))] = []
        var paths: [String] { requests.map { ($0.httpMethod ?? "GET") + " " + ($0.url!.path) } }
        lazy var fetch: S3.Fetch = { [self] r in
            requests.append(r)
            let key = (r.httpMethod ?? "GET") + " " + r.url!.path
            let (code, body) = routes.first { key.hasPrefix($0.0) }?.1(r) ?? (404, "{}")
            return (Data(body.utf8), HTTPURLResponse(url: r.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }

    static let created = """
    {"id":"bco_1","url":"https://pay.example.com/c/1","plan":"maker","period":"month","amountSar":"25.00","currency":"SAR"}
    """
    static let mine = #"{"billingEnabled":true,"plan":"maker","label":"Maker","status":"active","active":true,"until":"2026-12-03T00:00:00Z"}"#

    final class Opened: @unchecked Sendable { var urls: [URL] = [] }

    @Test("billing-provider-off and beta-running hide the pay button for the session and are not asked again",
          arguments: ["billing-provider-off", "beta-running"])
    func providerOffHides(reason: String) async {
        let cloud = Cloud()
        cloud.routes = [("POST /v1/billing/checkout", { _ in (409, #"{"reason":""# + reason + #""}"#) })]
        let gate = CloudCheckout.Gate()
        let opened = Opened()
        #expect(!gate.providerOff)
        let first = await CloudCheckout.run(plan: "maker", period: .month, Self.connection, token: "t", fetch: cloud.fetch,
                                            gate: gate, open: { opened.urls.append($0); return true }, sleep: { _ in })
        #expect(first == .providerOff && gate.providerOff && opened.urls.isEmpty)
        let again = await CloudCheckout.run(plan: "maker", period: .month, Self.connection, token: "t", fetch: cloud.fetch,
                                            gate: gate, open: { _ in true }, sleep: { _ in })
        #expect(again == .providerOff)
        #expect(cloud.requests.count == 1, "the second tap does not spam the cloud")
    }

    @Test("other 409s are refusals, they do not hide the button")
    func otherRefusals() async {
        let cloud = Cloud()
        cloud.routes = [("POST /v1/billing/checkout", { _ in (409, #"{"reason":"not-for-sale"}"#) })]
        let gate = CloudCheckout.Gate()
        let out = await CloudCheckout.run(plan: "maker", period: .year, Self.connection, token: "t", fetch: cloud.fetch,
                                          gate: gate, open: { _ in true }, sleep: { _ in })
        guard case .refused(let r) = out else { Issue.record("expected a refusal, got \(out)"); return }
        #expect(r.reason == "not-for-sale" && !gate.providerOff)
    }

    @Test("201 opens the url, polls until paid, then reads billing/me")
    func paidFlow() async {
        let cloud = Cloud()
        cloud.routes = [
            ("POST /v1/billing/checkout", { _ in (201, Self.created) }),
            ("GET /v1/billing/checkout/bco_1", { [cloud] _ in
                cloud.polls += 1
                return cloud.polls < 3 ? (200, #"{"id":"bco_1","status":"pending"}"#)
                                       : (200, #"{"id":"bco_1","status":"paid","periodEnd":"2026-12-03T00:00:00Z","receiptNo":"R-1"}"#)
            }),
            ("GET /v1/billing/me", { _ in (200, Self.mine) }),
        ]
        let opened = Opened()
        let out = await CloudCheckout.run(plan: "maker", period: .month, Self.connection, token: "tok", fetch: cloud.fetch,
                                          gate: CloudCheckout.Gate(), open: { opened.urls.append($0); return true }, sleep: { _ in })
        guard case .paid(let end, let mine) = out else { Issue.record("expected paid, got \(out)"); return }
        #expect(end == "2026-12-03T00:00:00Z" && mine?.plan == "maker")
        #expect(opened.urls.map(\.absoluteString) == ["https://pay.example.com/c/1"])
        #expect(cloud.polls == 3)
        #expect(cloud.paths.first == "POST /v1/billing/checkout" && cloud.paths.last == "GET /v1/billing/me")
        let post = cloud.requests[0]
        let body = (try? JSONSerialization.jsonObject(with: post.httpBody ?? Data())) as? [String: String]
        #expect(body == ["shopId": "shop_ab", "plan": "maker", "period": "month"])
        #expect(post.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let poll = cloud.requests[1]
        #expect(poll.url?.query == "shopId=shop_ab")
    }

    @Test("failed and mismatch end the wait and are told apart")
    func failedAndMismatch() async {
        for (status, expected) in [("failed", CloudCheckout.Outcome.failed), ("error", .failed),
                                   ("mismatch", .mismatch(id: "bco_1"))] {
            let cloud = Cloud()
            cloud.routes = [("POST /v1/billing/checkout", { _ in (201, Self.created) }),
                            ("GET /v1/billing/checkout/", { _ in (200, #"{"id":"bco_1","status":"\#(status)"}"#) })]
            let out = await CloudCheckout.run(plan: "maker", period: .month, Self.connection, token: "t", fetch: cloud.fetch,
                                              gate: CloudCheckout.Gate(), open: { _ in true }, sleep: { _ in })
            #expect(out == expected, "\(status)")
            #expect(!cloud.paths.contains("GET /v1/billing/me"), "no refresh for an unpaid attempt")
        }
    }

    @Test("a browser that will not open stops before any polling; a pending forever checkout times out")
    func openAndTimeout() async {
        let cloud = Cloud()
        cloud.routes = [("POST /v1/billing/checkout", { _ in (201, Self.created) }),
                        ("GET /v1/billing/checkout/", { _ in (200, #"{"status":"pending"}"#) })]
        let none = await CloudCheckout.run(plan: "maker", period: .month, Self.connection, token: "t", fetch: cloud.fetch,
                                           gate: CloudCheckout.Gate(), open: { _ in false }, sleep: { _ in })
        #expect(none == .couldNotOpen && cloud.polls == 0)
        let late = await CloudCheckout.run(plan: "maker", period: .month, Self.connection, token: "t", fetch: cloud.fetch,
                                           gate: CloudCheckout.Gate(), delays: Array(repeating: .seconds(1), count: 4),
                                           open: { _ in true }, sleep: { _ in })
        #expect(late == .timedOut(id: "bco_1"))
    }

    @Test("closing the sheet cancels the wait")
    func cancelled() async {
        struct Stop: Error {}
        let cloud = Cloud()
        cloud.routes = [("POST /v1/billing/checkout", { _ in (201, Self.created) })]
        let out = await CloudCheckout.run(plan: "maker", period: .month, Self.connection, token: "t", fetch: cloud.fetch,
                                          gate: CloudCheckout.Gate(), open: { _ in true }, sleep: { _ in throw Stop() })
        #expect(out == .cancelled)
    }

    @Test("the digest reads and saves as the cloud answers; serverEnabled false is kept")
    func digest() async throws {
        let cloud = Cloud()
        cloud.routes = [("GET /v1/shops/shop_ab/digest", { _ in (200, #"{"enabled":true,"serverEnabled":false,"lastSentWeek":null}"#) }),
                        ("PUT /v1/shops/shop_ab/digest", { _ in (200, #"{"enabled":false,"serverEnabled":true,"lastSentWeek":"2026-11-01"}"#) })]
        let got = try await CloudCheckout.digest(Self.connection, token: "t", fetch: cloud.fetch)
        #expect(got == .init(enabled: true, serverEnabled: false, lastSentWeek: nil))
        let saved = try await CloudCheckout.setDigest(false, Self.connection, token: "t", fetch: cloud.fetch)
        #expect(saved == .init(enabled: false, serverEnabled: true, lastSentWeek: "2026-11-01"))
        let body = try JSONSerialization.jsonObject(with: #require(cloud.requests[1].httpBody)) as? [String: Bool]
        #expect(body == ["enabled": false])
    }

    @Test("a non-owner's digest is refused with owner-only")
    func digestOwnerOnly() async {
        let cloud = Cloud()
        cloud.routes = [("GET", { _ in (403, #"{"reason":"owner-only"}"#) })]
        await #expect(throws: CloudPlans.Refusal.self) {
            _ = try await CloudCheckout.digest(Self.connection, token: "t", fetch: cloud.fetch)
        }
    }

    // MARK: - VAT by billing country

    static let priceNet = #"{"plan":"maker","period":"month","country":"SA","netSar":"25.00","vatSar":"0.00","vatRate":0,"totalSar":"25.00","currency":"SAR","vatAdded":false}"#
    static let priceVat = #"{"plan":"maker","period":"year","country":"DE","netSar":"100.00","vatSar":"19.00","vatRate":0.19,"totalSar":"119.00","currency":"SAR","vatAdded":true}"#

    @Test("the price lookup asks for plan, period and an upper-cased country, with no token")
    func priceQuery() async throws {
        let cloud = Cloud()
        cloud.routes = [("GET /v1/billing/price", { _ in (200, Self.priceNet) })]
        let q = try await CloudCheckout.quote(plan: "maker", period: .month, country: "sa",
                                              baseURL: Self.connection.url, fetch: cloud.fetch)
        let url = try #require(cloud.requests.first?.url)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        #expect(url.path == "/v1/billing/price")
        #expect(items == ["plan": "maker", "period": "month", "country": "SA"])
        #expect(cloud.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(q.totalSar == 25 && q.netSar == 25 && !q.vatAdded)
    }

    @Test("the answer is read with VAT added and without")
    func priceFormatted() async throws {
        let cloud = Cloud()
        cloud.routes = [("GET /v1/billing/price", { r in
            (200, r.url?.query?.contains("country=DE") == true ? Self.priceVat : Self.priceNet) })]
        let de = try await CloudCheckout.quote(plan: "maker", period: .year, country: "DE",
                                               baseURL: Self.connection.url, fetch: cloud.fetch)
        #expect(de.vatAdded && de.vatSar == 19 && de.totalSar == 119 && de.ratePercent == 19)
        let sa = try await CloudCheckout.quote(plan: "maker", period: .month, country: "SA",
                                               baseURL: Self.connection.url, fetch: cloud.fetch)
        #expect(!sa.vatAdded && sa.vatSar == 0 && sa.totalSar == 25)
        let half = CloudCheckout.Quote(plan: "p", period: "month", country: "XX", netSar: 100, vatSar: 7.5,
                                       vatRate: 0.075, totalSar: 107.5, currency: "SAR", vatAdded: true)
        #expect(half.ratePercent == 7.5)
    }

    @Test("a lookup without a country code makes no request; the cloud's 400 is a refusal")
    func priceRefusals() async {
        let cloud = Cloud()
        cloud.routes = [("GET /v1/billing/price", { _ in (400, #"{"reason":"country-required"}"#) })]
        for country in ["", "Germany"] {
            await #expect(throws: CloudPlans.Refusal.self) {
                _ = try await CloudCheckout.quote(plan: "maker", period: .month, country: country,
                                                  baseURL: Self.connection.url, fetch: cloud.fetch)
            }
        }
        #expect(cloud.requests.isEmpty, "no request for a country that is not a code")
        do {
            _ = try await CloudCheckout.quote(plan: "maker", period: .month, country: "SA",
                                              baseURL: Self.connection.url, fetch: cloud.fetch)
            Issue.record("expected a refusal")
        } catch let r as CloudPlans.Refusal {
            #expect(r.status == 400 && r.reason == "country-required")
        } catch { Issue.record("\(error)") }
    }

    @Test("checkout sends the country, and reads the new 201 and poll fields")
    func countrySent() async throws {
        let cloud = Cloud()
        cloud.routes = [("POST /v1/billing/checkout", { _ in (201, #"{"id":"bco_2","url":"https://pay.example.com/c/2","plan":"maker","period":"year","amountSar":"119.00","country":"DE","netSar":"100.00","vatSar":"19.00","vatRate":0.19,"totalSar":"119.00","currency":"SAR","vatAdded":true}"#) }),
                        ("GET /v1/billing/checkout/bco_2", { _ in (200, #"{"id":"bco_2","status":"pending","country":"DE","netSar":"100.00","vatSar":"19.00","vatRate":0.19}"#) })]
        let s = try await CloudCheckout.start(plan: "maker", period: .year, country: "de", Self.connection, token: "t", fetch: cloud.fetch)
        let body = try JSONSerialization.jsonObject(with: #require(cloud.requests[0].httpBody)) as? [String: String]
        #expect(body == ["shopId": "shop_ab", "plan": "maker", "period": "year", "country": "DE"])
        #expect(s.total == 119 && s.vatAdded == true && s.vatSar == 19 && s.country == "DE")
        let st = try await CloudCheckout.status(id: "bco_2", Self.connection, token: "t", fetch: cloud.fetch)
        #expect(st.state == .pending && st.vatSar == 19 && st.vatRate == 0.19 && st.country == "DE")
        // An older cloud: the new fields are simply absent.
        let old = Cloud()
        old.routes = [("POST /v1/billing/checkout", { _ in (201, Self.created) })]
        let o = try await CloudCheckout.start(plan: "maker", period: .month, country: "SA", Self.connection, token: "t", fetch: old.fetch)
        #expect(o.total == 25 && o.vatAdded == nil && o.netSar == nil)
    }

    @Test("400 country-required becomes its own outcome and does not hide the button")
    func countryRequired() async {
        let cloud = Cloud()
        cloud.routes = [("POST /v1/billing/checkout", { _ in (400, #"{"reason":"country-required"}"#) })]
        let gate = CloudCheckout.Gate()
        let out = await CloudCheckout.run(plan: "maker", period: .month, Self.connection, token: "t", fetch: cloud.fetch,
                                          gate: gate, open: { _ in true }, sleep: { _ in })
        #expect(out == .countryRequired && !gate.providerOff)
    }

    @Test("the catalogue's note shows for added-by-country or prices that are not inclusive")
    func vatNote() throws {
        func cat(_ extra: String) throws -> CloudPlans.Catalogue {
            try JSONDecoder().decode(CloudPlans.Catalogue.self, from: Data(("{\"plans\":[]" + extra + "}").utf8))
        }
        #expect(try cat(#","vat":"added-by-country","pricesInclusive":false"#).vatAddedAtCheckout)
        #expect(try cat(#","vat":"added-by-country""#).vatAddedAtCheckout)
        #expect(try cat(#","pricesInclusive":false"#).vatAddedAtCheckout)
        #expect(try !cat("").vatAddedAtCheckout)
        #expect(try !cat(#","pricesInclusive":true"#).vatAddedAtCheckout)
    }
}
