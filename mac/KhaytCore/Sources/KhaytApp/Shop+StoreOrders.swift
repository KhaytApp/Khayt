import Foundation
import KhaytCore

/// Store orders as real jobs, and the linked reprint after a QC failure.
///
/// Both are shared rules this app only carries: `lib/store-order-job.js`
/// matches a Salla, Zid or cloud-queue line to a catalogue product (SKU, then
/// exact name, else unmatched — never a guess) and builds its parts;
/// `lib/reprint.js` makes the linked reprint the desktop makes. Here is only
/// the write and the screen.
@MainActor
extension Shop {

    /// The shop picked the product for a store line nothing matched.
    ///
    /// The product's parts are added for every piece the line asked for, so
    /// the job now reserves their filament like any open job, and the "Not
    /// matched to a product" note for the line goes. Through `writeToOneOrder`,
    /// so it takes the same lock, the same swap and the same undo as any edit.
    func assignStoreLine(_ id: Order.ID, index: Int, productId: String) async {
        await writeToOneOrder(id, named: words.callIt("store.pick_title"), as: .person("orders", "edit")) { order, engine, root in
            guard let product = Self.rows(root, "products").first(where: { Self.recordId($0) == productId }) else {
                throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
            }
            let book: JSONValue = .object([
                "settings": .object(Self.settings(root)),
                "inventory": .array(Self.rows(root, "inventory")),
                "consumables": .array(Self.rows(root, "consumables")),
            ])
            let placed = try await engine.storeOrderAssign(order: order, index: index, product: product, book: book)
            // Nothing to do — the line was placed already (another Mac, a
            // second click). The record is written back as it was.
            return OneOrderEdit(order: placed == .null ? order : placed)
        }
    }

    /// Whether a QC failure here offers Scrap or a linked reprint, as the
    /// desktop does with `settings.qc.enabled` on. Off, a failed job goes back
    /// to Pending, as it always has.
    var qcReprintFlow: Bool {
        guard case .object(let qc)? = settingsDict["qc"], case .bool(let on)? = qc["enabled"] else { return false }
        return on
    }

    /// What the shop chose after a QC failure, with QC switched on.
    enum QcNext: Equatable, Sendable {
        /// Keep the failed job as a scrapped record. Nothing more is made.
        case scrap
        /// A new, linked job to print it again. `cost` is `shop` (no charge —
        /// our defect) or `billable`.
        case reprint(cost: String)
    }

    /// The failed job, scrapped, and — for a reprint — the linked new job, in
    /// the SAME write as the failure itself: a book where the job failed and
    /// its reprint does not exist yet is a job nobody is printing.
    ///
    /// Returns the new job's id, if one was made.
    static func applyQcNext(_ next: QcNext, failedId: String, root: inout [String: JSONValue],
                            engine: KhaytEngine, now: Date) async throws -> String? {
        let at = StoreWriter.iso(now)
        var orders = rows(root, "printLog")
        guard let i = orders.firstIndex(where: { recordId($0) == failedId }) else { return nil }
        orders[i] = try await engine.qcMarkScrapped(orders[i], at: at)
        root["printLog"] = .array(orders)
        guard case .reprint(let cost) = next else { return nil }
        guard let made = try await engine.linkedReprint(
            of: failedId, printLog: orders, settings: settings(root), now: now,
            tokens: (tracking: randomBytes(16), quoteApproval: randomBytes(16)),
            inventory: rows(root, "inventory"), consumables: rows(root, "consumables"),
            clients: rows(root, "clients"), reason: "qc_fail", cost: cost,
            partIdBase: uid("PRT")) else { return nil }
        root["printLog"] = .array(made.printLog)
        root["settings"] = .object(made.settings)
        return plainString(asObject(made.order)?["id"])
    }

    /// The `qc_failed` webhook the desktop's QC sheet fires, now this app's
    /// too — `lib/webhook-bus.js statusPayload` holds its keys.
    func qcFailedDeliveries(_ order: JSONValue) async -> [KhaytEngine.WebhookDelivery] {
        guard let engine else { return [] }
        let settings = settingsDict
        return (try? await engine.webhookDeliveries(
            order: order,
            effects: [WebhookEffect(kind: "webhook", event: "qc_failed", newStatus: nil)],
            settings: DevConnectors.withDev(settings),
            shopName: Self.plainString(settings["bizEn"]) ?? Self.plainString(settings["bizAr"]) ?? "Khayt",
            clientName: "", currency: Self.shopCurrencyOf(settings),
            at: ISO8601DateFormatter().string(from: Date()),
            nowMs: Date().timeIntervalSince1970 * 1000)) ?? []
    }

    /// Put the person on another job — a reprint's original, or its reprint.
    func goToJob(_ id: Order.ID) {
        selection = id
        shelf = .jobs(nil)
    }
}
