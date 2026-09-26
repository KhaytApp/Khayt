import Foundation
import Testing
@testable import KhaytApp

/// What the library says happened.
///
/// The banner area under the search field answers ONE question — what happened
/// when you last asked for something — and four gestures write there: a move, an
/// import, a conversion, opening a slicer.
///
/// Each used to clear only its own line. Reported from the running app: a green
/// "1 moved in · 0 already there · 0 failed" with the conversion's
/// `KhaytCore: TypeError…` directly underneath it, from two different gestures
/// minutes apart. Read together — which is the only way they are read — they
/// describe something that never happened.
@MainActor
struct LibraryOutcomeTests {

    @Test("a new gesture clears the last one's answer, whichever gesture it was")
    func oneAnswerAtATime() {
        let shop = Shop()
        shop.importNote = "1 moved in · 0 already there · 0 failed."
        shop.importProblem = "a zip that would not open"
        shop.convertNote = "saved as dragon-u1.3mf"
        shop.convertProblem = "KhaytCore: TypeError"
        shop.slicerProblem = "Orca would not start"
        shop.moveProblem = "a folder cannot be moved inside itself"

        shop.clearLastOutcome()

        #expect(shop.importNote == nil)
        #expect(shop.importProblem == nil)
        #expect(shop.convertNote == nil)
        #expect(shop.convertProblem == nil)
        #expect(shop.slicerProblem == nil)
        #expect(shop.moveProblem == nil)
    }

    /// The helper is worth nothing unless every gesture starts with it, and
    /// this is the half that would rot: a fifth gesture added later would clear
    /// its own line and pile up beside the others exactly as these four did.
    @Test("every library gesture starts by clearing the last answer")
    func everyGestureClears() {
        let shop = MenuCoverageTests.source("Shop.swift")
        #expect(!shop.isEmpty, "Shop.swift moved")

        for gesture in ["func addModelToLibrary() async {",
                        "func addModelsToLibrary(_ chosen: [URL]) async {",
                        "func convertModel(_ file: LibraryFile, targetId: String?) async {",
                        "func openInSlicer(_ url: URL, slicer: KhaytEngine.Slicer) async {",
                        "func deleteLibraryFiles(_ files: [LibraryFile]) async {"] {
            let start = try? #require(shop.range(of: gesture), "\(gesture) moved or was renamed")
            guard let start else { continue }
            // The FIRST thing it does. A clear further down would run after an
            // early `return` had already written the new answer.
            let body = shop[start.upperBound...].prefix(120)
            #expect(body.contains("clearLastOutcome()"),
                    "\(gesture) leaves the previous gesture's banner on screen")
        }
    }

    /// The banner stack is what makes the pile-up visible, so it is worth
    /// pinning that these lines really do share one place on screen.
    @Test("the four gestures write to the same banner area")
    func sameBannerArea() {
        let banners = MenuCoverageTests.source("Banners.swift")
        #expect(!banners.isEmpty, "Banners.swift moved")
        for field in ["shop.importProblem", "shop.importNote",
                      "shop.convertProblem", "shop.convertNote",
                      "shop.slicerProblem", "shop.moveProblem"] {
            #expect(banners.contains(field), "\(field) no longer draws a banner")
        }
    }
}
