import Foundation
import KhaytCore

/// Something the shop has ordered and is waiting for.
///
/// ── WHY THIS IS A THIN READ AND NOT A MODEL ───────────────────────────────
///
/// Everything that DECIDES anything about a purchase order — what it asks for,
/// what arrives when goods are booked in, whether it is priced a thousand times
/// too high — is `lib/purchase-orders.js` and `lib/po-audit.js`, and this app
/// runs both. What is here is only what a row on a screen needs to draw itself.
///
/// `kind` is not among these fields on purpose. Whether an order is counted in
/// grams or in the shop's own unit is the rule's answer (`isConsumableOrder`),
/// because an order written before consumables could be ordered carries no
/// `kind` at all — and reading absent as "consumable" would restock the wrong
/// collection.
struct PurchaseOrder: Identifiable, Hashable, Sendable {
    let id: String
    /// What was ordered, as the order itself names it — a material for a spool,
    /// a name for a consumable.
    let itemName: String
    let supplierName: String
    /// Grams, or the shop's own unit.
    let qty: Double
    let receivedSoFar: Double
    /// Empty for a filament order, which is always in grams.
    let unit: String
    let unitPrice: Double?
    /// 'ordered' | 'partial' | 'received' | 'draft'
    let status: String
    let orderedAt: String
    let estimatedDelivery: String?

    /// Has a supplier's bill been recorded against this order?
    let hasBill: Bool
    /// Was it recorded and found not to agree with what the order expected?
    let billMismatched: Bool

    /// What is still to come, never below zero.
    var outstanding: Double { max(0, qty - receivedSoFar) }

    /// What the whole order is worth, when it carries a price at all.
    var total: Double? { unitPrice.map { qty * $0 } }

    @MainActor
    init?(row: JSONValue) {
        guard case .object(let o) = row,
              case .string(let id)? = o["id"], !id.isEmpty else { return nil }
        self.id = id
        self.itemName = Shop.plainString(o["itemName"]) ?? id
        self.supplierName = Shop.plainString(o["supplierName"]) ?? ""
        self.qty = Shop.plainNumber(o["qty"]) ?? 0
        self.receivedSoFar = Shop.plainNumber(o["receivedSoFar"]) ?? 0
        self.unit = Shop.plainString(o["unit"]) ?? ""
        self.unitPrice = Shop.plainNumber(o["unitPrice"])
        self.status = Shop.plainString(o["status"]) ?? "ordered"
        self.orderedAt = Shop.plainString(o["orderedAt"]) ?? ""
        // The VERDICT is the rule's, stored on the row when the bill was
        // recorded; this only reads what is there.
        self.hasBill = o["supplierInvoice"] != nil
        if case .bool(true)? = o["invoiceDiscrepancy"] { self.billMismatched = true }
        else { self.billMismatched = false }
        let due = Shop.plainString(o["estimatedDelivery"]) ?? ""
        self.estimatedDelivery = due.isEmpty ? nil : due
    }
}
