import SwiftUI
import AppKit
import KhaytCore

/// Photographs of work the shop has finished.
///
/// Every photo on every job, flattened into one grid — which is what makes it a
/// portfolio rather than a folder. A shop showing somebody what it can do does
/// not want to open nineteen orders.
///
/// ── WHERE THE PICTURES ARE ────────────────────────────────────────────────
///
/// Two places, and the split is Khayt's rather than this app's. A thumbnail is
/// a data URL stored INSIDE the job record, so the grid draws with no file
/// access at all — that is what makes this screen work on a book opened
/// read-only. The full-size photo is a file in `order-photos/` beside the
/// store, written when the photo was added, and is only touched when somebody
/// asks to open one.
struct Portfolio: View {
    @Bindable var shop: Shop

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12)]

    /// THE WINDOW'S search field, not one of this screen's own.
    ///
    /// It was written with a `.searchable` of its own, which would have put a
    /// second `NSSearchField` in a window that already has one. That is worth
    /// not doing on its own terms — the prompt belongs to the shelf, and
    /// `ShopWindow.searchPrompt` names it — and every other screen here reads
    /// `shop.search` the same way.
    ///
    /// It is NOT, as an earlier version of this comment claimed, the cause of
    /// the `_postWindowNeedsUpdateConstraints` abort in the screenshot runner.
    /// A bisect put that crash on a commit predating this screen entirely; the
    /// trigger is the dark-to-light appearance switch, where a search field
    /// attaches its cancel-button cell mid-draw — so dark and light are two
    /// runs now rather than one. Left written down because the wrong story was
    /// convincing enough to be believed twice.
    private var shown: [Shop.Snapshot] {
        let term = shop.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return shop.snapshots }
        return shop.snapshots.filter {
            $0.project.lowercased().contains(term) || $0.orderId.lowercased().contains(term)
        }
    }

    var body: some View {
        Group {
            if shop.snapshots.isEmpty {
                ContentUnavailableView(shop.words.callIt("pf.empty"), systemImage: "photo.on.rectangle")
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: shop.search)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(shown) { snap in cell(snap) }
                    }
                    .padding(Metric.screen)
                }
                .background(Khayt.ground)
            }
        }
    }

    @ViewBuilder
    private func cell(_ snap: Shop.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The library's own thumbnail view: loaded off the main thread and
            // cached, which a grid of a shop's whole history needs as much as
            // the model grid does.
            Thumbnail(source: snap.thumb.map(ThumbnailSource.inlineData))
                .frame(height: 150)
                .clipped()
            VStack(alignment: .leading, spacing: 1) {
                Text(snap.project.isEmpty ? snap.orderId : snap.project)
                    .font(.callout).lineLimit(1)
                Text(snap.orderId + (snap.date.isEmpty ? "" : " · " + snap.date))
                    .font(.caption2).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card(padding: 0)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .help(snap.project)
        .onTapGesture(count: 2) { shop.openPhoto(snap) }
        .contextMenu {
            Button(shop.words.callIt("mac.open")) { shop.openPhoto(snap) }
                .disabled(snap.file == nil)
            Button(shop.words.callIt("mac.reveal")) { shop.revealPhoto(snap) }
                .disabled(snap.file == nil)
            Divider()
            // In the menu rather than the toolbar: the toolbar belongs to the
            // window, and a screen that adds to it is a screen that can rebuild
            // it from underneath itself.
            Button(shop.words.callIt("pf.reveal_folder")) { shop.revealPhotoFolder() }
                .disabled(shop.photoFolder == nil)
        }
    }
}
