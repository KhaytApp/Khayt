import XCTest
import KhaytCore
@testable import KhaytCompanion

/// The notification extension follows the shop's "Make no internet calls"
/// switch through `OutboundMirror` in the App Group (follow-up to #2638):
/// what the app's gate follows is written there, and the extension's own
/// gate reads it before its one cloud fetch.
final class OutboundMirrorTests: XCTestCase {
    private let offline: JSONValue = .object(["network": .object(["offline": .bool(true)])])
    private let events = URL(string: "https://cloud.khaytapp.com/v1/shops/S1/events?since=2026-11-22T10:00:00Z")!
    private var suite: UserDefaults!

    override func setUp() {
        suite = UserDefaults(suiteName: "mirror-\(UUID().uuidString)")
        PhoneOutbound.defaults = UserDefaults(suiteName: "outbound-\(UUID().uuidString)")!
        PhoneOutbound.mirror = suite
    }

    override func tearDown() { PhoneOutbound.defaults = .standard; PhoneOutbound.mirror = nil }

    /// Only the keys the rule reads leave the app: settings hold integration
    /// keys, and the App Group is readable by the extension and the widget.
    func testOnlyTheKeysTheRuleReadsAreWritten() throws {
        let settings: JSONValue = .object(["network": .object(["offline": .bool(true)]),
                                           "telemetry": .object(["installCount": .bool(false)]),
                                           "smtpPassword": .string("secret"), "currency": .string("SAR")])
        let data = try XCTUnwrap(OutboundMirror.encode(.settings(settings)))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("SAR"))
        XCTAssertEqual(OutboundMirror.decode(data), .settings(.object(["network": .object(["offline": .bool(true)]),
                                                                       "telemetry": .object(["installCount": .bool(false)])])))
    }

    func testEachBookRoundTrips() {
        for book: OutboundGate.Book in [.none, .unread, .settings(offline), .settings(.object([:]))] {
            XCTAssertEqual(OutboundMirror.decode(OutboundMirror.encode(book)), book)
        }
    }

    /// Settings that are not an object hold everything in the app's gate
    /// (review of this PR): the extension must hold too, never read "no switch".
    func testSettingsThatAreNotAnObjectHoldTheFetch() {
        for odd: JSONValue in [.null, .string("x"), .array([]), .number(1)] {
            let gate = OutboundGate()
            gate.update(book: .settings(odd))
            XCTAssertFalse(gate.verdict(.cloud).allowed, "the app's gate holds \(odd)")
            XCTAssertEqual(OutboundMirror.decode(OutboundMirror.encode(.settings(odd))), .unread)
        }
        let storedNull = Data(#"{"book":"settings","settings":null}"#.utf8)
        XCTAssertEqual(OutboundMirror.decode(storedNull), .unread)
    }

    /// An extension updated before the app ran again has nothing to read: it
    /// fails closed, and the alert stays Apple's generic one.
    func testNothingStoredOrGarbageHoldsTheFetch() {
        XCTAssertEqual(OutboundMirror.decode(nil), .unread)
        XCTAssertEqual(OutboundMirror.decode(Data("not json".utf8)), .unread)
        XCTAssertThrowsError(try OutboundMirror.gate(from: suite).require(.cloud, url: events))
    }

    /// The app's gate and the extension's agree: what the book says reaches
    /// the extension on the same write, and the extension's fetch follows it.
    func testTheExtensionFollowsEveryBookTheAppFollows() {
        OutboundGate.$scoped.withValue(OutboundGate()) {
            // Online first, so the refusal below can only come from the write.
            PhoneOutbound.changed(["settings": .object(["network": .object(["offline": .bool(false)])])])
            XCTAssertNoThrow(try OutboundMirror.gate(from: suite).require(.cloud, url: events))
            PhoneOutbound.changed(["settings": offline])
            XCTAssertThrowsError(try OutboundMirror.gate(from: suite).require(.cloud, url: events),
                                 "the switch on at the Mac stops the extension's fetch")
            PhoneOutbound.changed(["settings": .object(["network": .object(["offline": .bool(false)])])])
            XCTAssertNoThrow(try OutboundMirror.gate(from: suite).require(.cloud, url: events))
            PhoneOutbound.forgotten()
            XCTAssertEqual(OutboundMirror.decode(suite.data(forKey: OutboundMirror.key)), .none)
            XCTAssertNoThrow(try OutboundMirror.gate(from: suite).require(.cloud, url: events),
                             "unpaired: nothing to follow, as the app")
        }
    }
}
