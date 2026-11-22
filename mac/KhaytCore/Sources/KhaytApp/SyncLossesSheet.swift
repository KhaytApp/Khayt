import SwiftUI
import KhaytCore

/// The records a sync took from this book, and the way back for each.
///
/// Copies, not the records themselves: each one was written to
/// `sync-conflicts/` before the merge replaced the book, so closing this loses
/// nothing — the files stay beside the backups.
struct SyncLossesSheet: View {
    @Bindable var shop: Shop

    var body: some View {
        // `SheetFrame`: a merge can take many records, and a sheet cannot be
        // moved to reach buttons below the screen.
        SheetFrame(width: 560) {
            VStack(alignment: .leading, spacing: 6) {
                Text(shop.words.callIt("mac.losses_head")).font(.headline)
                Text(shop.words.callIt("mac.losses_body"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shop.syncLossNotice?.losses ?? []) { loss in
                    row(loss)
                    Divider()
                }
            }
            if let problem = shop.moveProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            HStack {
                Button(shop.words.callIt("mac.losses_show_file")) { shop.revealSyncLosses() }
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.reviewingSyncLosses = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func row(_ loss: SyncLoss) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(loss.title).font(.body).lineLimit(1)
                Text(shop.words.callIt(Self.kindKey(loss.collection)) + " · " + describe(loss.kind))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if shop.syncLossesPutBack.contains(loss.id) {
                Label(shop.words.callIt("mac.losses_put_back_done"), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(Khayt.done)
            } else {
                Button(shop.words.callIt("mac.losses_put_back")) {
                    Task { await shop.putBackSyncLoss(loss) }
                }
                .disabled(!shop.canMoveJobs)
            }
        }
        .padding(.vertical, 6)
    }

    /// The store's collection names are the book's, not the shop's: a row
    /// that said "printLog" or "clients" was the file talking. A collection
    /// without a word of its own is a "record" rather than its key.
    nonisolated static let kindKeys: [String: String] = [
        "printLog": "mac.losses_kind_job",
        "clients": "mac.losses_kind_customer",
        "inventory": "mac.losses_kind_spool",
        "products": "mac.losses_kind_product",
        "machines": "mac.losses_kind_machine",
        "printFiles": "mac.losses_kind_model",
        "expenses": "mac.losses_kind_expense",
        "wasteLog": "mac.losses_kind_waste",
        "waTemplates": "mac.losses_kind_message",
        "suppliers": "mac.losses_kind_supplier",
        "purchaseOrders": "mac.losses_kind_purchase_order",
        "giftCards": "mac.losses_kind_gift_card",
        "machMaintTasks": "mac.losses_kind_maintenance",
        "machMaintLog": "mac.losses_kind_service",
        "consumables": "mac.losses_kind_consumable",
        "operators": "mac.losses_kind_operator",
        "timeEntries": "mac.losses_kind_time",
        "locations": "mac.losses_kind_location",
        "loyaltyLedger": "mac.losses_kind_loyalty",
    ]

    nonisolated static func kindKey(_ collection: String) -> String {
        kindKeys[collection] ?? "mac.losses_kind_record"
    }

    private func describe(_ kind: SyncLoss.Kind) -> String {
        switch kind {
        case .removed: return shop.words.callIt("mac.losses_removed")
        case .replaced: return shop.words.callIt("mac.losses_replaced")
        case .keptDeleted: return shop.words.callIt("mac.losses_kept_deleted")
        }
    }
}
