import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The SMTP client against a real server, over a real socket.
///
/// ── WHY THIS IS NOT COVERED BY THE PARITY TESTS ───────────────────────────
///
/// `SmtpParityTests` proves the RULES agree with `lib/smtp-format.js` — where a
/// reply ends, what may go in a Subject, which lines get a second dot. Every
/// one of those can be right while nothing is ever sent. What they cannot
/// reach is the part that only exists on this platform: whether the STARTTLS
/// framer actually upgrades the socket, whether `AUTH LOGIN` puts the user
/// before the password, whether the body arrives whole.
///
/// So these start `Resources/fake-smtp.py` — a strict little SMTP server that
/// records everything said to it — and check the transcript. It is checked
/// against Python's own `smtplib` as well, so a failure here means this app is
/// wrong rather than the fake being wrong.
///
/// ── THE CERTIFICATE ───────────────────────────────────────────────────────
///
/// The server makes one and throws it away, so nothing trusts it. The tests
/// switch `SmtpClient.Trust.acceptAnyCertificate` on, which exists only inside
/// `#if DEBUG` — see `trustSwitchCannotShip` at the bottom, which is the guard
/// that keeps it that way.
///
/// They also come in through `converse` rather than `send`: `send` refuses a
/// loopback address, correctly, and this server is on one. The door's guard is
/// covered by `SmtpHostGuardTests`.
@Suite(.serialized)
struct SmtpWireTests {

    // MARK: - Starting the server

    struct Transcript: Decodable {
        let said: [String]
        let body: String?
        let upgraded: Bool
        let auth: [String]?
        let error: String?
    }

    /// The server, its port, and where it will write what it heard.
    final class Fake {
        let process = Process()
        let port: UInt16
        let transcript: URL

        init?(mode: String) throws {
            let script = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appending(path: "Resources/fake-smtp.py")
            guard FileManager.default.fileExists(atPath: script.path) else { return nil }
            transcript = FileManager.default.temporaryDirectory
                .appending(path: "khayt-smtp-\(UUID().uuidString).json")

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script.path, "--mode", mode,
                                 "--transcript", transcript.path]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            do { try process.run() } catch { return nil }

            // `READY <port>` on the first line, or the environment has no
            // usable python3 / openssl and there is nothing to test against.
            //
            // READ ON ANOTHER THREAD, because `availableData` blocks: a loop
            // that checks a deadline between blocking reads has no deadline at
            // all, and on a loaded runner the generated certificate can take a
            // while. This waits a bounded time and says what it actually saw.
            let box = Line()
            let handle = out.fileHandleForReading
            Thread.detachNewThread {
                var seen = Data()
                while !seen.contains(0x0A) {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    seen.append(chunk)
                }
                box.set(String(decoding: seen, as: UTF8.self))
            }
            let deadline = Date().addingTimeInterval(60)
            while box.text == nil, Date() < deadline { usleep(20_000) }

            guard let text = box.text else {
                process.terminate()
                Issue.record("the fake SMTP server never printed READY — it is still starting")
                return nil
            }
            guard let number = text.split(separator: " ").last
                .flatMap({ UInt16($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else {
                process.terminate()
                let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
                Issue.record(Comment(rawValue: "the fake SMTP server said \"\(said)\" instead of "
                                     + "READY — python3 or openssl is missing here"))
                return nil
            }
            port = number
        }

        /// One line, written by a reader thread and read by the test.
        final class Line: @unchecked Sendable {
            private let lock = NSLock()
            private var value: String?
            func set(_ s: String) { lock.lock(); value = s; lock.unlock() }
            var text: String? { lock.lock(); defer { lock.unlock() }; return value }
        }

        func finish() throws -> Transcript {
            // A DEADLINE, not `waitUntilExit()` alone. The server sits in
            // `recv` until the client says something or hangs up, so a client
            // that leaks its socket hangs the test suite rather than failing
            // it — which is how this was found, and is not a way to find it
            // again.
            let deadline = Date().addingTimeInterval(20)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                Issue.record("the fake server never finished — the client left its socket open")
            }
            let data = try Data(contentsOf: transcript)
            try? FileManager.default.removeItem(at: transcript)
            return try JSONDecoder().decode(Transcript.self, from: data)
        }
    }

    static func relay(port: UInt16, secure: Bool, user: String = "orders@shop.test",
                      password: String = "hunter2") -> SmtpClient.Relay {
        SmtpClient.Relay(host: "127.0.0.1", port: port, user: user, password: password,
                         secure: secure, from: "orders@shop.test", fromName: "Acme 3D")
    }

    static let mail = OrderEmail(
        to: "customer@example.com",
        subject: "Your print is ready",
        // A line beginning with a dot, which is the one that decides whether
        // an email arrives whole or is cut off where the shop wrote a list.
        html: "<p>Ready for collection.</p>\n.Thanks for your order\n<p>Acme 3D</p>",
        provider: "custom")

    // MARK: - The tests

    @Test("STARTTLS: the framer upgrades the socket and the whole message arrives")
    func startTlsSend() async throws {
        SmtpClient.Trust.acceptAnyCertificate = true
        // The product waits 20s for a mail server, which is right for a shop
        // and wrong for a test box running 2,500 others beside a Python SMTP
        // server on the same cores.
        SmtpClient.patience = 120
        defer {
            SmtpClient.Trust.acceptAnyCertificate = false
            SmtpClient.patience = SmtpClient.timeout
        }

        guard let fake = try Fake(mode: "starttls") else {
            // No python3 or no openssl. Skipping is honest; pretending to pass
            // is not, so it says so.
            Issue.record("could not start the fake SMTP server — this machine cannot run this test")
            return
        }
        do {
            try await SmtpClient.converse(Self.mail, relay: Self.relay(port: fake.port, secure: false))
        } catch {
            // WHAT THE SERVER HEARD, which is the whole diagnosis. Nothing at
            // all means this never got a connection — a starved runner, not a
            // broken upgrade. An EHLO and a STARTTLS and then silence means the
            // handshake itself failed, which would be a real fault.
            let heard = try? fake.finish()
            let transcript = "\(heard?.said ?? []) upgraded=\(heard?.upgraded ?? false) "
                + "serverError=\(heard?.error ?? "none")"
            Issue.record(Comment(rawValue: "the send failed: \(error). "
                                 + "The server heard: \(transcript)"))
            return
        }
        let heard = try fake.finish()

        #expect(heard.error == nil, "the server gave up: \(heard.error ?? "")")
        #expect(heard.upgraded, "the connection was never upgraded to TLS")

        // The framer's EHLO, then the one after the upgrade. Two, not one:
        // RFC 3207 says the server forgets everything it learned beforehand.
        let ehlos = heard.said.filter { $0.uppercased().hasPrefix("EHLO") }
        #expect(ehlos.count == 2, "expected an EHLO either side of the upgrade, got \(ehlos)")
        #expect(ehlos.allSatisfy { $0 == "EHLO \(Smtp.ehloName)" },
                "the two apps must give the same name: \(ehlos)")

        // The order of the whole conversation, which is the protocol.
        let shape = heard.said.map { $0.uppercased().prefix(10) }
        #expect(shape.contains { $0.hasPrefix("STARTTLS") })
        #expect(shape.contains { $0.hasPrefix("AUTH LOGIN") })
        #expect(shape.contains { $0.hasPrefix("MAIL FROM") })
        #expect(shape.contains { $0.hasPrefix("RCPT TO") })
        #expect(shape.contains { $0.hasPrefix("DATA") })

        // AUTH LOGIN sends the user FIRST. Round the other way a shop
        // authenticates as its own password, which a server answers with the
        // same 535 a wrong password gets.
        let auth = try #require(heard.auth, "the server was never authenticated to")
        #expect(auth.count == 2)
        #expect(Data(base64Encoded: auth[0]).map { String(decoding: $0, as: UTF8.self) }
                == "orders@shop.test")
        #expect(Data(base64Encoded: auth[1]).map { String(decoding: $0, as: UTF8.self) }
                == "hunter2")

        // And the message itself, as the customer would read it. The server
        // un-stuffs the dots, so a leading dot that survived the round trip is
        // proof the client doubled it.
        let body = try #require(heard.body)
        #expect(body.contains("Subject: Your print is ready"))
        #expect(body.contains("From: Acme 3D <orders@shop.test>"))
        #expect(body.contains("To: customer@example.com"))
        #expect(body.contains("Content-Type: text/html; charset=UTF-8"))
        #expect(body.contains(".Thanks for your order"),
                "the dot-stuffed line did not survive: \(body)")
        #expect(body.contains("<p>Acme 3D</p>"),
                "the message was cut off at the dotted line")
    }

    @Test("implicit TLS on 465 needs no prelude and sends the same message")
    func implicitTlsSend() async throws {
        SmtpClient.Trust.acceptAnyCertificate = true
        // The product waits 20s for a mail server, which is right for a shop
        // and wrong for a test box running 2,500 others beside a Python SMTP
        // server on the same cores.
        SmtpClient.patience = 120
        defer {
            SmtpClient.Trust.acceptAnyCertificate = false
            SmtpClient.patience = SmtpClient.timeout
        }

        guard let fake = try Fake(mode: "implicit") else {
            Issue.record("could not start the fake SMTP server"); return
        }
        try await SmtpClient.converse(Self.mail, relay: Self.relay(port: fake.port, secure: true))
        let heard = try fake.finish()

        #expect(heard.error == nil, "the server gave up: \(heard.error ?? "")")
        // ONE EHLO on this path — the greeting is read by the dialogue rather
        // than by a framer, and there is no upgrade to re-introduce itself
        // after. A second one here would mean the greeting was mistaken for
        // an EHLO response, which would put the whole conversation one reply
        // out of step.
        #expect(heard.said.filter { $0.uppercased().hasPrefix("EHLO") }.count == 1,
                "expected exactly one EHLO on the implicit-TLS path: \(heard.said)")
        #expect(!heard.said.contains { $0.uppercased() == "STARTTLS" },
                "STARTTLS was sent on a connection that was already encrypted")
        #expect(try #require(heard.body).contains(".Thanks for your order"))
    }

    @Test("a server that will not encrypt gets no password")
    func refusesToLeakThePassword() async throws {
        SmtpClient.Trust.acceptAnyCertificate = true
        // The product waits 20s for a mail server, which is right for a shop
        // and wrong for a test box running 2,500 others beside a Python SMTP
        // server on the same cores.
        SmtpClient.patience = 120
        defer {
            SmtpClient.Trust.acceptAnyCertificate = false
            SmtpClient.patience = SmtpClient.timeout
        }

        guard let fake = try Fake(mode: "nostarttls") else {
            Issue.record("could not start the fake SMTP server"); return
        }
        await #expect(throws: SmtpClient.Failure.self) {
            try await SmtpClient.converse(Self.mail, relay: Self.relay(port: fake.port, secure: false))
        }
        let heard = try fake.finish()

        // THE POINT OF THE WHOLE EXERCISE. Not just that it failed — that the
        // password never reached the wire. A client that sent AUTH and then
        // gave up has already handed the shop's password to whoever was
        // listening, and failing afterwards does not take it back.
        #expect(heard.auth == nil, "the server was authenticated to over a plaintext socket")
        #expect(!heard.said.contains { $0.uppercased().hasPrefix("AUTH") },
                "AUTH was sent in the clear: \(heard.said)")
        #expect(!heard.said.contains { $0.uppercased().hasPrefix("MAIL FROM") },
                "the conversation continued past the refusal: \(heard.said)")
        // It did get as far as EHLO — otherwise this test would pass on a
        // client that never connected at all.
        #expect(heard.said.contains { $0.uppercased().hasPrefix("EHLO") },
                "nothing was ever sent — this test proves nothing")
    }

    @Test("the reason a shop is given names the missing encryption, not a socket error")
    func theRefusalSaysWhy() async throws {
        SmtpClient.Trust.acceptAnyCertificate = true
        // The product waits 20s for a mail server, which is right for a shop
        // and wrong for a test box running 2,500 others beside a Python SMTP
        // server on the same cores.
        SmtpClient.patience = 120
        defer {
            SmtpClient.Trust.acceptAnyCertificate = false
            SmtpClient.patience = SmtpClient.timeout
        }

        guard let fake = try Fake(mode: "nostarttls") else {
            Issue.record("could not start the fake SMTP server"); return
        }
        var said = ""
        do {
            try await SmtpClient.converse(Self.mail, relay: Self.relay(port: fake.port, secure: false))
        } catch let failure as SmtpClient.Failure {
            said = failure.errorDescription ?? ""
        }
        _ = try? fake.finish()
        // `markFailed` carries an `NWError`, and none of its cases says this.
        // Without the handoff the shop is told "Operation cancelled", which
        // names nothing it can fix.
        #expect(said.contains("encrypt"), "the shop was told: \(said)")
        #expect(said.contains("465"), "the shop was not told what to try instead: \(said)")
    }

    /// The switch that lets these tests accept a throwaway certificate must not
    /// exist in a shipping build.
    ///
    /// Read as source rather than tested behaviourally, because the thing being
    /// asserted is that a release compile has no such symbol — which a test
    /// running in a debug build cannot observe any other way.
    @Test("the test-only switches are inside #if DEBUG and cannot ship")
    func trustSwitchCannotShip() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/SmtpClient.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.isEmpty, "SmtpClient.swift was not read — this would pass vacuously")

        // Every mention of the switch, and every call that would weaken a
        // handshake, must sit inside a `#if DEBUG` block.
        var debugDepth = 0
        var offenders: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let bare = line.trimmingCharacters(in: .whitespaces)
            if bare.hasPrefix("#if DEBUG") { debugDepth += 1; continue }
            if bare.hasPrefix("#endif") { debugDepth = max(0, debugDepth - 1); continue }
            let dangerous = bare.contains("acceptAnyCertificate")
                || bare.contains("sec_protocol_options_set_verify_block")
                // The patience knob too: a release build must wait the twenty
                // seconds a shop should wait, not whatever a test last set.
                || bare.contains("patience")
            // The doc comment explains the switch and is not the switch.
            if dangerous, debugDepth == 0, !bare.hasPrefix("///"), !bare.hasPrefix("//") {
                offenders.append(bare)
            }
        }
        #expect(offenders.isEmpty, "these would ship in a release build: \(offenders)")
        #expect(text.contains("acceptAnyCertificate"), "the switch is gone — retire this test")
        #expect(text.contains("patience"), "the patience knob is gone — retire that half")
    }
}
