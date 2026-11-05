import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The integrations the Mac now sends as the desktop does: texts, webhook
/// deliveries with their log and retries, the accounting push and the KPI
/// email digest. The rules are `lib/`; these hold that the Mac asks them, in
/// the desktop's fields, and that what it saves the desktop can read.
@MainActor
struct IntegrationsParityTests {

    // MARK: - SMS

    @Test("a Twilio text is the shared request, byte for byte — form, Basic header, no Node")
    func twilioRequest() async throws {
        let engine = try KhaytEngine()
        let req = try await engine.smsRequest(
            provider: "twilio", config: ["accountSid": .string("AC1"), "authToken": .string("tok"),
                                         "from": .string("+15550001111")],
            to: "+966 50 000 0000", message: "طلبك جاهز", channel: "sms")
        #expect(req.error == nil)
        #expect(req.url == "https://api.twilio.com/2010-04-01/Accounts/AC1/Messages.json")
        #expect(req.headers?["Authorization"] == "Basic " + Data("AC1:tok".utf8).base64EncodedString())
        #expect(req.contentType == "application/x-www-form-urlencoded")
        // URLSearchParams' own encoding: the Arabic as UTF-8 %XX, a space as +.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._")
        let body = "طلبك جاهز".addingPercentEncoding(withAllowedCharacters: allowed)!
            .replacingOccurrences(of: "%20", with: "+")
        #expect(req.body == "From=%2B15550001111&To=%2B966500000000&Body=" + body)
    }

    @Test("a misconfigured provider is refused with the rule's own sentence, not thrown")
    func refusals() async throws {
        let engine = try KhaytEngine()
        let req = try await engine.smsRequest(provider: "twilio", config: [:], to: "+1", message: "x", channel: "sms")
        #expect(req.url == nil)
        #expect(req.error?.contains("Account SID") == true)
        let account = try await engine.smsAccount(settings: ["smsConfig": .object([
            "provider": .string("whatsapp_cloud"), "token": .string("t")])])
        #expect(account.ok == false && account.reason == "not_set_up",
                "WhatsApp Business sends templates, never a text")
    }

    @Test("a text is logged as an sms line on the job's milestone, and found again")
    func smsLog() async throws {
        let engine = try KhaytEngine()
        let entry = try await engine.smsCommEntry(id: "CMM1", at: Date(timeIntervalSince1970: 0), text: "Ready",
                                                  orderId: "J1", milestone: "ready", provider: "twilio")
        guard case .object(let o) = entry else { Issue.record("no entry"); return }
        #expect(o["type"] == .string("sms"))
        #expect(o["milestone"] == .string("ready"))
        #expect(try await engine.smsSentAt(commLog: [entry], orderId: "J1", milestone: "ready") == "1970-01-01T00:00:00Z")
        #expect(try await engine.smsSentAt(commLog: [entry], orderId: "J1", milestone: "shipped") == nil)
    }

    @Test("campaign channels: email, and the text channels once there is a text provider")
    func campaignChannels() {
        #expect(Shop.Segment.channels(textProvider: false) == ["email"])
        #expect(Shop.Segment.channels(textProvider: true) == ["email", "sms", "whatsapp"])
    }

    @Test("the SMS pane writes the provider only when it was changed there")
    func smsForm() {
        var opened = SmsSettings.Draft()
        opened.provider = "whatsapp_cloud"
        var d = opened
        d.channel = "sms"
        #expect(d.form(opened: opened)["provider"] == nil, "saving the channel kept WhatsApp Business")
        d.provider = "twilio"
        #expect(d.form(opened: opened)["provider"] == .string("twilio"))
    }

    @Test("saving the SMS fields keeps the WhatsApp Business token, and seals nothing in the clear")
    func smsSave() async throws {
        let engine = try KhaytEngine()
        var root: [String: JSONValue] = ["settings": .object(["smsConfig": .object([
            "provider": .string("whatsapp_cloud"), "phoneNumberId": .string("123"), "token": .string("__enc__W")])])]
        try await Shop.applySettings(to: &root, form: ["smsConfig": .object([
            "provider": .string("unifonic"), "appSid": .string("__enc__A"), "senderId": .string(" Acme "),
            "channel": .string("sms")])], country: nil, engine: engine)
        guard case .object(let s)? = root["settings"], case .object(let c)? = s["smsConfig"] else {
            Issue.record("no smsConfig"); return
        }
        #expect(c["provider"] == .string("unifonic"))
        #expect(c["appSid"] == .string("__enc__A"))
        #expect(c["senderId"] == .string("Acme"))
        #expect(c["token"] == .string("__enc__W"))
    }

    // MARK: - Webhooks

    static func book() -> [String: JSONValue] {
        ["webhooks": .object([
            "enabled": .bool(true), "secret": .string("shared"),
            "subscriptions": .array([
                .object(["id": .string("whs_a"), "url": .string("https://a.example.com/h"),
                         "events": .array([.string("status_changed")]), "secret": .string("")]),
            ]),
        ])]
    }

    @Test("a subscription with no secret of its own signs with the shop's signing secret")
    func sharedSecret() async throws {
        let engine = try KhaytEngine()
        let owed = try await engine.webhookDeliveries(
            order: .object(["id": .string("J1"), "project": .string("Bracket")]),
            effects: [.init(kind: "webhook", event: "status_changed", newStatus: "completed")],
            settings: Self.book(), shopName: "Acme", clientName: "Maha", currency: "SAR",
            at: "2026-11-05T10:00:00.000Z", nowMs: 1_800_000_000_000)
        let one = try #require(owed.first)
        #expect(one.secret == "shared")
        #expect(one.subscriptionId == "whs_a")
        #expect(one.attempt == 1)
        guard case .object(let p)? = one.payload else { Issue.record("no payload"); return }
        #expect(p["orderId"] == .string("J1"))
    }

    @Test("a failure goes in the log and on the queue; a 410 switches the subscription off")
    func attemptPolicy() async throws {
        let engine = try KhaytEngine()
        let owed = try await engine.webhookDeliveries(
            order: .object(["id": .string("J1")]),
            effects: [.init(kind: "webhook", event: "status_changed", newStatus: "completed")],
            settings: Self.book(), shopName: "Acme", clientName: "", currency: "SAR",
            at: "2026-11-05T10:00:00.000Z", nowMs: 1_800_000_000_000)
        let one = try #require(owed.first)
        guard case .object(let s) = Self.book()["webhooks"]! else { return }
        let failed = try await engine.webhookAttempt(webhooks: .object(s), delivery: one, status: 503,
                                                     error: "HTTP 503", nowMs: 1_800_000_000_000, at: "T")
        #expect(failed.retry && failed.afterMs == 30_000)
        guard case .object(let wh) = failed.webhooks, case .array(let log)? = wh["deliveries"],
              case .array(let pending)? = wh["pending"] else { Issue.record("no log"); return }
        #expect(log.count == 1 && pending.count == 1)
        if case .object(let line) = log[0] {
            #expect(line["status"] == .string("retrying"))
            #expect(line["payload"] != nil, "a resend needs what was sent")
        }
        // The retry comes back off the queue, addressed as the settings now say.
        let due = try await engine.webhookDue(failed.webhooks, nowMs: 1_800_000_000_000 + 31_000)
        #expect(due.count == 1)
        var settings = Self.book()
        settings["webhooks"] = failed.webhooks
        let again = try #require(try await engine.webhookRedelivery(due[0], settings: settings, resend: false,
                                                                     nowMs: 1_800_000_031_000, at: "T2"))
        #expect(again.attempt == 2 && again.deliveryId == one.deliveryId && again.secret == "shared")
        // Delivered: off the queue.
        let ok = try await engine.webhookAttempt(webhooks: failed.webhooks, delivery: again, status: 200,
                                                 error: nil, nowMs: 1_800_000_031_000, at: "T2")
        guard case .object(let okWh) = ok.webhooks, case .array(let left)? = okWh["pending"] else { return }
        #expect(left.isEmpty && !ok.retry)
        // Gone: never again, and the subscription is switched off.
        let gone = try await engine.webhookAttempt(webhooks: .object(s), delivery: one, status: 410,
                                                   error: "HTTP 410", nowMs: 0, at: "T")
        #expect(gone.gone && !gone.retry)
        guard case .object(let g) = gone.webhooks, case .array(let subs)? = g["subscriptions"],
              case .object(let sub) = subs[0] else { return }
        #expect(sub["enabled"] == .bool(false))
        // A retry for a subscription the shop removed is not sent.
        var removed = Self.book()
        removed["webhooks"] = .object(["enabled": .bool(true), "subscriptions": .array([])])
        #expect(try await engine.webhookRedelivery(due[0], settings: removed, resend: false, nowMs: 0, at: "") == nil)
    }

    @Test("the delivery log decodes newest first")
    func logDecode() {
        let settings: [String: JSONValue] = ["webhooks": .object(["deliveries": .array([
            .object(["id": .string("d1"), "subscriptionId": .string("whs_a"), "event": .string("status_changed"),
                     "at": .string("2026-11-01T00:00:00Z"), "status": .string("failed"), "attempts": .number(5)]),
            .object(["id": .string("d2"), "subscriptionId": .string("event:status"), "event": .string("order.status"),
                     "at": .string("2026-11-02T00:00:00Z"), "status": .string("ok"), "httpStatus": .number(200)]),
        ])])]
        let lines = Shop.webhookLog(in: settings)
        #expect(lines.map(\.event) == ["order.status", "status_changed"])
        #expect(lines[1].attempts == 5)
        #expect(lines[0].httpStatus == 200)
    }

    @Test("the webhooks pane shows a legacy book as the subscriptions it becomes, and saves them")
    func legacyBook() async throws {
        let engine = try KhaytEngine()
        let legacy: [String: JSONValue] = ["webhooks": .object([
            "enabled": .bool(true), "secret": .string("__enc__S"),
            "events": .object(["status_changed": .string("https://a.example.com/h"),
                               "payment_received": .string("https://a.example.com/h"),
                               "order_created": .string("")]),
        ])]
        let draft = WebhookSettings.Draft.read(legacy)
        #expect(draft.subs.count == 1)
        #expect(draft.subs[0].events == ["status_changed", "payment_received"])
        #expect(draft.subs[0].isNew)
        var root: [String: JSONValue] = ["settings": .object(legacy)]
        try await Shop.applySettings(to: &root, form: ["webhooks": .object(draft.form())], country: nil, engine: engine)
        guard case .object(let s)? = root["settings"], case .object(let wh)? = s["webhooks"],
              case .array(let subs)? = wh["subscriptions"], case .object(let events)? = wh["events"] else {
            Issue.record("not saved"); return
        }
        #expect(subs.count == 1)
        #expect(wh["secret"] == .string("__enc__S"), "the sealed signing secret is kept")
        #expect(events["payment_received"] == .string("https://a.example.com/h"),
                "the desktop's per-event screen still shows the address")
    }

    // MARK: - Accounting

    @Test("an invoice is pushed once, when paid, as the row the accountant's CSV has")
    func accountingPayload() async throws {
        let engine = try KhaytEngine()
        let settings: [String: JSONValue] = [
            "currency": .string("SAR"), "enableVat": .bool(true), "vatRate": .number(15),
            "accountingSync": .object(["enabled": .bool(true), "webhookUrl": .string("https://books.example/k"),
                                       "format": .string("xero"), "salesAccount": .string("200")]),
        ]
        let order: JSONValue = .object(["id": .string("J1"), "status": .string("completed"), "price": .number(115),
                                        "paymentStatus": .string("paid"), "paidAt": .string("2026-11-03"),
                                        "date": .string("2026-10-30")])
        #expect(try await engine.accountingWouldPush(order: order, settings: settings).push)
        let payload = try #require(try await engine.accountingPayload(order: order, settings: settings, clients: []))
        guard case .object(let p) = payload else { Issue.record("no payload"); return }
        #expect(p["type"] == .string("invoice"))
        #expect(p["date"] == .string("2026-11-03"), "dated the day it was paid, as the desktop sends")
        #expect(p["salesAccount"] == .string("200"))
        #expect(p["format"] == .string("xero"))
        guard case .string(let key)? = p["idempotencyKey"] else { Issue.record("no key"); return }
        #expect(key.hasPrefix("inv:"))
        let req = try await engine.accountingRequest(payload: payload, secret: "s3")
        #expect(req.headers["X-Khayt-Secret"] == "s3")
        #expect(req.headers["Idempotency-Key"] == key)
        // Pushed: never again. A quote: never at all.
        guard case .object(var pushed) = order else { return }
        pushed["accountingPushedAt"] = .string("2026-11-03T10:00:00Z")
        #expect(try await engine.accountingWouldPush(order: .object(pushed), settings: settings).reason == "already_pushed")
        #expect(try await engine.accountingPayload(order: .object(["id": .string("Q"), "status": .string("quote"),
                                                                  "price": .number(5)]),
                                                   settings: settings, clients: []) == nil)
    }

    @Test("the retry sweep takes failed pushes only, and a success clears the failure")
    func accountingRetry() async throws {
        let engine = try KhaytEngine()
        let settings: [String: JSONValue] = ["accountingSync": .object([
            "enabled": .bool(true), "webhookUrl": .string("https://books.example/k")])]
        let orders: [JSONValue] = [
            .object(["id": .string("A"), "paymentStatus": .string("paid")]),
            .object(["id": .string("B"), "paymentStatus": .string("paid"), "accountingPushFailedAt": .string("x")]),
        ]
        #expect(try await engine.accountingRetryable(orders: orders, settings: settings) == ["B"])
        let ok = try await engine.accountingOutcome(ok: true, at: "T", error: nil)
        #expect(ok.set["accountingPushedAt"] == .string("T"))
        #expect(ok.clear == ["accountingPushFailedAt", "accountingPushError"])
    }

    // MARK: - The KPI email

    @Test("the digest is due at its hour, once a period, and is the desktop's email")
    func digest() async throws {
        let engine = try KhaytEngine()
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 5; parts.hour = 8; parts.minute = 3
        let at = try #require(Calendar(identifier: .gregorian).date(from: parts))
        let ms = at.timeIntervalSince1970 * 1000
        var settings: [String: JSONValue] = ["email": .string("shop@example.com"), "currency": .string("SAR"),
                                             "emailDigest": .object(["enabled": .bool(true), "hour": .number(8)])]
        let due = try await engine.digestDue(settings: settings, nowMs: ms)
        #expect(due.due && due.periodKey == "2026-11-05")
        settings["emailDigest"] = try await engine.digestSent(settings: settings, periodKey: due.periodKey)
        #expect(try await engine.digestDue(settings: settings, nowMs: ms).reason == "already_sent")
        let mail = try await engine.digestEmail(
            orders: [], inventory: [.object(["material": .string("PLA"), "weight": .number(100)])],
            waitingList: [], clients: [], settings: settings, shopName: "Acme", localeTag: "en",
            nowMs: ms, test: true)
        #expect(mail.to == "shop@example.com")
        #expect(mail.subject == "Acme — Test Digest")
        #expect(mail.html.contains("PLA — 100g remaining"))
    }

    @Test("the cloud digest's refusals are sentences: 403 owner-only, 409 no-account")
    func cloudRefusals() {
        let words = Words()
        #expect(Shop.cloudDigestRefusal(.init(status: 403, reason: "owner-only", error: ""), words: words)
                == words.callIt("mac.summary_cloud_owner_only"))
        #expect(Shop.cloudDigestRefusal(.init(status: 409, reason: "no-account", error: ""), words: words)
                == words.callIt("mac.summary_cloud_no_account"))
        #expect(Shop.cloudDigestRefusal(.init(status: 500, reason: "", error: "x"), words: words)
                == words.callIt("mac.summary_cloud_failed"))
        #expect(words.callIt("mac.summary_cloud_not_yet") != "mac.summary_cloud_not_yet")
    }

    @Test("the email summary offers the four choices and writes the desktop's digest fields")
    func summaryForm() {
        var local = EmailSummarySettings.Local()
        local.enabled = true
        local.frequency = "weekly"
        local.weekday = 0
        let form = local.form()
        #expect(form["enabled"] == .bool(true))
        #expect(form["weekday"] == .number(0))
        #expect(form["recipientEmail"] == .string(""))
        #expect(form["lastSentDate"] == nil, "the period key is the sender's, never a form's")
    }
}
