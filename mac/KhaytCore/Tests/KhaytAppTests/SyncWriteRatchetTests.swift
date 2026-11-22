import Foundation
import Testing

/// Every place the Mac app still writes the whole book SYNCHRONOUSLY — and a
/// list that may only get shorter.
///
/// A synchronous `StoreWriter.update` / `updateRecord` from the main actor
/// decodes, changes, encodes and fsyncs the whole book while the window waits,
/// and waits first for any scan write already on the chain (#1859, #1860,
/// `StoreWritePerfTests`). The way off is `StoreWriter.updateOffMain`, or the
/// async `update` when the change has to ask the engine.
///
/// ── `try await` DOES NOT MAKE IT ASYNC ───────────────────────────────────
///
/// `try await StoreWriter.update(storeURL:…) { root in … }` with no `await`
/// inside the closure compiles to the SYNCHRONOUS update: the closure fits
/// both overloads and the plain one wins. Nine writes looked asynchronous and
/// were not — a customer's LAN intake and a cloud sign-in among them. So an
/// awaited call counts here as synchronous unless its trailing closure awaits.
///
/// The list is by file and function. A new synchronous write fails this; so
/// does one that has gone — take it off the list, so the list stays the truth.
struct SyncWriteRatchetTests {

    /// What is left, and why it is left. Keyed `File.swift:function`.
    static let allowed: [String: Int] = [
        // The `khayt import` command line: no window, run in Terminal.
        "ImportCommand.swift:drawMissingPreviews": 1,
        "ImportCommand.swift:remeasure3MFs": 1,
        // Runs inside `PinWork.run`, off the main thread already.
        "LinkedFolders.swift:regroupLinked": 1,
        // A one-time migration on load, a no-op on every book without the
        // stray key (`Shop.load` is another lane's; left alone).
        "Shop+Library.swift:rescueStrandedServiceLog": 1,
    ]

    static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
    }

    /// Every synchronous whole-book write in `text`, by enclosing function.
    static func syncWrites(in text: String, file: String) -> [String] {
        let chars = Array(text.utf8)
        var found: [String] = []
        let needles = ["StoreWriter.update(", "StoreWriter.updateRecord("].map { Array($0.utf8) }
        var i = 0
        while i < chars.count {
            guard let needle = needles.first(where: { matches($0, chars, at: i) }) else { i += 1; continue }
            defer { i += needle.count }
            let lineStart = (chars[..<i].lastIndex(of: UInt8(ascii: "\n")) ?? -1) + 1
            let before = String(decoding: chars[lineStart..<i], as: UTF8.self)
            if before.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            if before.contains("await") {
                // Awaited: asynchronous only if its trailing closure awaits.
                guard let close = matching(chars, open: i + needle.count - 1, "(", ")") else { continue }
                var j = close + 1
                while j < chars.count, chars[j] == UInt8(ascii: " ") || chars[j] == UInt8(ascii: "\n") { j += 1 }
                guard j < chars.count, chars[j] == UInt8(ascii: "{"),
                      let end = matching(chars, open: j, "{", "}") else { continue }
                if String(decoding: chars[j...end], as: UTF8.self).contains("await") { continue }
            }
            found.append(file + ":" + enclosingFunction(chars, before: i))
        }
        return found
    }

    static func matches(_ needle: [UInt8], _ chars: [UInt8], at i: Int) -> Bool {
        i + needle.count <= chars.count && Array(chars[i..<(i + needle.count)]) == needle
    }

    static func matching(_ chars: [UInt8], open: Int, _ o: Character, _ c: Character) -> Int? {
        let ob = UInt8(ascii: o.unicodeScalars.first!), cb = UInt8(ascii: c.unicodeScalars.first!)
        var depth = 0
        for k in open..<chars.count {
            if chars[k] == ob { depth += 1 }
            if chars[k] == cb { depth -= 1; if depth == 0 { return k } }
        }
        return nil
    }

    static func enclosingFunction(_ chars: [UInt8], before i: Int) -> String {
        let head = String(decoding: chars[..<i], as: UTF8.self)
        guard let range = head.range(of: "func ", options: .backwards) else { return "?" }
        return String(head[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    @Test("no synchronous whole-book write is added, and the list names what is left")
    func ratchet() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.sources.path)
            .filter { $0.hasSuffix(".swift") && $0 != "StoreWriter+Build.swift" }
        #expect(files.count > 100, "the sources moved")
        var counts: [String: Int] = [:]
        for file in files {
            let text = try String(contentsOf: Self.sources.appending(path: file), encoding: .utf8)
            for key in Self.syncWrites(in: text, file: file) { counts[key, default: 0] += 1 }
        }
        let added = counts.filter { (Self.allowed[$0.key] ?? 0) < $0.value }.keys.sorted()
        let gone = Self.allowed.filter { (counts[$0.key] ?? 0) < $0.value }.keys.sorted()
        #expect(added.isEmpty, "a synchronous whole-book write from the main actor: \(added) — use StoreWriter.updateOffMain")
        #expect(gone.isEmpty, "no longer synchronous, take it off the list: \(gone)")
    }

    @Test("an awaited write whose closure never awaits is counted as the synchronous one it is")
    func awaitedButSync() {
        let text = """
        func a() async throws {
            try await StoreWriter.update(
                storeURL: u, owns: { true }, whoHasIt: { nil }
            ) { root in root["x"] = .null }
        }
        func b() async throws {
            try await StoreWriter.update(storeURL: u, owns: { true }, whoHasIt: { nil }) { root in
                root["x"] = try await engine.ask()
            }
        }
        func c() async throws {
            try await StoreWriter.updateOffMain(build) { root in root["x"] = .null }
            // try StoreWriter.update(build) in a comment
        }
        func d() { try? StoreWriter.updateRecord(build, collection: "c", id: "i") { _ in } }
        """
        let found = SyncWriteRatchetTests.syncWrites(in: text, file: "F.swift")
        #expect(found == ["F.swift:a", "F.swift:d"])
    }
}
