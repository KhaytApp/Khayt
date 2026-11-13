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
        var reply = #"{"ok":true,"tokens":1,"sent":1,"dropped":0,"failed":0,"apns":true}"#
        var offline = false
        func fetch(_ r: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(r)
            if offline { throw URLError(.notConnectedToInternet) }
            return (Data(reply.utf8),
                    HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    static func status(_ state: String, progress: Int = 42, left: Double? = 3600) throws -> KhaytEngine.PrinterStatus {
        var o: [String: Any] = ["state": state, "progress": progress, "filename": "bracket.gcode", "type": "moonraker"]
        if let left { o["timeRemaining"] = left }
        return try JSONDecoder().decode(KhaytEngine.PrinterStatus.self,
                                        from: JSONSerialization.data(withJSONObject: o))
    }

    static func shop(cloud: [String: JSONValue]?, optedIn: Bool = true) async -> (Shop, Recorder) {
        let shop = Shop()
        await shop.load(.sample)
        var settings = shop.settingsDict
        if let cloud { settings["cloud"] = .object(cloud) } else { settings["cloud"] = nil }
        await shop.useLockFixture(operators: shop.operatorRows, settings: settings)
        let rec = Recorder()
        shop.liveActivityFetch = rec.fetch
        shop.liveActivitiesOptedIn = { optedIn }
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
        for _ in 0..<60_000 where rec.requests.count < count { try? await Task.sleep(for: .milliseconds(10)) }
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
        // Five minutes, not the print's finish an hour away: a stream that
        // stops goes stale on the phone within that (push review M1).
        #expect(start["staleAt"] == .string("2026-08-29T10:45:00Z"))
        // When it happened on the Mac, in Unix seconds (push review C3).
        #expect(start["at"] == .number(1_788_000_000))

        let bare = LiveActivityPlan.State(phase: .paused, job: nil, progress: 5, startedAt: nil, endsAt: nil)
        guard case .object(let b)? = LiveActivityPush.body(.update(machineId: "m1", bare), now: Self.now)["state"] else {
            Issue.record("no state"); return
        }
        #expect(b["job"] == nil && b["startedAt"] == nil && b["endsAt"] == nil, "a missing value was sent as null")

        let end = LiveActivityPush.body(.end(machineId: "m1", s), now: Self.now)
        #expect(end["dismissAt"] == .string("2026-08-29T11:10:00Z"))
        #expect(end["machineName"] == nil)
    }

    // ── The push review's Mac fixes (Nov 13) ─────────────────────────────

    @Test("every start and update carries a stale time, and an unchanged print is sent again before it")
    func staleAndRefresh() {
        let none = LiveActivityPlan.State(phase: .printing, job: "a.gcode", progress: 10, startedAt: Self.now, endsAt: nil)
        #expect(LiveActivityPlan.staleAt(none, now: Self.now) == Self.now.addingTimeInterval(300))
        var soon = none; soon.endsAt = Self.now.addingTimeInterval(60)
        #expect(LiveActivityPlan.staleAt(soon, now: Self.now) == Self.now.addingTimeInterval(60))
        let body = LiveActivityPush.body(.update(machineId: "m1", none), now: Self.now)
        #expect(body["staleAt"] == .string("2026-08-29T10:45:00Z"), "an update with no finish has no staleAt")

        let reading = LiveActivityPlan.Reading(name: "U1", state: "printing", progress: 10, filename: "a.gcode",
                                               timeRemaining: nil, error: nil)
        let running = ["m1": none]
        #expect(LiveActivityPlan.refresh(machineId: "m1", reading: reading, running: running,
                                         lastSent: ["m1": Self.now], now: Self.now.addingTimeInterval(200)) == nil)
        #expect(LiveActivityPlan.refresh(machineId: "m1", reading: reading, running: running,
                                         lastSent: ["m1": Self.now], now: Self.now.addingTimeInterval(240)) != nil)
        var idle = reading; idle.state = "standby"
        #expect(LiveActivityPlan.refresh(machineId: "m1", reading: idle, running: running,
                                         lastSent: ["m1": Self.now], now: Self.now.addingTimeInterval(600)) == nil,
                "a print that stopped is an end, not a refresh")
    }

    @Test("an end heard late carries the finish the printer predicted, not the moment it was heard")
    func lateEnd() {
        let was = LiveActivityPlan.State(phase: .printing, job: "a", progress: 90, startedAt: Self.now,
                                         endsAt: Self.now.addingTimeInterval(600))
        // The Mac slept for six hours.
        #expect(LiveActivityPlan.endedAt(was, now: Self.now.addingTimeInterval(6 * 3600))
                == Self.now.addingTimeInterval(600))
        // Heard ending before its prediction: now.
        #expect(LiveActivityPlan.endedAt(was, now: Self.now.addingTimeInterval(300)) == Self.now.addingTimeInterval(300))
        var unknown = was; unknown.endsAt = nil
        #expect(LiveActivityPlan.endedAt(unknown, now: Self.now.addingTimeInterval(9000)) == Self.now.addingTimeInterval(9000))
    }

    @Test("what was running survives a relaunch, for this shop only, and not past a day")
    func runningIsKept() throws {
        let defaults = try #require(UserDefaults(suiteName: "khayt.test.liveActivity.\(UUID().uuidString)"))
        let s = LiveActivityPlan.State(phase: .paused, job: "a.gcode", progress: 55,
                                       startedAt: Self.now, endsAt: Self.now.addingTimeInterval(900))
        LiveActivityPush.keep(["m1": s], shopId: "S1", defaults: defaults)
        #expect(LiveActivityPush.restore(shopId: "S1", now: Self.now.addingTimeInterval(60), defaults: defaults) == ["m1": s])
        #expect(LiveActivityPush.restore(shopId: "S2", now: Self.now, defaults: defaults).isEmpty, "another shop's")
        #expect(LiveActivityPush.restore(shopId: "S1", now: Self.now.addingTimeInterval(25 * 3600), defaults: defaults).isEmpty,
                "a day-old print is not running")
        // The sample book never keeps or reads it (`liveActivityMemory`).
        let code = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/KhaytApp/LiveActivityPush.swift"), encoding: .utf8)
        #expect(code.contains("source.build == nil ? [:] : LiveActivityPush.restore"))
        #expect(code.contains("if source.build != nil { LiveActivityPush.keep"))
    }

    @Test("one printer's failure does not silence another, and an end is never held behind a backoff")
    func perPrinterBackoff() async throws {
        let (shop, rec) = await Self.shop(cloud: Self.connected)
        let two = Array(shop.machines.filter(\.inService).prefix(2))
        try #require(two.count == 2)
        rec.status = 500
        shop.liveActivityHeard(two[0], status: try Self.status("printing"), now: Self.now)
        await Self.settle(rec, count: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(shop.liveActivities.quietFor[two[0].id] != nil && shop.liveActivities.quietUntil == nil)
        // The other printer is asked at once.
        rec.status = 200
        shop.liveActivityHeard(two[1], status: try Self.status("printing"), now: Self.now.addingTimeInterval(1))
        await Self.settle(rec, count: 2)
        #expect(rec.requests.count == 2)

        // The first printer's start goes through after its wait; then it finishes
        // during a backoff caused by a failed update, and the end still goes.
        shop.liveActivityHeard(two[0], status: try Self.status("printing"), now: Self.now.addingTimeInterval(100))
        await Self.settle(rec, count: 3)
        try await Task.sleep(for: .milliseconds(50))
        rec.status = 500
        shop.liveActivityHeard(two[0], status: try Self.status("printing", progress: 60), now: Self.now.addingTimeInterval(200))
        await Self.settle(rec, count: 4)
        try await Task.sleep(for: .milliseconds(50))
        #expect(shop.liveActivities.quietFor[two[0].id] != nil)
        shop.liveActivityHeard(two[0], status: try Self.status("complete", progress: 100, left: nil),
                               now: Self.now.addingTimeInterval(201))
        await Self.settle(rec, count: 5)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rec.requests.count == 5, "the end waited behind the update's backoff")
        // That end failed too: tried again after `endRetry`, not before, and not after half an hour.
        shop.liveActivityHeard(two[0], status: try Self.status("complete", progress: 100, left: nil),
                               now: Self.now.addingTimeInterval(205))
        try await Task.sleep(for: .milliseconds(80))
        #expect(rec.requests.count == 5)
        rec.status = 200
        shop.liveActivityHeard(two[0], status: try Self.status("complete", progress: 100, left: nil),
                               now: Self.now.addingTimeInterval(201 + LiveActivityPush.endRetry))
        await Self.settle(rec, count: 6)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rec.requests.count == 6)
        #expect(shop.liveActivities.running[two[0].id] == nil, "ended")
    }

    @Test("unlocking the cloud sends what was changed while it was locked, at once")
    func unlockSends() throws {
        let code = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/KhaytApp/Shop+Cloud.swift"), encoding: .utf8)
        // Both ways a key arrives: remembered at launch, and typed.
        let restore = try #require(code.range(of: "func restoreCloudKey()"))
        let after = code[restore.upperBound...]
        let end = try #require(after.range(of: "\n    }\n"))
        #expect(after[..<end.lowerBound].contains("bookChanged()"), "restoreCloudKey does not send what was waiting")
        #expect(code.contains("if case .locked = syncStatus { syncStatus = .idle }\n            bookChanged()"))
    }

    @Test("a print-finished alert that could not go is held, bounded, and in order; a refusal is not")
    func heldAlerts() async {
        #expect(Shop.worthKeeping(nil) && Shop.worthKeeping(.failed(0)) && Shop.worthKeeping(.failed(503)))
        #expect(!Shop.worthKeeping(.sent) && !Shop.worthKeeping(.rateLimited) && !Shop.worthKeeping(.readOnly)
                && !Shop.worthKeeping(.notOffered) && !Shop.worthKeeping(.tooLarge))
        let shop = Shop()
        for i in 0..<25 {
            shop.queueEvent(.init(kind: "print-finished", at: "2026-11-13T10:\(String(format: "%02d", i)):00Z",
                                  payload: ["n": .number(Double(i))], since: Self.now))
        }
        #expect(shop.pendingEvents.count == Shop.pendingLimit)
        #expect(shop.pendingEvents.first?.payload["n"] == .number(5), "the oldest went first")
        let again = shop.pendingEvents[0]
        shop.queueEvent(again)
        #expect(shop.pendingEvents.count == Shop.pendingLimit, "the same alert is held once")
        // Six hours on, they are not news: dropped, not sent (the cloud is locked here anyway).
        shop.flushPendingEvents(now: Self.now.addingTimeInterval(Shop.pendingFor + 1))
        #expect(shop.pendingEvents.isEmpty)
    }

    @Test("an event's id is the same on every attempt, different for another print, and names nothing")
    func eventIds() {
        let ended = FinishCamera.Ended(machineId: "M1", machineName: "Baby U1", orderId: "ORD-01024", outcome: "finished",
                                       durationS: 3600, photoTaken: false, filename: "lantern.gcode")
        let a = ShopEventPublisher.printFinishedId(ended, at: "2026-11-13T10:20:00Z")
        #expect(a == ShopEventPublisher.printFinishedId(ended, at: "2026-11-13T10:20:00Z"), "a retry is the same event")
        #expect(a != ShopEventPublisher.printFinishedId(ended, at: "2026-11-13T11:11:00Z"), "the next print is not")
        #expect(a.count == 32 && a.allSatisfy(\.isHexDigit))
        #expect(!a.contains("lantern") && !a.contains("ORD"))
    }

    @Test("the finish memory survives a relaunch for its own book, and the alert carries when the print ended")
    func finishMemoryKept() async throws {
        let defaults = try #require(UserDefaults(suiteName: "khayt.test.finishMemo.\(UUID().uuidString)"))
        let engine = try KhaytEngine()
        let camera = FinishCamera()
        camera.restore(book: "/books/a.json", defaults: defaults)
        let printing: JSONValue = .object(["state": .string("printing"), "progress": .number(90),
                                           "filename": .string("a.gcode"), "timeRemaining": .number(600)])
        _ = await camera.observe("M1", status: printing, engine: engine)
        let predicted = try #require(camera.predictedEnd["M1"])

        // Relaunched: a new camera for the same book remembers the print.
        let again = FinishCamera()
        again.restore(book: "/books/a.json", defaults: defaults)
        #expect(again.remembers("M1"))
        #expect(again.predictedEnd["M1"] == predicted)
        // Another book does not.
        let other = FinishCamera()
        other.restore(book: "/books/b.json", defaults: defaults)
        #expect(!other.remembers("M1"))
        // The print ended while the app was closed: an edge, at the predicted finish.
        let idle: JSONValue = .object(["state": .string("complete"), "progress": .number(100), "filename": .string("a.gcode")])
        let edge = await again.observe("M1", status: idle, engine: engine)
        #expect(edge != nil, "a print that ended while the app was closed still has its end")
        #expect(again.finishedAt("M1", now: predicted.addingTimeInterval(3600)) == predicted)
        #expect(again.finishedAt("M1", now: predicted.addingTimeInterval(-60)) == predicted.addingTimeInterval(-60))
    }

    @Test("the job's name goes in place of the file name when given; the file name otherwise")
    func jobTitle() {
        let s = LiveActivityPlan.State(phase: .printing, job: "plate_1.gcode.3mf", progress: 1, startedAt: nil, endsAt: nil)
        func job(_ b: [String: JSONValue]) -> JSONValue? { if case .object(let st)? = b["state"] { return st["job"] }; return nil }
        #expect(job(LiveActivityPush.body(.update(machineId: "m1", s), now: Self.now, jobTitle: "Museum replica")) == .string("Museum replica"))
        #expect(job(LiveActivityPush.body(.update(machineId: "m1", s), now: Self.now, jobTitle: nil)) == .string("plate_1.gcode.3mf"))
        #expect(job(LiveActivityPush.body(.update(machineId: "m1", s), now: Self.now, jobTitle: "")) == .string("plate_1.gcode.3mf"))
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

    // MARK: alpha.63 review

    @Test("not opted in on this Mac: nothing is sent, connected or not — and the opt-in is OFF by default")
    func optIn() async throws {
        let (shop, rec) = await Self.shop(cloud: Self.connected, optedIn: false)
        let machine = try #require(shop.machines.first)
        shop.liveActivityHeard(machine, status: try Self.status("printing"), now: Self.now)
        try await Task.sleep(for: .milliseconds(200))
        #expect(rec.requests.isEmpty)
        // The real seam reads a key nobody has written as off.
        let fresh = UserDefaults(suiteName: "khayt.la.\(UUID().uuidString)")!
        #expect(fresh.bool(forKey: LiveActivityPush.optInKey) == false)
        #expect(LiveActivityPush.optInKey == "mac.liveActivities")
    }

    @Test("a 200 with no phones goes quiet: updates and ends are not posted, a start asks again after ten minutes")
    func noPhones() async throws {
        let (shop, rec) = await Self.shop(cloud: Self.connected)
        let machine = try #require(shop.machines.first)
        rec.reply = #"{"ok":true,"tokens":0,"sent":0,"dropped":0,"failed":0,"apns":true}"#
        shop.liveActivityHeard(machine, status: try Self.status("printing"), now: Self.now)
        await Self.settle(rec, count: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(shop.liveActivities.noPhonesSince == Self.now)
        // The print moves and ends: nothing posted, but the plan keeps up.
        shop.liveActivityHeard(machine, status: try Self.status("printing", progress: 60), now: Self.now.addingTimeInterval(60))
        shop.liveActivityHeard(machine, status: try Self.status("standby", left: nil), now: Self.now.addingTimeInterval(120))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rec.requests.count == 1)
        #expect(shop.liveActivities.running[machine.id] == nil, "the ended print is still remembered as running")
        // A new print inside ten minutes: still quiet.
        shop.liveActivityHeard(machine, status: try Self.status("printing"), now: Self.now.addingTimeInterval(300))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rec.requests.count == 1)
        // A new print after them: asked again, and a phone is there now.
        shop.liveActivityHeard(machine, status: try Self.status("standby", left: nil), now: Self.now.addingTimeInterval(400))
        rec.reply = #"{"ok":true,"tokens":1}"#
        shop.liveActivityHeard(machine, status: try Self.status("printing"), now: Self.now.addingTimeInterval(700))
        await Self.settle(rec, count: 2)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rec.requests.count == 2)
        #expect(try Self.body(try #require(rec.requests.last))["event"] as? String == "start")
        #expect(shop.liveActivities.noPhonesSince == nil)
    }

    @Test("401 is quiet for an hour; 400, 413, 5xx and no answer back off, growing, capped")
    func backsOff() async throws {
        #expect(LiveActivityPush.backoff(1) == 30)
        #expect(LiveActivityPush.backoff(2) == 60)
        #expect(LiveActivityPush.backoff(3) == 120)
        #expect(LiveActivityPush.backoff(40) == 1800)

        let (shop, rec) = await Self.shop(cloud: Self.connected)
        let machine = try #require(shop.machines.first)
        rec.status = 401
        shop.liveActivityHeard(machine, status: try Self.status("printing"), now: Self.now)
        await Self.settle(rec, count: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(shop.liveActivities.quietUntil == Self.now.addingTimeInterval(3600))

        let (other, rec2) = await Self.shop(cloud: Self.connected)
        let m2 = try #require(other.machines.first)
        for (i, code) in [500, 413, 400].enumerated() {
            rec2.status = code
            let at = Self.now.addingTimeInterval(Double(i) * 10_000)
            other.liveActivityHeard(m2, status: try Self.status("printing"), now: at)
            await Self.settle(rec2, count: i + 1)
            try await Task.sleep(for: .milliseconds(50))
            // That printer backs off, not the shop (push review M2).
            #expect(other.liveActivities.failuresFor[m2.id] == i + 1)
            #expect(other.liveActivities.quietFor[m2.id] == at.addingTimeInterval(LiveActivityPush.backoff(i + 1)))
            #expect(other.liveActivities.quietUntil == nil)
            // Inside the wait: not asked.
            other.liveActivityHeard(m2, status: try Self.status("printing"), now: at.addingTimeInterval(1))
            try await Task.sleep(for: .milliseconds(50))
            #expect(rec2.requests.count == i + 1, "posted inside the backoff after a \(code)")
        }
        rec2.offline = true
        other.liveActivityHeard(m2, status: try Self.status("printing"), now: Self.now.addingTimeInterval(40_000))
        await Self.settle(rec2, count: 4)
        try await Task.sleep(for: .milliseconds(50))
        #expect(other.liveActivities.failuresFor[m2.id] == 4, "no answer is a failure too")
        // Taken: the count starts again.
        rec2.offline = false; rec2.status = 200
        other.liveActivityHeard(m2, status: try Self.status("printing"), now: Self.now.addingTimeInterval(50_000))
        await Self.settle(rec2, count: 5)
        try await Task.sleep(for: .milliseconds(50))
        #expect(other.liveActivities.failuresFor[m2.id] == nil)
    }

    @Test("the 200's tokens: 0 is nobody, a count is sent, a reply without one is sent")
    func tokensRead() {
        #expect(LiveActivityPush.tokens(in: Data(#"{"ok":true,"tokens":0}"#.utf8)) == 0)
        #expect(LiveActivityPush.tokens(in: Data(#"{"ok":true,"tokens":3}"#.utf8)) == 3)
        #expect(LiveActivityPush.tokens(in: Data(#"{"ok":true}"#.utf8)) == nil)
        #expect(LiveActivityPush.tokens(in: Data("not json".utf8)) == nil)
    }
}
