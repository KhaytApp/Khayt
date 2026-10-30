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
                     : p.reason == "remix"
                     ? shop.words.callIt("mac.licence_remix_line", ["name": .string(p.name), "parent": .string(p.until)])
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

/// The designers a product must credit (CC BY), and the button that puts the
/// credit into the listing's description — once; a line already there is not
/// added twice.
struct LicenceCredits: View {
    let shop: Shop
    let credits: [ModelLicence.Credit]
    let written: String
    let add: (String) -> Void

    private var missing: [ModelLicence.Credit] { credits.filter { !written.contains($0.line) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(shop.words.callIt("mac.licence_credit_title"), systemImage: "person.text.rectangle")
                .font(.callout.weight(.semibold))
            ForEach(credits, id: \.id) { c in
                Text(verbatim: c.line).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !missing.isEmpty {
                Button(shop.words.callIt("mac.licence_credit_add")) {
                    add(shop.words.callIt("mac.licence_credit_lead") + "\n" + missing.map(\.line).joined(separator: "\n"))
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Role.line2.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
