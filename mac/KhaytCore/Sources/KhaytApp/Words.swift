import Foundation
import Observation
import SwiftUI
import KhaytCore

/// What the app calls things.
///
/// Two catalogues, in this order, and the order is the point.
///
/// **Khayt's own translations first.** `renderer/locales/*.js` is bundled and
/// run, so a stage this app calls "قيد الطباعة" is called that because the
/// Electron app calls it that. An app that invents its own word for "Owed" has
/// given one shop two vocabularies, and the person reading the second one has to
/// work out that it means the first.
///
/// **This app's own catalogue second**, for the handful of things Khayt has
/// never needed a word for — "Opened read-only", "On this Mac". They are kept
/// here rather than added to the shared locale files because that catalogue is
/// nine languages wide and guarded for completeness: adding a key there means
/// adding it in nine, and an English value sitting in `ar.js` is precisely the
/// failure `test/locale-quality.test.js` exists to catch.
@MainActor @Observable
final class Words {
    private(set) var language = "en"
    private var khayt: [String: String] = [:]

    /// Arabic reads right to left. This is a LAYOUT property, not a translation:
    /// it moves the sidebar, flips every leading/trailing edge, and reverses the
    /// table's column order.
    var isRTL: Bool { language == "ar" }

    /// Mirroring is NOT done from here — see `Direction`.
    ///
    /// `.environment(\\.layoutDirection, .rightToLeft)` on the window loops
    /// SwiftUI's `NavigationSplitView` until AppKit aborts, so the writing
    /// direction is set the way AppKit has always done it, before the app
    /// starts. This value is kept for views that need to ask, and for the tests.
    var layout: LayoutDirection { isRTL ? .rightToLeft : .leftToRight }

    /// Which languages this app has words for. English is the fallback and Arabic
    /// is the one that changes the layout; the other seven are a matter of
    /// bundling more files, not of new machinery.
    nonisolated static let supported = ["en", "ar"]

    init() {
        if let warm = Self.warm {
            language = warm.language
            khayt = warm.strings
        }
    }

    func load(_ wanted: String?, engine: KhaytEngine?) async {
        let lang = Self.supported.contains(wanted ?? "") ? wanted! : "en"
        language = lang
        khayt = (try? await engine?.translations(language: lang)) ?? [:]
    }

    /// The catalogue, read before AppKit starts.
    ///
    /// ── WHY THIS EXISTS, AND IT IS NOT AN OPTIMISATION ─────────────────────
    /// A SwiftUI menu item's TITLE is baked when the menu bar is built and is
    /// never rewritten. Not when the value behind it changes, not when the menu
    /// is about to open, not after `NSMenu.update()`. Verified three ways: with
    /// the items in a plain `View` (the fix the forums give for the enabled
    /// state, which does work for that), with the model injected through the
    /// environment as the forum thread shows, and by calling `update()` on every
    /// submenu before reading the titles back. All three still read the value
    /// from build time.
    ///
    /// The menu bar is built as the scene is created, and the book — with the
    /// shop's language in it — is opened afterwards, asynchronously. So every
    /// stage in the Job menu read `queue.quote`, `queue.pending`: the key
    /// itself, which is exactly what a missing translation looks like.
    ///
    /// `Direction` already resolves the language before launch, from the store
    /// on disk, because the writing direction has the same problem. This does
    /// the same for the words. It costs one engine start at launch, which the
    /// app pays for anyway a moment later.
    ///
    /// A book opened LATER in a different language still updates everything
    /// except the menu titles. Changing the language is already a restart —
    /// `Direction.settle()` says so — and this is one more reason.
    /// `nonisolated(unsafe)` because it is written exactly once, before AppKit
    /// starts and before any other thread exists to read it, and only read
    /// afterwards. There is nothing to race with.
    nonisolated(unsafe) private(set) static var warm: (language: String, strings: [String: String])?

    nonisolated static func preload(_ wanted: String) {
        let lang = supported.contains(wanted) ? wanted : "en"
        guard let engine = try? KhaytEngine(),
              let strings = try? engineTranslations(engine, lang) else { return }
        warm = (lang, strings)
    }

    /// `KhaytEngine` is an actor and this runs before there is a run loop to
    /// await on, so the hop is made explicitly and waited for.
    ///
    /// `Task.detached`, NOT `Task` — this type is `@MainActor`, so a plain
    /// `Task` inherits the main actor, and the main thread is the one sitting in
    /// `wait()`. The app launched to a window that never appeared until it was
    /// killed. A detached task inherits no isolation and runs while the main
    /// thread is blocked, which is the whole point of blocking it.
    private nonisolated static func engineTranslations(_ engine: KhaytEngine,
                                                       _ lang: String) throws -> [String: String] {
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        Task.detached {
            do { box.strings = try await engine.translations(language: lang) }
            catch { box.failure = error }
            done.signal()
        }
        done.wait()
        if let failure = box.failure { throw failure }
        return box.strings
    }

    /// Somewhere for the detached task to put its answer. Written once before
    /// the semaphore is signalled and read once after it is waited on, which is
    /// the ordering `@unchecked` is standing on.
    private final class Box: @unchecked Sendable {
        var strings: [String: String] = [:]
        var failure: Error?
    }

    /// Khayt's word, then this app's, then the key — which is visible enough on
    /// screen to be reported rather than quietly reading as a label.
    func callIt(_ key: String) -> String {
        if let theirs = khayt[key], !theirs.isEmpty { return theirs }
        if let mine = Self.own[key]?[language] ?? Self.own[key]?["en"] { return mine }
        return key
    }

    /// One of a thing, or several.
    ///
    /// Two keys rather than an "(s)": Khayt writes `{n} order(s)` in English
    /// and `{n} طلب` in Arabic, which works because that string is one
    /// sentence. These are a COUNT and a NOUN assembled by the window, and
    /// "1 machines" is what assembling them without asking gives you.
    func counting(_ n: Int, _ key: String) -> String {
        // ── ARABIC COUNTS TWO OF A THING DIFFERENTLY ──────────────────────
        //
        // Arabic has a DUAL: not a plural of two, a form of its own, and the
        // numeral is not said with it. "Two days" is `يومين`, not `2 أيام` —
        // which is what this returned, and which reads to an Arabic speaker
        // the way "2 dayses" reads in English.
        //
        // Only where the word has been given a `_two`. Every key without one
        // behaves exactly as before, so this cannot quietly change a string
        // nobody has looked at — and the nine counted strings in this app can
        // be corrected one at a time by somebody who speaks the language.
        //
        // The dual carries no numeral because the form already says "two".
        // Writing `2 يومين` says it twice.
        if language == "ar", n == 2, let dual = Self.own[key + "_two"]?["ar"], !dual.isEmpty {
            return dual
        }
        return "\(n) " + callIt(n == 1 ? key + "_one" : key)
    }

    /// The same, with the placeholders filled.
    ///
    /// Khayt's strings carry `{name}` placeholders and `renderer/i18n.js`
    /// replaces every occurrence of each. Matched here rather than approximated,
    /// because a string that comes back still saying `{days}` is worse than one
    /// that says nothing.
    /// A word, or something sensible when neither locale has the key.
    ///
    /// ── `callIt(k)` DOES NOT FALL BACK, AND LOOKS LIKE IT DOES ────────────
    ///
    /// A missing key comes back as the KEY — "pe.kind_render" on screen, in a
    /// menu, in front of a customer. So the idiomatic-looking
    /// `callIt(k) != "" ? callIt(k) : mine` is always the first branch and
    /// never falls back, which is the same shape as the renderer's
    /// `t('k') || 'Fallback'` bug.
    ///
    /// It matters here because some words come from `lib/`. The picture kinds
    /// carry their own English labels, and a shop running a locale that has not
    /// been given `pe.kind_*` should read "Actual print" rather than the key
    /// that would have produced it.
    func callIt(_ key: String, fallback: String) -> String {
        let said = callIt(key)
        return said == key ? fallback : said
    }

    func callIt(_ key: String, _ params: [String: JSONValue]) -> String {
        var out = callIt(key)
        for (name, value) in params {
            out = out.replacingOccurrences(of: "{\(name)}", with: Self.plain(value))
        }
        return out
    }

    /// A parameter as the renderer's `String(vars[k])` would render it —
    /// including a whole number staying whole, which `"\(Double)"` does not do.
    static func plain(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n):
            return n == n.rounded() && abs(n) < 1e15
                ? String(Int(n))
                : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array, .object:
            let data = (try? JSONEncoder().encode(value)) ?? Data()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    /// What a notice from the shared rules says, in the shop's language.
    ///
    /// The codes come from `lib/order-status.js` and `lib/order-deduction.js`;
    /// the strings are Khayt's own, so a spool running low says the same
    /// sentence here that it says there.
    func sentence(for notice: Notice) -> String {
        let key: String
        switch notice.code {
        case "due_extended":           key = "ord.due_extended"
        case "filament_deducted":      key = "inv.deducted_summary"
        case "filament_deducted_low":  key = "inv.deducted_summary_low"
        case "packaging_deducted":     key = "cons.packaging_deducted"
        case "consumable_low", "packaging_low":
            return callIt("cons.low") + ": " + Self.plain(notice.params["name"] ?? .string(""))
        default:
            // A code nobody has a sentence for is shown as the code. It reads as
            // wrong, which is the point — a notice that renders as nothing is a
            // notice that was never delivered.
            return notice.code
        }
        return callIt(key, notice.params)
    }

    /// Why the rules refused a move.
    func gateRefusal(_ gate: StatusGate) -> String {
        guard let block = gate.block else { return callIt("mac.move_refused") }
        switch block.code {
        case "production_paused":       return callIt("prod.paused_block")
        case "wip_blocked":             return callIt("wip.limit_blocked", block.params)
        case "assembly_not_assembled":  return callIt("asm.gate_not_assembled")
        case "assembly_parts":          return callIt("asm.gate_parts", block.params)
        default:                        return block.code
        }
    }

    /// Why no ZATCA QR was drawn.
    ///
    /// It names the fields, because "not compliant" tells a shop nothing and
    /// "no VAT registration number" tells them what to go and type.
    func zatcaRefusal(_ reason: StatusGate.Reason) -> String {
        guard case .array(let missing)? = reason.params["missing"] else {
            return callIt("inv.qr_failed")
        }
        return missing.compactMap { if case .string(let key) = $0 { return callIt(key) } else { return nil } }
            .joined(separator: " · ")
    }

    /// Why this app will not make a move that has to reach somebody.
    ///
    /// It names the channels rather than saying "an integration", because
    /// "this sends a Telegram message" tells a shop owner what to do next and
    /// "an integration is configured" does not.
    func outboundRefusal(_ reaches: [Outbound]) -> String {
        let named = reaches.map { callIt("mac.reach_" + $0.channel) }
        let list = named.joined(separator: named.count == 2 ? " " + callIt("mac.and") + " " : "، ")
        return callIt("mac.move_reaches") + " " + list + ". " + callIt("mac.move_in_khayt")
    }

    /// A word needed before there is a `Words` to ask.
    ///
    /// The menu bar's own titles — Book, Go, Job, Model — are built with the
    /// scene, before any book is open, and like every other menu title they are
    /// never rewritten. `warm` is already in hand by then, so they can be said
    /// in the shop's language instead of always in English.
    nonisolated static func upfront(_ key: String) -> String {
        if let theirs = warm?.strings[key], !theirs.isEmpty { return theirs }
        let lang = warm?.language ?? "en"
        if let mine = own[key]?[lang] ?? own[key]?["en"] { return mine }
        return key
    }

    /// The words this app needed and Khayt did not have.
    ///
    /// Every entry carries both languages. A key with only English is worse than
    /// no key at all: it reads as a translation that happens to look English, and
    /// nothing tells anyone it is missing.
    /// The Mac's own words.
    ///
    /// `PrintFactLines.ownWords` is MERGED IN rather than copied: the Quick Look
    /// preview shows the same facts from a separate bundle and needs the same
    /// words, and two literals would agree today and drift by the third change.
    nonisolated static let own: [String: [String: String]] =
        base.merging(PrintFactLines.ownWords) { mine, _ in mine }

    private nonisolated static let base: [String: [String: String]] = [
        // Shelves
        "mac.all_jobs":      ["en": "All jobs",      "ar": "كل الأعمال"],
        "mac.pipeline":      ["en": "Pipeline",      "ar": "المسار"],
        "mac.board":         ["en": "Board",         "ar": "اللوح"],
        "mac.nothing_here":  ["en": "nothing here",  "ar": "لا شيء هنا"],
        "mac.no_jobs":       ["en": "No jobs yet",   "ar": "لا أعمال بعد"],
        // Needs attention — what is wrong, and the button that goes to it
        "mac.attn_go_machine": ["en": "Open printer",  "ar": "افتح الطابعة"],
        "mac.attn_go_nozzle":  ["en": "Replace",       "ar": "استبدل"],
        "mac.attn_go_stock":   ["en": "Order more",    "ar": "اطلب المزيد"],
        "mac.attn_go_job":     ["en": "Open job",      "ar": "افتح العمل"],
        "mac.attn_state_offline": ["en": "not answering", "ar": "لا تجيب"],
        "mac.attn_state_error":   ["en": "reporting a fault", "ar": "تبلّغ عن عطل"],
        "mac.attn_nozzle_of":  ["en": "past {n} g",    "ar": "تجاوزت {n} غ"],
        "mac.attn_more":       ["en": "and {n} more",  "ar": "و{n} أخرى"],
        "mac.attn_see_all":    ["en": "See all",       "ar": "اعرض الكل"],
        "mac.fleet_offline": ["en": "{n} not answering", "ar": "{n} لا تجيب"],
        // The band: the next two days on the machines
        "mac.band_title":    ["en": "The next 48 hours",  "ar": "الـ 48 ساعة القادمة"],
        "mac.band_sub":      ["en": "now → {hours} hours ahead · one mark = 6 h",
                              "ar": "من الآن إلى {hours} ساعة · كل علامة 6 ساعات"],
        // Said ONLY when a machine cannot be asked, so it reads as news rather
        // than as a permanent disclaimer nobody sees any more.
        "mac.band_over":     ["en": "over {counted} of your machines — {silent} not answering",
                              "ar": "على {counted} من طابعاتك — {silent} لا تجيب"],
        // When NONE of them can be timed the band has nothing to draw, so it is
        // not drawn: one line saying what is missing beats three empty lanes and
        // a legend for marks that do not appear.
        "mac.band_free_across": ["en": "{hours} free across {n} machines",
                                 "ar": "{hours} متفرغة على {n} طابعات"],
        "mac.band_none":     ["en": "Khayt cannot time any of these printers yet",
                              "ar": "لا يستطيع خيط تقدير أي من هذه الطابعات بعد"],
        "mac.band_none_why": ["en": "Connect a printer and the next 48 hours fill themselves in — what is running, when each machine comes free, and what is waiting on filament.",
                              "ar": "اربط طابعة وتمتلئ الـ 48 ساعة القادمة من تلقاء نفسها — ما يعمل، ومتى تتفرغ كل طابعة، وما ينتظر خيطاً."],
        "mac.band_unknown":  ["en": "no estimate",   "ar": "لا تقدير"],
        "mac.band_cannot_ask": ["en": "printing something Khayt cannot time — nothing here is a guess",
                                "ar": "تطبع شيئاً لا يستطيع خيط تقديره — ولا شيء هنا تخمين"],
        "mac.band_free_in":  ["en": "free in {hours} h",  "ar": "متفرغة خلال {hours} ساعة"],
        // A machine Khayt has no protocol for is not a machine that has stopped
        // answering, and the two must not read the same.
        "mac.band_no_protocol": ["en": "Khayt has no way to ask this kind of machine what it is doing — it is not a fault",
                                 "ar": "لا يملك خيط طريقة لسؤال هذا النوع من الأجهزة عمّا يفعله — وليس هذا عطلاً"],
        "mac.band_not_asked":   ["en": "not asked",  "ar": "لا يُسأل"],
        // Machine kinds
        "mach.kind":         ["en": "Kind",  "ar": "النوع"],
        "mach.kind_fdm":     ["en": "Filament printer", "ar": "طابعة خيط"],
        "mach.kind_resin":   ["en": "Resin printer",    "ar": "طابعة راتنج"],
        "mach.kind_uv":      ["en": "UV flatbed",       "ar": "طابعة UV مسطحة"],
        "mach.kind_laser":   ["en": "Laser cutter",     "ar": "قاطعة ليزر"],
        "mach.kind_cnc":     ["en": "CNC router",       "ar": "راوتر CNC"],
        "mach.consumes_filament": ["en": "Filament", "ar": "خيط"],
        "mach.consumes_resin":    ["en": "Resin",    "ar": "راتنج"],
        "mach.consumes_ink":      ["en": "Ink",      "ar": "حبر"],
        "mach.consumes_sheet":    ["en": "Sheet material", "ar": "ألواح"],
        "mach.consumes_stock":    ["en": "Stock",    "ar": "خامة"],
        "mach.wear_nozzle":    ["en": "Nozzle",     "ar": "الفوهة"],
        "mach.wear_fep":       ["en": "FEP film",   "ar": "غشاء FEP"],
        "mach.wear_lcd":       ["en": "LCD screen", "ar": "شاشة LCD"],
        "mach.wear_printhead": ["en": "Printhead",  "ar": "رأس الطباعة"],
        "mach.wear_tube":      ["en": "Laser tube", "ar": "أنبوب الليزر"],
        "mach.wear_lens":      ["en": "Lens",       "ar": "العدسة"],
        "mach.wear_bit":       ["en": "Cutting bit", "ar": "لقمة القطع"],
        // Units an item is counted in, and what a price is quoted per.
        "unit.g":      ["en": "g",      "ar": "غ"],
        // What a price is quoted PER. Singular, and a separate key from the
        // word after a quantity — "6 sheets" but "24.00 / sheet".
        "unit.per_kg":    ["en": "kg",    "ar": "كغ"],
        "unit.per_L":     ["en": "L",     "ar": "لتر"],
        "unit.per_sheet": ["en": "sheet", "ar": "لوح"],
        "inv.unit":    ["en": "Counted in", "ar": "الوحدة"],
        "inv.unit_g":     ["en": "Grams — filament", "ar": "غرامات — خيط"],
        "inv.unit_ml":    ["en": "Millilitres — resin or ink", "ar": "مليلترات — راتنج أو حبر"],
        "inv.unit_sheet": ["en": "Sheets — board or acrylic", "ar": "ألواح — خشب أو أكريليك"],
        "unit.ml":     ["en": "ml",     "ar": "مل"],
        "unit.sheet":  ["en": "sheets", "ar": "لوح"],
        "unit.prints": ["en": "prints", "ar": "طبعة"],
        "unit.h":      ["en": "h",      "ar": "ساعة"],
        "mac.band_printing": ["en": "Printing now",   "ar": "تطبع الآن"],
        "mac.band_queued":   ["en": "Queued — projected", "ar": "في الانتظار — متوقع"],
        "mac.band_blocked":  ["en": "Blocked on stock",  "ar": "متوقف على المخزون"],
        "mac.band_free":     ["en": "free",           "ar": "متفرغة"],
        "mac.band_state_printing": ["en": "Printing", "ar": "تطبع"],
        "mac.band_state_queued":   ["en": "Queued",   "ar": "في الانتظار"],
        "mac.band_state_free":     ["en": "Free",     "ar": "متفرغة"],
        "mac.band_short":    ["en": "{grams} g short of {material}",
                              "ar": "ناقص {grams} غ من {material}"],
        "mac.band_past":     ["en": "runs {hours} past the end of this window",
                              "ar": "يمتد {hours} بعد نهاية هذه النافذة"],
        "mac.band_before":   ["en": "started {hours} before now",
                              "ar": "بدأ قبل {hours} من الآن"],
        // Moving a job
        "mac.move_action":   ["en": "Move Job",       "ar": "نقل العمل"],
        "mac.move_refused":  ["en": "That move was refused.", "ar": "رُفض هذا النقل."],
        "mac.move_gone":     ["en": "That job is no longer in the book.",
                              "ar": "لم يعد هذا العمل في الدفتر."],
        "mac.move_sample":   ["en": "The sample shop cannot be changed.",
                              "ar": "لا يمكن تغيير المحل التجريبي."],
        "mac.move_no_engine": ["en": "The shared rules did not start, so nothing may be moved.",
                               "ar": "لم تبدأ القواعد المشتركة، فلا يمكن نقل شيء."],
        "mac.move_unhandled": ["en": "This move asks for something this app does not know how to do, so nothing was changed.",
                               "ar": "يتطلب هذا النقل أمراً لا يعرفه هذا التطبيق، فلم يتغير شيء."],
        "mac.move_reaches":  ["en": "Finishing this here would skip",
                              "ar": "إنهاء العمل هنا سيتخطى"],
        "mac.move_in_khayt": ["en": "Do it in Khayt so it is sent.",
                              "ar": "نفّذه في خيط ليُرسل."],
        "mac.reach_webhooks":      ["en": "a webhook",        "ar": "إشعار ويب"],
        "mac.reach_event_webhook": ["en": "an order webhook", "ar": "إشعار ويب للطلب"],
        "mac.reach_telegram":      ["en": "a Telegram message", "ar": "رسالة تيليجرام"],
        "mac.reach_email":         ["en": "an email to the customer", "ar": "بريداً للعميل"],
        "mac.reach_portal":        ["en": "the customer's tracking link", "ar": "رابط متابعة العميل"],
        "mac.and":           ["en": "and",            "ar": "و"],
        // The menu bar's own titles, said before any book is open
        "mac.menu_book":     ["en": "Book",           "ar": "الدفتر"],
        "mac.menu_go":       ["en": "Go",             "ar": "انتقال"],
        "mac.menu_job":      ["en": "Job",            "ar": "العمل"],
        "mac.menu_model":    ["en": "Model",          "ar": "المجسم"],
        "mac.reload":        ["en": "Reload from Disk", "ar": "إعادة التحميل من القرص"],
        "mac.favourite":     ["en": "Favourite",      "ar": "مفضّلة"],
        "mac.reveal_in_finder": ["en": "Reveal in Finder", "ar": "إظهار في الباحث"],
        "mac.open_book":     ["en": "Open",           "ar": "فتح دفتر"],
        // Khayt clears a payment from a button with no label of its own.
        "mac.clear_payment": ["en": "Clear payment",  "ar": "مسح الدفعة"],
        "mac.not_finished_yet": ["en": "A job is handed over after it is finished.",
                                 "ar": "يُسلَّم العمل بعد إتمامه."],
        "mac.edit_job":      ["en": "Edit Job",       "ar": "تعديل العمل"],
        "mac.no_due_date":   ["en": "No due date",    "ar": "بلا تاريخ تسليم"],
        "mac.priority_normal": ["en": "Normal",       "ar": "عادي"],
        // Taking a job
        "mac.new_job":       ["en": "New Job",        "ar": "عمل جديد"],
        "mac.what_is_it":    ["en": "What is it?",    "ar": "ما هو؟"],
        "mac.walk_in":       ["en": "No customer",    "ar": "بلا عميل"],
        "mac.a_part":        ["en": "A part",         "ar": "قطعة"],
        "mac.add_part":      ["en": "Add part",       "ar": "إضافة قطعة"],
        "mac.take_the_job":  ["en": "Take the job",   "ar": "استلام العمل"],
        "mac.save_quote":    ["en": "Save as quote",  "ar": "حفظ كعرض سعر"],
        "mac.grams":         ["en": "grams",          "ar": "غرام"],
        "mac.hours":         ["en": "hours",          "ar": "ساعة"],
        // The answers Khayt gives the system when it is asked a question —
        // Siri, Spotlight, Shortcuts. See `Ask.swift`. Khayt's own catalogue
        // rather than the shared one, which knows nothing about intents.
        "mac.no_book":            ["en": "No book on this Mac yet",
                                   "ar": "لا يوجد دفتر على هذا الجهاز بعد"],
        "mac.nothing_printing":   ["en": "Nothing on the beds",
                                   "ar": "لا شيء قيد الطباعة"],
        "mac.printing_count":     ["en": "printing", "ar": "تطبع"],
        "mac.printing_count_one": ["en": "printing", "ar": "تطبع"],
        "mac.nothing_waiting":    ["en": "Nothing waiting", "ar": "لا شيء بانتظار الطباعة"],
        "mac.waiting_count":      ["en": "waiting", "ar": "بانتظار"],
        "mac.waiting_count_one":  ["en": "waiting", "ar": "بانتظار"],
        "mac.without_printer":    ["en": "{n} with no printer yet",
                                   "ar": "{n} بلا طابعة بعد"],
        "mac.job_on_machine":     ["en": "{job} on the {machine}",
                                   "ar": "{job} على {machine}"],
        // The menu bar, which is Mac-only in a way nothing else here is.
        "mac.next_free":          ["en": "next free in", "ar": "أول جهاز يفرغ خلال"],
        "mac.not_connected":      ["en": "No connection set up", "ar": "لا يوجد اتصال"],
        "mac.menu_bar":           ["en": "Show the floor in the menu bar",
                                   "ar": "إظهار الورشة في شريط القوائم"],
        // Customers
        "mac.new_customer":  ["en": "New Customer",   "ar": "عميل جديد"],
        "mac.edit_customer": ["en": "Edit Customer",  "ar": "تعديل العميل"],
        "mac.no_record":     ["en": "Not written down yet",
                              "ar": "غير مسجّل بعد"],
        "mac.write_them_down": ["en": "Write them down",
                                "ar": "تسجيل العميل"],
        "mac.what_went_wrong": ["en": "What went wrong?", "ar": "ما الذي حدث؟"],
        // (جم) and not (غم): the shared catalogue's `common.grams` is جم, and
        // that is the abbreviation every weight in this app now prints. Two
        // spellings of the gram on one screen is a typo with a rationale.
        "mac.wasted":        ["en": "Filament wasted (g)", "ar": "الخيط المهدور (جم)"],
        "mac.board_unplaced": ["en": "{n} job(s) are in a stage this board has no column for.",
                               "ar": "{n} من الأعمال في مرحلة لا عمود لها في هذا اللوح."],
        "mac.library":       ["en": "Library",       "ar": "المكتبة"],
        "mac.all_models":    ["en": "All models",    "ar": "كل المجسمات"],
        "mac.people":        ["en": "People",        "ar": "الأشخاص"],
        "mac.customers":     ["en": "Customers",     "ar": "العملاء"],
        // Stage — the one status Khayt has no word for
        "mac.cancelled":     ["en": "Cancelled",     "ar": "ملغى"],
        // How much passes inspection first time.
        "mac.qc_title":      ["en": "Quality",        "ar": "الجودة"],
        "mac.qc_first":      ["en": "right first time", "ar": "صحيح من أول مرة"],
        "mac.qc_passed":     ["en": "passed inspection", "ar": "اجتاز الفحص"],
        "mac.qc_gap":        ["en": "{n} jobs passed only after being reprinted.",
                              "ar": "{n} من الأعمال اجتازت بعد إعادة الطباعة فقط."],
        "mac.qc_worst":      ["en": "Most often: {fault}.", "ar": "الأكثر تكرارًا: {fault}."],
        "mac.qc_rma":        ["en": "{n} came back under warranty, costing {amount} to put right.",
                              "ar": "{n} عادت تحت الضمان بتكلفة {amount} لإصلاحها."],
        "mac.qc_none":       ["en": "Nothing has been through inspection yet.",
                              "ar": "لم يمر أي عمل بالفحص بعد."],
        // What the shelf costs.
        "mac.mc_title":      ["en": "What materials cost", "ar": "تكلفة المواد"],
        "mac.mc_per":        ["en": "per {unit}",        "ar": "لكل {unit}"],
        "mac.mc_risen":      ["en": "{name} has risen {pct}% since you first bought it.",
                              "ar": "ارتفع {name} بنسبة {pct}% منذ أول شراء."],
        "mac.mc_one_buy":    ["en": "bought once",       "ar": "شُري مرة واحدة"],
        "mac.mc_none":       ["en": "Nothing has been bought twice yet, so no price change can be known.",
                              "ar": "لم يُشترَ أي صنف مرتين بعد، لذا لا يمكن معرفة تغيّر السعر."],
        // When the shop finishes work.
        "mac.tp_title":      ["en": "When work finishes", "ar": "متى ينتهي العمل"],
        "mac.tp_busiest":    ["en": "Most work finishes {day} around {hour}.",
                              "ar": "معظم العمل ينتهي يوم {day} قرابة {hour}."],
        "mac.tp_closed":     ["en": "{pct}% of it finishes on a day the shop is closed.",
                              "ar": "{pct}% منه ينتهي في يوم يكون المحل مغلقًا فيه."],
        "mac.tp_thin":       ["en": "Not enough finished work yet to read a pattern — {n} so far.",
                              "ar": "لا يوجد عمل منجز كافٍ لقراءة نمط بعد — {n} حتى الآن."],
        // Which machine is costing the shop.
        "mac.mr_title":      ["en": "What gets scrapped", "ar": "ما الذي يُهدر"],
        "mac.mr_rate":       ["en": "{pct}% scrapped",  "ar": "{pct}% مهدر"],
        "mac.mr_worst":      ["en": "{name} scraps the most of what it prints — mostly {fault}.",
                              "ar": "{name} أكثر آلة تهدر مما تطبع — غالبًا بسبب {fault}."],
        "mac.mr_clean":      ["en": "nothing scrapped", "ar": "لا هدر"],
        "mac.mr_of":         ["en": "{scrap} of {out}", "ar": "{scrap} من {out}"],
        // Growing, or serving the same people?
        "mac.cm_title":      ["en": "Where the work comes from", "ar": "من أين يأتي العمل"],
        "mac.cm_new":        ["en": "New customers",  "ar": "عملاء جدد"],
        "mac.cm_returning":  ["en": "Coming back",    "ar": "عملاء عائدون"],
        "mac.cm_people":     ["en": "{n} people",     "ar": "{n} أشخاص"],
        "mac.cm_first":      ["en": "A new customer's first order is worth {amount} on average.",
                              "ar": "أول طلب لعميل جديد يساوي {amount} في المتوسط."],
        // Which products actually earn.
        "mac.pp_title":      ["en": "What earns",     "ar": "ما الذي يكسب"],
        "mac.pp_per_hour":   ["en": "per machine hour", "ar": "لكل ساعة تشغيل"],
        "mac.pp_best":       ["en": "{name} earns the most per machine hour — {amount} — which is the thing to push.",
                              "ar": "{name} الأعلى ربحًا لكل ساعة تشغيل — {amount} — وهو ما يستحق الترويج."],
        "mac.pp_hours":      ["en": "{n} h",          "ar": "{n} ساعة"],
        // How many quotes turn into work.
        "mac.qf_by_value":   ["en": "of the money",   "ar": "من قيمة العروض"],
        "mac.qf_by_count":   ["en": "of the quotes",  "ar": "من عدد العروض"],
        "mac.qf_decide":     ["en": "{n} days to decide, typically",
                              "ar": "{n} يومًا للبتّ عادةً"],
        "mac.qf_open":       ["en": "{n} quotes still open, worth {amount}. The oldest has been waiting {days} days.",
                              "ar": "{n} عروض ما زالت مفتوحة بقيمة {amount}. أقدمها ينتظر منذ {days} يومًا."],
        // Whether the shop can take another job.
        "mac.cap_clear_days": ["en": "clear in {n} days", "ar": "يخلو خلال {n} يومًا"],
        "mac.cap_clear_soon": ["en": "free today",       "ar": "متاح اليوم"],
        "mac.cap_over":       ["en": "{n} days behind",  "ar": "متأخر {n} يومًا"],
        "mac.cap_untargeted": ["en": "{h} h of booked work is on machines with no daily target, so it is in no percentage here.",
                               "ar": "{h} ساعة من العمل المحجوز على آلات بلا هدف يومي، فلا تدخل في أي نسبة هنا."],
        "mac.cap_hours":      ["en": "{booked} h of {available} h", "ar": "{booked} من {available} ساعة"],
        // Who the customers are worth.
        "mac.cv_share":      ["en": "{pct}% of everything the shop has earned is this one customer.",
                              "ar": "{pct}% من كل ما كسبه المحل يأتي من هذا العميل وحده."],
        "mac.cv_in_flight":  ["en": "in flight",       "ar": "قيد التنفيذ"],
        "mac.cv_quiet_for":  ["en": "quiet {n} days",  "ar": "صامت {n} يومًا"],
        "mac.cv_never":      ["en": "no finished work","ar": "لا عمل منجز"],
        // Cash flow — money paid on a day nobody wrote down.
        "mac.cf_undated":    ["en": "{amount} was collected on days that were never recorded, so it is not on the chart.",
                              "ar": "حُصِّل {amount} في أيام لم تُسجَّل، لذا لا يظهر في الرسم."],
        // Report builder — the shared catalogue has the screen's own words
        // but not the sentence that says which knob to turn.
        // The shape of a typed day. Translated rather than left as the ISO
        // letters: "YYYY" is a hint only to someone who reads English, and the
        // field it hints at is one a shop is expected to type into.
        "mac.date_hint":     ["en": "YYYY-MM-DD",     "ar": "سنة-شهر-يوم"],
        "mac.rb_empty_why":  ["en": "No job in the book matches. Tick more stages, or widen the dates.",
                              "ar": "لا يوجد عمل مطابق في الدفتر. اختر مراحل أكثر، أو وسّع المدة."],
        // Columns
        "mac.job":           ["en": "Job",           "ar": "العمل"],
        "mac.stage":         ["en": "Stage",         "ar": "المرحلة"],
        "mac.settled":       ["en": "settled",       "ar": "مسدّد"],
        "mac.jobs_count":    ["en": "Jobs",          "ar": "الأعمال"],
        "mac.open_count":    ["en": "Open",          "ar": "المفتوحة"],
        "mac.last_job":      ["en": "Last job",      "ar": "آخر عمل"],
        "mac.billed":        ["en": "Billed",        "ar": "المفوتر"],
        // Provenance
        "mac.read_only":     ["en": "Opened read-only",          "ar": "مفتوح للقراءة فقط"],
        "mac.writable":      ["en": "This book is yours to change", "ar": "هذا الدفتر تحت تصرفك"],
        "mac.sample":        ["en": "Sample data",   "ar": "بيانات تجريبية"],
        "mac.not_real_shop": ["en": "sample data — not a real shop",
                              "ar": "بيانات تجريبية — ليست محلاً حقيقياً"],
        "mac.yours":         ["en": "yours to change", "ar": "تحت تصرفك"],
        // Library
        "mac.on_this_mac":   ["en": "On this Mac",   "ar": "على هذا الجهاز"],
        "mac.not_found":     ["en": "not found",     "ar": "غير موجود"],
        "mac.printed":       ["en": "Printed",       "ar": "طُبع"],
        "mac.never":         ["en": "never",         "ar": "لم يُطبع"],
        "mac.last_run":      ["en": "Last run",      "ar": "آخر تشغيل"],
        "mac.mesh":          ["en": "Mesh",          "ar": "المجسم"],
        "mac.triangles":     ["en": "Triangles",     "ar": "المثلثات"],
        "mac.swaps":         ["en": "Swaps",         "ar": "التبديلات"],
        "mac.filament":      ["en": "Filament",      "ar": "الخيط"],
        "mac.file":          ["en": "File",          "ar": "الملف"],
        "mac.money":         ["en": "Money",         "ar": "المال"],
        "mac.parts":         ["en": "Parts",         "ar": "الأجزاء"],
        "mac.machine_time":  ["en": "Machine time",  "ar": "زمن التشغيل"],
        "mac.shop_keeps":    ["en": "Shop keeps",    "ar": "يبقى للمحل"],
        // ── Words that were written in English and left there ────────────────
        //
        // Every one of these reached a screen untranslated. An Arabic shop read
        // "No jobs yet" under a right-to-left toolbar, and a context menu of
        // English verbs over an Arabic library. `WordsAreTranslatedTests` is
        // what stops the next one: a literal in a view is now a test failure,
        // not something somebody has to notice in a photograph.
        "mac.reveal_folder":  ["en": "Reveal Folder in Finder", "ar": "إظهار المجلد في فايندر"],
        "mac.copy_name":     ["en": "Copy Name",       "ar": "نسخ الاسم"],
        "mac.copy_file_name": ["en": "Copy File Name", "ar": "نسخ اسم الملف"],
        "mac.no_customers":  ["en": "No customers yet", "ar": "لا عملاء بعد"],
        "mac.no_filament":   ["en": "No filament yet",  "ar": "لا خيوط بعد"],
        "mac.convert_for":   ["en": "Convert for",     "ar": "حوّل إلى"],
        "mac.standard_3mf":  ["en": "Standard 3MF",    "ar": "ملف 3MF قياسي"],
        "mac.converting":    ["en": "Converting…",     "ar": "جارٍ التحويل…"],
        "mac.converted":     ["en": "Saved {name} for {target}.",
                              "ar": "حُفظ {name} لـ {target}."],
        "mac.no_customers_hint": ["en": "A customer appears here once a job is billed to them.",
                                  "ar": "يظهر العميل هنا بعد أن يُحرَّر له حساب على عمل."],
        "mac.past_due":      ["en": "Past due",        "ar": "متأخر السداد"],
        // Khayt's `flow.paid` is the STATUS word — lowercase "paid", which is
        // right beside a job and wrong as a row label between "Total" and
        // "Owed". A borrowed key wins over this app's own, so the label needs a
        // key of its own rather than a different value under the same one.
        "mac.paid":          ["en": "Paid",           "ar": "مدفوع"],
        "mac.overdue_jobs":  ["en": "{n} unpaid jobs past their due date",
                              "ar": "{n} أعمال غير مدفوعة تجاوزت موعدها"],
        "mac.jobs_word":     ["en": "jobs",           "ar": "أعمال"],
        "mac.jobs_word_one": ["en": "job",            "ar": "عمل"],
        // Nominative: these stand alone as a label rather than after a
        // preposition, so the dual takes its `ـان` ending.
        "mac.jobs_word_two": ["en": "jobs",           "ar": "عملان"],

        // How long a spool has got, at the rate the shop is using it.
        //
        // "in" rather than "on": the figure comes from a trailing thirty-day
        // average and is an estimate, so it must not read like an appointment.
        // Only shown for a spool with two months or less left — a roll with a
        // year in it does not need a line, and a shelf that annotates every
        // card annotates none of them.
        "mac.empty_in":      ["en": "empty in",       "ar": "ينفد خلال"],
        "mac.days_word":     ["en": "days",           "ar": "أيام"],
        "mac.days_word_one": ["en": "day",            "ar": "يوم"],
        // Genitive: this word only ever follows `خلال` ("within"), and a
        // preposition takes the genitive dual — `خلال يومين`, not `خلال يومان`.
        "mac.days_word_two": ["en": "days",           "ar": "يومين"],
        // Today, or already promised away.
        "mac.empty_now":     ["en": "none left",      "ar": "لم يتبقَّ شيء"],

        // Filament goes damp on a shelf and prints badly when it has. The
        // interval is per material and per storage — a nylon in open air is a
        // day, the same nylon in a sealed box is twenty — and it is a nudge,
        // not a measurement, so the words are an instruction rather than a
        // verdict about moisture nobody has measured.
        "mac.dry_overdue":   ["en": "needs drying",   "ar": "بحاجة إلى تجفيف"],
        "mac.dry_due":       ["en": "dry it soon",    "ar": "جفّفها قريبًا"],

        // A printable sheet of QR labels for the rack. The code on each one is
        // `KHAYT-SPOOL:<id>`, which is what the Electron app writes too — a
        // shop must be able to scan a rack labelled from either app.
        // What the QUEUE is about to make late, which is a different piece of
        // news from what already is. "Expected", not "will be": the projection
        // is the shop's own working hours over the queue's print hours, and it
        // is an estimate that should sound like one.
        "mac.will_be_late":  ["en": "Expected to miss their due date",
                              "ar": "يُتوقع تأخرها عن موعدها"],
        "mac.due_expected":  ["en": "due {due} · expected {eta}",
                              "ar": "الموعد {due} · متوقع {eta}"],

        "mac.shelf_labels":  ["en": "Shelf labels",   "ar": "ملصقات الرف"],
        "mac.print_labels":  ["en": "Print shelf labels…", "ar": "طباعة ملصقات الرف…"],
        "mac.print":         ["en": "Print",          "ar": "طباعة"],
        "mac.labels_count":  ["en": "labels",         "ar": "ملصقات"],
        "mac.labels_count_one": ["en": "label",       "ar": "ملصق"],
        "mac.labels_count_two": ["en": "labels", "ar": "ملصقان"],

        "mac.reading_file":   ["en": "Reading the file…", "ar": "جارٍ قراءة الملف…"],
        // The library's grouping menu.
        "mac.pick_a_model":  ["en": "Select a model first", "ar": "اختر نموذجًا أولًا"],
        "mac.new_group":     ["en": "New Group\u{2026}", "ar": "مجموعة جديدة\u{2026}"],
        "mac.remove_from_group": ["en": "Remove from Group", "ar": "إزالة من المجموعة"],
        "mac.group_n_models": ["en": "Group {n} Models", "ar": "تجميع {n} نماذج"],
        "mac.group":         ["en": "Group",           "ar": "تجميع"],
        "mac.group_why":     ["en": "File the selected models under one name",
                              "ar": "احفظ النماذج المختارة تحت اسم واحد"],
        "mac.group_locked":  ["en": "Another app has this book open, so nothing here can be changed",
                              "ar": "تطبيق آخر يفتح هذا الدفتر، فلا يمكن تغيير شيء هنا"],
        "mac.name_this_group": ["en": "Name this group", "ar": "سمِّ هذه المجموعة"],
        "mac.group_name_kept": ["en": "A name already in use keeps its spelling.",
                                "ar": "الاسم المستخدَم من قبل يحتفظ بهجائه."],
        "mac.file_it":       ["en": "File",            "ar": "احفظ"],
        "mac.n_models":      ["en": "{n} models",      "ar": "{n} نماذج"],
        "mac.together":      ["en": "Together",        "ar": "مجتمعة"],
        "mac.on_disk":       ["en": "On disk",         "ar": "على القرص"],
        "mac.not_on_this_mac": ["en": "Not on this Mac", "ar": "ليست على هذا الماك"],
        "mac.group_hint":    ["en": "Use the Group button in the toolbar to file them together.",
                              "ar": "استخدم زر التجميع في شريط الأدوات لحفظها معًا."],
        // The library and the jobs table.
        "mac.is_favourite":  ["en": "Marked a favourite", "ar": "معلَّم كمفضّل"],
        "mac.make_favourite": ["en": "Mark a favourite", "ar": "علّمه كمفضّل"],
        "mac.unmake_favourite": ["en": "Stop marking this a favourite", "ar": "أزل تعليمه كمفضّل"],
        "mac.add_to_favourites": ["en": "Add to Favourites", "ar": "إضافة إلى المفضّلة"],
        "mac.remove_from_favourites": ["en": "Remove from Favourites", "ar": "إزالة من المفضّلة"],
        "mac.file_in":       ["en": "File in {name}",  "ar": "احفظ في {name}"],

        // ── KITS: SEVERAL PRINTS THAT ARE ONE OBJECT ──────────────────────
        //
        // "Kit" and not "assembly", deliberately. An assembly in Khayt is one
        // ORDER holding several parts plus bought-in components, gated on QC —
        // a thing you sell. A kit is a grouping ACROSS orders, over work
        // already done. Two words because they are two things, and a shop can
        // have both on the same job.
        "mac.kits":          ["en": "Kits",            "ar": "الأطقم"],
        "mac.kit":           ["en": "Kit",             "ar": "الطقم"],
        "mac.no_kit":        ["en": "No kit",          "ar": "بلا طقم"],
        "mac.new_kit":       ["en": "New Kit…",        "ar": "طقم جديد…"],
        "mac.kit_name_title": ["en": "These jobs are one object",
                               "ar": "هذه الأعمال شيء واحد"],
        "mac.kit_name_hint": ["en": "Name it, and their hours, filament and cost are totalled together.",
                              "ar": "سمِّه، فتُجمع ساعاته وخيطه وتكلفته معًا."],
        "mac.kit_name_field": ["en": "Kit name",       "ar": "اسم الطقم"],
        "mac.remove_from_kit": ["en": "Remove from Kit", "ar": "إزالة من الطقم"],
        "mac.rename_kit":    ["en": "Rename Kit…",     "ar": "إعادة تسمية الطقم…"],
        "mac.disband_kit":   ["en": "Disband Kit",     "ar": "تفكيك الطقم"],
        "mac.disband_kit_q": ["en": "Take these jobs out of {name}?",
                              "ar": "إخراج هذه الأعمال من {name}؟"],
        "mac.disband_kit_hint": ["en": "The prints themselves are not touched.",
                                 "ar": "لا تُمسّ المطبوعات نفسها."],
        "mac.kit_name_taken": ["en": "Another kit is already called {name}",
                               "ar": "يوجد طقم آخر بالاسم {name}"],
        "mac.kit_unknown":   ["en": "This kit could not be named",
                              "ar": "تعذّرت تسمية هذا الطقم"],
        // Asked, never assumed. A name one edit from an existing kit is far
        // more often a slip than a second kit, and the cost of being wrong is
        // asymmetric — a wrongly-merged job is one click to pull out again,
        // while a silently split rollup looks correct and is never noticed.
        // But "Leg L" and "Leg R" are one edit apart and genuinely different,
        // so the shop answers rather than the app deciding.
        "mac.kit_near_q":    ["en": "A kit called {name} already exists",
                              "ar": "يوجد بالفعل طقم اسمه {name}"],
        "mac.kit_near_hint": ["en": "Add these jobs to it, or make a second kit called {typed}?",
                              "ar": "أضف هذه الأعمال إليه، أم تُنشئ طقمًا ثانيًا اسمه {typed}؟"],
        "mac.kit_use_existing": ["en": "Add to {name}", "ar": "أضف إلى {name}"],
        "mac.kit_make_new":  ["en": "Make {typed}",    "ar": "أنشئ {typed}"],
        // The count behind every total, which is not decoration: a build total
        // that silently omits an unmeasured job is the one bug lib/print-kits.js
        // exists to prevent, and hiding the count reintroduces it at the last
        // step.
        "mac.kit_measured":  ["en": "{n} of {total} measured",
                              "ar": "قيس {n} من {total}"],
        "mac.kit_all_measured": ["en": "every job measured", "ar": "كل عمل مقيس"],
        "mac.kit_mixed_currency": ["en": "mixed currencies", "ar": "عملات مختلطة"],
        "mac.kit_vs_estimate": ["en": "vs estimate",   "ar": "مقابل التقدير"],
        // The definition is gone and the jobs are not.
        "mac.kit_orphaned":  ["en": "name deleted",    "ar": "حُذف الاسم"],
        "mac.kit_orphaned_help": ["en": "This kit's name was deleted. Renaming it writes the name back.",
                                  "ar": "حُذف اسم هذا الطقم. إعادة التسمية تُعيد كتابته."],
        "mac.no_kits":       ["en": "No kits yet",     "ar": "لا أطقم بعد"],
        "mac.no_kits_hint":  ["en": "A figure printed as head, hands and body is four jobs and one object. File them together and Khayt totals them.",
                              "ar": "تمثال يُطبع رأسًا ويدين وجسمًا هو أربعة أعمال وشيء واحد. احفظها معًا يجمعها خيط."],
        "mac.filament_n":    ["en": "Filament {n}",    "ar": "الخيط {n}"],
        "mac.n_swaps":       ["en": "{n} filament swaps", "ar": "{n} تبديلات خيط"],
        "mac.library_wont_open": ["en": "This library will not open", "ar": "لا تُفتح هذه المكتبة"],
        "mac.no_models":     ["en": "No models yet",   "ar": "لا نماذج بعد"],
        "mac.no_models_hint": ["en": "Print files added in Khayt appear here.",
                               "ar": "تظهر هنا ملفات الطباعة المضافة في خيط."],
        "mac.is_urgent":     ["en": "Marked urgent",   "ar": "معلَّم كعاجل"],
        "mac.overdue_unpaid": ["en": "Overdue and unpaid", "ar": "متأخر وغير مدفوع"],
        "mac.due_on":        ["en": "Due {date}",      "ar": "الاستحقاق {date}"],
        "mac.nothing_paid":  ["en": "Nothing paid yet", "ar": "لم يُدفع شيء بعد"],
        "mac.pct_paid":      ["en": "{n}% paid",       "ar": "مدفوع {n}%"],
        "mac.book_wont_open": ["en": "This book will not open", "ar": "لا يُفتح هذا الدفتر"],
        "mac.nothing_at_stage": ["en": "Nothing at this stage", "ar": "لا شيء في هذه المرحلة"],
        // What a model really costs against what it is quoted at.
        "mac.quoting":      ["en": "Quoting",  "ar": "التسعير"],
        // What each machine earned, and what it cost to keep earning it.
        "mac.mpl_title":        ["en": "By machine",   "ar": "حسب الآلة"],
        "mac.mpl_all_machines": ["en": "All machines", "ar": "كل الآلات"],
        "mac.mpl_not_net":      ["en": "What each job consumed — its filament, expenses filed against it, and the machine's servicing. Your labour, power and rent are in the Profit & Loss, not here.",
                                 "ar": "ما استهلكه كل عمل — خيطه، والمصروفات المسجّلة عليه، وصيانة الآلة. أما العمالة والكهرباء والإيجار فهي في الأرباح والخسائر، لا هنا."],
        "mac.check_updates": ["en": "Check for Updates…", "ar": "التحقق من التحديثات…"],
        // Counted, because "From 1 measured prints" is what a {n} placeholder
        // gives you. `counting` also knows Arabic's dual, which is a form of its
        // own and carries no numeral — "2 طبعات" reads the way "2 printses"
        // does.
        "mac.acc_prints":     ["en": "measured prints", "ar": "طبعات مقيسة"],
        "mac.acc_prints_one": ["en": "measured print",  "ar": "طبعة مقيسة"],
        "mac.acc_prints_two": ["en": "measured prints", "ar": "طبعتان مقيستان"],
        // Only this app draws the accuracy panel, so the sentence explaining
        // what it leaves out lives here rather than in the nine renderer
        // locales — a key no JavaScript can reach is one the reachability
        // guard is right to call dead.
        "mac.acc_measured_only": ["en": "Only prints a printer timed itself. A time typed on completion is usually the estimate confirmed, which would report every machine as perfect.",
                                  "ar": "الطبعات التي قاست الطابعة زمنها فقط. الزمن المكتوب عند الإكمال هو غالبًا التقدير نفسه، وهو ما يجعل كل آلة تبدو مضبوطة تمامًا."],
        "mac.mpl_empty":        ["en": "No machine finished anything in this period",
                                 "ar": "لم تُنهِ أي آلة عملاً في هذه الفترة"],
        // NOT "no data". A shop reaches this by looking at a period it did no
        // work in, which is a thing it can change by looking at another one.
        "mac.mpl_empty_why":    ["en": "Choose a longer period, or finish a job on a machine and it appears here.",
                                 "ar": "اختر فترة أطول، أو أنهِ عملاً على آلة فتظهر هنا."],
        // The camera on a printer.
        "mac.camera":        ["en": "Camera",            "ar": "الكاميرا"],
        // A machine the shop booked out of service on purpose.
        "mac.band_down":     ["en": "Maintenance",       "ar": "صيانة"],
        "mac.downtime_none": ["en": "Not booked out for anything.",
                              "ar": "غير محجوزة لأي صيانة."],
        // Said while it can still be corrected. The shared rule DROPS a window
        // that runs backwards, silently — which would be a shop typing
        // something and finding nothing saved.
        "mac.downtime_backwards": ["en": "This window ends before it starts, and will not be saved.",
                                   "ar": "هذه الفترة تنتهي قبل أن تبدأ، ولن تُحفظ."],
        // The scheduler with nothing to schedule. `sched.none_to_assign` is
        // shared with the Electron board and says the fact; this says why it
        // is not a problem, and lives here because only this app draws it.
        "mac.nothing_to_assign_why": ["en": "Every job waiting for a machine already has one.",
                                      "ar": "كل طلب ينتظر آلة لديه واحدة بالفعل."],
        // Where the two numbers that used to be typed here now come from.
        "mac.lead_from_hours": ["en": "Hours a day and days a week come from Working Hours above.",
                                "ar": "ساعات اليوم وأيام الأسبوع مأخوذة من ساعات العمل أعلاه."],
        "mac.cam_find":      ["en": "Find it",           "ar": "ابحث عنها"],
        "mac.cam_no_frame":  ["en": "No picture yet",     "ar": "لا صورة بعد"],
        "mac.cam_unreachable": ["en": "Camera not answering", "ar": "الكاميرا لا تجيب"],
        "mac.cam_still":     ["en": "Snapshot address",  "ar": "عنوان اللقطة"],
        "mac.cam_rotate":    ["en": "Rotate",            "ar": "تدوير"],
        "mac.cam_flip_h":    ["en": "Flip across",       "ar": "قلب أفقي"],
        "mac.cam_flip_v":    ["en": "Flip down",         "ar": "قلب رأسي"],
        "mac.cam_found":     ["en": "Found a camera, and it answered with a picture.",
                              "ar": "وُجدت كاميرا، وأجابت بصورة."],
        // A registered camera that has not captured a frame yet is a camera.
        // Saying "none found" here would be wrong in the one case a shop is
        // most likely to hit — the moment after plugging one in.
        "mac.cam_warming":   ["en": "Found a camera. It has no picture yet — give it a moment.",
                              "ar": "وُجدت كاميرا. لا صورة بعد — امنحها لحظة."],
        "mac.cam_none":      ["en": "No camera answered on the addresses this kind of printer uses. If you know its address, type it above.",
                              "ar": "لم تُجب أي كاميرا على العناوين المعتادة لهذا النوع من الطابعات. إن كنت تعرف العنوان فاكتبه أعلاه."],
        "mac.cam_needs_host": ["en": "Give the printer an address first — a camera is looked for on the same machine.",
                               "ar": "أعطِ الطابعة عنواناً أولاً — تُطلب الكاميرا من الجهاز نفسه."],
        "mac.cam_same_host": ["en": "A path is enough — /webcam/?action=snapshot. It is read from the printer's own address, and only from there.",
                              "ar": "المسار يكفي — ‎/webcam/?action=snapshot‎. تُقرأ من عنوان الطابعة نفسه، ومنه وحده."],
        // Finishing a job, and what it really took.
        // The title, the button and the hint are Khayt's own `act.*` — the two
        // apps ask this question with the same words in nine languages, and a
        // second English sentence here would be one to keep in step for ever.
        // NOT "measured". A figure off a keyboard and a figure off a printer
        // are different claims, the record keeps them apart, and the screens
        // that need a measurement ignore this one — so the sheet says so.
        "mac.completion_typed":   ["en": "Recorded as typed by hand, not read from the printer.",
                                   "ar": "تُسجَّل ككتابة يدوية، لا كقراءة من الطابعة."],
        // `mac.filament` is already written above — the sidebar's shelf — and a
        // second copy is a fatal `Dictionary literal contains duplicate keys`
        // at launch, not a warning. `DuplicateWordKeyTests` guards it and could
        // not help here: the literal traps before any test runs.
        "mac.time":         ["en": "Time",     "ar": "الوقت"],
        "mac.not_measured": ["en": "Not measured", "ar": "غير مقاس"],
        "mac.pct_over":     ["en": "{pct}% over",  "ar": "{pct}% زيادة"],
        "mac.pct_under":    ["en": "{pct}% under", "ar": "{pct}% أقل"],
        "mac.prints_word_one": ["en": "print",  "ar": "طبعة"],
        "mac.prints_word":     ["en": "prints", "ar": "طبعات"],
        // English has no dual, so its `_two` is just the plural — as every other
        // `_two` key here carries one. `counting` only reaches for this form in
        // Arabic; the English side exists so the both-languages guard means
        // what it says rather than growing an exception.
        "mac.prints_word_two": ["en": "prints", "ar": "طبعتين"],
        "mac.quoting_advice_filament": ["en": "Quoted {pct}% short on filament — the price is under what this costs.",
                                        "ar": "التسعير أقل بـ{pct}% في الخيط — السعر دون تكلفته الفعلية."],
        "mac.quoting_advice_time":     ["en": "Takes {pct}% longer than quoted — the machine time is under-charged.",
                                        "ar": "تستغرق {pct}% أطول من المقدَّر — وقت الآلة غير محسوب بالكامل."],
        "mac.quoting_empty":     ["en": "Nothing measured yet", "ar": "لا قياسات بعد"],
        // NOT "no data". A shop with a full book gets this screen too, and the
        // two reasons are both things it can go and change.
        "mac.quoting_empty_why": ["en": "This compares what a model was quoted at with what a printer reported. It needs jobs finished with figures read from the machine, on prints of a single part.",
                                  "ar": "تقارن هذه الصفحة ما قُدِّر للنموذج بما أبلغت عنه الطابعة. تحتاج أعمالاً منتهية بأرقام مقروءة من الآلة، على طبعات ذات قطعة واحدة."],
        // A search that emptied the screen. The term is quoted because a shop
        // that has mistyped one letter needs to SEE the letter it typed, and
        // an unquoted word in a sentence hides a stray space entirely.
        "mac.nothing_matches": ["en": "Nothing matches “{q}”", "ar": "لا شيء يطابق «{q}»"],
        // NO LEADING ELLIPSIS IN THE ARABIC. It reads as a continuation of the
        // title in English and it cannot in Arabic: a leading "…" is a neutral
        // character, and bidi resolves it against the run it sits beside, so it
        // rendered at the LEFT edge — the visual END of an Arabic line. The
        // sentence appeared to trail off before it began. Photographed with
        // KHAYT_LANG=ar; nothing in the string suggests it.
        "mac.and_only_stage":  ["en": "…and the sidebar is showing only {stage}.",
                                "ar": "والشريط الجانبي يعرض {stage} فقط."],
        "mac.clear_search":    ["en": "Clear Search",   "ar": "امسح البحث"],
        "mac.show_all_stages": ["en": "Show All Stages", "ar": "اعرض كل المراحل"],
        "mac.stage_hint":    ["en": "Jobs will appear here as they reach it.",
                              "ar": "تظهر الأعمال هنا حين تبلغ هذه المرحلة."],
        // The window itself.
        "mac.details":       ["en": "Details",         "ar": "التفاصيل"],
        "mac.find":          ["en": "Find\u{2026}",        "ar": "بحث\u{2026}"],
        "mac.quick_look":    ["en": "Quick Look",     "ar": "نظرة سريعة"],
        // ── The sidebar's own names for three screens ────────────────────────
        //
        // Khayt calls them "Expense Tracker", "Failed Prints & Waste Log" and
        // "Profit & Loss by Quarter", which are good names for a screen and too
        // long for a 190pt column: two of the three were truncated mid-word in
        // every launch. Under a heading that already says "Money", the short
        // form loses nothing — and the screens keep their full titles.
        "mac.nav_expenses":  ["en": "Expenses",       "ar": "المصروفات"],
        "mac.nav_waste":     ["en": "Waste",          "ar": "الهدر"],
        "mac.nav_reports":   ["en": "Profit & Loss",  "ar": "الأرباح والخسائر"],
        "mac.details_toggle": ["en": "Show or hide the details", "ar": "إظهار التفاصيل أو إخفاؤها"],
        "mac.hide_details":  ["en": "Hide details",    "ar": "إخفاء التفاصيل"],
        "mac.show_details":  ["en": "Show details",    "ar": "إظهار التفاصيل"],
        "mac.about_khayt":   ["en": "About Khayt",     "ar": "عن خيط"],
        "mac.unreadable_records": ["en": "{n} records could not be read",
                                   "ar": "تعذّرت قراءة {n} سجلات"],
        // Which book is open. Shown in the picker at the top of the window.
        "mac.book_sample":   ["en": "Sample shop",     "ar": "متجر تجريبي"],
        "mac.book_dev":      ["en": "This Mac \u{2014} development",
                              "ar": "هذا الماك \u{2014} تطوير"],
        "mac.book_khayt":    ["en": "This Mac \u{2014} Khayt", "ar": "هذا الماك \u{2014} خيط"],
        // What the lock says when the other app has the book.
        "mac.book_owned":    ["en": "Another app owns this book", "ar": "تطبيق آخر يملك هذا الدفتر"],
        "mac.book_taken":    ["en": "Another app took the book", "ar": "أخذ تطبيق آخر الدفتر"],
        "mac.vat_number":    ["en": "VAT No.",         "ar": "الرقم الضريبي"],
        "mac.none":          ["en": "none",            "ar": "لا شيء"],
        "mac.n_different":   ["en": "{n} different",   "ar": "{n} مختلفة"],
        "mac.group_example": ["en": "Saudi Kings",      "ar": "ملوك السعودية"],
        "mac.group_unknown": ["en": "Could not work out which group that is.",
                              "ar": "تعذّر تحديد المجموعة المقصودة."],
        "mac.lock_why":      ["en": "Khayt serialises writes per process. While another app "
                            + "owns this book, only it may change anything.",
                              "ar": "يكتب خيط بالتتابع لكل عملية. وما دام تطبيق آخر يملك هذا الدفتر، "
                            + "فهو وحده من يستطيع تغيير أي شيء."],
        // Who else has the book open. Assembled from `StoreLock.Held`, which
        // carries the facts and no language: the application's own name, and
        // the machine when it is not this one.
        "mac.lock_another":  ["en": "Another copy of Khayt", "ar": "نسخة أخرى من خيط"],
        "mac.lock_held":     ["en": "{who} has this book open",
                              "ar": "{who} يفتح هذا الدفتر"],
        "mac.lock_held_on":  ["en": "{who} on {where} has this book open",
                              "ar": "{who} على {where} يفتح هذا الدفتر"],
        // Khayt's catalogue has "Quotes expiring soon" and "Overdue" but no
        // heading for the invoices a shop is meant to chase, which is a
        // narrower list than either: past due, still owing, not nudged
        // recently and not nudged too often already.
        "mac.chase_invoices": ["en": "Invoices to chase", "ar": "فواتير للمتابعة"],
        "mac.chase_days_over": ["en": "{n}d overdue", "ar": "متأخرة {n} يوم"],
        "mac.chase_days_left": ["en": "expires in {n}d", "ar": "تنتهي خلال {n} يوم"],
        "mac.chase_expired":   ["en": "expired", "ar": "منتهية"],
        "mac.reveal":        ["en": "Reveal",        "ar": "إظهار"],
        "mac.open":          ["en": "Open",          "ar": "فتح"],
        "mac.name":          ["en": "Name",          "ar": "الاسم"],
        "mac.late":          ["en": "late",          "ar": "متأخرة"],
        "mac.owed_caps":     ["en": "OWED",          "ar": "المستحق"],
        "mac.sort_default":  ["en": "Favourites first", "ar": "المفضّلة أولاً"],
        "mac.sort_by":       ["en": "Sort Library By",  "ar": "ترتيب المكتبة حسب"],
        "mac.dashboard":     ["en": "Dashboard",       "ar": "اللوحة"],
        "mac.late_tile":     ["en": "Late",            "ar": "متأخرة"],
        "mac.the_machine":   ["en": "The machine",     "ar": "الطابعة"],
        "mac.bed":           ["en": "Bed",             "ar": "المنصة"],
        "mac.nozzle":        ["en": "Nozzle",          "ar": "الفوهة"],
        "mac.colours":       ["en": "Colours",         "ar": "الألوان"],
        "mac.extruder":      ["en": "Extruder",        "ar": "الباثق"],
        "mac.power":         ["en": "Power",           "ar": "الطاقة"],
        "mac.address":       ["en": "Address",         "ar": "العنوان"],
        "mac.quarter_drawn": ["en": "Where {q} went",  "ar": "أين ذهب {q}"],
        "mac.idle":          ["en": "Idle",            "ar": "متوقفة"],
        "mac.cannot_ask":    ["en": "Khayt cannot ask this machine",
                              "ar": "لا تستطيع خيط سؤال هذه الآلة"],
        "mach.connection":   ["en": "Connection",      "ar": "الاتصال"],
        "mach.protocol":     ["en": "Speaks",          "ar": "البروتوكول"],
        "mach.protocol_none":["en": "Not connected",   "ar": "غير متصلة"],
        "mach.key_ph":       ["en": "if the printer needs one", "ar": "إن كانت الطابعة تحتاجه"],
        "mach.key_kept":     ["en": "saved — type to replace",  "ar": "محفوظ — اكتب للاستبدال"],
        "mach.key_forget":   ["en": "Forget",          "ar": "انسَ"],
        "mach.key_will_clear":["en": "The saved key will be cleared when you save.",
                              "ar": "سيُمحى المفتاح المحفوظ عند الحفظ."],
        "mach.key_where":    ["en": "Encrypted in your login Keychain, the same way Khayt stores it.",
                              "ar": "يُحفظ مشفَّراً في سلسلة المفاتيح، كما تحفظه خيط."],
        "mach.test":         ["en": "Test",            "ar": "اختبر"],
        "mach.test_bad_draft":["en": "Fill in an address first.", "ar": "أدخل العنوان أولاً."],
        "mac.nozzle_wear":   ["en": "Nozzle wear",     "ar": "تآكل الفوهة"],
        // The dashed rectangle behind a bed plan. Without this the drawing
        // reads as a rendering fault rather than as a comparison.
        "mac.bed_against":   ["en": "dashed: the largest bed here, {w} × {d}",
                              "ar": "المتقطع: أكبر منصة هنا، {w} × {d}"],
        "mac.nozzle_due":    ["en": "due a change",    "ar": "تحتاج تغييراً"],
        "mac.installed":     ["en": "Installed",       "ar": "رُكّبت"],
        "mac.takes":         ["en": "Takes",           "ar": "تقبل"],
        "mac.weight":        ["en": "Weight",          "ar": "الوزن"],
        "mac.cost":          ["en": "Cost",            "ar": "التكلفة"],
        "mac.per_kilo":      ["en": "Per kilo",        "ar": "لكل كيلو"],
        "mac.inventory":     ["en": "Filament",        "ar": "الخيوط"],
        "mac.no_machines":   ["en": "No machines yet", "ar": "لا طابعات بعد"],
        "mac.no_machines_hint": ["en": "Printers added in Khayt appear here.",
                                 "ar": "تظهر هنا الطابعات المضافة في خيط."],
        "mac.no_stock":      ["en": "No filament recorded", "ar": "لا خيوط مسجّلة"],
        "mac.no_stock_hint": ["en": "Spools added in Khayt appear here.",
                              "ar": "تظهر هنا البكرات المضافة في خيط."],
        "mac.needs_attention": ["en": "Needs attention", "ar": "يحتاج انتباهك"],
        "mac.the_floor":     ["en": "The floor",       "ar": "الورشة"],
        // The SHELF: the sidebar row, the Go menu item, the screen itself.
        "mac.machines":      ["en": "Machines",        "ar": "الطابعات"],
        // The dashboard TILE, which is a different thing wearing the same word.
        // "Machines 0/3" beside "Printing 5" reads as a contradiction because
        // it is one: the number counts printers ANSWERING ON THE NETWORK
        // (`fleet.live`), not machines with work on them, so a shop with three
        // printers all busy and none of them networked saw both at once under
        // one heading.
        //
        // ITS OWN KEY, and that is the point. Renaming `mac.machines` fixed the
        // tile and renamed the sidebar row and the Go menu item with it — the
        // menu came back reading "Online ⌘5", which is not a place anyone
        // navigates to.
        "mac.machines_online": ["en": "Online",        "ar": "متصلة"],
        "mac.revenue":       ["en": "Revenue",         "ar": "الإيراد"],
        "mac.margin":        ["en": "Margin",          "ar": "هامش الربح"],
        "mac.avg_order":     ["en": "Average job",     "ar": "متوسط العمل"],
        "mac.gross":         ["en": "Gross profit",    "ar": "الربح الإجمالي"],
        "mac.on_time":       ["en": "On time",         "ar": "في الموعد"],
        // TWO KEYS, and `counting` cannot do this one. That helper puts the
        // number first — "3 " + noun — which is right for "3 jobs" and wrong
        // here, because Arabic says متأخر before the count. So the placeholder
        // stays inside the sentence and the SENTENCE has a singular.
        "mac.days_late":     ["en": "{n} days late",   "ar": "متأخر {n} يوماً"],
        "mac.days_late_one": ["en": "{n} day late",    "ar": "متأخر {n} يوماً"],
        "mac.no_figures":    ["en": "No figures yet",  "ar": "لا أرقام بعد"],
        // The FIRST screen this app ever shows a shop. Not "0.00 revenue",
        // which is what a quiet month looks like — this is a shop that has not
        // opened, and the difference is the whole point of saying it in words.
        "mac.no_money_yet":  ["en": "No jobs on the books yet",
                              "ar": "لا أعمال في الدفتر بعد"],
        "mac.no_money_yet_hint":
            ["en": "Take a job and the money follows — what you earned, what it cost you, and what you are owed.",
             "ar": "سجّل أول عمل وتظهر الأرقام: ما كسبته، وما كلّفك، وما لك عند العملاء."],
        "mac.no_figures_hint": ["en": "They appear once the shop's book has loaded.",
                                "ar": "تظهر بعد تحميل دفتر المحل."],
        "mac.search_jobs": ["en": "Job, customer or number", "ar": "عمل أو عميل أو رقم"],
        "mac.search_models": ["en": "Model, material or tag", "ar": "مجسم أو خامة أو وسم"],
        "mac.search_people": ["en": "Customer or job", "ar": "عميل أو عمل"],
        "mac.no_job": ["en": "No job selected", "ar": "لم يُختر عمل"],
        "mac.no_job_hint": ["en": "Pick a row to see its parts and its money.", "ar": "اختر صفاً لعرض أجزائه وحسابه."],
        "mac.no_model": ["en": "No model selected", "ar": "لم يُختر مجسم"],
        // The print-risk section's own chrome. HERE rather than in the nine
        // shared locales because only this app draws it: the other app computes
        // the same findings on its quote screen and throws them away. The
        // FINDINGS themselves are `risk.*` in the shared catalogue, written
        // once by `lib/intake-view.js` and rendered by both.
        "risk.title": ["en": "Before you quote", "ar": "قبل أن تُسعّر"],
        // The assistant pane's own chrome. Mac-only: the other app's AI screen
        // is one long panel rather than a tab, so it has no heading of its own
        // and no way to forget a key.
        "set.ai_feats": ["en": "What it may do", "ar": "ما يُسمح له بفعله"],
        "mac.ai_forget_key": ["en": "Forget the stored key",
                              "ar": "حذف المفتاح المحفوظ"],
        "mac.ai_key_unsealed": ["en": "That key could not be encrypted, so it was not saved. The book syncs and is backed up, and a key in the clear would go with it.",
                                "ar": "لم يتمكّن خيط من تشفير المفتاح، فلم يُحفظ. الدفتر يُزامن ويُنسخ احتياطيًا، والمفتاح غير المشفّر سينتقل معه."],
        "risk.looking": ["en": "Reading the mesh…", "ar": "جارٍ قراءة المجسّم…"],
        "risk.clear": ["en": "Nothing to flag on this one.", "ar": "لا ملاحظات على هذا الملف."],
        "risk.not_looked": ["en": "Khayt has not looked at this mesh yet. Reading it takes a few seconds on a large model.",
                            "ar": "لم يفحص خيط هذا المجسّم بعد. قراءته تستغرق ثوانٍ في الموديلات الكبيرة."],
        "risk.look": ["en": "Check the mesh", "ar": "افحص المجسّم"],
        // The setting, and it is THIS app's setting: the other one computes
        // these findings for a quote and never stores them, so it has no import
        // to do the work at. `lib/print-risk.js` holds the rule so that when it
        // does, the two cannot disagree about what the default is.
        "set.risk_when": ["en": "Check models for print risks", "ar": "فحص الموديلات لمخاطر الطباعة"],
        "set.risk_demand": ["en": "When I ask", "ar": "عند الطلب"],
        "set.risk_import": ["en": "As each file is imported", "ar": "عند استيراد كل ملف"],
        "set.risk_hint": ["en": "Reading a mesh takes a few seconds on a large model. Checking at import pays that once per file and answers instantly afterwards; checking when you ask keeps imports fast.",
                          "ar": "قراءة المجسّم تستغرق ثوانٍ في الموديلات الكبيرة. الفحص عند الاستيراد يدفع هذه الثواني مرّة واحدة لكل ملف ثم يجيب فورًا؛ والفحص عند الطلب يُبقي الاستيراد سريعًا."],
        "risk.unreadable": ["en": "Khayt could not read the mesh in that file.",
                            "ar": "لم يتمكّن خيط من قراءة المجسّم في هذا الملف."],
        "mac.no_model_hint": ["en": "Pick a model to see its file and its filament.", "ar": "اختر مجسماً لعرض ملفه وخيطه."],
        "mac.no_customer": ["en": "No customer selected", "ar": "لم يُختر عميل"],
        "mac.no_customer_hint": ["en": "Pick a row to see their jobs and their balance.", "ar": "اختر صفاً لعرض أعماله ورصيده."],
        "mac.models_count": ["en": "models", "ar": "مجسمات"],
        "mac.customers_count": ["en": "customers", "ar": "عملاء"],
        // One of a thing. English needs the singular and Arabic reads better
        // with it, and the window said "1 machines" until it had one.
        "mac.models_count_one": ["en": "model", "ar": "مجسم"],
        "mac.models_count_two": ["en": "models", "ar": "مجسمان"],
        "mac.customers_count_one": ["en": "customer", "ar": "عميل"],
        "mac.customers_count_two": ["en": "customers", "ar": "عميلان"],
        // Counting words, not the sidebar's labels. Reusing those gave the
        // window "6 Filament" and "3 Machines" — a nav label has a capital and
        // is a heading, and neither is a thing you can put a number in front of.
        "mac.spools_count":  ["en": "spools",   "ar": "بكرات"],
        "mac.machines_count": ["en": "machines", "ar": "طابعات"],
        "mac.spools_count_one": ["en": "spool",   "ar": "بكرة"],
        "mac.spools_count_two": ["en": "spools", "ar": "بكرتان"],
        "mac.machines_count_one": ["en": "machine", "ar": "طابعة"],
        "mac.machines_count_two": ["en": "printers", "ar": "طابعتان"],
        // What the shop spent, and what it wasted
        "mac.search_expenses": ["en": "Note, category or job", "ar": "ملاحظة أو تصنيف أو عمل"],
        // Two screens that filtered correctly and asked the wrong question:
        // the prompt fell through to the jobs one, so the shelf and the
        // catalogue both invited a "Job, customer or number".
        "mac.search_filament": ["en": "Material or colour", "ar": "خامة أو لون"],
        "mac.search_products": ["en": "Product, material or group", "ar": "منتج أو خامة أو مجموعة"],
        "mac.search_waste":  ["en": "Material, reason or failure", "ar": "خامة أو سبب أو نوع العطل"],
        "mac.of_which_fixed": ["en": "incl. overhead", "ar": "منها التكاليف الثابتة"],
        "mac.quarter_in_progress": ["en": "This quarter is still running, so its overhead is charged for the days elapsed.",
                                    "ar": "هذا الربع لم ينتهِ، فتُحتسب تكاليفه الثابتة بحسب الأيام المنقضية."],
        "mac.edit_spool":    ["en": "Edit spool",   "ar": "تعديل البكرة"],
        "mac.edit_part":     ["en": "Edit part",    "ar": "تعديل الجزء"],
        // "Take the figures from the file this part was printed from." Short,
        // because it sits on a button beside the weight and the hours it fills.
        "mac.fill_from_file": ["en": "Fill from file", "ar": "تعبئة من الملف"],
        // The bundled list of filaments other people have already written down,
        // as against `known` above, which is this shop's own materials.
        "mac.filament_catalog": ["en": "Search the filament catalogue",
                                 "ar": "البحث في دليل الخيوط"],
        "mac.new_spool":     ["en": "New Spool",    "ar": "بكرة جديدة"],
        "mac.swatch":        ["en": "Swatch",       "ar": "اللون"],
        "mac.telegram_sent":   ["en": "Telegram message sent.", "ar": "أُرسلت رسالة تيليجرام."],
        "mac.telegram_failed": ["en": "The job was saved, but the Telegram message did not go out:",
                                "ar": "حُفظ العمل، لكن لم تُرسل رسالة تيليجرام:"],
        "mac.back_up_now":   ["en": "Back Up Now",   "ar": "نسخ احتياطي الآن"],
        "mac.reveal_backups": ["en": "Reveal Backups", "ar": "إظهار النسخ الاحتياطية"],
        "mac.backed_up":     ["en": "Backed up as",   "ar": "حُفظت النسخة باسم"],
        "mac.backup_failed": ["en": "Today's backup could not be written:",
                              "ar": "تعذّرت كتابة نسخة اليوم الاحتياطية:"],
        // Putting one back. The confirmation says what will be lost in the
        // shop's own words, because "are you sure?" is not a question anybody
        // can answer.
        "mac.restore_backup": ["en": "Restore from Backup\u{2026}", "ar": "استعادة من نسخة احتياطية\u{2026}"],
        "mac.restore_title": ["en": "Restore this backup?", "ar": "استعادة هذه النسخة؟"],
        "mac.restore_what": ["en": "Everything in the book is replaced by what this backup held.",
                             "ar": "سيُستبدل كل ما في الدفتر بما تحتويه هذه النسخة."],
        "mac.restore_safety": ["en": "A copy of the book as it is now is taken first.",
                               "ar": "تُؤخذ نسخة من الدفتر كما هو الآن أولًا."],
        "mac.restore_insurance": ["en": "taken before an update", "ar": "أُخذت قبل تحديث"],
        "mac.restore_do":    ["en": "Restore",      "ar": "استعادة"],
        "mac.restored":      ["en": "Restored from", "ar": "استُعيدت من"],
        "mac.restore_failed": ["en": "Nothing was restored:", "ar": "لم تُستعد أي بيانات:"],
        "mac.restore_none":  ["en": "There are no backups to restore from yet.",
                              "ar": "لا توجد نسخ احتياطية للاستعادة منها بعد."],
        // Giving a copy away. The panel says what has been taken out, because
        // a shop that thinks its keys are in the file will treat it as though
        // they are — and a shop that does not know they were removed will send
        // it expecting the other end to be able to connect.
        "mac.export_copy":   ["en": "Export a Copy\u{2026}", "ar": "تصدير نسخة\u{2026}"],
        "mac.export_redacted": ["en": "API keys, passwords and access codes are removed from this copy.",
                                "ar": "تُحذف مفاتيح الواجهات وكلمات المرور ورموز الوصول من هذه النسخة."],
        "mac.exported_to":   ["en": "Exported as", "ar": "صُدّرت باسم"],
        // The calculator. The shared `calc.*` strings are the Electron form's
        // and carry its step numbers — "1. Part & Material", "4. Build Cart &
        // Quote" — which are a lie on a screen with two sections. Its field
        // labels are reused where they read short; these are the rest.
        "mac.calc_title":    ["en": "Calculator", "ar": "الحاسبة"],
        "mac.calc_part":     ["en": "The part", "ar": "القطعة"],
        // TWO SECTIONS, TWO HEADINGS. Both said "What to charge" — the
        // controls and the answer, stacked, under the identical words. It was
        // invisible for as long as the screen had never been photographed with
        // a part in it, because the second section only exists once there is
        // something to price.
        "mac.calc_price":    ["en": "What to charge", "ar": "كم تطلب"],
        "mac.calc_rates":    ["en": "Margin and fees", "ar": "الهامش والرسوم"],
        "mac.calc_breakdown_sum": ["en": "adds up to the cost", "ar": "مجموعها التكلفة"],
        "mac.calc_breakdown": ["en": "Where it goes", "ar": "أين يذهب"],
        "mac.calc_cost":     ["en": "cost", "ar": "التكلفة"],
        "mac.calc_weight":   ["en": "Weight", "ar": "الوزن"],
        "mac.calc_time":     ["en": "Print time", "ar": "زمن الطباعة"],
        "mac.calc_printer":  ["en": "Printer", "ar": "الطابعة"],
        "mac.calc_nothing":  ["en": "Nothing to price yet",
                              "ar": "لا شيء لتسعيره بعد"],
        "mac.calc_nothing_hint": [
            "en": "Put in a weight or a print time and this works out what the job costs you and what to charge for it.",
            "ar": "أدخل وزناً أو زمن طباعة ليحسب تكلفة العمل والسعر المناسب له."],
        "mac.any_filament":  ["en": "Any filament", "ar": "أي خيط"],
        "mac.any_machine":   ["en": "Any machine", "ar": "أي طابعة"],
        "mac.calc_no_filament": [
            "en": "No filament chosen, so the plastic is not counted in this price.",
            "ar": "لم يُختر خيط، لذا لا تشمل هذه التسعيرة تكلفة المادة."],
        "mac.export_accounting": ["en": "Export for the Accountant",
                                  "ar": "تصدير للمحاسب"],
        "mac.export_accounting_where": [
            "en": "Two files are written here: one of invoices and one of expenses.",
            "ar": "يُكتب هنا ملفان: ملف للفواتير وآخر للمصروفات."],
        "mac.export_failed": ["en": "Nothing was exported:", "ar": "لم يُصدَّر شيء:"],
        // Who the shop's money came from, and what it is asked for. Khayt has
        // its own words for the two lists; this is the name of the page that
        // holds both, which it does not.
        "mac.best":          ["en": "Best",         "ar": "الأفضل"],
        "mac.times_ordered": ["en": "Orders",       "ar": "الطلبات"],
        "mac.unnamed":       ["en": "(no name yet)", "ar": "(بلا اسم بعد)"],
        "mac.price":         ["en": "Price",        "ar": "السعر"],
        "mac.engine_failed": ["en": "The shared rules did not load",
                              "ar": "لم تُحمَّل القواعد المشتركة"],
        "mac.last_crash":    ["en": "It stopped unexpectedly last time",
                              "ar": "توقّف التطبيق فجأة في المرة الماضية"],
        "mac.no_products":   ["en": "No catalogue yet", "ar": "لا يوجد كتالوج بعد"],
        "mac.no_products_hint": ["en": "A product is something the shop has decided to sell, "
                              + "with a price it stands behind. Khayt is where one is made.",
                                 "ar": "المنتج شيء قرر المحل بيعه بسعر يقف خلفه. يُنشأ في خيط."],
        // What the printer is doing. Khayt has words for the states and the
        // errors; these are the ones its own card does not need, because this
        // app tells a shop what it is NOT doing as well.
        "mac.live":          ["en": "Right now",     "ar": "الآن"],
        "mac.eta":           ["en": "Left",          "ar": "المتبقي"],
        "mac.by_layers":     ["en": "by layer",      "ar": "حسب الطبقة"],
        "mac.by_bytes":      ["en": "by file position", "ar": "حسب موضع الملف"],
        "mac.nozzle_temp":   ["en": "Nozzle",        "ar": "الفوهة"],
        "mac.bed_temp":      ["en": "Bed",           "ar": "المنصة"],
        // Said out loud rather than left blank: a card that shows nothing looks
        // broken, and a shop would go back to the other app not knowing why.
        "mac.not_polled":    ["en": "Khayt watches this printer; this app does not speak {protocol} yet.",
                              "ar": "خيط يتابع هذه الطابعة؛ هذا التطبيق لا يتحدث {protocol} بعد."],
        "mac.no_connection": ["en": "No connection set up for this printer.",
                              "ar": "لا يوجد اتصال معدّ لهذه الطابعة."],
        "mac.asking":        ["en": "Asking\u{2026}", "ar": "جارٍ السؤال\u{2026}"],
        // What has gone wrong. Khayt's own alert sentences are built in English
        // inside the shared module because they go to Telegram; this one is
        // read by the person in the workshop, in the language the book is kept.
        "mac.alert_error":   ["en": "{machine} has a fault", "ar": "{machine} بها عطل"],
        "mac.alert_offline": ["en": "{machine} stopped answering", "ar": "{machine} توقفت عن الرد"],
        "mac.alert_stalled": ["en": "{machine} has stopped moving", "ar": "{machine} توقفت عن التقدم"],
        "mac.printer_trouble": ["en": "Printer trouble", "ar": "مشاكل الطابعة"],
        // WHAT SYNC IS DOING, one short line each.
        //
        // These replaced a single standing sentence — "Not synced
        // automatically" — which said the same thing whether the book was up to
        // date or an hour behind. It was an apology for a missing feature, and
        // the feature is no longer missing.
        //
        // SHORT ENOUGH FOR ONE LINE. The sidebar column holds at 190pt and a
        // label that wraps there is the bug `SidebarLayoutTests` was written
        // after; the sentence that explains any of this lives in
        // `mac.sync_auto_why`, which is a tooltip and can be as long as it
        // needs to be.
        // The tax line in the sidebar footer, on every screen.
        //
        // It was built in Swift as "\(name) \(percent)% included in the price"
        // — an English clause welded onto a translated screen, so an Arabic
        // shop read "ضريبة القيمة المضافة 15.00% included in the price". It was
        // the only sentence in the app assembled that way and nothing caught
        // it, because it never passes through a Text literal.
        //
        // `name` stays as `lib/tax.js` gives it. That is the tax's own label —
        // what the shop's invoices say — and not interface wording to translate.
        "mac.tax_inclusive": ["en": "{name} {pct}% included in the price",
                              "ar": "{name} {pct}% شامل السعر"],
        "mac.tax_exclusive": ["en": "{name} {pct}% added on top",
                              "ar": "{name} {pct}% يُضاف على السعر"],
        // Six months of takings on the dashboard, and the sentence over them.
        //
        // A SENTENCE, not the word "Revenue" over an axis. The HIG asks a chart
        // to carry "brief descriptive text that serves as a headline or summary
        // … helping people grasp essential information at a glance", and
        // Weather's "Chance of light rain in the next hour" is the model. Three
        // of them, because "your best month" and "up 8%" are different news and
        // a shop should be told the more interesting one.
        "mac.takings":       ["en": "Takings", "ar": "الإيرادات"],
        "mac.takings_month": ["en": "{month} · {amount}", "ar": "{month} · {amount}"],
        "mac.takings_best":  ["en": "{month} was your best month of the six.",
                              "ar": "{month} كان أفضل شهورك الستة."],
        "mac.takings_up":    ["en": "Trending up — next month looks like {amount}, {pct}% above last.",
                              "ar": "الاتجاه صاعد — الشهر القادم يبدو نحو {amount}، أي {pct}% فوق الماضي."],
        "mac.takings_down":  ["en": "Trending down — next month looks like {amount}, {pct}% below last.",
                              "ar": "الاتجاه هابط — الشهر القادم يبدو نحو {amount}، أي {pct}% دون الماضي."],
        // Not enough of a run to call it either way, said rather than left to a
        // flat line the reader has to interpret.
        "mac.takings_flat":  ["en": "Six months, side by side.",
                              "ar": "ستة أشهر، جنبًا إلى جنب."],
        // Adding a model to the library.
        "mac.add_model":     ["en": "Add model", "ar": "إضافة نموذج"],
        "mac.adding_model":  ["en": "Measuring\u{2026}", "ar": "جارٍ القياس\u{2026}"],
        // The triangle count, because it is the one number that says the file
        // was actually read rather than merely copied.
        "mac.model_added":   ["en": "Added {name} — {n} triangles.",
                              "ar": "أُضيف {name} — {n} مثلثًا."],
        "mac.model_added_plain": ["en": "Added {name}.", "ar": "أُضيف {name}."],
        // MOVED, not added, and the sentence has to say so: the file is no
        // longer where its owner left it. Only shown when the original was
        // actually taken in — a source the import was told to keep, or one it
        // could not remove, still reads "Added".
        "mac.model_moved":   ["en": "Moved {name} into the library — {n} triangles.",
                              "ar": "نُقل {name} إلى المكتبة — {n} مثلثًا."],
        "mac.model_moved_plain": ["en": "Moved {name} into the library.",
                                  "ar": "نُقل {name} إلى المكتبة."],
        // A batch says all three numbers every time, including the zeros. "412
        // moved in" alone leaves a shop wondering what happened to the other
        // eleven files it selected.
        "mac.import_done":   ["en": "{moved} moved in · {duplicates} already there · {failed} failed.",
                              "ar": "نُقل {moved} · {duplicates} موجود مسبقًا · {failed} فشل."],
        "mac.import_nothing": ["en": "Nothing there Khayt can read.",
                               "ar": "لا يوجد ما تستطيع خيط قراءته."],
        // The file's own name, not just a count: on a long import it is the
        // one thing that says which model the slow minute is being spent on.
        "mac.import_progress": ["en": "Importing {done} of {total} — {name}",
                                "ar": "يجري الاستيراد {done} من {total} — {name}"],
        "mac.stop":          ["en": "Stop", "ar": "إيقاف"],
        // The slicers pane. Khayt calls the section "Slicer" already —
        // `slicer.settings_title` — so the tab reuses it rather than inventing
        // a second name for the same page in the same shop.
        // The TAB, not the section. Khayt's own `slicer.settings_title` is
        // "Slicer integration" — a fine heading for a page in a scrolling
        // settings screen, and too long for a macOS tab, which it widened by
        // half. The heading inside the pane still uses Khayt's wording.
        // The directory itself is `integ.*` in the SHARED locale — every one of
        // those keys already ships in both languages, so the pane reads the
        // same words the Electron page does. Only this app's own tab name is
        // here, because the other app's settings navigation is not a tab list.
        "mac.nav_integrations": ["en": "Integrations", "ar": "التكاملات"],
        // Said on the assistant pane, PER FEATURE, on the ones this app cannot
        // perform yet. It was one note over the whole list — and stopped being
        // true the moment "Quote from a description" started working here,
        // which is exactly how a caveat becomes a lie: it outlives the
        // limitation it described. Attached to the features themselves now, so
        // it disappears feature by feature as each one lands.
        "mac.ai_elsewhere":  ["en": "Runs in the Windows and Linux app for now — switching it on "
                              + "here records your answer for the whole shop.",
                              "ar": "يعمل في تطبيق ويندوز ولينكس حاليًا — تشغيله هنا يسجّل إجابتك "
                              + "للمتجر كله."],
        // ── DRAFTING A QUOTE FROM A DESCRIPTION ───────────────────────────
        "mac.describe_the_job": ["en": "Describe the job — \"20 cable clips, black PETG\"",
                                 "ar": "صف العمل — «٢٠ مشبك كابل، PETG أسود»"],
        "mac.draft_it":      ["en": "Draft",           "ar": "صُغ"],
        "mac.drafting":      ["en": "Asking…",         "ar": "جارٍ السؤال…"],
        // Always shown, never folded away: a drafted part is a guess with
        // figures in it, and the assumptions are the only way to tell a good
        // one from a confident one.
        "mac.it_assumed":    ["en": "It assumed",      "ar": "افترض"],
        "mac.ai_no_draft":   ["en": "Nothing usable came back — fill the part in yourself.",
                              "ar": "لم يصل شيء صالح — املأ القطعة بنفسك."],
        "mac.ai_not_consented": ["en": "Switch on \"Quote from a description\" in Settings → AI assist first.",
                                 "ar": "فعّل «تسعيرة من وصف» في الإعدادات ← مساعد الذكاء أولًا."],
        "mac.ai_no_key":     ["en": "Add your provider's API key in Settings → AI assist.",
                              "ar": "أضف مفتاح المزوّد في الإعدادات ← مساعد الذكاء."],
        "mac.nav_slicers":   ["en": "Slicers", "ar": "برامج التقطيع"],
        "mac.no_slicers":    ["en": "No slicer set up yet. Khayt can look for the ones you already have.",
                              "ar": "لم يُضبط أي برنامج شرائح بعد. يستطيع خيط البحث عمّا لديك."],
        "mac.find_slicers":  ["en": "Find installed slicers", "ar": "ابحث عن البرامج المثبّتة"],
        "mac.slicers_found": ["en": "Added {n}.", "ar": "أُضيف {n}."],
        "mac.slicers_none_found": ["en": "Nothing new — everything found is already on the list.",
                                   "ar": "لا جديد — كل ما وُجد موجود في القائمة بالفعل."],
        "mac.slicer_add":    ["en": "Add\u{2026}", "ar": "إضافة\u{2026}"],
        "mac.slicer_remove": ["en": "Remove from the list", "ar": "إزالة من القائمة"],
        "mac.slicer_make_default": ["en": "Open models in this one",
                                    "ar": "افتح النماذج بهذا"],
        "mac.slicer_no_binary": ["en": "{name} does not carry a program Khayt can open.",
                                 "ar": "{name} لا يحتوي على برنامج يستطيع خيط فتحه."],
        "mac.slicer_why":    ["en": "The one with the mark is what a model opens in from the library. "
                            + "The rest stay one menu away.",
                              "ar": "البرنامج المعلَّم هو ما تُفتح به النماذج من المكتبة، والبقية على "
                            + "بُعد قائمة واحدة."],
        // Opening a model in the shop's own slicer, and the two ways it does not.
        "mac.open_in":       ["en": "Open in {name}", "ar": "افتح في {name}"],
        "mac.open_in_other": ["en": "Open in", "ar": "افتح في"],
        // A refusal, not a failure — and said as one. The path came from the
        // shop's settings, which travel in a backup and through the cloud.
        "mac.slicer_not_allowed": ["en": "Khayt will not launch \u{201C}{name}\u{201D}: that program "
                                 + "does not look like a slicer, and the path came from your settings, "
                                 + "which travel in backups and through the cloud.",
                                   "ar": "لن يشغّل خيط \u{201C}{name}\u{201D}: هذا البرنامج لا يبدو "
                                 + "شرائحيًا، والمسار جاء من إعداداتك التي تنتقل في النسخ الاحتياطية "
                                 + "وعبر السحابة."],
        "mac.slicer_missing": ["en": "{name} is not where your settings say it is.",
                               "ar": "{name} ليس في المكان الذي تشير إليه إعداداتك."],
        "mac.sync_off":      ["en": "Cloud off", "ar": "السحابة متوقفة"],
        "mac.sync_locked":   ["en": "Cloud locked", "ar": "السحابة مقفلة"],
        "mac.sync_on":       ["en": "Syncing automatically", "ar": "تُزامَن تلقائيًا"],
        "mac.sync_sending":  ["en": "Sending…", "ar": "جارٍ الإرسال…"],
        "mac.sync_waiting":  ["en": "Changes to send", "ar": "تغييرات للإرسال"],
        "mac.sync_done":     ["en": "Sent {time}", "ar": "أُرسلت {time}"],
        "mac.sync_retrying": ["en": "Not sent — trying again",
                              "ar": "لم تُرسل — تُعاد المحاولة"],
        // Why the key does not outlive the app, said where somebody hovering
        // over "Locked" will find it rather than in a document.
        "mac.sync_auto_why": ["en": "This Mac sends what you change here to Khayt Cloud on its own, "
                            + "a few seconds after each change. It needs the cloud passphrase once "
                            + "per launch — the passphrase is never stored anywhere, which is what "
                            + "keeps the cloud copy readable only by you.",
                              "ar": "يرسل هذا الماك ما تغيّره هنا إلى سحابة خيط تلقائيًا، بعد ثوانٍ "
                            + "من كل تغيير. يحتاج عبارة مرور السحابة مرة واحدة عند كل تشغيل — "
                            + "والعبارة لا تُحفظ في أي مكان، وهذا ما يبقي نسخة السحابة مقروءة لك وحدك."],
        "mac.lock_cloud":    ["en": "Lock Khayt Cloud", "ar": "قفل سحابة خيط"],
        // Asking the cloud what it holds, and offering to send what is only
        // here. The check itself writes nothing and the sheet says so before it
        // asks for a passphrase; sending is a second, deliberate press.
        "mac.check_cloud":   ["en": "Check the cloud", "ar": "فحص السحابة"],
        "mac.check_cloud_do": ["en": "Check",        "ar": "فحص"],
        "mac.check_cloud_reads": ["en": "This reads what Khayt Cloud holds and counts the difference. "
                               + "Nothing is sent, merged or changed on either side. Sending is a "
                               + "separate button, after you have seen the difference.",
                                  "ar": "يقرأ هذا ما تحتفظ به سحابة خيط ويحسب الفرق. "
                               + "لا يُرسل أو يُدمج أو يُغيَّر شيء في أيٍّ من الجهتين. والإرسال زر "
                               + "منفصل، بعد أن ترى الفرق."],
        "mac.cloud_passphrase": ["en": "Cloud passphrase", "ar": "عبارة مرور السحابة"],
        "mac.cloud_passphrase_why": ["en": "Khayt stores this nowhere — that is what makes the cloud "
                                   + "copy readable only by you. It is used once here and not kept.",
                                     "ar": "لا يخزّن خيط هذه العبارة في أي مكان — وهذا ما يجعل النسخة "
                                   + "السحابية مقروءة لك وحدك. تُستخدم مرة واحدة هنا ولا تُحفظ."],
        "mac.cloud_in_step": ["en": "This Mac and the cloud hold the same records",
                              "ar": "هذا الماك والسحابة يحملان السجلات نفسها"],
        "mac.cloud_apart":   ["en": "This Mac and the cloud are not the same",
                              "ar": "هذا الماك والسحابة ليسا متطابقين"],
        "mac.cloud_rev":     ["en": "Cloud revision",  "ar": "مراجعة السحابة"],
        "mac.cloud_folded":  ["en": "{chain} changes after the base, {applied} applied",
                              "ar": "{chain} تغييرات بعد الأساس، طُبّق منها {applied}"],
        "mac.only_here":     ["en": "Only here",       "ar": "هنا فقط"],
        "mac.only_there":    ["en": "Only in cloud",   "ar": "في السحابة فقط"],
        "mac.newer_here":    ["en": "Newer here",      "ar": "أحدث هنا"],
        "mac.cloud_apart_why": ["en": "Sending puts up what is only here and what is newer here. "
                              + "Anything the cloud holds a newer copy of is left exactly as it is — "
                              + "open Khayt on this Mac to bring those down.",
                                "ar": "يرفع الإرسال ما هو هنا فقط وما هو أحدث هنا. "
                              + "أما ما تحتفظ السحابة بنسخة أحدث منه فيُترك كما هو تمامًا — "
                              + "افتح خيط على هذا الماك لجلبه."],
        "mac.cloud_send":    ["en": "Send what is only here", "ar": "أرسل ما هو هنا فقط"],
        "mac.cloud_pull":    ["en": "Bring down what is only there",
                              "ar": "أنزل ما هو هناك فقط"],
        "mac.cloud_pulled":  ["en": "{applied} taken down, {removed} removed here. "
                            + "A backup was made first.",
                              "ar": "نُزّل {applied}، وحُذف {removed} من هنا. "
                            + "أُخذت نسخة احتياطية أولًا."],
        "mac.cloud_pull_why": ["en": "This changes the book on this Mac. A record that is newer in "
                             + "the cloud replaces the copy here; a record only this Mac has is left "
                             + "alone. Settings are never brought down, and the ledgers — waste, "
                             + "maintenance, time — are only added to.",
                               "ar": "يغيّر هذا الدفتر على هذا الماك. السجل الأحدث في السحابة يحل محل "
                             + "النسخة هنا؛ والسجل الموجود على هذا الماك وحده يُترك كما هو. "
                             + "لا تُنزَّل الإعدادات أبدًا، والسجلات — الهدر والصيانة والوقت — يُضاف إليها فقط."],
        "mac.cloud_lost_edits": ["en": "{n} change(s) made here were discarded: the record had been "
                               + "deleted on another device.",
                                 "ar": "أُلغيت {n} تغييرات أُجريت هنا: كان السجل قد حُذف على جهاز آخر."],
        "mac.cloud_sent":    ["en": "{n} sent. Khayt Cloud is now at revision {rev}.",
                              "ar": "أُرسل {n}. سحابة خيط الآن عند المراجعة {rev}."],
        // A shop whose delta chain the service refuses. Said plainly, because
        // "the whole book went up" is a different event from "one change did".
        "mac.cloud_sent_whole": ["en": "This shop cannot send changes one at a time, so the cloud's "
                               + "copy was merged in here first and the whole book sent. Khayt Cloud "
                               + "is now at revision {rev}.",
                                 "ar": "لا يستطيع هذا المحل إرسال التغييرات واحدًا تلو الآخر، لذا "
                               + "دُمجت نسخة السحابة هنا أولًا ثم أُرسل الدفتر كاملًا. سحابة خيط "
                               + "الآن عند المراجعة {rev}."],
        // WHY it cannot, and what ends it. Without this the shop sees a
        // permanent state with no cause and no way out of it: the whole book
        // goes up every time, forever, and nothing on any screen says the
        // reason is a device rather than a fault. Both remedies are the same
        // gesture — open Khayt on each machine — so it is said as one.
        "mac.cloud_sent_whole_why": ["en": "That happens when a device signed in to this shop has "
                               + "not synced yet, or is running a Khayt older than 3.6. Open Khayt "
                               + "on every machine that uses this shop, update it, and let it sync "
                               + "once; after that, changes go up one at a time again.",
                                     "ar": "يحدث ذلك عندما يكون أحد الأجهزة المسجَّلة في هذا المحل "
                               + "لم يزامن بعد، أو يعمل بإصدار من خيط أقدم من 3.6. افتح خيط على كل "
                               + "جهاز يستخدم هذا المحل، وحدّثه، ودعه يزامن مرة واحدة؛ بعدها تُرسل "
                               + "التغييرات واحدًا تلو الآخر من جديد."],
        "mac.cloud_nothing_to_send": ["en": "Nothing left to send — the cloud already has it.",
                                      "ar": "لا شيء متبقٍّ للإرسال — السحابة تحتفظ به بالفعل."],
        // No "too". It said "Settings differ too" beside a result reporting that
        // the two held the same records, which reads as a contradiction — and
        // was one, because the comparison was counting the sync's own
        // bookkeeping. Now it stands on its own and only appears when a setting
        // really has changed.
        "mac.cloud_settings_stay": ["en": "A setting here differs from the cloud's copy, and this app "
                                  + "cannot send it: a setting is one thing rather than a list of "
                                  + "records, so there is nowhere to put it in a change. Open Khayt "
                                  + "on this Mac for that.",
                                    "ar": "أحد الإعدادات هنا يختلف عن نسخة السحابة، ولا يستطيع هذا "
                                  + "التطبيق إرساله: الإعداد شيء واحد لا قائمة سجلات، فلا موضع له في "
                                  + "التغيير. افتح خيط على هذا الماك من أجله."],
        // The machine's own memory of what it has printed.
        "mac.read_history":  ["en": "Read the printer\u{2019}s history",
                              "ar": "قراءة سجل الطابعة"],
        "mac.reading_history": ["en": "Reading\u{2026}", "ar": "جارٍ القراءة\u{2026}"],
        "mac.history_read":  ["en": "Jobs read from the printer:", "ar": "أعمال قُرئت من الطابعة:"],
        "mac.history_failed": ["en": "Could not read the printer\u{2019}s history:",
                               "ar": "تعذّرت قراءة سجل الطابعة:"],
        "mac.wear_from_printer": ["en": "counted from the printer\u{2019}s own history",
                                  "ar": "محسوب من سجل الطابعة نفسها"],
        // Settings
        "mac.revert":        ["en": "Revert",       "ar": "تراجع"],
        "mac.settings_saved": ["en": "Saved.",      "ar": "حُفظ."],
        "mac.settings_sample": ["en": "The sample shop's settings are for looking at.",
                                "ar": "إعدادات المحل التجريبي للعرض فقط."],
        "mac.preferences":   ["en": "Preferences",  "ar": "التفضيلات"],
        "mac.tax_none":      ["en": "No tax is charged.", "ar": "لا تُحتسب ضريبة."],
        // Writing a product down. The catalogue could be read on this Mac and
        // not added to, so a shop wanting a new product had to go to the other
        // app for it.
        "mac.new_product":   ["en": "New product",  "ar": "منتج جديد"],
        // Making a product FROM a model. Mac-only: the other app's catalogue
        // has no route from the library at all, only a `fileRef` field a shop
        // types a filename into.
        "mac.product_from_model": ["en": "Make a product from this",
                                   "ar": "أنشئ منتجًا من هذا"],
        // A printer that changed address. Mac-only wording: the other app
        // words this on its machines page and does not share the strings.
        "mac.moved_find": ["en": "Find it on the network",
                           "ar": "ابحث عنه في الشبكة"],
        // What a model would take. Mac-only wording: the other app puts these
        // on its estimator settings panel, worded for a form rather than for a
        // model somebody is looking at.
        "mac.est_title": ["en": "If you print this", "ar": "إذا طبعت هذا"],
        // WHERE THE RATE CAME FROM, because a number a shop cannot attribute is
        // a number it cannot check.
        "mac.est_learned": ["en": "From your own printers — {rate} g/hour, measured across {jobs} jobs.",
                            "ar": "من طابعاتك — {rate} غرام/ساعة، مقيسة على {jobs} أعمال."],
        "mac.est_default": ["en": "Using Khayt's default rate. Record what a few prints actually took and this learns your own.",
                            "ar": "باستخدام معدّل خيط الافتراضي. سجّل ما استغرقته بعض الطبعات فعليًا وسيتعلّم معدّلك."],
        "mac.est_filament": ["en": "Filament", "ar": "الخيط"],
        "mac.est_time": ["en": "Time", "ar": "الوقت"],
        // WHAT THE FLAG ACTUALLY MEANS, arrived at the long way. It fired on
        // every model at first because the bounding box was not being passed,
        // so I reworded it to "Khayt does not stand behind these figures" —
        // which was right about the flag and wrong about the cause. With the
        // box passed and a measured area, the only way it fires is a model that
        // is nearly all wall, where the shell term has swallowed the part and
        // there is no infill headroom left. So the original wording was right
        // for the fixed code.
        "mac.est_thin_walled": ["en": "Mostly wall, so the weight is a rough guide — check it before you quote.",
                                "ar": "معظمه جدار، فالوزن تقديري — راجعه قبل التسعير."],
        // The estimator's own settings.
        "mac.est_section": ["en": "Estimating from a model", "ar": "التقدير من مجسّم"],
        "mac.est_density": ["en": "Filament density (g/cm³)", "ar": "كثافة الخيط (غرام/سم³)"],
        "mac.est_infill": ["en": "Default infill (%)", "ar": "التعبئة الافتراضية (%)"],
        "mac.est_wall": ["en": "Wall thickness (mm)", "ar": "سماكة الجدار (مم)"],
        "mac.est_waste": ["en": "Waste (%)", "ar": "الهدر (%)"],
        "mac.est_wall_hint": ["en": "Perimeters plus top and bottom skin. Khayt works out how much of a part is shell from this and its surface area.",
                              "ar": "المحيطات مع الطبقة العلوية والسفلية. يحسب خيط من هذا ومن مساحة السطح كم من الجزء قشرة."],
        "mac.est_rate_hint": ["en": "How fast your printers run is not asked for — Khayt learns it from jobs whose real weight and duration were recorded.",
                              "ar": "لا نسأل عن سرعة طابعاتك — يتعلّمها خيط من الأعمال التي سُجّل وزنها ومدّتها الحقيقية."],
        "mac.moved_looking": ["en": "Looking…", "ar": "جارٍ البحث…"],
        "mac.moved_here": ["en": "It answers at {host} now",
                           "ar": "يستجيب الآن على {host}"],
        // The two cases the rule separates, said differently on purpose: one is
        // identity and one is a guess, and the button must not read the same.
        "mac.moved_apply": ["en": "Point Khayt at it",
                            "ar": "وجّه خيط إليه"],
        "mac.moved_maybe": ["en": "This might be it — check before you apply",
                            "ar": "قد يكون هذا — تحقّق قبل التطبيق"],
        "mac.moved_done": ["en": "{name} is pointed at {host}.",
                           "ar": "تم توجيه {name} إلى {host}."],
        "mac.moved_failed": ["en": "Khayt could not repair that machine's address.",
                             "ar": "لم يتمكّن خيط من إصلاح عنوان هذه الآلة."],
        "mac.moved_none_on_network": ["en": "Nothing answered on the network.",
                                      "ar": "لا شيء استجاب في الشبكة."],
        "mac.moved_none_matched": ["en": "Printers answered, but none of them is this machine.",
                                   "ar": "استجابت طابعات، لكن ليست أيٌّ منها هذه الآلة."],
        "mac.product_from_file_failed": ["en": "Khayt could not read that model's figures.",
                                         "ar": "لم يتمكّن خيط من قراءة أرقام هذا المجسّم."],
        // NAMED, not swallowed. A field the file could not answer for is left
        // at zero, and a zero that looks typed is worse than a blank somebody
        // was told about.
        "mac.product_from_file_missing": ["en": "Filled in from the file. It could not answer for: {fields} — check those before you sell it.",
                                          "ar": "تم التعبئة من الملف. ولم يُجب عن: {fields} — راجعها قبل البيع."],
        // The catalogue's two layouts. Said as tooltips on the toggle, so they
        // are the only words a shop ever reads for them.
        // IMPORT, said as a shop would look for it. The menu item is called
        // "Add model" and is in the Book menu; somebody with a folder of
        // downloads searches for "import", so the toolbar button says that.
        "mac.import_models": ["en": "Import models", "ar": "استيراد مجسمات"],
        "mac.import_models_hint": ["en": "Add models from a folder — or drag them onto the library.",
                                   "ar": "أضف مجسمات من مجلد — أو اسحبها إلى المكتبة."],
        // Khayt's own help. macOS supplies an empty Help menu; an app that
        // leaves it empty has said it has none.
        // ── WHAT TO RUN NEXT ─────────────────────────────────────────
        //
        // `lib/auto-dispatch.js` answers in KEYS, so the rule does not decide
        // which language the shop reads. These are them. Kept here rather than
        // in the shared catalogue because the dispatcher is this app's — see
        // the note at the top of this file about nine languages.
        // Telling a printer what to do — which this app could not, on any of
        // the seven protocols it can watch.
        // Finding a printer, so nobody types an address off the front of a
        // machine across the room.
        "mac.find_printers":  ["en": "Find printers", "ar": "ابحث عن طابعات"],
        "mac.find_looking":   ["en": "Looking on this network…", "ar": "يبحث في هذه الشبكة…"],
        // NOT "no printers on this network": this app cannot tell an empty
        // network from a refused permission, and saying the first when it is
        // the second sends somebody hunting for a fault in the printer.
        "mac.find_none":      ["en": "Nothing answered. If the printer is on and on this network, check that Khayt is allowed Local Network access in System Settings › Privacy & Security.",
                               "ar": "لم يُجب شيء. إن كانت الطابعة تعمل وعلى هذه الشبكة، فتحقّق من السماح لخيط بالوصول إلى الشبكة المحلية في إعدادات النظام ← الخصوصية والأمان."],
        "mac.find_add":       ["en": "Add",           "ar": "أضف"],
        "mac.find_again":     ["en": "Look again",    "ar": "ابحث مرة أخرى"],
        "mac.find_unsupported": ["en": "Khayt cannot talk to this one yet",
                                 "ar": "لا يستطيع خيط التحدث إلى هذه بعد"],
        "mac.printer_pause":  ["en": "Pause",        "ar": "إيقاف مؤقت"],
        "mac.printer_resume": ["en": "Resume",       "ar": "استئناف"],
        "mac.printer_cancel": ["en": "Cancel print", "ar": "إلغاء الطباعة"],
        "mac.cancel_ask":     ["en": "Cancel the print on {machine}?",
                               "ar": "إلغاء الطباعة على {machine}؟"],
        "mac.cancel_why":     ["en": "Everything printed so far is scrap. The printer will not ask again.",
                               "ar": "كل ما طُبع حتى الآن خردة. ولن تسأل الطابعة مرة أخرى."],
        // Dropping one object from a plate.
        "mac.drop_object":    ["en": "Drop one object", "ar": "إسقاط مجسم"],
        "mac.drop_it":        ["en": "Drop it",       "ar": "أسقِطه"],
        "mac.drop_printing_now": ["en": "printing now", "ar": "تُطبع الآن"],
        "mac.drop_forever":   ["en": "This cannot be undone. What has already printed of it stays on the plate, and the rest is never printed.",
                               "ar": "لا يمكن التراجع عن هذا. يبقى ما طُبع منه على الطاولة، ولا يُطبع الباقي أبداً."],
        "mac.drop_unsupported": ["en": "This printer does not report the objects on its plate. Klipper needs its exclude_object module, and the file must have been sliced with object markers.",
                                 "ar": "لا تبلّغ هذه الطابعة عن المجسمات على طاولتها. يحتاج Klipper إلى وحدة exclude_object، ويجب أن يكون الملف مقطّعاً بعلامات المجسمات."],
        "mac.drop_nothing":   ["en": "Nothing is printing on this machine.",
                               "ar": "لا شيء يُطبع على هذه الآلة."],
        "mac.dispatch_title": ["en": "Next up",      "ar": "التالي"],
        "mac.dispatch_none":  ["en": "Nothing is waiting for a machine.",
                               "ar": "لا شيء ينتظر آلة."],
        "mac.dispatch_send":  ["en": "Send",         "ar": "أرسِل"],
        "ad.next_in_queue":   ["en": "Next in the queue", "ar": "التالي في الطابور"],
        "ad.same_material":   ["en": "Already loaded with this material",
                               "ar": "محمّلة بهذه الخامة أصلاً"],
        "ad.materials_unknown": ["en": "This machine lists no materials — check it can print this",
                                 "ar": "لا تذكر هذه الآلة خامات — تأكّد أنها تطبع هذه"],
        // The one that matters. An idle printer is very often an idle printer
        // with yesterday's part still bolted to the plate.
        "ad.bed_not_clear":   ["en": "Bed not cleared since its last print",
                               "ar": "لم تُفرَّغ الطاولة منذ آخر طباعة"],
        "ad.bed_unknown":     ["en": "Nobody has said the bed is clear",
                               "ar": "لم يقل أحد إن الطاولة فارغة"],
        "ad.busy":            ["en": "Printing",     "ar": "تطبع"],
        "ad.printer_error":   ["en": "Reporting a fault", "ar": "تبلّغ عن عطل"],
        "ad.no_reading":      ["en": "Not answering", "ar": "لا تجيب"],
        "ad.no_printer":      ["en": "No printer linked", "ar": "لا طابعة مرتبطة"],
        "ad.held":            ["en": "Held back",    "ar": "موقوفة"],
        "mac.bed_cleared":    ["en": "Bed is clear", "ar": "الطاولة فارغة"],
        "mac.help_title":    ["en": "Khayt Help",   "ar": "مساعدة خيط"],
        "mac.help_search":   ["en": "Search help",  "ar": "ابحث في المساعدة"],
        "mac.help_none":     ["en": "No help article is selected",
                              "ar": "لم يُختَر أي موضوع"],
        "mac.view_list":     ["en": "List",         "ar": "قائمة"],
        "mac.view_grid":     ["en": "Grid",         "ar": "شبكة"],
        "mac.edit_product":  ["en": "Edit product", "ar": "تعديل المنتج"],
        "mac.product_need_name": ["en": "A product needs a name in at least one language.",
                                  "ar": "يحتاج المنتج إلى اسم بلغة واحدة على الأقل."],
        // Said on the sheet, because the alternative is a shop assuming the
        // parts were dropped when it saved. PHOTOS CAME OFF THIS LIST when the
        // sheet learnt to edit them — a sentence promising to leave something
        // alone, on a screen that now changes it, is worse than no sentence.
        "mac.product_kept":  ["en": "Parts, prices per quantity and documents "
                              + "stay as they are — edit those in Khayt.",
                              "ar": "تبقى القطع وأسعار الكميات والمستندات كما هي — عدّلها في خيط."],
        // ── A PRODUCT'S PICTURES ──────────────────────────────────────────
        //
        // The kind labels themselves are NOT here: `pe.kind_render` and its
        // siblings are in the shared locale, so the word a shop reads beside a
        // photo is the same in both apps and in all nine languages. Only what
        // this sheet says around them is new.
        "mac.pictures":      ["en": "Pictures",        "ar": "الصور"],
        "mac.add_picture":   ["en": "Add Pictures…",   "ar": "إضافة صور…"],
        "mac.no_pictures":   ["en": "No pictures yet", "ar": "لا صور بعد"],
        "mac.make_main":     ["en": "Use as the main picture", "ar": "اجعلها الصورة الرئيسية"],
        "mac.remove_picture": ["en": "Remove Picture", "ar": "إزالة الصورة"],
        // What the first picture IS, which is the thing a shop cannot guess
        // from a strip of thumbnails.
        "mac.main_picture_is": ["en": "The first picture is the one the catalogue, "
                                + "the storefront and the invoice use.",
                                "ar": "الصورة الأولى هي التي يستخدمها الكتالوج والمتجر والفاتورة."],
        "mac.picture_caption": ["en": "Caption", "ar": "تعليق"],
        "mac.delete_product": ["en": "Delete product", "ar": "حذف المنتج"],
        // The document a customer is handed
        "mac.save_pdf":      ["en": "Save PDF",     "ar": "حفظ PDF"],
        "mac.saved_to":      ["en": "Saved as",     "ar": "حُفظ باسم"],
        "mac.no_document":   ["en": "This job's invoice could not be built.",
                              "ar": "تعذّر إنشاء فاتورة هذا العمل."],
    ]

    /// The Khayt keys this app leans on. Listed so a test can prove every one of
    /// them still exists in every bundled language — a key that disappears from
    /// the shared catalogue would otherwise surface as a raw `queue.printing`
    /// sitting in the sidebar.
    /// The shared keys this app uses. `PrintFactLines` declares its own, so a
    /// key added to that panel cannot be forgotten here.
    static let borrowed = PrintFactLines.borrowedKeys + [
        // The product editor. Khayt's own words for the same two fields on its
        // product form — borrowed rather than re-supplied, so the two editors
        // cannot come to call one thing by two names. The group's key is
        // `plib.group`, not `pe.group`: it is the print library's word, and the
        // Electron form borrows it too.
        "pe.description", "plib.group",
        // The tax on a purchase. BORROWED, not supplied: Electron's expense
        // form needs the same words, so they went into the shared catalogue in
        // all nine languages — and a key this app also supplied would shadow
        // Khayt's, which is what `a borrowed key never shadows one this app
        // supplies` refuses. One vocabulary, both apps.
        // The printer's credential field. Electron's machine editor asks for
        // the same thing, so the word is Khayt's rather than this app's — and
        // supplying it here would shadow eight other languages with two.
        "mach.api_key",
        "exp.vat_paid", "exp.vat_paid_hint", "exp.vat_reclaimed", "exp.vat_due",
        "inv.costs_a_job",
        "queue.quote", "queue.pending", "queue.printing", "queue.completed",
        "queue.delivered", "doc.client", "doc.due", "doc.notes", "common.total",
        "an.range.month", "an.range.last_month", "an.range.quarter", "an.range.year",
        "an.range.all",
        "flow.owed", "flow.paid", "plib.group", "plib.unfiled", "plib.favorite",
        "plib.material", "plib.tags_short", "plib.group_ph", "set.store_size",
        // What a slicer's config says about a model — see `LibraryInspector`.

        "tab.clients", "doc.invoice", "doc.quotation", "common.close",
        "inv.qr_failed",
        "qc.weight_typed",
        // The machines
        "mach.need_name",
        "mach.saved",
        "mach.edit",
        "mach.add",
        "mach.color", "mach.name", "mach.name_ph", "mach.nozzle_installed", "mach.nozzle_material", "mach.nozzle_threshold", "mach.printer_model", "mach.printer_model_hint", "mach.printer_model_ph", "mach.target_hours",
        // The shelf
        "inv.colour_variant", "inv.lot", "inv.material_ph", "inv.opened_on", "inv.price_history", "inv.reorder_point",
        "set.last_backup",
        // Reports
        "an.aged_receivables",
        "an.aged_bucket_days", "an.aged_col_client", "an.aged_col_days", "an.aged_col_order", "an.aged_col_owed", "an.aged_col_project", "an.aged_none", "an.aged_orders_n",
        "an.pnl_empty", "an.pnl_expenses", "an.pnl_net", "an.pnl_orders", "an.pnl_period", "an.pnl_title", "an.pnl_vat", "an.revenue",
        // Expenses and waste
        "common.cancel", "common.delete", "exp.add_btn", "exp.add_title", "exp.amount",
        "exp.budget_title", "exp.cat.electricity", "exp.cat.filament",
        "exp.cat.maintenance", "exp.cat.other", "exp.cat.shipping", "exp.cat.tools",
        "exp.category", "exp.date", "exp.no_budgets", "exp.note", "exp.note_ph",
        "exp.order_ref", "exp.order_ref_ph", "exp.over_budget", "exp.recurring",
        "exp.recurring_annually", "exp.recurring_monthly",
        "exp.recurring_quarterly", "exp.sum.expenses", "exp.summary", "exp.title",
        "mach.unassigned", "waste.add", "waste.date", "waste.deduct_inv", "waste.empty",
        "waste.est_cost", "waste.failure_breakdown", "waste.failure_type",
        "waste.ft.bed_adhesion", "waste.ft.design_issue", "waste.ft.material_quality",
        "waste.ft.nozzle_jam", "waste.ft.operator_error", "waste.ft.other",
        "waste.ft.power_failure", "waste.ft.stringing", "waste.ft.warping",
        "waste.log_btn", "waste.material", "waste.printer", "waste.reason",
        "waste.reason_ph", "waste.title", "waste.total_cost", "waste.total_entries",
        "waste.total_weight", "waste.weight",
        // The Settings window
        "common.save", "day.fri", "day.mon", "day.sat", "day.sun", "day.thu",
        "day.tue", "day.wed", "pay.method.applepay", "pay.method.cash",
        "pay.method.mada", "pay.method.other", "pay.method.stcpay",
        "pay.method.transfer", "pay.method.visa", "set.accepted", "set.account_holder",
        "set.auto_deduct", "set.bank_name", "set.bank_section", "set.biz_contact",
        "set.biz_identity", "set.biz_tax", "set.cr", "set.currency", "set.email",
        "set.enable_vat", "set.enable_zatca", "set.iban", "set.iban_ph",
        "set.inv_accent", "set.inv_bilingual", "set.inv_bilingual_auto",
        "set.inv_bilingual_both", "set.inv_bilingual_single", "set.inv_bilingual_zatca",
        "set.inv_second_lang", "set.inv_template", "set.inv_tmpl_classic",
        "set.inv_tmpl_minimal", "set.inv_tmpl_modern", "set.invoice_prefix",
        "set.invoice_section", "set.language", "set.lead_publish",
        "set.lead_safety_hint", "set.lead_title", "set.locale_section", "set.low_stock",
        "set.nav_biz", "set.nav_invoice", "set.nav_ops", "set.nav_payments",
        "set.ops_section", "set.payment_instructions", "set.phone", "set.prefs_section",
        "set.qc_enabled", "set.qc_head", "set.qc_require_inspector",
        "set.qc_require_photo", "set.quote_prefix", "set.rush_fee_enabled",
        "set.stock_section", "set.tax_country", "set.tax_country_custom",
        "set.tax_mode", "set.tax_mode_example", "set.tax_mode_exclusive",
        "set.tax_mode_inclusive", "set.use_arabic_nums", "set.use_hijri", "set.vat",
        "set.vat_rate", "set.wh_hint", "set.wip_enforce_hard", "set.wip_limits",
        "set.working_hours", "set.worldwide_section",
    ]
}
