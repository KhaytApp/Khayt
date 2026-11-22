import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A date a person reads is in the SHOP's language. A date the book holds is
/// not in any language at all.
///
/// ── WHAT WENT WRONG ───────────────────────────────────────────────────────
///
/// `Date.formatted` takes the system locale when it is not given one, and the
/// system locale is the Mac's rather than the book's. So a shop running Khayt
/// in Arabic — which is most of the reason this app is bilingual — read its
/// front door as "Tuesday, 22 September 2026 at 2:45 PM" under an Arabic
/// heading, and the money masthead said "SEPTEMBER · صافي". Twenty-two places
/// did it.
///
/// It survives every test and every review: the strings are correct, they are
/// simply in somebody else's language, and the one Mac this was built on keeps
/// its system in English. It was found by photographing the app in Arabic.
///
/// TWO of those places carried a comment saying they already did this —
/// "where the locale is known, and where Arabic gets Arabic month names rather
/// than a transliteration", and "the time of day, in the shop's own locale".
/// Both described the intent and not the code, which is the hardest kind of
/// comment to disbelieve.
///
/// ── AND THE HALF THAT MUST NOT BE SWEPT ───────────────────────────────────
///
/// The book's own dates are DATA. `2026-09-22`, the ISO stamps, the backup
/// filenames — `Order.swift` pins those to `en_US_POSIX` on purpose, because a
/// stored date that formats itself in Arabic-Indic digits is a stored date
/// nothing can read back. Sweeping those would corrupt every shop's book, so
/// this suite holds both halves: the displayed ones follow the shop, and the
/// stored ones must not.
@MainActor
struct DatesReadInTheShopsLanguageTests {

    static let when = Date(timeIntervalSince1970: 1_790_000_000)

    static func words(_ language: String) async throws -> Words {
        let w = Words()
        await w.load(language, engine: try KhaytEngine())
        return w
    }

    // MARK: - What a person reads

    @Test("a displayed date follows the shop, not the Mac")
    func displayedDatesFollowTheShop() async throws {
        let english = try await Self.words("en")
        let arabic = try await Self.words("ar")
        let style = Date.FormatStyle(date: .complete, time: .shortened)
        let inEnglish = english.say(Self.when, style)
        let inArabic = arabic.say(Self.when, style)
        #expect(inEnglish != inArabic, """
            the front door's date reads the same in both languages — \
            "\(inEnglish)" — so it is following this Mac rather than the book
            """)
        // Arabic names the month in Arabic script; English does not.
        #expect(inArabic.contains(where: { $0.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } }),
                "the Arabic date has no Arabic in it: \(inArabic)")
        #expect(!inEnglish.contains(where: { $0.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } }))
    }

    @Test("the month on the money masthead is the shop's word for it")
    func theMastheadMonthIsTranslated() async throws {
        let english = try await Self.words("en")
        let arabic = try await Self.words("ar")
        let style = Date.FormatStyle.dateTime.month(.wide)
        #expect(english.say(Self.when, style) != arabic.say(Self.when, style), """
            "SEPTEMBER · صافي" — an English month under an Arabic label
            """)
    }

    /// THE RATCHET. Every DISPLAYED date in the app goes through `Words.say`,
    /// so the next one written cannot quietly take the Mac's locale.
    ///
    /// Storage is excluded by shape rather than by filename: a formatter that
    /// pins `en_US_POSIX` or sets an explicit `dateFormat` is declaring itself
    /// data, and an ISO formatter has no locale to take.
    @Test("no screen formats a date without asking the shop")
    func nothingFormatsWithoutAsking() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        var loose: [String] = []
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where url.pathExtension == "swift" {
            // `Words.swift` defines `say`; `MachineBand` and `Throughput` draw
            // AXIS LABELS, where digits read the same in every language and
            // `en_US_POSIX` is the deliberate answer they each argue for.
            let name = url.lastPathComponent
            if ["Words.swift", "MachineBand.swift", "Throughput.swift"].contains(name) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = line.trimmingCharacters(in: .whitespaces)
                guard l.range(of: #"\.formatted\(\s*(date:|\.dateTime)"#,
                              options: .regularExpression) != nil
                        || l.range(of: #"Text\([^,]+,\s*format:\s*\.dateTime"#,
                                   options: .regularExpression) != nil else { continue }
                if l.contains(".locale(") || l.contains("en_US_POSIX") { continue }
                loose.append("\(name):\(i + 1)  \(l.prefix(76))")
            }
        }
        #expect(loose.isEmpty, """
            these format a date a person reads without giving it a locale, so \
            they take the Mac's language rather than the shop's. Use \
            `words.say(date, style)`.

            \(loose.joined(separator: "\n"))
            """)
    }

    // MARK: - What the book holds

    /// The other half, and the one that would do damage. A stored date must be
    /// the same bytes on every Mac in every language.
    @Test("a stored date is not in anybody's language")
    func storedDatesAreData() {
        let day = DateFormatter.shopDay.string(from: Self.when)
        #expect(day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                "the book's own date format moved: \(day)")
        #expect(DateFormatter.shopDay.locale?.identifier == "en_US_POSIX", """
            the stored-date formatter lost its POSIX locale — on an Arabic Mac \
            it will write Arabic-Indic digits into the book and nothing will \
            read them back
            """)
    }
}
