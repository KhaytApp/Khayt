import Foundation
import Testing
@testable import KhaytApp

/// A button that shows only a symbol has to be named for VoiceOver.
///
/// `.help` is a tooltip and is not reliably spoken as the control's name, so
/// "minus.circle" with help alone reads as "button". The Nov 11 2026 UI
/// review found 15 of these. Read as source: a view cannot be asked what
/// VoiceOver would say without running it.
struct IconButtonsAreNamedTests {

    static var sources: [(name: String, lines: [String])] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }.map {
            ($0.lastPathComponent, ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").components(separatedBy: "\n"))
        }
    }

    /// `label: { Image(systemName: "…") }` and `{ Image(systemName: "…") }`
    /// closing a Button on one line: the whole label is one symbol.
    static func isIconOnlyLabel(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("Image(systemName:"), t.hasSuffix("}") else { return false }
        guard t.contains("label: { Image(systemName:") || t.hasPrefix("Button") else { return false }
        // A label with words beside the symbol is not icon-only.
        return !t.contains("Text(") && !t.contains("Label(")
    }

    @Test("every icon-only button says what it is")
    func named() {
        var unnamed: [String] = []
        for file in Self.sources {
            for (i, line) in file.lines.enumerated() where Self.isIconOnlyLabel(line) {
                // The modifiers that follow the label, up to the next blank
                // line or closing brace of the row.
                let tail = file.lines[(i)..<min(file.lines.count, i + 8)].joined(separator: "\n")
                if !tail.contains(".accessibilityLabel(") && !tail.contains(".accessibilityHidden(true)") {
                    unnamed.append("\(file.name):\(i + 1)")
                }
            }
        }
        #expect(unnamed.isEmpty, Comment(rawValue: "icon-only buttons with no accessibilityLabel: "
                                         + unnamed.joined(separator: ", ")))
    }

    @Test("a row's button carries the row's name, and falls back to the verb")
    func naming() {
        #expect(IconLabel.naming("Delete", "Bracket body") == "Delete, Bracket body")
        #expect(IconLabel.naming("Delete", "  ") == "Delete")
    }
}
