import Testing
@testable import KhaytApp

/// Three rows that cut their own words now have room for them
/// (Nov 11 2026 UI review, B10). Source guards: the fault is a layout that
/// leaves a control less room than its words, and the cure is in the shape of
/// the row.
@MainActor struct SheetRowsWrapTests {

    static func code(_ file: String) throws -> String {
        let source = try #require(IconSources.all.first { $0.name == file }).text
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).components(separatedBy: "//").first ?? "" }.joined(separator: "\n")
    }

    @Test("the product sheet's library button is on the buttons' own line and keeps its width")
    func fromYourPrintLibrary() throws {
        let code = try Self.code("ProductSheet.swift")
        let after = try #require(code.components(separatedBy: #"callIt("link.from_library")"#).last)
        // Its own width, the first thing said after the button.
        let next = after.components(separatedBy: "Button(").first ?? ""
        #expect(next.contains(".fixedSize()"))
        // And not on the line with the grams and hours fields any more.
        let row = try #require(code.components(separatedBy: #"callIt("mac.grams")"#).last?
            .components(separatedBy: "HStack(spacing: 8) {").first)
        #expect(!row.contains("link.from_library"))
    }

    @Test("a price agreement's note is as flexible as its product, not a fixed 120 points")
    func perUnitAnyColour() throws {
        let code = try Self.code("CustomerSheet.swift")
        let note = try #require(code.components(separatedBy: #"callIt("ce.pl_note")"#).last?
            .components(separatedBy: "Button").first)
        #expect(note.contains(".frame(minWidth: 120)"))
        #expect(!note.contains(".frame(width: 120)"))
    }

    @Test("a downtime window's reason has the line under the dates to itself")
    func lensClean() throws {
        let code = try Self.code("MachineSheet.swift")
        let editor = try #require(code.components(separatedBy: "struct DowntimeEditor").last)
        let reason = try #require(editor.components(separatedBy: #"callIt("mach.downtime_reason")"#).last)
        let style = reason.components(separatedBy: "\n").prefix(3).joined()
        #expect(style.contains(".textFieldStyle(.roundedBorder)"))
        #expect(!style.contains("minWidth: 90"), "the reason is back on the dates' line")
        // The dates' line ends with the remove button, before the reason.
        let before = try #require(editor.components(separatedBy: #"callIt("mach.downtime_reason")"#).first)
        #expect(before.contains("minus.circle"))
    }
}
