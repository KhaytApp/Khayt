import Foundation
import Testing
@testable import KhaytCore

/// scrypt, against numbers this code did not produce.
///
/// The only thing that matters about `Scrypt.swift` is that it agrees with
/// Node, because Khayt's keyset was wrapped by `crypto.scryptSync`. A KEK one
/// byte different does not fail loudly — it produces a GCM authentication error
/// at the far end of the unwrap, which reads as "wrong passphrase". A shop
/// would be told its own password was wrong, for ever.
///
/// So the vectors come from two places that are not this implementation: RFC
/// 7914 §11, and Node's own `scryptSync` run on this machine.
struct ScryptTests {

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    // MARK: - RFC 7914 §11

    @Test("RFC 7914: the empty vector")
    func rfcEmpty() throws {
        let out = try Scrypt.key(password: Data(), salt: Data(), n: 16, r: 1, p: 1, length: 64)
        #expect(Self.hex(out) == "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442"
                               + "fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906")
    }

    @Test("RFC 7914: p greater than one")
    func rfcMultipleBlocks() throws {
        // p=16 is the only vector that exercises mixing more than one block,
        // and Khayt's own keysets use p=1 — so without this the loop over `p`
        // would never run twice anywhere.
        let out = try Scrypt.key(password: Data("password".utf8), salt: Data("NaCl".utf8),
                                 n: 1024, r: 8, p: 16, length: 64)
        #expect(Self.hex(out) == "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b373162"
                               + "2eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640")
    }

    @Test("RFC 7914: the large-N vector")
    func rfcLargeN() throws {
        let out = try Scrypt.key(password: Data("pleaseletmein".utf8),
                                 salt: Data("SodiumChloride".utf8),
                                 n: 16384, r: 8, p: 1, length: 64)
        #expect(Self.hex(out) == "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2"
                               + "d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887")
    }

    // MARK: - Khayt's own parameters

    @Test("Khayt's keyset parameters, against Node on this machine")
    func khaytDefaults() throws {
        // N=32768, r=8, p=1, 32 bytes — `DEFAULT_KDF` in lib/sync-crypto.js, and
        // the numbers in this shop's own `settings.cloud.keyset.kdf`. Produced
        // by `crypto.scryptSync` and pasted here; nothing in Swift computed it.
        let salt = Data([0x01, 0x02, 0x03]) + Data("saltysalt".utf8)
        let out = try Scrypt.kek(secret: "a shop passphrase", salt: salt)
        #expect(Self.hex(out) == "88e87b826342cd66695980c7409ee965a2b590bf45bbce18e44414dbac176c23")
        #expect(out.count == 32)
    }

    @Test("the default parameters are the ones the keyset asks for")
    func defaultsMatchTheKeyset() throws {
        // A mismatch here is the failure that reads as a wrong passphrase.
        let explicit = try Scrypt.key(password: Data("x".utf8), salt: Data("y".utf8),
                                      n: 32768, r: 8, p: 1, length: 32)
        let byDefault = try Scrypt.kek(secret: "x", salt: Data("y".utf8))
        #expect(explicit == byDefault)
    }

    // MARK: - What it refuses

    @Test("N must be a power of two")
    func refusesBadN() {
        // Not pedantry: `j = x[…] & (N - 1)` is only a modulo when N is one, and
        // a silently wrong index would give a plausible-looking wrong key.
        for n in [0, 1, 3, 1000] {
            #expect(throws: Scrypt.Failure.self) {
                try Scrypt.key(password: Data(), salt: Data(), n: n, r: 1, p: 1, length: 32)
            }
        }
    }

    @Test("zero-length everything is refused rather than guessed at")
    func refusesZeroes() {
        #expect(throws: Scrypt.Failure.self) {
            try Scrypt.key(password: Data(), salt: Data(), n: 16, r: 0, p: 1, length: 32)
        }
        #expect(throws: Scrypt.Failure.self) {
            try Scrypt.key(password: Data(), salt: Data(), n: 16, r: 1, p: 0, length: 32)
        }
        #expect(throws: Scrypt.Failure.self) {
            try Scrypt.key(password: Data(), salt: Data(), n: 16, r: 1, p: 1, length: 0)
        }
    }

    @Test("a different passphrase is a different key")
    func differentSecrets() throws {
        let salt = Data("saltysalt".utf8)
        let a = try Scrypt.kek(secret: "one", salt: salt, n: 16, r: 1, p: 1)
        let b = try Scrypt.kek(secret: "two", salt: salt, n: 16, r: 1, p: 1)
        #expect(a != b)
    }
}
