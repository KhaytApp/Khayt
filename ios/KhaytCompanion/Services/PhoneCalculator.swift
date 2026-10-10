import Foundation
import Observation
import KhaytCore

/// What should I charge for this? Answered on the phone.
///
/// ── WHY NOT THE MAC'S /api/quote ─────────────────────────────────────────
///
/// The first quote sheet (`QuoteSheet`) sent seven numbers to the Mac and
/// drew what came back, so it worked only within reach of the Mac, at
/// Khayt's opening rates, on whatever the shop typed for a spool's price. The
/// phone has carried the shop's book and the engine since the offline work:
/// its spools, printers, presets, consumables and settings. So this prices a
/// part exactly as the Mac's calculator does, with the same calls:
///
/// - the part is `CalculatorPart.input` (KhaytCore), which the Mac's
///   `CalculatorModel` builds through too;
/// - its cost is `lib/calculator-cost.js` through `KhaytEngine.costPart`, at
///   the rates `lib/print-rates.js` resolves for the preset and machine;
/// - its price is `lib/pricing.js` `quoteTotal`, given
///   `CalculatorPart.quoteInput`.
///
/// Not one line of arithmetic is written here. A figure typed into a rate is
/// sent as part of the part, where the shared rule already lets it win.
struct CalculatorShelf: Sendable, Equatable {
    struct Spool: Identifiable, Sendable, Equatable {
        var id: String { costing.id }
        let costing: CalculatorPart.Spool
        let label: String
        let hex: String?
        /// A spool with no price costs its filament at nothing; the screen says so.
        var hasPrice: Bool { (costing.cost ?? 0) > 0 }
    }

    struct Named: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
    }

    var spools: [Spool] = []
    var machines: [Named] = []
    var presets: [Named] = []
    var consumables: [CalculatorPart.ShelfItem] = []
    var currency: String?

    /// Read out of a book. Spools are the store's spelling (`spoolWeight`, or
    /// the wire's `weightTotal`); a row with no id is skipped.
    static func from(_ store: [String: JSONValue]) -> CalculatorShelf {
        func rows(_ key: String) -> [[String: JSONValue]] {
            guard case .array(let r)? = store[key] else { return [] }
            return r.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
        }
        func text(_ v: JSONValue?) -> String? {
            guard case .string(let s)? = v else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        func number(_ v: JSONValue?) -> Double? {
            switch v {
            case .number(let n)? where n.isFinite: return n
            case .string(let s)?: return Double(s).flatMap { $0.isFinite ? $0 : nil }
            default: return nil
            }
        }
        var shelf = CalculatorShelf()
        shelf.spools = rows("inventory").compactMap { o in
            guard let id = text(o["id"]) else { return nil }
            let material = text(o["material"]) ?? text(o["materialType"]) ?? ""
            let costing = CalculatorPart.Spool(id: id, material: material, cost: number(o["cost"]),
                                               spoolWeight: number(o["spoolWeight"]) ?? number(o["weightTotal"]),
                                               color: text(o["color"]))
            let label = [text(o["brand"]), material.isEmpty ? nil : material, text(o["colorName"])]
                .compactMap { $0 }.joined(separator: " ")
            return Spool(costing: costing, label: label.isEmpty ? id : label, hex: text(o["color"]))
        }
        shelf.machines = rows("machines").compactMap { o in
            text(o["id"]).map { Named(id: $0, name: text(o["name"]) ?? $0) }
        }
        shelf.presets = rows("printers").compactMap { o in
            text(o["id"]).map { Named(id: $0, name: text(o["name"]) ?? $0) }
        }
        shelf.consumables = rows("consumables").compactMap { o in
            text(o["id"]).map { CalculatorPart.ShelfItem(id: $0, name: text(o["name"]), cost: number(o["cost"])) }
        }
        if case .object(let s)? = store["settings"] { shelf.currency = text(s["currency"]) }
        return shelf
    }
}

/// One calculation, asked of the book.
struct CalculatorQuestion: Sendable, Equatable {
    var lines: [CalculatorPart.Line]
    var purge: Double
    var hours: Double
    var qty: Int
    var machineId: String?
    var presetId: String?
    /// Only the rates actually typed — see `PhoneCalculator.typedRates`.
    var rates: [String: Double]
    var pieces: [(id: String, qty: Double)]
    var margin: Double
    var discount: Double
    var rush: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.lines == b.lines && a.purge == b.purge && a.hours == b.hours && a.qty == b.qty
            && a.machineId == b.machineId && a.presetId == b.presetId && a.rates == b.rates
            && a.pieces.map(\.id) == b.pieces.map(\.id) && a.pieces.map(\.qty) == b.pieces.map(\.qty)
            && a.margin == b.margin && a.discount == b.discount && a.rush == b.rush
    }
}

struct CalculatorAnswer: Sendable, Equatable {
    /// One piece's cost, its split, and the rates it was costed at.
    let costed: KhaytEngine.CostedPart
    let quoted: QuoteTotal
    let qty: Int

    /// What the whole order costs the shop to make.
    var cost: Double { costed.cost * Double(qty) }
    /// What the customer pays for each piece.
    var perPiece: Double { quoted.total / Double(max(1, qty)) }
}

extension BookReader {

    /// What the calculator can choose from.
    func calculatorShelf() throws -> CalculatorShelf { CalculatorShelf.from(try wholeBook()) }

    /// What a part WOULD be costed at for this preset and machine, before
    /// anything is typed over it — `lib/print-rates.js`, never restated here.
    func calculatorRates(machineId: String?, presetId: String?) async throws -> [String: Double] {
        let store = try wholeBook()
        return try await sharedEngine().printRates(machine: Self.row(store, "machines", machineId),
                                                   preset: Self.row(store, "printers", presetId),
                                                   settings: Self.settings(store))
    }

    func calculate(_ q: CalculatorQuestion) async throws -> CalculatorAnswer {
        let store = try wholeBook()
        let shelf = CalculatorShelf.from(store)
        let settings = Self.settings(store)
        let pieces = CalculatorPart.consumableRows(q.pieces, shelf: shelf.consumables)
        let part = CalculatorPart.input(lines: q.lines, purge: q.purge, hours: q.hours, qty: q.qty,
                                        pieces: pieces, extra: q.rates.mapValues { .number($0) })
        func list(_ key: String) -> [JSONValue] {
            if case .array(let r)? = store[key] { return r }
            return []
        }
        let engine = try sharedEngine()
        let costed = try await engine.costPart(part, inventory: list("inventory"), settings: settings,
                                               machine: Self.row(store, "machines", q.machineId),
                                               preset: Self.row(store, "printers", q.presetId),
                                               consumables: list("consumables"))
        let qty = max(1, q.qty)
        let quoted = try await engine.quoteTotal(CalculatorPart.quoteInput(
            baseCost: costed.cost * Double(qty), margin: q.margin, discountPct: q.discount,
            rush: q.rush, settings: settings))
        return CalculatorAnswer(costed: costed, quoted: quoted, qty: qty)
    }

    private static func settings(_ store: [String: JSONValue]) -> [String: JSONValue] {
        if case .object(let s)? = store["settings"] { return s }
        return [:]
    }

    private static func row(_ store: [String: JSONValue], _ key: String, _ id: String?) -> JSONValue? {
        guard let id, !id.isEmpty, case .array(let rows)? = store[key] else { return nil }
        return rows.first { if case .object(let o) = $0 { return o["id"] == .string(id) } else { return false } }
    }
}

/// Everything the calculator screen holds, and the one call that prices it.
/// Held apart from the view so a test can move each input and watch the
/// total move — the lesson of the Mac's `CalculatorModel`, whose tester
/// reported a total that "doesn't change no matter how I adjust the costs".
@MainActor @Observable
final class PhoneCalculator {

    struct FilamentLine: Identifiable, Equatable {
        let id = UUID()
        var spoolId: String?
        var grams = ""
    }

    struct PieceLine: Identifiable, Equatable {
        let id = UUID()
        var consumableId: String?
        var qty = 1
    }

    static let rateKeys = ["laborRate", "prepTime", "postTime", "wearRate", "powerDraw", "elecRate", "failureRate"]

    var shelf = CalculatorShelf()
    /// Never empty: the first line is the screen's Weight and Filament.
    var lines = [FilamentLine()]
    var purge = ""
    var hours = ""
    var qty = 1
    var machineId: String?
    var presetId: String?
    /// The seven rates as typed; empty means "what the preset and machine say".
    var rates: [String: String] = [:]
    /// What the preset and machine resolve to.
    private(set) var resolved: [String: Double] = [:]
    var margin = 30.0
    var discount = 0.0
    var rush = false
    var pieces: [PieceLine] = []

    private(set) var answer: CalculatorAnswer?
    private(set) var problem: String?

    init() {}

    // MARK: Reading what was typed

    /// A typed figure: Arabic-Indic digits and a comma decimal read too, since
    /// a phone's keyboard can type either.
    static func number(_ text: String) -> Double {
        var said = ""
        for ch in text.trimmingCharacters(in: .whitespaces) {
            if let d = ch.wholeNumberValue, ch.isNumber { said.append(String(d)) }
            else if ch == "," || ch == "٫" { said.append(".") }
            else { said.append(ch) }
        }
        guard let n = Double(said), n.isFinite else { return 0 }
        return max(0, n)
    }

    var gramsValue: Double { lines.reduce(0) { $0 + Self.number($1.grams) } }
    var hasInput: Bool {
        gramsValue > 0 || Self.number(hours) > 0 || pieces.contains { $0.consumableId != nil }
    }

    /// A spool picked on a line with no price: its filament costs nothing.
    var unpricedSpool: Bool {
        lines.contains { line in
            guard Self.number(line.grams) > 0, let id = line.spoolId else { return false }
            return shelf.spools.first { $0.id == id }?.hasPrice == false
        }
    }

    /// Only the figures actually typed travel with the part, so an untouched
    /// rate keeps following the preset and machine.
    var typedRates: [String: Double] {
        var out: [String: Double] = [:]
        for key in Self.rateKeys {
            let said = (rates[key] ?? "").trimmingCharacters(in: .whitespaces)
            if !said.isEmpty { out[key] = Self.number(said) }
        }
        return out
    }

    var ratesEdited: Bool {
        typedRates.contains { key, value in abs(value - (resolved[key] ?? 0)) > 0.0001 }
    }

    func resetRates() { rates = [:] }

    var question: CalculatorQuestion {
        CalculatorQuestion(
            lines: lines.map { line in
                CalculatorPart.Line(spool: line.spoolId.flatMap { id in shelf.spools.first { $0.id == id }?.costing },
                                    grams: Self.number(line.grams))
            },
            purge: Self.number(purge), hours: Self.number(hours), qty: max(1, qty),
            machineId: machineId, presetId: presetId, rates: typedRates,
            pieces: pieces.compactMap { p in p.consumableId.map { (id: $0, qty: Double(p.qty)) } },
            margin: margin, discount: discount, rush: rush)
    }

    // MARK: Lines

    /// A second colour SPLITS what was typed as the print's weight, so the
    /// slicer's total typed first is not charged twice (the Mac's rule).
    func addColour() {
        let used = Set(lines.compactMap(\.spoolId))
        var line = FilamentLine(spoolId: shelf.spools.first { !used.contains($0.id) }?.id ?? shelf.spools.first?.id)
        if lines.count == 1 {
            let typed = Self.number(lines[0].grams)
            if typed > 0 {
                let half = (typed / 2 * 100).rounded() / 100
                lines[0].grams = Self.figure(typed - half)
                line.grams = Self.figure(half)
            }
        }
        lines.append(line)
    }

    func removeColour(_ id: FilamentLine.ID) {
        guard lines.count > 1 else { return }
        lines.removeAll { $0.id == id }
    }

    func addPiece() {
        let used = Set(pieces.compactMap(\.consumableId))
        pieces.append(PieceLine(consumableId: shelf.consumables.first { !used.contains($0.id) }?.id
                                    ?? shelf.consumables.first?.id))
    }

    func removePiece(_ id: PieceLine.ID) { pieces.removeAll { $0.id == id } }

    static func figure(_ n: Double) -> String {
        n == n.rounded() && abs(n) < 1e12 ? String(Int(n)) : String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), n)
    }

    // MARK: The answer

    /// Load what can be chosen from, and start the first line on a real spool —
    /// without one there is no cost per gram.
    func load(_ reader: BookReader) async {
        shelf = (try? await reader.calculatorShelf()) ?? CalculatorShelf()
        if lines.count == 1, lines[0].spoolId == nil {
            lines[0].spoolId = shelf.spools.first { $0.hasPrice }?.id ?? shelf.spools.first?.id
        }
        if presetId == nil, shelf.presets.count == 1 { presetId = shelf.presets[0].id }
        await resolveRates(reader)
    }

    func resolveRates(_ reader: BookReader) async {
        resolved = (try? await reader.calculatorRates(machineId: machineId, presetId: presetId)) ?? [:]
    }

    func recompute(_ reader: BookReader) async {
        guard hasInput else { answer = nil; problem = nil; return }
        do {
            answer = try await reader.calculate(question)
            problem = nil
        } catch {
            answer = nil
            problem = error.localizedDescription
        }
    }

    /// The quote, as a message the shop can send — what a customer asked for.
    func quoteText(currency: String?) -> String? {
        guard let a = answer else { return nil }
        var lines = [L10n.format("calc.share.price", Money.text(a.quoted.total, currency))]
        if a.qty > 1 {
            lines.append(L10n.format("calc.share.each", a.qty, Money.text(a.perPiece, currency)))
        }
        if a.quoted.rushFee > 0 { lines.append(L10n.tr("calc.share.rush")) }
        return lines.joined(separator: "\n")
    }
}
