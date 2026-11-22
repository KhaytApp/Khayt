import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A camera the printer does not announce, a still that has stopped changing,
/// and a print's timelapse — each against the bench Snapmaker U1's own
/// replies (test/fixtures/u1-*.json, captured read-only on 2026-10-22).
@MainActor
struct CameraDiscoveryTests {

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "test/fixtures")

    static func fixture(_ name: String) throws -> JSONValue {
        try JSONValue.decode(JSONValue.self, from: Data(contentsOf: fixtures.appending(path: name)))
    }

    static func object(_ name: String) throws -> [String: JSONValue] {
        guard case .object(let o) = try fixture(name) else { throw CocoaError(.fileReadCorruptFile) }
        return o
    }

    static let u1: JSONValue = .object(["type": .string("moonraker"), "host": .string("192.168.68.56"),
                                        "port": .number(7125)])
    static let dead: JSONValue = .object(["enabled": .bool(false),
                                          "snapshotUrl": .string("http://192.168.68.56:8080/?action=snapshot")])
    static let monitor = "http://192.168.68.56:7125/server/files/camera/monitor.jpg"

    @Test("the U1: its list is empty, its camera folder has monitor.jpg, and that is offered beside the dead saved one")
    func theU1sCameraIsFound() async throws {
        let engine = try KhaytEngine()
        let steps = try await engine.cameraDiscoverySteps(printerApi: Self.u1, webcam: Self.dead)
        #expect(steps.map(\.source) == ["configured", "printer_list", "camera_files", "guess"])

        let list = try #require(steps.first { $0.source == "printer_list" })
        #expect(list.listUrl == "http://192.168.68.56:7125/server/webcams/list")
        #expect(try await engine.cameraCandidate(step: list, body: Self.fixture("u1-webcams-list.json"),
                                                 printerApi: Self.u1) == nil)

        let files = try #require(steps.first { $0.source == "camera_files" })
        let found = try #require(try await engine.cameraCandidate(step: files, body: Self.fixture("u1-camera-files.json"),
                                                                 printerApi: Self.u1))
        #expect(found.snapshotUrl == Self.monitor)
        #expect(found.vendor == "snapmaker")
        // The pin still holds: it is the printer's own host.
        try await engine.assertWebcamHost(found.snapshotUrl, printerApi: Self.u1)
        // Offered as a replacement, never applied.
        #expect(try await engine.cameraSuggestion(saved: Self.dead, found: found.snapshotUrl) == "replace")
    }

    static func machine(snapshot: String) throws -> Machine {
        let row: [String: JSONValue] = [
            "id": .string("U1"), "name": .string("U1"),
            "printerApi": .object(["type": .string("moonraker"), "host": .string("192.168.68.56"), "port": .number(7125)]),
            "webcam": .object(["enabled": .bool(true), "snapshotUrl": .string(snapshot)]),
        ]
        return try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(row))
    }

    /// The headers the bench answered with, ten minutes after a print ended.
    static func monitorReply(_ request: URLRequest, date: String? = nil) throws -> (Data, URLResponse) {
        guard case .object(let headers)? = try object("u1-monitor-jpg-headers.json")["headers"] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var fields: [String: String] = [:]
        for (k, v) in headers { if case .string(let s) = v { fields[k] = s } }
        if let date { fields["Date"] = date }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10])
        fields["Content-Length"] = "\(jpeg.count)"
        return (jpeg, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: fields)!)
    }

    @Test("the bench's monitor.jpg, six minutes old by the printer's own clock, is a PAUSED camera")
    func aFrozenStillIsPaused() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let machine = try Self.machine(snapshot: Self.monitor)
        let frame = await Camera.fetch(machine, shop: shop) { try Self.monitorReply($0) }
        guard case .paused = frame else { Issue.record("\(frame) is drawn as live"); return }
    }

    @Test("the same still two seconds old is live")
    func aFreshStillIsLive() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let machine = try Self.machine(snapshot: Self.monitor)
        let frame = await Camera.fetch(machine, shop: shop) {
            try Self.monitorReply($0, date: "Thu, 22 Oct 2026 12:01:05 GMT")
        }
        guard case .picture = frame else { Issue.record("\(frame) is not live"); return }
    }

    @Test("a paused frame is never taken as the finish photo")
    func aPausedFrameIsNoFinishPhoto() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let machine = try Self.machine(snapshot: Self.monitor)
        let edge = try JSONDecoder().decode(KhaytEngine.FinishTrack.self, from: Data(#"""
        {"memo": {}, "capture": true, "outcome": "finished", "filename": "x.gcode", "durationS": 60}
        """#.utf8))
        let log: [JSONValue] = [.object(["id": .string("J1"), "status": .string("printing"),
                                         "machineId": .string("U1"), "project": .string("x")])]
        var attached = false
        let (_, outcome) = await FinishCamera.finish(machine, edge: edge, printLog: log, shop: shop,
                                                     get: { try Self.monitorReply($0) }) { _, _ in
            attached = true
            return true
        }
        #expect(!attached)
        #expect(outcome == .noFrame)
    }

    @Test("job 00004E on the bench finds its timelapse by the printer's history and camera folder")
    func theTimelapseIsFound() async throws {
        let engine = try KhaytEngine()
        let history = try Self.object("u1-history-around-timelapse.json")
        let files = try Self.object("u1-camera-files.json")
        var asked: [String] = []
        let found = await Timelapse.look(base: URL(string: "http://192.168.68.56:7125")!,
                                         filename: "d0de11b4e5a09b4119ca41bdab22300d_PLA_4h29m.gcode",
                                         key: "", engine: engine) { _, path, _ in
            asked.append(path)
            return path.hasPrefix("/server/history/list") ? history : files
        }
        #expect(asked == ["/server/history/list?limit=5", "/server/files/list?root=camera"])
        #expect(found?.video == "d0de11b4e5a09b4119ca41bdab22300d_PLA_4h29m_20260803192022.mp4")
        #expect(found?.cover == "d0de11b4e5a09b4119ca41bdab22300d_PLA_4h29m_20260803192022.jpg")
        #expect(found?.bytes == 59481447)

        // A job with no timelapse beside it matches nothing, and the folder is
        // not asked for a file the printer never ran.
        let none = await Timelapse.look(base: URL(string: "http://192.168.68.56:7125")!,
                                        filename: "td-swatch_PLA_17m25s.gcode", key: "", engine: engine) { _, path, _ in
            path.hasPrefix("/server/history/list") ? history : files
        }
        #expect(none == nil)
        let unknown = await Timelapse.look(base: URL(string: "http://192.168.68.56:7125")!,
                                           filename: "never-printed.gcode", key: "", engine: engine) { _, path, _ in
            #expect(!path.contains("root=camera"))
            return history
        }
        #expect(unknown == nil)
    }

    @Test("the job keeps names, and the link is built from the machine's host when opened")
    func theLinkFollowsTheMachine() async throws {
        let engine = try KhaytEngine()
        let match = KhaytEngine.TimelapseMatch(video: "Dark Knight_PLA_5h39m_20260626202455.mp4",
                                               cover: "Dark Knight_PLA_5h39m_20260626202455.jpg", bytes: 109118582)
        let record = try await engine.timelapseRecord(machineId: "U1", match: match, at: "2026-06-27T01:52:00.000Z")
        let order = JSONValue.object(["id": .string("J1"), "printerTimelapse": record])
        let machine = JSONValue.object(["id": .string("U1"), "printerApi": Self.u1])
        let link = try #require(try await engine.timelapseLink(order: order, machine: machine))
        #expect(link.videoUrl == "http://192.168.68.56:7125/server/files/camera/Dark%20Knight_PLA_5h39m_20260626202455.mp4")
        #expect(link.bytes == 109118582)
        // And it is a camera address the pin allows.
        try await engine.assertWebcamHost(link.videoUrl, printerApi: Self.u1)
        // A synced record naming a path out of the folder resolves to nothing.
        let bad = JSONValue.object(["printerTimelapse": .object(["machineId": .string("U1"),
                                                                  "video": .string("../config/printer.cfg.mp4")])])
        #expect(try await engine.timelapseLink(order: bad, machine: machine) == nil)
    }

    @Test("the sample shop is never written a timelapse")
    func theSampleIsNotWritten() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let match = KhaytEngine.TimelapseMatch(video: "a_20260101000000.mp4", cover: nil, bytes: nil)
        let id = try #require(shop.orders.first?.id)
        #expect(await shop.writeTimelapse(match, jobId: id, machineId: "U1") == false)
    }

    @Test("a size reads in Western digits in Arabic too")
    func theSizeIsWestern() async throws {
        let words = Words()
        await words.load("ar", engine: try KhaytEngine())
        let said = TimelapseLine.size(59481447, words)
        #expect(said.contains("59"), "\(said)")
        #expect(TimelapseLine.size(nil, words) == "—")
    }
}

/// The verifier's findings on the first pass (C1, C3, C4).
@MainActor
struct CameraReviewFixTests {

    @Test("a record write that changes nothing is not stamped")
    func aNoOpIsNotStamped() {
        var root: [String: JSONValue] = ["printLog": .array([
            .object(["id": .string("J1"), "rev": .number(4), "updatedAt": .string("2026-10-01T00:00:00.000Z"),
                     "printerTimelapse": .object(["video": .string("a_20260101000000.mp4")])]),
        ])]
        let before = root
        let wrote = StoreWriter.changeRecord(&root, collection: "printLog", id: "J1") { job -> Bool in
            guard job["printerTimelapse"] == nil else { return false }
            job["printerTimelapse"] = .string("x")
            return true
        }
        #expect(wrote == false)
        #expect(root == before, "rev/updatedAt moved on a write that changed nothing")

        // And a real change is stamped.
        _ = StoreWriter.changeRecord(&root, collection: "printLog", id: "J1") { $0["notes"] = .string("n") }
        guard case .array(let rows)? = root["printLog"], case .object(let j)? = rows.first else {
            Issue.record("no row"); return
        }
        #expect(j["rev"] == .number(5))
    }

    @Test("a still is never served from a cache")
    func theStillIsNotCached() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let machine = try CameraDiscoveryTests.machine(snapshot: CameraDiscoveryTests.monitor)
        var policy: URLRequest.CachePolicy?
        _ = await Camera.fetch(machine, shop: shop) { request in
            policy = request.cachePolicy
            return try CameraDiscoveryTests.monitorReply(request)
        }
        #expect(policy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    @Test("the timelapse player reads in bounded ranges and knows the total")
    func theLoaderRanges() {
        #expect(PinnedVideoLoader.range(offset: 0, end: 1) == (0, 1))
        #expect(PinnedVideoLoader.range(offset: 0, end: nil) == (0, PinnedVideoLoader.chunk - 1))
        let far = PinnedVideoLoader.range(offset: 10, end: 100_000_000)
        #expect(far.1 - far.0 + 1 == PinnedVideoLoader.chunk)
        #expect(PinnedVideoLoader.total("bytes 0-1/59481447") == 59481447)
        // Overflow-safe: an offset near the top saturates, and a known
        // total caps the last byte.
        #expect(PinnedVideoLoader.range(offset: .max - 5, end: nil).1 == .max)
        #expect(PinnedVideoLoader.range(offset: 100, end: .max, total: 150) == (100, 149))
        #expect(PinnedVideoLoader.total(nil) == nil)
        // The player is never handed the printer's http address.
        #expect(PinnedVideoLoader.playerURL.scheme == "khayt-timelapse")
    }

    @Test("a 206 that starts somewhere else, or declares more than was asked, is refused before its body")
    func aWrongRangeIsRefused() {
        let cap = PinnedVideoLoader.cap(recorded: 59481447)
        // The right one.
        let ok = PinnedVideoLoader.admit(status: 206, contentRange: "bytes 0-2097151/59481447",
                                         expectedLength: 2097152, from: 0, to: 2097151, cap: cap)
        #expect(ok.ok && ok.total == 59481447)
        // Wrong offset.
        #expect(!PinnedVideoLoader.admit(status: 206, contentRange: "bytes 4096-2101247/59481447",
                                         expectedLength: 2097152, from: 0, to: 2097151, cap: cap).ok)
        // Ends past the asked range.
        #expect(!PinnedVideoLoader.admit(status: 206, contentRange: "bytes 0-4194303/59481447",
                                         expectedLength: 4194304, from: 0, to: 2097151, cap: cap).ok)
        // Oversize declared body under a correct-looking range.
        #expect(!PinnedVideoLoader.admit(status: 206, contentRange: "bytes 0-1/59481447",
                                         expectedLength: 104_857_600, from: 0, to: 1, cap: cap).ok)
        // A whole-file 200, a redirect, garbage.
        #expect(!PinnedVideoLoader.admit(status: 200, contentRange: nil, expectedLength: 59481447,
                                         from: 0, to: 1, cap: cap).ok)
        #expect(!PinnedVideoLoader.admit(status: 302, contentRange: nil, expectedLength: -1,
                                         from: 0, to: 1, cap: cap).ok)
        #expect(!PinnedVideoLoader.admit(status: 206, contentRange: "bytes x-y/z", expectedLength: -1,
                                         from: 0, to: 1, cap: cap).ok)
    }

    @Test("a huge claimed total is clamped, and never overflows")
    func aHugeTotalIsClamped() {
        let recorded = PinnedVideoLoader.cap(recorded: 59481447)
        #expect(recorded == 59481447)
        let huge = PinnedVideoLoader.admit(status: 206, contentRange: "bytes 0-1/9223372036854775807",
                                           expectedLength: 2, from: 0, to: 1, cap: recorded)
        #expect(huge.ok && huge.total == 59481447)
        // No size recorded: 8 GB.
        #expect(PinnedVideoLoader.cap(recorded: nil) == 8 * 1024 * 1024 * 1024)
        #expect(PinnedVideoLoader.cap(recorded: .infinity) == PinnedVideoLoader.defaultCap)
        #expect(PinnedVideoLoader.cap(recorded: 1e30) == PinnedVideoLoader.defaultCap)
        // A total past Int64 does not parse as a total at all.
        #expect(PinnedVideoLoader.total("bytes 0-1/99999999999999999999") == nil)
        // A range that ends at or past the clamped total is refused.
        #expect(!PinnedVideoLoader.admit(status: 206, contentRange: "bytes 0-99/9000000000000",
                                         expectedLength: 100, from: 0, to: 99, cap: 50).ok)
        #expect(PinnedVideoLoader.plus(.max, 1) == .max)
    }
}
