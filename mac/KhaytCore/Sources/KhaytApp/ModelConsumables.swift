import Foundation
import SwiftUI
import KhaytCore

/// The bought-in pieces a library model uses each time it is printed —
/// magnets, heat-set inserts, screws.
///
/// A shop could count magnets on the Consumables shelf and had nowhere to say
/// a model uses four of them, so the calculator, the catalogue and the job all
/// priced the print without them and the shelf never went down. Reported by a
/// tester: "I can add consumables to the inventory (such as magnets), but I
/// have no way of listing them in the print files or calculator."
///
/// Stored on the model's record as `consumables: [{consumableId, qty,
/// unitCost, name}]`, `qty` per print. It travels onto a product's part when a
/// product is made from the model (`productFromFile`), from there onto a job's
/// part (`partRows`), is costed by `lib/calculator-cost.js` and drawn off the
/// shelf by `lib/order-deduction.js` when that job completes.
extension Shop {

    struct ConsumableUse: Identifiable, Equatable, Sendable {
        var id = UUID()
        var consumableId: String
        var qty: Double
    }

    /// One model's record, as written.
    func fileRecord(_ id: String) -> [String: JSONValue]? {
        for row in fileRows {
            if case .object(let o) = row, o["id"] == .string(id) { return o }
        }
        return nil
    }

    /// What one print of this model uses. Read off the raw record, leniently:
    /// a line with no id or no quantity is not a line.
    func consumablesUsed(by fileId: String) -> [ConsumableUse] {
        Self.consumableUses(fileRecord(fileId)?["consumables"])
    }

    static func consumableUses(_ value: JSONValue?) -> [ConsumableUse] {
        guard case .array(let rows)? = value else { return [] }
        return rows.compactMap { row in
            guard case .object(let o) = row, let id = plainString(o["consumableId"]), !id.isEmpty,
                  let qty = plainNumber(o["qty"]), qty > 0 else { return nil }
            return ConsumableUse(consumableId: id, qty: qty)
        }
    }

    /// Write the list. An empty list removes the key, so a model that never
    /// had any reads exactly as it did before.
    @discardableResult
    func setConsumablesUsed(_ uses: [ConsumableUse], on fileId: String) -> Bool {
        let rows = CalculatorModel.consumableRows(uses.map { ($0.consumableId, $0.qty) }, shelf: consumables)
        return editFiles([fileId], named: words.callIt("mac.model_consumables")) { record in
            if rows.isEmpty { record.removeValue(forKey: "consumables") }
            else { record["consumables"] = .array(rows) }
        }
    }

    /// The colour → spool assignment the other app's colour planner saved on
    /// the model (`rec.colorPlan`), keyed by upper-case `#RRGGBB`.
    func colourPlan(of fileId: String) -> [String: String] {
        guard case .array(let rows)? = fileRecord(fileId)?["colorPlan"] else { return [:] }
        var out: [String: String] = [:]
        for row in rows {
            guard case .object(let o) = row, let hex = Self.plainString(o["hex"]),
                  let spool = Self.plainString(o["filamentId"]), !spool.isEmpty else { continue }
            out[CalculatorModel.normalHex(hex)] = spool
        }
        return out
    }

    /// A whole part, costed — for a caller that built the part itself (the
    /// calculator's several filaments and consumables).
    func costedPart(_ part: JSONValue, machineId: String? = nil,
                    presetId: String? = nil) async -> KhaytEngine.CostedPart? {
        guard let engine else { return nil }
        return try? await engine.costPart(part, inventory: inventoryRows, settings: settingsDict,
                                          machine: machineRow(machineId),
                                          preset: presetRowFor(presetId),
                                          consumables: consumableRows)
    }
}

/// The inspector's list of what one print of a model uses.
///
/// Every change is written at once — a stepper click, a pick, a removal — the
/// way the inspector's other controls (Print next, favourite) write, and each
/// is undoable through the same library undo.
struct ModelConsumablesSection: View {
    let shop: Shop
    let file: LibraryFile

    var body: some View {
        let uses = shop.consumablesUsed(by: file.id)
        DetailSection(shop.words.callIt("mac.model_consumables")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(uses) { use in
                    HStack(spacing: 8) {
                        Picker(shop.words.callIt("mac.calc_consumable"), selection: Binding(
                            get: { use.consumableId },
                            set: { id in write(uses.map { $0.id == use.id ? Shop.ConsumableUse(id: $0.id, consumableId: id, qty: $0.qty) : $0 }) })) {
                            ForEach(shop.consumables) { item in
                                Text(item.title(shop.words)).tag(item.id)
                            }
                            // A line whose item has since been deleted still
                            // shows, so it can be removed rather than lurking.
                            if !shop.consumables.contains(where: { $0.id == use.consumableId }) {
                                Text(shop.words.callIt("mac.unnamed")).tag(use.consumableId)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 180)
                        Stepper(value: Binding(
                            get: { use.qty },
                            set: { q in write(uses.map { $0.id == use.id ? Shop.ConsumableUse(id: $0.id, consumableId: $0.consumableId, qty: q) : $0 }) }),
                                in: 1...9999, step: 1) {
                            Text("× " + Words.plain(.number(use.qty))).monospacedDigit()
                        }
                        .fixedSize()
                        Button(role: .destructive) { write(uses.filter { $0.id != use.id }) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(shop.words.callIt("common.delete"))
                        Spacer(minLength: 0)
                    }
                }
                if shop.consumables.isEmpty {
                    Text(shop.words.callIt("mac.calc_no_consumables"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button {
                        let taken = Set(uses.map(\.consumableId))
                        guard let pick = shop.consumables.first(where: { !taken.contains($0.id) }) ?? shop.consumables.first
                        else { return }
                        write(uses + [Shop.ConsumableUse(consumableId: pick.id, qty: 1)])
                    } label: {
                        Label(shop.words.callIt("mac.calc_add_consumable"), systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    Text(shop.words.callIt("mac.model_consumables_hint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func write(_ uses: [Shop.ConsumableUse]) {
        shop.setConsumablesUsed(uses, on: file.id)
    }
}
