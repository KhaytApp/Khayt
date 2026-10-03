import Foundation
import CryptoKit
import Testing
@testable import KhaytApp
@testable import KhaytCore

/// The network clients' security review, Oct 2026: smart plugs, the scrypt
/// cost a keyset may ask for, https for sign-in and the portal, the AI
/// client's redirects, and the webhook's pinned socket and second signature.
/// (The cloud rollback check is in `CloudRollbackTests`, the Bambu pin and
/// packet cap in `SecurityBatch4Tests`.)
@MainActor
struct ClientSecurityTests {

    static func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/\(name)"), encoding: .utf8)
    }

    // MARK: - Smart plugs

    @Test("a plug is spoken to only on this network — the printer's guard, not a looser one")
    func plugHost() async throws {
        let engine = try KhaytEngine()
        // Names resolve through a fake: a name is judged by where it points
        // (Alpha58SecurityTests.plugNamesResolve), and a Nabu Casa remote URL
        // points at the public internet, so it is refused like 8.8.8.8 is.
        let dns: @Sendable (String) async -> [String] = { name in
            ["homeassistant.local": ["192.168.1.30"], "ha.example.ui.nabu.casa": ["35.157.1.2"]][name] ?? []
        }
        for ok in ["http://192.168.1.40/relay/0", "http://10.0.0.7/cm?cmnd=Power",
                   "http://homeassistant.local:8123/api/states/switch.x"] {
            #expect(await SmartPlug.allowed(URL(string: ok)!, engine: engine, resolve: dns), Comment(rawValue: ok))
        }
        for bad in ["http://8.8.8.8/relay/0", "http://127.0.0.1:8123/api", "http://localhost/relay/0",
                    "http://169.254.169.254/latest/meta-data/", "http://2130706433/relay/0",
                    "http://user:pw@192.168.1.40/relay/0", "file:///etc/passwd",
                    "https://ha.example.ui.nabu.casa/api/states/switch.x"] {
            #expect(!(await SmartPlug.allowed(URL(string: bad)!, engine: engine, resolve: dns)), Comment(rawValue: bad))
        }
    }

    @Test("a Home Assistant token never leaves for a public address — nothing is sent at all")
    func plugTokenStaysHome() async throws {
        let engine = try KhaytEngine()
        let machine: JSONValue = .object(["id": .string("M1"), "smartPlug": .object([
            "type": .string("homeassistant"), "host": .string("http://203.0.113.9:8123"),
            "entity": .string("switch.core_one"), "token": .string("SECRET")])])
        let request = try #require(try await engine.plugRequest(machine: machine, action: "status"))
        var sent = false
        await #expect(throws: SmartPlug.Failure.self) {
            _ = try await SmartPlug.send(request, engine: engine, fetch: { r in
                sent = true
                return (Data(), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        }
        #expect(!sent, "the request went out before the host was checked")
        #expect(request.headers["Authorization"] == "Bearer SECRET", "the fixture carries no token to protect")
    }

    @Test("a plug's session follows no redirect, and the poller goes through the guarded send")
    func plugRedirects() throws {
        #expect(SmartPlug.session.delegate is RefuseRedirects)
        let shop = try Self.source("Shop.swift")
        #expect(!shop.contains("SmartPlug.send(request)"), "a plug call skips the host check")
        #expect(shop.contains("SmartPlug.send(request, engine: engine)"))
        let plug = try Self.source("SmartPlug.swift")
        #expect(!plug.contains("URLSession(configuration: .ephemeral).data"),
                "a plug request goes out on a session that follows redirects")
    }

    @Test("the plug sheet says so when a token or password would go over http")
    func plugCleartextWarning() throws {
        #expect(MachineSheet.plugSendsCredentialInClear(type: "homeassistant", host: "http://ha.local:8123", user: ""))
        #expect(MachineSheet.plugSendsCredentialInClear(type: "homeassistant", host: "ha.local:8123", user: ""))
        #expect(!MachineSheet.plugSendsCredentialInClear(type: "homeassistant", host: "https://ha.local", user: ""))
        #expect(MachineSheet.plugSendsCredentialInClear(type: "tasmota", host: "192.168.1.9", user: "admin"))
        #expect(!MachineSheet.plugSendsCredentialInClear(type: "tasmota", host: "192.168.1.9", user: ""))
        #expect(!MachineSheet.plugSendsCredentialInClear(type: "shelly", host: "192.168.1.9", user: ""))
        #expect(try Self.source("Words.swift").contains("\"plug.cleartext\""))
        #expect(try Self.source("MachineSheet.swift").contains("callIt(\"plug.cleartext\")"))
    }

    // MARK: - scrypt cost

    @Test("every keyset that exists still opens: the defaults, and anything up to the caps")
    func kdfDefaultsStillWork() throws {
        #expect(try SyncCrypto.Kdf.from(nil) == SyncCrypto.Kdf())
        let real = try SyncCrypto.Kdf.from(.object(["algo": .string("scrypt"), "N": .number(32768),
                                                    "r": .number(8), "p": .number(1), "keyLen": .number(32)]))
        #expect(real == SyncCrypto.Kdf())
        let atCap = try SyncCrypto.Kdf.from(.object(["N": .number(131_072), "r": .number(8), "p": .number(2)]))
        #expect(atCap.n == 131_072 && atCap.r == 8 && atCap.p == 2)
    }

    @Test("a keyset asking for more than 128 MiB of scrypt is refused by name, not clamped")
    func kdfCaps() {
        for (key, value) in [("N", 262_144.0), ("N", 1_048_576.0), ("r", 16.0), ("r", 32.0), ("p", 3.0), ("p", 16.0)] {
            #expect(throws: SyncCrypto.Failure.self, Comment(rawValue: "\(key)=\(value)")) {
                _ = try SyncCrypto.Kdf.from(.object([key: .number(value)]))
            }
        }
    }

    // MARK: - https for the cloud

    @Test("sign-in and the portal speak https; a LAN address over http is refused")
    func cloudHttpsOnly() async throws {
        #expect(throws: Never.self) { try CloudSignIn.requireHttps("https://cloud.khaytapp.com") }
        for bad in ["http://192.168.1.10:8080", "http://10.0.0.2", "http://cloud.khaytapp.com", "ftp://x"] {
            #expect(throws: CloudSignIn.InsecureAddress.self, Comment(rawValue: bad)) {
                try CloudSignIn.requireHttps(bad)
            }
        }
        #if DEBUG
        // A khayt-cloud on this Mac, in a debug build only.
        #expect(throws: Never.self) { try CloudSignIn.requireHttps("http://127.0.0.1:8787") }
        #expect(throws: Never.self) { try CloudSignIn.requireHttps("http://localhost:8787") }
        #endif

        let engine = try KhaytEngine()
        // `lib/base-url.js` lets this through (it is a private address); the
        // sign-in must not.
        #expect(try await engine.cloudBaseUrl("http://192.168.1.10:8080") == "http://192.168.1.10:8080")
        await #expect(throws: CloudSignIn.Failure.self) {
            _ = try await CloudSignIn.logIn(url: "http://192.168.1.10:8080", email: "a@b.c",
                                            password: "pw", engine: engine)
        }
        #expect(try Self.source("PortalClient.swift").contains("try CloudSignIn.requireHttps(base)"))
    }

    // MARK: - AI

    @Test("the AI request follows a redirect only to the same host")
    func aiRedirects() throws {
        #expect(AiClient.session.delegate is SameHostRedirects)
        let ai = try WebhookWiringTests.code("AiClient.swift")
        #expect(!ai.contains("URLSession.shared"), "URLSession.shared carries the API key along any redirect")
    }

    // MARK: - Webhooks

    @Test("the existing signature is unchanged, and the second one signs the timestamp too")
    func webhookSignatures() {
        let body = Data(#"{"event":"order.status","payload":{},"timestamp":1}"#.utf8)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let headers = Dictionary(WebhookClient.signedHeaders(payload: body, secret: "s3cret",
                                                             event: "order.status", now: now),
                                 uniquingKeysWith: { a, _ in a })
        let key = SymmetricKey(data: Data("s3cret".utf8))
        let hex = { (d: Data) in HMAC<SHA256>.authenticationCode(for: d, using: key)
            .map { String(format: "%02x", $0) }.joined() }
        #expect(headers["X-Khayt-Signature"] == hex(body), "the signature consumers verify today moved")
        #expect(headers["X-Khayt-Timestamp"] == "1790000000")
        #expect(headers["X-Khayt-Signature-V2"] == hex(Data("1790000000.".utf8) + body))
        #expect(headers["X-Khayt-Event"] == "order.status")
        #expect(headers["Content-Type"] == "application/json")

        let unsigned = WebhookClient.signedHeaders(payload: body, secret: "", event: "e", now: now)
        #expect(!unsigned.contains { $0.0.hasPrefix("X-Khayt-Signature") || $0.0 == "X-Khayt-Timestamp" })
    }

    @Test("the request names the host the shop typed, whatever address the socket went to")
    func webhookHead() {
        let url = URL(string: "https://hooks.example.com/in/abc?x=1")!
        let head = String(decoding: WebhookClient.requestHead(
            url, host: "hooks.example.com", headers: [("X-Khayt-Event", "order.status\r\nX-Evil: 1")],
            length: 12), as: UTF8.self)
        #expect(head.hasPrefix("POST /in/abc?x=1 HTTP/1.1\r\nHost: hooks.example.com\r\n"))
        #expect(head.contains("Content-Length: 12\r\n"))
        #expect(head.contains("Connection: close\r\n"))
        #expect(head.hasSuffix("\r\n\r\n"))
        #expect(!head.contains("\r\nX-Evil"), "a header value started a header of its own")
        let port = String(decoding: WebhookClient.requestHead(
            URL(string: "https://h.example:8443")!, host: "h.example", headers: [], length: 0), as: UTF8.self)
        #expect(port.hasPrefix("POST / HTTP/1.1\r\nHost: h.example:8443\r\n"))
    }

    @Test("the status comes off the first line, and anything else is no status")
    func webhookStatusLine() {
        #expect(WebhookClient.statusCode(Data("HTTP/1.1 204 No Content\r\n".utf8)) == 204)
        #expect(WebhookClient.statusCode(Data("HTTP/1.0 302 Found\r\nLocation: x\r\n".utf8)) == 302)
        #expect(WebhookClient.statusCode(Data("HTTP/1.1 200".utf8)) == nil, "not a whole line yet")
        #expect(WebhookClient.statusCode(Data("SSH-2.0-OpenSSH\r\n".utf8)) == nil)
        #expect(WebhookClient.statusCode(Data("HTTP/1.1 999 Nope\r\n".utf8)) == nil)
    }

    @Test("the socket goes to the checked address: nothing resolves the name a second time")
    func webhookPinned() throws {
        let client = try WebhookWiringTests.code("WebhookClient.swift")
        #expect(client.contains("NWConnection(host: NWEndpoint.Host(address)"),
                "the connection is made to the name again, which a rebinder answers differently")
        #expect(client.contains("sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)"),
                "TLS would validate the address, not the host the shop typed")
        #expect(client.contains("for address in resolved"))
    }
}
