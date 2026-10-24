import Foundation
import Testing
@testable import KhaytCore

/// `CloudTeam` against khayt-cloud's members and devices routes, through the
/// fetch seam (no credentials, no network).
struct CloudTeamTests {
    static let connection = CloudReader.Connection(url: "https://cloud.example.com", shopId: "shop_ab", storedToken: "")
    final class Log: @unchecked Sendable { var requests: [URLRequest] = [] }

    static func answering(_ code: Int, _ body: String, log: Log = Log()) -> S3.Fetch {
        { r in
            log.requests.append(r)
            return (Data(body.utf8), HTTPURLResponse(url: r.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("members and devices read as the cloud sends them, with the token and the delta header")
    func reads() async throws {
        let log = Log()
        let m = try await CloudTeam.members(Self.connection, token: "tok", fetch: Self.answering(200, """
        {"members":[{"email":"o@x.com","role":"owner","verified":true},{"email":"v@x.com","role":"viewer","verified":false}]}
        """, log: log))
        #expect(m.map(\.role) == ["owner", "viewer"] && m[1].verified == false)
        let r = try #require(log.requests.first)
        #expect(r.url?.path == "/v1/shops/shop_ab/members" && r.httpMethod == "GET")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(r.value(forHTTPHeaderField: "x-delta-capable") == "1")

        let d = try await CloudTeam.devices(Self.connection, token: "tok", fetch: Self.answering(200, """
        {"devices":[{"id":"shop","account":null,"role":"owner","createdAt":"2026-09-25T10:00:00Z","lastUsedOn":"2026-10-24","deltaCapable":true,"current":false},
                    {"id":"a1b2c3d4e5f6","account":"v@x.com","role":"viewer","createdAt":null,"lastUsedOn":null,"current":true}]}
        """))
        #expect(d[0].isShopKey && d[0].account == nil && d[0].lastUsedOn == "2026-10-24")
        #expect(!d[1].isShopKey && d[1].current == true && d[1].lastUsedOn == nil)
    }

    @Test("an invite sends the address trimmed and a role the cloud keeps; owner is never asked for")
    func invite() async throws {
        let log = Log()
        let emailed = try await CloudTeam.invite("  store@x.com ", role: "viewer", Self.connection, token: "tok",
                                                 fetch: Self.answering(200, #"{"ok":true,"emailConfigured":false}"#, log: log))
        #expect(!emailed)
        let r = try #require(log.requests.first)
        #expect(r.httpMethod == "POST" && r.url?.path == "/v1/shops/shop_ab/members/invite")
        #expect(try JSONSerialization.jsonObject(with: r.httpBody!) as? [String: String]
                == ["email": "store@x.com", "role": "viewer"])
        _ = try await CloudTeam.invite("a@x.com", role: "owner", Self.connection, token: "tok",
                                       fetch: Self.answering(200, #"{"ok":true}"#, log: log))
        #expect(try JSONSerialization.jsonObject(with: log.requests[1].httpBody!) as? [String: String]
                == ["email": "a@x.com", "role": "operator"])
    }

    @Test("remove and sign-out escape their path parts; a refusal keeps the cloud's sentence")
    func removeAndSignOut() async throws {
        let log = Log()
        try await CloudTeam.remove("a+b@x.com", Self.connection, token: "tok", fetch: Self.answering(200, "{}", log: log))
        #expect(log.requests[0].httpMethod == "DELETE")
        #expect(log.requests[0].url?.absoluteString == "https://cloud.example.com/v1/shops/shop_ab/members/a%2Bb%40x.com")
        try await CloudTeam.signOut(device: "a1b2c3d4e5f6", Self.connection, token: "tok",
                                    fetch: Self.answering(200, "{}", log: log))
        #expect(log.requests[1].url?.path == "/v1/shops/shop_ab/devices/a1b2c3d4e5f6")
        do {
            try await CloudTeam.signOut(device: "a1b2c3d4e5f6", Self.connection, token: "tok",
                                        fetch: Self.answering(403, #"{"error":"Only the owner can sign out the owner’s devices"}"#))
            Issue.record("accepted a refusal")
        } catch let e as CloudTeam.Refusal {
            #expect(e.status == 403 && e.error.hasPrefix("Only the owner"))
        }
    }
}
