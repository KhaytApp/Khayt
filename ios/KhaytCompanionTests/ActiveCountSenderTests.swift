import KhaytCore
import XCTest
@testable import KhaytCompanion

/// The phone's half of the anonymous install count: when it sends, what it
/// keeps, and that nothing else rides along.
@MainActor
final class ActiveCountSenderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: ConnectionSettings!
    private var savedSwitch = true
    private let day1 = ISO8601DateFormatter().date(from: "2026-10-21T09:00:00Z")!

    override func setUp() {
        defaults = UserDefaults(suiteName: "active-\(UUID().uuidString)")
        settings = ConnectionSettings()
        savedSwitch = settings.countInstall
        settings.countInstall = true
        CountCloud.reset()
    }

    override func tearDown() {
        settings.countInstall = savedSwitch
        CountCloud.reset()
    }

    private func sender(ready: Bool = true, channel: String? = "beta") -> ActiveCountSender {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountCloud.self]
        return ActiveCountSender(settings: settings, defaults: defaults, session: URLSession(configuration: config),
                                 ready: ready, channel: { channel })
    }

    func testOnceADayWithTheSixFieldsAndNothingElse() async throws {
        let s = sender()
        await s.tick(now: day1)
        XCTAssertEqual(CountCloud.bodies.count, 1)
        let body = try XCTUnwrap(CountCloud.bodies.first)
        XCTAssertEqual(Set(body.keys), ["platform", "channel", "version", "firstThisWeek", "firstThisMonth", "firstEver"])
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["channel"] as? String, "beta")
        XCTAssertEqual(body["firstEver"] as? Bool, true)
        XCTAssertEqual(s.state, ActiveCount.State(lastCounted: "2026-10-21", doneDay: "2026-10-21"))

        await s.tick(now: day1.addingTimeInterval(3600))
        XCTAssertEqual(CountCloud.bodies.count, 1, "the same UTC day is done")

        await s.tick(now: day1.addingTimeInterval(86_400))
        XCTAssertEqual(CountCloud.bodies.count, 2)
        XCTAssertEqual(CountCloud.bodies.last?["firstEver"] as? Bool, false)
        XCTAssertEqual(CountCloud.bodies.last?["firstThisWeek"] as? Bool, false, "Wednesday then Thursday: one ISO week")
    }

    func testSwitchedOffSendsNothingAndKeepsTheDates() async {
        let s = sender()
        await s.tick(now: day1)
        settings.countInstall = false
        await s.tick(now: day1.addingTimeInterval(86_400))
        XCTAssertEqual(CountCloud.bodies.count, 1)
        XCTAssertEqual(s.state.lastCounted, "2026-10-21", "back on is not a new install")
    }

    func testHeldUntilReadyAndWithoutAChannel() async {
        await sender(ready: false).tick(now: day1)
        await sender(channel: nil).tick(now: day1)
        XCTAssertTrue(CountCloud.bodies.isEmpty)
    }

    func testAFailedTryKeepsTheDayOwedAndWaitsAnHour() async {
        CountCloud.status = 503
        let s = sender()
        await s.tick(now: day1)
        XCTAssertEqual(s.state, ActiveCount.State())
        CountCloud.status = 200
        await s.tick(now: day1.addingTimeInterval(600))
        XCTAssertEqual(CountCloud.bodies.count, 1, "not again within the hour")
        await s.tick(now: day1.addingTimeInterval(3700))
        XCTAssertEqual(CountCloud.bodies.count, 2)
        XCTAssertEqual(CountCloud.bodies.last?["firstEver"] as? Bool, true, "the failed one counted nothing")
    }

    func testARefusalEndsTheDayWithoutCounting() async {
        CountCloud.status = 422
        let s = sender()
        await s.tick(now: day1)
        XCTAssertEqual(s.state, ActiveCount.State(lastCounted: nil, doneDay: "2026-10-21"))
    }
}

/// `POST /v1/active`, answering with `status`.
final class CountCloud: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var bodies: [[String: Any]] = []

    static func reset() { status = 200; bodies = [] }

    override class func canInit(with request: URLRequest) -> Bool { request.url == ActiveCount.endpoint }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var out = Data(); var buf = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; out.append(buf, count: n) }
            data = out
        }
        if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { Self.bodies.append(json) }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
