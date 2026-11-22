import XCTest
import KhaytCore
@testable import KhaytCompanion

/// The shop's "Make no internet calls" switch on the phone (P8): the book
/// tells the gate, and the phone's own internet calls ask it. Every test runs
/// on a gate of its own (`OutboundGate.$scoped`), never the app's.
final class PhoneOutboundTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private let offline: JSONValue = .object(["network": .object(["offline": .bool(true)])])

    /// `test/fixtures/outbound-vectors.json` through the gate the phone asks,
    /// with the book handed over the way the phone hands it: the rule, not the
    /// phone, decides (a malformed `settings.network` included).
    func testTheSharedVectorsThroughThePhonesGate() throws {
        struct Case: Decodable {
            let why: String; let settings: JSONValue?; let purpose: String; let ctx: Ctx?
            let want: Want
            struct Want: Decodable { let allowed: Bool; let reason: String }
            struct Ctx: Decodable {
                let local: Local?; let host: String?
                struct Local: Decodable { let offline: Bool?; let installCountOff: Bool? }
            }
        }
        struct Vectors: Decodable { let cases: [Case] }
        let v = try JSONDecoder().decode(Vectors.self,
                                         from: Data(contentsOf: root.appending(path: "test/fixtures/outbound-vectors.json")))
        XCTAssertGreaterThanOrEqual(v.cases.count, 40)
        var checked = 0
        for c in v.cases {
            guard let purpose = OutboundPurpose(rawValue: c.purpose) else { continue }   // a typo case: the rule's own
            let gate = OutboundGate()
            switch c.settings {
            case nil, .null?: gate.update(book: .unread)
            case .object(let o)?: gate.update(book: .settings(.object(o)))
            case let other?: gate.update(book: .settings(other))
            }
            gate.update(local: .init(offline: c.ctx?.local?.offline ?? false,
                                     installCountOff: c.ctx?.local?.installCountOff ?? false))
            let got = gate.verdict(purpose, host: c.ctx?.host)
            XCTAssertEqual(got.allowed, c.want.allowed, c.why)
            XCTAssertEqual(got.reason, c.want.reason, c.why)
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 40)
    }

    func testTheBookTheGateIsTold() {
        XCTAssertEqual(PhoneOutbound.book(exists: false, store: nil), .none, "no book: nothing to follow")
        XCTAssertEqual(PhoneOutbound.book(exists: true, store: nil), .unread,
                       "a book that could not be read holds everything but lan")
        XCTAssertEqual(PhoneOutbound.book(exists: true, store: ["printLog": .array([])]), .settings(.object([:])))
        XCTAssertEqual(PhoneOutbound.book(exists: true, store: ["settings": offline]), .settings(offline))
    }

    /// Writing the book tells the gate: the switch turned on at the Mac and
    /// pulled to the phone stops the phone's cloud calls; turned off, they go.
    func testEveryBookWriteTellsTheGate() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "outbound-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = OutboundGate()
        try OutboundGate.$scoped.withValue(gate) {
            let book = CompanionBook(directory: dir)
            var store = SampleShop.book()
            store["settings"] = offline
            try book.replace(with: store, scope: nil)
            XCTAssertFalse(gate.verdict(.cloud).allowed)
            XCTAssertEqual(gate.verdict(.cloud).reason, "offline")
            XCTAssertTrue(gate.verdict(.lan, host: "192.168.1.40").allowed, "the shop's own network still works")
            try book.update { root in root["settings"] = .object(["network": .object(["offline": .bool(false)])]) }
            XCTAssertTrue(gate.verdict(.cloud).allowed)
            book.forget()
            XCTAssertEqual(gate.currentBook, .none)
        }
    }

    /// A Khayt Cloud request is refused where it is built (CloudReader.request,
    /// #2637), so the phone's sync, live channel, push registration and photo
    /// calls never leave the phone while the shop is offline.
    func testACloudRequestIsNeverBuiltWhileOffline() {
        let gate = OutboundGate()
        gate.update(book: .settings(offline))
        OutboundGate.$scoped.withValue(gate) {
            XCTAssertThrowsError(try CloudReader.request(
                CloudReader.Connection(url: "https://cloud.khaytapp.com", shopId: "shop_x", storedToken: ""),
                token: "t", method: "GET", tail: "/live")) { error in
                XCTAssertEqual((error as? OutboundBlocked)?.purpose, .cloud)
            }
        }
    }

    func testABarcodeLookupAsksFirst() async {
        let gate = OutboundGate()
        gate.update(book: .settings(offline))
        await OutboundGate.$scoped.withValue(gate) {
            let lookup = BarcodeLookup()
            do {
                _ = try await lookup.fetch(URLRequest(url: URL(string: BarcodeLookup.endpoint)!))
                XCTFail("an offline shop's phone makes no lookup")
            } catch {
                XCTAssertEqual((error as? OutboundBlocked)?.purpose, .lookups)
            }
        }
        XCTAssertEqual(gate.blocked(.lookups)?.count, 1, "counted for the Settings list")
    }

    /// The install count: refused while the shop is offline (dropped, the
    /// dates kept), and the phone's own switch tells the gate too.
    func testTheInstallCountAsksTheGate() async {
        let defaults = UserDefaults(suiteName: "outbound-count-\(UUID().uuidString)")!
        let settings = ConnectionSettings()
        let saved = settings.countInstall
        settings.countInstall = true
        defer { settings.countInstall = saved }
        CountCloud.reset()
        let config = ActiveCountSender.session.configuration
        config.protocolClasses = [CountCloud.self]
        let sender = ActiveCountSender(settings: settings, defaults: defaults, session: URLSession(configuration: config),
                                       ready: true, channel: { "beta" })
        let gate = OutboundGate()
        gate.update(book: .settings(offline))
        await OutboundGate.$scoped.withValue(gate) {
            await sender.tick(now: Date(timeIntervalSince1970: 1_792_540_800))
        }
        XCTAssertTrue(CountCloud.bodies.isEmpty, "nothing sent while offline")
        XCTAssertNil(sender.state.lastCounted, "a refused count is not a count")
        XCTAssertEqual(gate.currentLocal.installCountOff, false)
        gate.update(book: .settings(.object([:])))
        await OutboundGate.$scoped.withValue(gate) {
            await sender.tick(now: Date(timeIntervalSince1970: 1_792_540_800))
        }
        XCTAssertEqual(CountCloud.bodies.count, 1, "back online, counted")
        CountCloud.reset()
    }
}
