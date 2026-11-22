import Foundation
import SwiftUI
import Testing
@testable import KhaytApp

/// Rows bound by ID (`RowsByID.swift`): a field whose row has gone commits
/// into nothing, instead of indexing past the end of the array and quitting
/// the app — the Settings ▸ Overhead crash on alpha.77.
@MainActor
struct RowsByIDTests {
    struct Row: Identifiable, Equatable {
        let id: String
        var amount: Double
    }

    final class Box {
        var rows: [Row]
        init(_ rows: [Row]) { self.rows = rows }
        var binding: Binding<[Row]> { Binding(get: { self.rows }, set: { self.rows = $0 }) }
    }

    @Test("a field whose row was removed writes nothing and reads its last value")
    func removedRow() {
        let box = Box([Row(id: "a", amount: 1), Row(id: "b", amount: 2), Row(id: "c", amount: 3)])
        let fields = box.binding.byID
        // The last row's ✖︎ is clicked while its amount field still has focus.
        box.rows.removeAll { $0.id == "c" }
        // The field commits on its way out. By position this was rows[2]: a trap.
        fields[2].wrappedValue.amount = 99
        #expect(box.rows == [Row(id: "a", amount: 1), Row(id: "b", amount: 2)])
        #expect(fields[2].wrappedValue == Row(id: "c", amount: 3))
    }

    @Test("a write finds its row by ID after the rows above it move")
    func movedRow() {
        let box = Box([Row(id: "a", amount: 1), Row(id: "b", amount: 2)])
        let fields = box.binding.byID
        box.rows.removeAll { $0.id == "a" }
        fields[1].wrappedValue.amount = 20
        #expect(box.rows == [Row(id: "b", amount: 20)], "row b, not whatever sits at index 1")
    }

    @Test("an amount is read as it is typed, in either digit set")
    func liveNumbers() {
        #expect(LiveNumberField.parse("100") == 100)
        #expect(LiveNumberField.parse("١٠٠") == 100)
        #expect(LiveNumberField.parse("1,250.5") == 1250.5)
        #expect(LiveNumberField.parse("١٬٢٥٠٫٥") == 1250.5)
        #expect(LiveNumberField.parse("12.") == 12)
        #expect(LiveNumberField.parse("rent") == nil)
        #expect(LiveNumberField.parse("-5") == nil)
        #expect(LiveNumberField.show(0) == "")
        #expect(LiveNumberField.show(1250) == "1250")
    }

    @Test("no editable list binds its rows by position")
    func noForEachOverABinding() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "found only \(files.count) source files — the scan has rotted")
        let byPosition = try Regex(#"ForEach\(\$[A-Za-z_.]+\)"#)
        var offenders: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("///")
                && line.contains(byPosition) && !line.contains(".byID)") {
                offenders.append("\(url.lastPathComponent):\(n + 1)")
            }
        }
        #expect(offenders.isEmpty, "use ForEach($rows.byID): \(offenders)")
    }
}
