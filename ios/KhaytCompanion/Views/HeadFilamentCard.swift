import SwiftUI

/// "Filament used" per head on a job (signed-off frame, iPhone Figma
/// "Printer states · iPhone (Nov 21)", Turki Nov 22). The book holds each
/// head's grams, not its spool, so the rows read T1, T2, … with the grams.
struct HeadFilamentCard: View {
    let split: HeadFilament

    private func grams(_ g: Double) -> String {
        L10n.format("heads.grams", g.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("heads.title"))
                .font(.khayt(17, .semibold, relativeTo: .headline))
                .foregroundStyle(KhaytDesign.ink)
            ForEach(split.heads) { h in
                HStack(spacing: 10) {
                    Text("T\(h.head + 1)")
                        .font(.khaytMono(12.5, .medium, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.note)
                        .environment(\.layoutDirection, .leftToRight)
                    Spacer(minLength: 0)
                    Text(grams(h.grams))
                        .font(.khaytMono(12.5, .medium, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.ink)
                        .environment(\.layoutDirection, .leftToRight)
                }
                .accessibilityElement(children: .combine)
            }
            Text(L10n.format("heads.note", grams(split.totalGrams)))
                .font(.khayt(11.5, relativeTo: .caption2))
                .foregroundStyle(KhaytDesign.note)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
