import Foundation
import Testing
@testable import KhaytApp

/// What the 404 offers, against what the server answers.
///
/// The 404 body used to recite `lan-pages`' endpoint list, which is the NODE
/// server's: sixteen routes, eleven of which answer 404 here. That is wrong
/// twice over, and the second way is the one that matters. The 404 is served
/// before any gate, so a stranger on the shop's Wi‑Fi who mistyped a path was
/// handed the shop's whole integration surface — `/api/webhook/salla`,
/// `/api/webhook/zid`, `/api/webhook/smsa`, `/api/webhook/aramex`,
/// `/api/webhook/spl` — telling them which storefront and which courier to go
/// and look at. None of those exists on this host.
///
/// A list kept by hand drifts, so this asks the running server for every line
/// of it.
@MainActor
struct LanEndpointsTests {

    /// The four that only take a POST. Asked with a GET they fall to the 404,
    /// exactly as they do on the Node server — neither host answers 405, and
    /// making this one do so would be the two servers disagreeing, which is the
    /// thing `LanServerTests` exists to prevent.
    static let writes: Set<String> = ["/api/store/deltas", "/api/intake",
                                      "/api/intake/estimate", "/api/survey"]

    @Test("every endpoint the 404 advertises is one this server routes")
    func advertisedEndpointsAnswer() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        for endpoint in LanServer.endpoints where !endpoint.contains(":") {
            let method = Self.writes.contains(endpoint) ? "POST" : "GET"
            let reply = try await bench.get(endpoint, method: method)
            // Anything but 404: a PIN refusal, a redirect, a bad-request and a
            // page are all the route existing. What is proven is that the
            // server does not offer a caller something it then denies having.
            #expect(reply.status != 404,
                    Comment(rawValue: "the 404 offers \(endpoint), which answers 404 to \(method)"))
        }
    }

    /// The parameterised ones are checked at the router instead: a real id
    /// belongs to a real order, and a missing order is a legitimate 404 that
    /// would make this test pass for the wrong reason.
    @Test("the endpoints with an id in them are shapes the router recognises")
    func parameterisedEndpointsParse() {
        for endpoint in LanServer.endpoints where endpoint.contains(":") {
            let concrete = endpoint.replacingOccurrences(of: ":id", with: "abc123")
            let recognised = LanServer.trackingPath(concrete) != nil
                || LanServer.quotePath(concrete) != nil
                || LanServer.approvePath(concrete) != nil
            #expect(recognised,
                    Comment(rawValue: "the 404 offers \(endpoint), which no route parses"))
        }
    }

    /// And the other direction: the list must not have quietly become the Node
    /// server's again.
    @Test("the 404 does not recite the other server's routes")
    func noForeignRoutes() async throws {
        let foreign = ["/api/clients", "/api/machines", "/api/inventory", "/api/orders",
                       "/api/waiting-list", "/api/webhook/salla", "/api/webhook/zid",
                       "/api/webhook/smsa", "/api/webhook/aramex", "/api/webhook/spl",
                       "/api/webhook/printer/:machineId"]
        for route in foreign {
            #expect(!LanServer.endpoints.contains(route),
                    Comment(rawValue: "\(route) is advertised here and served by the other app"))
        }

        // Proven through the wire as well as through the constant, because the
        // body is built by the shared rule and could ignore what it is passed.
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        let reply = try await bench.get("/api/definitely-not-a-route")
        #expect(reply.status == 404)
        for route in foreign {
            #expect(!reply.text.contains(route),
                    Comment(rawValue: "the 404 body still names \(route)"))
        }
        // It still says what IS here — an empty list would pass every check above.
        #expect(reply.text.contains("/api/status"), "the 404 stopped saying what is here")
        #expect(reply.text.contains("/intake"), "the 404 stopped saying what is here")
    }
}
