import XCTest
@testable import KhaytCompanion

/// "Taken off" and "Bed is clear" on the phone's printer panel
/// (`POST /api/printer/{id}/bed-clear`, docs/LAN_API.md; the signed frame
/// "Printer states · iPhone (Nov 21)"). Sample data only.
@MainActor
final class BedClearTests: XCTestCase {

    private func reply(_ status: Int, _ body: String) -> PrinterReply {
        KhaytAPIClient.bedClearReply(status: status, body: Data(body.utf8))
    }

    func testEachAnswerTheRouteGives() {
        XCTAssertTrue(reply(200, #"{"ok":true,"bedClearedAt":"2026-11-22T14:07:05.120Z"}"#).ok)
        XCTAssertEqual(reply(404, #"{"ok":false,"reason":"not-found"}"#).reason, "not-found")
        XCTAssertEqual(reply(409, #"{"ok":false,"reason":"read-only"}"#).reason, "read-only")
        XCTAssertEqual(reply(500, #"{"ok":false,"reason":"not-saved","message":"another computer holds the book"}"#).reason, "not-saved")
        XCTAssertEqual(reply(503, #"{"ok":false,"reason":"busy"}"#).reason, "busy")
        XCTAssertEqual(reply(403, #"{"ok":false,"reason":"device-key-required"}"#).reason, "device-key-required")
        // The role refusal has no `ok` field.
        XCTAssertEqual(reply(403, #"{"reason":"role-scope","required":"machines:control"}"#).reason, "role-scope")
        XCTAssertFalse(reply(403, #"{"reason":"role-scope","required":"machines:control"}"#).ok)
        // A computer from before the route, and nonsense.
        XCTAssertEqual(reply(404, "Not found").reason, "not-offered")
        XCTAssertEqual(reply(502, "").reason, "unreachable")
        XCTAssertFalse(reply(500, #"{"ok":true}"#).ok, "done only on a 200 that says so")
    }

    func testEveryRefusalHasItsOwnSentence() {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        var seen: Set<String> = []
        for reason in ["not-found", "read-only", "not-saved", "busy", "device-key-required", "role-scope", "not-offered", "no-answer", "unreachable"] {
            let words = PrinterReply.failed(reason).sentence
            XCTAssertFalse(words.isEmpty || words.hasPrefix("printer.why."), reason)
            seen.insert(words)
        }
        XCTAssertEqual(seen.count, 9, "no two refusals share a sentence")
        XCTAssertEqual(PrinterReply.failed("read-only").sentence, "The Mac is showing the sample shop, which cannot be changed.")
    }

    func testWhichReasonsATapCanEnd() {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        XCTAssertEqual(PrinterNeedsPanel.clearWords("print-to-take-off"), "Taken off")
        XCTAssertEqual(PrinterNeedsPanel.clearWords("bed-to-clear"), "Bed is clear")
        XCTAssertNil(PrinterNeedsPanel.clearWords("filament-runout"), "loaded at the printer, not from the phone")
        XCTAssertNil(PrinterNeedsPanel.clearWords("printer-attention"))
        XCTAssertNil(PrinterNeedsPanel.clearWords("something-new"))
    }

    func testTheButtonShowsOnlyWhereTheMacWouldTakeIt() {
        XCTAssertTrue(PrinterNeedsPanel.mayClear(canControl: true, macInReach: true, sampleShop: false))
        XCTAssertFalse(PrinterNeedsPanel.mayClear(canControl: false, macInReach: true, sampleShop: false), "a viewer's phone")
        XCTAssertFalse(PrinterNeedsPanel.mayClear(canControl: true, macInReach: false, sampleShop: false), "away from the shop's Wi-Fi")
        XCTAssertFalse(PrinterNeedsPanel.mayClear(canControl: true, macInReach: true, sampleShop: true))
        // The roles, through the table the Mac checks with.
        for (role, may) in [("owner", true), ("manager", true), ("operator", true), ("viewer", false)] {
            XCTAssertEqual(DeviceRole.allows(role, "machines:control"), may, role)
        }
    }

    func testTheWordsAreInAllNineLanguages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for lang in ["en", "ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            let url = root.appending(path: "KhaytCompanion/Resources/\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
            for key in ["waiting.do.taken_off", "waiting.do.bed_clear", "printer.why.read_only", "printer.why.not_saved", "printer.why.role"] {
                XCTAssertFalse((table[key] ?? "").isEmpty, "\(lang): \(key)")
            }
        }
    }
}
