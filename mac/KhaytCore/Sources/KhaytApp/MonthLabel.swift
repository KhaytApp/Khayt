import Foundation

/// How a month is written under a bar.
///
/// Khayt's rules key a month as `2026-08`, which is right for sorting and
/// wrong for reading sideways under twelve columns forty points wide. Every
/// chart in the app shortens it the same way, and until this existed every
/// chart shortened it with its own byte-identical copy of these four lines —
/// four places for one convention to drift in, which is how two charts on one
/// screen end up labelling the same month differently.
enum MonthLabel {

    /// `2026-08` → `08/26`.
    ///
    /// Anything that is not `YYYY-MM` is handed back untouched rather than
    /// mangled into a plausible-looking wrong month: a key this does not
    /// recognise is a bug to see, not one to hide behind a tidy label.
    static func short(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2 else { return key }
        return "\(parts[1])/\(parts[0].suffix(2))"
    }
}
