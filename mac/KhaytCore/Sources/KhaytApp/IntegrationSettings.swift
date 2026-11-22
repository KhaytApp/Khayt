import SwiftUI
import KhaytCore

// Settings › Integrations: texts, outgoing webhooks, the signed event
// webhook, accounting sync and the email summary — the desktop's sections, in
// the fields the desktop writes, so a shop that set one up on either app finds
// it set up on the other.
//
// Each SAVES ITSELF, like the email and WhatsApp Business panes, for their
// reason: the secrets are sealed with the book's own Keychain key at the
// moment of saving and never held in a draft a revert could write back. A
// secret that cannot be sealed is REFUSED rather than written in the clear,
// because this file syncs, backs up and exports. An empty secret field keeps
// the stored one; "Forget" clears it.
//
// Every one answers to the operator lock as its neighbours do: a person
// without "settings: edit" reads these and changes nothing.

/// One secret field, the same three answers everywhere: absent keeps what is
/// stored, an empty string is the forget switch, anything typed is sealed.
@MainActor
enum SealedField {
    static func value(_ typed: String, forget: Bool, build: StoreReader.Build) async throws -> JSONValue? {
        try await BnplSettings.sealed(typed, forget: forget, seal: { try await Secrets.seal($0, for: build) })
    }

    static func stored(_ object: JSONValue?, _ key: String) -> Bool {
        guard case .object(let o)? = object else { return false }
        return !(Shop.plainString(o[key]) ?? "").isEmpty
    }
}

/// A labelled text box at the width the other panes use.
private struct FieldRow: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    var body: some View {
        LabeledContent(label) {
            TextField("", text: $text, prompt: Text(verbatim: prompt))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .autocorrectionDisabled()
        }
    }
}

/// A secret box, with its forget switch once one is stored.
private struct SecretRow: View {
    let shop: Shop
    let label: String
    @Binding var text: String
    @Binding var forget: Bool
    let stored: Bool
    var body: some View {
        LabeledContent(label) {
            SecureField("", text: $text, prompt: Text(verbatim: stored ? "••••••••" : ""))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
        }
        if stored && text.isEmpty {
            Toggle(shop.words.callIt("mac.bnpl_forget"), isOn: $forget).font(.caption)
        }
    }
}

/// What a test said, coloured by how it went.
private struct ResultLine: View {
    let text: String?
    var body: some View {
        if let text {
            Text(text).font(.callout)
                .foregroundStyle(text.hasPrefix("✓") ? Khayt.done : Khayt.attention)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Texts (SMS)

/// `settings.smsConfig` with a text provider: Twilio, Unifonic or the shop's
/// own webhook. The same object WhatsApp Business lives in (`provider:
/// "whatsapp_cloud"`), because a book has one provider — the desktop's rule.
struct SmsSettings: View {
    let shop: Shop

    static let providers = ["none", "twilio", "unifonic", "webhook"]

    struct Draft: Equatable {
        var provider = "none"
        var channel = "whatsapp"
        var accountSid = "", from = "", senderId = "", url = ""
        /// Typed this session, or empty — never the stored ciphertext.
        var authToken = "", appSid = "", secret = ""
        var forget: Set<String> = []

        @MainActor static func read(_ settings: [String: JSONValue]) -> Draft {
            var d = Draft()
            guard case .object(let c)? = settings["smsConfig"] else { return d }
            d.provider = Shop.plainString(c["provider"]) ?? "none"
            d.channel = Shop.plainString(c["channel"]) == "sms" ? "sms" : "whatsapp"
            d.accountSid = Shop.plainString(c["accountSid"]) ?? ""
            d.from = Shop.plainString(c["from"]) ?? ""
            d.senderId = Shop.plainString(c["senderId"]) ?? ""
            d.url = Shop.plainString(c["url"]) ?? ""
            return d
        }

        /// What the pane sends, secrets aside. The provider only when the
        /// shop changed it here: a book on WhatsApp Business opened in this
        /// pane and saved for its channel must not lose that provider.
        func form(opened: Draft) -> [String: JSONValue] {
            var out: [String: JSONValue] = [
                "channel": .string(channel), "accountSid": .string(accountSid),
                "from": .string(from), "senderId": .string(senderId), "url": .string(url),
            ]
            if provider != opened.provider { out["provider"] = .string(provider) }
            return out
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var stored: Set<String> = []
    @State private var result: String?
    @State private var testing = false

    private var mayWrite: Bool { shop.lockAllows("settings", "edit") && shop.source.build != nil }

    var body: some View {
        Section(shop.words.callIt("sms.title")) {
            Text(shop.words.callIt("mac.sms_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(shop.words.callIt("sms.provider"), selection: $draft.provider) {
                Text(shop.words.callIt("sms.none")).tag("none")
                Text(verbatim: "Twilio (SMS + WhatsApp)").tag("twilio")
                Text(verbatim: "Unifonic (SMS)").tag("unifonic")
                Text(shop.words.callIt("sms.webhook")).tag("webhook")
                if original.provider == "whatsapp_cloud" {
                    Text(shop.words.callIt("mac.wab_section")).tag("whatsapp_cloud")
                }
            }
            if original.provider == "whatsapp_cloud" && draft.provider != "whatsapp_cloud" {
                Text(shop.words.callIt("mac.sms_replaces_wab"))
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ["twilio", "unifonic", "webhook"].contains(draft.provider) {
                Picker(shop.words.callIt("sms.channel"), selection: $draft.channel) {
                    Text(shop.words.callIt("mac.whatsapp")).tag("whatsapp")
                    Text(verbatim: "SMS").tag("sms")
                }
            }
            switch draft.provider {
            case "twilio":
                FieldRow(label: "Account SID", text: $draft.accountSid, prompt: "AC…")
                SecretRow(shop: shop, label: "Auth Token", text: $draft.authToken,
                          forget: forget("authToken"), stored: stored.contains("authToken"))
                FieldRow(label: shop.words.callIt("sms.from"), text: $draft.from, prompt: "+1 555…")
            case "unifonic":
                SecretRow(shop: shop, label: "AppSid", text: $draft.appSid,
                          forget: forget("appSid"), stored: stored.contains("appSid"))
                FieldRow(label: shop.words.callIt("sms.sender"), text: $draft.senderId, prompt: "Acme")
            case "webhook":
                FieldRow(label: shop.words.callIt("sms.url"), text: $draft.url, prompt: "https://…")
                SecretRow(shop: shop, label: shop.words.callIt("sms.secret"), text: $draft.secret,
                          forget: forget("secret"), stored: stored.contains("secret"))
            default:
                EmptyView()
            }
            if let problem = invalid {
                Text(problem).font(.caption).foregroundStyle(Khayt.attention)
            }
            HStack {
                Button(shop.words.callIt("common.save")) { Task { await save() } }
                    .disabled(!mayWrite || draft == original || invalid != nil)
                if shop.smsProvider != nil {
                    Button(shop.words.callIt("sms.test")) {
                        testing = true
                        Task { result = await shop.testText(); testing = false }
                    }
                    .disabled(!mayWrite || testing || draft != original)
                }
                ResultLine(text: result)
                Spacer()
            }
        }
        .disabled(!mayWrite)
        .task(id: shop.settingsValue) { reload() }
    }

    /// Said before saving: the Mac sends a text webhook over https only.
    private var invalid: String? {
        guard draft.provider == "webhook" else { return nil }
        let u = draft.url.trimmingCharacters(in: .whitespaces).lowercased()
        return u.isEmpty || u.hasPrefix("https://") ? nil : shop.words.callIt("mac.sms_https_only")
    }

    private func forget(_ key: String) -> Binding<Bool> {
        Binding(get: { draft.forget.contains(key) },
                set: { if $0 { draft.forget.insert(key) } else { draft.forget.remove(key) } })
    }

    private func reload() {
        original = Draft.read(shop.settingsDict)
        draft = original
        stored = Set(["authToken", "appSid", "secret"].filter { SealedField.stored(shop.settingsDict["smsConfig"], $0) })
    }

    private func save() async {
        guard let build = shop.source.build else { shop.settingsProblem = shop.words.callIt("mac.move_sample"); return }
        var sms = draft.form(opened: original)
        do {
            for (key, typed) in [("authToken", draft.authToken), ("appSid", draft.appSid), ("secret", draft.secret)] {
                if let v = try await SealedField.value(typed, forget: draft.forget.contains(key), build: build) { sms[key] = v }
            }
        } catch {
            shop.settingsProblem = shop.words.callIt("mac.int_unsealed"); return
        }
        await shop.saveSettings(["smsConfig": .object(sms)], opened: ["smsConfig": .object(original.form(opened: original))])
        result = nil
        reload()
    }
}

// MARK: - Outgoing webhooks

/// `settings.webhooks`: the switch, the one signing secret, the
/// subscriptions (several addresses, each listening to the events it names)
/// and the delivery log with Resend. The desktop's screen shows the same
/// book one address per event (`KhaytWebhookBus.legacyEvents`).
struct WebhookSettings: View {
    let shop: Shop

    struct Sub: Equatable, Identifiable {
        var id: String
        var url = ""
        var events: Set<String> = []
        var enabled = true
        var isNew = false
        var gone = false
    }

    struct Draft: Equatable {
        var enabled = false
        var subs: [Sub] = []
        var secret = ""
        var forgetSecret = false

        @MainActor static func read(_ settings: [String: JSONValue]) -> Draft {
            var d = Draft()
            guard case .object(let wh)? = settings["webhooks"] else { return d }
            d.enabled = Shop.plainBool(wh["enabled"]) ?? false
            var rows: [JSONValue] = []
            if case .array(let subs)? = wh["subscriptions"], !subs.isEmpty { rows = subs }
            for row in rows {
                guard case .object(let s) = row, let id = Shop.plainString(s["id"]) else { continue }
                var events: Set<String> = []
                if case .array(let list)? = s["events"] { events = Set(list.compactMap { Shop.plainString($0) }) }
                d.subs.append(Sub(id: id, url: Shop.plainString(s["url"]) ?? "", events: events,
                                  enabled: Shop.plainBool(s["enabled"]) ?? true,
                                  gone: Shop.plainString(s["disabledReason"]) == "gone"))
            }
            // A book with only the legacy one-URL-per-event map: shown as the
            // subscriptions it migrates to, which is what the first save writes.
            if rows.isEmpty, case .object(let legacy)? = wh["events"] {
                var byUrl: [String: Set<String>] = [:]
                var order: [String] = []
                for (event, value) in legacy.sorted(by: { $0.key < $1.key }) {
                    let url = (Shop.plainString(value) ?? "").trimmingCharacters(in: .whitespaces)
                    guard !url.isEmpty else { continue }
                    if byUrl[url] == nil { order.append(url) }
                    byUrl[url, default: []].insert(event)
                }
                d.subs = order.map { Sub(id: Shop.uid("whs"), url: $0, events: byUrl[$0] ?? [], isNew: true) }
            }
            return d
        }

        func form() -> [String: JSONValue] {
            let subs: [JSONValue] = subs.map { s in
                var o: [String: JSONValue] = [
                    "id": .string(s.id), "url": .string(s.url.trimmingCharacters(in: .whitespaces)),
                    "events": .array(s.events.sorted().map(JSONValue.string)), "enabled": .bool(s.enabled),
                ]
                if s.isNew {
                    o["isNew"] = .bool(true)
                    o["createdAt"] = .string(ISO8601DateFormatter().string(from: Date()))
                }
                return .object(o)
            }
            return ["enabled": .bool(enabled), "subscriptions": .array(subs)]
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var storedSecret = false
    @State private var events: [String] = []
    @State private var result: String?
    @State private var busy = false

    private var mayWrite: Bool { shop.lockAllows("settings", "edit") && shop.source.build != nil }

    var body: some View {
        Section(shop.words.callIt("set.webhooks_title")) {
            Text(shop.words.callIt("set.webhooks_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(shop.words.callIt("whk.enabled"), isOn: $draft.enabled)
            SecretRow(shop: shop, label: shop.words.callIt("whk.secret"), text: $draft.secret,
                      forget: $draft.forgetSecret, stored: storedSecret)
            Text(shop.words.callIt("mac.hook_secret_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach($draft.subs.byID) { $sub in
                subscriptionRow($sub)
            }
            HStack {
                Button(shop.words.callIt("mac.hook_add")) {
                    draft.subs.append(Sub(id: Shop.uid("whs"), events: ["status_changed"], isNew: true))
                }
                Spacer()
            }
            if let problem = invalid {
                Text(problem).font(.caption).foregroundStyle(Khayt.attention)
            }
            HStack {
                Button(shop.words.callIt("common.save")) { Task { await save() } }
                    .disabled(!mayWrite || (draft == original) || invalid != nil)
                ResultLine(text: result)
                Spacer()
            }
            WebhookLogList(shop: shop, urls: Dictionary(uniqueKeysWithValues: original.subs.map { ($0.id, $0.url) }),
                           result: $result)
        }
        .disabled(!mayWrite)
        .task(id: shop.settingsValue) { await reload() }
    }

    @ViewBuilder
    private func subscriptionRow(_ sub: Binding<Sub>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("", text: sub.url, prompt: Text(verbatim: "https://hooks.zapier.com/…"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Toggle(shop.words.callIt("mac.hook_on"), isOn: sub.enabled)
                    .toggleStyle(.switch).controlSize(.small)
            }
            if sub.wrappedValue.gone && !sub.wrappedValue.enabled {
                Text(shop.words.callIt("mac.hook_gone")).font(.caption).foregroundStyle(Khayt.attention)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(events, id: \.self) { event in
                    Toggle(shop.words.callIt("mac.hook_ev_" + event, fallback: event), isOn: Binding(
                        get: { sub.wrappedValue.events.contains(event) },
                        set: { on in
                            if on { sub.wrappedValue.events.insert(event) } else { sub.wrappedValue.events.remove(event) }
                        }))
                    .toggleStyle(.checkbox).font(.caption)
                }
            }
            HStack {
                Button(shop.words.callIt("whk.test")) {
                    busy = true
                    let url = sub.wrappedValue.url
                    Task { result = await shop.testWebhook(url: url); busy = false }
                }
                .disabled(busy || draft != original || !sub.wrappedValue.url.lowercased().hasPrefix("https://"))
                Button(shop.words.callIt("mac.hook_remove"), role: .destructive) {
                    let id = sub.wrappedValue.id
                    draft.subs.removeAll { $0.id == id }
                }
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var invalid: String? {
        for s in draft.subs {
            let u = s.url.trimmingCharacters(in: .whitespaces).lowercased()
            if !u.hasPrefix("https://") || u.count <= "https://".count { return shop.words.callIt("mac.hook_bad_url") }
            if s.events.isEmpty { return shop.words.callIt("mac.hook_no_events") }
        }
        return nil
    }

    private func reload() async {
        original = Draft.read(shop.settingsDict)
        draft = original
        storedSecret = SealedField.stored(shop.settingsDict["webhooks"], "secret")
        if events.isEmpty, let list = try? await shop.engine?.webhookEvents() { events = list }
    }

    private func save() async {
        guard let build = shop.source.build else { shop.settingsProblem = shop.words.callIt("mac.move_sample"); return }
        var wh = draft.form()
        do {
            if let v = try await SealedField.value(draft.secret, forget: draft.forgetSecret, build: build) { wh["secret"] = v }
        } catch {
            shop.settingsProblem = shop.words.callIt("mac.int_unsealed"); return
        }
        await shop.saveSettings(["webhooks": .object(wh)], opened: ["webhooks": .object(original.form())])
        result = nil
        await reload()
    }
}

/// The last deliveries, newest first, each with Resend.
private struct WebhookLogList: View {
    let shop: Shop
    let urls: [String: String]
    @Binding var result: String?
    @State private var resending: String?

    var body: some View {
        let lines = Array(shop.webhookLog.prefix(20))
        VStack(alignment: .leading, spacing: 4) {
            Text(shop.words.callIt("mac.hook_log")).font(.callout.weight(.medium))
            if lines.isEmpty {
                Text(shop.words.callIt("mac.hook_log_empty")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(shop.words.callIt("mac.hook_ev_" + line.event, fallback: line.event)
                             + " · " + where_(line))
                            .font(.caption)
                        Text(said(line)).font(.caption2)
                            .foregroundStyle(line.status == "ok" ? Khayt.done
                                             : line.status == "retrying" ? Color.secondary : Khayt.attention)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button(shop.words.callIt("mac.hook_resend")) {
                        resending = line.id
                        Task { result = await shop.resendWebhook(line); resending = nil }
                    }
                    .controlSize(.small)
                    .disabled(resending != nil)
                }
            }
        }
    }

    /// The host only: a webhook URL usually carries a token in its path.
    private func where_(_ line: Shop.WebhookLogLine) -> String {
        if line.subscriptionId.hasPrefix("event:") { return shop.words.callIt("ewh.title") }
        guard let u = urls[line.subscriptionId], let host = URL(string: u)?.host else { return "—" }
        return host
    }

    private func said(_ line: Shop.WebhookLogLine) -> String {
        var parts = [shop.words.callIt("mac.hook_status_" + line.status, fallback: line.status)]
        if let code = line.httpStatus { parts.append("HTTP \(code)") }
        if line.attempts > 1 { parts.append(shop.words.callIt("mac.hook_attempts", ["n": .string(String(line.attempts))])) }
        if let e = line.error, !e.isEmpty, line.status != "ok" { parts.append(e) }
        if !line.at.isEmpty { parts.append(Calendar.localDay(ofInstant: line.at)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The signed event webhook

/// `settings.eventWebhooks`: one https endpoint, its secret, and a switch per
/// event (`created`, `status`, `paid`) that defaults on.
struct EventWebhookSettings: View {
    let shop: Shop
    static let events = ["created", "status", "paid"]

    struct Draft: Equatable {
        var enabled = false
        var url = ""
        var on: [String: Bool] = [:]
        var secret = ""
        var forget = false

        @MainActor static func read(_ settings: [String: JSONValue]) -> Draft {
            var d = Draft()
            guard case .object(let w)? = settings["eventWebhooks"] else { return d }
            d.enabled = Shop.plainBool(w["enabled"]) ?? false
            d.url = Shop.plainString(w["url"]) ?? ""
            if case .object(let ev)? = w["events"] {
                for k in EventWebhookSettings.events { if case .bool(false)? = ev[k] { d.on[k] = false } }
            }
            return d
        }

        func isOn(_ k: String) -> Bool { on[k] ?? true }

        func form() -> [String: JSONValue] {
            ["enabled": .bool(enabled), "url": .string(url),
             "events": .object(Dictionary(uniqueKeysWithValues: EventWebhookSettings.events.map { ($0, JSONValue.bool(isOn($0))) }))]
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var stored = false
    @State private var result: String?
    @State private var testing = false

    private var mayWrite: Bool { shop.lockAllows("settings", "edit") && shop.source.build != nil }

    var body: some View {
        Section(shop.words.callIt("ewh.title")) {
            Toggle(shop.words.callIt("ewh.enabled"), isOn: $draft.enabled)
            FieldRow(label: shop.words.callIt("ewh.url"), text: $draft.url, prompt: "https://api.example.com/khayt/webhook")
            SecretRow(shop: shop, label: shop.words.callIt("ewh.secret"), text: $draft.secret,
                      forget: $draft.forget, stored: stored)
            Text(shop.words.callIt("ewh.events")).font(.callout.weight(.medium))
            ForEach(Self.events, id: \.self) { k in
                Toggle(shop.words.callIt("ewh.ev_" + k), isOn: Binding(
                    get: { draft.isOn(k) }, set: { draft.on[k] = $0 }))
                    .toggleStyle(.checkbox)
            }
            if !draft.url.isEmpty && !draft.url.lowercased().hasPrefix("https://") {
                Text(shop.words.callIt("ewh.enter_url")).font(.caption).foregroundStyle(Khayt.attention)
            }
            HStack {
                Button(shop.words.callIt("common.save")) { Task { await save() } }
                    .disabled(!mayWrite || draft == original
                              || (!draft.url.isEmpty && !draft.url.lowercased().hasPrefix("https://")))
                Button(shop.words.callIt("ewh.test")) {
                    testing = true
                    Task { result = await shop.testEventWebhook(); testing = false }
                }
                .disabled(!mayWrite || testing || draft != original || original.url.isEmpty)
                ResultLine(text: result)
                Spacer()
            }
        }
        .disabled(!mayWrite)
        .task(id: shop.settingsValue) { reload() }
    }

    private func reload() {
        original = Draft.read(shop.settingsDict)
        draft = original
        stored = SealedField.stored(shop.settingsDict["eventWebhooks"], "secret")
    }

    private func save() async {
        guard let build = shop.source.build else { shop.settingsProblem = shop.words.callIt("mac.move_sample"); return }
        var w = draft.form()
        do {
            if let v = try await SealedField.value(draft.secret, forget: draft.forget, build: build) { w["secret"] = v }
        } catch {
            shop.settingsProblem = shop.words.callIt("mac.int_unsealed"); return
        }
        await shop.saveSettings(["eventWebhooks": .object(w)], opened: ["eventWebhooks": .object(original.form())])
        result = nil
        reload()
    }
}

// MARK: - Accounting sync

/// `settings.accountingSync`: where paid invoices are pushed, in which
/// format, with which account and tax codes, and whether to push the moment
/// an invoice is paid. Failed pushes are listed and tried again.
struct AccountingSyncSettings: View {
    let shop: Shop
    static let formats: [(String, String?)] = [("generic", nil), ("quickbooks", "QuickBooks"), ("xero", "Xero"),
                                               ("zoho", "Zoho Books"), ("wafeq", "Wafeq"), ("daftra", "Daftra")]

    struct Draft: Equatable {
        var enabled = false
        var format = "generic"
        var webhookUrl = ""
        var pushOnPaid = true
        var salesAccount = ""
        var taxCode = ""
        var secret = ""
        var forget = false

        @MainActor static func read(_ settings: [String: JSONValue]) -> Draft {
            var d = Draft()
            guard case .object(let c)? = settings["accountingSync"] else { return d }
            d.enabled = Shop.plainBool(c["enabled"]) ?? false
            d.format = Shop.plainString(c["format"]) ?? "generic"
            d.webhookUrl = Shop.plainString(c["webhookUrl"]) ?? ""
            d.pushOnPaid = Shop.plainBool(c["pushOnPaid"]) ?? true
            d.salesAccount = Shop.plainString(c["salesAccount"]) ?? ""
            d.taxCode = Shop.plainString(c["taxCode"]) ?? ""
            return d
        }

        func form() -> [String: JSONValue] {
            ["enabled": .bool(enabled), "format": .string(format), "webhookUrl": .string(webhookUrl),
             "pushOnPaid": .bool(pushOnPaid), "salesAccount": .string(salesAccount), "taxCode": .string(taxCode)]
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var stored = false
    @State private var result: String?
    @State private var busy = false

    private var mayWrite: Bool { shop.lockAllows("settings", "edit") && shop.source.build != nil }
    private var badUrl: Bool {
        let u = draft.webhookUrl.trimmingCharacters(in: .whitespaces).lowercased()
        return !u.isEmpty && !u.hasPrefix("https://")
    }

    var body: some View {
        Section(shop.words.callIt("acct.title")) {
            Text(shop.words.callIt("acct.intro"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(shop.words.callIt("acct.enable"), isOn: $draft.enabled)
            Picker(shop.words.callIt("acct.format"), selection: $draft.format) {
                ForEach(Self.formats, id: \.0) { f in
                    Text(verbatim: f.1 ?? shop.words.callIt("acct.fmt_generic")).tag(f.0)
                }
            }
            FieldRow(label: shop.words.callIt("acct.url"), text: $draft.webhookUrl, prompt: "https://hooks…/khayt")
            SecretRow(shop: shop, label: shop.words.callIt("acct.secret"), text: $draft.secret,
                      forget: $draft.forget, stored: stored)
            FieldRow(label: shop.words.callIt("acct.sales_account"), text: $draft.salesAccount,
                     prompt: shop.words.callIt("acct.sales_account_ph"))
            FieldRow(label: shop.words.callIt("acct.tax_code"), text: $draft.taxCode,
                     prompt: shop.words.callIt("acct.tax_code_ph"))
            Text(shop.words.callIt("acct.mapping_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(shop.words.callIt("acct.push_on_paid"), isOn: $draft.pushOnPaid)
            if badUrl {
                Text(shop.words.callIt("mac.acct_https_only")).font(.caption).foregroundStyle(Khayt.attention)
            }
            HStack {
                Button(shop.words.callIt("common.save")) { Task { await save() } }
                    .disabled(!mayWrite || draft == original || badUrl)
                Button(shop.words.callIt("acct.test")) {
                    busy = true
                    Task { result = await shop.testAccountingSync(); busy = false }
                }
                .disabled(!mayWrite || busy || draft != original || original.webhookUrl.isEmpty)
                ResultLine(text: result)
                Spacer()
            }
            let stuck = shop.stuckAccountingPushes
            if original.enabled && !stuck.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shop.words.callIt("mac.acct_stuck", ["n": .string(String(stuck.count))]))
                        .font(.callout.weight(.medium))
                    ForEach(stuck.prefix(8)) { invoice in
                        Text(verbatim: "\u{2068}" + invoice.id + "\u{2069} · " + invoice.error)
                            .font(.caption).foregroundStyle(Khayt.attention).lineLimit(2)
                    }
                    Button(shop.words.callIt("mac.acct_retry")) {
                        busy = true
                        Task { await shop.retryFailedAccountingPushes(); busy = false }
                    }
                    .controlSize(.small)
                    .disabled(busy)
                }
            }
        }
        .disabled(!mayWrite)
        .task(id: shop.settingsValue) { reload() }
    }

    private func reload() {
        original = Draft.read(shop.settingsDict)
        draft = original
        stored = SealedField.stored(shop.settingsDict["accountingSync"], "secret")
    }

    private func save() async {
        guard let build = shop.source.build else { shop.settingsProblem = shop.words.callIt("mac.move_sample"); return }
        var c = draft.form()
        do {
            if let v = try await SealedField.value(draft.secret, forget: draft.forget, build: build) { c["secret"] = v }
        } catch {
            shop.settingsProblem = shop.words.callIt("mac.int_unsealed"); return
        }
        await shop.saveSettings(["accountingSync": .object(c)], opened: ["accountingSync": .object(original.form())])
        result = nil
        reload()
    }
}

// MARK: - The email summary

/// Which summary the shop gets (Turki, Nov 2026: it is the shop's choice):
/// the KPI email this Mac sends on the shop's own schedule through its own
/// mail provider (`settings.emailDigest`, the desktop's), Khayt Cloud's
/// weekly owner digest (the cloud's own switch), both, or neither. Each half
/// keeps its switch where it already lives; this only offers the four.
struct EmailSummarySettings: View {
    let shop: Shop

    struct Local: Equatable {
        var enabled = false
        var frequency = "daily"
        var hour = 8
        var weekday = 1
        var monthday = 1
        var recipient = ""

        @MainActor static func read(_ settings: [String: JSONValue]) -> Local {
            var d = Local()
            guard case .object(let g)? = settings["emailDigest"] else { return d }
            d.enabled = Shop.plainBool(g["enabled"]) ?? false
            let f = Shop.plainString(g["frequency"]) ?? "daily"
            d.frequency = ["daily", "weekly", "monthly"].contains(f) ? f : "daily"
            d.hour = Int(Shop.plainNumber(g["hour"]) ?? 8)
            d.weekday = Int(Shop.plainNumber(g["weekday"]) ?? 1)
            d.monthday = Int(Shop.plainNumber(g["monthday"]) ?? 1)
            d.recipient = Shop.plainString(g["recipientEmail"]) ?? ""
            return d
        }

        func form() -> [String: JSONValue] {
            ["enabled": .bool(enabled), "frequency": .string(frequency), "hour": .number(Double(hour)),
             "weekday": .number(Double(weekday)), "monthday": .number(Double(monthday)),
             "recipientEmail": .string(recipient)]
        }
    }

    @State private var local = Local()
    @State private var original = Local()
    @State private var cloud: CloudCheckout.Digest?
    /// Why the cloud's half could not be read or saved, in a sentence: not
    /// the owner (403 `owner-only`), no owner account (409 `no-account`).
    @State private var cloudProblem: String?
    @State private var cloudWanted = false
    @State private var result: String?
    @State private var busy = false

    private var mayWrite: Bool { shop.lockAllows("settings", "edit") && shop.source.build != nil }
    /// The cloud's half can be chosen only by the owner, signed in.
    private var cloudChoosable: Bool { shop.cloudIsOwner && cloud != nil }
    /// The cloud stores the choice but sends nothing yet (`serverEnabled`
    /// false): the option says so rather than looking active.
    private var cloudLive: Bool { cloud?.serverEnabled == true }

    private var choice: Binding<String> {
        Binding(get: {
            switch (local.enabled, cloudChoosable && cloudWanted) {
            case (true, true): "both"
            case (true, false): "local"
            case (false, true): "cloud"
            default: "none"
            }
        }, set: { pick in
            local.enabled = pick == "local" || pick == "both"
            if cloudChoosable { cloudWanted = pick == "cloud" || pick == "both" }
        })
    }

    private var dirty: Bool { local != original || (cloudChoosable && cloudWanted != (cloud?.enabled ?? false)) }

    var body: some View {
        Section(shop.words.callIt("mac.summary_title")) {
            Text(shop.words.callIt("mac.summary_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(shop.words.callIt("mac.summary_choice"), selection: choice) {
                Text(shop.words.callIt("mac.summary_none")).tag("none")
                Text(shop.words.callIt("mac.summary_local")).tag("local")
                if cloudChoosable {
                    Text(shop.words.callIt(cloudLive ? "mac.summary_cloud" : "mac.summary_cloud_soon")).tag("cloud")
                    Text(shop.words.callIt(cloudLive ? "mac.summary_both" : "mac.summary_both_soon")).tag("both")
                }
            }
            if let cloudProblem {
                Text(cloudProblem).font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !cloudChoosable {
                Text(shop.words.callIt("mac.summary_cloud_needs"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !cloudLive {
                // Said whatever is picked: the cloud's summary is not sent by
                // anyone yet, and an option that looked active would be a
                // promise the cloud is not keeping.
                Text(shop.words.callIt("mac.summary_cloud_not_yet")).font(.caption)
                    .foregroundStyle(cloudWanted ? Khayt.attention : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let week = cloud?.lastSentWeek, !week.isEmpty, cloudWanted {
                Text(shop.words.callIt("mac.digest_last", ["day": .string(Calendar.localDay(ofInstant: week))]))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if local.enabled {
                Picker(shop.words.callIt("digest.frequency"), selection: $local.frequency) {
                    Text(shop.words.callIt("digest.daily")).tag("daily")
                    Text(shop.words.callIt("digest.weekly")).tag("weekly")
                    Text(shop.words.callIt("digest.monthly")).tag("monthly")
                }
                .pickerStyle(.segmented)
                Picker(shop.words.callIt("digest.send_hour"), selection: $local.hour) {
                    ForEach(0..<24, id: \.self) { h in Text(verbatim: String(format: "%02d:00", h)).tag(h) }
                }
                if local.frequency == "weekly" {
                    Picker(shop.words.callIt("digest.weekday"), selection: $local.weekday) {
                        ForEach(Array(weekdays.enumerated()), id: \.offset) { day in
                            Text(verbatim: day.element).tag(day.offset)
                        }
                    }
                }
                if local.frequency == "monthly" {
                    Picker(shop.words.callIt("digest.monthday"), selection: $local.monthday) {
                        ForEach(1...28, id: \.self) { d in Text(verbatim: String(d)).tag(d) }
                    }
                }
                FieldRow(label: shop.words.callIt("digest.recipient"), text: $local.recipient,
                         prompt: Shop.plainString(shop.settingsDict["email"]) ?? "")
                if let sent = lastLocal {
                    Text(shop.words.callIt("mac.summary_last_local", ["period": .string(sent)]))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(shop.words.callIt("common.save")) { Task { await save() } }
                    .disabled(!mayWrite || !dirty || busy)
                if original.enabled {
                    Button(shop.words.callIt("digest.send_test")) {
                        busy = true
                        let to = local.recipient
                        Task { result = await shop.sendDigestTest(to: to); busy = false }
                    }
                    .disabled(!mayWrite || busy || dirty)
                }
                ResultLine(text: result)
                Spacer()
            }
        }
        .disabled(!mayWrite)
        .task(id: shop.settingsValue) { reloadLocal() }
        .task { take(await shop.cloudDigestState()) }
    }

    /// Sunday first, as the desktop's picker and the stored number are.
    private var weekdays: [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = shop.words.locale
        return cal.weekdaySymbols
    }

    private var lastLocal: String? {
        guard case .object(let g)? = shop.settingsDict["emailDigest"],
              let s = Shop.plainString(g["lastSentDate"]), !s.isEmpty else { return nil }
        return "\u{2068}" + s + "\u{2069}"
    }

    private func reloadLocal() {
        original = Local.read(shop.settingsDict)
        local = original
    }

    private func save() async {
        busy = true
        defer { busy = false }
        result = nil
        if local != original {
            await shop.saveSettings(["emailDigest": .object(local.form())], opened: ["emailDigest": .object(original.form())])
            reloadLocal()
        }
        if cloudChoosable, cloudWanted != (cloud?.enabled ?? false) {
            let asked = cloudWanted
            let answer = await shop.cloudDigestState(setting: asked)
            if case .ok = answer { take(answer) } else {
                // Refused: the switch goes back to what the cloud holds.
                if case .refused(let why) = answer { result = "✗ " + why }
                cloudWanted = cloud?.enabled ?? false
            }
        }
    }

    private func take(_ state: Shop.CloudDigestState) {
        switch state {
        case .ok(let d): cloud = d; cloudWanted = d.enabled; cloudProblem = nil
        case .refused(let why): cloud = nil; cloudWanted = false; cloudProblem = why
        case .unavailable: cloud = nil; cloudWanted = false; cloudProblem = nil
        }
    }
}
