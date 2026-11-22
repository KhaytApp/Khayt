import Foundation
import Network
import KhaytCore

/// Sending mail through the shop's own SMTP server.
///
/// ── WHY THIS FILE EXISTS ──────────────────────────────────────────────────
///
/// `EmailClient` opens a door per provider, and two of them are one HTTPS POST
/// apiece. The third, `custom`, is a shop's own relay: a socket, a greeting, a
/// negotiation, an upgrade to TLS midway through, and a dialogue. For as long
/// as this app has existed it refused that provider by name — and the comment
/// explaining the refusal said writing a second implementation is how two apps
/// come to disagree about whether a customer was told.
///
/// That was true and it was not a reason to leave a shop unable to send. It is
/// a reason to share the part that can disagree: `lib/smtp-format.js` holds
/// every rule with an opinion in it — where a reply ends, what may go in a
/// Subject, which lines get a second dot — and `KhaytCore.Smtp` is that module
/// in Swift, pinned against the real file by `SmtpParityTests`. What is left
/// here is plumbing, which cannot disagree about anything.
///
/// ── STARTTLS, AND WHY IT NEEDED A FRAMER ──────────────────────────────────
///
/// Port 465 is TLS from the first byte and needs no ceremony. Port 587 — which
/// is the one Office 365 and most hosts actually offer — starts in the clear
/// and upgrades on command, and Network.framework cannot switch TLS on midway
/// through a connection. Apple's answer to this (DTS, forums thread 129901) is
/// a custom `NWProtocolFramer` that runs the plaintext prelude itself and then
/// prepends TLS to its own protocol stack before marking the connection ready.
/// `StartTlsFramer` below is that, and the ordering its thread is about —
/// `passThroughInput()` and `passThroughOutput()` BEFORE `markReady()` — is
/// the whole trick.
///
/// The prelude is also where the one security decision lives: if the server's
/// EHLO does not offer STARTTLS, this fails the connection rather than
/// continuing, because the next thing that would go down the socket is the
/// shop's password in base64, which is not encryption.
enum SmtpClient {

    /// Twenty seconds, which is `custom-smtp.js`'s. Longer than the HTTP
    /// providers' ten because this is several round trips, not one.
    static let timeout: TimeInterval = 20

    /// How long to wait for the connection to become usable.
    ///
    /// `timeout` in a shipping build, and nothing else: the `#if DEBUG` branch
    /// exists because the end-to-end tests run alongside two and a half
    /// thousand others on a shared CI runner, with a Python SMTP server on the
    /// other end of the socket competing for the same cores. Twenty seconds is
    /// the right answer for a shop waiting on a mail server and the wrong one
    /// for a test box under that much load — and a test that fails for want of
    /// CPU teaches nothing about whether STARTTLS works.
    ///
    /// Guarded the way `Trust` is, by `trustSwitchCannotShip`: a release build
    /// has no path to it.
    static var connectTimeout: TimeInterval {
        #if DEBUG
        return patience
        #else
        return timeout
        #endif
    }

    #if DEBUG
    nonisolated(unsafe) static var patience: TimeInterval = timeout
    #endif

    enum Failure: Error, LocalizedError {
        case incomplete
        case blocked(String)
        case noStartTls
        case unreachable(String)
        case refused(Int, String)

        var errorDescription: String? {
            switch self {
            case .incomplete:
                return "This shop's SMTP server, sender address and recipient are not all set"
            case .blocked(let host):
                return "SMTP host not allowed: \(host)"
            case .noStartTls:
                return "The SMTP server did not offer to encrypt the connection, so the password was not sent. Use port 465, or a server that supports STARTTLS."
            case .unreachable(let why):
                return why
            case .refused(let code, let line):
                return line.isEmpty ? "The SMTP server refused the message (\(code))" : line
            }
        }
    }

    /// What the shop configured, already opened.
    struct Relay: Sendable {
        var host: String
        var port: UInt16
        var user: String
        var password: String
        /// TLS from the first byte — port 465. Otherwise STARTTLS is required.
        var secure: Bool
        var from: String
        var fromName: String
    }

    /// Send one message and wait for the server to say it took it.
    ///
    /// Serialised app-wide by `Gate`: the STARTTLS framer is handed its server
    /// name through a box the protocol stack cannot be given one any other
    /// way, and two connections being built at once would swap them. Campaigns
    /// already send one at a time, 350 ms apart, so this costs nothing — but it
    /// is enforced here rather than assumed, because the cost of being wrong is
    /// a mail validated against the wrong certificate.
    static func send(_ mail: OrderEmail, relay: Relay, engine: KhaytEngine) async throws {
        let host = relay.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, !relay.from.isEmpty, !mail.to.isEmpty else {
            throw Failure.incomplete
        }
        // The same two layers the webhooks get, and for the same reason: the
        // host is typed by the shop, and `127.0.0.1` or a cloud metadata
        // address would make this app into a probe of its own network.
        if (try? await engine.isBlockedHost(host)) ?? true { throw Failure.blocked(host) }
        for address in await WebhookClient.addresses(of: host) {
            if (try? await engine.isBlockedHost(address)) ?? true {
                throw Failure.blocked("\(host) → \(address)")
            }
        }

        let settled = { var r = relay; r.host = host; return r }()
        try await Gate.shared.run { try await converse(mail, relay: settled) }
    }

    /// Whether a certificate has to be one the system trusts.
    ///
    /// ── THIS EXISTS FOR ONE TEST AND CANNOT SHIP ──────────────────────────
    ///
    /// The end-to-end tests talk to a real SMTP server started by the test
    /// itself, with a certificate it generates and throws away — which nothing
    /// trusts, and must not. Without a way to accept it there is no way to
    /// prove the STARTTLS upgrade happens at all, and an unproven TLS
    /// handshake is the last thing this file should ship.
    ///
    /// So the switch is inside `#if DEBUG`, which `swift test` builds and a
    /// release build does not — the shipped binary has no code path to this,
    /// not a flag that defaults to off. `SmtpTrustIsDebugOnlyTests` reads this
    /// file and fails if the guard is ever removed.
    enum Trust {
        #if DEBUG
        nonisolated(unsafe) static var acceptAnyCertificate = false
        #endif

        /// Applied wherever TLS options are made — the implicit-TLS connection
        /// and the framer's upgrade — so a test cannot accidentally prove one
        /// path while the other still validates.
        static func apply(to tls: NWProtocolTLS.Options) {
            #if DEBUG
            guard acceptAnyCertificate else { return }
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, _, complete in complete(true) },
                DispatchQueue.global())
            #endif
        }
    }

    /// One SMTP send at a time, app-wide.
    actor Gate {
        static let shared = Gate()
        func run(_ body: @Sendable () async throws -> Void) async throws { try await body() }
    }

    // MARK: - The dialogue

    /// The conversation, with no host guard in front of it.
    ///
    /// NOT private, and not guarded: `send` is the door, and it refuses a
    /// loopback or metadata address before reaching here. The end-to-end tests
    /// come in at this level precisely because their server IS on loopback,
    /// and `SmtpHostGuardTests` covers the door separately.
    static func converse(_ mail: OrderEmail, relay: Relay) async throws {
        let wire = try await Wire.connect(relay)
        defer { wire.close() }

        // On the STARTTLS path the framer has already read the greeting, said
        // EHLO once and upgraded; the connection only became ready afterwards.
        // RFC 3207 requires EHLO again over the new channel, and the server
        // discards everything it learned before the upgrade — including that
        // this client exists.
        if relay.secure {
            _ = try await wire.read()                       // the greeting
        }
        _ = try await wire.command("EHLO \(Smtp.ehloName)")

        if !relay.user.isEmpty && !relay.password.isEmpty {
            _ = try await wire.command("AUTH LOGIN")
            for payload in Smtp.authLoginPayloads(user: relay.user, pass: relay.password) {
                _ = try await wire.command(payload)
            }
        }
        _ = try await wire.command("MAIL FROM:<\(Smtp.sanitizeHeader(relay.from))>")
        _ = try await wire.command("RCPT TO:<\(Smtp.sanitizeHeader(mail.to))>")
        _ = try await wire.command("DATA")
        _ = try await wire.command(Smtp.buildMessage(
            from: relay.from, fromName: relay.fromName, to: mail.to,
            subject: mail.subject, html: mail.html))
        // QUIT is courtesy. A server that closes the socket instead of
        // answering has still accepted the message — the 250 for DATA above is
        // the acceptance — so a failure here is not one the shop is told about.
        try? await wire.write("QUIT")
    }

    // MARK: - The socket

    /// One connection, with the line discipline SMTP wants on top of it.
    private final class Wire: @unchecked Sendable {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "khayt.smtp")
        /// Bytes read but not yet a whole reply. A server is free to answer in
        /// any number of packets, and a 250-line EHLO routinely arrives in two.
        private var pending = ""

        private init(_ connection: NWConnection) { self.connection = connection }

        static func connect(_ relay: Relay) async throws -> Wire {
            let parameters: NWParameters
            if relay.secure {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_tls_server_name(
                    tls.securityProtocolOptions, relay.host)
                Trust.apply(to: tls)
                parameters = NWParameters(tls: tls)
            } else {
                parameters = NWParameters(tls: nil)
                let options = NWProtocolFramer.Options(definition: StartTlsFramer.definition)
                parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            }
            let port = NWEndpoint.Port(rawValue: relay.port) ?? 587
            let connection = NWConnection(host: .init(relay.host), port: port, using: parameters)
            let wire = Wire(connection)

            // The framer is built by the protocol stack, which takes no
            // arguments — so the server name it needs for the certificate, and
            // the slot it reports "no STARTTLS offered" back through, are
            // handed over here. `Gate` is what makes that safe.
            StartTlsFramer.handoff.set(serverName: relay.host)

            // ── THE CONNECTION MUST BE CANCELLED IF THIS THROWS ───────────
            //
            // `converse` closes the `Wire` it is handed, and a failure here
            // means it is never handed one — so the socket stayed open, half
            // open, until the process ended. A server on the other end waits
            // to be spoken to or hung up on and gets neither, which is a
            // HANG rather than an error: found by a test that never returned.
            //
            // NOT `defer` with a flag. That was the first fix, and the flag
            // read `true` at the return and `false` on a second pass through
            // the same block, so the connection this function had just handed
            // over was cancelled underneath its caller. An explicit catch has
            // one exit edge and no state to be wrong about.
            do {
                try await withCheckedThrowingContinuation { (go: CheckedContinuation<Void, Error>) in
                    let once = Once(go)
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            once.resume(.success(()))
                        case .failed(let error), .waiting(let error):
                            // `waiting` is a refused connection, or a host that
                            // is unreachable and will retry forever; there is
                            // nobody here to wait for it.
                            once.resume(.failure(Self.translate(error)))
                        case .cancelled:
                            once.resume(.failure(Failure.unreachable(
                                "The SMTP connection was closed")))
                        default:
                            break
                        }
                    }
                    connection.start(queue: wire.queue)
                    wire.queue.asyncAfter(deadline: .now() + connectTimeout) {
                        // The CONNECTION is cancelled, not a task: a parked
                        // `receive` does not notice task cancellation, and the
                        // state handler above turns the cancel into a failure.
                        if connection.state != .ready { connection.cancel() }
                    }
                }
            } catch {
                StartTlsFramer.handoff.clear()
                connection.cancel()
                throw error
            }
            StartTlsFramer.handoff.clear()
            return wire
        }

        /// Why the connection failed, in words a shop can act on.
        private static func translate(_ error: NWError) -> Failure {
            if let reason = StartTlsFramer.handoff.failure { return reason }
            return Failure.unreachable(error.localizedDescription)
        }

        func close() { connection.cancel() }

        /// Send a line and wait for the reply, refusing on 4xx and 5xx.
        @discardableResult
        func command(_ line: String) async throws -> Smtp.Reply {
            try await write(line)
            return try await read()
        }

        func write(_ line: String) async throws {
            let data = Data((line + "\r\n").utf8)
            try await withCheckedThrowingContinuation { (go: CheckedContinuation<Void, Error>) in
                let once = Once(go)
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        once.resume(.failure(Failure.unreachable(error.localizedDescription)))
                    } else {
                        once.resume(.success(()))
                    }
                })
            }
        }

        /// Read until a whole reply has arrived, then check what it says.
        @discardableResult
        func read() async throws -> Smtp.Reply {
            while true {
                if let reply = Smtp.replyIsComplete(pending) {
                    pending = ""
                    guard reply.ok else { throw Failure.refused(reply.code, reply.reason) }
                    return reply
                }
                pending += try await receive()
            }
        }

        private func receive() async throws -> String {
            try await withCheckedThrowingContinuation { (go: CheckedContinuation<String, Error>) in
                let once = Once(go)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                    data, _, complete, error in
                    if let error {
                        once.resume(.failure(Failure.unreachable(error.localizedDescription)))
                    } else if let data, !data.isEmpty {
                        once.resume(.success(String(decoding: data, as: UTF8.self)))
                    } else if complete {
                        once.resume(.failure(Failure.unreachable(
                            "The SMTP server closed the connection before answering")))
                    } else {
                        once.resume(.success(""))
                    }
                }
            }
        }
    }

    /// A continuation resumed exactly once, whatever the callback does.
    ///
    /// `NWConnection`'s state handler fires repeatedly — `.waiting` then
    /// `.failed` is an ordinary sequence — and resuming a checked continuation
    /// twice is a crash, not a warning.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
        func resume(_ result: Result<T, Error>) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(with: result)
        }
    }
}
