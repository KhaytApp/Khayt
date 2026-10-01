import Foundation
import Testing
@testable import KhaytCore

/// `RoundTrip.keepUntouched` — the stored spelling of whatever the edit did
/// not change.
struct RoundTripCoreTests {

    @Test("an untouched value goes back as the book spells it")
    func untouched() {
        let stored: [String: JSONValue] = ["w": .string("150"), "d": .string("2026-07-05T08:00:00.000Z"),
                                           "n": .null, "extra": .bool(true)]
        let baseline: [String: JSONValue] = ["w": .number(150), "d": .string("2026-07-05"), "n": .string("")]
        let out = RoundTrip.keepUntouched(written: baseline, baseline: baseline, stored: stored)
        #expect(out == stored)
    }

    @Test("an absent key the editor wrote as a default stays absent")
    func absentStaysAbsent() {
        let out = RoundTrip.keepUntouched(written: ["cr": .string("")], baseline: ["cr": .string("")],
                                          stored: [:])
        #expect(out.isEmpty)
    }

    @Test("an edited value is written, and its untouched neighbours are kept")
    func nested() {
        let stored: [String: JSONValue] = ["dep": .object(["price": .string("3000"),
                                                           "bought": .string("2026-01-15T00:00:00Z")])]
        let baseline: [String: JSONValue] = ["dep": .object(["price": .number(3000), "bought": .string("2026-01-15")])]
        let written: [String: JSONValue] = ["dep": .object(["price": .number(3500), "bought": .string("2026-01-15")])]
        let out = RoundTrip.keepUntouched(written: written, baseline: baseline, stored: stored)
        #expect(out == ["dep": .object(["price": .number(3500), "bought": .string("2026-01-15T00:00:00Z")])])
    }

    @Test("a row added to a list leaves the others as they were")
    func rows() {
        let stored: [String: JSONValue] = ["list": .array([.object(["p": .string("25"), "sku": .string("X")])])]
        let baseline: [String: JSONValue] = ["list": .array([.object(["p": .number(25)])])]
        let written: [String: JSONValue] = ["list": .array([.object(["p": .number(9)]), .object(["p": .number(25)])])]
        let out = RoundTrip.keepUntouched(written: written, baseline: baseline, stored: stored)
        #expect(out == ["list": .array([.object(["p": .number(9)]),
                                         .object(["p": .string("25"), "sku": .string("X")])])])
    }

    @Test("a key the edit removed stays removed; one both left out comes back")
    func removals() {
        let stored: [String: JSONValue] = ["a": .number(1), "b": .number(2)]
        let baseline: [String: JSONValue] = ["a": .number(1)]
        let out = RoundTrip.keepUntouched(written: [:], baseline: baseline, stored: stored)
        #expect(out == ["b": .number(2)])
    }
}

extension RoundTripCoreTests {
    @Test("filling gaps: a key the book lacks takes the rule's default; one it has keeps its spelling")
    func fillingGaps() {
        let stored: [String: JSONValue] = ["vatRate": .string("15")]
        let baseline: [String: JSONValue] = ["vatRate": .number(15), "firstRunDone": .bool(true)]
        let out = RoundTrip.keepUntouched(written: baseline, baseline: baseline, stored: stored, fillingGaps: true)
        #expect(out == ["vatRate": .string("15"), "firstRunDone": .bool(true)])
    }
}
