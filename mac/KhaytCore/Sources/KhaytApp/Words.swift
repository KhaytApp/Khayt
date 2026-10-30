import Foundation
import Observation
import SwiftUI
import KhaytCore
import KhaytWidgetData

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
    /// A count's numeral: grouped, and in the digits this Mac asked for
    /// (`Digits`) — it was a bare `NumberFormatter`, which took the Mac's
    /// locale and wrote "١٢ jobs" in the English app on an Arabic-Indic Mac.
    func numeral(_ n: Int) -> String {
        n.formatted(.number.locale(locale))
    }

    /// Keys whose `_one` form is the whole phrase with no number in it, in
    /// a way `واحد` cannot spot: «طُبع مرة» — "printed once" — says the count
    /// with «مرة» alone. Listed rather than guessed: a bare noun in `_one`
    /// still wants its numeral.
    nonisolated static let wholeSingulars: Set<String> = ["mac.printed_n"]

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
        // ── AND NONE, WHERE THE WORD HAS BEEN GIVEN IT ───────────────────
        //
        // The 11-and-over form a key falls back to reads badly for nothing:
        // "0 آلة", "منذ 0 يومًا". Arabic says none in words. Opt-in, like
        // the dual: only a key with a `_zero`.
        if language == "ar", n == 0, let none = Self.own[key + "_zero"]?["ar"], !none.isEmpty {
            return none
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
        // ── AND THREE TO TEN, WHERE THE WORD HAS BEEN GIVEN THEM ──────────
        //
        // Arabic counts 3–10 with the plural (٣ أيام) and 11–99 with the
        // accusative singular (٣٠ يومًا). A key written in the second shape
        // read "5 يومًا". Opt-in like the dual: only a key with a `_few`.
        let tail = n % 100
        if language == "ar", (3...10).contains(tail), let few = Self.own[key + "_few"]?["ar"], !few.isEmpty {
            let number = numeral(n)
            return few.replacingOccurrences(of: "{n}", with: number)
        }
        let said = callIt(n == 1 ? key + "_one" : key)
        let number = numeral(n)
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
        //
        // A literal (UTF-16) search, not `contains`: in "يومًا واحدًا" the
        // tanween joins the last letter into one grapheme, which hides واحد.
        if n == 1, said.range(of: "واحد", options: .literal) != nil { return said }
        // …or says "once" in a word of its own (`wholeSingulars`): «طُبع مرة»
        // is "printed once", and a numeral before it read "1 printed once".
        if n == 1, Self.wholeSingulars.contains(key) { return said }
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

    /// One of this app's own sentences in English, with no `Words` to hand —
    /// for a `description` that lands in a log, or a test. What a shop reads
    /// goes through `callIt`, in the shop's language; this is the same entry's
    /// English, so the two cannot drift into two spellings.
    nonisolated static func english(_ key: String, _ params: [String: JSONValue] = [:]) -> String {
        var out = own[key]?["en"] ?? key
        for (name, value) in params {
            out = out.replacingOccurrences(of: "{\(name)}", with: plain(value))
        }
        return out
    }

    /// A parameter as the renderer's `String(vars[k])` would render it —
    /// including a whole number staying whole, which `"\(Double)"` does not do.
    nonisolated static func plain(_ value: JSONValue) -> String {
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
        // A finished job moved back gives its completion's filament back
        // (`KhaytOrderDeduction.returnForOrder`). Said, because a spool that
        // grows by itself is a number nobody trusts.
        case "filament_returned":      key = "mac.filament_returned"
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
        // The shop's language's own list: "A, B and C" in English (the
        // Arabic comma was being used for both), "أ وب وج" in Arabic.
        let list = named.formatted(.list(type: .and).locale(locale))
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
            .merging(ReviewWords.alpha58) { mine, _ in mine }
            .merging(TelemetryWords.table) { mine, _ in mine }
            .merging(WebSaveWords.table) { mine, _ in mine }
            .merging(WebAttachWords.table) { mine, _ in mine }
            .merging(BrowserHostWords.table) { mine, _ in mine }

    private nonisolated static let base: [String: [String: String]] = [
        // ── Library grid redesign ─────────────────────────────────────────
        //
        // Tile size, grid or list, the facts line on a tile, the three new
        // orders, the list's columns, the one Edit menu and the empty states
        // (`LibraryDisplay.swift`, `LibraryList.swift`, `EditSelectionMenu`).
        // Numerals in the Arabic are isolated (U+2068/U+2069) so a figure
        // never drags the line's direction with it.
        "mac.lg_size_small": ["en": "Small tiles", "ar": "مربعات صغيرة"],
        "mac.lg_size_medium": ["en": "Medium tiles", "ar": "مربعات متوسطة"],
        "mac.lg_size_large": ["en": "Large tiles", "ar": "مربعات كبيرة"],
        "mac.lg_tile_size": ["en": "Tile size", "ar": "حجم المربعات"],
        "mac.lg_tile_size_help": ["en": "Tile size — Small, Medium or Large (⌘− and ⌘+)",
                                  "ar": "حجم المربعات — صغير أو متوسط أو كبير (⌘− و⌘+)"],
        "mac.lg_view": ["en": "View", "ar": "العرض"],
        "mac.lg_view_grid": ["en": "As Grid", "ar": "كشبكة"],
        "mac.lg_view_list": ["en": "As List", "ar": "كقائمة"],
        "mac.lg_larger": ["en": "Larger Tiles", "ar": "مربعات أكبر"],
        "mac.lg_smaller": ["en": "Smaller Tiles", "ar": "مربعات أصغر"],
        "mac.lg_default_size": ["en": "Default Tile Size", "ar": "حجم المربعات الافتراضي"],
        "mac.lg_sort_time": ["en": "Print time", "ar": "مدة الطباعة"],
        "mac.lg_sort_grams": ["en": "Filament weight", "ar": "وزن الخيط"],
        "mac.lg_sort_price": ["en": "Price", "ar": "السعر"],
        "mac.lg_col_folder": ["en": "Folder", "ar": "المجلد"],
        "mac.lg_col_material": ["en": "Material", "ar": "الخامة"],
        "mac.lg_col_grams": ["en": "Weight", "ar": "الوزن"],
        "mac.lg_col_storage": ["en": "Storage", "ar": "التخزين"],
        "mac.lg_filter_empty": ["en": "{name}: nothing in this library to choose from yet",
                                "ar": "{name}: لا شيء في هذه المكتبة للاختيار منه بعد"],
        "mac.lg_edit": ["en": "Edit", "ar": "تعديل"],
        "mac.lg_edit_n": ["en": "Edit {what}", "ar": "تعديل {what}"],
        "mac.lg_edit_help": ["en": "Change the selected models: their group, category, tags and where they came from",
                             "ar": "غيّر النماذج المحددة: مجموعتها وتصنيفها ووسومها ومصدرها"],
        "mac.lg_none_filtered": ["en": "No models match these filters", "ar": "لا نماذج تطابق هذه المرشحات"],
        "mac.lg_none_filtered_hint": ["en": "Clear the filters to see the whole library again.",
                                      "ar": "امسح المرشحات لترى المكتبة كاملة مرة أخرى."],
        "mac.lg_empty_hint": ["en": "Import a folder of models with the button below, or drop files anywhere on this screen.",
                              "ar": "استورد مجلدًا من النماذج بالزر أدناه، أو أفلت الملفات في أي مكان على هذه الشاشة."],
        "mac.lg_more_filters": ["en": "More", "ar": "المزيد"],
        // ── end of Library grid redesign ──────────────────────────────────

        // ── Library smart folders ─────────────────────────────────────────
        //
        // Saved searches in the sidebar, the five built in, Save Search…, the
        // Ranges popover and the axes they added (`Shop+LibraryQuery.swift`,
        // `LibrarySmartFolders.swift`). Numerals and placeholders in the
        // Arabic are isolated (U+2068/U+2069) so a figure or a shop's own
        // name never drags the line's direction with it.
        "mac.ls_ready": ["en": "Ready to print", "ar": "جاهز للطباعة"],
        "mac.ls_no_figures": ["en": "No print figures", "ar": "بلا أرقام طباعة"],
        "mac.ls_in_catalogue": ["en": "Sells in catalogue", "ar": "يُباع في الكتالوج"],
        "mac.ls_ready_any": ["en": "Any printer", "ar": "أي طابعة"],
        "mac.ls_builtin_help": ["en": "Built in: always here, worked out from the library",
                                "ar": "مدمج: موجود دائمًا ويُحسب من المكتبة"],
        "mac.ls_save": ["en": "Save Search…", "ar": "حفظ البحث…"],
        "mac.ls_save_help": ["en": "Keep this search in the sidebar, under Library",
                             "ar": "احتفظ بهذا البحث في الشريط الجانبي، تحت المكتبة"],
        "mac.ls_update": ["en": "Update Search", "ar": "تحديث البحث"],
        "mac.ls_update_help": ["en": "Keep the search on screen as “{name}”",
                               "ar": "احفظ البحث المعروض باسم «\u{2068}{name}\u{2069}»"],
        "mac.ls_save_menu": ["en": "Save", "ar": "حفظ"],
        "mac.ls_name": ["en": "Name", "ar": "الاسم"],
        "mac.ls_name_prompt": ["en": "Ready for the market", "ar": "جاهز للسوق"],
        "mac.ls_save_button": ["en": "Save", "ar": "حفظ"],
        "mac.ls_cancel": ["en": "Cancel", "ar": "إلغاء"],
        "mac.ls_replaces": ["en": "Replaces the saved search with this name.",
                            "ar": "يستبدل البحث المحفوظ الذي يحمل هذا الاسم."],
        "mac.ls_rename": ["en": "Rename…", "ar": "إعادة تسمية…"],
        "mac.ls_rename_taken": ["en": "Another saved search has this name.",
                                "ar": "بحث محفوظ آخر يحمل هذا الاسم."],
        "mac.ls_edit": ["en": "Edit Search", "ar": "تعديل البحث"],
        "mac.ls_delete_title": ["en": "Delete the saved search “{name}”?",
                                "ar": "حذف البحث المحفوظ «\u{2068}{name}\u{2069}»؟"],
        "mac.ls_delete_note": ["en": "Only the search goes. The models stay in the library.",
                               "ar": "يُحذف البحث فقط، وتبقى النماذج في المكتبة."],
        "mac.ls_duplicate": ["en": "Duplicate", "ar": "تكرار"],
        "mac.ls_delete": ["en": "Delete", "ar": "حذف"],
        "mac.ls_copy_name": ["en": "{name} {n}", "ar": "\u{2068}{name}\u{2069} \u{2068}{n}\u{2069}"],
        "mac.ls_sample": ["en": "The sample shop cannot keep a saved search.",
                          "ar": "لا يحفظ المتجر التجريبي أي بحث."],
        "mac.ls_ranges": ["en": "Ranges", "ar": "النطاقات"],
        "mac.ls_ranges_on": ["en": "Ranges: {n}", "ar": "النطاقات: \u{2068}{n}\u{2069}"],
        "mac.ls_ranges_help": ["en": "Narrow by print time, filament, price, times printed and date added",
                               "ar": "ضيّق حسب مدة الطباعة والخيط والسعر ومرات الطباعة وتاريخ الإضافة"],
        "mac.ls_range_time": ["en": "Print time (h)", "ar": "مدة الطباعة (س)"],
        "mac.ls_range_grams": ["en": "Filament (g)", "ar": "الخيط (غ)"],
        "mac.ls_range_price": ["en": "Price ({currency})", "ar": "السعر (\u{2068}{currency}\u{2069})"],
        "mac.ls_range_printed": ["en": "Times printed", "ar": "مرات الطباعة"],
        "mac.ls_range_added": ["en": "Date added", "ar": "تاريخ الإضافة"],
        "mac.ls_min": ["en": "Min", "ar": "الأدنى"],
        "mac.ls_max": ["en": "Max", "ar": "الأعلى"],
        "mac.ls_any_time": ["en": "Any time", "ar": "أي وقت"],
        "mac.ls_last_7": ["en": "Last 7 days", "ar": "آخر \u{2068}7\u{2069} أيام"],
        "mac.ls_last_30": ["en": "Last 30 days", "ar": "آخر \u{2068}30\u{2069} يومًا"],
        "mac.ls_last_90": ["en": "Last 90 days", "ar": "آخر \u{2068}90\u{2069} يومًا"],
        "mac.ls_between": ["en": "Between dates", "ar": "بين تاريخين"],
        "mac.ls_from": ["en": "From", "ar": "من"],
        "mac.ls_to": ["en": "To", "ar": "إلى"],
        "mac.ls_unknown_rule": ["en": "A model with no figure never matches a range.",
                                "ar": "النموذج الذي لا رقم له لا يطابق أي نطاق."],
        "mac.ls_unknown_n": ["en": "{n} with no figure left out", "ar": "لم يُحتسب \u{2068}{n}\u{2069} بلا رقم"],
        "mac.ls_unknown_date_n": ["en": "{n} with no date added left out", "ar": "لم يُحتسب \u{2068}{n}\u{2069} بلا تاريخ إضافة"],
        "mac.ls_clear_ranges": ["en": "Clear Ranges", "ar": "مسح النطاقات"],
        // ── end of Library smart folders ──────────────────────────────────
        // ── Library health ────────────────────────────────────────────────
        //
        // The Library Health page (`LibraryHealthView`, `Shop+LibraryHealth`),
        // its Show-menu filter, and the Print next note and badge
        // (`PrintNextRow`, the tile). Placeholders in the Arabic are isolated
        // (U+2068/U+2069) so a model's name or a figure never turns the line.
        "mac.lh_title": ["en": "Library Health", "ar": "صحة المكتبة"],
        "mac.lh_intro": ["en": "What needs a look in your library, a group at a time. Nothing changes until you press a button, and nothing is ever merged.",
                         "ar": "ما يحتاج إلى نظرة في مكتبتك، مجموعةً مجموعة. لا يتغيّر شيء حتى تضغط زرًّا، ولا يُدمج شيء أبدًا."],
        "mac.lh_checking": ["en": "Checking the library\u{2026}", "ar": "جارٍ فحص المكتبة\u{2026}"],
        "mac.lh_check_again": ["en": "Check Again", "ar": "افحص مجددًا"],
        "mac.lh_back": ["en": "Back to Library", "ar": "عودة إلى المكتبة"],
        "mac.lh_all_good": ["en": "Nothing needs a look. Every model is here or online, measured, filed and one of a kind.",
                            "ar": "لا شيء يحتاج إلى نظرة. كل النماذج هنا أو على الإنترنت، مقيسة ومصنّفة وغير مكررة."],
        "mac.lh_show": ["en": "Show in Library", "ar": "اعرضها في المكتبة"],
        "mac.lh_show_select": ["en": "Show and Select", "ar": "اعرضها وحدّدها"],
        "mac.lh_side_by_side": ["en": "Show Side by Side", "ar": "اعرضها جنبًا إلى جنب"],
        "mac.lh_remove": ["en": "Remove from Library", "ar": "أزلها من المكتبة"],
        "mac.lh_measure": ["en": "Measure", "ar": "قِسها"],
        "mac.lh_catalogue": ["en": "Open the Catalogue", "ar": "افتح الكتالوج"],
        "mac.lh_open": ["en": "Open", "ar": "افتح"],
        "mac.lh_fewer": ["en": "Show fewer", "ar": "اعرض أقل"],
        "mac.lh_locate": ["en": "Locate", "ar": "حدّد مكانه"],
        "mac.lh_locate_prompt": ["en": "Where is the file for {name} now?",
                                 "ar": "أين ملف \u{2068}{name}\u{2069} الآن؟"],
        "mac.lh_locate_wrong": ["en": "That is a different file from the one {name} was made from, so it was not taken. Choose the original file, or remove the model.",
                                "ar": "هذا ملف مختلف عن الملف الذي صُنع منه \u{2068}{name}\u{2069}، فلم يُؤخذ. اختر الملف الأصلي أو أزل النموذج."],
        "mac.lh_locate_failed": ["en": "The file could not be copied back into the library folder.",
                                 "ar": "تعذّر نسخ الملف إلى مجلد المكتبة."],
        "mac.lh_locate_done": ["en": "Found the file for {name}.", "ar": "وُجد ملف \u{2068}{name}\u{2069}."],
        "mac.lh_mirror_note": ["en": "A mirrored part — a left and a right — has the same shape figures as its twin, so these can be two different parts. Look before removing one.",
                               "ar": "الجزء المعكوس — أيسر وأيمن — له أرقام الشكل نفسها التي لتوأمه، فقد يكون هذان جزأين مختلفين. انظر قبل أن تزيل أحدهما."],
        // ── Library stage 3b: stacks, Find Similar, the viewer ──────────────
        "mac.stk_sec": ["en": "Variants", "ar": "المتغيّرات"],
        "mac.stk_n_variants": ["en": "{n} variants", "ar": "{n} متغيّرًا"],
        "mac.stk_n_variants_one": ["en": "{n} variant", "ar": "متغيّر واحد"],
        "mac.stk_n_variants_two": ["en": "{n} variants", "ar": "متغيّران"],
        "mac.stk_n_variants_few": ["en": "{n} variants", "ar": "{n} متغيّرات"],
        "mac.stk_n_variants_zero": ["en": "No variants", "ar": "لا متغيّرات"],
        "mac.stk_badge_of": ["en": "{n} of {total}", "ar": "{n} من {total}"],
        "mac.stk_badge_open": ["en": "A stack of {variants} — show them", "ar": "رزمة فيها {variants} — اعرضها"],
        "mac.stk_badge_close": ["en": "A stack of {variants} — hide them", "ar": "رزمة فيها {variants} — أخفِها"],
        "mac.stk_stack": ["en": "Stack", "ar": "ضمّ في رزمة"],
        "mac.stk_stack_n": ["en": "Stack {n} Models", "ar": "ضمّ {n} نموذجًا في رزمة"],
        "mac.stk_stack_n_one": ["en": "Stack {n} Model", "ar": "ضمّ نموذج واحد في رزمة"],
        "mac.stk_stack_n_two": ["en": "Stack {n} Models", "ar": "ضمّ النموذجين في رزمة"],
        "mac.stk_stack_n_few": ["en": "Stack {n} Models", "ar": "ضمّ {n} نماذج في رزمة"],
        "mac.stk_unstack": ["en": "Unstack", "ar": "فكّ الرزمة"],
        "mac.stk_remove": ["en": "Remove from Stack", "ar": "إخراج من الرزمة"],
        "mac.stk_make_cover": ["en": "Show on Top of Stack", "ar": "جعله واجهة الرزمة"],
        "mac.stk_cover": ["en": "on top of the stack", "ar": "واجهة الرزمة"],
        "mac.stk_show": ["en": "Show Variants", "ar": "عرض المتغيّرات"],
        "mac.stk_hide": ["en": "Hide Variants", "ar": "إخفاء المتغيّرات"],
        "mac.stk_accept": ["en": "Stack with {variants}", "ar": "ضمّه في رزمة مع {variants}"],
        "mac.stk_why_file": ["en": "the same file", "ar": "الملف نفسه"],
        "mac.stk_why_name": ["en": "the same name in the same group", "ar": "الاسم نفسه في المجموعة نفسها"],
        "mac.stk_why_shape": ["en": "the same size and shape", "ar": "الحجم والشكل نفساهما"],
        "mac.stk_in_stack": ["en": "In a stack of {variants}.", "ar": "في رزمة من {variants}."],
        // Counted (`Words.counting`): after أنّ the noun is accusative, and
        // the predicate agrees with one, two, three-to-ten and eleven-on.
        "mac.stk_suggest": ["en": "{n} variants look like versions of this model ({why}).",
                            "ar": "يبدو أنّ {n} متغيّرًا نسخٌ من هذا النموذج ({why})."],
        "mac.stk_suggest_one": ["en": "{n} variant looks like a version of this model ({why}).",
                                "ar": "يبدو أنّ متغيّرًا واحدًا نسخةٌ من هذا النموذج ({why})."],
        "mac.stk_suggest_two": ["en": "{n} variants look like versions of this model ({why}).",
                                "ar": "يبدو أنّ متغيّرَين نسختان من هذا النموذج ({why})."],
        "mac.stk_suggest_few": ["en": "{n} variants look like versions of this model ({why}).",
                                "ar": "يبدو أنّ {n} متغيّرات نسخٌ من هذا النموذج ({why})."],
        "mac.stk_none": ["en": "No other model looks like a variant of this one.",
                         "ar": "لا يبدو أي نموذج آخر متغيّرًا من هذا النموذج."],
        "mac.stk_more": ["en": "and {n} more", "ar": "و{n} غيرها"],
        "mac.sim_find": ["en": "Find Similar", "ar": "البحث عن المشابه"],
        "mac.sim_none": ["en": "Nothing in the library is like {name}.",
                         "ar": "لا شيء في المكتبة يشبه \u{2068}{name}\u{2069}."],
        "mac.sim_chip": ["en": "Like {name}", "ar": "يشبه \u{2068}{name}\u{2069}"],
        "mac.sim_help": ["en": "The same shape first, then models near it in size, volume and detail, and those in the same group or with the same tags.",
                         "ar": "الشكل نفسه أولًا، ثم النماذج القريبة منه في المقاسات والحجم والتفاصيل، ثم ما في المجموعة نفسها أو يحمل الوسوم نفسها."],
        "mac.mv_sec": ["en": "Views", "ar": "المناظر"],
        "mac.mv_side_label": ["en": "Seen from", "ar": "منظور من"],
        "mac.mv_help": ["en": "Iso, front, top or side — ⌥⌘1 to ⌥⌘4.",
                        "ar": "مائل أو أمامي أو علوي أو جانبي — ⌥⌘1 إلى ⌥⌘4."],
        "mac.mv_plate": ["en": "Plate", "ar": "اللوح"],
        "mac.mv_said": ["en": "{side} view of the model", "ar": "منظر {side} للنموذج"],
        "mac.mv_not_here": ["en": "The file is not on this Mac, so it cannot be drawn.",
                            "ar": "الملف ليس على هذا الماك، فلا يمكن رسمه."],
        "mac.mv_failed": ["en": "This file has no shape that could be drawn.",
                          "ar": "لا يحمل هذا الملف شكلًا يمكن رسمه."],
        "mac.mv_menu": ["en": "Model View", "ar": "منظر النموذج"],
        "mac.mv_iso": ["en": "Iso", "ar": "مائل"],
        "mac.mv_front": ["en": "Front", "ar": "أمامي"],
        "mac.mv_top": ["en": "Top", "ar": "علوي"],
        "mac.mv_side": ["en": "Side", "ar": "جانبي"],
        // ── Library stage 3b: model bundles ─────────────────────────────────
        "mac.mb_export": ["en": "Export Model Bundle", "ar": "تصدير حزمة النموذج"],
        "mac.mb_import_menu": ["en": "Import Model Bundle", "ar": "استيراد حزمة نموذج"],
        "mac.mb_not_here": ["en": "The file for {name} is not on this Mac, so it cannot be packed.",
                            "ar": "ملف \u{2068}{name}\u{2069} ليس على هذا الماك، فلا يمكن تحزيمه."],
        "mac.mb_export_says": ["en": "A model bundle holds the model file, its pictures, its print setups and what the library knows about it — never a customer's name or a licence code. Its group and the files beside it go only if you tick them.",
                               "ar": "تحوي حزمة النموذج ملف النموذج وصوره وإعدادات طباعته وما تعرفه المكتبة عنه — ولا تحوي أبدًا اسم عميل أو رمز ترخيص. لا تُضاف مجموعته ولا الملفات المجاورة له إلا إذا حدّدتها."],
        "mac.mb_include_price": ["en": "Include price", "ar": "تضمين السعر"],
        "mac.mb_include_group": ["en": "Include its group ({group})",
                                 "ar": "تضمين مجموعته (\u{2068}{group}\u{2069})"],
        "mac.mb_papers": ["en": "Files beside the model — tick only those that name no customer:",
                          "ar": "الملفات المجاورة للنموذج — حدّد فقط ما لا يحمل اسم عميل:"],
        "mac.mb_packing": ["en": "Packing {name} — {done} of {total}",
                           "ar": "يجري تجهيز \u{2068}{name}\u{2069} — {done} من {total}"],
        "mac.mb_bundle_figures": ["en": "The bundle's estimate (another shop's slice): {figures}",
                                  "ar": "تقدير الحزمة (من تقطيع ورشة أخرى): {figures}"],
        "mac.mb_exported": ["en": "Saved {name}.", "ar": "حُفظ \u{2068}{name}\u{2069}."],
        "mac.mb_too_big": ["en": "The bundle is too large: one file may be 512 MB and the whole bundle 1 GB.",
                           "ar": "الحزمة كبيرة جدًا: الملف الواحد حتى 512 ميغابايت والحزمة كلها حتى 1 غيغابايت."],
        "mac.mb_export_failed": ["en": "The bundle could not be saved: {why}", "ar": "تعذّر حفظ الحزمة: {why}"],
        "mac.mb_not_bundle": ["en": "That file is not a Khayt model bundle.", "ar": "هذا الملف ليس حزمة نموذج من خيط."],
        "mac.mb_bad_name": ["en": "The bundle names a file Khayt will not unpack: {name}",
                            "ar": "تسمّي الحزمة ملفًا لن يفكّه خيط: \u{2068}{name}\u{2069}"],
        "mac.mb_encrypted": ["en": "{name} in the bundle is encrypted.", "ar": "\u{2068}{name}\u{2069} في الحزمة مشفّر."],
        "mac.mb_no_model": ["en": "The bundle has no model file in it.", "ar": "لا تحوي الحزمة ملف نموذج."],
        "mac.mb_import_says": ["en": "Choose a model bundle to add its model to the library.",
                               "ar": "اختر حزمة نموذج لإضافة نموذجها إلى المكتبة."],
        "mac.mb_import": ["en": "Fill from Bundle", "ar": "تعبئة من الحزمة"],
        "mac.mb_imported": ["en": "Added {name} from the bundle.", "ar": "أُضيف \u{2068}{name}\u{2069} من الحزمة."],
        "mac.lh_plan_deleted": ["en": "Deleted from the vault by the plan limit", "ar": "حذفتها الخزنة بسبب حد الخطة"],
        "mac.lh_plan_deleted_says": ["en": "This Mac held only the vault’s copy of these, and the vault deleted them while it held more than the plan allows. Another Mac may still have the files: look there before you remove them, because Remove takes them out of the library on every Mac.",
          "ar": "كان هذا الماك يحتفظ بنسخة الخزنة فقط من هذه النماذج، وحذفتها الخزنة حين تجاوزت ما تسمح به الخطة. قد تكون الملفات على ماك آخر، فابحث عنها هناك قبل إزالتها، لأن الإزالة تحذفها من المكتبة على كل أجهزة ماك."],
        "mac.lh_vault_gone": ["en": "Not on this Mac and gone from the vault", "ar": "ليست على هذا الماك وحُذفت من الخزنة"],
        "mac.lh_vault_gone_says": ["en": "This Mac held only the vault’s copy of these, and the vault no longer has it. Another Mac may still have the files: look there before you remove them, because Remove takes them out of the library on every Mac.",
          "ar": "كان هذا الماك يحتفظ بنسخة الخزنة فقط من هذه النماذج، ولم تعد في الخزنة. قد تكون الملفات على ماك آخر، فابحث عنها هناك قبل إزالتها، لأن الإزالة تحذفها من المكتبة على كل أجهزة ماك."],
        "mac.lh_missing": ["en": "Missing from this Mac", "ar": "مفقودة من هذا الماك"],
        "mac.lh_missing_says": ["en": "The library lists these, but their files are not on this Mac and not online. Locate a file you moved, or remove the ones that are gone.",
                                "ar": "المكتبة تذكرها، لكن ملفاتها ليست على هذا الماك ولا على الإنترنت. حدّد مكان ملف نقلته، أو أزل ما فُقد منها."],
        "mac.lh_unreachable": ["en": "On a drive that is not connected", "ar": "على قرص غير موصول"],
        "mac.lh_unreachable_says": ["en": "The drive, network share or folder these files are on is not connected to this Mac right now, so they cannot be checked. Nothing is wrong with them: connect it and they are checked again.",
                                    "ar": "القرص أو مجلد الشبكة أو المجلد الذي فيه هذه الملفات غير موصول بهذا الماك الآن، فلا يمكن فحصها. لا خلل فيها: صِله وتُفحص من جديد."],
        "mac.lh_online": ["en": "Online, never measured", "ar": "على الإنترنت ولم تُقَس"],
        "mac.lh_online_bring": ["en": "These are in your online storage rather than a linked folder: bring one back (right-click it in the Library) to measure it.",
                                "ar": "هذه في تخزينك على الإنترنت لا في مجلد مرتبط: أعِد أحدها (انقر عليه بالزر الأيمن في المكتبة) لتقيسه."],
        "mac.lh_online_says": ["en": "Kept online and never measured, so they have no time or weight and cannot be priced. Measuring downloads each one and hands it back.",
                               "ar": "محفوظة على الإنترنت ولم تُقَس قط، فلا مدة لها ولا وزن ولا يمكن تسعيرها. القياس يُنزّل كلًّا منها ثم يعيده."],
        "mac.lh_no_figures": ["en": "No time or weight", "ar": "بلا مدة أو وزن"],
        "mac.lh_no_figures_says": ["en": "On this Mac, but missing a print time or a weight — not from a slicer and not from a measured shape. Measure reads each file again.",
                                   "ar": "على هذا الماك، لكن ينقصها مدة الطباعة أو الوزن — لا من برنامج التقطيع ولا من شكل مقيس. «قِسها» تقرأ كل ملف من جديد."],
        "mac.lh_same_file": ["en": "The same file twice", "ar": "الملف نفسه مرتين"],
        "mac.lh_same_file_says": ["en": "These are the very same bytes, added more than once. Nothing is merged: look at each copy and remove the ones you do not need.",
                                  "ar": "هذه البيانات نفسها تمامًا، أُضيفت أكثر من مرة. لا يُدمج شيء: انظر إلى كل نسخة وأزل ما لا تحتاج إليه."],
        "mac.lh_looks_same": ["en": "Look the same", "ar": "تبدو متشابهة"],
        "mac.lh_looks_same_says": ["en": "Different files with the same shape and the same size — often one model saved twice from different slicers.",
                                   "ar": "ملفات مختلفة بالشكل نفسه والحجم نفسه — غالبًا نموذج واحد حُفظ مرتين من برنامجَي تقطيع مختلفين."],
        "mac.lh_too_big": ["en": "Too big for every printer", "ar": "أكبر من كل طابعاتك"],
        "mac.lh_too_big_says": ["en": "Bigger than the bed of every 3D printer you have — usually a file at the wrong scale. Lasers and UV printers are not counted.",
                                "ar": "أكبر من سرير كل طابعة ثلاثية الأبعاد لديك — غالبًا ملف بمقياس خاطئ. لا تُحسب أجهزة الليزر ولا طابعات الأشعة فوق البنفسجية."],
        "mac.lh_unorganised": ["en": "No tag or category", "ar": "بلا وسم أو تصنيف"],
        "mac.lh_unorganised_says": ["en": "Nothing a filter can find these by. Select them all and add a tag or a category in one go.",
                                    "ar": "لا شيء يجدها به المرشّح. حدّدها كلها وأضف وسمًا أو تصنيفًا دفعة واحدة."],
        "mac.lh_orphans": ["en": "Products without their model", "ar": "منتجات بلا نموذجها"],
        "mac.lh_orphans_says": ["en": "These catalogue products print from a model that is no longer in the library. Open each one to choose another file or take the part out.",
                                "ar": "هذه المنتجات في الكتالوج تُطبع من نموذج لم يعد في المكتبة. افتح كلًّا منها لتختار ملفًا آخر أو تحذف الجزء."],
        "mac.print_next_for": ["en": "For", "ar": "لأجل"],
        "mac.print_next_for_hint": ["en": "Who or what it is for (optional)", "ar": "لمن أو لماذا (اختياري)"],
        "mac.print_next_for_said": ["en": "Print next: for {name}", "ar": "التالي للطباعة: لأجل \u{2068}{name}\u{2069}"],
        "mac.print_next_help": ["en": "Mark it to print (⌘B). Starting a job from it takes it off the list.",
                                "ar": "علّمه للطباعة (⌘B). بدء مهمة منه يزيله من القائمة."],
        // ── end of Library health ─────────────────────────────────────────

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
        "mac.band_free_across": ["en": "{hours} free across {machines}",
                                 "ar": "{hours} متفرغة على {machines}"],
        "mac.band_machines": ["en": "{n} machines", "ar": "{n} طابعة"],
        "mac.band_machines_one": ["en": "{n} machine", "ar": "طابعة واحدة"],
        "mac.band_machines_two": ["en": "2 machines", "ar": "طابعتين"],
        "mac.band_machines_few": ["en": "{n} machines", "ar": "{n} طابعات"],
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
        // The customer's cloud link (PortalOwner.swift).
        "mac.portal_publish": ["en": "Publish customer link", "ar": "نشر رابط العميل"],
        "mac.portal_publish_quote": ["en": "Publish quote link\u{2026}", "ar": "نشر رابط عرض السعر\u{2026}"],
        "mac.portal_copy": ["en": "Copy customer link", "ar": "نسخ رابط العميل"],
        "mac.portal_published": ["en": "The customer's link is live.", "ar": "رابط العميل منشور."],
        "mac.portal_published_unlinked": ["en": "The link is live, but the customer's email was not linked today — the shop has reached its daily limit of new customer emails. The link still works.",
                                          "ar": "الرابط منشور، لكن لم يُربط بريد العميل اليوم — بلغ المتجر حدّه اليومي من عناوين العملاء الجديدة. الرابط يعمل."],
        "mac.portal_published_copied": ["en": "Published, and the link is copied.", "ar": "نُشر الرابط ونُسخ."],
        "mac.portal_viewer": ["en": "Your role on Khayt Cloud is view-only, so this cannot be changed from here.",
                              "ar": "دورك في خيط السحابي للعرض فقط، فلا يمكن تغيير هذا من هنا."],
        "mac.portal_other_shop": ["en": "That link belongs to another shop.", "ar": "هذا الرابط يخص متجرًا آخر."],
        "mac.portal_rate": ["en": "Khayt Cloud is busy. Try again in a minute.", "ar": "خيط السحابي مشغول. أعد المحاولة بعد دقيقة."],
        "mac.portal_not_here": ["en": "This job's link is not on this Khayt Cloud server, or the server is older than this Khayt.",
                                "ar": "رابط هذا العمل غير موجود على خادم خيط السحابي هذا، أو أن الخادم أقدم من هذا الإصدار."],
        "mac.move_gone":     ["en": "That job is no longer in the book.",
                              "ar": "لم يعد هذا العمل في الدفتر."],
        "mac.filament_returned": ["en": "Put {weight}g back on the shelf — the job is no longer finished, so its filament is not used yet.",
                                  "ar": "أُعيد {weight} غ إلى المخزون — لم يعد العمل منتهيًا، فخيوطه لم تُستهلك بعد."],
        "mac.undo_partial":  ["en": "Some of this changed since — not undone: {fields}",
                              "ar": "تغيّر بعض هذا منذ ذلك الحين — لم يُتراجع عنه: {fields}"],
        "mac.record_gone":   ["en": "Not saved: this was deleted on another device while you were editing it.",
                              "ar": "لم يُحفظ: حُذف هذا من جهاز آخر أثناء تعديلك له."],
        "mac.move_sample":   ["en": "The sample shop cannot be changed.",
                              "ar": "لا يمكن تغيير المحل التجريبي."],
        "mac.remeasured":    ["en": "{n} models were measured again — their sizes were wrong.",
                              "ar": "تم قياس {n} من النماذج من جديد — كانت أبعادها خاطئة."],
        // A supplier's receipt, read off its ZATCA QR (ReceiptQr.swift).
        "mac.receipt_add":   ["en": "Add from receipt", "ar": "إضافة من إيصال"],
        "mac.receipt_title": ["en": "Add an expense from a receipt", "ar": "إضافة مصروف من إيصال"],
        "mac.receipt_hint":  ["en": "Open a photo, screenshot or PDF of a Saudi tax invoice and Khayt reads the QR code on it — the seller, the total and the VAT. You check it and choose the category before it is saved.",
                              "ar": "افتح صورة أو لقطة شاشة أو ملف PDF لفاتورة ضريبية سعودية وسيقرأ خيط رمز QR الذي عليها — البائع والإجمالي وضريبة القيمة المضافة. تراجعها وتختار الفئة قبل حفظها."],
        "mac.receipt_open":  ["en": "Open receipt", "ar": "فتح الإيصال"],
        "mac.receipt_paste": ["en": "Or paste the code's text", "ar": "أو الصق نص الرمز"],
        "mac.receipt_read":  ["en": "Read", "ar": "قراءة"],
        "mac.receipt_use":   ["en": "Use this receipt", "ar": "استخدام هذا الإيصال"],
        "mac.receipt_vat":   ["en": "VAT {vat}", "ar": "الضريبة {vat}"],
        "mac.receipt_supplier": ["en": "One of your suppliers", "ar": "من مورّديك"],
        "mac.receipt_from":  ["en": "Filled in from a receipt — check it, then choose the category.",
                              "ar": "عُبّئ من إيصال — راجعه ثم اختر الفئة."],
        "mac.receipt_duplicate": ["en": "This receipt is already in your expenses, so it is not offered again.",
                                  "ar": "هذا الإيصال مسجّل في مصروفاتك، لذا لا يُعرض مرة أخرى."],
        "mac.receipt_none_found": ["en": "No QR code was found in that file. Try a sharper picture, or paste the code's text.",
                                   "ar": "لم يُعثر على رمز QR في هذا الملف. جرّب صورة أوضح أو الصق نص الرمز."],
        "mac.receipt_unreadable": ["en": "No code here is a Saudi tax invoice's QR.",
                                   "ar": "لا يوجد هنا رمز QR لفاتورة ضريبية سعودية."],
        "mac.receipt_reason.empty":        ["en": "The code is empty.", "ar": "الرمز فارغ."],
        "mac.receipt_reason.too_long":     ["en": "The code is far longer than a tax invoice's.", "ar": "الرمز أطول بكثير من رمز فاتورة ضريبية."],
        "mac.receipt_reason.not_base64":   ["en": "This code is not a tax invoice's — it may be a link or a payment code.",
                                            "ar": "هذا الرمز ليس رمز فاتورة ضريبية — قد يكون رابطاً أو رمز دفع."],
        "mac.receipt_reason.truncated":    ["en": "The code is cut short.", "ar": "الرمز مقطوع."],
        "mac.receipt_reason.bad_tag":      ["en": "The code holds a field a tax invoice does not have.", "ar": "يحتوي الرمز على حقل ليس في الفاتورة الضريبية."],
        "mac.receipt_reason.not_utf8":     ["en": "The seller's name in the code cannot be read.", "ar": "تعذّرت قراءة اسم البائع في الرمز."],
        "mac.receipt_reason.missing_tag":  ["en": "The code is missing the seller, VAT number, time, total or VAT.",
                                            "ar": "ينقص الرمز البائع أو الرقم الضريبي أو الوقت أو الإجمالي أو الضريبة."],
        "mac.receipt_reason.bad_vat_number": ["en": "The seller's VAT number is not a Saudi one (15 digits, starting and ending in 3).",
                                              "ar": "الرقم الضريبي للبائع ليس سعودياً (15 رقماً تبدأ وتنتهي بالرقم 3)."],
        "mac.receipt_reason.bad_amount":   ["en": "The total or the VAT in the code is not an amount.", "ar": "الإجمالي أو الضريبة في الرمز ليس مبلغاً."],
        "mac.receipt_reason.vat_over_total": ["en": "The code says the VAT is more than the total.", "ar": "يقول الرمز إن الضريبة أكبر من الإجمالي."],
        "mac.receipt_reason.bad_timestamp": ["en": "The invoice date in the code cannot be read.", "ar": "تعذّرت قراءة تاريخ الفاتورة في الرمز."],
        "mac.receipt_vat_number": ["en": "VAT no. {vat}", "ar": "الرقم الضريبي {vat}"],
        "mac.receipt_note":  ["en": "{seller} · VAT no. {vat}", "ar": "{seller} · الرقم الضريبي {vat}"],
        "mac.receipt_new_supplier": ["en": "Not one of your suppliers yet", "ar": "ليس من مورّديك بعد"],
        "mac.receipt_add_supplier": ["en": "Add as supplier", "ar": "إضافة كمورّد"],
        "mac.receipt_code":  ["en": "Code: {code}", "ar": "الرمز: {code}"],
        "mac.receipt_sar":   ["en": "The receipt's amounts are in Saudi riyals; your shop keeps its books in {currency}.",
                              "ar": "مبالغ الإيصال بالريال السعودي، ومتجرك يسجّل حساباته بعملة {currency}."],
        "mac.sup_vat":       ["en": "VAT number", "ar": "الرقم الضريبي"],
        "mac.sup_vat_invalid": ["en": "A Saudi VAT number is 15 digits, starting and ending with 3.",
                                "ar": "الرقم الضريبي السعودي 15 رقمًا، يبدأ بالرقم 3 وينتهي به."],
        // Live Activities: this Mac's own opt-in (LiveActivityPush.optInKey).
        "mac.la_section":    ["en": "iPhone", "ar": "الآيفون"],
        "mac.la_toggle":     ["en": "Send print progress to my iPhone (Live Activities)",
                              "ar": "إرسال تقدّم الطباعة إلى iPhone (الأنشطة المباشرة)"],
        "mac.la_hint":       ["en": "Off unless you turn it on, and set on each Mac. When on, this Mac sends your printers' progress and job names through Khayt Cloud and Apple to your iPhone's Lock Screen.",
                              "ar": "مُطفأ ما لم تشغّله، ويُضبط على كل Mac وحده. عند تشغيله يرسل هذا الـMac تقدّم طابعاتك وأسماء المهام عبر خيط السحابي وApple إلى شاشة القفل في iPhone."],
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
        "mac.menu_model":    ["en": "Model",          "ar": "النموذج"],
        "mac.reload":        ["en": "Reload from Disk", "ar": "إعادة التحميل من القرص"],
        "mac.favourite":     ["en": "Favourite",      "ar": "مفضّلة"],
        "mac.reveal_in_finder": ["en": "Reveal in Finder", "ar": "إظهار في الباحث"],
        "mac.open_book":     ["en": "Open",           "ar": "فتح دفتر"],
        "mac.mb_open_khayt": ["en": "Open Khayt",     "ar": "فتح خيط"],
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
        "mac.sliced_title": ["en": "As sliced", "ar": "حسب التقطيع"],
        // `{plates}` is `words.counting(n, "mac.n_plates")`: Arabic says two
        // plates, three to ten plates and eleven plates three different ways.
        "mac.sliced_project": ["en": "As sliced — {plates}", "ar": "حسب التقطيع — {plates}"],
        "mac.n_plates":       ["en": "{n} plates", "ar": "{n} لوحًا"],
        "mac.n_plates_one":   ["en": "{n} plate", "ar": "لوح واحد"],
        "mac.n_plates_two":   ["en": "{n} plates", "ar": "لوحان"],
        "mac.n_plates_few":   ["en": "{n} plates", "ar": "{n} ألواح"],
        "mac.plate_n": ["en": "Plate {n}", "ar": "اللوح {n}"],
        "mac.plate_named": ["en": "Plate {n} — {name}", "ar": "اللوح {n} — {name}"],
        "mac.calc_from_model": ["en": "From a model…", "ar": "من نموذج…"],
        "mac.calc_whole_project": ["en": "Whole project ({plates})", "ar": "المشروع كاملًا ({plates})"],
        "mac.calc_model_none": ["en": "This model has no weight or time to fill in.", "ar": "لا يحمل هذا النموذج وزنًا أو زمنًا لتعبئته."],
        // A quote or a job from a model, or from the calculator's answer —
        // without retyping the grams and hours (JobFromModel.swift).
        "mac.new_quote": ["en": "New Quote", "ar": "عرض سعر جديد"],
        "mac.make_quote": ["en": "Make quote", "ar": "إنشاء عرض سعر"],
        "mac.make_job": ["en": "Make job", "ar": "إنشاء عمل"],
        "mac.make_quote_help": ["en": "Opens a new quote or job on this part at this price — nothing to type again.",
                                "ar": "يفتح عرض سعر أو عملًا جديدًا على هذه القطعة بهذا السعر — دون إعادة كتابة شيء."],
        "mac.quote_model": ["en": "Quote this model", "ar": "عرض سعر لهذا النموذج"],
        "mac.job_from_model": ["en": "New job from model", "ar": "عمل جديد من النموذج"],
        "mac.quote_n_models": ["en": "Quote {n} models as one job", "ar": "عرض سعر واحد للنماذج المحددة ({n})"],
        "mac.job_from_n_models": ["en": "New job from {n} models", "ar": "عمل جديد من النماذج المحددة ({n})"],
        "mac.quote_model_none": ["en": "No weight or time to quote for: {names}.", "ar": "لا وزن ولا زمن للتسعير في: {names}."],
        "mac.figures_sliced": ["en": "From the sliced file", "ar": "من الملف المقطَّع"],
        "mac.figures_estimated": ["en": "Estimated from the model's shape", "ar": "تقدير من شكل النموذج"],
        "mac.figures_part_estimated": ["en": "Partly estimated from the model's shape", "ar": "تقدير جزئي من شكل النموذج"],
        "mac.paid_in_full": ["en": "Paid in full", "ar": "مدفوع بالكامل"],
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
                                   "ar": "لا يوجد دفتر على هذا الماك بعد"],
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
        // THE WHOLE COST OF A FAILED PRINT (`lib/failed-print-cost.js`):
        // filament, machine time, electricity. Shown on the Waste screen as
        // information — the P&L keeps counting the filament only, because the
        // machine and the power bill are already the shop's real expenses.
        "mac.waste_filament":   ["en": "Filament", "ar": "الخيط"],
        "mac.waste_machine":    ["en": "Machine time", "ar": "وقت الآلة"],
        "mac.waste_power":      ["en": "Electricity", "ar": "الكهرباء"],
        "mac.waste_full":       ["en": "True cost", "ar": "التكلفة الفعلية"],
        "mac.waste_true_title": ["en": "True cost of failures", "ar": "التكلفة الفعلية للطباعات الفاشلة"],
        "mac.waste_energy":     ["en": "Energy metered", "ar": "الطاقة المقيسة"],
        "mac.waste_true_note":  ["en": "For your information. The machine's time and the electricity are already in your expenses, so the profit and loss counts the filament only.",
                                 "ar": "للاطلاع فقط. وقت الآلة والكهرباء محسوبان مسبقًا ضمن مصروفاتك، لذا لا تحسب الأرباح والخسائر إلا الخيط."],
        "mac.waste_true_older": ["en": "Entries logged without a job count their filament only.",
                                 "ar": "الإدخالات المسجلة دون طلب تُحسب بخيطها فقط."],
        "mac.waste_job":        ["en": "Job", "ar": "الطلب"],
        "mac.waste_no_job":     ["en": "No job", "ar": "بلا طلب"],
        "mac.waste_job_help":   ["en": "Link the failed print to its job to cost its machine time and electricity too.",
                                 "ar": "اربط الطباعة الفاشلة بطلبها لتُحسب تكلفة وقت الآلة والكهرباء أيضًا."],
        // A machine's wattage, from what its plug measured (`print-energy`).
        // {prints} is a `Words.counting` of `mac.acc_prints`.
        "mac.power_measured":   ["en": "The plug measured {watts} W over {prints}.",
                                 "ar": "قاس المقبس {watts} واط على {prints}."],
        "mac.power_use":        ["en": "Use this", "ar": "استخدم هذه القيمة"],
        // Units beside the printer's fields, in the shop's language.
        "mac.unit_mm":          ["en": "mm", "ar": "مم"],
        "mac.unit_watts":       ["en": "W", "ar": "واط"],
        "mac.unit_kwh":         ["en": "kWh", "ar": "كيلوواط ساعة"],
        // Electricity quoted against electricity metered, per machine — the
        // actuals panel, not the P&L.
        "mac.acc_power_title":  ["en": "Electricity: quoted and metered", "ar": "الكهرباء: المقدّرة والمقيسة"],
        "mac.acc_power_note":   ["en": "Only prints a smart plug metered. Your electricity bill stays in your expenses.",
                                 "ar": "الطباعات التي قاسها مقبس ذكي فقط. تبقى فاتورة الكهرباء ضمن مصروفاتك."],
        // COUNTED through `Words.counting`, with a `_one` and an Arabic `_two`:
        // "20 finished job(s)" was the board's banner on the shop's own book
        // (alpha.51 review), and an "(s)" is a sentence that did not decide.
        "mac.board_unplaced": ["en": "{n} jobs are in a stage this board has no column for.",
                               "ar": "{n} من الأعمال في مرحلة لا عمود لها في لوحة المهام."],
        "mac.board_unplaced_one": ["en": "{n} job is in a stage this board has no column for.",
                                   "ar": "عمل واحد في مرحلة لا عمود لها في لوحة المهام."],
        "mac.board_unplaced_two": ["en": "{n} jobs are in a stage this board has no column for.",
                                   "ar": "عملان في مرحلة لا عمود لها في لوحة المهام."],
        // The board draws work in flight; delivered and cancelled jobs leave it.
        // Said, so a shop whose every job is finished is not shown eight empty
        // lanes and left to wonder where its jobs went.
        "mac.board_finished_elsewhere": ["en": "{n} finished jobs left the board when delivered or cancelled. They are all in Jobs.",
                                         "ar": "{n} من الأعمال المنتهية خرجت من لوحة المهام بعد التسليم أو الإلغاء، وكلها في قائمة الأعمال."],
        "mac.board_finished_elsewhere_one": ["en": "{n} finished job left the board when it was delivered or cancelled. It is in Jobs.",
                                             "ar": "عمل منتهٍ واحد خرج من لوحة المهام بعد التسليم أو الإلغاء، وهو في قائمة الأعمال."],
        "mac.board_finished_elsewhere_two": ["en": "{n} finished jobs left the board when delivered or cancelled. They are both in Jobs.",
                                             "ar": "عملان منتهيان خرجا من لوحة المهام بعد التسليم أو الإلغاء، وكلاهما في قائمة الأعمال."],
        "mac.board_open_jobs": ["en": "Show in Jobs", "ar": "اعرضها في الأعمال"],
        // SENTENCE CASE, as the rest of the Mac app is. Khayt's shared locale
        // says "Issue Gift Card", "Gift Card Code", "Failure Category" and
        // "+ Add Supplier"; those strings are the Electron app's, so the Mac
        // asks for its own rather than recasing nine languages under it.
        "mac.issue_gift_card": ["en": "Issue Gift Card", "ar": "إصدار بطاقة هدية"],
        "mac.gift_card_code":  ["en": "Gift card code",  "ar": "رمز بطاقة الهدية"],
        "mac.failure_category": ["en": "Failure category", "ar": "فئة الفشل"],
        "mac.add_supplier":    ["en": "Add supplier",    "ar": "إضافة مورد"],
        "mac.edit_supplier":   ["en": "Edit supplier",   "ar": "تعديل المورد"],
        // A shop that has never logged waste has not done a great job — it has
        // not started. The shared "great job!" praised an empty book.
        // The expenses table's order column. The shared `exp.order_ref` is the
        // sheet's field label, "(optional)" and all, and did not fit a column.
        "mac.expense_order_col": ["en": "Order", "ar": "الطلب"],
        // Titles, so no full stop — as "No customers yet".
        "mac.waste_empty":     ["en": "No waste logged yet", "ar": "لم يُسجَّل أي هدر بعد"],
        "mac.expenses_empty":  ["en": "No expenses recorded yet", "ar": "لا توجد مصروفات مسجلة بعد"],
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
        "mac.mc_title":      ["en": "Price on the shelf", "ar": "السعر على الرف"],
        "mac.mc_sub":        ["en": "Per unit, from the most recent spool of each material.",
                              "ar": "لكل وحدة، من أحدث بكرة لكل مادة."],
        "mac.mc_spools":     ["en": "{n} spools", "ar": "{n} بكرة"],
        "mac.mc_spools_one": ["en": "{n} spool", "ar": "بكرة واحدة"],
        "mac.mc_spools_two": ["en": "{n} spools", "ar": "بكرتان"],
        "mac.mc_spools_few": ["en": "{n} spools", "ar": "{n} بكرات"],
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
        "mac.cm_people":     ["en": "{n} people",     "ar": "{n} شخصًا"],
        "mac.cm_people_one": ["en": "{n} person",     "ar": "شخص واحد"],
        "mac.cm_people_two": ["en": "2 people",       "ar": "شخصان"],
        "mac.cm_people_few": ["en": "{n} people",     "ar": "{n} أشخاص"],
        "mac.cm_people_zero": ["en": "No people", "ar": "لا أحد"],
        "mac.cm_first":      ["en": "A new customer's first order is worth {amount} on average.",
                              "ar": "أول طلب لعميل جديد يساوي {amount} في المتوسط."],
        // Which products actually earn.
        "mac.pp_title":      ["en": "What earns",     "ar": "ما الذي يكسب"],
        "mac.pp_per_hour":   ["en": "per machine hour", "ar": "لكل ساعة تشغيل"],
        "mac.pp_best":       ["en": "{name} earns the most per machine hour — {amount} — which is the thing to push.",
                              "ar": "{name} الأعلى ربحًا لكل ساعة تشغيل — {amount} — وهو ما يستحق الترويج."],
        "mac.pp_hours":      ["en": "{n} h",          "ar": "{n} ساعة"],
        // Profit per printer hour: the catalogue ranked by machine time.
        "mac.pph_column":    ["en": "Per hour",       "ar": "لكل ساعة"],
        "mac.pph_column_help": ["en": "Profit per printer hour: (price − cost) ÷ print hours",
                                "ar": "الربح لكل ساعة طباعة: (السعر − التكلفة) ÷ ساعات الطباعة"],
        "mac.pph_rate":      ["en": "{amount}/h",     "ar": "{amount}/ساعة"],
        "mac.pph_title":     ["en": "Best use of the printer", "ar": "أفضل استخدام للطابعة"],
        "mac.pph_intro":     ["en": "What each product earns for an hour on the printer. With one printer, machine time runs out before anything else.",
                              "ar": "ما يكسبه كل منتج مقابل ساعة على الطابعة. مع طابعة واحدة، وقت الآلة هو أول ما ينفد."],
        "mac.pph_average":   ["en": "Across the catalogue the printer earns {amount} an hour.",
                              "ar": "يكسب الكتالوج في المتوسط {amount} لكل ساعة طباعة."],
        "mac.pph_actual_average": ["en": "Finished jobs actually earned {amount} an hour.",
                                   "ar": "كسبت المهام المنجزة فعليًا {amount} لكل ساعة."],
        "mac.pph_planned":   ["en": "planned",        "ar": "المخطط"],
        "mac.pph_actual":    ["en": "actual",         "ar": "الفعلي"],
        "mac.pph_actual_jobs": ["en": "actual {amount}/h from {n} finished jobs",
                                "ar": "الفعلي {amount}/ساعة (عدد المهام المنجزة: {n})"],
        "mac.pph_longer":    ["en": "prints ran {pct}% longer than estimated",
                              "ar": "استغرقت الطباعة أطول من التقدير بنسبة {pct}%"],
        "mac.pph_shorter":   ["en": "prints ran {pct}% shorter than estimated",
                              "ar": "استغرقت الطباعة أقصر من التقدير بنسبة {pct}%"],
        "mac.pph_under":     ["en": "Below the shop's average per hour — about {amount} would match it.",
                              "ar": "أقل من متوسط المتجر لكل ساعة — سعر يقارب {amount} يطابقه."],
        "mac.pph_unranked":  ["en": "Not ranked yet (no price or no print hours): {n}",
                              "ar": "لم تُرتَّب بعد (بلا سعر أو بلا ساعات طباعة): {n}"],
        "mac.pph_empty":     ["en": "Give your products print hours and a price to see which earns most per hour.",
                              "ar": "أضف ساعات الطباعة والسعر لمنتجاتك لترى أيها يكسب أكثر لكل ساعة."],
        "mac.ws_pph_title":  ["en": "Suggestions",    "ar": "اقتراحات"],
        "mac.ws_pph_best":   ["en": "These listed products earn the most per printer hour — worth featuring.",
                              "ar": "هذه المنتجات المعروضة تكسب أكثر لكل ساعة طباعة — تستحق الإبراز."],
        "mac.ws_pph_under":  ["en": "These may be underpriced for the printer time they take.",
                              "ar": "قد تكون هذه أقل من سعرها مقارنة بوقت الطباعة الذي تأخذه."],
        "mac.ws_pph_under_line": ["en": "{rate} against the shop's {average}; about {price} would match it.",
                                  "ar": "{rate} مقابل متوسط المتجر {average}؛ سعر يقارب {price} يطابقه."],
        // How many quotes turn into work.
        "mac.qf_by_value":   ["en": "of the money",   "ar": "من قيمة العروض"],
        "mac.qf_by_count":   ["en": "of the quotes",  "ar": "من عدد العروض"],
        "mac.qf_decide":     ["en": "{n} days to decide, typically",
                              "ar": "{n} يومًا للبتّ عادةً"],
        "mac.qf_decide_one": ["en": "{n} day to decide, typically", "ar": "يوم واحد للبتّ عادةً"],
        "mac.qf_decide_two": ["en": "2 days to decide, typically", "ar": "يومان للبتّ عادةً"],
        "mac.qf_decide_few": ["en": "{n} days to decide, typically", "ar": "{n} أيام للبتّ عادةً"],
        "mac.qf_decide_zero": ["en": "Decided the same day, typically", "ar": "يُبتّ فيها في اليوم نفسه عادةً"],
        // Two counts in one sentence, each counted on its own: Arabic says
        // "3 عروض" but "11 عرضًا", and "منذ يومين" rather than "منذ 2 يومًا".
        "mac.qf_open":       ["en": "{quotes} still open, worth {amount}. The oldest has been waiting {days}.",
                              "ar": "لم يُبتّ بعد في {quotes} بقيمة {amount}. أقدمها ينتظر منذ {days}."],
        "mac.qf_quotes":     ["en": "{n} quotes", "ar": "{n} عرضًا"],
        "mac.qf_quotes_one": ["en": "{n} quote", "ar": "عرض واحد"],
        "mac.qf_quotes_two": ["en": "2 quotes", "ar": "عرضين"],
        "mac.qf_quotes_few": ["en": "{n} quotes", "ar": "{n} عروض"],
        "mac.qf_days":       ["en": "{n} days", "ar": "{n} يومًا"],
        "mac.qf_days_one":   ["en": "{n} day", "ar": "يوم واحد"],
        "mac.qf_days_two":   ["en": "2 days", "ar": "يومين"],
        "mac.qf_days_few":   ["en": "{n} days", "ar": "{n} أيام"],
        "mac.qf_days_zero":  ["en": "today", "ar": "اليوم"],
        // Whether the shop can take another job.
        "mac.cap_clear_days": ["en": "clear in {n} days", "ar": "يخلو خلال {n} يومًا"],
        "mac.cap_clear_days_one": ["en": "clear in {n} day", "ar": "يخلو خلال يوم واحد"],
        "mac.cap_clear_days_two": ["en": "clear in {n} days", "ar": "يخلو خلال يومين"],
        "mac.cap_clear_days_few": ["en": "clear in {n} days", "ar": "يخلو خلال {n} أيام"],
        "mac.cap_clear_soon": ["en": "free today",       "ar": "متاح اليوم"],
        "mac.cap_over":       ["en": "{n} days behind",  "ar": "متأخر {n} يومًا"],
        "mac.cap_over_one":   ["en": "{n} day behind",   "ar": "متأخر بيوم واحد"],
        "mac.cap_over_two":   ["en": "{n} days behind",  "ar": "متأخر بيومين"],
        "mac.cap_over_few":   ["en": "{n} days behind",  "ar": "متأخر {n} أيام"],
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
        "mac.spool_repair_done": ["en": "{n} products were re-priced on their spools' sizes, as reviewed.", "ar": "أُعيد تسعير {n} منتجات على حجم بكراتها، كما راجعتها."],
        "mac.spool_repair_done_one": ["en": "{n} product was re-priced on its spool's size, as reviewed.", "ar": "أُعيد تسعير منتج واحد على حجم بكرته، كما راجعته."],
        "mac.spool_repair_done_two": ["en": "{n} products were re-priced on their spools' sizes, as reviewed.", "ar": "أُعيد تسعير منتجَين على حجم بكرتيهما، كما راجعتهما."],
        "mac.spool_repair_pending": ["en": "{n} products are costed on a spool size that has changed. Their prices have not been touched.", "ar": "تكلفة {n} منتجات محسوبة على حجم بكرة تغيّر. لم تُمسّ أسعارها."],
        "mac.spool_repair_pending_one": ["en": "{n} product is costed on a spool size that has changed. Its price has not been touched.", "ar": "تكلفة منتج واحد محسوبة على حجم بكرة تغيّر. لم يُمسّ سعره."],
        "mac.spool_repair_pending_two": ["en": "{n} products are costed on a spool size that has changed. Their prices have not been touched.", "ar": "تكلفة منتجَين محسوبة على حجم بكرة تغيّر. لم يُمسّ سعرهما."],
        "mac.spool_repair_review": ["en": "Review", "ar": "مراجعة"],
        "mac.spool_repair_title": ["en": "Re-cost on spool sizes", "ar": "إعادة التكلفة على حجم البكرات"],
        "mac.spool_repair_explain": ["en": "These products were costed on a spool figure that is not the spool's size now. Here is what each price would become. Nothing changes unless you re-price them.", "ar": "حُسبت تكلفة هذه المنتجات على رقم بكرة لا يطابق حجمها الحالي. هذا ما سيصبح عليه كل سعر. لن يتغيّر شيء ما لم تُعِد تسعيرها."],
        "mac.spool_repair_apply": ["en": "Re-price {n} products", "ar": "إعادة تسعير {n} منتجات"],
        "mac.spool_repair_apply_one": ["en": "Re-price {n} product", "ar": "إعادة تسعير منتج واحد"],
        "mac.spool_repair_apply_two": ["en": "Re-price {n} products", "ar": "إعادة تسعير منتجَين"],
        "mac.ws_prices_held": ["en": "Prices changed — review before publishing", "ar": "تغيّرت الأسعار — راجعها قبل النشر"],
        "mac.ws_prices_held_hint": ["en": "Your live store was not updated: these prices changed without being saved in a product. Publish to list them, or fix the product first.", "ar": "لم يُحدَّث متجرك: تغيّرت هذه الأسعار دون حفظها في منتج. انشر لعرضها، أو صحّح المنتج أولاً."],
        "mac.lock_lost":     ["en": "Another app has this book open now, so this Mac has stopped changing it. Close the book there, then reopen it here to make changes.", "ar": "دفترك مفتوح الآن في تطبيق آخر، لذا توقّف هذا الماك عن تعديله. أغلق الدفتر هناك ثم افتحه هنا من جديد لتجري تغييرات."],
        "mac.read_only":     ["en": "Opened read-only",          "ar": "مفتوح للقراءة فقط"],
        "mac.writable":      ["en": "This book is yours to change", "ar": "هذا الدفتر تحت تصرفك"],
        "mac.sample":        ["en": "Sample data",   "ar": "بيانات تجريبية"],
        "mac.not_real_shop": ["en": "sample data — not a real shop",
                              "ar": "بيانات تجريبية — ليست محلاً حقيقياً"],
        "mac.yours":         ["en": "yours to change", "ar": "تحت تصرفك"],
        // Library
        "mac.on_this_mac":   ["en": "On this Mac",   "ar": "على هذا الماك"],
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
        "mac.no_customers_hint": ["en": "Add one now, or they appear here once a job is billed to them.",
                                  "ar": "أضف عميلًا الآن، أو يظهر هنا بعد أن يُحرَّر له حساب على عمل."],
        "mac.add_customer":  ["en": "Add Customer", "ar": "إضافة عميل"],
        "mac.integ_cloud_hint": ["en": "Sign in to Khayt Cloud ({where}) to get import and feed links for these storefronts.",
                                 "ar": "سجّل الدخول إلى سحابة خيط ({where}) للحصول على روابط الاستيراد والخلاصة لهذه المتاجر."],
        "mac.past_due":      ["en": "Past due",        "ar": "متأخر السداد"],
        // Khayt's `flow.paid` is the STATUS word — lowercase "paid", which is
        // right beside a job and wrong as a row label between "Total" and
        // "Owed". A borrowed key wins over this app's own, so the label needs a
        // key of its own rather than a different value under the same one.
        "mac.paid":          ["en": "Paid",           "ar": "مدفوع"],
        // ── PAYMENT TERMS (lib/payment-terms.js) ─────────────────────────
        //
        // A customer's terms: due on receipt, net 7…90, or a custom number of
        // days. "صافي 30" carries no counted noun, so it needs no plural forms;
        // the explanation under the picker does, and has them.
        "mac.payment_terms":   ["en": "Payment terms", "ar": "شروط الدفع"],
        "mac.terms_receipt":   ["en": "Due on receipt", "ar": "الدفع عند الاستلام"],
        "mac.terms_net":       ["en": "Net {n}", "ar": "صافي {n}"],
        "mac.terms_custom":    ["en": "Custom…", "ar": "مخصص…"],
        "mac.terms_days":      ["en": "Due {n} days after the invoice date",
                                "ar": "يُستحق بعد {n} يومًا من تاريخ الفاتورة"],
        "mac.terms_days_one":  ["en": "Due {n} day after the invoice date",
                                "ar": "يُستحق بعد يوم واحد من تاريخ الفاتورة"],
        "mac.terms_days_two":  ["en": "Due 2 days after the invoice date",
                                "ar": "يُستحق بعد يومين من تاريخ الفاتورة"],
        "mac.terms_days_few":  ["en": "Due {n} days after the invoice date",
                                "ar": "يُستحق بعد {n} أيام من تاريخ الفاتورة"],
        // Money past the customer's terms — not the jobs past their delivery
        // date, which `mac.past_due` counts beside it.
        "mac.terms_overdue":   ["en": "Overdue", "ar": "تجاوز موعد السداد"],
        "mac.aged_due":        ["en": "Due", "ar": "الاستحقاق"],
        "mac.not_yet_due":     ["en": "Not yet due", "ar": "لم يحن موعده"],
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
                                  "ar": "المدة اللازمة لإخراج بكرة من رأس وتحميل أخرى. تُستخدم فقط لتقدير الوقت الموفَّر عند تجميع الأعمال حسب اللون. 3 دقائق تناسب Snapmaker U1 بوجود شخص عند الطابعة؛ ولا يُحتسب وقت الوصول إليها."],
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
        // The File menu's Mac commands — see `Shop+Conventions.swift`.
        "mac.share":         ["en": "Share",          "ar": "مشاركة"],
        "mac.duplicate":     ["en": "Duplicate",      "ar": "تكرار"],
        // Appended to a duplicated product's name, so the copy is never read
        // as the original in a list.
        "mac.copy_suffix":   ["en": "copy",           "ar": "(نسخة)"],
        "mac.labels_count":  ["en": "labels",         "ar": "ملصقات"],
        "mac.labels_count_one": ["en": "label",       "ar": "ملصق"],
        "mac.labels_count_two": ["en": "labels", "ar": "ملصقان"],

        // The library in this Mac's own search.
        "mac.spotlight":     ["en": "Find models in Spotlight",
                              "ar": "البحث عن النماذج في Spotlight"],
        "mac.spotlight_note": ["en": "Model names, projects and tags only — never jobs or customers.",
                               "ar": "أسماء النماذج والمشاريع والوسوم فقط — لا الطلبات ولا العملاء."],

        // Which digits a figure is written in, on this Mac (`Digits`).
        "mac.mac_digits":      ["en": "Use the Mac's number format",
                                "ar": "استخدام أرقام الماك"],
        "mac.mac_digits_note": ["en": "Off, numbers are written 0–9 in English and Arabic. On, they follow Language & Region on this Mac.",
                                "ar": "عند إيقافه تُكتب الأرقام 0–9 بالعربية والإنجليزية. وعند تشغيله تتبع إعدادات اللغة والمنطقة في هذا الماك."],

        // A photograph of the finished print, on the job that made it.
        "mac.add_print_photo": ["en": "Add a photo of the print",
                                "ar": "إضافة صورة للطباعة"],
        "mac.photo_on_finished_only": ["en": "A photo can be added once the job is finished.",
                                       "ar": "يمكن إضافة صورة بعد انتهاء الطلب."],
        "mac.photo_where": ["en": "Open a finished job and choose “Add a photo of the print”.",
                            "ar": "افتح طلبًا منتهيًا واختر «إضافة صورة للطباعة»."],
        "mac.show_finished_jobs": ["en": "Show finished jobs", "ar": "عرض الطلبات المنتهية"],
        // The job's photos — the printer's own at the end of a print, or the
        // shop's — and putting one on the product as the real thing.
        "mac.print_photos": ["en": "Photos of the print", "ar": "صور الطباعة"],
        "mac.use_as_product_photo": ["en": "Use as product photo",
                                     "ar": "استخدامها صورةً للمنتج"],
        "mac.product_photo_added": ["en": "Added to the product as a photo of the real print.",
                                    "ar": "أُضيفت إلى المنتج كصورة للقطعة المطبوعة فعلًا."],
        "mac.product_photo_already": ["en": "This photo is already on the product.",
                                      "ar": "هذه الصورة موجودة في المنتج بالفعل."],

        // The shop's own saved messages.
        "mac.send_a_message": ["en": "Send a message", "ar": "إرسال رسالة"],
        "mac.message_template": ["en": "Message",      "ar": "الرسالة"],
        "mac.open_whatsapp":  ["en": "Open WhatsApp",  "ar": "فتح واتساب"],
        "mac.no_phone_for_whatsapp": ["en": "This customer has no phone number on file.",
                                      "ar": "لا يوجد رقم هاتف مسجّل لهذا العميل."],
        // WhatsApp updates at a job's milestones (lib/whatsapp-message.js).
        "mac.send_on_whatsapp": ["en": "Send on WhatsApp", "ar": "إرسال عبر واتساب"],
        "mac.wa_update": ["en": "WhatsApp update", "ar": "تحديث عبر واتساب"],
        "mac.wa_update_due": ["en": "Tell the customer: {m}", "ar": "أبلغ العميل: {m}"],
        "mac.wa_update_sent": ["en": "{m} update opened in WhatsApp on {day}",
                               "ar": "فُتح تحديث «{m}» في واتساب بتاريخ {day}"],
        "mac.wa_m_received": ["en": "Order received", "ar": "تم استلام الطلب"],
        "mac.wa_m_ready": ["en": "Ready", "ar": "جاهز"],
        "mac.wa_m_shipped": ["en": "Shipped", "ar": "تم الشحن"],
        "mac.wa_m_delivered": ["en": "Delivered", "ar": "تم التسليم"],
        "mac.wa_saved_messages": ["en": "Saved messages", "ar": "الرسائل المحفوظة"],
        "mac.wa_language": ["en": "Language", "ar": "اللغة"],
        "mac.wa_lang_ar": ["en": "Arabic", "ar": "العربية"],
        "mac.wa_lang_en": ["en": "English", "ar": "الإنجليزية"],
        "mac.wa_lang_auto": ["en": "Automatic", "ar": "تلقائي"],
        "mac.wa_any_language": ["en": "Any language", "ar": "أي لغة"],
        "mac.wa_messages_in": ["en": "Messages in", "ar": "لغة الرسائل"],
        "mac.wa_milestone": ["en": "Sent when", "ar": "تُرسل عند"],
        "mac.wa_milestone_none": ["en": "Any time (saved message)", "ar": "في أي وقت (رسالة محفوظة)"],
        "mac.wa_to": ["en": "To {number}", "ar": "إلى {number}"],
        "mac.wa_logged_note": ["en": "Opening WhatsApp writes this message to the customer's log. WhatsApp sends nothing until you press send there.",
                               "ar": "فتح واتساب يسجّل هذه الرسالة في سجل تواصل العميل. لا يُرسل واتساب شيئًا حتى تضغط إرسال فيه."],
        "mac.wa_default_words": ["en": "Khayt's default words. To use your own, save a WhatsApp template for this step in Settings › Integrations.",
                                 "ar": "هذه صياغة خيط الافتراضية. لاستخدام صياغتك، احفظ قالب واتساب لهذه المرحلة من الإعدادات › التكاملات."],
        "mac.wa_number_ok": ["en": "WhatsApp: {number}", "ar": "واتساب: {number}"],
        "mac.wa_reason_no_customer": ["en": "This job has no customer record, so there is no number to send to.",
                                      "ar": "لا يوجد سجل عميل لهذا الطلب، فلا يوجد رقم للإرسال إليه."],
        "mac.wa_reason_too_short": ["en": "The phone number is too short to be a WhatsApp number.",
                                    "ar": "رقم الهاتف أقصر من أن يكون رقم واتساب."],
        "mac.wa_reason_too_long": ["en": "The phone number is too long to be a WhatsApp number.",
                                   "ar": "رقم الهاتف أطول من أن يكون رقم واتساب."],
        "mac.wa_reason_no_country_code": ["en": "Add the country code to this number (for example +971…). Only Saudi numbers can be written without one.",
                                          "ar": "أضف رمز الدولة لهذا الرقم (مثل ‎+971…‎). الأرقام السعودية وحدها تُكتب بدونه."],
        "mac.wa_reason_bad_saudi_number": ["en": "This is not a Saudi mobile or landline number. 800 and 9200 numbers have no WhatsApp.",
                                           "ar": "هذا ليس رقم جوال أو هاتف ثابت سعوديًا. أرقام 800 و9200 لا تدعم واتساب."],
        "mac.wa_reason_no_milestone": ["en": "A quote or a cancelled job has no update to send.",
                                       "ar": "لا يوجد تحديث لإرساله لعرض سعر أو طلب ملغى."],
        "mac.wab_section": ["en": "WhatsApp Business: send updates for you",
          "ar": "واتساب للأعمال: إرسال التحديثات نيابةً عنك"],
        "mac.wab_hint": ["en": "Connect your own WhatsApp Business account (Meta's Cloud API) and Khayt sends the customer an update by itself when a job is approved, ready, shipped or delivered. It sends only templates you wrote and Meta approved, and only to customers marked as having agreed to updates on WhatsApp. The access token is locked on this Mac and is never sent to Khayt Cloud or a phone. Until this is set up, updates open in WhatsApp for you to send.",
          "ar": "اربط حسابك في واتساب للأعمال (واجهة Meta السحابية) ليرسل خيط للعميل تحديثاً من تلقاء نفسه عند اعتماد الطلب أو جاهزيته أو شحنه أو تسليمه. لا يرسل إلا قوالب كتبتها أنت ووافقت عليها Meta، ولا يرسلها إلا للعملاء المسجّل أنهم وافقوا على تلقي التحديثات عبر واتساب. رمز الوصول مقفل على هذا الماك ولا يُرسل أبداً إلى خيط السحابي أو إلى جوال. إلى أن يُعدّ هذا، تُفتح التحديثات في واتساب لترسلها بنفسك."],
        "mac.wab_enabled": ["en": "Send order updates through my WhatsApp Business account",
          "ar": "إرسال تحديثات الطلبات عبر حسابي في واتساب للأعمال"],
        "mac.wab_other_provider": ["en": "The desktop app's SMS settings use another provider for this shop. Turning this on replaces it.",
          "ar": "إعدادات الرسائل في تطبيق سطح المكتب تستخدم مزوّداً آخر لهذا المتجر. تفعيل هذا يستبدله."],
        "mac.wab_number_id": ["en": "Phone number ID",
          "ar": "معرّف رقم الهاتف"],
        "mac.wab_number_id_hint": ["en": "In Meta's WhatsApp Manager or the app dashboard: WhatsApp › API Setup. It is a long number, not your phone number.",
          "ar": "في WhatsApp Manager أو لوحة تطبيق Meta: ‏WhatsApp ‹ API Setup. وهو رقم طويل، وليس رقم هاتفك."],
        "mac.wab_token": ["en": "Access token",
          "ar": "رمز الوصول"],
        "mac.wab_token_hint": ["en": "Use a permanent token from a system user in Meta Business Settings. A temporary token stops working within a day.",
          "ar": "استخدم رمزاً دائماً من مستخدم نظام في إعدادات Meta للأعمال. الرمز المؤقت يتوقف خلال يوم."],
        "mac.wab_forget": ["en": "Forget the saved token",
          "ar": "نسيان الرمز المحفوظ"],
        "mac.wab_templates": ["en": "Approved templates",
          "ar": "القوالب المعتمدة"],
        "mac.wab_templates_hint": ["en": "Create these in WhatsApp Manager › Message templates, category Utility, in Arabic and English. Leave a step empty to send nothing for it. Khayt fills the template's variables in this order:",
          "ar": "أنشئها في WhatsApp Manager ‹ قوالب الرسائل، فئة «خدمية» (Utility)، بالعربية والإنجليزية. اترك الخطوة فارغة إن لم ترد إرسال شيء لها. يملأ خيط متغيرات القالب بهذا الترتيب:"],
        "mac.wab_params_basic": ["en": "{{1}} customer name · {{2}} order number · {{3}} shop name",
          "ar": "{{1}} اسم العميل · {{2}} رقم الطلب · {{3}} اسم المتجر"],
        "mac.wab_params_shipped": ["en": "{{1}} customer name · {{2}} order number · {{3}} carrier · {{4}} tracking number · {{5}} shop name",
          "ar": "{{1}} اسم العميل · {{2}} رقم الطلب · {{3}} شركة الشحن · {{4}} رقم التتبع · {{5}} اسم المتجر"],
        "mac.wab_template_name": ["en": "Template name",
          "ar": "اسم القالب"],
        "mac.wab_langs": ["en": "Languages",
          "ar": "اللغات"],
        "mac.wab_bad_name": ["en": "Template names use lowercase letters, digits and _ only, as WhatsApp Manager shows them.",
          "ar": "أسماء القوالب بأحرف إنجليزية صغيرة وأرقام و _ فقط، كما تظهر في WhatsApp Manager."],
        "mac.wab_bad_lang": ["en": "Languages are Meta's codes separated by commas, such as ar, en or en_US.",
          "ar": "اللغات رموز Meta مفصولة بفواصل، مثل ar أو en أو en_US."],
        "mac.wab_needs_template": ["en": "Each step with a template needs at least one language.",
          "ar": "كل خطوة لها قالب تحتاج لغة واحدة على الأقل."],
        "mac.wab_check": ["en": "Check account",
          "ar": "فحص الحساب"],
        "mac.wab_check_ok": ["en": "Connected to {number} ({name}). Nothing was sent.",
          "ar": "متصل بالرقم {number} ‏({name}). لم يُرسل شيء."],
        "mac.wab_unsealed": ["en": "The token could not be locked on this Mac, so it was not saved.",
          "ar": "تعذّر قفل الرمز على هذا الماك، لذا لم يُحفظ."],
        "mac.wab_opt_in": ["en": "Agreed to order updates on WhatsApp",
          "ar": "وافق على تلقي تحديثات الطلب عبر واتساب"],
        "mac.wab_opt_in_since": ["en": "since {day}",
          "ar": "منذ {day}"],
        "mac.wab_offers_opted_out": ["en": "Opted out of marketing below, so no offers go to them.",
          "ar": "ألغى الاشتراك في التسويق أدناه، فلن تصله أي عروض."],
        "mac.wab_how_asked": ["en": "Asked in person or by phone",
          "ar": "سُئل شخصياً أو هاتفياً"],
        "mac.wab_how_form": ["en": "On an order form",
          "ar": "في نموذج الطلب"],
        "mac.wab_how_customer_wrote": ["en": "Wrote to us on WhatsApp",
          "ar": "راسلنا عبر واتساب"],
        "mac.wab_how_other": ["en": "Another way",
          "ar": "بطريقة أخرى"],
        "mac.wab_sent_not_logged": ["en": "WhatsApp took the message (id {id}), but it could not be written to the customer’s log. Don’t send it again; add a note by hand if you need the record.", "ar": "استلم واتساب الرسالة (المعرّف {id})، لكن تعذّر تسجيلها في سجل العميل. لا ترسلها مجدداً؛ وأضف ملاحظة يدوياً إن احتجت إلى السجل."],
        "mac.wab_note": ["en": "WhatsApp Business template {name}: {params}",
          "ar": "قالب واتساب للأعمال {name}: {params}"],
        "mac.wab_sent": ["en": "“{m}” update sent to the customer on WhatsApp.",
          "ar": "أُرسل تحديث «{m}» للعميل عبر واتساب."],
        "mac.wab_not_sent": ["en": "The “{m}” WhatsApp update was not sent.",
          "ar": "لم يُرسل تحديث «{m}» عبر واتساب."],
        "mac.wab_send_now": ["en": "Send through WhatsApp Business",
          "ar": "إرسال عبر واتساب للأعمال"],
        "mac.wab_write_myself": ["en": "Write it myself",
          "ar": "سأكتبها بنفسي"],
        "mac.wab_r_not_set_up": ["en": "WhatsApp Business is not set up in Settings › Integrations.",
          "ar": "واتساب للأعمال غير مُعدّ في الإعدادات ‹ التكاملات."],
        "mac.wab_r_no_phone_number_id": ["en": "Add the phone number ID in Settings › Integrations.",
          "ar": "أضف معرّف رقم الهاتف في الإعدادات ‹ التكاملات."],
        "mac.wab_r_no_token": ["en": "Add the access token in Settings › Integrations.",
          "ar": "أضف رمز الوصول في الإعدادات ‹ التكاملات."],
        "mac.wab_r_no_template": ["en": "There is no approved template for this step in Settings › Integrations.",
          "ar": "لا يوجد قالب معتمد لهذه الخطوة في الإعدادات ‹ التكاملات."],
        "mac.wab_r_not_opted_in": ["en": "The customer has not agreed to updates on WhatsApp. Tick it on their record once they have.",
          "ar": "لم يوافق العميل على تلقي التحديثات عبر واتساب. فعّلها في سجله بعد موافقته."],
        "mac.wab_r_no_customer": ["en": "This job has no customer record.",
          "ar": "لا يوجد سجل عميل لهذا الطلب."],
        "mac.wab_r_already_sent": ["en": "This update has already been sent.",
          "ar": "أُرسل هذا التحديث من قبل."],
        "mac.wab_r_no_change": ["en": "This change is not a new step for the customer.",
          "ar": "هذا التغيير ليس خطوة جديدة بالنسبة للعميل."],
        "mac.wab_r_no_milestone": ["en": "A quote or a cancelled job has no update to send.",
          "ar": "لا يوجد تحديث لإرساله لعرض سعر أو طلب ملغى."],
        "mac.wab_r_token_locked": ["en": "The access token could not be opened on this Mac. Enter it again in Settings › Integrations.",
          "ar": "تعذّر فتح رمز الوصول على هذا الماك. أدخله مرة أخرى في الإعدادات ‹ التكاملات."],
        "mac.wab_r_unreachable": ["en": "Meta could not be reached. Check the internet connection.",
          "ar": "تعذّر الوصول إلى Meta. تحقق من اتصال الإنترنت."],
        "mac.wab_r_failed": ["en": "Meta did not accept the message.",
          "ar": "لم تقبل Meta الرسالة."],
        "mac.wab_r_bad_phone_number_id": ["en": "The phone number ID should be digits only.",
          "ar": "يجب أن يكون معرّف رقم الهاتف أرقاماً فقط."],
        "mac.wab_r_bad_token": ["en": "Meta did not accept the access token. It may have expired: paste a permanent one in Settings › Integrations.",
          "ar": "لم تقبل Meta رمز الوصول، وقد يكون منتهياً: الصق رمزاً دائماً في الإعدادات ‹ التكاملات."],
        "mac.wab_r_bad_recipient": ["en": "The customer's number cannot be used on WhatsApp.",
          "ar": "لا يمكن استخدام رقم العميل على واتساب."],
        "mac.wab_r_bad_template": ["en": "The template name is not one WhatsApp allows.",
          "ar": "اسم القالب غير مسموح في واتساب."],
        "mac.wab_r_bad_language": ["en": "The template language is not one of Meta's codes.",
          "ar": "لغة القالب ليست من رموز Meta."],
        "mac.wab_r_no_message_id": ["en": "Meta answered without a message id, so the message cannot be followed.",
          "ar": "ردّت Meta دون معرّف للرسالة، فلا يمكن تتبعها."],
        "mac.wab_r_no_permission": ["en": "The token is not allowed to send from this number. Give the system user the WhatsApp permissions in Meta Business Settings.",
          "ar": "الرمز غير مخوّل بالإرسال من هذا الرقم. امنح مستخدم النظام صلاحيات واتساب في إعدادات Meta للأعمال."],
        "mac.wab_r_bad_request": ["en": "Meta refused the request. Check the phone number ID.",
          "ar": "رفضت Meta الطلب. تحقق من معرّف رقم الهاتف."],
        "mac.wab_r_rate_limited": ["en": "WhatsApp is limiting how fast this number sends. Try again in a few minutes.",
          "ar": "يحدّ واتساب من سرعة الإرسال لهذا الرقم. حاول بعد دقائق."],
        "mac.wab_r_account_restricted": ["en": "Meta has restricted this WhatsApp Business account. Check WhatsApp Manager.",
          "ar": "قيّدت Meta حساب واتساب للأعمال هذا. راجع WhatsApp Manager."],
        "mac.wab_r_payment_problem": ["en": "Meta needs a payment method on this WhatsApp Business account.",
          "ar": "تحتاج Meta وسيلة دفع على حساب واتساب للأعمال هذا."],
        "mac.wab_r_not_on_whatsapp": ["en": "The customer's number is not on WhatsApp, or cannot receive this message.",
          "ar": "رقم العميل ليس على واتساب، أو لا يستطيع استلام هذه الرسالة."],
        "mac.wab_r_recipient_not_allowed": ["en": "Meta's test number can only write to numbers on its allowed list. Add the customer there, or use your real number.",
          "ar": "رقم Meta التجريبي لا يراسل إلا الأرقام في قائمته المسموحة. أضف العميل إليها أو استخدم رقمك الحقيقي."],
        "mac.wab_r_outside_window": ["en": "WhatsApp refused a message outside a template.",
          "ar": "رفض واتساب رسالة من خارج قالب."],
        "mac.wab_r_template_params": ["en": "The template's variables do not match what Khayt sends. Check the order shown in Settings › Integrations.",
          "ar": "متغيرات القالب لا تطابق ما يرسله خيط. راجع الترتيب المعروض في الإعدادات ‹ التكاملات."],
        "mac.wab_r_template_missing": ["en": "WhatsApp has no approved template with this name in this language.",
          "ar": "لا يوجد في واتساب قالب معتمد بهذا الاسم وبهذه اللغة."],
        "mac.wab_r_template_rejected": ["en": "Meta rejected this template's text.",
          "ar": "رفضت Meta نص هذا القالب."],
        "mac.wab_r_template_paused": ["en": "Meta has paused this template. Check its quality in WhatsApp Manager.",
          "ar": "أوقفت Meta هذا القالب مؤقتاً. راجع جودته في WhatsApp Manager."],
        "mac.wab_r_template_disabled": ["en": "Meta has disabled this template.",
          "ar": "عطّلت Meta هذا القالب."],
        "mac.wab_r_number_not_registered": ["en": "This phone number is not registered with the WhatsApp Cloud API yet.",
          "ar": "رقم الهاتف هذا غير مسجّل في واجهة واتساب السحابية بعد."],
        "mac.wab_r_unavailable": ["en": "WhatsApp is not answering right now. Try again shortly.",
          "ar": "واتساب لا يستجيب حالياً. حاول بعد قليل."],
        // Settings › Online › Khayt Cloud plan (`CloudPlanSettings`). The beta
        // sentences restate khaytapp.com/terms §4 "Plans during the beta":
        // tell the website lane before changing them.
        "mac.vp_release_changed": ["en": "The files changed while this was open: another device uploaded a version or restored a file. Check the list again, then confirm.", "ar": "تغيّرت الملفات أثناء فتح هذه النافذة: رفع جهاز آخر نسخة أو استعاد ملفاً. راجع القائمة مجدداً ثم أكّد."],
        "mac.plan_title": ["en": "Khayt Cloud plan", "ar": "خطة سحابة خيط"],
        "mac.plan_current": ["en": "Current plan", "ar": "الخطة الحالية"],
        "mac.plan_free_price": ["en": "Free", "ar": "مجاناً"],
        "mac.plan_name_free": ["en": "Free", "ar": "المجانية"],
        "mac.plan_per_month": ["en": "{price} a month", "ar": "{price} شهرياً"],
        "mac.plan_per_year": ["en": "{price} a year", "ar": "{price} سنوياً"],
        "mac.plan_vat_included": ["en": "Prices include VAT.", "ar": "الأسعار شاملة ضريبة القيمة المضافة."],
        "mac.plan_vault": ["en": "Vault {size}", "ar": "خزنة \u{2068}{size}\u{2069}"],
        "mac.plan_links": ["en": "{n} share links", "ar": "\u{2068}{n}\u{2069} رابط مشاركة"],
        "mac.plan_links_one": ["en": "{n} share link", "ar": "رابط مشاركة واحد"],
        "mac.plan_links_two": ["en": "{n} share links", "ar": "رابطا مشاركة"],
        "mac.plan_links_few": ["en": "{n} share links", "ar": "\u{2068}{n}\u{2069} روابط مشاركة"],
        "mac.plan_no_links": ["en": "no share links", "ar": "بلا روابط مشاركة"],
        "mac.plan_selling": ["en": "selling on makerrun.com", "ar": "البيع عبر makerrun.com"],
        "mac.plan_seats": ["en": "team up to {n}", "ar": "فريق حتى \u{2068}{n}\u{2069}"],
        "mac.plan_upgrade": ["en": "Upgrade", "ar": "ترقية"],
        "mac.plan_move": ["en": "Move to this plan", "ar": "الانتقال إلى هذه الخطة"],
        "mac.plan_move_title": ["en": "Move to {plan}?", "ar": "الانتقال إلى {plan}؟"],
        "mac.plan_move_confirm": ["en": "Move", "ar": "انتقال"],
        "mac.plan_beta_free": ["en": "Free during the beta. When the beta ends you have {days} days to start paying, or the shop moves back to Free. Over Free’s limits the vault becomes read-only; if it still holds too much {lapse} days later, files are deleted until it fits (Khayt emails you the date first).",
          "ar": "مجاناً أثناء النسخة التجريبية. وحين تنتهي يكون لديك {days} يوماً لبدء الدفع، وإلا تعود المطبعة إلى الخطة المجانية. وتصبح الخزنة للقراءة فقط فيما يتجاوز حدود الخطة المجانية؛ فإن بقيت تحوي أكثر من اللازم بعد {lapse} يوماً، حُذفت ملفات حتى تتّسع (ويراسلك خيط بالتاريخ أولاً)."],
        "mac.plan_grace_until": ["en": "The beta has ended. This plan stays until {day}; start paying before then, or the shop moves back to Free. Over Free’s limits the vault then becomes read-only, and files still over the limit {lapse} days later are deleted.",
          "ar": "انتهت النسخة التجريبية. تبقى هذه الخطة حتى {day}؛ ابدأ الدفع قبل ذلك، وإلا تعود المطبعة إلى الخطة المجانية. وتصبح الخزنة حينها للقراءة فقط فيما يتجاوز حدودها، وتُحذف الملفات التي تبقى زائدة بعد {lapse} يوماً."],
        // khaytapp.com/terms §4 says the same (website lane, Oct 25 2026). `{days}`
        // is 90, passed as a number so the Mac's digit setting applies.
        "mac.plan_move_down_note": ["en": "If the vault holds more than this plan allows, it becomes read-only: downloads and existing links keep working, but uploads, new share links and product changes stop. Khayt emails you a date {days} days ahead; if the vault still holds too much then, files are deleted until it fits.",
          "ar": "إن كانت الخزنة تحوي أكثر مما تسمح به هذه الخطة، صارت للقراءة فقط: يبقى التنزيل وروابط المشاركة الموجودة تعمل، لكن يتوقف الرفع وإنشاء روابط مشاركة جديدة وتعديل المنتجات. ويراسلك خيط بالبريد بتاريخ بعد {days} يوماً؛ فإن بقيت الخزنة حينها تحوي أكثر من اللازم، حُذفت ملفات حتى تتّسع."],
        "mac.plan_move_down_selling": ["en": "This plan has no selling: products can’t be made, changed or released, and they leave makerrun.com. Sales of products already released still deliver, and paid buyers keep their links.",
          "ar": "لا تشمل هذه الخطة البيع: فلا يمكن إنشاء المنتجات ولا تعديلها ولا طرحها للبيع، وتُزال من makerrun.com. وتبقى مبيعات المنتجات المطروحة سابقاً تُسلَّم، ويحتفظ المشترون الذين دفعوا بروابطهم."],
        // A vault over its plan after a move down (`Shop+VaultLapse.swift`,
        // khayt-cloud #143). The order is the cloud's own.
        "mac.lapse_over": ["en": "Your vault holds {size} more than this plan allows, so it is read-only.",
          "ar": "تحوي خزنتك {size} أكثر مما تسمح به هذه الخطة، لذا صارت للقراءة فقط."],
        "mac.lapse_over_since": ["en": "Your vault holds {size} more than this plan allows, so it has been read-only since {date}.",
          "ar": "تحوي خزنتك {size} أكثر مما تسمح به هذه الخطة، لذا صارت للقراءة فقط منذ {date}."],
        "mac.lapse_delete_on": ["en": "Files over the limit will be deleted on {date} ({days}).",
          "ar": "ستُحذف الملفات الزائدة عن الحد في {date} ({days})."],
        "mac.lapse_days": ["en": "{n} days", "ar": "{n} يوماً"],
        "mac.lapse_days_one": ["en": "{n} day", "ar": "يوم واحد"],
        "mac.lapse_days_two": ["en": "{n} days", "ar": "يومان"],
        "mac.lapse_days_few": ["en": "{n} days", "ar": "{n} أيام"],
        "mac.lapse_today": ["en": "today", "ar": "اليوم"],
        "mac.lapse_vault_only": ["en": "The only copy of {models} is in the vault: Free Up Space moved them off this Mac. If the vault deletes them, no copy is left anywhere.",
          "ar": "النسخة الوحيدة من {models} موجودة في الخزنة: نقلها «توفير المساحة» من هذا الماك. إذا حذفتها الخزنة فلن تبقى منها أي نسخة."],
        "mac.lapse_bring_back_before": ["en": "Bring back {models} before {date}", "ar": "أعد {models} قبل {date}"],
        "mac.lapse_bring_back_read_only": ["en": "Bring back {models} while the vault is read-only",
          "ar": "أعد {models} ما دامت الخزنة للقراءة فقط"],
        "mac.lapse_bring_back": ["en": "Bring Back {models}", "ar": "أعد {models}"],
        "mac.lapse_bringing_back": ["en": "Bringing back {done} of {total}\u{2026}", "ar": "تجري إعادة {done} من {total}\u{2026}"],
        "mac.lapse_deleting_now": ["en": "Files over the limit are being deleted now (the date was {date}).",
          "ar": "تُحذف الآن الملفات الزائدة عن الحد (كان موعدها {date})."],
        "mac.lapse_what": ["en": "Downloads and existing links keep working. New share links and product changes are paused.",
          "ar": "يبقى التنزيل والروابط الموجودة تعمل، لكن إنشاء روابط مشاركة جديدة وتعديل المنتجات متوقف."],
        "mac.lapse_order": ["en": "If the vault still holds too much, files are deleted until it fits, in this order: Trash, then old versions, then files in no product, then product files nobody has bought, and files buyers hold last — the least recently changed first in each.",
          "ar": "إن بقيت الخزنة تحوي أكثر من اللازم، حُذفت ملفات حتى تتّسع، بهذا الترتيب: سلة المهملات، ثم النسخ القديمة، ثم الملفات التي لا تنتمي إلى أي منتج، ثم ملفات المنتجات التي لم يشترها أحد، وأخيراً الملفات التي يملكها المشترون — ويُبدأ في كلٍّ منها بالأقدم تعديلاً."],
        "mac.lapse_fix": ["en": "To get back under the limit, upgrade or delete files: emptying Trash, removing old versions and deleting files or products all still work.",
          "ar": "للعودة ضمن الحد، يمكنك ترقية الخطة أو حذف ملفات: فإفراغ سلة المهملات وإزالة النسخ القديمة وحذف الملفات أو المنتجات كلها ما زالت تعمل."],
        "mac.vault_over_err": ["en": "Your shop is over its plan's storage, so new share links and product changes are paused. Upgrade or delete files.",
          "ar": "تجاوزت مطبعتك مساحة التخزين في خطتها، لذا توقف إنشاء روابط المشاركة الجديدة وتعديل المنتجات. يمكنك ترقية الخطة أو حذف ملفات."],
        "mac.plan_owner_only": ["en": "Only the shop’s owner can change the plan.", "ar": "لا يغيّر الخطة إلا مالك المطبعة."],
        "mac.plan_opens_soon": ["en": "Upgrades open soon.", "ar": "تُتاح الترقية قريباً."],
        "mac.plan_beta_over": ["en": "The beta has ended, so free upgrades are closed.", "ar": "انتهت النسخة التجريبية، فلم تعد الترقية المجانية متاحة."],
        "mac.plan_paid": ["en": "This shop pays for its plan, so it can’t move to a free beta plan.", "ar": "تدفع هذه المطبعة لخطتها، فلا يمكن نقلها إلى خطة تجريبية مجانية."],
        "mac.plan_unavailable": ["en": "Khayt Cloud can’t change plans for this shop right now.", "ar": "لا تستطيع سحابة خيط تغيير خطة هذه المطبعة الآن."],
        "mac.plan_sign_in": ["en": "Sign in to Khayt Cloud to see your plan.", "ar": "سجّل الدخول إلى سحابة خيط لترى خطتك."],
        // Settings › Online › Team and Devices (`TeamSettings`).
        "mac.team_title": ["en": "Team", "ar": "الفريق"],
        "mac.team_role_owner": ["en": "Owner", "ar": "المالك"],
        "mac.team_role_manager": ["en": "Manager", "ar": "مدير"],
        "mac.team_role_operator": ["en": "Operator", "ar": "مشغّل"],
        "mac.team_role_viewer": ["en": "Viewer", "ar": "مشاهد"],
        "mac.team_unverified": ["en": "invite not accepted yet", "ar": "لم تُقبل الدعوة بعد"],
        "mac.team_email": ["en": "Email address", "ar": "البريد الإلكتروني"],
        "mac.team_invite": ["en": "Invite", "ar": "دعوة"],
        "mac.team_invite_hint": ["en": "They get a code by email that lasts 7 days. A viewer can read the shop but not change it — use one for a store's server.", "ar": "يصلهم رمز بالبريد صالح 7 أيام. يستطيع المشاهد قراءة بيانات المطبعة دون تغييرها — استخدمه لخادم المتجر."],
        "mac.team_invited": ["en": "Invited {email}. The code is on its way by email.", "ar": "تمت دعوة {email}. الرمز في طريقه بالبريد."],
        "mac.team_invited_no_mail": ["en": "Invited {email}, but Khayt Cloud could not send the email. Ask them to sign up with this address.", "ar": "تمت دعوة {email}، لكن سحابة خيط لم تتمكن من إرسال البريد. اطلب منهم التسجيل بهذا العنوان."],
        "mac.team_remove": ["en": "Remove", "ar": "إزالة"],
        "mac.team_remove_title": ["en": "Remove this member?", "ar": "إزالة هذا العضو؟"],
        "mac.team_remove_body": ["en": "{email} loses access now, and every device signed in with that account is signed out.", "ar": "يفقد {email} الوصول الآن، ويُسجَّل خروج كل جهاز دخل بذلك الحساب."],
        "mac.team_not_allowed": ["en": "Only the shop’s owner or a manager can do that.", "ar": "لا يفعل ذلك إلا مالك المطبعة أو مدير."],
        "mac.team_sign_in": ["en": "Sign in to Khayt Cloud to see your team.", "ar": "سجّل الدخول إلى سحابة خيط لترى فريقك."],
        "mac.devices_title": ["en": "Signed-in devices", "ar": "الأجهزة المسجّل دخولها"],
        "mac.devices_explain": ["en": "Every key that can reach this shop on Khayt Cloud, and when it was last used. Sign out any you don’t recognise.", "ar": "كل مفتاح يصل إلى هذه المطبعة في سحابة خيط، ومتى استُخدم آخر مرة. سجّل خروج أي مفتاح لا تعرفه."],
        "mac.devices_shop_key": ["en": "The shop’s own key", "ar": "مفتاح المطبعة نفسه"],
        "mac.devices_owner": ["en": "Owner", "ar": "المالك"],
        "mac.devices_since": ["en": "since {day}", "ar": "منذ {day}"],
        "mac.devices_last_used": ["en": "last used {day}", "ar": "آخر استخدام {day}"],
        "mac.devices_never_used": ["en": "never used", "ar": "لم يُستخدم"],
        "mac.devices_this_mac": ["en": "This Mac", "ar": "هذا الماك"],
        "mac.devices_sign_out": ["en": "Sign Out", "ar": "تسجيل الخروج"],
        "mac.devices_sign_out_title": ["en": "Sign this device out?", "ar": "تسجيل خروج هذا الجهاز؟"],
        "mac.devices_sign_out_body": ["en": "Its key stops working at once. To use Khayt Cloud again it has to sign in.", "ar": "يتوقف مفتاحه عن العمل فوراً. ولاستخدام سحابة خيط مجدداً عليه تسجيل الدخول."],
        "mac.vault_title": ["en": "Khayt Vault",
          "ar": "خزنة خيط"],
        "mac.vault_pitch": ["en": "Keep the library's online copy in your Khayt Vault. Each model is encrypted on this Mac before it is uploaded, with a key Khayt Cloud never holds, so Khayt cannot open it. Your other Macs signed in to this shop open it with the same cloud passphrase, and you can share models by private link.",
          "ar": "احفظ النسخة الإلكترونية من المكتبة في خزنة خيط. يُشفَّر كل نموذج على هذا الماك قبل رفعه، بمفتاح لا تملكه سحابة خيط أبداً، فلا يستطيع خيط فتحه. وتفتحها أجهزة الماك الأخرى المسجّلة في هذا المتجر بعبارة مرور السحابة نفسها، ويمكنك مشاركة النماذج برابط خاص."],
        "mac.vault_use": ["en": "Use the Khayt Vault",
          "ar": "استخدام خزنة خيط"],
        "mac.vault_switch_note": ["en": "Models already in your Google Drive or bucket stay there. New copies go to the vault, and “Back up the whole library now” copies the rest.",
          "ar": "النماذج الموجودة في Google Drive أو الحاوية تبقى هناك. تذهب النسخ الجديدة إلى الخزنة، وزر «انسخ المكتبة كلها الآن» ينسخ الباقي."],
        "mac.vault_in_use": ["en": "Your library is in your Khayt Vault",
          "ar": "مكتبتك في خزنة خيط"],
        "mac.vault_in_use_why": ["en": "Encrypted on this Mac before it leaves. Khayt Cloud stores only what it cannot read.",
          "ar": "مشفّرة على هذا الماك قبل أن تغادره. لا تخزّن سحابة خيط إلا ما لا تستطيع قراءته."],
        "mac.vault_locked": ["en": "Khayt Cloud is locked on this Mac, so nothing is copied to the vault. Unlock it with your cloud passphrase.",
          "ar": "سحابة خيط مقفلة على هذا الماك، فلا يُنسخ شيء إلى الخزنة. افتحها بعبارة مرور السحابة."],
        "mac.vault_stop": ["en": "Stop Using the Vault",
          "ar": "التوقف عن استخدام الخزنة"],
        "mac.vault_stop_title": ["en": "Stop keeping the library's copy in the vault?",
          "ar": "التوقف عن حفظ نسخة المكتبة في الخزنة؟"],
        "mac.vault_stop_body": ["en": "Nothing is deleted: what is in the vault stays there, and models moved there can still be brought back. New models are not copied anywhere until you choose another place.",
          "ar": "لن يُحذف شيء: ما في الخزنة يبقى فيها، ويمكن استرجاع النماذج المنقولة إليها. ولن تُنسخ النماذج الجديدة إلى أي مكان حتى تختار مكاناً آخر."],
        "mac.vault_now_used": ["en": "The library now keeps its copy in your Khayt Vault.",
          "ar": "أصبحت المكتبة تحفظ نسختها في خزنة خيط."],
        "mac.vault_no_longer_used": ["en": "The library no longer copies to the vault.",
          "ar": "لم تعد المكتبة تنسخ إلى الخزنة."],
        "mac.vault_kept_both": ["en": "The vault’s copy of “{name}” is not the one on this Mac. Both are kept: the vault’s is beside yours as “{copy}”. Choose one, and the other goes to the Trash.",
          "ar": "نسخة الخزنة من «\u{2068}{name}\u{2069}» ليست النسخة التي على هذا الماك. حُفظت النسختان، ونسخة الخزنة بجانب نسختك باسم «\u{2068}{copy}\u{2069}». اختر إحداهما، وتذهب الأخرى إلى سلة المهملات."],
        "mac.vault_keep_mine": ["en": "Keep This Mac’s",
          "ar": "الإبقاء على نسخة هذا الماك"],
        "mac.vault_keep_mine_help": ["en": "The vault’s copy goes to the Trash.",
          "ar": "تذهب نسخة الخزنة إلى سلة المهملات."],
        "mac.vault_use_vaults": ["en": "Use the Vault’s",
          "ar": "استخدام نسخة الخزنة"],
        "mac.vault_use_vaults_help": ["en": "This Mac’s copy goes to the Trash.",
          "ar": "تذهب نسخة هذا الماك إلى سلة المهملات."],
        "mac.vault_more_kept": ["en": "And {n} more models with both copies kept.",
          "ar": "ونماذج أخرى حُفظت نسختاها: {n}."],
        "mac.li_figures_stale": ["en": "Out of date: a newer version came from another Mac. These figures are the old file’s until it is measured again.",
          "ar": "قديمة: وصل إصدار أحدث من ماك آخر. هذه الأرقام للملف القديم حتى يُقاس من جديد."],
        "mac.figures_stale_reason": ["en": "The slicer’s figures are an older version’s, so these are an estimate, not measured.",
          "ar": "أرقام برنامج التقطيع لنسخة أقدم من الملف، لذا هذه تقديرات وليست قياساً."],
        "mac.vp_products": ["en": "Products",
          "ar": "المنتجات"],
        "mac.vp_sell": ["en": "Sell as a Product",
          "ar": "بيعه كمنتج"],
        "mac.vp_title": ["en": "Products for sale",
          "ar": "منتجات للبيع"],
        "mac.vp_explain": ["en": "List vault files for sale on makerrun.com. Buyers pay at your own checkout. Khayt and makerrun never take the payment or a fee, and once your provider confirms a sale, the buyer gets their link even while this Mac is asleep.",
          "ar": "اعرض ملفات الخزنة للبيع على makerrun.com. يدفع المشترون في صفحة الدفع الخاصة بك، ولا يتسلّم خيط ولا makerrun الدفعة ولا يأخذان رسوماً. وحين يؤكد مزوّد الدفع البيع، يصل المشتري رابطه ولو كان هذا الماك نائماً."],
        "mac.vp_none": ["en": "No products yet. Choose models in the library and pick Sell as a Product, or press New Product.",
          "ar": "لا توجد منتجات بعد. اختر نماذج في المكتبة ثم «بيعه كمنتج»، أو اضغط «منتج جديد»."],
        "mac.vp_new": ["en": "New Product",
          "ar": "منتج جديد"],
        "mac.vp_new_title": ["en": "New product",
          "ar": "منتج جديد"],
        "mac.vp_edit_title": ["en": "Edit product",
          "ar": "تعديل المنتج"],
        "mac.vp_edit": ["en": "Edit",
          "ar": "تعديل"],
        "mac.vp_release": ["en": "Release",
          "ar": "طرح"],
        "mac.vp_buyers": ["en": "Buyers",
          "ar": "المشترون"],
        "mac.vp_remove": ["en": "Remove Product",
          "ar": "إزالة المنتج"],
        "mac.vp_remove_title": ["en": "Remove this product?",
          "ar": "إزالة هذا المنتج؟"],
        "mac.vp_remove_body": ["en": "Its listing goes from makerrun for good and the files are no longer on sale. Buyers who already paid keep their links. Your vault files are not deleted.",
          "ar": "تُزال صفحته من makerrun نهائياً ولا تعود الملفات معروضة للبيع. يحتفظ المشترون الذين دفعوا بروابطهم، ولا تُحذف ملفات خزنتك."],
        "mac.vp_unpublished": ["en": "Hidden",
          "ar": "مخفي"],
        "mac.vp_listable": ["en": "On makerrun",
          "ar": "على makerrun"],
        "mac.vp_not_listable": ["en": "Not listable",
          "ar": "غير قابل للعرض"],
        "mac.vp_n_files": ["en": "{n} files",
          "ar": "{n} ملفات"],
        "mac.vp_n_files_n1": ["en": "1 file",
          "ar": "ملف واحد"],
        "mac.vp_n_files_n2": ["en": "2 files",
          "ar": "ملفان"],
        "mac.vp_not_released": ["en": "not released yet",
          "ar": "لم يُطرح بعد"],
        "mac.vp_released_on": ["en": "released {day}",
          "ar": "طُرح في {day}"],
        "mac.vp_n_unreleased": ["en": "{n} added since, not on sale yet",
          "ar": "{n} أُضيفت بعدها ولم تُطرح بعد"],
        "mac.vp_n_unreleased_n1": ["en": "1 added since, not on sale yet",
          "ar": "واحد أُضيف بعدها ولم يُطرح بعد"],
        "mac.vp_makerrun_connected": ["en": "Connected as “{name}”.",
          "ar": "متصل باسم «{name}»."],
        "mac.vp_makerrun_disconnect": ["en": "Disconnect makerrun",
          "ar": "فصل makerrun"],
        "mac.vp_makerrun_how": ["en": "Not connected. Connect from makerrun.com: it asks for your owner or manager email and a code Khayt Cloud sends you.",
          "ar": "غير متصل. اتصل من makerrun.com: سيطلب بريد المالك أو المدير ورمزاً ترسله لك سحابة خيط."],
        "mac.vp_public_note": ["en": "Everything here except the files is public: makerrun shows it to anyone.",
          "ar": "كل ما هنا عدا الملفات عام: يعرضه makerrun لأي أحد."],
        "mac.vp_title_en": ["en": "Title (English)",
          "ar": "العنوان (بالإنجليزية)"],
        "mac.vp_title_ar": ["en": "Title (Arabic)",
          "ar": "العنوان (بالعربية)"],
        "mac.vp_desc_en": ["en": "Description (English)",
          "ar": "الوصف (بالإنجليزية)"],
        "mac.vp_desc_ar": ["en": "Description (Arabic)",
          "ar": "الوصف (بالعربية)"],
        "mac.vp_kind": ["en": "Sold as",
          "ar": "يُباع كـ"],
        "mac.vp_kind_paid": ["en": "One-time purchase",
          "ar": "شراء لمرة واحدة"],
        "mac.vp_kind_members": ["en": "Members",
          "ar": "للأعضاء"],
        "mac.vp_provider": ["en": "Checkout",
          "ar": "الدفع عبر"],
        "mac.vp_checkout": ["en": "Checkout link",
          "ar": "رابط الدفع"],
        "mac.vp_provider_id": ["en": "Product ID at the provider",
          "ar": "معرّف المنتج لدى المزوّد"],
        "mac.vp_provider_id_hint": ["en": "Lets a sale from Stripe, Lemon Squeezy or Gumroad deliver itself: the ID your provider gives this product.",
          "ar": "يجعل البيع من Stripe أو Lemon Squeezy أو Gumroad يُسلَّم تلقائياً: المعرّف الذي يعطيه مزوّدك لهذا المنتج."],
        "mac.vp_price": ["en": "Price shown",
          "ar": "السعر المعروض"],
        "mac.vp_licence": ["en": "Licence",
          "ar": "الترخيص"],
        "mac.vp_lic_personal": ["en": "Personal use",
          "ar": "استخدام شخصي"],
        "mac.vp_lic_commercial": ["en": "Commercial use",
          "ar": "استخدام تجاري"],
        "mac.vp_lic_ccby": ["en": "Creative Commons BY 4.0",
          "ar": "المشاع الإبداعي BY 4.0"],
        "mac.vp_lic_ccbync": ["en": "Creative Commons BY-NC 4.0",
          "ar": "المشاع الإبداعي BY-NC 4.0"],
        "mac.vp_lic_other": ["en": "Other",
          "ar": "أخرى"],
        "mac.vp_lic_name": ["en": "Licence name",
          "ar": "اسم الترخيص"],
        "mac.vp_files": ["en": "Files",
          "ar": "الملفات"],
        "mac.vp_files_hint": ["en": "Vault files in this product. Only the owner sees this list. Saving does not put anything on sale: Release does.",
          "ar": "ملفات الخزنة في هذا المنتج. لا يرى هذه القائمة إلا المالك. الحفظ لا يعرض شيئاً للبيع، بل «طرح»."],
        "mac.vp_delivery": ["en": "Each buyer's link",
          "ar": "رابط كل مشترٍ"],
        "mac.vp_n_downloads": ["en": "{n} downloads",
          "ar": "{n} تنزيلات"],
        "mac.vp_n_downloads_n1": ["en": "1 download",
          "ar": "تنزيل واحد"],
        "mac.vp_n_downloads_n2": ["en": "2 downloads",
          "ar": "تنزيلان"],
        "mac.vp_per_file": ["en": "for each file",
          "ar": "لكل ملف"],
        "mac.vp_valid_for": ["en": "Ends after",
          "ar": "ينتهي بعد"],
        "mac.vp_delivery_hint": ["en": "A download limit counts downloads through the link. It cannot stop a buyer keeping or copying a file they downloaded.",
          "ar": "حد التنزيل يحسب التنزيلات عبر الرابط، ولا يمنع المشتري من الاحتفاظ بملف نزّله أو نسخه."],
        "mac.vp_previews": ["en": "Pictures",
          "ar": "الصور"],
        "mac.vp_n_previews": ["en": "{n} pictures",
          "ar": "{n} صور"],
        "mac.vp_n_previews_n1": ["en": "1 picture",
          "ar": "صورة واحدة"],
        "mac.vp_n_previews_n2": ["en": "2 pictures",
          "ar": "صورتان"],
        "mac.vp_add_preview": ["en": "Add Picture",
          "ar": "إضافة صورة"],
        "mac.vp_clear_previews": ["en": "Remove All",
          "ar": "إزالة الكل"],
        "mac.vp_previews_hint": ["en": "JPEG or PNG, up to 2 MB, at most 8. Khayt Cloud removes location and camera details before anyone sees them.",
          "ar": "صور بصيغة JPEG أو PNG، حتى 2 ميغابايت، وثماني صور كحد أقصى. تزيل سحابة خيط بيانات الموقع والكاميرا قبل أن يراها أحد."],
        "mac.vp_hide": ["en": "Hide from makerrun for now",
          "ar": "إخفاؤه عن makerrun مؤقتاً"],
        "mac.vp_need_title": ["en": "Give it a title in English or Arabic.",
          "ar": "أعطه عنواناً بالإنجليزية أو العربية."],
        "mac.vp_need_checkout": ["en": "Add the https link to your checkout.",
          "ar": "أضف رابط https لصفحة الدفع."],
        "mac.vp_need_files": ["en": "Choose at least one file.",
          "ar": "اختر ملفاً واحداً على الأقل."],
        "mac.vp_need_licence": ["en": "Name the licence.",
          "ar": "اكتب اسم الترخيص."],
        "mac.vp_release_title": ["en": "Release for sale",
          "ar": "الطرح للبيع"],
        "mac.vp_release_list": ["en": "Khayt Cloud will be able to read exactly these files, at these versions:",
          "ar": "ستتمكن سحابة خيط من قراءة هذه الملفات بالضبط، بهذه النسخ:"],
        "mac.vp_version": ["en": "version {v}",
          "ar": "النسخة {v}"],
        "mac.vp_missing": ["en": "{n} files in the listing are no longer in the vault and are left out.",
          "ar": "{n} من ملفات القائمة لم تعد في الخزنة، فاستُبعدت."],
        "mac.vp_missing_n1": ["en": "1 file in the listing is no longer in the vault and is left out.",
          "ar": "ملف واحد من القائمة لم يعد في الخزنة، فاستُبعد."],
        "mac.vp_release_promise": ["en": "A version you have released stays readable by Khayt Cloud while it is stored and is either still on sale or reachable through a buyer’s link. Deleting the file ends both. Stopping a sale protects only later versions, and buyers who have already paid keep their access unless you revoke it.",
          "ar": "النسخة التي طرحتها تبقى مقروءة لسحابة خيط ما دامت مخزّنة وما زالت معروضة للبيع أو يمكن الوصول إليها عبر رابط أحد المشترين. وحذف الملف ينهي الأمرين معاً. وإيقاف البيع لا يحمي إلا النسخ اللاحقة، ويحتفظ المشترون الذين دفعوا بإمكانية الوصول ما لم تُلغها."],
        "mac.vp_dropping": ["en": "{n} files on sale before are not in the listing now. Buyers who have them lose them from their links.",
          "ar": "{n} ملفات كانت معروضة للبيع ليست في القائمة الآن، وسيفقدها المشترون من روابطهم."],
        "mac.vp_dropping_n1": ["en": "1 file on sale before is not in the listing now. Buyers who have it lose it from their links.",
          "ar": "ملف كان معروضاً للبيع ليس في القائمة الآن، وسيفقده المشترون من روابطهم."],
        "mac.vp_licence_doubt": ["en": "{n} of these files were downloaded or carry a licence that may not let you sell the file itself. A licence to sell prints rarely covers selling the file. Check before you release:",
          "ar": "{n} من هذه الملفات منزّلة من الإنترنت أو يحمل ترخيصًا قد لا يسمح لك ببيع الملف نفسه. ترخيص بيع المطبوعات نادرًا ما يشمل بيع الملف. تحقّق قبل الطرح:"],
        "mac.vp_licence_doubt_n1": ["en": "One of these files was downloaded or carries a licence that may not let you sell the file itself. A licence to sell prints rarely covers selling the file. Check before you release:",
          "ar": "أحد هذه الملفات منزّل من الإنترنت أو يحمل ترخيصًا قد لا يسمح لك ببيع الملف نفسه. ترخيص بيع المطبوعات نادرًا ما يشمل بيع الملف. تحقّق قبل الطرح:"],
        "mac.vp_release_confirm": ["en": "Release for Sale",
          "ar": "طرح للبيع"],
        "mac.vp_release_confirm_drop": ["en": "Release and Take Those Out",
          "ar": "طرح وإزالة تلك الملفات"],
        "mac.vp_released": ["en": "Released: {n} files are on sale.",
          "ar": "تم الطرح: {n} ملفات معروضة للبيع."],
        "mac.vp_buyers_updated": ["en": "{n} buyers' links now hold these versions.",
          "ar": "روابط {n} من المشترين تحمل الآن هذه النسخ."],
        "mac.vp_buyers_updated_n1": ["en": "1 buyer's link now holds these versions.",
          "ar": "رابط مشترٍ واحد يحمل الآن هذه النسخ."],
        "mac.vp_buyers_title": ["en": "Buyers",
          "ar": "المشترون"],
        "mac.vp_no_buyers": ["en": "No buyers yet.",
          "ar": "لا يوجد مشترون بعد."],
        "mac.vp_buyer_line": ["en": "{provider} · order {order} · {used} downloads",
          "ar": "الطلب {order} · {used} تنزيلات · {provider}"],
        "mac.vp_status_paid": ["en": "Paid",
          "ar": "مدفوع"],
        "mac.vp_status_refunded": ["en": "Refunded",
          "ar": "مسترد"],
        "mac.vp_status_revoked": ["en": "Revoked",
          "ar": "ملغى"],
        "mac.vp_add_buyer": ["en": "Deliver by hand",
          "ar": "التسليم يدوياً"],
        "mac.vp_add_buyer_hint": ["en": "For a sale your provider cannot report, such as a bank transfer: Khayt Cloud emails the buyer their own link. The same order number twice delivers once.",
          "ar": "لبيع لا يستطيع مزوّدك الإبلاغ عنه، كالتحويل البنكي: ترسل سحابة خيط للمشتري رابطه الخاص بالبريد. ورقم الطلب نفسه مرتين يُسلَّم مرة واحدة."],
        "mac.vp_order_ref": ["en": "Order number (optional)",
          "ar": "رقم الطلب (اختياري)"],
        "mac.vp_note": ["en": "Note (optional)",
          "ar": "ملاحظة (اختيارية)"],
        "mac.vp_deliver": ["en": "Send the Buyer Their Link",
          "ar": "إرسال الرابط للمشتري"],
        "mac.vp_delivered": ["en": "Sent. The buyer gets an email with their link.",
          "ar": "أُرسل. سيصل المشتري بريد فيه رابطه."],
        "mac.vp_already_delivered": ["en": "That order was delivered before. Nothing was sent again.",
          "ar": "سُلِّم هذا الطلب من قبل، ولم يُرسل شيء مرة أخرى."],
        "mac.vp_revoke_title": ["en": "Revoke this buyer's link?",
          "ar": "إلغاء رابط هذا المشتري؟"],
        "mac.vp_revoke_body": ["en": "The link stops working at once and cannot be turned back on. Refund the buyer at your provider if that is due.",
          "ar": "يتوقف الرابط فوراً ولا يمكن إعادته. أعد المبلغ للمشتري لدى مزوّدك إن كان ذلك مستحقاً."],
        "mac.vp_hooks": ["en": "Sales that deliver themselves",
          "ar": "مبيعات تُسلَّم تلقائياً"],
        "mac.vp_hooks_hint": ["en": "Give your payment provider the address below, so each sale and refund reaches Khayt Cloud. The secret is shown nowhere after you save it.",
          "ar": "أعطِ مزوّد الدفع العنوان أدناه ليصل كل بيع واسترداد إلى سحابة خيط. لا يظهر السر في أي مكان بعد حفظه."],
        "mac.vp_hook_secret": ["en": "Signing secret",
          "ar": "سر التوقيع"],
        "mac.vp_hook_gumroad_ph": ["en": "Leave empty to have one made",
          "ar": "اتركه فارغاً لإنشاء واحد"],
        "mac.vp_hook_save": ["en": "Save",
          "ar": "حفظ"],
        "mac.vp_hook_set": ["en": "Set up",
          "ar": "مُعدّ"],
        "mac.vp_hook_url": ["en": "Give your provider this address:",
          "ar": "أعطِ مزوّدك هذا العنوان:"],
        "mac.vp_hook_url_once": ["en": "Give Gumroad this address now. It holds the secret and is not shown again:",
          "ar": "أعطِ Gumroad هذا العنوان الآن، فهو يحمل السر ولن يظهر مرة أخرى:"],
        "mac.vp_err_cloud": ["en": "Khayt Cloud refused: {why}",
          "ar": "رفضت سحابة خيط: {why}"],
        "mac.vp_err_preview_big": ["en": "That picture is over 2 MB.",
          "ar": "هذه الصورة أكبر من 2 ميغابايت."],
        "mac.vp_err_no_publishing": ["en": "This shop's plan does not include selling.",
          "ar": "خطة هذا المتجر لا تشمل البيع."],
        "mac.vp_err_products_full": ["en": "This shop has 500 products, the most a shop can have.",
          "ar": "لدى هذا المتجر 500 منتج، وهو الحد الأقصى."],
        "mac.vp_err_removed": ["en": "This product was removed.",
          "ar": "أُزيل هذا المنتج."],
        "mac.vp_err_provider_product_taken": ["en": "Another product already uses that product ID at this provider.",
          "ar": "منتج آخر يستخدم معرّف المنتج هذا لدى المزوّد نفسه."],
        "mac.vp_err_checkout_host": ["en": "That checkout link is not the provider chosen. Choose the right provider, or Other.",
          "ar": "رابط الدفع هذا لا يعود للمزوّد المختار. اختر المزوّد الصحيح أو «أخرى»."],
        "mac.vp_err_bad_checkout_url": ["en": "That is not a checkout link Khayt can use: https only, with no user name or port.",
          "ar": "هذا ليس رابط دفع يمكن لخيط استخدامه: https فقط، دون اسم مستخدم أو منفذ."],
        "mac.vp_err_unknown_items": ["en": "{n} files are no longer in the vault.",
          "ar": "{n} ملفات لم تعد في الخزنة."],
        "mac.vp_err_not_in_product": ["en": "{n} files are not in this product. Save the listing first.",
          "ar": "{n} ملفات ليست في هذا المنتج. احفظ القائمة أولاً."],
        "mac.vp_err_bad_release": ["en": "Khayt Cloud could not open a released file. Nothing was put on sale.",
          "ar": "لم تستطع سحابة خيط فتح ملف مطروح، فلم يُعرض شيء للبيع."],
        "mac.vp_err_release_drops_file": ["en": "Buyers still hold {n} files this release leaves out. Release again to take them out on purpose.",
          "ar": "ما زال المشترون يحملون {n} ملفات يستبعدها هذا الطرح. اطرح مرة أخرى لإزالتها عن قصد."],
        "mac.vp_err_publish_off": ["en": "Selling is not switched on at Khayt Cloud yet.",
          "ar": "البيع غير مفعّل في سحابة خيط بعد."],
        "mac.vp_err_not_released": ["en": "Release the product first: there is nothing to deliver yet.",
          "ar": "اطرح المنتج أولاً، فلا يوجد ما يُسلَّم بعد."],
        "mac.vp_err_mail_off": ["en": "Khayt Cloud cannot send email right now, so it cannot send the buyer their link.",
          "ar": "لا تستطيع سحابة خيط إرسال البريد الآن، فلا يمكنها إرسال الرابط للمشتري."],
        "mac.vp_err_links_disabled": ["en": "Khayt has turned off this shop's links, so nothing can be delivered.",
          "ar": "أوقف خيط روابط هذا المتجر، فلا يمكن تسليم شيء."],
        "mac.vp_err_role": ["en": "Only the shop's owner or a manager can release files for sale.",
          "ar": "لا يطرح الملفات للبيع إلا مالك المتجر أو مديره."],
        "mac.vp_err_unknown_product": ["en": "Khayt Cloud has no such product.",
          "ar": "لا يوجد هذا المنتج في سحابة خيط."],
        "mac.vp_err_unknown_buyer": ["en": "That buyer's link is not part of this product.",
          "ar": "رابط هذا المشتري ليس جزءاً من هذا المنتج."],
        "mac.vp_err_previews_full": ["en": "A product has at most 8 pictures.",
          "ar": "للمنتج 8 صور كحد أقصى."],
        "mac.vp_err_unknown_previews": ["en": "A picture changed on another device. Close and open the product again.",
          "ar": "تغيّرت صورة على جهاز آخر. أغلق المنتج وافتحه مرة أخرى."],
        "mac.vp_err_bad_secret": ["en": "That is not a signing secret this provider gives (Stripe's begin with whsec_).",
          "ar": "هذا ليس سر توقيع يعطيه هذا المزوّد (أسرار Stripe تبدأ بـ whsec_)."],
        "mac.vp_prov_salla": ["en": "Salla",
          "ar": "سلة"],
        "mac.vp_prov_zid": ["en": "Zid",
          "ar": "زد"],
        "mac.vp_prov_moyasar": ["en": "Moyasar",
          "ar": "ميسّر"],
        "mac.vp_prov_medusa": ["en": "Your own store",
          "ar": "متجرك الخاص"],
        "mac.vp_prov_other": ["en": "Other",
          "ar": "أخرى"],
        "mac.vp_prov_manual": ["en": "By hand",
          "ar": "يدوياً"],
        "mac.replace_edited_message": ["en": "Replace what you have typed?",
                                       "ar": "استبدال ما كتبته؟"],
        "mac.replace":        ["en": "Replace",        "ar": "استبدال"],

        "mac.reading_file":   ["en": "Reading the file…", "ar": "جارٍ قراءة الملف…"],
        // The library's grouping menu.
        "mac.pick_a_model":  ["en": "Select a model first", "ar": "اختر نموذجًا أولًا"],
        "mac.new_group":     ["en": "New Group\u{2026}", "ar": "مجموعة جديدة\u{2026}"],
        "mac.remove_from_group": ["en": "Remove from Group", "ar": "إزالة من المجموعة"],
        "mac.delete_n_models": ["en": "Delete {n} Models", "ar": "حذف {n} نماذج"],
        "mac.delete_from_mac": ["en": "Remove from This Mac", "ar": "إزالة من هذا الماك"],
        "mac.delete_only_here_too": ["en": "Remove, and Delete the {n} Only on This Mac", "ar": "إزالة، مع حذف ما لا يوجد إلا على هذا الماك ({n})"],
        "mac.delete_only_here_too_n1": ["en": "Remove, and Delete the One Only on This Mac", "ar": "إزالة، مع حذف الواحد الذي لا يوجد إلا على هذا الماك"],
        "mac.delete_completely": ["en": "Delete Completely from Library", "ar": "حذف نهائي من المكتبة"],
        "mac.delete_choose_one": ["en": "What should happen to \u{201C}{name}\u{201D}?", "ar": "ماذا تريد أن تفعل بـ\u{201C}{name}\u{201D}؟"],
        "mac.delete_choose_many": ["en": "What should happen to these {n} models?", "ar": "ماذا تريد أن تفعل بهذه النماذج ({n})؟"],
        "mac.delete_choose_many_n1": ["en": "What should happen to this model?", "ar": "ماذا تريد أن تفعل بهذا النموذج؟"],
        "mac.delete_checking": ["en": "Checking which have an online copy\u{2026}", "ar": "جارٍ التحقق مما له نسخة على الإنترنت\u{2026}"],
        // The question's lines are COUNTED (`Words.counting`), with a `_single`
        // form for the one-model question: "1 have an online copy" was what a
        // single delete said, in both languages (Oct 2026 review).
        "mac.delete_kept_online": ["en": "{n} have an online copy. Remove from This Mac deletes only the file here; they stay in the library as online models you can download again.", "ar": "لـ{n} منها نسخة على الإنترنت. «إزالة من هذا الماك» تحذف الملف الموجود هنا فقط، وتبقى في المكتبة نماذجَ على الإنترنت يمكنك تنزيلها مجددًا."],
        "mac.delete_kept_online_n1": ["en": "One has an online copy. Remove from This Mac deletes only the file here; it stays in the library as an online model you can download again.", "ar": "لواحد منها نسخة على الإنترنت. «إزالة من هذا الماك» تحذف ملفه الموجود هنا فقط، ويبقى في المكتبة نموذجًا على الإنترنت يمكنك تنزيله مجددًا."],
        "mac.delete_kept_online_n2": ["en": "Two have an online copy. Remove from This Mac deletes only the file here; they stay in the library as online models you can download again.", "ar": "لاثنين منها نسخة على الإنترنت. «إزالة من هذا الماك» تحذف ملفيهما الموجودين هنا فقط، ويبقيان في المكتبة على الإنترنت يمكنك تنزيلهما مجددًا."],
        "mac.delete_kept_online_single": ["en": "This model has an online copy. Remove from This Mac deletes only the file here; it stays in the library as an online model you can download again.", "ar": "لهذا النموذج نسخة على الإنترنت. «إزالة من هذا الماك» تحذف ملفه الموجود هنا فقط، ويبقى في المكتبة نموذجًا على الإنترنت يمكنك تنزيله مجددًا."],
        "mac.delete_cloud_only": ["en": "{n} are online only, with nothing on this Mac: only Delete Completely removes them.", "ar": "{n} منها على الإنترنت فقط ولا شيء منها على هذا الماك: لا يزيلها إلا «الحذف النهائي»."],
        "mac.delete_cloud_only_n1": ["en": "One is online only, with nothing on this Mac: only Delete Completely removes it.", "ar": "واحد منها على الإنترنت فقط ولا شيء منه على هذا الماك: لا يزيله إلا «الحذف النهائي»."],
        "mac.delete_cloud_only_n2": ["en": "Two are online only, with nothing on this Mac: only Delete Completely removes them.", "ar": "اثنان منها على الإنترنت فقط ولا شيء منهما على هذا الماك: لا يزيلهما إلا «الحذف النهائي»."],
        "mac.delete_cloud_only_single": ["en": "This model is online only, with nothing on this Mac: only Delete Completely removes it.", "ar": "هذا النموذج على الإنترنت فقط ولا شيء منه على هذا الماك: لا يزيله إلا «الحذف النهائي»."],
        "mac.delete_only_here": ["en": "{n} of these {total} are only on this Mac — deleting them removes them for good.", "ar": "{n} من هذه الـ{total} لا توجد إلا على هذا الماك — حذفها يزيلها نهائيًا."],
        "mac.delete_only_here_n1": ["en": "One of these {total} is only on this Mac — deleting it removes it for good.", "ar": "واحد من هذه الـ{total} لا يوجد إلا على هذا الماك — حذفه يزيله نهائيًا."],
        "mac.delete_only_here_n2": ["en": "Two of these {total} are only on this Mac — deleting them removes them for good.", "ar": "اثنان من هذه الـ{total} لا يوجدان إلا على هذا الماك — حذفهما يزيلهما نهائيًا."],
        "mac.delete_only_here_all": ["en": "None of these has an online copy — deleting them removes them for good.", "ar": "ليس لأيٍّ منها نسخة على الإنترنت — حذفها يزيلها نهائيًا."],
        "mac.delete_only_here_single": ["en": "This model is only on this Mac — deleting it removes it for good.", "ar": "هذا النموذج لا يوجد إلا على هذا الماك — حذفه يزيله نهائيًا."],
        "mac.delete_in_place": ["en": "{n} are files in your own folders: only their library entry is removed, never the file.", "ar": "{n} منها ملفات في مجلداتك أنت: يُزال قيدها من المكتبة فقط، ولا يُمسّ الملف أبدًا."],
        "mac.delete_in_place_n1": ["en": "One is a file in your own folder: only its library entry is removed, never the file.", "ar": "واحد منها ملف في مجلدك أنت: يُزال قيده من المكتبة فقط، ولا يُمسّ الملف أبدًا."],
        "mac.delete_in_place_n2": ["en": "Two are files in your own folders: only their library entry is removed, never the file.", "ar": "اثنان منها ملفان في مجلداتك أنت: يُزال قيدهما من المكتبة فقط، ولا يُمسّ الملفان أبدًا."],
        "mac.delete_in_place_single": ["en": "This model is a file in your own folder: only its library entry is removed, never the file.", "ar": "هذا النموذج ملف في مجلدك أنت: يُزال قيده من المكتبة فقط، ولا يُمسّ الملف أبدًا."],
        "mac.delete_completely_says": ["en": "Delete Completely also deletes the online copies of {n} of them.", "ar": "«الحذف النهائي» يحذف أيضًا النسخ الموجودة على الإنترنت لـ{n} منها."],
        "mac.delete_completely_says_n1": ["en": "Delete Completely also deletes the online copy of one of them.", "ar": "«الحذف النهائي» يحذف أيضًا النسخة الموجودة على الإنترنت لواحد منها."],
        "mac.delete_completely_says_n2": ["en": "Delete Completely also deletes the online copies of two of them.", "ar": "«الحذف النهائي» يحذف أيضًا النسخ الموجودة على الإنترنت لاثنين منها."],
        "mac.delete_completely_says_single": ["en": "Delete Completely also deletes its online copy.", "ar": "«الحذف النهائي» يحذف أيضًا نسخته الموجودة على الإنترنت."],
        "mac.delete_hand_placed": ["en": "That includes {n} files you put in the bucket yourself.", "ar": "ومن بينها ملفات وضعتها أنت في التخزين السحابي، عددها {n}."],
        "mac.delete_hand_placed_n1": ["en": "That includes one file you put in the bucket yourself.", "ar": "ومن بينها ملف وضعته أنت في التخزين السحابي."],
        "mac.delete_hand_placed_n2": ["en": "That includes two files you put in the bucket yourself.", "ar": "ومن بينها ملفان وضعتهما أنت في التخزين السحابي."],
        "mac.delete_hand_placed_single": ["en": "It is a file you put in the bucket yourself.", "ar": "وهو ملف وضعته أنت في التخزين السحابي."],
        "mac.delete_local_done": ["en": "{n} removed from this Mac and kept online; {gone} removed from the library.", "ar": "أُزيل {n} من هذا الماك وبقيت على الإنترنت؛ وأُزيل {gone} من المكتبة."],
        "mac.delete_online_failed": ["en": "The online copy of {n} could not be deleted, so they were kept — in the library and online:", "ar": "تعذّر حذف النسخة على الإنترنت لـ{n}، فأُبقيت — في المكتبة وعلى الإنترنت:"],
        "mac.delete_many_title": ["en": "Delete {n} models?", "ar": "حذف {n} نموذجًا؟"],
        "mac.delete_many_title_one": ["en": "Delete {n} model?", "ar": "حذف نموذج واحد؟"],
        "mac.delete_many_title_two": ["en": "Delete {n} models?", "ar": "حذف نموذجين؟"],
        "mac.delete_many_title_few": ["en": "Delete {n} models?", "ar": "حذف {n} نماذج؟"],
        "mac.delete_n_confirm": ["en": "{n} models and their files go to the Trash, and out of the library.", "ar": "ستُنقل {n} نماذج وملفاتها إلى سلة المهملات، وتُحذف من المكتبة."],
        "mac.deleted_n_models": ["en": "{n} models deleted.", "ar": "حُذفت {n} نماذج."],
        "mac.delete_and_more": ["en": "and {n} more", "ar": "و{n} غيرها"],
        "mac.delete_in_groups": ["en": "{n} of these are filed in a group: {groups}.", "ar": "{n} منها محفوظة ضمن مجموعة: {groups}."],
        "mac.delete_vault_gone": ["en": "Some of these are gone from the vault, but another Mac may still have their files. Deleting them takes them out of the library on every Mac.",
          "ar": "بعض هذه النماذج حُذفت من الخزنة، لكن قد تكون ملفاتها على ماك آخر. حذفها يزيلها من المكتبة على كل أجهزة ماك."],
        "mac.delete_not_on_screen": ["en": "Nothing was deleted: {n} of the chosen models are not on screen (inside a group, or hidden by a search or filter). Select only the models you can see.", "ar": "لم يُحذف شيء: {n} من النماذج المختارة غير ظاهرة على الشاشة (داخل مجموعة، أو مخفية ببحث أو تصفية). اختر النماذج الظاهرة فقط."],
        // Counted (`Words.counting`): "1 of the chosen models IS not on
        // screen" in English; Arabic says one and two in words.
        "mac.delete_not_on_screen_one": ["en": "Nothing was deleted: {n} of the chosen models is not on screen (inside a group, or hidden by a search or filter). Select only the models you can see.", "ar": "لم يُحذف شيء: نموذج واحد من النماذج المختارة غير ظاهر على الشاشة (داخل مجموعة، أو مخفي ببحث أو تصفية). اختر النماذج الظاهرة فقط."],
        "mac.delete_not_on_screen_two": ["en": "Nothing was deleted: {n} of the chosen models are not on screen (inside a group, or hidden by a search or filter). Select only the models you can see.", "ar": "لم يُحذف شيء: نموذجان من النماذج المختارة غير ظاهرين على الشاشة (داخل مجموعة، أو مخفيان ببحث أو تصفية). اختر النماذج الظاهرة فقط."],
        "mac.deleted_n_models_one": ["en": "{n} model deleted.", "ar": "حُذف نموذج واحد."],
        "mac.deleted_n_models_two": ["en": "{n} models deleted.", "ar": "حُذف نموذجان."],
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
        // A group made legible: the slash flattened, the tile, the note.
        "mac.group_slash_flattened": ["en": "Will be filed as \u{201C}{name}\u{201D} \u{2014} a slash would make a group inside a group.",
                                      "ar": "سيُحفظ باسم \u{00AB}{name}\u{00BB} \u{2014} الشرطة المائلة تصنع مجموعة داخل مجموعة."],
        "mac.group_tile_a11y": ["en": "Group {name}: {kind}, {models}", "ar": "مجموعة {name}: {kind}، {models}"],
        "mac.group_tile_parts": ["en": "One print",    "ar": "طباعة واحدة"],
        "mac.group_tile_collection": ["en": "Collection", "ar": "طباعات منفصلة"],
        "mac.group_in_parent": ["en": "in {name}", "ar": "في {name}"],
        "mac.n_parts":       ["en": "{n} parts",       "ar": "{n} جزءًا"],
        "mac.n_parts_few":   ["en": "{n} parts",       "ar": "{n} أجزاء"],
        "mac.n_parts_one":   ["en": "{n} part",        "ar": "جزء واحد"],
        "mac.n_parts_two":   ["en": "{n} parts",       "ar": "جزآن"],
        "mac.group_kind_parts": ["en": "One print in parts", "ar": "طباعة واحدة من أجزاء"],
        "mac.group_kind_collection": ["en": "Separate prints", "ar": "طباعات منفصلة"],
        "mac.group_kind_menu": ["en": "This Group Is", "ar": "نوع المجموعة"],
        // A group's own picture, instead of the first model's.
        "mac.group_picture_set": ["en": "Set Group Picture…", "ar": "تعيين صورة المجموعة…"],
        "mac.group_picture_use_model": ["en": "Use a Model’s Picture", "ar": "استخدام صورة نموذج"],
        "mac.group_picture_remove": ["en": "Remove Group Picture", "ar": "إزالة صورة المجموعة"],
        "mac.group_picture_choose": ["en": "Use as Group Picture", "ar": "استخدامها صورةً للمجموعة"],
        "mac.group_kind_hint": ["en": "In All models, a print in parts shows as one tile; separate prints show one by one.",
                                "ar": "في «كل النماذج» تظهر الطباعة ذات الأجزاء بطاقةً واحدة، وتظهر الطباعات المنفصلة كلٌّ على حدة."],
        "mac.open_group":    ["en": "Open the group {name}", "ar": "افتح مجموعة {name}"],
        "mac.show_group":    ["en": "Show Group",      "ar": "اعرض المجموعة"],
        "mac.filed_in_group": ["en": "Filed {models} in {name}.", "ar": "{models} في {name} الآن."],
        // ── THE DASHBOARD THE DESIGN SPEC DESCRIBES ──────────────────────
        "mac.owed": ["en": "Owed", "ar": "مستحق"],
        "mac.net_income": ["en": "Net income", "ar": "صافي الدخل"],
        // A print's time left, in the shop's language (was "33m" in Arabic).
        "mac.dur_hm":        ["en": "{h}h {m}m", "ar": "{h} س {m} د"],
        "mac.dur_m":         ["en": "{m}m",      "ar": "{m} د"],
        "mac.dur_under_1m":  ["en": "<1m",       "ar": "أقل من دقيقة"],
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
        "mac.days_over": ["en": "{n} days over", "ar": "متأخر {n} يومًا"],
        "mac.days_over_one": ["en": "{n} day over", "ar": "متأخر يومًا واحدًا"],
        "mac.days_over_two": ["en": "2 days over", "ar": "متأخر يومين"],
        "mac.days_over_few": ["en": "{n} days over", "ar": "متأخر {n} أيام"],
        "mac.past_its_date": ["en": "Past its due date", "ar": "تجاوز تاريخ التسليم"],
        "mac.grams_left": ["en": "{n} g left", "ar": "بقي {n} غ"],
        "mac.out_of_stock": ["en": "None left on the shelf", "ar": "لا شيء على الرف"],
        "mac.needs_a_look": ["en": "Needs a look", "ar": "يحتاج فحصًا"],
        "mac.untitled": ["en": "Untitled", "ar": "بلا عنوان"],
        "mac.untitled_print": ["en": "Untitled print", "ar": "طباعة بلا عنوان"],
        "mac.own_print": ["en": "Own print", "ar": "طباعة خاصة"],
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
        "mac.pane_model": ["en": "Model", "ar": "النموذج"],
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
                + "themselves; what is left here is waiting for you. Quote "
                + "requests from your website's form arrive here too: import one "
                + "to make a quote, or delete it.",
            "ar": "الطلبات التي أرسلها متجرك إلى خيط. يُقارن كل طلب بالرف "
                + "أولًا — فما هو مطبوع مسبقًا بيعٌ لا عملٌ جديد. طلبات المتجر "
                + "المدفوعة تصبح أعمالًا تلقائيًا، وما بقي هنا ينتظرك. وتصل هنا "
                + "أيضًا طلبات التسعير من نموذج موقعك: استوردها لتصبح عروض أسعار، "
                + "أو احذفها.",
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
        // The first-run setup — `ShopSetupSheet`.
        "mac.setup_menu": ["en": "Set up your shop", "ar": "جهّز متجرك"],
        "mac.setup_step": ["en": "Step {n} of {total}", "ar": "الخطوة {n} من {total}"],
        "mac.setup_not_now": ["en": "Not now", "ar": "ليس الآن"],
        "mac.setup_try_sample": ["en": "Try the sample shop instead", "ar": "جرّب المتجر التجريبي بدلًا من ذلك"],
        "mac.setup_back": ["en": "Back", "ar": "رجوع"],
        "mac.setup_skip": ["en": "Skip", "ar": "تخطَّ"],
        "mac.setup_continue": ["en": "Continue", "ar": "متابعة"],
        "mac.setup_save": ["en": "Save and finish", "ar": "احفظ وأنهِ"],
        "mac.setup_start_book": ["en": "Start my book", "ar": "ابدأ دفتري"],
        "mac.setup_close": ["en": "Close", "ar": "إغلاق"],
        "mac.setup_saved": ["en": "Your shop is set up.", "ar": "تم تجهيز متجرك."],
        "mac.setup_shop_title": ["en": "Your shop", "ar": "متجرك"],
        "mac.setup_shop_why": ["en": "Three answers every price starts from. Leave any of them blank — nothing here is required, and nothing is saved until the last step.",
                               "ar": "ثلاث إجابات يبدأ منها كل سعر. اترك أيًّا منها فارغًا — لا شيء هنا إلزامي، ولا يُحفظ شيء قبل الخطوة الأخيرة."],
        "mac.setup_shop_why_new": ["en": "There is no book on this Mac yet, so you are looking at the sample shop. Answer what you like; the last step starts your own book with it.",
                                   "ar": "لا يوجد دفتر على هذا الماك بعد، لذا فأنت ترى المتجر التجريبي. أجب عمّا تشاء، وستبدأ الخطوة الأخيرة دفترك الخاص بإجاباتك."],
        "mac.setup_electricity": ["en": "Electricity", "ar": "الكهرباء"],
        "mac.setup_per_kwh": ["en": "{mark} per kWh", "ar": "{mark} لكل كيلوواط ساعة"],
        "mac.setup_electricity_hint": ["en": "From your bill. Saved as the shop’s electricity price: every job, quote and failed print is costed at it unless a calculator preset says otherwise.",
                                       "ar": "من فاتورتك. يُحفظ كسعر الكهرباء للمتجر: تُحسب به كل الأعمال وعروض الأسعار والطباعات الفاشلة ما لم يحدد إعداد في الحاسبة غير ذلك."],
        "mac.setup_preset_name": ["en": "Shop rates", "ar": "أسعار المتجر"],
        "mac.set_running_costs": ["en": "Running costs", "ar": "تكاليف التشغيل"],
        "mac.set_elec_rate": ["en": "Electricity per kWh", "ar": "الكهرباء لكل كيلوواط ساعة"],
        "mac.set_elec_rate_hint": ["en": "What a kWh costs the shop, from your bill. Every job, quote and failed print is costed at it unless a calculator preset sets its own. Blank means Khayt’s {rate}.",
                                   "ar": "ما يكلّفه الكيلوواط ساعة على المتجر، من فاتورتك. تُحسب به كل الأعمال وعروض الأسعار والطباعات الفاشلة ما لم يحدد إعداد في الحاسبة سعره الخاص. الفارغ يعني {rate} الافتراضي في خيط."],
        "mac.setup_vat": ["en": "VAT", "ar": "ضريبة القيمة المضافة"],
        "mac.setup_vat_on": ["en": "I charge VAT", "ar": "أفرض ضريبة القيمة المضافة"],
        "mac.setup_printer_title": ["en": "Your printer", "ar": "طابعتك"],
        "mac.setup_printer_why": ["en": "Pick the model and Khayt fills in its power. What it cost and how long it should last become a wear cost on every print hour.",
                                  "ar": "اختر الطراز وسيملأ خيط قدرتها. ما كلّفته والمدة المتوقعة لعمرها يتحوّلان إلى تكلفة استهلاك لكل ساعة طباعة."],
        "mac.setup_printer_hint": ["en": "Expected life is in print hours here, and 5,000 is a careful guess for most desktop printers. The machine’s Value tab opens in the same print hours, and can switch the life to years if you prefer.",
                                   "ar": "العمر المتوقع هنا بساعات الطباعة، و5000 ساعة تقدير حذر لمعظم الطابعات المكتبية. يفتح تبويب القيمة في الآلة بساعات الطباعة نفسها، ويمكنه تحويل العمر إلى سنوات إن فضّلت."],
        "mac.setup_filament_title": ["en": "Your filament", "ar": "خيطك"],
        "mac.setup_filament_why": ["en": "What a typical spool costs you. It goes on the shelf as your first spool, and a job’s plastic is costed from it.",
                                   "ar": "كم تكلّفك البكرة المعتادة. توضع على الرف كأول بكرة لديك، وتُحسب منها تكلفة الخيط في كل عمل."],
        "mac.setup_material": ["en": "Material", "ar": "المادة"],
        "mac.setup_per_kg": ["en": "{price} per kg", "ar": "{price} لكل كغ"],
        "mac.setup_filament_hint": ["en": "Add the rest of your shelf from Inventory when you are ready.",
                                    "ar": "أضف بقية رفّك من المخزون عندما تكون جاهزًا."],
        "mac.setup_finish_title": ["en": "Ready", "ar": "جاهز"],
        "mac.setup_finish_why": ["en": "This is what will be saved:", "ar": "هذا ما سيُحفظ:"],
        "mac.setup_finish_nothing": ["en": "Nothing to save — every step was left empty or skipped.",
                                     "ar": "لا شيء للحفظ — تُركت كل الخطوات فارغة أو تم تخطيها."],
        "mac.setup_finish_hint": ["en": "You can come back to this any time from the Book menu.",
                                  "ar": "يمكنك العودة إلى هذا في أي وقت من قائمة الدفتر."],
        "mac.setup_sum_currency": ["en": "Prices in {code}", "ar": "الأسعار بعملة {code}"],
        "mac.setup_sum_vat_on": ["en": "VAT at {rate}%", "ar": "ضريبة القيمة المضافة بنسبة {rate}%"],
        "mac.setup_sum_vat_off": ["en": "No VAT", "ar": "بلا ضريبة قيمة مضافة"],
        "mac.setup_sum_electricity": ["en": "Electricity at {rate} per kWh, for the whole shop",
                                      "ar": "الكهرباء بسعر {rate} لكل كيلوواط ساعة، للمتجر كله"],
        "mac.setup_sum_printer": ["en": "{name} on the floor", "ar": "{name} في الورشة"],
        "mac.setup_sum_printer_value": ["en": "{name}, bought for {price}, expected to last {hours} print hours",
                                        "ar": "{name}، اشتُريت بـ{price}، ويُتوقع أن تعمل {hours} ساعة طباعة"],
        "mac.setup_sum_filament": ["en": "A spool of {material} at {price}", "ar": "بكرة {material} بسعر {price}"],
        // Why Finish did not save, in a sentence — it showed Swift's own
        // `String(describing:)` of the error before (alpha.56 review).
        "mac.setup_err_exists": ["en": "There is already a book on this Mac, so a new one was not started. None of your answers were saved.",
                                 "ar": "يوجد دفتر على هذا الماك بالفعل، فلم يُبدأ دفتر جديد. لم تُحفظ أي من إجاباتك."],
        "mac.setup_err_start": ["en": "Khayt could not start a book on this Mac — its folder could not be written. None of your answers were saved.",
                                "ar": "تعذّر على خيط بدء دفتر على هذا الماك — لم تمكن الكتابة في مجلده. لم تُحفظ أي من إجاباتك."],
        "mac.setup_err_not_ours": ["en": "Another copy of Khayt has the book open, and it owns the book while it runs. Close it, then try again. None of your answers were saved.",
                                   "ar": "نسخة أخرى من خيط تفتح الدفتر، وهي تملكه ما دامت تعمل. أغلقها ثم حاول مجددًا. لم تُحفظ أي من إجاباتك."],
        "mac.setup_err_too_large": ["en": "The book is too large to change safely. None of your answers were saved.",
                                    "ar": "الدفتر أكبر من أن يُعدَّل بأمان. لم تُحفظ أي من إجاباتك."],
        "mac.setup_err_unreadable": ["en": "Khayt could not read the book to change it. None of your answers were saved.",
                                     "ar": "تعذّر على خيط قراءة الدفتر لتعديله. لم تُحفظ أي من إجاباتك."],
        "mac.setup_err_other": ["en": "The setup could not be saved. None of your answers were saved — try again.",
                                "ar": "تعذّر حفظ الإعداد. لم تُحفظ أي من إجاباتك — حاول مجددًا."],
        // The Machine sheet for a laser cutter or a CNC router, which are not
        // printers: it said "Edit Printer" and "Printer name" over a laser.
        "mac.mach_edit_machine": ["en": "Edit Machine", "ar": "تعديل الآلة"],
        "mac.mach_add_machine": ["en": "+ Add Machine", "ar": "+ إضافة آلة"],
        "mac.mach_name_machine": ["en": "Machine name", "ar": "اسم الآلة"],
        "mac.mach_name_ph_machine": ["en": "e.g. xTool S1, Shapeoko 5", "ar": "مثال: xTool S1، Shapeoko 5"],
        "mac.mach_model_machine": ["en": "Machine model", "ar": "طراز الآلة"],
        "mac.mach_model_ph_machine": ["en": "The model, as its maker names it", "ar": "الطراز كما تسمّيه الشركة المصنّعة"],
        "mac.mach_model_hint_machine": ["en": "Type the model as its maker names it.",
                                        "ar": "اكتب الطراز كما تسمّيه الشركة المصنّعة."],
        "mac.dep_what_machine": ["en": "What this machine costs you in wear, per hour of work.",
                                 "ar": "ما تكلّفك هذه الآلة من استهلاك عن كل ساعة عمل."],
        // The spool's reorder fields. The unit is the word after the box, so
        // the label does not carry it a second time in brackets — and the
        // shared `inv.reorder_qty` says (كغ) in Arabic over a box in grams.
        "mac.spool_reorder_point": ["en": "Reorder when below", "ar": "أعد الطلب عند أقل من"],
        "mac.spool_reorder_qty": ["en": "Default order quantity", "ar": "كمية الطلب الافتراضية"],
        // The filament settings, for the same reason: the shared `inv.print_temp`,
        // `inv.bed_temp` and `inv.max_speed` carry (°C) / (mm/s) in brackets
        // because the other app draws no unit after the box. This sheet does
        // (`mac.celsius`, `mac.mm_s`), so the shared words said it twice.
        "mac.spool_print_temp": ["en": "Print temp", "ar": "حرارة الطباعة"],
        "mac.spool_bed_temp": ["en": "Bed temp", "ar": "حرارة السطح"],
        "mac.spool_max_speed": ["en": "Max speed", "ar": "السرعة القصوى"],
        "mac.first": ["en": "First", "ar": "أولًا"],
        "mac.then": ["en": "Then", "ar": "ثم"],
        "mac.add_a_machine": ["en": "Add a machine", "ar": "أضف آلة"],
        "mac.add_a_machine_why": ["en": "Its hourly rate is what turns a print into a cost.", "ar": "سعر الساعة هو ما يحوّل الطباعة إلى تكلفة."],
        "mac.put_a_spool": ["en": "Put a spool on the shelf", "ar": "ضع بكرة على الرف"],
        "mac.put_a_spool_why": ["en": "Weight and price per kilo. Khayt does the rest.", "ar": "الوزن وسعر الكيلو. خيط يتكفّل بالباقي."],
        "mac.take_a_job": ["en": "Take your first job", "ar": "خذ أول عمل"],
        "mac.take_a_job_why": ["en": "Or price one in the Calculator without saving it.", "ar": "أو سعّر واحدًا في الحاسبة دون حفظه."],
        "mac.open_the_sample": ["en": "Or open the sample shop — 42 jobs, 5 machines, real numbers.", "ar": "أو افتح المتجر التجريبي — 42 عملًا و5 آلات وأرقام حقيقية."],
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
        // What a machine cost and how long it should last — lib/depreciation.js.
        "mac.pane_value": ["en": "Value", "ar": "القيمة"],
        "mac.dep_title": ["en": "Depreciation", "ar": "الإهلاك"],
        "mac.dep_what": ["en": "What this printer costs you in wear, per hour of printing.",
                         "ar": "ما تكلّفك هذه الطابعة من استهلاك عن كل ساعة طباعة."],
        "mac.dep_working": ["en": "Working out the hourly figure…", "ar": "جارٍ حساب المبلغ بالساعة…"],
        "mac.dep_price": ["en": "Purchase price", "ar": "سعر الشراء"],
        "mac.dep_bought": ["en": "Bought on", "ar": "تاريخ الشراء"],
        "mac.dep_life": ["en": "Expected life", "ar": "العمر المتوقع"],
        "mac.dep_unit_hours": ["en": "print hours", "ar": "ساعة طباعة"],
        "mac.dep_unit_years": ["en": "years", "ar": "سنوات"],
        "mac.dep_residual": ["en": "Resale value", "ar": "قيمة إعادة البيع"],
        "mac.dep_method": ["en": "Spread the cost", "ar": "توزيع التكلفة"],
        "mac.dep_per_hour": ["en": "Per print hour", "ar": "لكل ساعة طباعة"],
        "mac.dep_straight": ["en": "Evenly over the years", "ar": "بالتساوي على السنوات"],
        "mac.dep_monthly_hours": ["en": "Hours a month", "ar": "ساعات في الشهر"],
        "mac.dep_per_hour_hint": [
            "en": "The price less the resale value, spread over the hours it should print. Every job on this machine is charged that much per hour.",
            "ar": "السعر ناقص قيمة إعادة البيع، موزعًا على الساعات التي يُتوقع أن تطبعها. يُحمَّل كل عمل على هذه الآلة هذا المبلغ عن كل ساعة.",
        ],
        "mac.dep_straight_hint": [
            "en": "The price less the resale value, spread evenly by month. Quotes charge the monthly amount over the hours it prints a month — the figure above, or what it has printed lately.",
            "ar": "السعر ناقص قيمة إعادة البيع، موزعًا بالتساوي على الأشهر. تُحمِّل عروض الأسعار المبلغ الشهري على ساعات الطباعة في الشهر — الرقم أعلاه، أو ما طبعته الآلة مؤخرًا.",
        ],
        "mac.dep_rate_line": ["en": "Quotes on this machine: {rate} per print hour", "ar": "عروض الأسعار على هذه الآلة: {rate} لكل ساعة طباعة"],
        "mac.dep_rate_missing": [
            "en": "Not enough to work out an hourly figure yet — add the expected life, and for a life in years the hours a month. Until then the flat wear rate is used.",
            "ar": "لا يكفي هذا لحساب مبلغ بالساعة بعد — أضف العمر المتوقع، ولعمر بالسنوات أضف ساعات الشهر. حتى ذلك الحين يُستخدم معدل الاستهلاك الثابت.",
        ],
        "mac.dep_value": ["en": "Value", "ar": "القيمة"],
        "mac.dep_book_value": ["en": "Book value", "ar": "القيمة الدفترية"],
        "mac.dep_to_date": ["en": "Depreciated so far", "ar": "الإهلاك حتى الآن"],
        "mac.dep_left": ["en": "Life left", "ar": "العمر المتبقي"],
        "mac.dep_hours_left": ["en": "{n} print hours", "ar": "{n} ساعة طباعة"],
        // Counted with `Words.counting`: Arabic says one, two, three-to-ten
        // and eleven-up differently, and "{n} شهرًا" is only the last.
        "mac.dep_months_left": ["en": "{n} months", "ar": "{n} شهرًا"],
        "mac.dep_months_left_one": ["en": "{n} month", "ar": "شهر واحد"],
        "mac.dep_months_left_two": ["en": "{n} months", "ar": "شهران"],
        "mac.dep_months_left_few": ["en": "{n} months", "ar": "{n} أشهر"],
        "mac.dep_rate": ["en": "Wear charged", "ar": "الاستهلاك المحمَّل"],
        "mac.dep_per_hour_amount": ["en": "{rate} / hour", "ar": "{rate} / ساعة"],
        "mac.dep_fully": [
            "en": "Fully depreciated. Quotes still charge its wear, to pay for the next one.",
            "ar": "مُهلكة بالكامل. تبقى عروض الأسعار تحمّل استهلاكها لتغطية الآلة التالية.",
        ],
        "mac.dep_needs_life": ["en": "Add its expected life to work this out.", "ar": "أضف عمرها المتوقع لحساب ذلك."],
        "mac.dep_needs_purchaseDate": ["en": "Add when it was bought to work this out.", "ar": "أضف تاريخ شرائها لحساب ذلك."],
        "mac.dep_needs_monthlyHours": ["en": "Add its hours a month to work out an hourly figure.", "ar": "أضف ساعات الشهر لحساب مبلغ بالساعة."],
        "mac.pnl_depreciation": ["en": "Machine depreciation", "ar": "إهلاك الآلات"],
        // The P&L TABLE's headers, short enough to fit their columns. The
        // statement and the waterfall keep the full names (`pnl.waste`,
        // `an.pnl_vat`); a column header is a label, not the line's name.
        "mac.pnl_col_cogs": ["en": "Cost of goods", "ar": "تكلفة البضاعة"],
        "mac.pnl_col_waste": ["en": "Waste", "ar": "الهدر"],
        "mac.pnl_col_labour": ["en": "Labour", "ar": "العمالة"],
        "mac.pnl_col_vat": ["en": "VAT", "ar": "الضريبة"],
        // GROSS: `marginPct` is (revenue − cost of goods) / revenue — nothing
        // else is taken off it — so "Margin" beside a net income read as the
        // net margin it is not.
        //
        // SHORT, because the table has 10pt to spare at 1,320 × 760 (its ideals
        // must fit beside the totals — `ColumnWidthsTests.pnlIdealsFit`), and
        // "Gross margin" / «الهامش الإجمالي» came out "Gross…" / «الهامش الإ…»
        // (alpha.74 review). Every figure under it carries its own "%", and
        // «مجمل الربح» is the accountant's word for gross profit.
        "mac.pnl_col_margin": ["en": "Gross %", "ar": "مجمل الربح"],
        // The table's cost column: expenses, the monthly overhead, machine
        // depreciation and labour. NOT "Expenses", which the waterfall uses for
        // expenses alone; and not "All costs", because cost of goods and waste
        // sit in their own columns beside it.
        "mac.pnl_col_operating": ["en": "Operating costs", "ar": "تكاليف التشغيل"],
        // The net income card adds up every period in the book.
        "mac.pnl_all_time": ["en": "all time", "ar": "منذ البداية"],
        // A filed VAT return (PnlControls.swift VatSummaryCard).
        "mac.vat_unfile_title": ["en": "Mark {period} as not filed?", "ar": "هل تعلّم {period} غير مُقدَّم؟"],
        "mac.vat_unfile_message": ["en": "This forgets what you filed for {period}. Only do this if the return was not actually filed.",
                                   "ar": "هذا ينسى ما قدّمته عن {period}. لا تفعل ذلك إلا إذا لم يُقدَّم الإقرار فعلًا."],
        "mac.vat_unfile_confirm": ["en": "Mark as not filed", "ar": "علّمه غير مُقدَّم"],
        "mac.vat_refile_title": ["en": "File {period} again?", "ar": "هل تعلّم {period} مُقدَّمًا من جديد؟"],
        "mac.vat_refile_message": ["en": "Khayt kept what you filed for this period. Restore it, or record the book as it is now if you filed an amended return.",
                                   "ar": "احتفظ خيط بما قدّمته عن هذه الفترة. استعده، أو سجّل الدفتر كما هو الآن إن قدّمت إقرارًا معدَّلًا."],
        "mac.vat_refile_restore": ["en": "Restore what you filed", "ar": "استعد ما قدّمته"],
        "mac.vat_refile_fresh": ["en": "Record the book as it is now", "ar": "سجّل الدفتر كما هو الآن"],
        "mac.vat_filed_part_of": ["en": "Filed as part of {period}", "ar": "مُقدَّم ضمن {period}"],
        "mac.vat_filed_later": ["en": "{later} is filed after {period} and already corrects it. Un-file {later} first.", "ar": "الفترة {later} مُقدَّمة بعد {period} وتصحّحها بالفعل. ألغِ تقديم {later} أولًا."],
        "mac.vat_filed_overlap": ["en": "{period} overlaps {other}, which is already marked filed.",
                                  "ar": "تتداخل {period} مع {other} المُعلَّمة مُقدَّمة."],
        // A failure allowance learned from the shop's own history —
        // lib/failure-rate.js. Offered beside the field, never applied alone.
        "mac.fail_suggest": [
            "en": "Your history: {pct}% failed, based on {n} prints",
            "ar": "سجلك: فشل {pct}٪، بناءً على {n} طباعة",
        ],
        "mac.fail_use": ["en": "Use this", "ar": "استخدم هذا"],
        "mac.fail_scope_machine_material": ["en": "This machine and material, last 90 days", "ar": "هذه الآلة وهذه المادة، آخر 90 يومًا"],
        "mac.fail_scope_machine": ["en": "This machine, last 90 days", "ar": "هذه الآلة، آخر 90 يومًا"],
        "mac.fail_scope_material": ["en": "This material, last 90 days", "ar": "هذه المادة، آخر 90 يومًا"],
        "mac.fail_scope_shop": ["en": "The whole shop, last 90 days", "ar": "المحل كله، آخر 90 يومًا"],
        "mac.fail_too_few": [
            "en": "{n} prints in the last 90 days — a suggestion needs {min}.",
            "ar": "{n} طباعة في آخر 90 يومًا — يحتاج الاقتراح إلى {min}.",
        ],
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
        "mac.synced":        ["en": "synced",       "ar": "متزامن"],
        "mac.offline":       ["en": "offline",      "ar": "غير متصل"],
        "mac.saved_at":      ["en": "saved {t}",    "ar": "حُفظ {t}"],
        // The strip's save line. Its own words, not `mac.never` — that one is
        // "never PRINTED" in Arabic (لم يُطبع), and the strip read it as the
        // book never having been saved.
        "mac.not_saved_yet": ["en": "not saved yet", "ar": "لم يُحفظ بعد"],
        // The last backup is a DAY, so the strip says the day, not a time.
        "mac.saved_today":   ["en": "saved today",   "ar": "حُفظ اليوم"],
        "mac.saved_yesterday": ["en": "saved yesterday", "ar": "حُفظ أمس"],
        "mac.n_machines":    ["en": "{n} machines", "ar": "{n} آلة"],
        "mac.n_machines_two": ["en": "2 machines", "ar": "آلتان"],
        "mac.n_machines_few": ["en": "{n} machines", "ar": "{n} آلات"],
        "mac.n_machines_zero": ["en": "No machines", "ar": "لا آلات"],
        "mac.n_machines_one": ["en": "{n} machine", "ar": "آلة واحدة"],
        "mac.n_people":      ["en": "{n} people",   "ar": "{n} شخصًا"],
        "mac.n_people_two":  ["en": "2 people",     "ar": "شخصان"],
        "mac.n_people_few":  ["en": "{n} people",   "ar": "{n} أشخاص"],
        "mac.n_people_zero": ["en": "No people", "ar": "لا أحد"],
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
        "mac.price_history": ["en": "Price paid to suppliers",
                              "ar": "السعر المدفوع للموردين"],
        "mac.price_history_sub": ["en": "Per unit, the latest purchase in the log.",
                                  "ar": "لكل وحدة، آخر عملية شراء في السجل."],
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
        // Arabic counts 3–10 with the plural and 11 and over with the
        // accusative singular: "18 نماذج" read as "18 models" said wrong.
        "mac.n_models":      ["en": "{n} models",      "ar": "{n} نموذجًا"],
        "mac.n_models_one":  ["en": "{n} model",       "ar": "نموذج واحد"],
        "mac.n_models_two":  ["en": "{n} models",      "ar": "نموذجان"],
        "mac.n_models_few":  ["en": "{n} models",      "ar": "{n} نماذج"],
        "mac.n_models_zero": ["en": "No models",       "ar": "لا نماذج"],
        "mac.together":      ["en": "Together",        "ar": "مجتمعة"],
        "mac.on_disk":       ["en": "On disk",         "ar": "على القرص"],
        "mac.not_on_this_mac": ["en": "Not on this Mac", "ar": "ليست على هذا الماك"],
        "mac.group_hint":    ["en": "Select them, then choose Group above the library or right-click them.",
                              "ar": "حدّدها ثم اختر «تجميع» أعلى المكتبة أو انقر عليها بزر الفأرة الأيمن."],
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
        "mac.mpl_not_net":      ["en": "What each job consumed — its filament, expenses filed against it, and the machine's servicing. Power and rent are in the Profit & Loss, not here.",
                                 "ar": "ما استهلكه كل عمل — خيطه، والمصروفات المسجّلة عليه، وصيانة الآلة. أما الكهرباء والإيجار فهي في الأرباح والخسائر، لا هنا."],
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
        // A camera a look found: offered, never applied. The saved address
        // is the shop's, and only the owner replaces it.
        "mac.cam_offer_title": ["en": "Found a camera", "ar": "وُجدت كاميرا"],
        "mac.cam_offer_new":   ["en": "Use it for this printer? Nothing changes until you save.",
                                "ar": "استخدامها لهذه الطابعة؟ لا يتغير شيء حتى تحفظ."],
        "mac.cam_offer_replace": ["en": "It is not the address saved here, and the saved one did not answer. The saved one stays unless you use this.",
                                  "ar": "ليس هذا العنوان المحفوظ هنا، والمحفوظ لم يُجب. يبقى المحفوظ ما لم تستخدم هذا."],
        "mac.cam_offer_enable": ["en": "This is the address saved here, switched off. Switch it on?",
                                 "ar": "هذا هو العنوان المحفوظ هنا، وهو مطفأ. تشغيله؟"],
        "mac.cam_offer_paused": ["en": "Its picture is paused right now: the printer refreshes it only while its own screen or app is watching.",
                                 "ar": "صورتها متوقفة الآن: لا تحدّثها الطابعة إلا أثناء مشاهدة شاشتها أو تطبيقها."],
        "mac.cam_offer_use":   ["en": "Use this camera", "ar": "استخدم هذه الكاميرا"],
        "mac.cam_offer_not_now": ["en": "Not now", "ar": "ليس الآن"],
        "mac.cam_found_paused": ["en": "Found a camera. Its picture is paused until the printer's own screen or app watches it.",
                                 "ar": "وُجدت كاميرا. صورتها متوقفة حتى تشاهدها شاشة الطابعة أو تطبيقها."],
        "mac.cam_saved_answered": ["en": "The saved camera answered with a picture.",
                                   "ar": "أجابت الكاميرا المحفوظة بصورة."],
        "mac.cam_saved_paused": ["en": "The saved camera answered, but its picture is paused.",
                                 "ar": "أجابت الكاميرا المحفوظة، لكن صورتها متوقفة."],
        // On the tile: the last frame, dimmed, never drawn as live.
        "mac.cam_paused":      ["en": "Camera paused", "ar": "الكاميرا متوقفة"],
        // A finished job's timelapse, kept on the printer.
        "mac.timelapse_watch": ["en": "Watch timelapse", "ar": "شاهد الفيديو المتسارع"],
        "mac.timelapse_on_printer": ["en": "{size} on {machine}. It plays from the printer and is not copied into the book.",
                                     "ar": "{size} على {machine}. يُعرض من الطابعة ولا يُنسخ إلى الدفتر."],
        "mac.timelapse_gone":  ["en": "The printer did not answer, or no longer has this video.",
                                "ar": "لم تُجب الطابعة، أو لم يعد هذا الفيديو عليها."],
        "mac.timelapse_title": ["en": "Timelapse", "ar": "الفيديو المتسارع"],
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
        "mac.prints_word_one": ["en": "print",  "ar": "طبعة واحدة"],
        "mac.prints_word":     ["en": "prints", "ar": "طبعة"],
        "mac.prints_word_few": ["en": "{n} prints", "ar": "{n} طبعات"],
        "mac.prints_word_zero": ["en": "No prints", "ar": "لا طبعات"],
        // English has no dual, so its `_two` is just the plural — as every other
        // `_two` key here carries one. `counting` only reaches for this form in
        // Arabic; the English side exists so the both-languages guard means
        // what it says rather than growing an exception.
        "mac.prints_word_two": ["en": "prints", "ar": "طبعتين"],
        // A model's print count, Mac-own so Arabic can count it: the shared
        // `cat.printed_n` has one form, and drew "طُبع 9 مرة".
        "mac.printed_n":     ["en": "printed {n}×", "ar": "طُبع {n} مرة"],
        // "مرة" alone says once; "مرة واحدة" ran out of a tile's width
        // beside a group name (KING Salman, Oct 2026 capture).
        "mac.printed_n_one": ["en": "printed {n}×", "ar": "طُبع مرة"],
        "mac.printed_n_two": ["en": "printed 2×", "ar": "طُبع مرتين"],
        "mac.printed_n_few": ["en": "printed {n}×", "ar": "طُبع {n} مرات"],
        // An average in days. A whole number is counted; a fraction takes the
        // singular in Arabic ("0.7 يوم"), as a measure rather than a count.
        "mac.avg_days":      ["en": "{n} days", "ar": "{n} يومًا"],
        "mac.avg_days_one":  ["en": "{n} day", "ar": "يوم واحد"],
        "mac.avg_days_two":  ["en": "2 days", "ar": "يومان"],
        "mac.avg_days_few":  ["en": "{n} days", "ar": "{n} أيام"],
        "mac.avg_days_zero": ["en": "Under a day", "ar": "أقل من يوم"],
        "mac.avg_days_fraction": ["en": "{n} days", "ar": "{n} يوم"],
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
        // ⌘K, "Go to…" — the palette over the whole book (`GoToPalette`).
        "mac.goto":          ["en": "Go to",                "ar": "انتقال إلى"],
        "mac.goto_prompt":   ["en": "Jobs, customers, models, screens\u{2026}",
                              "ar": "الأعمال، العملاء، النماذج، الشاشات\u{2026}"],
        "mac.goto_group_screen":   ["en": "Screens and commands", "ar": "الشاشات والأوامر"],
        "mac.goto_group_job":      ["en": "Jobs",                 "ar": "الأعمال"],
        "mac.goto_group_customer": ["en": "Customers",            "ar": "العملاء"],
        "mac.goto_group_model":    ["en": "Library",              "ar": "المكتبة"],
        "mac.goto_group_product":  ["en": "Catalogue",            "ar": "الكتالوج"],
        "mac.goto_group_machine":  ["en": "Machines",             "ar": "الطابعات"],
        "mac.goto_screen":   ["en": "Screen",               "ar": "شاشة"],
        "mac.goto_command":  ["en": "Command",              "ar": "أمر"],
        "mac.goto_none":     ["en": "Nothing in the book matches", "ar": "لا شيء في الدفتر يطابق"],
        "mac.goto_loading":  ["en": "Loading the book\u{2026}",  "ar": "جارٍ تحميل الدفتر\u{2026}"],
        "mac.goto_hint":     ["en": "\u{2191}\u{2193} to move · \u{21A9} to open · esc to close",
                              "ar": "\u{2191}\u{2193} للتنقّل · \u{21A9} للفتح · esc للإغلاق"],
        "mac.quick_look":    ["en": "Quick Look",     "ar": "نظرة سريعة"],
        // The desktop widgets (`WidgetFeed`). Written into the widget's file in
        // the book's language, because the widget has no catalogue of its own.
        "mac.widget_printing":  ["en": "Printing now",          "ar": "قيد الطباعة الآن"],
        "mac.widget_idle":      ["en": "Every printer is free", "ar": "كل الطابعات متاحة"],
        "mac.widget_paused":    ["en": "Paused",                "ar": "متوقفة مؤقتًا"],
        "mac.widget_today":     ["en": "Today",                 "ar": "اليوم"],
        "mac.widget_due_today": ["en": "Due today",             "ar": "مستحقة اليوم"],
        "mac.widget_late":      ["en": "Late",                  "ar": "متأخرة"],
        "mac.widget_owed":      ["en": "Owed",                  "ar": "المستحق"],
        "mac.widget_updated":   ["en": "Updated",               "ar": "حُدّث"],
        "mac.widget_more":      ["en": "+{n} more",             "ar": "+{n} أخرى"],
        "mac.widget_filament":  ["en": "Filament low",          "ar": "خيط على وشك النفاد"],
        "mac.widget_all_stocked": ["en": "Every spool is stocked", "ar": "كل البكرات متوفرة"],
        "mac.widget_grams":     ["en": "{n} g",                 "ar": "{n} غ"],
        "mac.widget_up_next":   ["en": "Up next",               "ar": "التالي"],
        "mac.widget_queue_empty": ["en": "Nothing waiting to print", "ar": "لا شيء بانتظار الطباعة"],
        "mac.widget_urgent":    ["en": "Urgent",                "ar": "عاجل"],
        "mac.widget_glance":    ["en": "Shop at a glance",      "ar": "الورشة في لمحة"],
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
        "mac.chase_days_over": ["en": "{n}d overdue", "ar": "متأخرة {n} يومًا"],
        "mac.chase_days_over_one": ["en": "{n}d overdue", "ar": "متأخرة يومًا واحدًا"],
        "mac.chase_days_over_two": ["en": "2d overdue", "ar": "متأخرة يومين"],
        "mac.chase_days_over_few": ["en": "{n}d overdue", "ar": "متأخرة {n} أيام"],
        "mac.chase_days_over_zero": ["en": "Due today", "ar": "مستحقة اليوم"],
        "mac.chase_days_left": ["en": "expires in {n}d", "ar": "تنتهي خلال {n} يومًا"],
        "mac.chase_days_left_one": ["en": "expires in {n}d", "ar": "تنتهي خلال يوم واحد"],
        "mac.chase_days_left_two": ["en": "expires in 2d", "ar": "تنتهي خلال يومين"],
        "mac.chase_days_left_few": ["en": "expires in {n}d", "ar": "تنتهي خلال {n} أيام"],
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
        // The Printer menu holds Ready on AND Fits (stage 3a), so it is named
        // for the machine rather than for one of the two questions.
        "mac.lib_printer":     ["en": "Printer", "ar": "الطابعة"],
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
        "mac.extruder_direct": ["en": "Direct drive", "ar": "دفع مباشر"],
        "mac.extruder_bowden": ["en": "Bowden", "ar": "بودن"],
        "mac.power":         ["en": "Power",           "ar": "الطاقة"],
        "mac.address":       ["en": "Address",         "ar": "العنوان"],
        "mac.quarter_drawn": ["en": "Where {q} went",  "ar": "أين ذهب {q}"],
        "mac.quarter_1": ["en": "Q1\u{00A0}{year}", "ar": "الربع الأول {year}"],
        "mac.quarter_2": ["en": "Q2\u{00A0}{year}", "ar": "الربع الثاني {year}"],
        "mac.quarter_3": ["en": "Q3\u{00A0}{year}", "ar": "الربع الثالث {year}"],
        "mac.quarter_4": ["en": "Q4\u{00A0}{year}", "ar": "الربع الرابع {year}"],
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
        // A save the book refused, said inside the machine sheet — which now
        // stays open so nothing typed is lost.
        "mac.mach_not_saved": ["en": "The machine was not saved.", "ar": "لم تُحفظ الآلة."],
        // ── What a printer's failure says (`PrinterWatch.sentence`) ─────────
        // Reaches the Test button, the machine card and the menu bar.
        "mac.pw_handshake": ["en": "The printer refused the connection: {why}",
                             "ar": "رفضت الطابعة الاتصال: {why}"],
        "mac.pw_needs_serial": ["en": "This Bambu has no serial number yet. It is printed on the machine, and every message to it is addressed by it, so there is nothing to ask without one.",
                                "ar": "لا يوجد رقم تسلسلي لطابعة Bambu هذه بعد. الرقم مطبوع على الجهاز، وكل رسالة إليها تُوجَّه به، فلا يمكن سؤالها من دونه."],
        "mac.pw_unreadable": ["en": "The {type} printer answered with something this app could not read.",
                              "ar": "ردّت طابعة {type} بشيء لم يستطع هذا التطبيق قراءته."],
        "mac.pw_needs_mainboard": ["en": "This printer has no mainboard ID yet. It is how every message reaches it, and it is not printed on the machine — scan the network to find it.",
                                   "ar": "لا يوجد معرّف اللوحة الرئيسية لهذه الطابعة بعد. به تصل إليها كل رسالة، وهو غير مطبوع على الجهاز — افحص الشبكة للعثور عليه."],
        "mac.pw_no_host": ["en": "This machine has no address yet.", "ar": "لا يوجد عنوان لهذه الآلة بعد."],
        "mac.pw_not_lan": ["en": "{host} is not an address on this network. A printer is a machine in the workshop, so only the private ranges are allowed.",
                           "ar": "{host} ليس عنوانًا على هذه الشبكة. الطابعة جهاز داخل الورشة، لذا يُسمح بالعناوين الخاصة فقط."],
        "mac.pw_bad_port": ["en": "{port} is not a port.", "ar": "{port} ليس منفذًا صالحًا."],
        "mac.pw_redirected": ["en": "The printer sent this request somewhere else, so it was dropped.",
                              "ar": "حوّلت الطابعة هذا الطلب إلى مكان آخر، فأُلغي."],
        "mac.pw_http": ["en": "The printer's server answered {code}.", "ar": "أجاب خادم الطابعة بالرمز {code}."],
        "mac.pw_http_body": ["en": "The printer's server answered {code}: {body}.",
                             "ar": "أجاب خادم الطابعة بالرمز {code}: {body}."],
        "mac.pw_no_history": ["en": "A {type} printer does not keep a job history Khayt can read. Klipper (Moonraker) is the only one of the three that does — the rest answer nothing at all, which arrives as a 404. Khayt counts this machine's wear from the jobs in your own book instead.",
                              "ar": "طابعة {type} لا تحتفظ بسجل مهام يستطيع خيط قراءته. Klipper (Moonraker) وحدها من الثلاث تفعل ذلك — والبقية لا تجيب بشيء، فيصل ذلك على شكل 404. يحسب خيط اهتراء هذه الآلة من المهام في دفترك بدلًا من ذلك."],
        "mac.pw_no_history_any": ["en": "A printer of this kind does not keep a job history Khayt can read. Klipper (Moonraker) is the only one of the three that does — the rest answer nothing at all, which arrives as a 404. Khayt counts this machine's wear from the jobs in your own book instead.",
                                  "ar": "هذا النوع من الطابعات لا يحتفظ بسجل مهام يستطيع خيط قراءته. Klipper (Moonraker) وحدها من الثلاث تفعل ذلك — والبقية لا تجيب بشيء، فيصل ذلك على شكل 404. يحسب خيط اهتراء هذه الآلة من المهام في دفترك بدلًا من ذلك."],
        "mac.pw_not_json": ["en": "The printer's answer was not JSON.", "ar": "لم يكن ردّ الطابعة بصيغة JSON."],
        "mac.pw_timed_out": ["en": "The printer did not answer in time. It may be asleep or off the network.",
                             "ar": "لم تُجب الطابعة في الوقت المحدد. ربما هي في وضع السكون أو خارج الشبكة."],
        "mac.pw_cannot_connect": ["en": "Nothing answered at that address. Check the printer is on and on this network.",
                                  "ar": "لم يُجب شيء على هذا العنوان. تأكد أن الطابعة تعمل ومتصلة بهذه الشبكة."],
        "mac.pw_cannot_find": ["en": "That name did not resolve to anything on this network.",
                               "ar": "لم يُشِر هذا الاسم إلى أي جهاز على هذه الشبكة."],
        "mac.pw_sdcp_refused": ["en": "The printer refused: {why}", "ar": "رفضت الطابعة: {why}"],
        "mac.pw_sdcp_silent": ["en": "The printer did not answer in time. Check it is on, and that the mainboard ID is the one this machine actually has.",
                               "ar": "لم تُجب الطابعة في الوقت المحدد. تأكد أنها تعمل، وأن معرّف اللوحة الرئيسية هو معرّف هذه الآلة فعلًا."],
        "mac.pw_closed": ["en": "The printer closed the connection before answering.",
                          "ar": "أغلقت الطابعة الاتصال قبل أن تُجيب."],
        "mac.pw_conn_closed": ["en": "The connection to the printer was closed.", "ar": "أُغلق الاتصال بالطابعة."],
        "mac.pw_unreachable": ["en": "Could not reach the printer: {why}", "ar": "تعذّر الوصول إلى الطابعة: {why}"],
        "mac.pw_malformed": ["en": "The printer sent something this app could not read.",
                             "ar": "أرسلت الطابعة شيئًا لم يستطع هذا التطبيق قراءته."],
        "mac.pw_cert_changed": ["en": "The printer answered with a different certificate from the one it used before, so the access code was not sent. If the printer was replaced or reset, save its access code again on the machine sheet to trust the new one.",
                                "ar": "ردّت الطابعة بشهادة مختلفة عن التي استخدمتها من قبل، لذا لم يُرسَل رمز الوصول. إن استُبدلت الطابعة أو أُعيد ضبطها، فاحفظ رمز الوصول مجددًا في نافذة الآلة لتثق بالشهادة الجديدة."],
        "mac.pw_code_refused": ["en": "The printer refused the access code (CONNACK {code}). It is shown on the printer's own screen, in the LAN-only Mode area.",
                                "ar": "رفضت الطابعة رمز الوصول (CONNACK {code}). يظهر الرمز على شاشة الطابعة نفسها، في قسم وضع الشبكة المحلية فقط."],
        "mac.pw_bambu_silent": ["en": "The printer accepted the connection and then said nothing. That is what happens when Developer Mode is off — LAN-only Mode alone does not open MQTT. Both are in the same menu on the printer (Settings → LAN Mode, or WLAN/Network on P1 and A1).",
                                "ar": "قبلت الطابعة الاتصال ثم لم تقل شيئًا. هذا ما يحدث حين يكون وضع المطوّر (Developer Mode) مطفأً — وضع الشبكة المحلية وحده لا يفتح MQTT. كلاهما في القائمة نفسها على الطابعة (Settings ← LAN Mode، أو WLAN/Network في P1 وA1)."],
        "mac.mach_cert_unverified": ["en": "Certificate not verified by Bambu Lab. This printer is trusted because it presented the same certificate as the first time it connected.",
                                     "ar": "الشهادة غير موثّقة من Bambu Lab. هذه الطابعة موثوقة لأنها قدّمت الشهادة نفسها التي قدّمتها أول مرة اتصلت فيها."],
        "mac.pw_cert_not_bambu": ["en": "The device at this address did not present a Bambu Lab certificate, so the access code was not sent. Check the address is the printer's ({why}).",
                                  "ar": "لم يقدّم الجهاز على هذا العنوان شهادة من Bambu Lab، لذا لم يُرسَل رمز الوصول. تأكد أن العنوان هو عنوان الطابعة ({why})."],
        "mac.pw_cert_other_printer": ["en": "A different Bambu printer answered at this address (its certificate names serial {name}), so the access code was not sent. Check the address and the serial on the machine sheet.",
                                      "ar": "أجابت طابعة Bambu أخرى على هذا العنوان (شهادتها تحمل الرقم التسلسلي {name})، لذا لم يُرسَل رمز الوصول. تحقق من العنوان والرقم التسلسلي في نافذة الآلة."],
        "mac.pw_bambu_quiet": ["en": "The printer stopped sending updates for over a minute. Khayt is reconnecting.",
                               "ar": "توقفت الطابعة عن إرسال التحديثات لأكثر من دقيقة. يعيد خيط الاتصال بها."],
        "mac.pw_bambu_refused": ["en": "The printer refused the command: {why}. On firmware with Bambu's authorization control, LAN commands are accepted only while Developer Mode is on.",
                                 "ar": "رفضت الطابعة الأمر: {why}. في البرامج الثابتة التي فيها التحكم بالتفويض من Bambu، لا تُقبل أوامر الشبكة المحلية إلا ووضع المطوّر (Developer Mode) مفعّل."],
        "mac.pw_bambu_refused_bare": ["en": "The printer refused the command. On firmware with Bambu's authorization control, LAN commands are accepted only while Developer Mode is on.",
                                      "ar": "رفضت الطابعة الأمر. في البرامج الثابتة التي فيها التحكم بالتفويض من Bambu، لا تُقبل أوامر الشبكة المحلية إلا ووضع المطوّر (Developer Mode) مفعّل."],
        "mac.pw_unconfirmed": ["en": "The command was sent, but the printer did not confirm it. Check the printer before trying again.",
                               "ar": "أُرسل الأمر، لكن الطابعة لم تؤكده. تحقق من الطابعة قبل المحاولة مجددًا."],
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
        "mac.days_late":     ["en": "{n} days late",   "ar": "متأخر {n} يومًا"],
        "mac.days_late_one": ["en": "{n} day late",    "ar": "متأخر يومًا واحدًا"],
        "mac.days_late_two": ["en": "2 days late",     "ar": "متأخر يومين"],
        "mac.days_late_few": ["en": "{n} days late",   "ar": "متأخر {n} أيام"],
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
        "mac.search_models": ["en": "Model, material or tag", "ar": "نموذج أو خامة أو وسم"],
        "mac.search_people": ["en": "Customer or job", "ar": "عميل أو عمل"],
        "mac.no_job": ["en": "No job selected", "ar": "لم يُختر عمل"],
        "mac.no_job_hint": ["en": "Pick a row to see its parts and its money.", "ar": "اختر صفاً لعرض أجزائه وحسابه."],
        "mac.no_model": ["en": "No model selected", "ar": "لم يُختر نموذج"],
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
        // `settings.mcp.shareCustomerNames` — what the books tools in
        // `khayt-mcp` may say about a customer. Off unless the shop turns it on.
        "mac.mcp_share_names": ["en": "Share customer names with AI assistants (khayt-mcp)",
                                "ar": "مشاركة أسماء العملاء مع مساعدي الذكاء الاصطناعي (khayt-mcp)"],
        "mac.mcp_share_names_hint": ["en": "Off: assistants connected to khayt-mcp see “Customer 1”, “Customer 2” instead of names. On: they see your customers’ names. Phone numbers, emails and addresses are never shared.",
                                     "ar": "عند الإيقاف: يرى المساعدون المتصلون بـ khayt-mcp ‏«Customer 1» و«Customer 2» بدلًا من الأسماء. عند التشغيل: يرون أسماء عملائك. أرقام الهواتف والبريد الإلكتروني والعناوين لا تُشارَك أبدًا."],
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
        "mac.payment_received_label": ["en": "Payment received", "ar": "تم استلام الدفعة"],
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
        "mac.notice_to_phone": ["en": "A print finishes, fails or pauses",
                                "ar": "انتهاء طباعة أو فشلها أو إيقافها مؤقتًا"],
        "mac.notice_names": ["en": "Include job and file names",
                             "ar": "تضمين اسم المهمة واسم الملف"],
        "mac.notice_names_hint": ["en": "Off: the message names only the printer and what happened. A job or file is often named after a customer.",
                                  "ar": "عند الإيقاف لا تذكر الرسالة إلا الطابعة وما حدث. كثيرًا ما تُسمّى المهمة أو الملف باسم العميل."],
        "mac.tg_test": ["en": "Send a test message", "ar": "إرسال رسالة تجريبية"],
        "mac.tg_test_body": ["en": "Test from Khayt. Telegram alerts are working.",
                             "ar": "رسالة تجريبية من خيط. تنبيهات تيليجرام تعمل."],
        "risk.looking": ["en": "Reading the mesh…", "ar": "جارٍ قراءة المجسّم…"],
        "risk.clear": ["en": "Nothing to flag on this one.", "ar": "لا ملاحظات على هذا الملف."],
        "risk.not_looked": ["en": "Khayt has not looked at this mesh yet. Reading it takes a few seconds on a large model.",
                            "ar": "لم يفحص خيط هذا المجسّم بعد. قراءته تستغرق ثوانٍ في النماذج الكبيرة."],
        "risk.look": ["en": "Check the mesh", "ar": "افحص المجسّم"],
        // The setting, and it is THIS app's setting: the other one computes
        // these findings for a quote and never stores them, so it has no import
        // to do the work at. `lib/print-risk.js` holds the rule so that when it
        // does, the two cannot disagree about what the default is.
        "set.risk_when": ["en": "Check models for print risks", "ar": "فحص النماذج لمخاطر الطباعة"],
        "set.risk_demand": ["en": "When I ask", "ar": "عند الطلب"],
        "set.risk_import": ["en": "As each file is imported", "ar": "عند استيراد كل ملف"],
        "set.risk_hint": ["en": "Reading a mesh takes a few seconds on a large model. Checking at import pays that once per file and answers instantly afterwards; checking when you ask keeps imports fast.",
                          "ar": "قراءة المجسّم تستغرق ثوانٍ في النماذج الكبيرة. الفحص عند الاستيراد يدفع هذه الثواني مرّة واحدة لكل ملف ثم يجيب فورًا؛ والفحص عند الطلب يُبقي الاستيراد سريعًا."],
        "risk.unreadable": ["en": "Khayt could not read the mesh in that file.",
                            "ar": "لم يتمكّن خيط من قراءة المجسّم في هذا الملف."],
        "mac.no_model_hint": ["en": "Pick a model to see its file and its filament.", "ar": "اختر نموذجًا لعرض ملفه وخيطه."],
        "mac.no_customer": ["en": "No customer selected", "ar": "لم يُختر عميل"],
        "mac.no_customer_hint": ["en": "Pick a row to see their jobs and their balance.", "ar": "اختر صفاً لعرض أعماله ورصيده."],
        "mac.models_count": ["en": "models", "ar": "نموذجًا"],
        "mac.models_count_few": ["en": "{n} models", "ar": "{n} نماذج"],
        "mac.customers_count": ["en": "customers", "ar": "عملاء"],
        // One of a thing. English needs the singular and Arabic reads better
        // with it, and the window said "1 machines" until it had one.
        "mac.models_count_one": ["en": "model", "ar": "نموذج"],
        "mac.models_count_two": ["en": "models", "ar": "نموذجان"],
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
        // The waterfall's own step. NOT "of which": there the monthly costs
        // come off AFTER the expenses, as the rule's net takes them, so a label
        // saying they are part of the bar beside them reads as counted twice.
        // Named as Settings names them, where the shop typed them in.
        "mac.waterfall_fixed": ["en": "Monthly costs", "ar": "التكاليف الشهرية"],
        // Short: a waterfall slot holds two lines, and "Filament wasted
        // (failed prints)" needed three — it was cut to "Filament wasted (fail…".
        "mac.waterfall_waste": ["en": "Failed prints", "ar": "طباعات فاشلة"],
        // Captions under a quarter's Expenses figure, naming its parts. Short,
        // because three of them share one column.
        "mac.pnl_cap_monthly": ["en": "Monthly costs", "ar": "التكاليف الشهرية"],
        "mac.pnl_cap_depreciation": ["en": "Depreciation", "ar": "الإهلاك"],
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
        "mac.filament_catalog_hint": ["en": "Type a brand or material above — e.g. “bambu pla matte” — to search the catalogue.",
                                      "ar": "اكتب علامة أو مادة في الحقل أعلاه — مثل «bambu pla matte» — للبحث في الدليل."],
        "mac.filament_catalog_none": ["en": "Nothing in the catalogue matches that.",
                                      "ar": "لا شيء في الدليل يطابق ذلك."],
        "mac.new_spool":     ["en": "New Spool",    "ar": "بكرة جديدة"],
        // The storefront promise, which reported only to stderr.
        "mac.lead_time_last": ["en": "Lead time last", "ar": "آخر مدة تسليم"],
        "mac.linked_title": ["en": "Folders indexed where they are", "ar": "مجلدات مفهرسة في مكانها"],
        "mac.linked_link": ["en": "Link a folder", "ar": "اربط مجلدًا"],
        "mac.linked_unlink": ["en": "Unlink", "ar": "افصل"],
        "mac.linked_rescan": ["en": "Look for new models", "ar": "ابحث عن نماذج جديدة"],
        "mac.linked_hint": ["en": "A NAS, an external drive or a shared folder: its models appear in the library, measured and pictured, and stay exactly where they are — nothing is copied, moved or deleted. Unlinking takes them out of the library and leaves the files alone.", "ar": "خادم تخزين أو قرص خارجي أو مجلد مشترك: تظهر نماذجه في المكتبة مقيسة ومصوّرة وتبقى في مكانها تمامًا — لا يُنسخ شيء ولا يُنقل ولا يُحذف. الفصل يُخرجها من المكتبة ويترك الملفات كما هي."],
        "mac.linked_not_vault": ["en": "That folder is the library\u{2019}s own — it is indexed already.", "ar": "هذا المجلد هو مجلد المكتبة نفسه — مفهرس من قبل."],
        "mac.linked_unlinked": ["en": "Unlinked. {n} models left the library; their files were not touched.", "ar": "فُصل المجلد. خرج {n} من النماذج من المكتبة، ولم تُمسّ ملفاتها."],
        "mac.linked_up_to_date": ["en": "The linked folders have nothing new.", "ar": "لا جديد في المجلدات المرتبطة."],
        "mac.linked_scanned": ["en": "Indexed {n} models where they are; {same} were already in the library.", "ar": "فُهرس {n} من النماذج في مكانها؛ و{same} كانت في المكتبة من قبل."],
        // Private share links (VaultShareSheet, VaultLinksSheet).
        "mac.vl_share": ["en": "Share by Private Link", "ar": "مشاركة برابط خاص"],
        "mac.vl_links": ["en": "Share Links", "ar": "روابط المشاركة"],
        "mac.vl_share_title": ["en": "Share by private link", "ar": "مشاركة برابط خاص"],
        "mac.vl_n_models": ["en": "{n} models", "ar": "{n} نماذج"],
        "mac.vl_n_models_n1": ["en": "1 model", "ar": "نموذج واحد"],
        "mac.vl_n_models_n2": ["en": "2 models", "ar": "نموذجان"],
        "mac.vl_create": ["en": "Create Link", "ar": "إنشاء الرابط"],
        "mac.vl_limit_downloads": ["en": "Limit the number of downloads", "ar": "تحديد عدد مرات التنزيل"],
        "mac.vl_downloads_n": ["en": "{n} downloads", "ar": "{n} تنزيلات"],
        "mac.vl_downloads_n_n1": ["en": "1 download", "ar": "تنزيل واحد"],
        "mac.vl_downloads_n_n2": ["en": "2 downloads", "ar": "تنزيلان"],
        "mac.vl_per_file": ["en": "Count each file separately", "ar": "احتساب كل ملف على حدة"],
        "mac.vl_downloads_explain": ["en": "This counts downloads through the link. It cannot stop someone keeping or passing on a file once they have downloaded it.", "ar": "هذا يحسب مرات التنزيل عبر الرابط فقط، ولا يمنع أحدًا من الاحتفاظ بالملف أو إرساله لغيره بعد تنزيله."],
        "mac.vl_ends": ["en": "Link ends", "ar": "ينتهي الرابط"],
        "mac.vl_no_end": ["en": "No end date", "ar": "بلا تاريخ انتهاء"],
        "mac.vl_after_days": ["en": "After {n} days", "ar": "بعد {n} أيام"],
        "mac.vl_after_days_n1": ["en": "After 1 day", "ar": "بعد يوم واحد"],
        "mac.vl_after_days_n2": ["en": "After 2 days", "ar": "بعد يومين"],
        "mac.vl_ends_on": ["en": "Ends {date}", "ar": "ينتهي في {date}"],
        "mac.vl_use_password": ["en": "Ask for a password", "ar": "طلب كلمة مرور"],
        "mac.vl_password_ph": ["en": "Password for this link", "ar": "كلمة مرور لهذا الرابط"],
        "mac.vl_password_rule": ["en": "Use at least 10 characters.", "ar": "استخدم 10 أحرف على الأقل."],
        "mac.vl_password_explain": ["en": "A password only helps if it is hard to guess: anyone who gets the link can try passwords as often as they like. A few unrelated words work well.", "ar": "كلمة المرور تفيد فقط إذا كان تخمينها صعبًا، لأن من يحصل على الرابط يستطيع تجربة كلمات مرور بلا حد. بضع كلمات لا علاقة بينها خيار جيد."],
        "mac.vl_note_ph": ["en": "Note for yourself (optional)", "ar": "ملاحظة لنفسك (اختيارية)"],
        "mac.vl_note_explain": ["en": "Only your shop sees this note, in the Share Links list. It is encrypted before it leaves this Mac.", "ar": "لا يرى هذه الملاحظة إلا متجرك، في قائمة روابط المشاركة. تُشفَّر قبل أن تغادر هذا الماك."],
        "mac.vl_copy_link": ["en": "Copy Link", "ar": "نسخ الرابط"],
        "mac.vl_send_whatsapp": ["en": "Send on WhatsApp", "ar": "إرسال عبر واتساب"],
        "mac.vl_no_whatsapp": ["en": "WhatsApp is not on this Mac, so the link was copied instead.", "ar": "واتساب غير مثبّت على هذا الماك، لذلك نُسخ الرابط بدلًا من ذلك."],
        "mac.vl_whatsapp_text": ["en": "Here are the files: {link}", "ar": "إليك الملفات: {link}"],
        "mac.vl_password_separately": ["en": "Send the password separately, not in the same message as the link.", "ar": "أرسل كلمة المرور بشكل منفصل، لا في الرسالة نفسها التي فيها الرابط."],
        "mac.vl_not_kept": ["en": "This Mac could not keep the link, so Copy Link will not be offered again later. Copy it now.", "ar": "لم يتمكن هذا الماك من حفظ الرابط، فلن يظهر «نسخ الرابط» لاحقًا. انسخه الآن."],
        "mac.vl_private_explain": ["en": "The part after # unlocks the files. It stays on this Mac and in the link you send; Khayt Cloud never receives it.", "ar": "الجزء الذي بعد علامة # هو مفتاح الملفات. يبقى على هذا الماك وفي الرابط الذي ترسله، ولا يصل إلى خيط السحابي أبدًا."],
        "mac.vl_err_not_allowed": ["en": "This sign-in cannot make or change share links.", "ar": "تسجيل الدخول هذا لا يسمح بإنشاء روابط المشاركة أو تعديلها."],
        "mac.vl_err_vault_off": ["en": "Share links need the library to be kept in your Khayt Vault.", "ar": "روابط المشاركة تتطلب أن تكون المكتبة محفوظة في خزنة خيط."],
        "mac.vl_err_missing": ["en": "{n} of these models have no copy in the vault yet. Back them up, then try again.", "ar": "{n} من هذه النماذج ليست لها نسخة في الخزنة بعد. انسخها احتياطيًا ثم حاول مرة أخرى."],
        "mac.vl_err_missing_n1": ["en": "One of these models has no copy in the vault yet. Back it up, then try again.", "ar": "أحد هذه النماذج ليست له نسخة في الخزنة بعد. انسخه احتياطيًا ثم حاول مرة أخرى."],
        "mac.vl_err_not_in_vault": ["en": "A file in this link is no longer in the vault.", "ar": "أحد الملفات في هذا الرابط لم يعد في الخزنة."],
        "mac.vl_err_incomplete": ["en": "Not every file could be added, so the link was cancelled. Nothing was shared. Try again.", "ar": "تعذّرت إضافة كل الملفات، فأُلغي الرابط ولم يُشارَك شيء. حاول مرة أخرى."],
        "mac.vl_err_other_mac": ["en": "This link was made on another device. Copy it from there.", "ar": "أُنشئ هذا الرابط على جهاز آخر. انسخه من هناك."],
        "mac.vl_err_links_full": ["en": "Your plan's share links are all in use ({n}). Revoke one, or change plan.", "ar": "كل روابط المشاركة في باقتك مستخدمة ({n}). ألغِ أحدها أو غيّر الباقة."],
        "mac.vl_err_no_links": ["en": "Your plan does not include share links.", "ar": "باقتك لا تشمل روابط المشاركة."],
        "mac.vl_err_downloads_cap": ["en": "Your plan allows at most {n} downloads per link.", "ar": "باقتك تسمح بـ{n} تنزيلات كحد أقصى لكل رابط."],
        "mac.vl_err_signin": ["en": "Khayt Cloud did not accept this shop's sign-in. Sign in again.", "ar": "لم يقبل خيط السحابي تسجيل دخول هذا المتجر. سجّل الدخول مرة أخرى."],
        "mac.vl_err_slow": ["en": "Khayt Cloud asked to slow down. Try again in a minute.", "ar": "طلب خيط السحابي التمهّل. حاول مرة أخرى بعد دقيقة."],
        "mac.vl_err_generic": ["en": "The link could not be made or changed. Check the connection and try again.", "ar": "تعذّر إنشاء الرابط أو تعديله. تحقق من الاتصال وحاول مرة أخرى."],
        "mac.vl_links_title": ["en": "Share links", "ar": "روابط المشاركة"],
        "mac.vl_refresh": ["en": "Refresh", "ar": "تحديث"],
        "mac.vl_none": ["en": "No share links yet. Right-click a model and choose Share by Private Link.", "ar": "لا توجد روابط مشاركة بعد. انقر بزر الفأرة الأيمن على نموذج واختر «مشاركة برابط خاص»."],
        "mac.vl_n_files": ["en": "{n} files", "ar": "{n} ملفات"],
        "mac.vl_n_files_n1": ["en": "1 file", "ar": "ملف واحد"],
        "mac.vl_n_files_n2": ["en": "2 files", "ar": "ملفان"],
        "mac.vl_and_more": ["en": "{name} and {n} more", "ar": "{name} و{n} غيره"],
        "mac.vl_state_ok": ["en": "Active", "ar": "فعّال"],
        "mac.vl_state_revoked": ["en": "Revoked", "ar": "ملغى"],
        "mac.vl_state_expired": ["en": "Expired", "ar": "منتهي"],
        "mac.vl_state_used_up": ["en": "Used up", "ar": "استُنفد"],
        "mac.vl_state_unknown": ["en": "Unknown", "ar": "غير معروف"],
        "mac.vl_used_no_limit": ["en": "{used} downloaded, no limit", "ar": "نُزّل {used} مرة، بلا حد"],
        "mac.vl_used_left": ["en": "{used} downloaded, {left} left", "ar": "نُزّل {used} مرة، والمتبقي {left}"],
        "mac.vl_revoked_on": ["en": "Revoked {date}", "ar": "أُلغي في {date}"],
        "mac.vl_ends_after_open": ["en": "Ends a set time after it is first opened", "ar": "ينتهي بعد مدة محددة من أول فتح"],
        "mac.vl_has_password": ["en": "Needs a password", "ar": "يتطلب كلمة مرور"],
        "mac.vl_activity": ["en": "Show Activity", "ar": "عرض النشاط"],
        "mac.vl_hide_activity": ["en": "Hide Activity", "ar": "إخفاء النشاط"],
        "mac.vl_no_activity": ["en": "Nobody has opened this link yet.", "ar": "لم يفتح أحد هذا الرابط بعد."],
        "mac.vl_add_downloads": ["en": "Add {n} Downloads", "ar": "إضافة {n} تنزيلات"],
        "mac.vl_extend_days": ["en": "Extend by {n} Days", "ar": "تمديد {n} أيام"],
        "mac.vl_remove_end": ["en": "Remove the End Date", "ar": "إزالة تاريخ الانتهاء"],
        "mac.vl_revoke": ["en": "Revoke Link", "ar": "إلغاء الرابط"],
        "mac.vl_more": ["en": "More for this link", "ar": "خيارات أخرى لهذا الرابط"],
        "mac.vl_revoke_title": ["en": "Revoke this link?", "ar": "إلغاء هذا الرابط؟"],
        "mac.vl_revoke_explain": ["en": "Nobody can open it or download from it again. A download already under way may finish within 15 minutes. This cannot be undone.", "ar": "لن يستطيع أحد فتحه أو التنزيل منه بعد الآن. قد يكتمل تنزيل جارٍ خلال 15 دقيقة. لا يمكن التراجع عن هذا."],
        "mac.vl_event_open": ["en": "Opened", "ar": "فُتح"],
        "mac.vl_event_ticket": ["en": "Downloaded", "ar": "نُزّل"],
        "mac.vl_event_refused": ["en": "Refused", "ar": "رُفض"],
        "mac.vl_event_other": ["en": "Activity", "ar": "نشاط"],
        "mac.vl_device_phone": ["en": "phone", "ar": "هاتف"],
        "mac.vl_device_tablet": ["en": "tablet", "ar": "جهاز لوحي"],
        "mac.vl_device_computer": ["en": "computer", "ar": "حاسوب"],
        "mac.vl_device_other": ["en": "other device", "ar": "جهاز آخر"],
        "mac.vl_err_incomplete_live": ["en": "Not every file could be added, and the half-made link could not be cancelled. Open Share Links and revoke it.", "ar": "تعذّرت إضافة كل الملفات، وتعذّر إلغاء الرابط الناقص. افتح «روابط المشاركة» وألغِه."],
        "mac.vl_err_too_big": ["en": "Too many files for one link. Share fewer at a time.", "ar": "الملفات كثيرة على رابط واحد. شارك عددًا أقل في كل مرة."],
        "mac.vl_err_unknown_grant": ["en": "Khayt Cloud no longer has this link.", "ar": "لم يعد هذا الرابط موجودًا في خيط السحابي."],
        "mac.vl_err_not_yet": ["en": "Khayt Cloud does not offer that yet.", "ar": "خيط السحابي لا يقدّم هذه الميزة بعد."],
        "mac.vl_state_incomplete": ["en": "Incomplete", "ar": "ناقص"],
        "mac.vl_incomplete_explain": ["en": "This link was not finished: some files were not added. It cannot be copied. Revoke it and make a new one.", "ar": "لم يكتمل هذا الرابط، فبعض الملفات لم تُضف إليه، ولا يمكن نسخه. ألغِه وأنشئ رابطًا جديدًا."],
        // Phase 2b: the email lock, and links Khayt turned off.
        "mac.vl_lock_toggle": ["en": "Only these people", "ar": "لهؤلاء الأشخاص فقط"],
        "mac.vl_lock_ph": ["en": "Email addresses, separated by commas", "ar": "عناوين البريد الإلكتروني، تفصل بينها فواصل"],
        "mac.vl_lock_explain": ["en": "Each person has to enter a code that is emailed to them before they can see the files. Khayt Cloud sends the codes, so it can read these addresses, and everyone in your shop can see them in Share Links.", "ar": "على كل شخص أن يُدخل رمزًا يصله بالبريد الإلكتروني قبل أن يرى الملفات. خيط السحابي هو من يرسل الرموز، لذلك يستطيع قراءة هذه العناوين، ويستطيع كل من في متجرك رؤيتها في «روابط المشاركة»."],
        "mac.vl_lock_count": ["en": "{n} addresses", "ar": "{n} عناوين"],
        "mac.vl_lock_count_n1": ["en": "1 address", "ar": "عنوان واحد"],
        "mac.vl_lock_count_n2": ["en": "2 addresses", "ar": "عنوانان"],
        "mac.vl_lock_err_none": ["en": "Add at least one email address, or turn off Only these people.", "ar": "أضف عنوان بريد إلكتروني واحدًا على الأقل، أو أوقف «لهؤلاء الأشخاص فقط»."],
        "mac.vl_lock_err_too_many": ["en": "A link can be limited to at most {n} email addresses.", "ar": "يمكن قصر الرابط على {n} عنوان بريد إلكتروني كحد أقصى."],
        "mac.vl_lock_err_bad": ["en": "This is not an email address: {email}", "ar": "هذا ليس عنوان بريد إلكتروني: {email}"],
        "mac.vl_err_mail_off": ["en": "Khayt Cloud cannot send email right now, so a link cannot be limited to email addresses. Try again later, or share without the email list.", "ar": "لا يستطيع خيط السحابي إرسال البريد الإلكتروني الآن، لذلك لا يمكن قصر الرابط على عناوين بريد. حاول لاحقًا، أو شارك من دون قائمة العناوين."],
        "mac.vl_err_bad_lock": ["en": "Khayt Cloud did not accept one of the email addresses. Check them and try again.", "ar": "لم يقبل خيط السحابي أحد عناوين البريد الإلكتروني. تحقق منها وحاول مرة أخرى."],
        "mac.vl_err_links_off": ["en": "Khayt has turned off share links for this shop. No new link can be made, and the shop's existing links are turned off too. Write to Khayt to ask why, or to have them turned back on.", "ar": "أوقف خيط روابط المشاركة لهذا المتجر، فلا يمكن إنشاء رابط جديد، والروابط الحالية للمتجر متوقفة أيضًا. راسل خيط لمعرفة السبب أو لإعادة تشغيلها."],
        "mac.vl_err_disabled": ["en": "Khayt turned this link off, so it can only be revoked.", "ar": "أوقف خيط هذا الرابط، فلا يمكن إلا إلغاؤه."],
        "mac.vl_state_disabled": ["en": "Turned off by Khayt", "ar": "أوقفه خيط"],
        "mac.vl_disabled_explain": ["en": "Nobody can open this link while it is turned off. You can revoke it; nothing else about it can be changed.", "ar": "لا يستطيع أحد فتح هذا الرابط وهو متوقف. يمكنك إلغاؤه، ولا يمكن تغيير أي شيء آخر فيه."],
        "mac.vl_disabled_reason": ["en": "Reason: {reason}", "ar": "السبب: {reason}"],
        "mac.vl_disabled_on": ["en": "Turned off {date}", "ar": "أُوقف في {date}"],
        "mac.vl_locked_to": ["en": "Only for {emails}", "ar": "مقصور على {emails}"],
        "mac.vl_locked_more": ["en": "{emails} and {n} more", "ar": "{emails} و{n} غيرهم"],
        "mac.vl_lock_set": ["en": "Limit to Email Addresses", "ar": "قصره على عناوين بريد"],
        "mac.vl_lock_change": ["en": "Change Who Can Open", "ar": "تغيير من يستطيع الفتح"],
        "mac.vl_lock_remove": ["en": "Remove the Email List", "ar": "إزالة قائمة العناوين"],
        "mac.vl_lock_remove_title": ["en": "Remove the email list?", "ar": "إزالة قائمة العناوين؟"],
        "mac.vl_lock_remove_explain": ["en": "Anyone who has the link, and its password if it has one, will be able to open it without a code.", "ar": "سيستطيع كل من لديه الرابط، وكلمة مروره إن كانت له كلمة مرور، أن يفتحه من دون رمز."],
        "mac.vl_lock_edit_title": ["en": "Who can open this link", "ar": "من يستطيع فتح هذا الرابط"],
        "mac.vl_lock_made": ["en": "Only the people on the list can open it. Tell them to expect an email with a code.", "ar": "لا يستطيع فتحه إلا من في القائمة. أخبرهم أن رسالة فيها رمز ستصلهم بالبريد الإلكتروني."],
        "mac.vl_lock_edit_explain": ["en": "Someone taken off the list can no longer open the link, even if they already have.", "ar": "من يُحذف من القائمة لن يستطيع فتح الرابط بعد ذلك، حتى لو كان قد فتحه من قبل."],
        "mac.storage_rescan": ["en": "Rescan Storage", "ar": "إعادة فحص التخزين"],
        "mac.storage_scanned": ["en": "Library folder checked. Added where they are: {n}; already in the library: {same}; with a photo: {photos}.", "ar": "فُحص مجلد المكتبة. أُضيف في مكانه: {n}؛ موجود في المكتبة من قبل: {same}؛ مع صورة: {photos}."],
        "mac.storage_progress": ["en": "Library storage: {done} of {total} — {name}", "ar": "تخزين المكتبة: {done} من {total} — {name}"],
        "mac.storage_nothing_new": ["en": "The library folder has no models the library does not already know.", "ar": "لا نماذج في مجلد المكتبة إلا وهي في المكتبة."],
        "mac.storage_downloaded_duplicate": ["en": "Downloaded — and it is the same file as “{name}”, already in the library.", "ar": "نُزّل — وهو الملف نفسه الموجود في المكتبة باسم “{name}”."],
        "mac.storage_capped": ["en": "The folder is very large, so this stopped part way — rescan to look further.", "ar": "المجلد كبير جدًا فتوقف الفحص في منتصفه — أعد الفحص للمتابعة."],
        "mac.linked_where": ["en": "Linked — in {path}", "ar": "مرتبط — في {path}"],
        "mac.scan_stopped": ["en": "Stopped. Models added before you stopped: {n}. Look again whenever you like — it carries on from there.", "ar": "تم الإيقاف. النماذج المضافة قبل الإيقاف: {n}. ابحث مجددًا متى شئت — يكمل من حيث توقف."],
        "mac.library_looking": ["en": "Looking through the library\u{2019}s folders…", "ar": "جارٍ البحث في مجلدات المكتبة…"],
        "mac.linked_online": ["en": "Online only, added without downloading: {online}. Each one downloads when you open it.", "ar": "نماذج على الإنترنت فقط أُضيفت دون تنزيل: {online}. يُنزَّل كل منها عند فتحه."],
        // ── Compressed files as folders (`Shop+ArchiveFolders.swift`) ──
        "mac.arc_scanned": ["en": "{n} models indexed from inside compressed files.", "ar": "فُهرس \u{2068}{n}\u{2069} نموذجًا من داخل ملفات مضغوطة."],
        "mac.arc_scanned_one": ["en": "{n} model indexed from inside a compressed file.", "ar": "فُهرس نموذج واحد من داخل ملف مضغوط."],
        "mac.arc_scanned_two": ["en": "{n} models indexed from inside compressed files.", "ar": "فُهرس نموذجان من داخل ملفات مضغوطة."],
        "mac.arc_scanned_few": ["en": "{n} models indexed from inside compressed files.", "ar": "فُهرست \u{2068}{n}\u{2069} نماذج من داخل ملفات مضغوطة."],
        "mac.arc_locked_n": ["en": "{n} locked with a password — listed, never opened.", "ar": "\u{2068}{n}\u{2069} مقفلة بكلمة مرور — تُعرض ولا تُفتح أبدًا."],
        "mac.arc_online_n": ["en": "{n} compressed files are online only: their models appear once the files are on this Mac.", "ar": "\u{2068}{n}\u{2069} ملفًا مضغوطًا على الإنترنت فقط: تظهر نماذجها حين تصبح الملفات على هذا الماك."],
        "mac.arc_online_n_one": ["en": "{n} compressed file is online only: its models appear once the file is on this Mac.", "ar": "ملف مضغوط واحد على الإنترنت فقط: تظهر نماذجه حين يصبح الملف على هذا الماك."],
        "mac.arc_online_n_two": ["en": "{n} compressed files are online only: their models appear once the files are on this Mac.", "ar": "ملفان مضغوطان على الإنترنت فقط: تظهر نماذجهما حين يصبح الملفان على هذا الماك."],
        "mac.arc_online_n_few": ["en": "{n} compressed files are online only: their models appear once the files are on this Mac.", "ar": "\u{2068}{n}\u{2069} ملفات مضغوطة على الإنترنت فقط: تظهر نماذجها حين تصبح الملفات على هذا الماك."],
        "mac.arc_refused_n": ["en": "{n} compressed files were not opened: unsafe, damaged or too large.", "ar": "لم يُفتح \u{2068}{n}\u{2069} من الملفات المضغوطة: غير آمنة أو تالفة أو كبيرة جدًا."],
        "mac.arc_reveal": ["en": "Show Compressed File in Finder", "ar": "إظهار الملف المضغوط في Finder"],
        "mac.arc_where": ["en": "Inside {name} — in {path}", "ar": "داخل \u{2068}{name}\u{2069} — في \u{2068}{path}\u{2069}"],
        "mac.arc_member": ["en": "Inside a compressed file", "ar": "داخل ملف مضغوط"],
        "mac.arc_locked": ["en": "Locked with a password", "ar": "مقفل بكلمة مرور"],
        "mac.arc_locked_says": ["en": "Its compressed file is encrypted. Khayt lists the model and never asks for the password; unpack it yourself to print it.",
                                "ar": "ملفه المضغوط مشفّر. يعرض خيط النموذج ولا يطلب كلمة المرور أبدًا؛ فُكّ ضغطه بنفسك لتطبعه."],
        "mac.arc_extracting": ["en": "Taking it out of the compressed file…", "ar": "يُستخرج من الملف المضغوط…"],
        "mac.arc_not_here": ["en": "Its compressed file is not on this Mac right now, so it cannot be opened.", "ar": "ملفه المضغوط ليس على هذا الماك الآن، فلا يمكن فتحه."],
        "mac.arc_untouched": ["en": "Read from inside the compressed file. The file itself is never changed.", "ar": "يُقرأ من داخل الملف المضغوط، ولا يُغيَّر الملف نفسه أبدًا."],
        "mac.arc_tile": ["en": "Compressed file", "ar": "ملف مضغوط"],
        "mac.arc_tile_a11y": ["en": "{name}, a compressed file, {models}", "ar": "\u{2068}{name}\u{2069}، ملف مضغوط، \u{2068}{models}\u{2069}"],
        "mac.arc_remove": ["en": "Remove {name} from Library", "ar": "إزالة \u{2068}{name}\u{2069} من المكتبة"],
        "mac.lh_arc_row": ["en": "{name} — {models} inside", "ar": "\u{2068}{name}\u{2069} — \u{2068}{models}\u{2069} بداخله"],
        "mac.linked_download": ["en": "Download to this Mac", "ar": "نزّله إلى هذا الماك"],
        "mac.linked_regroup": ["en": "Regroup from folders", "ar": "أعد التجميع حسب المجلدات"],
        "mac.linked_regroup_help": ["en": "File the linked models by their folders again, with the current rules. Groups you set yourself are left alone.", "ar": "يعيد ترتيب النماذج المرتبطة حسب مجلداتها بالقواعد الحالية. المجموعات التي اخترتها بنفسك تبقى كما هي."],
        "mac.measure_online_title": ["en": "Models kept online", "ar": "نماذج محفوظة على الإنترنت"],
        "mac.measure_online": ["en": "Measure online models", "ar": "قِس النماذج المحفوظة على الإنترنت"],
        "mac.measure_online_hint": ["en": "{n} models in your linked folders are kept online by their drive and have never been measured, so they cannot be priced here or from your phone. Measuring downloads each one ({size} in all), one at a time, and hands it back to the drive afterwards.", "ar": "في مجلداتك المرتبطة نماذج يحفظها التخزين السحابي على الإنترنت ولم تُقَس قط (عددها: {n})، لذا لا يمكن تسعيرها هنا ولا من جوالك. القياس يُنزّل كلًّا منها ({size} إجمالًا) واحدًا تلو الآخر ثم يعيده إلى التخزين السحابي."],
        "mac.measure_online_q": ["en": "Download and measure every online model?", "ar": "تنزيل كل النماذج المحفوظة على الإنترنت وقياسها؟"],
        "mac.measure_online_body": ["en": "{n} models, {size} in all. They are downloaded one at a time and handed back to the drive once measured, so your disk only ever holds one. A large drive takes hours; you can keep working, and Stop keeps everything measured so far.", "ar": "عدد النماذج: {n}، والحجم الإجمالي: {size}. تُنزَّل واحدًا تلو الآخر وتُعاد إلى التخزين السحابي بعد قياسها، فلا يحمل قرصك إلا واحدًا في كل مرة. التخزين الكبير يستغرق ساعات؛ يمكنك مواصلة العمل، والإيقاف يحتفظ بكل ما قيس حتى تلك اللحظة."],
        // One model, said as one in both languages ("One model", "نموذج
        // واحد"). `_single`, not `_one`: these carry {size} too, and a
        // counted `_one` is held to rules that a sentence with two marks
        // cannot meet in both languages at once.
        "mac.measure_online_hint_single": ["en": "One model in your linked folders is kept online by its drive and has never been measured, so it cannot be priced here or from your phone. Measuring downloads it ({size}) and hands it back to the drive afterwards.", "ar": "في مجلداتك المرتبطة نموذج واحد يحفظه التخزين السحابي على الإنترنت ولم يُقَس قط، لذا لا يمكن تسعيره هنا ولا من جوالك. القياس يُنزّله ({size}) ثم يعيده إلى التخزين السحابي."],
        "mac.measure_online_body_single": ["en": "One model, {size}. It is downloaded and handed back to the drive once measured. You can keep working, and Stop keeps it if it is already measured.", "ar": "نموذج واحد، حجمه {size}. يُنزَّل ثم يُعاد إلى التخزين السحابي بعد قياسه. يمكنك مواصلة العمل، والإيقاف يحتفظ به إن كان قد قيس."],
        "mac.measure_online_done": ["en": "Measured: {n}. Could not be measured: {skipped}.", "ar": "تم قياسها: {n}. تعذّر قياسها: {skipped}."],
        "mac.measure_online_stopped": ["en": "Stopped. Measured before you stopped: {n}. Could not be measured: {skipped}. Press Measure again to carry on.", "ar": "تم الإيقاف. ما قيس قبل الإيقاف: {n}. تعذّر قياسها: {skipped}. اضغط «قِس» مجددًا للمتابعة."],
        "mac.measure_online_none": ["en": "Every linked model has been measured.", "ar": "كل النماذج المرتبطة مقيسة."],
        "mac.phones_title": ["en": "Paired phones", "ar": "الجوالات المقترنة"],
        "mac.phones_none": ["en": "None yet", "ar": "لا يوجد بعد"],
        "mac.phones_unnamed": ["en": "Phone", "ar": "جوال"],
        "mac.phones_seen": ["en": "Last seen {date}", "ar": "آخر ظهور {date}"],
        "mac.phones_sign_out": ["en": "Sign out", "ar": "تسجيل الخروج"],
        "mac.phones_sign_out_q": ["en": "Sign out “{name}”?", "ar": "تسجيل خروج «{name}»؟"],
        "mac.phones_sign_out_note": ["en": "It can no longer reach this Mac until someone enters the LAN PIN on it again. Your other phones stay signed in. If the phone was lost, also change the LAN PIN, and sign it out of Khayt Cloud if it uses it: this does not reach the cloud.", "ar": "لن يتمكن من الوصول إلى هذا الماك حتى يُدخَل رمز الشبكة المحلية عليه من جديد. جوالاتك الأخرى تبقى مسجّلة الدخول. إن كان الجوال مفقودًا فغيّر رمز الشبكة المحلية أيضًا، وسجّل خروجه من Khayt Cloud إن كان يستخدمها: هذا الإجراء لا يصل إلى السحابة."],
        "mac.phones_hint": ["en": "A phone pairs once with the LAN PIN, after you click Pair a phone here, and signs its requests after that. Changing the PIN signs every phone out.", "ar": "يقترن الجوال مرة واحدة برمز الشبكة المحلية بعد أن تضغط «إقران جوال» هنا، ثم يوقّع طلباته بعد ذلك. تغيير الرمز يسجّل خروج كل الجوالات."],
        "mac.pair_open": ["en": "Pair a phone", "ar": "إقران جوال"],
        "mac.pair_waiting": ["en": "Waiting for a phone… {time}", "ar": "بانتظار جوال… {time}"],
        "mac.pair_open_hint": ["en": "On the phone, enter the LAN PIN to pair, or for a phone already set up, tap Secure this phone in its Settings.", "ar": "على الجوال، أدخل رمز الشبكة المحلية للاقتران، أو لجوال مُعدّ من قبل اضغط «تأمين هذا الجوال» في إعداداته."],
        "mac.pair_done": ["en": "Paired “{name}”.", "ar": "تم إقران «{name}»."],
        "mac.pair_timed_out": ["en": "No phone paired in time. Click Pair a phone to try again.", "ar": "لم يقترن أي جوال في الوقت المحدد. اضغط «إقران جوال» للمحاولة مجددًا."],
        "mac.pair_too_many": ["en": "Closed after many wrong PINs from several devices. Someone on this network may be guessing the PIN. Consider changing it.", "ar": "أُغلق بعد محاولات كثيرة برمز خاطئ من عدة أجهزة. ربما يحاول أحد على هذه الشبكة تخمين الرمز. فكّر في تغييره."],
        "mac.pair_loopback": ["en": "A phone can’t reach this Mac yet. Turn on “Listen on all network interfaces (LAN)” above and save.", "ar": "لا يمكن للجوال الوصول إلى هذا الماك بعد. فعّل «الاستماع على جميع واجهات الشبكة (LAN)» في الأعلى واحفظ."],
        "mac.pair_server_stopped": ["en": "Pairing stopped because the LAN server stopped.", "ar": "توقف الإقران لأن خادم الشبكة المحلية توقف."],
        "mac.pair_locked_some": ["en": "A device on this network entered a wrong PIN too many times. It can’t pair until you click Pair a phone again. Other phones still can.", "ar": "أدخل جهاز على هذه الشبكة رمزًا خاطئًا مرات كثيرة، ولا يمكنه الاقتران حتى تضغط «إقران جوال» مجددًا. الجوالات الأخرى ما زال بإمكانها ذلك."],
        "mac.linked_regrouped": ["en": "Regrouped from their folders: {n}. Groups you set yourself were left alone.", "ar": "أُعيد تجميعها حسب مجلداتها: {n}. المجموعات التي اخترتها بنفسك بقيت كما هي."],
        "mac.linked_sort": ["en": "Sort linked folders…", "ar": "فرز المجلدات المرتبطة…"],
        "mac.linked_sort_help": ["en": "Find the prints in your linked folders and make each one a group, with its picture. Shows what would change before anything moves.", "ar": "يجد الطباعات في مجلداتك المرتبطة ويجعل كل طباعة مجموعة بصورتها. يعرض ما سيتغير قبل نقل أي شيء."],
        "mac.ai_feat_library": ["en": "Sort linked folders", "ar": "فرز المجلدات المرتبطة"],
        "mac.ai_data_library": ["en": "the names of the folders in your linked folders, a few file names from each, how many models each folder holds, and the names of the files (models and pictures) lying loose at the top of a linked folder, in the order they were added. Never the files themselves, and never a picture.", "ar": "أسماء المجلدات في مجلداتك المرتبطة، وبضعة أسماء ملفات من كل مجلد، وعدد النماذج في كل مجلد، وأسماء الملفات المتفرقة (نماذج وصور) في أعلى المجلد المرتبط بترتيب إضافتها. لا تُرسل الملفات نفسها أبدًا، ولا أي صورة."],
        "mac.ai_feat_pictures": ["en": "Check pictures", "ar": "فحص الصور"],
        "mac.ai_data_pictures": ["en": "the print’s name, the candidate photo redrawn as a new JPEG of at most 512 pixels with none of its metadata, and the print’s own preview when there is one (from a 3MF or a model on this Mac), to confirm they show the same print. At most 2 images a request and 40 checks a scan. Never a model file; nothing kept only in the cloud is downloaded for it.", "ar": "اسم الطباعة، والصورة المرشّحة بعد إعادة رسمها كصورة JPEG جديدة لا تتجاوز 512 بكسل وبلا أي بيانات وصفية، ومعاينة الطباعة نفسها إن وُجدت (من ملف 3MF أو نموذج على هذا الماك)، للتأكد أنهما للطباعة نفسها. صورتان على الأكثر في الطلب و40 فحصًا على الأكثر في كل مسح. لا يُرسل ملف نموذج أبدًا، ولا يُنزَّل لذلك أي ملف محفوظ في السحابة فقط."],
        "mac.sort_pictures_check": ["en": "Pictures to check", "ar": "صور للمراجعة"],
        "mac.sort_pictures_check_help": ["en": "Not sure these are the right pictures. Tick the ones to use; one left unticked is offered again next time. “Not this print” means it is never offered for that print again.", "ar": "لسنا متأكدين أن هذه هي الصور الصحيحة. حدّد ما تريد استخدامه؛ وما تتركه دون تحديد يُعرض عليك مرة أخرى لاحقًا. أما «ليست لهذه الطباعة» فتعني ألّا تُقترح لهذه الطباعة مجددًا."],
        "mac.sort_picture_not_this": ["en": "Not this print", "ar": "ليست لهذه الطباعة"],
        "mac.sort_picture_undo": ["en": "Undo", "ar": "تراجع"],
        "mac.sort_picture_cloud": ["en": "In the cloud", "ar": "في السحابة"],
        "mac.sort_picture_show": ["en": "Show", "ar": "عرض"],
        "mac.sort_pictures_ai_off": ["en": "Your assistant cannot look at pictures with this provider, so they were not checked.", "ar": "لا يستطيع مساعدك رؤية الصور مع هذا المزوّد، فلم تُفحص."],
        "mac.sort_pictures_checked": ["en": "Pictures your assistant checked: {n}.", "ar": "صور فحصها مساعدك: {n}."],
        "mac.sort_title": ["en": "Sort linked folders", "ar": "فرز المجلدات المرتبطة"],
        // "Collection" is where files came from (a Patreon tier, a pack, a
        // month's release) and becomes a TAG. Not مجموعة in Arabic: that is
        // the library's word for a GROUP, the very thing a collection stops
        // being here. A print is طباعة, as everywhere else in the library.
        "mac.sort_summary": ["en": "Prints found: {prints}. Collections they came from: {collections}.", "ar": "الطباعات التي وُجدت: {prints}. الحزم التي جاءت منها: {collections}."],
        "mac.sort_moved": ["en": "Models that move into their print’s group: {n}.", "ar": "نماذج ستنتقل إلى مجموعة طباعتها: {n}."],
        "mac.sort_loose": ["en": "Loose models at the top of the folder: {n} of {total} go into {prints} prints.", "ar": "النماذج المتفرقة في أعلى المجلد: {n} من {total} ستُجمع في {prints} طباعة."],
        "mac.sort_renamed": ["en": "Models named after their print or part: {n}.", "ar": "نماذج ستأخذ اسم طباعتها أو جزئها: {n}."],
        "mac.sort_tagged": ["en": "Models tagged with the collection they came from: {n}.", "ar": "نماذج سيُضاف إليها وسم الحزمة التي جاءت منها: {n}."],
        "mac.sort_kept": ["en": "Models you grouped yourself stay where they are: {n}.", "ar": "النماذج التي جمّعتها بنفسك تبقى مكانها: {n}."],
        "mac.sort_models": ["en": "Models: {n}", "ar": "النماذج: {n}"],
        "mac.sort_from": ["en": "From {name}", "ar": "من {name}"],
        "mac.sort_apply": ["en": "Apply", "ar": "تطبيق"],
        "mac.sort_asking": ["en": "Asking your assistant to sort the folders by their names…", "ar": "جارٍ سؤال مساعدك عن فرز المجلدات حسب أسمائها…"],
        "mac.sort_ai_used": ["en": "Your assistant sorted folders: {n}.", "ar": "مجلدات فرزها مساعدك: {n}."],
        "mac.sort_ai_loose": ["en": "Your assistant grouped loose files: {n}.", "ar": "ملفات متفرقة جمّعها مساعدك: {n}."],
        "mac.sort_ai_loose_held": ["en": "Loose files your assistant could not group, grouped on this Mac instead: {n}. Press “Sort linked folders…” to ask again.", "ar": "ملفات متفرقة تعذّر على مساعدك تجميعها فجُمّعت على هذا الماك: {n}. اضغط «فرز المجلدات المرتبطة…» لتسأله مجددًا."],
        // {why} is a whole sentence (`mac.ai_no_key`) or the provider's own
        // words, so it follows the sentence rather than sitting in brackets.
        "mac.sort_ai_failed": ["en": "Your assistant could not sort the folders, so this Mac sorted them by their names. {why}", "ar": "تعذّر على مساعدك فرز المجلدات، ففرزها هذا الماك حسب أسمائها. {why}"],
        "mac.sort_ai_held": ["en": "Folders your assistant could not sort, sorted on this Mac instead: {n}. Press “Sort linked folders…” to ask again.", "ar": "مجلدات تعذّر على مساعدك فرزها ففُرزت على هذا الماك: {n}. اضغط «فرز المجلدات المرتبطة…» لتسأله مجددًا."],
        // The pane is "AI assist" (`set.ai_master`), as `mac.ai_no_key` says it.
        "mac.sort_ai_off": ["en": "Sorted by the folders’ names on this Mac. To let your assistant check it, turn on “Sort linked folders” in Settings → AI assist — only folder and file names are sent.", "ar": "فُرزت حسب أسماء المجلدات على هذا الماك. لتسمح لمساعدك بمراجعتها، فعّل «فرز المجلدات المرتبطة» في الإعدادات ← مساعدة الذكاء الاصطناعي — تُرسل أسماء المجلدات والملفات فقط."],
        "mac.sort_pictures_added": ["en": "Pictures added: {n}.", "ar": "صور أُضيفت: {n}."],
        "mac.print_next": ["en": "Print next", "ar": "التالي للطباعة"],
        "mac.print_next_add": ["en": "Add to Print next", "ar": "أضف إلى «التالي للطباعة»"],
        "mac.print_next_remove": ["en": "Remove from Print next", "ar": "أزل من «التالي للطباعة»"],
        "mac.duplicates": ["en": "Duplicates", "ar": "المكرّرة"],
        // Putting a model aside by hand, and the Archived view it comes back
        // from (`Shop.archive`). Never a delete: the file and the record stay.
        "mac.archive_model": ["en": "Archive", "ar": "أرشفة"],
        "mac.archive_n_models": ["en": "Archive {n} Models", "ar": "أرشفة {n} نماذج"],
        "mac.unarchive_model": ["en": "Restore from Archive", "ar": "استعادة من الأرشيف"],
        "mac.unarchive_n_models": ["en": "Restore {n} Models from Archive", "ar": "استعادة {n} نماذج من الأرشيف"],
        "mac.lib_archived": ["en": "Archived", "ar": "المؤرشفة"],
        // The search box's tokens (`LibrarySearch`), as their chips name them.
        "mac.lib_token_tag": ["en": "Tag", "ar": "الوسم"],
        "mac.lib_token_group": ["en": "Group", "ar": "المجموعة"],
        "mac.lib_token_category": ["en": "Category", "ar": "التصنيف"],
        "mac.lib_token_material": ["en": "Material", "ar": "الخامة"],
        "mac.lib_token_creator": ["en": "Creator", "ar": "المصمم"],
        "mac.lib_token_printer": ["en": "Ready on", "ar": "جاهز على"],
        "mac.lib_token_remove": ["en": "Remove {name}", "ar": "إزالة {name}"],
        // Where a model's bytes are (`LibrarySyncIndex`): the tile badge, the
        // Show menu pair, and the inspector's Storage section.
        "mac.lib_online_only": ["en": "Online only", "ar": "على الإنترنت فقط"],
        "mac.lib_this_mac_only": ["en": "On this Mac only", "ar": "على هذا الماك فقط"],
        "mac.storage_section": ["en": "Storage", "ar": "التخزين"],
        "mac.storage_state_local": ["en": "On this Mac only", "ar": "على هذا الماك فقط"],
        "mac.storage_state_backed_up": ["en": "On this Mac and backed up online", "ar": "على هذا الماك ومنسوخ على الإنترنت"],
        "mac.storage_state_online": ["en": "Online only", "ar": "على الإنترنت فقط"],
        "mac.storage_free_one": ["en": "Free Up Space", "ar": "توفير المساحة"],
        "mac.storage_free_one_help": ["en": "Remove this Mac’s copy once the copy online has been checked. “Bring back from the cloud” fetches it again.",
                                      "ar": "احذف نسخة هذا الماك بعد التحقق من النسخة على الإنترنت. يعيدها زر «أعده من السحابة» متى شئت."],
        "mac.storage_freed_one": ["en": "Freed {size}. The model is Online only now.", "ar": "وُفّر {size}. النموذج الآن «على الإنترنت فقط»."],
        "mac.storage_busy": ["en": "Another online storage task is running. Try again when it finishes.",
                             "ar": "تجري مهمة تخزين أخرى على الإنترنت. حاول مجددًا عند انتهائها."],
        "mac.storage_free_not_here": ["en": "This model’s file is not in the library folder on this Mac, so it was left alone.",
                                      "ar": "ملف هذا النموذج ليس في مجلد المكتبة على هذا الماك، لذا تُرك كما هو."],
        "mac.storage_free_in_use_q": ["en": "An open job uses this model", "ar": "عمل مفتوح يستخدم هذا النموذج"],
        "mac.storage_free_in_use": ["en": "Free Up Space never moves a model an open job needs. Remove this Mac’s copy anyway? It is fetched again when the job opens it.",
                                    "ar": "لا ينقل «توفير المساحة» أبدًا نموذجًا يحتاجه عمل مفتوح. هل تحذف نسخة هذا الماك رغم ذلك؟ ستُنزَّل مجددًا عندما يفتحه العمل."],
        "mac.storage_free_anyway": ["en": "Free Up Space Anyway", "ar": "وفّر المساحة رغم ذلك"],
        "mac.delete_kept_single": ["en": "One of these is set to Keep on This Mac. Remove from This Mac takes its copy here anyway and turns that off.",
                                "ar": "أحدها مضبوط على «إبقاء على هذا الماك». «إزالة من هذا الماك» ستحذف نسخته هنا رغم ذلك وتوقف هذا الخيار."],
        "mac.delete_kept_many": ["en": "{n} of these are set to Keep on This Mac. Remove from This Mac takes their copies here anyway and turns that off.",
                              "ar": "{n} منها مضبوطة على «إبقاء على هذا الماك». «إزالة من هذا الماك» ستحذف نسخها هنا رغم ذلك وتوقف هذا الخيار."],
        "mac.unarchive_both_one": ["en": "The converted copy stays in the library; you’ll have both.",
                                   "ar": "تبقى النسخة المحوّلة في المكتبة، وسيكون لديك الاثنتان."],
        "mac.unarchive_both_n": ["en": "{n} of these have a converted copy that stays in the library; you’ll have both of each.",
                                 "ar": "لـ{n} منها نسخ محوّلة تبقى في المكتبة، وسيكون لديك الاثنتان من كل منها."],
        "mac.storage_keep": ["en": "Keep on This Mac", "ar": "إبقاء على هذا الماك"],
        "mac.storage_keep_help": ["en": "Free Up Space never moves this model off this Mac. If it is online only, it is brought back first.",
                                  "ar": "لن ينقل «توفير المساحة» هذا النموذج من هذا الماك أبدًا. وإن كان على الإنترنت فقط فسيُعاد أولًا."],
        // A model's title (`Shop.rename`); the file keeps its own name.
        "mac.rename_model": ["en": "Rename", "ar": "إعادة تسمية"],
        "mac.rename_model_undo": ["en": "Rename Model", "ar": "إعادة تسمية النموذج"],
        "mac.archived_on": ["en": "Archived {date}", "ar": "أُرشف في {date}"],
        "mac.archived_undated": ["en": "Archived", "ar": "مؤرشف"],
        "mac.archive_help": ["en": "Take this model out of the library. Its file and its history stay, and Show ▸ Archived brings it back.",
                             "ar": "أخرج هذا النموذج من المكتبة. يبقى ملفه وسجله، ويعيده «عرض ▸ المؤرشفة»."],
        "mac.by_creator": ["en": "by {name}", "ar": "من تصميم {name}"],
        "mac.creator_show_all": ["en": "Show everything by this creator", "ar": "اعرض كل أعمال هذا المصمم"],
        "mac.duplicate_of": ["en": "The same model as {n} other in the library:", "ar": "النموذج نفسه موجود {n} مرة أخرى في المكتبة:"],
        "mac.libmove_title": ["en": "Where the library lives", "ar": "مكان المكتبة"],
        "mac.libmove_now": ["en": "Now", "ar": "الآن"],
        "mac.libmove_in_icloud": ["en": "In iCloud Drive. With Optimize Mac Storage on, macOS keeps models you have not opened in iCloud and brings each back when it is opened.", "ar": "في iCloud Drive. مع تفعيل تحسين مساحة التخزين، يُبقي macOS النماذج غير المفتوحة في iCloud ويعيد كل واحد منها عند فتحه."],
        "mac.libmove_use_icloud": ["en": "Use iCloud Drive", "ar": "استخدم iCloud Drive"],
        "mac.libmove_choose": ["en": "Choose a folder", "ar": "اختر مجلدًا"],
        "mac.libmove_choose_prompt": ["en": "Use this folder", "ar": "استخدم هذا المجلد"],
        "mac.libmove_back_home": ["en": "Back to this Mac\u{2019}s own folder", "ar": "عُد إلى مجلد هذا الماك"],
        "mac.libmove_hint": ["en": "The models already here move with it: each is copied, read back and compared, and only then is the original moved to the Trash. Nothing is overwritten, and a file that cannot be moved stays where it is.", "ar": "تنتقل النماذج الموجودة معها: يُنسخ كل ملف ويُقرأ ويُقارن، وبعدها فقط يُنقل الأصل إلى سلة المهملات. لا يُكتب فوق شيء، والملف الذي لا يمكن نقله يبقى مكانه."],
        "mac.libmove_confirm_title": ["en": "Move the print library?", "ar": "نقل مكتبة الطباعة؟"],
        "mac.libmove_confirm": ["en": "Move the library", "ar": "انقل المكتبة"],
        "mac.libmove_confirm_body": ["en": "New models will go to {path}, and the ones already here will be moved there. The originals go to the Trash only after each copy is checked.", "ar": "ستذهب النماذج الجديدة إلى {path}، وتُنقل الموجودة إليه. لا تذهب الأصول إلى سلة المهملات إلا بعد التحقق من كل نسخة."],
        "mac.libmove_not_writable": ["en": "Khayt cannot write to {path}.", "ar": "لا يستطيع خيط الكتابة في {path}."],
        "mac.libmove_nothing": ["en": "The library is in its new folder. There were no files to move.", "ar": "المكتبة في مجلدها الجديد. لم تكن هناك ملفات لنقلها."],
        "mac.libmove_no_room": ["en": "Not enough room in the new folder — {short} short. Nothing was moved; new models will still go there.", "ar": "لا مساحة كافية في المجلد الجديد — ينقص {short}. لم يُنقل شيء، وستذهب النماذج الجديدة إليه."],
        "mac.libmove_done": ["en": "Moved {n} files; {same} were already there.", "ar": "نُقل {n} ملفًا؛ و{same} كانت موجودة من قبل."],
        "mac.libmove_some_failed": ["en": "{n} files could not be moved and are where they were:", "ar": "تعذّر نقل {n} ملفًا وبقيت مكانها:"],
        "mac.linked_unlink_busy": ["en": "The library is busy with a scan or a move. Unlink the folder once it has finished.", "ar": "المكتبة مشغولة بفحص أو نقل. ألغِ ربط المجلد بعد انتهائه."],
        "mac.cloudlib_other_bucket": ["en": "This model is in the bucket {bucket}, which is not the one set up now, so it was not brought back.", "ar": "هذا النموذج في الحاوية {bucket}، وهي ليست الحاوية المعدّة الآن، لذا لم يُستعد."],
        "mac.cloudlib_not_there": ["en": "The bucket did not confirm the upload: the file is not there.", "ar": "لم تؤكد الحاوية الرفع: الملف غير موجود فيها."],
        "mac.cloudlib_wrong_size": ["en": "The bucket did not confirm the upload: it holds {there} bytes, not {here}.", "ar": "لم تؤكد الحاوية الرفع: فيها {there} بايت وليس {here}."],
        "mac.cloudlib_hash_mismatch": ["en": "The bucket did not confirm the upload: its content hash does not match.", "ar": "لم تؤكد الحاوية الرفع: بصمة المحتوى لا تطابق."],
        "mac.cloudlib_read_back_differs": ["en": "The bucket did not confirm the upload: what came back is not what went up.", "ar": "لم تؤكد الحاوية الرفع: ما عاد منها ليس ما رُفع إليها."],
        "mac.cloudlib_no_sidecar": ["en": "This model is not in the cloud.", "ar": "هذا النموذج ليس في السحابة."],
        "mac.cloudlib_bucket_lost_it": ["en": "The bucket no longer has this model.", "ar": "لم تعد الحاوية تحمل هذا النموذج."],
        "mac.cloudlib_bad_download": ["en": "The download did not match what left this Mac:", "ar": "ما نُزّل لا يطابق ما خرج من هذا الماك:"],
        "mac.gdrive_production": ["en": "In the Google Cloud console, set the OAuth consent screen to In production. Left in Testing, Google signs Khayt out every seven days.", "ar": "في Google Cloud، اضبط شاشة موافقة OAuth على وضع الإنتاج. إن بقيت في وضع الاختبار يُخرج Google خيط كل سبعة أيام."],
        "mac.gdrive_client_id": ["en": "OAuth client ID", "ar": "معرّف عميل OAuth"],
        "mac.gdrive_client_secret": ["en": "Client secret (if Google gave one)", "ar": "سرّ العميل (إن أعطاك Google واحدًا)"],
        "mac.gdrive_folder": ["en": "Folder in your Drive", "ar": "المجلد في Drive"],
        "mac.gdrive_own_client": ["en": "Use my own Google client", "ar": "استخدم عميل Google الخاص بي"],
        "mac.gdrive_open_page": ["en": "Open the sign-in page", "ar": "افتح صفحة تسجيل الدخول"],
        "mac.gdrive_copy_link": ["en": "Copy link", "ar": "انسخ الرابط"],
        "mac.gdrive_no_page_hint": ["en": "No Google page in your browser? Open it from here, or copy the link into your browser.", "ar": "لا تظهر صفحة Google في المتصفح؟ افتحها من هنا، أو انسخ الرابط إلى المتصفح."],
        "mac.gdrive_connect": ["en": "Connect Google Drive", "ar": "اربط Google Drive"],
        "mac.gdrive_disconnect": ["en": "Disconnect", "ar": "افصل"],
        "mac.gdrive_need_client": ["en": "Add the OAuth client ID from your Google Cloud project first.", "ar": "أضف معرّف عميل OAuth من مشروعك في Google Cloud أولًا."],
        "mac.gdrive_waiting": ["en": "Waiting for the sign-in in your browser…", "ar": "بانتظار تسجيل الدخول في المتصفح…"],
        "mac.gdrive_connected": ["en": "Google Drive connected.", "ar": "رُبط Google Drive."],
        "mac.portal_takedown_pending": ["en": "This customer was erased and their link is still on Khayt Cloud. Khayt keeps trying to take it down; you can try now.", "ar": "حُذف هذا العميل وما زال رابطه على خيط السحابي. يحاول خيط إزالته باستمرار، ويمكنك المحاولة الآن."],
        "mac.gdrive_disconnected_revoked": ["en": "Disconnected, and Google has withdrawn Khayt's access. Anything already in Drive stays there.", "ar": "فُصل الحساب وسحبت Google إذن خيط. ما في Drive يبقى هناك."],
        "mac.gdrive_disconnected": ["en": "Disconnected. Anything already in Drive stays there. To withdraw the access fully, remove Khayt at myaccount.google.com.", "ar": "فُصل الحساب. ما في Drive يبقى هناك. لسحب الإذن كاملًا، احذف خيط من myaccount.google.com."],
        "mac.gdrive_disconnect_warn": ["en": "Models that were moved to the cloud will not open until they are brought back — bring them back first.", "ar": "النماذج المنقولة إلى السحابة لن تُفتح حتى تُعاد — أعدها أولًا."],
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
        "mac.cloudlib_provider": ["en": "Provider", "ar": "المزوّد"],
        "mac.cloudlib_endpoint": ["en": "Endpoint", "ar": "نقطة الاتصال"],
        "mac.cloudlib_bucket": ["en": "Bucket", "ar": "الحاوية"],
        "mac.cloudlib_region": ["en": "Region", "ar": "المنطقة"],
        "mac.cloudlib_prefix": ["en": "Folder inside the bucket", "ar": "مجلد داخل الحاوية"],
        "mac.cloudlib_key_id": ["en": "Access key ID", "ar": "معرّف مفتاح الوصول"],
        "mac.cloudlib_secret": ["en": "Secret access key", "ar": "مفتاح الوصول السري"],
        "mac.cloudlib_back_up_all": ["en": "Back up the whole library now", "ar": "انسخ المكتبة كلها الآن"],
        "mac.cloudlib_test": ["en": "Test connection", "ar": "اختبار الاتصال"],
        "mac.cloudlib_free_now": ["en": "Free up space now", "ar": "وفّر المساحة الآن"],
        "mac.cloudlib_bring_all": ["en": "Bring everything back", "ar": "أعد كل شيء"],
        "mac.cloudlib_not_set_up": ["en": "Set up the bucket first: provider, bucket and access key.", "ar": "أعدّ الحاوية أولًا: المزوّد والحاوية ومفتاح الوصول."],
        "mac.cloudlib_test_ok": ["en": "Wrote, read back and removed a test file.", "ar": "كُتب ملف اختبار وقُرئ ثم حُذف."],
        "mac.cloudlib_test_mismatch": ["en": "The test file came back different from what was sent.", "ar": "عاد ملف الاختبار مختلفًا عمّا أُرسل."],
        "mac.cloudlib_test_failed": ["en": "The bucket refused:", "ar": "رفضت الحاوية:"],
        "mac.cloudlib_backup_some_failed": ["en": "{n} models could not be backed up.", "ar": "تعذّر نسخ {n} من النماذج."],
        "mac.cloudlib_backed_up_all": ["en": "Backed up {n} of {total} files.", "ar": "نُسخ {n} من {total} ملفات."],
        "mac.cloudlib_tier_off": ["en": "Switch on moving old models to the cloud first.", "ar": "فعّل نقل النماذج القديمة إلى السحابة أولًا."],
        "mac.cloudlib_freed": ["en": "Moved {n} of {total} models to the cloud, freeing {size}.", "ar": "نُقل {n} من {total} نماذج إلى السحابة، وتوفّرت {size}."],
        "mac.cloudlib_brought_back": ["en": "Brought back {n} models.", "ar": "أُعيد {n} من النماذج."],
        "mac.cloudlib_bring_back": ["en": "Bring back from the cloud", "ar": "أعده من السحابة"],
        "mac.cloudlib_bring_back_failed": ["en": "Could not bring it back:", "ar": "تعذّرت إعادته:"],
        "mac.cloudlib_in_cloud": ["en": "In the cloud", "ar": "في السحابة"],
        "mac.cloudlib_could_move": ["en": "{n} models could move to the cloud, freeing {size}. {cloud} already there.", "ar": "يمكن نقل {n} من النماذج إلى السحابة لتوفير {size}. {cloud} موجودة هناك."],
        "mac.cloudlib_progress": ["en": "{name} ({done} of {total})", "ar": "{name} ({done} من {total})"],
        "mac.cloudlib_saved": ["en": "Online storage saved.", "ar": "حُفظ التخزين السحابي."],
        // Online storage, built around Google Drive (CloudLibrarySettings.swift).
        "mac.gdrive_pitch": ["en": "Keep a copy of your models in your Google Drive, and free space on this Mac.", "ar": "احتفظ بنسخة من نماذجك في Google Drive، ووفّر المساحة على هذا الماك."],
        "mac.gdrive_recommended": ["en": "Recommended", "ar": "موصى به"],
        "mac.gdrive_is_connected": ["en": "Google Drive is connected", "ar": "تم ربط Google Drive"],
        "mac.gdrive_checking": ["en": "Asking Google for the account…", "ar": "جارٍ سؤال Google عن الحساب…"],
        "mac.gdrive_usage_of": ["en": "{used} of {limit} used", "ar": "مستخدم {used} من {limit}"],
        "mac.gdrive_usage": ["en": "{used} used", "ar": "مستخدم {used}"],
        "mac.gdrive_card_folder": ["en": "Models go in “{folder}” in your Drive", "ar": "تُحفظ النماذج في «{folder}» في Drive"],
        "mac.gdrive_waiting_title": ["en": "Finish signing in to Google in your browser", "ar": "أكمل تسجيل الدخول إلى Google في المتصفح"],
        "mac.gdrive_own_client_why": ["en": "Only for a shop with its own Google Cloud project. Use the same client on every computer, or each will see an empty folder.", "ar": "فقط لمتجر لديه مشروعه الخاص في Google Cloud. استخدم العميل نفسه على كل جهاز، وإلا رأى كل جهاز مجلدًا فارغًا."],
        "mac.gdrive_folder_fixed": ["en": "To use a different folder or your own Google client, disconnect first, then connect again.", "ar": "لاستخدام مجلد آخر أو عميل Google خاص بك، افصل الحساب أولًا ثم اربطه من جديد."],
        "mac.cloudlib_advanced": ["en": "Advanced", "ar": "متقدم"],
        "mac.cloudlib_use_bucket": ["en": "Use a storage bucket instead (S3, R2, B2…)", "ar": "استخدم حاوية تخزين بدلًا منه (S3 وR2 وB2…)"],
        "mac.cloudlib_use_drive": ["en": "Use Google Drive instead", "ar": "استخدم Google Drive بدلًا منها"],
        "mac.cloudlib_bucket_title": ["en": "Storage bucket", "ar": "حاوية تخزين"],
        "mac.cloudlib_bucket_why": ["en": "For a shop that already has an S3-compatible bucket. Google Drive needs none of this.", "ar": "لمتجر لديه حاوية متوافقة مع S3. لا يحتاج Google Drive إلى شيء من هذا."],
        "mac.cloudlib_options": ["en": "What Khayt keeps online", "ar": "ما يحفظه خيط على الإنترنت"],
        "mac.cloudlib_opt_copy": ["en": "Keep a copy of every model", "ar": "احتفظ بنسخة من كل نموذج"],
        "mac.cloudlib_opt_copy_why": ["en": "Each new model is copied online as it comes in, so a lost or broken Mac loses no models.", "ar": "يُنسخ كل نموذج جديد إلى الإنترنت عند إضافته، فلا تضيع النماذج إن فُقد الماك أو تعطّل."],
        "mac.cloudlib_opt_move": ["en": "Move models off this Mac when unused for", "ar": "انقل النماذج عن هذا الماك إن لم تُستخدم لمدة"],
        "mac.cloudlib_opt_move_why": ["en": "They stay listed in the library. To use one again, choose Bring back from the cloud on its page, or Bring everything back here. Models on an unfinished job are never moved, and nothing is removed from this Mac until the online copy has been checked.", "ar": "تبقى ظاهرة في المكتبة. لاستخدام أحدها مجددًا اختر «أعده من السحابة» في صفحته، أو «أعد كل شيء» هنا. لا تُنقل نماذج أي مهمة لم تنتهِ، ولا يُحذف شيء من هذا الماك قبل التحقق من النسخة على الإنترنت."],
        "mac.cloudlib_where_drive": ["en": "Google Drive", "ar": "حساب Google Drive"],
        "mac.cloudlib_where_bucket": ["en": "the storage bucket", "ar": "حاوية التخزين"],
        "mac.cloudlib_nothing_to_move": ["en": "Nothing to move: every model has been used recently or is on an unfinished job.", "ar": "لا شيء للنقل: كل النماذج استُخدمت مؤخرًا أو مرتبطة بمهمة لم تنتهِ."],
        "mac.cloudlib_free_confirm_title": ["en": "Move {n} models ({size}) off this Mac?", "ar": "نقل النماذج ({n}) بحجم {size} عن هذا الماك؟"],
        "mac.cloudlib_free_confirm": ["en": "Move Them Off This Mac", "ar": "انقلها عن هذا الماك"],
        "mac.cloudlib_free_confirm_body": ["en": "Each copy on this Mac is deleted once {where} has been checked to hold it, and {where} is then the only copy. To use one again, choose Bring back from the cloud on its page. {names}", "ar": "تُحذف نسخة كل نموذج من هذا الماك بعد التحقق من وجوده في {where}، فتصبح {where} النسخة الوحيدة. لاستخدام أحدها مجددًا اختر «أعده من السحابة» في صفحته. {names}"],
        "mac.cloudlib_and_more": ["en": "and {n} more", "ar": "و{n} غيرها"],
        "mac.cloudlib_missing": ["en": "Models moved online can no longer be found there: {n}. This Mac has no other copy.", "ar": "نماذج نُقلت إلى الإنترنت ولم تعد موجودة هناك: {n}. لا توجد نسخة أخرى على هذا الماك."],
        "mac.cloudlib_restore_trash": ["en": "Restore from Drive Trash", "ar": "استعدها من سلة Drive"],
        "mac.cloudlib_check_again": ["en": "Check again", "ar": "تحقق مجددًا"],
        "mac.cloudlib_restored_from_trash": ["en": "Restored from Drive's Trash: {n}.", "ar": "استُعيد من سلة Drive: {n}."],
        "mac.cloudlib_switch_blocked": ["en": "Models moved off this Mac are still on the online storage you are leaving: {n}. Bring them back first (Bring everything back), then switch.", "ar": "نماذج نُقلت عن هذا الماك ما زالت على التخزين الذي تتركه: {n}. أعدها أولًا («أعد كل شيء») ثم بدّل."],
        "mac.cloudlib_n_days": ["en": "{n} days", "ar": "{n} يومًا"],
        "mac.cloudlib_n_days_one": ["en": "{n} day", "ar": "يوم واحد"],
        "mac.cloudlib_n_days_two": ["en": "{n} days", "ar": "يومان"],
        "mac.cloudlib_n_days_few": ["en": "{n} days", "ar": "{n} أيام"],
        "mac.offsite_drive_suggest": ["en": "Google Drive is connected under Online storage. Send the nightly backup there?", "ar": "ربطتَ Google Drive في التخزين السحابي. أترسل النسخة الليلية إليه؟"],
        "mac.offsite_use_drive": ["en": "Use Google Drive", "ar": "استخدم Google Drive"],
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
        "mac.alert_title":   ["en": "Alerts on your iPhone", "ar": "التنبيهات على الآيفون"],
        "mac.alert_desc":    ["en": "When a print finishes, your iPhones are told through Khayt Cloud. Send a sample to check they receive it.", "ar": "عند انتهاء أي طباعة يصل تنبيه إلى أجهزة الآيفون عبر سحابة خيط. أرسل تنبيهًا تجريبيًا للتأكد من وصوله."],
        "mac.alert_test":    ["en": "Send a test alert", "ar": "إرسال تنبيه تجريبي"],
        "mac.alert_test_sent": ["en": "Sent. It should appear on your iPhone within a few seconds.", "ar": "أُرسل. يُفترض أن يظهر على الآيفون خلال ثوانٍ."],
        "mac.alert_test_limit": ["en": "Not sent: the shop has used its 60 alerts for this hour.", "ar": "لم يُرسل: استُهلكت التنبيهات الستون المسموح بها لهذه الساعة."],
        "mac.alert_test_not_offered": ["en": "Not sent: this Khayt Cloud does not take alerts yet.", "ar": "لم يُرسل: سحابة خيط هذه لا تستقبل التنبيهات بعد."],
        "mac.alert_test_failed": ["en": "Not sent. Check the connection and try again.", "ar": "لم يُرسل. تحقّق من الاتصال وأعد المحاولة."],
        "mac.alert_test_locked": ["en": "Unlock the cloud first (Book menu), then send the test.", "ar": "افتح قفل السحابة أولًا (قائمة الدفتر)، ثم أرسل التجربة."],
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
        // Customer records for the shop's own storefront (CustomerRecords.swift).
        "mac.cr_title":      ["en": "Customers on your web store", "ar": "العملاء في متجرك الإلكتروني"],
        "mac.cr_enable":     ["en": "Let your web store show customers their orders",
                              "ar": "اسمح لمتجرك بعرض طلبات العملاء لهم"],
        "mac.cr_hint":       ["en": "Sends each customer who has an email (name, phone and their orders) to Khayt Cloud, where your storefront can show them their own history once they sign in. This copy is not encrypted. Turning it off deletes it.",
                              "ar": "يرسل كل عميل له بريد إلكتروني (الاسم والهاتف وطلباته) إلى سحابة خيط، ليعرض متجرك على العميل سجله بعد أن يسجّل دخوله. هذه النسخة غير مشفّرة، وإيقاف الخيار يحذفها."],
        "mac.cr_held":       ["en": "Not available yet: it will be once Khayt's privacy policy covers this copy.",
                              "ar": "غير متاح بعد، ويتاح حين تشمل سياسة الخصوصية في خيط هذه النسخة."],
        "mac.cr_needs_cloud": ["en": "Sign in to Khayt Cloud to use this.", "ar": "سجّل الدخول إلى سحابة خيط لاستخدام هذا."],
        // ── Quote form for the shop's own store (khayt-cloud #144) ──────────
        "mac.qfe_files_count_one": ["en": "{n} file",
            "ar": "ملف واحد"],
        "mac.qfe_files_count_two": ["en": "{n} files",
            "ar": "ملفان"],
        "mac.qfe_files_count_few": ["en": "{n} files",
            "ar": "{n} ملفات"],
        "mac.qfe_origins_shared": ["en": "{origin} is shared by every store on that platform, so any of them could show your form. Use your store's own domain instead.",
            "ar": "{origin} عنوان تشترك فيه كل متاجر تلك المنصة، فيستطيع أي منها عرض نموذجك. استخدم نطاق متجرك الخاص بدلًا منه."],
        "mac.qfe_where": ["en": "Requests arrive in Catalogue › Online orders.",
            "ar": "تصل الطلبات إلى الكتالوج › الطلبات الإلكترونية."],
        "mac.qfe_open_requests": ["en": "Open requests",
            "ar": "فتح الطلبات"],
        "mac.qfe_preview": ["en": "Preview",
            "ar": "معاينة"],
        "mac.qfe_import": ["en": "Import as quote",
            "ar": "استيراد كعرض سعر"],
        "mac.qfe_qty": ["en": "Quantity: {n}",
            "ar": "الكمية: {n}"],
        "mac.qfe_made": ["en": "Quote {job} made for {name}.",
            "ar": "أُنشئ عرض السعر {job} للعميل {name}."],
        "mac.qfe_open_job": ["en": "Open",
            "ar": "فتح"],
        "mac.qfe_delete": ["en": "Delete…",
            "ar": "حذف…"],
        "mac.qfe_delete_q": ["en": "Delete the request from {name}?",
            "ar": "حذف الطلب المرسل من {name}؟"],
        "mac.qfe_delete_confirm": ["en": "Delete request",
            "ar": "حذف الطلب"],
        "mac.qfe_delete_why": ["en": "It is deleted from Khayt Cloud. Nothing is added to your book.",
            "ar": "يُحذف من سحابة خيط، ولا يُضاف شيء إلى دفترك."],
        "mac.qfe_delete_why_file": ["en": "It is deleted from Khayt Cloud with its file, {file}. Nothing is added to your book.",
            "ar": "يُحذف من سحابة خيط مع ملفه {file}، ولا يُضاف شيء إلى دفترك."],
        "mac.qfe_deleted": ["en": "The request was deleted.",
            "ar": "حُذف الطلب."],
        "mac.qfe_waiting": ["en": "{n} quote requests waiting",
            "ar": "{n} طلب تسعير بالانتظار"],
        "mac.qfe_waiting_one": ["en": "{n} quote request waiting",
            "ar": "طلب تسعير واحد بالانتظار"],
        "mac.qfe_waiting_two": ["en": "{n} quote requests waiting",
            "ar": "طلبا تسعير بالانتظار"],
        "mac.qfe_waiting_few": ["en": "{n} quote requests waiting",
            "ar": "{n} طلبات تسعير بالانتظار"],
        "mac.qfe_notify_title": ["en": "New quote request",
            "ar": "طلب تسعير جديد"],
        "mac.qfe_notify_body": ["en": "{name}: {title}",
            "ar": "{name}: {title}"],
        "mac.qfe_send_whatsapp": ["en": "Send quote by WhatsApp",
            "ar": "إرسال العرض عبر واتساب"],
        "mac.qfe_send_email": ["en": "Send quote by email",
            "ar": "إرسال العرض بالبريد"],
        "mac.qfe_send_text": ["en": "Your quote from {shop} is ready. You can review and approve it here: {link}",
            "ar": "عرض السعر من {shop} جاهز. يمكنك مراجعته واعتماده من هنا: {link}"],
        "mac.qfe_send_subject": ["en": "Your quote from {shop}",
            "ar": "عرض السعر من {shop}"],
        "mac.qfe_send_no_phone": ["en": "This customer has no phone number WhatsApp can use.",
            "ar": "لا يوجد لهذا العميل رقم يصلح لواتساب."],
        "mac.qfe_send_no_app": ["en": "WhatsApp is not installed, so the message is copied — paste it in a chat.",
            "ar": "واتساب غير مثبّت، فنُسخت الرسالة — الصقها في محادثة."],
        "mac.qfe_send_no_email": ["en": "This customer has no email address.",
            "ar": "لا يوجد لهذا العميل بريد إلكتروني."],
        "mac.qfe_title":      ["en": "Quote form for your store", "ar": "نموذج التسعير لمتجرك"],
        "mac.qfe_desc": ["en": "A visitor to your web store uploads a model, sees a price from your published quote sheet, and can send it to you as a request — with the file. Unlike the instant quote on your Wi‑Fi above, Khayt Cloud keeps the visitor's file for 14 days so it arrives with the request.",
            "ar": "يرفع زائر متجرك موديلًا، فيرى سعرًا من جدول التسعير المنشور، ويستطيع إرساله إليك طلبًا مع الملف. وبخلاف التسعير الفوري على شبكة الواي فاي أعلاه، تحتفظ سحابة خيط بملف الزائر 14 يومًا ليصلك مع الطلب."],
        "mac.qfe_needs_cloud": ["en": "Connect this Mac to Khayt Cloud to put a quote form on your store.",
                                "ar": "اربط هذا الماك بسحابة خيط لتضع نموذج التسعير في متجرك."],
        "mac.qfe_not_available": ["en": "Not available yet. The quote form will open here once Khayt Cloud switches it on.",
                                  "ar": "غير متاح بعد. سيظهر نموذج التسعير هنا حين تفعّله سحابة خيط."],
        "mac.qfe_try_again":  ["en": "Try again", "ar": "حاول مجددًا"],
        "mac.qfe_enable": ["en": "Accept quote requests from my store",
            "ar": "استقبال طلبات التسعير من متجري"],
        "mac.qfe_no_price":   ["en": "The form cannot give a price: no quote sheet is published. Turn on “Let customers price their own model” in the instant quote settings above, with this Mac connected to Khayt Cloud.",
                               "ar": "لا يستطيع النموذج إعطاء سعر: لا يوجد جدول تسعير منشور. فعّل «دع العملاء يسعّرون نماذجهم» في إعدادات التسعير الفوري أعلاه، مع ربط هذا الماك بسحابة خيط."],
        "mac.qfe_no_files":   ["en": "Requests arrive WITHOUT the customer's file: Khayt Cloud is not keeping uploaded files for this shop.",
                               "ar": "تصل الطلبات بلا ملف العميل: سحابة خيط لا تحتفظ بالملفات المرفوعة لهذا المتجر."],
        "mac.qfe_files":      ["en": "Files kept", "ar": "الملفات المحفوظة"],
        "mac.qfe_files_count": ["en": "{n} files",
            "ar": "{n} ملفًا"],
        "mac.qfe_files_count_of": ["en": "{n} of {max} files",
            "ar": "{n} من أصل {max} ملفًا"],
        "mac.qfe_files_each": ["en": "up to {size} each", "ar": "حتى {size} للملف"],
        "mac.qfe_month":      ["en": "This month", "ar": "هذا الشهر"],
        "mac.qfe_month_line": ["en": "{quotes} prices given · {requests} requests sent",
                               "ar": "{quotes} سعرًا معروضًا · {requests} طلبًا مرسلًا"],
        "mac.qfe_origins":    ["en": "Websites allowed to show the form in a frame", "ar": "المواقع المسموح لها بعرض النموذج داخل إطار"],
        "mac.qfe_origins_hint": ["en": "One per line, exactly like https://shop.example or https://shop.example:8443 — no path, no slash at the end, no *. At most {n}. Use your store's own domain: a platform's shared address lets other stores show your form.",
            "ar": "واحد في كل سطر، بالشكل https://shop.example أو https://shop.example:8443 تمامًا، بلا مسار ولا شرطة في آخره ولا *. {n} على الأكثر. استخدم نطاق متجرك الخاص: العنوان المشترك لمنصة ما يتيح لمتاجر أخرى عرض نموذجك."],
        "mac.qfe_save":       ["en": "Save", "ar": "حفظ"],
        "mac.qfe_managers_only": ["en": "Only the shop's owner or a manager can change the quote form.",
                                  "ar": "لا يغيّر نموذج التسعير إلا مالك المتجر أو مدير."],
        "mac.qfe_lang":       ["en": "Language", "ar": "اللغة"],
        "mac.qfe_theme":      ["en": "Look", "ar": "المظهر"],
        "mac.qfe_theme_light": ["en": "Light", "ar": "فاتح"],
        "mac.qfe_theme_dark": ["en": "Dark", "ar": "داكن"],
        "mac.qfe_link": ["en": "Link (works on Salla, Zid and any store)",
            "ar": "رابط (يعمل في سلة وزد وأي متجر)"],
        "mac.qfe_link_hint": ["en": "Add it to your store as a button or a menu link. It works everywhere, including Salla and Zid. Use this one if you are unsure.",
            "ar": "أضفه إلى متجرك زرًّا أو رابطًا في القائمة. يعمل في كل مكان، ومنها سلة وزد. استخدمه إن لم تكن متأكدًا."],
        "mac.qfe_frame":      ["en": "Frame", "ar": "إطار"],
        "mac.qfe_frame_hint": ["en": "Shows the form inside a page — only if your store lets you paste HTML, which Salla and Zid may not. Only the websites listed above can frame it.",
            "ar": "يعرض النموذج داخل صفحة — فقط إن سمح متجرك بلصق HTML، وقد لا تسمح بذلك سلة وزد. لا يعرضه داخل إطار إلا المواقع المذكورة أعلاه."],
        "mac.qfe_script":     ["en": "Script", "ar": "سكربت"],
        "mac.qfe_script_hint": ["en": "Only if your store lets you paste a script tag. Salla and Zid may not allow it.",
            "ar": "فقط إن سمح متجرك بلصق وسم سكربت. قد لا تسمح بذلك سلة وزد."],
        "mac.qfe_copy":       ["en": "Copy", "ar": "نسخ"],
        "mac.qfe_copied":     ["en": "Copied", "ar": "نُسخ"],
        "mac.qfe_err_unauthorised": ["en": "Khayt Cloud did not accept this sign-in.", "ar": "لم تقبل سحابة خيط تسجيل الدخول هذا."],
        "mac.qfe_err_origin": ["en": "Not an address the form can be framed on: {value}. Use https://host or https://host:port.",
                               "ar": "عنوان لا يمكن تأطير النموذج عليه: {value}. استخدم https://host أو https://host:port."],
        "mac.qfe_err_too_many": ["en": "At most {n} websites.", "ar": "{n} مواقع على الأكثر."],
        "mac.qfe_err_malformed": ["en": "Khayt Cloud answered with something this app could not read.",
                                  "ar": "ردّت سحابة خيط بما لا يستطيع التطبيق قراءته."],
        // The request's file, on the online orders sheet.
        "mac.qfe_chip":       ["en": "Quote form", "ar": "نموذج التسعير"],
        "mac.qfe_file_until": ["en": "kept until {day}", "ar": "محفوظ حتى {day}"],
        "mac.qfe_file_gone":  ["en": "file expired", "ar": "انتهت صلاحية الملف"],
        "mac.qfe_file_expired_note": ["en": "The customer's file ({name}) had expired on Khayt Cloud before this request was imported. Ask them to send it again.",
                                      "ar": "انتهت صلاحية ملف العميل ({name}) في سحابة خيط قبل استيراد هذا الطلب. اطلب منه إرساله مجددًا."],
        "mac.qfe_file_not_taken_note": ["en": "The customer's file ({name}) was empty, so there was nothing to keep. Ask them to send it again.",
            "ar": "كان ملف العميل ({name}) فارغًا فلم يكن هناك ما يُحفظ. اطلب منه إرساله مجددًا."],
        "mac.qfe_imported_not_taken": ["en": "Imported without the file: it was empty. The job says so.",
            "ar": "استُورد بلا الملف لأنه فارغ، والعمل يذكر ذلك."],
        "mac.qfe_note_link": ["en": "Model link from the customer: {link}", "ar": "رابط الموديل من العميل: {link}"],
        "mac.qfe_note_contact": ["en": "Contact: {contact}", "ar": "التواصل: {contact}"],
        "mac.qfe_file_lost_note": ["en": "The customer's file ({name}) was missing on Khayt Cloud, and the request was imported without it. Ask them to send it again.",
                                   "ar": "كان ملف العميل ({name}) مفقودًا في سحابة خيط، فاستُورد الطلب بدونه. اطلب منه إرساله مجددًا."],
        "mac.qfe_import_without_file": ["en": "Import without the file", "ar": "استيراد بدون الملف"],
        "mac.qfe_without_file_q": ["en": "Import this request without its file?", "ar": "استيراد هذا الطلب بدون ملفه؟"],
        "mac.qfe_without_file_why": ["en": "Khayt Cloud cannot find the customer's file. The request becomes a quote with a note saying the file is missing, and it leaves the requests inbox. Ask the customer to send the file again.",
                                     "ar": "لا تجد سحابة خيط ملف العميل. يصبح الطلب عرض سعر مع ملاحظة بأن الملف مفقود، ويخرج من صندوق الطلبات. اطلب من العميل إرسال الملف مجددًا."],
        "mac.qfe_auto_import": ["en": "Import requests as quotes automatically", "ar": "استيراد الطلبات كعروض أسعار تلقائيًا"],
        "mac.qfe_auto_import_hint": ["en": "On this Mac. Each request becomes an unnumbered quote with its file, and nothing is sent to the customer until you send the quote.",
                                     "ar": "على هذا الماك. يصبح كل طلب عرض سعر بلا رقم مع ملفه، ولا يُرسل شيء إلى العميل حتى ترسل عرض السعر بنفسك."],
        "mac.qfe_link_licence": ["en": "A model from {site}: check its licence allows selling prints before you quote. Many there are for personal use only.",
                                 "ar": "موديل من {site}: تحقّق أن ترخيصه يسمح ببيع المطبوعات قبل التسعير، فكثير منها للاستخدام الشخصي فقط."],
        "mac.qfe_err_missing_early": ["en": "Khayt Cloud has no file for this request, though it should still be kept. Nothing was imported; try again later or tell Khayt support.",
                                      "ar": "لا يوجد ملف لهذا الطلب في سحابة خيط مع أنه يُفترض أن يكون محفوظًا. لم يُستورد شيء؛ أعد المحاولة لاحقًا أو راسل دعم خيط."],
        "mac.qfe_shown_note": ["en": "The quote form showed the customer {price} for a quantity of {qty} (an estimate, not binding).",
                               "ar": "عرض نموذج التسعير على العميل {price} لكمية {qty} (تقدير غير ملزم)."],
        "mac.qfe_shown_note_unreliable": ["en": "The quote form showed the customer {price} for a quantity of {qty}, marked as a rough estimate: the model was hard to measure.",
                                          "ar": "عرض نموذج التسعير على العميل {price} لكمية {qty}، موسومًا بأنه تقدير تقريبي لصعوبة قياس الموديل."],
        "mac.qfe_file_held_note": ["en": "The customer sent a file ({name}) that is not a model, so it was kept out of the library and saved here instead: {path}. Check it before sending anything to a printer.",
                                    "ar": "أرسل العميل ملفًا ({name}) ليس نموذجًا، فلم يُضف إلى المكتبة وحُفظ هنا بدلًا من ذلك: {path}. افحصه قبل إرسال أي شيء إلى الطابعة."],
        "mac.qfe_imported_held": ["en": "Imported. The file was not a model, so it was saved beside the book rather than in the library. The job says where.",
            "ar": "استُورد الطلب. الملف ليس موديلًا فحُفظ بجانب الدفتر لا في المكتبة، والعمل يذكر مكانه."],
        "mac.qfe_imported_expired": ["en": "Imported without the file: it had already expired on Khayt Cloud. The job says so.",
            "ar": "استُورد بلا الملف لأن صلاحيته انتهت في سحابة خيط، والعمل يذكر ذلك."],
        "mac.qfe_kept": ["en": "Kept in the requests inbox, with its file:",
            "ar": "بقي في صندوق الطلبات مع ملفه:"],
        "mac.qfe_err_not_offered": ["en": "Khayt Cloud has the quote form switched off, so the file cannot be fetched yet.",
                                    "ar": "نموذج التسعير متوقف في سحابة خيط، فلا يمكن جلب الملف بعد."],
        "mac.qfe_err_download": ["en": "the file could not be downloaded ({why}).", "ar": "تعذّر تنزيل الملف ({why})."],
        "mac.qfe_err_checksum": ["en": "the downloaded file did not match what was uploaded, so nothing was imported.",
                                 "ar": "الملف المنزّل لا يطابق ما رُفع، فلم يُستورد شيء."],
        "mac.qfe_err_size":   ["en": "the downloaded file was {got}, not {expected}, so nothing was imported.",
                               "ar": "حجم الملف المنزّل {got} وليس {expected}، فلم يُستورد شيء."],
        "mac.qfe_err_write":  ["en": "the book did not take the request ({why}).", "ar": "لم يقبل الدفتر الطلب ({why})."],
        "mac.cr_published":  ["en": "Sent to Khayt Cloud. Customers: {count}.", "ar": "أُرسل إلى سحابة خيط. عدد العملاء: {count}."],
        "mac.cr_trimmed":    ["en": "To fit Khayt Cloud's 4 MB, left out: older orders {orders}, customers {people}.",
                              "ar": "لتتسع النسخة لحد سحابة خيط (4 ميجابايت) تُرك: طلبات أقدم {orders}، عملاء {people}."],
        "mac.cr_deleted":    ["en": "Deleted from Khayt Cloud.", "ar": "حُذف من سحابة خيط."],
        // WhatsApp delivery reports by way of Khayt Cloud (WhatsAppReports.swift).
        "mac.wa_hook_title": ["en": "WhatsApp delivery reports", "ar": "تقارير تسليم واتساب"],
        "mac.wa_hook_hint":  ["en": "Meta tells Khayt Cloud whether each WhatsApp message was delivered and read, and Khayt shows it on the customer's log beside each message sent through Meta. A message opened in the WhatsApp app is not reported. Paste your Meta app's secret, then enter the address and verify token below in Meta (WhatsApp → Configuration → Webhook) and subscribe to \"messages\".",
                              "ar": "يبلّغ Meta سحابة خيط بوصول كل رسالة واتساب وقراءتها، ويعرض خيط ذلك في سجل العميل بجانب كل رسالة أُرسلت عبر Meta. الرسالة التي تُفتح في تطبيق واتساب لا يصل عنها تقرير. الصق السر الخاص بتطبيقك في Meta، ثم أدخل العنوان ورمز التحقق أدناه في Meta (WhatsApp ← Configuration ← Webhook) واشترك في \"messages\"."],
        "mac.wa_app_secret": ["en": "Meta app secret", "ar": "سر تطبيق Meta"],
        "mac.wa_hook_connect": ["en": "Connect", "ar": "ربط"],
        "mac.wa_hook_url":   ["en": "Callback address", "ar": "عنوان الاستدعاء"],
        "mac.wa_hook_verify": ["en": "Verify token", "ar": "رمز التحقق"],
        "mac.wa_hook_last":  ["en": "Last report: {at}", "ar": "آخر تقرير: {at}"],
        "mac.wa_hook_none_yet": ["en": "No report from Meta yet.", "ar": "لم يصل تقرير من Meta بعد."],
        "mac.wa_hook_remove": ["en": "Remove", "ar": "إزالة"],
        "mac.wa_hook_owner_only": ["en": "Only the shop's owner or a manager can set this up.",
                                   "ar": "يمكن لمالك المحل أو المدير فقط إعداد هذا."],
        "mac.cr_failed":     ["en": "Could not reach Khayt Cloud.", "ar": "تعذّر الوصول إلى سحابة خيط."],
        "mac.cr_err_unauthorised": ["en": "Khayt Cloud did not accept this shop's sign-in. Sign in to Khayt Cloud again.",
                                    "ar": "لم تقبل سحابة خيط تسجيل دخول هذا المحل. سجّل الدخول إلى سحابة خيط مرة أخرى."],
        "mac.cr_err_read_only": ["en": "This sign-in can read the shop but cannot send its customers.",
                                 "ar": "تسجيل الدخول هذا يقرأ المحل لكنه لا يستطيع إرسال عملائه."],
        "mac.cr_err_not_offered": ["en": "Khayt Cloud does not take customer records yet.",
                                   "ar": "لا تستقبل سحابة خيط سجلات العملاء بعد."],
        "mac.cr_err_too_large": ["en": "More customers than Khayt Cloud keeps (5000, or 4 MB).",
                                 "ar": "عدد العملاء أكبر مما تحفظه سحابة خيط (5000 أو 4 ميغابايت)."],
        "mac.cr_err_limited": ["en": "Khayt Cloud asked for fewer sends. Khayt will try again later.",
                               "ar": "طلبت سحابة خيط تقليل الإرسال. سيعيد خيط المحاولة لاحقًا."],
        "mac.loyalty_changed": ["en": "This customer's points changed on another device. Look again and redeem what is left.",
                                "ar": "تغيّرت نقاط هذا العميل على جهاز آخر. راجعها ثم استبدل المتبقي."],
        "mac.cr_off_elsewhere": ["en": "Customer records were turned off for this shop on another Mac, so they are off here too. Turn them on again to publish.",
                                 "ar": "أُوقفت سجلات العملاء لهذا المتجر على جهاز ماك آخر، فأُوقفت هنا أيضًا. شغّلها مجددًا للنشر."],
        "mac.lib_err_not_ours": ["en": "Another app has this book open.", "ar": "تطبيق آخر يفتح هذا الدفتر."],
        "mac.lib_err_no_library": ["en": "This Mac has no print library folder.", "ar": "لا يوجد مجلد لمكتبة الطباعة على هذا الماك."],
        "mac.lib_err_unknown_kind": ["en": "Khayt does not read .{ext} files.", "ar": "لا يقرأ خيط ملفات ‎.{ext}‎."],
        "mac.lib_err_already_here": ["en": "{name} is already in the library.", "ar": "{name} موجود في المكتبة بالفعل."],
        "mac.lib_err_failed": ["en": "Could not add the file: {why}", "ar": "تعذّرت إضافة الملف: {why}"],
        "mac.conv_err_unreadable": ["en": "Could not read the 3MF: {why}", "ar": "تعذّرت قراءة ملف 3MF: {why}"],
        "mac.conv_err_mesh_too_big": ["en": "A colour plan has to rewrite the model itself, and {name} is {mb} MB, more than the {cap} MB this app will bring in at once. Convert it in Khayt, or retarget it here without a colour plan.",
                                      "ar": "خطة الألوان تعيد كتابة النموذج نفسه، و{name} حجمه {mb} ميغابايت، أكثر من {cap} ميغابايت يجلبها هذا التطبيق دفعة واحدة. حوّله في خيط، أو أعد توجيهه هنا دون خطة ألوان."],
        "mac.conv_err_too_big": ["en": "This 3MF unpacks to {mb} MB, more than the {cap} MB a conversion will hold at once.",
                                 "ar": "يتوسّع ملف 3MF هذا إلى {mb} ميغابايت، أكثر من {cap} ميغابايت تتسع لها عملية تحويل واحدة."],
        "mac.store_too_large": ["en": "That change would make the book larger than a backup can hold, so nothing was written.",
                                "ar": "هذا التغيير يجعل الدفتر أكبر مما تتسع له النسخة الاحتياطية، فلم يُكتب شيء."],
        "mac.store_unreadable": ["en": "Could not read the book to change it: {why}", "ar": "تعذّرت قراءة الدفتر لتعديله: {why}"],
        "mac.write_refused_nothing": ["en": "Nothing was changed: only the app that has the book open may write to it.",
                                      "ar": "لم يتغيّر شيء: وحده التطبيق الذي يفتح الدفتر يمكنه الكتابة فيه."],
        "mac.secret_locked": ["en": "The saved password or key is locked: Khayt keeps it in your login Keychain, and this app was not given access to it.",
                              "ar": "كلمة المرور أو المفتاح المحفوظ مقفل: يحفظه خيط في سلسلة مفاتيح الدخول، ولم يُمنح هذا التطبيق الوصول إليه."],
        "mac.secret_unreadable": ["en": "The saved password or key could not be read. Type it again.",
                                  "ar": "تعذّرت قراءة كلمة المرور أو المفتاح المحفوظ. اكتبه من جديد."],
        "mac.cloud_err_http": ["en": "Khayt Cloud answered with error {code}.", "ar": "ردّت سحابة خيط بالخطأ {code}."],
        "mac.wa_err_unauthorised": ["en": "Khayt Cloud did not accept this shop's sign-in. Sign in to Khayt Cloud again.",
                                    "ar": "لم تقبل سحابة خيط تسجيل دخول هذا المحل. سجّل الدخول إلى سحابة خيط مرة أخرى."],
        "mac.wa_err_not_offered": ["en": "Khayt Cloud does not take WhatsApp reports yet.",
                                   "ar": "لا تستقبل سحابة خيط تقارير واتساب بعد."],
        "mac.wa_err_bad_secret": ["en": "That is not a Meta app secret (16 to 128 letters and digits).",
                                  "ar": "هذا ليس سر تطبيق Meta (من 16 إلى 128 حرفًا ورقمًا)."],
        "mac.wa_status_sent": ["en": "Sent", "ar": "أُرسلت"],
        "mac.wa_status_delivered": ["en": "Delivered", "ar": "وصلت"],
        "mac.wa_status_read": ["en": "Read", "ar": "قُرئت"],
        "mac.wa_status_failed": ["en": "Not delivered", "ar": "لم تصل"],
        "mac.qs_last":       ["en": "Storefront prices", "ar": "أسعار المتجر"],
        "mac.qs_published":  ["en": "Sent to Khayt Cloud for your storefront.", "ar": "أُرسلت إلى سحابة خيط لمتجرك."],
        "mac.qs_withdrawn":  ["en": "Withdrawn from your storefront.", "ar": "سُحبت من متجرك."],
        "mac.qs_not_offered": ["en": "Khayt Cloud does not take storefront prices yet.", "ar": "لا تستقبل سحابة خيط أسعار المتجر بعد."],
        "mac.qs_failed":     ["en": "Not sent:", "ar": "لم تُرسل:"],
        "mac.qs_needs_cloud": ["en": "Sign in to the cloud (Book menu) so your storefront can use these prices.", "ar": "سجّل الدخول إلى السحابة (قائمة الدفتر) ليستخدم متجرك هذه الأسعار."],
        // The shop's order-import key (Integrations). Shown once; never stored here.
        "mac.ik_title":      ["en": "Import key", "ar": "مفتاح الاستيراد"],
        "mac.ik_explain":    ["en": "Your import link is public, so Khayt only trusts an order's payment and prices when your store sends this key. With it, paid web-store orders become jobs by themselves.", "ar": "رابط الاستيراد عام، لذلك لا يثق خيط بحالة الدفع والأسعار إلا إذا أرسل متجرك هذا المفتاح. معه تتحول طلبات المتجر المدفوعة إلى أعمال تلقائيًا."],
        "mac.ik_checking":   ["en": "Checking…", "ar": "جارٍ التحقق…"],
        "mac.ik_unknown":    ["en": "Could not check the import key.", "ar": "تعذّر التحقق من مفتاح الاستيراد."],
        "mac.ik_none":       ["en": "No key set. Orders are accepted from anyone who has the link, and are not trusted as paid.", "ar": "لا يوجد مفتاح. تُقبل الطلبات من أي شخص لديه الرابط، ولا تُعتبر مدفوعة."],
        "mac.ik_set":        ["en": "A key is set.", "ar": "يوجد مفتاح."],
        "mac.ik_set_since":  ["en": "A key is set, created {date}.", "ar": "يوجد مفتاح، أُنشئ في {date}."],
        "mac.ik_create":     ["en": "Create Key", "ar": "إنشاء مفتاح"],
        "mac.ik_replace":    ["en": "Replace Key", "ar": "استبدال المفتاح"],
        "mac.ik_remove":     ["en": "Remove Key", "ar": "إزالة المفتاح"],
        "mac.ik_copy":       ["en": "Copy", "ar": "نسخ"],
        "mac.ik_copied":     ["en": "Copied", "ar": "تم النسخ"],
        "mac.ik_shown_once": ["en": "This is the only time the key is shown. Set it as KHAYT_IMPORT_KEY in your Medusa server's environment, then restart the server.", "ar": "هذه المرة الوحيدة التي يظهر فيها المفتاح. عيّنه باسم KHAYT_IMPORT_KEY في متغيرات بيئة خادم Medusa، ثم أعد تشغيل الخادم."],
        "mac.ik_other_links": ["en": "Any other store that sends orders to an import link needs the key too: add ?key= and the key to the end of that link.", "ar": "أي متجر آخر يرسل الطلبات إلى رابط استيراد يحتاج المفتاح أيضًا: أضف ?key= والمفتاح إلى نهاية ذلك الرابط."],
        "mac.ik_create_title": ["en": "Create an import key?", "ar": "إنشاء مفتاح استيراد؟"],
        "mac.ik_create_body": ["en": "Once a key exists, Khayt refuses orders that do not carry it. Set it in your store straight away, or new orders will not arrive.", "ar": "بمجرد وجود المفتاح يرفض خيط الطلبات التي لا تحمله. عيّنه في متجرك فورًا، وإلا فلن تصل الطلبات الجديدة."],
        "mac.ik_replace_title": ["en": "Replace the import key?", "ar": "استبدال مفتاح الاستيراد؟"],
        "mac.ik_replace_body": ["en": "The old key keeps working for 2 hours, so your store can switch to the new one with no refused orders. If the old key may be in the wrong hands, stop it now instead.", "ar": "يبقى المفتاح القديم يعمل ساعتين، ليتمكن متجرك من الانتقال إلى الجديد دون رفض أي طلب. وإن كان المفتاح القديم قد وقع في أيدٍ أخرى، فأوقفه الآن بدلاً من ذلك."],
        "mac.ik_replace_now": ["en": "Replace and Stop the Old Key Now", "ar": "استبدال وإيقاف المفتاح القديم الآن"],
        "mac.ik_overlap_until": ["en": "The old key still works until {time}.", "ar": "يبقى المفتاح القديم يعمل حتى {time}."],
        "mac.ik_end_overlap": ["en": "Stop the Old Key", "ar": "إيقاف المفتاح القديم"],
        "mac.ik_end_overlap_title": ["en": "Stop the old key now?", "ar": "إيقاف المفتاح القديم الآن؟"],
        "mac.ik_end_overlap_body": ["en": "Orders sent with the old key are refused from now on. Do this once your store is using the new key.", "ar": "تُرفض من الآن الطلبات المرسلة بالمفتاح القديم. افعل ذلك بعد أن يستخدم متجرك المفتاح الجديد."],
        "mac.ik_remove_title": ["en": "Remove the import key?", "ar": "إزالة مفتاح الاستيراد؟"],
        "mac.ik_remove_body": ["en": "Your import link will accept orders from anyone again, and no order will be trusted as paid.", "ar": "سيقبل رابط الاستيراد الطلبات من أي شخص مجددًا، ولن يُعتبر أي طلب مدفوعًا."],
        "mac.ik_err_role":   ["en": "Only the shop's owner or a manager can manage the import key, and this sign-in is neither.", "ar": "لا يدير مفتاح الاستيراد إلا مالك المتجر أو مدير، وهذا الحساب ليس أيًا منهما."],
        "mac.ik_err_not_offered": ["en": "Khayt Cloud does not offer an import key yet.", "ar": "لا توفر سحابة خيط مفتاح استيراد بعد."],
        "mac.ik_err_generic": ["en": "Could not reach Khayt Cloud about the import key.", "ar": "تعذّر الاتصال بسحابة خيط بشأن مفتاح الاستيراد."],
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
                                    "ar": "تم تسجيل الدخول. يستطيع هذا الماك الوصول إلى سحابة المشغل."],
        "mac.cloud_signin_failed": ["en": "Could not sign in:",
                                    "ar": "تعذّر تسجيل الدخول:"],
        "mac.cloud_wrong_passphrase": [
            "en": "Signed in, but that sync passphrase does not open this shop's key — nothing was saved.",
            "ar": "تم تسجيل الدخول، لكن عبارة المزامنة لا تفتح مفتاح هذا المشغل — لم يُحفظ شيء."],
        "mac.cloud_key_local": [
            "en": "The server did not send a sync key, so this Mac used the one already in your book. It opened — but the cloud has no copy to give another machine, so keep your recovery key safe.",
            "ar": "لم يرسل الخادم مفتاح مزامنة، فاستخدم هذا الماك المفتاح الموجود في دفترك. فُتح المفتاح — لكن لا توجد نسخة لدى السحابة لتعطيها لجهاز آخر، فاحتفظ بمفتاح الاسترداد."],
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
        "mac.webhooks_sent":   ["en": "Told {n} other systems.",
                                "ar": "أُبلغ {n} نظامًا آخر."],
        "mac.webhooks_sent_one": ["en": "Told {n} other system.", "ar": "أُبلغ نظام آخر واحد."],
        "mac.webhooks_sent_two": ["en": "Told 2 other systems.", "ar": "أُبلغ نظامان آخران."],
        "mac.webhooks_sent_few": ["en": "Told {n} other systems.", "ar": "أُبلغت {n} أنظمة أخرى."],
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
        "mac.restore_wait_sync": ["en": "A cloud sync is still running. Nothing was restored — try again in a moment.",
                                  "ar": "ما زالت مزامنة السحابة جارية. لم يُستعد شيء — حاول مرة أخرى بعد لحظة."],
        // What automatic sync took from this book. Copies are kept in
        // sync-conflicts/ beside the backups; the banner offers them back.
        // One clause per count that is not zero, each counted on its own:
        // "replaced 1 record(s) … and removed 0" was a sentence that had not
        // decided. Arabic's clauses carry their own subject.
        "mac.losses_banner":   ["en": "Sync {what}. A copy of each was kept.",
                              "ar": "{what}. حُفظت نسخة من كل منها."],
        "mac.losses_replaced_n": ["en": "replaced {n} records changed on this Mac",
                                  "ar": "استبدلت المزامنة {n} سجلًا عُدّل على هذا الماك"],
        "mac.losses_replaced_n_one": ["en": "replaced {n} record changed on this Mac",
                                      "ar": "استبدلت المزامنة سجلًا واحدًا عُدّل على هذا الماك"],
        "mac.losses_replaced_n_two": ["en": "replaced 2 records changed on this Mac",
                                      "ar": "استبدلت المزامنة سجلّين عُدّلا على هذا الماك"],
        "mac.losses_replaced_n_few": ["en": "replaced {n} records changed on this Mac",
                                      "ar": "استبدلت المزامنة {n} سجلات عُدّلت على هذا الماك"],
        "mac.losses_removed_n": ["en": "removed {n} records", "ar": "حذفت المزامنة {n} سجلًا"],
        "mac.losses_removed_n_one": ["en": "removed {n} record", "ar": "حذفت المزامنة سجلًا واحدًا"],
        "mac.losses_removed_n_two": ["en": "removed 2 records", "ar": "حذفت المزامنة سجلّين"],
        "mac.losses_removed_n_few": ["en": "removed {n} records", "ar": "حذفت المزامنة {n} سجلات"],
        "mac.losses_head": ["en": "What sync took from this book",
                                 "ar": "ما أخذته المزامنة من هذا الدفتر"],
        "mac.losses_body": ["en": "Another device's copy won each of these. Put one back to keep this Mac's version — the next sync carries it everywhere.",
                                 "ar": "فازت نسخة جهاز آخر في كل منها. أعِد أيًا منها للإبقاء على نسخة هذا الماك — وستنقلها المزامنة التالية إلى كل الأجهزة."],
        "mac.losses_removed": ["en": "Deleted on another device", "ar": "حُذف على جهاز آخر"],
        "mac.losses_replaced": ["en": "Changed here, replaced by another device's copy",
                                   "ar": "عُدّل هنا، واستُبدل بنسخة جهاز آخر"],
        "mac.losses_kept_deleted": ["en": "Deleted here; another device's later change was dropped",
                                       "ar": "حُذف هنا؛ وأُسقط تغيير لاحق من جهاز آخر"],
        // The Mac's one word for the person a job is for. Khayt's `doc.client`
        // is "Client" — right on its printed documents — and the tables and
        // the New Job sheet said that beside a sidebar of "Customers".
        "mac.customer": ["en": "Customer", "ar": "العميل"],
        // What kind of record each loss was — never the store's own key.
        "mac.losses_kind_job": ["en": "Job", "ar": "عمل"],
        "mac.losses_kind_customer": ["en": "Customer", "ar": "عميل"],
        "mac.losses_kind_spool": ["en": "Spool", "ar": "بكرة"],
        "mac.losses_kind_product": ["en": "Product", "ar": "منتج"],
        "mac.losses_kind_machine": ["en": "Machine", "ar": "طابعة"],
        "mac.losses_kind_model": ["en": "Model", "ar": "نموذج"],
        "mac.losses_kind_expense": ["en": "Expense", "ar": "مصروف"],
        "mac.losses_kind_waste": ["en": "Waste", "ar": "هدر"],
        "mac.losses_kind_message": ["en": "Saved message", "ar": "رسالة محفوظة"],
        "mac.losses_kind_supplier": ["en": "Supplier", "ar": "مورّد"],
        "mac.losses_kind_purchase_order": ["en": "Purchase order", "ar": "أمر شراء"],
        "mac.losses_kind_gift_card": ["en": "Gift card", "ar": "بطاقة هدية"],
        "mac.losses_kind_maintenance": ["en": "Maintenance task", "ar": "مهمة صيانة"],
        "mac.losses_kind_service": ["en": "Service record", "ar": "سجل صيانة"],
        "mac.losses_kind_consumable": ["en": "Consumable", "ar": "مستهلك"],
        "mac.losses_kind_operator": ["en": "Operator", "ar": "مشغّل"],
        "mac.losses_kind_time": ["en": "Time entry", "ar": "وقت عمل"],
        "mac.losses_kind_location": ["en": "Location", "ar": "موقع"],
        "mac.losses_kind_loyalty": ["en": "Loyalty points", "ar": "نقاط ولاء"],
        "mac.losses_kind_record": ["en": "Record", "ar": "سجل"],
        "mac.losses_put_back": ["en": "Put back", "ar": "إعادة"],
        "mac.losses_put_back_done": ["en": "Put back", "ar": "أُعيد"],
        "mac.losses_put_back_failed": ["en": "Could not put it back:", "ar": "تعذّرت الإعادة:"],
        "mac.restore_hold_expired": ["en": "The restore from a backup is no longer held against the cloud: it was never sent up in 7 days. Edits from other devices to those records now apply again.",
                                     "ar": "لم تعد الاستعادة من النسخة الاحتياطية مُثبّتة أمام السحابة: لم تُرسَل خلال 7 أيام. تعديلات الأجهزة الأخرى على تلك السجلات تسري من جديد."],
        "mac.restore_hold_read_only": ["en": "The restore was applied once against the cloud. This Mac's cloud role cannot send it up, so edits from other devices to those records now apply again.",
                                       "ar": "طُبّقت الاستعادة مرة واحدة أمام السحابة. دور هذا الماك في السحابة لا يسمح بإرسالها، لذا تسري تعديلات الأجهزة الأخرى على تلك السجلات من جديد."],
        "mac.ws_empty_held": ["en": "The web store was not changed: nothing in the catalogue can be listed now, and an automatic update never takes the store offline. Take it offline from the Online pane if that is what you want.",
                              "ar": "لم يتغيّر المتجر الإلكتروني: لا شيء في الكتالوج قابل للعرض الآن، والتحديث التلقائي لا يوقف المتجر أبدًا. أوقفه من لوحة «عبر الإنترنت» إن أردت ذلك."],
        "mac.losses_show_file": ["en": "Show the copies in Finder", "ar": "إظهار النسخ في Finder"],
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
        // A percentage extra line is either a platform's cut (grossed up, so
        // the shop keeps its price) or the shop's own surcharge. The toggle
        // writes `fee: true`; a marketplace line is a fee by its platformId.
        "mac.extra_fee":      ["en": "Platform fee", "ar": "رسوم منصة"],
        "mac.extra_fee_from": ["en": "Set by {platform}", "ar": "تحدّدها {platform}"],
        "mac.extra_fee_hint": ["en": "The platform takes this share of the final price, so Khayt adds it on top: you keep your price.",
                               "ar": "تأخذ المنصة هذه النسبة من السعر النهائي، فيضيفها خيط فوقه: يبقى لك سعرك."],
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
        "mac.calc_add_filament": ["en": "Add filament / colour", "ar": "أضف خيطًا / لونًا"],
        "mac.calc_colour_n":    ["en": "Colour {n}", "ar": "اللون {n}"],
        "mac.calc_total_grams": ["en": "{g} g in all", "ar": "{g} غ إجمالًا"],
        "mac.job_components": ["en": "Components", "ar": "المكوّنات"],
        "mac.job_components_hint": [
            "en": "The product's bought-in pieces — magnets, screws, a box — for this many assemblies, priced at cost plus margin with the parts and drawn from the shelf when the job completes.",
            "ar": "القطع المشتراة للمنتج — مغناطيس، براغٍ، علبة — لهذا العدد من التجميعات، تُسعَّر بالتكلفة مع الهامش مع الأجزاء وتُخصم من الرف عند اكتمال المهمة."],
        "mac.calc_split_note": [
            "en": "The {g} g already typed was split between the two colours, not added to. Set each colour's own grams.",
            "ar": "قُسِّمت الـ{g} غ المكتوبة بين اللونين ولم تُضَف إليها. اكتب غرامات كل لون."],
        "mac.calc_purge":       ["en": "Purge / waste", "ar": "هدر التنظيف"],
        "mac.calc_multicolour_note": [
            "en": "{n} filaments, {g} g in all. Each is charged at its own spool's price; purge is shared across them by weight.",
            "ar": "{n} خيوط، {g} غ إجمالًا. يُحسب كل منها بسعر بكرته، ويُوزَّع هدر التنظيف عليها حسب الوزن."],
        "mac.calc_purge_note": [
            "en": "{g} g in all, purge included — charged at this spool's price.",
            "ar": "{g} غ إجمالًا مع هدر التنظيف — بسعر هذه البكرة."],
        "mac.calc_consumables": ["en": "Consumables", "ar": "المستهلكات"],
        "mac.calc_consumable":  ["en": "Consumable", "ar": "مستهلك"],
        "mac.calc_add_consumable": ["en": "Add consumable", "ar": "أضف مستهلكًا"],
        "mac.calc_no_consumables": [
            "en": "Nothing on the Consumables shelf yet. Add magnets, inserts or screws there and they can be priced into a print here.",
            "ar": "لا شيء في رف المستهلكات بعد. أضف المغناطيس أو الحشوات أو البراغي هناك لتُحتسب في تكلفة الطباعة هنا."],
        "mac.calc_consumables_note": [
            "en": "Per printed piece, at each item's cost on the shelf. Included in the cost above.",
            "ar": "لكل قطعة مطبوعة، بتكلفة كل صنف على الرف. مشمولة في التكلفة أعلاه."],
        "mac.model_consumables": ["en": "Consumables per print", "ar": "المستهلكات لكل طباعة"],
        "mac.model_consumables_empty_shelf": [
            "en": "Nothing on the Consumables shelf yet. Add magnets, inserts or screws there, then list here what each print of this model uses.",
            "ar": "لا شيء في رف المستهلكات بعد. أضف المغناطيس أو الحشوات أو البراغي هناك، ثم اذكر هنا ما تستهلكه كل طباعة لهذا النموذج."],
        "mac.model_consumables_hint": [
            "en": "Bought-in pieces each print uses — magnets, inserts, screws. Priced in the calculator and on a product made from this model, and taken off the shelf when its job completes.",
            "ar": "القطع المشتراة التي تستهلكها كل طباعة — مغناطيس، حشوات، براغي. تُحتسب في الحاسبة وفي المنتج المصنوع من هذا النموذج، وتُخصم من الرف عند اكتمال المهمة."],
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
        "mac.move_path_too_long": ["en": "That would make a folder path longer than 60 characters, which would merge it with another folder. Move it higher, or shorten a name first.",
                                   "ar": "سيجعل هذا مسار المجلد أطول من 60 حرفًا فيندمج مع مجلد آخر. انقله إلى مستوى أعلى أو اختصر اسمًا أولًا."],
        // MOVING SEVERAL GROUPS UNDER ONE PARENT, and renaming one. The other
        // app's library has no folders to move, so no words for it either.
        "mac.n_groups":      ["en": "{n} groups",      "ar": "{n} مجموعةً"],
        "mac.n_groups_one":  ["en": "{n} group",       "ar": "مجموعة واحدة"],
        "mac.n_groups_two":  ["en": "{n} groups",      "ar": "مجموعتان"],
        "mac.n_groups_few":  ["en": "{n} groups",      "ar": "{n} مجموعات"],
        // After a verbal noun ("نقل مجموعتين", "تجميع مجموعتين") the dual is
        // genitive; `mac.n_groups_two` is the nominative.
        "mac.n_groups_of":      ["en": "{n} groups",      "ar": "{n} مجموعةً"],
        "mac.n_groups_of_one":  ["en": "{n} group",       "ar": "مجموعة واحدة"],
        "mac.n_groups_of_two":  ["en": "{n} groups",      "ar": "مجموعتين"],
        "mac.n_groups_of_few":  ["en": "{n} groups",      "ar": "{n} مجموعات"],
        "mac.move_into_group": ["en": "Move into Group\u{2026}", "ar": "نقل إلى مجموعة\u{2026}"],
        "mac.move_n_groups_into": ["en": "Move {groups} into Group\u{2026}",
                                   "ar": "نقل {groups} إلى مجموعة\u{2026}"],
        "mac.rename_group":  ["en": "Rename Group\u{2026}", "ar": "إعادة تسمية المجموعة\u{2026}"],
        "mac.move_groups_title": ["en": "Move {groups} into a group", "ar": "نقل {groups} إلى مجموعة"],
        "mac.move_groups_into": ["en": "Into", "ar": "إلى"],
        "mac.move_groups_new": ["en": "A group named below", "ar": "مجموعة تسمّيها أدناه"],
        "mac.move_groups_type": ["en": "Group name, e.g. Baby Grendizer",
                                 "ar": "اسم المجموعة، مثل Baby Grendizer"],
        "mac.move_groups_plan": ["en": "What moves where", "ar": "ما يُنقل وإلى أين"],
        "mac.move_groups_joins": ["en": "{name} already exists \u{2014} these models join it, and it keeps its kind.",
                                  "ar": "{name} موجودة أصلاً \u{2014} ستنضم إليها هذه النماذج وتبقى على نوعها."],
        "mac.move_groups_riding": ["en": "{name} goes with the group it is in.",
                                   "ar": "تنتقل {name} مع المجموعة التي تحتويها."],
        "mac.move_groups_already": ["en": "{name} is already there.", "ar": "{name} موجودة هناك أصلاً."],
        "mac.move_groups_undo_hint": ["en": "One change: Edit \u{203A} Undo puts every group back.",
                                      "ar": "تغيير واحد: تحرير \u{2039} تراجع يعيد كل المجموعات كما كانت."],
        "mac.move_groups_same_name": ["en": "Two of the chosen groups are both called \u{201C}{name}\u{201D} and would become one. Rename one first.",
                                      "ar": "مجموعتان من المختارة اسمهما «{name}» وستصبحان واحدة. أعد تسمية إحداهما أولاً."],
        "mac.move_group_into_itself": ["en": "\u{201C}{name}\u{201D} cannot be moved inside itself.",
                                       "ar": "لا يمكن نقل «{name}» داخل نفسها."],
        "mac.group_path_too_long": ["en": "\u{201C}{path}\u{201D} would be longer than {n} characters, where Khayt cuts a group\u{2019}s name. Choose a shorter name.",
                                    "ar": "سيتجاوز «{path}» {n} حرفًا، وعندها يقطع خيط اسم المجموعة. اختر اسمًا أقصر."],
        "mac.move_groups_is_existing": ["en": "That is your group \u{201C}{name}\u{201D}.",
                                        "ar": "هذه مجموعتك «{name}»."],
        "mac.move_do":       ["en": "Move", "ar": "نقل"],
        "mac.moved_groups_into": ["en": "Move Groups into {name}", "ar": "نقل المجموعات إلى {name}"],
        "mac.rename_group_title": ["en": "Rename group", "ar": "إعادة تسمية المجموعة"],
        "mac.rename_group_hint": ["en": "Its models and anything inside it keep their places under the new name.",
                                  "ar": "تبقى نماذجها وما بداخلها في أماكنها تحت الاسم الجديد."],
        "mac.group_new_name": ["en": "New name", "ar": "الاسم الجديد"],
        "mac.rename_group_empty": ["en": "A group needs a name.", "ar": "تحتاج المجموعة إلى اسم."],
        "mac.rename_do":     ["en": "Rename", "ar": "إعادة التسمية"],
        "mac.rename_group_undo": ["en": "Rename Group", "ar": "إعادة تسمية المجموعة"],
        "mac.group_n_groups": ["en": "Group: {groups}", "ar": "تجميع: {groups}"],
        "mac.mark_dried": ["en": "Dried today", "ar": "جُفّفت اليوم"],
        "mac.spool_history": ["en": "Where this went", "ar": "أين ذهب هذا"],
        "mac.spool_history_empty": ["en": "Nothing has been printed with this spool yet.",
                                    "ar": "لم يُطبع شيء بهذه البكرة بعد."],
        "mac.spool_history_total": ["en": "Used altogether", "ar": "المستخدم إجمالاً"],
        // Lot tracing: which lot a job's filament came from, and back.
        "mac.filament_used": ["en": "Filament used", "ar": "الخيط المستخدم"],
        "mac.lot_inferred": ["en": "(inferred)", "ar": "(مُستنتَج)"],
        "mac.lot_label": ["en": "Lot {lot}", "ar": "الدفعة {lot}"],
        "mac.lot_copy_csv": ["en": "Copy jobs from lot {lot} as CSV",
                             "ar": "نسخ أعمال الدفعة {lot} بصيغة CSV"],
        "mac.lot_copied": ["en": "Copied {n} jobs to the clipboard.",
                           "ar": "نُسخ {n} من الأعمال إلى الحافظة."],
        "mac.lot_copied_one": ["en": "Copied 1 job to the clipboard.",
                               "ar": "نُسخ عمل واحد إلى الحافظة."],
        "mac.lot_receive_hint": ["en": "A lot different from the spool's own is booked in as a new spool, so a recall can find it.",
                                 "ar": "الدفعة المختلفة عن دفعة البكرة تُسجَّل بكرةً جديدة، ليسهل تتبّعها عند الاستدعاء."],
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
        // A campaign goes by email only: this app has no WhatsApp sender for a
        // list, and a WhatsApp list is phone numbers — mailed, they bounce.
        "mac.campaign_email_only": ["en": "Campaigns are sent by email only.",
                                    "ar": "تُرسل الحملات بالبريد الإلكتروني فقط."],
        // A full erase leaves the holder's name on a gift card that still has
        // money on it — the shop owes it to them. Counted, never "card(s)".
        "mac.erase_keeps_cards": ["en": "{n} gift cards still have a balance. They keep their holders' names, because the balance is money the shop owes.",
                                  "ar": "{n} من بطاقات الهدايا لا يزال فيها رصيد، وتحتفظ بأسماء حامليها لأن الرصيد مبلغ يدين به المتجر."],
        "mac.erase_keeps_cards_one": ["en": "{n} gift card still has a balance. It keeps its holder's name, because the balance is money the shop owes.",
                                      "ar": "بطاقة هدية واحدة لا يزال فيها رصيد، وتحتفظ باسم حاملها لأن الرصيد مبلغ يدين به المتجر."],
        "mac.erase_keeps_cards_two": ["en": "{n} gift cards still have a balance. They keep their holders' names, because the balance is money the shop owes.",
                                      "ar": "بطاقتا هدايا لا يزال فيهما رصيد، وتحتفظان باسمَي حامليهما لأن الرصيد مبلغ يدين به المتجر."],
        "mac.erase_keeps_cards_few": ["en": "{n} gift cards still have a balance. They keep their holders' names, because the balance is money the shop owes.",
                                      "ar": "{n} بطاقات هدايا لا يزال فيها رصيد، وتحتفظ بأسماء حامليها لأن الرصيد مبلغ يدين به المتجر."],
        "mac.whatsapp": ["en": "WhatsApp", "ar": "واتساب"],
        "mac.export_accounting_where": [
            "en": "Two files are written here: one of invoices and one of expenses.",
            "ar": "يُكتب هنا ملفان: ملف للفواتير وآخر للمصروفات."],
        // Said after a Wafeq or Daftra export, because both importers ask the
        // person to match columns and names, and neither file is right until
        // they do. lib/accounting-export.js cites where each rule comes from.
        "mac.export_wafeq_note": [
            "en": "In Wafeq, match the columns on the import screen and pick the account each expense was paid through. Customer, account and tax names must be spelled as they are in Wafeq.",
            "ar": "في وافِق، طابق الأعمدة في شاشة الاستيراد واختر الحساب الذي دُفع منه كل مصروف. يجب أن تُكتب أسماء العملاء والحسابات والضرائب كما هي في وافِق."],
        "mac.export_daftra_note": [
            "en": "Sales go to Daftra as incomes, dated DD/MM/YYYY — set the same date format in Daftra. Tax names must be spelled as they are in Daftra, and the tax must not be included in the price.",
            "ar": "تُستورد المبيعات إلى دفترة كإيرادات بتاريخ يوم/شهر/سنة — اضبط صيغة التاريخ نفسها في دفترة. يجب أن تُكتب أسماء الضرائب كما هي في دفترة، وألا تكون الضريبة مشمولة في السعر."],
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
        // The richer card. Short: they are tooltips and captions on a card
        // already carrying a bar and a filename.
        "mac.chamber_temp":  ["en": "Chamber",       "ar": "الحجرة"],
        "mac.part_fan":      ["en": "Part cooling fan", "ar": "مروحة تبريد القطعة"],
        "mac.speed_factor":  ["en": "Speed (100% is as sliced)", "ar": "السرعة (100% كما في التقطيع)"],
        "mac.flow_factor":   ["en": "Flow (100% is as sliced)",  "ar": "التدفق (100% كما في التقطيع)"],
        "mac.layer_of":      ["en": "Layer {layer} of {total}", "ar": "الطبقة {layer} من {total}"],
        "mac.filament_out":  ["en": "Out of filament", "ar": "نفد الخيط"],
        "mac.printer_says":  ["en": "What the printer says", "ar": "ما تقوله الطابعة"],
        // A card under a running print with no buttons on it reads as a
        // feature somebody forgot to draw; this says it is on purpose.
        "mac.printer_no_control": ["en": "Khayt cannot pause or cancel this printer yet. Use the printer itself or its own app.",
                                   "ar": "لا يستطيع خيط إيقاف هذه الطابعة مؤقتًا أو إلغاء طباعتها بعد. استخدم الطابعة نفسها أو تطبيقها."],
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
        "mac.import_done_kept": ["en": "{moved} added, originals kept · {duplicates} already there · {failed} failed.",
                                 "ar": "أُضيف {moved} مع إبقاء الأصول · {duplicates} موجود مسبقًا · {failed} فشل."],
        "mac.import_keep_originals": ["en": "Keep my original files", "ar": "احتفظ بملفاتي الأصلية"],
        "mac.import_move_originals": ["en": "Move them into Khayt's library (originals go to the Trash)", "ar": "انقلها إلى مكتبة خيط (تذهب الأصول إلى سلة المهملات)"],
        "mac.import_originals_title": ["en": "When adding models", "ar": "عند إضافة النماذج"],
        "mac.import_originals_hint": ["en": "Moving sends each original to the Trash once its copy in the library has been checked. In iCloud Drive or Dropbox that removes it from every device.", "ar": "النقل يرسل كل ملف أصلي إلى سلة المهملات بعد التحقق من نسخته في المكتبة. في iCloud Drive أو Dropbox يحذفه ذلك من كل الأجهزة."],
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
                                 "ar": "صف العمل — «20 مشبك كابل، PETG أسود»"],
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
        "mac.cloud_lost_edits": ["en": "{n} changes made here were discarded: the record had been "
                               + "deleted on another device.",
                                 "ar": "أُلغي {n} تغييرًا أُجري هنا: كان السجل قد حُذف على جهاز آخر."],
        "mac.cloud_lost_edits_one": ["en": "{n} change made here was discarded: the record had been "
                                   + "deleted on another device.",
                                     "ar": "أُلغي تغيير واحد أُجري هنا: كان السجل قد حُذف على جهاز آخر."],
        "mac.cloud_lost_edits_two": ["en": "2 changes made here were discarded: the record had been "
                                   + "deleted on another device.",
                                     "ar": "أُلغي تغييران أُجريا هنا: كان السجل قد حُذف على جهاز آخر."],
        "mac.cloud_lost_edits_few": ["en": "{n} changes made here were discarded: the record had been "
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
        "mac.new_product":   ["en": "New Product",  "ar": "منتج جديد"],
        // Making a product FROM a model. Mac-only: the other app's catalogue
        // has no route from the library at all, only a `fileRef` field a shop
        // types a filename into.
        "mac.product_from_model": ["en": "Add to the catalogue",
                                   "ar": "أضف إلى الكتالوج"],
        "mac.catalogue_add_as_one": ["en": "Add {n} models to the catalogue as one product", "ar": "أضف {n} نماذج إلى الكتالوج كمنتج واحد"],
        "mac.catalogue_add_each": ["en": "Add {n} models to the catalogue, one product each", "ar": "أضف {n} نماذج إلى الكتالوج، منتجًا لكل منها"],
        "mac.catalogue_add_folder": ["en": "Add this folder to the catalogue as one product", "ar": "أضف هذا المجلد إلى الكتالوج كمنتج واحد"],
        "mac.catalogue_added_each": ["en": "Added {n} products to the catalogue, each priced from its model. Open one to adjust it.", "ar": "أُضيف {n} منتجات إلى الكتالوج، سُعّر كل منها من نموذجه. افتح أيًّا منها لتعديله."],
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
        "mac.est_section": ["en": "Estimating from a model", "ar": "التقدير من نموذج"],
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
                                         "ar": "لم يتمكّن خيط من قراءة أرقام هذا النموذج."],
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
                                  "ar": "{fields} مُقدَّرة من النموذج نفسه — لا أعمال مقيسة بعد، "
                                  + "فراجعها قبل البيع."],
        "mac.product_estimated_calibrated": ["en": "{fields} estimated from the model, at the rate "
                                             + "your own {n} measured jobs actually ran at.",
                                             "ar": "{fields} مُقدَّرة من النموذج، بالمعدل الذي جرت "
                                             + "به {n} من أعمالك المقيسة."],
        "mac.product_costed_with": ["en": "Costed with your {spool} and your usual rates — change either on the sheet.", "ar": "حُسبت التكلفة بخامة {spool} وأسعارك المعتادة — غيّر أيًّا منها في الصفحة."],
        "mac.product_from_file_missing": ["en": "Filled in from the file. It could not answer for: {fields} — check those before you sell it.",
                                          "ar": "تم التعبئة من الملف. ولم يُجب عن: {fields} — راجعها قبل البيع."],
        // The catalogue's two layouts. Said as tooltips on the toggle, so they
        // are the only words a shop ever reads for them.
        // IMPORT, said as a shop would look for it. The menu item is called
        // "Add model" and is in the Book menu; somebody with a folder of
        // downloads searches for "import", so the toolbar button says that.
        "mac.import_models": ["en": "Import Models", "ar": "استيراد نماذج"],
        "mac.import_models_hint": ["en": "Add models from a folder — or drag them onto the library.",
                                   "ar": "أضف نماذج من مجلد — أو اسحبها إلى المكتبة."],
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
        // ── A UNIT OR A SHELF AS IT IS READ, never as it is stored ──────────
        // The book keeps whatever the shop typed ("L", "roll", "Cleaning");
        // these are only how a known one is SAID. See `Words.unitWord`.
        "mac.unit_each":     ["en": "each",   "ar": "حبة"],
        "mac.unit_piece":    ["en": "pcs",    "ar": "قطعة"],
        "mac.unit_roll":     ["en": "roll",   "ar": "لفة"],
        "mac.unit_box":      ["en": "box",    "ar": "علبة"],
        "mac.unit_bag":      ["en": "bag",    "ar": "كيس"],
        "mac.unit_pack":     ["en": "pack",   "ar": "عبوة"],
        "mac.unit_pair":     ["en": "pair",   "ar": "زوج"],
        "mac.unit_bottle":   ["en": "bottle", "ar": "زجاجة"],
        "mac.unit_spool":    ["en": "spool",  "ar": "بكرة"],
        "mac.unit_sheet":    ["en": "sheet",  "ar": "لوح"],
        "mac.unit_kg":       ["en": "kg",     "ar": "كغ"],
        "mac.unit_g":        ["en": "g",      "ar": "غ"],
        "mac.unit_l":        ["en": "L",      "ar": "لتر"],
        "mac.unit_ml":       ["en": "ml",     "ar": "مل"],
        "mac.unit_m":        ["en": "m",      "ar": "م"],
        "mac.shelf_packaging":   ["en": "Packaging",   "ar": "تغليف"],
        "mac.shelf_cleaning":    ["en": "Cleaning",    "ar": "تنظيف"],
        "mac.shelf_spares":      ["en": "Spares",      "ar": "قطع غيار"],
        "mac.shelf_tools":       ["en": "Tools",       "ar": "أدوات"],
        "mac.shelf_hardware":    ["en": "Hardware",    "ar": "عُدد ومثبتات"],
        "mac.shelf_adhesives":   ["en": "Adhesives",   "ar": "مواد لاصقة"],
        "mac.shelf_maintenance": ["en": "Maintenance", "ar": "صيانة"],
        "mac.shelf_safety":      ["en": "Safety",      "ar": "سلامة"],
        "mac.shelf_cat_labels":  ["en": "Labels",      "ar": "ملصقات"],
        "mac.shelf_finishing":   ["en": "Finishing",   "ar": "تشطيب"],
        "mac.shelf_electronics": ["en": "Electronics", "ar": "إلكترونيات"],
        "mac.find_cant_add_sample": ["en": "This is the sample shop: printers it finds can be seen, not added.",
                                     "ar": "هذا هو المحل التجريبي: تظهر الطابعات التي يجدها لكن لا يمكن إضافتها."],
        "mac.find_cant_add_locked": ["en": "Another app has this book open, so a printer it finds cannot be added here.",
                                     "ar": "تطبيق آخر يفتح هذا الدفتر، فلا يمكن إضافة طابعة يجدها من هنا."],
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
        "mac.cloud_accept_rollback": ["en": "Trust the cloud's older copy", "ar": "اعتمد النسخة الأقدم في السحابة"],
        "plug.cleartext": ["en": "This address is plain http: the plug's token or password crosses the network unencrypted. Use https if the plug offers it.", "ar": "هذا العنوان http غير مشفّر: يمر رمز المقبس أو كلمة مروره عبر الشبكة دون تشفير. استخدم https إن كان المقبس يدعمه."],
        "plug.unreachable": ["en": "The plug did not answer.", "ar": "المقبس لم يُجب."],
        "plug.auto_off_done": ["en": "Turned off {name}: the print finished and it has cooled.", "ar": "أُطفئت {name}: انتهت الطباعة وبردت."],
        "mac.printer_resume": ["en": "Resume",       "ar": "استئناف"],
        "mac.printer_cancel": ["en": "Cancel print", "ar": "إلغاء الطباعة"],
        "mac.printer_speed":  ["en": "Speed", "ar": "السرعة"],
        "mac.printer_speed_1": ["en": "Silent", "ar": "صامت"],
        "mac.printer_speed_2": ["en": "Standard", "ar": "قياسي"],
        "mac.printer_speed_3": ["en": "Sport", "ar": "رياضي"],
        "mac.printer_speed_4": ["en": "Ludicrous", "ar": "فائق"],
        "mac.printer_light":  ["en": "Light", "ar": "الإضاءة"],
        "mac.printer_light_on": ["en": "Chamber light on", "ar": "تشغيل إضاءة الحجرة"],
        "mac.printer_light_off": ["en": "Chamber light off", "ar": "إطفاء إضاءة الحجرة"],
        "mac.speed_ask":      ["en": "Set {machine} to {speed} speed?", "ar": "ضبط {machine} على السرعة {speed}؟"],
        "mac.speed_set":      ["en": "Set speed", "ar": "ضبط السرعة"],
        "mac.speed_why":      ["en": "This changes the print that is running now. A faster mode than the file was sliced for can cost quality or the print.",
                               "ar": "هذا يغيّر الطباعة الجارية الآن. وضع أسرع مما قُطّع له الملف قد يكلّف الجودة أو الطباعة نفسها."],
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
        "ad.under_service":   ["en": "Under service", "ar": "قيد الصيانة"],
        "ad.retired":         ["en": "Retired", "ar": "خارج الخدمة نهائيًا"],
        "ad.held":            ["en": "Held back",    "ar": "موقوفة"],
        "mac.bed_cleared":    ["en": "Bed is clear", "ar": "الطاولة فارغة"],
        "mac.help_title":    ["en": "Khayt Help",   "ar": "مساعدة خيط"],
        // View ▸ Kiosk — see `KioskWindow`.
        "mac.kiosk_title":   ["en": "Kiosk", "ar": "شاشة الورشة"],
        "mac.kiosk_open":    ["en": "Open Kiosk", "ar": "فتح شاشة الورشة"],
        "mac.kiosk_left":    ["en": "{time} left", "ar": "متبقٍ {time}"],
        "mac.kiosk_over":    ["en": "{time} over its estimate", "ar": "تجاوزت تقديرها بـ {time}"],
        "mac.kiosk_total":   ["en": "About {time} to print", "ar": "نحو {time} للطباعة"],
        "mac.kiosk_due":     ["en": "Due {date}", "ar": "التسليم {date}"],
        "mac.kiosk_from_printer": ["en": "from the printer", "ar": "من الطابعة"],
        "mac.kiosk_estimated": ["en": "estimated", "ar": "تقديري"],
        // The shop's sites. The other app's delete confirmation says "this
        // cannot be undone", which is not true here (⌘Z puts it back), so the
        // Mac says what a delete actually does.
        "mac.locations_hint": ["en": "Branches or rooms your machines stand in. Jobs belong to their machine's location, and Reports splits profit by location.",
                               "ar": "الفروع أو الغرف التي توجد فيها أجهزتك. ينتمي كل طلب إلى موقع جهازه، وتقسّم التقارير الربح حسب الموقع."],
        "mac.no_locations": ["en": "No locations yet. A shop with one site does not need any.",
                             "ar": "لا توجد مواقع بعد. المتجر ذو الموقع الواحد لا يحتاج إليها."],
        "mac.location_delete_confirm": ["en": "Delete “{name}”?", "ar": "حذف «{name}»؟"],
        // The site filter (SiteFilter.swift).
        "mac.site_menu_hint": ["en": "Show one site's jobs, machines and stock. Money and Reports stay the whole shop's.",
                               "ar": "اعرض طلبات موقع واحد وآلاته ومخزونه. تبقى الأموال والتقارير للمتجر كله."],
        "mac.site_banner": ["en": "{site} only — {shown} of {total}",
                            "ar": "{site} فقط — {shown} من {total}"],
        "mac.site_dashboard": ["en": "{site}: its jobs, machines and stock. Money is the whole shop's.",
                               "ar": "{site}: أعماله وآلاته ومخزونه. أما الأموال فللمتجر كله."],
        "mac.site_banner_hint": ["en": "Anything with no site is shown at every site.",
                                 "ar": "ما ليس له موقع يظهر في كل المواقع."],
        "mac.location_add": ["en": "Add location", "ar": "إضافة موقع"],
        "mac.location_new": ["en": "New location", "ar": "موقع جديد"],
        "mac.location_edit": ["en": "Edit location", "ar": "تعديل الموقع"],
        // The operators' own: they read the same as the locations' today, and
        // sharing a key meant rewording one would silently reword the other.
        // The operator lock (OperatorLock.swift).
        "mac.lock_title": ["en": "Sign in", "ar": "تسجيل الدخول"],
        "mac.lock_hint": ["en": "Staff sign-in is on. Choose who you are and type your PIN.", "ar": "تسجيل دخول الموظفين مفعّل. اختر اسمك واكتب رمزك."],
        "mac.lock_recovery_hint": ["en": "Type the shop's recovery code to sign in as the owner, then set a new PIN.", "ar": "اكتب رمز الاسترداد الخاص بالمتجر لتسجيل الدخول بصفتك المالك، ثم عيّن رمزًا جديدًا."],
        "mac.lock_sign_in": ["en": "Sign in", "ar": "دخول"],
        "mac.lock_use_pin": ["en": "Use a PIN instead", "ar": "استخدم الرمز بدلًا من ذلك"],
        "mac.lock_no_pin": ["en": "This person has no PIN yet. An owner can set one in Settings → Operations.", "ar": "لا يوجد رمز لهذا الشخص بعد. يمكن للمالك تعيينه من الإعدادات ← العمليات."],
        "mac.lock_pin_unreadable": ["en": "This PIN was saved in a format Khayt can no longer check. An owner needs to set it again.", "ar": "حُفظ هذا الرمز بصيغة لم يعد خيط قادرًا على التحقق منها. يجب على المالك تعيينه من جديد."],
        "mac.lock_cooling": ["en": "Too many wrong PINs. Try again at {time}.", "ar": "محاولات خاطئة كثيرة. حاول مجددًا الساعة {time}."],
        "mac.lock_screen_not_allowed": ["en": "Your access level does not include this screen.", "ar": "مستوى صلاحيتك لا يشمل هذه الشاشة."],
        "mac.lock_signed_in_as": ["en": "Signed in as {name}", "ar": "مسجّل الدخول باسم {name}"],
        "mac.lock_sign_in_first": ["en": "Sign in first.", "ar": "سجّل الدخول أولًا."],
        "mac.lock_not_allowed": ["en": "Your access level does not allow this.", "ar": "مستوى صلاحيتك لا يسمح بهذا."],
        "mac.lock_now": ["en": "Lock", "ar": "قفل"],
        "mac.lock_section": ["en": "Staff sign-in", "ar": "تسجيل دخول الموظفين"],
        "mac.lock_section_hint": ["en": "When it is on, this Mac asks who is using it, and each person's access level decides what they can open and change. It keeps staff to their part of the app; it is not encryption.", "ar": "عند تفعيله يسأل هذا الماك من يستخدمه، ويحدد مستوى صلاحية كل شخص ما يمكنه فتحه وتغييره. يحصر الموظفين في جزئهم من التطبيق، وليس تشفيرًا."],
        "mac.lock_status_off": ["en": "Off: everyone can use everything.", "ar": "متوقف: يمكن للجميع استخدام كل شيء."],
        "mac.lock_status_on": ["en": "On.", "ar": "مفعّل."],
        "mac.lock_status_not_in_force": ["en": "Switched on, but no owner has a PIN this Mac can check, so it is not in force. Set an owner's PIN.", "ar": "مفعّل، لكن لا يوجد مالك لديه رمز يمكن لهذا الماك التحقق منه، لذا لا يُطبَّق. عيّن رمزًا لأحد المالكين."],
        "mac.lock_switch_on": ["en": "Switch on", "ar": "تفعيل"],
        "mac.lock_switch_off": ["en": "Switch off", "ar": "إيقاف"],
        "mac.lock_off_hint": ["en": "Type an owner's PIN to switch staff sign-in off.", "ar": "اكتب رمز أحد المالكين لإيقاف تسجيل دخول الموظفين."],
        "mac.lock_needs_owner": ["en": "Set a PIN for at least one owner first, so somebody can sign in.", "ar": "عيّن رمزًا لمالك واحد على الأقل أولًا، ليتمكن أحد من تسجيل الدخول."],
        "mac.lock_last_owner": ["en": "This is the only owner who can sign in. Switch staff sign-in off before clearing their PIN.", "ar": "هذا هو المالك الوحيد القادر على تسجيل الدخول. أوقف تسجيل دخول الموظفين قبل مسح رمزه."],
        "mac.lock_failed": ["en": "That could not be saved. Try again.", "ar": "تعذّر الحفظ. حاول مجددًا."],
        "mac.lock_make_recovery": ["en": "Make a recovery code", "ar": "إنشاء رمز استرداد"],
        "mac.lock_set_pin": ["en": "Set PIN", "ar": "تعيين رمز"],
        "mac.lock_change_pin": ["en": "Change PIN", "ar": "تغيير الرمز"],
        "mac.lock_clear_pin": ["en": "Clear PIN", "ar": "مسح الرمز"],
        "mac.lock_pin_none": ["en": "No PIN", "ar": "بلا رمز"],
        "mac.lock_pin_set": ["en": "PIN set", "ar": "الرمز معيّن"],
        "mac.lock_pin_elsewhere_short": ["en": "PIN set on another computer", "ar": "الرمز معيّن على جهاز آخر"],
        "mac.lock_pin_unreadable_short": ["en": "PIN needs setting again", "ar": "الرمز يحتاج إلى تعيين من جديد"],
        "mac.lock_pin_for": ["en": "PIN for {name}", "ar": "رمز {name}"],
        "mac.lock_pin_again": ["en": "Type it again", "ar": "اكتبه مرة أخرى"],
        "mac.lock_pins_differ": ["en": "The two PINs are different.", "ar": "الرمزان مختلفان."],
        "mac.lock_pin_rule": ["en": "4 to 8 digits.", "ar": "من 4 إلى 8 أرقام."],
        "mac.lock_recovery_title": ["en": "Recovery code", "ar": "رمز الاسترداد"],
        "mac.portal_messages": ["en": "Messages from the customer", "ar": "رسائل العميل"],
        "mac.lock_switch_person": ["en": "Switch person", "ar": "تبديل الشخص"],
        // The Mac's own, in place of the shared hint's "updates via your
        // provider webhook" — a shop owner reads that as nothing.
        "mac.deposit_hint": ["en": "The customer pays on your payment provider's page. Leave the deposit empty to ask for none.",
                             "ar": "يدفع العميل على صفحة مزوّد الدفع لديك. اترك العربون فارغًا إن لم تطلب عربونًا."],
        "mac.portal_unpublish_q": ["en": "Take down {job}'s customer link?", "ar": "إيقاف رابط العميل لـ {job}؟"],
        "mac.portal_unpublish_why": ["en": "The link the customer has stops working until you publish it again — the same link then works again.",
                                     "ar": "سيتوقف الرابط الذي لدى العميل عن العمل حتى تنشره مجددًا، فيعود الرابط نفسه للعمل."],
        "mac.lock_forgot": ["en": "Forgot your PIN? Another owner can set a new one in Settings → Operations, or use the shop's recovery code.",
                            "ar": "نسيت رمزك؟ يمكن لمالك آخر تعيين رمز جديد من الإعدادات ← العمليات، أو استخدم رمز الاسترداد الخاص بالمتجر."],
        "mac.lock_forgot_no_code": ["en": "Forgot your PIN? Another owner can set a new one in Settings → Operations. No recovery code was made for this shop.",
                                    "ar": "نسيت رمزك؟ يمكن لمالك آخر تعيين رمز جديد من الإعدادات ← العمليات. لم يُنشأ رمز استرداد لهذا المتجر."],
        "mac.lock_recovery_once": ["en": "Write this down and keep it somewhere safe. It is shown only now; it lets an owner who forgets their PIN back in.", "ar": "دوّن هذا الرمز واحفظه في مكان آمن. لن يظهر إلا الآن، وهو يتيح للمالك الذي نسي رمزه الدخول مجددًا."],
        "mac.lock_recovery_done": ["en": "I have written it down", "ar": "دوّنته"],
        "mac.operator_delete_confirm": ["en": "Delete “{name}”?", "ar": "حذف «{name}»؟"],
        "mac.operator_add": ["en": "Add operator", "ar": "إضافة مشغّل"],
        "mac.operator_new": ["en": "New operator", "ar": "مشغّل جديد"],
        "mac.operator_edit": ["en": "Edit operator", "ar": "تعديل المشغّل"],
        "mac.operator_access_hint": ["en": "Used by the desktop app's operator lock. This Mac does not ask for a PIN.",
                                     "ar": "يستخدمه قفل المشغّلين في تطبيق سطح المكتب. هذا الماك لا يطلب رمزًا."],
        "mac.op_gone": ["en": "no longer on the list", "ar": "لم يعد في القائمة"],
        "mac.location_delete_hint": ["en": "Machines, spools, expenses and jobs at it become unassigned. You can undo this.",
                                     "ar": "تصبح الأجهزة والبكرات والمصروفات والطلبات التابعة له بلا موقع. يمكنك التراجع عن ذلك."],
        "mac.location_none": ["en": "None", "ar": "بدون"],
        "mac.location_gone": ["en": "A deleted location", "ar": "موقع محذوف"],
        "mac.location_pl_hint": ["en": "The shop's P&L for this period, split by where the work was done. Monthly costs belong to the whole shop and are not split.",
                                 "ar": "أرباح وخسائر المتجر لهذه الفترة مقسّمة حسب مكان العمل. التكاليف الشهرية للمتجر كله ولا تُقسَّم."],
        // The staff. A delete of somebody with work on record makes them
        // inactive instead (`lib/operators.js`), and the Mac says so before,
        // not after.
        "mac.operators_hint": ["en": "The people who run the machines. Put a job on somebody, log the hours they spend on it, and Reports shows each person's work.",
                               "ar": "الأشخاص الذين يشغّلون الأجهزة. أسند الطلب إلى أحدهم وسجّل ساعات عمله عليه، وتعرض التقارير عمل كل شخص."],
        "mac.no_operators": ["en": "No operators yet. A shop run by one person does not need any.",
                             "ar": "لا يوجد مشغّلون بعد. المتجر الذي يديره شخص واحد لا يحتاج إليهم."],
        "mac.operator_delete_hint": ["en": "You can undo this.", "ar": "يمكنك التراجع عن ذلك."],
        "mac.operator_active": ["en": "Active — offered when a job is assigned or time is logged",
                                "ar": "مفعّل — يظهر عند إسناد طلب أو تسجيل وقت"],
        "mac.operator_rate_hint": ["en": "Each time entry keeps the rate it was logged at.",
                                   "ar": "يحتفظ كل قيد وقت بالسعر الذي سُجّل به."],
        "mac.log_time": ["en": "Log work time\u{2026}", "ar": "تسجيل وقت عمل\u{2026}"],
        "mac.no_time_logged": ["en": "No time logged on this job.", "ar": "لم يُسجَّل وقت على هذا الطلب."],
        "mac.staff_hint": ["en": "Every finished job, the waste on each person's jobs, and how close their printer-measured prints came to the estimate.",
                           "ar": "كل طلب مكتمل، والهدر على طلبات كل شخص، ومدى قرب طباعاته المقيسة من التقدير."],
        "mac.labour_hint": ["en": "A job's revenue is shared by the hours each person put into it, and counts once the job is finished.",
                            "ar": "يُقسَّم إيراد الطلب بحسب ساعات كل شخص فيه، ويُحتسب عند اكتمال الطلب."],
        "mac.kiosk_unbooked": ["en": "Printing something not in the book",
                               "ar": "تطبع شيئاً غير مسجّل في الدفتر"],
        // Help ▸ Send Feedback… — see `Feedback`.
        "mac.feedback_menu":  ["en": "Send Feedback\u{2026}", "ar": "إرسال ملاحظات\u{2026}"],
        "mac.feedback_title": ["en": "Send Feedback", "ar": "إرسال ملاحظات"],
        "mac.feedback_what":  ["en": "What happened?", "ar": "ماذا حدث؟"],
        "mac.feedback_what_hint": ["en": "What you did, what you expected, and what you saw instead.",
                                   "ar": "ما الذي فعلته، وما الذي توقّعته، وما الذي ظهر بدلًا منه."],
        "mac.feedback_screenshot": ["en": "Include a screenshot of the window",
                                    "ar": "إرفاق صورة للنافذة"],
        "mac.feedback_screenshot_note": ["en": "The picture shows what is on screen — customer names and prices included.",
                                         "ar": "تُظهر الصورة ما على الشاشة، بما في ذلك أسماء العملاء والأسعار."],
        "mac.feedback_book":  ["en": "Include a copy of my book — only if Khayt support asks for it",
                               "ar": "إرفاق نسخة من دفتري — فقط إن طلبها منك دعم خيط"],
        "mac.feedback_book_note": ["en": "Your book holds your customers and your prices. Passwords, keys and tokens are masked before it is attached.",
                                   "ar": "يحوي دفترك عملاءك وأسعارك. تُحجب كلمات المرور والمفاتيح والرموز قبل إرفاقه."],
        "mac.feedback_diag_note": ["en": "A diagnostics file is always attached: versions, your Mac, how many records the book holds, and recent errors inside Khayt — no names, prices or secrets. Nothing is sent until you press Send in your mail app.",
                                   "ar": "يُرفق دائمًا ملف تشخيص: الإصدارات وجهازك وعدد السجلات في الدفتر وآخر الأخطاء داخل خيط — دون أسماء أو أسعار أو أسرار. لا يُرسل شيء حتى تضغط «إرسال» في تطبيق البريد."],
        "mac.feedback_compose": ["en": "Compose Email", "ar": "كتابة رسالة"],
        "mac.feedback_composed": ["en": "A draft is open in your mail app, addressed to {address}. Check it, then press Send.",
                                  "ar": "فُتحت مسودة في تطبيق البريد موجّهة إلى {address}. راجعها ثم اضغط «إرسال»."],
        "mac.feedback_saved": ["en": "No mail app is set up on this Mac. The report is saved as {file} in Downloads (shown in Finder), and {address} is copied. Write to that address and attach the file.",
                               "ar": "لا يوجد تطبيق بريد مُعدّ على هذا الماك. حُفظ التقرير باسم {file} في مجلد التنزيلات (ظاهر في Finder)، ونُسخ العنوان {address}. اكتب إلى هذا العنوان وأرفق الملف."],
        "mac.feedback_failed": ["en": "The report could not be prepared:", "ar": "تعذّر تجهيز التقرير:"],
        "mac.feedback_book_left_out": ["en": "The book could not be masked, so it was left out.",
                                       "ar": "تعذّر حجب أسرار الدفتر، فلم يُرفق."],
        "mac.help_search":   ["en": "Search help",  "ar": "ابحث في المساعدة"],
        "mac.help_none":     ["en": "No help article is selected",
                              "ar": "لم يُختَر أي موضوع"],
        "mac.view_list":     ["en": "List",         "ar": "قائمة"],
        "mac.view_grid":     ["en": "Grid",         "ar": "شبكة"],
        "mac.edit_product":  ["en": "Edit product", "ar": "تعديل المنتج"],
        "mac.product_need_name": ["en": "A product needs a name in at least one language.",
                                  "ar": "يحتاج المنتج إلى اسم بلغة واحدة على الأقل."],
        // The sheet shows the stored price until an edit re-prices it. Word
        // for word the desktop editor's `pe.price_kept` / `pe.price_was_now`
        // (#2010), so the two apps say the same thing about the same product.
        "mac.price_kept": ["en": "Saved price kept; today's costs give {now}",
                           "ar": "أُبقي السعر المحفوظ؛ تكاليف اليوم تعطي {now}"],
        "mac.price_was_now": ["en": "was {was} → now {now}",
                              "ar": "كان {was} ← الآن {now}"],
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
        "mac.vat":           ["en": "VAT",               "ar": "الضريبة"],
        "common.undo":       ["en": "Undo",              "ar": "تراجع"],
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
        // A quarter turn, for a photo that came out on its side. Physical
        // directions: anticlockwise is "left" in both languages.
        "mac.rotate_left":   ["en": "Rotate Left",     "ar": "تدوير لليسار"],
        "mac.rotate_right":  ["en": "Rotate Right",    "ar": "تدوير لليمين"],
        "mac.rotate_failed": ["en": "That picture could not be turned — its file could not be read.",
                              "ar": "تعذّر تدوير الصورة — لم يُقرأ ملفها."],
        // What the first picture IS, which is the thing a shop cannot guess
        // from a strip of thumbnails.
        "mac.main_picture_is": ["en": "The first picture is the one the catalogue, "
                                + "the storefront and the invoice use.",
                                "ar": "الصورة الأولى هي التي يستخدمها الكتالوج والمتجر والفاتورة."],
        "mac.picture_caption": ["en": "Caption", "ar": "تعليق"],
        "mac.delete_product": ["en": "Delete product", "ar": "حذف المنتج"],
        "mac.delete_product_q": ["en": "Delete “{name}”?", "ar": "حذف «{name}»؟"],
        // ── DELETING A JOB OR A CUSTOMER (`Shop+Delete.swift`) ───────────
        // A job with an invoice number or a payment is cancelled, never
        // deleted (`lib/record-delete.js`); these say so where Delete is off.
        "mac.delete_job_invoiced": ["en": "Invoiced: cancel instead",
                                    "ar": "صدرت له فاتورة: ألغِه بدلًا من حذفه"],
        "mac.delete_job_paid": ["en": "Has payments: cancel instead",
                                "ar": "عليه مدفوعات: ألغِه بدلًا من حذفه"],
        "mac.cancel_job": ["en": "Cancel Job", "ar": "إلغاء العمل"],
        "mac.delete_refused": ["en": "“{name}” can’t be deleted. {why}.",
                               "ar": "لا يمكن حذف «{name}». {why}."],
        "mac.delete_jobs_title": ["en": "Delete {n} jobs?", "ar": "حذف {n} عملًا؟"],
        "mac.delete_jobs_title_one": ["en": "Delete {n} job?", "ar": "حذف عمل واحد؟"],
        "mac.delete_jobs_title_two": ["en": "Delete {n} jobs?", "ar": "حذف عملين؟"],
        "mac.delete_jobs_title_few": ["en": "Delete {n} jobs?", "ar": "حذف {n} أعمال؟"],
        "mac.delete_jobs_goes": ["en": "Nothing goes but the job itself, with its print runs and photos.",
                                 "ar": "لا يُحذف إلا العمل نفسه، مع سجلات طباعته وصوره."],
        "mac.delete_jobs_unlinked": ["en": "Its expenses, filament use, waste and time entries stay in the books, unlinked ({n}).",
                                     "ar": "تبقى مصروفاته واستهلاك الخيوط وسجلات الهدر والوقت في الدفاتر، دون ربط ({n})."],
        "mac.delete_jobs_skipped": ["en": "Left alone, because they are invoiced or paid: {n}. Cancel those instead.",
                                    "ar": "تبقى كما هي لأنها مفوترة أو عليها مدفوعات: {n}. ألغِها بدلًا من ذلك."],
        "mac.delete_jobs_none": ["en": "None of the chosen jobs can be deleted: they are invoiced or paid. Cancel them instead.",
                                 "ar": "لا يمكن حذف أي من الأعمال المختارة: صدرت لها فواتير أو عليها مدفوعات. ألغِها بدلًا من ذلك."],
        "mac.deleted_jobs": ["en": "{n} jobs deleted.", "ar": "حُذف {n} عملًا."],
        "mac.deleted_jobs_one": ["en": "{n} job deleted.", "ar": "حُذف عمل واحد."],
        "mac.deleted_jobs_two": ["en": "{n} jobs deleted.", "ar": "حُذف عملان."],
        "mac.deleted_jobs_few": ["en": "{n} jobs deleted.", "ar": "حُذفت {n} أعمال."],
        "mac.delete_jobs_action": ["en": "Delete Jobs", "ar": "حذف الأعمال"],
        "mac.delete_portal_kept": ["en": "The customer link could not be taken down; remove it from Khayt Cloud.",
                                   "ar": "تعذّر إيقاف رابط العميل؛ احذفه من خيط كلاود."],
        "mac.customer_has_jobs": ["en": "Has {n} jobs", "ar": "له {n} عملًا"],
        "mac.customer_has_jobs_one": ["en": "Has {n} job", "ar": "له عمل واحد"],
        "mac.customer_has_jobs_two": ["en": "Has {n} jobs", "ar": "له عملان"],
        "mac.customer_has_jobs_few": ["en": "Has {n} jobs", "ar": "له {n} أعمال"],
        "mac.customer_has_cards": ["en": "Has gift cards ({n})", "ar": "له بطاقات هدايا ({n})"],
        "mac.delete_customers_title": ["en": "Delete {n} customers?", "ar": "حذف {n} عميلًا؟"],
        "mac.delete_customers_title_one": ["en": "Delete {n} customer?", "ar": "حذف عميل واحد؟"],
        "mac.delete_customers_title_two": ["en": "Delete {n} customers?", "ar": "حذف عميلين؟"],
        "mac.delete_customers_title_few": ["en": "Delete {n} customers?", "ar": "حذف {n} عملاء؟"],
        "mac.delete_customers_goes": ["en": "Their records and contact logs go. None of them has a job or a gift card.",
                                      "ar": "تُحذف سجلاتهم وسجلات التواصل معهم. لا أعمال لأي منهم ولا بطاقات هدايا."],
        "mac.delete_customers_skipped": ["en": "Left alone, because they have jobs or gift cards: {n}.",
                                         "ar": "يبقون كما هم لأن لهم أعمالًا أو بطاقات هدايا: {n}."],
        "mac.delete_customers_none": ["en": "None of the chosen customers can be deleted: each has jobs or gift cards.",
                                      "ar": "لا يمكن حذف أي من العملاء المختارين: لكل منهم أعمال أو بطاقات هدايا."],
        "mac.deleted_customers": ["en": "Customers deleted: {n}.", "ar": "العملاء المحذوفون: {n}."],
        "mac.delete_customers_action": ["en": "Delete Customers", "ar": "حذف العملاء"],
        // A customer's right to erasure (`Shop+Privacy.swift`). The sheet's
        // own words are the desktop's `priv.*`; only the menu item is new.
        "mac.erase_customer": ["en": "Erase Customer\u{2026}", "ar": "محو العميل\u{2026}"],
        // ── ASKED BEFORE A ONE-CLICK REMOVAL (see `AskFirst`) ────────────
        // `mac.delete_product_q` above is the title for every named delete —
        // "Delete “{name}”?" is not about products. These say what happens
        // next: whether Edit › Undo can bring it back, and what survives.
        "mac.no_undo":        ["en": "This cannot be undone.",
                               "ar": "لا يمكن التراجع عن هذا."],
        "mac.undo_after":     ["en": "Edit › Undo brings it back.",
                               "ar": "يمكن استعادته من تحرير › تراجع."],
        "mac.clear_payment_q": ["en": "Clear the {amount} recorded as paid on “{name}”?",
                                "ar": "مسح مبلغ {amount} المسجّل كمدفوع على «{name}»؟"],
        "mac.clear_payment_note": ["en": "The job will show nothing paid, and owe that amount again.",
                                   "ar": "سيظهر العمل بلا مبلغ مدفوع، ويعود ذلك المبلغ مستحقًا."],
        "mac.remove_plan_q":  ["en": "Remove the payment plan for “{name}”?",
                               "ar": "إزالة خطة الدفع لـ«{name}»؟"],
        "mac.remove_plan_note": ["en": "{n} agreed payments, {amount} in all, are dropped. "
                                 + "What has already been paid stays recorded.",
                                 "ar": "تُحذف الدفعات المتفق عليها ({n}) ومجموعها {amount}. "
                                 + "ما دُفع بالفعل يبقى مسجّلًا."],
        "mac.save_zero_q":    ["en": "Save at a price of 0?",
                               "ar": "الحفظ بسعر 0؟"],
        "mac.save_zero_note": ["en": "This product would be sold and quoted for nothing. "
                               + "Its price now is {price}.",
                               "ar": "سيُباع هذا المنتج ويُسعَّر بلا مقابل. "
                               + "سعره الحالي {price}."],
        "mac.save_zero_new":  ["en": "This product would be sold and quoted for nothing.",
                               "ar": "سيُباع هذا المنتج ويُسعَّر بلا مقابل."],
        "mac.save_zero_do":   ["en": "Save at 0", "ar": "حفظ بسعر 0"],
        "mac.not_stocked_q":  ["en": "Mark “{name}” as not stocked?",
                               "ar": "تعليم «{name}» كغير مخزّن؟"],
        "mac.not_stocked_note": ["en": "Its shelf count is cleared.",
                                 "ar": "يُمسح جرد الرف الخاص به."],
        "mac.unlink_folder_q": ["en": "Stop indexing “{name}”?",
                                "ar": "إيقاف فهرسة «{name}»؟"],
        "mac.unlink_folder_note": ["en": "Its models leave the library, with their tags, notes and "
                                   + "pictures. The files in the folder are not touched.",
                                   "ar": "تخرج نماذجه من المكتبة مع وسومها وملاحظاتها وصورها. "
                                   + "لا تُمسّ الملفات الموجودة في المجلد."],
        "mac.remove_logo_q":  ["en": "Remove the shop's logo?",
                               "ar": "إزالة شعار المتجر؟"],
        "mac.remove_logo_note": ["en": "Invoices and quotes print without it.",
                                 "ar": "تُطبع الفواتير وعروض الأسعار بدونه."],
        // The document a customer is handed
        "mac.save_pdf":      ["en": "Save PDF",     "ar": "حفظ PDF"],
        "mac.saved_to":      ["en": "Saved as",     "ar": "حُفظ باسم"],
        "mac.no_document":   ["en": "This job's invoice could not be built.",
                              "ar": "تعذّر إنشاء فاتورة هذا العمل."],
        "mac.invoice_not_issued": ["en": "Invoice number not issued yet",
                                   "ar": "لم يُصدَر رقم الفاتورة بعد"],
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
        "mac.licence_credit_title": ["en": "Its licence asks you to credit the designer wherever it is sold:",
            "ar": "ترخيصه يطلب ذكر المصمّم أينما بِيع:"],
        "mac.licence_credit_add": ["en": "Add the credit to the description", "ar": "إضافة ذكر المصمّم إلى الوصف"],
        "mac.licence_credit_lead": ["en": "Design credit:", "ar": "التصميم:"],
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
        // The job inspector: which machine a job was sent to from this app
        // (`lib/print-runs.js`), and the one it was planned for when that differs.
        "mac.job_printed_on": ["en": "Printed on {machine}", "ar": "طُبع على {machine}"],
        "mac.job_printed_on_planned": ["en": "Printed on {machine} (planned {planned})",
                                       "ar": "طُبع على {machine} (المخطّط: {planned})"],
        "mac.job_sent_to":   ["en": "Sent to {machine}", "ar": "أُرسل إلى {machine}"],
        "mac.job_sent_to_planned": ["en": "Sent to {machine} (planned {planned})",
                                    "ar": "أُرسل إلى {machine} (المخطّط: {planned})"],
        "mac.job_runs_earlier": ["en": "Earlier: {list}", "ar": "قبل ذلك: {list}"],
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
        "mac.lan_pin_too_short_stored": ["en": "The saved owner PIN is shorter than {n} characters, so the phone app and the queue page are locked until you set a new one. Customer pages keep working.",
                                         "ar": "رمز PIN المحفوظ للمالك أقصر من {n} أحرف، لذا تطبيق الهاتف وصفحة القائمة مقفلان حتى تعيّن رمزًا جديدًا. صفحات العملاء تبقى تعمل."],
        "mac.lan_pin_missing": ["en": "Set an owner PIN — the queue shows customers' names.",
                                "ar": "عيّن رمز PIN للمالك — فالقائمة تعرض أسماء العملاء."],
        "mac.lan_failed":    ["en": "The server could not start: {error}",
                              "ar": "تعذّر تشغيل الخادم: {error}"],
        "mac.lan_port_busy": ["en": "Another app is already using port {port}. Quit it, or choose a different port here and start again.",
                              "ar": "تطبيق آخر يستخدم المنفذ {port} بالفعل. أغلقه، أو اختر منفذًا آخر هنا وابدأ من جديد."],
        "mac.lan_port_denied": ["en": "macOS would not let Khayt use port {port}. Choose a port above 1024 and start again.",
                                "ar": "لم يسمح macOS لخيط باستخدام المنفذ {port}. اختر منفذًا أعلى من 1024 وابدأ من جديد."],
        "mac.lan_no_address": ["en": "This Mac has no network address to listen on yet. Check it is connected, then start again.",
                               "ar": "ليس لهذا الماك عنوان شبكة يستمع عليه بعد. تأكد من اتصاله ثم ابدأ من جديد."],
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
        "mac.part_no_rates": ["en": "A part here has no rates of its own, so its labour, power and wear are costed at your default rates. To set its own, edit the part and fill in the fields above.",
                              "ar": "أحد الأجزاء ليست له أسعار خاصة، فتُحتسب العمالة والكهرباء والاستهلاك فيه بأسعارك الافتراضية. لتحديد أسعاره، عدّل الجزء واملأ الحقول أعلاه."],
        "mac.tracking_link_copied": ["en": "Tracking link copied. The customer sees the stage, the shipping and, once done, a short survey.",
                                     "ar": "نُسخ رابط المتابعة. يرى العميل المرحلة والشحن، وبعد الإنجاز استبياناً قصيراً."],
        // ── Menu bar progress ─────────────────────────────────────────────
        // The status item's ring and figures, the fleet popover, the menu bar
        // style picker and the print notifications on this Mac
        // (`MenuBar.swift`, `MenuBarProgress.swift`, `PrintNotices.swift`).
        // Every figure, and every machine name inside an Arabic sentence, is
        // isolated (U+2068/U+2069) so it never drags the line's direction.
        "mac.mbp_figures": ["en": "{pct}% · {left}", "ar": "\u{2068}{pct}٪\u{2069} · \u{2068}{left}\u{2069}"],
        "mac.mbp_pct": ["en": "{pct}%", "ar": "\u{2068}{pct}٪\u{2069}"],
        "mac.mbp_hm": ["en": "{h}h {m}m", "ar": "\u{2068}{h} س {m} د\u{2069}"],
        "mac.mbp_m": ["en": "{m}m", "ar": "\u{2068}{m} د\u{2069}"],
        "mac.mbp_more": ["en": "+{n}", "ar": "\u{2068}+{n}\u{2069}"],
        "mac.mbp_left": ["en": "{left} left", "ar": "المتبقي \u{2068}{left}\u{2069}"],
        "mac.mbp_done_at": ["en": "done {time}", "ar": "ينتهي \u{2068}{time}\u{2069}"],
        "mac.mbp_attn_fault": ["en": "Fault", "ar": "عطل"],
        "mac.mbp_attn_paused": ["en": "Paused", "ar": "متوقفة مؤقتًا"],
        "mac.mbp_attn_runout": ["en": "Out of filament", "ar": "نفد الخيط"],
        "mac.mbp_attn_bed": ["en": "Finished · clear the bed", "ar": "انتهت · أفرغ السرير"],
        "mac.mbp_open_machine": ["en": "Open {machine} in the main window", "ar": "افتح \u{2068}{machine}\u{2069} في النافذة الرئيسية"],
        "mac.mbp_style": ["en": "Menu bar shows", "ar": "يعرض شريط القوائم"],
        "mac.mbp_style_ring_figures": ["en": "Progress ring and figures", "ar": "حلقة التقدم والأرقام"],
        "mac.mbp_style_ring": ["en": "Progress ring only", "ar": "حلقة التقدم فقط"],
        "mac.mbp_style_glyph": ["en": "Icon only", "ar": "الأيقونة فقط"],
        "mac.mbp_notify_finished": ["en": "Notify me when a print finishes", "ar": "نبّهني عند انتهاء طباعة"],
        "mac.mbp_notify_failed": ["en": "Notify me when a print fails", "ar": "نبّهني عند فشل طباعة"],
        "mac.mbp_notify_paused": ["en": "Notify me when a print is paused", "ar": "نبّهني عند إيقاف طباعة مؤقتًا"],
        "mac.mbp_notify_note": ["en": "Faults, filament runouts and printers that stop answering are always notified.",
                                "ar": "تصل دائمًا تنبيهات الأعطال ونفاد الخيط والطابعات التي تتوقف عن الرد."],
        "mac.mbp_notice_finished": ["en": "{machine} finished printing", "ar": "انتهت \u{2068}{machine}\u{2069} من الطباعة"],
        "mac.mbp_notice_failed": ["en": "The print on {machine} failed", "ar": "فشلت الطباعة على \u{2068}{machine}\u{2069}"],
        "mac.mbp_notice_paused": ["en": "{machine} is paused", "ar": "\u{2068}{machine}\u{2069} متوقفة مؤقتًا"],

        // ── A printer's working life: under service, retired, deleted ─────
        // (`Shop+MachineLife.swift`, `lib/machine-status.js`).
        "mac.life_badge_service": ["en": "Under service", "ar": "تحت الصيانة"],
        "mac.life_badge_retired": ["en": "Retired", "ar": "خارج الخدمة"],
        "mac.life_since": ["en": "since {date}", "ar": "منذ {date}"],
        "mac.life_retired_on": ["en": "Retired {date}", "ar": "خرجت من الخدمة في {date}"],
        "mac.life_retired_list": ["en": "Retired ({n})", "ar": "خارج الخدمة ({n})"],
        "mac.life_retired_hint": ["en": "Kept for their history — jobs, costs and service. Not polled, not offered for work.",
                                  "ar": "محفوظة لسجلها — الأعمال والتكاليف والصيانة. لا تُتابَع ولا تُعرض للعمل."],
        "mac.life_retired_suffix": ["en": "(retired)", "ar": "(خارج الخدمة)"],
        "mac.life_service_suffix": ["en": "(under service)", "ar": "(تحت الصيانة)"],
        "mac.life_send_refused": ["en": "{name} is under service or retired, so nothing was sent to it.",
                                  "ar": "{name} تحت الصيانة أو خارج الخدمة، فلم يُرسل إليها شيء."],
        "mac.life_deleted_printer": ["en": "Deleted printer", "ar": "طابعة محذوفة"],
        "mac.life_status": ["en": "Status", "ar": "الحالة"],
        "mac.life_mark_service": ["en": "Mark Under Service…", "ar": "ضعها تحت الصيانة…"],
        "mac.life_mark_service_action": ["en": "Mark Under Service", "ar": "وضع تحت الصيانة"],
        "mac.life_back_in_service": ["en": "Back in Service", "ar": "أعدها للعمل"],
        "mac.life_retire": ["en": "Retire…", "ar": "أخرجها من الخدمة…"],
        "mac.life_retire_action": ["en": "Retire Printer", "ar": "إخراج الطابعة من الخدمة"],
        "mac.life_unretire": ["en": "Return to Service", "ar": "أعدها إلى الخدمة"],
        "mac.life_delete": ["en": "Delete Printer…", "ar": "احذف الطابعة…"],
        "mac.life_delete_action": ["en": "Delete Printer", "ar": "حذف الطابعة"],
        "mac.life_delete_blocked": ["en": "Can't delete — used by {what}", "ar": "لا يمكن حذفها — مستخدمة في {what}"],
        "mac.life_delete_blocked_hint": ["en": "Retire it instead: its history stays.",
                                         "ar": "أخرجها من الخدمة بدلًا من ذلك: يبقى سجلها."],
        "mac.life_delete_missing": ["en": "This printer is no longer in the book.", "ar": "هذه الطابعة لم تعد في الدفتر."],
        "mac.life_delete_refused_now": ["en": "Not deleted:", "ar": "لم تُحذف:"],
        "mac.life_ref_jobs": ["en": "{n} jobs", "ar": "{n} عملًا"],
        "mac.life_ref_jobs_one": ["en": "{n} job", "ar": "عمل واحد"],
        "mac.life_ref_jobs_two": ["en": "2 jobs", "ar": "عملين"],
        "mac.life_ref_jobs_few": ["en": "{n} jobs", "ar": "{n} أعمال"],
        "mac.life_ref_service": ["en": "{n} service entries", "ar": "{n} سجل صيانة"],
        "mac.life_ref_service_one": ["en": "{n} service entry", "ar": "سجل صيانة واحد"],
        "mac.life_ref_service_two": ["en": "2 service entries", "ar": "سجلَّي صيانة"],
        "mac.life_ref_service_few": ["en": "{n} service entries", "ar": "{n} سجلات صيانة"],
        "mac.life_ref_tasks": ["en": "{n} maintenance tasks", "ar": "{n} مهمة صيانة"],
        "mac.life_ref_tasks_one": ["en": "{n} maintenance task", "ar": "مهمة صيانة واحدة"],
        "mac.life_ref_tasks_two": ["en": "2 maintenance tasks", "ar": "مهمتَي صيانة"],
        "mac.life_ref_tasks_few": ["en": "{n} maintenance tasks", "ar": "{n} مهام صيانة"],
        "mac.life_ref_waste": ["en": "{n} waste entries", "ar": "{n} سجل هدر"],
        "mac.life_ref_waste_one": ["en": "{n} waste entry", "ar": "سجل هدر واحد"],
        "mac.life_ref_waste_two": ["en": "2 waste entries", "ar": "سجلَّي هدر"],
        "mac.life_ref_waste_few": ["en": "{n} waste entries", "ar": "{n} سجلات هدر"],
        "mac.life_ref_expenses": ["en": "{n} expenses", "ar": "{n} مصروفًا"],
        "mac.life_ref_expenses_one": ["en": "{n} expense", "ar": "مصروف واحد"],
        "mac.life_ref_expenses_two": ["en": "2 expenses", "ar": "مصروفين"],
        "mac.life_ref_expenses_few": ["en": "{n} expenses", "ar": "{n} مصروفات"],
        "mac.life_ref_time": ["en": "{n} time entries", "ar": "{n} سجل وقت"],
        "mac.life_ref_time_one": ["en": "{n} time entry", "ar": "سجل وقت واحد"],
        "mac.life_ref_time_two": ["en": "2 time entries", "ar": "سجلَّي وقت"],
        "mac.life_ref_time_few": ["en": "{n} time entries", "ar": "{n} سجلات وقت"],
        "mac.life_ref_completions": ["en": "{n} print records from the printer", "ar": "{n} سجل طباعة من الطابعة"],
        "mac.life_ref_completions_one": ["en": "the printer's own print record", "ar": "سجل طباعة واحد من الطابعة"],
        "mac.life_ref_completions_two": ["en": "2 print records from the printer", "ar": "سجلَّي طباعة من الطابعة"],
        "mac.life_ref_completions_few": ["en": "{n} print records from the printer", "ar": "{n} سجلات طباعة من الطابعة"],
        "mac.life_ref_other": ["en": "{n} other records", "ar": "{n} سجلًا آخر"],
        "mac.life_ref_other_one": ["en": "{n} other record", "ar": "سجل آخر واحد"],
        "mac.life_ref_other_two": ["en": "2 other records", "ar": "سجلين آخرين"],
        "mac.life_ref_other_few": ["en": "{n} other records", "ar": "{n} سجلات أخرى"],
        "mac.life_service_title": ["en": "Mark “{name}” under service?", "ar": "هل تضع «{name}» تحت الصيانة؟"],
        "mac.life_service_message": ["en": "Khayt stops asking it for its status and stops offering it for work until you put it back in service. Its history and costs stay.",
                                     "ar": "يتوقف خيط عن سؤالها عن حالتها وعن عرضها للعمل حتى تعيدها للعمل. يبقى سجلها وتكاليفها."],
        "mac.life_reason": ["en": "Reason (optional)", "ar": "السبب (اختياري)"],
        "mac.life_service_confirm": ["en": "Mark Under Service", "ar": "ضعها تحت الصيانة"],
        "mac.life_retire_title": ["en": "Retire “{name}”?", "ar": "هل تُخرج «{name}» من الخدمة؟"],
        "mac.life_retire_message": ["en": "A retired printer keeps its jobs, costs and service history, and leaves the lists, pickers and polling. You can return it to service later.",
                                    "ar": "تحتفظ الطابعة الخارجة من الخدمة بأعمالها وتكاليفها وسجل صيانتها، وتختفي من القوائم والاختيارات والمتابعة. يمكنك إعادتها إلى الخدمة لاحقًا."],
        "mac.life_retire_jobs": ["en": "{n} unfinished jobs will lose their printer.", "ar": "ستُزال الطابعة من {n} عملًا غير منتهٍ."],
        "mac.life_retire_jobs_one": ["en": "{n} unfinished job will lose its printer.", "ar": "ستُزال الطابعة من عمل واحد غير منتهٍ."],
        "mac.life_retire_jobs_two": ["en": "2 unfinished jobs will lose their printer.", "ar": "ستُزال الطابعة من عملين غير منتهيين."],
        "mac.life_retire_jobs_few": ["en": "{n} unfinished jobs will lose their printer.", "ar": "ستُزال الطابعة من {n} أعمال غير منتهية."],
        "mac.life_retire_none": ["en": "No unfinished job is on it.", "ar": "لا يوجد عليها عمل غير منتهٍ."],
        "mac.life_retire_confirm": ["en": "Retire", "ar": "أخرجها من الخدمة"],
        "mac.life_delete_title": ["en": "Delete “{name}”?", "ar": "هل تحذف «{name}»؟"],
        "mac.life_delete_message": ["en": "Nothing in the book refers to this printer, so it can be deleted. Undo brings it back.",
                                    "ar": "لا شيء في الدفتر يشير إلى هذه الطابعة، لذا يمكن حذفها. التراجع يعيدها."],
        "mac.life_now_service": ["en": "{name} is under service.", "ar": "«{name}» تحت الصيانة الآن."],
        "mac.life_now_in_service": ["en": "{name} is back in service.", "ar": "عادت «{name}» إلى العمل."],
        "mac.life_now_retired": ["en": "{name} is retired.", "ar": "خرجت «{name}» من الخدمة."],
        "mac.life_now_returned": ["en": "{name} is back in service.", "ar": "عادت «{name}» إلى الخدمة."],
        "mac.life_now_deleted": ["en": "{name} was deleted.", "ar": "حُذفت «{name}»."],
        "mac.life_jobs_unassigned": ["en": "{n} jobs no longer have a printer.", "ar": "{n} عملًا لم تعد لها طابعة."],
        "mac.life_jobs_unassigned_one": ["en": "{n} job no longer has a printer.", "ar": "عمل واحد لم تعد له طابعة."],
        "mac.life_jobs_unassigned_two": ["en": "2 jobs no longer have a printer.", "ar": "عملان لم تعد لهما طابعة."],
        "mac.life_jobs_unassigned_few": ["en": "{n} jobs no longer have a printer.", "ar": "{n} أعمال لم تعد لها طابعة."],
        "mac.life_not_polled_service": ["en": "Under service — Khayt is not asking it", "ar": "تحت الصيانة — لا يسألها خيط"],
        "mac.life_not_polled_retired": ["en": "Retired — Khayt is not asking it", "ar": "خارج الخدمة — لا يسألها خيط"],

        // ── Library inspector redesign ────────────────────────────────────
        // The model page's summary card and sections, the multi-select pane
        // and the regrouped right-click menu (LibraryInspector.swift,
        // GroupMenu.swift `ManyModels`, FileActions.swift `ModelActions`).
        "mac.li_print_time": ["en": "Print time", "ar": "مدة الطباعة"],
        "mac.li_filament": ["en": "Filament", "ar": "الخيط"],
        "mac.li_cost": ["en": "Cost to make", "ar": "تكلفة الصنع"],
        "mac.li_estimated_note": ["en": "≈ Estimated from the shape. Slice it for exact figures.",
                                  "ar": "≈ تقدير من الشكل. قطّعه في برنامج التقطيع لأرقام دقيقة."],
        "mac.li_no_figures": ["en": "No time or weight yet: the file hasn’t been sliced and its shape hasn’t been measured.",
                              "ar": "لا مدة ولا وزن بعد: لم يُقطَّع الملف ولم يُقَس شكله."],
        "mac.li_sells_as": ["en": "Sells as {name}", "ar": "يُباع باسم \u{2068}{name}\u{2069}"],
        "mac.li_open_product": ["en": "Open this product in the catalogue", "ar": "افتح هذا المنتج في الكتالوج"],
        "mac.li_margin_pct": ["en": "{pct}% margin", "ar": "هامش {pct}٪"],
        "mac.li_margin_below": ["en": "Below your {min}% minimum margin.", "ar": "أقل من الحد الأدنى لهامشك {min}٪."],
        "mac.li_not_in_catalogue": ["en": "Not in the catalogue yet", "ar": "ليس في الكتالوج بعد"],
        "mac.li_where": ["en": "Where it can print", "ar": "أين يمكن طباعته"],
        "mac.li_state_ready": ["en": "Ready", "ar": "جاهز"],
        "mac.li_state_ready_turned": ["en": "Ready, turned 90°", "ar": "جاهز بعد تدويره 90°"],
        "mac.li_state_needs_swap": ["en": "Fits, change a spool", "ar": "يتسع، بدّل بكرة"],
        "mac.li_state_fits": ["en": "Fits", "ar": "يتسع"],
        "mac.li_state_fits_turned": ["en": "Fits turned 90°", "ar": "يتسع بعد تدويره 90°"],
        "mac.li_state_too_big": ["en": "Too big", "ar": "أكبر من السرير"],
        // Library stage 3a: the printer chips on a tile, the Fits filter and
        // the list's Fits column (`LibraryFitChips`).
        "mac.fits_on": ["en": "Fits {name}", "ar": "يناسب \u{2068}{name}\u{2069}"],
        // Held left to right in Arabic too, so it reads "+2" and not "2+".
        "mac.lfc_more": ["en": "+{n}", "ar": "\u{2066}+{n}\u{2069}"],
        "mac.lfc_more_said": ["en": "and {n} more printers", "ar": "و\u{2068}{n}\u{2069} طابعة أخرى"],
        "mac.lfc_more_said_one": ["en": "and {n} more printer", "ar": "وطابعة أخرى"],
        "mac.lfc_more_said_two": ["en": "and {n} more printers", "ar": "وطابعتان أخريان"],
        "mac.lfc_more_said_few": ["en": "and {n} more printers", "ar": "و\u{2068}{n}\u{2069} طابعات أخرى"],
        "mac.lfc_where": ["en": "Where it can print: {list}", "ar": "أين يمكن طباعته: {list}"],
        "mac.lfc_too_big_all": ["en": "Too big for every printer", "ar": "أكبر من كل الطابعات"],
        "mac.lg_col_fits": ["en": "Fits", "ar": "يناسب"],
        // ⌘J, Jump to in Library (`LibraryJumpPalette`).
        "mac.jump": ["en": "Jump to in Library", "ar": "انتقل داخل المكتبة"],
        "mac.jump_prompt": ["en": "Models, folders, tags, saved searches\u{2026}",
                            "ar": "النماذج، المجلدات، الوسوم، عمليات البحث المحفوظة\u{2026}"],
        "mac.jump_hint": ["en": "\u{21A9} open · \u{2318}\u{21A9} quote · \u{2325}\u{21A9} new job · esc to close",
                          "ar": "\u{21A9} فتح · \u{2318}\u{21A9} عرض سعر · \u{2325}\u{21A9} عمل جديد · esc للإغلاق"],
        "mac.jump_hint_open": ["en": "\u{21A9} open · esc to close", "ar": "\u{21A9} فتح · esc للإغلاق"],
        "mac.jump_none": ["en": "Nothing in the library matches", "ar": "لا شيء في المكتبة يطابق"],
        "mac.jump_recent": ["en": "Recent models", "ar": "نماذج حديثة"],
        "mac.jump_kind_folder": ["en": "Folder", "ar": "مجلد"],
        "mac.jump_kind_archive": ["en": "Compressed file", "ar": "ملف مضغوط"],
        "mac.jump_kind_tag": ["en": "Tag", "ar": "وسم"],
        "mac.jump_kind_search": ["en": "Saved search", "ar": "بحث محفوظ"],
        "mac.goto_group_folder": ["en": "Folders", "ar": "المجلدات"],
        "mac.goto_group_archive": ["en": "Compressed files", "ar": "الملفات المضغوطة"],
        "mac.goto_group_tag": ["en": "Tags", "ar": "الوسوم"],
        "mac.goto_group_search": ["en": "Saved searches", "ar": "عمليات البحث المحفوظة"],
        "mac.li_too_big_all": ["en": "Too big for every printer you have. Scale it down in your slicer.",
                               "ar": "أكبر من كل طابعاتك. صغّره في برنامج التقطيع."],
        "mac.li_online_only": ["en": "The file is online only. Quotes, jobs and the catalogue use its saved figures; bring it back to open or slice it.",
                               "ar": "الملف على الإنترنت فقط. تستخدم العروض والأعمال والكتالوج أرقامه المحفوظة؛ أعِده لفتحه أو تقطيعه."],
        "mac.li_missing_file": ["en": "The file isn’t on this Mac. Quotes, jobs and the catalogue use its saved figures; reconnect its drive or import it again to open it.",
                                "ar": "الملف ليس على هذا الماك. تستخدم العروض والأعمال والكتالوج أرقامه المحفوظة؛ أعد توصيل قرصه أو استورده مجددًا لفتحه."],
        "mac.li_not_here": ["en": "Missing", "ar": "مفقود"],
        "mac.li_quote": ["en": "Quote", "ar": "عرض سعر"],
        "mac.li_new_job": ["en": "New Job", "ar": "عمل جديد"],
        "mac.li_add_catalogue": ["en": "Add to Catalogue", "ar": "أضف إلى الكتالوج"],
        "mac.li_drop_photo": ["en": "Drop to use as this model’s photo", "ar": "أفلتها لتصبح صورة هذا النموذج"],
        "mac.li_photo_help": ["en": "Drop a photo of the finished print here to use it as this model’s picture.",
                              "ar": "أفلت هنا صورة للقطعة المطبوعة لتصبح صورة هذا النموذج."],
        "mac.li_sec_print": ["en": "Print", "ar": "الطباعة"],
        "mac.li_sec_file": ["en": "File & Storage", "ar": "الملف والتخزين"],
        "mac.li_sec_shape": ["en": "Shape", "ar": "الشكل"],
        "mac.li_sec_build": ["en": "Parts, Versions & Setups", "ar": "الأجزاء والإصدارات والإعدادات"],
        "mac.li_sec_origin": ["en": "Origin", "ar": "المصدر"],
        "mac.li_sec_notes": ["en": "Notes", "ar": "ملاحظات"],
        "mac.li_sec_archive": ["en": "Archive", "ar": "الأرشفة"],
        "mac.li_volume": ["en": "Volume", "ar": "الحجم"],
        "mac.li_dimensions": ["en": "Size", "ar": "الأبعاد"],
        "mac.li_file_size": ["en": "Size", "ar": "حجم الملف"],
        "mac.li_open_in_catalogue": ["en": "Open in Catalogue", "ar": "فتح في الكتالوج"],
        "mac.arc_inside": ["en": "Inside a compressed file", "ar": "داخل ملف مضغوط"],
        "mac.li_risk_title": ["en": "Likely print problems", "ar": "مشاكل طباعة محتملة"],
        "mac.li_risk_no_file": ["en": "Overhangs can’t be checked because the file isn’t on this Mac. Reconnect its drive or import it again, then check.",
                                "ar": "لا يمكن فحص البروزات لأن الملف ليس على هذا الماك. أعد توصيل قرصه أو استورده مجددًا ثم افحصه."],
        "mac.li_risk_online": ["en": "Overhangs can’t be checked while the file is online only. Bring it back to this Mac, then check.",
                               "ar": "لا يمكن فحص البروزات والملف على الإنترنت فقط. أعِده إلى هذا الماك ثم افحصه."],
        "mac.li_hidden_selected": ["en": "Also selected but not shown: {n}, inside folders or filtered out. Nothing here touches them.",
                                   "ar": "محدد أيضًا لكن غير ظاهر: {n}، داخل مجلدات أو مخفي بالتصفية. لا يمسّها شيء هنا."],
        "mac.li_online_only_label": ["en": "Online only", "ar": "على الإنترنت فقط"],
        "mac.li_totals_partial": ["en": "Time and filament cover {n} of {total}; the rest have no figures yet.",
                                  "ar": "تشمل المدة والخيط {n} من {total}؛ البقية بلا أرقام بعد."],
        "mac.li_not_here_n": ["en": "Not on this Mac: {n}", "ar": "ليست على هذا الماك: {n}"],
        "mac.li_group_print": ["en": "Print", "ar": "الطباعة"],
        "mac.li_group_organise": ["en": "Organise", "ar": "التنظيم"],
        "mac.li_group_share": ["en": "Share & Sell", "ar": "المشاركة والبيع"],
        "mac.li_group_storage": ["en": "Storage", "ar": "التخزين"],
        "mac.li_group_remove": ["en": "Archive or Delete", "ar": "الأرشفة أو الحذف"],
        "mac.li_quote_these": ["en": "Quote {n} Models…", "ar": "عرض سعر لـ\u{2068}{n}\u{2069} نموذجًا…"],
        "mac.li_quote_these_one": ["en": "Quote {n} Model…", "ar": "عرض سعر لنموذج واحد…"],
        "mac.li_quote_these_two": ["en": "Quote {n} Models…", "ar": "عرض سعر لنموذجين…"],
        "mac.li_quote_these_few": ["en": "Quote {n} Models…", "ar": "عرض سعر لـ\u{2068}{n}\u{2069} نماذج…"],
        "mac.li_catalogue_single": ["en": "One Product of All…", "ar": "منتج واحد للجميع…"],
        "mac.li_catalogue_each": ["en": "A Product for Each", "ar": "منتج لكل نموذج"],
        "mac.li_add_tag": ["en": "Add Tag…", "ar": "إضافة وسم…"],
        "mac.li_add_tag_menu": ["en": "Add Tag", "ar": "إضافة وسم"],
        "mac.li_add_tag_title": ["en": "Add a tag", "ar": "إضافة وسم"],
        "mac.li_add_tag_note": ["en": "Added to the tags each model already has. A tag you already use keeps its spelling.",
                                "ar": "يُضاف إلى الوسوم الموجودة في كل نموذج. الوسم المستخدم من قبل يحتفظ بكتابته."],
        "mac.li_add_tag_action": ["en": "Add Tag", "ar": "إضافة وسم"],
        "mac.li_add": ["en": "Add", "ar": "إضافة"],
        "mac.li_set": ["en": "Set", "ar": "تعيين"],
        "mac.li_set_category": ["en": "Set Category", "ar": "تعيين التصنيف"],
        "mac.li_move_folder": ["en": "Move to Folder", "ar": "نقل إلى مجلد"],
        "mac.li_set_material": ["en": "Set Material…", "ar": "تعيين الخامة…"],
        "mac.li_set_material_title": ["en": "Material", "ar": "الخامة"],
        "mac.li_set_material_action": ["en": "Set Material", "ar": "تعيين الخامة"],
        "mac.li_material_example": ["en": "PLA, PETG, TPU 95A…", "ar": "PLA، PETG، TPU 95A…"],
        "mac.li_material_note": ["en": "Replaces the material on every selected model. Leave it empty to clear it.",
                                 "ar": "يستبدل الخامة في كل النماذج المحددة. اتركه فارغًا لمسحها."],
        "mac.li_free_up_n": ["en": "Free Up Space ({n})", "ar": "توفير المساحة ({n})"],
        "mac.li_unkeep": ["en": "Stop Keeping on This Mac", "ar": "إيقاف الإبقاء على هذا الماك"],
        "mac.li_free_skipped": ["en": "Left on this Mac because an open job needs them: {n}",
                                "ar": "بقيت على هذا الماك لأن عملًا مفتوحًا يحتاجها: {n}"],
        // Khayt as a printer in the slicer (`LanServer+SlicerUpload`, `SlicerInboxSheet`).
        "mac.su_title": ["en": "From Your Slicer", "ar": "من برنامج التقطيع"],
        "mac.su_button": ["en": "From Slicer", "ar": "من برنامج التقطيع"],
        "mac.su_hint": ["en": "Files your slicer sent to Khayt, with the slicer's own weight and print time. Add one to the library, or start a job or a quote from it.",
                        "ar": "ملفات أرسلها برنامج التقطيع إلى خيط، بالوزن وزمن الطباعة كما حسبهما البرنامج. أضف أيًّا منها إلى المكتبة، أو ابدأ منه عملًا أو عرض سعر."],
        "mac.su_none": ["en": "Nothing has arrived from a slicer yet.",
                        "ar": "لم يصل شيء من برنامج التقطيع بعد."],
        "mac.su_no_figures": ["en": "The file does not say its weight and time.",
                              "ar": "لا يذكر الملف وزنه ولا زمن طباعته."],
        "mac.su_arrived": ["en": "Arrived {when}", "ar": "وصل {when}"],
        "mac.su_add": ["en": "Add to Library", "ar": "إضافة إلى المكتبة"],
        "mac.su_job": ["en": "New Job", "ar": "عمل جديد"],
        "mac.su_quote": ["en": "New Quote", "ar": "عرض سعر جديد"],
        "mac.su_discard": ["en": "Discard", "ar": "تجاهل"],
        "mac.su_added": ["en": "{name} is in the library.", "ar": "أصبح {name} في المكتبة."],
        "mac.su_gone": ["en": "That file is no longer in the inbox.",
                        "ar": "لم يعد هذا الملف في صندوق الوارد."],
        "mac.su_waiting": ["en": "{n} files from your slicer", "ar": "{n} ملف من برنامج التقطيع"],
        "mac.su_waiting_one": ["en": "{n} file from your slicer", "ar": "ملف واحد من برنامج التقطيع"],
        "mac.su_waiting_two": ["en": "{n} files from your slicer", "ar": "ملفان من برنامج التقطيع"],
        "mac.su_waiting_few": ["en": "{n} files from your slicer", "ar": "{n} ملفات من برنامج التقطيع"],
        "mac.su_settings_title": ["en": "Khayt as a Printer in Your Slicer",
                                  "ar": "خيط كطابعة في برنامج التقطيع"],
        "mac.su_accept": ["en": "Accept files from slicers (OctoPrint upload)",
                          "ar": "استقبال الملفات من برامج التقطيع (رفع OctoPrint)"],
        "mac.su_accept_hint": ["en": "In OrcaSlicer, PrusaSlicer or Bambu Studio, add a physical printer of type OctoPrint with the address and API key below. Every file you send lands in From Slicer with the slicer's grams and time. Khayt never starts a printer from here.",
                               "ar": "في OrcaSlicer أو PrusaSlicer أو Bambu Studio، أضف طابعة فعلية من نوع OctoPrint بالعنوان ومفتاح API أدناه. كل ملف ترسله يصل إلى «من برنامج التقطيع» بالغرامات والزمن كما حسبها البرنامج. لا يشغّل خيط أي طابعة من هنا."],
        "mac.su_address": ["en": "Address", "ar": "العنوان"],
        "mac.su_key": ["en": "API key", "ar": "مفتاح API"],
        "mac.su_copy": ["en": "Copy", "ar": "نسخ"],
        "mac.su_regenerate": ["en": "Regenerate", "ar": "إنشاء مفتاح جديد"],
        "mac.su_regenerate_note": ["en": "A new key stops every slicer that has the old one until you paste the new one in.",
                                   "ar": "المفتاح الجديد يوقف كل برنامج تقطيع يحمل المفتاح القديم حتى تلصق الجديد فيه."],
        "mac.su_needs_lan": ["en": "Turn on the LAN server and let other devices reach it, above, so a slicer on another computer can find this Mac.",
                             "ar": "شغّل خادم الشبكة المحلية واسمح للأجهزة الأخرى بالوصول إليه أعلاه، ليجد برنامج التقطيع على جهاز آخر هذا الماك."],
        "mac.su_no_key": ["en": "This Mac's Keychain would not keep the key.",
                          "ar": "تعذّر حفظ المفتاح في سلسلة مفاتيح هذا الماك."],
    ]

    /// The Khayt keys this app leans on. Listed so a test can prove every one of
    /// them still exists in every bundled language — a key that disappears from
    /// the shared catalogue would otherwise surface as a raw `queue.printing`
    /// sitting in the sidebar.
    /// The shared keys this app uses. `PrintFactLines` declares its own, so a
    /// key added to that panel cannot be forgotten here.
    static let borrowed = PrintFactLines.borrowedKeys + [
        // The first-run setup's filament step, in the Spool sheet's own words.
        "inv.cost", "inv.weight",
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
        "ce.wab_offers",
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
        "inv.colour_variant", "inv.lot", "inv.material_ph", "inv.opened_on", "inv.price_history",
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
    ///
    /// ── AND ITS DIGITS ARE THIS MAC'S CHOICE, NOT THE LANGUAGE'S ──────────
    ///
    /// Western 0–9 in both languages unless "Use the Mac's number format" is
    /// on (`Digits`, Settings ▸ On this Mac). The one locale everything a
    /// person reads is formatted in; the window puts it in the environment so
    /// `Text(_, format:)` and every `TextField` take it too.
    var locale: Locale { Digits.locale(language: language) }

    /// The one way a displayed date is written. Takes any `Date.FormatStyle`,
    /// so `.dateTime.day().month(.abbreviated)` and
    /// `Date.FormatStyle(date: .abbreviated, time: .shortened)` both go
    /// through it — which is what lets a test find the ones that do not.
    ///
    /// In the BOOK's calendar, Gregorian. A style left alone takes the Mac's
    /// calendar, and on a Mac set to Umm al-Qura every date Khayt showed read
    /// "Safar 1448 AH" — while the book, the invoices and the other app say
    /// September 2026 (Oct 2026). The language is the shop's; the calendar is
    /// the book's, the same split `Calendar.book` makes for stored days.
    func say(_ date: Date, _ style: Date.FormatStyle) -> String {
        var style = style
        style.calendar = .book
        return date.formatted(style.locale(locale))
    }

    /// The currency menu, in the shop's language and sorted in it.
    ///
    /// The shared table's labels are English only ("Saudi Riyal (SAR)"), so
    /// the Arabic Settings window and first-run setup listed every currency
    /// in English, ordered by the English name (alpha.56 review). The name
    /// comes from the system's own currency names for this language instead,
    /// with the code kept beside it because it is what invoices print. The
    /// table's label is the fallback for a code the system does not name.
    ///
    /// `labels` is code → the table's label; `current` is added if the table
    /// does not have it, so the picker is never blank.
    func currencyChoices(_ labels: [String: String], current: String? = nil) -> [(code: String, label: String)] {
        var codes = Array(labels.keys)
        if let current, !current.isEmpty, labels[current] == nil { codes.append(current) }
        let named = codes.map { code -> (code: String, label: String) in
            if let name = locale.localizedString(forCurrencyCode: code), !name.isEmpty,
               name.uppercased() != code.uppercased() {
                return (code, "\(name) (\(code))")
            }
            return (code, labels[code] ?? code)
        }
        let order = locale
        return named.sorted {
            $0.label.compare($1.label, options: [.caseInsensitive], range: nil, locale: order) == .orderedAscending
        }
    }

    /// Why the first-run setup's Finish did not save, as a sentence.
    ///
    /// `startingBook` is the failure of creating the empty book, as opposed
    /// to writing the answers into one.
    func setupFailure(_ error: Error, startingBook: Bool) -> String {
        if startingBook {
            if let cocoa = error as? CocoaError, cocoa.code == .fileWriteFileExists {
                return callIt("mac.setup_err_exists")
            }
            return callIt("mac.setup_err_start")
        }
        switch error as? StoreWriter.Refusal {
        case .notOurs?: return callIt("mac.setup_err_not_ours")
        case .tooLarge?: return callIt("mac.setup_err_too_large")
        case .unreadable?: return callIt("mac.setup_err_unreadable")
        case nil: return callIt("mac.setup_err_other")
        }
    }
}

extension Words {

    /// A unit as this shop READS it — never as it is stored.
    ///
    /// The book keeps whatever was typed into the unit field ("L", "roll",
    /// "each", "kg"), and the Arabic inventory printed those as they were:
    /// English units under Arabic names, and "3× · kg" pulled apart by the
    /// bidi algorithm. A unit this app knows is said in the shop's language;
    /// one it does not is shown exactly as the shop wrote it. The stored value
    /// is never touched, so a supplier's form and the other app still read "kg".
    func unitWord(_ stored: String) -> String {
        let raw = stored.trimmingCharacters(in: .whitespaces)
        guard let key = Self.unitKeys[raw.lowercased()] else { return raw }
        // English keeps the shop's own spelling ("Rolls", "pcs") — only a
        // language with a word of its own replaces it.
        if language == "en" { return raw }
        guard let said = Self.own[key]?[language], !said.isEmpty else { return raw }
        return said
    }

    /// A quantity and its unit, held together in their own direction.
    ///
    /// A first-strong isolate: "3 لتر" runs right to left and "3 pcs" left to
    /// right, and neither is reordered by the sentence around it.
    func amount(_ figure: String, _ storedUnit: String) -> String {
        let unit = unitWord(storedUnit)
        guard !unit.isEmpty else { return figure }
        // ARABIC COUNTS A COUNTABLE UNIT: "4 لفة" is "four roll". Two is the
        // dual and carries no numeral (as `counting` says it); three to ten
        // take the plural. Only for a unit this app knows and a whole count —
        // "2.5 كغ" is a measure, not a number of things.
        if let counted = countedUnit(figure, storedUnit) {
            return "\u{2068}" + counted + "\u{2069}"
        }
        return "\u{2068}" + figure + " " + unit + "\u{2069}"
    }

    /// The count and its unit in Arabic's own form for that count, or nil
    /// when the plain "figure unit" is right (any other language, a unit with
    /// no forms given, a figure that is not a whole number).
    func countedUnit(_ figure: String, _ storedUnit: String) -> String? {
        guard language == "ar",
              let key = Self.unitKeys[storedUnit.trimmingCharacters(in: .whitespaces).lowercased()],
              let n = Self.wholeCount(figure) else { return nil }
        if n == 2, let dual = Self.own[key + "_two"]?["ar"], !dual.isEmpty { return dual }
        if (3...10).contains(n % 100), let few = Self.own[key + "_few"]?["ar"], !few.isEmpty {
            return figure + " " + few
        }
        return nil
    }

    /// A figure as a whole number, in either set of digits, grouping marks
    /// and all; nil for a fraction or anything that is not a number.
    nonisolated static func wholeCount(_ figure: String) -> Int? {
        let arabicIndic = Array("٠١٢٣٤٥٦٧٨٩")
        var digits = ""
        for ch in figure.trimmingCharacters(in: .whitespaces) {
            if let i = arabicIndic.firstIndex(of: ch) { digits.append(Character(String(i))) }
            else if ch.isASCII, ch.isNumber { digits.append(ch) }
            else if ch == "," || ch == "٬" || ch == "\u{00A0}" || ch == "\u{202F}" { continue }
            else { return nil }
        }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// A consumable shelf (its category) as this shop reads it. The common
    /// English names a shop or the sample book types are said in the shop's
    /// language; anything else is the shop's own word, untouched.
    func shelfWord(_ stored: String) -> String {
        let raw = stored.trimmingCharacters(in: .whitespaces)
        let folded = raw.lowercased().split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard language != "en", let key = Self.shelfKeys[folded],
              let said = Self.own[key]?[language], !said.isEmpty else { return raw }
        return said
    }

    /// Spellings a shop actually types, to the word that says them.
    nonisolated static let unitKeys: [String: String] = [
        "each": "mac.unit_each", "ea": "mac.unit_each", "unit": "mac.unit_each", "units": "mac.unit_each",
        "pc": "mac.unit_piece", "pcs": "mac.unit_piece", "piece": "mac.unit_piece", "pieces": "mac.unit_piece",
        "roll": "mac.unit_roll", "rolls": "mac.unit_roll",
        "box": "mac.unit_box", "boxes": "mac.unit_box",
        "bag": "mac.unit_bag", "bags": "mac.unit_bag",
        "pack": "mac.unit_pack", "packs": "mac.unit_pack",
        "pair": "mac.unit_pair", "pairs": "mac.unit_pair",
        "bottle": "mac.unit_bottle", "bottles": "mac.unit_bottle",
        "spool": "mac.unit_spool", "spools": "mac.unit_spool",
        "sheet": "mac.unit_sheet", "sheets": "mac.unit_sheet",
        "kg": "mac.unit_kg", "kilo": "mac.unit_kg", "kilogram": "mac.unit_kg", "kilograms": "mac.unit_kg",
        "g": "mac.unit_g", "gram": "mac.unit_g", "grams": "mac.unit_g",
        "l": "mac.unit_l", "litre": "mac.unit_l", "liter": "mac.unit_l", "litres": "mac.unit_l", "liters": "mac.unit_l",
        "ml": "mac.unit_ml",
        "m": "mac.unit_m", "metre": "mac.unit_m", "meter": "mac.unit_m",
    ]

    nonisolated static let shelfKeys: [String: String] = [
        "packaging": "mac.shelf_packaging", "packing": "mac.shelf_packaging",
        "cleaning": "mac.shelf_cleaning",
        "spares": "mac.shelf_spares", "spare parts": "mac.shelf_spares", "spare": "mac.shelf_spares",
        "tools": "mac.shelf_tools",
        "hardware": "mac.shelf_hardware", "fasteners": "mac.shelf_hardware",
        "adhesives": "mac.shelf_adhesives", "glue": "mac.shelf_adhesives",
        "maintenance": "mac.shelf_maintenance",
        "safety": "mac.shelf_safety", "ppe": "mac.shelf_safety",
        "labels": "mac.shelf_cat_labels",
        "finishing": "mac.shelf_finishing", "post-processing": "mac.shelf_finishing",
        "electronics": "mac.shelf_electronics",
    ]
}

/// The shop's locale — its language, and the digits this Mac asked for — put
/// into a window's environment, so `Text(_, format:)`, `Text(_, style:)`,
/// every `TextField(value:format:)` and every picker draw in it rather than in
/// the Mac's locale. Every window and the menu bar panel wear it;
/// `DigitsTests` checks that they do.
///
/// A modifier rather than an `.environment` written at each root, because a
/// modifier's body is observed: switching "Use the Mac's number format" or the
/// language redraws what it holds.
struct ShopsLocale: ViewModifier {
    let words: Words
    func body(content: Content) -> some View {
        // The book's calendar too: without it every DatePicker on a Mac set
        // to Umm al-Qura offered Hijri months beside labels in Gregorian.
        content.environment(\.locale, words.locale)
            .environment(\.calendar, .book)
    }
}
