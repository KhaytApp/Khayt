import Foundation

/// The words the shop's papers and the quote answers needed that Khayt's own
/// catalogue did not have (`Shop+Papers.swift`, `Shop+Quotes.swift`). Nearly
/// everything on those screens is the desktop's own wording — "Packing Slip",
/// "Quote history", "Follow up" — and arrives in nine languages from there.
///
/// A table of its own, merged into `Words.own`, for the reason
/// `ReviewWords` gives: several branches add words at once.
enum DocumentWords {
    nonisolated static let table: [String: [String: String]] = [
        // The column a quote's version is listed under in its history.
        "mac.quote_version_col": ["en": "Version", "ar": "الإصدار"],
        // The customer inspector's heading over the statement and the invoices.
        "mac.customer_papers": ["en": "Statement and invoices", "ar": "كشف الحساب والفواتير"],
    ]
}
