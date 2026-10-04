import Foundation
import Observation
import SwiftUI
import KhaytCore

/// Everything the calculator screen is holding, and the one call that turns it
/// into a price.
///
/// ── WHY THIS LEFT THE VIEW ────────────────────────────────────────────────
///
/// A tester reported "a base project total that doesn't change no matter how I
/// adjust the costs such as labor, print time, or filament". Whether THIS
/// screen does that could only be argued from reading a View body: nothing
/// could type a labour rate into it and look at the total. So the state and
/// the recompute live here, the screen binds to them, and
/// `CalculatorModelTests` moves every input and watches the total move — the
/// same object, the same `Shop` calls, the same JavaScript.
///
/// ── SEVERAL FILAMENTS, ONE PART ───────────────────────────────────────────
///
/// A multicolour print is one part made of several spools. The shared cost
/// model already prices that shape — `part.colours` with a pre-summed
/// `spoolCost`/`spoolWeight` (`lib/calculator-cost.js`, written for the other
/// app's colour planner) — and `lib/order-deduction.js` already draws each
/// colour's grams off its own spool. This screen only had room for one spool.
///
/// Purge (flush and prime tower) is shared across the colours by weight, so
/// its cost is the blended price per gram and each spool is charged its share.
///
/// ── CONSUMABLES ───────────────────────────────────────────────────────────
///
/// Magnets, inserts, screws: `part.consumables`, `[{consumableId, qty,
/// unitCost}]` per printed piece, costed by `calculator-cost` and drawn off
/// the shelf by `order-deduction` when a job carrying them completes.
@MainActor @Observable
final class CalculatorModel {

    struct FilamentLine: Identifiable, Equatable {
        let id = UUID()
        var spoolId: String?
        var grams = ""
        /// The colour the model asked for, when the line came from a file.
        var hex: String?
    }

    struct ConsumableLine: Identifiable, Equatable {
        let id = UUID()
        var consumableId: String?
        var qty: Double = 1
    }

    /// Never empty: the first line is the screen's own Weight and Filament.
    var lines: [FilamentLine]
    var purge = ""
    var hours: String
    var qty = 1
    var machineId: String?
    var presetId: String?
    /// The seven rate figures, as typed. See `Calculator.ratesSection`.
    var rates: [String: String] = [:]
    /// What the preset and machine resolve to, for seeding and for Reset.
    var resolved: [String: Double] = [:]
    var margin = 30.0
    var discount = 0.0
    var rush = false
    var consumableLines: [ConsumableLine] = []
    /// The library model the figures were filled from, if any.
    var modelId: String?

    private(set) var costed: KhaytEngine.CostedPart?
    private(set) var quoted: QuoteTotal?

    init(grams: String = "", hours: String = "") {
        lines = [FilamentLine(grams: grams)]
        self.hours = hours
    }

    /// The runner's filled-in calculator. `KHAYT_SNAPSHOT_PART` and `_HOURS`
    /// as before; `KHAYT_SNAPSHOT_MULTI=1` adds a second colour and a
    /// consumable so the picture shows the whole screen.
    static func fromEnvironment() -> CalculatorModel {
        let env = ProcessInfo.processInfo.environment
        return CalculatorModel(grams: env["KHAYT_SNAPSHOT_PART"] ?? "",
                               hours: env["KHAYT_SNAPSHOT_HOURS"] ?? "")
    }

    // MARK: - Reading what was typed

    static func number(_ text: String) -> Double {
        let said = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return max(0, Double(said) ?? 0)
    }

    var hoursValue: Double { Self.number(hours) }
    var purgeValue: Double { Self.number(purge) }
    var gramsValue: Double { lines.reduce(0) { $0 + Self.number($1.grams) } }
    var isMulticolour: Bool { lines.filter { Self.number($0.grams) > 0 }.count > 1 }

    var hasInput: Bool {
        gramsValue > 0 || hoursValue > 0
            || consumableLines.contains { $0.consumableId != nil && $0.qty > 0 }
    }

    /// One typed rate, or what the preset and machine resolved to.
    func typed(_ key: String) -> Double {
        let said = (rates[key] ?? "").replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        if said.isEmpty { return resolved[key] ?? 0 }
        return max(0, Double(said) ?? 0)
    }

    var ratesEdited: Bool {
        Shop.Preset.rateKeys.contains { abs(typed($0) - (resolved[$0] ?? 0)) > 0.0001 }
    }

    func seedRates() {
        var out: [String: String] = [:]
        for (key, value) in resolved {
            // `Int(_:)` traps on NaN, infinity and anything past Int.max — and
            // a preset is a row in the book another app or a hand edit wrote.
            guard value.isFinite else { continue }
            out[key] = value == value.rounded() && abs(value) < 1e15
                ? String(Int(saturating: value)) : String(value)
        }
        rates = out
    }

    /// Everything the answer depends on, in one value, so the screen's
    /// `.task(id:)` re-runs `recompute` whenever any of it moves.
    var key: String {
        let typedRates = Shop.Preset.rateKeys.map { "\($0):\(rates[$0] ?? "")" }.joined(separator: ",")
        let filament = lines.map { "\($0.spoolId ?? "")=\($0.grams)" }.joined(separator: ";")
        let pieces = consumableLines.map { "\($0.consumableId ?? "")*\($0.qty)" }.joined(separator: ";")
        return "\(filament)|\(purge)|\(hours)|\(qty)|\(machineId ?? "")|\(presetId ?? "")|"
             + "\(margin)|\(discount)|\(rush)|\(typedRates)|\(pieces)"
    }

    // MARK: - Lines

    /// Add a colour.
    ///
    /// ── A TOTAL TYPED FIRST IS NOT CHARGED TWICE ─────────────────────────
    ///
    /// With one line the field is the print's WEIGHT, and a shop types the
    /// slicer's total into it. Adding a second colour used to leave that
    /// total on colour 1 and open colour 2 empty — so the colour-2 grams the
    /// shop then typed were charged ON TOP of a total that already held them.
    /// The first colour added SPLITS what was typed between the two lines, so
    /// the total does not move until the shop says how it divides; the note
    /// under the lines says so (`splitFrom`).
    func addFilament(spools: [Spool]) {
        // The next spool not already on a line, so a second colour does not
        // open on the first colour's spool.
        let used = Set(lines.compactMap(\.spoolId))
        var line = FilamentLine(spoolId: spools.first { !used.contains($0.id) }?.id ?? spools.first?.id)
        if lines.count == 1, let typed = lines.first.map({ Self.number($0.grams) }), typed > 0 {
            let half = (typed / 2 * 100).rounded() / 100
            lines[0].grams = Self.figure(typed - half)
            line.grams = Self.figure(half)
            splitFrom = typed
        }
        lines.append(line)
    }

    /// The total a colour added was split from, so the screen can say the
    /// grams were divided rather than added. Cleared once a line is typed in.
    var splitFrom: Double?

    func removeFilament(_ id: FilamentLine.ID) {
        guard lines.count > 1 else { return }
        lines.removeAll { $0.id == id }
        if lines.count == 1 { splitFrom = nil }
    }

    func addConsumable(_ consumables: [Consumable]) {
        let used = Set(consumableLines.compactMap(\.consumableId))
        consumableLines.append(ConsumableLine(
            consumableId: consumables.first { !used.contains($0.id) }?.id ?? consumables.first?.id))
    }

    func removeConsumable(_ id: ConsumableLine.ID) {
        consumableLines.removeAll { $0.id == id }
    }

    static func figure(_ grams: Double) -> String {
        Words.plain(.number((grams * 100).rounded() / 100))
    }

    // MARK: - Bindings by id

    /// ── BY ID, NEVER BY POSITION ─────────────────────────────────────────
    ///
    /// The lines were bound as `$model.lines[index]` from an enumerated
    /// `ForEach`. Removing a line, or `fill` replacing three colours with
    /// one, left SwiftUI holding a binding to an index that no longer
    /// existed, and the next read trapped: index out of range. A binding
    /// here finds its line by id each time; a line that has gone reads as
    /// empty and a write to it is dropped.
    func gramsBinding(_ id: FilamentLine.ID) -> Binding<String> {
        Binding(get: { [weak self] in self?.lines.first { $0.id == id }?.grams ?? "" },
                set: { [weak self] value in
                    guard let self, let i = self.lines.firstIndex(where: { $0.id == id }) else { return }
                    self.lines[i].grams = value
                    self.splitFrom = nil
                })
    }

    func spoolBinding(_ id: FilamentLine.ID) -> Binding<String?> {
        Binding(get: { [weak self] in self?.lines.first { $0.id == id }?.spoolId },
                set: { [weak self] value in
                    guard let self, let i = self.lines.firstIndex(where: { $0.id == id }) else { return }
                    self.lines[i].spoolId = value
                })
    }

    func consumableBinding(_ id: ConsumableLine.ID) -> Binding<String?> {
        Binding(get: { [weak self] in self?.consumableLines.first { $0.id == id }?.consumableId },
                set: { [weak self] value in
                    guard let self, let i = self.consumableLines.firstIndex(where: { $0.id == id }) else { return }
                    self.consumableLines[i].consumableId = value
                })
    }

    func consumableQtyBinding(_ id: ConsumableLine.ID) -> Binding<Double> {
        Binding(get: { [weak self] in self?.consumableLines.first { $0.id == id }?.qty ?? 1 },
                set: { [weak self] value in
                    guard let self, let i = self.consumableLines.firstIndex(where: { $0.id == id }) else { return }
                    self.consumableLines[i].qty = Self.consumableQty(value)
                })
    }

    /// The first line — the screen's Weight, or Colour 1 — by id too.
    var firstLineID: FilamentLine.ID? { lines.first?.id }

    /// A consumable count as a finite 1…9999 — the stepper's range, and what
    /// `lib/calculator-cost.js` will price. Not finite is 1, never `inf`,
    /// which JSONEncoder refuses and would make the book unwritable.
    static func consumableQty(_ q: Double) -> Double {
        guard q.isFinite else { return 1 }
        return Swift.min(9999, Swift.max(1, q.rounded()))
    }

    // MARK: - The part

    /// The part the shared cost model is handed. Static so a test can hold it
    /// to a record without standing up a screen.
    static func costInput(lines: [FilamentLine], purge: Double, hours: Double, qty: Int,
                          spools: [Spool], consumables: [ConsumableLine],
                          shelf: [Consumable], extra: [String: JSONValue] = [:]) -> JSONValue {
        let spool: (String?) -> Spool? = { id in id.flatMap { id in spools.first { $0.id == id } } }
        let used = lines.filter { number($0.grams) > 0 }
        var part: [String: JSONValue]
        if used.count > 1 {
            // Purge shared by weight: each colour carries its share, so the
            // shelf loses what the printer really flushed, spool by spool.
            let printed = used.reduce(0) { $0 + number($1.grams) }
            var colours: [JSONValue] = []
            var totalCost = 0.0, totalGrams = 0.0
            var materials: [String] = []
            var dominant: (id: String, grams: Double)?
            for line in used {
                let g = number(line.grams) + (printed > 0 ? purge * number(line.grams) / printed : 0)
                let s = spool(line.spoolId)
                let perGram = s.map { ($0.cost ?? 0) / max(1, $0.spoolWeight ?? 1000) } ?? 0
                var c: [String: JSONValue] = ["grams": .number(g), "cost": .number(perGram * g)]
                if let s {
                    c["filamentId"] = .string(s.id)
                    c["material"] = .string(s.material)
                    if !materials.contains(s.material) { materials.append(s.material) }
                    if g > (dominant?.grams ?? -1) { dominant = (s.id, g) }
                }
                if let hex = line.hex ?? s?.color, !hex.isEmpty { c["hex"] = .string(hex) }
                colours.append(.object(c))
                totalCost += perGram * g
                totalGrams += g
            }
            part = extra
            part["colours"] = .array(colours)
            part["printWeight"] = .number(totalGrams)
            part["spoolCost"] = .number(totalCost)
            part["spoolWeight"] = .number(max(1, totalGrams))
            part["printTime"] = .number(max(0, hours))
            part["qty"] = .number(Double(max(1, qty)))
            if let dominant { part["filamentId"] = .string(dominant.id) }
            if !materials.isEmpty { part["material"] = .string(materials.joined(separator: " + ")) }
            if purge > 0 { part["purgeGrams"] = .number(purge) }
        } else {
            let line = used.first ?? lines.first
            var withPurge = extra
            // One filament: the purge is that spool's, charged as support is.
            if purge > 0 { withPurge["supportWeight"] = .number(purge) }
            guard case .object(let o) = Shop.costInput(spool: spool(line?.spoolId),
                                                         grams: number(line?.grams ?? ""),
                                                         hours: hours, qty: qty, extra: withPurge)
            else { return .object([:]) }
            part = o
        }
        let pieces = consumableRows(consumables.compactMap { line in
            line.consumableId.map { (id: $0, qty: line.qty) }
        }, shelf: shelf)
        if !pieces.isEmpty { part["consumables"] = .array(pieces) }
        return .object(part)
    }

    /// Consumable lines as a part records them. `unitCost` is written beside
    /// the id so a host without the shelf in reach still costs the magnet at
    /// what it cost, never at nothing; `name` so the other app can show it.
    static func consumableRows(_ uses: [(id: String, qty: Double)], shelf: [Consumable]) -> [JSONValue] {
        uses.compactMap { use in
            // Finite and at most 9,999: `.number(inf)` makes JSONEncoder
            // throw, and the whole book write with it.
            guard !use.id.isEmpty, use.qty.isFinite, use.qty > 0 else { return nil }
            var row: [String: JSONValue] = ["consumableId": .string(use.id),
                                            "qty": .number(Swift.min(9999, use.qty))]
            if let item = shelf.first(where: { $0.id == use.id }) {
                let cost = item.cost ?? 0
                row["unitCost"] = .number(cost.isFinite ? max(0, cost) : 0)
                if let name = item.name, !name.isEmpty { row["name"] = .string(name) }
            }
            return .object(row)
        }
    }

    /// What the consumables add per printed piece, for the line beside them.
    func consumablesCost(_ shelf: [Consumable]) -> Double {
        consumableLines.reduce(0) { sum, line in
            guard let id = line.consumableId, let item = shelf.first(where: { $0.id == id }) else { return sum }
            let cost = item.cost ?? 0
            guard cost.isFinite, line.qty.isFinite else { return sum }
            return sum + max(0, cost) * min(9999, max(0, line.qty))
        }
    }

    // MARK: - The answer

    func recompute(_ shop: Shop) async {
        guard hasInput else { costed = nil; quoted = nil; return }
        // Only the figures actually typed travel with the part — see
        // `Calculator.ratesSection` for why sending all seven is wrong.
        var extra: [String: JSONValue] = [:]
        for key in Shop.Preset.rateKeys where !(rates[key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            extra[key] = .number(typed(key))
        }
        let part = Self.costInput(lines: lines, purge: purgeValue, hours: hoursValue, qty: qty,
                                  spools: shop.spools, consumables: consumableLines,
                                  shelf: shop.consumables, extra: extra)
        let costedPart = await shop.costedPart(part, machineId: machineId, presetId: presetId)
        let quote = await shop.previewQuote(baseCost: (costedPart?.cost ?? 0) * Double(qty),
                                            margin: margin, discountPct: discount,
                                            shippingCost: 0, rush: rush)
        costed = costedPart
        quoted = quote
    }

    // MARK: - Filling from a library model

    /// Take a model's figures. `grams` and `hours` are the caller's — the
    /// figures `Shop.partFields(from:plate:)` gives, which is what the
    /// catalogue prices the same model at — so the calculator and the product
    /// start from one number. On top of that: one filament line per colour the
    /// slicer weighed (the whole project's colours, or the chosen plate's),
    /// scaled to add up to `grams`, each on the spool the colour planner chose
    /// or the closest colour on the shelf; and the consumables the model is
    /// recorded as using. Returns how many filament lines it filled.
    @discardableResult
    func fill(from file: LibraryFile, plate: Int?, grams: Double, hours: Double, shop: Shop) -> Int {
        modelId = file.id
        let spools = shop.spools
        let plan = shop.colourPlan(of: file.id)
        let weighed: [(hex: String?, grams: Double)] = {
            if let plate, let p = shop.plates(of: file).first(where: { $0.index == plate }) {
                return p.filaments.filter { $0.grams > 0 }.map { ($0.hex, $0.grams) }
            }
            return file.palette.compactMap { c in
                guard let g = c.grams, g > 0 else { return nil }
                return (c.hex, g)
            }
        }()
        let fmt: (Double) -> String = { Words.plain(.number(($0 * 100).rounded() / 100)) }
        var next: [FilamentLine] = []
        if weighed.count > 1 {
            let sum = weighed.reduce(0) { $0 + $1.grams }
            let scale = grams > 0 && sum > 0 ? grams / sum : 1
            for colour in weighed {
                let hex = colour.hex.map(Self.normalHex)
                let planned = hex.flatMap { plan[$0] }.flatMap { id in spools.first { $0.id == id }?.id }
                next.append(FilamentLine(
                    spoolId: planned ?? Self.closestSpool(to: hex, material: file.material, in: spools)
                        ?? lines.first?.spoolId,
                    grams: fmt(colour.grams * scale), hex: hex))
            }
        } else {
            next = [FilamentLine(spoolId: lines.first?.spoolId, grams: grams > 0 ? fmt(grams) : "")]
        }
        lines = next
        splitFrom = nil
        self.hours = hours > 0 ? fmt(hours) : ""
        purge = ""
        consumableLines = shop.consumablesUsed(by: file.id).map {
            ConsumableLine(consumableId: $0.consumableId, qty: $0.qty)
        }
        return next.count
    }

    static func normalHex(_ hex: String) -> String {
        var h = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if !h.hasPrefix("#") { h = "#" + h }
        return String(h.prefix(7))
    }

    static func rgb(_ hex: String?) -> (Double, Double, Double)? {
        guard let hex else { return nil }
        let h = normalHex(hex).dropFirst()
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
    }

    /// The spool nearest in colour, preferring the model's own material. Nil
    /// when nothing on the shelf has a colour to compare.
    static func closestSpool(to hex: String?, material: String?, in spools: [Spool]) -> String? {
        guard let want = rgb(hex) else { return nil }
        let pool: [Spool] = {
            let same = spools.filter { s in
                guard let m = material, !m.isEmpty else { return false }
                return s.material.lowercased().contains(m.lowercased())
            }
            return same.contains { rgb($0.color) != nil } ? same : spools
        }()
        var best: (id: String, d: Double)?
        for s in pool {
            guard let c = rgb(s.color) else { continue }
            let d = pow(c.0 - want.0, 2) + pow(c.1 - want.1, 2) + pow(c.2 - want.2, 2)
            if d < (best?.d ?? .infinity) { best = (s.id, d) }
        }
        return best?.id
    }
}
