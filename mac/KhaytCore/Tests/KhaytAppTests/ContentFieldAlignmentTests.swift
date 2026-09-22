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

/// Every ORDINARY settings field starts where you type, not at the far edge.
///
/// ── HALF-FIXED IS WORSE THAN NOT FIXED ────────────────────────────────────
///
/// `LabeledContent` puts its content against the trailing edge, so "Phone" was
/// drawn as `+966 50 000 0000` hard against the right of the pane, a full
/// column away from its own label. The bilingual name fields were given an
/// explicit alignment when they needed a special one — an Arabic name in an
/// English window reads from the other edge — and the forty-three ordinary
/// fields were left alone. Fixing the exceptions and missing the rule leaves a
/// form with two behaviours and no explanation, which is how it was reported.
///
/// ── AND IT HAS TO BE INSIDE THE CLOSURE ───────────────────────────────────
///
/// The obvious placement does nothing: `.multilineTextAlignment(.leading)` on
/// the `LabeledContent` itself is overridden by the labelled style, which sets
/// its own alignment on the content it wraps — closer to the field, so it
/// wins. Photographed both ways before believing either. This pins the
/// placement, because the version that reads more naturally is the broken one.
@MainActor
struct SettingsFieldAlignmentTests {

    static func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "Sources/KhaytApp/SettingsWindow.swift"),
                          encoding: .utf8)
    }

    @Test("every field through `row` starts at the reading edge")
    func rowAlignsItsContent() throws {
        let text = try Self.source()
        #expect(text.contains("LabeledContent(label) { content().multilineTextAlignment(.leading) }"),
                """
                `row` no longer aligns its content, so every ordinary settings \
                field draws its text against the far edge of the pane — or the \
                alignment moved outside the closure, where the labelled style \
                overrides it and it silently does nothing
                """)
    }

    /// `.leading`, never `.left`. The reading edge of whichever direction the
    /// window is in, so an Arabic window keeps its fields on the right.
    @Test("the alignment is the reading edge, not a side")
    func itIsNotHardcodedLeft() throws {
        let text = try Self.source()
        #expect(!text.contains("multilineTextAlignment(.left)"),
                "a hard left pins every field to the wrong edge in an Arabic window")
    }

    /// And the two fields that need the OTHER edge still ask for it. They set
    /// theirs on the field itself, closer to the leaf than `row`'s.
    @Test("a bilingual field still chooses its own edge")
    func theExceptionSurvivesTheRule() throws {
        let text = try Self.source()
        #expect(text.contains(".multilineTextAlignment(field.textAlignment(appIsRTL: appIsRTL))"),
                """
                the bilingual name fields lost their own alignment, so an \
                Arabic name in an English window reads from the wrong edge again
                """)
    }
}
