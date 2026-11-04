import SwiftUI
import KhaytCore

/// The store order lines nothing in the catalogue matched, and the way to say
/// which product each one is.
///
/// `lib/store-order-job.js` matches a Salla, Zid or cloud-queue line by SKU,
/// then by exact name, and otherwise refuses to guess: the line stays on the
/// job with a "Not matched to a product" note. Picking the product here adds
/// its parts, so the job reserves its filament like any other.
struct StoreLinesSection: View {
    let shop: Shop
    let job: Order

    static func shows(_ job: Order) -> Bool { job.storeLines.contains { $0.productId == nil } }

    var body: some View {
        DetailSection(shop.words.callIt("store.pick_title")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(shop.words.callIt("store.pick_hint"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(job.storeLines.enumerated()), id: \.offset) { index, line in
                    if line.productId == nil {
                        HStack(spacing: 8) {
                            Text("\(line.name) × \(line.qty)" + (line.sku.map { " · SKU \($0)" } ?? ""))
                                .lineLimit(2)
                            Spacer()
                            if shop.canMoveJobs, !shop.catalogueRows.isEmpty {
                                Menu(shop.words.callIt("store.pick_title")) {
                                    ForEach(shop.catalogueRows) { row in
                                        Button(row.name) {
                                            Task { await shop.assignStoreLine(job.id, index: index, productId: row.id) }
                                        }
                                    }
                                }
                                .fixedSize()
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A reprint and the job it reprints, each pointing at the other
/// (`reprintOf` / `reprintedInto`, written by `lib/reprint.js`).
struct ReprintLinks: View {
    let shop: Shop
    let job: Order

    static func shows(_ job: Order) -> Bool { job.reprintOf != nil || !job.reprintedInto.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let of = job.reprintOf {
                link(shop.words.callIt("qc.reprint_of"), of)
            }
            ForEach(job.reprintedInto, id: \.self) { id in
                link(shop.words.callIt("qc.reprinted_as"), id)
            }
        }
        .font(.callout)
    }

    private func link(_ label: String, _ id: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Button("#" + id) { shop.goToJob(id) }
                .buttonStyle(.link)
        }
    }
}
