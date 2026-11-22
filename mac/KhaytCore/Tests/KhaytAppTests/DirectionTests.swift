import Foundation
import Testing
@testable import KhaytApp

/// Which way the window reads, decided before AppKit starts.
struct DirectionTests {

    @Test("Arabic reads right to left, English does not")
    func knowsTheDirection() {
        #expect(Direction.rtlLanguages.contains("ar"))
        #expect(!Direction.rtlLanguages.contains("en"))
        // The others are here so adding a locale is a one-line change in the
        // set rather than a new condition somewhere.
        for language in ["fa", "he", "ur"] {
            #expect(Direction.rtlLanguages.contains(language), "\(language) reads right to left")
        }
    }

    @Test("the language can be forced, which is the only way to photograph one")
    func envWins() {
        // KHAYT_LANG is set by the snapshot runs. Guarded rather than asserted
        // both ways: this test must pass whether or not it is set.
        if let forced = ProcessInfo.processInfo.environment["KHAYT_LANG"] {
            #expect(Direction.shopLanguage() == forced)
        } else {
            // Falls back to the shop's book, or English when there is no book.
            let language = Direction.shopLanguage()
            #expect(!language.isEmpty, "a language is always decided, never left blank")
        }
    }

    @Test("a shop with no book at all still gets a direction")
    func neverBlank() {
        let language = Direction.shopLanguage()
        #expect(language.count >= 2, "got \(language.debugDescription)")
    }
}
