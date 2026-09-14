import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The shop's Telegram bot.
///
/// The MESSAGE is `lib/telegram-message.js`, tested where it lives against the
/// renderer handler it was lifted from. What is tested here is that this app
/// asks for it correctly, that the two small checks spelled out in Swift agree
/// with the module, that a completion is no longer refused for a shop with a
/// bot, and that a send which fails is SAID rather than swallowed — the whole
/// reason these moves were refused before.
@MainActor
struct TelegramTests {

    static func book(_ telegram: [String: JSONValue], currency: String = "SAR") -> [String: JSONValue] {
        [
            "printLog": .array([.object([
                "id": .string("J1"), "project": .string("Bracket"), "status": .string("printing"),
                "price": .number(400), "parts": .array([]),
            ])]),
            "inventory": .array([]), "consumables": .array([]), "machines": .array([]),
            "clients": .array([]),
            "settings": .object(["currency": .string(currency), "telegram": .object(telegram)]),
        ]
    }

    static let configured: [String: JSONValue] = [
        "botToken": .string("123456:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"),
        "chatId": .string("-100123456"),
        "notifyOnComplete": .bool(true),
    ]

    static func move(_ root: inout [String: JSONValue], _ stage: Stage)
    async throws -> Shop.MoveOutcome {
        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)
        return try await Shop.applyMove(to: &root, id: "J1", stage: stage, engine: engine, words: words)
    }

    // MARK: - The message

    @Test("a shop with a bot gets the message the shared rule writes")
    func message() async throws {
        var root = Self.book(Self.configured)
        let out = try await Self.move(&root, .completed)
        let message = try #require(out.telegram, "the move should have carried a message")
        #expect(message.message.contains("Bracket"))
        // U+202F between the figure and the symbol, exactly as
        // `renderer/currency.js` writes it — see `currencyFollowsTheShopsTable`.
        #expect(message.message.contains("400.00\u{202F}SAR"), "in the shop's own currency")
        #expect(message.chatId == "-100123456")
    }

    /// This message goes to a CUSTOMER, so it has to read the same whichever
    /// app sent it. The price used to be assembled here as
    /// `toFixed(2) + " " + code`, which put the symbol of every
    /// symbol-before currency on the wrong side of the number — "400.00 USD"
    /// where the desktop says "$ 400.00" — and never used the shop's own
    /// currency table at all.
    @Test("the currency follows the shop's own table, on the side it belongs")
    func currencyFollowsTheShopsTable() async throws {
        var dollars = Self.book(Self.configured, currency: "USD")
        let usd = try #require(try await Self.move(&dollars, .completed).telegram)
        #expect(usd.message.contains("$\u{202F}400.00"), "a symbol that goes in front, in front")
        #expect(!usd.message.contains("400.00 USD"))

        var euros = Self.book(Self.configured, currency: "EUR")
        let eur = try #require(try await Self.move(&euros, .completed).telegram)
        #expect(eur.message.contains("€\u{202F}400.00"))

        // A currency the table has never heard of falls back to riyals — and
        // that is asserted here because it is what `renderer/currency.js` and
        // `lib/invoice-document.js` both already do, not because it is good.
        // Relabelling money is a poor failure, but fixing it HERE would put a
        // third opinion on the wire beside an invoice that still says SAR.
        // Khayt's settings only ever offer currencies from the table, so this
        // is reachable by an import rather than by the app.
        var invented = Self.book(Self.configured, currency: "ZZZ")
        let zzz = try #require(try await Self.move(&invented, .completed).telegram)
        #expect(zzz.message.contains("400.00\u{202F}SAR"), "matches the invoice, warts and all")
    }

    @Test("a shop that has not asked for one gets none, and the move still happens")
    func noMessage() async throws {
        for telegram in [[:], ["botToken": JSONValue.string("123:abc")], Self.configured.filter { $0.key != "notifyOnComplete" }] {
            var root = Self.book(telegram)
            let out = try await Self.move(&root, .completed)
            #expect(out.telegram == nil, "\(telegram.keys.sorted())")
            if case .array(let rows)? = root["printLog"], case .object(let job) = rows[0] {
                #expect(Shop.plainString(job["status"]) == "completed", "and the job is finished either way")
            }
        }
    }

    @Test("a completion is no longer refused for a shop whose only integration is a bot")
    func notRefused() async throws {
        // This is what the feature is for. Before it, the move threw whole.
        var root = Self.book(Self.configured)
        _ = try await Self.move(&root, .completed)
        if case .array(let rows)? = root["printLog"], case .object(let job) = rows[0] {
            #expect(Shop.plainString(job["status"]) == "completed")
        } else {
            Issue.record("the job was not written")
        }
    }

    @Test("a move that reaches a bot AND a webhook sends both")
    func bothChannels() async throws {
        let telegram = Self.configured
        var root = Self.book(telegram)
        // A shop with both switched on. This used to be refused whole — the app
        // could send the message but not the webhook, and half a move is worse
        // than none. It can send both now, so it does.
        root["settings"] = .object([
            "currency": .string("SAR"),
            "telegram": .object(telegram),
            "webhooks": .object(["enabled": .bool(true),
                                 "subscriptions": .array([.object([
                                    "id": .string("W1"),
                                    "url": .string("https://example.test/hook"),
                                    "events": .array([.string("status_changed")]),
                                    "enabled": .bool(true)])])]),
        ])
        let out = try await Self.move(&root, .completed)
        #expect(out.telegram != nil, "the bot would be told nothing")
        #expect(out.webhooks.map(\.url) == ["https://example.test/hook"],
                Comment(rawValue: "the consumer would be told nothing: \(out.webhooks.map(\.url))"))
    }

    /// And a channel this app still cannot reach refuses the whole move.
    @Test("a move that would ALSO email the customer is still refused whole")
    func stillRefused() async throws {
        let telegram = Self.configured
        var root = Self.book(telegram)
        root["clients"] = .array([.object(["id": .string("A"), "name": .string("Acme"),
                                           "email": .string("buyer@example.test")])])
        root["printLog"] = .array((Self.rowsOf(root, "printLog")).map { row in
            guard case .object(var job) = row else { return row }
            job["clientId"] = .string("A")
            return .object(job)
        })
        root["settings"] = .object([
            "currency": .string("SAR"),
            "telegram": .object(telegram),
            "emailConfig": .object(["provider": .string("resend"),
                                    "triggers": .array([.string("completed")])]),
        ])
        await #expect(throws: Shop.MoveRefused.self) {
            _ = try await Self.move(&root, .completed)
        }
    }

    static func rowsOf(_ root: [String: JSONValue], _ collection: String) -> [JSONValue] {
        if case .array(let r)? = root[collection] { return r }
        return []
    }

    // MARK: - The two checks spelled out in Swift

    @Test("the token and chat-id checks agree with the shared rule")
    func checksAgree() async throws {
        let engine = try KhaytEngine()
        for token in ["123456:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw", "", "nope", "123456", "1:a b", "1:a-b_c"] {
            let theirs = try await engine.raw("KhaytTelegramMessage.isBotToken(\(Self.json(token)))", as: Bool.self)
            #expect(KhaytTelegram.isBotToken(token) == theirs, "\(token)")
        }
        // A chat id is one of the two shapes Telegram documents, or nothing —
        // and the Swift copy has to agree with the module about which is which,
        // because this app sends on the strength of it.
        for id in [" -100123456 ", "@khaytshop", "khaytshop", " @Khayt_Shop ", "12345678",
                   "123; rm -rf /", "", "@my-shop", "@abc"] {
            let theirs = try await engine.raw("KhaytTelegramMessage.chatId(\(Self.json(id)))",
                                              as: String?.self)
            #expect(KhaytTelegram.chatId(id) == theirs, "\(id)")
        }
    }

    static func json(_ s: String) -> String {
        String(data: (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
    }

    // MARK: - Sending

    @Test("a bot token that cannot be one is refused before anything is sent")
    func badToken() async throws {
        await #expect(throws: Telegram.Failure.badToken) {
            try await Telegram.send(botToken: "not-a-token", chatId: "1", message: "x")
        }
    }

    @Test("a chat id Telegram cannot deliver to is refused, rather than mangled")
    func badChatId() async throws {
        // Khayt used to strip with `[^0-9@-]`, so "@khaytshop" became "@" and
        // the shop was sending to nowhere with nothing said.
        let token = "123456:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"
        for bad in ["", "  ", "@my-shop", "@abc", "not a chat"] {
            await #expect(throws: Telegram.Failure.badChatId, "\(bad)") {
                try await Telegram.send(botToken: token, chatId: bad, message: "x")
            }
        }
        #expect(KhaytTelegram.chatId("@khaytshop") == "@khaytshop", "and a real one goes through whole")
    }

    @Test("what Telegram says when it refuses is passed on")
    func refusal() {
        // A shop can act on "chat not found"; it cannot act on a bare 400.
        #expect(Shop.describe(.refused(400, "chat not found")) == "chat not found")
        #expect(Shop.describe(.refused(400, "")) == "HTTP 400")
        #expect(Shop.describe(.badToken).contains("Settings"))
        #expect(Shop.describe(.badChatId).contains("chat ID"))
    }
}
