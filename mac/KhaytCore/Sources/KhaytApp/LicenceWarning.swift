import SwiftUI
import KhaytCore

/// "Not for sale" beside a job or a product built from a model whose licence
/// does not allow selling prints — non-commercial, or a bought licence past its
/// last day. Silent when nothing is known: unknown is not no.
struct LicenceWarning: View {
    let shop: Shop
    let problems: [ModelLicence.SaleProblem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(shop.words.callIt("mac.licence_not_for_sale"), systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(Khayt.attention)
            ForEach(problems, id: \.id) { p in
                Text(p.reason == "expired"
                     ? shop.words.callIt("mac.licence_expired_line", ["name": .string(p.name), "until": .string(p.until)])
                     : shop.words.callIt("mac.licence_nc_line", ["name": .string(p.name)]))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Khayt.attention.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
