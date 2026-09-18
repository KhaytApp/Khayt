import SwiftUI
import KhaytCore

/// Stopping the floor, and saying why.
///
/// The reason is OPTIONAL and the sheet says so: a shop that just needs the
/// floor stopped should not have to invent one, and being made to type
/// something is how "asdf" ends up on a banner for a fortnight. But the
/// question is worth asking — "waiting on filament" read three days later is
/// the difference between a record and a gap.
struct PauseSheet: View {
    @Bindable var shop: Shop
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("prod.pause")).font(.headline)
            Text(shop.words.callIt("prod.paused_block"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(shop.words.callIt("prod.pause_reason"), text: $reason)
                .textFieldStyle(.roundedBorder)
                .onSubmit { pause() }
            if let problem = shop.writeProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.pausingProduction = false }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("prod.pause")) { pause() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func pause() {
        shop.pauseProduction(reason: reason)
        if shop.writeProblem == nil { shop.pausingProduction = false }
    }
}
