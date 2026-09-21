import SwiftUI
import KhaytCore

/// Telling this app where to send the shop's Telegram messages.
///
/// ── WHAT A MAC-ONLY SHOP COULD NOT DO ─────────────────────────────────────
///
/// Set Telegram up. This app has SENT Telegram messages for as long as
/// `Telegram.swift` has existed — a job completed, a job put on hold, a printer
/// that stopped answering — and it read `settings.telegram` to do it, which
/// only `renderer/settings.js` could write. So a shop could use a bot somebody
/// had configured elsewhere and could configure none of its own.
///
/// The same defect as the email settings beside it, and found by asking the
/// same question: which settings does this app READ and never WRITE?
/// `lib/settings-edit.js` answers it in one screenful — every `out.X = s.X ||`
/// line is a setting the form path ignores.
///
/// ── THE TOKEN ─────────────────────────────────────────────────────────────
///
/// `settings.telegram.botToken` is a registered secret in
/// `lib/store-secret-paths.js`, so what belongs in the book is `__enc__` plus
/// OSCrypt under the book's own Keychain key. It is never shown: a stored one
/// draws as dots, an empty field means "keep it", and forgetting it is a
/// deliberate switch. A token that cannot be sealed is REFUSED rather than
/// written in the clear, because this file syncs, backs up and exports.
struct TelegramSettings: View {
    let shop: Shop

    struct Draft: Equatable {
        var chatId = ""
        var onComplete = false
        var onHold = false
        var onLowStock = false
        var printerError = true
        var printerOffline = true
        var printerStall = false

        /// Typed this session, or empty. The stored token is never in here —
        /// a draft holding the ciphertext would write it back on the next save
        /// as though it had been typed, sealing an already-sealed string.
        var token = ""
        var clearToken = false

        @MainActor static func read(_ settings: [String: JSONValue]) -> Draft {
            guard case .object(let t)? = settings["telegram"] else { return Draft() }
            var out = Draft()
            out.chatId = Shop.plainString(t["chatId"]) ?? ""
            out.onComplete = Shop.plainBool(t["notifyOnComplete"]) ?? false
            out.onHold = Shop.plainBool(t["notifyOnHold"]) ?? false
            out.onLowStock = Shop.plainBool(t["notifyOnLowStock"]) ?? false
            // The three printer alerts default ON when the key is absent,
            // which is what `lib/printer-alerts.js` assumes. Reading them as
            // `false` would draw switches off that are in fact on.
            out.printerError = Shop.plainBool(t["notifyPrinterError"]) ?? true
            out.printerOffline = Shop.plainBool(t["notifyPrinterOffline"]) ?? true
            out.printerStall = Shop.plainBool(t["notifyPrinterStall"]) ?? false
            return out
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var storedToken = false
    @State private var testing = false
    @State private var result: String?

    /// Nothing below the credentials is worth showing until there is somewhere
    /// to send to — a switch that cannot fire is a switch that misleads.
    private var addressed: Bool { storedToken || !draft.token.isEmpty }

    var body: some View {
        Section(shop.words.callIt("mac.tg_section")) {
            row(shop.words.callIt("mac.tg_token")) {
                SecureField(storedToken ? "••••••••" : "123456:ABC…", text: $draft.token)
                    .frame(width: 240)
            }
            row(shop.words.callIt("mac.tg_chat")) {
                TextField("-1001234567890", text: $draft.chatId).frame(width: 240)
            }
            Text(shop.words.callIt("tg.chat_id_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if storedToken && draft.token.isEmpty {
                Toggle(shop.words.callIt("mac.tg_forget"), isOn: $draft.clearToken)
                    .font(.caption)
            }

            if addressed && !draft.chatId.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shop.words.callIt("mac.tg_when"))
                        .font(.callout.weight(.medium))
                    Toggle(shop.words.callIt("mac.tg_on_complete"), isOn: $draft.onComplete)
                    Toggle(shop.words.callIt("mac.tg_on_hold"), isOn: $draft.onHold)
                    Toggle(shop.words.callIt("mac.tg_on_low_stock"), isOn: $draft.onLowStock)
                    Toggle(shop.words.callIt("mac.tg_printer_error"), isOn: $draft.printerError)
                    Toggle(shop.words.callIt("mac.tg_printer_offline"), isOn: $draft.printerOffline)
                    Toggle(shop.words.callIt("mac.tg_printer_stall"), isOn: $draft.printerStall)
                }
            }

            HStack {
                Button(shop.words.callIt("common.save")) { Task { await save() } }
                    .disabled(draft == original)
                Button(shop.words.callIt("mac.tg_test")) { Task { await test() } }
                    .disabled(testing || draft != original
                              || !storedToken || draft.chatId.isEmpty)
                if let result {
                    Text(result).font(.callout)
                        .foregroundStyle(result.hasPrefix("✓") ? Khayt.done : Khayt.attention)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
        .task(id: shop.settingsValue) { reload() }
    }

    private func reload() {
        original = Draft.read(shop.settingsDict)
        draft = original
        result = nil
        if case .object(let t)? = shop.settingsDict["telegram"] {
            storedToken = !(Shop.plainString(t["botToken"]) ?? "").isEmpty
        } else {
            storedToken = false
        }
    }

    private func save() async {
        var telegram: [String: JSONValue] = [
            "chatId": .string(draft.chatId),
            "notifyOnComplete": .bool(draft.onComplete),
            "notifyOnHold": .bool(draft.onHold),
            "notifyOnLowStock": .bool(draft.onLowStock),
            "notifyPrinterError": .bool(draft.printerError),
            "notifyPrinterOffline": .bool(draft.printerOffline),
            "notifyPrinterStall": .bool(draft.printerStall),
        ]
        guard let build = shop.source.build else {
            shop.settingsProblem = shop.words.callIt("mac.move_sample"); return
        }
        // SEALED HERE OR NOT WRITTEN. Absent means "keep what is stored", which
        // is what a field showing dots means; an empty string is the forget
        // switch and nothing else.
        let typed = draft.token.trimmingCharacters(in: .whitespaces)
        if draft.clearToken && typed.isEmpty {
            telegram["botToken"] = .string("")
        } else if !typed.isEmpty {
            do { telegram["botToken"] = .string(try await Secrets.seal(typed, for: build)) }
            catch {
                shop.settingsProblem = shop.words.callIt("mac.tg_unsealed"); return
            }
        }
        await shop.saveSettings(["telegram": .object(telegram)])
        draft.token = ""
        draft.clearToken = false
        reload()
    }

    /// Send one message to the shop's own chat and say what happened.
    ///
    /// Through what is STORED rather than what is typed — the token has to be
    /// opened from the book to be used, and a test that took the typed one
    /// would need it in the clear a second time. Offered only once the draft is
    /// saved, for the same reason.
    private func test() async {
        testing = true
        defer { testing = false }
        result = nil
        do {
            var telegram: [String: JSONValue] = [:]
            if case .object(let t)? = shop.settingsDict["telegram"] { telegram = t }
            let token = try await Secrets.open(Shop.plainString(telegram["botToken"]) ?? "",
                                               for: shop.source)
            try await Telegram.send(botToken: token,
                                    chatId: Shop.plainString(telegram["chatId"]) ?? "",
                                    message: shop.words.callIt("mac.tg_test_body"))
            result = "✓ " + shop.words.callIt("tg.test_sent")
        } catch let failure as Telegram.Failure {
            // Telegram's own words where there are any — "chat not found" tells
            // a shop what to change and "the test failed" does not.
            result = shop.words.callIt("tg.error") + " " + Shop.describe(failure)
        } catch let locked as Secrets.Failure {
            result = shop.words.callIt("tg.error") + " " + locked.description
        } catch {
            result = shop.words.callIt("tg.error") + " " + String(describing: error)
        }
    }
}
