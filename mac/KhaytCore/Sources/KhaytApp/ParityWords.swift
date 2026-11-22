import Foundation

/// The words the desktop-parity reports added (`ParityReportCards`, the VAT
/// card's box-form return), merged into `Words.own`.
///
/// Almost every word on those screens is the other app's own, borrowed
/// (`Words.borrowed`); these are the two it never needed. A table of its own
/// for the reason `ReviewWords` gives. The other seven languages are in
/// `mac-words-<code>.json`.
enum ParityWords {
    nonisolated static let table: [String: [String: String]] = [
        "mac.vat_return_print_hint": ["en": "The box-form return for a period, to copy onto the return you file. Print it, or save it as a PDF from the print panel.",
                                      "ar": "إقرار الخانات لفترة ما، لتنقله إلى الإقرار الذي تقدّمه. اطبعه، أو احفظه PDF من نافذة الطباعة."],
        "mac.filament_net_note": ["en": "Revenue is what each job earned, net of VAT, split across its filaments by their share of its cost.",
                                  "ar": "الإيراد هو ما حققه كل عمل بعد خصم ضريبة القيمة المضافة، موزّعًا على خيوطه بحسب حصتها من تكلفته."],
    ]
}
