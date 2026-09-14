import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Telling a customer their job moved, by email.
///
/// The MESSAGE is `lib/order-email.js`, tested where it lives against the
/// renderer handler it was lifted from — including the fact that the handler
/// has not been able to run since #822. What is tested here is what only this
/// app can get wrong: that it asks for the message correctly, that it refuses
/// the move it cannot carry and makes the one it can, and that a send which
/// fails is SAID rather than swallowed.
@MainActor
struct OrderEmailTests {

    static func book(_ email: [String: JSONValue],
                     clientEmail: String = "buyer@example.com") -> [String: JSONValue] {
        [
            "printLog": .array([.object([
                "id": .string("J1"), "project": .string("Bracket"),
                "status": .string("printing"), "price": .number(400),
                "clientId": .string("C1"), "parts": .array([]),
            ])]),
            "inventory": .array([]), "consumables": .array([]), "machines": .array([]),
            "clients": .array([.object([
                "id": .string("C1"),
                "nameEn": .string("Sara"),
                "email": .string(clientEmail),
            ])]),
            "settings": .object([
                "bizEn": .string("Tuwaiq Prints"),
                "emailConfig": .object(email),
            ]),
        ]
    }

    static func sendgrid(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var cfg: [String: JSONValue] = [
            "provider": .string("sendgrid"),
            "triggers": .array([.string("completed")]),
            "apiKey": .string("SG.notarealkey"),
        ]
        for (k, v) in extra { cfg[k] = v }
        return cfg
    }

    static func move(_ root: inout [String: JSONValue], _ stage: Stage)
    async throws -> (undo: [Shop.ChangedRecord], notices: [String], telegram: TelegramMessage?,
                     webhooks: [KhaytEngine.WebhookDelivery], email: OrderEmail?) {
        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)
        return try await Shop.applyMove(to: &root, id: "J1", stage: stage,
                                        engine: engine, words: words)
    }

    // MARK: - The message

    @Test("a shop on SendGrid gets the message the shared rule writes")
    func message() async throws {
        var root = Self.book(Self.sendgrid())
        let out = try await Self.move(&root, .completed)
        let mail = try #require(out.email, "the move should have carried an email")
        #expect(mail.to == "buyer@example.com")
        #expect(mail.provider == "sendgrid")
        // The shop's own name, and the stage in the words `Words` resolves —
        // not the raw status, which is what a missing label looks like.
        #expect(mail.subject.hasPrefix("Tuwaiq Prints — Order J1 Update: "))
        #expect(!mail.subject.hasSuffix("completed"), "the stage should be in words")
        #expect(mail.html.contains("Dear Sara,"))
        #expect(mail.html.contains("<strong>J1</strong>"))
    }

    /// The greeting falls back to the address, which is what the other app does
    /// — a customer row with no name is common and is not an error.
    @Test("a customer with no name is greeted by address")
    func namelessCustomer() async throws {
        var root = Self.book(Self.sendgrid())
        root["clients"] = .array([.object([
            "id": .string("C1"), "email": .string("buyer@example.com"),
        ])])
        let mail = try #require(try await Self.move(&root, .completed).email)
        #expect(mail.html.contains("Dear buyer@example.com,"))
    }

    @Test("a shop that has not asked for one gets none, and the move still happens")
    func noMessage() async throws {
        let cases: [[String: JSONValue]] = [
            [:],                                                    // nothing configured
            ["provider": .string("none"), "triggers": .array([.string("completed")])],
            Self.sendgrid(["triggers": .array([.string("delivered")])]),  // not this status
        ]
        for config in cases {
            var root = Self.book(config)
            let out = try await Self.move(&root, .completed)
            #expect(out.email == nil, "no email was asked for")
            #expect(!out.undo.isEmpty, "and the move itself still happened")
        }
    }

    @Test("a customer with no address on file is not a refusal")
    func noAddress() async throws {
        var root = Self.book(Self.sendgrid(), clientEmail: "")
        let out = try await Self.move(&root, .completed)
        #expect(out.email == nil)
        #expect(!out.undo.isEmpty, "nothing is sent and nothing is missed")
    }

    // MARK: - What this app can and cannot carry

    @Test("SMTP is refused by name, and the move does not happen")
    func smtpRefused() async throws {
        var root = Self.book([
            "provider": .string("custom"),
            "triggers": .array([.string("completed")]),
            "smtpHost": .string("mail.example.com"),
        ])
        await #expect(throws: (any Error).self) {
            _ = try await Self.move(&root, .completed)
        }
        // And the job is still where it was: a refused move writes nothing.
        let orders = Shop.rows(root, "printLog")
        guard case .object(let job)? = orders.first else {
            Issue.record("the job is gone"); return
        }
        #expect(Shop.plainString(job["status"]) == "printing")
    }

    @Test("the providers this app carries are the module's, not a Swift list")
    func providersComeFromTheModule() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.emailProviderIsHttp("sendgrid"))
        #expect(try await engine.emailProviderIsHttp("mailgun"))
        #expect(!(try await engine.emailProviderIsHttp("custom")))
        #expect(!(try await engine.emailProviderIsHttp("")))
    }

    // MARK: - The sending domain

    /// `sanitizeMailgunDomain`, which decides what goes into a URL PATH. The
    /// first Swift draft read the same and was not the same — it accepted a
    /// label starting with a hyphen and rejected a numeric TLD. The pattern is
    /// pinned to the module's by `test/order-email.test.js`; these are the
    /// cases that pin the behaviour.
    @Test("a Mailgun domain is a hostname and nothing else")
    func mailgunDomain() {
        #expect(EmailClient.mailgunDomain("mg.example.com") == "mg.example.com")
        #expect(EmailClient.mailgunDomain("  MG.Example.COM ") == "mg.example.com")
        #expect(EmailClient.mailgunDomain("evil.com/path") == nil)
        #expect(EmailClient.mailgunDomain("user@evil.com") == nil)
        #expect(EmailClient.mailgunDomain("") == nil)
        // A single label is not a sending domain, and a label may not start or
        // end with a hyphen.
        #expect(EmailClient.mailgunDomain("localhost") == nil)
        #expect(EmailClient.mailgunDomain("-bad.example.com") == nil)
        #expect(EmailClient.mailgunDomain("bad-.example.com") == nil)
        #expect(EmailClient.mailgunDomain(String(repeating: "a", count: 250) + ".com") == nil)
    }

    // MARK: - Failure is said out loud

    @Test("a send that fails is reported, not swallowed")
    func failureIsSaid() async throws {
        let mail = OrderEmail(to: "buyer@example.com", subject: "s", html: "<p>h</p>",
                              provider: "sendgrid")
        // No key: the provider would answer 401, and this refuses before the
        // request — either way the shop has to be told, which is what the
        // thrown error is for. `Shop.post` turns it into a sentence.
        await #expect(throws: EmailClient.Failure.self) {
            try await EmailClient.send(mail, apiKey: "", config: [:])
        }
        let smtp = OrderEmail(to: "buyer@example.com", subject: "s", html: "<p>h</p>",
                              provider: "custom")
        await #expect(throws: EmailClient.Failure.self) {
            try await EmailClient.send(smtp, apiKey: "k", config: [:])
        }
    }
}
