import SwiftUI
import AppKit

/// A field whose value is machine data rather than the shop's language.
///
/// ── THE PHONE NUMBER WAS REORDERED ON SCREEN ──────────────────────────────
///
/// In an Arabic window `+966 50 000 0000` was drawn as `0000 000 50 966+`.
/// Nothing was wrong with the value: it is stored, exported and printed on the
/// invoice correctly. The bidi algorithm was applying the paragraph's
/// right-to-left direction to the whole run — `+` is a NEUTRAL character so it
/// takes the paragraph's side and lands at the far end, and digits are WEAK so
/// the groups reorder around it. A shop reading its own telephone number in
/// its own language was shown a different number.
///
/// The email survived by luck. Every character of `hello@tuwaiq.example` is
/// strong left-to-right, so there was nothing to move; one Arabic character in
/// a domain and it breaks the same way.
///
/// ── AND WHY THIS IS AN NSTextField AND NOT A MODIFIER ─────────────────────
///
/// Three SwiftUI attempts failed before this, and `Direction.swift` explains
/// why in advance: this app's right-to-left comes from
/// `NSForceRightToLeftWritingDirection`, set on AppKit before `main()`,
/// because `.environment(\.layoutDirection, .rightToLeft)` sends
/// `NavigationSplitView` into an unbounded layout loop on macOS 26. So
/// **SwiftUI is never asked to mirror anything** — its `layoutDirection` is
/// not what is flipping these fields, and writing to it changes nothing.
/// `.multilineTextAlignment` does not reach the control either; what a shop
/// sees is AppKit's own natural alignment.
///
/// The lever is therefore AppKit's. `baseWritingDirection` fixes the
/// paragraph's direction for this one control, which is what stops the
/// neutrals moving, and it is the documented way to say it.
///
/// `Figure` solves the same problem for money with one SwiftUI line — and it
/// can, because it draws `Text`, which resolves its own direction. A
/// `TextField` is an `NSTextField` in a coat.
struct LatinField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    /// The IBAN field asks for this, and a long unbroken key reads better in
    /// it. Everything else takes the body face, like every other field.
    var monospaced = false

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.drawsBackground = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        Self.harden(field, placeholder: placeholder, monospaced: monospaced)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // Only when it differs: assigning during editing moves the caret to
        // the end, and a shop correcting the middle of a number would be
        // fighting the field.
        if field.stringValue != text { field.stringValue = text }
        Self.harden(field, placeholder: placeholder, monospaced: monospaced)
    }

    /// The two lines this type exists for, on their own so they can be asked
    /// about. A rule that can only be exercised by standing up a SwiftUI
    /// hosting view is a rule nobody writes a test for.
    static func harden(_ field: NSTextField, placeholder: String, monospaced: Bool) {
        field.placeholderString = placeholder
        field.font = monospaced
            ? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize)
        // THE TWO LINES THIS TYPE EXISTS FOR. Set on every update as well as
        // at creation: AppKit resets a cell's direction when its string is
        // replaced, so a value arriving from the book would undo it.
        field.baseWritingDirection = .leftToRight
        field.alignment = .left
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        init(text: Binding<String>) { _text = text }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text = field.stringValue
        }

        /// A field that loses focus without the delegate hearing about it
        /// keeps a value the form never saw — which is how a settings pane
        /// comes to discard what somebody typed.
        func controlTextDidEndEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text = field.stringValue
        }
    }
}
