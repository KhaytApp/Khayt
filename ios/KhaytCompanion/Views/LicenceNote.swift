import SwiftUI
import KhaytCore

/// "Not licensed for sale" on a job built from a model whose licence does not
/// allow selling prints — non-commercial, or a bought licence past its last
/// day. The Mac's `LicenceWarning`, on the phone. Shown only when something is
/// known: unknown is not no.
struct LicenceNote: View {
    let problems: [ModelLicence.SaleProblem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.tr("licence.not_for_sale"), systemImage: "exclamationmark.triangle.fill")
                .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.attention)
            ForEach(problems, id: \.id) { p in
                Text(p.reason == "expired"
                     ? L10n.format("licence.expired_line", p.name, p.until)
                     : L10n.format("licence.nc_line", p.name))
                    .font(.khayt(12.5, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KhaytDesign.attention.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}
