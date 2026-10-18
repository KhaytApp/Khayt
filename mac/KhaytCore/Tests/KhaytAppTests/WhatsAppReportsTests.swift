import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// WhatsApp delivery reports by way of Khayt Cloud: the hook's setup and the
/// polling, through the `fetch` seam only.
@MainActor
struct WhatsAppReportsTests {

    static let connection = CloudReader.Connection(url: "https://cloud.khaytapp.com",
                                                   shopId: "shop_abc_123",
                                                   storedToken: "__enc__whatever")

    static func answer(_ code: Int, _ json: String) -> (URLRequest) -> (Data, URLResponse) {
        { request in
            (Data(json.utf8),
             HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("connecting PUTs the app secret, trimmed, and reads back the address and verify token")
    func connect() async throws {
        var seen: URLRequest?
        let hook = try await WhatsAppReports.hook(Self.connection, token: "tok", method: "PUT",
                                                  appSecret: "  abcdef0123456789abcdef  ") {
            seen = $0
            return Self.answer(200, #"{"configured":true,"url":"https://cloud.khaytapp.com/v1/hooks/whatsapp/shop_abc_123","verifyToken":"vt_1"}"#)($0)
        }
        let request = try #require(seen)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://cloud.khaytapp.com/v1/shops/shop_abc_123/whatsapp-webhook")
        let body = try JSONDecoder().decode([String: String].self, from: try #require(request.httpBody))
        #expect(body == ["appSecret": "abcdef0123456789abcdef"])
        #expect(hook.configured && hook.verifyToken == "vt_1")
    }

    @Test("a staff sign-in is told who can set it up; a bad secret is said as one")
    func failures() async throws {
        await #expect(throws: WhatsAppReports.Failure.notAllowed) {
            _ = try await WhatsAppReports.hook(Self.connection, token: "t", method: "GET",
                                               fetch: Self.answer(403, "{}"))
        }
        await #expect(throws: WhatsAppReports.Failure.badSecret) {
            _ = try await WhatsAppReports.hook(Self.connection, token: "t", method: "PUT", appSecret: "x",
                                               fetch: Self.answer(400, "{}"))
        }
    }

    @Test("the secret is checked as the cloud checks it before anything is sent")
    func plausible() {
        #expect(WhatsAppReports.plausibleSecret("abcdef0123456789"))
        #expect(!WhatsAppReports.plausibleSecret("short"))
        #expect(!WhatsAppReports.plausibleSecret("abcdef0123456789-with-dash"))
        #expect(!WhatsAppReports.plausibleSecret(String(repeating: "a", count: 129)))
    }

    @Test("reports are read after this Mac's place, and the next place is kept")
    func statuses() async throws {
        var seen: URLRequest?
        let page = try await WhatsAppReports.statuses(Self.connection, token: "tok", since: 41) {
            seen = $0
            return Self.answer(200, #"{"items":[{"messageId":"wamid.A","status":"read","seq":42}],"nextSince":42}"#)($0)
        }
        #expect(seen?.url?.absoluteString == "https://cloud.khaytapp.com/v1/shops/shop_abc_123/whatsapp-statuses?since=41")
        #expect(page.items.count == 1)
        #expect(WhatsAppReports.seq(page.nextSince) == 42)
        #expect(WhatsAppReports.seq(.string("7")) == 7)
        #expect(WhatsAppReports.seq(.null) == nil)
    }

    @Test("the shared rule moves a line forward by its message id, through the engine")
    func applies() async throws {
        let engine = try KhaytEngine()
        let clients: [JSONValue] = [.object(["id": .string("c1"), "commLog": .array([
            .object(["id": .string("m1"), "type": .string("whatsapp"), "messageId": .string("wamid.A"),
                     "status": .string("sent")]),
        ])])]
        let applied = try await engine.applyWhatsAppStatuses(clients: clients, items: [
            .object(["messageId": .string("wamid.A"), "status": .string("delivered"),
                     "at": .string("2026-10-18T08:01:00Z")]),
        ])
        #expect(applied.changed == 1)
        guard case .object(let c) = applied.clients[0], case .array(let log)? = c["commLog"],
              case .object(let line) = log[0] else { Issue.record("shape"); return }
        #expect(line["status"] == .string("delivered"))
    }

    @Test("every new string is in English and Arabic")
    func strings() async {
        for lang in ["en", "ar"] {
            let w = Words()
            await w.load(lang, engine: try? KhaytEngine())
            for key in ["mac.wa_hook_title", "mac.wa_hook_hint", "mac.wa_app_secret", "mac.wa_hook_connect",
                        "mac.wa_hook_url", "mac.wa_hook_verify", "mac.wa_hook_last", "mac.wa_hook_none_yet",
                        "mac.wa_hook_remove", "mac.wa_hook_owner_only"] {
                #expect(w.callIt(key) != key, "\(key) has no \(lang)")
            }
        }
    }
}
