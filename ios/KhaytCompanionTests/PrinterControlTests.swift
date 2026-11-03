import XCTest
import KhaytCore
@testable import KhaytCompanion

/// Pausing or stopping a print from the phone: the Mac's answer, said; and a
/// reply relayed through the cloud finds the command that asked.
@MainActor
final class PrinterControlTests: XCTestCase {
    override func setUp() async throws { L10n.setLanguage(.en) }
    override func tearDown() async throws { L10n.setLanguage(.system) }

    func testTheMacsRefusalsAreSaid() throws {
        func reply(_ json: String) throws -> PrinterReply { try JSONDecoder().decode(PrinterReply.self, from: Data(json.utf8)) }
        XCTAssertTrue(try reply(#"{"ok":true,"state":"paused"}"#).ok)
        XCTAssertEqual(try reply(#"{"ok":false,"reason":"refused","message":"Door open"}"#).sentence, "The printer said: Door open")
        XCTAssertEqual(try reply(#"{"ok":false,"reason":"device-key-required"}"#).sentence,
                       L10n.tr("printer.why.device"))
        XCTAssertEqual(PrinterReply.failed("something-new").sentence, L10n.tr("printer.why.unreachable"))
    }

    func testARelayedReplyFindsItsCommand() async throws {
        let dek = Data(repeating: 7, count: 32)
        let sealed = try SyncCrypto.seal(["id": .string("cmd-1"), "ok": .bool(true), "state": .string("paused")], dek: dek)
        let ct = try JSONEncoder().encode(sealed)
        let waiting = Task { await PrinterReplies.shared.wait(for: "cmd-1", seconds: 5) }
        await Task.yield()
        PrinterReplies.shared.receive(ct, dek: dek)
        let got = await waiting.value
        XCTAssertEqual(got, PrinterReply(ok: true, state: "paused"))
    }

    func testNoAnswerIsSaidAsSuch() async {
        let got = await PrinterReplies.shared.wait(for: "cmd-none", seconds: 0.1)
        XCTAssertEqual(got.reason, "no-answer")
    }
}
