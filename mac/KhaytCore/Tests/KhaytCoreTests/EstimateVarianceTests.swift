import Foundation
import Testing
@testable import KhaytCore

/// What a model really costs, against what the shop quotes for it.
///
/// The unit is the MODEL and not the order, which is the whole reason this
/// exists: analytics can already average a time variance across a book, and
/// that average is not actionable — an order happened once, to one customer,
/// at a price already charged. "This bracket is quoted at 41 g and across four
/// prints it took 48 g" is a sentence that changes a price.
///
/// Three modules had to be bundled for it and none can answer alone, so these
/// prove the JOIN as much as the arithmetic: `order-file-link` allocating a
/// job's figures back to its parts, `printer-actuals` comparing one pair, and
/// `estimate-variance` taking the medians.
@Suite struct EstimateVarianceTests {

    /// A finished job with one part, whose figures a PRINTER reported.
    ///
    /// Both of those matter and neither implies the other. One part means
    /// nothing was divided to get here; measured means a machine said so rather
    /// than somebody confirming the estimate — and a typed actual would compare
    /// an estimate to itself.
    /// The shape `order-file-link.allocateActuals` reads, which is not the one
    /// guessing gives you: the ESTIMATE lives on the order's parts
    /// (`printTime`, `printWeight`), the ACTUAL lives on the order
    /// (`actualPrintTime`, `actualWeight`), and "a printer said so" is
    /// `actualsSource.{time,weight}` being anything other than `manual`.
    static func job(_ id: String, file: String, estG: Double, actG: Double,
                    estH: Double, actH: Double, date: String = "2026-09-01",
                    measured: Bool = true) -> JSONValue {
        .object([
            "id": .string(id),
            "project": .string("Shelf bracket"),
            "status": .string("completed"),
            "date": .string(date),
            "parts": .array([.object([
                "id": .string("p-" + id),
                "printFileId": .string(file),
                "partName": .string("Shelf bracket"),
                "qty": .number(1),
                "printTime": .number(estH),
                "printWeight": .number(estG),
            ])]),
            "actualPrintTime": .number(actH),
            "actualWeight": .number(actG),
            "actualsSource": .object([
                "time": .string(measured ? "printer" : "manual"),
                "weight": .string(measured ? "printer" : "manual"),
            ]),
        ])
    }

    @Test("a model quoted short is reported, worst first")
    func underQuotedIsFound() async throws {
        let engine = try KhaytEngine()
        let rows = try await engine.estimateVariance(orders: [
            // 41 g quoted, 48 g actual — 17% short, twice over.
            Self.job("j1", file: "f-bracket", estG: 41, actG: 48, estH: 3.2, actH: 3.8),
            Self.job("j2", file: "f-bracket", estG: 41, actG: 48, estH: 3.2, actH: 3.8),
        ], minSamples: 2)
        let bracket = try #require(rows.first { $0.printFileId == "f-bracket" },
                                   "the model with two measured prints was not reported")
        #expect(bracket.sampled == 2)
        #expect(bracket.estGrams == 41)
        #expect(bracket.actGrams == 48)
        let short = try #require(bracket.gramsDeltaPct)
        #expect(short > 16 && short < 18, "17% short read as \(short)%")
    }

    /// The sentence, and the fact that it is withheld.
    @Test("only a model that is consistently under-quoted earns a sentence")
    func adviceIsWithheld() async throws {
        let engine = try KhaytEngine()
        let bad = try await engine.estimateVariance(orders: [
            Self.job("j1", file: "f-bracket", estG: 41, actG: 48, estH: 3.2, actH: 3.8),
            Self.job("j2", file: "f-bracket", estG: 41, actG: 48, estH: 3.2, actH: 3.8),
        ], minSamples: 2)
        let said = try await engine.varianceAdvice(try #require(bad.first))
        let advice = try #require(said, "a model 17% under-quoted was not worth a sentence")
        #expect(advice.pct >= 17)
        #expect(advice.sampled == 2)

        // A shop that quotes generously is not a problem this reports. It finds
        // that out from its customers.
        let generous = try await engine.estimateVariance(orders: [
            Self.job("k1", file: "f-lid", estG: 50, actG: 44, estH: 4, actH: 3.5),
            Self.job("k2", file: "f-lid", estG: 50, actG: 44, estH: 4, actH: 3.5),
        ], minSamples: 2)
        #expect(try await engine.varianceAdvice(try #require(generous.first)) == nil,
                "over-quoting was reported as news")
    }

    /// A typed actual is usually the estimate confirmed, so counting it would
    /// compare an estimate to itself and report a variance near zero. That is
    /// the precise failure `printer-actuals.js` was written to end.
    @Test("a typed actual is not evidence about a model")
    func typedActualsAreIgnored() async throws {
        let engine = try KhaytEngine()
        let typed = Self.job("j1", file: "f-bracket", estG: 41, actG: 48,
                             estH: 3.2, actH: 3.8, measured: false)
        let rows = try await engine.estimateVariance(orders: [typed, typed], minSamples: 1)
        #expect(rows.isEmpty, "a figure somebody typed was counted as a measurement")
    }

    /// An empty answer is the common one for a young shop, and it must not be
    /// an error — the screen says why in words, and cannot if this throws.
    @Test("a book with nothing measured yet answers empty rather than failing")
    func nothingMeasured() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.estimateVariance(orders: []).isEmpty)
    }

    /// ── THE SAMPLE BOOK HAS TO REACH THIS SCREEN ─────────────────────────
    ///
    /// It did not. All 42 of its jobs had estimates and NOT ONE had an actual,
    /// so every measured-actuals feature in the app — this panel, printer
    /// accuracy, the estimator's calibration — drew nothing whatever book you
    /// opened it with, and a branch the sample cannot reach is a branch nobody
    /// has looked at.
    ///
    /// Eight finished jobs now carry them, and the SPREAD is the point rather
    /// than the figures: a model under-quoted twice over (Falcon hood, which
    /// earns a sentence), one quoted accurately twice (the lantern, which must
    /// NOT earn one), one badly out on time with a single print behind it, one
    /// a shop quotes generously, and two whose figures were typed rather than
    /// measured — which this panel is required to ignore.
    @Test("the sample shop can show this panel, with every case in it")
    func theSampleSpansTheCases() async throws {
        let engine = try KhaytEngine()
        // From the repo, not a bundle: the sample is a resource of KhaytApp and
        // these tests are KhaytCore's, so `Bundle.module` here is the wrong
        // bundle and answers nil rather than failing loudly.
        let sample = BundledLogicIsNotAForkTests.repoRoot
            .appending(path: "mac/KhaytCore/Sources/KhaytApp/Resources/sample-shop.json")
        let data = try Data(contentsOf: sample)
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let book) = root, case .array(let orders)? = book["printLog"] else {
            Issue.record("the sample book has no printLog"); return
        }
        let rows = try await engine.estimateVariance(orders: orders, minSamples: 1)
        #expect(rows.count == 4,
                "the sample shows \(rows.count) models: \(rows.map(\.name))")

        // The two typed jobs are absent, which is the filter working on real
        // data rather than on a fixture built to prove it.
        #expect(!rows.contains { $0.name.contains("Dental") || $0.name.contains("dallah") },
                "a typed actual reached the panel")

        let falcon = try #require(rows.first { $0.printFileId == "PF-sample-falcon" })
        #expect(falcon.sampled == 2)
        #expect(try #require(falcon.gramsDeltaPct) > 10, "the under-quoted model is not under-quoted")
        #expect(try await engine.varianceAdvice(falcon) != nil, "it earns a sentence and did not get one")

        let lantern = try #require(rows.first { $0.printFileId == "PF-sample-lantern" })
        #expect(abs(try #require(lantern.gramsDeltaPct)) < 5, "the accurate model is not accurate")
        #expect(try await engine.varianceAdvice(lantern) == nil,
                "a model quoted within a few per cent was reported as news")

        // Worst first. A panel sorted any other way buries the row it exists for.
        let worst = rows.map { max($0.gramsDeltaPct ?? 0, $0.hoursDeltaPct ?? 0) }
        #expect(worst == worst.sorted(by: >), "the rows are not worst-first: \(worst)")
    }
}
