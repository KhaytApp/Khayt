import Foundation

/// Text as a search compares it.
///
/// `localizedStandardContains` is case- and Latin-diacritic-insensitive, and
/// that is all — measured on macOS 26, not assumed: "أحمد" does not contain
/// "احمد", "مكتبة" does not contain "مكتبه", "ＰＬＡ" does not contain "pla",
/// and a vowelled "أَحْمَد" matches nothing typed without the vowels. An Arabic
/// shop types hamza, tā' marbūṭa and alif maqṣūra inconsistently — in a file
/// name, in a tag, and in the search box — so a search that cares which one was
/// typed finds half the shelf.
///
/// So both sides are folded first: case, diacritics and width by Foundation;
/// then the Arabic short vowels and the tatweel dropped, أ إ آ ٱ read as ا,
/// ة as ه and ى as ي. Pure and portable, so the phone can search the same way.
///
/// DIGITS TOO. The book stores Western digits — an invoice number, a phone, a
/// job's number — and an Arabic keyboard types ٠١٢٣ (or the Persian ۰۱۲۳). A
/// search for "١٠٠٢" that cannot find ORD-01002 is the same half-a-shelf bug,
/// so both Arabic-Indic sets fold to 0–9.
public enum SearchText {
    public static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: nil)
        var out = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            switch scalar.value {
            case 0x064B...0x065F, 0x0670, 0x0640: continue          // harakat, superscript alif, tatweel
            case 0x0622, 0x0623, 0x0625, 0x0671: out.append("\u{0627}") // آ أ إ ٱ → ا
            case 0x0629: out.append("\u{0647}")                       // ة → ه
            case 0x0649: out.append("\u{064A}")                       // ى → ي
            case 0x0660...0x0669:                                     // ٠–٩ → 0–9
                out.append(Unicode.Scalar(scalar.value - 0x0660 + 0x30)!)
            case 0x06F0...0x06F9:                                     // ۰–۹ → 0–9
                out.append(Unicode.Scalar(scalar.value - 0x06F0 + 0x30)!)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// Whether `text` holds `query`, both folded. An empty query matches.
    public static func contains(_ text: String, _ query: String) -> Bool {
        containsFolded(text, fold(query.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// The same, for a query already folded — a list searched per keystroke
    /// folds the query once, not once per row.
    public static func containsFolded(_ text: String, _ foldedQuery: String) -> Bool {
        guard !foldedQuery.isEmpty else { return true }
        return fold(text).localizedStandardContains(foldedQuery)
    }
}
