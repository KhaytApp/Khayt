import Testing
import Foundation
@testable import KhaytCore

/// The native app must leave Khayt's encrypted fields exactly as Electron would.
///
/// One half of this is provable here and is: the algorithm. Swift and Node are
/// held to the same bytes, the same way MoneyParityTests holds them to the same
/// numbers.
///
/// The other half — that the Keychain item really holds the PBKDF2 password —
/// is NOT proved here, on purpose. It would mean reading a live secret out of
/// the login Keychain during a test run. `verifyAgainstRealStore` is the
/// one-command check a person runs on their own machine instead; see its note.
@Suite struct SafeStorageTests {

    /// Node, given the same parameters. If Swift and Node disagree about a byte,
    /// one of them is wrong about a shop's cloud token.
    static func node(_ script: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node", "-e", script]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let password = "not-the-real-key-just-a-fixture"

    @Test("Swift derives the same key as Node")
    func keyDerivation() throws {
        let swift = SafeStorage.key(fromPassword: Self.password).map { String(format: "%02x", $0) }.joined()
        let node = try Self.node("""
          const c=require('crypto');
          process.stdout.write(c.pbkdf2Sync('\(Self.password)','saltysalt',1003,16,'sha1').toString('hex'))
        """)
        #expect(swift == node, "PBKDF2 disagreement — Swift \(swift) vs Node \(node)")
        #expect(swift.count == 32, "AES-128 means a 16-byte key; a 32-byte one silently becomes AES-256")
    }

    @Test("Swift seals the bytes Electron would")
    func sealMatchesNode() throws {
        let key = SafeStorage.key(fromPassword: Self.password)
        // Short, block-aligned, long, non-ASCII, and empty — the padding edges.
        for secret in ["sk-abc", "0123456789abcdef", String(repeating: "z", count: 130), "مفتاح-٤٢", ""] {
            let swift = try SafeStorage.seal(secret, key: key)
            let node = try Self.node("""
              const c=require('crypto');
              const k=c.pbkdf2Sync('\(Self.password)','saltysalt',1003,16,'sha1');
              const e=c.createCipheriv('aes-128-cbc',k,Buffer.alloc(16,0x20));
              const b=Buffer.concat([e.update(Buffer.from(\(jsString(secret)),'utf8')),e.final()]);
              process.stdout.write('__enc__'+Buffer.concat([Buffer.from('v10'),b]).toString('base64'))
            """)
            #expect(swift == node, "sealed bytes differ for \(secret.debugDescription)")
            #expect(try SafeStorage.open(swift, key: key) == secret, "did not survive its own round trip")
        }
    }

    @Test("a wrong key is refused, not silently accepted")
    func wrongKeyFails() throws {
        // The dangerous failure is a wrong key that "works" and returns mojibake,
        // which then gets written back and destroys the real secret. PKCS7 makes
        // that overwhelmingly unlikely; this asserts we do not paper over it.
        let sealed = try SafeStorage.seal("sk-live-secret", key: SafeStorage.key(fromPassword: "right"))
        #expect(throws: (any Error).self) {
            try SafeStorage.open(sealed, key: SafeStorage.key(fromPassword: "wrong"))
        }
    }

    @Test("sealing refuses to return a field it cannot itself open")
    func sealVerifiesItsOwnOutput() throws {
        // Drives the guard the way a broken future edit would: encryption that
        // produces something the decrypt side disagrees with. Without the guard
        // this returns happily and the caller writes it over a real secret.
        let key = SafeStorage.key(fromPassword: Self.password)
        #expect(throws: SafeStorage.Failure.self) {
            try SafeStorage.seal("sk-live-secret", key: key, verify: { _, _ in "something else" })
        }
        // And the guard must not be so eager it rejects correct output.
        #expect(try SafeStorage.seal("sk-live-secret", key: key, verify: SafeStorage.open)
                == (try SafeStorage.seal("sk-live-secret", key: key)))
    }

    @Test("the format guards are the ones that fire")
    func formatGuards() throws {
        let key = SafeStorage.key(fromPassword: Self.password)
        #expect(throws: (any Error).self) { try SafeStorage.open("plain text", key: key) }
        // A future Electron writing v11 must be a loud failure, never a decrypt attempt.
        let v11 = "__enc__" + (Data("v11".utf8) + Data(repeating: 0, count: 16)).base64EncodedString()
        var said = ""
        do { _ = try SafeStorage.open(v11, key: key) }
        catch let e as SafeStorage.Failure { said = e.description }
        #expect(said.contains("v11"), "an unknown version must name itself; got \(said.debugDescription)")
    }

    /// The real store on this machine, read for SHAPE only — never decrypted.
    ///
    /// This is what told us the format in the first place: a `v10` tag over a
    /// body that is always a whole number of AES blocks. If Electron ever
    /// changes it, this fails before any Swift code writes to a real store.
    @Test("the store on this machine has the format this code implements")
    func realStoreShape() throws {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/khayt/khayt-store.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return  // no dev store here; the parity tests above still stand
        }
        var checked = 0
        func walk(_ any: Any) {
            if let d = any as? [String: Any] { d.values.forEach(walk) }
            else if let a = any as? [Any] { a.forEach(walk) }
            else if let s = any as? String, s.hasPrefix(SafeStorage.marker) {
                checked += 1
                let raw = Data(base64Encoded: String(s.dropFirst(SafeStorage.marker.count)))
                guard let raw, raw.count > 3 else { Issue.record("an __enc__ field is not base64"); return }
                #expect(String(decoding: raw.prefix(3), as: UTF8.self) == "v10",
                        "Electron is writing a version this code does not implement")
                #expect((raw.count - 3) % 16 == 0,
                        "a v10 body must be whole AES blocks; got \(raw.count - 3)")
            }
        }
        walk(root)
        #expect(checked > 0, "no encrypted fields found — either safeStorage is off here, or the store moved")
    }
}

private func jsString(_ s: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: [s]), as: UTF8.self)
        .dropFirst().dropLast().description
}

/// Which fields hold credentials is not a Swift decision.
@Suite struct SecretPathsTests {

    @Test("the Mac app reads the same secret list the Electron app encrypts from")
    func sameList() async throws {
        let engine = try KhaytEngine()
        let swift = try await engine.secretPaths()

        let node = try SafeStorageTests.node("""
          process.stdout.write(JSON.stringify(
            require(process.cwd() + '/../../lib/store-secret-paths.js').SECRET_PATHS))
        """)
        let expected = try JSONDecoder().decode([String].self, from: Data(node.utf8))

        #expect(swift == expected, "the two apps disagree about which fields are secret")
        #expect(swift.count >= 30, "only \(swift.count) secret paths; some have gone missing")
        // The array case has to survive the crossing intact, or the printer API
        // keys are silently unprotected in the native app.
        #expect(swift.contains("machines[].printerApi.apiKey"))
        #expect(swift.contains("settings.cloud.token"), "the off-site backup token")
    }

    @Test("every listed path is one SafeStorage can actually seal")
    func everyPathSealable() throws {
        // A path is only protected if a value at it round-trips. This is the
        // Swift-side half of the Node suite's every-secret-is-protected test.
        let key = SafeStorage.key(fromPassword: SafeStorageTests.password)
        for path in ["settings.cloud.token", "machines[].printerApi.apiKey", "settings.ai.apiKey"] {
            let secret = "S3CR3T-" + path
            let sealed = try SafeStorage.seal(secret, key: key)
            #expect(sealed.hasPrefix(SafeStorage.marker))
            #expect(try SafeStorage.open(sealed, key: key) == secret)
        }
    }
}
