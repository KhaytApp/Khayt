import Foundation
import JavaScriptCore
import Testing

/// An Arabic invoice is dated in the Gregorian calendar, on the Mac too.
///
/// `ar-SA` defaults to the Umm al-Qura calendar in CLDR. Electron's ICU
/// happened to give Gregorian for `ar-SA-u-nu-latn`; this Mac's
/// JavaScriptCore does not — it printed "09 جمادى الأولى، 1448 هـ" under DATE
/// on an Arabic invoice dated 20 Oct 2026, unlike the desktop and unlike every
/// date the Swift side shows. The shop chose Gregorian (Oct 2026), so the tag
/// names the calendar instead of leaving it to whichever engine reads it.
@MainActor
struct PrintDateCalendarTests {

    @Test("an Arabic invoice date is Gregorian with Western digits in JavaScriptCore")
    func arabicIsGregorian() throws {
        let url = LocationsTests.repoRoot().appending(path: "mac/KhaytCore/Sources/KhaytCore/JS/print-date.js")
        let ctx = try #require(JSContext())
        ctx.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        let date = ctx.evaluateScript(
            "KhaytPrintDate.printDate('2026-10-20T10:00:00Z', KhaytPrintDate.localeTagFor('ar'))")?.toString() ?? ""
        #expect(date.contains("2026"), "\(date)")
        #expect(date.contains("أكتوبر"), "\(date)")
        #expect(!date.contains("هـ") && !date.contains("1448"), "a Hijri date: \(date)")
        #expect(!date.contains { ("٠"..."٩").contains($0) }, "Arabic-Indic digits: \(date)")
    }

    @Test("the Mac's copy of print-date.js is lib/'s")
    func sameAsLib() throws {
        let root = LocationsTests.repoRoot()
        let mac = try String(contentsOf: root.appending(path: "mac/KhaytCore/Sources/KhaytCore/JS/print-date.js"), encoding: .utf8)
        let lib = try String(contentsOf: root.appending(path: "lib/print-date.js"), encoding: .utf8)
        #expect(mac == lib)
    }
}
