import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Arabic counts two of a thing differently, and this app did not.
///
/// Arabic has a DUAL — not a plural of two, a form of its own — and the numeral
/// is not said with it. "Two days" is `يومين`; what this app wrote was
/// `2 أيام`, which reads to an Arabic speaker roughly the way "2 dayses" reads
/// in English. It appeared wherever a count met a noun: the shelf's "empty in 2
/// days", a customer with two jobs, two spools, two printers.
///
/// The mechanism is opt-in per key: a word without a `_two` behaves exactly as
/// it did. That is deliberate — the forms below are a judgement call in a
/// language the person who wrote them does not speak natively, and they should
/// be correctable one at a time without touching the rule.
@MainActor
struct ArabicDualTests {

    static func words(_ lang: String) async throws -> Words {
        let w = Words()
        await w.load(lang, engine: try KhaytEngine())
        return w
    }

    @Test("two days is the dual, and does not carry the numeral")
    func theDual() async throws {
        let ar = try await Self.words("ar")
        #expect(ar.counting(2, "mac.days_word") == "يومين",
                "two days read as “\(ar.counting(2, "mac.days_word"))”")
        // The form already says "two"; writing the numeral says it twice.
        #expect(!ar.counting(2, "mac.days_word").contains("2"))
    }

    @Test("one and many are unchanged, and still carry the numeral")
    func theRest() async throws {
        let ar = try await Self.words("ar")
        #expect(ar.counting(1, "mac.days_word") == "1 يوم")
        #expect(ar.counting(3, "mac.days_word") == "3 أيام")
        #expect(ar.counting(37, "mac.days_word") == "37 أيام")
    }

    @Test("English is untouched, including at two")
    func englishUnchanged() async throws {
        let en = try await Self.words("en")
        #expect(en.counting(1, "mac.days_word") == "1 day")
        #expect(en.counting(2, "mac.days_word") == "2 days")
        #expect(en.counting(9, "mac.days_word") == "9 days")
        #expect(en.counting(2, "mac.jobs_word") == "2 jobs")
    }

    /// A word with no dual must behave exactly as it did, or this change is a
    /// silent rewrite of strings nobody has looked at.
    @Test("a word without a dual is left alone")
    func optIn() async throws {
        let ar = try await Self.words("ar")
        // `printing_count` is a verb phrase, not a counted noun — it has no
        // dual on purpose.
        #expect(ar.counting(2, "mac.printing_count").hasPrefix("2 "))
    }

    /// Every dual that exists must be a real word, and must not be the plural
    /// wearing a different key — a `_two` equal to the plural is a copy-paste
    /// that would read as wrong Arabic while looking done.
    @Test("every dual differs from its own plural and singular")
    func theyAreRealForms() async throws {
        let ar = try await Self.words("ar")
        for key in ["mac.days_word", "mac.jobs_word", "mac.spools_count",
                    "mac.machines_count", "mac.models_count",
                    "mac.customers_count", "mac.labels_count"] {
            let dual = ar.counting(2, key)
            #expect(!dual.hasPrefix("2 "), "\(key) has no dual and this list says it should")
            #expect(dual != ar.callIt(key), "\(key)'s dual is just its plural")
            #expect(dual != ar.callIt(key + "_one"), "\(key)'s dual is just its singular")
        }
    }
}
