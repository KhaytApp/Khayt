import XCTest
import CryptoKit
import KhaytCore
@testable import KhaytCompanion

/// A phone that keeps no book (a floor phone) learns the shop's "make no
/// internet calls" switch from the paired Mac's signed `/api/status` answer
/// (#2640). Believed ONLY when `x-khayt-reply-mac` verifies; anything else is
/// "no answer", never "online". Each test on its own gate.
final class PhoneOutboundStatusTests: XCTestCase {

    private let key = Data(repeating: 7, count: 32)
    private var credential: DeviceKey.Credential {
        .init(deviceId: "dev_abcdefghijkl", key: key.base64EncodedString(), identityKey: "id")
    }
    private let nonce = "n-0123456789"

    /// The Mac's `LanServer.replyMac`, written out here on its own so the
    /// phone's check is held to the Mac's formula, not to itself.
    private func macSigns(_ body: Data, status: Int = 200, nonce: String? = nil, key: Data? = nil) -> String {
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let text = "khayt-reply-v1\n\(nonce ?? self.nonce)\n\(status)\n\(hash)"
        return Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key ?? self.key)))
            .base64EncodedString()
    }

    private func body(_ network: String?) -> Data {
        Data(("{\"queued\":2,\"pending\":1" + (network.map { ",\"network\":\($0)" } ?? "") + "}").utf8)
    }

    private func read(_ b: Data, mac: String?, status: Int = 200) -> PhoneOutbound.StatusNetwork {
        PhoneOutbound.StatusNetwork.read(credential, nonce: nonce, status: status, body: b, replyMac: mac)
    }

    override func setUp() {
        PhoneOutbound.defaults = UserDefaults(suiteName: "status-\(UUID().uuidString)")!
        // Other suites leave a book "held"; start each test bookless.
        OutboundGate.$scoped.withValue(OutboundGate()) { PhoneOutbound.forgotten() }
    }

    /// A fixed vector computed outside Swift (Node's crypto, the formula in
    /// `LanServer.replyMac`), so the phone is held to the Mac's bytes and not
    /// only to this file's restatement of them.
    func testAFixedReplyVector() {
        let b = Data(#"{"queued":2,"pending":1,"network":{"offline":true,"keep":["updates"]}}"#.utf8)
        XCTAssertTrue(DeviceKey.verifiesReply(credential, nonce: nonce, status: 200, body: b,
                                              replyMac: "O5DNu7znRwbgnoq0rdzFnBdFO9mGr0IKpsCbtD5d8gU="))
        XCTAssertEqual(macSigns(b), "O5DNu7znRwbgnoq0rdzFnBdFO9mGr0IKpsCbtD5d8gU=")
    }

    /// A book held, or arriving during the status request, always wins.
    func testABookHeldWinsOverAStatusAnswer() {
        let gate = OutboundGate()
        OutboundGate.$scoped.withValue(gate) {
            PhoneOutbound.changed(["settings": .object(["network": .object(["offline": .bool(false)])])])
            PhoneOutbound.statusAnswer(.network(.object(["offline": .bool(true)])))
            XCTAssertTrue(gate.verdict(.cloud).allowed, "the book's settings, not the status answer")
            XCTAssertEqual(PhoneOutbound.bookless(paired: true), .unread, "nothing saved while a book is held")
            PhoneOutbound.forgotten()
        }
    }

    /// Losing the credential (a sign-out, or a forged `device-revoked` on the
    /// Wi-Fi) never turns a verified offline into online; nor does a launch
    /// before the first unlock.
    func testAVerifiedBlockOutlivesTheCredential() {
        OutboundGate.$scoped.withValue(OutboundGate()) {
            XCTAssertEqual(PhoneOutbound.bookless(paired: false, dataAvailable: false), .unread, "before first unlock")
            let on: JSONValue = .object(["offline": .bool(true), "keep": .array([])])
            PhoneOutbound.statusAnswer(.network(on))
            XCTAssertEqual(PhoneOutbound.bookless(paired: false), .settings(.object(["network": on])),
                           "no credential any more: the verified block still stands")
        }
    }
    override func tearDown() { PhoneOutbound.defaults = .standard }

    func testOnlyAVerifiedAnswerIsBelieved() {
        let on = body(#"{"offline":true,"keep":["updates"]}"#)
        XCTAssertEqual(read(on, mac: macSigns(on)),
                       .network(.object(["offline": .bool(true), "keep": .array([.string("updates")])])))
        XCTAssertEqual(read(on, mac: nil), .noAnswer, "unsigned: anything on the Wi-Fi could send it")
        XCTAssertEqual(read(on, mac: "not base64 !"), .noAnswer)
        XCTAssertEqual(read(on, mac: macSigns(on, key: Data(repeating: 8, count: 32))), .noAnswer, "another key")
        XCTAssertEqual(read(on, mac: macSigns(on, nonce: "another-request")), .noAnswer, "a replayed answer")
        XCTAssertEqual(read(on, mac: macSigns(on, status: 201)), .noAnswer, "signed for another status")
        let off = body(#"{"offline":false,"keep":[]}"#)
        XCTAssertEqual(read(off, mac: macSigns(on)), .noAnswer, "a body swapped under a real signature")
        // Signed, but no block (an older Mac's counts, signed): no answer.
        let plain = body(nil)
        XCTAssertEqual(read(plain, mac: macSigns(plain)), .noAnswer)
        // Signed, a block that is present but not an object: passed as sent.
        let junk = body(#""x""#)
        XCTAssertEqual(read(junk, mac: macSigns(junk)), .network(.string("x")))
    }

    /// Verified blocks go to the gate; "no answer" keeps the last verified
    /// one; a malformed block reads offline (the shared vectors' rule).
    func testTheGateFollowsVerifiedAnswersOnly() {
        let gate = OutboundGate()
        OutboundGate.$scoped.withValue(gate) {
            gate.update(book: PhoneOutbound.bookless(paired: true))
            XCTAssertEqual(gate.currentBook, .unread, "first launch, never told: held")
            XCTAssertFalse(gate.verdict(.cloud).allowed)
            XCTAssertTrue(gate.verdict(.lan, host: "192.168.1.40").allowed, "the shop's own network still works")

            PhoneOutbound.statusAnswer(.network(.object(["offline": .bool(false), "keep": .array([])])))
            XCTAssertTrue(gate.verdict(.cloud).allowed, "the Mac said online, signed")

            PhoneOutbound.statusAnswer(.network(.object(["offline": .bool(true), "keep": .array([.string("updates")])])))
            XCTAssertFalse(gate.verdict(.cloud).allowed)
            XCTAssertEqual(gate.verdict(.cloud).reason, "offline")
            XCTAssertTrue(gate.verdict(.updates).allowed, "a kept purpose")

            PhoneOutbound.statusAnswer(.noAnswer)
            XCTAssertFalse(gate.verdict(.cloud).allowed, "no answer never turns the switch off")

            for junk: JSONValue in [.string("x"), .bool(true), .array([]), .null, .number(1)] {
                PhoneOutbound.statusAnswer(.network(junk))
                XCTAssertFalse(gate.verdict(.cloud).allowed, "malformed \(junk): offline")
            }
        }
    }

    /// The last verified block is what the next launch starts from; an
    /// unpaired phone has nobody to ask; forgetting the Mac forgets it.
    func testTheNextLaunchStartsFromTheLastVerifiedBlock() {
        OutboundGate.$scoped.withValue(OutboundGate()) {
            XCTAssertEqual(PhoneOutbound.bookless(paired: false), .none)
            XCTAssertEqual(PhoneOutbound.bookless(paired: true), .unread)
            let on: JSONValue = .object(["offline": .bool(true), "keep": .array([])])
            PhoneOutbound.statusAnswer(.network(on))
            XCTAssertEqual(PhoneOutbound.bookless(paired: true), .settings(.object(["network": on])))
            PhoneOutbound.statusAnswer(.noAnswer)
            XCTAssertEqual(PhoneOutbound.bookless(paired: true), .settings(.object(["network": on])), "kept")
            PhoneOutbound.forgotten()
            XCTAssertEqual(PhoneOutbound.bookless(paired: true), .unread)
        }
    }
}
