import Foundation
import Testing
@testable import KhaytApp

/// Every field the shop types into draws as a field.
///
/// A `TextField` or `SecureField` inside `LabeledContent` has no bezel, so an
/// EMPTY one is invisible. #1489 fixed thirty-five of them by setting the
/// style once on `row`, and said "so a pane added later cannot forget it" —
/// but the Online pane never used `row`, and its owner-PIN field was a blank
/// strip until a shop asked where the PIN goes. The PIN is the one field that
/// has to be filled before the phone queue is safe, and it had no placeholder
/// either until a PIN was stored.
///
/// So the check is the shape, anywhere in the app, not the helper.
@MainActor
struct FieldsHaveBezelsTests {

    @Test("no field inside LabeledContent draws without a border")
    func everyFieldHasABezel() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 30, "the source moved — this test is reading the wrong directory")
        var offences: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("LabeledContent(")
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let block = lines[i..<min(lines.count, i + 12)].joined(separator: "\n")
                guard block.contains("TextField(") || block.contains("SecureField(") else { continue }
                if !block.contains("roundedBorder") {
                    offences.append("\(file.lastPathComponent):\(i + 1)")
                }
            }
        }
        #expect(offences.isEmpty, Comment(rawValue:
            "fields with no border — invisible when empty; add .textFieldStyle(.roundedBorder) "
            + "or build the row with `row(…)`:\n" + offences.sorted().joined(separator: "\n")))
    }

    @Test("the owner PIN in particular")
    func thePin() {
        let pane = MenuCoverageTests.source("OnlinePane.swift")
        guard let at = pane.range(of: "text: $draft.pin)") else {
            Issue.record("the PIN field moved"); return
        }
        let after = pane[at.upperBound...].prefix(120)
        #expect(after.contains(".textFieldStyle(.roundedBorder)"), "the owner PIN field has no border again")
    }
}
