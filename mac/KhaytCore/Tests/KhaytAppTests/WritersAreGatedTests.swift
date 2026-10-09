import Foundation
import Testing
@testable import KhaytApp

/// Every write to the book — and every action with an effect outside it —
/// answers to the staff lock, or says why it does not.
///
/// The alpha.62 review found the lock enforced on about thirty functions and
/// roughly a hundred writers asking nothing; three re-checks then found
/// printer control, the web store, the feedback book, the customer links, the
/// library's file deletions and caller lists that named only some callers.
///
/// The rule, for every site below: the function it is in asks the lock
/// (`permitted`, `permittedRestoring`, `lockAllows`), or carries
///   `// lock: system — <why>`   not a person's action, said why, or
///   `// lock: callers — f, g`   gated by its callers — and EVERY call site of
///                                the function is in one of them, each of which
///                                asks the lock (or is system) itself.
/// Functions are bounded by their braces (comments and string literals
/// skipped), so a local function is not mistaken for the one around it and an
/// overloaded name is resolved by where the call actually is.
struct WritersAreGatedTests {

    // MARK: - What counts

    static let writes = ["StoreWriter.update(", "StoreWriter.updateRecord(", "StoreWriter.atomicWrite("]
    /// What reaches outside the book: a printer, a plug, the web store, the
    /// library's files, the outgoing mail, a restore over the book.
    static let effects = ["PrinterControl.", "PrinterSend.send", "SmartPlug.send",
                          "CatalogPublisher.publish", "LibraryImport.add(", "LibraryImport.addMany(",
                          "Feedback.compose", "Restore.restore(", ".removeItem(", ".trashItem("]

    /// A deletion that is housekeeping of the app's own scratch, not a shop's
    /// file: a `defer` clean-up, or a folder named for it.
    static func isScratchCleanup(_ line: String) -> Bool {
        let l = line.lowercased()
        return (line.contains(".removeItem(") || line.contains(".trashItem("))
            && (l.contains("defer") || l.contains("scratch"))
    }

    static func asksTheLock(_ text: String) -> Bool {
        ["permitted(", "permittedRestoring(", "lockAllows("].contains { text.contains($0) }
    }

    // MARK: - Reading the sources

    struct Function {
        let file: String; let name: String; let start: Int; let end: Int; let text: String
        let type: String; let isStatic: Bool
        var key: String { "\(file):\(start)" }
    }
    struct Source { let name: String; let lines: [String]; let code: [String]; let functions: [Function]; let types: [String] }

    /// The type each line belongs to: the last top-level `enum`/`struct`/
    /// `class`/`actor`/`extension` above it. Nested types are not tracked —
    /// enough to tell `Shop.trash` from `LibraryMove`'s calls.
    static func typesByLine(_ code: [String]) -> [String] {
        var current = ""
        return code.map { line in
            if let m = line.firstMatch(of: /^(?:@\w+\s+)*(?:(?:public|private|fileprivate|internal|final|nonisolated)\s+)*(?:enum|struct|class|actor|extension)\s+(\w+)/) {
                current = String(m.output.1)
            }
            return current
        }
    }

    /// The line with string literals and `//` comments blanked, and every line
    /// of a `"""` block blanked — what brace counting may look at.
    static func codeOnly(_ lines: [String]) -> [String] {
        var inBlock = false
        return lines.map { raw in
            if raw.contains("\"\"\"") {
                let n = raw.components(separatedBy: "\"\"\"").count - 1
                if n % 2 == 1 { inBlock.toggle() }
                return ""
            }
            if inBlock { return "" }
            var out = ""
            var inString = false, escaped = false
            let chars = Array(raw)
            var k = 0
            while k < chars.count {
                let c = chars[k]
                if !inString, c == "/", k + 1 < chars.count, chars[k + 1] == "/" { break }
                if inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                    out.append(" ")
                } else if c == "\"" {
                    inString = true; out.append(" ")
                } else {
                    out.append(c)
                }
                k += 1
            }
            return out
        }
    }

    static func read() throws -> [Source] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        return try names.sorted().map { name in
            parse(name, try String(contentsOf: dir.appending(path: name), encoding: .utf8))
        }
    }

    static func parse(_ name: String, _ text: String) -> Source {
        do {
            let lines = text.components(separatedBy: "\n")
            let code = codeOnly(lines)
            let types = typesByLine(code)
            var functions: [Function] = []
            for (i, line) in code.enumerated() {
                guard let m = line.firstMatch(of: /\bfunc\s+(\w+)/) else { continue }
                // The body: from the first `{` at or after the declaration to
                // its match. A protocol requirement has none.
                var depth = 0, opened = false, end = i
                scan: for j in i..<code.count {
                    for c in code[j] {
                        if c == "{" { depth += 1; opened = true }
                        if c == "}" { depth -= 1; if opened && depth == 0 { end = j; break scan } }
                    }
                }
                guard opened else { continue }
                functions.append(Function(file: name, name: String(m.output.1), start: i, end: end,
                                          text: lines[i...end].joined(separator: "\n"),
                                          type: types[i], isStatic: line.contains("static func")))
            }
            return Source(name: name, lines: lines, code: code, functions: functions, types: types)
        }
    }

    @Test("the callers list is checked for completeness, through overloads and receivers")
    func callersListIsComplete() {
        let a = Self.parse("A.swift", """
        enum Writer {
            static func put(_ x: Int) {
                // lock: callers — gatedPut
                try? StoreWriter.update(x)
            }
            static func put(_ x: Int, twice: Bool) {
                put(x)
            }
        }
        extension Shop {
            func gatedPut() {
                guard permitted("orders", "edit") else { return }
                Writer.put(1, twice: true)
            }
            func sneakyPut() { Writer.put(2) }
            func unrelated() { var total = Sum(); total.put(3) }
        }
        """)
        let put = a.functions.first { $0.name == "put" }!
        var seen: Set<String> = []
        let why = Self.verdict(put, in: [a], seen: &seen)
        // sneakyPut and nothing else (it is met twice: once per overload, as
        // overloads share a name). `total.put(` is not a call of Writer.put.
        #expect(!why.isEmpty)
        #expect(why.allSatisfy { $0.contains("sneakyPut") }, Comment(rawValue: why.joined(separator: "\n")))
    }

    /// The innermost function whose braces hold line `i`.
    static func enclosing(_ src: Source, _ i: Int) -> Function? {
        src.functions.filter { $0.start <= i && i <= $0.end }.min { ($0.end - $0.start) < ($1.end - $1.start) }
    }

    /// The function's own text, with any function nested inside it removed —
    /// a gate in a local helper is not a gate on the function around it.
    static func ownText(_ f: Function, in src: Source) -> String {
        let inner = src.functions.filter { $0.start > f.start && $0.end <= f.end }
        return (f.start...f.end).filter { line in !inner.contains { $0.start <= line && line <= $0.end } }
            .map { src.lines[$0] }.joined(separator: "\n")
    }

    static func callerList(_ text: String) -> [String]? {
        guard let line = text.components(separatedBy: "\n").last(where: { $0.contains("// lock: callers — ") }),
              let list = line.components(separatedBy: "// lock: callers — ").last else { return nil }
        return list.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - The checks

    @Test("every write and every outside effect asks the lock, or says why not — and the why is checked")
    func everyWriterIsGated() throws {
        let sources = try Self.read()
        var problems: [String] = []
        var sites = 0
        for src in sources {
            for (i, code) in src.code.enumerated() {
                let line = src.lines[i]
                guard (Self.writes + Self.effects).contains(where: { code.contains($0) }),
                      !code.contains("func "), !Self.isScratchCleanup(line) else { continue }
                sites += 1
                guard let f = Self.enclosing(src, i) else {
                    problems.append("\(src.name):\(i + 1) outside any function"); continue
                }
                var seen: Set<String> = []
                let why = Self.verdict(f, in: sources, seen: &seen)
                if !why.isEmpty { problems += ["\(src.name):\(i + 1) in \(f.name)"] + why }
            }
        }
        #expect(sites > 100, "the scan found \(sites) sites — it is not reading the sources")
        #expect(problems.isEmpty, Comment(rawValue: "ungated:\n" + Array(Set(problems)).sorted().joined(separator: "\n")))
    }

    /// Does the line call `f`? `name(` not as the tail of a longer name
    /// (Swift's Regex has no lookbehind), and through a receiver that can be
    /// `f`: `Type.name(`/`Self.name(` for a static function of that type, any
    /// lower-case receiver (`shop.`, `self?.`) for an instance method, and a
    /// bare call only from inside the same type. So `total.add(` is not a call
    /// of `LibraryImport.add`, nor a View's own `restore(` one of `Shop.restore`.
    static func calls(_ code: String, _ f: Function, lineType: String) -> Bool {
        var rest = code[...]
        while let r = rest.range(of: f.name + "(") {
            defer { rest = rest[r.upperBound...] }
            let before = rest[..<r.lowerBound]
            guard let last = before.last else { if lineType == f.type { return true }; continue }
            if last.isLetter || last.isNumber || last == "_" { continue }
            guard last == "." else { if lineType == f.type { return true }; continue }
            let receiver = String(before.dropLast().reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "?" }.reversed())
                .replacingOccurrences(of: "?", with: "")
            if receiver.isEmpty { continue }   // `.name(` — an enum case or a member of an expression
            if receiver == f.type || (receiver == "Self" && lineType == f.type) { if f.isStatic { return true }; continue }
            if receiver.first!.isUppercase { continue }
            if !f.isStatic { return true }
        }
        return false
    }

    /// Why `f` is not shown to answer to the lock — empty when it does: it
    /// asks, or is system, or lists its callers and EVERY call of it is in a
    /// listed function that answers in turn. An overload of the same name and
    /// type is looked through to its own callers.
    static func verdict(_ f: Function, in sources: [Source], seen: inout Set<String>,
                        listed inherited: [String]? = nil) -> [String] {
        guard seen.insert(f.key).inserted else { return [] }
        let src = sources.first { $0.name == f.file }!
        let text = ownText(f, in: src)
        if inherited == nil, asksTheLock(text) || text.contains("// lock: system — ") { return [] }
        guard let listed = inherited ?? callerList(text) else {
            return ["  \(f.file): \(f.name) neither asks the lock nor says why not"]
        }
        var problems: [String] = []
        var found = 0
        for other in sources {
            for (i, code) in other.code.enumerated() where calls(code, f, lineType: other.types[i]) {
                if code.contains("func \(f.name)") { continue }
                guard let caller = enclosing(other, i), caller.key != f.key else { continue }
                found += 1
                if caller.name == f.name && caller.type == f.type {
                    problems += verdict(caller, in: sources, seen: &seen, listed: listed)
                    continue
                }
                guard listed.contains(caller.name) else {
                    problems.append("  \(f.file): \(f.name) is called from \(caller.name) (\(other.name):\(i + 1)), which its callers list does not name")
                    continue
                }
                problems += verdict(caller, in: sources, seen: &seen)
            }
        }
        if found == 0 { problems.append("  \(f.file): \(f.name) lists callers and has none") }
        return problems
    }

    @Test("the customer links mint tokens only for somebody allowed to edit the job")
    func linkMintingIsGated() throws {
        let sources = try Self.read()
        for name in ["quoteLink", "trackingLink"] {
            let defs = sources.flatMap { $0.functions }.filter { $0.name == name }
            #expect(!defs.isEmpty, Comment(rawValue: name))
            for f in defs { #expect(f.text.contains("permitted(\"orders\", \"edit\")"), Comment(rawValue: name)) }
        }
    }

    @Test("a system note says why, and never that its callers decide")
    func systemNotesGiveReasons() throws {
        for src in try Self.read() {
            for line in src.lines where line.contains("// lock: system") {
                let why = line.components(separatedBy: "// lock: system").last ?? ""
                #expect(why.count > 12, Comment(rawValue: "\(src.name): \(line)"))
                #expect(!why.lowercased().contains("caller"),
                        Comment(rawValue: "\(src.name): use `// lock: callers — …`, which is checked: \(line)"))
            }
        }
    }

    @Test("the reader is not fooled: braces in strings and comments, and local functions")
    func readerSanity() throws {
        let sources = try Self.read()
        let fns = sources.flatMap(\.functions)
        #expect(fns.count > 500, "found \(fns.count) functions")
        // A known nested helper: `file` inside bareModelPresets, which must not
        // swallow the function around it.
        let outer = try #require(fns.first { $0.name == "bareModelPresets" })
        #expect(outer.end - outer.start > 20)
    }
}
