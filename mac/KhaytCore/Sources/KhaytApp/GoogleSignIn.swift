import Foundation
import Network
import AppKit
import KhaytCore

/// One Google sign-in, through the browser, back to a listener on this Mac —
/// `gdriveAuthorize` in the other app, the same shape:
///
/// * a listener on 127.0.0.1 (not `localhost`, which can be ::1 and give a
///   redirect Google will not match) on a port the system picks;
/// * PKCE, so a code intercepted on the way back cannot be spent;
/// * a `state` that must come back unchanged, compared in constant time
///   BEFORE the code is exchanged, so a code delivered by anything else on
///   this Mac is refused;
/// * one callback, then the listener closes; five minutes, then it gives up.
///
/// Google's "Desktop app" OAuth clients accept any loopback port, which is
/// why the shop's client must be of that type.
@MainActor
enum GoogleSignIn {

    enum Failure: Error, Equatable {
        case listener(String)
        case google(String)
        case wrongState
        case noCode
        case noRefreshToken
        case timedOut
    }

    /// The refresh token, or the reason there is none.
    static func run(clientId: String, clientSecret: String, words: Words, fetch: @escaping S3.Fetch,
                    open: (URL) -> Void = { NSWorkspace.shared.open($0) }) async throws -> String {
        let (verifier, challenge) = DriveClient.pkce()
        let state = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let loopback = try await Loopback.start()
        defer { loopback.stop() }
        let redirect = "http://127.0.0.1:\(loopback.port)/callback"
        let no = words.callIt("mac.gdrive_page_not_connected")
        open(DriveClient.authorizeURL(clientId: clientId, redirectURI: redirect, challenge: challenge, state: state))

        let query = try await loopback.nextCallback(timeout: 300)
        if let error = query["error"] {
            await loopback.reply(title: no, body: words.callIt("mac.gdrive_page_google_said") + " " + error)
            throw Failure.google(error)
        }
        guard constantTimeEqual(query["state"] ?? "", state) else {
            await loopback.reply(title: no, body: words.callIt("mac.gdrive_page_wrong_state"))
            throw Failure.wrongState
        }
        guard let code = query["code"], !code.isEmpty else {
            await loopback.reply(title: no, body: words.callIt("mac.gdrive_page_no_code"))
            throw Failure.noCode
        }
        do {
            let tokens = try await DriveClient.exchange(code: code, verifier: verifier, redirectURI: redirect,
                                                        clientId: clientId, clientSecret: clientSecret, fetch: fetch)
            guard let refresh = tokens.refreshToken, !refresh.isEmpty else {
                await loopback.reply(title: words.callIt("mac.gdrive_page_almost"),
                                     body: words.callIt("mac.gdrive_no_refresh"))
                throw Failure.noRefreshToken
            }
            await loopback.reply(title: words.callIt("mac.gdrive_page_connected"), body: words.callIt("mac.gdrive_page_close"))
            return refresh
        } catch let f as Failure {
            throw f
        } catch {
            await loopback.reply(title: no, body: String(describing: error))
            throw error
        }
    }

    nonisolated static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// The query of a `GET /callback?…` request line, or nil for anything else.
    nonisolated static func callbackQuery(_ request: String) -> [String: String]? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let c = URLComponents(string: "http://127.0.0.1" + parts[1]), c.path == "/callback" else { return nil }
        var out: [String: String] = [:]
        for item in c.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }

    /// A listener that takes ONE callback.
    final class Loopback: @unchecked Sendable {
        let listener: NWListener
        let port: UInt16
        private let queue = DispatchQueue(label: "khayt.google-signin")
        private var pending: NWConnection?
        private var waiter: CheckedContinuation<[String: String], Error>?
        /// A callback that came before anybody was waiting for it.
        private var early: [String: String]?

        private init(listener: NWListener, port: UInt16) { self.listener = listener; self.port = port }

        static func start() async throws -> Loopback {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            params.acceptLocalOnly = true
            let listener: NWListener
            do { listener = try NWListener(using: params) }
            catch { throw Failure.listener(String(describing: error)) }
            let port: UInt16 = try await withCheckedThrowingContinuation { cont in
                let once = Once()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if once.claim() { cont.resume(returning: listener.port?.rawValue ?? 0) }
                    case .failed(let e):
                        if once.claim() { cont.resume(throwing: Failure.listener(String(describing: e))) }
                    default: break
                    }
                }
                listener.newConnectionHandler = { _ in }
                listener.start(queue: DispatchQueue(label: "khayt.google-signin.listen"))
            }
            let loop = Loopback(listener: listener, port: port)
            listener.newConnectionHandler = { [loop] c in loop.accept(c) }
            return loop
        }

        private func accept(_ c: NWConnection) {
            c.start(queue: queue)
            c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, _, _ in
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard let query = GoogleSignIn.callbackQuery(text) else {
                    // A favicon, a probe — anything that is not the callback.
                    c.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                           completion: .contentProcessed { _ in c.cancel() })
                    return
                }
                // ONE callback: anything after the first is turned away.
                guard pending == nil, early == nil else { c.cancel(); return }
                pending = c
                if let w = waiter { waiter = nil; w.resume(returning: query) } else { early = query }
            }
        }

        func nextCallback(timeout: TimeInterval) async throws -> [String: String] {
            try await withCheckedThrowingContinuation { cont in
                queue.async { [self] in
                    if let q = early { early = nil; cont.resume(returning: q); return }
                    waiter = cont
                    queue.asyncAfter(deadline: .now() + timeout) { [self] in
                        guard let w = waiter else { return }
                        waiter = nil
                        w.resume(throwing: Failure.timedOut)
                    }
                }
            }
        }

        func reply(title: String, body: String) async {
            let escape = { (s: String) in
                s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
            }
            let html = "<!doctype html><meta charset=\"utf-8\"><title>\(escape(title))</title>"
                + "<body style=\"font-family:system-ui;padding:3rem;max-width:32rem;margin:auto\">"
                + "<h2>\(escape(title))</h2><p>\(escape(body))</p></body>"
            let bytes = Data(html.utf8)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                queue.async { [self] in
                    guard let c = pending else { cont.resume(); return }
                    pending = nil
                    c.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in
                        c.cancel(); cont.resume()
                    })
                }
            }
        }

        func stop() { listener.cancel() }
    }

    /// True the first time only — a continuation resumed twice is a crash.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }
}
