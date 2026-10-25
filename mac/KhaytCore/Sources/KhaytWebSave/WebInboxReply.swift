import Foundation

/// ── ONE ANSWER, WHICHEVER BROWSER ASKED ──────────────────────────────────
///
/// The Safari extension's handler and the browser host (`khayt-browser-host`,
/// for Chrome, Edge, Brave, Vivaldi and Firefox) are two doors into the same
/// room. Both hand the extension's message here, as bytes, and send back
/// whatever this returns — so a save from Chrome is checked, written and
/// answered by exactly the code a save from Safari is.
///
/// It never opens the book, never fetches anything and never starts the app.
/// It checks the message (`WebSave`), writes it into the inbox, and waits a
/// few seconds for the app's answer.
extension WebInbox {

    /// How long the popup is kept waiting for the app's answer while it is
    /// open, and how long when it is not (an answer cannot come; this only
    /// gives a just-launched app its moment).
    public static let answerWait: TimeInterval = 4
    public static let answerWaitClosed: TimeInterval = 0.5

    /// The answer to one message from the extension.
    ///
    /// - `ping`: whether a save can go anywhere (`ready`, or `no-inbox` for a
    ///   build with no app group), and whether the app is open.
    /// - `save` / `attach`: checked, written, and the app's answer — or
    ///   `queued` when none came in time.
    /// - anything else: `invalid`, with the `WebSave.Refusal` that said so.
    ///
    /// `inbox` is nil for a build with no app group. `wait` overrides the
    /// waiting time (tests).
    public static func reply(toMessageData data: Data?, browser: String, inbox: URL?,
                             appRunning: Bool, now: Date = Date(),
                             wait: TimeInterval? = nil) -> [String: Any] {
        guard let data else {
            return Result(id: "", state: .invalid, reason: WebSave.Refusal.notJSON.rawValue).message
        }
        // `ping` is read before the checks: it carries nothing to check.
        if data.count <= 1_024,
           let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           o["kind"] as? String == "ping" {
            return ["ok": inbox != nil, "state": inbox == nil ? "no-inbox" : "ready", "running": appRunning]
        }
        guard let inbox else { return ["ok": false, "state": "no-inbox"] }
        let id = WebSave.newEntryId()
        let entry: WebSave.Entry
        do {
            entry = try WebSave.entry(fromMessageData: data, id: id, at: iso(now), browser: browser)
        } catch {
            return Result(id: id, state: .invalid, reason: error.rawValue).message
        }
        do {
            try write(entry, into: inbox)
        } catch {
            return ["ok": false, "state": "no-inbox"]
        }
        let timeout = wait ?? (appRunning ? answerWait : answerWaitClosed)
        if let answer = awaitAnswer(id, inbox: inbox, timeout: timeout) {
            return answer.message
        }
        var queued = Result(id: id, state: .queued).message
        queued["running"] = appRunning
        return queued
    }

    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

/// ── NATIVE MESSAGING'S FRAMING ───────────────────────────────────────────
///
/// What Chromium browsers and Firefox speak to a native host over its standard
/// input and output: each message is a 32-bit length in the machine's byte
/// order — little-endian on every Mac Khayt runs on, so it is written as that
/// — and then that many bytes of UTF-8 JSON.
///
/// Caps, both ways. In: 1 MB — far above the 64 KB `WebSave` allows a save,
/// and far below the 4 GB a length field can claim; a bigger length is not
/// read at all, because the stream cannot be trusted past a lie about its
/// own size. Out: the browsers refuse a message from a host over 1 MB, and
/// nothing Khayt answers comes near 16 KB, so anything larger is a bug and is
/// answered with a plain refusal instead of being sent.
public enum NativeMessaging {

    public static let maxIncoming = 1_024 * 1_024
    public static let maxReply = 16 * 1_024

    public enum ReadError: Error, Equatable {
        /// The browser closed the pipe: the conversation is over.
        case closed
        /// A length over `maxIncoming`, or zero.
        case badLength(UInt32)
        /// Fewer bytes arrived than the length said.
        case truncated
    }

    /// One message, read through `read(n)` — which returns up to `n` bytes, or
    /// empty at the end of the stream.
    public static func readMessage(_ read: (Int) -> Data) throws(ReadError) -> Data {
        let head = readExactly(4, read)
        guard !head.isEmpty else { throw .closed }
        guard head.count == 4 else { throw .truncated }
        let length = UInt32(head[head.startIndex]) | UInt32(head[head.startIndex + 1]) << 8
            | UInt32(head[head.startIndex + 2]) << 16 | UInt32(head[head.startIndex + 3]) << 24
        guard length > 0, Int(length) <= maxIncoming else { throw .badLength(length) }
        let body = readExactly(Int(length), read)
        guard body.count == Int(length) else { throw .truncated }
        return body
    }

    static func readExactly(_ count: Int, _ read: (Int) -> Data) -> Data {
        var out = Data()
        while out.count < count {
            let more = read(count - out.count)
            if more.isEmpty { break }
            out.append(more)
        }
        return out
    }

    /// One reply, framed. A reply that is not JSON or is over `maxReply` is
    /// replaced by `{"ok":false,"state":"invalid","reason":"reply"}`.
    public static func frame(_ reply: [String: Any]) -> Data {
        var body = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data()
        if body.isEmpty || body.count > maxReply {
            body = Data(#"{"ok":false,"reason":"reply","state":"invalid"}"#.utf8)
        }
        let n = UInt32(body.count)
        var out = Data([UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)])
        out.append(body)
        return out
    }

    /// Which browser started the host, for the inbox entry — `firefox`,
    /// `edge`, `brave`, `vivaldi`, `chromium`, `chrome`, or `browser`.
    ///
    /// A Chromium browser passes the extension's origin as the first argument;
    /// Firefox passes the path of the host manifest and the extension's id.
    /// Every Chromium browser passes the same kind of origin, so which one it
    /// was is read off the parent process's path.
    public static func browser(arguments: [String], parentPath: String) -> String {
        let parent = parentPath.lowercased()
        if arguments.contains(where: { $0.hasPrefix("chrome-extension://") }) {
            if parent.contains("microsoft edge") || parent.contains("edgemac") { return "edge" }
            if parent.contains("brave") { return "brave" }
            if parent.contains("vivaldi") { return "vivaldi" }
            if parent.contains("chromium") { return "chromium" }
            return "chrome"
        }
        if arguments.contains(BrowserHosts.firefoxExtensionId) || parent.contains("firefox") { return "firefox" }
        return "browser"
    }
}
