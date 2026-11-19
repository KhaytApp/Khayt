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
        return out
    }
}

/// The product sheet's section: Labour (once) and Machine (every part).
struct ProductRatesSection: View {
    let shop: Shop
    @Binding var rest: [String: JSONValue]
    var reprice: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(shop.words.callIt("mac.prod_labour_note"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        row("calc.labor.rate", "laborRate", unit: shop.currency)
                        row("calc.labor.prep", "prepTime", unit: shop.words.callIt("common.hours"))
                        row("calc.labor.post", "postTime", unit: shop.words.callIt("common.hours"))
                    }
                    Toggle(shop.words.callIt("mac.prod_labour_per_part"), isOn: Binding(
                        get: { ProductRates.labourPerPart(rest) },
                        set: { rest["labourPerPart"] = $0 ? .bool(true) : .bool(false); reprice() }))
                        .toggleStyle(.checkbox).font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(shop.words.callIt("mac.prod_labour_once")).font(.subheadline.weight(.semibold))
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
