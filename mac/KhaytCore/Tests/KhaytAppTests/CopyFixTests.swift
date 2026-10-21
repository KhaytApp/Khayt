import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Words the beta.1 review found the shop reading wrong: store keys on
/// screen, "(s)" plurals, an Arabic comma in English, counts that never
/// asked Arabic how many.
@MainActor
struct CopyFixTests {

    static func arabic() async throws -> Words {
        let words = Words()
        await words.load("ar", engine: try KhaytEngine())
        return words
    }

    static func sampleCollections() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Resources/sample-shop.json")
        let book = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        return book.compactMap { $0.value is [Any] ? $0.key : nil }.sorted()
    }

    // MARK: - What sync took: a word, not the store's key

    @Test("every collection in a book is named by a word in both languages; an unknown one is a record")
    func lossKinds() async throws {
        let en = Words()
        let ar = try await Self.arabic()
        let collections = try Self.sampleCollections()
        #expect(collections.count > 10)
        for collection in collections {
            let key = SyncLossesSheet.kindKey(collection)
            #expect(key != "mac.losses_kind_record", "\(collection) has no word of its own")
            for words in [en, ar] {
                let said = words.callIt(key)
                #expect(said != key && said != collection, "\(collection) reads \(said)")
            }
        }
        #expect(en.callIt(SyncLossesSheet.kindKey("printLog")) == "Job")
        #expect(ar.callIt(SyncLossesSheet.kindKey("clients")) == "عميل")
        #expect(en.callIt(SyncLossesSheet.kindKey("somethingNew")) == "Record")
        #expect(ar.callIt(SyncLossesSheet.kindKey("somethingNew")) == "سجل")
    }

    // MARK: - Lists

    @Test("the outbound refusal lists channels the shop's language's way")
    func outboundList() async throws {
        let reaches = try JSONDecoder().decode([Outbound].self, from: Data("""
            [{"channel":"telegram","why":"enabled"},{"channel":"email","why":"enabled"},
             {"channel":"portal","why":"published"}]
            """.utf8))
        let en = Words().outboundRefusal(reaches)
        #expect(en.contains("a Telegram message, an email, and the customer's tracking link")
                || en.contains("a Telegram message, an email and the customer's tracking link"), "\(en)")
        #expect(!en.contains("،"), "an Arabic comma in English: \(en)")
        let ar = try await Self.arabic().outboundRefusal(reaches)
        #expect(ar.contains("و"), "\(ar)")
    }

    // MARK: - Plurals that decided

    @Test("what sync took: one clause per non-zero count, each its own plural")
    func lossBanner() async throws {
        func loss(_ kind: SyncLoss.Kind, _ id: String) -> SyncLoss {
            SyncLoss(kind: kind, collection: "printLog", recordId: id, record: .object([:]), replacedBy: nil)
        }
        let one = SyncLossNotice(files: [], losses: [loss(.replaced, "a")])
        let mixed = SyncLossNotice(files: [], losses: [loss(.replaced, "a"), loss(.keptDeleted, "b"),
                                                       loss(.removed, "c")])
        let en = Words()
        #expect(SyncLossBanner.said(one, en) == "Sync replaced 1 record changed on this Mac. A copy of each was kept.")
        #expect(SyncLossBanner.said(mixed, en)
                == "Sync replaced 2 records changed on this Mac and removed 1 record. A copy of each was kept.")
        let ar = try await Self.arabic()
        let said = SyncLossBanner.said(mixed, ar)
        #expect(said.contains("سجلّين") && said.contains("سجلًا واحدًا"), "\(said)")
        #expect(!said.contains("{"), "\(said)")
    }

    @Test("no English word in the Mac's own table says (s)")
    func noMaybePlurals() {
        let offenders = Words.own.compactMap { key, value -> String? in
            (value["en"] ?? "").contains("(s)") ? key : nil
        }
        #expect(offenders.isEmpty, "count it with counting(): \(offenders.sorted())")
    }

    @Test("webhooks told and discarded edits count in both languages")
    func countedSentences() async throws {
        let en = Words()
        #expect(en.counting(1, "mac.webhooks_sent") == "Told 1 other system.")
        #expect(en.counting(3, "mac.webhooks_sent") == "Told 3 other systems.")
        #expect(en.counting(1, "mac.cloud_lost_edits").hasPrefix("1 change made here was discarded"))
        #expect(en.counting(1, "mac.losses_dismiss_body").hasPrefix("1 record sync took has not"))
        let ar = try await Self.arabic()
        #expect(ar.counting(2, "mac.webhooks_sent") == "أُبلغ نظامان آخران.")
        #expect(ar.counting(5, "mac.cloud_lost_edits").hasPrefix("أُلغيت 5 تغييرات"))
    }

    // MARK: - Smaller things the review read

    @Test("dashboard counts are grouped and in the shop's digits, not a bare \\(n)")
    func dashboardCounts() {
        let dashboard = EmptyStateTests.source("Dashboard.swift")
        #expect(!dashboard.contains("value: \"\\("), "a Stat value interpolates a raw number")
        #expect(dashboard.contains("value: Money.quantity(Double(facts.printingCount), decimals: 0)"))
    }

    @Test("one word for the person a job is for: Customer, not Client")
    func customerNotClient() async throws {
        for file in ["CustomersTable.swift", "OrdersTable.swift", "NewJobSheet.swift"] {
            #expect(!EmptyStateTests.source(file).contains("callIt(\"doc.client\")"), "\(file)")
        }
        #expect(Words().callIt("mac.customer") == "Customer")
        let ar = try await Self.arabic()
        #expect(ar.callIt("mac.customer") == ar.callIt("doc.client"), "Arabic already said one word")
    }

    @Test("an empty expenses or waste log says why its buttons are grey, and its title has no full stop")
    func emptyLogs() async throws {
        let spending = EmptyStateTests.source("Spending.swift")
        #expect(spending.components(separatedBy: "WhyLockedNote(shop: shop)").count - 1 == 2)
        let ar = try await Self.arabic()
        for words in [Words(), ar] {
            for key in ["mac.expenses_empty", "mac.waste_empty", "mac.no_customers"] {
                #expect(!words.callIt(key).hasSuffix("."), "\(key)")
            }
        }
    }

    @Test("the WhatsApp report hint says Meta tells Khayt Cloud")
    func waHookHint() {
        #expect(Words().callIt("mac.wa_hook_hint").hasPrefix("Meta tells Khayt Cloud whether each WhatsApp message was delivered and read"))
    }

    @Test("an icon-only button says its name to VoiceOver, not only on hover")
    func iconButtonsAreNamed() throws {
        let sites: [(String, String)] = [
            ("LibraryInspector.swift", "shop.words.callIt(file.isFavourite ? \"mac.unmake_favourite\" : \"mac.make_favourite\")"),
            ("SettingsWindow.swift", "shop.words.callIt(\"mac.slicer_make_default\")"),
            ("SettingsWindow.swift", "shop.words.callIt(\"mac.slicer_remove\")"),
            ("FixedCostsSettings.swift", "shop.words.callIt(\"mac.fixed_remove\")"),
            ("ProductSheet.swift", "shop.words.callIt(\"common.delete\")"),
            ("WebStore.swift", "w.callIt(\"common.delete\")"),
            ("Calculator.swift", "shop.words.callIt(\"common.delete\")"),
            ("ModelConsumables.swift", "shop.words.callIt(\"common.delete\")"),
            ("Operators.swift", "words.callIt(\"common.delete\")"),
            ("ShopFloor.swift", "shop.words.callIt(\"cons.add_title\")"),
        ]
        for (file, said) in sites {
            let source = EmptyStateTests.source(file)
            let pair = try Regex("\\.help\\(" + NSRegularExpression.escapedPattern(for: said)
                                 + "\\)\\n\\s*\\.accessibilityLabel\\(" + NSRegularExpression.escapedPattern(for: said) + "\\)")
            #expect(source.contains(pair), "\(file): \(said)")
        }
    }

    // MARK: - Arabic counts

    @Test("counted sentences take Arabic's one, two, few and many forms")
    func arabicCounts() async throws {
        let ar = try await Self.arabic()
        #expect(ar.counting(1, "mac.days_late") == "متأخر يومًا واحدًا")
        #expect(ar.counting(2, "mac.days_late") == "متأخر يومين")
        #expect(ar.counting(5, "mac.days_late") == "متأخر 5 أيام")
        #expect(ar.counting(14, "mac.days_late") == "متأخر 14 يومًا")
        #expect(ar.counting(1, "mac.days_over") == "متأخر يومًا واحدًا", "no numeral prepended to the one form")
        #expect(ar.counting(2, "mac.days_over") == "متأخر يومين")
        #expect(ar.counting(9, "mac.printed_n") == "طُبع 9 مرات")
        #expect(ar.counting(2, "mac.printed_n") == "طُبع مرتين")
        #expect(ar.counting(18, "mac.cm_people") == "18 شخصًا")
        #expect(ar.counting(4, "mac.cm_people") == "4 أشخاص")
        #expect(ar.counting(1, "mac.prints_word") == "طبعة واحدة")
        #expect(ar.counting(12, "mac.prints_word") == "12 طبعة")
        #expect(ar.counting(2, "mac.n_groups_of") == "مجموعتين")
        #expect(ar.counting(12, "mac.band_machines") == "12 طابعة")
        let en = Words()
        #expect(en.counting(1, "mac.days_late") == "1 day late")
        #expect(en.counting(1, "mac.printed_n") == "printed 1×")
    }

    @Test("a quote funnel's open line counts quotes and days on their own")
    func quoteFunnelOpen() async throws {
        let ar = try await Self.arabic()
        let said = ar.callIt("mac.qf_open", ["quotes": .string(ar.counting(2, "mac.qf_quotes")),
                                              "amount": .string("100"),
                                              "days": .string(ar.counting(2, "mac.qf_days"))])
        #expect(said.contains("عرضين") && said.contains("منذ يومين"), "\(said)")
        #expect(EmptyStateTests.source("QuoteFunnel.swift").contains("words.counting(report.totals.openCount, \"mac.qf_quotes\")"))
    }

    @Test("an average in days: counted when whole, the singular for a fraction")
    func cycleDays() async throws {
        let ar = try await Self.arabic()
        #expect(CycleTimeCard.said(0.7, ar) == "0.7 يوم")
        #expect(CycleTimeCard.said(2, ar) == "يومان")
        #expect(CycleTimeCard.said(1, Words()) == "1 day")
        #expect(CycleTimeCard.said(2.5, Words()) == "2.5 days")
    }

    // MARK: - Smaller Arabic fixes

    @Test("a P&L quarter is named, not keyed")
    func quarterLabels() async throws {
        #expect(MonthLabel.period("2026-Q3", words: Words()) == "Q3 " + Figure.isolated("2026"))
        let ar = try await Self.arabic()
        #expect(MonthLabel.period("2026-Q3", words: ar) == "الربع الثالث " + Figure.isolated("2026"))
        #expect(MonthLabel.period("2026-08", words: ar) == "2026-08")
        #expect(MonthLabel.period("2026-Q9", words: ar) == "2026-Q9")
    }

    @Test("the extruder type is a word in the shop's language")
    func extruderWords() async throws {
        let ar = try await Self.arabic()
        #expect(MachineCard.extruderWord("Direct Drive", ar) == "دفع مباشر")
        #expect(MachineCard.extruderWord("Bowden", ar) == "بودن")
        #expect(MachineCard.extruderWord("Something else", ar) == "Something else")
    }

    @Test("move along is ⌘→ and left to the system to mirror in Arabic")
    func moveAlongArrow() {
        // AppKit mirrors arrow key equivalents in a right-to-left interface;
        // a hand flip on top of that turned "along" back into "back".
        let menus = EmptyStateTests.source("Menus.swift")
        #expect(menus.contains(".keyboardShortcut(.rightArrow, modifiers: .command, localization: .automatic)"))
        #expect(menus.contains(".keyboardShortcut(.leftArrow, modifiers: .command, localization: .automatic)"))
        #expect(!menus.contains("isRTL"), "the menu flips an arrow the system already flips")
    }

    @Test("time left is isolated, so a negative figure does not turn the Arabic line around")
    func negativeTimeLeft() {
        let floor = EmptyStateTests.source("ShopFloor.swift")
        #expect(floor.contains("let n = Figure.isolated(Money.quantity(v.rounded(), decimals: 0))"))
        #expect(!floor.contains(".locale(shop.words.locale))\n        return \"\\(n)"))
    }

    @Test("band tick labels sit on zero-width frames, not alignment guides that grow the ruler")
    func bandTicks() {
        let band = EmptyStateTests.source("MachineBand.swift")
        #expect(band.contains(".frame(width: 0, alignment: minute == 0 ? .leading"))
        #expect(!band.contains("minute == 0 ? 0 : (minute >= band.minutes ? d.width : d.width / 2)"))
    }

    // MARK: - Second pass

    @Test("the dashboard's day counts go through counting(), so Arabic gets its dual and 3-10 forms")
    func dashboardDays() async throws {
        let dashboard = EmptyStateTests.source("Dashboard.swift")
        #expect(dashboard.contains("shop.words.counting(late, \"mac.days_late\")"))
        #expect(!dashboard.contains("\"mac.days_late_one\""), "a hand-picked singular skips the other forms")
        #expect(dashboard.contains("shop.words.counting(days, \"mac.chase_days_over\")"))
        let ar = try await Self.arabic()
        #expect(ar.counting(2, "mac.chase_days_over") == "متأخرة يومين")
        #expect(ar.counting(4, "mac.chase_days_left") == "تنتهي خلال 4 أيام")
    }

    @Test("none, in Arabic words, where the word has a zero form; English is untouched")
    func zeroCounts() async throws {
        let ar = try await Self.arabic()
        #expect(ar.counting(0, "mac.n_machines") == "لا آلات")
        #expect(ar.counting(0, "mac.cm_people") == "لا أحد")
        #expect(ar.counting(0, "mac.qf_days") == "اليوم")
        #expect(ar.counting(0, "mac.avg_days") == "أقل من يوم")
        #expect(Words().counting(0, "mac.n_machines") == "0 machines")
    }

    @Test("counts in word lines take the shop's digits, not a bare \\(Int)")
    func numeralsInLines() {
        let floor = EmptyStateTests.source("ShopFloor.swift")
        #expect(floor.contains("shop.words.numeral(low) + \" \" + shop.words.callIt(\"cons.low\")"))
        #expect(floor.contains("shop.words.numeral(Int(saturating: wear.wear))"))
        #expect(EmptyStateTests.source("RatingTrend.swift").contains("words.numeral(trend.responses)"))
    }
}

