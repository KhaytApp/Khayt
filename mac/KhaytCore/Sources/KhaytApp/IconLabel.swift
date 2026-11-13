import Foundation

/// What VoiceOver says for a button that shows only a symbol.
///
/// `.help` is a tooltip; it is not reliably spoken as the control's name, so
/// an icon-only button with help alone reads as "button" (Nov 11 2026 UI
/// review: 15 of them). In a list of rows the verb alone is not enough either
/// — "Delete, Delete, Delete" — so the row's own name follows it.
enum IconLabel {
    /// "Delete, Bracket body"; just the verb when the row has no name yet.
    static func naming(_ verb: String, _ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? verb : verb + ", " + n
    }
}
