import SwiftUI
import KhaytCore

// MARK: - Online

/// The LAN server's switch, port and PIN — the block the Electron page keeps
/// under "Advanced: REST API…", in that page's own words.
///
/// Save restarts the server when the port or the PIN changed, because the
/// server is started from the book and a save is a reload of the book. There
/// is no separate Start button: on this app the switch IS the button, and a
/// switch that could disagree with what is running is two sources of truth.
struct OnlinePane: View {
    let shop: Shop

    struct Draft: Equatable {
        var enabled = false
        var port = "3219"
        var bindLan = false
        /// What was typed. Blank keeps the stored PIN — the rule's reading.
        var pin = ""
        /// Whether the book has a PIN at all, sealed or not.
        var pinStored = false

        @MainActor static func read(_ settings: [String: JSONValue], shop: Shop) -> Draft {
            let lan = SettingsReader(settings: SettingsReader(settings: settings).object("lanApi"))
            return Draft(enabled: lan.flag("enabled"),
                         port: String(Int(lan.number("port", 3219))),
                         bindLan: lan.flag("bindLan"),
                         pin: "",
                         pinStored: !lan.text("pin").isEmpty)
        }

        var portNumber: Int { Int(port.trimmingCharacters(in: .whitespaces)) ?? 3219 }
    }

    @State private var draft = Draft()
    @State private var original = Draft()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(shop.words.callIt("mac.online_title")) {
                    Text(shop.words.callIt("mac.online_desc"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(shop.words.callIt("lan.enabled"), isOn: $draft.enabled)
                    LabeledContent(shop.words.callIt("lan.port")) {
                        TextField("", text: $draft.port)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle(shop.words.callIt("lan.bind_lan"), isOn: $draft.bindLan)
                    Text(shop.words.callIt(draft.bindLan ? "lan.bind_lan_hint" : "lan.loopback_warn"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    LabeledContent(shop.words.callIt("lan.pin")) {
                        SecureField(draft.pinStored ? shop.words.callIt("common.secret_unchanged") : "",
                                    text: $draft.pin)
                            .frame(maxWidth: 220)
                    }
                    if draft.enabled, !draft.pinStored, draft.pin.trimmingCharacters(in: .whitespaces).isEmpty {
                        Label(shop.words.callIt("mac.lan_pin_missing"), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Khayt.attention)
                    }
                }
                Section {
                    if let url = shop.lanURL {
                        Text(shop.words.callIt("mac.lan_open")).font(.callout)
                        Text(url)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("lan-url")
                    } else {
                        Text(shop.words.callIt("lan.not_running")).foregroundStyle(.secondary)
                    }
                    if let problem = shop.lanProblem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Khayt.attention).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(shop.words.callIt("mac.lan_restart_note"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: draft != original,
                    save: { Task {
                        await shop.saveLanSettings(enabled: draft.enabled, port: draft.portNumber,
                                                   pin: draft.pin, bindLan: draft.bindLan)
                        reset()
                    } },
                    revert: { draft = original })
        }
        .task(id: shop.settingsValue) { reset() }
    }

    private func reset() { original = .read(shop.settingsDict, shop: shop); draft = original }
}
