import UserNotifications
import XCTest
@testable import KhaytCompanion

/// A print that stopped in a way the Mac cannot name is "ended", said
/// neutrally, and any outcome or phase this build does not know reads the same,
/// never a failed decode (Nov 14: a finished print was alerted as cancelled;
/// the Mac will send `ended` when it cannot tell).
final class PrintEndedOutcomeTests: XCTestCase {
    private func event(_ outcome: String) throws -> PrintFinished {
        let json = #"{"v":1,"kind":"print-finished","at":"2026-11-14T04:30:00Z","machineId":"M1","machineName":"U1","orderId":"KH-1","project":null,"client":null,"filename":"a.gcode","durationS":3600,"outcome":"\#(outcome)","photo":false,"advancedTo":null}"#
        return try JSONDecoder().decode(PrintFinished.self, from: Data(json.utf8))
    }

    func testEndedAndAnUnknownOutcomeBothDecodeToEnded() throws {
        XCTAssertEqual(try event("ended").outcome, .ended)
        XCTAssertEqual(try event("something-new").outcome, .ended)
        XCTAssertEqual(try event("finished").outcome, .finished, "the known ones are unchanged")
        XCTAssertEqual(try event("cancelled").outcome, .cancelled)
    }

    func testTheAlertSaysItNeutrallyWithNoButton() throws {
        for raw in ["ended", "something-new"] {
            let e = try event(raw)
            let c = PrintAlertText.content(for: e, orderStatus: "printing") { $0 }
            XCTAssertEqual(c.title, "alert.print.ended", raw)
            XCTAssertEqual(c.interruptionLevel, .active, "not through Focus")
            XCTAssertNil(PrintAlertAction.offered(for: e, orderStatus: "printing"), "neither move fits an unknown ending")
            XCTAssertEqual(c.categoryIdentifier, PrintAlertAction.infoCategory)
        }
    }

    func testTheNeutralLineHasWordsInEveryLanguage() {
        for lang in AppLanguage.allCases where lang != .system {
            L10n.setLanguage(lang)
            let line = L10n.tr("alert.print.ended")
            XCTAssertNotEqual(line, "alert.print.ended", "\(lang)")
            XCTAssertNotEqual(line, L10n.tr("alert.print.cancelled"), "\(lang): never reads as cancelled")
        }
        L10n.setLanguage(.system)
        XCTAssertTrue(PrintAlertText.keys.contains("alert.print.ended"), "the extension carries it too")
    }

    /// The extension finds the job's stage in the alert index whatever the
    /// outcome: decoding no longer fails, so the rewrite still happens.
    func testTheAlertIndexIsReadForAnEndedPrint() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ended-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        AlertIndex.write(["KH-1": "printing"], to: dir)
        let e = try event("something-new")
        let status = e.orderId.flatMap { AlertIndex.status(of: $0, in: dir) }
        XCTAssertEqual(status, "printing")
        XCTAssertEqual(PrintAlertText.content(for: e, orderStatus: status) { $0 }.userInfo["orderId"] as? String, "KH-1")
    }

    func testTheFeedShowsItQuietly() throws {
        let item = ShopFeed.item(for: try event("ended"), id: "x") { $0 }
        XCTAssertEqual(item.tone, FeedItem.Tone.none)
    }

    // MARK: Live Activity

    typealias State = PrintActivityAttributes.ContentState

    private func state(_ phase: String) throws -> State {
        try JSONDecoder().decode(State.self, from: Data(#"{"phase":"\#(phase)","progress":97}"#.utf8))
    }

    func testALiveActivityTakesEndedAndUnknownPhases() throws {
        XCTAssertEqual(try state("ended").phase, .ended)
        XCTAssertEqual(try state("something-new").phase, .ended, "a newer Mac's word never drops the update")
        XCTAssertEqual(try state("printing").phase, .printing)
        XCTAssertNil(PrintActivityText.move(.ended), "no move for an unknown ending")
        XCTAssertFalse(PrintActivityText.showsPercent(.ended))
        XCTAssertEqual(PrintActivityText.shownProgress(try state("ended")), 97, "not claimed whole")
    }

    func testTheLiveActivityWordsExistInEveryLanguage() throws {
        let widget = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "KhaytWidget")
        for lang in ["en", "ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            let table = try XCTUnwrap(NSDictionary(contentsOf: widget.appending(path: "\(lang).lproj/Localizable.strings")) as? [String: String])
            XCTAssertNotNil(table["Print ended — check the printer"], lang)
            XCTAssertNotNil(table["Ended"], lang)
        }
    }
}
