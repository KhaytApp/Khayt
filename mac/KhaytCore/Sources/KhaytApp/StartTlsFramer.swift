import Foundation
import Network
import KhaytCore

/// Turning a plaintext SMTP socket into an encrypted one, mid-conversation.
///
/// ── WHY A FRAMER AND NOT AN `if` ──────────────────────────────────────────
///
/// Network.framework decides a connection's protocol stack when the connection
/// is created and does not let it change afterwards, so TLS cannot simply be
/// switched on when the server says `220 Ready to start TLS`. Apple's answer
/// (DTS, developer.apple.com/forums/thread/129901) is this: a custom framing
/// protocol that returns `.willMarkReady` from `start`, runs the plaintext
/// prelude itself, and then prepends TLS to its OWN protocol stack before
/// declaring the connection ready. Everything above it — `SmtpClient.Wire` —
/// only ever sees a connection that was encrypted from the moment it could
/// first write to it.
///
/// The ordering is the part that is easy to get wrong and silent when wrong:
/// `passThroughInput()` and `passThroughOutput()` must both be called BEFORE
/// `markReady()`, or the framer stays in the path and swallows the handshake.
///
/// ── THE PRELUDE IS ALSO WHERE THE PASSWORD IS PROTECTED ───────────────────
///
/// Between the greeting and the upgrade there is exactly one question worth
/// asking: did the server offer to encrypt at all? If it did not — a
/// misconfigured relay, or an active attacker who stripped the capability out
/// of the EHLO response — the next thing this app would put on the wire is the
/// shop's password, base64'd, which anyone watching can read back. So a
/// missing offer fails the connection here, before `AUTH` is ever reached.
/// `lib/custom-smtp.js` refuses in the same place for the same reason.
final class StartTlsFramer: NWProtocolFramerImplementation {

    static let definition = NWProtocolFramer.Definition(implementation: StartTlsFramer.self)
    static var label: String { "SmtpStartTls" }

    /// What the protocol stack cannot be given, handed across instead.
    ///
    /// A framer is built by Network.framework with no arguments, so the server
    /// name it needs to validate a certificate against — and the slot it
    /// reports a refusal back through, since `markFailed` carries an `NWError`
    /// and "this server would not encrypt" is not one — travel through here.
    /// `SmtpClient.Gate` serialises connection setup so there is only ever one
    /// in flight; without that this would be a race that mixes up hostnames.
    final class Handoff: @unchecked Sendable {
        private let lock = NSLock()
        private var name = ""
        private var reason: SmtpClient.Failure?

        func set(serverName: String) {
            lock.lock(); defer { lock.unlock() }
            name = serverName; reason = nil
        }
        func clear() { lock.lock(); defer { lock.unlock() }; name = "" }
        var serverName: String { lock.lock(); defer { lock.unlock() }; return name }
        var failure: SmtpClient.Failure? { lock.lock(); defer { lock.unlock() }; return reason }
        func fail(_ why: SmtpClient.Failure) {
            lock.lock(); defer { lock.unlock() }; reason = why
        }
    }

    static let handoff = Handoff()

    private enum Step {
        /// Waiting for `220`, which the server sends unprompted.
        case greeting
        /// Waiting for the EHLO response, which is where STARTTLS is offered.
        case capabilities
        /// Waiting for `220 Ready to start TLS`.
        case upgrade
        /// TLS is in the stack and this framer is out of the way.
        case done
    }

    private var step: Step = .greeting
    private var buffer = ""
    private let serverName: String

    init(framer: NWProtocolFramer.Instance) {
        serverName = StartTlsFramer.handoff.serverName
    }

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        // NOT `.ready`: the connection must not be usable until the prelude has
        // run and TLS is in place, or the first thing written to it goes out in
        // the clear.
        .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while step != .done {
            var arrived = false
            _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                slice, _ in
                guard let slice, !slice.isEmpty else { return 0 }
                buffer += String(decoding: slice, as: UTF8.self)
                arrived = true
                return slice.count
            }
            // Nothing more to read right now; ask to be called again when
            // another byte turns up.
            guard arrived else { return 1 }

            guard let reply = Smtp.replyIsComplete(buffer) else { continue }
            buffer = ""
            advance(framer, reply)
        }
        return 0
    }

    private func advance(_ framer: NWProtocolFramer.Instance, _ reply: Smtp.Reply) {
        switch step {
        case .greeting:
            guard reply.ok else { return give(up: framer, .refused(reply.code, reply.reason)) }
            say(framer, "EHLO \(Smtp.ehloName)")
            step = .capabilities

        case .capabilities:
            guard reply.ok else { return give(up: framer, .refused(reply.code, reply.reason)) }
            guard Smtp.offersStartTls(reply.text) else {
                return give(up: framer, .noStartTls)
            }
            say(framer, "STARTTLS")
            step = .upgrade

        case .upgrade:
            guard reply.ok else { return give(up: framer, .refused(reply.code, reply.reason)) }
            let tls = NWProtocolTLS.Options()
            // WITHOUT THIS the handshake has no name to validate the
            // certificate against, and a connection to the shop's relay would
            // accept a certificate issued for anywhere at all. The connection's
            // own endpoint is not consulted by a prepended protocol.
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
            SmtpClient.Trust.apply(to: tls)
            do {
                try framer.prependApplicationProtocol(options: tls)
            } catch {
                return give(up: framer, .unreachable(
                    "The SMTP connection could not be encrypted: \(error.localizedDescription)"))
            }
            // The order here is the whole of Apple's answer: pass through
            // first, mark ready second. Reversed, this framer stays in the data
            // path and eats the TLS handshake it just asked for.
            framer.passThroughInput()
            framer.passThroughOutput()
            framer.markReady()
            step = .done

        case .done:
            break
        }
    }

    private func say(_ framer: NWProtocolFramer.Instance, _ line: String) {
        framer.writeOutput(data: Data((line + "\r\n").utf8))
    }

    private func give(up framer: NWProtocolFramer.Instance, _ why: SmtpClient.Failure) {
        // Recorded before the connection fails, because `markFailed` carries an
        // `NWError` and none of its cases says "that server would not encrypt".
        // `SmtpClient.Wire.translate` reads this back.
        StartTlsFramer.handoff.fail(why)
        step = .done
        framer.markFailed(error: nil)
    }

    /// Nothing is written through this framer before it is ready — the prelude
    /// writes with `writeOutput` directly — so this only has to not lose
    /// anything if something tries.
    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message,
                      messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}
