import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The ratchet behind "make no internet calls": no Swift file may build a
/// request or open a socket without asking the gate (`OutboundGate`).
///
/// A request is gated where it is BUILT, so one that was refused never
/// exists to be sent by any session. That makes the check simple enough to
/// hold: every file with a `URLRequest(`, an `NWConnection(`, a
/// `webSocketTask(` or an `NWBrowser(` asks `OutboundGate.shared`, or is
/// named below with the reason it does not need to. A new file that calls
/// out fails here until it says what the call is for.
@Suite struct OutboundRatchetTests {

    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources")

    /// Files that open something and do not ask, each with why.
    static let exempt: [String: String] = [
        "KhaytApp/PrinterFinder.swift": "Bonjour on `local.` only: it browses the shop's own network and connects to what answered there",
    ]

    static var opens: Regex<AnyRegexOutput> { try! Regex(#"URLRequest\(|NWConnection\(|webSocketTask\(|NWBrowser\("#) }

    static func files() throws -> [(name: String, text: String)] {
        var out: [(String, String)] = []
        for dir in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) {
            guard let list = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in list where file.pathExtension == "swift" {
                out.append(("\(dir.lastPathComponent)/\(file.lastPathComponent)", try String(contentsOf: file, encoding: .utf8)))
            }
        }
        return out
    }

    /// The code of a file without its comment lines: a comment that mentions
    /// `URLRequest(` is not a request.
    static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("every file that builds a request or opens a socket asks the gate, or is named with its reason")
    func everyFileAsks() throws {
        var ungated: [String] = [], opening = 0
        for file in try Self.files() {
            let code = Self.code(file.text)
            guard code.contains(Self.opens) else { continue }
            opening += 1
            if code.contains("OutboundGate.shared") || code.contains("outboundGate.") { continue }
            if Self.exempt[file.name] != nil { continue }
            ungated.append(file.name)
        }
        #expect(opening >= 30, "the scan found the files it is meant to (\(opening))")
        #expect(ungated.isEmpty, "these build a request or open a socket without asking OutboundGate:\n\(ungated.sorted().joined(separator: "\n"))")
    }

    @Test("an exemption is for a file that still opens something, and still does not ask")
    func exemptionsAreCurrent() throws {
        let files = Dictionary(uniqueKeysWithValues: try Self.files().map { ($0.name, Self.code($0.text)) })
        for (name, why) in Self.exempt {
            let code = try #require(files[name], Comment(rawValue: "\(name) is gone: drop its exemption"))
            #expect(code.contains(Self.opens), Comment(rawValue: "\(name) opens nothing now: drop its exemption"))
            #expect(!code.contains("OutboundGate.shared"), Comment(rawValue: "\(name) asks the gate now: drop its exemption"))
            #expect(why.count > 20)
        }
    }

    @Test("nothing sends on the shared session without a request the gate saw: no bare URL fetches")
    func noBareURLFetches() throws {
        // `data(from: url)`, `download(from:)`, `bytes(from:)` and
        // `Data(contentsOf: https…)` make a request with no `URLRequest(` in
        // sight, which would pass the test above.
        let bare = try Regex(#"\.data\(from:|\.bytes\(from:|\.download\(from:|\.upload\(for:.*from:|dataTask\(with: *[a-z]*[uU]rl\b"#)
        var hits: [String] = []
        for file in try Self.files() where Self.code(file.text).contains(bare) { hits.append(file.name) }
        #expect(hits.isEmpty, "build a URLRequest (and ask the gate) instead: \(hits)")
    }

    @Test("Khayt Cloud's request builder asks the gate with the route's own purpose")
    func cloudBuilderAsks() throws {
        #expect(CloudReader.purpose(forTail: "/catalog") == .storefront)
        #expect(CloudReader.purpose(forTail: "/catalog?since=3") == .storefront)
        #expect(CloudReader.purpose(forTail: "/sfstats") == .storefront)
        #expect(CloudReader.purpose(forTail: "/lead-time") == .storefront)
        for tail in ["/deltas", "/keyset", "/intake/abc", "/events", "/live/printers", "/quote-sheet", "/catalogue", "/store", "/order-status", ""] {
            #expect(CloudReader.purpose(forTail: tail) == .cloud, Comment(rawValue: tail))
        }
        #expect(CloudReader.storefrontTails == ["/catalog", "/sfstats", "/lead-time"], "the desktop's three routes (lib/cloud-client.js STOREFRONT)")
    }
}
