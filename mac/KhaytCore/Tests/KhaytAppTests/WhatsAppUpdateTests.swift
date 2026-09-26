import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// WhatsApp updates at a job's milestones, with no account.
///
/// The rules are `lib/whatsapp-message.js` and are tested in Node. What is
/// pinned here is the Mac's side: that the bundled rule is the one called,
/// that the sample book reaches every branch the screen draws, that the
/// customer's language and number survive a save, and that the button, the
/// sheet and the log are wired to something.
@MainActor
struct WhatsAppUpdateTests {

    static func loaded() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    // MARK: - The number

    @Test("a local Saudi number opens WhatsApp on the international number")
    func saudiNumbersNormalise() async throws {
        let shop = await Self.loaded()
        for typed in ["0501234567", "050 123 4567", "+966 50 123 4567", "966501234567",
                      "00966501234567", "٠٥٠١٢٣٤٥٦٧"] {
            let chat = await shop.whatsAppRecipient(phone: typed)
            #expect(chat.ok, Comment(rawValue: typed))
            #expect(chat.e164 == "+966501234567", Comment(rawValue: "\(typed) → \(chat.e164)"))
            #expect(chat.link == "https://wa.me/966501234567", Comment(rawValue: chat.link))
        }
    }

    @Test("an unusable number is refused with a sentence, not a dead button")
    func unusableNumbersAreRefused() async {
        let shop = await Self.loaded()
        for (typed, reason) in [("", "no_phone"), ("12345", "too_short"),
                                ("07700900123", "no_country_code"),
                                ("+966 920 012 345", "bad_saudi_number")] {
            let chat = await shop.whatsAppRecipient(phone: typed)
            #expect(!chat.ok)
            #expect(chat.reason == reason, Comment(rawValue: "\(typed): \(chat.reason)"))
            #expect(chat.link.isEmpty)
            // Every reason has words of its own, in both languages.
            let said = shop.whatsAppReason(chat.reason)
            #expect(!said.hasPrefix("mac."), Comment(rawValue: said))
        }
        for reason in ["no_customer", "too_short", "too_long", "no_country_code",
                       "bad_saudi_number", "no_milestone"] {
            for lang in ["en", "ar"] {
                #expect(Words.own["mac.wa_reason_" + reason]?[lang]?.isEmpty == false,
                        Comment(rawValue: "\(reason) has no \(lang) words"))
            }
        }
    }

    @Test("the text survives the link: + and & are escaped, Arabic intact")
    func linkCarriesTheText() async throws {
        let shop = await Self.loaded()
        let engine = try #require(shop.engine)
        let text = "طلبك جاهز — 1+1 & more"
        let chat = try await engine.whatsAppChat(phone: "0501234567", text: text)
        let url = try #require(URL(string: chat.link))
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.host == "wa.me" && parts.path == "/966501234567")
        #expect(parts.queryItems?.first { $0.name == "text" }?.value == text)
    }

    // MARK: - The sample book spans the cases

    @Test("the sample book reaches every branch the sheet and the row draw")
    func sampleSpansTheCases() async throws {
        let shop = await Self.loaded()
        var reasons = Set<String>()
        var milestones = Set<String>()
        for job in shop.orders {
            let recipient = await shop.whatsAppRecipient(for: job)
            reasons.insert(recipient.ok ? "ok" : recipient.reason)
            if let offer = await shop.whatsAppOffer(for: job) { milestones.insert(offer.milestone) }
        }
        #expect(reasons.contains("ok"), "no job can be sent")
        #expect(reasons.contains("no_customer"), "no job without a customer record")
        #expect(reasons.contains("no_phone"), "no customer without a number")
        #expect(reasons.contains("no_country_code"), "no number the rule refuses")
        #expect(milestones.isSuperset(of: ["received", "ready", "delivered"]),
                Comment(rawValue: "milestones drawn: \(milestones)"))
        // A quote owes no update.
        let quote = try #require(shop.orders.first { $0.status == "quote" })
        #expect(await shop.whatsAppOffer(for: quote) == nil)
        // And a template for a milestone, so that branch of the editor is drawn.
        #expect(shop.messageTemplates.contains { !$0.milestone.isEmpty && !$0.lang.isEmpty })
    }

    @Test("a job's update is in the customer's language, from the bundled rule")
    func updateForAJob() async throws {
        let shop = await Self.loaded()
        let job = try #require(shop.orders.first {
            shop.clientRecord(for: $0)?.client.phone == "+966 50 123 4567"
        })
        let update = try #require(await shop.whatsAppUpdate(for: job))
        #expect(update.ok, Comment(rawValue: update.reason))
        #expect(update.e164 == "+966501234567")
        #expect(!update.text.contains("{{"), Comment(rawValue: update.text))
        #expect(update.text.contains(job.id))
        // Both names are written down for this customer, so the shop's
        // language decides; each language gives its own words.
        let ar = try #require(await shop.whatsAppUpdate(for: job, milestone: "ready", lang: "ar"))
        let en = try #require(await shop.whatsAppUpdate(for: job, milestone: "ready", lang: "en"))
        #expect(ar.text.contains("مرحباً") && ar.lang == "ar", Comment(rawValue: ar.text))
        #expect(en.text.hasPrefix("Hi ") && en.lang == "en", Comment(rawValue: en.text))
        #expect(ar.isDefault && en.isDefault)
        // The sample's own English "shipped" template replaces the default.
        let shipped = try #require(await shop.whatsAppUpdate(for: job, milestone: "shipped", lang: "en"))
        #expect(shipped.templateId == "tpl-shipped-en")
        #expect(!shipped.isDefault)
    }

    // MARK: - The customer record

    @Test("the customer's message language is read, written, and survives every copier")
    func messageLangRoundTrips() throws {
        let json = #"{"id":"C1","nameEn":"Layla","phone":"0501234567","messageLang":"en"}"#
        let client = try JSONDecoder().decode(Client.self, from: Data(json.utf8))
        #expect(client.messageLang == "en")
        #expect(client.record["messageLang"] == .string("en"))
        #expect(client.with(\.phone, "0559").messageLang == "en")
        #expect(client.with(\.messageLang, "").record["messageLang"] == .string(""),
                "going back to automatic cannot clear a stored language")
        #expect(client.marketed(false).messageLang == "en")
        #expect(client.replacing(priceList: []).messageLang == "en")
        #expect(client.replacing(recurring: nil).messageLang == "en")
    }

    @Test("a marketing opt-out survives the customer sheet's save")
    func optOutSurvivesTheSave() {
        // The sheet saves `draft.replacing(priceList:).replacing(recurring:)`.
        // Both dropped the opt-out, and `record` always writes the flag — so
        // every opt-out ticked on the sheet was saved as "may be marketed to".
        let draft = Client(id: "C1", nameEn: "Layla").marketed(false)
        let saving = draft.replacing(priceList: []).replacing(recurring: nil)
        #expect(saving.marketingOptOut)
        #expect(saving.record["marketingOptOut"] == .bool(true))
    }

    // MARK: - Templates

    @Test("a milestone template keeps its milestone and language through the book's shape")
    func templateRowsCarryMilestones() {
        let rows: [JSONValue] = [
            .object(["id": .string("a"), "name": .string("Ready"), "body": .string("Hi"),
                     "milestone": .string("ready"), "lang": .string("ar")]),
            .object(["id": .string("b"), "name": .string("Plain"), "body": .string("Hi")]),
        ]
        let made = MessageTemplate.from(rows)
        #expect(made.map(\.row) == rows, "a template read and written back changed shape")
        #expect(made[0].milestone == "ready" && made[0].lang == "ar")
        #expect(made[1].milestone.isEmpty && made[1].lang.isEmpty)
    }

    // MARK: - Wiring

    @Test("the row, the sheet, the customer button and the log are all wired")
    func wiredIn() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        func read(_ name: String) throws -> String {
            try String(contentsOf: sources.appending(path: name), encoding: .utf8)
        }
        #expect(try read("OrderInspector.swift").contains("WhatsAppJobRow(shop: shop, job: job)"),
                "the job never offers the update")
        #expect(try read("ShopWindow.swift").contains("MessageSheet(shop: shop"),
                "nothing raises the WhatsApp sheet")
        #expect(try read("CustomersTable.swift").contains("openWhatsAppChat(with: record)"),
                "the customer has no WhatsApp button")
        #expect(try read("CustomerSheet.swift").contains("binding(\\.messageLang)"),
                "the customer's language cannot be set")
        let send = try read("WhatsApp.swift")
        #expect(send.contains("whatsAppCommEntry(") && send.contains("addCommunication("),
                "sending writes nothing to the customer's log")
        #expect(try read("MessageSheet.swift").contains("shop.sendWhatsApp("),
                "the sheet opens WhatsApp some other way than the one that logs")
    }
}
