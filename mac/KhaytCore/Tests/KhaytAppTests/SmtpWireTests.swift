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
    final class Fake: @unchecked Sendable {
        let process: Process
        let port: UInt16
        let transcript: URL

        private init(process: Process, port: UInt16, transcript: URL) {
            self.process = process
            self.port = port
            self.transcript = transcript
        }

        /// Start the server and wait until it is LISTENING: it binds its port
        /// and only then prints `READY <port>`, so that line is the readiness.
        ///
        /// ── THE WAIT IS FOR THE LINE, NOT FOR A CLOCK ─────────────────────
        ///
        /// This used to give the server sixty seconds and then record "it is
        /// still starting", and on a full local run (Nov 12 2026, load average
        /// about 4) it did exactly that. Measured afterwards at the same load,
        /// the server prints READY in 0.08–0.14 s, so those sixty seconds were
        /// not a slow start that needed sixty-one. Something held the child up
        /// and the helper had thrown away everything that would have said
        /// what: it never read the child's stderr and never said whether the
        /// child was alive. (The likeliest something: a full run of these
        /// tests took 33 GB on a 32 GB Mac, and a new process waits a long
        /// time for memory on a machine that is swapping. See
        /// `Tests/KhaytTestWidth/width.c`, which is the cure for that.)
        ///
        /// So now the test waits for one of the two things that can actually
        /// happen: the line arrives, or the child's output ends (it exited).
        /// The budget is the same `patience` both ends of the conversation
        /// already carry, as a hang guard and not a speed limit: when it runs
        /// out the child is stopped, which ends its output, and the failure
        /// says how long it had, and everything it wrote to stderr. The script
        /// dumps its own Python stack there if it is not listening after
        /// thirty seconds (`faulthandler`), so a start that hangs again names
        /// the line it hung on.
        ///
        /// `async`, so the wait holds none of the cooperative pool's threads:
        /// the old loop slept on one for as long as the server took.
        static func start(mode: String, budget: TimeInterval = SmtpWireTests.patience) async throws -> Fake? {
            let script = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appending(path: "Resources/fake-smtp.py")
            guard FileManager.default.fileExists(atPath: script.path) else { return nil }
            let transcript = FileManager.default.temporaryDirectory
                .appending(path: "khayt-smtp-\(UUID().uuidString).json")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script.path, "--mode", mode,
                                 "--transcript", transcript.path]
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch { return nil }

            // The hang guard. Stopping the child closes its end of the pipe,
            // so the reader below returns with whatever it had.
            let began = Date()
            let gaveUp = Flag()
            let listening = Flag()
            nonisolated(unsafe) let child = process
            DispatchQueue.global().asyncAfter(deadline: .now() + budget) {
                guard !listening.isSet else { return }
                gaveUp.set()
                child.terminate()
            }

            // `READY <port>` on the first line, or the environment has no
            // usable python3 / openssl and there is nothing to test against.
            //
            // READ ON ANOTHER THREAD, because `availableData` blocks.
            let handle = out.fileHandleForReading
            let text: String = await withCheckedContinuation { done in
                Thread.detachNewThread {
                    var seen = Data()
                    while !seen.contains(0x0A) {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        seen.append(chunk)
                    }
                    listening.set()
                    done.resume(returning: String(decoding: seen, as: UTF8.self))
                }
            }

            let words = text.split(whereSeparator: \.isWhitespace)
            if words.count == 2, words[0] == "READY", let port = UInt16(words[1]) {
                return Fake(process: process, port: port, transcript: transcript)
            }

            // Not listening. Say which of the two it was, and what the child
            // itself said: its output has ended, so its stderr can be read to
            // the end without blocking once it has gone.
            process.terminate()
            process.waitUntilExit()
            let complaint = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let waited = Int(Date().timeIntervalSince(began))
            let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = complaint.isEmpty
                ? "it wrote nothing to stderr (python3 never reached the script)"
                : "its stderr: \(complaint.suffix(2_000))"
            if gaveUp.isSet {
                Issue.record(Comment(rawValue: "the fake SMTP server was still not listening after "
                                     + "\(waited)s and was stopped; \(stderr)"))
            } else {
                Issue.record(Comment(rawValue: "the fake SMTP server exited after \(waited)s having said "
                                     + "\"\(said)\" instead of READY — python3 or openssl is missing "
                                     + "here; \(stderr)"))
            }
            return nil
        }

        /// Set once, from one thread, and read from another.
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.lock(); value = true; lock.unlock() }
            var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
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

    /// How long either end waits, in these tests only.
    ///
    /// The product waits 20s for a mail server, which is right for a shop and
    /// wrong for a test box running 2,500 tests beside a Python SMTP server on
    /// the same cores. BOTH ends have to carry this number: raising only the
    /// client's just moves which end gives up first, and the failure then
    /// blames the network for a server that ran out of patience — which is
    /// exactly how this suite failed on CI, with the client reporting "server
    /// closed session with no notification" over a Python
    /// `TimeoutError: the handshake operation timed out`.
    ///
    /// `fake-smtp.py` carries the same figure, and `patienceIsAgreed` below
    /// fails if the two ever drift apart.
    static let patience: TimeInterval = 600

    // ── ONLY IN A DEBUG BUILD ─────────────────────────────────────────────
    //
    // The four tests that hold a conversation switch on
    // `SmtpClient.Trust.acceptAnyCertificate` and `SmtpClient.patience`, which
    // exist only inside `#if DEBUG` (see `trustSwitchCannotShip`). Outside
    // this block they stopped `swift test -c release` from compiling at all,
    // for the sake of two switches a release build is right not to have.
    #if DEBUG
    @Test("STARTTLS: the framer upgrades the socket and the whole message arrives")
    func startTlsSend() async throws {
        SmtpClient.Trust.acceptAnyCertificate = true
        // The product waits 20s for a mail server, which is right for a shop
        // and wrong for a test box running 2,500 others beside a Python SMTP
        // server on the same cores.
        SmtpClient.patience = Self.patience
        defer {
            SmtpClient.Trust.acceptAnyCertificate = false
            SmtpClient.patience = SmtpClient.timeout
        }

        guard let fake = try await Fake.start(mode: "starttls") else {
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
        SmtpClient.patience = Self.patience
        defer {
            SmtpClient.Trust.acceptAnyCertificate = false
            SmtpClient.patience = SmtpClient.timeout
        }

        guard let fake = try await Fake.start(mode: "implicit") else {
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
        SmtpClient.patience = Self.patience
        defer {
            SmtpClient.Trust.acceptAnyCertificate = false
            SmtpClient.patience = SmtpClient.timeout
        }

        guard let fake = try await Fake.start(mode: "nostarttls") else {
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
        SmtpClient.patience = Self.patience
        defer {
            SmtpClient.Trust.acceptAnyCertificate = false
            SmtpClient.patience = SmtpClient.timeout
        }

        guard let fake = try await Fake.start(mode: "nostarttls") else {
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
    #endif

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

    /// The two ends of this test agree about how long to wait.
    ///
    /// They are in different languages and different files, so nothing but
    /// this connects them. Raising one alone is the bug that produced the
    /// failure this constant exists for.
    @Test("the fake server is as patient as the client")
    func patienceIsAgreed() throws {
        // Read from source, the same way `Fake` starts it: the script is
        // EXCLUDED from the bundle in Package.swift because it is run as a
        // program, so there is nothing to find in `Bundle.module`.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Resources/fake-smtp.py")
        let source = try String(contentsOf: url, encoding: .utf8)
        let line = try #require(source.split(separator: "\n")
            .first { $0.contains("PATIENCE = ") }, "fake-smtp.py no longer declares PATIENCE")
        let value = try #require(Double(line.split(separator: "=")[1]
            .trimmingCharacters(in: .whitespaces)), "PATIENCE is not a number: \(line)")
        #expect(value >= Self.patience,
                Comment(rawValue: "the fake server waits \(value)s and the client waits "
                        + "\(Self.patience)s — the server will give up first and the failure "
                        + "will read as a network fault"))
    }
}
