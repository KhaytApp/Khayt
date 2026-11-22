import Foundation
import Testing
@testable import KhaytCore

/// `CloudPlans` against khayt-cloud's `GET /v1/plans`, `GET /v1/billing/me`
/// and `POST /v1/shops/{id}/plan`, in the shapes the live service answered
/// on 2026-10-24.
struct CloudPlansTests {

    static let catalogue = Data("""
    {"plans":[
     {"name":"free","label":"Free","priceSar":0,"priceUsd":null,"annualSar":null,"annualUsd":null,"period":"month","limits":{"maxStoreBytes":0,"maxVaultBytes":2147483648,"maxActiveLinks":0}},
     {"name":"maker","label":"Maker","priceSar":25,"priceUsd":7,"annualSar":250,"annualUsd":70,"period":"month","limits":{"maxStoreBytes":0,"maxVaultBytes":161061273600,"maxActiveLinks":50,"maxSeats":3}},
     {"name":"creator","label":"Creator","priceSar":65,"priceUsd":null,"period":"month","limits":{"maxVaultBytes":429496729600,"maxActiveLinks":200,"publishing":true}},
     {"name":"odd"}],
     "defaultPlan":"free","pricesInclusive":true,"beta":{"freeUpgrades":false,"endsAt":null,"graceDays":30}}
    """.utf8)

    static let connection = CloudReader.Connection(url: "https://cloud.example.com", shopId: "shop_ab", storedToken: "")

    final class Log: @unchecked Sendable { var requests: [URLRequest] = [] }

    static func answering(_ code: Int, _ body: String, log: Log = Log()) -> S3.Fetch {
        { r in
            log.requests.append(r)
            return (Data(body.utf8), HTTPURLResponse(url: r.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("the catalogue reads as the cloud sends it, a missing price is nil, a bare plan still reads")
    func catalogueReads() async throws {
        let log = Log()
        let c = try await CloudPlans.catalogue(baseURL: "https://cloud.example.com/",
                                               fetch: Self.answering(200, String(decoding: Self.catalogue, as: UTF8.self), log: log))
        #expect(log.requests.first?.url?.absoluteString == "https://cloud.example.com/v1/plans")
        #expect(log.requests.first?.value(forHTTPHeaderField: "Authorization") == nil, "the catalogue is public")
        #expect(c.plans.map(\.name) == ["free", "maker", "creator", "odd"])
        #expect(c.plans[0].priceUsd == nil && c.plans[1].annualUsd == 70)
        #expect(c.plans[2].limits.publishing == true && c.plans[1].limits.maxSeats == 3)
        #expect(c.plans[3].label == "odd" && c.plans[3].limits == .init())
        #expect(c.beta?.freeUpgrades == false && c.beta?.graceDays == 30 && c.freePlan == "free")
    }

    @Test("riyals for a SAR shop, dollars elsewhere when the plan has them, riyals when it has not")
    func priceToShow() throws {
        let c = try JSONDecoder().decode(CloudPlans.Catalogue.self, from: Self.catalogue)
        #expect(CloudPlans.price(c.plans[1], currency: "SAR")! == (25, "SAR"))
        #expect(CloudPlans.price(c.plans[1], currency: "usd")! == (7, "USD"))
        #expect(CloudPlans.price(c.plans[2], currency: "EUR")! == (65, "SAR"))
        #expect(CloudPlans.price(c.plans[3], currency: "SAR") == nil)
        #expect(CloudPlans.isUpgrade(c.plans[2], from: c.plans[1]))
        #expect(!CloudPlans.isUpgrade(c.plans[0], from: c.plans[2]))
    }

    @Test("billing/me is asked with the shop and the token; the beta block reads")
    func mine() async throws {
        let log = Log()
        let m = try await CloudPlans.mine(Self.connection, token: "tok", fetch: Self.answering(200, """
        {"billingEnabled":true,"plan":"creator","label":"Creator","status":"trialing","active":true,"until":null,
         "priceSar":65,"period":"month","beta":{"upgrade":true,"endsAt":null,"graceEndsAt":null,"graceDays":30}}
        """, log: log))
        let r = try #require(log.requests.first)
        #expect(r.url?.absoluteString == "https://cloud.example.com/v1/billing/me?shopId=shop_ab")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(m.plan == "creator" && m.onFreeUpgrade)
    }

    @Test("choosing posts the plan to the shop's route; a refusal keeps its reason")
    func choose() async throws {
        let log = Log()
        let m = try await CloudPlans.choose("maker", Self.connection, token: "tok",
                                            fetch: Self.answering(200, #"{"plan":"maker","active":true}"#, log: log))
        let r = try #require(log.requests.first)
        #expect(r.httpMethod == "POST" && r.url?.path == "/v1/shops/shop_ab/plan")
        #expect(try JSONSerialization.jsonObject(with: r.httpBody!) as? [String: String] == ["plan": "maker"])
        #expect(m.plan == "maker")
        for (code, reason) in [(403, "owner-only"), (403, "upgrades-closed"), (409, "paid-plan"), (403, "beta-over")] {
            do {
                _ = try await CloudPlans.choose("studio", Self.connection, token: "tok",
                                                fetch: Self.answering(code, #"{"error":"no","reason":"\#(reason)"}"#))
                Issue.record("accepted \(reason)")
            } catch let e as CloudPlans.Refusal {
                #expect(e.status == code && e.reason == reason)
            }
        }
    }

    @Test("an http address is refused before the token is sent")
    func httpsOnly() async {
        let plain = CloudReader.Connection(url: "http://cloud.example.com", shopId: "shop_ab", storedToken: "")
        await #expect(throws: CloudReader.Failure.self) {
            _ = try await CloudPlans.mine(plain, token: "tok", fetch: Self.answering(200, "{}"))
        }
    }
}
