import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The door in front of the SMTP client.
///
/// ── WHY AN SMTP HOST NEEDS GUARDING AT ALL ────────────────────────────────
///
/// SendGrid's and Mailgun's hosts are constants compiled into `EmailClient`;
/// the only thing a shop supplies is a key, and there is nothing for a guard to
/// guard. An SMTP relay is the opposite — a hostname typed into a settings
/// field, which this app then connects to and speaks a protocol with. That is
/// the shape of every SSRF: a name somebody else chooses, turned into a
/// connection from inside the network the app is running on.
///
/// `lib/custom-smtp.js` refuses loopback and cloud-metadata addresses for
/// exactly this reason, and the rule it refuses with is the shared one. This
/// app asks the same rule, in two layers — the name, and every address the name
/// resolves to — which is what `WebhookClient` does with a webhook URL.
///
/// The second layer is the one that matters: `smtp.example.com` is not a
/// loopback address and can still have an A record pointing at `127.0.0.1`.
struct SmtpHostGuardTests {

    static let mail = OrderEmail(to: "customer@example.com", subject: "Hello",
                                 html: "<p>Hello</p>", provider: "custom")

    static func relay(_ host: String) -> SmtpClient.Relay {
        SmtpClient.Relay(host: host, port: 587, user: "u", password: "p",
                         secure: false, from: "orders@shop.test", fromName: "Acme")
    }

    @Test("loopback and cloud metadata are refused before a socket is opened")
    func blockedHosts() async throws {
        let engine = try KhaytEngine()
        // The spellings the shared rule exists for. A guard matching the
        // literal "localhost" and nothing else passes this list's first entry
        // and fails every other one.
        let blocked = [
            "localhost", "127.0.0.1", "127.1", "0.0.0.0", "[::1]", "::1",
            "169.254.169.254",          // the cloud metadata endpoint
            "metadata.google.internal",
            "10.0.0.5", "192.168.1.10", "172.16.0.1",
        ]
        for host in blocked {
            await #expect(throws: SmtpClient.Failure.self,
                          "\(host) was not refused") {
                try await SmtpClient.send(Self.mail, relay: Self.relay(host), engine: engine)
            }
        }
    }

    @Test("a name that resolves to loopback is refused too, not just the literal")
    func resolvedAddressesAreChecked() async throws {
        let engine = try KhaytEngine()
        // `localhost` is the one name every machine resolves to 127.0.0.1, so
        // it is the only portable way to prove the SECOND layer runs without
        // depending on a DNS record this repository does not control. It is
        // caught by the first layer as well — which is the point: prove the
        // resolver path separately.
        let addresses = WebhookClient.resolve("localhost")
        #expect(!addresses.isEmpty, "localhost resolved to nothing — the layer is untestable here")
        for address in addresses {
            #expect((try? await engine.isBlockedHost(address)) == true,
                    "\(address) is a loopback address the shared rule did not refuse")
        }
    }

    @Test("a send with nothing configured is refused before any lookup")
    func incompleteIsRefused() async throws {
        let engine = try KhaytEngine()
        await #expect(throws: SmtpClient.Failure.self) {
            try await SmtpClient.send(Self.mail, relay: Self.relay(""), engine: engine)
        }
        await #expect(throws: SmtpClient.Failure.self) {
            try await SmtpClient.send(Self.mail, relay: Self.relay("   "), engine: engine)
        }
        // No sender address.
        var noSender = Self.relay("smtp.example.com")
        noSender.from = ""
        await #expect(throws: SmtpClient.Failure.self) {
            try await SmtpClient.send(Self.mail, relay: noSender, engine: engine)
        }
        // No recipient.
        let noRecipient = OrderEmail(to: "", subject: "Hello", html: "<p>Hi</p>",
                                     provider: "custom")
        await #expect(throws: SmtpClient.Failure.self) {
            try await SmtpClient.send(noRecipient, relay: Self.relay("smtp.example.com"),
                                      engine: engine)
        }
    }

    /// The blocking call has ONE caller, and it is the one that steps off the
    /// thread first.
    ///
    /// `WebhookClient.resolve` is `getaddrinfo`, which waits — for a name that
    /// does not resolve, until DNS gives up. Both types that use it are
    /// `@MainActor`, so calling it directly blocks the interface; and because a
    /// blocked thread of Swift's cooperative pool is one no other async work
    /// can use, it also stops unrelated tasks elsewhere in the app.
    ///
    /// `SmtpClient.send` called it directly, on a path reached from
    /// `@MainActor EmailClient` — so a shop finishing a job with a relay whose
    /// name resolved slowly would have watched the window stop.
    ///
    /// Read as source because the fault is "who calls what", which no runtime
    /// assertion can see.
    @Test("nothing calls the blocking resolver except the wrapper that offloads it")
    func resolveIsNotCalledOnAnActor() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                     includingPropertiesForKeys: nil)) ?? []
        #expect(!files.isEmpty, "no sources were read — this would pass vacuously")

        var offenders: [String] = []
        var wrapperFound = false
        for url in files where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines) {
                let bare = line.trimmingCharacters(in: .whitespaces)
                if bare.hasPrefix("//") || bare.hasPrefix("///") { continue }
                // The wrapper itself, which is the one place allowed to.
                if bare.contains("{ resolve(host) }") { wrapperFound = true; continue }
                // The declaration is not a call.
                if bare.contains("static func resolve(") { continue }
                if bare.contains("resolve(host)") || bare.contains("WebhookClient.resolve(") {
                    offenders.append("\(url.lastPathComponent): \(bare)")
                }
            }
        }
        #expect(wrapperFound, "the offloading wrapper is gone — retire this test or restore it")
        #expect(offenders.isEmpty,
                Comment(rawValue: "these block a main-actor thread on DNS: \(offenders)"))
    }

    /// Anti-vacuity: if the guard refused everything, every test above would
    /// pass while the feature was broken.
    @Test("an ordinary relay name is not refused by the guard")
    func ordinaryHostsPassTheGuard() async throws {
        let engine = try KhaytEngine()
        for host in ["smtp.gmail.com", "smtp.office365.com", "mail.myshop.example"] {
            #expect((try? await engine.isBlockedHost(host)) == false,
                    "\(host) is refused — no shop could use its own relay")
        }
    }
}
