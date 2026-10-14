import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Reading a store and writing it back must change nothing but the edit.
///
/// The Mac app's write path never decrypts: the secrets on disk are already
/// `__enc__` strings, so a record edit carries them through untouched and
/// SafeStorage is never involved. What that buys in safety it spends on a
/// different risk — the WHOLE store goes through a JSON decode and encode, and
/// if that alters so much as a number's spelling, every record's fingerprint
/// moves. `stampChanges` would then see the entire book as edited, bump every
/// `rev`, and push the lot to the cloud as changes nobody made.
///
/// So this checks the round trip on a real store rather than a fixture.
struct StoreRoundTripTests {

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// A store to test against: this Mac's, if there is one, else the sample.
    static func source() throws -> (name: String, data: Data) {
        for build in StoreReader.Build.allCases where build.exists {
            return (build.rawValue, try Data(contentsOf: build.storeURL))
        }
        let url = Bundle.module.url(forResource: "sample-shop", withExtension: "json")!
        return ("sample", try Data(contentsOf: url))
    }

    @Test("a store decoded and re-encoded is the same store, value for value")
    func valuesSurvive() throws {
        let (name, data) = try Self.source()
        // Through the same reader and writer `StoreWriter` uses.
        let decoded = try JSONValue.decode([String: JSONValue].self, from: data)
        let reencoded = try JSONValue.encode(decoded)

        // Compared through Node, because Node is what has to read this back and
        // it is Node's own idea of equality that matters.
        let before = try Self.write(data, as: "before.json")
        let after = try Self.write(reencoded, as: "after.json")
        let verdict = try Self.node("""
        const a = require(process.argv[1]), b = require(process.argv[2]);
        const stable = (v) => {
          if (Array.isArray(v)) return '[' + v.map(stable).join(',') + ']';
          if (v && typeof v === 'object') {
            return '{' + Object.keys(v).sort().map(k => JSON.stringify(k) + ':' + stable(v[k])).join(',') + '}';
          }
          return JSON.stringify(v);
        };
        const sa = stable(a), sb = stable(b);
        if (sa === sb) { process.stdout.write('identical'); }
        else {
          // Name the first place they part company rather than dumping a store.
          let i = 0; while (i < sa.length && i < sb.length && sa[i] === sb[i]) i++;
          process.stdout.write('differs at ' + i + ': ' + JSON.stringify(sa.slice(Math.max(0, i - 60), i + 60))
            + ' vs ' + JSON.stringify(sb.slice(Math.max(0, i - 60), i + 60)));
        }
        """, args: [before.path, after.path])

        #expect(verdict == "identical",
                "round-tripping \(name)'s store changed it — \(verdict)")
    }

    // MARK: - plumbing

    static func write(_ data: Data, as name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-roundtrip-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try data.write(to: url)
        return url
    }

    static func node(_ script: String, args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", script] + args
        process.currentDirectoryURL = repoRoot
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let problem = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return "node failed: " + (String(data: problem, encoding: .utf8) ?? "")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
