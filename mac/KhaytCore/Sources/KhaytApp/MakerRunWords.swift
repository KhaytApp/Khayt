import Foundation

/// The words the MakerRun tab, the colour planner and the 3D viewer added,
/// merged into `Words.own`. Almost every word on the MakerRun and planner
/// screens is the desktop's own (`mr.*`, `plan.*`, `view3d.*`, borrowed);
/// these are the few the Mac needs that the desktop never did — chiefly the
/// connection code, because the desktop links by `bedready://` and this app
/// does not claim that scheme. The other seven languages are in
/// `mac-words-<code>.json`.
enum MakerRunWords {
    nonisolated static let table: [String: [String: String]] = [
        // ── MakerRun ──────────────────────────────────────────────────────
        "mac.st_makerrun": ["en": "MakerRun", "ar": "منصة MakerRun"],
        "mac.mkr_account": ["en": "MakerRun account", "ar": "حساب MakerRun"],
        "mac.mkr_linked": ["en": "This Mac is connected to MakerRun.", "ar": "هذا الماك متصل بـ MakerRun."],
        "mac.mkr_not_linked": ["en": "Not connected. Browsing needs no account; downloading and publishing do.", "ar": "غير متصل. التصفح لا يحتاج حسابًا، أما التنزيل والنشر فيحتاجان إليه."],
        "mac.mkr_code_hint": ["en": "On makerrun.com/app-link, sign in, choose Copy code, and paste the code here.", "ar": "في makerrun.com/app-link سجّل الدخول، واختر نسخ الرمز، ثم الصقه هنا."],
        "mac.mkr_open_link_page": ["en": "Open the Connect Page", "ar": "فتح صفحة الربط"],
        "mac.mkr_code": ["en": "Connection code", "ar": "رمز الربط"],
        "mac.mkr_link": ["en": "Connect", "ar": "ربط"],
        "mac.mkr_linking": ["en": "Connecting", "ar": "يجري الربط"],
        "mac.mkr_unlink": ["en": "Disconnect", "ar": "إلغاء الربط"],
        "mac.mkr_unlink_q": ["en": "Disconnect this Mac from MakerRun?", "ar": "إلغاء ربط هذا الماك بـ MakerRun؟"],
        "mac.mkr_unlink_body": ["en": "Downloading and publishing will need the code again. Nothing in the library changes.", "ar": "سيحتاج التنزيل والنشر إلى الرمز من جديد. لا يتغير شيء في المكتبة."],
        "mac.mkr_listing_print": ["en": "This listing sells finished prints; order one on makerrun.com.", "ar": "يبيع هذا الإدراج مطبوعات جاهزة؛ اطلبها من makerrun.com."],
        "mac.mkr_downloads": ["en": "Downloads: {n}", "ar": "التنزيلات: {n}"],
        "mac.mkr_cover_ai": ["en": "Cover made with AI", "ar": "صورة الغلاف مُنشأة بالذكاء الاصطناعي"],
        "mac.mkr_not_here": ["en": "The model file is not on this Mac, so it cannot be published from here.", "ar": "ملف النموذج ليس على هذا الماك، فلا يمكن نشره من هنا."],
        "mac.mkr_show_model": ["en": "Show in Library", "ar": "عرض في المكتبة"],
        "mac.mkr_publish": ["en": "Publish to MakerRun…", "ar": "النشر على MakerRun…"],
        "mac.mkr_on_makerrun": ["en": "On MakerRun…", "ar": "على MakerRun…"],
        "mac.mkr_rate_publish": ["en": "MakerRun allows 20 new listings an hour and 60 a day, and this account has reached that. Nothing was lost: finish this listing later.", "ar": "يسمح MakerRun بعشرين إدراجًا جديدًا في الساعة وستين في اليوم، وقد بلغ هذا الحساب الحد. لم يضِع شيء: أكمل هذا الإدراج لاحقًا."],
        "mac.mkr_field_refused": ["en": "{field}: {message}", "ar": "{field}: {message}"],
        "mac.mkr_choose": ["en": "Choose a design to see its files.", "ar": "اختر تصميمًا لعرض ملفاته."],

        // ── The colour planner ────────────────────────────────────────────
        "mac.cpl_open": ["en": "Plan Colours…", "ar": "تخطيط الألوان…"],
        "mac.cpl_save": ["en": "Save Plan", "ar": "حفظ الخطة"],
        "mac.cpl_used_by": ["en": "The calculator and Quote This Model cost this model with the spools saved here.", "ar": "تحسب الآلة الحاسبة وتسعير هذا النموذج التكلفة بالبكرات المحفوظة هنا."],
        "mac.cpl_good": ["en": "Close match", "ar": "تطابق قريب"],
        "mac.cpl_ok": ["en": "Fair match", "ar": "تطابق مقبول"],
        "mac.cpl_far": ["en": "Far from this colour", "ar": "بعيد عن هذا اللون"],
        "mac.cpl_slot": ["en": "Slot {n}", "ar": "الخانة {n}"],

        // ── The 3D viewer ─────────────────────────────────────────────────
        "mac.v3d_pictures": ["en": "Pictures", "ar": "صور"],
        "mac.v3d_orbit": ["en": "3D", "ar": "ثلاثي الأبعاد"],
        "mac.v3d_colours": ["en": "Colours", "ar": "الألوان"],
        "mac.v3d_reset": ["en": "Reset View", "ar": "إعادة ضبط العرض"],
        "mac.v3d_help": ["en": "Drag to orbit, scroll or pinch to zoom, and Option-drag to pan.", "ar": "اسحب للدوران، ومرّر أو اقرص للتكبير، واسحب مع Option للتحريك."],
        "mac.v3d_reading": ["en": "Reading the model", "ar": "يُقرأ النموذج"],
        "mac.v3d_sampled": ["en": "Showing {shown} of {total} triangles.", "ar": "يُعرض {shown} من {total} مثلث."],
        "mac.v3d_too_big": ["en": "This model is too large to show in 3D.", "ar": "هذا النموذج أكبر من أن يُعرض بثلاثة أبعاد."],
        "mac.v3d_failed": ["en": "This model could not be shown in 3D.", "ar": "تعذّر عرض هذا النموذج بثلاثة أبعاد."],
    ]
}
