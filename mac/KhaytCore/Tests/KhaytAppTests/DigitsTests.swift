import Foundation
import Testing
import KhaytCore
import KhaytWidgetData
import KhaytWidgetViews
@testable import KhaytApp

/// Western digits by default, in both languages; the Mac's own when asked.
///
/// ── WHAT WENT WRONG ───────────────────────────────────────────────────────
///
/// The Arabic app was built on a bare `ar` locale, whose digits are 0–9. The
/// English app took the Mac's locale wherever a formatter was left alone — a
/// count, a percentage, a file size, a field — so on a Mac whose region writes
/// Arabic-Indic digits, English Khayt wrote ١٢٣ and Arabic Khayt wrote 123.
/// Decided Oct 17 2026: Western by default in both, and "Use the Mac's number
/// format" (Settings ▸ On this Mac) for the Mac's own.
///
/// Every test pins the Mac's locale and the choice through `Digits.pinned`, a
/// task-local, so nothing here reads or writes this Mac's defaults and a suite
/// running beside it sees nothing change.
@MainActor
struct DigitsTests {

    static let when = Date(timeIntervalSince1970: 1_790_000_000)

    /// A Mac in Saudi Arabia, English, whose region writes Arabic-Indic digits
    /// — the Mac the bug was found on, but in English.
    nonisolated static let englishArabicIndicMac = Locale(identifier: "en_SA@numbers=arab")
    nonisolated static let arabicMac = Locale(identifier: "ar_SA")

    static func western(_ s: String) -> Bool {
        s.unicodeScalars.contains { ("0"..."9").contains($0) }
            && !s.unicodeScalars.contains { (0x0660...0x0669).contains($0.value) || (0x06F0...0x06F9).contains($0.value) }
    }
    static func arabicIndic(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0660...0x0669).contains($0.value) }
            && !s.unicodeScalars.contains { ("0"..."9").contains($0) }
    }

    static func words(_ language: String) async -> Words {
        let w = Words()
        await w.load(language, engine: nil)
        return w
    }

    /// Everything a person reads that the app formats itself, in one list.
    static func everything(_ words: Words) -> [String: String] {
        [
            "money": Money.text(1234.5, "USD"),
            "money, short": Money.short(98765, "USD"),
            "quantity": Money.quantity(559.1, decimals: 1),
            "date": words.say(when, Date.FormatStyle(date: .abbreviated, time: .shortened)),
            "count": words.counting(1234, "mac.labels_count"),
            "numeral": words.numeral(42),
            "figure": Figure(value: 4820, style: .plain).renderedText,
            "figure, money": Figure(value: 52691.57, style: .money(code: "USD")).renderedText,
            "percent": Figure(value: 0.48, style: .percent).renderedText,
            "file size": Format.bytes(12_345_678),
            "file count": Format.count(1234),
            "duration": KioskTime.spell(340, words.language),
            "month": MonthLabel.long("2026-08", language: words.language),
            "clock": Shop.clockText(when, words.locale),
        ]
    }

    @Test("by default every figure is 0–9, in English and Arabic, on an Arabic-Indic Mac",
          arguments: ["en", "ar"], [englishArabicIndicMac, arabicMac])
    func westernByDefault(language: String, mac: Locale) async {
        let words = await Self.words(language)
        Digits.$pinned.withValue(.init(followsMac: false, mac: mac)) {
            for (what, said) in Self.everything(words) {
                #expect(Self.western(said), "\(language) on \(mac.identifier): the \(what) reads \"\(said)\"")
            }
        }
    }

    @Test("with the setting on, figures follow the Mac's Arabic-Indic digits, in both languages",
          arguments: ["en", "ar"], [englishArabicIndicMac, arabicMac])
    func macDigitsWhenAsked(language: String, mac: Locale) async {
        let words = await Self.words(language)
        Digits.$pinned.withValue(.init(followsMac: true, mac: mac)) {
            for (what, said) in Self.everything(words) {
                #expect(Self.arabicIndic(said), "\(language) on \(mac.identifier): the \(what) reads \"\(said)\"")
            }
        }
    }

    @Test("with the setting on, a Mac that writes 0–9 gets 0–9 in Arabic too")
    func followsAWesternMac() async {
        let words = await Self.words("ar")
        Digits.$pinned.withValue(.init(followsMac: true, mac: Locale(identifier: "en_US"))) {
            for (what, said) in Self.everything(words) {
                #expect(Self.western(said), "the \(what) reads \"\(said)\"")
            }
        }
    }

    @Test("only the digits move: the language, region and calendar of the base are kept")
    func onlyTheDigitsMove() {
        let base = Locale(identifier: "ar_SA@calendar=gregorian")
        let western = Digits.locale(base, followsMac: false)
        #expect(western.numberingSystem.identifier == "latn")
        #expect(western.language.languageCode?.identifier == "ar")
        #expect(western.region?.identifier == "SA")
        #expect(western.calendar.identifier == .gregorian)
        Digits.$pinned.withValue(.init(followsMac: true, mac: Self.arabicMac)) {
            #expect(Digits.locale(language: "en").numberingSystem.identifier == "arab")
            #expect(Digits.locale(language: "en").language.languageCode?.identifier == "en")
        }
    }

    @Test("the setting is off on a Mac that never touched it")
    func offByDefault() {
        let fresh = UserDefaults(suiteName: "digits-tests-\(UUID().uuidString)")!
        #expect(Digits(defaults: fresh).followsMac == false)
        let mine = Digits(defaults: fresh)
        mine.followsMac = true
        #expect(fresh.bool(forKey: Digits.defaultsKey), "switching it on is remembered on this Mac")
        #expect(Digits(defaults: fresh).followsMac)
    }

    // MARK: - The widgets

    static func snapshot(macDigits: Bool?, language: String = "en") -> ShopWidgetSnapshot {
        ShopWidgetSnapshot(writtenAt: when, shopName: "Tuwaiq", language: language, rightToLeft: language == "ar",
                           words: [:], printing: [], machineCount: 1,
                           today: .init(dueToday: 2, overdue: 0, owed: nil), macDigits: macDigits)
    }

    @Test("the widget draws the digits the app was told to use, carried in the snapshot")
    func widgetHonoursTheSetting() throws {
        Digits.$pinned.withValue(.init(followsMac: false, mac: Self.arabicMac)) {
            for language in ["en", "ar"] {
                let off = KhaytWidgetView.locale(Self.snapshot(macDigits: false, language: language))
                #expect(off.numberingSystem.identifier == "latn")
                #expect(off.calendar.identifier == .gregorian, "the widget keeps the book's calendar")
                // A file from before the setting: Western, the default.
                #expect(KhaytWidgetView.locale(Self.snapshot(macDigits: nil, language: language))
                    .numberingSystem.identifier == "latn")
                let on = KhaytWidgetView.locale(Self.snapshot(macDigits: true, language: language))
                #expect(on.numberingSystem.identifier == "arab")
                #expect(on.language.languageCode?.identifier == language)
            }
        }
        // And it survives the file.
        let back = ShopWidgetSnapshot.decode(try Self.snapshot(macDigits: true).encoded())
        #expect(back?.macDigits == true)
    }

    @Test("the app writes the setting into the widget's snapshot")
    func feedWritesTheSetting() async {
        let shop = Shop()
        Digits.$pinned.withValue(.init(followsMac: true, mac: Self.arabicMac)) {
            #expect(WidgetFeed.compose(shop, now: Self.when).macDigits == true)
        }
        Digits.$pinned.withValue(.init(followsMac: false, mac: Self.arabicMac)) {
            #expect(WidgetFeed.compose(shop, now: Self.when).macDigits == false)
        }
    }

    // MARK: - The ratchet

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources")

    /// Places allowed to name the Mac's locale or build a formatter without
    /// one, each with its reason. Keyed `File.swift: text on the line`.
    static let allowed: [String: String] = [
        "Feedback.swift: locale: Locale.current.identifier":
            "a feedback report NAMES the Mac's locale for the developer; it formats nothing",
        "Feedback.swift: region: Locale.current.region":
            "the same report, naming the Mac's region",
    ]

    struct Hit: CustomStringConvertible {
        let file: String, line: Int, text: String, why: String
        var description: String { "\(file):\(line)  \(text.prefix(90))  — \(why)" }
    }

    /// Every displayed figure goes through `Digits` — so the next formatter
    /// written cannot quietly take the Mac's digits again.
    ///
    /// Data is excluded by shape: a formatter pinned to `en_US_POSIX` declares
    /// itself the book's, and `String(format:)` and interpolation write 0–9
    /// whatever the Mac says. SwiftUI's `Text(_, format:)`, `Text(_, style:)`
    /// and `TextField(value:format:)` take the window's locale, which
    /// `ShopsLocale` sets — the last test holds that half.
    @Test("nothing formats a figure in the Mac's locale behind Digits' back")
    func noBypasses() throws {
        var hits: [Hit] = []
        let dirs = ["KhaytApp", "KhaytWidgetViews", "KhaytWidgets"]
        for dir in dirs {
            let folder = Self.root.appending(path: dir)
            guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let name = url.lastPathComponent
                let lines = try String(contentsOf: url, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                for (i, raw) in lines.enumerated() {
                    let l = raw.trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("//") { continue }
                    let code = l.components(separatedBy: " //").first ?? l
                    let after = lines[i..<min(lines.count, i + 8)].joined(separator: "\n")
                    let near = lines[i..<min(lines.count, i + 3)].joined(separator: "\n")
                    func hit(_ why: String) {
                        if Self.allowed.keys.contains(where: { key in
                            let parts = key.components(separatedBy: ": ")
                            return parts[0] == name && code.contains(parts.dropFirst().joined(separator: ": "))
                        }) { return }
                        hits.append(Hit(file: name, line: i + 1, text: l, why: why))
                    }
                    if (code.contains("Locale.current") || code.contains("Locale.autoupdatingCurrent")
                        || (code.contains(".autoupdatingCurrent") && !code.contains("timeZone"))) {
                        hit("the Mac's locale, digits and all — use Digits.macLocale or words.locale")
                    }
                    if code.contains("Locale(identifier:"), !code.contains("Digits.locale("), !code.contains("en_US_POSIX") {
                        hit("a locale built outside Digits — wrap it in Digits.locale(…)")
                    }
                    if code.contains("NumberFormatter()") || (code.contains("DateFormatter()") && !code.contains("ISO8601DateFormatter()")) {
                        if !after.contains(".locale =") {
                            hit("a formatter left in the Mac's locale — give it Money.digits, words.locale or en_US_POSIX")
                        }
                    }
                    for loose in ["ByteCountFormatter", "DateComponentsFormatter", "RelativeDateTimeFormatter",
                                  "MeasurementFormatter", "DateIntervalFormatter", "ListFormatter",
                                  "NumberFormatter.localizedString", "DateFormatter.localizedString"]
                    where code.contains(loose) {
                        hit("\(loose) writes the Mac's digits — use a FormatStyle with .locale(…) (Format.fileSize)")
                    }
                    if code.contains(".formatted("), !code.contains(".iso8601"),
                       !near.contains(".locale(") && !near.contains("locale:") {
                        hit(".formatted without a locale takes the Mac's — add .locale(words.locale) or Money.digits")
                    }
                }
            }
        }
        #expect(hits.isEmpty, """
            these format something a person reads in the Mac's locale, so they \
            write the Mac's digits even with "Use the Mac's number format" off. \
            Route them through `Digits` (words.locale, Money.digits, \
            Digits.macLocale), or add them to `DigitsTests.allowed` with a reason.

            \(hits.map(\.description).joined(separator: "\n"))
            """)
    }

    @Test("every window and the menu bar panel wear the shop's locale")
    func everyWindowWearsIt() throws {
        let app = try String(contentsOf: Self.root.appending(path: "KhaytApp/KhaytApp.swift"), encoding: .utf8)
        for window in ["ShopWindow(shop: shop)", "SettingsWindow(shop: shop)",
                       "HelpWindow(shop: shop)", "KioskWindow(shop: shop)"] {
            let range = try #require(app.range(of: window), "\(window) is not in KhaytApp.swift")
            let next = app[range.upperBound...].prefix(80)
            #expect(next.contains(".modifier(ShopsLocale(words: shop.words))"),
                    "\(window) draws in the Mac's locale: its Text(format:) and fields take the Mac's digits")
        }
        let menu = try String(contentsOf: Self.root.appending(path: "KhaytApp/MenuBar.swift"), encoding: .utf8)
        for line in menu.split(separator: "\n") where line.contains("NSHostingController(rootView:") {
            #expect(line.contains("ShopsLocale"), "the menu bar panel draws in the Mac's locale")
        }
    }

    @Test("the setting is in Settings, in both languages")
    func theSettingIsThere() throws {
        for key in ["mac.mac_digits", "mac.mac_digits_note"] {
            #expect(Words.own[key]?["en"]?.isEmpty == false, "\(key) has no English")
            #expect(Words.own[key]?["ar"]?.isEmpty == false, "\(key) has no Arabic")
        }
        let settings = try String(contentsOf: Self.root.appending(path: "KhaytApp/SettingsWindow.swift"), encoding: .utf8)
        #expect(settings.contains("callIt(\"mac.mac_digits\")"))
        #expect(settings.contains("Digits.shared.followsMac = on"))
    }
}
