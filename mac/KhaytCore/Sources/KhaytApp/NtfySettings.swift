import SwiftUI
import KhaytCore

/// Printer alerts pushed to the shop's phone through ntfy.
///
/// ntfy needs no account and no bot: pick a topic nobody would guess, install
/// the ntfy app, subscribe to it. A self-hosted server, or a protected topic,
/// takes an access token — sealed like every credential and never shown again.
/// Saves ITSELF, like the Telegram section beside it, for the same reason.
struct NtfySettings: View {
    let shop: Shop

    struct Draft: Equatable {
        var enabled = false
        var server = ""
        var topic = ""
        var token = ""          // typed this session, never the stored one
        var clearToken = false
        var error = true, offline = true, stall = false, runout = true

        @MainActor static func read(_ settings: [String: JSONValue]) -> Draft {
            guard case .object(let n)? = settings["ntfy"] else { return Draft() }
            var d = Draft()
            d.enabled = Shop.plainBool(n["enabled"]) ?? false
            d.server = Shop.plainString(n["server"]) ?? ""
            d.topic = Shop.plainString(n["topic"]) ?? ""
            if case .object(let e)? = n["events"] {
                d.error = Shop.plainBool(e["error"]) ?? true
                d.offline = Shop.plainBool(e["offline"]) ?? true
                d.stall = Shop.plainBool(e["stall"]) ?? false
                d.runout = Shop.plainBool(e["runout"]) ?? true
            }
            return d
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var storedToken = false
    @State private var result: String?
    @State private var testing = false

    var body: some View {
        Section(shop.words.callIt("mac.ntfy_section")) {
            Toggle(shop.words.callIt("mac.ntfy_enable"), isOn: $draft.enabled)
            Text(shop.words.callIt("mac.ntfy_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if draft.enabled {
                LabeledContent(shop.words.callIt("mac.ntfy_topic")) {
                    HStack {
                        TextField("", text: $draft.topic, prompt: Text(verbatim: "athar-printers-7f3k"))
                            .textFieldStyle(.roundedBorder).frame(width: 200)
                        Button(shop.words.callIt("mac.ntfy_make_topic")) {
                            // A topic IS the address: anyone who knows it can read
                            // it, so a guessable one is a public one.
                            let letters = Array("abcdefghjkmnpqrstuvwxyz23456789")
                            draft.topic = "khayt-" + String((0..<12).map { _ in letters.randomElement()! })
                        }
                    }
                }
                LabeledContent(shop.words.callIt("mac.ntfy_server")) {
                    TextField("", text: $draft.server, prompt: Text(verbatim: "https://ntfy.sh"))
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                }
                LabeledContent(shop.words.callIt("mac.ntfy_token")) {
                    SecureField(storedToken ? "••••••••" : "", text: $draft.token)
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                }
                if storedToken && draft.token.isEmpty {
                    Toggle(shop.words.callIt("mac.tg_forget"), isOn: $draft.clearToken).font(.caption)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(shop.words.callIt("mac.tg_when")).font(.callout.weight(.medium))
                    Toggle(shop.words.callIt("mac.tg_printer_error"), isOn: $draft.error)
                    Toggle(shop.words.callIt("mac.tg_printer_offline"), isOn: $draft.offline)
                    Toggle(shop.words.callIt("mac.ntfy_runout"), isOn: $draft.runout)
                    Toggle(shop.words.callIt("mac.tg_printer_stall"), isOn: $draft.stall)
                }
            }
            HStack {
                Button(shop.words.callIt("common.save")) { Task { await save() } }
                    .disabled(draft == original || !shop.canMoveJobs)
                Button(shop.words.callIt("mac.tg_test")) { Task { await test() } }
                    .disabled(testing || draft != original || !original.enabled || original.topic.isEmpty)
                if let result {
                    Text(result).font(.callout)
                        .foregroundStyle(result.hasPrefix("✓") ? Khayt.done : Khayt.attention)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            // The last alert that did not arrive, said where the shop would
            // look after a phone stayed quiet.
            if let problem = shop.ntfyProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: shop.settingsValue) { reload() }
    }

    private func reload() {
        original = Draft.read(shop.settingsDict)
        draft = original
        if case .object(let n)? = shop.settingsDict["ntfy"], case .string(let t)? = n["token"] {
            storedToken = !t.isEmpty
        } else { storedToken = false }
    }

    private func save() async {
        guard let build = shop.source.build else {
            shop.settingsProblem = shop.words.callIt("mac.move_sample"); return
        }
        var ntfy: [String: JSONValue] = [
            "enabled": .bool(draft.enabled),
            "server": .string(draft.server.trimmingCharacters(in: .whitespaces)),
            "topic": .string(draft.topic.trimmingCharacters(in: .whitespaces)),
            "events": .object(["error": .bool(draft.error), "offline": .bool(draft.offline),
                               "stall": .bool(draft.stall), "runout": .bool(draft.runout)]),
        ]
        let typed = draft.token.trimmingCharacters(in: .whitespaces)
        if draft.clearToken && typed.isEmpty {
            ntfy["token"] = .string("")
        } else if !typed.isEmpty {
            do { ntfy["token"] = .string(try await Secrets.seal(typed, for: build)) }
            catch { shop.settingsProblem = String(describing: error); return }
        }
        await shop.saveSettings(["ntfy": .object(ntfy)])
        result = nil
        reload()
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            try await shop.sendNtfy(type: "error", title: shop.words.callIt("mac.ntfy_test_title"),
                                    body: shop.words.callIt("mac.ntfy_test_body"))
            result = "✓ " + shop.words.callIt("mac.ntfy_test_sent")
        } catch {
            result = String(describing: error)
        }
    }
}
