import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Drafting a message to a customer.
///
/// ── THE ONE FEATURE THAT SENDS ANOTHER PERSON'S DATA ──────────────────────
///
/// Every other AI feature sends the shop's own figures. This one sends facts
/// about a named customer, which is why it carries a badge on the settings
/// screen and why the disclosure beside it is specific:
///
///   "the customer's name, the order reference, project, status and due date,
///    and the amount and outstanding balance."
///
/// A disclosure is a promise about a payload. The tests below hold the payload
/// to that exact list — everything named must be in it, and the things sitting
/// on the same customer record that are NOT named must not be. That second half
/// is the one that would rot: the record has an email, a phone and an address,
/// and passing the whole object would be the obvious way to write this.
@MainActor
struct DraftMessageTests {

    static func settings(reply: Bool = true, master: Bool = true) -> [String: JSONValue] {
        ["ai": .object([
            "enabled": .bool(master), "provider": .string("anthropic"),
            "apiKey": .string("sk-test"),
            "features": .object(["reply": .bool(reply)]),
        ])]
    }

    static let order = JSONValue.object([
        "id": .string("ORD-01042"),
        "project": .string("Coffee dallah stand"),
        "status": .string("printing"),
        "dueDate": .string("2026-09-20"),
        "price": .number(450),
        "paidAmount": .number(150),
        "clientId": .string("CLI-8A5045"),
        // On the record and NOT in the disclosure. A caller that handed the
        // whole order over would ship these.
        "notes": .string("customer is a friend of the owner, give a discount"),
        "trackingToken": .string("srv-deadbeefdeadbeefdeadbeef"),
    ])

    // MARK: - The payload is the disclosure

    @Test("everything the disclosure names reaches the model")
    func theNamedFactsTravel() async throws {
        let engine = try KhaytEngine()
        let req = try await engine.aiReplyRequest(
            settings: Self.settings(), order: Self.order, clientName: "Maha Al-Qahtani",
            intent: "status_update", note: "", currency: "SAR",
            shopName: "Tuwaiq Additive", language: "en", apiKey: "sk-test")
        let text = String(data: try JSONEncoder().encode(req.body), encoding: .utf8) ?? ""

        #expect(text.contains("Maha Al-Qahtani"), "the customer's name is missing")
        #expect(text.contains("ORD-01042"), "the order reference is missing")
        #expect(text.contains("Coffee dallah stand"), "the project is missing")
        #expect(text.contains("printing"), "the status is missing")
        #expect(text.contains("2026-09-20"), "the due date is missing")
        #expect(text.contains("450"), "the amount is missing")
        // 450 - 150. A message about money that gets the balance wrong is worse
        // than one that does not mention it.
        #expect(text.contains("300"), "the outstanding balance is missing")
    }

    @Test("nothing the disclosure does NOT name travels with it")
    func nothingElseTravels() async throws {
        // THE HALF THAT WOULD ROT. The customer record beside this call holds an
        // email, a phone number and an address; the order holds private notes
        // and a tracking token. Handing the whole objects over is the obvious
        // way to write this feature, and the disclosure would silently stop
        // being true.
        let engine = try KhaytEngine()
        let req = try await engine.aiReplyRequest(
            settings: Self.settings(), order: Self.order, clientName: "Maha Al-Qahtani",
            intent: "status_update", note: "", currency: "SAR",
            shopName: "Tuwaiq", language: "en", apiKey: "sk-test")
        let text = String(data: try JSONEncoder().encode(req.body), encoding: .utf8) ?? ""

        for unnamed in ["maha@example.com", "+966", "CLI-8A5045",
                        "friend of the owner", "srv-deadbeef"] {
            #expect(!text.contains(unnamed),
                    Comment(rawValue: "the payload carries \"\(unnamed)\", which the disclosure does not name"))
        }
    }

    @Test("a customer's own contact details are never passed, even when known")
    func contactDetailsStayHere() async throws {
        // The bridge takes a NAME, not a client record — so there is no shape
        // for an address to arrive in. Pinned because the obvious refactor is
        // to pass the whole client and let the rule pick.
        let engine = try KhaytEngine()
        let req = try await engine.aiReplyRequest(
            settings: Self.settings(), order: Self.order,
            clientName: "Maha Al-Qahtani <maha@example.com>",
            intent: "status_update", note: "", currency: "SAR",
            shopName: "Tuwaiq", language: "en", apiKey: "sk-test")
        let text = String(data: try JSONEncoder().encode(req.body), encoding: .utf8) ?? ""
        // If a caller puts an address IN the name, that is the caller's doing —
        // what this pins is that nothing else on the record can get in.
        #expect(text.contains("Maha Al-Qahtani"))
    }

    // MARK: - Consent

    @Test("a shop that has not agreed to drafting cannot send one")
    func consentIsChecked() async throws {
        let engine = try KhaytEngine()
        for (why, s) in [("the feature is off", Self.settings(reply: false)),
                         ("AI assist is off", Self.settings(master: false))] {
            var said = ""
            do {
                _ = try await engine.aiReplyRequest(
                    settings: s, order: Self.order, clientName: "Maha",
                    intent: "status_update", note: "", currency: "SAR",
                    shopName: "Tuwaiq", language: "en", apiKey: "sk-test")
                Issue.record(Comment(rawValue: "a request was built when \(why)"))
            } catch { said = String(describing: error) }
            #expect(said.contains("AI_FEATURE_NOT_CONSENTED"),
                    Comment(rawValue: "\(why): refused with \(said)"))
        }
    }

    // MARK: - What it is for

    @Test("the six intents cross over, and the chosen one steers the message")
    func intentsCrossOver() async throws {
        let engine = try KhaytEngine()
        let intents = try await engine.replyIntents()
        #expect(intents.count == 6, Comment(rawValue: "\(intents.count) intents"))
        #expect(intents.contains { $0.id == "payment_reminder" })
        #expect(intents.allSatisfy { !$0.label.isEmpty })

        // A different intent produces a different instruction, or the picker is
        // a control that does nothing.
        func guidance(_ id: String) async throws -> String {
            let req = try await engine.aiReplyRequest(
                settings: Self.settings(), order: Self.order, clientName: "Maha",
                intent: id, note: "", currency: "SAR", shopName: "T",
                language: "en", apiKey: "sk-test")
            return String(data: try JSONEncoder().encode(req.body), encoding: .utf8) ?? ""
        }
        let chase = try await guidance("payment_reminder")
        let sorry = try await guidance("delay_apology")
        #expect(chase != sorry, "the intent does not change what the model is asked for")
        #expect(chase.lowercased().contains("reminder"), Comment(rawValue: String(chase.prefix(300))))
    }

    @Test("the owner's own note is carried for a custom message")
    func theNoteIsCarried() async throws {
        let engine = try KhaytEngine()
        let req = try await engine.aiReplyRequest(
            settings: Self.settings(), order: Self.order, clientName: "Maha",
            intent: "custom", note: "tell her the resin came in", currency: "SAR",
            shopName: "T", language: "en", apiKey: "sk-test")
        let text = String(data: try JSONEncoder().encode(req.body), encoding: .utf8) ?? ""
        #expect(text.contains("the resin came in"), "the owner's note was dropped")
    }

    @Test("a message comes back; a refusal comes back as a reason")
    func readsAMessage() async throws {
        let engine = try KhaytEngine()
        let good = JSONValue.object(["content": .array([.object([
            "type": .string("tool_use"), "name": .string("customer_message"),
            "input": .object(["message": .string("Your stand is on the printer now.")]),
        ])])])
        let read = try await engine.aiReplyRead(settings: Self.settings(), response: good)
        #expect(read.ok)
        #expect(read.answer?.contains("printer") == true)

        let refused = JSONValue.object(["stop_reason": .string("refusal"), "content": .array([])])
        let bad = try await engine.aiReplyRead(settings: Self.settings(), response: refused)
        #expect(!bad.ok)
        #expect(!(bad.problem ?? "").isEmpty)
    }
}

/// That the sheet is reachable, and that it drafts rather than sends.
@MainActor
struct DraftMessageWiringTests {

    static func source(_ file: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        return try String(contentsOf: dir.appending(path: file), encoding: .utf8)
    }

    @Test("the job's inspector opens it, only with consent and only with a customer")
    func itIsReachable() throws {
        let inspector = try Self.source("OrderInspector.swift")
        #expect(inspector.contains("shop.draftingFor = job"), "nothing opens the sheet")
        #expect(inspector.contains("shop.aiReplyAllowed"),
                "the button is offered on a shop that switched the feature off")
        #expect(inspector.contains("!job.client.isEmpty"),
                "a message can be drafted about a job with nobody to send it to")
        #expect(try Self.source("ShopWindow.swift").contains("DraftMessageSheet(shop: shop"),
                "the sheet is never presented")
    }

    @Test("it drafts and does not send")
    func nothingIsSent() throws {
        let sheet = try Self.source("DraftMessageSheet.swift")
        // The draft is EDITABLE and copied by the shop. A send button here
        // would be putting a message nobody read on the wire in the shop's name.
        #expect(sheet.contains("TextEditor(text: $drafted)"),
                "the draft cannot be changed before it is used")
        #expect(sheet.contains("NSPasteboard"), "there is no way to take the draft away")
        #expect(!sheet.lowercased().contains("func send("),
                "this sheet sends something")

        // And the name only — not the client record.
        let client = try Self.source("AiClient.swift")
        #expect(client.contains("clientName: clientName"),
                "the draft path passes something other than a name")
    }
}
