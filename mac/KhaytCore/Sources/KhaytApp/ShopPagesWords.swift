import Foundation

/// The words the Nov 2026 parity batch added (environment log, closure dates,
/// the satisfaction card, customer reviews), merged into `Words.own`.
///
/// A table of its own, as `ReviewWords` is, so parallel branches adding words
/// do not collide at the foot of `Words.base`. Everything the desktop already
/// had a key for — `envLogs`, `env.*`, `set.holidays`, `set.ai_spend*`,
/// `cloud.slug_*`, `store.review*`, `store.ins_*` — is the desktop's key, in
/// all nine languages, and is not repeated here.
enum ShopPagesWords {
    nonisolated static let table: [String: [String: String]] = [
        // ── The environment log (`EnvironmentLogSection`) ─────────────────
        "mac.env_hint": ["en": "Damp filament and a cold room cause failed prints. A reading a day shows when the workshop drifts.",
                         "ar": "الخيط الرطب والغرفة الباردة يسببان فشل الطباعة. قراءة واحدة يوميًا تُظهر متى تتغير أجواء الورشة."],
        "mac.env_temp": ["en": "Temperature (°C)", "ar": "درجة الحرارة (°م)"],
        "mac.env_humidity": ["en": "Humidity (%)", "ar": "الرطوبة (%)"],
        "mac.env_machine": ["en": "Machine", "ar": "الطابعة"],
        "mac.env_room": ["en": "Whole workshop", "ar": "الورشة كلها"],
        "mac.env_notes": ["en": "Notes", "ar": "ملاحظات"],
        "mac.env_none": ["en": "No readings yet. Log the workshop’s temperature and humidity to see how they move.",
                         "ar": "لا قراءات بعد. سجّل درجة حرارة الورشة ورطوبتها لترى كيف تتغيران."],
        "mac.env_trend": ["en": "Temperature over the recent readings", "ar": "درجة الحرارة في القراءات الأخيرة"],
        "mac.env_delete_q": ["en": "Delete this reading?", "ar": "حذف هذه القراءة؟"],

        // ── Closure dates (`HolidaysSection`) ──────────────────────────────
        "mac.holidays_none": ["en": "No closure dates.", "ar": "لا أيام إغلاق."],
        "mac.holidays_hint": ["en": "Days the shop is closed. Khayt skips them when it counts the printing hours left before a due date.",
                              "ar": "الأيام التي يُغلق فيها المحل. يتخطاها خيط عند حساب ساعات الطباعة المتبقية قبل موعد التسليم."],

        // ── The satisfaction card (`SurveySummaryCard`) ────────────────────
        "mac.sv_avg": ["en": "Average rating", "ar": "متوسط التقييم"],
        "mac.sv_nps": ["en": "NPS", "ar": "صافي نقاط الترويج"],
        "mac.sv_responses": ["en": "Responses", "ar": "الردود"],
        "mac.sv_nps_hint": ["en": "Every rating your customers have given. For the NPS, five stars counts as a promoter, four as passive and three or fewer as a detractor.",
                            "ar": "كل تقييم قدّمه عملاؤك. في صافي نقاط الترويج، تُحسب الخمس نجوم مروّجًا، والأربع محايدًا، والثلاث فأقل منتقدًا."],

        // ── Customer reviews (`CustomerReviewsSection`) ────────────────────
        "mac.rv_owner_only": ["en": "Only the shop’s owner can read the reviews one by one and remove them.",
                              "ar": "مالك المحل وحده يستطيع قراءة المراجعات واحدة واحدة وحذفها."],
    ]
}
