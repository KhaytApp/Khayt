import Foundation
import Testing
@testable import KhaytApp

/// A number a person TYPED is read with `TypedNumber.parse`, never `Double(…)`.
///
/// `Double("١٥٠")` is nil and `Double("2,5")` is nil, so a field read that way
/// took Arabic digits or a decimal comma as nothing: a machine preset saved
/// with every rate 0, a campaign filter that silently was not applied, a
/// promo code worth 0. `TypedNumber` was written for New Job (#2383) and the
/// beta.34 review found its siblings still on `Double(` (L7). Reading found
/// six; this scan found three more (Edit Part's grams and hours, and two
/// failure-rate hints).
///
/// ── WHAT THE SCAN CATCHES ────────────────────────────────────────────────
///
/// `Double(` cannot be told apart by type from here (`Double(count)` is
/// everywhere and is fine), so the scan looks for the ways a STRING
/// conversion is used, since only that one is optional:
///   - its result is defaulted or mapped: `Double(x) ?? 0`, `.flatMap`, `.map`;
///   - it is bound in a condition: `let n = Double(x),` / `… else`;
///   - `Double.init` handed to a map;
///   - its argument is plainly text: `.trimmingCharacters`,
///     `.replacingOccurrences`, `?? ""`;
///   - it is returned or assigned from a name text goes by (`s`, `t`,
///     `typed`, `cleaned`, `…Text`, `raw`, …).
/// Every line it finds is either converted or counted below with the reason
/// it is NOT something a person typed. A new one fails here until it is one
/// or the other.
struct TypedNumberRatchetTests {

    /// File → how many flagged lines it may hold, and why none of them is a
    /// typed field.
    static let notTyped: [String: (count: Int, why: String)] = [
        // The last line of a reader that has already normalised what was typed.
        "TypedNumber.swift": (1, "the reader itself"),
        "RowsByID.swift": (1, "a typed-number reader of its own, digits already made plain"),
        "LibrarySmartFolders.swift": (1, "a typed-number reader of its own, digits already made plain"),
        "CalculatorModel.swift": (1, "a typed-number reader of its own, digits already made plain"),
        // A number the BOOK holds as a string (the desktop app writes some so).
        "Client.swift": (2, "a book value stored as a string"),
        "Milestones.swift": (1, "a book value stored as a string"),
        "Operators.swift": (2, "a book value stored as a string"),
        "ProductSheet.swift": (1, "a book value stored as a string"),
        "Shop+Jobs.swift": (1, "a book value stored as a string"),
        "Shop+Library.swift": (1, "a book value stored as a string"),
        "LenientDecoding.swift": (1, "a book value stored as a string"),
        // What a file, a server or the system wrote.
        "Mesh.swift": (4, "coordinates in a model file"),
        "LibraryFile.swift": (1, "a figure cached from a model file"),
        "ModelInfo.swift": (1, "a slicer's comment in a print file"),
        "LibraryInspector.swift": (1, "a slot number from a print file"),
        "RiyalMark.swift": (1, "the app's own SVG path"),
        "CustomReport.swift": (1, "a cell the report engine returned"),
        "OnlineOrders.swift": (2, "prices as Khayt Cloud holds them"),
        "WebStore.swift": (2, "prices as Khayt Cloud holds them"),
        "Telemetry.swift": (1, "an HTTP Retry-After header"),
        "LivePrinterPublisher.swift": (1, "an HTTP Retry-After header"),
        "KhaytApp.swift": (2, "debug environment variables"),
        "LibraryMove.swift": (1, "an Int64 of free bytes, mapped"),
    ]

    static let argument = #"(?:[^()]|\((?:[^()]|\([^()]*\))*\))*"#
    static let patterns: [String] = [
        #"Double\("# + argument + #"\)\s*(?:\?\?|\.flatMap|\.map)"#,
        #"\blet \w+ = Double\("# + argument + #"\)\s*(?:,|else)"#,
        #"Double\.init"#,
        #"Double\(.*?(?:trimmingCharacters|replacingOccurrences|\?\? "")"#,
        #"(?:\? nil : |return |(?<![<>!=])= )Double\((?:s|t|\w*[Tt]ext|\w*[Tt]yped|cleaned|raw|said|plain|out|token|rest|cell)[.)]"#,
    ]

    static func flagged(_ line: String) -> Bool {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return false }
        let range = NSRange(line.startIndex..., in: line)
        return patterns.contains { pattern in
            (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: line, range: range) != nil
        }
    }

    @Test("the scan knows a string conversion from a count")
    func theScanItself() {
        for line in [
            "rates[key] = max(0, Double(typed) ?? 0)",
            "return cleaned.isEmpty ? nil : Double(cleaned)",
            "guard let n = Double(typed), n.isFinite, n > 0 else { return nil }",
            #"let n = max(0, Double(s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) ?? 0)"#,
            #"current: Double(presetRates["failureRate"] ?? "")) { pct in"#,
            "grams: Double(now.grams) ?? 0, hours: 1,",
            "let rates = texts.compactMap(Double.init)",
            "price = Double(priceText)",
        ] { #expect(Self.flagged(line), "missed: \(line)") }
        for line in [
            #""n": .number(Double(recipients.count))]),"#,
            "let k = Double(side) * margin / span",
            "guard abs(a - b) <= Double(out.count), c else { return [] }",
            "// rates[key] = Double(typed) ?? 0",
            "let n = TypedNumber.parse(typed) ?? 0",
        ] { #expect(!Self.flagged(line), "false alarm: \(line)") }
    }

    @Test("no field a person types into is read with Double( — every string conversion is accounted for")
    func everyStringConversionIsAccountedFor() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        var found: [String: [String]] = [:]
        let walker = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var files = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            files += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() where Self.flagged(line) {
                found[url.lastPathComponent, default: []].append("\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(files > 200, "the scan did not find the app's sources")
        for (file, lines) in found.sorted(by: { $0.key < $1.key }) {
            let allowed = Self.notTyped[file]?.count ?? 0
            #expect(lines.count == allowed, """
                \(file): \(lines.count) string→Double conversions, \(allowed) accounted for. \
                A typed field reads with TypedNumber.parse; anything else is listed in `notTyped` with its reason.
                \(lines.joined(separator: "\n"))
                """)
        }
        // And the list cannot outlive what it excuses.
        for (file, entry) in Self.notTyped where found[file] == nil {
            Issue.record("\(file) is excused (\(entry.why)) and holds no such line any more: take it off the list")
        }
    }

    @Test("the fields the review named read Arabic digits and a decimal comma")
    func theNamedSitesUseTheReader() throws {
        func source(_ name: String) throws -> String {
            try String(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Sources/KhaytApp/\(name)"), encoding: .utf8)
        }
        for name in ["OnlinePane.swift", "CampaignSheet.swift", "PartTrackingSheets.swift", "WebStore.swift",
                     "Shop+Money.swift", "Calculator.swift", "ProductSheet.swift"] {
            #expect(try source(name).contains("TypedNumber.parse("), "\(name)")
        }
        // What those fields now make of what a Saudi keyboard types.
        #expect(TypedNumber.parse("١٥٠") == 150)
        #expect(TypedNumber.parse("٢٫٥") == 2.5)
        #expect(TypedNumber.parse("2,5") == 2.5)
        #expect(TypedNumber.parse("1,250") == 1250)
        #expect(TypedNumber.parse("") == nil)
    }
}
