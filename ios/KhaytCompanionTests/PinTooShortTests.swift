import XCTest
@testable import KhaytCompanion

/// The native Mac refuses an owner PIN shorter than 8 characters (#1713).
/// That is a different thing to say than "wrong PIN", and the phone says it.
final class PinTooShortTests: XCTestCase {
    func testTheMacsTooShortReplyIsToldApartFromAWrongPin() {
        let mac = #"{"error":"The LAN PIN is too short. Set a new one of at least 8 characters in Khayt settings to access this data"}"#
        XCTAssertEqual(kind(mac), "pinTooShort")
        XCTAssertEqual(kind(#"{"error":"Unauthorized","reason":"pin-too-short"}"#), "pinTooShort", "a reason code wins")
        XCTAssertEqual(kind(#"{"error":"Unauthorized"}"#), "unauthorized")
        XCTAssertEqual(kind(""), "unauthorized", "an empty 401 is still a wrong PIN")
    }

    func testTheWordsSayWhatToDo() {
        XCTAssertEqual(KhaytAPIError.pinTooShort.errorDescription, L10n.tr("pair.pin.too_short"))
        XCTAssertTrue(L10n.tr("pair.pin.too_short").contains("8"))
    }

    private func kind(_ body: String) -> String {
        switch KhaytAPIClient.unauthorizedKind(Data(body.utf8)) {
        case .pinTooShort: return "pinTooShort"
        case .unauthorized: return "unauthorized"
        default: return "other"
        }
    }
}
