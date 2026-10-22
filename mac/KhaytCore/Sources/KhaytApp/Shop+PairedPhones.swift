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
    /// Outside the app — a test runner, which has no business in this Mac's
    /// Keychain — a store of its own in memory: a render that reached
    /// `.shared` read the shop's real paired phones (alpha.85 review).
    var lanDeviceStore: LanDevices { lanDevicesForTests ?? (Self.inTheApp ? .shared : Self.outsideTheApp) }
    nonisolated static let inTheApp = Bundle.main.bundlePath.hasSuffix(".app")
    nonisolated static let outsideTheApp = LanDevices.inMemory()

    func refreshPairedPhones() {
        pairedPhones = lanDeviceStore.list()
    }

    /// Open the window a new phone may pair in, for `LanPairingWindow.length`.
    func openPairing() {
        guard permitted("settings", "edit") else { return }
        lanPairing.open()
    }

    func closePairing() {
        lanPairing.close()
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
                                // `lockAllows`, not `permitted`: asking must not
                                // set a "not allowed" problem just by drawing.
                                .disabled(!shop.lockAllows("settings", "edit"))
                        }
                    }
                }
            }
        }
        PairAPhone(shop: shop)
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

/// "Pair a phone": the window a new phone may enrol in (`LanPairingWindow`),
/// with what is left of it, and how the last one ended.
struct PairAPhone: View {
    let shop: Shop

    var body: some View {
        let window = shop.lanPairing
        VStack(alignment: .leading, spacing: 4) {
            if let until = window.until {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(shop.words.callIt("mac.pair_waiting", ["time": .string(
                            Self.clock(window.remaining(at: context.date) ?? 0, locale: shop.words.locale))]))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Button(shop.words.callIt("common.close")) { shop.closePairing() }
                        .controlSize(.small)
                        .accessibilityIdentifier("pair-close")
                }
                if window.lockedAddresses > 0 {
                    Text(shop.words.callIt("mac.pair_locked_some"))
                        .font(.caption).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(shop.words.callIt("mac.pair_open_hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Shut it on time even when no phone asks: the server
                    // would refuse anyway, but the pane should not say
                    // "waiting" with nothing left to wait for.
                    .task(id: until) {
                        let left = until.timeIntervalSince(window.now())
                        if left > 0 { try? await Task.sleep(for: .seconds(left)) }
                        guard !Task.isCancelled else { return }
                        _ = window.isOpen()
                    }
            } else {
                HStack {
                    Button(shop.words.callIt("mac.pair_open")) { shop.openPairing() }
                        // `lockAllows`, not `permitted`: see the sign-out button.
                        .disabled(!shop.lockAllows("settings", "edit") || shop.lanURL == nil)
                        .accessibilityIdentifier("pair-open")
                    Spacer(minLength: 0)
                }
                if let said = Self.outcome(window.lastClosed, words: shop.words) {
                    Text(said.text)
                        .font(.caption)
                        .foregroundStyle(said.warn ? AnyShapeStyle(Khayt.attention) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: window.lastClosed) { _, closed in
            if case .paired? = closed { shop.refreshPairedPhones() }
        }
    }

    /// "1:45", in the digits this Mac asked for (`Digits`).
    static func clock(_ seconds: Int, locale: Locale) -> String {
        Duration.seconds(max(0, seconds))
            .formatted(Duration.TimeFormatStyle(pattern: .minuteSecond).locale(locale))
    }

    /// What the last window came to; nil for one closed by the owner, or none yet.
    static func outcome(_ closed: LanPairingWindow.Closed?, words: Words) -> (text: String, warn: Bool)? {
        switch closed {
        case .paired(let name)?:
            let shown = name.isEmpty ? words.callIt("mac.phones_unnamed") : name
            return (words.callIt("mac.pair_done", ["name": .string(shown)]), false)
        case .timedOut?: return (words.callIt("mac.pair_timed_out"), false)
        case .tooManyWrong?: return (words.callIt("mac.pair_too_many"), true)
        case .byOwner?, nil: return nil
        }
    }
}
