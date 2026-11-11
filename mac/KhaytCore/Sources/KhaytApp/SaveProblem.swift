import SwiftUI

/// Why a save was refused, said IN the sheet that tried it.
///
/// Five sheets closed before their write and left the refusal on a banner
/// behind them, with the typed form gone. They now stay open until the write
/// lands, and this is where the reason shows.
struct SaveProblem: View {
    let text: String?
    var body: some View {
        if let text, !text.isEmpty {
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Khayt.attention).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
