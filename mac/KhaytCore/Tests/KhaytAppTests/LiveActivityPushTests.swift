import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Mac's posts to `POST /v1/shops/{id}/live-activity`. Never a real
/// server: every test swaps `Shop.liveActivityFetch` for a recorder.
@MainActor
struct LiveActivityPushTests {
    static let now = Date(timeIntervalSince1970: 1_788_000_000)

    final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
        var status = 200
        func fetch(_ r: URLRequest) async throws -> URLResponse {
            requests.append(r)
            return HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
    }

    static func status(_ state: String, progress: Int = 42, left: Double? = 3600) throws -> KhaytEngine.PrinterStatus {
        var o: [String: Any] = ["state": state, "progress": progress, "filename": "bracket.gcode", "type": "moonraker"]
        if let left { o["timeRemaining"] = left }
        return try JSONDecoder().decode(KhaytEngine.PrinterStatus.self,
                                        from: JSONSerialization.data(withJSONObject: o))
    }

    static func shop(cloud: [String: JSONValue]?) async -> (Shop, Recorder) {
        let shop = Shop()
        await shop.load(.sample)
        var settings = shop.settingsDict
        if let cloud { settings["cloud"] = .object(cloud) } else { settings["cloud"] = nil }
        await shop.useLockFixture(operators: shop.operatorRows, settings: settings)
        let rec = Recorder()
        shop.liveActivityFetch = rec.fetch
        return (shop, rec)
    }

    static let connected: [String: JSONValue] = [
        "url": .string("https://cloud.example.com"), "shopId": .string("shop_1"),
        "token": .string("plain-token-for-tests"), "verified": .bool(true), "role": .string("owner"),
    ]

    static func body(_ r: URLRequest) throws -> [String: Any] {
        let data = try #require(r.httpBody)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    /// The post runs on its own task; wait for it, briefly.
    static func settle(_ rec: Recorder, count: Int) async {
        for _ in 0..<200 where rec.requests.count < count { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("the body: ISO dates, a WHOLE-number progress, job and dates left out when absent")
    func bodyShape() throws {
        let s = LiveActivityPlan.State(phase: .printing, job: "bracket.gcode", progress: 42,
                                       startedAt: Self.now, endsAt: Self.now.addingTimeInterval(3600))
        let start = LiveActivityPush.body(.start(machineId: "m1", name: "U1", s), now: Self.now)
        #expect(start["event"] == .string("start"))
        #expect(start["machineName"] == .string("U1"))
        guard case .object(let state)? = start["state"] else { Issue.record("no state"); return }
        #expect(state["progress"] == .number(42))
        let encoded = String(decoding: try JSONEncoder().encode(JSONValue.object(start)), as: UTF8.self)
        #expect(encoded.contains("\"progress\":42") && !encoded.contains("42."), Comment(rawValue: encoded))
        #expect(state["startedAt"] == .string("2026-08-29T10:40:00Z"))
        #expect(start["staleAt"] == .string("2026-08-29T11:40:00Z"))

        let bare = LiveActivityPlan.State(phase: .paused, job: nil, progress: 5, startedAt: nil, endsAt: nil)
        guard case .object(let b)? = LiveActivityPush.body(.update(machineId: "m1", bare), now: Self.now)["state"] else {
            Issue.record("no state"); return
        }
        #expect(b["job"] == nil && b["startedAt"] == nil && b["endsAt"] == nil, "a missing value was sent as null")

        let end = LiveActivityPush.body(.end(machineId: "m1", s), now: Self.now)
        #expect(end["dismissAt"] == .string("2026-08-29T11:10:00Z"))
        #expect(end["machineName"] == nil)
    }

    @Test("a printing machine posts a start to the shop's own route, with the shop token")
    func postsStart() async throws {
        let (shop, rec) = await Self.shop(cloud: Self.connected)
        let machine = try #require(shop.machines.first)
        shop.liveActivityHeard(machine, status: try Self.status("printing"), now: Self.now)
        await Self.settle(rec, count: 1)
        let request = try #require(rec.requests.first)
        #expect(request.url?.absoluteString == "https://cloud.example.com/v1/shops/shop_1/live-activity")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer plain-token-for-tests")
        let body = try Self.body(request)
        #expect(body["event"] as? String == "start")
        #expect(body["machineId"] as? String == machine.id)
        #expect((body["state"] as? [String: Any])?["progress"] as? Int == 42)
    }

    @Test("not connected to Khayt Cloud, or connected view-only: nothing is sent")
    func gated() async throws {
        let (off, offRec) = await Self.shop(cloud: nil)
        off.liveActivityHeard(try #require(off.machines.first), status: try Self.status("printing"), now: Self.now)
        var viewer = Self.connected; viewer["role"] = .string("viewer")
        let (ro, roRec) = await Self.shop(cloud: viewer)
        ro.liveActivityHeard(try #require(ro.machines.first), status: try Self.status("printing"), now: Self.now)
        try await Task.sleep(for: .milliseconds(200))
        #expect(offRec.requests.isEmpty && roRec.requests.isEmpty)
    }

    @Test("sent, then the same reading again: nothing; a 429 waits the floor; an end clears the machine")
    func memory() async throws {
        let (shop, rec) = await Self.shop(cloud: Self.connected)
        let machine = try #require(shop.machines.first)
        shop.liveActivityHeard(machine, status: try Self.status("printing"), now: Self.now)
        await Self.settle(rec, count: 1)
        try await Task.sleep(for: .milliseconds(50))
        // The same reading: nothing new to say.
        shop.liveActivityHeard(machine, status: try Self.status("printing"), now: Self.now.addingTimeInterval(20))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rec.requests.count == 1)
        // A new percent inside the 15 s floor: held, not sent.
        shop.liveActivityHeard(machine, status: try Self.status("printing", progress: 43), now: Self.now.addingTimeInterval(5))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rec.requests.count == 1)
        // After it: sent. Answered 429, the floor starts again from then.
        rec.status = 429
        shop.liveActivityHeard(machine, status: try Self.status("printing", progress: 43), now: Self.now.addingTimeInterval(30))
        await Self.settle(rec, count: 2)
        try await Task.sleep(for: .milliseconds(50))
        #expect(shop.liveActivities.lastSent[machine.id] == Self.now.addingTimeInterval(30))
        #expect(shop.liveActivities.running[machine.id]?.progress == 42, "a refused update was recorded as sent")
        // The print ends: an end, and the machine is forgotten.
        rec.status = 200
        shop.liveActivityHeard(machine, status: try Self.status("standby", left: nil), now: Self.now.addingTimeInterval(40))
        await Self.settle(rec, count: 3)
        try await Task.sleep(for: .milliseconds(50))
        let last = try #require(rec.requests.last)
        #expect(try Self.body(last)["event"] as? String == "end")
        #expect(shop.liveActivities.running[machine.id] == nil)
    }

    @Test("a 403 or 404 stops the posts for an hour rather than asking every poll")
    func quiet() async throws {
        let (shop, rec) = await Self.shop(cloud: Self.connected)
        let machine = try #require(shop.machines.first)
        rec.status = 404
        shop.liveActivityHeard(machine, status: try Self.status("printing"), now: Self.now)
        await Self.settle(rec, count: 1)
        try await Task.sleep(for: .milliseconds(50))
        shop.liveActivityHeard(machine, status: try Self.status("printing"), now: Self.now.addingTimeInterval(60))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rec.requests.count == 1)
        #expect(shop.liveActivities.quietUntil == Self.now.addingTimeInterval(3600))
    }
}
