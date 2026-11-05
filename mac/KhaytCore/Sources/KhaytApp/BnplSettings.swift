import SwiftUI
import KhaytCore

/// Settings › Online › Pay later: the shop's own Tabby and Tamara accounts.
///
/// ── THE SAME FIELDS THE DESKTOP WRITES ────────────────────────────────────
///
/// `settings.bnpl.tabby = { enabled, apiKey, merchantCode, currency }` and
/// `settings.bnpl.tamara = { enabled, apiKey, notificationToken, currency,
/// country }` — `renderer/settings.js renderBnplSettings`. Both apps read one
/// book, so a shop that set Tabby up on either finds it set up on the other.
/// Saved through `lib/settings-edit.js` (its `bnpl` branch); Stripe, which this
/// app does not make links for, is left exactly as stored.
///
/// The desktop has no sandbox switch for either provider — its requests go to
/// the live hosts — so neither does this: a second idea of "which host" would
/// be a Mac link the desktop then checks on the wrong one.
///
/// ── THE KEYS ──────────────────────────────────────────────────────────────
///
/// `apiKey` (both) and Tamara's `notificationToken` are registered secrets
/// (`lib/store-secret-paths.js`): sealed here with the book's own Keychain key
/// before they are written, the way the Telegram token is, never shown, and an
/// empty field means "keep it". A key that cannot be sealed is refused rather
/// than written in the clear.
struct BnplSettings: View {
    let shop: Shop

    struct Provider: Equatable {
        var enabled = false
        var merchantCode = ""
        var currency = ""
        var country = ""
        /// Typed this session, or empty — the stored key is never in here.
        var apiKey = ""
        var forgetKey = false
        var token = ""
        var forgetToken = false
    }

    struct Draft: Equatable {
        var tabby = Provider()
        var tamara = Provider()

        @MainActor static func read(_ settings: [String: JSONValue]) -> Draft {
            var out = Draft()
            guard case .object(let b)? = settings["bnpl"] else { return out }
            if case .object(let t)? = b["tabby"] {
                out.tabby.enabled = Shop.plainBool(t["enabled"]) ?? false
                out.tabby.merchantCode = Shop.plainString(t["merchantCode"]) ?? ""
                out.tabby.currency = Shop.plainString(t["currency"]) ?? ""
            }
            if case .object(let t)? = b["tamara"] {
                out.tamara.enabled = Shop.plainBool(t["enabled"]) ?? false
                out.tamara.currency = Shop.plainString(t["currency"]) ?? ""
                out.tamara.country = Shop.plainString(t["country"]) ?? ""
            }
            return out
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var stored: Set<String> = []

    private var mayWrite: Bool { shop.lockAllows("settings", "edit") && shop.source.build != nil }

    var body: some View {
        Section(shop.words.callIt("mac.bnpl_section")) {
            Toggle(isOn: $draft.tabby.enabled) { Text(verbatim: "Tabby") }
            if draft.tabby.enabled {
                secret("bnpl.api_key", "tabby.apiKey", text: $draft.tabby.apiKey, forget: $draft.tabby.forgetKey)
                field("bnpl.merchant_code", text: $draft.tabby.merchantCode, prompt: "MERCHANT_CODE")
                field("bnpl.currency", text: $draft.tabby.currency, prompt: "SAR")
            }
            Toggle(isOn: $draft.tamara.enabled) { Text(verbatim: "Tamara") }
            if draft.tamara.enabled {
                secret("bnpl.api_key", "tamara.apiKey", text: $draft.tamara.apiKey, forget: $draft.tamara.forgetKey)
                secret("bnpl.notification_token", "tamara.notificationToken",
                       text: $draft.tamara.token, forget: $draft.tamara.forgetToken)
                field("bnpl.currency", text: $draft.tamara.currency, prompt: "SAR")
                field("bnpl.country", text: $draft.tamara.country, prompt: "SA")
            }
            Text(shop.words.callIt("mac.bnpl_note"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(shop.words.callIt("common.save")) { Task { await save() } }
                    .disabled(!mayWrite || draft == original)
                Spacer()
            }
        }
        .disabled(!mayWrite)
        .task(id: shop.settingsValue) { reload() }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        LabeledContent(shop.words.callIt(label)) {
            TextField("", text: text, prompt: Text(verbatim: prompt))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .autocorrectionDisabled()
        }
    }

    @ViewBuilder
    private func secret(_ label: String, _ path: String, text: Binding<String>, forget: Binding<Bool>) -> some View {
        LabeledContent(shop.words.callIt(label)) {
            SecureField("", text: text, prompt: Text(verbatim: stored.contains(path) ? "••••••••" : ""))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
        }
        if stored.contains(path) && text.wrappedValue.isEmpty {
            Toggle(shop.words.callIt("mac.bnpl_forget"), isOn: forget).font(.caption)
        }
    }

    private func reload() {
        original = Draft.read(shop.settingsDict)
        draft = original
        var have: Set<String> = []
        if case .object(let b)? = shop.settingsDict["bnpl"] {
            for (id, keys) in [("tabby", ["apiKey"]), ("tamara", ["apiKey", "notificationToken"])] {
                guard case .object(let row)? = b[id] else { continue }
                for k in keys where !(Shop.plainString(row[k]) ?? "").isEmpty { have.insert("\(id).\(k)") }
            }
        }
        stored = have
    }

    /// What the pane sends, the keys aside — also run over what it opened
    /// with, so a field nobody touched keeps its stored spelling.
    static func form(_ d: Draft) -> [String: JSONValue] {
        [
            "tabby": .object([
                "enabled": .bool(d.tabby.enabled),
                "merchantCode": .string(d.tabby.merchantCode),
                "currency": .string(d.tabby.currency),
            ]),
            "tamara": .object([
                "enabled": .bool(d.tamara.enabled),
                "currency": .string(d.tamara.currency),
                "country": .string(d.tamara.country),
            ]),
        ]
    }

    /// One secret, as the form carries it: absent keeps what is stored, an
    /// empty string is the forget switch, anything typed is sealed first.
    static func sealed(_ typed: String, forget: Bool,
                       seal: (String) async throws -> String) async throws -> JSONValue? {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return .string(try await seal(t)) }
        return forget ? .string("") : nil
    }

    private func save() async {
        guard let build = shop.source.build else {
            shop.settingsProblem = shop.words.callIt("mac.move_sample"); return
        }
        var bnpl = Self.form(draft)
        do {
            let seal: (String) async throws -> String = { try await Secrets.seal($0, for: build) }
            for (id, key, typed, forget) in [
                ("tabby", "apiKey", draft.tabby.apiKey, draft.tabby.forgetKey),
                ("tamara", "apiKey", draft.tamara.apiKey, draft.tamara.forgetKey),
                ("tamara", "notificationToken", draft.tamara.token, draft.tamara.forgetToken),
            ] {
                guard let value = try await Self.sealed(typed, forget: forget, seal: seal),
                      case .object(var row)? = bnpl[id] else { continue }
                row[key] = value
                bnpl[id] = .object(row)
            }
        } catch {
            shop.settingsProblem = shop.words.callIt("mac.bnpl_unsealed"); return
        }
        await shop.saveSettings(["bnpl": .object(bnpl)], opened: ["bnpl": .object(Self.form(original))])
        reload()
    }
}
