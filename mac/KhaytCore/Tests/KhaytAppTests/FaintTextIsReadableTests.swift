import AppKit
import SwiftUI
import Testing
@testable import KhaytApp

/// Dark is one family of surfaces, and the faintest text can still be read
/// (Nov 11 2026 UI review, B23 to B25).
@MainActor
struct FaintTextIsReadableTests {

    static func luminance(_ c: NSColor) -> Double {
        func lin(_ v: CGFloat) -> Double { let x = Double(v); return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    static func hex(_ c: NSColor) -> String {
        String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }

    @Test("faint text clears 4.5:1 on every card and ground, in both appearances")
    func faintIsText() {
        let grounds: [(String, Color)] = [("surface", Khayt.surface), ("ground", Khayt.ground), ("recessed", Khayt.recessed),
                                          ("role surf", Role.surf), ("role surf2", Role.surf2), ("role surf3", Role.surf3),
                                          ("role bg", Role.bg)]
        for dark in [false, true] {
            let ink = ContrastTests.resolve(Khayt.faint, dark: dark)
            for (name, ground) in grounds {
                let g = ContrastTests.resolve(ground, dark: dark)
                let ratio = Self.contrast(ink, g)
                #expect(ratio >= 4.5, Comment(rawValue: "faint \(Self.hex(ink)) on \(name) \(Self.hex(g)) \(dark ? "dark" : "light") is \(String(format: "%.2f", ratio)):1"))
            }
        }
    }

    @Test("in dark the older card palette is the navy family, not charcoal")
    func oneFamily() {
        #expect(Self.hex(ContrastTests.resolve(Role.surf, dark: true)) == Self.hex(ContrastTests.resolve(Khayt.surface, dark: true)))
        #expect(Self.hex(ContrastTests.resolve(Role.bg, dark: true)) == Self.hex(ContrastTests.resolve(Khayt.ground, dark: true)))
        #expect(Self.hex(ContrastTests.resolve(Role.surf2, dark: true)) == Self.hex(ContrastTests.resolve(Khayt.recessed, dark: true)))
        #expect(Self.hex(ContrastTests.resolve(Role.line, dark: true)) == Self.hex(ContrastTests.resolve(Khayt.hairline, dark: true)))
        // Light is untouched.
        #expect(Self.hex(ContrastTests.resolve(Role.surf, dark: false)) == "#FFFFFF")
    }

    @Test("a model's picture sits on the well in dark, lighter than its card")
    func theWell() {
        let well = ContrastTests.resolve(LibraryTile.well, dark: true)
        #expect(Self.hex(well) == Self.hex(ContrastTests.resolve(Khayt.well, dark: true)))
        let card = ContrastTests.resolve(Khayt.surface, dark: true)
        #expect(Self.luminance(well) > Self.luminance(card))
        // A black print stands off it more than it did off the old
        // brown-black (#24211C).
        let black = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        let old = NSColor(srgbRed: 0x24 / 255.0, green: 0x21 / 255.0, blue: 0x1C / 255.0, alpha: 1)
        #expect(Self.contrast(black, well) > Self.contrast(black, old) * 1.4)
    }

    @Test("text is never set in the system's tertiary style, which measures about 2:1")
    func noTertiaryText() {
        var hits: [String] = []
        for file in IconSources.all {
            for (index, line) in file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where Self.setsTextInTertiary(String(line)) {
                hits.append("\(file.name):\(index + 1)")
            }
        }
        #expect(hits.isEmpty, Comment(rawValue: "use Khayt.faint: " + hits.joined(separator: ", ")))
    }

    /// Does this line of source set text in the system's tertiary style?
    ///
    /// THREE spellings, because the first sweep knew one. It looked for
    /// `.foregroundStyle(.tertiary)` and so walked past every place the style
    /// is one arm of a choice: `dim ? AnyShapeStyle(.tertiary) : …` (the
    /// machine cards' section captions and dim labels, `Detail.swift`) and
    /// `x == nil ? .tertiary : .primary` (the gift cards table). A stroke or a
    /// fill in tertiary is a line, not text, and is left alone; so is prose in
    /// a comment.
    static func setsTextInTertiary(_ line: String) -> Bool {
        let code = line.components(separatedBy: "//").first ?? line
        if code.contains(".foregroundStyle(.tertiary)") { return true }
        let lower = code.lowercased()
        let drawsALine = lower.contains("stroke") || lower.contains(".fill(")
        if code.contains("AnyShapeStyle(.tertiary)") { return !drawsALine }
        if code.contains("foregroundStyle("), code.contains("? .tertiary :") || code.contains(": .tertiary)") {
            return true
        }
        return false
    }

    @Test("the guard knows a caption from a stroke")
    func theGuardReads() {
        #expect(Self.setsTextInTertiary("Text(a).foregroundStyle(.tertiary)"))
        #expect(Self.setsTextInTertiary(".foregroundStyle(dim ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))"))
        #expect(Self.setsTextInTertiary("    : AnyShapeStyle(.tertiary))"))
        #expect(Self.setsTextInTertiary(".foregroundStyle(holder == nil ? .tertiary : .primary)"))
        #expect(!Self.setsTextInTertiary(".strokeBorder(colour == nil ? AnyShapeStyle(.tertiary)"))
        #expect(!Self.setsTextInTertiary("// was AnyShapeStyle(.tertiary) until the review"))
        #expect(!Self.setsTextInTertiary(".foregroundStyle(dim ? AnyShapeStyle(Khayt.faint) : AnyShapeStyle(.secondary))"))
    }

    @Test("a machine card's captions and dim labels are drawn in the faint ink")
    func machineCaptions() throws {
        let detail = try #require(IconSources.all.first { $0.name == "Detail.swift" }).text
        #expect(detail.contains("accent.map(AnyShapeStyle.init) ?? AnyShapeStyle(Khayt.faint)"))
        #expect(detail.contains("dim ? AnyShapeStyle(Khayt.faint) : AnyShapeStyle(.secondary)"))
    }
}

/// The app's sources, read once.
enum IconSources {
    static var all: [(name: String, text: String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "swift" }.map {
            ($0.lastPathComponent, (try? String(contentsOf: $0, encoding: .utf8)) ?? "")
        }
    }
}
