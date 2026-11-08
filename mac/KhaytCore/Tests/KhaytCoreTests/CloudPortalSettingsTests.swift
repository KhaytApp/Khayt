import Foundation
import Testing
@testable import KhaytCore

/// `CloudPortalSettings` against khayt-cloud's portal-settings route (#196).
struct CloudPortalSettingsTests {
    static let connection = CloudReader.Connection(url: "https://cloud.example.com", shopId: "shop_ab", storedToken: "")

    @Test("reads the choice; a missing value is on, the default")
    func reads() async throws {
        let log = CloudTeamTests.Log()
        let off = try await CloudPortalSettings.get(Self.connection, token: "tok", fetch: CloudTeamTests.answering(
            200, #"{"crossShop":false,"updatedAt":"2026-11-07T10:00:00Z"}"#, log: log))
        #expect(off.crossShop == false && off.updatedAt == "2026-11-07T10:00:00Z")
        let r = try #require(log.requests.first)
        #expect(r.httpMethod == "GET" && r.url?.path == "/v1/shops/shop_ab/portal-settings")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(try await CloudPortalSettings.get(Self.connection, token: "t",
                                                  fetch: CloudTeamTests.answering(200, "{}")).crossShop == true)
        #expect(try await CloudPortalSettings.get(Self.connection, token: "t",
                                                  fetch: CloudTeamTests.answering(200, "null")).crossShop == true)
    }

    @Test("a save sends a boolean, and a viewer is refused with the reason role")
    func saves() async throws {
        let log = CloudTeamTests.Log()
        let back = try await CloudPortalSettings.put(crossShop: false, Self.connection, token: "t",
                                                     fetch: CloudTeamTests.answering(200, #"{"crossShop":false}"#, log: log))
        #expect(back.crossShop == false && log.requests[0].httpMethod == "PUT")
        let sent = try JSONSerialization.jsonObject(with: log.requests[0].httpBody!) as? [String: Bool]
        #expect(sent == ["crossShop": false])
        do {
            try await CloudPortalSettings.put(crossShop: true, Self.connection, token: "t",
                                              fetch: CloudTeamTests.answering(403, #"{"reason":"role"}"#))
            Issue.record("should have thrown")
        } catch let r as CloudPortalSettings.Refusal {
            #expect(r.status == 403 && r.reason == "role")
        }
    }
}
