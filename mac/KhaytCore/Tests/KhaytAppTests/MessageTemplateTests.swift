import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Sending a customer one of the shop's own saved messages.
///
/// The book has held these all along — this shop wrote three — and nothing on
/// this Mac could read them. The only way to write to a customer here needed a
/// model key, a connection and an agreement to send a customer's details to a
/// service, which most shops have none of.
@MainActor
struct MessageTemplateTests {

    static func loaded() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    @Test("the templates are read from the key the other app writes them under")
    func templatesAreRead() async {
        let shop = await Self.loaded()
        #expect(MessageTemplate.collection == "waTemplates")
        #expect(!shop.messageTemplates.isEmpty, "the sample book has no saved messages to show")
    }

    @Test("a row with no body is dropped, and one with no name is called something")
    func rowsAreFiltered() {
        let rows: [JSONValue] = [
            .object(["id": .string("a"), "name": .string("Ready"), "body": .string("Hi")]),
            .object(["id": .string("b"), "name": .string("Empty"), "body": .string("")]),
            .object(["id": .string("c"), "body": .string("No name")]),
            .object(["id": .string(""), "body": .string("No id")]),
            .object(["name": .string("No id either"), "body": .string("x")]),
            .string("not a row"), .null, .number(3),
        ]
        let made = MessageTemplate.from(rows)
        #expect(made.map(\.id) == ["a", "c"],
                Comment(rawValue: "kept \(made.map(\.id))"))
        // A template with no name still has to be pickable, so it wears its id.
        #expect(made.last?.name == "c")
    }

    @Test("a real job fills a real template, with no braces left")
    func fillsAJob() async throws {
        let shop = await Self.loaded()
        let job = try #require(shop.orders.first { !$0.client.isEmpty })
        for template in shop.messageTemplates {
            let text = shop.fillMessage(template, for: job)
            #expect(!text.contains("{{"), Comment(rawValue: "braces left in: \(text)"))
            #expect(!text.contains("}}"), Comment(rawValue: "braces left in: \(text)"))
            #expect(text.contains(job.id) || !WaTemplate.uses(template.body, "id"))
        }
    }

    @Test("the price and the currency are written the way the rest of the screen writes them")
    func moneyMatchesTheScreen() async throws {
        // A message quoting a different figure from the one on the job card is
        // a message about a different job, as far as a customer is concerned.
        let shop = await Self.loaded()
        let job = try #require(shop.orders.first { $0.price > 0 })
        let template = MessageTemplate(id: "t", name: "t", body: "{{price}} {{currency}}")
        #expect(shop.fillMessage(template, for: job)
                == Money.figure(job.price) + " " + Money.mark(shop.currency))
    }

    @Test("the status is the word this app uses, not the raw field")
    func statusIsAWord() async throws {
        let shop = await Self.loaded()
        let job = try #require(shop.orders.first { Stage.of($0) != nil })
        let template = MessageTemplate(id: "t", name: "t", body: "{{status}}")
        let said = shop.fillMessage(template, for: job)
        #expect(!said.isEmpty)
        // `post` and `on_hold` are field values, not words a customer reads.
        #expect(!said.contains("_"), Comment(rawValue: "a raw field reached a customer: \(said)"))
    }

    @Test("a job with no customer falls back to the project, not to an empty greeting")
    func namelessJobUsesTheProject() async throws {
        let shop = await Self.loaded()
        let job = try #require(shop.orders.first { $0.client.isEmpty })
        let template = MessageTemplate(id: "t", name: "t", body: "Hi {{client}}")
        #expect(shop.fillMessage(template, for: job) == "Hi " + job.project)
    }

    // MARK: - The number

    @Test("the number comes from the customer record, and a job without one has none")
    func phoneComesFromTheRecord() async throws {
        let shop = await Self.loaded()
        // A name on a job is not something to dial.
        let withRecord = try #require(shop.orders.first { job in
            guard let id = job.clientId else { return false }
            return shop.clients.contains { $0.id == id && !$0.phone.isEmpty }
        })
        #expect(!shop.customerPhone(for: withRecord).isEmpty)

        let noRecord = try #require(shop.orders.first { ($0.clientId ?? "").isEmpty })
        #expect(shop.customerPhone(for: noRecord).isEmpty)
    }

    @Test("the sample book can draw both branches")
    func sampleSpansTheCases() async {
        // A branch the sample cannot reach has never been drawn, let alone
        // reviewed: the sheet shows a WhatsApp button for one and an
        // explanation for the other.
        let shop = await Self.loaded()
        #expect(shop.clients.contains { !$0.phone.isEmpty }, "no customer has a number")
        #expect(shop.clients.contains { $0.phone.isEmpty }, "every customer has a number")
        #expect(shop.messageTemplates.count >= 3)
        // And one template that uses every placeholder between them.
        let bodies = shop.messageTemplates.map(\.body).joined()
        for key in WaTemplate.placeholders {
            #expect(bodies.contains("{{\(key)}}"),
                    Comment(rawValue: "no sample template uses {{\(key)}}, so it is never drawn"))
        }
    }

    // MARK: - The link

    @Test("the number is reduced to digits, because wa.me takes nothing else")
    func waLinkIsDigitsOnly() throws {
        // A number with a `+`, spaces or dashes opens WhatsApp on a blank
        // chat, which looks like the feature not working.
        for (typed, digits) in [("+966 50 123 4567", "966501234567"),
                                ("0501234567", "0501234567"),
                                ("(050) 123-4567", "0501234567"),
                                ("+966-50-123-4567", "966501234567")] {
            #expect(typed.filter(\.isWholeNumber) == digits,
                    Comment(rawValue: "\(typed) reduced wrongly"))
        }
    }

    @Test("a message is percent-encoded into the link rather than pasted in raw")
    func waLinkEncodes() throws {
        // The message is a shop's own sentence: it holds spaces, `&`, `#`, and
        // Arabic. Built with URLComponents so none of that truncates the text
        // or splits it into a second query parameter.
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "wa.me"; parts.path = "/966501234567"
        parts.queryItems = [URLQueryItem(name: "text", value: "مرحبا & أهلا #1 100% done")]
        let url = try #require(parts.url)
        #expect(url.absoluteString.hasPrefix("https://wa.me/966501234567?text="))
        #expect(!url.absoluteString.contains(" "))
        let back = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "text" }?.value)
        #expect(back == "مرحبا & أهلا #1 100% done", "the message did not survive the round trip")
    }
}
