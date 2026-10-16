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
}
