import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "Printed N times" on a library tile, in Arabic, by the number rule:
/// once «طُبع مرة» with no numeral, twice the dual, 3–10 the plural, 11 and
/// up the singular. The KING Salman tile read «1 طُبع مرة» — the count said
/// twice (Oct 2026 capture).
@MainActor
struct PrintedCountArabicTests {

    @Test("printed once, twice, a few times and many, in Arabic")
    func arabicForms() async throws {
        let words = Words()
        await words.load("ar", engine: try KhaytEngine())
        #expect(words.counting(1, "mac.printed_n") == "طُبع مرة")
        #expect(words.counting(2, "mac.printed_n") == "طُبع مرتين")
        #expect(words.counting(3, "mac.printed_n") == "طُبع 3 مرات")
        #expect(words.counting(10, "mac.printed_n") == "طُبع 10 مرات")
        #expect(words.counting(11, "mac.printed_n") == "طُبع 11 مرة")
        #expect(words.counting(25, "mac.printed_n") == "طُبع 25 مرة")
        #expect(words.counting(103, "mac.printed_n") == "طُبع 103 مرات")
    }

    @Test("English keeps its numeral")
    func english() async throws {
        let words = Words()
        await words.load("en", engine: try KhaytEngine())
        #expect(words.counting(1, "mac.printed_n") == "printed 1×")
        #expect(words.counting(12, "mac.printed_n") == "printed 12×")
    }
}
