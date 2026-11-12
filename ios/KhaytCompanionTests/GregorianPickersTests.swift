import XCTest
@testable import KhaytCompanion

/**
 * Due dates are picked and written in the Gregorian calendar.
 *
 * Every due date is shown Gregorian (DueDateParser.display), but the New
 * order and Edit pickers used the phone's own calendar, which is Umm al-Qura
 * on a Saudi phone: the shop picked a Hijri day and read back a Gregorian one
 * (UI review Nov 11, F5).
 */
final class GregorianPickersTests: XCTestCase {

    func testEveryDatePickerIsGregorian() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("KhaytCompanion/Views")
        let files = try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var pickers = 0
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("DatePicker(") {
                pickers += 1
                let next = lines[i..<min(i + 6, lines.count)].joined(separator: "\n")
                XCTAssertTrue(next.contains("Calendar(identifier: .gregorian)"),
                              "\(file.lastPathComponent):\(i + 1) picks in the phone's own calendar")
            }
        }
        XCTAssertGreaterThanOrEqual(pickers, 3, "the pickers moved; this test lost them")
    }

    func testTheWrittenDayIsGregorianOnAnIslamicPhone() {
        var umm = Calendar(identifier: .islamicUmmAlQura)
        umm.timeZone = .current
        // 12 Nov 2026 at noon, built in the Gregorian calendar.
        var greg = Calendar(identifier: .gregorian)
        greg.timeZone = .current
        let day = greg.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12))!
        XCTAssertNotEqual(umm.component(.year, from: day), 2026, "sanity: the Hijri year differs")
        XCTAssertEqual(NewOrderSheet.dayFormat.string(from: day), "2026-11-12")
        XCTAssertEqual(EditOrderSheet.dayFormat.string(from: day), "2026-11-12")
    }
}
