import SwiftUI
import KhaytCore

/// A product's OWN cost rates: labour once for the product, the machine rates
/// for every part by its print time (Turki, Nov 19; Figma Mac file p.18).
///
/// ── WHY THEY ARE THE PRODUCT'S ───────────────────────────────────────────
///
/// The labour, power and wear fields on the product sheet belonged to the
/// part being ADDED (`ProductSheet.newPart`), pre-filled with the shop's
/// defaults. A shop that opened a product and typed a labour rate changed the
/// next new part, and Save dropped it, because that part had no grams or
/// hours. And labour was charged on every part and every piece: a product of
/// four parts cost four times the labour of one. The shared rule
/// (`lib/product-pricing.js`, `usesProductRates` / `productLabourCost`) now
/// reads `rates` on the PRODUCT and charges labour once; a product with no
/// `rates` (every one saved before this) is costed exactly as before, until
/// the shop accepts the new cost. Nothing re-prices by itself.
enum ProductRates {

    /// The seven keys, the same as a part's.
    static let keys = ProductSheet.PartRow.rateKeys

    /// Whether the product carries its own rates (the shared rule's
    /// `usesProductRates`: `rates` is an object).
    static func usesOwn(_ rest: [String: JSONValue]) -> Bool {
        if case .object? = rest["rates"] { return true }
        return false
    }

    static func rates(_ rest: [String: JSONValue]) -> [String: JSONValue] {
        if case .object(let o)? = rest["rates"] { return o }
        return [:]
    }

    /// A rate as the field shows it; blank when the product does not say.
    static func text(_ rest: [String: JSONValue], _ key: String) -> String {
        guard let n = Shop.plainNumber(rates(rest)[key]) else { return "" }
        return Money.fieldValue(n)
    }

    /// A typed rate onto the product. Blank removes it (the shop default
    /// stands), as a part's does: blank is not zero.
    static func set(_ rest: inout [String: JSONValue], _ key: String, _ typed: String) {
        var o = rates(rest)
        let t = typed.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { o.removeValue(forKey: key) } else { o[key] = .number(TypedNumber.parse(t) ?? 0) }
        rest["rates"] = .object(o)
    }

    static func labourPerPart(_ rest: [String: JSONValue]) -> Bool { rest["labourPerPart"] == .bool(true) }

    /// The rates a product costed the old way would take: the first part
    /// that carries any (they were the product's in all but name), else the
    /// shop's defaults. Only the figures said; blank stays blank.
    static func proposed(parts: [ProductSheet.PartRow], defaults: [String: String]) -> [String: JSONValue] {
        let source = parts.first(where: \.hasRates)?.rates ?? defaults
        var out: [String: JSONValue] = [:]
        for key in keys {
            let t = (source[key] ?? defaults[key] ?? "").trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, let n = TypedNumber.parse(t) { out[key] = .number(n) }
        }
        return out
    }

    /// The fields the shared rule prices a product with, besides its parts.
    static func pricingFields(_ rest: [String: JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if let r = rest["rates"], case .object = r { out["rates"] = r }
        if let l = rest["labourPerPart"] { out["labourPerPart"] = l }
        // How many fit one box (#2586): the rule boxes a line of N by it.
        if let b = rest["perBox"] { out["perBox"] = b }
        return out
    }

    /// Pieces per box as the field shows it; blank is the rule's default (1).
    static func perBoxText(_ rest: [String: JSONValue]) -> String {
        guard let n = Shop.plainNumber(rest["perBox"]), n >= 1 else { return "" }
        return Money.fieldValue(n)
    }

    /// A typed pieces-per-box onto the product: a whole number of at least 1,
    /// blank removes it (one box each).
    static func setPerBox(_ rest: inout [String: JSONValue], _ typed: String) {
        let t = typed.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { rest.removeValue(forKey: "perBox"); return }
        guard let n = TypedNumber.parse(t), n.isFinite, n >= 1 else { return }
        rest["perBox"] = .number(min(9999, n.rounded()))
    }
}

/// The product sheet's section: Labour (once) and Machine (every part).
struct ProductRatesSection: View {
    let shop: Shop
    @Binding var rest: [String: JSONValue]
    /// The product as the rule prices it (parts and pricing fields), for the
    /// "For N pieces" preview.
    var record: JSONValue
    var reprice: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(shop.words.callIt("mac.prod_labour_line_note"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        row("calc.labor.rate", "laborRate", unit: shop.currency)
                        row("mac.prod_prep_line", "prepTime", unit: shop.words.callIt("common.hours"))
                        row("mac.prod_post_piece", "postTime", unit: shop.words.callIt("common.hours"))
                    }
                    Toggle(shop.words.callIt("mac.prod_labour_per_part"), isOn: Binding(
                        get: { ProductRates.labourPerPart(rest) },
                        set: { rest["labourPerPart"] = $0 ? .bool(true) : .bool(false); reprice() }))
                        .toggleStyle(.checkbox).font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(shop.words.callIt("mac.prod_labour_line_title")).font(.subheadline.weight(.semibold))
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        row("calc.machine.power", "powerDraw", unit: shop.words.callIt("calc.machine.watts"))
                        row("calc.machine.elec", "elecRate", unit: shop.words.callIt("calc.machine.per_kwh"))
                        row("calc.machine.wear", "wearRate", unit: shop.currency)
                        row("calc.labor.failure", "failureRate", unit: "%")
                    }
                    Text(shop.words.callIt("mac.prod_part_own_note"))
                        .font(.caption2).foregroundStyle(Khayt.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(shop.words.callIt("mac.prod_machine")).font(.subheadline.weight(.semibold))
            }
            // Packaging by the box (Figma 180:223). The packaging per box is
            // the shop's (Settings); what a product says is how many fit one.
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            Text(shop.words.callIt("mac.prod_per_box")).gridColumnAlignment(.trailing)
                                .font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                TextField("1", text: Binding(
                                    get: { ProductRates.perBoxText(rest) },
                                    set: { ProductRates.setPerBox(&rest, $0); reprice() }))
                                    .textFieldStyle(.roundedBorder).frame(width: 70).monospacedDigit()
                                    .accessibilityLabel(shop.words.callIt("mac.prod_per_box"))
                                Text(shop.words.callIt("mac.prod_pieces")).font(.caption2).foregroundStyle(Khayt.faint)
                                Spacer()
                            }
                        }
                    }
                    Text(shop.words.callIt("mac.prod_per_box_note", [
                        "amount": .string(Money.text(shop.packagingPerBox, shop.currency))]))
                        .font(.caption2).foregroundStyle(Khayt.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(shop.words.callIt("mac.prod_packaging_box")).font(.subheadline.weight(.semibold))
            }
            if !ProductRates.labourPerPart(rest) {
                ProductLinePreview(shop: shop, record: record)
            }
        }
    }

    private func row(_ label: String, _ key: String, unit: String) -> some View {
        GridRow {
            Text(shop.words.callIt(label)).gridColumnAlignment(.trailing)
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField("", text: Binding(
                    get: { ProductRates.text(rest, key) },
                    set: { ProductRates.set(&rest, key, $0); reprice() }))
                    .textFieldStyle(.roundedBorder).frame(width: 70).monospacedDigit()
                    .accessibilityLabel(shop.words.callIt(label))
                Text(unit).font(.caption2).foregroundStyle(Khayt.faint)
                Spacer()
            }
        }
    }
}

/// A product costed the old way: what the new rule would make it cost, and
/// the choice. Nothing changes until the shop picks one.
struct ProductRatesNotice: View {
    let shop: Shop
    let partCount: Int
    let oldCost: Double
    let newCost: Double
    let price: Double?
    var useNew: () -> Void
    var keepPerPart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shop.words.callIt("mac.prod_new_rule_title"))
                .font(.subheadline.weight(.semibold)).foregroundStyle(Khayt.attention)
            Text(shop.words.callIt("mac.prod_new_rule_body", [
                "n": .number(Double(partCount)),
                "old": .string(Money.text(oldCost, shop.currency)),
                "new": .string(Money.text(newCost, shop.currency))]))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            // Said beside the cost when the price no longer covers it.
            if let price, price + 0.005 < newCost {
                Text(shop.words.callIt("mac.prod_price_below", [
                    "price": .string(Money.text(price, shop.currency)),
                    "cost": .string(Money.text(newCost, shop.currency))]))
                    .font(.callout.weight(.medium)).foregroundStyle(Khayt.late)
            }
            HStack(spacing: 8) {
                Button(shop.words.callIt("mac.prod_use_new_cost"), action: useNew)
                    .buttonStyle(.borderedProminent)
                Button(shop.words.callIt("mac.prod_keep_per_part"), action: keepPerPart)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Khayt.attention.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// "What it costs to make, for N pieces" (Figma 180:223): the product as one
/// line of N through the shared rule (`productJobParts` with `units`), prep
/// once, finishing per piece, packaging by the box. Every figure is the lib's.
struct ProductLinePreview: View {
    let shop: Shop
    let record: JSONValue
    @State private var units = 10
    @State private var line: Shop.ProductLine?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(shop.words.callIt("mac.prod_for_n")).font(.caption).foregroundStyle(.secondary)
                    TextField("", value: $units, format: .number.locale(Money.digits))
                        .textFieldStyle(.roundedBorder).frame(width: 60).monospacedDigit()
                        .accessibilityLabel(shop.words.callIt("mac.prod_for_n"))
                    Stepper("", value: $units, in: 1...9999).labelsHidden()
                    Text(shop.words.callIt("mac.prod_pieces")).font(.caption2).foregroundStyle(Khayt.faint)
                }
                if let line {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        figure(shop.words.callIt("mac.prod_line_parts"), line.parts)
                        figure(shop.words.callIt("mac.prod_line_labour", ["n": .number(Double(line.units))]), line.labour)
                        figure(shop.words.callIt("mac.prod_line_packaging", ["boxes": .number(line.boxes)]), line.packaging)
                        figure(shop.words.callIt("mac.prod_line_cost"), line.cost, bold: true)
                        figure(shop.words.callIt("mac.prod_line_per_piece"), line.perPiece)
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(shop.words.callIt("mac.prod_line_title")).font(.subheadline.weight(.semibold))
        }
        .task(id: Key(record: record, units: units)) {
            // A quarter second after the last keystroke, as Recalculate's
            // preview: four engine calls per digit typed was the cost before,
            // and a superseded answer must not land over a newer one.
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            let next = await shop.productLine(record, units: max(1, min(9999, units)))
            if Task.isCancelled { return }
            line = next
        }
    }

    private struct Key: Equatable { let record: JSONValue; let units: Int }

    private func figure(_ label: String, _ amount: Double, bold: Bool = false) -> some View {
        GridRow {
            Text(label).fontWeight(bold ? .semibold : .regular)
            Text(Money.text(amount, shop.currency)).monospacedDigit()
                .fontWeight(bold ? .semibold : .regular)
                .gridColumnAlignment(.trailing)
        }
    }
}
