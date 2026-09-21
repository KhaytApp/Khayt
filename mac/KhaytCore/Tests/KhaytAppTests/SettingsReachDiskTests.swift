import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The three new settings panes, written to a real file and read back off it.
///
/// ── WHY THIS EXISTS SEPARATELY FROM THE PANES' OWN TESTS ──────────────────
///
/// `EmailSettingsTests`, `TelegramSettingsTests` and `FixedCostsSettingsTests`
/// drive `Shop.applySettings` on a dictionary in memory. That is the half with
/// the rules in it, and it is the half that was broken — `settings-edit.js`
/// ignored all three keys — so it is the right thing to test hardest.
///
/// It is not the whole write. `shop.saveSettings` puts `applySettings` inside
/// `StoreWriter.update`, which reads the book off disk, applies, and swaps the
/// file atomically. A pane could pass every test above and still not save,
/// because nothing had ever run it through the thing that writes.
///
/// ── AND WHY IT IS A TEMP COPY, NOT THE SHOP'S BOOK ────────────────────────
///
/// The obvious way to check a settings screen saves is to open the app and
/// save something. The obvious way is not available here: `Build.development`
/// is `khayt` and `Build.shipped` is `Khayt`, which on a case-insensitive
/// filesystem are ONE directory — so a development build writes to the same
/// book the shop uses every day. There is no isolated book to experiment in,
/// and a test is not a reason to write to somebody's live shop.
///
/// So this copies the sample into a temporary directory and writes there, the
/// way `CloudMergeTests.freshCopy` does. Deliberately the sample and not the
/// real book: a test whose fixture is whatever this Mac happens to hold is a
/// test that reads differently on every machine.
@MainActor
struct SettingsReachDiskTests {

    /// A throwaway book, from the sample, in a directory of its own.
    static func scratchBook() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        let sample = try #require(Bundle.module.url(forResource: "sample-shop",
                                                    withExtension: "json"))
        try Data(contentsOf: sample).write(to: url)
        return url
    }

    /// `saveSettings` without the `Shop` — the same two steps in the same
    /// order, against a book this test owns.
    static func save(_ form: [String: JSONValue], to url: URL) async throws {
        let engine = try KhaytEngine()
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            try await Shop.applySettings(to: &root, form: form, country: nil, engine: engine)
        }
    }

    /// Off the disk, not out of a variable — the point of the exercise.
    static func settingsOnDisk(_ url: URL) throws -> [String: JSONValue] {
        let raw = try JSONDecoder().decode(JSONValue.self, from: try Data(contentsOf: url))
        guard case .object(let root) = raw,
              case .object(let settings)? = root["settings"] else { return [:] }
        return settings
    }

    @Test("all three panes' settings survive a real write and a re-read")
    func theyReachTheFile() async throws {
        let url = try Self.scratchBook()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await Self.save([
            "emailConfig": .object([
                "provider": .string("custom"),
                "smtpHost": .string("smtp.shop.test"),
                "smtpPort": .number(465),
                "fromEmail": .string("orders@shop.test"),
                "triggers": .array([.string("completed")]),
            ]),
            "telegram": .object([
                "chatId": .string("-1001234567890"),
                "notifyOnComplete": .bool(true),
                "notifyPrinterStall": .bool(true),
            ]),
            "fixedCosts": .array([
                .object(["id": .string("a"), "name": .string("Rent"), "amount": .number(3000)]),
                .object(["id": .string("b"), "name": .string("Power"), "amount": .number(450)]),
            ]),
        ], to: url)

        let settings = try Self.settingsOnDisk(url)

        guard case .object(let email)? = settings["emailConfig"] else {
            Issue.record("emailConfig never reached the file"); return
        }
        #expect(email["provider"] == .string("custom"))
        #expect(email["smtpHost"] == .string("smtp.shop.test"))
        #expect(email["smtpPort"] == .number(465))

        guard case .object(let telegram)? = settings["telegram"] else {
            Issue.record("telegram never reached the file"); return
        }
        #expect(telegram["chatId"] == .string("-1001234567890"))
        #expect(telegram["notifyOnComplete"] == .bool(true))
        // The default that is ON when nothing was said, written as stored.
        #expect(telegram["notifyPrinterError"] == .bool(true))

        guard case .array(let costs)? = settings["fixedCosts"] else {
            Issue.record("fixedCosts never reached the file"); return
        }
        #expect(costs.count == 2, "the monthly costs did not survive the write")
    }

    /// A second save must not undo the first — the shape that would make a
    /// shop enter the same thing twice.
    @Test("saving one pane leaves the other two alone on disk")
    func oneSaveDoesNotUndoAnother() async throws {
        let url = try Self.scratchBook()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await Self.save([
            "emailConfig": .object(["provider": .string("sendgrid"),
                                    "apiKey": .string("__enc__k")]),
        ], to: url)
        try await Self.save([
            "fixedCosts": .array([.object(["id": .string("a"),
                                           "name": .string("Rent"),
                                           "amount": .number(3000)])]),
        ], to: url)
        // And something belonging to neither, through the ordinary form path.
        // The shop's NAME goes inside `content`, not at the top level — it is
        // per-language (`bizEn`, `bizAr`) and `settings-edit.js` spreads
        // `f.content` into the result rather than copying named keys.
        try await Self.save(["content": .object(["bizEn": .string("Acme 3D")])], to: url)

        let settings = try Self.settingsOnDisk(url)
        guard case .object(let email)? = settings["emailConfig"],
              case .array(let costs)? = settings["fixedCosts"] else {
            Issue.record("a later save wiped an earlier one"); return
        }
        #expect(email["provider"] == .string("sendgrid"),
                "saving the costs reset the mail provider")
        #expect(email["apiKey"] == .string("__enc__k"),
                "saving something else lost the sealed key")
        #expect(costs.count == 1, "saving the shop's name wiped its monthly costs")
        #expect(settings["bizEn"] == .string("Acme 3D"), "the ordinary save stopped working")
    }
}
