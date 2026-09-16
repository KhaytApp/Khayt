import Foundation
import Testing
@testable import KhaytCore

/// Pricing a stranger's uploaded model, through the shared rule.
///
/// ── WHY THIS TEST EXISTS AT ALL ───────────────────────────────────────────
///
/// The binding wires four dependencies by their GLOBAL NAMES —
/// `KhaytStl.estimateFromStl`, `KhaytEstimateCalibration.applyCalibration`
/// and two more — and JavaScriptCore does not complain about a name that is
/// not there until the line runs. Three of the four were typed from memory
/// and two of those were wrong (`KhaytStlEstimate`, `KhaytCalibration`).
/// Nothing in a build catches that. This does: it asks for a real price and
/// checks a real number comes back.
struct PublicQuoteBindingTests {

    /// A shop that has switched public pricing on and said what to charge.
    ///
    /// A PRINTER PRESET IS NOT OPTIONAL: the rule builds the customer's price
    /// from a real preset the shop chose, and refuses with `missing: printer`
    /// without one. Those presets are `store.printers`, written by the other
    /// app's calculator — so a Mac shop with none cannot quote publicly yet,
    /// which the Online pane has to say rather than fail quietly.
    static func store(enabled: Bool = true, preset: Bool = true) -> JSONValue {
        .object([
            "settings": .object([
                "currency": .string("SAR"),
                "lanApi": .object(["intakeQuote": .object([
                    "enabled": .bool(enabled),
                    "presetId": .string(preset ? "PRESET-1" : ""),
                    "spoolCost": .number(75), "spoolWeight": .number(1000),
                    "marginPct": .number(30), "minPrice": .number(0), "wastePct": .number(0.05),
                ])]),
            ]),
            "printers": .array(preset ? [.object([
                "id": .string("PRESET-1"), "name": .string("U1"),
                "wearRate": .number(0.75), "powerDraw": .number(150), "elecRate": .number(0.18),
                "laborRate": .number(90), "failureRate": .number(10),
                "prepTime": .number(0.1), "postTime": .number(0.1),
            ])] : []),
            "printLog": .array([]),
        ])
    }

    /// A cube 50mm on a side, as this app's own mesh reader measures one.
    static let cube: JSONValue = .object([
        "source": .string("geometry"),
        "geometry": .object([
            "volumeMm3": .number(125_000), "areaMm2": .number(15_000),
            "triangleCount": .number(12),
            "bbox": .object(["x": .number(50), "y": .number(50), "z": .number(50)]),
        ]),
    ])

    @Test("a measured mesh comes back with a price, so every wired dependency resolved")
    func geometryIsPriced() async throws {
        let engine = try KhaytEngine()
        let quote = try await engine.publicQuote(intake: Self.cube, store: Self.store(), qty: 1)
        guard case .object(let q) = quote else { Issue.record("not an object"); return }
        #expect(q["ok"] == .bool(true), Comment(rawValue: "\(q)"))
        guard case .number(let price)? = q["price"] else { Issue.record("no price: \(q)"); return }
        #expect(price > 0, Comment(rawValue: "priced at \(price)"))
        guard case .number(let grams)? = q["grams"], case .number(let hours)? = q["hours"] else {
            Issue.record("no weight or time: \(q)"); return
        }
        #expect(grams > 0 && hours > 0)
        #expect(q["currency"] == .string("SAR"))
        // Never a promise, whatever the number.
        #expect(q["binding"] == .bool(false))
    }

    @Test("a sliced file is taken at its own figures rather than estimated")
    func slicedIsExact() async throws {
        let engine = try KhaytEngine()
        let sliced: JSONValue = .object([
            "exact": .bool(true), "printTimeMins": .number(272), "filamentGrams": .number(140.91),
            "slicer": .string("SnapmakerOrca"),
        ])
        let quote = try await engine.publicQuote(intake: sliced, store: Self.store(), qty: 2)
        guard case .object(let q) = quote else { Issue.record("not an object"); return }
        #expect(q["ok"] == .bool(true), Comment(rawValue: "\(q)"))
        #expect(q["exact"] == .bool(true))
        #expect(q["qty"] == .number(2))
    }

    @Test("the reluctant answers are the rule's own, not a Swift guess")
    func refusals() async throws {
        let engine = try KhaytEngine()
        // Off unless the shop turned it on.
        let off = try await engine.publicQuote(intake: Self.cube, store: Self.store(enabled: false), qty: 1)
        guard case .object(let o) = off else { Issue.record("not an object"); return }
        #expect(o["ok"] == .bool(false))
        #expect(o["reason"] == .string("off"))
        // A shop that never chose a printer preset cannot quote a stranger.
        let noPreset = try await engine.publicQuote(intake: Self.cube, store: Self.store(preset: false), qty: 1)
        guard case .object(let n) = noPreset else { Issue.record("not an object"); return }
        #expect(n["reason"] == .string("not-configured"))
        #expect(n["missing"] == .string("printer"), Comment(rawValue: "\(n)"))
        // A file that produced no usable numbers.
        let empty = try await engine.publicQuote(intake: .object([:]), store: Self.store(), qty: 1)
        guard case .object(let e) = empty else { Issue.record("not an object"); return }
        #expect(e["ok"] == .bool(false))
        #expect(e["reason"] == .string("no-numbers"), Comment(rawValue: "\(e)"))
    }
}
