import AppKit

/// Keys that belong to the text being typed, not to the menu bar.
///
/// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
/// Job ▸ Move Along is ⌘→, Move Back is ⌘← and File ▸ Delete… is ⌘⌫. Those
/// are also "end of line", "start of line" and "delete to the start of the
/// line" in every text field on the Mac. AppKit offers a ⌘ key-down to the
/// key window's views first (`performKeyEquivalent`), then to the MAIN MENU,
/// and only then to the first responder as an ordinary key-down. A text field
/// does not claim these keys in the first step — it handles them in the third
/// — so the menu took them: with a job selected, pressing ⌘→ while typing in
/// the search field moved the job a stage, and the caret stayed where it was
/// (Nov 11 2026 UI review; reproduced off-screen with a search field, a field
/// editor and a menu item on ⌘→).
///
/// A menu item cannot be greyed for this — nothing a `Commands` builder
/// observes changes when a field takes focus — so the key is routed before
/// the menu sees it: a local monitor hands it to the text view being edited
/// and swallows it. Nothing else changes: with no text being edited the menu
/// has the key exactly as before.
@MainActor
enum TypingKeys {
    /// ←, →, ↓, ↑, ⌫ and ⌦ by key code. Arrows and deletes are the only menu
    /// keys here that mean something while typing; ⌘N, ⌘F, ⌘1 and the rest are
    /// not editing keys and stay with the menu.
    nonisolated static let textKeyCodes: Set<UInt16> = [123, 124, 125, 126, 51, 117]

    /// Whether a key-down goes to the text being edited rather than the menu.
    /// Any of ⇧ and ⌥ may be held as well (⇧⌘→ selects to the end of the
    /// line); ⌃ is left alone, since ⌃⌘ keys are the app's own (Lock Now).
    nonisolated static func belongsToText(keyCode: UInt16, flags: NSEvent.ModifierFlags,
                                          editing: Bool) -> Bool {
        guard editing, flags.contains(.command), !flags.contains(.control) else { return false }
        return textKeyCodes.contains(keyCode)
    }

    /// The text view being typed into in `window`: a field's editor, or an
    /// editable text view. Selectable-only text is not being typed into, so
    /// the menu keeps its keys there.
    static func editor(in window: NSWindow?) -> NSTextView? {
        guard let view = window?.firstResponder as? NSTextView,
              view.isFieldEditor || view.isEditable else { return nil }
        return view
    }

    /// The monitor's body: nil when the key was given to the text, the event
    /// itself otherwise.
    static func route(_ event: NSEvent, keyWindow: NSWindow? = NSApp.keyWindow) -> NSEvent? {
        guard event.type == .keyDown else { return event }
        let text = editor(in: event.window ?? keyWindow)
        guard let text, belongsToText(keyCode: event.keyCode, flags: event.modifierFlags,
                                      editing: true) else { return event }
        text.keyDown(with: event)
        return nil
    }

    private static var monitor: Any?

    /// Once, at launch.
    static func install() {
        guard monitor == nil else { return }
        // Local monitors run on the main thread. A `Bool` crosses the
        // isolation check; an `NSEvent` is not Sendable.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let taken = MainActor.assumeIsolated { route(event) == nil }
            return taken ? nil : event
        }
    }
}
