import XCTest
import CryptoKit
import KhaytCore
@testable import KhaytCompanion

/// H1: a floor phone (operator or viewer) keeps no book, so it follows the
/// shop's "make no internet calls" switch from its Mac's SIGNED `/api/status`
/// answer. Until then, and after its book is forgotten on the way down to the
/// floor, the gate holds everything but `lan` (`.unread`), never "online".
/// M2: nothing of the shop's jobs goes back into Spotlight on a floor phone.
@MainActor
final class FloorPhoneGateTests: XCTestCase {

    private var saved: (String, Int, String, Bool, Bool, DeviceKey.Credential?, String)?
    private var settings: ConnectionSettings?
    private static let key = Data(repeating: 9, count: 32)
    private static let identity = "floor-identity"

    override func setUp() async throws {
        PhoneOutbound.defaults = UserDefaults(suiteName: "floor-\(UUID().uuidString)")!
        PhoneOutbound.mirror = nil
        OutboundGate.$scoped.withValue(OutboundGate()) { PhoneOutbound.forgotten() }
        StatusMac.reset()
    }

    override func tearDown() async throws {
        if let saved, let s = settings {
            (s.host, s.port, s.pin, s.isPaired, s.isSampleShop, s.device, s.macIdentityKey) = saved
        }
        PhoneOutbound.paired = { false }
        PhoneOutbound.floor = { false }
        JobSearch.floorPhone = { false }
        StatusMac.reset()
    }

    /// A paired, enrolled phone with no book on disk.
    private func client() -> KhaytAPIClient {
        let s = ConnectionSettings()
        settings = s
        saved = (s.host, s.port, s.pin, s.isPaired, s.isSampleShop, s.device, s.macIdentityKey)
        s.host = StatusMac.host; s.port = 3219; s.pin = "12345678"; s.isPaired = true; s.isSampleShop = false
        s.macIdentityKey = Self.identity
        s.device = .init(deviceId: "dev_floorphone01", key: Self.key.base64EncodedString(), identityKey: Self.identity)
        return KhaytAPIClient(settings: s, protocols: [StatusMac.self], withBook: false)
    }

    private static let on: JSONValue = .object(["offline": .bool(true), "keep": .array([])])

    // MARK: (a) the signed status answer reaches the gate

    func testASignedStatusAnswerSetsTheSwitchOnABooklessPhone() async throws {
        let gate = OutboundGate()
        gate.update(book: .unread)
        StatusMac.network = Self.on
        let api = client()
        try await OutboundGate.$scoped.withValue(gate) {
            let status = try await api.fetchStatus()
            XCTAssertEqual(status.queued, 2)
            XCTAssertEqual(gate.currentBook, .settings(.object(["network": Self.on])), "the Mac's verified word")
            XCTAssertFalse(gate.verdict(.cloud).allowed)
        }
        XCTAssertNotNil(StatusMac.lastDevice, "the status poll is signed, so the Mac may say the switch")
    }

    func testAStatusAnswerWhoseSignatureDoesNotVerifyIsNotBelieved() async throws {
        let gate = OutboundGate()
        gate.update(book: .unread)
        StatusMac.network = .object(["offline": .bool(false), "keep": .array([])])
        StatusMac.forge = true
        let api = client()
        try await OutboundGate.$scoped.withValue(gate) {
            _ = try await api.fetchStatus()
            XCTAssertEqual(gate.currentBook, .unread, "never read as online on an unverified answer")
        }
    }

    // MARK: (b) the app starts the gate knowing a floor phone is one

    func testTheAppTellsTheGateWhetherThisIsAFloorPhone() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "KhaytCompanion/KhaytCompanionApp.swift")
        let text = try String(contentsOf: app, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "PhoneOutbound.start("))
        let call = String(text[start.lowerBound...].prefix(600))
        XCTAssertTrue(call.contains("floor:"), "PhoneOutbound.start is given floor:")
        XCTAssertTrue(call.contains("storedIsFloorPhone"), "…from the phone's role, read from storage")
        // Never through the main actor: the gate may ask from any thread (#2717).
        XCTAssertFalse(text.contains("assumeIsolated { s.isFloorPhone }"))
        XCTAssertFalse(text.contains("assumeIsolated { s.isPaired"))
    }

    // MARK: (c) forgetting the book on the way to the floor leaves the gate held

    func testAFloorPhonesForgottenBookLeavesTheGateUnread() {
        let gate = OutboundGate()
        OutboundGate.$scoped.withValue(gate) {
            PhoneOutbound.changed(["settings": .object(["network": .object(["offline": .bool(false)])])])
            PhoneOutbound.paired = { true }
            PhoneOutbound.floor = { true }
            PhoneOutbound.forgotten()
            XCTAssertEqual(gate.currentBook, .unread, "held until the Mac's signed status says")
            XCTAssertFalse(gate.verdict(.cloud).allowed)
            // Unpaired: nobody to ask, as before.
            PhoneOutbound.paired = { false }
            PhoneOutbound.forgotten()
            XCTAssertEqual(gate.currentBook, OutboundGate.Book.none)
        }
    }

    // MARK: the closures are safe from any thread (#2717 review)

    /// What the app hands the gate and Spotlight, called from a background
    /// queue: answers, never traps, and agrees with the main-actor property.
    func testTheRoleAndPairingAreReadableFromABackgroundQueue() async {
        let s = ConnectionSettings()
        let saved = (s.deviceRole, s.pairedByCode)
        defer { s.deviceRole = saved.0; s.pairedByCode = saved.1 }
        s.pairedByCode = true
        s.deviceRole = "operator"
        let onMain = s.isFloorPhone
        // The closures exactly as the app installs them.
        PhoneOutbound.floor = { ConnectionSettings.storedIsFloorPhone }
        PhoneOutbound.paired = { ConnectionSettings.storedIsPaired }
        JobSearch.floorPhone = { ConnectionSettings.storedIsFloorPhone }
        let gateFloor = PhoneOutbound.floor, gatePaired = PhoneOutbound.paired, spotlightFloor = JobSearch.floorPhone
        let off: (Bool, Bool) = await withCheckedContinuation { done in
            DispatchQueue.global(qos: .background).async {
                XCTAssertFalse(Thread.isMainThread)
                _ = gatePaired()
                XCTAssertEqual(gateFloor(), spotlightFloor())
                done.resume(returning: (gateFloor(), gatePaired()))
            }
        }
        XCTAssertTrue(onMain)
        XCTAssertEqual(off.0, onMain, "the same answer off the main thread")
        s.deviceRole = "manager"
        let manager: Bool = await withCheckedContinuation { done in
            DispatchQueue.global().async { done.resume(returning: ConnectionSettings.storedIsFloorPhone) }
        }
        XCTAssertFalse(manager)
        _ = off.1
    }

    // MARK: M2: no customer names back into Spotlight on a floor phone

    func testAFloorPhoneNeverReindexesSpotlight() async {
        JobSearch.floorPhone = { true }
        let spotlight = FakeIndex()
        await JobSearch.index(now: Date(), into: spotlight)
        XCTAssertEqual(spotlight.calls, ["delete"], "emptied, never filled")
    }
}

/// The Mac's `/api/status`, signing its answer to a signed request with
/// `x-khayt-reply-mac` (`LanServer.replyMac`), and adding `network` only then.
final class StatusMac: URLProtocol, @unchecked Sendable {
    static let host = "khayt-status.invalid"
    nonisolated(unsafe) static var network: JSONValue?
    nonisolated(unsafe) static var forge = false
    nonisolated(unsafe) static var lastDevice: String?

    static func reset() { network = nil; forge = false; lastDevice = nil }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let device = request.value(forHTTPHeaderField: "x-khayt-device")
        let nonce = request.value(forHTTPHeaderField: "x-khayt-nonce")
        Self.lastDevice = device
        var body: [String: JSONValue] = ["queued": .number(2), "pending": .number(1), "printing": .number(1),
                                         "post": .number(0), "qc": .number(0), "completed_today": .number(3)]
        if device != nil, let network = Self.network { body["network"] = network }
        let data = (try? JSONEncoder().encode(JSONValue.object(body))) ?? Data()
        var headers = ["Content-Type": "application/json"]
        if device != nil, let nonce {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let text = "khayt-reply-v1\n\(nonce)\n200\n\(hash)"
            let key = Self.forge ? Data(repeating: 1, count: 32) : Data(repeating: 9, count: 32)
            headers["x-khayt-reply-mac"] = Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8),
                                                                            using: SymmetricKey(data: key))).base64EncodedString()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
