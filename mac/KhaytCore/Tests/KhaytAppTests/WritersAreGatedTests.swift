import Foundation
import Testing
@testable import KhaytApp

/// Every write to the book answers to the staff lock — or says why it does not.
///
/// The alpha.62 review found the lock enforced on about thirty functions and
/// roughly a hundred writers asking nothing: a viewer could issue a gift card,
/// clear a payment, change the VAT, point the book at a cloud server. They were
/// gated in one pass; this keeps a new one from arriving ungated.
///
/// The rule: every `StoreWriter.update`/`updateRecord` call in the app sits in
/// a function that asks the lock (`permitted`, `permittedRestoring`,
/// `lockAllows`) or carries a `// lock: system — <why>` note — a write that is
/// not a person's action (a sync merge, a printer's report, a paired phone or
/// a customer through the LAN server, a migration). The shared helpers
/// (`writeToOneOrder`, `write(as:)`) take the gate as a required argument, so
/// their callers are held at compile time.
struct WritersAreGatedTests {

    /// Substrings, not a `\b` regex: Swift's default word boundaries are
    /// Unicode's, which read `shop.permitted` as ONE word, so a `\b` before
    /// `permitted` never matched a gate written on `shop`.
    static func asksTheLock(_ text: String) -> Bool {
        ["permitted(", "permittedRestoring(", "lockAllows("].contains { text.contains($0) }
    }
    static var funcDecl: Regex<Substring> { /func\s+\w+/ }

    static func sources() throws -> [(name: String, text: String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        return try names.sorted().map { ($0, try String(contentsOf: dir.appending(path: $0), encoding: .utf8)) }
    }

    @Test("every StoreWriter call in the app is gated or says it is the system's")
    func everyWriterIsGated() throws {
        var ungated: [String] = []
        var writers = 0
        for (name, text) in try Self.sources() {
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated()
            where line.contains("StoreWriter.update(") || line.contains("StoreWriter.updateRecord(") {
                writers += 1
                var j = i
                while j >= 0, lines[j].firstMatch(of: Self.funcDecl) == nil { j -= 1 }
                let body = lines[max(0, j)...i].joined(separator: "\n")
                let systemNote = body.contains("// lock: system — ")
                if !Self.asksTheLock(body), !systemNote {
                    ungated.append("\(name):\(i + 1) \(j >= 0 ? lines[j].trimmingCharacters(in: .whitespaces) : "?")")
                }
            }
        }
        #expect(writers > 100, "the scan found \(writers) writers — it is not reading the sources")
        #expect(ungated.isEmpty, Comment(rawValue: "ungated writers:\n" + ungated.joined(separator: "\n")))
    }

    @Test("a system note says why, not just that it is one")
    func systemNotesGiveReasons() throws {
        for (name, text) in try Self.sources() {
            for line in text.components(separatedBy: "\n") where line.contains("// lock: system") {
                let why = line.components(separatedBy: "// lock: system").last ?? ""
                #expect(why.count > 12, Comment(rawValue: "\(name): \(line)"))
            }
        }
    }
}
