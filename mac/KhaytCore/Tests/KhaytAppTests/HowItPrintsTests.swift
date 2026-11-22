import Testing
import Foundation
import KhaytCore
@testable import KhaytApp

/// The library inspector's "How it prints" panel.
///
/// The rule that produces the facts is `lib/print-facts.js` and is tested in
/// `test/print-facts.test.js`. What is tested here is the SECOND place the same
/// mistake can be made: a panel that shows a support style for a model with no
/// support, or picks one part's infill for a plate whose parts disagree, is
/// wrong even when the rule underneath it is right.
@MainActor
struct HowItPrintsTests {

    /// A `PrintFacts` the way one really arrives: decoded from what the JS rule
    /// returns, so a field renamed on either side fails here too.
    func facts(printer: String? = "Snapmaker U1", layerHeight: Double? = 0.12,
               nozzle: Double? = 0.4, nozzleVaries: Bool = false,
               materials: [String] = ["PLA"], infill: String? = "15%",
               infillVaries: Bool = false, support: Bool? = false,
               supportStyle: String? = nil, objects: Int? = 1,
               source: String? = "orca") -> KhaytEngine.PrintFacts {
        var dict: [String: Any] = [
            "nozzleVaries": nozzleVaries,
            "materials": materials,
            "infillVaries": infillVaries,
            "printer": printer as Any,
            "layerHeight": layerHeight as Any,
            "nozzle": nozzle as Any,
            "infill": infill as Any,
            "support": support as Any,
            "supportStyle": supportStyle as Any,
            "objects": objects as Any,
            "source": source as Any,
        ]
        for (key, value) in dict where value is NSNull || (value as? String) == nil
            && (value as? Double) == nil && (value as? Int) == nil
            && (value as? Bool) == nil && (value as? [String]) == nil {
            dict[key] = NSNull()
        }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(KhaytEngine.PrintFacts.self, from: data)
    }

    @Test func aFileThatSaysNothingGetsNoPanelAtAll() {
        let words = Words()
        #expect(LibraryInspector.lines(from: nil, words: words).isEmpty)
        // The CAD case: no source, no objects. A panel headed "How it prints"
        // with nothing under it is worse than no panel.
        let empty = facts(printer: nil, layerHeight: nil, nozzle: nil, materials: [],
                          infill: nil, support: nil, objects: nil, source: nil)
        #expect(empty.isEmpty)
        #expect(LibraryInspector.lines(from: empty, words: words).isEmpty)
    }

    @Test func supportOffNeverShowsAStyle() {
        let words = Words()
        // The file still carries `support_type: tree(auto)` — this is exactly
        // the shape that reaches the panel when the rule is doing its job, and
        // the panel must not put it on screen anyway.
        let lines = LibraryInspector.lines(
            from: facts(support: false, supportStyle: "tree(auto)"), words: words)
        let support = lines.first { $0.label == words.callIt("doc.supports") }
        #expect(support?.value == words.callIt("common.none"))
        #expect(!lines.contains { $0.value.contains("tree") })
    }

    @Test func supportOnSaysHow() {
        let words = Words()
        let lines = LibraryInspector.lines(
            from: facts(support: true, supportStyle: "tree(auto)"), words: words)
        #expect(lines.contains { $0.value == "tree(auto)" })
    }

    @Test func aPlateWhoseObjectsDisagreeSaysSo() {
        let words = Words()
        let lines = LibraryInspector.lines(
            from: facts(infill: "100%", infillVaries: true), words: words)
        let infill = lines.first { $0.label == words.callIt("mac.infill") }
        #expect(infill?.value == words.callIt("mac.varies_by_part"))
        #expect(infill?.value != "100%")
    }

    @Test func mixedNozzlesAreNotReportedAsOneNozzle() {
        let words = Words()
        let lines = LibraryInspector.lines(
            from: facts(nozzle: 0.4, nozzleVaries: true), words: words)
        let nozzle = lines.first { $0.label == words.callIt("conv.cp_nozzle") }
        #expect(nozzle?.value == words.callIt("mac.mixed_nozzles"))
    }

    @Test func aSingleObjectPlateDoesNotBragAboutBeingOne() {
        let words = Words()
        let one = LibraryInspector.lines(from: facts(objects: 1), words: words)
        #expect(!one.contains { $0.label == words.callIt("mac.on_the_plate") })
        let many = LibraryInspector.lines(from: facts(objects: 20), words: words)
        #expect(many.contains { $0.value == words.counting(20, "mac.objects_n") })
    }

    @Test func measurementsCarryNoTrailingZeros() {
        #expect(LibraryInspector.number(0.12) == "0.12")
        #expect(LibraryInspector.number(0.4) == "0.4")
        #expect(LibraryInspector.number(0.2) == "0.2")
        #expect(LibraryInspector.number(1) == "1")
    }

    @Test func noLineCarriesAnEnglishUnit() {
        // The unit belongs to the label, which is translated. A value of
        // "0.12 mm" would put an English word in the Arabic panel — the mistake
        // this app has already made once with "3 h 06 m".
        let words = Words()
        let lines = LibraryInspector.lines(
            from: facts(support: true, supportStyle: "tree(auto)"), words: words)
        for line in lines {
            #expect(!line.value.hasSuffix(" mm"), "\(line.label) carries a unit: \(line.value)")
        }
    }

    @Test func everySharedKeyThePanelUsesIsDeclaredBorrowed() {
        // A fresh `Words` has not loaded Khayt's catalogue, so a shared key
        // comes back as ITSELF — which is exactly what a shop would see if the
        // key were never declared. `Words.borrowed` is the list
        // `WordsTests.borrowedKeysExist` then proves complete in every language,
        // so a key used here and missing there ships as `conv.cp_nozzle` in an
        // inspector. This is the join between the two.
        let words = Words()
        let lines = LibraryInspector.lines(
            from: facts(nozzleVaries: true, infillVaries: true, support: true,
                        supportStyle: "tree(auto)", objects: 4), words: words)
        #expect(lines.count >= 6)
        for line in lines where line.label.contains(".") {
            #expect(Words.borrowed.contains(line.label),
                    "\(line.label) is used by the inspector and is not in Words.borrowed")
        }
        // And the app's own words really did resolve, rather than passing the
        // check by also looking like keys.
        #expect(lines.contains { $0.label == "Infill" })
    }
}
