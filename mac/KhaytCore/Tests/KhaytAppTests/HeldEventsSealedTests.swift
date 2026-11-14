import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Held shop alerts survive a quit, sealed (`Shop+HeldEvents.swift`).
///
/// NOTHING HERE MAY TOUCH THE LOGIN KEYCHAIN: the key is the suite's own,
/// through `Secrets.keySource` / `keyMaker`, as `SecretsTests` does it.
/// Serialized for the same reason: `Secrets` keeps its seams in statics.
@MainActor
@Suite(.serialized)
struct HeldEventsSealedTests {

    nonisolated static let key = SafeStorage.key(fromPassword: "a test password, not a shop's")

    init() {
        Secrets.forget()
        Secrets.keySource = { _ in Self.key }
        Secrets.keyMaker = { _ in Self.key }
    }

    static func event(_ n: Int, since: Date) -> Shop.PendingEvent {
        .init(kind: "print-finished", at: "2026-11-14T10:0\(n):00Z",
              payload: ["client": .string("Customer \(n)"), "project": .string("Bracket \(n)")],
              since: since, id: String(repeating: "\(n)", count: 32))
    }

    @Test("sealed, opened, and never in the clear")
    func roundTrip() async throws {
        let held = Shop.HeldEvents(book: "/tmp/book.json", events: [.init(Self.event(1, since: Date()))])
        let sealed = try #require(await Shop.sealHeld(held, build: .development))
        #expect(sealed.hasPrefix(SafeStorage.marker))
        #expect(!sealed.contains("Customer 1") && !sealed.contains("Bracket 1"))
        #expect(await Shop.openHeld(sealed, build: .development) == held)
        // A value nobody sealed is not read.
        let plain = String(decoding: try JSONEncoder().encode(held), as: UTF8.self)
        #expect(await Shop.openHeld(plain, build: .development) == nil)
    }

    @Test("no key: nothing is sealed, so nothing is written")
    func noKey() async {
        Secrets.forget()
        Secrets.keySource = { _ in nil }
        Secrets.keyMaker = { _ in nil }
        let held = Shop.HeldEvents(book: "/tmp/book.json", events: [.init(Self.event(1, since: Date()))])
        #expect(await Shop.sealHeld(held, build: .development) == nil)
    }

    @Test("the sample book, and a test runner's default, keep nothing")
    func nothingKept() async {
        let shop = Shop()
        await shop.load(.sample)
        #expect(Bundle.main.bundleIdentifier != nil || shop.heldEventsDefaults == nil)
        let defaults = UserDefaults(suiteName: "held-\(UUID().uuidString)")!
        shop.heldEventsDefaults = defaults
        shop.queueEvent(Self.event(1, since: Date()))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(defaults.dictionary(forKey: Shop.heldEventsKey) == nil, "the sample has no build")
    }
}
