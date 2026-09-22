import SwiftUI
import KhaytCore

/// Telling this app how the shop sends email.
///
/// ── WHAT A MAC-ONLY SHOP COULD NOT DO ─────────────────────────────────────
///
/// Set email up at all. `EmailClient` has sent through SendGrid and Mailgun
/// for as long as it has existed, and `SmtpClient` speaks to a shop's own
/// relay now — but every one of those reads `settings.emailConfig`, and the
/// only screen in the world that wrote it was `renderer/settings.js`. So this
/// app could send email a shop had configured somewhere else and could not
/// configure any. Which is the same defect as a record an app can read and
/// cannot write, and it made the SMTP client underneath it unreachable for
/// anybody who had not already set one up in the other app.
///
/// ── THE TWO SECRETS ───────────────────────────────────────────────────────
///
/// `apiKey` and `smtpPassword` are both registered in
/// `lib/store-secret-paths.js`, so what belongs in the book is `__enc__` plus
/// OSCrypt under the book's own Keychain key — the same bytes Electron writes
/// and reads. Neither is ever shown: a stored one draws as dots, an empty
/// field means "keep it", and forgetting one is a deliberate switch. A secret
/// that cannot be sealed is REFUSED rather than written in the clear, because
/// this file syncs, backs up and exports.
struct EmailSettings: View {
    let shop: Shop

    /// The screen's own copy of `settings.emailConfig`.
    ///
    /// The secrets are NOT in here as stored values — only as what was typed.
    /// A draft that carried the ciphertext would put it in a `TextField`'s
    /// binding, and a revert would write it back as though it were freshly
    /// entered.
    struct Draft: Equatable {
        var provider = "none"
        var fromEmail = ""
        var fromName = ""
        var domain = ""
        var host = ""
        var port = "587"
        var user = ""
        var secure = false
        var triggers: Set<String> = []

        /// Typed this session, or empty.
        var apiKey = ""
        var password = ""
        /// Deliberately forgetting a stored secret.
        var clearApiKey = false
        var clearPassword = false

        @MainActor static func read(_ settings: [String: JSONValue]) -> Draft {
            guard case .object(let c)? = settings["emailConfig"] else { return Draft() }
            var out = Draft()
            out.provider = Shop.plainString(c["provider"]) ?? "none"
            out.fromEmail = Shop.plainString(c["fromEmail"]) ?? ""
            out.fromName = Shop.plainString(c["fromName"]) ?? ""
            out.domain = Shop.plainString(c["domain"]) ?? ""
            out.host = Shop.plainString(c["smtpHost"]) ?? ""
            out.port = String(EmailClient.smtpPort(c["smtpPort"]))
            out.user = Shop.plainString(c["smtpUser"]) ?? ""
            out.secure = Shop.plainBool(c["smtpSecure"]) ?? false
            if case .array(let list)? = c["triggers"] {
                out.triggers = Set(list.compactMap { Shop.plainString($0) })
            }
            return out
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var triggers: [KhaytEngine.EmailTrigger] = []
    @State private var stored = (apiKey: false, password: false)
    @State private var testing = false
    @State private var result: String?

    private var usesSmtp: Bool { draft.provider == "custom" }
    private var usesKey: Bool { draft.provider == "sendgrid" || draft.provider == "mailgun" }
    /// `none` sends nothing and `mailto` opens a compose window rather than
    /// sending; neither has anything to configure past this point.
    private var sends: Bool { usesSmtp || usesKey }

    var body: some View {
        Section(shop.words.callIt("set.notifications")) {
            row(shop.words.callIt("set.email_provider")) {
                Picker("", selection: $draft.provider) {
                    ForEach(Self.offered, id: \.self) { id in
                        Text(shop.words.callIt(Self.providerLabels[id] ?? id)).tag(id)
                    }
                }
                .labelsHidden().frame(width: 220)
            }

            if draft.provider == "mailto" {
                Text(shop.words.callIt("mac.email_mailto_hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if sends {
                row(shop.words.callIt("set.email_from")) {
                    TextField("", text: $draft.fromEmail, prompt: Text(verbatim: "orders@yourshop.com")).frame(width: 240)
                }
                row(shop.words.callIt("set.email_from_name")) {
                    TextField(shop.shopName, text: $draft.fromName).frame(width: 240)
                }
            }

            if usesKey {
                row(shop.words.callIt("set.email_api_key")) {
                    SecureField(stored.apiKey ? "••••••••" : "", text: $draft.apiKey)
                        .frame(width: 240)
                }
                if draft.provider == "mailgun" {
                    row(shop.words.callIt("set.email_domain")) {
                        TextField("", text: $draft.domain, prompt: Text(verbatim: "mg.yourshop.com")).frame(width: 240)
                    }
                }
                // AFTER the fields, not between them. Drawn straight under the
                // key it belongs to, it sat between "API key" and "Domain" and
                // read as though it were about the domain.
                if stored.apiKey && draft.apiKey.isEmpty {
                    Toggle(shop.words.callIt("mac.email_forget_key"), isOn: $draft.clearApiKey)
                        .font(.caption)
                }
            }

            if usesSmtp {
                row(shop.words.callIt("set.smtp_host")) {
                    TextField("", text: $draft.host, prompt: Text(verbatim: "smtp.yourshop.com")).frame(width: 240)
                }
                row(shop.words.callIt("set.smtp_port")) {
                    TextField("", text: $draft.port, prompt: Text(verbatim: "587")).frame(width: 90)
                }
                row(shop.words.callIt("set.smtp_user")) {
                    TextField("", text: $draft.user, prompt: Text(verbatim: "orders@yourshop.com")).frame(width: 240)
                }
                row(shop.words.callIt("set.smtp_pass")) {
                    SecureField(stored.password ? "••••••••" : "", text: $draft.password)
                        .frame(width: 240)
                }
                Toggle(shop.words.callIt("set.smtp_secure"), isOn: $draft.secure)
                if stored.password && draft.password.isEmpty {
                    Toggle(shop.words.callIt("mac.email_forget_pass"), isOn: $draft.clearPassword)
                        .font(.caption)
                }
                // WHICH PORT MEANS WHICH, said here rather than left to be
                // discovered by a send that fails. 465 is encrypted from the
                // first byte; 587 starts in the clear and upgrades, and this
                // app refuses to send a password if the upgrade is not offered.
                Text(shop.words.callIt("mac.smtp_ports"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // WHAT GETS EMAILED. Without a trigger switched on, everything
            // above is configured and nothing is ever sent — which reads as
            // email being broken rather than as nothing being asked for.
            //
            // `!triggers.isEmpty` as well as `sends`: the list is fetched from
            // the shared rule when the pane appears, and drawing the heading
            // before it arrives gives a shop "Send email when" with nothing
            // underneath — which is what the first render of this pane showed.
            if sends && !triggers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shop.words.callIt("set.email_triggers"))
                        .font(.callout.weight(.medium))
                    ForEach(triggers) { trigger in
                        Toggle(label(trigger), isOn: Binding(
                            get: { draft.triggers.contains(trigger.key) },
                            set: { on in
                                if on { draft.triggers.insert(trigger.key) }
                                else { draft.triggers.remove(trigger.key) }
                            }))
                    }
                    if draft.triggers.isEmpty {
                        Text(shop.words.callIt("mac.email_no_triggers"))
                            .font(.caption).foregroundStyle(Khayt.note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Button(shop.words.callIt("common.save")) { Task { await save() } }
                    .disabled(draft == original)
                if sends {
                    // Sent to the shop's OWN address, which is the only one it
                    // is entitled to test with — a test that mails a customer
                    // is not a test.
                    Button(shop.words.callIt("set.email_test")) { Task { await test() } }
                        .disabled(testing || draft != original)
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

    /// The providers this screen offers, in the order the other app lists them.
    ///
    /// Not `engine.emailProviders()` at draw time: a `Picker` cannot wait on an
    /// actor mid-body, and a list that arrives late draws an empty menu. The
    /// engine's list is what `providersMatchTheSharedList` checks this against.
    static let offered = ["none", "sendgrid", "mailgun", "custom", "mailto"]

    /// Their names, from the shared catalogue rather than written again here —
    /// the other app's email screen calls them exactly these things, and a shop
    /// running both should not have to work out that "Custom SMTP" and
    /// "Your own server" are the same choice.
    static let providerLabels = [
        "none": "set.smtp_none", "sendgrid": "set.smtp_sendgrid",
        "mailgun": "set.smtp_mailgun", "custom": "set.smtp_custom",
        "mailto": "set.smtp_mailto",
    ]

    private func label(_ trigger: KhaytEngine.EmailTrigger) -> String {
        // Translated when this app has a word for it, and the module's own
        // English when it does not — a trigger added there and not here draws
        // readably rather than as a raw key.
        let key = "mac.email_when_" + trigger.key
        let said = shop.words.callIt(key)
        return said == key ? trigger.label : said
    }

    private func reload() async {
        original = Draft.read(shop.settingsDict)
        draft = original
        result = nil
        if case .object(let c)? = shop.settingsDict["emailConfig"] {
            stored = (!(Shop.plainString(c["apiKey"]) ?? "").isEmpty,
                      !(Shop.plainString(c["smtpPassword"]) ?? "").isEmpty)
        } else {
            stored = (false, false)
        }
        triggers = (try? await shop.engine?.emailTriggers()) ?? []
    }

    private func save() async {
        var config: [String: JSONValue] = [
            "provider": .string(draft.provider),
            "fromEmail": .string(draft.fromEmail),
            "fromName": .string(draft.fromName),
            "domain": .string(draft.domain),
            "smtpHost": .string(draft.host),
            "smtpPort": .number(Double(EmailClient.smtpPort(.string(draft.port)))),
            "smtpUser": .string(draft.user),
            "smtpSecure": .bool(draft.secure),
            "triggers": .array(draft.triggers.sorted().map(JSONValue.string)),
        ]

        // ── THE SECRETS ARE SEALED HERE OR NOT WRITTEN AT ALL ─────────────
        //
        // Absent means "keep what is stored" — which is what a field showing
        // dots means to the person typing in it. Sending an empty string would
        // silently forget a key the shop never touched, so forgetting one is a
        // switch and nothing else.
        guard let build = shop.source.build else {
            shop.settingsProblem = shop.words.callIt("mac.move_sample"); return
        }
        func seal(_ typed: String, clear: Bool, into key: String) async -> Bool {
            let text = typed.trimmingCharacters(in: .whitespaces)
            if clear && text.isEmpty { config[key] = .string(""); return true }
            guard !text.isEmpty else { return true }
            do { config[key] = .string(try await Secrets.seal(text, for: build)); return true }
            catch {
                shop.settingsProblem = shop.words.callIt("mac.email_unsealed")
                return false
            }
        }
        guard await seal(draft.apiKey, clear: draft.clearApiKey, into: "apiKey") else { return }
        guard await seal(draft.password, clear: draft.clearPassword, into: "smtpPassword") else { return }

        await shop.saveSettings(["emailConfig": .object(config)])
        draft.apiKey = ""
        draft.password = ""
        draft.clearApiKey = false
        draft.clearPassword = false
        await reload()
    }

    /// Send one email to the shop's own address and say what happened.
    ///
    /// A settings screen that saves and says nothing leaves a shop to find out
    /// whether it works by finishing a real job — which is the moment a wrong
    /// password costs a customer their notification. Only offered once the
    /// draft is saved, because it sends through what is STORED: testing what
    /// is typed would need the secrets a second time, in the clear.
    private func test() async {
        guard let engine = shop.engine else { return }
        let to = Shop.plainString(shop.settingsDict["email"]) ?? ""
        guard !to.isEmpty else {
            result = shop.words.callIt("mac.email_no_shop_address"); return
        }
        testing = true
        defer { testing = false }
        result = nil
        do {
            var config: [String: JSONValue] = [:]
            if case .object(let c)? = shop.settingsDict["emailConfig"] { config = c }
            let key = try await Secrets.open(Shop.plainString(config["apiKey"]) ?? "",
                                             for: shop.source)
            let password = try await Secrets.open(Shop.plainString(config["smtpPassword"]) ?? "",
                                                  for: shop.source)
            let mail = OrderEmail(to: to,
                                  subject: shop.words.callIt("mac.email_test_subject"),
                                  html: "<p>" + shop.words.callIt("mac.email_test_body") + "</p>",
                                  provider: draft.provider)
            try await EmailClient.send(mail, apiKey: key, config: config,
                                       smtpPassword: password, engine: engine)
            result = "✓ " + shop.words.callIt("set.email_test_sent")
        } catch {
            // The provider's own words where there are any: "535 5.7.8
            // Authentication credentials invalid" tells a shop what to change
            // and "the test failed" does not.
            let why = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            result = shop.words.callIt("mac.email_test_failed") + " " + why
        }
    }
}
