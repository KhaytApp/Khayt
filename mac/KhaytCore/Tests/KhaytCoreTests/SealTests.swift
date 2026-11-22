import Foundation
import Testing
@testable import KhaytCore

/// Sealing a payload the rest of Khayt can open.
///
/// Reading is easy to test against yourself and easy to get wrong in a way that
/// only shows up on somebody else's machine: an inflater that ignores a
/// malformed container will happily read a writer that produces one. So the
/// pin here is **Node**, running the shop's own `lib/sync-crypto.js` — the exact
/// code every desktop copy of Khayt will use to open what this app sends. If
/// that cannot read it, nothing else about it matters.
struct SealTests {

    static let dek = Data((0..<32).map { UInt8($0) })

    /// Run a script under this repo's Node, with the repo as the working
    /// directory so `require('./lib/…')` resolves.
    ///
    /// Node is not optional and this does not skip when it is missing: a test
    /// that quietly passes because it did nothing is worse than no test, and
    /// `npm test` already makes Node a hard requirement of this repository.
    static func node(_ script: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["node", "-e", script]
        task.currentDirectoryURL = repo
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        try task.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let problem = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            Issue.record("node failed: \(problem)")
            return ""
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("Node's zlib reads what this gzips")
    func nodeReadsOurGzip() throws {
        // Text, because it must actually compress; and long enough to be more
        // than one stored block's worth of nothing.
        let plain = String(repeating: "the shop sells printed things. ", count: 400)
        let packed = try SyncCrypto.gzip(Data(plain.utf8))
        #expect(packed.count < plain.utf8.count / 2, "it did not compress")
        let read = try Self.node("""
            const zlib = require('node:zlib');
            const b = Buffer.from('\(packed.base64EncodedString())', 'base64');
            process.stdout.write(zlib.gunzipSync(b).toString('utf8').length.toString());
            """)
        #expect(read == String(plain.utf8.count))
    }

    @Test("empty input still makes a gzip stream Node can read")
    func emptyGzip() throws {
        let packed = try SyncCrypto.gzip(Data())
        let read = try Self.node("""
            const zlib = require('node:zlib');
            const b = Buffer.from('\(packed.base64EncodedString())', 'base64');
            process.stdout.write(String(zlib.gunzipSync(b).length));
            """)
        #expect(read == "0")
    }

    /// Incompressible bytes come out BIGGER. A destination buffer sized at the
    /// input length is not tight, it is wrong, and this is the case that finds it.
    @Test("bytes that do not compress are still sealed correctly")
    func incompressible() throws {
        var random = Data(count: 4096)
        random.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 4096, $0.baseAddress!) }
        let packed = try SyncCrypto.gzip(random)
        #expect(try SyncCrypto.gunzip(packed) == random)
    }

    @Test("what this seals, lib/sync-crypto.js opens")
    func nodeOpensOurBlob() throws {
        let payload: [String: JSONValue] = [
            "deltas": .array([.object([
                "collection": .string("orders"),
                "record": .object(["id": .string("o1"), "rev": .number(7),
                                   "title": .string("عميل جديد")]),
            ])]),
            "tombstones": .array([]),
            "cursor": .object(["rev": .number(0), "ts": .string("")]),
        ]
        let blob = try SyncCrypto.seal(payload, dek: Self.dek)
        #expect(blob.z == "gzip")
        #expect(blob.v == 1)

        let wire = String(decoding: try JSONEncoder().encode(blob), as: UTF8.self)
        let read = try Self.node("""
            const sc = require('./lib/sync-crypto.js');
            const dek = Buffer.from('\(Self.dek.base64EncodedString())', 'base64');
            const store = sc.decryptStore(JSON.parse(process.env.BLOB), dek);
            process.stdout.write(store.deltas[0].record.title + '|' + store.deltas[0].record.rev);
            """.replacingOccurrences(of: "process.env.BLOB", with: "`" + wire + "`"))
        // Arabic through JSON, gzip, GCM, base64 and back out the other side.
        #expect(read == "عميل جديد|7")
    }

    @Test("a blob sealed here opens here")
    func roundTrip() throws {
        let payload: [String: JSONValue] = ["deltas": .array([]), "tombstones": .array([])]
        let blob = try SyncCrypto.seal(payload, dek: Self.dek)
        #expect(try SyncCrypto.store(blob, dek: Self.dek) == payload)
    }

    @Test("the wrong key does not open it")
    func wrongKey() throws {
        let blob = try SyncCrypto.seal(["a": .number(1)], dek: Self.dek)
        #expect(throws: SyncCrypto.Failure.self) {
            _ = try SyncCrypto.store(blob, dek: Data(repeating: 9, count: 32))
        }
    }

    /// Two seals of the same payload must not produce the same nonce. A repeated
    /// nonce under one key is not a small mistake; it hands over the keystream.
    @Test("every seal gets its own nonce")
    func freshNonce() throws {
        let a = try SyncCrypto.seal(["a": .number(1)], dek: Self.dek)
        let b = try SyncCrypto.seal(["a": .number(1)], dek: Self.dek)
        #expect(a.iv != b.iv)
        #expect(a.ct != b.ct)
    }
}
