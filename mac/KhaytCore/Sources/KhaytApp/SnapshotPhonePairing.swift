import AppKit
import SwiftUI
import KhaytCore

/// ── PAIRING A PHONE BY CODE, ON THE SAMPLE, IN MEMORY ────────────────────
///
/// Figma Qqxg4imtKVgC3TfNGcRGOk page 26, frames 1 to 7, with the frames' own
/// sample people. Nothing is paired, nothing is written and no window is
/// opened: each scene is handed its state as a value.
///
/// `KHAYT_SNAPSHOT_PHONEPAIR=1` runs only these.
extension Snapshot {

    static func capturePhonePairing(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = (dark ? "-dark" : "-light") + "-" + shop.words.language
        await shop.load(.sample)
        await settle()
        let words = shop.words
        let rtl = Direction.rtlLanguages.contains(words.language)
        func shot(_ name: String, width: CGFloat, _ view: some View) {
            captureView(named: "phonepair-\(name)\(tag)",
                        view.padding(16)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                            .padding(20)
                            .frame(width: width, alignment: .topLeading)
                            .background(dark ? Color(white: 0.16) : Khayt.ground)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                            .environment(\.photographFlat, true)
                            .modifier(ShopsLocale(words: words)),
                        into: dir)
        }
        let all = ["viewer", "operator", "manager", "owner"]
        let asked = PhonePairingUI.Asked(pairId: "pair_sample", name: "Reem's iPhone", app: "Khayt iPhone", version: "1.2.0",
                                         address: "192.168.1.47", check: "418207")
        func panel(_ p: PhonePairingUI.Panel, left: TimeInterval, grantable: [String] = all) -> some View {
            PhonePairingPanel(panel: p, words: words, remaining: { left }, address: "192.168.1.20:3210",
                              grantable: grantable, role: .constant("operator"))
        }

        // Frame 1: the window is open.
        shot("1-waiting", width: 560, panel(.waiting(denied: nil), left: 108))
        // Frame 2: a phone asked, the owner approving.
        shot("2-asked-owner", width: 560, panel(.asked(asked), left: 52))
        // Frame 3: the same for a manager, with no Owner choice.
        shot("3-asked-manager", width: 560, panel(.asked(asked), left: 52, grantable: ["viewer", "operator", "manager"]))
        // Frame 4: how it ended.
        shot("4a-paired", width: 560, panel(.closed(.paired(name: "Reem's iPhone", role: "operator")), left: 0))
        shot("4b-denied", width: 560, panel(.waiting(denied: "Reem's iPhone"), left: 41))
        shot("4c-timed-out", width: 560, panel(.closed(.timedOut), left: 0))
        shot("4d-offers-used", width: 560, panel(.closed(.offersUsed), left: 0))
        shot("4e-pin-unreadable", width: 560, panel(.closed(.pinUnreadable), left: 0))

        // Frames 5 and 6: the paired phones with their roles.
        let now = Date()
        func phone(_ id: String, _ name: String, code: Bool, role: String?, days: Double) -> LanDevices.Listed {
            var p = LanDevices.Listed(id: id, name: name, createdAt: now.addingTimeInterval(-86_400 * 20),
                                      lastSeenAt: now.addingTimeInterval(-86_400 * days))
            p.codePaired = code; p.role = role; p.rolesVersion = code ? 1 : nil
            return p
        }
        let phones: [(LanDevices.Listed, String)] = [
            (phone("p1", "Turki's iPhone", code: false, role: nil, days: 0), "owner"),
            (phone("p2", "Reem's iPhone", code: true, role: "operator", days: 0), "operator"),
            (phone("p3", "Workshop iPad", code: true, role: "viewer", days: 3), "viewer"),
            (phone("p4", "Faisal's iPhone", code: true, role: "manager", days: 2), "manager"),
        ]
        func list(owner: Bool) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(words.callIt("mac.phones_title")).font(.headline)
                ForEach(phones, id: \.0.id) { phone, role in
                    PairedPhoneRow(phone: phone, role: role,
                                   settable: owner ? (phone.codePaired ? all : ["owner"]) : [],
                                   mayRemove: true, words: words)
                    Divider()
                }
                Text(words.callIt(owner ? "mac.phones_roles_note" : "mac.phones_roles_manager"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                panel(.closed(nil), left: 0)
            }
        }
        shot("5-phones-owner", width: 680, list(owner: true))
        shot("6-phones-manager", width: 680, list(owner: false))

        // Frame 7: the role choices for one phone.
        captureView(named: "phonepair-7-role-menu\(tag)",
                    PhoneRoleMenu(name: "Reem's iPhone", roles: all, role: "operator", words: words) { _ in }
                        .background(Color(nsColor: .controlBackgroundColor))
                        .padding(20)
                        .background(dark ? Color(white: 0.16) : Khayt.ground)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                        .environment(\.photographFlat, true)
                        .modifier(ShopsLocale(words: words)),
                    into: dir)
    }
}
