import Foundation

/// The words slice-and-send and the converter sheet added, merged into
/// `Words.own` (`Shop+PrintPrep.swift`, `SendToPrinterSheet`, `ConvertSheet`).
///
/// A table of its own for the reason `ReviewWords` gives: several branches add
/// words at once, and a dictionary literal TRAPS on a repeated key. Most of
/// what the converter says is the desktop's own (`conv.*`, `slicer.*`),
/// borrowed from the shared catalogue in all nine languages; these are only
/// the lines the desktop never needed. The other seven languages are in
/// `mac-words-<code>.json`.
enum PrintPrepWords {
    nonisolated static let table: [String: [String: String]] = [
        "mac.send_will_slice": ["en": "This is a model. Khayt slices it with {name} first, then sends the G-code.",
                                "ar": "هذا نموذج. سيقطّعه خيط باستخدام {name} أولًا، ثم يرسل ملف G-code."],
        "mac.slice_send_only": ["en": "Slice and send", "ar": "قطّع وأرسل"],
        "mac.send_choose_hint_model": ["en": "Choose a sliced file, or a model to slice first.",
                                       "ar": "اختر ملفًا مُقطّعًا، أو نموذجًا لتقطيعه أولًا."],
        "mac.cv_colour_plan": ["en": "Colours", "ar": "الألوان"],
        "mac.cv_plan_slots": ["en": "Slot by slot", "ar": "خانة بخانة"],
        "mac.cv_plan_fs": ["en": "Full Spectrum", "ar": "الطيف الكامل"],
        "mac.cv_plan_band": ["en": "Band-swap", "ar": "تبديل النطاقات"],
        "mac.cv_fit_unknown": ["en": "This model has not been measured yet, so its fit on the bed is not checked.",
                               "ar": "لم يُقَس هذا النموذج بعد، لذا لم يُتحقَّق من ملاءمته لسطح الطباعة."],
    ]
}
