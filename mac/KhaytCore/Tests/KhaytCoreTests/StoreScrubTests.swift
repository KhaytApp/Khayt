import Foundation
import Testing
@testable import KhaytCore

/// SECURITY: the shop's webhook signing secret is never copied onto a
/// subscription, and a book that already carries such a copy loses it — on
/// every write, and from everything a phone or the cloud is sent.
struct StoreScrubTests {

    static func book() -> [String: JSONValue] {
        ["settings": .object(["webhooks": .object([
            "secret": .string("__enc__SEALED"),
            "subscriptions": .array([
                .object(["id": .string("a"), "url": .string("https://a.example/h"), "secret": .string("REAL")]),
                .object(["id": .string("b"), "url": .string("https://b.example/h")]),
            ]),
        ])])]
    }

    static func text(_ v: [String: JSONValue]) throws -> String {
        String(decoding: try JSONValue.encode(.object(v)), as: UTF8.self)
    }

    @Test("the Swift drop list is the JavaScript one")
    func sameList() async throws {
        let engine = try KhaytEngine()
        let js = try await engine.dropPaths()
        #expect(js == StoreScrub.dropPaths)
    }

    @Test("a book that carries a copy loses it on the next write, and the real secret stays")
    func scrubbedOnWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "scrub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "khayt-store.json")
        try JSONValue.encode(.object(Self.book())).write(to: url)
        try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            root["touched"] = .bool(true)
        }
        let after = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(!after.contains("REAL"))
        #expect(after.contains("__enc__SEALED"))
    }

    @Test("what /api/store hands a phone, and the cloud is sent, never carries it")
    func neverServed() async throws {
        let engine = try KhaytEngine()
        #expect(!(try Self.text(try await engine.storeForPhone(Self.book()))).contains("REAL"))
        #expect(!(try Self.text(try await engine.storeForCloud(Self.book()))).contains("REAL"))
    }

    @Test("a migrated subscription has no secret and signs with the shared one, as before")
    func migratedSignsTheSame() async throws {
        let engine = try KhaytEngine()
        let legacy: JSONValue = .object(["enabled": .bool(true), "secret": .string("shared"),
                                         "events": .object(["status_changed": .string("https://a.example/h")])])
        let subs = try await engine.webhookSubscriptions(legacy, event: "status_changed")
        #expect(subs.count == 1)
        #expect(subs[0].secret == nil)
        let owed = try await engine.webhookDeliveries(
            order: .object(["id": .string("J1")]),
            effects: [.init(kind: "webhook", event: "status_changed", newStatus: "completed")],
            settings: ["webhooks": legacy], shopName: "Acme", clientName: "", currency: "SAR",
            at: "2026-11-05T10:00:00.000Z", nowMs: 1_800_000_000_000)
        #expect(owed.first?.secret == "shared", "the signature is over the same secret it always was")
    }
}
