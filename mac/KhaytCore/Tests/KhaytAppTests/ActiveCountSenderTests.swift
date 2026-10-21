import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Mac's active-install sender. No test reaches the network.
@Suite(.serialized) @MainActor
struct ActiveCountSenderTests {

    final class Rig {
        let sender: ActiveCountSender
        var requests: [URLRequest] = []
        var status = 200
        var clock = ActiveCountTestsClock.at("2026-10-21")

        @MainActor init() {
            sender = ActiveCountSender(defaults: UserDefaults(suiteName: "khayt.active.\(UUID().uuidString)")!)
            sender.sendsFromThisBuild = true
            sender.ready = true
            sender.appVersion = "4.0.0-alpha.86"
            let box = Box(rig: self)
            sender.now = { [unowned self] in self.clock }
            sender.fetch = { try await box.answer($0) }
        }

        final class Box: @unchecked Sendable {
            weak var rig: Rig?
            init(rig: Rig) { self.rig = rig }
            func answer(_ request: URLRequest) async throws -> (Data, URLResponse) {
                try await MainActor.run {
                    guard let rig else { throw URLError(.cancelled) }
                    rig.requests.append(request)
                    if rig.status == 0 { throw URLError(.notConnectedToInternet) }
                    return (Data(#"{"counted":true}"#.utf8),
                            HTTPURLResponse(url: request.url!, statusCode: rig.status, httpVersion: nil, headerFields: nil)!)
                }
            }
        }

        func body(_ i: Int) throws -> [String: Any] {
            let data = try #require(requests[i].httpBody)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    @Test("on by default: one ping a day, first ever, then not")
    func daily() async throws {
        let rig = Rig()
        #expect(rig.sender.enabled)
        #expect(await rig.sender.tick() == "counted")
        #expect(await rig.sender.tick() == "done")
        #expect(rig.requests.count == 1)
        let first = try rig.body(0)
        #expect(first["platform"] as? String == "mac" && first["channel"] as? String == "alpha")
        #expect(first["firstEver"] as? Bool == true)
        #expect(rig.requests[0].url == ActiveCount.endpoint && rig.requests[0].httpMethod == "POST")
        #expect(rig.requests[0].value(forHTTPHeaderField: "Authorization") == nil)

        rig.clock = ActiveCountTestsClock.at("2026-10-22")
        #expect(await rig.sender.tick() == "counted")
        let second = try rig.body(1)
        #expect(second["firstEver"] as? Bool == false && second["firstThisWeek"] as? Bool == false)
    }

    @Test("a failed send waits an hour and sends the same flags")
    func retry() async throws {
        let rig = Rig()
        rig.status = 404
        #expect(await rig.sender.tick() == "retry")
        #expect(await rig.sender.tick() == "waiting")
        #expect(rig.sender.state == ActiveCount.State())
        rig.status = 200
        rig.clock = rig.clock.addingTimeInterval(3601)
        #expect(await rig.sender.tick() == "counted")
        #expect(try rig.body(1)["firstEver"] as? Bool == true)
    }

    @Test("a 422 finishes the day without counting it")
    func refused() async {
        let rig = Rig()
        rig.status = 422
        #expect(await rig.sender.tick() == "refused")
        #expect(await rig.sender.tick() == "done")
        #expect(rig.sender.state.lastCounted == nil)
    }

    @Test("switched off sends nothing and keeps the days")
    func off() async {
        let rig = Rig()
        #expect(await rig.sender.tick() == "counted")
        let kept = rig.sender.state
        rig.sender.enabled = false
        rig.clock = ActiveCountTestsClock.at("2026-11-02")
        #expect(await rig.sender.tick() == "off")
        #expect(rig.requests.count == 1 && rig.sender.state == kept)
        // Back on: not a new install.
        rig.sender.enabled = true
        #expect(await rig.sender.tick() == "counted")
        #expect(true == (rig.requests.count == 2))
    }

    @Test("a development build and an unknown version send nothing")
    func neverSends() async {
        let rig = Rig()
        rig.sender.sendsFromThisBuild = false
        #expect(await rig.sender.tick() == "development-build")
        rig.sender.sendsFromThisBuild = true
        rig.sender.appVersion = "0.0.0-dev"
        #expect(await rig.sender.tick() == "version")
        #expect(rig.requests.isEmpty)
    }

    @Test("held: nothing is sent until the policy and the route are live")
    func held() async {
        let rig = Rig()
        rig.sender.ready = false
        #expect(await rig.sender.tick() == "held")
        #expect(rig.requests.isEmpty && rig.sender.state == ActiveCount.State())
        #expect(!ActiveCountSender.READY, "flip READY only once khaytapp.com/privacy #active-count is live")
    }

    @Test("the switch is remembered on this Mac")
    func remembered() {
        let suite = "khayt.active.\(UUID().uuidString)"
        ActiveCountSender(defaults: UserDefaults(suiteName: suite)!).enabled = false
        #expect(!ActiveCountSender(defaults: UserDefaults(suiteName: suite)!).enabled)
    }
}

enum ActiveCountTestsClock {
    static func at(_ day: String) -> Date {
        let p = day.split(separator: "-").map { Int($0)! }
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
    }
}
