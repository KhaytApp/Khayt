import SwiftUI
import KhaytCore

/// The proof behind a bought licence: the designer's code, a page that
/// verifies it, and the last day it covers.
///
/// A designer's commercial licence — a Patreon merchant tier, a shop plan — is
/// what makes selling prints of their model lawful, and it usually lasts only
/// while it is paid. Recording the last day is what lets every sale of the
/// model say, the day after, that it is no longer covered.
struct LicenceProofSheet: View {
    let shop: Shop
    let file: LibraryFile

    @State private var code = ""
    @State private var link = ""
    @State private var hasEnd = false
    @State private var until = Date()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("mac.licence_proof")).font(.headline)
            Text(file.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("mac.licence_code")).foregroundStyle(.secondary)
                    TextField("", text: $code).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(shop.words.callIt("mac.licence_verify")).foregroundStyle(.secondary)
                    TextField("", text: $link, prompt: Text(verbatim: "https://"))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Toggle(shop.words.callIt("mac.licence_has_end"), isOn: $hasEnd)
                        .gridCellColumns(2)
                }
                if hasEnd {
                    GridRow {
                        Text(shop.words.callIt("mac.licence_until")).foregroundStyle(.secondary)
                        DatePicker("", selection: $until, displayedComponents: .date).labelsHidden()
                    }
                }
            }
            Text(shop.words.callIt("mac.licence_proof_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save")) {
                    shop.setLicenceProof(file.id, code: code, url: link,
                                         expires: hasEnd ? Shop.today(until) : "")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            code = file.licenceCode ?? ""
            link = file.licenceUrl ?? ""
            if let day = file.licenceExpires, let date = Order.day(day) { hasEnd = true; until = date }
        }
    }
}
