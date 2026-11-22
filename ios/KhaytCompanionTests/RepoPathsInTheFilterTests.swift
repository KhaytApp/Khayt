import XCTest

/// The iOS job only runs when a PR touches a path in `ios-contract.yml`'s
/// filter. Several tests read repo files outside `ios/` straight from the
/// checkout (`lib/plugin-manifest.js`, `plugins/samples/*.json`, …). A test
/// reading a path the filter misses would let a PR change that file without
/// the iOS job running at all. Every such path must match the filter.
final class RepoPathsInTheFilterTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func filter() throws -> NSRegularExpression {
        let yml = try String(contentsOf: root.appending(path: ".github/workflows/ios-contract.yml"), encoding: .utf8)
        let line = try XCTUnwrap(yml.split(separator: "\n").first { $0.contains("pattern='") }, "no pattern in the workflow")
        let start = try XCTUnwrap(line.range(of: "pattern='"))
        let rest = line[start.upperBound...]
        let end = try XCTUnwrap(rest.firstIndex(of: "'"))
        return try NSRegularExpression(pattern: String(rest[..<end]))
    }

    func testEveryRepoPathATestReadsIsInTheFilter() throws {
        let re = try filter()
        func inFilter(_ path: String) -> Bool {
            re.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
        }
        XCTAssertTrue(inFilter("ios/KhaytCompanion/App.swift"), "the scan read the real pattern")
        XCTAssertFalse(inFilter("README.md"))

        let fm = FileManager.default
        let topDirs = Set(try fm.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") && $0 != "ios" && $0 != "node_modules" }
            .filter { var d: ObjCBool = false; return fm.fileExists(atPath: root.appending(path: $0).path, isDirectory: &d) && d.boolValue })
        XCTAssertTrue(topDirs.contains("lib"), "the scan found the repo root")

        let tests = root.appending(path: "ios/KhaytCompanionTests")
        // A whole literal with no spaces (a message that names a path is not a read);
        // an interpolated one ends at its `\(`, and its prefix is checked.
        let literal = try NSRegularExpression(pattern: #""([A-Za-z0-9_.-]+/[^"\\\s]*)["\\]"#)
        var missed: [String] = []
        for name in try fm.contentsOfDirectory(atPath: tests.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: tests.appending(path: name), encoding: .utf8)
            for m in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                let path = String(text[r])
                guard let top = path.split(separator: "/").first, topDirs.contains(String(top)) else { continue }
                if !inFilter(path) { missed.append("\(name): \(path)") }
            }
        }
        XCTAssertEqual(missed, [], "add these to ios-contract.yml's pattern, or the iOS job skips PRs that change them")
    }
}
