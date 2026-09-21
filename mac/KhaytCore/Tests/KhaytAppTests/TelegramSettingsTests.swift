import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The screen that sets Telegram up, which this app did not have.
///
/// `Telegram.swift` has sent the shop's messages for as long as it has existed
/// and read `settings.telegram` to do it — a record only the other app could
/// write. The same defect as the email settings, found by the same question:
/// which settings does this app read and never write?
@MainActor
struct TelegramSettingsTests {

    static func book(_ telegram: [String: JSONValue]) -> [String: JSONValue] {
        ["settings": .object(["telegram": .object(telegram)])]
    }

    @Test("reading a configured book fills every switch")
    func draftReadsTheBook() {
        let draft = TelegramSettings.Draft.read(["telegram": .object([
            "botToken": .string("__enc__secret"),
            "chatId": .string("-1001234567890"),
            "notifyOnComplete": .bool(true),
            "notifyPrinterStall": .bool(true),
        ])])
        #expect(draft.chatId == "-1001234567890")
        #expect(draft.onComplete)
        #expect(draft.printerStall)
        // THE TOKEN IS NOT IN THE DRAFT — a draft holding `__enc__secret` puts
        // it in a field's binding, and the next save seals the sealed string.
        #expect(draft.token.isEmpty, "the stored bot token leaked into the draft")
    }

    /// The one that is easy to get backwards, in both directions.
    @Test("the three printer alerts are ON when the book has never said")
    func printerAlertsDefaultOn() {
        // `lib/printer-alerts.js` treats an absent key as ON for error and
        // offline — `tg.notifyPrinterError !== false`. A screen that read them
        // as `false` would draw two switches off that are in fact firing, and
        // a shop turning "on" a switch that was already on changes nothing
        // while appearing to.
        let fresh = TelegramSettings.Draft.read(["telegram": .object([:])])
        #expect(fresh.printerError, "printer errors are alerted unless switched off")
        #expect(fresh.printerOffline, "an offline printer is alerted unless switched off")
        #expect(!fresh.printerStall, "a stall is NOT alerted unless switched on")
        // And an explicit false is honoured rather than defaulted back on.
        let off = TelegramSettings.Draft.read(["telegram": .object([
            "notifyPrinterError": .bool(false),
        ])])
        #expect(!off.printerError, "a shop that switched this off had it switched back on")
    }

    @Test("an empty book reads as a shop that has not set Telegram up")
    func draftReadsNothing() {
        let draft = TelegramSettings.Draft.read([:])
        #expect(draft.chatId.isEmpty)
        #expect(!draft.onComplete && !draft.onHold && !draft.onLowStock)
        #expect(draft.printerError && draft.printerOffline)
    }

    /// The write path, which is the half that did not exist.
    @Test("a saved Telegram setting actually reaches the book")
    func theSaveIsNotSwallowed() async throws {
        let engine = try KhaytEngine()
        var root = Self.book([:])
        try await Shop.applySettings(to: &root, form: [
            "telegram": .object([
                "chatId": .string("  -1001234567890  "),
                "notifyOnComplete": .bool(true),
                "notifyPrinterError": .bool(false),
            ]),
        ], country: nil, engine: engine)

        guard case .object(let settings)? = root["settings"],
              case .object(let tg)? = settings["telegram"] else {
            Issue.record("no telegram was written at all"); return
        }
        #expect(tg["chatId"] == .string("-1001234567890"), "a pasted chat id keeps its spaces")
        #expect(tg["notifyOnComplete"] == .bool(true))
        // An explicit off must survive the defaults.
        #expect(tg["notifyPrinterError"] == .bool(false),
                "switching a printer alert off did not stick")
        #expect(tg["notifyPrinterOffline"] == .bool(true), "an unset alert must stay on")
    }

    @Test("a masked token is kept, and forgetting it is deliberate")
    func tokenSurvivesASave() async throws {
        let engine = try KhaytEngine()
        var root = Self.book(["botToken": .string("__enc__kept"),
                              "chatId": .string("-100")])

        // The field showed dots and nobody typed in it.
        try await Shop.applySettings(to: &root, form: [
            "telegram": .object(["chatId": .string("-200")]),
        ], country: nil, engine: engine)
        #expect(Self.token(root) == "__enc__kept",
                "a save that did not mention the token lost it")

        // Asked for, on purpose.
        try await Shop.applySettings(to: &root, form: [
            "telegram": .object(["botToken": .string("")]),
        ], country: nil, engine: engine)
        #expect(Self.token(root) == "", "the forget switch did not forget anything")
    }

    @Test("a form with no telegram in it leaves the stored settings alone")
    func absentFormChangesNothing() async throws {
        let engine = try KhaytEngine()
        var root = Self.book(["botToken": .string("__enc__kept"),
                              "chatId": .string("-100"),
                              "notifyOnComplete": .bool(true)])
        try await Shop.applySettings(to: &root, form: ["bizEn": .string("Acme")],
                                     country: nil, engine: engine)
        guard case .object(let settings)? = root["settings"],
              case .object(let tg)? = settings["telegram"] else {
            Issue.record("no telegram"); return
        }
        #expect(tg["chatId"] == .string("-100"))
        #expect(tg["notifyOnComplete"] == .bool(true))
        #expect(Self.token(root) == "__enc__kept")
    }

    /// A correct screen nothing opens is the failure this repository keeps
    /// producing.
    @Test("the Telegram settings are actually drawn on a settings page")
    func theScreenIsReachable() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Integrations.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.isEmpty, "Integrations.swift was not read — this would pass vacuously")
        #expect(text.contains("TelegramSettings(shop: shop)"),
                "the Telegram settings screen exists and nothing opens it")
    }

    // MARK: - The warning the switch turns on

    /// The shared rule answers for a configured shop, and says nothing for
    /// every shape of shop that has not asked.
    @Test("the low-stock warning is built by the shared rule, not here")
    func theWarningComesFromTheRule() async throws {
        let engine = try KhaytEngine()
        let spools: [JSONValue] = [
            .object(["id": .string("s1"), "material": .string("PLA Black"),
                     "weight": .number(40), "originalWeight": .number(1000)]),
            .object(["id": .string("s2"), "material": .string("PETG"),
                     "weight": .number(900), "originalWeight": .number(1000)]),
        ]
        let on: [String: JSONValue] = ["telegram": .object([
            "botToken": .string("__enc__t"), "chatId": .string("-100"),
            "notifyOnLowStock": .bool(true),
        ])]

        let warning = try await engine.lowStockWarning(spools, settings: on)
        let said = try #require(warning, "a shop with a nearly-empty spool was told nothing")
        #expect(said.message.contains("PLA Black"), "the empty spool is not named: \(said.message)")
        #expect(!said.message.contains("PETG"), "a full spool was reported as low")
        // The token comes back as it sits in the book — opening it is the
        // app's job, and a rule that decrypted anything would need a Keychain.
        #expect(said.botToken == "__enc__t")
        #expect(said.chatId == "-100")

        // And silence in every shape of "not asked".
        for quiet in [["botToken": JSONValue.string(""), "chatId": .string("-1"),
                       "notifyOnLowStock": .bool(true)],
                      ["botToken": .string("t"), "chatId": .string(""),
                       "notifyOnLowStock": .bool(true)],
                      ["botToken": .string("t"), "chatId": .string("-1"),
                       "notifyOnLowStock": .bool(false)]] {
            let none = try await engine.lowStockWarning(
                spools, settings: ["telegram": .object(quiet)])
            #expect(none == nil, "a shop that did not ask was told anyway")
        }
        // Nothing low, everything configured.
        let full: [JSONValue] = [.object(["id": .string("s2"), "material": .string("PETG"),
                                          "weight": .number(900),
                                          "originalWeight": .number(1000)])]
        #expect(try await engine.lowStockWarning(full, settings: on) == nil,
                "a shop with full spools was warned")
    }

    /// A correct rule nothing calls is the failure this repository keeps
    /// producing, and the reason this file is not finished without it.
    ///
    /// Read as source because the call sits inside `load`, which needs a book
    /// on disk, an engine and a Keychain to run — and because what is being
    /// asserted is that the call EXISTS, which no amount of running proves if
    /// the run never reaches it.
    @Test("something actually sends the warning")
    func theWarningIsWired() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift")
        let shop = try String(contentsOf: url, encoding: .utf8)
        #expect(!shop.isEmpty, "Shop.swift was not read — this would pass vacuously")

        #expect(shop.contains("func warnAboutLowStock("), "the sender is gone")
        #expect(shop.contains("await warnAboutLowStock("),
                "`warnAboutLowStock` exists and nothing calls it — the switch is dead again")
        #expect(shop.contains("engine.lowStockWarning("),
                "the sender does not ask the shared rule")
        #expect(shop.contains("Telegram.send(botToken:"),
                "the sender never reaches Telegram")
        // Once per launch. Without the flag this fires on every load, and this
        // app re-reads the book on every save.
        #expect(shop.contains("guard !lowStockWarned"),
                "the warning is not held to once a launch")
    }

    private static func token(_ root: [String: JSONValue]) -> String? {
        guard case .object(let settings)? = root["settings"],
              case .object(let tg)? = settings["telegram"],
              case .string(let value)? = tg["botToken"] else { return nil }
        return value
    }
}
