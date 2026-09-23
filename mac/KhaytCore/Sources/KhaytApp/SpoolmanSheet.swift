import SwiftUI
import KhaytCore

/// Bring a shop's spools across from Spoolman.
///
/// One field and one button. The address is remembered on this Mac, because a
/// shop imports again after buying rolls and should not have to find the Pi's
/// address twice; it is not a setting of the book, since another computer may
/// reach Spoolman differently.
struct SpoolmanSheet: View {
    let shop: Shop

    @AppStorage("spoolmanAddress") private var address = ""
    @State private var working = false
    @State private var result: String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("mac.spoolman_import")).font(.headline)
            Text(shop.words.callIt("mac.spoolman_hint"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent(shop.words.callIt("mac.spoolman_address")) {
                TextField("", text: $address, prompt: Text(verbatim: "192.168.1.20:7912"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(run)
            }
            if let result {
                Label(result, systemImage: "checkmark.circle").foregroundStyle(Khayt.done)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(shop.words.callIt(result == nil ? "common.cancel" : "common.close")) {
                    shop.importingSpoolman = false
                }
                .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.spoolman_go"), action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func run() {
        working = true
        result = nil
        problem = nil
        let typed = address
        Task {
            do { result = try await shop.importFromSpoolman(typed) }
            catch let refusal as Shop.MoveRefused { problem = refusal.sentence }
            catch { problem = (error as? LocalizedError)?.errorDescription ?? String(describing: error) }
            working = false
        }
    }
}
