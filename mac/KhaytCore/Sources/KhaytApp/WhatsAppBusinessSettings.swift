import SwiftUI
import KhaytCore

/// Settings › Integrations: the shop's own WhatsApp Business account, and the
/// approved template each milestone sends (`WhatsAppCloud.swift` sends them).
///
/// Saves ITSELF, like the email and Telegram panes, for their reason: the
/// access token is a sealed secret, encrypted at the moment of saving and
/// never held in a draft that a revert could write back. A token that cannot
/// be sealed is REFUSED rather than written in the clear, because this file
/// syncs, backs up and exports.
///
/// The account is `settings.smsConfig` with `provider: "whatsapp_cloud"` — the
/// shape the other app's SMS screen already writes, so both apps read one
/// account — and the templates are `settings.whatsappTemplates`.
struct WhatsAppBusinessSettings: View {
    let shop: Shop

    static let milestones = ["received", "ready", "shipped", "delivered"]

    struct Draft: Equatable {
        var enabled = false
        var phoneNumberId = ""
        /// Typed this session, or empty — never the stored ciphertext.
        var token = ""
        var clearToken = false
        /// Per milestone: the template's name and its languages as typed,
        /// comma separated.
        var names: [String: String] = [:]
        var langs: [String: String] = [:]

        @MainActor static func read(_ settings: [String: JSONValue]) -> Draft {
            var out = Draft()
            if case .object(let c)? = settings["smsConfig"] {
                out.enabled = Shop.plainString(c["provider"]) == "whatsapp_cloud"
                out.phoneNumberId = Shop.plainString(c["phoneNumberId"]) ?? ""
            }
            if case .object(let map)? = settings["whatsappTemplates"] {
                for m in WhatsAppBusinessSettings.milestones {
                    guard case .object(let t)? = map[m] else { continue }
                    out.names[m] = Shop.plainString(t["name"]) ?? ""
                    if case .array(let l)? = t["langs"] {
                        out.langs[m] = l.compactMap { Shop.plainString($0) }.joined(separator: ", ")
                    }
                }
            }
            return out
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var storedToken = false
    /// Another provider the other app set up — Twilio, Unifonic — which
    /// turning this on would replace.
    @State private var otherProvider = false
    @State private var checking = false
    @State private var result: String?
    @State private var guide: [String: String] = [:]

    var body: some View {
        Section(shop.words.callIt("mac.wab_section")) {
            Text(shop.words.callIt("mac.wab_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(shop.words.callIt("mac.wab_enabled"), isOn: $draft.enabled)
            if otherProvider && draft.enabled && !original.enabled {
                Text(shop.words.callIt("mac.wab_other_provider"))
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if draft.enabled {
                LabeledContent(shop.words.callIt("mac.wab_number_id")) {
                    TextField("", text: $draft.phoneNumberId, prompt: Text(verbatim: "106540352242922"))
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                }
                Text(shop.words.callIt("mac.wab_number_id_hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent(shop.words.callIt("mac.wab_token")) {
                    SecureField(storedToken ? "••••••••" : "EAAG…", text: $draft.token)
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                }
                Text(shop.words.callIt("mac.wab_token_hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if storedToken && draft.token.isEmpty {
                    Toggle(shop.words.callIt("mac.wab_forget"), isOn: $draft.clearToken)
                        .font(.caption)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(shop.words.callIt("mac.wab_templates")).font(.callout.weight(.medium))
                    Text(shop.words.callIt("mac.wab_templates_hint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(shop.words.callIt("mac.wab_params_basic"))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(shop.words.callIt("mac.wa_m_shipped") + ": " + shop.words.callIt("mac.wab_params_shipped"))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            Color.clear.frame(width: 1, height: 1)
                            Text(shop.words.callIt("mac.wab_template_name")).font(.caption).foregroundStyle(.secondary)
                            Text(shop.words.callIt("mac.wab_langs")).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Self.milestones, id: \.self) { m in
                            GridRow {
                                Text(shop.whatsAppMilestoneName(m)).gridColumnAlignment(.trailing)
                                TextField("", text: name(m), prompt: Text(verbatim: guide[m] ?? ""))
                                    .textFieldStyle(.roundedBorder).frame(width: 180)
                                TextField("", text: langs(m), prompt: Text(verbatim: "ar, en"))
                                    .textFieldStyle(.roundedBorder).frame(width: 100)
                            }
                        }
                    }
                }
            }
            if let problem = invalid {
                Text(problem).font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(shop.words.callIt("common.save")) { Task { await save() } }
                    .disabled(draft == original || invalid != nil)
                if original.enabled {
                    Button(shop.words.callIt("mac.wab_check")) {
                        checking = true
                        Task { result = await shop.checkWhatsAppBusiness(); checking = false }
                    }
                    .disabled(checking || draft != original || !storedToken)
                }
                if let result {
                    Text(result).font(.callout)
                        .foregroundStyle(result.hasPrefix("✓") ? Khayt.done : Khayt.attention)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
        .task(id: shop.settingsValue) { await reload() }
    }

    private func name(_ m: String) -> Binding<String> {
        Binding(get: { draft.names[m] ?? "" }, set: { draft.names[m] = $0 })
    }

    private func langs(_ m: String) -> Binding<String> {
        Binding(get: { draft.langs[m] ?? "" }, set: { draft.langs[m] = $0 })
    }

    static func split(_ typed: String) -> [String] {
        typed.split(whereSeparator: { $0 == "," || $0 == "،" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// What is wrong with the draft, said before it is saved — a template
    /// name WhatsApp would not take is a step that silently never sends.
    /// The same shapes `lib/whatsapp-send.js` accepts.
    private var invalid: String? {
        guard draft.enabled else { return nil }
        for m in Self.milestones {
            let n = (draft.names[m] ?? "").trimmingCharacters(in: .whitespaces)
            let l = Self.split(draft.langs[m] ?? "")
            if n.isEmpty { continue }
            if n.range(of: "^[a-z0-9_]{1,512}$", options: .regularExpression) == nil {
                return shop.words.callIt("mac.wab_bad_name")
            }
            if l.isEmpty { return shop.words.callIt("mac.wab_needs_template") }
            if l.contains(where: { $0.range(of: "^[a-z]{2,3}(_[A-Z]{2})?$", options: .regularExpression) == nil }) {
                return shop.words.callIt("mac.wab_bad_lang")
            }
        }
        let id = draft.phoneNumberId.filter { !$0.isWhitespace }
        if !id.isEmpty, id.range(of: "^\\d{6,20}$", options: .regularExpression) == nil {
            return shop.words.callIt("mac.wab_r_bad_phone_number_id")
        }
        return nil
    }

    private func reload() async {
        original = Draft.read(shop.settingsDict)
        draft = original
        result = nil
        if case .object(let c)? = shop.settingsDict["smsConfig"] {
            let provider = Shop.plainString(c["provider"]) ?? "none"
            otherProvider = provider != "none" && provider != "whatsapp_cloud" && !provider.isEmpty
            storedToken = provider == "whatsapp_cloud" && !(Shop.plainString(c["token"]) ?? "").isEmpty
        } else {
            otherProvider = false
            storedToken = false
        }
        if guide.isEmpty, let names = try? await shop.engine?.whatsAppTemplateGuide().names {
            guide = names
        }
    }

    /// What the pane sends, the token aside — run over what it opened with
    /// too, so what was not touched is kept as stored.
    ///
    /// The provider is written only when this pane owns the answer: switched
    /// on, or switched off FROM WhatsApp Business. Switching off a shop whose
    /// other app sends through Twilio is not this pane's to do.
    static func form(_ draft: Draft, opened: Draft) -> [String: JSONValue] {
        var sms: [String: JSONValue] = ["phoneNumberId": .string(draft.phoneNumberId)]
        if draft.enabled { sms["provider"] = .string("whatsapp_cloud") }
        else if opened.enabled { sms["provider"] = .string("none") }
        var map: [String: JSONValue] = [:]
        for m in milestones {
            let n = (draft.names[m] ?? "").trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { continue }
            map[m] = .object(["name": .string(n),
                              "langs": .array(split(draft.langs[m] ?? "").map(JSONValue.string))])
        }
        return ["smsConfig": .object(sms), "whatsappTemplates": .object(map)]
    }

    private func save() async {
        var form = Self.form(draft, opened: original)
        guard let build = shop.source.build else {
            shop.settingsProblem = shop.words.callIt("mac.move_sample"); return
        }
        // SEALED HERE OR NOT WRITTEN. Absent keeps what is stored; an empty
        // string is the forget switch and nothing else.
        if case .object(var sms)? = form["smsConfig"] {
            let typed = draft.token.trimmingCharacters(in: .whitespacesAndNewlines)
            if draft.clearToken && typed.isEmpty {
                sms["token"] = .string("")
            } else if !typed.isEmpty {
                do { sms["token"] = .string(try await Secrets.seal(typed, for: build)) }
                catch { shop.settingsProblem = shop.words.callIt("mac.wab_unsealed"); return }
            }
            form["smsConfig"] = .object(sms)
        }
        await shop.saveSettings(form, opened: Self.form(original, opened: original))
        draft.token = ""
        draft.clearToken = false
        await reload()
    }
}
