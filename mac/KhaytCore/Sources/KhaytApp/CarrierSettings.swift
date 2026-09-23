import SwiftUI
import KhaytCore

/// SMSA, Aramex and Saudi Post: which the shop uses, and the secret each one
/// signs its status updates with.
///
/// The Electron Shipping section was the only place these were ever set, so a
/// Mac shop's Ship sheet could offer nothing but Manual and a carrier's status
/// webhook had no secret to be checked against. It saves ITSELF, like the
/// Telegram section beside it, and for the same reason: two of its fields are
/// sealed secrets, encrypted at the moment of saving and never held in a draft
/// a revert could write back.
///
/// The API key and account number are kept because the other app creates
/// labels with them, and a Mac save must not lose them; this app does not call
/// a carrier's API itself, and the hint says so.
struct CarrierSettings: View {
    let shop: Shop

    struct Row: Equatable {
        var enabled = false
        var accountNumber = ""
        /// Typed this session, or empty — never the stored ciphertext.
        var apiKey = ""
        var webhookSecret = ""
    }

    @State private var carriers: [KhaytEngine.CarrierChoice] = []
    @State private var draft: [String: Row] = [:]
    @State private var original: [String: Row] = [:]
    /// Which secrets the book already holds, so a field can say "unchanged".
    @State private var stored: Set<String> = []

    var body: some View {
        Section(shop.words.callIt("ship.section")) {
            Text(shop.words.callIt("mac.carriers_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(carriers.filter { $0.id != "manual" }) { carrier in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(carrier.name(shop.words.language), isOn: binding(carrier.id, \.enabled))
                    if draft[carrier.id]?.enabled == true {
                        LabeledContent(shop.words.callIt("ship.account")) {
                            TextField("", text: binding(carrier.id, \.accountNumber))
                                .textFieldStyle(.roundedBorder).frame(width: 220)
                        }
                        LabeledContent(shop.words.callIt("ship.api_key")) {
                            SecureField(placeholder(carrier.id, "apiKey"), text: binding(carrier.id, \.apiKey))
                                .textFieldStyle(.roundedBorder).frame(width: 220)
                        }
                        LabeledContent(shop.words.callIt("ship.webhook_secret")) {
                            SecureField(placeholder(carrier.id, "webhookSecret"),
                                        text: binding(carrier.id, \.webhookSecret))
                                .textFieldStyle(.roundedBorder).frame(width: 220)
                        }
                        // Where the carrier sends its updates: this Mac's own
                        // address while the Online server runs. Selectable,
                        // because it is pasted into the carrier's dashboard.
                        if let base = shop.lanURL {
                            LabeledContent(shop.words.callIt("ship.webhook_url")) {
                                Text(base + "api/webhook/" + carrier.id)
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            HStack {
                Button(shop.words.callIt("common.save")) { Task { await save() } }
                    .disabled(draft == original || !shop.canMoveJobs)
                Spacer()
            }
        }
        .task(id: shop.settingsValue) { await reload() }
    }

    private func placeholder(_ id: String, _ key: String) -> String {
        stored.contains(id + "." + key) ? shop.words.callIt("common.secret_unchanged") : ""
    }

    private func binding<T>(_ id: String, _ path: WritableKeyPath<Row, T>) -> Binding<T> {
        Binding(get: { (draft[id] ?? Row())[keyPath: path] },
                set: { var row = draft[id] ?? Row(); row[keyPath: path] = $0; draft[id] = row })
    }

    private func reload() async {
        if carriers.isEmpty, let engine = shop.engine { carriers = (try? await engine.allCarriers()) ?? [] }
        var rows: [String: Row] = [:]
        var held: Set<String> = []
        if case .object(let map)? = shop.settingsDict["shipping"] {
            for (id, value) in map {
                guard case .object(let cfg) = value else { continue }
                rows[id] = Row(enabled: Shop.plainBool(cfg["enabled"]) ?? false,
                               accountNumber: Shop.plainString(cfg["accountNumber"]) ?? "")
                for key in ["apiKey", "webhookSecret"] where !(Shop.plainString(cfg[key]) ?? "").isEmpty {
                    held.insert(id + "." + key)
                }
            }
        }
        original = rows
        draft = rows
        stored = held
    }

    private func save() async {
        guard let build = shop.source.build else {
            shop.settingsProblem = shop.words.callIt("mac.move_sample"); return
        }
        var form: [String: JSONValue] = [:]
        for (id, row) in draft where row != original[id] ?? Row() {
            var cfg: [String: JSONValue] = ["enabled": .bool(row.enabled),
                                            "accountNumber": .string(row.accountNumber)]
            // SEALED HERE OR NOT WRITTEN. Absent keeps what is stored, which is
            // what a field showing "unchanged" means.
            for (key, typed) in [("apiKey", row.apiKey), ("webhookSecret", row.webhookSecret)] {
                let secret = typed.trimmingCharacters(in: .whitespaces)
                guard !secret.isEmpty else { continue }
                do { cfg[key] = .string(try await Secrets.seal(secret, for: build)) }
                catch { shop.settingsProblem = String(describing: error); return }
            }
            form[id] = .object(cfg)
        }
        guard !form.isEmpty else { return }
        await shop.saveSettings(["shipping": .object(form)])
        await reload()
    }
}
