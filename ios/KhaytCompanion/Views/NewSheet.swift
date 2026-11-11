import SwiftUI

/// **New** — the redesign's create sheet (Figma R9W19Jakt19nKs1yM5GEde,
/// "New · sheet over Today"): one place for everything the shop makes from
/// the phone, as tiles, instead of a menu of nine lines.
///
/// It only chooses. The sheet closes and the screen that opened it presents
/// the choice from `onDismiss`, because SwiftUI drops a second sheet asked for
/// while the first is still on screen.
struct NewSheet: View {
    enum Choice: Hashable {
        case job, quoteFile, spool, expense, waste, calculator
        case scanLabel, library, catalogue, endOfDay
    }

    /// Whether this phone holds the book (End of day needs it).
    let holdsBook: Bool
    let choose: (Choice) -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Tile: Identifiable {
        let choice: Choice
        let title: String
        let detail: String
        let icon: String
        var id: Choice { choice }
    }

    private var tiles: [Tile] {
        [
            Tile(choice: .job, title: L10n.tr("order.new.title"), detail: L10n.tr("new.job.detail"),
                 icon: "square.stack.3d.up"),
            Tile(choice: .quoteFile, title: L10n.tr("quote.file.pick"), detail: L10n.tr("new.quote_file.detail"),
                 icon: "doc"),
            Tile(choice: .spool, title: L10n.tr("home.action.add_spool"), detail: L10n.tr("new.spool.detail"),
                 icon: "viewfinder"),
            Tile(choice: .calculator, title: L10n.tr("home.action.calculator"), detail: L10n.tr("new.calculator.detail"),
                 icon: "function"),
            Tile(choice: .expense, title: L10n.tr("home.action.expense"), detail: L10n.tr("new.expense.detail"),
                 icon: "doc.text.viewfinder"),
            Tile(choice: .waste, title: L10n.tr("home.action.waste"), detail: L10n.tr("new.waste.detail"),
                 icon: "exclamationmark.triangle"),
        ]
    }

    private var more: [(Choice, String, String)] {
        var rows: [(Choice, String, String)] = [
            (.scanLabel, L10n.tr("scan.label.title"), "qrcode.viewfinder"),
            (.library, L10n.tr("library.price"), "books.vertical"),
            (.catalogue, L10n.tr("catalogue.title"), "shippingbox"),
        ]
        if holdsBook { rows.append((.endOfDay, L10n.tr("eod.title"), "moon.stars")) }
        return rows
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(tiles) { tile in
                            Button { pick(tile.choice) } label: { tileView(tile) }
                                .buttonStyle(.plain)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        KhaytEyebrow(text: L10n.tr("new.more"))
                            .padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(more.enumerated()), id: \.offset) { i, row in
                                if i > 0 { KhaytThreadDivider().padding(.leading, 48) }
                                Button { pick(row.0) } label: { moreRow(row.1, row.2) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: KhaytDesign.radiusLG))
                    }
                }
                .padding(16)
            }
            .background(KhaytDesign.ground.ignoresSafeArea())
            .navigationTitle(L10n.tr("new.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.close")) { dismiss() }
                }
            }
        }
        // Full height: at the medium detent two of the six choices sat
        // below the fold (review W4, Figma 28:83).
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func pick(_ choice: Choice) {
        choose(choice)
        dismiss()
    }

    private func tileView(_ tile: Tile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: tile.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(KhaytDesign.brand)
                .frame(width: 38, height: 38)
                // One tint for every tile: the live/collect/attention tints
                // borrowed status colours and said nothing.
                .background(KhaytDesign.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            Spacer(minLength: 10)
            Text(tile.title)
                .font(.khayt(16, .semibold, relativeTo: .headline))
                .foregroundStyle(KhaytDesign.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(tile.detail)
                .font(.khayt(12.5, relativeTo: .caption))
                .foregroundStyle(KhaytDesign.note)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .padding(14)
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: KhaytDesign.radiusLG))
        .contentShape(RoundedRectangle(cornerRadius: KhaytDesign.radiusLG))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func moreRow(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(KhaytDesign.brand)
                .frame(width: 24)
            Text(title)
                .font(.khayt(15, .medium, relativeTo: .body))
                .foregroundStyle(KhaytDesign.ink)
            Spacer()
            Image(systemName: "chevron.forward")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(KhaytDesign.note)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}
