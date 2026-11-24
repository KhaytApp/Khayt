import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A printer that is not there: answers `CappedDownload`'s one request from a script.
final class StubPrinter: URLProtocol, @unchecked Sendable {
    struct Script { var status = 200; var headers: [String: String] = [:]; var chunks: [Data] = []; var redirect: URL?; var fail = false }
    nonisolated(unsafe) static var script = Script()
    nonisolated(unsafe) static var asked: [URLRequest] = []
    private static let lock = NSLock()

    static func set(_ script: Script) { lock.lock(); self.script = script; asked = []; lock.unlock() }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return asked }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock(); Self.asked.append(request); let script = Self.script; Self.lock.unlock()
        if script.fail { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        if let to = script.redirect {
            let moved = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": to.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: to), redirectResponse: moved)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: script.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in script.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// `GET /api/orders/{id}/timelapse` and `POST /api/orders/{id}/timelapse/keep`,
/// and the copy behind them (iPhone frame 7b, "Keep as proof"). Sample data
/// only: the printer is `StubPrinter`, and no printer is spoken to.
@MainActor
@Suite(.serialized)
struct LanTimelapseTests {
    static let engine = OperatorLockTests.sharedEngine
    static let video = "Dark Knight_PLA_5h39m_20260626202455.mp4"

    // MARK: - The routes and who may use them

    @Test("each path names one job and is not the other's")
    func paths() {
        #expect(LanServer.timelapseReadPath("/api/orders/J1/timelapse") == "J1" && LanServer.timelapseKeepPath("/api/orders/J1/timelapse") == nil)
        #expect(LanServer.timelapseKeepPath("/api/orders/J%201/timelapse/keep") == "J 1" && LanServer.timelapseReadPath("/api/orders/J1/timelapse/keep") == nil)
        for other in ["/api/orders//timelapse", "/api/orders/J1/timelapse/", "/api/orders/J1/timelapse/keep/x", "/api/orders/J1/timelapse/kept",
                      "/api/orders/J1/photos", "/api/orders/J1", "/api/order/J1/timelapse", "api/orders/J1/timelapse", "/api/printer/J1/timelapse"] {
            #expect(LanServer.timelapseReadPath(other) == nil && LanServer.timelapseKeepPath(other) == nil, Comment(rawValue: other))
        }
        #expect(LanServer.jobPhotoPath("/api/orders/J1/timelapse") == nil)
    }

    @Test("the PIN alone and nothing at all are refused; the job's other routes are still theirs")
    func pinIsNotEnough() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        let pin = ["x-khayt-pin": LanDeviceKeysTests.pin]
        let read = try await bench.get("/api/orders/J1/timelapse", headers: pin)
        #expect(read.status == 403 && read.text.contains("device-key-required"))
        let keep = try await bench.post("/api/orders/J1/timelapse/keep", json: "", headers: pin)
        #expect(keep.status == 403 && keep.text.contains("device-key-required"))
        #expect(try await bench.get("/api/orders/J1/timelapse").status == 401)
        #expect(try await bench.post("/api/orders/J1/timelapse/keep", json: "").status == 401)
        #expect(try await bench.post("/api/orders/J1/timelapse", json: "", headers: pin).status == 404)
        #expect(try await bench.get("/api/orders/J1/timelapse/keep", headers: pin).status == 404)
        #expect(bench.lapseCalls.calls.isEmpty)
    }

    func role(_ role: String, keeps: Bool) async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let phone = try PhoneRolesTests.codePaired(bench.devices, role: role, name: role)
        #expect(try await PhoneRolesTests.status(bench, phone, "GET", "/api/orders/J1/timelapse").0 == 200, Comment(rawValue: role))
        let (sent, json) = try await PhoneRolesTests.status(bench, phone, "POST", "/api/orders/J1/timelapse/keep")
        #expect(sent == (keeps ? 201 : 403), Comment(rawValue: role))
        if !keeps { #expect(json["reason"] as? String == "role-scope" && json["required"] as? String == "orders:write") }
        #expect(bench.lapseCalls.calls == (keeps ? ["read J1", "keep J1"] : ["read J1"]), Comment(rawValue: role))
        let (_, me) = try await PhoneRolesTests.status(bench, phone, "GET", "/api/devices/self")
        #expect(((me["can"] as? [String]) ?? []).contains("timelapse-keep") == keeps, Comment(rawValue: role))
    }

    @Test("a viewer's phone sees whether there is one and may not have it kept") func viewer() async throws { try await role("viewer", keeps: false) }
    @Test("an operator's phone may have it kept") func `operator`() async throws { try await role("operator", keeps: true) }
    @Test("a manager's phone may have it kept") func manager() async throws { try await role("manager", keeps: true) }
    @Test("the owner's phone may have it kept") func owner() async throws { try await role("owner", keeps: true) }

    @Test("both answers are signed for the phone that asked: the one with the address to open, and the keep's")
    func signed() async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let phone = try PhoneRolesTests.codePaired(bench.devices, role: "operator", name: "Op")
        for (method, path, want) in [("GET", "/api/orders/J1/timelapse", 200), ("POST", "/api/orders/J1/timelapse/keep", 201)] {
            let headers = phone.headers(method, path)
            let reply = try await bench.send(method, path, body: nil, headers: headers, timeout: 30)
            #expect(reply.status == want, Comment(rawValue: path))
            let mac = try #require(reply.headers["x-khayt-reply-mac"], Comment(rawValue: path))
            #expect(mac == LanServer.replyMac(key: phone.key, nonce: headers["x-khayt-nonce"] ?? "", status: reply.status, body: reply.body),
                    Comment(rawValue: path))
        }
        // A viewer's refusal is signed too (the gate's); the PIN-only refusal is not: nobody's key was shown.
        let pin = try await bench.get("/api/orders/J1/timelapse", headers: ["x-khayt-pin": LanDeviceKeysTests.pin])
        #expect(pin.status == 403 && pin.headers["x-khayt-reply-mac"] == nil)
    }

    @Test("a paired slicer is refused both; the rule names the scopes and the wrong direction is the owner's")
    func slicerAndRule() async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let slicer = try LanConnectorRoutesTests.enrol(bench)
        for (method, path) in [("GET", "/api/orders/J1/timelapse"), ("POST", "/api/orders/J1/timelapse/keep")] {
            let (status, _) = try await PhoneRolesTests.status(bench, slicer, method, path)
            #expect(status == 401 || status == 403, "\(method) \(status)")
        }
        #expect(bench.lapseCalls.calls.isEmpty)
        func ask(_ role: String, _ method: String, _ path: String) async throws -> (Bool, String?) {
            let a = try await Self.engine.deviceAllows(.object(["role": .string(role), "rolesVersion": .number(1)]), path: path, method: method)
            return (a.ok, a.required)
        }
        for (role, keeps) in [("viewer", false), ("operator", true), ("manager", true), ("owner", true)] {
            #expect(try await ask(role, "GET", "/api/orders/j1/timelapse") == (true, "orders:read"), Comment(rawValue: role))
            #expect(try await ask(role, "POST", "/api/orders/j1/timelapse/keep") == (keeps, "orders:write"), Comment(rawValue: role))
        }
        #expect(try await ask("manager", "POST", "/api/orders/j1/timelapse") == (false, "owner"))
        #expect(try await ask("manager", "GET", "/api/orders/j1/timelapse/keep") == (false, "owner"))
    }

    // MARK: - The copy, counted as it arrives

    static func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-lapse-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func listing(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
    static let request = URLRequest(url: URL(string: "http://192.168.68.56:7125/server/files/camera/x.mp4")!)

    @Test("the limit is on what is read: a stated size over it is refused unread, and an under-stated one is cut off")
    func capped() async throws {
        CappedDownload.protocolsForTests = [StubPrinter.self]
        defer { CappedDownload.protocolsForTests = nil }
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "a.part")
        let kb = Data(repeating: 7, count: 1024)
        // A whole file, under the limit: every byte, and the count.
        StubPrinter.set(.init(headers: ["Content-Length": "4096"], chunks: [kb, kb, kb, kb]))
        #expect(try await CappedDownload.run(Self.request, to: file, cap: 8192) == 4096)
        #expect(try Data(contentsOf: file) == kb + kb + kb + kb)
        // Exactly the limit is allowed; one byte more is not.
        StubPrinter.set(.init(chunks: [kb, kb]))
        #expect(try await CappedDownload.run(Self.request, to: file, cap: 2048) == 2048)
        // The printer SAYS it is too big: refused before the body, nothing written.
        StubPrinter.set(.init(headers: ["Content-Length": "9000"], chunks: [kb]))
        await #expect(throws: CappedDownload.Failure.overBudget(9000)) { _ = try await CappedDownload.run(Self.request, to: file, cap: 8192) }
        #expect(((try? Data(contentsOf: file)) ?? Data()).isEmpty)
        // The printer says 1 KB and sends 5: cut off, and never more than the limit on disk.
        StubPrinter.set(.init(headers: ["Content-Length": "1024"], chunks: [kb, kb, kb, kb, kb]))
        do { _ = try await CappedDownload.run(Self.request, to: file, cap: 3000); Issue.record("a file past the limit was taken") }
        catch let failure as CappedDownload.Failure {
            guard case .overBudget(let seen) = failure else { Issue.record("\(failure)"); return }
            #expect(seen > 3000)
        }
        #expect(((try? Data(contentsOf: file)) ?? Data()).count <= 3000, "bytes past the limit reached the disk")
        // No stated size at all: still counted.
        StubPrinter.set(.init(chunks: [kb, kb, kb, kb]))
        await #expect(throws: CappedDownload.Failure.self) { _ = try await CappedDownload.run(Self.request, to: file, cap: 2000) }
        // Not a 200; a redirect; a printer that is off.
        StubPrinter.set(.init(status: 404, chunks: [Data("not found".utf8)]))
        await #expect(throws: CappedDownload.Failure.status(404)) { _ = try await CappedDownload.run(Self.request, to: file, cap: 8192) }
        StubPrinter.set(.init(status: 206, chunks: [kb]))
        await #expect(throws: CappedDownload.Failure.status(206)) { _ = try await CappedDownload.run(Self.request, to: file, cap: 8192) }
        StubPrinter.set(.init(redirect: URL(string: "http://example.com/big.mp4")!))
        await #expect(throws: CappedDownload.Failure.redirected) { _ = try await CappedDownload.run(Self.request, to: file, cap: 8192) }
        #expect(StubPrinter.requests.count == 1, "the redirect was followed")
        StubPrinter.set(.init(fail: true))
        await #expect(throws: (any Error).self) { _ = try await CappedDownload.run(Self.request, to: file, cap: 8192) }
        // An empty file is zero bytes, which the caller treats as no file.
        StubPrinter.set(.init())
        #expect(try await CappedDownload.run(Self.request, to: file, cap: 8192) == 0)
    }

    // MARK: - Keeping it with the job

    @MainActor final class Wrote { var rows: [(String, [String: JSONValue])] = []; var answer: Bool? = true; var throwing = false }

    static func job(bytes: JSONValue? = .number(4096), video: String = video, files: [JSONValue] = []) -> JSONValue {
        var lapse: [String: JSONValue] = ["machineId": .string("U1"), "video": .string(video), "at": .string("2026-11-20T10:00:00.000Z")]
        if let bytes { lapse["bytes"] = bytes }
        return .object(["id": .string("J 1/x"), "project": .string("Lantern"), "printerTimelapse": .object(lapse), "attachedFiles": .array(files)])
    }

    static func shop(_ jobs: [JSONValue], machineType: String = "moonraker") -> (Shop, Wrote, URL) {
        let shop = Shop()
        shop.useEngine(engine)
        shop.orderRows = jobs
        shop.machineRows = [.object(["id": .string("U1"), "name": .string("Baby U1"),
                                     "printerApi": .object(["type": .string(machineType), "host": .string("192.168.68.56")])])]
        let dir = scratch()
        shop.timelapseFolderForTests = dir
        shop.timelapseBaseForTests = PrinterRunoutTests.base
        let wrote = Wrote()
        shop.timelapseWriteForTests = { id, row in
            if wrote.throwing { throw CocoaError(.fileWriteNoPermission) }
            wrote.rows.append((id, row))
            return wrote.answer
        }
        return (shop, wrote, dir)
    }

    @Test("kept: one GET for the job's own file, one file under the rule's name, one row with the size that was written")
    func keeps() async throws {
        CappedDownload.protocolsForTests = [StubPrinter.self]
        defer { CappedDownload.protocolsForTests = nil }
        let (shop, wrote, dir) = Self.shop([Self.job()])
        defer { try? FileManager.default.removeItem(at: dir) }
        let kb = Data(repeating: 9, count: 1024)
        // The printer said 4096 and sends 3072: the row says what was written.
        StubPrinter.set(.init(chunks: [kb, kb, kb]))
        let outcome = await shop.keepTimelapse("J 1/x", gate: .system("test"), now: Date(timeIntervalSince1970: 1_795_000_000))
        guard case .kept(let name, let bytes) = outcome else { Issue.record("\(outcome)"); return }
        #expect(bytes == 3072)
        // The job's id is not a path: every character that could be one is gone.
        #expect(name.hasPrefix("J_1_x-timelapse-") && name.hasSuffix(".mp4") && Shop.safeKeptName(name))
        #expect(Self.listing(dir) == [name], "a partial copy, or a second file, was left")
        #expect(try Data(contentsOf: dir.appending(path: name)) == kb + kb + kb)
        // Asked once, for that file, at the printer's own address, and only read.
        let asked = StubPrinter.requests
        #expect(asked.count == 1 && asked[0].httpMethod == "GET")
        #expect(asked[0].url?.absoluteString == "http://192.168.68.56:7125/server/files/camera/Dark%20Knight_PLA_5h39m_20260626202455.mp4")
        // The row the other app reads, with the size written.
        #expect(wrote.rows.count == 1 && wrote.rows[0].0 == "J 1/x")
        let row = wrote.rows[0].1
        #expect(row["filename"] == .string(name) && row["kind"] == .string("timelapse") && row["size"] == .number(3072))
        #expect(row["originalName"] == .string(Self.video))
        #expect(row["from"] == .object(["machineId": .string("U1"), "video": .string(Self.video)]))
        #expect(shop.timelapseCopying.isEmpty)
    }

    @Test("not fetched at all: too large by the printer's own word, no stated size, already kept, nothing to keep, no printer")
    func notFetched() async throws {
        CappedDownload.protocolsForTests = [StubPrinter.self]
        defer { CappedDownload.protocolsForTests = nil }
        StubPrinter.set(.init(chunks: [Data(repeating: 1, count: 10)]))
        func outcome(_ job: JSONValue, type: String = "moonraker", max: Double? = nil) async -> (Shop.TimelapseKept, [String]) {
            let (shop, wrote, dir) = Self.shop([job], machineType: type)
            defer { try? FileManager.default.removeItem(at: dir) }
            let out = await shop.keepTimelapse("J 1/x", gate: .system("test"), maxBytes: max)
            #expect(wrote.rows.isEmpty)
            return (out, Self.listing(dir))
        }
        // 180 MB against the rule's 150 MB.
        let big = await outcome(Self.job(bytes: .number(180 * 1024 * 1024)))
        #expect(big.0 == .link(reason: "over-budget", bytes: 180 * 1024 * 1024, maxBytes: 150 * 1024 * 1024) && big.1.isEmpty)
        #expect(await outcome(Self.job(bytes: nil)).0 == .link(reason: "size-unknown", bytes: nil, maxBytes: 150 * 1024 * 1024))
        #expect(await outcome(Self.job(bytes: .number(0))).0 == .link(reason: "size-unknown", bytes: nil, maxBytes: 150 * 1024 * 1024))
        let kept: JSONValue = .object(["filename": .string("J_1_x-timelapse-a.mp4"), "kind": .string("timelapse"), "size": .number(4000),
                                       "from": .object(["machineId": .string("U1"), "video": .string(Self.video)])])
        #expect(await outcome(Self.job(files: [kept])).0 == .already)
        // No record; a name that is not one plain file in the camera folder; a cover, not a video.
        #expect(await outcome(.object(["id": .string("J 1/x")])).0 == .none)
        for bad in ["../../etc/passwd.mp4", "a/b.mp4", ".hidden.mp4", "cover.jpg", "x.mp4\u{0}", ""] {
            #expect(await outcome(Self.job(video: bad)).0 == .none, Comment(rawValue: bad))
        }
        // Its printer is not a Moonraker printer any more.
        #expect(await outcome(Self.job(), type: "bambu").0 == .noMachine)
        #expect(StubPrinter.requests.isEmpty, "a printer was asked for a file that was never going to be kept")
        // No such job.
        let (shop, _, dir) = Self.shop([Self.job()])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await shop.keepTimelapse("nobody", gate: .system("test")) == .none)
        // One copy per job at a time.
        shop.timelapseCopying = ["J 1/x"]
        #expect(await shop.keepTimelapse("J 1/x", gate: .system("test")) == .busy)
    }

    @Test("nothing is left behind: a printer that sends more than it said, one that is off, and a job that cannot be written")
    func nothingLeft() async throws {
        CappedDownload.protocolsForTests = [StubPrinter.self]
        defer { CappedDownload.protocolsForTests = nil }
        let kb = Data(repeating: 3, count: 1024)
        let (shop, wrote, dir) = Self.shop([Self.job(bytes: .number(1024))])
        defer { try? FileManager.default.removeItem(at: dir) }
        // Says 1 KB (so the rule lets it be fetched), sends 6 KB against a 4 KB limit.
        StubPrinter.set(.init(chunks: [kb, kb, kb, kb, kb, kb]))
        let cut = await shop.keepTimelapse("J 1/x", gate: .system("test"), maxBytes: 4096)
        guard case .link(let reason, let bytes, let most) = cut else { Issue.record("\(cut)"); return }
        #expect(reason == "over-budget" && (bytes ?? 0) > 4096 && most == 4096)
        #expect(Self.listing(dir).isEmpty && wrote.rows.isEmpty)
        // Off, a 404, an empty answer, a redirect.
        for script in [StubPrinter.Script(fail: true), .init(status: 404), .init(), .init(redirect: URL(string: "http://example.com/x.mp4")!)] {
            StubPrinter.set(script)
            #expect(await shop.keepTimelapse("J 1/x", gate: .system("test")) == .unreachable)
            #expect(Self.listing(dir).isEmpty && wrote.rows.isEmpty)
        }
        // Copied, and then: the other app kept it meanwhile; the job left the book; the book could not be written.
        StubPrinter.set(.init(chunks: [kb]))
        wrote.answer = false
        #expect(await shop.keepTimelapse("J 1/x", gate: .system("test")) == .already)
        #expect(Self.listing(dir).isEmpty, "a copy nobody's job points at was left on disk")
        wrote.answer = nil
        #expect(await shop.keepTimelapse("J 1/x", gate: .system("test")) == .none)
        #expect(Self.listing(dir).isEmpty)
        wrote.throwing = true
        guard case .notSaved = await shop.keepTimelapse("J 1/x", gate: .system("test")) else { Issue.record("a failed write was not said"); return }
        #expect(Self.listing(dir).isEmpty && shop.timelapseCopying.isEmpty)
    }

    @Test("at the Mac it is orders/edit: a viewer under the staff lock is refused before anything is asked of the printer")
    func staffLock() async throws {
        CappedDownload.protocolsForTests = [StubPrinter.self]
        defer { CappedDownload.protocolsForTests = nil }
        StubPrinter.set(.init(chunks: [Data(repeating: 1, count: 100)]))
        let shop = await OperatorLockTests.shop()
        shop.orderRows = [Self.job()]
        #expect(await shop.signIn("OP-v", pin: "4444") == .ok)
        #expect(await shop.keepTimelapse("J 1/x") == .notPermitted)
        #expect(StubPrinter.requests.isEmpty)
        // An operator may edit jobs: past the lock (and then stopped by the sample book, which has nowhere to write).
        #expect(await shop.signIn("OP-x", pin: "3333") == .ok)
        #expect(await shop.keepTimelapse("J 1/x") == .readOnly)
    }

    @Test("the names: only what the rule makes is a file here, and only one plain file is asked of the printer")
    func names() {
        for good in ["J_1-timelapse-mb3k2a1.mp4", "job-timelapse-0.mp4", "a-b_c-timelapse-Z9.mp4"] { #expect(Shop.safeKeptName(good), Comment(rawValue: good)) }
        for bad in ["../x-timelapse-1.mp4", "x/y-timelapse-1.mp4", "x-timelapse-1.mp4.part", "x-timelapse-.mp4", "-timelapse-1.mp4", "x-timelapse-1.mov",
                    "x-timelapse-1.mp4 ", "x.y-timelapse-1.mp4", "x-timelapse-1/2.mp4", String(repeating: "a", count: 300) + "-timelapse-1.mp4", ""] {
            #expect(!Shop.safeKeptName(bad), Comment(rawValue: bad))
        }
        let base = PrinterRunoutTests.base
        #expect(Shop.cameraFile(base, "a b&c?d#e%f+g.mp4")?.absoluteString == "http://192.168.68.56:7125/server/files/camera/a%20b%26c%3Fd%23e%25f%2Bg.mp4")
        for bad in ["", "a/b.mp4", "a\\b.mp4", "..mp4", ".a.mp4", "a.jpg", "a.mp4\n", "a\u{7F}.mp4", String(repeating: "a", count: 260) + ".mp4"] {
            #expect(Shop.cameraFile(base, bad) == nil, Comment(rawValue: bad))
        }
        // A name cannot move the request to another host, port or scheme.
        #expect(Shop.cameraFile(base, "@evil.example.mp4")?.host() == "192.168.68.56")
        #expect(Shop.cameraFile(base, ":9999.mp4")?.port == 7125)
    }

    @Test("the row goes on the job once")
    func row() {
        var job: [String: JSONValue] = ["id": .string("J1")]
        let row: [String: JSONValue] = ["filename": .string("J1-timelapse-a.mp4"), "kind": .string("timelapse"),
                                        "from": .object(["machineId": .string("U1"), "video": .string(Self.video)])]
        #expect(Shop.appendKept(row, to: &job, video: Self.video, machineId: "U1"))
        #expect(!Shop.appendKept(row, to: &job, video: Self.video, machineId: "U1"))
        guard case .array(let files)? = job["attachedFiles"] else { Issue.record("shape"); return }
        #expect(files == [.object(row)])
        // The same file name from another printer is another video.
        #expect(Shop.appendKept(row, to: &job, video: Self.video, machineId: "U2"))
        // A file attached by hand is never taken for a kept time-lapse.
        #expect(!Shop.isKept(.object(["filename": .string("x.mp4")]), video: Self.video, machineId: "U1"))
    }

    // MARK: - What the phone is told

    static func json(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:] }

    @Test("the four states, and the answers to Keep as proof")
    func phone() async throws {
        CappedDownload.protocolsForTests = [StubPrinter.self]
        defer { CappedDownload.protocolsForTests = nil }
        func state(_ job: JSONValue, type: String = "moonraker") async -> [String: Any] {
            let (shop, _, dir) = Self.shop([job], machineType: type)
            defer { try? FileManager.default.removeItem(at: dir) }
            let (status, body) = await shop.phoneTimelapse("J 1/x")
            #expect(status == 200)
            return Self.json(body)
        }
        let available = await state(Self.job(bytes: .number(34_000_000)))
        #expect(available["state"] as? String == "available" && available["bytes"] as? Int == 34_000_000)
        #expect(available["url"] as? String == "http://192.168.68.56:7125/server/files/camera/Dark%20Knight_PLA_5h39m_20260626202455.mp4")
        let link = await state(Self.job(bytes: .number(180 * 1024 * 1024)))
        #expect(link["state"] as? String == "link" && link["reason"] as? String == "over-budget" && link["maxBytes"] as? Int == 150 * 1024 * 1024)
        #expect(link["url"] as? String != nil, "Open on the printer has nothing to open")
        #expect((await state(Self.job(bytes: nil)))["reason"] as? String == "size-unknown")
        let kept: JSONValue = .object(["filename": .string("J_1_x-timelapse-a.mp4"), "kind": .string("timelapse"), "size": .number(4000),
                                       "from": .object(["machineId": .string("U1"), "video": .string(Self.video)])])
        let have = await state(Self.job(files: [kept]))
        #expect(have["state"] as? String == "kept" && have["bytes"] as? Int == 4000 && have["url"] == nil)
        #expect((await state(.object(["id": .string("J 1/x")])))["state"] as? String == "none")
        // Its printer is no longer a Moonraker printer: nothing the phone could do with it.
        #expect((await state(Self.job(), type: "bambu"))["state"] as? String == "none")

        let (shop, wrote, dir) = Self.shop([Self.job()])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await shop.phoneTimelapse("nobody").0 == 404)
        #expect(await shop.phoneKeepTimelapse("nobody").0 == 404)
        StubPrinter.set(.init(chunks: [Data(repeating: 5, count: 2048)]))
        let (status, body) = await shop.phoneKeepTimelapse("J 1/x")
        let said = Self.json(body)
        #expect(status == 201 && said["state"] as? String == "kept" && said["bytes"] as? Int == 2048 && (said["filename"] as? String ?? "").hasSuffix(".mp4"))
        #expect(wrote.rows.count == 1)
        StubPrinter.set(.init(fail: true))
        let (off, why) = await shop.phoneKeepTimelapse("J 1/x")
        #expect(off == 502 && Self.json(why)["reason"] as? String == "printer-unreachable")
        shop.timelapseCopying = ["J 1/x"]
        let (busy, copying) = await shop.phoneKeepTimelapse("J 1/x")
        #expect(busy == 409 && Self.json(copying)["reason"] as? String == "copying")
        #expect(Self.json(await shop.phoneTimelapse("J 1/x").1)["copying"] as? Bool == true)
        let starting = Shop()
        if starting.engine == nil { #expect(await starting.phoneKeepTimelapse("J 1/x").0 == 503) }
    }

    @Test("the routes in the real server are these functions; the printer is only ever asked for the file; the reference says so")
    func wiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = try String(contentsOf: root.appending(path: "Sources/KhaytApp/LanServer.swift"), encoding: .utf8)
        #expect(server.contains("await self?.phoneTimelapse(id)") && server.contains("await self?.phoneKeepTimelapse(id)"))
        let mine = try String(contentsOf: root.appending(path: "Sources/KhaytApp/Shop+TimelapseKeep.swift"), encoding: .utf8)
        for never in ["PrinterControl", "gcode", "PrinterWatch.send", "PrinterWatch.upload", "printers.commanding", "httpMethod", "httpBody"] {
            #expect(!mine.contains(never), Comment(rawValue: never))
        }
        #expect(mine.components(separatedBy: "CappedDownload.run(").count == 2)
        let copy = try String(contentsOf: root.appending(path: "Sources/KhaytApp/CappedDownload.swift"), encoding: .utf8)
        #expect(copy.contains("try OutboundGate.shared.require(.lan, url: url)") && !copy.contains("httpMethod") && !copy.contains("uploadTask"))
        let docs = try String(contentsOf: root.deletingLastPathComponent().deletingLastPathComponent().appending(path: "docs/LAN_API.md"), encoding: .utf8)
        #expect(docs.contains("### `GET /api/orders/{id}/timelapse`") && docs.contains("### `POST /api/orders/{id}/timelapse/keep`"))
    }
}
