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
    private nonisolated static let counter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

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
        // ── THE VALUE MAY CARRY ITS OWN `{n}` ────────────────────────────
        //
        // Two shapes, because the catalogue has both. A value written as
        // "{n} models" places the numeral ITSELF, which is the only way to put
        // it anywhere but the front — and Arabic wants it elsewhere often
        // enough that this matters. A value written as "models" gets the old
        // behaviour: the numeral in front, a space, the word.
        //
        // The first shape is also the one §5 prefers, because it substitutes
        // rather than concatenating a numeral onto a word in whatever the
        // paragraph's direction happens to be.
        let said = callIt(n == 1 ? key + "_one" : key)
        let number = Self.counter.string(from: NSNumber(value: n)) ?? String(n)
        if said.contains("{n}") {
            return said.replacingOccurrences(of: "{n}", with: number)
        }
        // ── AND A FORM THAT SPELLS THE NUMBER OUT GETS NO NUMERAL ─────────
        //
        // §11: Arabic's natural `one` carries the number in words — آلة واحدة
        // is "one machine" — so a numeral in front of it reads as "one one
        // machine". The dual (آلتان) returns earlier, above.
        //
        // The test is the VALUE, not the language or the count: `يوم` is bare
        // "day" and wants its numeral, `آلة واحدة` already has one. Checking
        // for the word rather than assuming by language is what keeps the
        // first of those working.
        if n == 1, said.contains("واحد") { return said }
        // A plain space, not a non-breaking one. Binding the numeral to the
        // word is tempting and wrong here: eight existing tests read this
        // output back and compare it to "2 days", and a caller that has to
        // know which invisible character came out is a caller that will get it
        // wrong. The `{n}` form above is where a value places its own numeral.
        return number + " " + said
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
        "mac.all_jobs":      ["en": "Jobs",          "ar": "الأعمال"],
        "mac.pipeline":      ["en": "Pipeline",      "ar": "المسار"],
        "mac.board":         ["en": "Board",         "ar": "لوحة المهام"],
        "mac.nothing_here":  ["en": "nothing here",  "ar": "لا شيء هنا"],
        // A catalogue chip, and the one worth interrupting for: a product a
        // shop cannot sell sitting among ones it can.
        "mac.no_price_yet":  ["en": "No price",      "ar": "بلا سعر"],
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
        "mac.band_none_answering": ["en": "Not answering — free hours unknown",
                                    "ar": "لا تجيب — الساعات المتاحة غير معروفة"],
        "mac.band_none_answering_why": ["en": "Khayt cannot say when these printers are free until they answer. Check that they are switched on and on the network.",
                                        "ar": "لا يستطيع خيط معرفة متى تتفرغ هذه الطابعات حتى تجيب. تأكد أنها مشغّلة ومتصلة بالشبكة."],
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
        // An hour after a figure, as short as the gram beside it.
        "mac.unit_h":  ["en": "h",      "ar": "س"],
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
        "mac.band_state_offline": ["en": "Not answering", "ar": "لا تجيب"],
        "mac.band_state_down":    ["en": "Maintenance", "ar": "صيانة"],
        "mac.band_offline_note": ["en": "not answering — its hours are left out of the free total until it does", "ar": "لا تجيب — ساعاتها خارج إجمالي الوقت المتاح حتى تجيب"],
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
        "mac.remeasured":    ["en": "{n} models were measured again — their sizes were wrong.",
                              "ar": "تم قياس {n} من النماذج من جديد — كانت أبعادها خاطئة."],
        "mac.move_no_engine": ["en": "The shared rules did not start, so nothing may be moved.",
                               "ar": "لم تبدأ القواعد المشتركة، فلا يمكن نقل شيء."],
        "mac.move_unhandled": ["en": "This move asks for something this app does not know how to do, so nothing was changed.",
                               "ar": "يتطلب هذا النقل أمراً لا يعرفه هذا التطبيق، فلم يتغير شيء."],
        "mac.move_reaches":  ["en": "Finishing this here would skip",
                              "ar": "إنهاء العمل هنا سيتخطى"],
        // WHAT TO FIX, NOT WHERE TO GO. This used to read "Do it in Khayt so
        // it is sent" — which sent a shop to another app rather than telling
        // it that a mail provider it configured is one this app has no door
        // for. Every provider the other app sends through, this one now sends
        // through too, so reaching here means the setting is the problem.
        "mac.move_in_khayt": ["en": "Set up how these are sent in Settings, then move it.",
                              "ar": "اضبط طريقة الإرسال في الإعدادات ثم انقله."],
        "mac.reach_webhooks":      ["en": "a webhook",        "ar": "إشعار ويب"],
        "mac.reach_event_webhook": ["en": "an order webhook", "ar": "إشعار ويب للطلب"],
        "mac.reach_telegram":      ["en": "a Telegram message", "ar": "رسالة تيليجرام"],
        // SMTP used to be named here, because a shop on its own relay was the
        // one case this app could not carry. `SmtpClient` carries it now, so
        // what is left is a provider this app has never heard of — which the
        // word "email" describes and a provider name would not.
        "mac.reach_email":         ["en": "an email", "ar": "بريداً إلكترونياً"],
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
        "mac.update_part": ["en": "Update part", "ar": "حدّث الجزء"],
        "mac.plate_part": ["en": "{name} — plate {n}", "ar": "{name} — اللوح {n}"],
        "mac.plates": ["en": "Plates", "ar": "الألواح"],
        "mac.plates_all": ["en": "All", "ar": "الكل"],
        "mac.plate_chip": ["en": "{n} · {time} · {grams} g", "ar": "{n} · {time} · {grams} غ"],
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
        // The heading over a customer's schedule in their pane. Khayt's own
        // key for it, `rec.enable`, is the checkbox's sentence — "Recurring
        // order (auto-create on schedule)" — and a heading is not a sentence.
        "mac.standing_order": ["en": "Standing order", "ar": "طلب دوري"],
        // The P&L's grain. Khayt's own title names the quarter and has no
        // word for the other choice.
        // The P&L's name WITHOUT its grain. The shared "Profit & Loss by
        // Quarter" sat as a tab beside a By quarter / By month switch, so the
        // tab repeated the switch and contradicted it once Month was chosen.
        "mac.pnl_title":      ["en": "Profit & Loss", "ar": "الأرباح والخسائر"],
        "mac.by_quarter":     ["en": "By quarter", "ar": "بالربع"],
        "mac.by_month":       ["en": "By month",   "ar": "بالشهر"],
        "mac.edit_customer": ["en": "Edit Customer",  "ar": "تعديل العميل"],
        "mac.no_record":     ["en": "Not written down yet",
                              "ar": "غير مسجّل بعد"],
        "mac.write_them_down": ["en": "Write them down",
                                "ar": "تسجيل العميل"],
        "mac.what_went_wrong": ["en": "What went wrong?", "ar": "ما الذي حدث؟"],
        // (غ), the ONE Arabic gram: the shared catalogue's `common.grams` is غ
        // (it was جم until Sep 2026, beside غ, غرام and a Latin g on other
        // screens), and that is the abbreviation every weight in this app
        // prints. Two spellings of the gram in one app is a typo with a
        // rationale.
        "mac.wasted":        ["en": "Filament wasted (g)", "ar": "الخيط المهدور (غ)"],
        "mac.board_unplaced": ["en": "{n} job(s) are in a stage this board has no column for.",
                               "ar": "{n} من الأعمال في مرحلة لا عمود لها في لوحة المهام."],
        // The board draws work in flight; delivered and cancelled jobs leave it.
        // Said, so a shop whose every job is finished is not shown eight empty
        // lanes and left to wonder where its jobs went.
        "mac.board_finished_elsewhere": ["en": "{n} finished job(s) left the board when delivered or cancelled. They are all in Jobs.",
                                         "ar": "{n} من الأعمال المنتهية خرجت من لوحة المهام بعد التسليم أو الإلغاء، وكلها في قائمة الأعمال."],
        "mac.board_open_jobs": ["en": "Show in Jobs", "ar": "اعرضها في الأعمال"],
        // SENTENCE CASE, as the rest of the Mac app is. Khayt's shared locale
        // says "Issue Gift Card", "Gift Card Code", "Failure Category" and
        // "+ Add Supplier"; those strings are the Electron app's, so the Mac
        // asks for its own rather than recasing nine languages under it.
        "mac.issue_gift_card": ["en": "Issue gift card", "ar": "إصدار بطاقة هدية"],
        "mac.gift_card_code":  ["en": "Gift card code",  "ar": "رمز بطاقة الهدية"],
        "mac.failure_category": ["en": "Failure category", "ar": "فئة الفشل"],
        "mac.add_supplier":    ["en": "Add supplier",    "ar": "إضافة مورد"],
        "mac.edit_supplier":   ["en": "Edit supplier",   "ar": "تعديل المورد"],
        // A shop that has never logged waste has not done a great job — it has
        // not started. The shared "great job!" praised an empty book.
        // The expenses table's order column. The shared `exp.order_ref` is the
        // sheet's field label, "(optional)" and all, and did not fit a column.
        "mac.expense_order_col": ["en": "Order", "ar": "الطلب"],
        "mac.waste_empty":     ["en": "No waste logged yet.", "ar": "لم يُسجَّل أي هدر بعد."],
        "mac.library":       ["en": "Library",       "ar": "المكتبة"],
        "mac.all_models":    ["en": "Library",       "ar": "المكتبة"],
        "mac.people":        ["en": "People",        "ar": "الأشخاص"],
        "mac.customers":     ["en": "Customers",     "ar": "العملاء"],
        // Stage — the one status Khayt has no word for
        "mac.cancelled":     ["en": "Cancelled",     "ar": "ملغى"],
        // The submenu that holds the stages, wherever a job is right-clicked.
        // The tooltip on the library breadcrumb's way out of a folder.
        "mac.leave_group":   ["en": "Back to the whole library", "ar": "العودة إلى كل المكتبة"],
        "mac.move_to":       ["en": "Move to",       "ar": "نقل إلى"],
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
        "mac.full_spool":   ["en": "Full spool", "ar": "البكرة كاملة"],
        "mac.mc_needs_full": ["en": "What a kilo costs needs each spool's full weight. Edit a spool and fill in Full spool (1,000 g for a 1 kg roll).", "ar": "تكلفة الكيلو تحتاج وزن كل بكرة كاملة. عدّل البكرة واملأ «البكرة كاملة» (1,000 غ لبكرة 1 كغ)."],
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
        // Three reports this app could not draw until it bundled their rules,
        // and the sentences each needs that the shared catalogue has no key
        // for — every one of them says something about what the chart above
        // is NOT, which is why none of them existed for the other app's
        // version of the same chart.
        "mac.rt_all_time":   ["en": "{n} ratings in total, including months before this chart.",
                              "ar": "{n} تقييماً إجمالاً، بما فيها أشهر سابقة لهذا الرسم."],
        "mac.rt_thin":       ["en": "Too few ratings yet to read this as a score.",
                              "ar": "التقييمات أقل من أن تُقرأ كدرجة بعد."],
        "mac.rt_none":       ["en": "No ratings yet. Customers are asked when you send them the job's page.",
                              "ar": "لا توجد تقييمات بعد. يُسأل العملاء عند إرسال صفحة الطلب إليهم."],
        "mac.cs_unrecorded": ["en": "No customer has a source recorded yet — set one on a customer to see where your work comes from.",
                              "ar": "لم يُسجَّل مصدر لأي عميل بعد — حدِّد مصدراً لعميل لتعرف من أين يأتي عملك."],
        "mac.cs_unset":      ["en": "Not recorded",
                              "ar": "غير مسجَّل"],
        "mac.mc_no_service": ["en": "No servicing was logged against a machine in {year}.",
                              "ar": "لم تُسجَّل صيانة على أي آلة في {year}."],
        "mac.mc_sold":       ["en": "This machine is no longer in the fleet — the cost is kept because the money still left the shop.",
                              "ar": "لم تعد هذه الآلة ضمن الأسطول — أُبقيت التكلفة لأن المال خرج فعلاً."],
        // The service log — what was DONE to a machine, as against the
        // schedule above it saying what it is due for.
        "mac.sl_add":        ["en": "Record a service",
                              "ar": "تسجيل صيانة"],
        "mac.sl_total":      ["en": "Spent on this machine",
                              "ar": "أُنفق على هذه الآلة"],
        "mac.sl_more":       ["en": "and {n} earlier",
                              "ar": "و{n} أقدم"],
        "mac.sl_as_expense": ["en": "Also record this as an expense",
                              "ar": "سجِّلها أيضاً كمصروف"],
        "mac.sl_as_expense_why": ["en": "This machine's profit already has its servicing taken off it, so recording the repair as an expense as well counts the money twice. Tick this only if you keep maintenance in your expenses.",
                              "ar": "رِبح هذه الآلة مخصوم منه أصلاً تكلفة صيانتها، لذا تسجيل الإصلاح كمصروف أيضاً يحتسب المبلغ مرتين. علِّم هذا فقط إن كنت تُدرج الصيانة ضمن مصروفاتك."],
        "mac.dt_none":       ["en": "No machine has been booked out of action in these months.",
                              "ar": "لم تُسجَّل أي آلة خارج الخدمة في هذه الأشهر."],
        "mac.mpl_hours":     ["en": "Hours run",
                              "ar": "ساعات التشغيل"],
        "mac.mpl_estimated": ["en": "{n} estimated",
                              "ar": "{n} تقديري"],
        "mac.mpl_no_target": ["en": "Utilisation is blank because no machine has target hours a day set — add it on a machine to see how hard it is working against what you wanted.",
                              "ar": "الاستغلال فارغ لأنه لم تُحدَّد ساعات مستهدفة يومياً لأي آلة — أضفها على آلة لترى مدى تشغيلها مقابل ما أردته."],
        // Setting up what a machine is due for — the schedule half of
        // maintenance, which this app could read and never write.
        "mac.mt_new":        ["en": "Add a task",
                              "ar": "إضافة مهمة"],
        // A photograph of the finished print, which this app could draw and
        // never take.
        "mac.lp_photo":      ["en": "Photo",
                              "ar": "صورة"],
        "mac.lp_drop":       ["en": "Drop a photo here",
                              "ar": "أفلِت صورة هنا"],
        "mac.lp_add":        ["en": "Add a photo",
                              "ar": "إضافة صورة"],
        "mac.lp_replace":    ["en": "Replace photo",
                              "ar": "استبدال الصورة"],
        "mac.lp_remove":     ["en": "Remove photo",
                              "ar": "إزالة الصورة"],
        "mac.lp_action":     ["en": "Add a photo",
                              "ar": "إضافة صورة"],
        "mac.lp_removed":    ["en": "Remove photo",
                              "ar": "إزالة الصورة"],
        "mac.lp_why":        ["en": "A photo of the finished print is shown instead of the generated preview — it is what somebody is trying to recognise.",
                              "ar": "تظهر صورة الطباعة المنتهية بدل المعاينة المولَّدة — فهي ما يحاول المرء التعرّف عليه."],
        "mac.mt_edit":       ["en": "Edit task",
                              "ar": "تعديل المهمة"],
        "mac.mt_why_interval": ["en": "Set hours, days, or both — a nozzle wears by hours and a filter ages by days.",
                              "ar": "حدِّد ساعات أو أياماً أو كليهما — الفوهة تتآكل بالساعات والمرشِّح يتقادم بالأيام."],
        "mac.mt_edit_keeps": ["en": "Changing the interval does not mark the task done — if it is overdue now, it stays overdue.",
                              "ar": "تغيير الفترة لا يعني إنجاز المهمة — إن كانت متأخرة الآن فستبقى متأخرة."],
        "mac.ec_reclaimed":  ["en": "{amount} of tax on these is reclaimable, so it is not charged as a cost.",
                              "ar": "{amount} من الضريبة على هذه قابلة للاسترداد، لذا لا تُحتسب تكلفةً."],
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
        "mac.markup":        ["en": "Markup", "ar": "نسبة الإضافة"],
        "mac.spool_repair_done": ["en": "{n} products were costed on the grams left on a spool rather than its size, and have been re-priced.", "ar": "كانت تكلفة {n} منتجات محسوبة على الغرامات المتبقية في البكرة بدل حجمها، وأُعيد تسعيرها."],
        "mac.spool_repair_done_one": ["en": "{n} product was costed on the grams left on a spool rather than its size, and has been re-priced.", "ar": "كانت تكلفة منتج واحد محسوبة على الغرامات المتبقية في البكرة بدل حجمها، وأُعيد تسعيره."],
        "mac.spool_repair_done_two": ["en": "{n} products were costed on the grams left on a spool rather than its size, and have been re-priced.", "ar": "كانت تكلفة منتجَين محسوبة على الغرامات المتبقية في البكرة بدل حجمها، وأُعيد تسعيرهما."],
        "mac.lock_lost":     ["en": "Another app has this book open now, so this Mac has stopped changing it. Close the book there, then reopen it here to make changes.", "ar": "دفترك مفتوح الآن في تطبيق آخر، لذا توقّف هذا الماك عن تعديله. أغلق الدفتر هناك ثم افتحه هنا من جديد لتجري تغييرات."],
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
        // The same, when it also reached the library — which is the ordinary
        // case. The two are separate sentences because a conversion that saved
        // and failed to import is a real outcome and must not claim the library
        // has it.
        // The checkbox in the save panel. "Put aside", not "delete": the
        // original stays in the book and on disk, so a job printed from it
        // still points at the file it really used.
        "mac.replace_original":
                             ["en": "Put the original aside in the library",
                              "ar": "أبعد الأصل في المكتبة"],
        "mac.converted_into_library":
                             ["en": "Saved {name} for {target}, and added it to the library.",
                              "ar": "حُفظ {name} لـ {target}، وأُضيف إلى المكتبة."],
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
        // ── GROUPING THE QUEUE BY COLOUR (lib/swap-queue.js) ─────────────
        //
        // A "colour change" here is one spool taken off one head and another
        // put on, between two jobs. Counted, so each has its one and two.
        "mac.swap_changes":     ["en": "{n} colour changes", "ar": "{n} تبديلات ألوان"],
        "mac.swap_changes_one": ["en": "{n} colour change", "ar": "تبديل لون واحد"],
        "mac.swap_changes_two": ["en": "{n} colour changes", "ar": "تبديلا لون"],
        "mac.swap_saves":       ["en": "Grouped by colour saves {changes} (~{min} min)",
                                 "ar": "التجميع حسب اللون يوفّر {changes} (~{min} دقيقة)"],
        "mac.swap_adds":        ["en": "adds {n} colour changes", "ar": "يضيف {n} تبديلات ألوان"],
        "mac.swap_adds_one":    ["en": "adds {n} colour change", "ar": "يضيف تبديل لون واحد"],
        "mac.swap_adds_two":    ["en": "adds {n} colour changes", "ar": "يضيف تبديلَي لون"],
        "mac.swap_group":       ["en": "Group by colour", "ar": "التجميع حسب اللون"],
        "mac.swap_estimate":    ["en": "An estimate at {min} min per spool change (Settings › Operations). Due dates and priority come first: no job is made late to save a change.",
                                 "ar": "تقدير على أساس {min} دقيقة لكل تبديل بكرة (الإعدادات › العمليات). المواعيد والأولوية أولًا: لا يتأخر أي عمل لتوفير تبديل."],
        "mac.swap_minutes":     ["en": "Minutes per spool change (estimate)", "ar": "دقائق تبديل البكرة (تقدير)"],
        "mac.swap_minutes_hint": ["en": "How long it takes to take one spool off a head and load another. Used only to estimate the time saved by running jobs grouped by colour. 3 minutes suits a Snapmaker U1 with someone already at the machine; walking over to it is not counted.",
                                  "ar": "المدة اللازمة لإخراج بكرة من رأس وتحميل أخرى. تُستخدم فقط لتقدير الوقت الموفَّر عند تجميع الأعمال حسب اللون. ٣ دقائق تناسب Snapmaker U1 بوجود شخص عند الطابعة؛ ولا يُحتسب وقت الوصول إليها."],
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

        // The library in this Mac's own search.
        "mac.spotlight":     ["en": "Find models in Spotlight",
                              "ar": "البحث عن النماذج في Spotlight"],
        "mac.spotlight_note": ["en": "Model names, projects and tags only — never jobs or customers.",
                               "ar": "أسماء النماذج والمشاريع والوسوم فقط — لا الطلبات ولا العملاء."],

        // A photograph of the finished print, on the job that made it.
        "mac.add_print_photo": ["en": "Add a photo of the print",
                                "ar": "إضافة صورة للطباعة"],
        "mac.photo_on_finished_only": ["en": "A photo can be added once the job is finished.",
                                       "ar": "يمكن إضافة صورة بعد انتهاء الطلب."],
        "mac.photo_where": ["en": "Open a finished job and choose “Add a photo of the print”.",
                            "ar": "افتح طلبًا منتهيًا واختر «إضافة صورة للطباعة»."],
        "mac.show_finished_jobs": ["en": "Show finished jobs", "ar": "عرض الطلبات المنتهية"],

        // The shop's own saved messages.
        "mac.send_a_message": ["en": "Send a message", "ar": "إرسال رسالة"],
        "mac.message_template": ["en": "Message",      "ar": "الرسالة"],
        "mac.open_whatsapp":  ["en": "Open WhatsApp",  "ar": "فتح واتساب"],
        "mac.no_phone_for_whatsapp": ["en": "This customer has no phone number on file.",
                                      "ar": "لا يوجد رقم هاتف مسجّل لهذا العميل."],
        "mac.replace_edited_message": ["en": "Replace what you have typed?",
                                       "ar": "استبدال ما كتبته؟"],
        "mac.replace":        ["en": "Replace",        "ar": "استبدال"],

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
        // ── THE DASHBOARD THE DESIGN SPEC DESCRIBES ──────────────────────
        "mac.owed": ["en": "Owed", "ar": "مستحق"],
        "mac.net": ["en": "Net", "ar": "صافي"],
        "mac.material_cost": ["en": "Material cost", "ar": "تكلفة الخامة"],
        "mac.record_a_payment": ["en": "Record a payment", "ar": "تسجيل دفعة"],
        "mac.triage": ["en": "Triage", "ar": "الفرز"],
        "mac.ledger": ["en": "Ledger", "ar": "السجل"],
        "mac.net_in_reports": ["en": "Reconciled in Reports, not here.", "ar": "تتم التسوية في التقارير، لا هنا."],
        "mac.n_jobs_unrecorded": ["en": "{n} jobs unrecorded", "ar": "{n} أعمال غير مسجّلة"],
        "mac.n_jobs_unrecorded_one": ["en": "{n} job unrecorded", "ar": "عمل واحد غير مسجّل"],
        "mac.n_without_cost": ["en": "{n} carry no cost", "ar": "{n} بلا تكلفة"],
        "mac.n_without_cost_one": ["en": "{n} carries no cost", "ar": "واحد بلا تكلفة"],
        "mac.cost_never_recorded": ["en": "No material cost was recorded for this job, so the margin is unknown — not zero.", "ar": "لم تُسجَّل تكلفة خامة لهذا العمل، فالهامش غير معروف — وليس صفرًا."],
        "mac.open_total": ["en": "open", "ar": "مفتوح"],
        "mac.n_things_need_you": ["en": "{n} things need you", "ar": "{n} أمور تحتاجك"],
        "mac.n_things_need_you_one": ["en": "{n} thing needs you", "ar": "أمر واحد يحتاجك"],
        "mac.n_open": ["en": "{n} open", "ar": "{n} مفتوح"],
        "mac.n_open_one": ["en": "{n} open", "ar": "واحد مفتوح"],
        "mac.n_closed": ["en": "{n} closed", "ar": "{n} مغلق"],
        "mac.n_closed_one": ["en": "{n} closed", "ar": "واحد مغلق"],
        "mac.attn_order": ["en": "{n} jobs are late", "ar": "{n} أعمال متأخرة"],
        "mac.attn_order_one": ["en": "{n} job is late", "ar": "عمل واحد متأخر"],
        "mac.attn_stock": ["en": "The shelf is thin", "ar": "المخزون منخفض"],
        "mac.attn_stock_one": ["en": "The shelf is thin", "ar": "المخزون منخفض"],
        "mac.attn_machine": ["en": "A machine needs a look", "ar": "آلة تحتاج فحصًا"],
        "mac.attn_machine_one": ["en": "A machine needs a look", "ar": "آلة تحتاج فحصًا"],
        "mac.attn_nozzle": ["en": "A nozzle is past its life", "ar": "فوهة تجاوزت عمرها"],
        "mac.attn_nozzle_one": ["en": "A nozzle is past its life", "ar": "فوهة تجاوزت عمرها"],
        "mac.attn_unpriced": ["en": "{n} finished jobs were charged nothing", "ar": "{n} أعمال منجزة لم يُحتسب عليها شيء"],
        "mac.attn_unpriced_one": ["en": "{n} finished job was charged nothing", "ar": "عمل منجز واحد لم يُحتسب عليه شيء"],
        "mac.charged_nothing": ["en": "Finished at a price of 0. A test, a gift or for the shop itself?", "ar": "أُنجز بسعر صفر. تجربة أو هدية أو للمحل نفسه؟"],
        "mac.mark_all_not_business": ["en": "Mark all Not business", "ar": "اجعلها كلها «ليس عملًا تجاريًا»"],
        "mac.days_over": ["en": "{n} days over", "ar": "متأخر {n} أيام"],
        "mac.days_over_one": ["en": "{n} day over", "ar": "متأخر يومًا"],
        "mac.past_its_date": ["en": "Past its due date", "ar": "تجاوز تاريخ التسليم"],
        "mac.grams_left": ["en": "{n} g left", "ar": "بقي {n} غ"],
        "mac.out_of_stock": ["en": "None left on the shelf", "ar": "لا شيء على الرف"],
        "mac.needs_a_look": ["en": "Needs a look", "ar": "يحتاج فحصًا"],
        "mac.untitled": ["en": "Untitled", "ar": "بلا عنوان"],
        "mac.open_both": ["en": "Open", "ar": "افتح"],
        "mac.tell_the_customers": ["en": "Tell the customers", "ar": "أبلغ العملاء"],
        "mac.log_a_purchase": ["en": "Log a purchase", "ar": "سجّل شراء"],
        "mac.see_shelf": ["en": "See shelf", "ar": "اعرض الرف"],
        "mac.on_the_machines": ["en": "On the machines", "ar": "على الآلات"],
        "mac.the_shelf": ["en": "The shelf", "ar": "الرف"],
        "mac.no_machines_yet": ["en": "No machines yet", "ar": "لا آلات بعد"],
        "mac.printing": ["en": "Printing", "ar": "يطبع"],
        "mac.out": ["en": "Out", "ar": "نفد"],
        "mac.gross_short": ["en": "Gross", "ar": "الإجمالي"],
        // §6's panes — a pane is a place, so each is named for what is in it.
        "mac.pane_job": ["en": "Job", "ar": "العمل"],
        "mac.pane_parts": ["en": "Parts", "ar": "القطع"],
        "mac.pane_cost": ["en": "Cost", "ar": "التكلفة"],
        "mac.pane_price": ["en": "Price", "ar": "السعر"],
        "mac.pane_dates": ["en": "Dates", "ar": "التواريخ"],
        "mac.pane_notes": ["en": "Notes", "ar": "ملاحظات"],
        "mac.pane_product": ["en": "Product", "ar": "المنتج"],
        "mac.pane_model": ["en": "Model", "ar": "المجسم"],
        "mac.pane_material": ["en": "Material", "ar": "الخامة"],
        "mac.pane_photos": ["en": "Photos", "ar": "الصور"],
        "mac.pane_machine": ["en": "Machine", "ar": "الآلة"],
        "mac.pane_build": ["en": "Build volume", "ar": "حجم الطباعة"],
        "mac.pane_rate": ["en": "Rate", "ar": "السعر بالساعة"],
        "mac.pane_service": ["en": "Service", "ar": "الصيانة"],
        "mac.pane_who": ["en": "Who", "ar": "من"],
        "mac.pane_contact": ["en": "Contact", "ar": "التواصل"],
        "mac.pane_billing": ["en": "Billing", "ar": "الفوترة"],
        "mac.pane_shop": ["en": "Shop", "ar": "المتجر"],
        "mac.pane_tax": ["en": "Currency & tax", "ar": "العملة والضريبة"],
        "mac.pane_rates": ["en": "Rates", "ar": "الأسعار"],
        "mac.pane_sync": ["en": "Sync", "ar": "المزامنة"],
        "set.appearance": ["en": "Appearance", "ar": "المظهر"],
        "set.new_shell": ["en": "Use the redesigned window", "ar": "استخدم النافذة الجديدة"],
        "set.new_shell_why": ["en": "A new sidebar, title bar and Dashboard. The other screens are unchanged for now, and you can switch back at any time.", "ar": "شريط جانبي وشريط عنوان ولوحة معلومات جديدة. بقية الشاشات كما هي حاليًا، ويمكنك الرجوع في أي وقت."],
        // A tile is a hundred points wide. "Khayt cannot ask this machine" is
        // true and does not fit; this is the same fact at tile size, and the
        // Machines screen carries the sentence.
        "mac.no_protocol": ["en": "no link", "ar": "بلا ربط"],
        // Khayt counts REAL prints, so this chip is a fact rather than a
        // status somebody ticks. Its own key rather than a borrowed one:
        // `plib.*` comes from Khayt's nine-language file and this app
        // cannot add to it with two.
        "mac.never_printed": ["en": "Never printed", "ar": "لم تُطبع"],
        "mac.ready_on":      ["en": "Ready on {name}", "ar": "جاهز على {name}"],
        "mac.ready_now":     ["en": "Ready to start", "ar": "جاهز للطباعة"],
        "mach.loaded":       ["en": "Loaded now", "ar": "المحمّل الآن"],
        "mach.loaded_hint":  ["en": "What is in each head, so the library can say what is ready to start. A printer that reports its spools is read instead.", "ar": "ما في كل رأس، ليعرف المعرض ما هو جاهز للطباعة. الطابعة التي تُبلغ عن بكراتها تُقرأ بدلًا من ذلك."],
        "mach.head_n":       ["en": "Head {n}", "ar": "الرأس {n}"],
        "mac.needs_swap":    ["en": "Needs a spool swap", "ar": "يحتاج تبديل بكرة"],
        // ── WHAT IS ALREADY PRINTED AND BOXED ─────────────────────────────
        //
        // The shop counts; a storefront decides what is left, because it is
        // the thing watching orders. "On the shelf" rather than "in stock":
        // this app already says "stock" about filament and consumables, and
        // a second meaning for the same word on a screen beside them is how
        // somebody orders a spool instead of printing a batch.
        "mac.on_the_shelf":  ["en": "On the shelf",  "ar": "على الرف"],
        "mac.count_the_shelf": ["en": "Count the shelf", "ar": "جرد الرف"],
        "mac.record_count":  ["en": "Record count",  "ar": "سجّل الجرد"],
        "mac.not_stocked":   ["en": "Not stocked",   "ar": "غير مخزّن"],
        "mac.counted_on":    ["en": "Counted {date}", "ar": "جُرد {date}"],
        "mac.stock_counted": ["en": "Count the shelf", "ar": "جرد الرف"],
        "mac.sell_from_shelf": ["en": "Sell one from the shelf", "ar": "بيع قطعة من الرف"],
        "mac.sell_one":        ["en": "Sell one",       "ar": "بِع قطعة"],
        "mac.sold_here_n": ["en": "Sold here: {n}", "ar": "بيع هنا: {n}"],
        "mac.sold_here_hint": [
            "en": "Pieces sold across the counter, and online orders you have "
                + "brought in. An online order nobody has brought in yet is "
                + "not counted.",
            "ar": "القطع التي بيعت عند الطاولة، والطلبات الإلكترونية التي "
                + "أدخلتها. الطلب الإلكتروني الذي لم يُدخل بعد لا يُحسب.",
        ],
        "mac.online_orders": ["en": "Online orders", "ar": "الطلبات الإلكترونية"],
        "mac.online_orders_hint": [
            "en": "Orders your storefront has sent to Khayt. Each one is "
                + "checked against the shelf first — anything already printed "
                + "is a sale, not a job. Paid web-store orders become jobs by "
                + "themselves; what is left here is waiting for you.",
            "ar": "الطلبات التي أرسلها متجرك إلى خيط. يُقارن كل طلب بالرف "
                + "أولًا — فما هو مطبوع مسبقًا بيعٌ لا عملٌ جديد. طلبات المتجر "
                + "المدفوعة تصبح أعمالًا تلقائيًا، وما بقي هنا ينتظرك.",
        ],
        "mac.online_none": [
            "en": "Nothing new from your storefront.",
            "ar": "لا جديد من متجرك.",
        ],
        "mac.online_refresh": ["en": "Look again", "ar": "تحديث"],
        "mac.online_off_shelf": [
            "en": "{n} off the shelf", "ar": "{n} من الرف",
        ],
        "mac.online_to_print": ["en": "To print", "ar": "للطباعة"],
        "mac.online_part": [
            "en": "{shelf} off the shelf, {print} to print",
            "ar": "{shelf} من الرف، {print} للطباعة",
        ],
        "mac.online_unmatched": [
            "en": "Not in your catalogue", "ar": "ليس في كتالوجك",
        ],
        // Web-store orders that become jobs by themselves (WebStoreOrders.swift).
        "mac.webstore_arrived": [
            "en": "Paid web-store orders that became jobs by themselves: {n}",
            "ar": "طلبات المتجر المدفوعة التي أصبحت أعمالًا تلقائيًا: {n}",
        ],
        "mac.webstore_became_jobs": ["en": "Became jobs", "ar": "أصبحت أعمالًا"],
        "mac.webstore_new": ["en": "New", "ar": "جديد"],
        "mac.webstore_paid": ["en": "Paid", "ar": "مدفوع"],
        "mac.webstore_wait_unpaid": [
            "en": "Waiting for you: the store says this order has not been paid.",
            "ar": "بانتظارك: يقول المتجر إن هذا الطلب لم يُدفع.",
        ],
        "mac.webstore_wait_payment_unknown": [
            "en": "Waiting for you: the store did not say whether this order was paid.",
            "ar": "بانتظارك: لم يذكر المتجر هل دُفع هذا الطلب.",
        ],
        "mac.webstore_wait_no_reference": [
            "en": "Waiting for you: the store sent no order number, so Khayt cannot tell it from a repeat.",
            "ar": "بانتظارك: لم يرسل المتجر رقم الطلب، فلا يستطيع خيط تمييزه عن طلب مكرر.",
        ],
        "mac.webstore_status_sent": [
            "en": "Told the web store where {n} orders have got to.",
            "ar": "أُبلغ المتجر بحالة {n} من الطلبات.",
        ],
        "mac.webstore_status_not_offered": [
            "en": "Khayt Cloud cannot pass order progress to the web store yet.",
            "ar": "لا تستطيع سحابة خيط بعدُ نقل تقدّم الطلبات إلى المتجر.",
        ],
        "mac.webstore_status_failed": [
            "en": "Could not tell the web store where its orders have got to.",
            "ar": "تعذّر إبلاغ المتجر بتقدّم طلباته.",
        ],
        "mac.online_record_sale": ["en": "Record the sale", "ar": "سجّل البيع"],
        "mac.online_add_to_queue": ["en": "Add to the queue", "ar": "أضف للطابور"],
        "mac.online_already_recorded": ["en": "This order was already in the book, so no second job was made. It has been taken out of the queue.", "ar": "هذا الطلب مسجّل من قبل، فلم يُنشأ طلب ثانٍ. أُزيل من قائمة الانتظار."],
        "mac.online_kept_in_queue": [
            "en": "The order was recorded, but it could not be taken out of "
                + "the cloud queue — it will be offered again.",
            "ar": "سُجّل الطلب، لكن تعذّر حذفه من طابور السحابة — سيُعرض مرة أخرى.",
        ],
        "mac.sold_from_shelf": ["en": "Sold from the shelf", "ar": "بيع من الرف"],
        "mac.sell_from_shelf_q": ["en": "Sell one {name} from the shelf?",
                                  "ar": "بيع قطعة {name} من الرف؟"],
        "mac.not_enough_on_shelf": ["en": "There are not that many on the shelf.",
                                    "ar": "لا يوجد هذا العدد على الرف."],
        "mac.sell_from_shelf_hint": [
            "en": "Records it as sold today at the catalogue price, with its cost "
                + "and its print hours, and takes one off the count. Nothing is "
                + "printed and no filament is deducted — that happened when the "
                + "batch was made.",
            "ar": "يسجّلها مبيعة اليوم بسعر الكتالوج، مع تكلفتها وساعات طباعتها، "
                + "وينقص واحدة من الجرد. لا تُطبع أي قطعة ولا يُخصم خيط — حدث ذلك "
                + "عند طباعة الدفعة.",
        ],
        "mac.shelf_hint": [
            "en": "How many are printed, boxed and ready to post. A shop's "
                + "online store uses this to offer a piece today instead of "
                + "printing it to order.",
            "ar": "كم قطعة مطبوعة ومعبأة وجاهزة للشحن. يستخدم متجرك هذا الرقم "
                + "ليعرض القطعة اليوم بدل طباعتها عند الطلب.",
        ],
        // Assembly instructions and colour guides, which used to be thrown
        // away on import. "Guides" rather than "documents": it is what the
        // creator calls them and what a shop is looking for.
        "mac.guides": ["en": "Guides", "ar": "أدلة"],
        "mac.filter_needs_me": ["en": "Needs me", "ar": "يحتاجني"],
        "mac.filter_running": ["en": "Running", "ar": "قيد التشغيل"],
        "mac.filter_unpaid": ["en": "Unpaid", "ar": "غير مدفوع"],
        "mac.filter_all": ["en": "All", "ar": "الكل"],
        "mac.sorted_by_urgency": ["en": "sorted by urgency", "ar": "مرتّب حسب الأولوية"],
        "mac.col_state": ["en": "State", "ar": "الحالة"],
        "mac.col_job": ["en": "Job", "ar": "العمل"],
        "mac.col_due": ["en": "Due", "ar": "الاستحقاق"],
        "mac.col_charged": ["en": "Charged", "ar": "المحسوب"],
        "mac.col_margin": ["en": "Margin", "ar": "الهامش"],
        "mac.charged_net": ["en": "Charged, net", "ar": "المحسوب، صافي"],
        "mac.charged_gross": ["en": "Charged, gross", "ar": "المحسوب، إجمالي"],
        "mac.margin_at_least": ["en": "Margin", "ar": "الهامش"],
        "mac.first_run_title": ["en": "This shop's book is empty — that's the right place to start", "ar": "دفتر هذا المتجر فارغ — وهذه هي البداية الصحيحة"],
        "mac.first_run_why": ["en": "Khayt keeps one file on this Mac. Nothing leaves it unless you turn on the cloud.", "ar": "يحتفظ خيط بملف واحد على هذا الماك. لا شيء يغادره إلا إذا فعّلت السحابة."],
        "mac.first": ["en": "First", "ar": "أولًا"],
        "mac.then": ["en": "Then", "ar": "ثم"],
        "mac.add_a_machine": ["en": "Add a machine", "ar": "أضف آلة"],
        "mac.add_a_machine_why": ["en": "Its hourly rate is what turns a print into a cost.", "ar": "سعر الساعة هو ما يحوّل الطباعة إلى تكلفة."],
        "mac.put_a_spool": ["en": "Put a spool on the shelf", "ar": "ضع بكرة على الرف"],
        "mac.put_a_spool_why": ["en": "Weight and price per kilo. Khayt does the rest.", "ar": "الوزن وسعر الكيلو. خيط يتكفّل بالباقي."],
        "mac.take_a_job": ["en": "Take your first job", "ar": "خذ أول عمل"],
        "mac.take_a_job_why": ["en": "Or price one in the Calculator without saving it.", "ar": "أو سعّر واحدًا في الحاسبة دون حفظه."],
        "mac.open_the_sample": ["en": "Or open the sample shop — 42 jobs, 5 machines, real numbers.", "ar": "أو افتح المتجر التجريبي — ٤٢ عملًا و٥ آلات وأرقام حقيقية."],
        // ── THE DESIGN SYSTEM'S OWN WORDS ────────────────────────────────
        //
        // §4: every state is a GLYPH and a WORD as well as a hue. These are
        // the words. Caps are applied by the label style, not typed here, so
        // Arabic — which has no case — is not shouted at.
        "mac.state_late":      ["en": "Late",      "ar": "متأخر"],
        "mac.state_today":     ["en": "Today",     "ar": "اليوم"],
        "mac.state_running":   ["en": "Running",   "ar": "يعمل"],
        "mac.state_queued":    ["en": "Queued",    "ar": "في الانتظار"],
        "mac.state_finishing": ["en": "Finishing", "ar": "التشطيب"],
        "mac.state_done":      ["en": "Done",      "ar": "تم"],
        "mac.state_blocked":   ["en": "Blocked",   "ar": "متوقف"],
        "mac.state_quoted":    ["en": "Quoted",    "ar": "عرض سعر"],
        "mac.state_offline":   ["en": "Offline",   "ar": "غير متصل"],
        "mac.state_stopped": ["en": "Stopped", "ar": "متوقفة"],
        "mac.state_check_it": ["en": "Check it", "ar": "افحصها"],
        "mac.state_worn": ["en": "Worn", "ar": "مهترئة"],
        "mac.state_out": ["en": "Out", "ar": "نفد"],
        "mac.state_low": ["en": "Low", "ar": "منخفض"],
        // §4: gift cards get no chip — the balance column says it instead, and
        // a spent card says `closed` where a figure would be.
        "mac.gc_closed": ["en": "closed", "ar": "مغلقة"],
        "mac.gc_all": ["en": "All", "ar": "الكل"],
        // §6's panes, one word each. The Machine sheet is the only one in this
        // app above twelve fields, and these are the three the design named.
        "mac.pane_printer": ["en": "Printer", "ar": "الطابعة"],
        "mac.pane_connection": ["en": "Connection", "ar": "الاتصال"],
        "mac.pane_upkeep": ["en": "Upkeep", "ar": "الصيانة"],
        // The picker's one verb. "Choose", not "Add": choosing a model fills
        // the part in; adding the part is the next button along.
        "mac.choose": ["en": "Choose", "ar": "اختيار"],
        // §5: a total built over a hole says which way it is wrong.
        "mac.at_least":      ["en": "at least",     "ar": "على الأقل"],
        "mac.at_most":       ["en": "at most",      "ar": "على الأكثر"],
        // §7: the sidebar's three groups — the shop's own division of its
        // work: what it sells, what makes it, what it is worth.
        "mac.group_shop":    ["en": "Shop",         "ar": "المتجر"],
        "mac.group_floor":   ["en": "Floor",        "ar": "الورشة"],
        "mac.group_money":   ["en": "Money",        "ar": "المال"],
        "mac.book":          ["en": "Book",         "ar": "الدفتر"],
        "mac.search_the_book": ["en": "Search jobs, models, spools, people",
                                "ar": "ابحث في الأعمال والنماذج والبكرات والعملاء"],
        "mac.synced":        ["en": "synced",       "ar": "متزامن"],
        "mac.offline":       ["en": "offline",      "ar": "غير متصل"],
        "mac.saved_at":      ["en": "saved {t}",    "ar": "حُفظ {t}"],
        "mac.n_machines":    ["en": "{n} machines", "ar": "{n} آلات"],
        "mac.n_machines_one": ["en": "{n} machine", "ar": "آلة واحدة"],
        "mac.n_people":      ["en": "{n} people",   "ar": "{n} أشخاص"],
        "mac.n_people_one":  ["en": "{n} person",   "ar": "شخص واحد"],
        // ── AND THE TWO AXES THE GROUPING MENU NEVER HAD ─────────────────
        //
        // A group is the SET a model belongs to; a category is what it IS, and
        // a tag is everything neither of those covers. Both could be filtered
        // on this Mac and neither could be set from it, so a shop wanting to
        // call something a bust had to open the other app — which is the
        // definition of a gap rather than a difference.
        "mac.category":      ["en": "Category",        "ar": "التصنيف"],
        "mac.new_category":  ["en": "New Category\u{2026}", "ar": "تصنيف جديد\u{2026}"],
        "mac.remove_from_category": ["en": "Remove from Category",
                                     "ar": "إزالة من التصنيف"],
        "mac.category_n_models": ["en": "Categorise {n} Models", "ar": "تصنيف {n} نماذج"],
        "mac.category_why":  ["en": "Say what the selected models ARE",
                              "ar": "حدّد ما تمثّله النماذج المختارة"],
        "mac.name_this_category": ["en": "Name this category", "ar": "سمِّ هذا التصنيف"],
        "mac.category_example": ["en": "Wall art",      "ar": "فن جداري"],
        "mac.tags":          ["en": "Tags",            "ar": "الوسوم"],
        "mac.tag_models":    ["en": "Tag Models",      "ar": "وسم النماذج"],
        "mac.tag_example":   ["en": "relief, portrait", "ar": "نقش، صورة"],
        // Said out loud because it is the surprising half: tagging several at
        // once REPLACES what each carried rather than adding to it.
        "mac.tags_replaced": ["en": "These become the tags on every model selected.",
                              "ar": "تصبح هذه وسوم كل نموذج مختار."],
        // Where a model came from. The licence's own names come from Khayt's
        // shared catalogue (`plib.licence_*`); these are the few sentences this
        // app needs around them.
        // What the logo box ACCEPTS. It used to borrow `set.logo_too_big` —
        // "Image too large — use a file under 1 MB" — which is a REFUSAL, and
        // sat under an empty box saying something had already gone wrong.
        // Found by photographing the pane; no test can see a sentence that is
        // grammatical, translated, and the wrong sentence.
        "mac.logo_accepts":  ["en": "PNG, JPEG, GIF or WebP, under 1 MB. It is kept inside the book, so it travels with every backup.",
                              "ar": "PNG أو JPEG أو GIF أو WebP، أقل من 1 ميغابايت. يُحفظ داخل الدفتر، فينتقل مع كل نسخة احتياطية."],
        // The two numbers a rewards programme actually runs on. Khayt's own
        // catalogue names the tiers and the switch but not these — its settings
        // screen labels them in the markup — so they are this app's words.
        "mac.points_per_unit": ["en": "Points per unit spent",
                                "ar": "النقاط لكل وحدة إنفاق"],
        "mac.points_worth":    ["en": "Each point is worth",
                                "ar": "قيمة النقطة الواحدة"],
        "mac.points_explains": ["en": "Points are earned on what the shop keeps — after tax, credit notes and anything written off — and are spent as store credit.",
                                "ar": "تُحتسب النقاط على ما يبقى للورشة فعلياً — بعد الضريبة وإشعارات الدائن وما شُطب — وتُصرف كرصيد لدى الورشة."],
        // The rule refused the repair: the order no longer looks affected —
        // someone put it back on another Mac, or its plan changed under the
        // list. Not an error in the app, and not silence either.
        "mac.deposit_not_affected": ["en": "That order no longer looks affected — its figures may have been corrected already.",
                                     "ar": "لم يعد هذا الطلب يبدو متأثراً — ربما صُححت أرقامه سلفاً."],
        "mac.review":               ["en": "Review", "ar": "مراجعة"],
        // What a plan IS, said before one is offered. "Generate plan" on an
        // empty sheet is a button whose result the shop learns by pressing it.
        "mac.plan_explains": ["en": "Three payments, a month apart, covering what this job still owes. Each is collected here as it arrives.",
                              "ar": "ثلاث دفعات، بين كل واحدة شهر، تغطي ما تبقى على هذا الطلب. تُسجَّل كل دفعة هنا عند استلامها."],
        // Said when a collected row is put back: the ROW changes, the cash does
        // not. `collectionTotals` never lowers `paidAmount` — it can have grown
        // since the plan was made, and taking it down would destroy money
        // recorded at the counter.
        "mac.plan_cash_stays": ["en": "The payment is no longer marked collected. Money already recorded on the job stays — change that on the payment sheet.",
                                "ar": "لم تعد الدفعة مؤشَّرة كمستلمة. المبلغ المسجَّل على الطلب يبقى كما هو — تُعدّله من نافذة الدفع."],
        // DRAFT, and the word is the point. A purchase order is something a
        // shop hands a supplier; an app that sent one because somebody chose a
        // menu item would have acted on their behalf in a way they cannot take
        // back. "Order more" would have promised exactly that.
        "mac.to_order":     ["en": "things to order", "ar": "أشياء بحاجة للطلب"],
        "mac.to_order_one": ["en": "thing to order",  "ar": "شيء بحاجة للطلب"],
        "mac.to_order_two": ["en": "things to order", "ar": "شيئان بحاجة للطلب"],
        "mac.draft_them":   ["en": "Draft the orders", "ar": "إنشاء المسودات"],
        "mac.draft_an_order": ["en": "Draft a purchase order",
                               "ar": "إنشاء مسودة أمر شراء"],
        "mac.overpriced_orders": ["en": "Priced per spool", "ar": "مسعّرة بالبكرة"],
        "mac.orders_word":     ["en": "on order",  "ar": "قيد الطلب"],
        "mac.orders_word_one": ["en": "on order",  "ar": "قيد الطلب"],
        // HOW MANY MATERIALS THIS SUPPLIER HAS A PRICE FOR, which is the
        // field on a supplier that actually does something: a quoted rate is
        // what a drafted order is priced at, in preference to dividing a
        // spool's own cost by its weight.
        // SAID, NOT WRITTEN. What the price per unit comes to when the shop
        // gave an amount and a quantity but no unit price. The book keeps
        // what was typed: filling a field nobody filled turns a division
        // into a fact, and the price history compares what is in the book.
        "mac.works_out_at": ["en": "Works out at", "ar": "يساوي"],
        // The examples the other app puts in the same box, said here rather
        // than typed into the field: `WordsAreTranslatedTests` refuses English
        // spelled out in a view, and it is right to — a placeholder is text a
        // shop reads.
        // WHAT A MATERIAL HAS COST. The other app draws this chart under a
        // bare div with no heading of its own, so there is no shared key to
        // borrow — these are this app's words.
        "mac.price_history": ["en": "What materials have cost",
                              "ar": "ما كلّفته المواد"],
        "mac.purchases_word":     ["en": "{n} purchases", "ar": "{n} مشتريات"],
        "mac.purchases_word_one": ["en": "{n} purchase",  "ar": "شراء واحد"],
        "mac.purchases_word_two": ["en": "2 purchases",   "ar": "شراءان"],
        "mac.cheapest_was": ["en": "cheapest", "ar": "الأرخص"],
        // Said, because a group that quietly mixed grams with kilograms would
        // be the very thing this rule exists to stop, and a shop looking at a
        // converted figure should know it was converted.
        "mac.units_converted": ["en": "converted to one unit",
                                "ar": "محوّلة إلى وحدة واحدة"],
        "mac.material_ph": ["en": "PLA, PETG, Resin…", "ar": "PLA أو PETG أو راتنج…"],
        "mac.quotes_word":     ["en": "{n} quoted prices", "ar": "{n} أسعار مسجّلة"],
        "mac.quotes_word_one": ["en": "{n} quoted price",    "ar": "سعر مسجّل واحد"],
        "mac.quotes_word_two": ["en": "2 quoted prices",   "ar": "سعران مسجّلان"],
        // What is kept when a supplier is corrected, said where it can be read
        // BEFORE the form is saved: this app writes the fields on the form and
        // leaves the purchase log the other app keeps exactly as it found it.
        "mac.supplier_kept_history": ["en": "{n} logged purchases stay with this supplier.",
                                      "ar": "تبقى {n} من المشتريات المسجّلة مع هذا المورّد."],
        // Said BEFORE save, not discovered afterwards: an order with no price
        // on it books no expense, and a shop reconciling its spend should know
        // which receipts will never appear there.
        "mac.receipt_books_nothing": ["en": "This order carries no price, so receiving it records no spending.",
                                      "ar": "لا يحمل هذا الطلب سعراً، لذا لن يُسجَّل أي مصروف عند استلامه."],
        // The rule refused: the order no longer looks over-priced — someone
        // corrected it on another Mac, or its linked item changed.
        "mac.order_not_suspect": ["en": "That order no longer looks over-priced — it may have been corrected already.",
                                  "ar": "لم يعد هذا الطلب يبدو مبالغاً في سعره — ربما صُحِّح سلفاً."],
        "mac.rating_out_of_range": ["en": "A rating is one to five stars.",
                                    "ar": "التقييم من نجمة إلى خمس نجوم."],
        "mac.licence_set":   ["en": "Record Licence",   "ar": "تسجيل الترخيص"],
        "mac.licence_cleared": ["en": "Clear Licence",  "ar": "مسح الترخيص"],
        "mac.licence_unknown": ["en": "That is not a licence Khayt knows.",
                                "ar": "هذا ليس ترخيصًا يعرفه خيط."],
        "mac.source_set":    ["en": "Record Source",    "ar": "تسجيل المصدر"],
        "mac.source_replaced": ["en": "This becomes the source on every model selected.",
                                "ar": "يصبح هذا مصدر كل نموذج مختار."],
        "mac.provenance_why": ["en": "Say where a model came from and what its licence allows. Not recorded is not the same as not for sale.",
                               "ar": "سجِّل مصدر النموذج وما يسمح به ترخيصه. \"غير مسجل\" لا يعني \"غير قابل للبيع\"."],
        // The mode switch. Khayt's own catalogue names the modes and the
        // sentences around them (`set.mode_*`); these two are this app's.
        "mac.mode_unknown":  ["en": "That is not a mode Khayt offers.",
                              "ar": "هذا ليس وضعًا يوفره خيط."],
        "mac.simple_hides":  ["en": "Simple hides Expenses and Reports. Nothing is deleted — switch back and they return.",
                              "ar": "يُخفي الوضع البسيط المصروفات والتقارير. لا يُحذف شيء — عُد وستظهر من جديد."],
        "mac.n_models":      ["en": "{n} models",      "ar": "{n} نماذج"],
        "mac.n_models_one":  ["en": "{n} model",       "ar": "نموذج واحد"],
        "mac.n_models_two":  ["en": "{n} models",      "ar": "نموذجان"],
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
        // WAS "Print files added in Khayt appear here." — which stopped being
        // true when this app learnt to import, and until it was noticed it was
        // sending people to the other app for something they could do here.
        "mac.no_models_hint": ["en": "Add models with the Import button, or drop a folder here.",
                               "ar": "أضف النماذج بزر الاستيراد، أو أفلت مجلدًا هنا."],
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
        "mac.updates_always_ask": ["en": "Khayt looks for a new version when it opens and asks before installing it — never on its own.", "ar": "يبحث خيط عن إصدار جديد عند فتحه ويستأذنك قبل تثبيته — لا يثبّت شيئًا من تلقاء نفسه."],
        "mac.updates_auto_check": ["en": "Check for updates when Khayt opens, and every hour",
                                   "ar": "التحقق من التحديثات عند فتح خيط وكل ساعة"],
        "mac.updates_unavailable": ["en": "This build cannot update itself.",
                                    "ar": "هذه النسخة لا تستطيع تحديث نفسها."],
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
        "mac.nothing_to_plan_why": ["en": "Nothing is waiting to be printed. Finished work and quotes are not planned onto plates.",
                                    "ar": "لا يوجد عمل ينتظر الطباعة. الأعمال المنتهية وعروض الأسعار لا تُوضع على الصواني."],
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
        "mac.nav_reports":   ["en": "Reports",        "ar": "التقارير"],
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
        "mac.lib_view_models": ["en": "All models", "ar": "كل النماذج"],
        "mac.lib_view_groups": ["en": "Groups", "ar": "المجموعات"],
        "mac.lib_view_help":   ["en": "Every model in one grid, or grouped into folders", "ar": "كل النماذج في شبكة واحدة، أو مجمّعة في مجلدات"],
        "mac.lib_show":        ["en": "Show", "ar": "عرض"],
        "mac.lib_printer":     ["en": "Ready on", "ar": "جاهز على"],
        "mac.lib_creator":     ["en": "Creator", "ar": "المصمم"],
        "mac.lib_tag":         ["en": "Tag", "ar": "الوسم"],
        "mac.sort_added":    ["en": "Date added", "ar": "تاريخ الإضافة"],
        "mac.sort_default":  ["en": "Favourites first", "ar": "المفضّلة أولاً"],
        "mac.sort_by":       ["en": "Sort Library By",  "ar": "ترتيب المكتبة حسب"],
        "mac.dashboard":     ["en": "Dashboard",       "ar": "نظرة عامة"],
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
        "mac.inventory":     ["en": "Inventory",       "ar": "المخزون"],
        "mac.no_machines":   ["en": "No machines yet", "ar": "لا طابعات بعد"],
        // WAS "Printers added in Khayt appear here." Same stale pointer: this
        // app finds printers on the network and adds them itself.
        "mac.no_machines_hint": ["en": "Add a printer, or let Khayt find the ones on your network.",
                                 "ar": "أضف طابعة، أو دع خيط يجد الطابعات على شبكتك."],
        "mac.no_stock":      ["en": "No filament recorded", "ar": "لا خيوط مسجّلة"],
        // WAS "Spools added in Khayt appear here." Same again: a spool can be
        // looked up from the catalogue here rather than typed anywhere else.
        "mac.no_stock_hint": ["en": "Add a spool — start typing a filament and Khayt fills the rest.",
                              "ar": "أضف بكرة — ابدأ بكتابة الخيط ويكمل خيط الباقي."],
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
        // ── SETTING EMAIL UP, WHICH THIS APP COULD NOT DO ─────────────────
        //
        // The shared catalogue already names every field — `set.email_provider`,
        // `set.smtp_host`, `set.smtp_pass` and the rest — because the other
        // app's screen has had them for years. What is here is only what that
        // screen never had to say: the two secrets this app seals itself, and
        // the sentences a shop needs when a send goes wrong.
        "mac.email_forget_key": ["en": "Forget the stored API key",
                                 "ar": "حذف مفتاح الواجهة المحفوظ"],
        "mac.email_forget_pass": ["en": "Forget the stored password",
                                  "ar": "حذف كلمة المرور المحفوظة"],
        "mac.email_unsealed": ["en": "That could not be encrypted, so nothing was saved. The book syncs and is backed up, and a password in the clear would go with it.",
                               "ar": "تعذّر التشفير، فلم يُحفظ شيء. الدفتر يُزامن ويُنسخ احتياطيًا، وكلمة المرور غير المشفّرة ستنتقل معه."],
        // 465 and 587 are not two ways of saying the same thing, and a shop
        // that picks the wrong one gets a failure that names neither.
        "mac.smtp_ports": ["en": "Port 465 is encrypted from the start. Port 587 starts in the clear and asks the server to encrypt — and Khayt will not send your password if the server refuses.",
                           "ar": "المنفذ 465 مشفّر من البداية. المنفذ 587 يبدأ دون تشفير ثم يطلب من الخادم تشفير الاتصال — ولن يرسل خيط كلمة مرورك إن رفض الخادم."],
        "mac.email_no_triggers": ["en": "Nothing is set to send yet, so no customer will be emailed.",
                                  "ar": "لم يُحدَّد أي حدث للإرسال، فلن يصل أي عميل بريد."],
        "mac.email_mailto_hint": ["en": "This opens a message in your mail app for you to send yourself. Khayt cannot send it for you, so campaigns and automatic updates stay off.",
                                  "ar": "يفتح هذا رسالة في تطبيق البريد لديك لترسلها بنفسك. لا يستطيع خيط إرسالها نيابةً عنك، لذا تبقى الحملات والتحديثات التلقائية معطّلة."],
        "mac.email_no_shop_address": ["en": "This shop has no email address in Settings, so there is nowhere to send a test.",
                                      "ar": "لا يوجد بريد للمحل في الإعدادات، فلا مكان لإرسال رسالة تجريبية إليه."],
        "mac.email_test_subject": ["en": "Khayt — test email", "ar": "خيط — رسالة تجريبية"],
        "mac.email_test_body": ["en": "This is a test from Khayt. Email is working.",
                                "ar": "هذه رسالة تجريبية من خيط. البريد يعمل."],
        "mac.email_test_failed": ["en": "The test did not send:",
                                  "ar": "لم تُرسل الرسالة التجريبية:"],
        // The moves a shop can have emailed. The keys come from
        // `lib/order-email.js`; these are that list said in the shop's own
        // language, and a trigger added there without a word here still draws
        // readably — see `EmailSettings.label`.
        "mac.email_when_printing": ["en": "Printing starts", "ar": "عند بدء الطباعة"],
        "mac.email_when_post": ["en": "It goes to finishing", "ar": "عند الانتقال إلى التشطيب"],
        "mac.email_when_completed": ["en": "It is ready to collect", "ar": "عند الجاهزية للاستلام"],
        "mac.email_when_quote": ["en": "A quote is made", "ar": "عند إنشاء عرض سعر"],
        "mac.email_when_payment_received": ["en": "A payment arrives", "ar": "عند استلام دفعة"],
        // ── WHAT THE SHOP PAYS EVERY MONTH ────────────────────────────────
        //
        // `an.be_none` on the break-even screen has told shops to add these
        // "in Settings" since it shipped, and this app's Settings had nowhere
        // to do it — a sentence written for the other app's pane. These are
        // the words for the pane that sentence was always pointing at.
        "mac.fixed_section": ["en": "Monthly costs", "ar": "التكاليف الشهرية"],
        "mac.fixed_none": ["en": "Nothing yet. Add rent, subscriptions, wages — anything paid every month whether you print or not. Reports uses these to work out what you have to bill to break even.",
                           "ar": "لا شيء بعد. أضف الإيجار والاشتراكات والرواتب — كل ما يُدفع شهريًا سواء طبعت أم لا. تستخدمها التقارير لحساب ما يجب تحصيله لتغطية التكاليف."],
        "mac.fixed_name_ph": ["en": "Rent, electricity, a subscription…",
                              "ar": "إيجار، كهرباء، اشتراك…"],
        "mac.fixed_add": ["en": "Add a cost", "ar": "إضافة تكلفة"],
        "mac.fixed_remove": ["en": "Remove this cost", "ar": "حذف هذه التكلفة"],
        "mac.fixed_total": ["en": "Every month:", "ar": "شهريًا:"],
        // ── SETTING TELEGRAM UP, WHICH THIS APP COULD NOT DO ──────────────
        //
        // The shared catalogue has `tg.chat_id_hint`, `tg.test_sent` and
        // `tg.error` because the other app's screen needed them. It does NOT
        // have the field labels — it hard-codes "Telegram Notifications",
        // "Bot Token" and "Chat ID" as English literals, and spells two of its
        // own checkboxes "Notify on order on_hold", which is a raw status
        // value shown to a shop. Said properly here, and in both languages.
        "mac.tg_section": ["en": "Telegram alerts", "ar": "تنبيهات تيليجرام"],
        "mac.tg_token": ["en": "Bot token", "ar": "رمز البوت"],
        "mac.tg_chat": ["en": "Chat ID", "ar": "معرّف المحادثة"],
        "mac.tg_forget": ["en": "Forget the stored bot token",
                          "ar": "حذف رمز البوت المحفوظ"],
        "mac.tg_unsealed": ["en": "That token could not be encrypted, so nothing was saved. The book syncs and is backed up, and a token in the clear would go with it.",
                            "ar": "تعذّر تشفير الرمز، فلم يُحفظ شيء. الدفتر يُزامن ويُنسخ احتياطيًا، والرمز غير المشفّر سينتقل معه."],
        "mac.tg_when": ["en": "Send a message when", "ar": "أرسل رسالة عند"],
        "mac.tg_on_complete": ["en": "A job is finished", "ar": "اكتمال عمل"],
        "mac.tg_on_hold": ["en": "A job is put on hold", "ar": "تعليق عمل"],
        "mac.tg_on_low_stock": ["en": "Filament is running low", "ar": "انخفاض مخزون الخيط"],
        // THE LAST THREE ARE NOT THE SHARED `fleet.notify_*`, and the picture
        // is why. Those read "Notify on printer error", which is right on the
        // fleet screen and wrong under this heading: "Send a message when
        // Notify on printer error". Every switch in this list has to complete
        // the sentence above it, so all six are events.
        "mac.tg_printer_error": ["en": "A printer reports an error",
                                 "ar": "إبلاغ طابعة عن خطأ"],
        "mac.tg_printer_offline": ["en": "A printer stops answering",
                                   "ar": "توقّف طابعة عن الاستجابة"],
        "mac.tg_printer_stall": ["en": "A print stops moving",
                                 "ar": "توقّف طباعة عن التقدّم"],
        "mac.tg_test": ["en": "Send a test message", "ar": "إرسال رسالة تجريبية"],
        "mac.tg_test_body": ["en": "Test from Khayt. Telegram alerts are working.",
                             "ar": "رسالة تجريبية من خيط. تنبيهات تيليجرام تعمل."],
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
        "mac.pnl_unpriced": ["en": "{n} finished jobs were charged nothing. What they cost to make is in the margin and the net income. For a test, a gift or something for the shop itself, right-click the job and choose Not business to leave it out.", "ar": "{n} من الأعمال المنجزة لم يُحتسب عليها شيء، وتكلفتها داخلة في الهامش وصافي الدخل. إن كانت تجربة أو هدية أو شيئًا للمحل نفسه، انقر على العمل بالزر الأيمن واختر «ليس عملًا تجاريًا» لاستبعاده."],
        "mac.not_business": ["en": "Not business", "ar": "ليس عملًا تجاريًا"],
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
        // The storefront promise, which reported only to stderr.
        "mac.lead_time_last": ["en": "Lead time last", "ar": "آخر مدة تسليم"],
        "mac.linked_title": ["en": "Folders indexed where they are", "ar": "مجلدات مفهرسة في مكانها"],
        "mac.linked_link": ["en": "Link a folder", "ar": "اربط مجلدًا"],
        "mac.linked_unlink": ["en": "Unlink", "ar": "افصل"],
        "mac.linked_rescan": ["en": "Look for new models", "ar": "ابحث عن مجسّمات جديدة"],
        "mac.linked_hint": ["en": "A NAS, an external drive or a shared folder: its models appear in the library, measured and pictured, and stay exactly where they are — nothing is copied, moved or deleted. Unlinking takes them out of the library and leaves the files alone.", "ar": "خادم تخزين أو قرص خارجي أو مجلد مشترك: تظهر مجسّماته في المكتبة مقيسة ومصوّرة وتبقى في مكانها تمامًا — لا يُنسخ شيء ولا يُنقل ولا يُحذف. الفصل يُخرجها من المكتبة ويترك الملفات كما هي."],
        "mac.linked_not_vault": ["en": "That folder is the library\u{2019}s own — it is indexed already.", "ar": "هذا المجلد هو مجلد المكتبة نفسه — مفهرس من قبل."],
        "mac.linked_unlinked": ["en": "Unlinked. {n} models left the library; their files were not touched.", "ar": "فُصل المجلد. خرج {n} من المجسّمات من المكتبة، ولم تُمسّ ملفاتها."],
        "mac.linked_up_to_date": ["en": "The linked folders have nothing new.", "ar": "لا جديد في المجلدات المرتبطة."],
        "mac.linked_scanned": ["en": "Indexed {n} models where they are; {same} were already in the library.", "ar": "فُهرس {n} من المجسّمات في مكانها؛ و{same} كانت في المكتبة من قبل."],
        "mac.linked_where": ["en": "Linked — in {path}", "ar": "مرتبط — في {path}"],
        "mac.print_next": ["en": "Print next", "ar": "للطباعة لاحقًا"],
        "mac.print_next_add": ["en": "Add to Print next", "ar": "أضف إلى قائمة الطباعة"],
        "mac.print_next_remove": ["en": "Remove from Print next", "ar": "أزل من قائمة الطباعة"],
        "mac.duplicates": ["en": "Duplicates", "ar": "المكرّرة"],
        "mac.by_creator": ["en": "by {name}", "ar": "من تصميم {name}"],
        "mac.creator_show_all": ["en": "Show everything by this creator", "ar": "اعرض كل أعمال هذا المصمم"],
        "mac.duplicate_of": ["en": "The same model as {n} other in the library:", "ar": "المجسّم نفسه موجود {n} مرة أخرى في المكتبة:"],
        "mac.libmove_title": ["en": "Where the library lives", "ar": "مكان المكتبة"],
        "mac.libmove_now": ["en": "Now", "ar": "الآن"],
        "mac.libmove_in_icloud": ["en": "In iCloud Drive. With Optimize Mac Storage on, macOS keeps models you have not opened in iCloud and brings each back when it is opened.", "ar": "في iCloud Drive. مع تفعيل تحسين مساحة التخزين، يُبقي macOS المجسّمات غير المفتوحة في iCloud ويعيد كل واحد منها عند فتحه."],
        "mac.libmove_use_icloud": ["en": "Use iCloud Drive", "ar": "استخدم iCloud Drive"],
        "mac.libmove_choose": ["en": "Choose a folder", "ar": "اختر مجلدًا"],
        "mac.libmove_choose_prompt": ["en": "Use this folder", "ar": "استخدم هذا المجلد"],
        "mac.libmove_back_home": ["en": "Back to this Mac\u{2019}s own folder", "ar": "عُد إلى مجلد هذا الماك"],
        "mac.libmove_hint": ["en": "The models already here move with it: each is copied, read back and compared, and only then is the original moved to the Trash. Nothing is overwritten, and a file that cannot be moved stays where it is.", "ar": "تنتقل المجسّمات الموجودة معها: يُنسخ كل ملف ويُقرأ ويُقارن، وبعدها فقط يُنقل الأصل إلى سلة المهملات. لا يُكتب فوق شيء، والملف الذي لا يمكن نقله يبقى مكانه."],
        "mac.libmove_confirm_title": ["en": "Move the print library?", "ar": "نقل مكتبة الطباعة؟"],
        "mac.libmove_confirm": ["en": "Move the library", "ar": "انقل المكتبة"],
        "mac.libmove_confirm_body": ["en": "New models will go to {path}, and the ones already here will be moved there. The originals go to the Trash only after each copy is checked.", "ar": "ستذهب المجسّمات الجديدة إلى {path}، وتُنقل الموجودة إليه. لا تذهب الأصول إلى سلة المهملات إلا بعد التحقق من كل نسخة."],
        "mac.libmove_not_writable": ["en": "Khayt cannot write to {path}.", "ar": "لا يستطيع خيط الكتابة في {path}."],
        "mac.libmove_nothing": ["en": "The library is in its new folder. There were no files to move.", "ar": "المكتبة في مجلدها الجديد. لم تكن هناك ملفات لنقلها."],
        "mac.libmove_no_room": ["en": "Not enough room in the new folder — {short} short. Nothing was moved; new models will still go there.", "ar": "لا مساحة كافية في المجلد الجديد — ينقص {short}. لم يُنقل شيء، وستذهب المجسّمات الجديدة إليه."],
        "mac.libmove_done": ["en": "Moved {n} files; {same} were already there.", "ar": "نُقل {n} ملفًا؛ و{same} كانت موجودة من قبل."],
        "mac.libmove_some_failed": ["en": "{n} files could not be moved and are where they were:", "ar": "تعذّر نقل {n} ملفًا وبقيت مكانها:"],
        "mac.cloudlib_not_there": ["en": "The bucket did not confirm the upload: the file is not there.", "ar": "لم تؤكد الحاوية الرفع: الملف غير موجود فيها."],
        "mac.cloudlib_wrong_size": ["en": "The bucket did not confirm the upload: it holds {there} bytes, not {here}.", "ar": "لم تؤكد الحاوية الرفع: فيها {there} بايت وليس {here}."],
        "mac.cloudlib_hash_mismatch": ["en": "The bucket did not confirm the upload: its content hash does not match.", "ar": "لم تؤكد الحاوية الرفع: بصمة المحتوى لا تطابق."],
        "mac.cloudlib_read_back_differs": ["en": "The bucket did not confirm the upload: what came back is not what went up.", "ar": "لم تؤكد الحاوية الرفع: ما عاد منها ليس ما رُفع إليها."],
        "mac.cloudlib_no_sidecar": ["en": "This model is not in the cloud.", "ar": "هذا المجسّم ليس في السحابة."],
        "mac.cloudlib_bucket_lost_it": ["en": "The bucket no longer has this model.", "ar": "لم تعد الحاوية تحمل هذا المجسّم."],
        "mac.cloudlib_bad_download": ["en": "The download did not match what left this Mac:", "ar": "ما نُزّل لا يطابق ما خرج من هذا الماك:"],
        "mac.gdrive_where": ["en": "Keep the copy in", "ar": "احفظ النسخة في"],
        "mac.gdrive_bucket": ["en": "A storage bucket", "ar": "حاوية تخزين"],
        "mac.gdrive_why": ["en": "Uses the storage you already pay Google for. Khayt sees only the files it puts there, in one folder. You need an OAuth client of type Desktop app from your Google Cloud project; use the same one on every computer, or each will see an empty folder.", "ar": "يستخدم المساحة التي تدفع لـ Google مقابلها. لا يرى خيط إلا الملفات التي يضعها هناك، في مجلد واحد. تحتاج عميل OAuth من نوع تطبيق سطح المكتب من مشروعك في Google Cloud، واستخدم العميل نفسه على كل جهاز وإلا رأى كل جهاز مجلدًا فارغًا."],
        "mac.gdrive_production": ["en": "In the Google Cloud console, set the OAuth consent screen to In production. Left in Testing, Google signs Khayt out every seven days.", "ar": "في Google Cloud، اضبط شاشة موافقة OAuth على وضع الإنتاج. إن بقيت في وضع الاختبار يُخرج Google خيط كل سبعة أيام."],
        "mac.gdrive_client_id": ["en": "OAuth client ID", "ar": "معرّف عميل OAuth"],
        "mac.gdrive_client_secret": ["en": "Client secret (if Google gave one)", "ar": "سرّ العميل (إن أعطاك Google واحدًا)"],
        "mac.gdrive_folder": ["en": "Folder in your Drive", "ar": "المجلد في Drive"],
        "mac.gdrive_connect": ["en": "Connect Google Drive", "ar": "اربط Google Drive"],
        "mac.gdrive_disconnect": ["en": "Disconnect", "ar": "افصل"],
        "mac.gdrive_connected_as": ["en": "Connected as {email} — {used} used", "ar": "مرتبط بحساب {email} — مستخدم {used}"],
        "mac.gdrive_connected_of": ["en": "Connected as {email} — {used} of {limit} used", "ar": "مرتبط بحساب {email} — مستخدم {used} من {limit}"],
        "mac.gdrive_need_client": ["en": "Add the OAuth client ID from your Google Cloud project first.", "ar": "أضف معرّف عميل OAuth من مشروعك في Google Cloud أولًا."],
        "mac.gdrive_waiting": ["en": "Waiting for the sign-in in your browser…", "ar": "بانتظار تسجيل الدخول في المتصفح…"],
        "mac.gdrive_connected": ["en": "Google Drive connected.", "ar": "رُبط Google Drive."],
        "mac.gdrive_disconnected": ["en": "Disconnected. Anything already in Drive stays there. To withdraw the access fully, remove Khayt at myaccount.google.com.", "ar": "فُصل الحساب. ما في Drive يبقى هناك. لسحب الإذن كاملًا، احذف خيط من myaccount.google.com."],
        "mac.gdrive_disconnect_warn": ["en": "Models that were moved to the cloud will not open until they are brought back — bring them back first.", "ar": "المجسّمات المنقولة إلى السحابة لن تُفتح حتى تُعاد — أعدها أولًا."],
        "mac.gdrive_timed_out": ["en": "The browser sign-in was not finished within five minutes.", "ar": "لم يكتمل تسجيل الدخول في المتصفح خلال خمس دقائق."],
        "mac.gdrive_no_listener": ["en": "Could not start the sign-in on this Mac:", "ar": "تعذّر بدء تسجيل الدخول على هذا الماك:"],
        "mac.gdrive_http": ["en": "Google Drive answered {what} with HTTP {code}.", "ar": "ردّ Google Drive على {what} بالرمز {code}."],
        "mac.gdrive_refused": ["en": "Google Drive did not give Khayt what it asked for.", "ar": "لم يعطِ Google Drive خيط ما طلبه."],
        "mac.gdrive_no_refresh": ["en": "Google did not issue a refresh token. Remove Khayt at myaccount.google.com → Security → Third-party access, then connect again.", "ar": "لم يُصدر Google رمز تحديث. احذف خيط من myaccount.google.com ← الأمان ← وصول الجهات الخارجية، ثم اربط من جديد."],
        "mac.gdrive_page_not_connected": ["en": "Not connected", "ar": "لم يُربط"],
        "mac.gdrive_page_google_said": ["en": "Google reported:", "ar": "أفاد Google:"],
        "mac.gdrive_page_wrong_state": ["en": "That sign-in did not come from Khayt. Nothing was changed.", "ar": "تسجيل الدخول هذا لم يصدر عن خيط. لم يتغيّر شيء."],
        "mac.gdrive_page_no_code": ["en": "Google did not return an authorisation code.", "ar": "لم يُرجع Google رمز تفويض."],
        "mac.gdrive_page_almost": ["en": "Almost there", "ar": "بقي القليل"],
        "mac.gdrive_page_connected": ["en": "Connected", "ar": "تم الربط"],
        "mac.gdrive_page_close": ["en": "Khayt can now use your Google Drive. You can close this tab.", "ar": "يستطيع خيط الآن استخدام Google Drive. يمكنك إغلاق هذا التبويب."],
        "mac.cloudlib_title": ["en": "Online storage", "ar": "التخزين السحابي"],
        "mac.cloudlib_why": ["en": "Keep a copy of every model in a bucket, and move models nobody has used for a while there to free this Mac’s disk.", "ar": "احتفظ بنسخة من كل مجسّم في حاوية تخزين، وانقل المجسّمات غير المستخدمة منذ مدة إليها لتوفير مساحة القرص."],
        "mac.cloudlib_provider": ["en": "Provider", "ar": "المزوّد"],
        "mac.cloudlib_endpoint": ["en": "Endpoint", "ar": "نقطة الاتصال"],
        "mac.cloudlib_bucket": ["en": "Bucket", "ar": "الحاوية"],
        "mac.cloudlib_region": ["en": "Region", "ar": "المنطقة"],
        "mac.cloudlib_prefix": ["en": "Folder inside the bucket", "ar": "مجلد داخل الحاوية"],
        "mac.cloudlib_key_id": ["en": "Access key ID", "ar": "معرّف مفتاح الوصول"],
        "mac.cloudlib_secret": ["en": "Secret access key", "ar": "مفتاح الوصول السري"],
        "mac.cloudlib_back_up": ["en": "Back up new models to the bucket", "ar": "انسخ المجسّمات الجديدة إلى الحاوية"],
        "mac.cloudlib_back_up_all": ["en": "Back up the whole library now", "ar": "انسخ المكتبة كلها الآن"],
        "mac.cloudlib_test": ["en": "Test connection", "ar": "اختبار الاتصال"],
        "mac.cloudlib_tier": ["en": "Move old models to the cloud to free up space", "ar": "انقل المجسّمات القديمة إلى السحابة لتوفير المساحة"],
        "mac.cloudlib_keep_days": ["en": "Keep on this Mac for", "ar": "أبقِها على هذا الماك لمدة"],
        "mac.cloudlib_days": ["en": "days", "ar": "يوم"],
        "mac.cloudlib_free_now": ["en": "Free up space now", "ar": "وفّر المساحة الآن"],
        "mac.cloudlib_bring_all": ["en": "Bring everything back", "ar": "أعد كل شيء"],
        "mac.cloudlib_not_set_up": ["en": "Set up the bucket first: provider, bucket and access key.", "ar": "أعدّ الحاوية أولًا: المزوّد والحاوية ومفتاح الوصول."],
        "mac.cloudlib_test_ok": ["en": "Wrote, read back and removed a test file.", "ar": "كُتب ملف اختبار وقُرئ ثم حُذف."],
        "mac.cloudlib_test_mismatch": ["en": "The test file came back different from what was sent.", "ar": "عاد ملف الاختبار مختلفًا عمّا أُرسل."],
        "mac.cloudlib_test_failed": ["en": "The bucket refused:", "ar": "رفضت الحاوية:"],
        "mac.cloudlib_backup_some_failed": ["en": "{n} models could not be backed up.", "ar": "تعذّر نسخ {n} من المجسّمات."],
        "mac.cloudlib_backed_up_all": ["en": "Backed up {n} of {total} files.", "ar": "نُسخ {n} من {total} ملفات."],
        "mac.cloudlib_tier_off": ["en": "Switch on moving old models to the cloud first.", "ar": "فعّل نقل المجسّمات القديمة إلى السحابة أولًا."],
        "mac.cloudlib_freed": ["en": "Moved {n} of {total} models to the cloud, freeing {size}.", "ar": "نُقل {n} من {total} مجسّمات إلى السحابة، وتوفّرت {size}."],
        "mac.cloudlib_brought_back": ["en": "Brought back {n} models.", "ar": "أُعيد {n} من المجسّمات."],
        "mac.cloudlib_bring_back": ["en": "Bring back from the cloud", "ar": "أعده من السحابة"],
        "mac.cloudlib_bring_back_failed": ["en": "Could not bring it back:", "ar": "تعذّرت إعادته:"],
        "mac.cloudlib_in_cloud": ["en": "In the cloud", "ar": "في السحابة"],
        "mac.cloudlib_could_move": ["en": "{n} models could move to the cloud, freeing {size}. {cloud} already there.", "ar": "يمكن نقل {n} من المجسّمات إلى السحابة لتوفير {size}. {cloud} موجودة هناك."],
        "mac.cloudlib_progress": ["en": "{name} ({done} of {total})", "ar": "{name} ({done} من {total})"],
        "mac.cloudlib_saved": ["en": "Online storage saved.", "ar": "حُفظ التخزين السحابي."],
        "mac.cloudlib_safety": ["en": "Nothing leaves this Mac until the bucket has confirmed it holds the exact file, in a separate check.", "ar": "لا يُحذف شيء من هذا الماك قبل أن تؤكد الحاوية، في فحص مستقل، أنها تحمل الملف نفسه تمامًا."],
        // The off-site backup (OffsiteBackups.swift).
        "mac.offsite_title": ["en": "Off-site backup", "ar": "نسخة احتياطية خارج الجهاز"],
        "mac.offsite_why": ["en": "Every night, an encrypted copy of the book goes somewhere other than this Mac, so a lost or broken Mac does not take the shop’s records with it. The last 30 days and one a month for the 12 months before are kept.", "ar": "كل ليلة تُرسل نسخة مشفّرة من الدفتر إلى مكان غير هذا الماك، حتى لا يضيع سجل المتجر إذا فُقد الجهاز أو تعطّل. تُحفظ نسخ آخر 30 يومًا، ونسخة لكل شهر من الأشهر الاثني عشر السابقة."],
        "mac.offsite_on": ["en": "Back up the book off this Mac every night", "ar": "انسخ الدفتر خارج هذا الماك كل ليلة"],
        "mac.offsite_where": ["en": "Where", "ar": "إلى أين"],
        "mac.offsite_dest_folder": ["en": "A folder (such as iCloud Drive)", "ar": "مجلد (مثل iCloud Drive)"],
        "mac.offsite_dest_bucket": ["en": "The library’s bucket", "ar": "حاوية المكتبة"],
        "mac.offsite_choose": ["en": "Choose Folder…", "ar": "اختر مجلدًا…"],
        "mac.offsite_choose_prompt": ["en": "Back Up Here", "ar": "انسخ هنا"],
        "mac.offsite_icloud": ["en": "Use iCloud Drive", "ar": "استخدم iCloud Drive"],
        "mac.offsite_bucket_uses": ["en": "Goes to {bucket}, the bucket set up under Online storage.", "ar": "تُرسل إلى {bucket}، الحاوية المعدّة في التخزين السحابي."],
        "mac.offsite_bucket_missing": ["en": "No bucket is set up on this Mac. Set one up under Online storage first.", "ar": "لا توجد حاوية معدّة على هذا الماك. أعدّ واحدة في التخزين السحابي أولًا."],
        "mac.offsite_drive_uses": ["en": "Goes to the Google Drive connected under Online storage.", "ar": "تُرسل إلى Google Drive المربوط في التخزين السحابي."],
        "mac.offsite_drive_missing": ["en": "Google Drive is not connected on this Mac. Connect it under Online storage first.", "ar": "Google Drive غير مربوط على هذا الماك. اربطه في التخزين السحابي أولًا."],
        "mac.offsite_folder_missing": ["en": "Choose a folder first.", "ar": "اختر مجلدًا أولًا."],
        "mac.offsite_encrypted": ["en": "Encrypted with your Khayt Cloud key before it leaves this Mac. On a new Mac, sign in to Khayt Cloud with your passphrase to restore it.", "ar": "تُشفَّر بمفتاح سحابة خيط قبل أن تغادر هذا الماك. على ماك جديد، سجّل الدخول إلى سحابة خيط بعبارة المرور لاستعادتها."],
        "mac.offsite_needs_cloud": ["en": "Not backing up: the book only leaves this Mac encrypted with your Khayt Cloud key, and this Mac is not signed in to Khayt Cloud. Sign in to turn this on.", "ar": "لا يجري النسخ: لا يغادر الدفتر هذا الماك إلا مشفّرًا بمفتاح سحابة خيط، وهذا الماك غير مسجّل الدخول إلى سحابة خيط. سجّل الدخول لتفعيله."],
        "mac.offsite_needs_unlock": ["en": "Not backing up: the book only leaves this Mac encrypted with your Khayt Cloud key, and Khayt Cloud is locked on this Mac. Unlock it to back up.", "ar": "لا يجري النسخ: لا يغادر الدفتر هذا الماك إلا مشفّرًا بمفتاح سحابة خيط، وسحابة خيط مقفلة على هذا الماك. افتحها لإجراء النسخ."],
        "mac.offsite_last": ["en": "Last off-site backup: {when}, {size}", "ar": "آخر نسخة خارج الجهاز: {when}، {size}"],
        "mac.offsite_never": ["en": "No off-site backup yet.", "ar": "لا توجد نسخة خارج الجهاز بعد."],
        "mac.offsite_failing": ["en": "Failing since {when}: {why}", "ar": "تفشل منذ {when}: {why}"],
        "mac.offsite_now": ["en": "Back Up Now", "ar": "انسخ الآن"],
        "mac.offsite_done": ["en": "Backed up off this Mac: {name}, {size}.", "ar": "نُسخ خارج هذا الماك: {name}، {size}."],
        "mac.offsite_failed": ["en": "The off-site backup failed:", "ar": "فشلت النسخة الاحتياطية خارج الجهاز:"],
        "mac.offsite_wrong_key": ["en": "The backup would not open with this shop’s Khayt Cloud key.", "ar": "تعذّر فتح النسخة بمفتاح سحابة خيط لهذا المتجر."],
        "mac.offsite_read_back": ["en": "The copy read back from the destination was not the one sent, so it was not counted as a backup.", "ar": "النسخة المقروءة من الوجهة لم تطابق المرسلة، فلم تُحتسب نسخة احتياطية."],
        "mac.offsite_restore": ["en": "Restore from Off-site…", "ar": "استعد من خارج الجهاز…"],
        "mac.offsite_restore_title": ["en": "Restore from an off-site backup", "ar": "الاستعادة من نسخة خارج الجهاز"],
        "mac.offsite_restore_explain": ["en": "Choose a backup. It is downloaded, decrypted with your Khayt Cloud key and put back in place of the book.", "ar": "اختر نسخة. ستُنزَّل وتُفك بمفتاح سحابة خيط وتوضع مكان الدفتر."],
        "mac.offsite_loading": ["en": "Looking for backups…", "ar": "جارٍ البحث عن النسخ…"],
        "mac.offsite_none": ["en": "There are no off-site backups there yet.", "ar": "لا توجد نسخ خارج الجهاز هناك بعد."],
        "mac.offsite_restored": ["en": "Restored the book from {name}.", "ar": "استُعيد الدفتر من {name}."],
        "mac.offsite_overdue": ["en": "The off-site backup has been failing for more than 2 days. Settings → Preferences → Off-site backup says why.", "ar": "تفشل النسخة الاحتياطية خارج الجهاز منذ أكثر من يومين. يوضح السبب في الإعدادات ← التفضيلات ← نسخة احتياطية خارج الجهاز."],
        // The web store's catalogue (WebStore.swift).
        "mac.ws_button":     ["en": "Web Store", "ar": "المتجر الإلكتروني"],
        "mac.ws_desc":       ["en": "Your web store lists the products published from here: names, prices, photos, categories and stock, straight from the catalogue. Stores that read Khayt Cloud pick up a change within a few minutes.", "ar": "يعرض متجرك الإلكتروني المنتجات المنشورة من هنا: الأسماء والأسعار والصور والفئات والمخزون، مباشرةً من الكتالوج. تلتقط المتاجر التي تقرأ من سحابة خيط أي تغيير خلال دقائق."],
        "mac.ws_state":      ["en": "Web store", "ar": "المتجر الإلكتروني"],
        "mac.ws_unknown":    ["en": "Not checked yet", "ar": "لم يُتحقَّق بعد"],
        "mac.ws_listing":    ["en": "Publishing lists", "ar": "سيُنشر"],
        "mac.ws_products":   ["en": "{n} products", "ar": "{n} منتجات"],
        "mac.ws_products_one": ["en": "{n} product", "ar": "منتج واحد"],
        "mac.ws_products_two": ["en": "{n} products", "ar": "منتجان"],
        "mac.ws_follows":    ["en": "While the store is live, a change to a product is sent to it automatically.", "ar": "ما دام المتجر يعمل، يُرسل إليه أي تغيير على منتج تلقائيًا."],
        "mac.ws_confirmed":  ["en": "Published. Khayt Cloud is now listing {products} with {photos}. Your website shows them within 5 minutes.", "ar": "نُشر. تعرض سحابة خيط الآن {products} مع {photos}. يظهر ذلك في موقعك خلال 5 دقائق."],
        "mac.ws_short":      ["en": "Only part of it arrived: {sent} were sent.", "ar": "وصل جزء منه فقط: أُرسل {sent}."],
        "mac.ws_publishing": ["en": "Publishing to your web store…", "ar": "جارٍ النشر في متجرك الإلكتروني…"],
        "mac.ws_photos":     ["en": "{n} photos", "ar": "{n} صور"],
        "mac.ws_photos_one": ["en": "{n} photo", "ar": "صورة واحدة"],
        "mac.ws_photos_two": ["en": "{n} photos", "ar": "صورتين"],
        "mac.ws_emptied":    ["en": "Your web store was taken offline: no product in the catalogue can be listed.", "ar": "أُوقف متجرك الإلكتروني: لا يوجد في الكتالوج منتج يمكن عرضه."],
        "mac.ws_sent_unchecked": ["en": "Published {products}. Khayt Cloud could not be asked to confirm just now; open this again in a minute to check.", "ar": "نُشر {products}. تعذّر التأكد من سحابة خيط الآن؛ افتح هذا مجددًا بعد دقيقة للتحقق."],
        "mac.ws_show":       ["en": "Show on the web store", "ar": "اعرضه في المتجر الإلكتروني"],
        "mac.ws_hide":       ["en": "Hide", "ar": "إخفاء"],
        "mac.ws_hidden":     ["en": "{n} products are hidden from the web store.", "ar": "{n} منتجات مخفية عن المتجر الإلكتروني."],
        "mac.ws_hidden_one": ["en": "{n} product is hidden from the web store.", "ar": "منتج واحد مخفي عن المتجر الإلكتروني."],
        "mac.ws_hidden_two": ["en": "{n} products are hidden from the web store.", "ar": "منتجان مخفيان عن المتجر الإلكتروني."],
        "mac.ws_review":     ["en": "Before you publish", "ar": "قبل النشر"],
        "mac.ws_issue_no_price": ["en": "no price", "ar": "بلا سعر"],
        "mac.ws_issue_no_photo": ["en": "no photo", "ar": "بلا صورة"],
        "mac.ws_issue_no_description": ["en": "no description", "ar": "بلا وصف"],
        "mac.ws_issue_no_category": ["en": "no category", "ar": "بلا تصنيف"],
        "mac.ws_issue_second_language": ["en": "the second language is missing or repeats the first", "ar": "اللغة الثانية ناقصة أو تكرّر الأولى"],
        "mac.ws_issue_file_name": ["en": "a name that reads like a file name", "ar": "اسم يشبه اسم ملف"],
        "mac.ws_settings":   ["en": "Store settings: shipping, deposit, payment link, promo codes", "ar": "إعدادات المتجر: الشحن والعربون ورابط الدفع وأكواد الخصم"],
        "mac.ws_settings_saved_live": ["en": "Store settings saved, and on their way to your web store.", "ar": "حُفظت إعدادات المتجر، وهي في طريقها إلى متجرك الإلكتروني."],
        "mac.ws_settings_saved": ["en": "Store settings saved. Publish to send them to your web store.", "ar": "حُفظت إعدادات المتجر. انشر لإرسالها إلى متجرك الإلكتروني."],
        "mac.ws_update":     ["en": "Publish Changes", "ar": "نشر التغييرات"],
        "mac.ws_page":       ["en": "Shop page", "ar": "صفحة المتجر"],
        "mac.ws_open_page":  ["en": "Open", "ar": "فتح"],
        "mac.ws_failed":     ["en": "Not published:", "ar": "لم يُنشر:"],
        "mac.ws_check_failed": ["en": "Could not check the web store:", "ar": "تعذّر التحقق من المتجر الإلكتروني:"],
        "mac.ws_err_token":  ["en": "Khayt Cloud did not accept this shop's sign-in. Sign in again from the Book menu.", "ar": "لم تقبل سحابة خيط تسجيل دخول هذا المتجر. سجّل الدخول مجددًا من قائمة الدفتر."],
        "mac.ws_err_readonly": ["en": "This sign-in can view the shop but not publish for it.", "ar": "يستطيع هذا الحساب عرض المتجر لكن لا يستطيع النشر له."],
        "mac.ws_err_too_large": ["en": "The catalogue is too large to publish. Try without photos.", "ar": "الكتالوج أكبر من أن يُنشر. جرّب دون صور."],
        "mac.ws_err_http":   ["en": "Khayt Cloud answered {code}.", "ar": "ردّت سحابة خيط بالرمز {code}."],
        "mac.qs_last":       ["en": "Storefront prices", "ar": "أسعار المتجر"],
        "mac.qs_published":  ["en": "Sent to Khayt Cloud for your storefront.", "ar": "أُرسلت إلى سحابة خيط لمتجرك."],
        "mac.qs_withdrawn":  ["en": "Withdrawn from your storefront.", "ar": "سُحبت من متجرك."],
        "mac.qs_not_offered": ["en": "Khayt Cloud does not take storefront prices yet.", "ar": "لا تستقبل سحابة خيط أسعار المتجر بعد."],
        "mac.qs_failed":     ["en": "Not sent:", "ar": "لم تُرسل:"],
        "mac.qs_needs_cloud": ["en": "Sign in to the cloud (Book menu) so your storefront can use these prices.", "ar": "سجّل الدخول إلى السحابة (قائمة الدفتر) ليستخدم متجرك هذه الأسعار."],
        // The calculator's own rates, which it could not show or change.
        "mac.calc_cost_rates":    ["en": "Cost rates", "ar": "أسعار التكلفة"],
        "mac.calc_rates_default": ["en": "Khayt's defaults", "ar": "الإعدادات الافتراضية"],
        "mac.calc_rates_edited":  ["en": "edited", "ar": "مُعدَّل"],
        "mac.calc_rates_reset":   ["en": "Reset", "ar": "إعادة"],
        // One step along the way work goes, without naming the stage.
        "mac.move_along":    ["en": "Move Along",   "ar": "تقديم"],
        "mac.move_back":     ["en": "Move Back",    "ar": "إرجاع"],
        // The other shelf. Every other `cons.` word is in the shared
        // catalogue already, with its Arabic; these two are this sheet's own.
        "cons.unit_ph":      ["en": "each / ml / roll", "ar": "حبة / مل / لفة"],
        "cons.min_stock_note": ["en": "Empty counts as low whatever this says.",
                                "ar": "النفاد يُعد انخفاضاً مهما كانت هذه القيمة."],
        "mac.swatch":        ["en": "Swatch",       "ar": "اللون"],
        "mac.telegram_sent":   ["en": "Telegram message sent.", "ar": "أُرسلت رسالة تيليجرام."],
        "mac.telegram_failed": ["en": "The job was saved, but the Telegram message did not go out:",
                                "ar": "حُفظ العمل، لكن لم تُرسل رسالة تيليجرام:"],
        // ── FOUR THAT RENDERED AS THEIR OWN KEYS ──────────────────────────
        //
        // Added as `callIt("mac.…")` calls in #1216 and #1224 with no words
        // behind them, so the catalogue button read "mac.job_from_product" on
        // screen. A missing key is not blank and does not fall back — it IS the
        // key, which looks like placeholder text nobody removed.
        "mac.job_from_product":    ["en": "New Job from This", "ar": "عمل جديد من هذا"],
        "mac.add_tier":            ["en": "Add a tier", "ar": "إضافة شريحة"],
        "mac.wholesale":           ["en": "Wholesale", "ar": "جملة"],
        "mac.how_it_prints":       ["en": "How it prints", "ar": "كيف يُطبع"],
        "mac.cloud_sign_in":       ["en": "Sign in to the cloud", "ar": "تسجيل الدخول إلى السحابة"],
        "mac.cloud_sign_out":   ["en": "Sign out of the cloud", "ar": "تسجيل الخروج من السحابة"],
        "mac.cloud_sign_out_do": ["en": "Sign out", "ar": "تسجيل الخروج"],
        "mac.cloud_sign_out_q": ["en": "Sign out of Khayt Cloud on this Mac? The book stays, and so does the cloud copy.", "ar": "تسجيل الخروج من سحابة خيط على هذا الماك؟ يبقى الدفتر وتبقى النسخة السحابية."],
        "mac.cloud_signed_out": ["en": "Signed out. This Mac no longer syncs; the book and the cloud copy are both kept.", "ar": "تم تسجيل الخروج. لم يعد هذا الماك يزامن؛ الدفتر والنسخة السحابية محفوظان."],
        "mac.cloud_remember":   ["en": "Remember me on this Mac", "ar": "تذكّرني على هذا الماك"],
        "mac.cloud_remember_why": ["en": "Keeps the unlock key in this Mac's Keychain, so Khayt opens signed in. Turn it off on a Mac other people use.", "ar": "يحفظ مفتاح الفتح في سلسلة مفاتيح هذا الماك ليفتح خيط وأنت مسجّل الدخول. أوقفه على ماك يستخدمه آخرون."],
        "mac.cloud_line_hint":  ["en": "Click to sign in or check the cloud; right-click for more.", "ar": "انقر لتسجيل الدخول أو فحص السحابة، وانقر بالزر الأيمن للمزيد."],
        "mac.cloud_signed_in":     ["en": "Signed in. This Mac can reach the shop's cloud.",
                                    "ar": "تم تسجيل الدخول. يستطيع هذا الجهاز الوصول إلى سحابة المشغل."],
        "mac.cloud_signin_failed": ["en": "Could not sign in:",
                                    "ar": "تعذّر تسجيل الدخول:"],
        "mac.cloud_wrong_passphrase": [
            "en": "Signed in, but that sync passphrase does not open this shop's key — nothing was saved.",
            "ar": "تم تسجيل الدخول، لكن عبارة المزامنة لا تفتح مفتاح هذا المشغل — لم يُحفظ شيء."],
        "mac.cloud_key_local": [
            "en": "The server did not send a sync key, so this Mac used the one already in your book. It opened — but the cloud has no copy to give another machine, so keep your recovery key safe.",
            "ar": "لم يرسل الخادم مفتاح مزامنة، فاستخدم هذا الجهاز المفتاح الموجود في دفترك. فُتح المفتاح — لكن لا توجد نسخة لدى السحابة لتعطيها لجهاز آخر، فاحتفظ بمفتاح الاسترداد."],
        "mac.cloud_forgot":        ["en": "Forgot the password?", "ar": "نسيت كلمة المرور؟"],
        "mac.cloud_reset_title":   ["en": "Reset the account password", "ar": "إعادة تعيين كلمة مرور الحساب"],
        "mac.cloud_reset_send":    ["en": "Email me a code", "ar": "أرسل لي رمزاً"],
        "mac.cloud_reset_sent":    ["en": "If that address has an account, a code is on its way to {email}.",
                                    "ar": "إن كان لهذا العنوان حساب، فالرمز في طريقه إلى {email}."],
        "mac.cloud_reset_code":    ["en": "Code from the email", "ar": "الرمز من البريد"],
        "mac.cloud_reset_newpw":   ["en": "New account password", "ar": "كلمة مرور جديدة للحساب"],
        "mac.cloud_reset_do":      ["en": "Set the password", "ar": "تعيين كلمة المرور"],
        "mac.cloud_reset_done":    ["en": "Password changed. Sign in with the new one.",
                                    "ar": "تغيّرت كلمة المرور. سجّل الدخول بالجديدة."],
        "mac.cloud_reset_failed":  ["en": "Could not set the password:", "ar": "تعذّر تعيين كلمة المرور:"],
        "mac.cloud_reset_no_mail": ["en": "This server cannot send email, so no code will arrive. Nothing was changed.",
                                    "ar": "لا يستطيع هذا الخادم إرسال البريد، لذا لن يصل رمز. لم يتغيّر شيء."],
        "mac.cloud_reset_send_failed": ["en": "The server tried to send the code and could not. Nothing was changed.",
                                        "ar": "حاول الخادم إرسال الرمز ولم يتمكّن. لم يتغيّر شيء."],
        // The sentence that stops a shop resetting the wrong thing.
        "mac.cloud_reset_note": [
            "en": "This changes the account password only. Your shop's data stays encrypted under your sync passphrase — if THAT is what you have lost, a reset will not open it and your recovery key is what you need.",
            "ar": "هذا يغيّر كلمة مرور الحساب فقط. تبقى بيانات مشغلك مشفّرة بعبارة المزامنة — فإن كانت هي المفقودة فلن تفتحها إعادة التعيين، ومفتاح الاسترداد هو ما تحتاجه."],
        "mac.cloud_server":        ["en": "Server", "ar": "الخادم"],
        "mac.cloud_email":         ["en": "Email", "ar": "البريد"],
        "mac.cloud_password":      ["en": "Password", "ar": "كلمة المرور"],
        "mac.portal_refreshed": ["en": "The customer's tracking link was updated.",
                                 "ar": "حُدّث رابط متابعة العميل."],
        "mac.portal_failed":    ["en": "The job was saved, but the customer's tracking link still shows the old stage:",
                                 "ar": "حُفظ العمل، لكن رابط المتابعة ما زال يعرض المرحلة السابقة:"],
        "mac.email_sent":      ["en": "The customer was emailed.",
                                "ar": "أُرسل بريد إلى العميل."],
        "mac.email_failed":    ["en": "The job was saved, but the customer's email did not go out:",
                                "ar": "حُفظ العمل، لكن لم يُرسل بريد العميل:"],
        "mac.webhooks_sent":   ["en": "Told {n} other system(s).",
                                "ar": "أُبلغ {n} نظام آخر."],
        "mac.webhook_failed":  ["en": "The job was saved, but {where} was not told:",
                                "ar": "حُفظ العمل، لكن لم يُبلَّغ {where}:"],
        "mac.webhook_bad_url": ["en": "that address cannot be read.",
                                "ar": "تعذّرت قراءة هذا العنوان."],
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
        "mac.restore_before_wipe": ["en": "taken before everything was reset", "ar": "أُخذت قبل مسح كل شيء"],
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
        // "Export all data (CSV)" is what the other app calls it; said the
        // same way here so a shop that has used one recognises the other.
        "mac.export_csv":       ["en": "Export All Data (CSV)…",
                                 "ar": "تصدير كل البيانات (CSV)…"],
        "mac.export_csv_where": ["en": "Choose a folder for the CSV files",
                                 "ar": "اختر مجلداً لملفات CSV"],
        // READING BACK A LABEL THIS APP PRINTED. Not "scan" as in a camera:
        // a barcode scanner is a keyboard, and what the shop needs is
        // somewhere for it to type.
        "mac.scan_title": ["en": "Scan a Label", "ar": "مسح ملصق"],
        "mac.scan_hint":  ["en": "Hold a scanner to a spool or parcel label, or type the code.",
                           "ar": "وجّه الماسح إلى ملصق بكرة أو طرد، أو اكتب الرمز."],
        // The shape of a code, said rather than typed into the field:
        // `WordsAreTranslatedTests` refuses English spelled out in a view, and
        // "or a tracking link" is the half a shop actually has to be told.
        "mac.scan_ph": ["en": "KHAYT-SPOOL:… or a tracking link",
                        "ar": "KHAYT-SPOOL:… أو رابط تتبّع"],
        "mac.scan_open":  ["en": "Open", "ar": "فتح"],
        "mac.scan_unknown": ["en": "That is not a Khayt label.", "ar": "هذا ليس ملصق خيط."],
        // WHO A CAMPAIGN WOULD REACH. The other app has no word for the
        // count, because it draws a number beside a fixed label; this says the
        // whole sentence, which is what a shop about to write to forty people
        // is actually reading.
        "mac.campaign_reach":     ["en": "{n} customers would get this",
                                   "ar": "{n} عملاء سيصلهم هذا"],
        // `{n}`, not a typed "1": `counting` puts a numeral in front of any
        // value that neither carries `{n}` nor spells the number out, so a
        // literal 1 here reads "1 1 customer would get this". The Arabic says
        // واحد, which the same rule recognises and leaves alone.
        "mac.campaign_reach_one": ["en": "{n} customer would get this",
                                   "ar": "عميل واحد سيصله هذا"],
        "mac.campaign_reach_two": ["en": "2 customers would get this",
                                   "ar": "عميلان سيصلهما هذا"],
        // THE COUNT IS IN THE QUESTION — and the question itself is the other
        // app's `camp.confirm`, which is translated into nine languages. Only
        // the HINT is written here, because the other app has no equivalent:
        // it does not say that the run cannot be taken back.
        // WHAT HAS ALREADY GONE OUT. Neither app has ever drawn this, so there
        // is no shared word to borrow — the other one writes the same log and
        // shows it nowhere.
        "mac.campaign_log": ["en": "Already sent", "ar": "أُرسل سابقاً"],
        // WHERE A SPOOL WENT. The other app calls this "Spool history"; there
        // is a shared key for the heading (`inv.spool_history`) but none for
        // the empty state this app needs, so both are written here to keep the
        // pair in one place rather than half-borrowed.
        // UNITS for the filament settings. The other app hard-codes "°C" and
        // "mm/s" into its markup; here they are words, because a unit beside a
        // number in an Arabic column is drawn by the catalogue like any other.
        "mac.celsius": ["en": "°C", "ar": "°م"],
        "mac.mm_s": ["en": "mm/s", "ar": "مم/ث"],
        // DRIED TODAY. The other app has a whole drying LOG and a word for
        // it (`inv.dry_log`), but none for the single act — it opens a sheet
        // and asks for a date, a temperature and a duration. This app answers
        // the nag where the nag appears, and a menu item needs its own words.
        // MOVING A WHOLE FOLDER. The other app files a SELECTION into a
        // group and has no word for moving a folder, because its library has
        // no folders to move.
        "mac.move_folder": ["en": "Move to…", "ar": "نقل إلى…"],
        "mac.move_to_top": ["en": "Top level", "ar": "المستوى الأعلى"],
        "mac.move_into_itself": ["en": "A folder cannot be moved inside itself.",
                                 "ar": "لا يمكن نقل مجلد داخل نفسه."],
        "mac.mark_dried": ["en": "Dried today", "ar": "جُفّفت اليوم"],
        "mac.spool_history": ["en": "Where this went", "ar": "أين ذهب هذا"],
        "mac.spool_history_empty": ["en": "Nothing has been printed with this spool yet.",
                                    "ar": "لم يُطبع شيء بهذه البكرة بعد."],
        "mac.spool_history_total": ["en": "Used altogether", "ar": "المستخدم إجمالاً"],
        "mac.campaign_confirm_hint": ["en": "One message each, a third of a second apart. It cannot be taken back.",
                                      "ar": "رسالة لكل عميل، بفاصل ثلث ثانية. لا يمكن التراجع عن ذلك."],
        // ── WHAT THIS USED TO SAY ─────────────────────────────────────────
        //
        // "Campaigns go through SendGrid or Mailgun. A shop on its own SMTP
        // server still sends these from the Windows and Linux app." Which was
        // accurate and was still the wrong thing to print: a shop reading it
        // has a mailing list, this app, and an instruction to go and install
        // another one. SMTP is a door here now, so the only shops that reach
        // this line are the ones that have not set email up at all — and
        // Settings is where they do that, in this app.
        "mac.campaign_needs_email": ["en": "Set up an email provider in Settings before sending a campaign.",
                                     "ar": "اضبط مزوّد البريد في الإعدادات قبل إرسال حملة."],
        "mac.whatsapp": ["en": "WhatsApp", "ar": "واتساب"],
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
        // The slicer's own time percentage, relayed by the firmware — the
        // number on the machine's screen. Named after where the shop can
        // check it, not after the G-code command that carries it.
        "mac.by_time":       ["en": "of the estimated time", "ar": "من الوقت المقدَّر"],
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
        //
        // AND IT NAMES NO OTHER APP. It used to read "Runs in the Windows and
        // Linux app for now", which is a shop being sent somewhere else for a
        // feature this one should simply have. Every feature the shared rule
        // offers is performed here — `AiRunsHereTests.nothingIsLeftToTheOtherApp`
        // fails the build if a fifth is ever added and not built — so this line
        // is unreachable today and says the honest thing if it ever is not.
        "mac.ai_elsewhere":  ["en": "Not available here yet — switching it on "
                              + "records your answer for the whole shop.",
                              "ar": "غير متاح هنا بعد — تشغيله يسجّل إجابتك "
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
        "mac.product_from_model": ["en": "Add to the catalogue",
                                   "ar": "أضف إلى الكتالوج"],
        "mac.catalogue_add_as_one": ["en": "Add {n} models to the catalogue as one product", "ar": "أضف {n} مجسّمات إلى الكتالوج كمنتج واحد"],
        "mac.catalogue_add_each": ["en": "Add {n} models to the catalogue, one product each", "ar": "أضف {n} مجسّمات إلى الكتالوج، منتجًا لكل منها"],
        "mac.catalogue_add_folder": ["en": "Add this folder to the catalogue as one product", "ar": "أضف هذا المجلد إلى الكتالوج كمنتج واحد"],
        "mac.catalogue_added_each": ["en": "Added {n} products to the catalogue, each priced from its model. Open one to adjust it.", "ar": "أُضيف {n} منتجات إلى الكتالوج، سُعّر كل منها من مجسّمه. افتح أيًّا منها لتعديله."],
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
                            "ar": "من طابعاتك — {rate} غ/ساعة، مقيسة على {jobs} أعمال."],
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
        "mac.est_density": ["en": "Filament density (g/cm³)", "ar": "كثافة الخيط (غ/سم³)"],
        "mac.est_infill": ["en": "Default infill (%)", "ar": "التعبئة الافتراضية (%)"],
        "mac.est_wall": ["en": "Wall thickness (mm)", "ar": "سماكة الجدار (مم)"],
        "mac.est_waste": ["en": "Waste (%)", "ar": "الهدر (%)"],
        "mac.est_wall_hint": ["en": "Perimeters plus top and bottom skin. Khayt works out how much of a part is shell from this and its surface area.",
                              "ar": "المحيطات مع الطبقة العلوية والسفلية. يحسب خيط من هذا ومن مساحة السطح كم من الجزء قشرة."],
        "mac.est_rate_hint": ["en": "How fast your printers run is not asked for — Khayt learns it from jobs whose real weight and duration were recorded.",
                              "ar": "لا نسأل عن سرعة طابعاتك — يتعلّمها خيط من الأعمال التي سُجّل وزنها ومدّتها الحقيقية."],
        "mac.moved_looking": ["en": "Looking…", "ar": "جارٍ البحث…"],
        // The slow half: listening found nothing, so the addresses around the
        // one it used to be on are being asked one at a time.
        "mac.moved_asking": ["en": "Asking the network…", "ar": "جارٍ سؤال الشبكة…"],
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
        // ── AN ESTIMATE, SAID AS ONE ──────────────────────────────────────
        //
        // Two sentences, not one, because they are two different claims. A
        // calibrated estimate is grounded in the shop's own finished jobs and
        // says how many; an uncalibrated one is an assumption and says so. A
        // figure a shop believes is measured, and prices against, is the whole
        // risk this wording exists to avoid.
        "mac.product_estimated": ["en": "{fields} estimated from the model itself — "
                                  + "no measured jobs yet, so check before you sell it.",
                                  "ar": "{fields} مُقدَّرة من المجسم نفسه — لا أعمال مقيسة بعد، "
                                  + "فراجعها قبل البيع."],
        "mac.product_estimated_calibrated": ["en": "{fields} estimated from the model, at the rate "
                                             + "your own {n} measured jobs actually ran at.",
                                             "ar": "{fields} مُقدَّرة من المجسم، بالمعدل الذي جرت "
                                             + "به {n} من أعمالك المقيسة."],
        "mac.product_costed_with": ["en": "Costed with your {spool} and your usual rates — change either on the sheet.", "ar": "حُسبت التكلفة بخامة {spool} وأسعارك المعتادة — غيّر أيًّا منها في الصفحة."],
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
        "plug.title": ["en": "Smart plug", "ar": "المقبس الذكي"],
        "plug.none": ["en": "None", "ar": "لا يوجد"],
        "plug.kind_shelly": ["en": "Shelly (Gen 1)", "ar": "Shelly (الجيل 1)"],
        "plug.host": ["en": "Address", "ar": "العنوان"],
        "plug.entity": ["en": "Entity", "ar": "الكيان"],
        "plug.token": ["en": "Access token", "ar": "رمز الوصول"],
        "plug.user": ["en": "User", "ar": "المستخدم"],
        "plug.password": ["en": "Password", "ar": "كلمة المرور"],
        "plug.auto_off": ["en": "Turn off after a print, once cooled", "ar": "أطفئ بعد انتهاء الطباعة وبعد أن تبرد"],
        "plug.delay": ["en": "Wait", "ar": "الانتظار"],
        "plug.minutes": ["en": "minutes", "ar": "دقيقة"],
        "plug.why": ["en": "Khayt never cuts power while the printer is printing, paused, not answering, or hot.", "ar": "لا يقطع خيط الكهرباء أبدًا والطابعة تطبع أو متوقفة مؤقتًا أو لا تجيب أو ساخنة."],
        "plug.on": ["en": "Plug on", "ar": "المقبس يعمل"],
        "plug.off": ["en": "Plug off", "ar": "المقبس مطفأ"],
        "plug.unknown": ["en": "Plug not answering", "ar": "المقبس لا يجيب"],
        "plug.turn_on": ["en": "Turn on", "ar": "تشغيل"],
        "plug.turn_off": ["en": "Turn off", "ar": "إطفاء"],
        "plug.printing": ["en": "Not while it is printing or paused.", "ar": "ليس أثناء الطباعة أو الإيقاف المؤقت."],
        "plug.not_answering": ["en": "Not while the printer is not answering: it may still be printing.", "ar": "ليس والطابعة لا تجيب: قد تكون ما زالت تطبع."],
        "plug.no_reading": ["en": "Not until Khayt has heard from the printer.", "ar": "ليس قبل أن يسمع خيط من الطابعة."],
        "plug.hot": ["en": "Not until the nozzle has cooled below 50 °C.", "ar": "ليس قبل أن تبرد الفوهة إلى أقل من 50 °م."],
        "plug.unreachable": ["en": "The plug did not answer.", "ar": "المقبس لم يُجب."],
        "plug.auto_off_done": ["en": "Turned off {name}: the print finished and it has cooled.", "ar": "أُطفئت {name}: انتهت الطباعة وبردت."],
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
        "mac.parts_cost_nothing": ["en": "These parts have no filament chosen, so they cost "
                                   + "nothing — saving will set this product's price to zero. "
                                   + "Pick a spool for each part.",
                                   "ar": "لم يُختر خيط لهذه القطع، فلا تكلفة لها — سيصبح سعر المنتج "
                                   + "صفرًا عند الحفظ. اختر بكرة لكل قطعة."],
        // THE SAME FACT, SAID WHERE THE SHOP MEETS IT.
        //
        // The warning above is in the product EDITOR. A shop that takes a job
        // from the catalogue never opens that sheet: it presses Take a job,
        // gets a form with a part in it and a total of zero, and has nothing to
        // read. Reported exactly that way — "I click create a job for an item
        // in catalogue but the price is zero?"
        "mac.product_not_costed": ["en": "{product} has no weight, print time or "
                                   + "filament recorded, so there is nothing to price yet. "
                                   + "Fill the part in below, or open it in the Catalogue "
                                   + "and cost it once.",
                                   "ar": "لا يحتوي {product} على وزن أو زمن طباعة أو خيط مسجّل، "
                                   + "فلا شيء لتسعيره بعد. أكمل القطعة أدناه، أو افتحه في "
                                   + "الكتالوج وسعّره مرة واحدة."],
        // The shop's own realized margins, NET OF TAX. Two sentences because
        // the rule falls back to every priced job when a material has fewer
        // than three, and a median over "everything you sell" is a different
        // claim from a median over "jobs in this material".
        "mac.you_usually_make": ["en": "You usually make {pct}% — median of {n} finished jobs.",
                                 "ar": "تحقق عادةً {pct}% — وسيط {n} عملًا منتهيًا."],
        "mac.you_usually_make_material": ["en": "You usually make {pct}% on {material} — "
                                          + "median of {n} finished jobs.",
                                          "ar": "تحقق عادةً {pct}% على {material} — "
                                          + "وسيط {n} عملًا منتهيًا."],
        "mac.use_it":        ["en": "Use it",          "ar": "استخدمه"],
        "mac.ask_what_to_charge": ["en": "Ask what to charge", "ar": "اسأل عن السعر"],
        "mac.advice_no_reason": ["en": "Suggested {pct}%, with no reason given.",
                                 "ar": "اقترح {pct}% دون ذكر سبب."],
        "mac.ai_price_not_consented": ["en": "Switch on \"Price advice\" in "
                                       + "Settings → AI assist first.",
                                       "ar": "فعّل «نصيحة التسعير» في الإعدادات ← مساعد الذكاء أولًا."],
        // ── DRAFTING A MESSAGE TO A CUSTOMER ──────────────────────────────
        "mac.draft_a_message": ["en": "Draft a message", "ar": "صياغة رسالة"],
        "mac.what_about":    ["en": "About",             "ar": "بخصوص"],
        "mac.what_to_say":   ["en": "What should it say?", "ar": "ماذا تريد أن تقول؟"],
        "mac.draft_again":   ["en": "Draft another",     "ar": "صُغ أخرى"],
        "mac.copy_message":  ["en": "Copy",              "ar": "نسخ"],
        "mac.copied":        ["en": "Copied",            "ar": "نُسخ"],
        // Said under every draft. It DRAFTS; the shop sends.
        "mac.draft_not_sent": ["en": "Nothing has been sent. Read it, change what you want, "
                               + "and send it yourself.",
                               "ar": "لم يُرسل شيء. اقرأها وعدّل ما تشاء وأرسلها بنفسك."],
        "mac.ai_reply_not_consented": ["en": "Switch on \"Customer message drafting\" in "
                                       + "Settings → AI assist first.",
                                       "ar": "فعّل «صياغة رسائل العملاء» في الإعدادات ← مساعد الذكاء أولًا."],

        // ── ASKING ABOUT THE BOOK ─────────────────────────────────────────
        "mac.ask_the_book":  ["en": "Ask about your book", "ar": "اسأل عن دفترك"],
        "mac.ask_a_question": ["en": "Ask a question",     "ar": "اطرح سؤالًا"],
        "mac.ask_it":        ["en": "Ask",                 "ar": "اسأل"],
        "mac.thinking":      ["en": "Thinking…",           "ar": "يفكّر…"],
        "mac.start_over":    ["en": "Start over",          "ar": "ابدأ من جديد"],
        // What it is given, said before the first question rather than after a
        // shop wonders. The payload is a SUMMARY — no customer name, address or
        // order reference is in it — and that is worth saying plainly.
        "mac.ask_what_it_sees": ["en": "It is given a summary of your book — totals, counts and "
                                 + "what is outstanding. No customer names or order details "
                                 + "leave your Mac. Try:",
                                 "ar": "يُعطى ملخصًا لدفترك — إجماليات وأعداد وما هو مستحق. "
                                 + "لا تغادر أسماء العملاء ولا تفاصيل الطلبات ماكك. جرّب:"],
        // Questions the summary genuinely contains an answer to. A blank box is
        // a test a shop can fail; these are the ones that work.
        "mac.ask_eg_month":  ["en": "How did this month compare with last?",
                              "ar": "كيف كان هذا الشهر مقارنةً بالماضي؟"],
        "mac.ask_eg_owing":  ["en": "How much is still owed to me?",
                              "ar": "كم المبلغ المستحق لي؟"],
        "mac.ask_eg_busy":   ["en": "What is sitting in the queue right now?",
                              "ar": "ما الذي ينتظر في الطابور الآن؟"],
        "mac.ai_assistant_not_consented": ["en": "Switch on \"Ask about your book\" in "
                                           + "Settings → AI assist first.",
                                           "ar": "فعّل «اسأل عن دفترك» في الإعدادات ← مساعد الذكاء أولًا."],
        "mac.no_parts_no_price": ["en": "Add a part to give this product a price — "
                                  + "it is worked out from what the parts cost.",
                                  "ar": "أضف قطعة ليكون للمنتج سعر — يُحسب من تكلفة القطع."],
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
        "mac.delete_product_q": ["en": "Delete “{name}”?", "ar": "حذف «{name}»؟"],
        // The document a customer is handed
        "mac.save_pdf":      ["en": "Save PDF",     "ar": "حفظ PDF"],
        "mac.saved_to":      ["en": "Saved as",     "ar": "حُفظ باسم"],
        "mac.no_document":   ["en": "This job's invoice could not be built.",
                              "ar": "تعذّر إنشاء فاتورة هذا العمل."],
        // ── The LAN server ───────────────────────────────────────────────
        // The TAB name, as with Integrations and Slicers: Khayt's own heading
        // for this block is `lan.settings_intro`, a sentence. The words inside
        // the pane are the shared `lan.*` ones the Electron page reads, so the
        // two apps call the same switch the same thing.
        "mac.nav_online":    ["en": "Online", "ar": "الشبكة"],
        "mac.online_title":  ["en": "The phone's live queue", "ar": "قائمة الانتظار على الهاتف"],
        // WHAT THIS PANE CLAIMS IS HELD TO WHAT THE SERVER ROUTES.
        //
        // This sentence sent the shop to the other app for the intake form,
        // quote approval and the calendar feed — all three of which this app
        // has served since alpha.18, out of `LanServer.swift`. A shop reading
        // it would have gone and started a second app to be handed something
        // this one was already serving on the same Wi‑Fi.
        //
        // `OnlinePaneTruthTests` now reads the route table and fails the build
        // if the closing sentence sends a shop elsewhere for anything this app
        // answers — the same correction, and the same shape of guard, as the
        // assistant pane's "runs in the Windows and Linux app".
        "mac.online_desc":   ["en": "This Mac serves the live queue to phones on the shop's Wi‑Fi, "
                                    + "the customer intake form, quote approval, the tracking page "
                                    + "and the calendar feed, and the same status API the Windows "
                                    + "and Linux app serves. It takes orders from Salla and Zid, and parcel "
                                    + "updates from SMSA, Aramex and Saudi Post. Printer webhooks run in that app "
                                    + "for now.",
                              "ar": "يقدّم هذا الماك قائمة الانتظار المباشرة للهواتف على شبكة Wi‑Fi الخاصة بالمحل، "
                                    + "ونموذج طلبات العملاء واعتماد عروض الأسعار وصفحة تتبّع الطلب "
                                    + "وتقويم المواعيد، ونفس واجهة الحالة التي يقدّمها تطبيق ويندوز ولينكس، "
                                    + "ويستقبل الطلبات من سلة وزد وتحديثات الشحنات من سمسا وأرامكس والبريد السعودي. "
                                    + "أما ويب هوك الطابعات فيعمل في ذلك التطبيق حالياً."],
        "mac.cloud_key_published": ["en": "This shop's key is on Khayt Cloud now, and the book has been sent, so your other devices can sign in and sync.",
                                    "ar": "مفتاح المتجر موجود الآن على خيط السحابي، وأُرسل الدفتر، فيمكن لأجهزتك الأخرى تسجيل الدخول والمزامنة."],
        "mac.cloud_key_not_published": ["en": "Signed in, but this shop's key could not be put on Khayt Cloud, so other devices cannot sync yet. Sign in again to retry.",
                                        "ar": "تم تسجيل الدخول، لكن تعذّر وضع مفتاح المتجر على خيط السحابي، فلا يمكن للأجهزة الأخرى المزامنة بعد. سجّل الدخول مجددًا للمحاولة."],
        "mac.licence_proof": ["en": "Licence proof", "ar": "إثبات الترخيص"],
        "mac.licence_code":  ["en": "Licence code", "ar": "رمز الترخيص"],
        "mac.licence_verify": ["en": "Verification page", "ar": "صفحة التحقق"],
        "mac.licence_has_end": ["en": "It ends on a date (a subscription)", "ar": "ينتهي في تاريخ محدد (اشتراك)"],
        "mac.licence_until": ["en": "Covers sales until", "ar": "يغطي البيع حتى"],
        "mac.licence_lapsed": ["en": "Lapsed on", "ar": "انتهى في"],
        "mac.licence_proof_hint": ["en": "The code and page the designer gave you for selling prints of this model. "
                                        + "After the last day, every job and product using it says it is no longer covered.",
                                   "ar": "الرمز والصفحة التي أعطاك إياها المصمم لبيع مطبوعات هذا النموذج. "
                                        + "بعد آخر يوم، ينبّه كل طلب ومنتج يستخدمه أنه لم يعد مشمولًا."],
        "mac.licence_bad_link": ["en": "The verification page must be an http or https address.",
                                 "ar": "يجب أن تكون صفحة التحقق عنوان http أو https."],
        "mac.licence_bad_date": ["en": "That end date could not be read.", "ar": "تعذّرت قراءة تاريخ الانتهاء."],
        "mac.licence_not_for_sale": ["en": "Not licensed for sale", "ar": "غير مرخّص للبيع"],
        "mac.licence_nc_line": ["en": "{name}: its licence does not allow selling prints.",
                                "ar": "{name}: ترخيصه لا يسمح ببيع المطبوعات."],
        "mac.licence_expired_line": ["en": "{name}: the bought licence ended on {until}.",
                                     "ar": "{name}: انتهى الترخيص المشترى في {until}."],
        "mac.alert_runout":  ["en": "{machine} ran out of filament", "ar": "نفد الخيط في {machine}"],
        "mac.ntfy_section":  ["en": "Push to a phone (ntfy)", "ar": "إشعار إلى الهاتف (ntfy)"],
        "mac.ntfy_enable":   ["en": "Send printer alerts through ntfy", "ar": "أرسل تنبيهات الطابعات عبر ntfy"],
        "mac.ntfy_hint":     ["en": "No account or bot needed: install the ntfy app and subscribe to this topic. "
                                  + "Anyone who knows the topic can read it, so make one nobody would guess.",
                              "ar": "لا يلزم حساب أو بوت: ثبّت تطبيق ntfy واشترك في هذا الموضوع. "
                                  + "من يعرف اسم الموضوع يستطيع قراءته، فاجعله اسمًا لا يُخمَّن."],
        "mac.ntfy_topic":    ["en": "Topic", "ar": "الموضوع"],
        "mac.ntfy_make_topic": ["en": "Make one", "ar": "أنشئ واحدًا"],
        "mac.ntfy_server":   ["en": "Server", "ar": "الخادم"],
        "mac.ntfy_token":    ["en": "Access token (optional)", "ar": "رمز الوصول (اختياري)"],
        "mac.ntfy_runout":   ["en": "A spool ran out", "ar": "نفاد بكرة الخيط"],
        "mac.ntfy_test_title": ["en": "Khayt test", "ar": "اختبار خيط"],
        "mac.ntfy_test_body": ["en": "Printer alerts will arrive here.", "ar": "ستصل تنبيهات الطابعات هنا."],
        "mac.ntfy_test_sent": ["en": "Sent — check your phone.", "ar": "أُرسل — تحقّق من هاتفك."],
        "mac.mach_serial":   ["en": "Serial number", "ar": "الرقم التسلسلي"],
        "mac.mach_mainboard": ["en": "Mainboard ID", "ar": "معرّف اللوحة الأم"],
        "mac.mach_slug":     ["en": "Printer on the server", "ar": "الطابعة على الخادم"],
        "mac.mach_access_code": ["en": "Access code", "ar": "رمز الوصول"],
        "mac.mach_bambu_hint": ["en": "On the printer, turn on LAN-only Mode and Developer Mode; the access code is "
                                    + "on that same screen. Developer Mode is what opens the connection Khayt uses.",
                                "ar": "على الطابعة، فعّل وضع الشبكة المحلية فقط ووضع المطوّر؛ رمز الوصول في نفس "
                                    + "الشاشة. وضع المطوّر هو ما يفتح الاتصال الذي يستخدمه خيط."],
        "mac.spoolman_import": ["en": "Import from Spoolman", "ar": "استيراد من Spoolman"],
        "mac.spoolman_address": ["en": "Spoolman address", "ar": "عنوان Spoolman"],
        "mac.spoolman_hint": ["en": "Every spool Spoolman holds comes onto the shelf, with its vendor, colour, price "
                                   + "and what is left on it. Spools already brought across are skipped, and Spoolman "
                                   + "itself is only read, never changed.",
                              "ar": "تُضاف كل بكرة في Spoolman إلى الرف مع المورّد واللون والسعر والكمية المتبقية. "
                                   + "تُتخطّى البكرات المستوردة سابقًا، ويُقرأ Spoolman فقط دون أي تغيير عليه."],
        "mac.spoolman_go":   ["en": "Import", "ar": "استيراد"],
        "mac.spoolman_done": ["en": "{added} spools added. {already} were already on the shelf; {skipped} skipped.",
                              "ar": "أُضيفت {added} بكرة. {already} موجودة مسبقًا على الرف، وتُخطّيت {skipped}."],
        "mac.send_title":    ["en": "Send to printer", "ar": "إرسال إلى الطابعة"],
        "mac.send_printer":  ["en": "Printer", "ar": "الطابعة"],
        "mac.send_file":     ["en": "File", "ar": "الملف"],
        "mac.send_choose":   ["en": "Choose…", "ar": "اختيار…"],
        "mac.send_choose_hint": ["en": "Choose a sliced file — G-code, binary G-code, or a sliced 3MF project.",
                                 "ar": "اختر ملفًا مُقطّعًا — G-code أو G-code ثنائي أو مشروع 3MF مُقطّع."],
        "mac.send_no_files": ["en": "No sliced file beside this job's models", "ar": "لا يوجد ملف مُقطّع بجانب نماذج هذا الطلب"],
        "mac.send_no_printers": ["en": "No machine has a printer connection. Add one in the machine's settings.",
                                 "ar": "لا توجد آلة متصلة بطابعة. أضف الاتصال من إعدادات الآلة."],
        "mac.send_start":    ["en": "Start printing when it arrives", "ar": "ابدأ الطباعة عند وصول الملف"],
        "mac.send_and_start": ["en": "Send and print", "ar": "إرسال وطباعة"],
        "mac.send_only":     ["en": "Send", "ar": "إرسال"],
        "mac.send_not_sliced": ["en": "That is a model, not a sliced file. Slice it first, then send the result.",
                                "ar": "هذا نموذج وليس ملفًا مُقطّعًا. قطّعه أولًا ثم أرسل الناتج."],
        "mac.send_wrong_kind": ["en": "This printer cannot run a .{kind} file.",
                                "ar": "لا تستطيع هذه الطابعة تشغيل ملف ‎.{kind}‎."],
        "mac.send_unsupported": ["en": "Sending a file to this kind of printer is not supported from the Mac yet.",
                                 "ar": "إرسال ملف إلى هذا النوع من الطابعات غير مدعوم من الماك بعد."],
        "mac.send_started":  ["en": "Sent to {name}, and printing.", "ar": "أُرسل إلى {name} وبدأت الطباعة."],
        "mac.send_uploaded": ["en": "Sent to {name}. Start it from the printer when ready.",
                              "ar": "أُرسل إلى {name}. ابدأ الطباعة من الطابعة عند الاستعداد."],
        "mac.carriers_hint": ["en": "Optional — shipping works fully by hand. A carrier turned on here is offered "
                                    + "when a job is shipped, and with a webhook secret it updates a parcel's status "
                                    + "by itself. Labels are created from the Windows and Linux app.",
                              "ar": "اختياري — الشحن يعمل يدويًا بالكامل. شركة الشحن المفعّلة هنا تظهر عند شحن "
                                    + "الطلب، ومع سرّ الويب هوك تُحدّث حالة الشحنة تلقائيًا. "
                                    + "تُنشأ بطاقات الشحن من تطبيق ويندوز ولينكس."],
        "mac.ship_hint":     ["en": "Type the tracking number from the carrier's receipt. A carrier set up "
                                    + "with a webhook secret moves the parcel along by itself.",
                              "ar": "اكتب رقم التتبّع من إيصال شركة الشحن. شركة الشحن المُعدّة "
                                    + "بسرّ ويب هوك تُحدّث حالة الشحنة تلقائيًا."],
        "mac.storefront_hooks_title": ["en": "Orders from a storefront",
                                       "ar": "طلبات المتجر الإلكتروني"],
        "mac.storefront_hooks_hint": ["en": "Paste the secret from the storefront's dashboard, and give it "
                                          + "{url}salla or {url}zid. The storefront has to be able to reach "
                                          + "this Mac, so off the shop's own network it needs a tunnel.",
                                      "ar": "الصق السر من لوحة تحكم المتجر، وأعطه العنوان "
                                          + "{url}salla أو {url}zid. يجب أن يصل المتجر إلى هذا الماك، "
                                          + "فمن خارج شبكة المحل يلزمه نفق."],
        "mac.lan_open":      ["en": "Open on a phone on the same Wi‑Fi:",
                              "ar": "افتحه على هاتف متصل بنفس شبكة Wi‑Fi:"],
        "mac.lan_pin_short": ["en": "Use at least {n} characters. The PIN is the only lock on the shop\u{2019}s book over the network.", "ar": "استخدم {n} أحرف على الأقل. الرمز هو القفل الوحيد على دفتر المتجر عبر الشبكة."],
        "mac.lan_pin_missing": ["en": "Set an owner PIN — the queue shows customers' names.",
                                "ar": "عيّن رمز PIN للمالك — فالقائمة تعرض أسماء العملاء."],
        "mac.lan_failed":    ["en": "The server could not start: {error}",
                              "ar": "تعذّر تشغيل الخادم: {error}"],
        "mac.lan_restart_note": ["en": "Saved settings take effect at once: the server restarts on Save.",
                                 "ar": "تسري الإعدادات فور حفظها: يُعاد تشغيل الخادم عند الحفظ."],
        // The customer's quote link, from the job
        "mac.copy_quote_link": ["en": "Copy quote link", "ar": "نسخ رابط عرض السعر"],
        "mac.quote_link_copied": ["en": "Quote link copied. Send it to the customer on the same Wi‑Fi; they approve from it.",
                                  "ar": "نُسخ رابط عرض السعر. أرسله للعميل على نفس شبكة Wi‑Fi ليعتمده منه."],
        "mac.quote_link_no_server": ["en": "Switch the server on in Settings → Online first; the link points at this Mac.",
                                     "ar": "شغّل الخادم من الإعدادات ← الشبكة أولاً؛ فالرابط يشير إلى هذا الماك."],
        "mac.copy_tracking_link": ["en": "Copy tracking link", "ar": "نسخ رابط متابعة الطلب"],
        // Letting a customer price their own model.
        "mac.iq_no_preset":  ["en": "No printer preset yet, and a price cannot be worked out without one. Make one below.",
                              "ar": "لا يوجد إعداد طابعة بعد، ولا يمكن حساب السعر بدونه. أنشئ واحداً أدناه."],
        "mac.iq_new_preset": ["en": "New printer preset", "ar": "إعداد طابعة جديد"],
        // Pricing a customer's upload by slicing it.
        "mac.iq_slice":      ["en": "Price it by slicing it, not by its shape",
                              "ar": "احسب السعر بتقطيع الملف، لا من شكله"],
        "mac.iq_slice_hint": ["en": "Far more accurate — the shape cannot know about purge, which on a "
                                    + "four-colour print is most of the filament. The file is checked first "
                                    + "(that it is the kind of model it claims, names nothing outside its "
                                    + "own folder, and does not expand out of all proportion), then written "
                                    + "to a scratch folder and sliced, then deleted. That check cannot "
                                    + "vouch for what a slicer does with a well-formed file.",
                              "ar": "أدق بكثير — فالشكل لا يعرف كمية التنظيف بين الألوان، وهي معظم الخيط في "
                                    + "الطباعة رباعية الألوان. يُفحص الملف أولاً (أنه من النوع الذي يدّعيه، "
                                    + "ولا يسمّي شيئاً خارج مجلده، ولا يتمدد بصورة غير متناسبة)، ثم يُكتب في "
                                    + "مجلد مؤقت ويُقطّع ثم يُحذف. وهذا الفحص لا يضمن ما يفعله برنامج التقطيع "
                                    + "بملف سليم البنية."],
        "mac.iq_slice_with": ["en": "Slice with", "ar": "قطّع باستخدام"],
        "mac.iq_slice_default": ["en": "— The default slicer —", "ar": "— برنامج التقطيع الافتراضي —"],
        // What a part costs besides its filament.
        "mac.part_rates":    ["en": "Labour, power and wear",
                              "ar": "العمالة والكهرباء والاستهلاك"],
        "mac.part_no_rates": ["en": "A part here carries no labour, power or wear, so it is costed at its filament alone. Add it again with the figures above to price it in full.",
                              "ar": "أحد الأجزاء لا يحمل عمالة أو كهرباء أو استهلاكاً، فتُحتسب كلفته من الخيط وحده. أضفه من جديد بالأرقام أعلاه لتسعيره بالكامل."],
        "mac.tracking_link_copied": ["en": "Tracking link copied. The customer sees the stage, the shipping and, once done, a short survey.",
                                     "ar": "نُسخ رابط المتابعة. يرى العميل المرحلة والشحن، وبعد الإنجاز استبياناً قصيراً."],
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
        // A customer's price agreements, standing order and communications
        // log — the words on Khayt's own customer editor, borrowed so the two
        // editors call one thing by one name.
        "ce.price_list", "ce.price_list_empty", "ce.price_list_hint", "ce.pl_product",
        "ce.pl_price", "ce.pl_note", "ce.pl_autofill",
        "rec.enable", "rec.interval", "rec.interval.weekly", "rec.interval.biweekly",
        "rec.interval.monthly", "rec.interval.quarterly", "rec.next_due", "rec.paused",
        "rec.end_date", "rec.skip_next", "rec.hint", "rec.created",
        "ce.comm_log", "ce.comm_empty", "ce.comm_note_ph", "ce.comm_call", "ce.comm_email",
        "ce.comm_wa", "ce.comm_meeting", "ce.comm_note", "common.add",
        // The last word on a job's total — rounding and a typed price — in the
        // words the product editor already uses for the same two things.
        // The trends card on Reports, in the other app's own words for it.
        "an.cost_trends", "an.rev_per_hour", "an.cost_per_gram",
        // The cycle-time card, in the other app's words for its two charts.
        // The waste trend card, in the other app's word for the chart.
        "an.waste_trend",
        // The on-time delivery card, in the other app's words for its section.
        "an.sla_title", "an.sla_with_due", "an.sla_on_time", "an.sla_late", "an.sla_avg_delay",
        "an.sla_no_data",
        // The margin column on the P&L, in the other app's word for it.
        "an.margin_col",
        "an.cycle_time", "an.days", "an.lead_time", "an.lead_time_avg",
        "an.lead_time_fastest", "an.lead_time_slowest", "ord.project",
        "pe.round_to", "pe.round_off", "pe.round_nearest", "pe.round_up", "pe.round_down",
        "pe.price_override", "pe.price_override_ph", "pe.price_is_override",
        "pe.price_is_rounded", "pe.price_is_base",
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
        "an.pnl_empty", "an.pnl_expenses", "an.pnl_net", "an.pnl_orders", "an.pnl_period", "an.pnl_vat", "an.revenue",
        // Expenses and waste
        "common.cancel", "common.delete", "exp.add_btn", "exp.add_title", "exp.amount",
        "exp.budget_title", "exp.cat.electricity", "exp.cat.filament",
        "exp.cat.maintenance", "exp.cat.other", "exp.cat.shipping", "exp.cat.tools",
        "exp.category", "exp.date", "exp.no_budgets", "exp.note", "exp.note_ph",
        "exp.order_ref", "exp.order_ref_ph", "exp.over_budget", "exp.recurring",
        "exp.recurring_annually", "exp.recurring_monthly",
        "exp.recurring_quarterly", "exp.sum.expenses", "exp.summary", "exp.title",
        "mach.unassigned", "waste.add", "waste.date", "waste.deduct_inv",
        "waste.est_cost", "waste.failure_breakdown",
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
        // The LAN server's pane, in the Electron page's own words.
        "lan.enabled", "lan.port", "lan.pin", "lan.bind_lan", "lan.bind_lan_hint",
        "lan.loopback_warn", "lan.not_running", "common.secret_unchanged", "lan.same_wifi_hint",
        "icalDescription",
        // The seven cost rates, in the calculator's own words.
        "calc.labor.rate", "calc.labor.prep", "calc.labor.post", "calc.labor.failure",
        "calc.machine.wear", "calc.machine.power", "calc.machine.elec",
        "calc.machine.watts", "calc.machine.per_kwh",
        "calc.machine.preset_name_ph", "calc.machine.save_preset",
        "pe.delete_q", "pe.deleted",
        "lan.iq_enable", "lan.iq_enable_hint", "lan.iq_printer", "lan.iq_pick", "lan.iq_filament",
        "lan.iq_flat", "lan.iq_spool_cost", "lan.iq_spool_weight", "lan.iq_margin",
        "lan.iq_min", "lan.iq_waste", "lan.iq_limit", "lan.iq_note", "slicer.none",
    ]
}

extension Words {

    /// A date as THIS SHOP reads it, not as this Mac does.
    ///
    /// ── WHAT WENT WRONG ───────────────────────────────────────────────────
    ///
    /// `Date.formatted` takes the system locale when it is not given one, and
    /// the system locale is the Mac's, not the book's. So a shop running Khayt
    /// in Arabic — which is most of the reason this app is bilingual — read
    /// its front door as "Tuesday, 22 September 2026 at 2:45 PM" under an
    /// Arabic heading, and the money masthead said "SEPTEMBER · صافي".
    /// Twenty-two places did it.
    ///
    /// It survives every test: the strings are correct, they are simply in
    /// somebody else's language, and the one Mac this was built on keeps its
    /// system in English.
    ///
    /// ── AND WHY THIS IS NOT APPLIED TO EVERY DATE ─────────────────────────
    ///
    /// Only the ones a PERSON READS. The book's own dates — `2026-09-22`, the
    /// ISO stamps, the backup filenames — are data, and `Order.swift` already
    /// pins those to `en_US_POSIX` on purpose: a stored date that formats
    /// itself in Arabic-Indic digits is a stored date nothing can read back.
    /// Sweeping those too would corrupt the book, so the split is deliberate
    /// and `DatesReadInTheShopsLanguageTests` holds both halves of it.
    var locale: Locale { Locale(identifier: language) }

    /// The one way a displayed date is written. Takes any `Date.FormatStyle`,
    /// so `.dateTime.day().month(.abbreviated)` and
    /// `Date.FormatStyle(date: .abbreviated, time: .shortened)` both go
    /// through it — which is what lets a test find the ones that do not.
    func say(_ date: Date, _ style: Date.FormatStyle) -> String {
        date.formatted(style.locale(locale))
    }
}
