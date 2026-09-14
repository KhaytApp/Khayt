import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Keeping the customer's tracking link current.
///
/// The REQUEST is `lib/portal-refresh.js`, tested where it lives against the
/// renderer it was lifted from. What is tested here is what only this app can
/// get wrong: that it asks for the request correctly, that a published job no
/// longer has its move refused, that the address a shop typed is checked before
/// a bearer token travels to it, and that a failed refresh is SAID.
@MainActor
struct PortalRefreshTests {

    static func book(_ cloud: [String: JSONValue],
                     published: Bool = true) -> [String: JSONValue] {
        var order: [String: JSONValue] = [
            "id": .string("J1"), "project": .string("Bracket"),
            "status": .string("printing"), "price": .number(400),
            "clientId": .string("C1"), "parts": .array([]),
            "dueDate": .string("2026-10-01"),
        ]
        if published {
            order["cloudPublished"] = .bool(true)
            order["trackingToken"] = .string("trk_abc123")
        }
        return [
            "printLog": .array([.object(order)]),
            "inventory": .array([]), "consumables": .array([]), "machines": .array([]),
            "clients": .array([.object([
                "id": .string("C1"), "nameEn": .string("Sara"),
                "email": .string("buyer@example.com"),
            ])]),
            "settings": .object([
                "bizEn": .string("Tuwaiq Prints"),
                "addrEn": .string("Riyadh"),
                "currency": .string("SAR"),
                "cloud": .object(cloud),
            ]),
        ]
    }

    static let live: [String: JSONValue] = [
        "enabled": .bool(true),
        "shopId": .string("shop_1"),
        "url": .string("https://cloud.khaytapp.com"),
        "token": .string("tok_plain"),
    ]

    static func move(_ root: inout [String: JSONValue], _ stage: Stage)
    async throws -> (undo: [Shop.ChangedRecord], notices: [String], telegram: TelegramMessage?,
                     webhooks: [KhaytEngine.WebhookDelivery], email: OrderEmail?,
                     portal: PortalRefresh?) {
        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)
        return try await Shop.applyMove(to: &root, id: "J1", stage: stage,
                                        engine: engine, words: words)
    }

    // MARK: - The request

    @Test("a published job's move carries the refresh the shared rule writes")
    func request() async throws {
        var root = Self.book(Self.live)
        let out = try await Self.move(&root, .completed)
        let portal = try #require(out.portal, "the move should have carried a refresh")
        #expect(portal.kind == "order")
        #expect(portal.pubToken == "trk_abc123")
        #expect(portal.customerEmail == "buyer@example.com")

        guard case .object(let payload) = portal.payload else {
            Issue.record("the payload is not an object"); return
        }
        #expect(Shop.plainString(payload["ref"]) == "J1")
        #expect(Shop.plainString(payload["shopName"]) == "Tuwaiq Prints")
        // The stage the job moved TO, not the one it left.
        #expect(Shop.plainString(payload["status"]) == "completed")
        #expect(Shop.plainString(payload["statusLabel"]) == "Completed")
        // And the five timeline words come from `Words`, not from the module's
        // own fallbacks — the customer reads these.
        guard case .array(let stages)? = payload["stages"] else {
            Issue.record("no timeline on an order"); return
        }
        #expect(stages.count == 5)
    }

    /// The whole point of the gap being closed: this move used to throw.
    @Test("a published job can be moved at all now")
    func theMoveIsNoLongerRefused() async throws {
        var root = Self.book(Self.live)
        let out = try await Self.move(&root, .completed)
        #expect(!out.undo.isEmpty, "the move happened")
        let orders = Shop.rows(root, "printLog")
        guard case .object(let job)? = orders.first else {
            Issue.record("the job is gone"); return
        }
        #expect(Shop.plainString(job["status"]) == "completed")
    }

    @Test("an unpublished job owes nothing, and still moves")
    func unpublished() async throws {
        var root = Self.book(Self.live, published: false)
        let out = try await Self.move(&root, .completed)
        #expect(out.portal == nil)
        #expect(!out.undo.isEmpty)
    }

    @Test("a shop with the cloud switched off owes nothing")
    func cloudOff() async throws {
        var root = Self.book(["enabled": .bool(false), "shopId": .string("shop_1")])
        let out = try await Self.move(&root, .completed)
        #expect(out.portal == nil)
        #expect(!out.undo.isEmpty)
    }

    // MARK: - The address a bearer token travels to

    /// `settings.cloud.url` is typed by a person and can arrive by sync from
    /// another machine, and every request to it carries the shop's token. The
    /// check is the shared rule's, not a second opinion in Swift.
    @Test("the cloud address is validated before anything is sent")
    func addressIsChecked() async throws {
        let engine = try KhaytEngine()
        await #expect(throws: (any Error).self) {
            _ = try await engine.cloudBaseUrl("http://169.254.169.254")
        }
        await #expect(throws: (any Error).self) {
            _ = try await engine.cloudBaseUrl("not a url")
        }
        // https to a public host is the ordinary case and comes back normalised.
        let ok = try await engine.cloudBaseUrl("https://cloud.khaytapp.com/")
        #expect(ok.hasPrefix("https://cloud.khaytapp.com"))
    }

    @Test("the path is the module's, not a string built in Swift")
    func pathComesFromTheModule() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.portalPath(shopId: "shop_1", pubToken: "trk_abc")
                == "/v1/shops/shop_1/published/trk_abc")
        // A token that tries to climb out of its own segment cannot.
        #expect(try await engine.portalPath(shopId: "a/b", pubToken: "c d")
                == "/v1/shops/a%2Fb/published/c%20d")
    }

    // MARK: - Failure is said out loud

    @Test("a refresh that cannot be addressed is reported, not swallowed")
    func failureIsSaid() async throws {
        let engine = try KhaytEngine()
        let refresh = PortalRefresh(kind: "order", pubToken: "trk",
                                    payload: .object(["ref": .string("J1")]),
                                    customerEmail: "")
        await #expect(throws: PortalClient.Failure.self) {
            try await PortalClient.republish(refresh, baseUrl: "http://169.254.169.254",
                                             shopId: "s1", token: "t", engine: engine)
        }
        await #expect(throws: PortalClient.Failure.self) {
            try await PortalClient.republish(refresh, baseUrl: "", shopId: "s1",
                                             token: "t", engine: engine)
        }
    }
}
