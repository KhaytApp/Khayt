import Foundation
import Testing
@testable import KhaytApp

/// The kiosk spells a length of time with its units, because across a room,
/// under a clock, "18:04" is a time of day.
struct KioskTimeTests {

    @Test("hours and minutes carry their units, never a colon", arguments: [
        (9.0, "en", "9m"), (64, "en", "1h 4m"), (1084, "en", "18h 4m"), (120, "en", "2h"),
        (9, "ar", "9د"), (1084, "ar", "18س 4د"),
    ])
    func spelled(_ minutes: Double, _ language: String, _ expected: String) {
        let s = KioskTime.spell(minutes, language)
        #expect(s == expected)
        #expect(!s.contains(":"))
    }

    @Test("digits stay Latin in Arabic, as everywhere else in the app")
    func latinDigits() {
        #expect(KioskTime.spell(340, "ar").unicodeScalars.allSatisfy { !(0x0660...0x0669).contains($0.value) })
    }

    @Test("nothing the book can hold traps it")
    func hostileInput() {
        _ = KioskTime.spell(.nan, "en")
        _ = KioskTime.spell(.infinity, "en")
        #expect(KioskTime.spell(-5, "en") == "0m")
    }
}
