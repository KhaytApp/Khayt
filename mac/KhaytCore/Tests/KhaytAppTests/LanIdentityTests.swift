import Foundation
import Testing
import CryptoKit
@testable import KhaytApp

/// A phone can tell this Mac from a device that took its Bonjour name,
/// without the PIN ever leaving the phone first.
@MainActor
struct LanIdentityTests {

    @Test("a proof is the key's signature over prefix + nonce, and says nothing else")
    func proofVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let nonce = String(repeating: "ab", count: 16)
        let sig = try #require(LanIdentity.proof(nonce: nonce, key: key))
        let raw = try #require(Data(base64Encoded: sig))
        #expect(key.publicKey.isValidSignature(raw, for: Data(("khayt-proof:" + nonce).utf8)))
        let other = Curve25519.Signing.PrivateKey()
        #expect(!other.publicKey.isValidSignature(raw, for: Data(("khayt-proof:" + nonce).utf8)),
                "a device with another key cannot pass")
    }

    @Test("only a hex nonce of 32 to 128 digits is signed")
    func nonces() {
        let key = Curve25519.Signing.PrivateKey()
        #expect(LanIdentity.proof(nonce: "short", key: key) == nil)
        #expect(LanIdentity.proof(nonce: String(repeating: "z", count: 32), key: key) == nil)
        #expect(LanIdentity.proof(nonce: String(repeating: "a", count: 129), key: key) == nil)
        #expect(LanIdentity.proof(nonce: String(repeating: "0", count: 32), key: key) != nil)
    }

    @Test("the routes: identity behind the PIN, proof open, both from the same key")
    func routes() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let bench = try await LanServerTests.Bench(identity: key)
        defer { bench.stop() }

        let refused = try await bench.get("/api/identity")
        #expect(refused.status == 401 || refused.status == 403, "the public key needs the PIN")

        let id = try await bench.get("/api/identity", headers: ["x-khayt-pin": "24682468"])
        #expect(id.status == 200)
        let idBody = try JSONSerialization.jsonObject(with: id.body) as? [String: String]
        #expect(idBody?["publicKey"] == key.publicKey.rawRepresentation.base64EncodedString())

        let nonce = String(repeating: "c3", count: 16)
        let proof = try await bench.get("/api/proof?nonce=\(nonce)")
        #expect(proof.status == 200)
        let body = try JSONSerialization.jsonObject(with: proof.body) as? [String: String]
        let raw = try #require(body?["sig"].flatMap { Data(base64Encoded: $0) })
        #expect(key.publicKey.isValidSignature(raw, for: Data(("khayt-proof:" + nonce).utf8)))

        #expect(try await bench.get("/api/proof?nonce=xyz").status == 400)
        #expect(try await bench.get("/api/proof").status == 400)
    }
}
