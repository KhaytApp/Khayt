import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The screen that sets email up, which this app did not have.
///
/// Every mail path here — SendGrid, Mailgun, the new SMTP client, campaigns,
/// the email a job sends when it moves — reads `settings.emailConfig`, and the
/// only screen that ever WROTE it lived in the other app. So this app could
/// send mail somebody else had configured and could configure none of it.
///
/// What is checked here is the part that cannot be seen by looking: that the
/// save reaches the book at all, that a masked secret is kept rather than
/// blanked, and that the choices offered are the shared list rather than a
/// second copy of it.
@MainActor
struct EmailSettingsTests {

    static func settings(_ config: [String: JSONValue]) -> [String: JSONValue] {
        ["emailConfig": .object(config)]
    }

    @Test("the providers offered are the shared list, in the shared order")
    func providersMatchTheSharedList() async throws {
        let engine = try KhaytEngine()
        let shared = try await engine.emailProviders()
        #expect(EmailSettings.offered == shared,
                "the picker offers \(EmailSettings.offered) and the rule knows \(shared)")
        // And every one of them has a name, or the menu draws a raw key.
        for id in shared {
            #expect(EmailSettings.providerLabels[id] != nil, "\(id) has no label")
        }
    }

    @Test("the trigger checkboxes are the shared list, not a second copy")
    func triggersMatchTheSharedList() async throws {
        let engine = try KhaytEngine()
        let triggers = try await engine.emailTriggers()
        // The five the other app draws. This is the pair that had drifted
        // apart once already — a literal in the renderer, a lookup in the rule.
        #expect(triggers.map(\.key)
                == ["printing", "post", "completed", "quote", "payment_received"])
        #expect(triggers.allSatisfy { !$0.label.isEmpty })
    }

    @Test("reading a configured book fills every field")
    func draftReadsTheBook() {
        let draft = EmailSettings.Draft.read(Self.settings([
            "provider": .string("custom"),
            "fromEmail": .string("orders@shop.test"),
            "fromName": .string("Acme 3D"),
            "smtpHost": .string("smtp.shop.test"),
            "smtpPort": .number(465),
            "smtpUser": .string("orders@shop.test"),
            "smtpPassword": .string("__enc__secret"),
            "smtpSecure": .bool(true),
            "triggers": .array([.string("completed"), .string("quote")]),
        ]))
        #expect(draft.provider == "custom")
        #expect(draft.host == "smtp.shop.test")
        #expect(draft.port == "465")
        #expect(draft.secure)
        #expect(draft.triggers == ["completed", "quote"])
        // THE SECRET IS NOT IN THE DRAFT. A draft holding `__enc__secret` puts
        // it in a field's binding, and the next save writes the ciphertext back
        // as though the shop had typed it — sealing the sealed string.
        #expect(draft.password.isEmpty, "the stored password leaked into the draft")
        #expect(draft.apiKey.isEmpty, "the stored key leaked into the draft")
    }

    @Test("an empty book reads as a shop that has not set email up")
    func draftReadsNothing() {
        let draft = EmailSettings.Draft.read([:])
        #expect(draft.provider == "none")
        #expect(draft.port == "587", "the default port must be the one the other app uses")
        #expect(draft.triggers.isEmpty)
    }

    /// The write path, through the shared rule rather than through the view.
    ///
    /// `applySettings` is what every Mac save goes through, and it kept
    /// whatever `emailConfig` was stored and ignored the form — because the
    /// only screen that ever wrote one saved the whole book directly. A screen
    /// that appears to save and changes nothing is worse than no screen.
    @Test("a saved email setting actually reaches the book")
    func theSaveIsNotSwallowed() async throws {
        let engine = try KhaytEngine()
        var root: [String: JSONValue] = ["settings": .object([:])]
        try await Shop.applySettings(to: &root, form: [
            "emailConfig": .object([
                "provider": .string("custom"),
                "smtpHost": .string("  SMTP.Shop.TEST  "),
                "smtpPort": .number(465),
                "smtpUser": .string("orders@shop.test"),
                "smtpSecure": .bool(true),
                "fromEmail": .string("orders@shop.test"),
                "triggers": .array([.string("completed"), .string("nonsense")]),
            ]),
        ], country: nil, engine: engine)

        guard case .object(let settings)? = root["settings"],
              case .object(let config)? = settings["emailConfig"] else {
            Issue.record("no emailConfig was written at all"); return
        }
        #expect(config["provider"] == .string("custom"))
        // Trimmed and lowered, because a hostname is not case-sensitive and a
        // pasted one arrives with whitespace.
        #expect(config["smtpHost"] == .string("smtp.shop.test"))
        #expect(config["smtpPort"] == .number(465))
        #expect(config["smtpSecure"] == .bool(true))
        // A status nobody has a switch for is a trigger nobody asked for.
        #expect(config["triggers"] == .array([.string("completed")]),
                "an unknown trigger was stored: \(String(describing: config["triggers"]))")
    }

    @Test("a masked secret is kept, and forgetting one is deliberate")
    func secretsSurviveASave() async throws {
        let engine = try KhaytEngine()
        var root: [String: JSONValue] = ["settings": .object(Self.settings([
            "provider": .string("custom"),
            "smtpHost": .string("smtp.shop.test"),
            "smtpPassword": .string("__enc__kept"),
            "apiKey": .string("__enc__alsokept"),
        ]))]

        // A save with the password field left alone — which is what a field
        // showing dots means. Sending an empty string here would blank a
        // password the shop never touched, and the next job to finish would
        // fail to tell a customer anything.
        try await Shop.applySettings(to: &root, form: [
            "emailConfig": .object([
                "provider": .string("custom"),
                "smtpHost": .string("smtp.shop.test"),
                "smtpUser": .string("someone@shop.test"),
            ]),
        ], country: nil, engine: engine)

        guard case .object(let settings)? = root["settings"],
              case .object(let config)? = settings["emailConfig"] else {
            Issue.record("no emailConfig"); return
        }
        #expect(config["smtpPassword"] == .string("__enc__kept"),
                "the stored password was lost by a save that did not mention it")
        #expect(config["apiKey"] == .string("__enc__alsokept"))
        #expect(config["smtpUser"] == .string("someone@shop.test"), "the save did nothing")

        // And forgetting one IS possible — an empty string, sent on purpose.
        try await Shop.applySettings(to: &root, form: [
            "emailConfig": .object([
                "provider": .string("custom"),
                "smtpHost": .string("smtp.shop.test"),
                "smtpPassword": .string(""),
            ]),
        ], country: nil, engine: engine)
        guard case .object(let after)? = root["settings"],
              case .object(let cleared)? = after["emailConfig"] else {
            Issue.record("no emailConfig"); return
        }
        // AN EMPTY STRING CLEARS IT, and that is the whole point of the
        // switch. The rule used to treat "absent" and "empty" the same, so
        // "Forget the stored password" could be turned on, saved, and leave
        // the password exactly where it was — a shop that meant to revoke a
        // credential would believe it had.
        #expect(cleared["smtpPassword"] == .string(""),
                "the forget switch did not forget anything")
        // And only that one: clearing a password must not take the API key
        // with it.
        #expect(cleared["apiKey"] == .string("__enc__alsokept"))
    }

    /// The same switch, on the assistant's key, which had the same fault.
    ///
    /// Found here rather than there: `mac.ai_forget_key` has been drawn on the
    /// assistant settings page since it shipped, and the rule behind it kept
    /// the key. Checked from this file because this is where the shape was
    /// noticed, and a test in the file that noticed it is a test that will not
    /// be deleted along with the feature it is really about.
    @Test("forgetting the assistant's key forgets it too")
    func theAssistantKeyCanBeForgotten() async throws {
        let engine = try KhaytEngine()
        var root: [String: JSONValue] = ["settings": .object([
            "ai": .object(["provider": .string("anthropic"),
                           "apiKey": .string("__enc__live")]),
        ])]
        // Untouched: the field showed dots and nobody typed in it.
        try await Shop.applySettings(to: &root, form: [
            "ai": .object(["provider": .string("anthropic")]),
        ], country: nil, engine: engine)
        #expect(key(root) == "__enc__live", "a save that did not mention the key lost it")

        // Asked for, on purpose.
        try await Shop.applySettings(to: &root, form: [
            "ai": .object(["provider": .string("anthropic"), "apiKey": .string("")]),
        ], country: nil, engine: engine)
        #expect(key(root) == "", "the forget switch did not forget anything")
    }

    private func key(_ root: [String: JSONValue]) -> String? {
        guard case .object(let settings)? = root["settings"],
              case .object(let ai)? = settings["ai"],
              case .string(let value)? = ai["apiKey"] else { return nil }
        return value
    }

    /// The screen is reachable, which is the failure mode this repository keeps
    /// producing: a correct thing with no caller.
    @Test("the email settings are actually drawn on a settings page")
    func theScreenIsReachable() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Integrations.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.isEmpty, "Integrations.swift was not read — this would pass vacuously")
        #expect(text.contains("EmailSettings(shop: shop)"),
                "the email settings screen exists and nothing opens it")
    }
}
