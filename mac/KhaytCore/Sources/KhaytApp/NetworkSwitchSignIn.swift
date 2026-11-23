import SwiftUI
import KhaytCore

// Frame H (Mac file, page 27, node 217:223; signed off by Turki, Nov 23 2026).
// In a file of its own because it DRAWS (`MessagesAreShownTests`).

/// "Internet use was turned back on here, but your other computers don't know
/// yet." Under the switch on Settings ▸ General ▸ Internet use, on the amber
/// ground the questions use, with one button: Sign in again.
///
/// Shown when the switch was turned OFF here, the "off" could not be sent
/// through Khayt Cloud, and the reason is a sign-in that has ended
/// (`Shop.networkSwitchSignInEnded`). Khayt keeps the change and sends it by
/// itself once somebody signs in again; nothing else changes. It replaces the
/// general "your other computers were not told" sentence, which cannot say
/// what to do about it.
///
/// Only for somebody who may change the switch: nobody else can act on it.
struct NetworkSwitchSignIn: View {
    let shop: Shop
    /// A capture's stand-ins.
    var pretendBy: String??
    var pretendAt: Date??
    @State private var signingIn = false

    private var words: Words { shop.words }
    private var by: String? { pretendBy ?? InternetUse.switchedBy(shop.networkSettings) }
    private var at: Date? { pretendAt ?? InternetUse.switchedAt(shop.networkSettings) }

    /// The second sentence: who and when, as far as the book says.
    @MainActor static func detail(by: String?, at: Date?, words: Words) -> String {
        let time = at.map { words.say($0, .dateTime.hour().minute()) }
        switch (by, time) {
        case let (name?, time?): return words.callIt("mac.net_h_by_at", ["name": .string(name), "time": .string(time)])
        case let (nil, time?): return words.callIt("mac.net_h_at", ["time": .string(time)])
        default: return words.callIt("mac.net_h_plain")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13)).foregroundStyle(Khayt.attention).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(words.callIt("mac.net_h_title")).font(.system(size: 13, weight: .medium))
                    Text(Self.detail(by: by, at: at, words: words)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(words.callIt("mac.net_h_sign_in")) { signingIn = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Khayt.attention.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
        // The existing Khayt Cloud sign-in, nothing of its own.
        .shopSheet(isPresented: $signingIn) { CloudSignInSheet(shop: shop) }
    }
}
