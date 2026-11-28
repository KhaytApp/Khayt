import XCTest
import SwiftUI
@testable import KhaytCompanion

/// The Live Activity's Lock Screen view, rendered. The simulator has no Lock
/// Screen to photograph, so this is how the design is looked at: run with
/// `TEST_RUNNER_KHAYT_SHOTS=<dir>` and every phase is written there as a PNG,
/// in English and Arabic, light and dark. Without it the renders are only
/// checked to exist, so a view that stops drawing fails here.
@MainActor
final class PrintActivityLookTests: XCTestCase {

    private let phases: [PrintActivityAttributes.ContentState.Phase] = [.printing, .paused, .finished, .failed]

    private func state(_ phase: PrintActivityAttributes.ContentState.Phase) -> PrintActivityAttributes.ContentState {
        let now = Date()
        return .init(phase: phase, job: "Dragon_0.2mm_PLA_3h12m.gcode", progress: 62,
                     startedAt: now.addingTimeInterval(-2 * 3600), endsAt: now.addingTimeInterval(72 * 60))
    }

    /// The widget's own table, as the extension would read it.
    private var widgetBundle: Bundle {
        let url = Bundle.main.builtInPlugInsURL!.appending(path: "KhaytWidgetExtension.appex")
        return Bundle(url: url) ?? .main
    }

    func testEveryPhaseDrawsInBothLanguagesAndBothAppearances() throws {
        let out = ProcessInfo.processInfo.environment["KHAYT_SHOTS"].map { URL(filePath: $0) }
        let attributes = PrintActivityAttributes(machineId: "demo", machineName: "Snapmaker U1")
        for phase in phases {
            for lang in ["en", "ar"] {
                for dark in [false, true] {
                    let view = PrintActivityLockScreen(attributes: attributes, state: state(phase), bundle: widgetBundle)
                        .padding(.horizontal, 18).padding(.vertical, 16)
                        .frame(width: 370)
                        .background(PrintActivityLook.surface.opacity(0.92))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(12)
                        .background(dark ? Color.black : Color(white: 0.82))
                        .environment(\.locale, Locale(identifier: lang))
                        .environment(\.layoutDirection, lang == "ar" ? .rightToLeft : .leftToRight)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 3
                    let image = try XCTUnwrap(renderer.uiImage, "\(phase) \(lang) did not draw")
                    XCTAssertGreaterThan(image.size.height, 80)
                    if let out, let png = image.pngData() {
                        try png.write(to: out.appending(path: "la-\(phase.rawValue)-\(lang)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }

    /// The safety net (Turki, Nov 28): a card whose estimated finish has
    /// passed with no reading since says "Should be done — open Khayt"
    /// instead of standing at its last percent, in both languages, right to
    /// left in Arabic. Written as `la-overdue-*` beside the phases.
    func testAnOverdueCardSaysOpenKhaytInsteadOfAFrozenPercent() throws {
        let out = ProcessInfo.processInfo.environment["KHAYT_SHOTS"].map { URL(filePath: $0) }
        let attributes = PrintActivityAttributes(machineId: "demo", machineName: "Baby U1")
        let now = Date()
        let late = PrintActivityAttributes.ContentState(phase: .printing, job: "Bracket_PLA_2h10m.gcode", progress: 61,
                                                        startedAt: now.addingTimeInterval(-3 * 3600),
                                                        endsAt: now.addingTimeInterval(-20 * 60))
        XCTAssertTrue(PrintActivityText.overdue(late, stale: true, now: now))
        for lang in ["en", "ar"] {
            for dark in [false, true] {
                let view = PrintActivityLockScreen(attributes: attributes, state: late, bundle: widgetBundle, stale: true)
                    .padding(.horizontal, 18).padding(.vertical, 16)
                    .frame(width: 370)
                    .background(PrintActivityLook.surface.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(12)
                    .background(dark ? Color.black : Color(white: 0.82))
                    .environment(\.locale, Locale(identifier: lang))
                    .environment(\.layoutDirection, lang == "ar" ? .rightToLeft : .leftToRight)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage, "overdue \(lang) did not draw")
                XCTAssertGreaterThan(image.size.height, 80)
                if let out, let png = image.pngData() {
                    try png.write(to: out.appending(path: "la-overdue-\(lang)-\(dark ? "dark" : "light").png"))
                }
            }
        }
        // The words are in every table the extension ships.
        for lang in ["en", "ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            let table = try XCTUnwrap(widgetBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: lang)
                .flatMap { NSDictionary(contentsOf: $0) as? [String: String] }, lang)
            let said = try XCTUnwrap(table["Should be done — open Khayt"], lang)
            XCTAssertFalse(said.isEmpty, lang)
            XCTAssertNil(said.rangeOfCharacter(from: .decimalDigits), "\(lang): no figure that can be out of date")
        }
    }

    /// Only a printing card whose finish has passed AND that no reading has
    /// moved since. A fresh card, a paused one, or one with no estimate keeps
    /// what it shows.
    func testOnlyAStaleCardPastItsFinishIsOverdue() {
        let now = Date()
        func s(_ phase: PrintActivityAttributes.ContentState.Phase, ends: TimeInterval?) -> PrintActivityAttributes.ContentState {
            .init(phase: phase, job: nil, progress: 61, startedAt: now.addingTimeInterval(-3600),
                  endsAt: ends.map { now.addingTimeInterval($0) })
        }
        XCTAssertTrue(PrintActivityText.overdue(s(.printing, ends: -60), stale: true, now: now))
        XCTAssertTrue(PrintActivityText.overdue(s(.printing, ends: 0), stale: true, now: now))
        XCTAssertFalse(PrintActivityText.overdue(s(.printing, ends: -60), stale: false, now: now), "a reading came: believe it")
        XCTAssertFalse(PrintActivityText.overdue(s(.printing, ends: 600), stale: true, now: now), "stale early (the Mac's 5-minute window): not yet due")
        XCTAssertFalse(PrintActivityText.overdue(s(.printing, ends: nil), stale: true, now: now), "no estimate: nothing has passed")
        XCTAssertFalse(PrintActivityText.overdue(s(.paused, ends: -60), stale: true, now: now))
        XCTAssertFalse(PrintActivityText.overdue(s(.finished, ends: -60), stale: true, now: now))
        // No update after the start: iOS flips isStale at the date the START
        // carried, and the phone starts with the estimated finish (or later),
        // never before it. So a card nobody ever updates still turns overdue
        // at its finish.
        let ends = now.addingTimeInterval(40 * 60)
        let startStale = PrintActivityPlan.staleDate(endsAt: ends, now: now)
        XCTAssertEqual(startStale, ends)
        XCTAssertTrue(PrintActivityText.overdue(s(.printing, ends: 40 * 60), stale: true, now: startStale))
        // A finish within five minutes: stale at five minutes, already past it.
        let soon = PrintActivityPlan.staleDate(endsAt: now.addingTimeInterval(60), now: now)
        XCTAssertTrue(PrintActivityText.overdue(s(.printing, ends: 60), stale: true, now: soon))
        // An estimate already passed when it started: stale in five minutes, overdue then.
        let past = PrintActivityPlan.staleDate(endsAt: now.addingTimeInterval(-60), now: now)
        XCTAssertTrue(PrintActivityText.overdue(s(.printing, ends: -60), stale: true, now: past))
    }

    func testAPrintersFileNameReadsAsATitle() {
        XCTAssertEqual(PrintActivityText.jobTitle("Dragon_0.2mm_PLA_3h12m.gcode"), "Dragon 0.2mm PLA 3h12m")
        XCTAssertEqual(PrintActivityText.jobTitle("plate_1.gcode.3mf"), "plate 1")
        XCTAssertEqual(PrintActivityText.jobTitle("Benchy.BGCODE"), "Benchy")
        XCTAssertEqual(PrintActivityText.jobTitle(".gcode"), ".gcode", "nothing left: the name as given")
    }

    func testAFinishedPrintIsWholeAndOnlyPrintingAndFailedShowAFigure() {
        XCTAssertEqual(PrintActivityText.shownProgress(state(.finished)), 100, "done at the printer's last 62 is still done")
        XCTAssertEqual(PrintActivityText.shownProgress(state(.failed)), 62, "a failure shows where it got to")
        XCTAssertEqual(phases.filter(PrintActivityText.showsPercent), [.printing, .failed])
    }

    func testThePercentIsWesternDigitsAndClamped() {
        XCTAssertEqual(PrintActivityText.percent(62), "62%")
        XCTAssertEqual(PrintActivityText.percent(140), "100%")
        XCTAssertEqual(PrintActivityText.percent(-3), "0%")
    }

    func testTheBarStandsAtTheReportedPercentWhenFirstSeenMidPrint() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let seen = PrintActivityAttributes.ContentState(phase: .printing, job: nil, progress: 45,
                                                        startedAt: now, endsAt: now.addingTimeInterval(55 * 60))
        let range = try XCTUnwrap(PrintActivityText.barRange(seen, now: now))
        let filled = now.timeIntervalSince(range.lowerBound) / range.upperBound.timeIntervalSince(range.lowerBound)
        XCTAssertEqual(filled, 0.45, accuracy: 0.001, "first seen at 45%, not an empty bar")

        var fresh = seen; fresh.progress = 0; fresh.startedAt = now.addingTimeInterval(-60)
        XCTAssertEqual(PrintActivityText.barRange(fresh, now: now)?.lowerBound, fresh.startedAt)
        var over = seen; over.endsAt = now.addingTimeInterval(-1)
        XCTAssertNil(PrintActivityText.barRange(over, now: now), "past its end: the drawn bar instead")
        XCTAssertNil(PrintActivityText.barRange(state(.paused), now: now))
    }

    func testTheTimeLeftAndEndTimeUseWesternDigitsInArabic() {
        let ar = PrintActivityText.latinDigits(Locale(identifier: "ar_SA"))
        XCTAssertEqual(ar.numberingSystem.identifier, "latn")
        XCTAssertEqual(ar.language.languageCode, .arabic, "still Arabic words and plurals")
        let time = Date(timeIntervalSince1970: 0).formatted(.dateTime.hour().minute().locale(ar))
        XCTAssertFalse(time.contains { "٠١٢٣٤٥٦٧٨٩".contains($0) }, time)
    }
}
