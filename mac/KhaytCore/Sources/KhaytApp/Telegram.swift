import Foundation
import KhaytCore

/// The shop's Telegram bot.
///
/// The MESSAGE is `lib/telegram-message.js`, so this app says exactly what
/// Khayt says. Only the sending is native, because sending is a platform's
/// job — Electron has its main process, this has URLSession.
///
/// This exists to remove a real blocker rather than to add a feature: a move
/// that would reach outside the shop is refused whole, so a shop whose only
/// integration is a Telegram bot could not finish a job on the Mac at all.
enum Telegram {

    /// What went wrong, in terms a shop can act on.
    enum Failure: Error, Equatable {
        /// The bot token in Settings cannot be a Telegram token.
        case badToken
        /// The chat id in Settings is not one Telegram can deliver to.
        case badChatId
        /// Telegram answered, and said no.
        case refused(Int, String)
        /// It could not be reached at all.
        case unreachable(String)
    }

    /// Send one message, and wait for Telegram to say it took it.
    ///
    /// AWAITED, not fired and forgotten. The whole reason the Mac refused
    /// these moves is that a piece of the move could not be done; a send whose
    /// result nobody looks at would put the app back where it started, with a
    /// job marked complete and a customer never told.
    static func send(botToken: String, chatId: String, message: String,
                     session: URLSession = .shared) async throws {
        guard KhaytTelegram.isBotToken(botToken) else { throw Failure.badToken }
        // Refused before anything is sent, and named: a mangled chat id sends
        // to nowhere and reports a bare 400.
        guard let chat = KhaytTelegram.chatId(chatId) else { throw Failure.badChatId }
        // Percent-encoded into the path, as the Electron handler does: a token
        // is not a path component a URL should be trusted to parse.
        // The same set `encodeURIComponent` uses, which is what the Electron
        // handler builds this path with. A bot token carries `:` and often `-`
        // and `_`; escaping more than Telegram's own clients do is a difference
        // with nothing to gain.
        let escaped = botToken.uriComponent
        guard let url = URL(string: "https://api.telegram.org/bot\(escaped)/sendMessage") else {
            throw Failure.badToken
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Ten seconds, the same as Electron's. A shop finishing a job should
        // not wait on a network that is not answering.
        request.timeoutInterval = 10
        request.httpBody = try JSONEncoder().encode([
            "chat_id": chat,
            "text": String(message.prefix(KhaytTelegram.maxMessage)),
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Telegram says why in `description`, and it is worth passing on:
            // "chat not found" is a settings mistake a shop can fix, and a
            // bare 400 is not.
            var why = ""
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                why = body["description"] as? String ?? ""
            }
            throw Failure.refused(status, why)
        }
    }
}

/// The message rule, as this app reaches it.
///
/// One name for the call sites; every decision is `KhaytCore.TelegramBot`,
/// which is where the rule now lives. It used to be spelled out twice — once
/// in `lib/telegram-message.js` and once here — with a test holding the two
/// together. There is one copy now, and the phone can reach it.
enum KhaytTelegram {
    static let maxMessage = TelegramBot.maxMessage
    static func isBotToken(_ token: String) -> Bool { TelegramBot.isBotToken(token) }
    static func chatId(_ value: String) -> String? { TelegramBot.chatId(value) }
}
