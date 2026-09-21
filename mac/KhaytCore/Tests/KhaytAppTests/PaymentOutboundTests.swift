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

    static func settings(webhooks: Bool = false, emailProvider: String? = nil,
                         smtpHost: String = "") -> [String: JSONValue] {
        var out: [String: JSONValue] = ["currency": .string("SAR")]
        if webhooks {
            out["webhooks"] = .object(["enabled": .bool(true),
                                       "secret": .string("s"),
                                       "events": .object(["payment_received": .string("https://example.test/hook")])])
        }
        if let emailProvider {
            var cfg: [String: JSONValue] = [
                "provider": .string(emailProvider),
                "triggers": .array([.string("payment_received")]),
            ]
            if !smtpHost.isEmpty { cfg["smtpHost"] = .string(smtpHost) }
            out["emailConfig"] = .object(cfg)
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

        let cannot = await Shop.channelsThisAppCannotSend(
            reaches, settings: Self.settings(webhooks: true), engine: engine)
        #expect(cannot.isEmpty,
                Comment(rawValue: "refused on channels it can send: "
                        + cannot.map(\.channel).joined(separator: ", ")))
    }

    /// SMTP used to be the one thing this app could not carry. It carries it
    /// now — but only once there is a relay to carry it to.
    @Test("a shop on its own SMTP relay is carried, and a half-set-up one is not")
    func smtpIsCarriedOnceConfigured() async throws {
        let engine = try KhaytEngine()

        // `custom` with nothing typed into it: a shop that started configuring
        // and stopped. There is no relay to open a connection to, so this must
        // still refuse — by name, so the shop knows which channel to fix.
        let half = Self.settings(emailProvider: "custom")
        let reaches = try await engine.paymentOutbound(
            order: Self.order, settings: half, clients: Self.clients)
        #expect(reaches.contains { $0.channel == "email" }, "the fixture reaches no email")
        let refused = await Shop.channelsThisAppCannotSend(reaches, settings: half, engine: engine)
        #expect(refused.map(\.channel) == ["email"],
                "a provider with no relay behind it must be refused by name")

        // And with a relay, `SmtpClient` carries it — so recording the money
        // is no longer refused for a shop on its own mail server.
        let whole = Self.settings(emailProvider: "custom", smtpHost: "smtp.shop.test")
        let carried = try await engine.paymentOutbound(
            order: Self.order, settings: whole, clients: Self.clients)
        #expect(carried.contains { $0.channel == "email" }, "the fixture reaches no email")
        let stillRefused = await Shop.channelsThisAppCannotSend(
            carried, settings: whole, engine: engine)
        #expect(stillRefused.isEmpty,
                "a shop on its own SMTP relay is still being refused its own money")
    }

    /// An HTTP provider is one this app POSTs to, so it is not a refusal.
    @Test("email through a provider this app can post to is carried")
    func httpEmailIsCarried() async throws {
        let engine = try KhaytEngine()
        let reaches = try await engine.paymentOutbound(
            order: Self.order, settings: Self.settings(emailProvider: "sendgrid"), clients: Self.clients)
        let cannot = await Shop.channelsThisAppCannotSend(
            reaches, settings: Self.settings(emailProvider: "sendgrid"), engine: engine)
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
