import Foundation
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// Lines that mix the shop's words with figures, and which way they run.
///
/// `Text("\(label) (\(unit))")` is a localized key: SwiftUI isolates each
/// interpolated piece, so the line has no strong letter of its own and runs
/// left to right even in Arabic — "(ساعة) وقت الطباعة" unit-first. A plain
/// String in `Text(verbatim:)` takes its direction from its first word.
@MainActor
struct BidiLineTests {

    static func sources() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "found only \(files.count) source files — the scan has rotted")
        return files
    }

    @Test("no Text(\"…\") interpolates the shop's words — they would run left to right in Arabic")
    func noWordsInAnInterpolatedKey() throws {
        // A `Text("` literal (not verbatim) holding an interpolation of a
        // word lookup or a label handed in from one.
        let wordy = try Regex(#"Text\("[^"]*\\\((shop\.)?(words\.|callIt|label\b|quoted\b|tier\.label)"#)
        var offenders: [String] = []
        for url in try Self.sources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && line.contains(wordy) {
                offenders.append("\(url.lastPathComponent):\(n + 1)")
            }
        }
        #expect(offenders.isEmpty, "build a String and use Text(verbatim:): \(offenders)")
    }

    @Test("the message box runs the way its message does")
    func messageDirection() {
        // The language the message is in, when it says.
        #expect(MessageSheet.direction(lang: "ar", text: "", shopLanguage: "en") == .rightToLeft)
        #expect(MessageSheet.direction(lang: "en", text: "مرحبا", shopLanguage: "ar") == .leftToRight)
        // A template for every customer: its first letter decides, and a
        // leading placeholder's digits or punctuation do not.
        #expect(MessageSheet.direction(lang: "", text: "{{name}}", shopLanguage: "ar") == .leftToRight)
        #expect(MessageSheet.direction(lang: "", text: "12 — طلبك جاهز", shopLanguage: "en") == .rightToLeft)
        #expect(MessageSheet.direction(lang: "", text: "Your order is ready", shopLanguage: "ar") == .leftToRight)
        // A blank box: the shop's own language.
        #expect(MessageSheet.direction(lang: "", text: "", shopLanguage: "ar") == .rightToLeft)
        #expect(MessageSheet.direction(lang: "", text: "  123 ", shopLanguage: "en") == .leftToRight)
    }

    @Test("a phone or email joined into a line is isolated, so its digit groups keep their order")
    func phonesIsolated() {
        #expect(EmptyStateTests.source("SupplierSheet.swift").contains("parts.append(Figure.isolated(supplier.phone))"))
        let goTo = EmptyStateTests.source("Shop+GoTo.swift")
        #expect(goTo.contains("[phone, email].filter { !$0.isEmpty }.map { Figure.isolated($0) }"))
        #expect(goTo.contains("[job.id, job.invoiceNumber ?? \"\", job.client]\n                .filter { !$0.isEmpty }.map { Figure.isolated($0) }"))
    }

    @Test("a narrow strip says Group and Category with their symbols, as Provenance does")
    func narrowStripMenus() {
        for file in ["GroupMenu.swift", "CategoryMenu.swift", "ProvenanceMenu.swift"] {
            let source = EmptyStateTests.source(file)
            #expect(source.contains("@Environment(\\.stripCompact) private var compact"), "\(file)")
            #expect(source.contains(".labelStyle(.iconOnly)"), "\(file)")
        }
        #expect(EmptyStateTests.source("Shell.swift").contains("minWidth: StripWidth.compact(width) ? 120 : 160"))
    }
}
