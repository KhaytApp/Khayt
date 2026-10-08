import Foundation
import Testing
@testable import KhaytCore

/// `PinHash` against `lib/pin-hash.js`, over vectors the JavaScript wrote.
///
/// The module needs `node:crypto`, so it cannot be bound into the engine and
/// compared live the way most shared rules are. `Fixtures/pin-hash-vectors.json`
/// was produced by running the module itself; regenerate it the same way if the
/// format ever changes (the generator is in the PR that added this file). Each
/// vector carries the module's own answers — verify, managed, needs-upgrade —
/// so a disagreement names which one.
struct PinHashTests {

    struct Vector: Decodable {
        let pin: String
        let stored: String
        let ok: Bool
        let managed: Bool
        let upgrade: Bool
    }

    static func vectors() throws -> [Vector] {
        struct File: Decodable { let vectors: [Vector] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/pin-hash-vectors.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).vectors
    }

    @Test("every vector the JavaScript wrote, answered the same way")
    func parity() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count > 40, "the fixture is the evidence; it went missing")
        #expect(vectors.contains { $0.ok && $0.stored.hasPrefix("p2$200000$") },
                "no vector at the production iteration count")
        #expect(vectors.contains { $0.ok && PinHash.isLegacySha256($0.stored) })
        for v in vectors {
            // The label never carries the PIN or the hash — only its shape.
            let label = Comment(rawValue: "\(v.stored.prefix(3))… pin length \(v.pin.count)")
            #expect(PinHash.verify(v.pin, v.stored) == v.ok, label)
            #expect(PinHash.isManaged(v.stored) == v.managed, label)
            #expect(PinHash.needsUpgrade(v.stored) == v.upgrade, label)
        }
    }

    @Test("a hash written here verifies here, and has the module's shape")
    func roundTrip() throws {
        let h = try #require(PinHash.hash("8642", iterations: 1_000))
        #expect(PinHash.isPbkdf2(h))
        let parts = h.split(separator: "$")
        #expect(parts[1] == "1000")
        #expect(parts[2].count == 32, "a 16-byte salt")
        #expect(parts[3].count == 64, "a 32-byte key")
        #expect(PinHash.verify("8642", h))
        #expect(!PinHash.verify("8643", h))
        // Salted: the same PIN twice is two different hashes.
        #expect(PinHash.hash("8642", iterations: 1_000) != h)
        // The default is the module's production count.
        #expect(try #require(PinHash.hash("1")).hasPrefix("p2$200000$"))
    }

    @Test("a stored hash cannot ask for an hour of CPU")
    func iterationCap() {
        let absurd = "p2$4000000000$00112233445566778899aabbccddeeff$" + String(repeating: "ab", count: 32)
        let started = Date()
        #expect(!PinHash.verify("1234", absurd))
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("the sync mask and garbage are never a PIN")
    func neverAPin() {
        for stored in ["__KHAYT_MASKED__", "", "****", "MTIzNA=="] {
            #expect(!PinHash.verify("", stored))
            #expect(!PinHash.verify("1234", stored))
            #expect(!PinHash.isManaged(stored))
        }
    }
}
