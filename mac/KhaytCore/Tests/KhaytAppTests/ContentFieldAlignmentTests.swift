import Foundation
import SwiftUI
import Testing
@testable import KhaytApp

/// Which edge a bilingual settings field's text starts at.
///
/// The shop writes its name, tagline and address in both languages, and each
/// one has to start at the edge its own script reads from — whatever language
/// the WINDOW is in. Four combinations, and the old code got two of them
/// wrong in a way nobody had noticed:
///
/// `LabeledContent` aligns its content trailing, and the code overrode
/// `layoutDirection` per field to fix that. Overriding `layoutDirection` on a
/// `TextField` does not move its text on macOS — so all it did was change
/// which side "trailing" meant. The English name hugged the RIGHT of its
/// field and the Arabic name hugged the LEFT: each read as the other script's
/// direction. Reported by the shop, found by photographing the pane, and the
/// fix confirmed the same way in both languages.
@MainActor
struct ContentFieldAlignmentTests {

    static func field(_ language: String) -> Shop.ContentField {
        Shop.ContentField(key: "biz" + language.capitalized, base: "biz",
                          language: language, label: "Business name")
    }

    @Test("a field in the window's own direction starts where the window does")
    func agreeing() {
        // English name, English window: left, like every other label on screen.
        #expect(Self.field("en").textAlignment(appIsRTL: false) == .leading)
        // Arabic name, Arabic window: right, for the same reason.
        #expect(Self.field("ar").textAlignment(appIsRTL: true) == .leading)
    }

    @Test("a field against the window's direction starts at the other edge")
    func disagreeing() {
        // THE TWO THAT WERE WRONG.
        //
        // An Arabic name in an English window must start at the right, and an
        // English name in an Arabic window at the left — which is the opposite
        // edge to the one the window calls leading in each case.
        #expect(Self.field("ar").textAlignment(appIsRTL: false) == .trailing)
        #expect(Self.field("en").textAlignment(appIsRTL: true) == .trailing)
    }

    /// A language this app has no direction opinion about is treated as
    /// left-to-right, which is what every other locale it ships is.
    @Test("a third language reads left to right")
    func others() {
        for language in ["fr", "de", "es", "ja", "zh", ""] {
            #expect(Self.field(language).textAlignment(appIsRTL: false) == .leading,
                    Comment(rawValue: "\(language) in an English window"))
            #expect(Self.field(language).textAlignment(appIsRTL: true) == .trailing,
                    Comment(rawValue: "\(language) in an Arabic window"))
        }
    }

    /// The rule is used everywhere a bilingual field is drawn, not just on the
    /// one pane the report came from.
    @Test("every bilingual settings field asks the rule")
    func everyFieldAsks() {
        let source = MenuCoverageTests.source("SettingsWindow.swift")
        #expect(!source.isEmpty, "SettingsWindow.swift moved")
        let asks = source.components(separatedBy: "field.textAlignment(appIsRTL:").count - 1
        #expect(asks >= 3, "only \(asks) field(s) use the rule — one was missed")
        // And nothing goes back to overriding the direction instead, which is
        // the thing that looked right in source and was wrong on screen.
        #expect(!source.contains("layoutDirection, field.language"),
                "a field is steering its text with layoutDirection again")
    }
}
