import Foundation
import KhaytCore

/// One event off a Server-Sent Events stream.
struct SSEEvent: Equatable {
    var name: String
    var data: String
}

/// Server-Sent Events, line by line — the framing khayt-cloud's `/live` uses
/// (`event: <name>`, `data: <JSON>`, a blank line to end the event, `:`
/// comments for its 25-second pings, `retry:` to set the reconnect delay).
///
/// Its own type so the framing is tested without a network.
struct SSEParser {
    private var name = ""
    private var data: [String] = []
    /// The server's `retry:`, in milliseconds, when it has sent one.
    private(set) var retryMs: Int?

    /// Feed one line (without its newline). Returns an event when the line
    /// completes one.
    mutating func feed(_ raw: String) -> SSEEvent? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty {
            defer { name = ""; data = [] }
            guard !data.isEmpty else { return nil }
            return SSEEvent(name: name.isEmpty ? "message" : name, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }                       // a ping
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var v = line[line.index(after: colon)...]
            if v.hasPrefix(" ") { v = v.dropFirst() }
            value = v
        } else {
            field = Substring(line); value = ""
        }
        switch field {
        case "event": name = String(value)
        case "data": data.append(String(value))
        case "retry": retryMs = Int(value)
        default: break                                              // `id` and anything new
        }
        return nil
    }
}

/// Khayt Cloud's live stream (`GET /v1/shops/{id}/live`), held open while the
/// app is in the foreground and signed in to the cloud.
///
/// ── WHAT IT REPLACES ────────────────────────────────────────────────────
///
/// Asking the cloud on a timer. The stream says when something moved:
/// `printers` carries the new snapshot itself, and `store {rev}` says the
/// book has changed there — so the phone pulls exactly when there is
/// something to pull, instead of every so often in case. Asked for by the
/// Cloud lane, which carries one of these per device.
///
/// ── HOW IT ENDS, AND WHAT EACH ENDING MEANS ─────────────────────────────
///
/// The server closes it every thirty minutes and at every deploy, by design:
/// reconnect, 5 s doubling to 60 s, and trust the `hello` that comes first
/// rather than anything that might have been missed. 429 is too many streams
/// — back off, never "signed out". 401 is signed out, and the phone says so.
/// Unknown events (`intake` is coming) are ignored until they are read.
@MainActor
final class LiveChannel: ObservableObject {
    @Published private(set) var isOpen = false

    private let api: KhaytAPIClient
    private let printers: LivePrinters
    private var task: Task<Void, Never>?
    private var pulling = false
    /// Where a shop event off the stream goes — the print alerts.
    var onEvent: ((_ kind: String, _ ciphertext: Data, _ session: CloudSession) async -> Void)?

    init(api: KhaytAPIClient, printers: LivePrinters) {
        self.api = api
        self.printers = printers
    }

    /// Open it if there is a cloud to open it to; close it otherwise.
    func setActive(_ active: Bool) {
        if active, api.cloud != nil, !api.cloudNeedsSignIn {
            guard task == nil else { return }
            task = Task { [weak self] in await self?.run() }
        } else {
            task?.cancel()
            task = nil
            opened(false)
        }
    }

    private func opened(_ open: Bool) {
        isOpen = open
        printers.streamOpen = open
    }

    private func run() async {
        var delay: Double = 5
        while !Task.isCancelled {
            guard let session = api.cloud else { break }
            var retryAfter: Double?
            do {
                var request = try CloudReader.request(
                    CloudReader.Connection(url: session.url, shopId: session.shopId, storedToken: ""),
                    token: session.token, method: "GET", tail: "/live")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                // Pings arrive every 25 s; the request's own 30 s would cut a
                // healthy stream on one late ping.
                request.timeoutInterval = 90
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 {
                    api.cloudSaysSignedOut()
                    break
                }
                if status == 429 {
                    retryAfter = (response as? HTTPURLResponse)?
                        .value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 30
                    throw URLError(.cannotConnectToHost)
                }
                guard status == 200 else { throw URLError(.badServerResponse) }
                opened(true)
                delay = 5
                var parser = SSEParser()
                var line: [UInt8] = []
                for try await byte in bytes {
                    if byte == 0x0A {
                        if let event = parser.feed(String(decoding: line, as: UTF8.self)) {
                            await handle(event, session: session)
                        }
                        line.removeAll(keepingCapacity: true)
                    } else {
                        line.append(byte)
                    }
                }
                if let ms = parser.retryMs { delay = max(1, Double(ms) / 1000) }
            } catch {
                // Dropped, refused or unreachable: try again later.
            }
            opened(false)
            if Task.isCancelled { break }
            let wait = retryAfter ?? delay
            try? await Task.sleep(for: .seconds(wait))
            delay = min(delay * 2, 60)
        }
        opened(false)
        task = nil
    }

    private func handle(_ event: SSEEvent, session: CloudSession) async {
        let body = Data(event.data.utf8)
        switch event.name {
        case "hello":
            // `rev` is the cloud's head: behind it means something was
            // missed while the stream was down.
            struct Hello: Decodable { let rev: Int? }
            if let rev = (try? JSONDecoder().decode(Hello.self, from: body))?.rev {
                await pullIfBehind(rev, session: session)
            }
        case "store":
            struct Store: Decodable { let rev: Int }
            if let rev = (try? JSONDecoder().decode(Store.self, from: body))?.rev {
                await pullIfBehind(rev, session: session)
            }
        case "printers":
            if let snap = try? CloudSync.liveSnapshot(from: body, dek: session.dek) {
                printers.ingest(snap)
            }
        case "event":
            // `{ kind, at, ciphertext }` — "Shop events" in the contract. The
            // kind is read here; what is inside is the alert's business.
            if case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: body),
               case .string(let kind)? = o["kind"], let sealed = o["ciphertext"],
               let data = try? JSONEncoder().encode(sealed) {
                await onEvent?(kind, data, session)
            }
        default:
            break                                   // `intake` and whatever comes next
        }
    }

    /// One pull at a time: a burst of `store` events during a busy afternoon
    /// is one sync, not a queue of them.
    private func pullIfBehind(_ rev: Int, session: CloudSession) async {
        guard rev > (api.cloud?.seenRev ?? -1), !pulling else { return }
        pulling = true
        defer { pulling = false }
        await api.syncThroughCloud()
    }
}
