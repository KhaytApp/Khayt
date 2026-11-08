import Foundation
import Testing
@testable import KhaytApp

/// Every collection the phone writes is one the Mac accepts from it.
///
/// `LanServer.foldFromPhone` drops a delta for a collection outside
/// `phoneWritable` and still answers 200 — on purpose, so one undeliverable
/// edit cannot jam the queue behind it. The price is that a collection missing
/// from the list is lost SILENTLY: the phone marks it synced and never sends it
/// again. It happened twice — `clients` (Oct 2026), then printer care
/// (`machMaintTasks`/`machMaintLog`, Nov 2026) — because nothing compared the
/// list with what the phone actually writes. This reads the phone's writer.
struct PhoneWritableContractTests {

    static func phoneWriter() throws -> String {
        // …/mac/KhaytCore/Tests/KhaytAppTests/<this file> → repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "ios/KhaytCompanion/Services/BookWriter.swift"),
                          encoding: .utf8)
    }

    /// `root["x"] = …` in the phone's writer: the collections it changes.
    static func written(_ source: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"root\["([A-Za-z]+)"\]\s*="#)
        let range = NSRange(source.startIndex..., in: source)
        var out = Set<String>()
        for m in pattern.matches(in: source, range: range) {
            if let r = Range(m.range(at: 1), in: source) { out.insert(String(source[r])) }
        }
        // Bookkeeping the fold handles itself, not a collection.
        out.remove("tombstones")
        return out
    }

    @Test("the Mac accepts every collection the phone's writer changes")
    func everyWriteIsAccepted() throws {
        let written = Self.written(try Self.phoneWriter())
        #expect(written.count >= 4, "the reader found almost nothing — has BookWriter changed shape?")
        let refused = written.subtracting(LanServer.phoneWritable)
        #expect(refused.isEmpty, Comment(rawValue:
            "the phone writes \(refused.sorted()) but LanServer.phoneWritable drops them with a 200 — the edit is lost"))
    }

    @Test("printer care and declined enquiries are among them")
    func careIsAccepted() {
        for c in ["machMaintTasks", "machMaintLog", "waitingListHistory"] {
            #expect(LanServer.phoneWritable.contains(c), Comment(rawValue: c))
        }
    }
}
