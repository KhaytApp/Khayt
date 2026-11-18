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

        // The repo's tracked top-level directories, NAMED, not listed from the
        // checkout at run time: a directory a CI step leaves behind (a build
        // folder, a cache) must not change what this test counts as a repo
        // path (#2546 went red on a words-only change). A new top-level
        // directory a test reads from goes here and in the workflow's pattern.
        let fm = FileManager.default
        let topDirs: Set<String> = Self.repoTopDirs
        for dir in topDirs.sorted() {
            var isDir: ObjCBool = false
            XCTAssertTrue(fm.fileExists(atPath: root.appending(path: dir).path, isDirectory: &isDir) && isDir.boolValue,
                          "RepoPathsInTheFilterTests.repoTopDirs names \(dir), which is not a directory in the checkout")
        }

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
        // One line per path, so the job log names it ("Which assertions failed").
        for miss in missed {
            XCTFail("repo path not in ios-contract.yml's pattern (the iOS job would skip PRs that change it): \(miss)")
        }
    }

    /// Every tracked top-level directory but `ios/` and the dot-directories (`git ls-files | cut -d/ -f1 | sort -u`, Nov 17 2026).
    static let repoTopDirs: Set<String> = [
        "assets", "contracts", "design", "design-system", "docs", "export", "extension-khayt",
        "lib", "mac", "plugins", "renderer", "scripts", "site-shots", "store", "test",
    ]
}
