import SwiftUI
import KhaytCore

/// The phones paired with this Mac, and signing one out.
///
/// A phone enrols once with the LAN PIN and signs every request after that
/// with a key of its own (`LanDevices`). Until this, the only way to cut off a
/// lost phone was to change the PIN — which signs out every phone the shop
/// has. Now each is listed with when it was last seen, and can be signed out
/// alone.
extension Shop {
    /// The store the LAN server checks signatures against.
    var lanDeviceStore: LanDevices { lanDevicesForTests ?? .shared }

    func refreshPairedPhones() {
        pairedPhones = lanDeviceStore.list()
    }

    func signOutPhone(_ id: String) {
        guard permitted("settings", "edit") else { return }
        lanDeviceStore.remove(id)
        refreshPairedPhones()
    }
}

/// Settings → Online, under the LAN address.
struct PairedPhones: View {
    let shop: Shop
    @State private var signingOut: LanDevices.Listed?

    var body: some View {
        LabeledContent(shop.words.callIt("mac.phones_title")) {
            if shop.pairedPhones.isEmpty {
                Text(shop.words.callIt("mac.phones_none")).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(shop.pairedPhones) { phone in
                        HStack(spacing: 8) {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(verbatim: phone.name.isEmpty ? shop.words.callIt("mac.phones_unnamed") : phone.name)
                                    .lineLimit(1).truncationMode(.middle)
                                Text(shop.words.callIt("mac.phones_seen", ["date": .string(
                                    shop.words.say(phone.lastSeenAt, .dateTime.day().month(.abbreviated).year()))]))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button(shop.words.callIt("mac.phones_sign_out") + "\u{2026}") { signingOut = phone }
                                .controlSize(.small)
                                .disabled(!shop.permitted("settings", "edit"))
                        }
                    }
                }
            }
        }
        Text(shop.words.callIt("mac.phones_hint"))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .task { shop.refreshPairedPhones() }
            .askFirst($signingOut,
                      title: { shop.words.callIt("mac.phones_sign_out_q", ["name": .string(
                          $0.name.isEmpty ? shop.words.callIt("mac.phones_unnamed") : $0.name)]) },
                      message: { _ in shop.words.callIt("mac.phones_sign_out_note") },
                      confirm: shop.words.callIt("mac.phones_sign_out"),
                      cancel: shop.words.callIt("common.cancel")) { phone in
                shop.signOutPhone(phone.id)
            }
    }
}
