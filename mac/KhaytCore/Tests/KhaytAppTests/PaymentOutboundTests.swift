import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Recording money, when recording it tells somebody.
///
/// Two doors ask the same question — a status move and a payment — and only
/// one of them knew the answer. The move filtered what it reaches down to the
/// channels this app genuinely cannot carry; `recordPayment` refused whenever a
/// payment would reach ANYBODY, including through the three channels the move
/// sends on every single job. So a shop with a webhook switched on could move
/// a job along and could not record the money for it, and the sentence it got
/// named a channel the app was perfectly able to use.
///
/// The filter is one method now. These pin both halves: what it refuses, and
/// that a payment which owes a webhook actually carries one.
@MainActor
struct PaymentOutboundTests {

    static func settings(webhooks: Bool = false, emailProvider: String? = nil) -> [String: JSONValue] {
        var out: [String: JSONValue] = ["currency": .string("SAR")]
        if webhooks {
            out["webhooks"] = .object(["enabled": .bool(true),
                                       "secret": .string("s"),
                                       "events": .object(["payment_received": .string("https://example.test/hook")])])
        }
        if let emailProvider {
            out["emailConfig"] = .object([
                "provider": .string(emailProvider),
                "triggers": .array([.string("payment_received")]),
            ])
        }
        return out
    }

    static let order: JSONValue = .object([
        "id": .string("ORD-1"), "project": .string("Bracket"),
        "clientId": .string("C1"), "price": .number(500), "paidAmount": .number(0),
    ])
    static let clients: [JSONValue] = [
        .object(["id": .string("C1"), "nameEn": .string("Acme"), "email": .string("a@example.test")])
    ]

    @Test("a webhook is something this app can send, so it is not a refusal")
    func webhookIsNotARefusal() async throws {
        let engine = try KhaytEngine()
        let reaches = try await engine.paymentOutbound(
            order: Self.order, settings: Self.settings(webhooks: true), clients: Self.clients)
        #expect(reaches.contains { $0.channel == "webhooks" }, "the fixture reaches nobody — it proves nothing")

        let cannot = await Shop.channelsThisAppCannotSend(reaches, engine: engine)
        #expect(cannot.isEmpty,
                Comment(rawValue: "refused on channels it can send: "
                        + cannot.map(\.channel).joined(separator: ", ")))
    }

    /// The one that must still refuse, and by name.
    @Test("a shop on its own SMTP is still refused, and told which channel")
    func smtpStillRefuses() async throws {
        let engine = try KhaytEngine()
        let reaches = try await engine.paymentOutbound(
            order: Self.order, settings: Self.settings(emailProvider: "custom"), clients: Self.clients)
        #expect(reaches.contains { $0.channel == "email" }, "the fixture reaches no email")

        let cannot = await Shop.channelsThisAppCannotSend(reaches, engine: engine)
        #expect(cannot.map(\.channel) == ["email"],
                "SMTP email is the one thing this app cannot carry, and it must say so")
    }

    /// An HTTP provider is one this app POSTs to, so it is not a refusal.
    @Test("email through a provider this app can post to is carried")
    func httpEmailIsCarried() async throws {
        let engine = try KhaytEngine()
        let reaches = try await engine.paymentOutbound(
            order: Self.order, settings: Self.settings(emailProvider: "sendgrid"), clients: Self.clients)
        let cannot = await Shop.channelsThisAppCannotSend(reaches, engine: engine)
        #expect(cannot.isEmpty, "SendGrid is HTTP; refusing it is refusing a thing that works")
    }

    /// The half that makes letting it through honest.
    ///
    /// Relaxing the refusal without sending would trade a loud refusal for a
    /// silent non-send, which is worse: the shop would believe the webhook had
    /// gone. `effects` flattens each one to its type; the event name is what a
    /// delivery is actually addressed with, and a payment used to throw it
    /// away.
    @Test("a recorded payment carries the webhooks it owes, with their events")
    func paymentCarriesItsWebhooks() async throws {
        let engine = try KhaytEngine()
        let done = try await engine.recordPayment(
            order: Self.order, amount: 500, method: "cash",
            paidAt: "2026-09-21", today: "2026-09-21")
        #expect(done.effects.contains("webhook"), "the rule no longer asks for a payment webhook")

        let asked = done.webhookEffects ?? []
        #expect(!asked.isEmpty, "the payment threw its webhook effects away again")
        #expect(asked.contains { $0.event == "payment_received" },
                Comment(rawValue: "no payment_received among: "
                        + asked.map(\.event).joined(separator: ", ")))
        // Paid in full, so the rule also asks for the `paid` order webhook.
        #expect(asked.contains { $0.event == "paid" },
                "a payment that settles the job owes the paid webhook too")
    }

    @Test("a part payment owes the received webhook and not the paid one")
    func partPaymentDoesNotClaimPaid() async throws {
        let engine = try KhaytEngine()
        let done = try await engine.recordPayment(
            order: Self.order, amount: 100, method: "cash",
            paidAt: "2026-09-21", today: "2026-09-21")
        let events = (done.webhookEffects ?? []).map(\.event)
        #expect(events.contains("payment_received"))
        #expect(!events.contains("paid"), "100 of 500 is not paid, and must not be announced as it")
    }
}
