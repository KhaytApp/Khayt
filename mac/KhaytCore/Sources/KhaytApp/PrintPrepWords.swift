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
        "mac.cv_split": ["en": "Split into plates (one file each)", "ar": "قسّم إلى ألواح (ملف لكل لوح)"],
        "mac.cv_split_note": ["en": "{n} plates, one file each. Each file carries only the colours its plate prints with, from slot 1. A plate with more colours than {t} has slots is merged to the nearest.", "ar": "{n} ألواح، ملف لكل لوح. يحمل كل ملف الألوان التي يطبع بها لوحه فقط، بدءًا من الخانة 1. اللوح الذي يحتاج ألوانًا أكثر من خانات {t} تُدمج ألوانه في الأقرب."],
        "mac.cv_split_folder": ["en": "Choose a folder for the plate files.", "ar": "اختر مجلدًا لملفات الألواح."],
        "mac.cv_split_done": ["en": "{ok} of {n} plates saved to {folder}.", "ar": "حُفظ {ok} من {n} ألواح في {folder}."],
        "mac.cv_split_failed": ["en": "Plate {n}: {why}", "ar": "اللوح {n}: {why}"],
        "mac.cv_keep_tower": ["en": "Keep the prime tower (drop variable layer height)", "ar": "أبقِ برج التنظيف (واحذف ارتفاع الطبقة المتغيّر)"],
        "mac.cv_keep_tower_note": ["en": "Snapmaker Orca cannot slice variable layer height with a prime tower. Off, the tower is turned off. On, the tower stays and the variable layer height is removed; height ranges keep their filament changes.", "ar": "لا يستطيع Snapmaker Orca تقطيع ارتفاع طبقة متغيّر مع برج تنظيف. عند الإيقاف يُطفأ البرج. عند التشغيل يبقى البرج ويُحذف ارتفاع الطبقة المتغيّر، وتحتفظ نطاقات الارتفاع بتبديلات الخيوط."],
    ]
}
