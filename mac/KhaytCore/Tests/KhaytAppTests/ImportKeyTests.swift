import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The shop's order-import key: what goes on the wire, what a refusal says,
/// and that the key is never kept.
///
/// Every case runs through the `fetch` seam, so none of them has a shop's
/// credentials and none of them speaks to the service.
@MainActor
struct ImportKeyTests {

    static let connection = CloudReader.Connection(url: "https://cloud.khaytapp.com",
                                                   shopId: "shop_abc_123",
                                                   storedToken: "__enc__whatever")

    static func answer(_ code: Int, _ body: String) -> ImportKeyClient.Fetch {
        { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code,
                                              httpVersion: nil, headerFields: nil)!)
        }
    }

    static func expectShape(_ request: URLRequest?, _ method: String) throws {
        let request = try #require(request)
        #expect(request.httpMethod == method)
        #expect(request.url?.absoluteString
                == "https://cloud.khaytapp.com/v1/shops/shop_abc_123/import-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        // Every route records the caller's delta capability; a call without it
        // would shut the shop's delta gate.
        #expect(request.value(forHTTPHeaderField: "x-delta-capable") == "1")
    }

    // MARK: - Request shapes

    @Test("GET reads whether a key is set, and since when")
    func status() async throws {
        var seen: URLRequest?
        let got = try await ImportKeyClient.status(Self.connection, token: "tok") { request in
            seen = request
            return try await Self.answer(200, #"{"set":true,"createdAt":"2026-09-26T08:30:00Z"}"#)(request)
        }
        try Self.expectShape(seen, "GET")
        #expect(got.set)
        #expect(got.createdAt == ISO8601DateFormatter().date(from: "2026-09-26T08:30:00Z"))

        let none = try await ImportKeyClient.status(Self.connection, token: "tok",
                                                    fetch: Self.answer(200, #"{"set":false,"createdAt":null}"#))
        #expect(none == .init(set: false, createdAt: nil))
    }

    @Test("the PHP backend's MySQL timestamp is read as UTC")
    func sqlDate() {
        #expect(ImportKeyClient.date("2026-09-26 08:30:00")
                == ISO8601DateFormatter().date(from: "2026-09-26T08:30:00Z"))
        #expect(ImportKeyClient.date("2026-09-26T08:30:00.123Z") != nil)
        #expect(ImportKeyClient.date("yesterday") == nil)
    }

    @Test("POST makes a key and hands it back once")
    func create() async throws {
        var seen: URLRequest?
        let made = try await ImportKeyClient.create(Self.connection, token: "tok") { request in
            seen = request
            return try await Self.answer(200, #"{"key":"ik_abcdefghijklmnopqrstuvwxyz012345","createdAt":"2026-09-28T10:00:00Z"}"#)(request)
        }
        try Self.expectShape(seen, "POST")
        #expect(made.key == "ik_abcdefghijklmnopqrstuvwxyz012345")
        #expect(made.createdAt != nil)
    }

    @Test("DELETE removes it")
    func remove() async throws {
        var seen: URLRequest?
        try await ImportKeyClient.remove(Self.connection, token: "tok") { request in
            seen = request
            return try await Self.answer(200, #"{"ok":true}"#)(request)
        }
        try Self.expectShape(seen, "DELETE")
    }

    @Test("a POST answer with no key is refused rather than shown as blank")
    func malformed() async {
        await #expect(throws: ImportKeyClient.Failure.malformed) {
            _ = try await ImportKeyClient.create(Self.connection, token: "tok",
                                                 fetch: Self.answer(200, #"{"createdAt":"x"}"#))
        }
    }

    @Test("plain http is refused before the token goes anywhere")
    func httpsOnly() async {
        let plain = CloudReader.Connection(url: "http://cloud.khaytapp.com", shopId: "s", storedToken: "")
        var called = false
        await #expect(throws: (any Error).self) {
            _ = try await ImportKeyClient.status(plain, token: "tok") { request in
                called = true
                return try await Self.answer(200, "{}")(request)
            }
        }
        #expect(!called)
    }

    // MARK: - Refusals

    @Test("a 403 says the sign-in is not the owner or a manager")
    func forbidden() async throws {
        do {
            _ = try await ImportKeyClient.create(Self.connection, token: "tok",
                                                 fetch: Self.answer(403, #"{"error":"Only the owner or a manager can manage the import key"}"#))
            Issue.record("a 403 was taken as success")
        } catch {
            #expect(error as? ImportKeyClient.Failure == .notManager)
            let en = ImportKeyClient.said(error, words: Words())
            #expect(en.contains("owner") && en.contains("manager"), Comment(rawValue: en))
            let ar = Words()
            await ar.load("ar", engine: try KhaytEngine())
            let said = ImportKeyClient.said(error, words: ar)
            #expect(said.contains("مالك") && said.contains("مدير"), Comment(rawValue: said))
        }
    }

    @Test("other refusals map to their own words")
    func otherRefusals() async {
        for (code, want) in [(401, ImportKeyClient.Failure.unauthorised),
                             (404, .notOffered)] {
            await #expect(throws: want) {
                _ = try await ImportKeyClient.status(Self.connection, token: "tok",
                                                     fetch: Self.answer(code, "{}"))
            }
        }
        let words = Words()
        #expect(ImportKeyClient.said(ImportKeyClient.Failure.http(500, ""), words: words).contains("500"))
    }

    // MARK: - The key is never kept

    static func source(_ file: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        return try String(contentsOf: dir.appending(path: file), encoding: .utf8)
    }

    @Test("nothing in the import-key code writes anywhere")
    func neverStored() throws {
        // The shop keeps the key in Medusa's environment and the server keeps
        // only its hash. This app shows it once from view state; a way to save
        // it would be a second copy of a secret nobody asked to keep.
        let file = try Self.source("ImportKey.swift")
        for writer in ["StoreWriter", "updateRecord", "saveSettings", "Secrets.seal", "UserDefaults",
                       "@AppStorage", "SecItemAdd", "Keychain", ".write(to", "FileManager",
                       "print(", "NSLog", "Logger(", "os_log"] {
            #expect(!file.contains(writer), Comment(rawValue: "ImportKey.swift mentions \(writer)"))
        }
        // The fresh key lives in @State and is dropped when the pane goes.
        #expect(file.contains("@State private var fresh: ImportKeyClient.Created?"))
        #expect(file.contains(".onDisappear { fresh = nil"))
    }

    @Test("the pane shows the row, and every word it uses exists in both languages")
    func wiredAndWorded() throws {
        #expect(try Self.source("Integrations.swift").contains("ImportKeySection(shop: shop)"))
        let file = try Self.source("ImportKey.swift")
        let keys = Set(file.matches(of: /"(mac\.ik_[a-z_]+)"/).map { String($0.1) })
        #expect(keys.count >= 15, Comment(rawValue: "\(keys.sorted())"))
        for key in keys {
            #expect(Words.own[key]?["en"]?.isEmpty == false, Comment(rawValue: "\(key) en"))
            #expect(Words.own[key]?["ar"]?.isEmpty == false, Comment(rawValue: "\(key) ar"))
        }
    }
}
