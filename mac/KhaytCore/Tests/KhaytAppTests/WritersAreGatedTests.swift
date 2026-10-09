import Foundation
import Testing
@testable import KhaytApp

/// Every write to the book — and every action with an effect outside it —
/// answers to the staff lock, or says why it does not.
///
/// The alpha.62 review found the lock enforced on about thirty functions and
/// roughly a hundred writers asking nothing; the re-check then found printer
/// control, the web store, the feedback book and the customer links asking
/// nothing either, and three `// lock: system — callers decide` notes whose
/// callers did not. This keeps a new one from arriving ungated.
///
/// The rule, for every site below: the enclosing function asks the lock
/// (`permitted`, `permittedRestoring`, `lockAllows`), or carries
///   `// lock: system — <why>`   a write that is not a person's action, or
///   `// lock: callers — f, g`   gated by its callers, each of which is
///                                checked here to ask the lock (or be system).
/// A system note may not say "callers": that is what the second form is for,
/// and the one place a claim about other code could go unchecked.
struct WritersAreGatedTests {

    static func asksTheLock(_ text: String) -> Bool {
        // Substrings, not a `\b` regex: Swift's word boundaries are Unicode's,
        // which read `shop.permitted` as one word.
        ["permitted(", "permittedRestoring(", "lockAllows("].contains { text.contains($0) }
    }
    static var funcDecl: Regex<Substring> { /func\s+\w+/ }

    /// What reaches outside the book: a printer, a plug, the web store, the
    /// library's files, the outgoing mail, a customer link's token.
    static let effects = ["PrinterControl.", "PrinterSend.send", "SmartPlug.send",
                          "CatalogPublisher.publish", "LibraryImport.add(", "Feedback.compose"]
    static let writes = ["StoreWriter.update(", "StoreWriter.updateRecord("]

    static func sources() throws -> [(name: String, lines: [String])] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        return try names.sorted().map {
            ($0, try String(contentsOf: dir.appending(path: $0), encoding: .utf8).components(separatedBy: "\n"))
        }
    }

    /// The text from the enclosing `func` down to `i`, and the func's line.
    static func enclosing(_ lines: [String], _ i: Int) -> (head: String, body: String)? {
        var j = i
        while j >= 0, lines[j].firstMatch(of: funcDecl) == nil { j -= 1 }
        guard j >= 0 else { return nil }
        return (lines[j].trimmingCharacters(in: .whitespaces), lines[j...i].joined(separator: "\n"))
    }

    /// The first ~60 lines of `func name(` anywhere in the sources.
    static func body(of name: String, in files: [(name: String, lines: [String])]) -> String? {
        for (_, lines) in files {
            for (i, line) in lines.enumerated() where line.contains("func \(name)(") {
                return lines[i..<min(lines.count, i + 60)].joined(separator: "\n")
            }
        }
        return nil
    }

    static func callers(in body: String) -> [String]? {
        guard let line = body.components(separatedBy: "\n").last(where: { $0.contains("// lock: callers — ") }),
              let list = line.components(separatedBy: "// lock: callers — ").last else { return nil }
        let names = list.components(separatedBy: CharacterSet(charactersIn: ",( "))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.first!.isLowercase && $0.allSatisfy { $0.isLetter || $0.isNumber } }
        return names
    }

    @Test("every write and every outside effect asks the lock, or says why not — and the why is checked")
    func everyWriterIsGated() throws {
        let files = try Self.sources()
        var problems: [String] = []
        var sites = 0
        for (name, lines) in files {
            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"),
                      (Self.writes + Self.effects).contains(where: { line.contains($0) }),
                      !line.contains("func ") else { continue }
                sites += 1
                guard let (head, body) = Self.enclosing(lines, i) else {
                    problems.append("\(name):\(i + 1) outside any function"); continue
                }
                if Self.asksTheLock(body) || body.contains("// lock: system — ") { continue }
                if let callers = Self.callers(in: body) {
                    #expect(!callers.isEmpty, Comment(rawValue: "\(name):\(i + 1) names no callers"))
                    for caller in callers {
                        guard let theirs = Self.body(of: caller, in: files) else {
                            problems.append("\(name):\(i + 1) names \(caller), which does not exist"); continue
                        }
                        if !Self.asksTheLock(theirs) && !theirs.contains("// lock: system — ") {
                            problems.append("\(name):\(i + 1) says \(caller) gates it; it does not")
                        }
                    }
                    continue
                }
                problems.append("\(name):\(i + 1) \(head)")
            }
        }
        #expect(sites > 100, "the scan found \(sites) sites — it is not reading the sources")
        #expect(problems.isEmpty, Comment(rawValue: "ungated:\n" + problems.joined(separator: "\n")))
    }

    @Test("the customer links mint tokens only for somebody allowed to edit the job")
    func linkMintingIsGated() throws {
        let files = try Self.sources()
        for name in ["quoteLink", "trackingLink"] {
            let body = try #require(Self.body(of: name, in: files))
            #expect(body.contains("permitted(\"orders\", \"edit\")"), Comment(rawValue: name))
        }
    }

    @Test("a system note says why, and never that its callers decide")
    func systemNotesGiveReasons() throws {
        for (name, lines) in try Self.sources() {
            for line in lines where line.contains("// lock: system") {
                let why = line.components(separatedBy: "// lock: system").last ?? ""
                #expect(why.count > 12, Comment(rawValue: "\(name): \(line)"))
                #expect(!why.lowercased().contains("caller"),
                        Comment(rawValue: "\(name): use `// lock: callers — …`, which is checked: \(line)"))
            }
        }
    }
}
