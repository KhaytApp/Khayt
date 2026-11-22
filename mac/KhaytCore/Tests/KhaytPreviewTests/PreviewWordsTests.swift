import Testing
import Foundation
import KhaytCore
@testable import KhaytPreview

/// The preview's vocabulary.
///
/// Small, and every part of it is a decision that fails silently when it is
/// wrong: a label falls back to its own key, or the panel starts calling a
/// printer something the app does not call it.
struct PreviewWordsTests {

    @Test func khaytsOwnWordComesFirst() {
        // The shared catalogue wins over anything this panel might hold, because
        // one shop must not be given two vocabularies for the same thing.
        let words = Words(language: "en", khayt: ["mac.infill": "Fill"])
        #expect(words.callIt("mac.infill") == "Fill")
    }

    @Test func thePanelsOwnWordsAnswerWhatKhaytHasNever() {
        let words = Words(language: "en", khayt: [:])
        #expect(words.callIt("mac.infill") == "Infill")
        #expect(words.callIt("mac.on_the_plate") == "On the plate")
    }

    @Test func arabicIsArabicAndNotTheEnglishWearingItsClothes() {
        let words = Words(language: "ar", khayt: [:])
        #expect(words.isRTL)
        for key in PrintFactLines.ownWords.keys {
            let ar = words.callIt(key)
            #expect(ar != key, "\(key) fell through to its own name")
            #expect(ar != PrintFactLines.ownWords[key]?["en"],
                    "\(key) shows the English in an Arabic panel")
        }
    }

    @Test func anEmptyStringIsNotAWord() {
        // A catalogue that carries the key with nothing in it must fall through,
        // not render a blank label — that is a row with no name beside a value.
        let words = Words(language: "en", khayt: ["mac.infill": ""])
        #expect(words.callIt("mac.infill") == "Infill")
    }

    @Test func anUnknownKeyShowsItselfSoItGetsReported() {
        let words = Words(language: "en", khayt: [:])
        #expect(words.callIt("conv.cp_nozzle") == "conv.cp_nozzle")
    }

    @Test func countingPutsTheNumberInFrontAndKnowsAboutOne() {
        let en = Words(language: "en", khayt: [:])
        #expect(en.counting(4, "mac.objects_n") == "4 objects")
        #expect(en.counting(1, "mac.objects_n") == "1 object")
        let ar = Words(language: "ar", khayt: [:])
        #expect(ar.counting(4, "mac.objects_n").hasSuffix("قطع"))
        #expect(ar.counting(1, "mac.objects_n").hasSuffix("قطعة"))
    }

    @Test func theLanguageIsOneThisPanelHasWordsFor() {
        // Whatever macOS is set to, the answer is a language the panel can
        // actually render. A `fr` here would show every label as its own key.
        #expect(["en", "ar"].contains(Words.preferred()))
    }

    /// Every line the panel can produce is a real word, in both languages.
    @Test func noLineEverRendersAKey() async throws {
        let facts = try JSONDecoder().decode(KhaytEngine.PrintFacts.self, from: Data("""
        {"printer":"Snapmaker U1","layerHeight":0.12,"nozzle":0.4,"nozzleVaries":true,
         "materials":["PLA","PETG"],"infill":"100%","infillVaries":true,
         "support":true,"supportStyle":"tree(auto)","objects":4,"source":"orca"}
        """.utf8))
        for language in ["en", "ar"] {
            // The shared catalogue as it really arrives, so the borrowed keys
            // are answered by Khayt rather than by this panel.
            let engine = try KhaytEngine()
            let khayt = try await engine.translations(language: language)
            let words = Words(language: language, khayt: khayt)
            let lines = PrintFactLines.lines(from: facts,
                                             word: { words.callIt($0) },
                                             counting: { words.counting($0, $1) })
            #expect(lines.count >= 6)
            for line in lines {
                #expect(!line.label.contains("."), "\(language): key on screen — \(line.label)")
                #expect(!line.label.isEmpty)
            }
        }
    }
}
