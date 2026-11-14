import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Held shop alerts survive a quit, sealed (`Shop+HeldEvents.swift`).
///
/// NOTHING HERE MAY TOUCH THE LOGIN KEYCHAIN, nor `Secrets`' shared key
/// source (SecretsTests swaps it while this runs): the seal is the suite's
/// own `Sealer`, over `SafeStorage` with a test key.
@MainActor
struct HeldEventsSealedTests {

    nonisolated static let key = SafeStorage.key(fromPassword: "a test password, not a shop's")
    static let sealer = Shop.Sealer(seal: { try SafeStorage.seal($0, key: key) },
                                    open: { try SafeStorage.open($0, key: key) })

    static func event(_ n: Int, since: Date) -> Shop.PendingEvent {
        .init(kind: "print-finished", at: "2026-11-14T10:0\(n):00Z",
              payload: ["client": .string("Customer \(n)"), "project": .string("Bracket \(n)")],
              since: since, id: String(repeating: "\(n)", count: 32))
    }

    @Test("sealed, opened, and never in the clear")
    func roundTrip() async throws {
        let held = Shop.HeldEvents(book: "/tmp/book.json", events: [.init(Self.event(1, since: Date()))])
        let sealed = try #require(await Shop.sealHeld(held, with: Self.sealer))
        #expect(sealed.hasPrefix(SafeStorage.marker))
        #expect(!sealed.contains("Customer 1") && !sealed.contains("Bracket 1"))
        #expect(await Shop.openHeld(sealed, with: Self.sealer) == held)
        // A value nobody sealed is not read.
        let plain = String(decoding: try JSONEncoder().encode(held), as: UTF8.self)
        #expect(await Shop.openHeld(plain, with: Self.sealer) == nil)
    }

    @Test("no key, or a seal that hands back plaintext: nothing is written")
    func noKey() async {
        let held = Shop.HeldEvents(book: "/tmp/book.json", events: [.init(Self.event(1, since: Date()))])
        let locked = Shop.Sealer(seal: { _ in throw Secrets.Failure.noKeychain }, open: { $0 })
        #expect(await Shop.sealHeld(held, with: locked) == nil)
        let leaky = Shop.Sealer(seal: { $0 }, open: { $0 })
        #expect(await Shop.sealHeld(held, with: leaky) == nil, "never stored in the clear")
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
