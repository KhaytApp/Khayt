import CryptoKit
import XCTest
@testable import KhaytCompanion

/// The phone's half of `/api/identity` and `/api/proof`: what counts as the
/// Mac proving itself, and when the pinned key is let go.
@MainActor
final class MacIdentityTests: XCTestCase {
    private let mac = Curve25519.Signing.PrivateKey()
    private var pinned: String { mac.publicKey.rawRepresentation.base64EncodedString() }

    /// What the Mac sends back for `nonce`, signed with `key`.
    private func sign(_ nonce: String, with key: Curve25519.Signing.PrivateKey) throws -> String {
        try key.signature(for: Data(("khayt-proof:" + nonce.lowercased()).utf8)).base64EncodedString()
    }

    func testTheNonceIsThirtyTwoLowercaseHexDigitsAndFresh() {
        let a = MacIdentity.nonce(), b = MacIdentity.nonce()
        XCTAssertEqual(a.count, 32)
        XCTAssertTrue(a.allSatisfy { "0123456789abcdef".contains($0) }, "the Mac accepts 32–128 hex digits")
        XCTAssertNotEqual(a, b)
    }

    func testTheMacsSignatureProvesIt() throws {
        let nonce = MacIdentity.nonce()
        XCTAssertTrue(MacIdentity.verify(signature: try sign(nonce, with: mac), alg: "ed25519", nonce: nonce, key: pinned))
    }

    func testTheMessageIsTheLowercasedNonce() throws {
        let nonce = "ABCDEF0123456789ABCDEF0123456789"
        let sig = try sign(nonce.lowercased(), with: mac)
        XCTAssertTrue(MacIdentity.verify(signature: sig, alg: "ed25519", nonce: nonce, key: pinned),
                      "the Mac and the desktop both lowercase before signing")
    }

    func testAnotherKeyDoesNotProveIt() throws {
        let nonce = MacIdentity.nonce()
        let impostor = Curve25519.Signing.PrivateKey()
        XCTAssertFalse(MacIdentity.verify(signature: try sign(nonce, with: impostor), alg: "ed25519", nonce: nonce, key: pinned))
    }

    func testASignatureOverAnotherNonceDoesNotProveIt() throws {
        let replayed = try sign(MacIdentity.nonce(), with: mac)
        XCTAssertFalse(MacIdentity.verify(signature: replayed, alg: "ed25519", nonce: MacIdentity.nonce(), key: pinned),
                       "a recorded answer must not work twice")
    }

    func testAnythingMalformedIsNotProof() throws {
        let nonce = MacIdentity.nonce()
        let sig = try sign(nonce, with: mac)
        XCTAssertFalse(MacIdentity.verify(signature: sig, alg: "hmac-sha256", nonce: nonce, key: pinned))
        XCTAssertFalse(MacIdentity.verify(signature: sig, alg: nil, nonce: nonce, key: pinned))
        XCTAssertFalse(MacIdentity.verify(signature: "not base64!", alg: "ed25519", nonce: nonce, key: pinned))
        XCTAssertFalse(MacIdentity.verify(signature: sig, alg: "ed25519", nonce: nonce, key: ""))
        XCTAssertNil(MacIdentity.publicKey(Data(repeating: 1, count: 31).base64EncodedString()), "a key is 32 bytes")
        XCTAssertNotNil(MacIdentity.publicKey(pinned))
    }

    // MARK: - When the pinned key is let go

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: ConnectionSettings.Keys.macIdentity)
    }
    override func tearDown() { setUp() }

    func testANewPinDropsThePinnedKey() {
        let s = ConnectionSettings()
        let oldPin = s.pin
        s.macIdentityKey = pinned
        s.pin = oldPin
        XCTAssertEqual(s.macIdentityKey, pinned, "the same PIN typed again is the same Mac")
        s.pin = oldPin + "9"
        XCTAssertEqual(s.macIdentityKey, "", "a new PIN may be a new Mac")
        s.pin = oldPin
    }

    func testThePinnedKeyIsKeptAcrossLaunches() {
        let s = ConnectionSettings()
        s.macIdentityKey = pinned
        XCTAssertEqual(ConnectionSettings().macIdentityKey, pinned)
    }
}
