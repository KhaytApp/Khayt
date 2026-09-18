import XCTest
@testable import KhaytCompanion

/**
 * The sentence under "Unpair this device" has to stay true.
 *
 * ── WHY THIS IS A TEST AND NOT A COMMENT ──────────────────────────────────
 *
 * It said "Clears paired state; PIN stays in Keychain until you change it."
 * — in English and in Arabic — long after `unpair()` had started deleting the
 * Keychain item. The audit records that deletion as a fix; nobody went back to
 * the sentence that described the behaviour it replaced. So the app spent that
 * whole time telling a shop its PIN was kept, at the exact moment it was being
 * destroyed, which is the worst direction for a privacy claim to be wrong in.
 *
 * Then it drifted the other way: `unpair()` now also forgets the shop's book,
 * its `.prev` rollback copy and its scope file. The footer had to be rewritten
 * again.
 *
 * Twice is a pattern, and the pattern is that the claim and the code are edited
 * by different people at different times. This pins them together.
 *
 * ── WHAT IT CAN AND CANNOT SEE ────────────────────────────────────────────
 *
 * It reads the source of `unpair()` rather than running it, because
 * `ConnectionSettings` writes through `UserDefaults.standard` and the login
 * Keychain — constructing one in a test would mutate the machine running the
 * test. So this proves the three calls are still THERE, not that they work;
 * `CompanionBookTests` covers whether `forget()` actually removes both copies.
 * A guard that catches a deletion is worth having even when it cannot catch a
 * subtler failure.
 */
final class UnpairTellsTheTruthTests: XCTestCase {

    private func unpairSource() throws -> String {
        let settings = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // KhaytCompanionTests
            .deletingLastPathComponent()          // ios
            .appending(path: "KhaytCompanion/Services/ConnectionSettings.swift")
        let text = try String(contentsOf: settings, encoding: .utf8)
        guard let start = text.range(of: "func unpair()") else {
            throw XCTSkip("unpair() has been renamed — update this guard with it")
        }
        // To the end of the function: the next line that closes at one indent.
        let rest = text[start.lowerBound...]
        guard let end = rest.range(of: "\n    }") else { return String(rest) }
        return String(rest[..<end.upperBound])
    }

    func testUnpairStillRemovesEverythingTheFooterPromises() throws {
        let body = try unpairSource()

        // The PIN. The footer used to promise the opposite of this line.
        XCTAssertTrue(body.contains("KeychainHelper.delete"),
                      "unpair() no longer deletes the PIN, but settings.unpair.footer still says it does")

        // The book — the shop's own records, which this phone keeps now.
        XCTAssertTrue(body.contains("CompanionBook") && body.contains("forget"),
                      "unpair() no longer forgets the shop's book, but settings.unpair.footer says it is deleted")

        // The per-endpoint cache, which holds the client list just as the book does.
        XCTAssertTrue(body.contains("CompanionCache") && body.contains("clear"),
                      "unpair() no longer clears the cached answers — they outlive the pairing")
    }

    func testTheFooterDoesNotClaimThePinIsKept() throws {
        // The exact untruth that shipped, in both languages. Named rather than
        // described, so the failure says which sentence is wrong.
        for language in ["en", "ar"] {
            let strings = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "KhaytCompanion/Resources/\(language).lproj/Localizable.strings")
            let text = try String(contentsOf: strings, encoding: .utf8)
            guard let line = text.split(separator: "\n")
                .first(where: { $0.hasPrefix("\"settings.unpair.footer\"") }) else {
                return XCTFail("settings.unpair.footer is missing from \(language).lproj")
            }
            XCTAssertFalse(line.contains("stays in Keychain") || line.contains("يبقى"),
                           "\(language): the unpair footer claims the PIN is kept; unpair() deletes it")
        }
    }
}
