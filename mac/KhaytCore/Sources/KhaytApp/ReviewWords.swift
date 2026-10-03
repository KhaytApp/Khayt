import Foundation

/// The words the alpha.58 UI review added, merged into `Words.own`.
///
/// A table of its own rather than more lines in `Words.base`: several branches
/// add words at once, every one of them at the foot of the same literal, and
/// a dictionary literal TRAPS on a repeated key (`DuplicateWordKeyTests`).
/// `Words.own` merges this with `base` winning, and `ReviewWordsTests` holds
/// that none of these keys is also in `base` — where it would be silently
/// shadowed rather than trap.
enum ReviewWords {
    nonisolated static let alpha58: [String: [String: String]] = [
        // ── Closing what sync took (`SyncLossBanner`) ─────────────────────
        "mac.losses_dismiss_q": ["en": "Close without putting them back?",
                                 "ar": "إغلاق دون إعادتها؟"],
        "mac.losses_dismiss_body": ["en": "{n} records sync took have not been put back. Their copies stay in the sync-conflicts folder beside your backups, but this notice will not come back.",
                                    "ar": "لم يُعَد {n} من السجلات التي أخذتها المزامنة. تبقى نسخها في مجلد sync-conflicts بجانب النسخ الاحتياطية، لكن هذا التنبيه لن يعود."],
        "mac.losses_dismiss": ["en": "Close Notice", "ar": "إغلاق التنبيه"],
        "mac.losses_review_unsaved": ["en": "Closed, but this Mac could not remember that — the notice will come back on the next launch:",
                                      "ar": "أُغلق، لكن تعذّر على هذا الماك تذكّر ذلك — سيعود التنبيه عند التشغيل التالي:"],

        // ── What an import did with the originals ─────────────────────────
        "mac.import_trashed": ["en": "{n} originals moved to the Trash.",
                               "ar": "نُقل {n} من الملفات الأصلية إلى سلة المهملات."],
        "mac.import_trashed_one": ["en": "{n} original moved to the Trash.",
                                   "ar": "نُقل ملف أصلي واحد إلى سلة المهملات."],
        "mac.import_trashed_two": ["en": "{n} originals moved to the Trash.",
                                   "ar": "نُقل ملفان أصليان إلى سلة المهملات."],
        "mac.import_trashed_few": ["en": "{n} originals moved to the Trash.",
                                   "ar": "نُقلت {n} ملفات أصلية إلى سلة المهملات."],

        // ── The spool-size repair: prices that do not move ────────────────
        "mac.spool_repair_same_price": ["en": "{n} more products are re-costed on the new size; their prices stay the same.",
                                        "ar": "{n} منتجًا آخر يُعاد حساب تكلفته على الحجم الجديد، وتبقى أسعارها كما هي."],
        "mac.spool_repair_same_price_one": ["en": "{n} more product is re-costed on the new size; its price stays the same.",
                                            "ar": "منتج واحد آخر يُعاد حساب تكلفته على الحجم الجديد، ويبقى سعره كما هو."],
        "mac.spool_repair_same_price_two": ["en": "{n} more products are re-costed on the new size; their prices stay the same.",
                                            "ar": "منتجان آخران يُعاد حساب تكلفتهما على الحجم الجديد، ويبقى سعرهما كما هو."],
        "mac.spool_repair_same_price_few": ["en": "{n} more products are re-costed on the new size; their prices stay the same.",
                                            "ar": "{n} منتجات أخرى يُعاد حساب تكلفتها على الحجم الجديد، وتبقى أسعارها كما هي."],
        "mac.spool_repair_apply_costs": ["en": "Update Costs", "ar": "تحديث التكاليف"],

        // ── A cloud that went backwards ───────────────────────────────────
        "mac.cloud_went_backwards": ["en": "Khayt Cloud answered with revision {got}, but this Mac has already seen revision {seen} for this shop. A cloud does not go backwards on its own, so nothing from it was applied. If you reset or restored the cloud yourself, choose \u{201C}Trust the cloud\u{2019}s older copy\u{201D} to carry on from it.",
                                     "ar": "ردّت سحابة خيط بالمراجعة {got}، لكن هذا الماك رأى من قبل المراجعة {seen} لهذا المتجر. لا تعود السحابة إلى الوراء من تلقاء نفسها، لذا لم يُطبَّق منها شيء. إن كنت أعدت ضبط السحابة أو استعدتها بنفسك، فاختر «اعتمد النسخة الأقدم في السحابة» للمتابعة منها."],
        "mac.cloud_went_backwards_banner": ["en": "Sync stopped: Khayt Cloud answered with an older copy (revision {got}) than this Mac has already seen ({seen}). Nothing from it was applied.",
                                            "ar": "توقفت المزامنة: ردّت سحابة خيط بنسخة أقدم (المراجعة {got}) مما رآه هذا الماك من قبل ({seen}). لم يُطبَّق منها شيء."],
        "mac.cloud_accept_rollback_q": ["en": "Carry on from the cloud\u{2019}s older copy?",
                                        "ar": "المتابعة من النسخة الأقدم في السحابة؟"],
        "mac.cloud_accept_rollback_body": ["en": "Only if you reset or restored Khayt Cloud yourself. This Mac then syncs with that copy straight away.",
                                           "ar": "فقط إن كنت أعدت ضبط سحابة خيط أو استعدتها بنفسك. بعدها يزامن هذا الماك مع تلك النسخة فورًا."],
        "mac.cloud_rollback_accepted": ["en": "Carrying on from the cloud\u{2019}s older copy \u{2014} syncing now.",
                                        "ar": "المتابعة من النسخة الأقدم في السحابة — تجري المزامنة الآن."],

        // ── Why an action is off ──────────────────────────────────────────
        "mac.sample_read_only": ["en": "This is the sample shop, for looking around. Open your own book to add to it.",
                                 "ar": "هذا متجر تجريبي للاطلاع فقط. افتح دفترك لتضيف إليه."],

        // ── The strip, in title case ──────────────────────────────────────
        // Khayt's own `mach.add` is "+ Add Printer", plus sign and all; the
        // strip draws its own plus, so it says the action in words of its own.
        "mac.add_printer": ["en": "Add Printer", "ar": "إضافة طابعة"],

        // ── Arabic counts its units (`Words.countedUnit`) ─────────────────
        // `_two` is the dual, said without a numeral; `_few` is the plural
        // that three to ten take. English never reads either.
        "mac.unit_each_two":   ["en": "each",    "ar": "حبتان"],
        "mac.unit_each_few":   ["en": "each",    "ar": "حبات"],
        "mac.unit_piece_two":  ["en": "pcs",     "ar": "قطعتان"],
        "mac.unit_piece_few":  ["en": "pcs",     "ar": "قطع"],
        "mac.unit_roll_two":   ["en": "rolls",   "ar": "لفتان"],
        "mac.unit_roll_few":   ["en": "rolls",   "ar": "لفات"],
        "mac.unit_box_two":    ["en": "boxes",   "ar": "علبتان"],
        "mac.unit_box_few":    ["en": "boxes",   "ar": "علب"],
        "mac.unit_bag_two":    ["en": "bags",    "ar": "كيسان"],
        "mac.unit_bag_few":    ["en": "bags",    "ar": "أكياس"],
        "mac.unit_pack_two":   ["en": "packs",   "ar": "عبوتان"],
        "mac.unit_pack_few":   ["en": "packs",   "ar": "عبوات"],
        "mac.unit_pair_two":   ["en": "pairs",   "ar": "زوجان"],
        "mac.unit_pair_few":   ["en": "pairs",   "ar": "أزواج"],
        "mac.unit_bottle_two": ["en": "bottles", "ar": "زجاجتان"],
        "mac.unit_bottle_few": ["en": "bottles", "ar": "زجاجات"],
        "mac.unit_spool_two":  ["en": "spools",  "ar": "بكرتان"],
        "mac.unit_spool_few":  ["en": "spools",  "ar": "بكرات"],
        "mac.unit_sheet_two":  ["en": "sheets",  "ar": "لوحان"],
        "mac.unit_sheet_few":  ["en": "sheets",  "ar": "ألواح"],
    ]
}
