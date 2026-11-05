import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Tabby / Tamara pay-later links on the Mac.
///
/// What is sent and what the answers mean are `lib/bnpl-requests.js` and
/// `lib/bnpl-confirm.js`, held by `test/bnpl-confirm.test.js` against the
/// desktop's main process. These pin that the Mac carries the same plans —
/// the same URLs, bodies and key — and keeps the same record on the job: the
/// link remembered, the payment finished and recorded ONCE through the payment
/// rule, a shipped Tamara order captured.
///
/// No test here reaches a provider: every round trip is a stub (`Fake`), and
/// there are no sandbox keys to reach one with.
@MainActor
@Suite(.serialized)
struct BnplTests {

    /// A canned provider: answers by "METHOD url", records what was sent.
    final class Fake: @unchecked Sendable {
        struct Seen: Sendable { let method: String; let url: String; let auth: String; let body: JSONValue? }
        private let lock = NSLock()
        private var answers: [String: (Int, String)]
        private(set) var seen: [Seen] = []
        init(_ answers: [String: (Int, String)]) { self.answers = answers }
        private func answer(_ s: Seen) -> (Int, String) {
            lock.withLock {
                seen.append(s)
                return answers[s.method + " " + s.url] ?? (404, #"{"error":"not stubbed"}"#)
            }
        }
        var fetch: BnplClient.Fetch {
            { [self] request in
                let method = request.httpMethod ?? "GET"
                let url = request.url?.absoluteString ?? ""
                let body = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
                let (status, text) = answer(Seen(method: method, url: url,
                                                 auth: request.value(forHTTPHeaderField: "Authorization") ?? "", body: body))
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                               headerFields: ["content-type": "application/json"])!
                return (Data(text.utf8), response)
            }
        }
    }

    static func args(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }

    // MARK: - The plans, carried

    @Test("Tamara: an approved order is authorised with the shop's key, and reported paid")
    func tamaraAuthorise() async throws {
        let engine = try KhaytEngine()
        let fake = Fake([
            "GET https://api.tamara.co/merchants/orders/ord-12345678": (200, #"{"status":"approved"}"#),
            "POST https://api.tamara.co/orders/ord-12345678/authorise": (200, #"{"status":"authorised"}"#),
        ])
        let r = try await BnplClient.run("check", args: Self.args(["provider": .string("tamara"), "id": .string("ord-12345678")]),
                                         key: "sk_disk", engine: engine, fetch: fake.fetch)
        #expect(r == BnplResult(ok: true, state: "paid", remoteStatus: "authorised", step: "authorised"))
        #expect(fake.seen.map { "\($0.method) \($0.url)" } == [
            "GET https://api.tamara.co/merchants/orders/ord-12345678",
            "POST https://api.tamara.co/orders/ord-12345678/authorise"])
        #expect(fake.seen.allSatisfy { $0.auth == "Bearer sk_disk" })
    }

    @Test("Tabby: an authorised payment is captured at Tabby's own amount, on the Saudi host for riyals")
    func tabbyCapture() async throws {
        let engine = try KhaytEngine()
        let fake = Fake([
            "GET https://api.tabby.sa/api/v2/payments/pay-12345678": (200, #"{"status":"AUTHORIZED","amount":"172.50"}"#),
            "POST https://api.tabby.sa/api/v2/payments/pay-12345678/captures": (200, #"{"status":"CLOSED"}"#),
        ])
        let r = try await BnplClient.run("check", args: Self.args([
            "provider": .string("tabby"), "id": .string("pay-12345678"), "currency": .string("SAR")]),
            key: "k", engine: engine, fetch: fake.fetch)
        #expect(r == BnplResult(ok: true, state: "paid", remoteStatus: "CLOSED", step: "captured"))
        #expect(fake.seen.last?.body == .object(["amount": .string("172.50"),
                                                 "reference_id": .string("khayt-capture-pay-12345678")]))
    }

    @Test("an id that could change the URL, an unknown provider and a missing key send nothing")
    func refusals() async throws {
        let engine = try KhaytEngine()
        let fake = Fake([:])
        let bad = try await BnplClient.run("check", args: Self.args(["provider": .string("tabby"), "id": .string("../../admin")]),
                                           key: "k", engine: engine, fetch: fake.fetch)
        #expect(bad.error == "Invalid payment id")
        let other = try await BnplClient.run("check", args: Self.args(["provider": .string("stripe"), "id": .string("pay-12345678")]),
                                             key: "k", engine: engine, fetch: fake.fetch)
        #expect(other.error == "Unknown provider")
        let keyless = try await BnplClient.run("check", args: Self.args(["provider": .string("tamara"), "id": .string("ord-12345678")]),
                                               key: "", engine: engine, fetch: fake.fetch)
        #expect(keyless.error == "No API key configured")
        #expect(fake.seen.isEmpty)
    }

    @Test("a refused step is reported with the provider's status, so the shop is told")
    func failedStep() async throws {
        let engine = try KhaytEngine()
        let fake = Fake([
            "GET https://api.tabby.ai/api/v2/payments/pay-12345678": (200, #"{"status":"AUTHORIZED","amount":"10.00"}"#),
            "POST https://api.tabby.ai/api/v2/payments/pay-12345678/captures": (400, #"{"error":"bad"}"#),
        ])
        let r = try await BnplClient.run("check", args: Self.args([
            "provider": .string("tabby"), "id": .string("pay-12345678"), "currency": .string("AED")]),
            key: "k", engine: engine, fetch: fake.fetch)
        #expect(r.ok == false)
        #expect(r.remoteStatus == "AUTHORIZED")
        #expect(r.error == "bad")
    }

    @Test("the Tamara checkout sends the desktop's body and keeps the order id a check takes")
    func tamaraCheckout() async throws {
        let engine = try KhaytEngine()
        let fake = Fake(["POST https://api.tamara.co/checkout":
                            (200, #"{"checkout_url":"https://checkout.tamara.co/x","checkout_id":"chk-1","order_id":"ord-12345678"}"#)])
        let r = try await BnplClient.run("checkout", args: Self.args([
            "provider": .string("tamara"), "amount": .number(172.5), "currency": .string("sar"),
            "description": .string("Lamp"), "itemName": .string("Lamp"), "orderId": .string("INV-7"),
            "country": .string("sa"),
            "buyer": .object(["name": .string("Sara Al Ahmad"), "phone": .string("+966500000000"), "email": .string("s@x.test")]),
        ]), key: "k", engine: engine, fetch: fake.fetch)
        #expect(r.ok && r.url == "https://checkout.tamara.co/x" && r.orderId == "ord-12345678")
        guard case .object(let body)? = fake.seen.first?.body else { Issue.record("no body"); return }
        #expect(body["total_amount"] == .object(["amount": .string("172.50"), "currency": .string("SAR")]))
        #expect(body["country_code"] == .string("SA"))
        #expect(body["consumer"] == .object(["email": .string("s@x.test"), "first_name": .string("Sara"),
                                             "last_name": .string("Al Ahmad"), "phone_number": .string("+966500000000")]))
    }

    @Test("a checkout's arguments are the desktop dialog's: the price, the document number, the customer")
    func checkoutArgs() async throws {
        let engine = try KhaytEngine()
        let order: JSONValue = .object(["id": .string("J1"), "project": .string("Lamp"), "price": .number(200),
                                        "clientId": .string("C1"), "date": .string("2026-10-01")])
        let clients: [JSONValue] = [.object(["id": .string("C1"), "phone": .string("+9665"), "email": .string("c@x.test")])]
        let settings: [String: JSONValue] = ["bnpl": .object(["tabby": .object(["merchantCode": .string("M1")])])]
        let a = try await engine.bnplCheckoutArgs(order: order, provider: "tabby", settings: settings,
                                                  clients: clients, buyerName: "Noura")
        guard case .object(let o) = a else { Issue.record("not an object"); return }
        #expect(o["amount"] == .number(200))
        #expect(o["currency"] == .string("SAR"), "the desktop's default")
        #expect(o["merchantCode"] == .string("M1"))
        #expect(o["description"] == .string("Lamp"))
        #expect(o["buyer"] == .object(["name": .string("Noura"), "phone": .string("+9665"), "email": .string("c@x.test")]))
        let number = try await engine.documentNumber(order: order, settings: settings)
        #expect(o["orderId"] == .string(number))
    }

    // MARK: - Settings

    @Test("the settings save merges per provider: an absent key is kept, an empty one cleared, Stripe untouched")
    func settingsSave() async throws {
        let engine = try KhaytEngine()
        var root: [String: JSONValue] = ["settings": .object(["bnpl": .object([
            "tabby": .object(["enabled": .bool(false), "apiKey": .string("__enc__a"), "merchantCode": .string("M"), "currency": .string("SAR")]),
            "tamara": .object(["enabled": .bool(true), "apiKey": .string("__enc__b"), "notificationToken": .string("__enc__c")]),
            "stripe": .object(["enabled": .bool(true), "apiKey": .string("__enc__s")]),
        ])])]
        try await Shop.applySettings(to: &root, form: ["bnpl": .object([
            "tabby": .object(["enabled": .bool(true), "merchantCode": .string(" M2 "), "currency": .string("SAR")]),
            "tamara": .object(["enabled": .bool(true), "notificationToken": .string(""), "currency": .string("SAR"), "country": .string("SA")]),
        ])], country: nil, engine: engine)
        guard case .object(let s)? = root["settings"], case .object(let b)? = s["bnpl"],
              case .object(let tabby)? = b["tabby"], case .object(let tamara)? = b["tamara"] else {
            Issue.record("no bnpl"); return
        }
        #expect(tabby["enabled"] == .bool(true))
        #expect(tabby["merchantCode"] == .string("M2"))
        #expect(tabby["apiKey"] == .string("__enc__a"), "absent keeps the stored key")
        #expect(tamara["apiKey"] == .string("__enc__b"))
        #expect(tamara["notificationToken"] == .string(""), "empty is the forget switch")
        #expect(b["stripe"] == .object(["enabled": .bool(true), "apiKey": .string("__enc__s")]))
    }

    @Test("a typed key is sealed, the forget switch clears, and an untouched field sends nothing")
    func secretField() async throws {
        let seal: (String) async throws -> String = { "__enc__" + $0 }
        #expect(try await BnplSettings.sealed(" k1 ", forget: false, seal: seal) == .string("__enc__k1"))
        #expect(try await BnplSettings.sealed("", forget: true, seal: seal) == .string(""))
        #expect(try await BnplSettings.sealed("", forget: false, seal: seal) == nil)
    }

    // MARK: - The book

    static let settings: JSONValue = .object([
        "currency": .string("SAR"),
        "bnpl": .object([
            "tabby": .object(["enabled": .bool(true), "apiKey": .string("sk_test_tabby"), "currency": .string("SAR")]),
            "tamara": .object(["enabled": .bool(true), "apiKey": .string("sk_test_tamara"), "currency": .string("SAR")]),
        ]),
    ])

    static func job(_ id: String, links: [JSONValue] = [], extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var o: [String: JSONValue] = [
            "id": .string(id), "date": .string("2026-10-01"), "status": .string("completed"),
            "project": .string("Lamp"), "client": .string("Sara"),
            "price": .number(200), "paidAmount": .number(0), "paymentStatus": .string("unpaid"),
            "printTime": .number(1), "priority": .bool(false), "notes": .string(""), "rev": .number(1),
        ]
        if !links.isEmpty { o["bnplLinks"] = .array(links) }
        for (k, v) in extra { o[k] = v }
        return o
    }

    static func link(_ provider: String, _ id: String, state: String = "open", extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = [
            "provider": .string(provider), "id": .string(id), "amount": .number(200), "currency": .string("SAR"),
            "createdAt": .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))),
            "state": .string(state),
        ]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    static func book(_ jobs: [[String: JSONValue]]) -> [String: JSONValue] {
        DepositsAndRemindersTests.book(jobs, settings: settings)
    }

    static func links(_ disk: [String: JSONValue]) -> [[String: JSONValue]] {
        guard case .array(let l)? = disk["bnplLinks"] else { return [] }
        return l.compactMap { if case .object(let o) = $0 { return o }; return nil }
    }
}

/// The writes, on a real book in a temp folder — serialized with the other
/// suite that owns that folder (`withPerfBook`).
extension LibraryEditPerfTests {

    @Test("a Tabby link the customer paid is captured, recorded on the job once, and left alone after")
    func bnpl_paidLinkIsRecordedOnce() async throws {
        let fake = BnplTests.Fake([
            "GET https://api.tabby.sa/api/v2/payments/pay-12345678": (200, #"{"status":"AUTHORIZED","amount":"200.00"}"#),
            "POST https://api.tabby.sa/api/v2/payments/pay-12345678/captures": (200, #"{"status":"CLOSED"}"#),
        ])
        let kept = Shop.bnplFetch
        Shop.bnplFetch = fake.fetch
        defer { Shop.bnplFetch = kept }
        try await withPerfBook(BnplTests.book([BnplTests.job("J1", links: [BnplTests.link("tabby", "pay-12345678")])])) { shop, url in
            shop.stopWatchingBnpl()
            let start = Date()
            await shop.checkBnplNow(now: start)
            var disk = try DepositsAndRemindersTests.onDisk(url, "J1")
            #expect(disk["paidAmount"] == .number(200), Comment(rawValue: shop.moveProblem ?? "not recorded"))
            #expect(disk["paymentStatus"] == .string("paid"))
            #expect(disk["paymentMethod"] == .string("Tabby"))
            let link = try #require(BnplTests.links(disk).first)
            #expect(link["state"] == .string("paid"))
            #expect(link["remoteStatus"] == .string("CLOSED"))
            #expect(link["checkedAt"] != nil)
            #expect(fake.seen.map(\.auth).allSatisfy { $0 == "Bearer sk_test_tabby" }, "the key from the book")
            #expect(shop.moveNotices.contains { $0.contains("Tabby") }, "the shop is told")

            // Again, past the minimum gap: the link is no longer open.
            let asked = fake.seen.count
            await shop.checkBnplNow(now: start.addingTimeInterval(120))
            disk = try DepositsAndRemindersTests.onDisk(url, "J1")
            #expect(fake.seen.count == asked, "nothing asked about a finished link")
            #expect(disk["paidAmount"] == .number(200), "not doubled")
        }
    }

    @Test("a link still waiting on the customer writes only its new status; a declined one is closed")
    func bnpl_waitingAndClosed() async throws {
        let fake = BnplTests.Fake([
            "GET https://api.tamara.co/merchants/orders/ord-11111111": (200, #"{"status":"new"}"#),
            "GET https://api.tamara.co/merchants/orders/ord-22222222": (200, #"{"status":"declined"}"#),
        ])
        let kept = Shop.bnplFetch
        Shop.bnplFetch = fake.fetch
        defer { Shop.bnplFetch = kept }
        try await withPerfBook(BnplTests.book([
            BnplTests.job("J1", links: [BnplTests.link("tamara", "ord-11111111")]),
            BnplTests.job("J2", links: [BnplTests.link("tamara", "ord-22222222")]),
        ])) { shop, url in
            shop.stopWatchingBnpl()
            await shop.checkBnplNow()
            let one = try DepositsAndRemindersTests.onDisk(url, "J1")
            #expect(BnplTests.links(one).first?["state"] == .string("open"))
            #expect(BnplTests.links(one).first?["remoteStatus"] == .string("new"))
            #expect(one["paidAmount"] == .number(0))
            let two = try DepositsAndRemindersTests.onDisk(url, "J2")
            #expect(BnplTests.links(two).first?["state"] == .string("closed"))
            #expect(two["paidAmount"] == .number(0))
            #expect(!fake.seen.contains { $0.method == "POST" }, "nothing authorised")
        }
    }

    @Test("making a link remembers it on the job, the way the desktop does")
    func bnpl_makeLinkRemembersIt() async throws {
        let fake = BnplTests.Fake(["POST https://api.tamara.co/checkout":
            (200, #"{"checkout_url":"https://checkout.tamara.co/x","checkout_id":"chk-1","order_id":"ord-12345678"}"#)])
        let kept = Shop.bnplFetch
        Shop.bnplFetch = fake.fetch
        defer { Shop.bnplFetch = kept }
        try await withPerfBook(BnplTests.book([BnplTests.job("J1")])) { shop, url in
            shop.stopWatchingBnpl()
            #expect(shop.bnplProvidersOffered == ["tabby", "tamara"])
            let out = await shop.makeBnplLink("J1", provider: "tamara")
            #expect(out.url == "https://checkout.tamara.co/x", Comment(rawValue: out.problem ?? ""))
            #expect(out.watched)
            let disk = try DepositsAndRemindersTests.onDisk(url, "J1")
            let link = try #require(BnplTests.links(disk).first)
            #expect(link["provider"] == .string("tamara"))
            #expect(link["id"] == .string("ord-12345678"))
            #expect(link["amount"] == .number(200))
            #expect(link["currency"] == .string("SAR"))
            #expect(link["state"] == .string("open"))
            guard case .object(let body)? = fake.seen.first?.body else { Issue.record("no body"); return }
            #expect(body["total_amount"] == .object(["amount": .string("200.00"), "currency": .string("SAR")]))
            #expect(fake.seen.first?.auth == "Bearer sk_test_tamara")
        }
    }

    @Test("a Tamara order Khayt authorised is captured once its job has shipped")
    func bnpl_tamaraCapturedAtShipment() async throws {
        let fake = BnplTests.Fake([
            "GET https://api.tamara.co/merchants/orders/ord-12345678":
                (200, #"{"status":"authorised","total_amount":{"amount":200,"currency":"SAR"}}"#),
            "POST https://api.tamara.co/payments/capture": (200, #"{"status":"fully_captured"}"#),
        ])
        let kept = Shop.bnplFetch
        Shop.bnplFetch = fake.fetch
        defer { Shop.bnplFetch = kept }
        let now = Date()
        let authorised = ISO8601DateFormatter().string(from: now.addingTimeInterval(-86400))
        let shipped = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        try await withPerfBook(BnplTests.book([BnplTests.job("J1",
            links: [BnplTests.link("tamara", "ord-12345678", state: "paid",
                                   extra: ["remoteStatus": .string("authorised"), "authorisedAt": .string(authorised)])],
            extra: ["shippedAt": .string(shipped), "courierName": .string("SMSA"), "paidAmount": .number(200)])])) { shop, url in
            shop.stopWatchingBnpl()
            await shop.captureShippedTamara(now: now)
            let disk = try DepositsAndRemindersTests.onDisk(url, "J1")
            let link = try #require(BnplTests.links(disk).first)
            #expect(link["capturedAt"] != nil)
            #expect(link["remoteStatus"] == .string("fully_captured"))
            let post = try #require(fake.seen.first { $0.method == "POST" })
            guard case .object(let body)? = post.body, case .object(let info)? = body["shipping_info"] else {
                Issue.record("no shipping"); return
            }
            #expect(body["order_id"] == .string("ord-12345678"))
            #expect(info["shipping_company"] == .string("SMSA"))
            #expect(disk["paidAmount"] == .number(200), "a capture records no second payment")
        }
    }
}
