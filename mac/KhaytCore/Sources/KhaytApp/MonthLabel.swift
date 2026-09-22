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

extension MonthLabel {

    /// `2026-08` → "August 2026", in the shop's own language.
    ///
    /// For a READOUT rather than an axis. Under a column there is room for five
    /// characters and `short` is right; in a line of text there is room for the
    /// month's name, and a shop that hovered a bar to find out which month it
    /// is has been told nothing by being shown "08/26" again.
    ///
    /// Same refusal as `short`: a key this does not recognise comes back
    /// untouched rather than as a plausible wrong month.
    static func long(_ key: String, language: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]),
              (1...12).contains(month) else { return key }
        let locale = Locale(identifier: language)
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1))
        else { return key }
        return date.formatted(.dateTime.month(.wide).year().locale(locale))
    }

    /// What a chart is showing: the months it covers, or the one being pointed
    /// at.
    ///
    /// ── A CHART THAT NEVER SAID WHICH MONTHS IT WAS ───────────────────────
    ///
    /// Cash flow and the waste trend both draw a window the shop chose
    /// somewhere else on the screen, and neither said what it was. The axis is
    /// `04/26 … 09/26`, so a reader who wanted the span had to read the first
    /// label and the last one and work it out — and a total in the corner
    /// belonged to a period the card would not name.
    ///
    /// One function because both cards needed the same line and the second one
    /// was written by copying the first, which is how two charts on one screen
    /// come to describe the same window differently — the exact drift `short`
    /// was extracted to stop.
    static func span(_ months: [String], pointingAt: String?, language: String) -> String {
        if let pointingAt { return long(pointingAt, language: language) }
        guard let first = months.first, let last = months.last else { return "" }
        let from = long(first, language: language)
        // A window one month wide is not a range, and "August 2026 – August
        // 2026" is a sentence a person has to read twice to learn nothing.
        if first == last { return from }
        return from + " – " + long(last, language: language)
    }
}
