import SwiftUI
import KhaytCore

// The window's banners that have a question behind them, each its own view so
// a snapshot can photograph it on its own (`SnapshotTests.newScreens`).

/// What sync took from this book, with the way back to each record.
///
/// ── THE ✕ ASKS WHILE ANYTHING IS STILL OUT ────────────────────────────────
///
/// It used to clear the notice in one click, and the notice was the only way
/// back to the records — kept on disk, and offered by nothing else. Closing it
/// is now a decision the shop is asked to make while records are still not
/// put back, and once made it is remembered (`SyncLossReview`), so the next
/// launch does not put it up again. Until then, it comes back on every launch.
struct SyncLossBanner: View {
    let shop: Shop
    let lost: SyncLossNotice
    @State private var asking: Int?

    var body: some View {
        Banner(text: shop.words.callIt("mac.losses_banner",
                                       ["replaced": .number(Double(lost.replaced + lost.keptDeleted)),
                                        "removed": .number(Double(lost.removed))]),
               symbol: "arrow.triangle.2.circlepath", tint: Khayt.attention) {
            Button(shop.words.callIt("mac.review") + "\u{2026}") {
                shop.reviewingSyncLosses = true
            }
            BannerClose(words: shop.words) {
                let outstanding = shop.unreviewedSyncLosses
                if outstanding > 0 { asking = outstanding } else { shop.closeSyncLosses() }
            }
        }
        .askFirst($asking,
                  title: { _ in shop.words.callIt("mac.losses_dismiss_q") },
                  message: { n in shop.words.callIt("mac.losses_dismiss_body", ["n": .number(Double(n))]) },
                  confirm: shop.words.callIt("mac.losses_dismiss"),
                  cancel: shop.words.callIt("common.cancel")) { _ in
            shop.closeSyncLosses()
        }
    }
}

/// Sync refused because the cloud answered BELOW a revision this Mac has
/// already seen — and the way on, where it can be found.
///
/// The button lived only in Check Cloud, behind the passphrase, and the
/// reason was a hard-coded English sentence; an automatic sync that hit it
/// simply kept failing with nothing on screen. Pressing it now also syncs,
/// rather than leaving the shop to wonder whether anything happened.
struct WentBackwardsBanner: View {
    let shop: Shop
    /// For a photograph, which has no cloud to be refused by.
    var shown: (seen: Int, got: Int)? = nil
    @State private var asking: Int?

    var body: some View {
        // Read for observation: a refusal always sets the problem, and
        // clearing it is what takes this away.
        let _ = shop.cloudProblem
        if let went = shown ?? shop.cloudWentBackwards {
            Banner(text: shop.words.callIt("mac.cloud_went_backwards_banner",
                                           ["seen": .number(Double(went.seen)),
                                            "got": .number(Double(went.got))]),
                   symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90", tint: Khayt.attention) {
                Button(shop.words.callIt("mac.cloud_accept_rollback") + "\u{2026}") { asking = went.got }
                    .disabled(shop.cloudBusy || !shop.canMoveJobs)
            }
            .askFirst($asking,
                      title: { _ in shop.words.callIt("mac.cloud_accept_rollback_q") },
                      message: { _ in shop.words.callIt("mac.cloud_accept_rollback_body") },
                      confirm: shop.words.callIt("mac.cloud_accept_rollback"),
                      cancel: shop.words.callIt("common.cancel")) { _ in
                shop.acceptCloudRollbackAndSync()
            }
        }
    }
}

/// Products costed on a spool size that has changed — said on every screen,
/// because the change that causes it is made on the shelf.
struct SpoolRepairBanner: View {
    let shop: Shop
    /// For a photograph of the sample, which cannot be repaired.
    var shown = false

    var body: some View {
        if shown || (shop.spoolRepairPending > 0 && shop.canMoveJobs) {
            Banner(text: shop.words.counting(shop.spoolRepairPending, "mac.spool_repair_pending"),
                   symbol: "scalemass", tint: Khayt.attention) {
                Button(shop.words.callIt("mac.spool_repair_review") + "\u{2026}") {
                    shop.showingSpoolRepair = true
                }
            }
        }
    }
}

extension Shop {

    /// The revision this Mac has seen and the lower one the cloud answered
    /// with, while a pull is refused for going backwards.
    var cloudWentBackwards: (seen: Int, got: Int)? {
        guard let connection = try? CloudReader.connection(settingsDict),
              let got = cloudRevisions.refusal(connection) else { return nil }
        return (cloudRevisions.highest(connection) ?? got, got)
    }

    /// The shop reset or restored its cloud on purpose: carry on from the
    /// older copy, and sync now rather than at the next edit.
    func acceptCloudRollbackAndSync() {
        acceptCloudRollback()
        guard cloudWentBackwards == nil else { return }
        moveNotices.append(words.callIt("mac.cloud_rollback_accepted"))
        Task { await self.autoSyncNow() }
    }
}

extension Words {
    /// What a cloud read failed with, in the shop's language where this app
    /// has the words for it. The service's own sentences stay as they are.
    func cloudFailure(_ failure: CloudReader.Failure) -> String {
        switch failure {
        case .wentBackwards(let seen, let got):
            return callIt("mac.cloud_went_backwards", ["seen": .number(Double(seen)),
                                                       "got": .number(Double(got))])
        default:
            return failure.description
        }
    }
}

/// A live web store about to publish a price the shop did not set — held, and
/// the way to review it. On the catalogue, where the web store opens from.
struct PriceHoldBanner: View {
    let shop: Shop
    /// For a photograph: the sample book has no live store to hold anything.
    var shown = false

    var body: some View {
        if shown || !shop.webStorePricesHeld.isEmpty {
            Banner(text: shop.words.callIt("mac.ws_prices_held"),
                   symbol: "storefront", tint: Khayt.attention) {
                Button(shop.words.callIt("mac.spool_repair_review") + "\u{2026}") {
                    shop.showingWebStore = true
                }
            }
        }
    }
}

extension Shop {
    /// Why this Mac may not change the book right now, in a sentence — for the
    /// hover on a greyed action and the note under an empty screen's button.
    var lockedReason: String {
        words.callIt(source.isReal ? "mac.group_locked" : "mac.sample_read_only")
    }
}

/// Under a button that is off because the book cannot be changed here.
struct WhyLockedNote: View {
    let shop: Shop

    var body: some View {
        if !shop.canMoveJobs {
            Label(shop.lockedReason, systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
