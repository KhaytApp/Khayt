import Foundation
import Testing
@testable import KhaytCore

/// What the shop's bot says, against the JavaScript it came from.
///
/// This message goes to a CUSTOMER, so the two apps saying it differently is
/// the shop speaking with two voices about one job.
@MainActor
struct TelegramBotParityTests {

    private func js() throws -> JSModule { try JSModule(["telegram-message"]) }

    /// `fmtPrice` is the caller's on both sides, so the harness passes the same
    /// trivial one to each and the message is compared whole.
    private func theirs(_ js: JSModule, _ order: JSONValue, _ status: String,
                        _ settings: [String: JSONValue]) throws -> TelegramMessage? {
        let v = try js.value("""
            KhaytTelegramMessage.forStatus(ARG0, ARG1, {
              settings: ARG2, fmtPrice: function (n) { return 'P' + String(n); },
            })
            """, [order, .string(status), .object(settings)])
        guard case .object(let o) = v else { return nil }
        func text(_ k: String) -> String { if case .string(let s)? = o[k] { return s }; return "" }
        return .init(botToken: text("botToken"), chatId: text("chatId"), message: text("message"))
    }

    private func check(_ order: JSONValue, _ status: String, _ settings: [String: JSONValue],
                       _ what: String, _ js: JSModule) throws {
        let mine = TelegramBot.forStatus(order, newStatus: status, settings: settings,
                                         money: { "P" + TelegramBot.jsString($0) })
        let theirs = try theirs(js, order, status, settings)
        #expect(mine == theirs, Comment(rawValue: """
            \(what)
              swift \(String(describing: mine))
              js    \(String(describing: theirs))
            """))
    }

    private func bot(complete: Bool = true, hold: Bool = true,
                     token: JSONValue = .string("123456:AAH"),
                     chat: JSONValue = .string("-100123")) -> [String: JSONValue] {
        ["telegram": .object(["botToken": token, "chatId": chat,
                              "notifyOnComplete": .bool(complete),
                              "notifyOnHold": .bool(hold)])]
    }

    private func job(project: JSONValue = .string("Dragon"), id: JSONValue = .string("A-1"),
                     price: JSONValue = .number(240), hold: JSONValue? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["project": project, "id": id, "price": price]
        if let hold { o["holdReason"] = hold }
        return .object(o)
    }

    @Test("the two moves the shop asked to be told about")
    func theTwoMoves() throws {
        let js = try js()
        for status in ["completed", "on_hold", "printing", "delivered", "cancelled", "", "quote"] {
            try check(job(), status, bot(), "a \(status.debugDescription) move", js)
        }
        try check(job(hold: .string("waiting on filament")), "on_hold", bot(), "a reason", js)
        try check(job(hold: .string("")), "on_hold", bot(), "an empty reason", js)
        try check(job(hold: .null), "on_hold", bot(), "a null reason", js)
    }

    @Test("a switch the shop turned off says nothing")
    func switchesOff() throws {
        let js = try js()
        for (complete, hold) in [(true, false), (false, true), (false, false)] {
            try check(job(), "completed", bot(complete: complete, hold: hold),
                      "complete \(complete) hold \(hold)", js)
            try check(job(), "on_hold", bot(complete: complete, hold: hold),
                      "complete \(complete) hold \(hold)", js)
        }
    }

    @Test("no bot configured says nothing at all")
    func noBot() throws {
        let js = try js()
        try check(job(), "completed", [:], "no telegram settings", js)
        try check(job(), "completed", ["telegram": .null], "a null bot", js)
        try check(job(), "completed", ["telegram": .object([:])], "an empty bot", js)
        try check(job(), "completed", bot(token: .string("")), "no token", js)
        try check(job(), "completed", bot(chat: .string("")), "no chat", js)
        try check(job(), "completed", ["telegram": .string("yes")], "a bot that is a string", js)
    }

    @Test("a job with no project falls back to its id")
    func projectFallback() throws {
        let js = try js()
        try check(job(project: .string("")), "completed", bot(), "no project", js)
        try check(job(project: .null), "completed", bot(), "a null project", js)
        try check(job(project: .null, id: .null), "completed", bot(), "neither", js)
        try check(.object([:]), "completed", bot(), "an empty order", js)
        try check(.null, "completed", bot(), "no order at all", js)
    }

    @Test("customer text cannot forge a second line")
    func safeText() throws {
        let js = try js()
        for raw in ["a\nb", "a\r\nb", "a\tb", "\n\n\n", String(repeating: "x", count: 250),
                    String(repeating: "🌸", count: 150), "زهرة\nورد", "ok"] {
            let mine = TelegramBot.safe(raw)
            let theirs = try js.value("KhaytTelegramMessage.safe(ARG0)", [.string(raw)])
            #expect(.string(mine) == theirs, Comment(rawValue: raw.debugDescription))
            try check(job(project: .string(raw)), "completed", bot(), "a forged name", js)
        }
        for raw: JSONValue in [.null, .number(3), .bool(true), .array([]), .object([:])] {
            #expect(.string(TelegramBot.safe(raw))
                    == (try js.value("KhaytTelegramMessage.safe(ARG0)", [raw])),
                    Comment(rawValue: "\(raw)"))
        }
    }

    @Test("the price is whatever the app writes it as")
    func priceIsTheApps() throws {
        let js = try js()
        for price: JSONValue in [.number(240), .number(0), .number(-5), .number(1234.5),
                                 .string("240"), .null, .bool(true)] {
            try check(job(price: price), "completed", bot(), "a price of \(price)", js)
        }
    }

    @Test("a bot token is one Telegram could accept, or it is refused")
    func botTokens() throws {
        let js = try js()
        for token in ["123456:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw", "", "nope", "123456",
                      "1:a b", "1:a-b_c", ":abc", "12:", "12:abc\n", " 12:abc",
                      "12:abc ", "١٢٣:abc"] {
            let theirs = try js.value("KhaytTelegramMessage.isBotToken(ARG0)", [.string(token)])
            #expect(.bool(TelegramBot.isBotToken(token)) == theirs,
                    Comment(rawValue: token.debugDescription))
        }
    }

    @Test("a chat id is refused rather than mangled")
    func chatIds() throws {
        let js = try js()
        for id in [" -100123456 ", "@khaytshop", "khaytshop", " @Khayt_Shop ", "12345678",
                   "123; rm -rf /", "", "  ", "@my-shop", "@abc", "@12345", "_____",
                   "@" + String(repeating: "a", count: 32), "@" + String(repeating: "a", count: 33),
                   "@@khaytshop", "-0", "007", "@zahra_شوب"] {
            let theirs = try js.value("KhaytTelegramMessage.chatId(ARG0)", [.string(id)])
            let mine = TelegramBot.chatId(id)
            #expect(mine.map(JSONValue.string) ?? .null == theirs,
                    Comment(rawValue: id.debugDescription))
            #expect(TelegramBot.isChatId(id) == (mine != nil))
        }
    }

    @Test("Telegram's own message limit is the same number on both sides")
    func maxMessage() throws {
        let js = try js()
        #expect(try js.value("KhaytTelegramMessage.MAX_MESSAGE", [])
                == .number(Double(TelegramBot.maxMessage)))
    }
}
