import Foundation

/// An error, said in a way that is safe to write to a log.
///
/// `"\(error)"` of a `URLError` prints its `userInfo`, and that holds the
/// failing URL whole. For a request whose URL IS a secret that writes the
/// secret into the system log: a Telegram bot token sits in the path of
/// `api.telegram.org/bot<token>/…`, and an ntfy topic is the only thing
/// standing between a shop's alerts and anyone who guesses it. So a log line
/// about one of those says what kind of failure it was — the URLError code,
/// the HTTP status — and never the address. Sep 2026 security review.
enum RedactedError {
    static func describe(_ error: Error) -> String {
        switch error {
        case let e as URLError:
            return "URLError \(e.code.rawValue)"
        case let e as Telegram.Failure:
            switch e {
            case .badToken: return "bad token"
            case .badChatId: return "bad chat id"
            case .refused(let status, _): return "HTTP \(status)"
            case .unreachable: return "unreachable"
            }
        case let e as Ntfy.Failure:
            return e.description
        default:
            let ns = error as NSError
            return "\(ns.domain) \(ns.code)"
        }
    }
}
