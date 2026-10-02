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
                Text(shop.words.callIt("mac.sync_losses_head")).font(.headline)
                Text(shop.words.callIt("mac.sync_losses_body"))
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
                Button(shop.words.callIt("mac.sync_show_file")) { shop.revealSyncLosses() }
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
                Text(loss.collection + " · " + describe(loss.kind))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if shop.syncLossesPutBack.contains(loss.id) {
                Label(shop.words.callIt("mac.sync_put_back_done"), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(Khayt.done)
            } else {
                Button(shop.words.callIt("mac.sync_put_back")) {
                    Task { await shop.putBackSyncLoss(loss) }
                }
                .disabled(!shop.canMoveJobs)
            }
        }
        .padding(.vertical, 6)
    }

    private func describe(_ kind: SyncLoss.Kind) -> String {
        switch kind {
        case .removed: return shop.words.callIt("mac.sync_loss_removed")
        case .replaced: return shop.words.callIt("mac.sync_loss_replaced")
        case .keptDeleted: return shop.words.callIt("mac.sync_loss_kept_deleted")
        }
    }
}
