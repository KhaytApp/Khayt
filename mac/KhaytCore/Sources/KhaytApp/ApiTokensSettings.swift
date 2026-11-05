import SwiftUI
import AppKit
import KhaytCore

/// The words the API token section needed and Khayt did not have. Everything
/// the Electron card says is borrowed from it (`api.*` in `Words.borrowed`).
enum ApiTokenWords {
    nonisolated static let table: [String: [String: String]] = [
        "mac.api_where": ["en": "Scripts reach this Mac\u{2019}s LAN server at {url} and send the token as \u{201C}Authorization: Bearer\u{201D}. The server has to be on.",
                          "ar": "تصل البرامج إلى خادم الشبكة المحلية على هذا الماك عبر {url} وترسل الرمز في الترويسة \u{201C}Authorization: Bearer\u{201D}. يجب أن يكون الخادم قيد التشغيل."],
        "mac.api_scopes": ["en": "Scopes", "ar": "الصلاحيات"],
        "mac.api_owner_only": ["en": "Only the owner can create or revoke API tokens.",
                               "ar": "المالك وحده يستطيع إنشاء رموز الواجهة البرمجية أو إلغاءها."],
    ]
}

/// One token as the owner sees it — never its hash (`redactTokens`).
struct ApiTokenRow: Identifiable, Equatable {
    let id: String
    let label: String
    let scopes: [String]
    let createdAt: String

    /// The rows of `settings.lanApi.apiTokens`, through the shared redaction.
    static func rows(_ redacted: [JSONValue]) -> [ApiTokenRow] {
        redacted.compactMap { row in
            guard case .object(let o) = row, case .string(let id)? = o["id"] else { return nil }
            var label = ""
            if case .string(let l)? = o["label"] { label = l }
            var scopes: [String] = []
            if case .array(let list)? = o["scopes"] {
                for case .string(let s) in list { scopes.append(s) }
            }
            var created = ""
            if case .string(let c)? = o["createdAt"] { created = String(c.split(separator: "T").first ?? "") }
            return ApiTokenRow(id: id, label: label, scopes: scopes, createdAt: created)
        }
    }
}

extension Shop {
    /// Whoever is at this Mac may make and revoke tokens: the owner. A token
    /// opens the book to whatever holds it, which is a security decision, not
    /// a setting (`lib/rbac.js`: only the owner has `security`).
    var mayManageApiTokens: Bool { lockAllows("security", "edit") }

    /// Mint a token and store its RECORD — the hash, never the token. Returns
    /// the plaintext, to be shown once; nil when refused or not written.
    func mintApiToken(label: String, scopes: [String]) async -> String? {
        apiTokenProblem = nil
        guard permitted("security", "edit") else { apiTokenProblem = moveProblem; return nil }
        guard let build = source.build else { apiTokenProblem = words.callIt("mac.settings_sample"); return nil }
        guard let engine else { apiTokenProblem = words.callIt("mac.move_no_engine"); return nil }
        let known = (try? await engine.apiTokenScopes()) ?? []
        let chosen = scopes.filter { known.contains($0) }
        guard !chosen.isEmpty else { apiTokenProblem = words.callIt("api.need_scope"); return nil }
        let minted = ApiTokens.mint(label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                                    scopes: chosen, known: known, now: StoreWriter.iso(Date()))
        let record = minted.record
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                Self.editApiTokens(&root) { $0.append(.object(record)) }
            }
        } catch {
            apiTokenProblem = ErrorText.plain(error)
            return nil
        }
        await load(source)
        return minted.token
    }

    /// Revoke: the record goes, and the next request carrying the token is 401.
    func revokeApiToken(_ id: String) async -> Bool {
        apiTokenProblem = nil
        guard permitted("security", "edit") else { apiTokenProblem = moveProblem; return false }
        guard let build = source.build else { apiTokenProblem = words.callIt("mac.settings_sample"); return false }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                Self.editApiTokens(&root) { list in
                    list.removeAll { if case .object(let o) = $0 { return o["id"] == .string(id) } else { return false } }
                }
            }
        } catch {
            apiTokenProblem = ErrorText.plain(error)
            return false
        }
        await load(source)
        return true
    }

    /// `settings.lanApi.apiTokens`, changed in place — every other key of
    /// `settings` and `lanApi` left exactly as the book holds it.
    nonisolated static func editApiTokens(_ root: inout [String: JSONValue], _ change: (inout [JSONValue]) -> Void) {
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }
        var lan: [String: JSONValue] = [:]
        if case .object(let l)? = settings["lanApi"] { lan = l }
        var list: [JSONValue] = []
        if case .array(let had)? = lan["apiTokens"] { list = had }
        change(&list)
        lan["apiTokens"] = .array(list)
        settings["lanApi"] = .object(lan)
        root["settings"] = .object(settings)
    }
}

/// Settings → Online → API tokens: the Electron card, on this Mac.
///
/// Saves itself, like the sections above it in the pane: a token is minted
/// into the book the moment it is made, because its plaintext is shown once
/// and a draft that was never saved would be a token that never works.
struct ApiTokensSection: View {
    let shop: Shop
    @State private var label = ""
    @State private var chosen: Set<String> = []
    @State private var scopes: [String] = []
    @State private var rows: [ApiTokenRow] = []
    @State private var revoking: ApiTokenRow?
    @State private var shown: ShownToken?
    @State private var note: String?

    struct ShownToken: Identifiable { let id = UUID(); let token: String }

    private var whereLine: String {
        let base: String = shop.lanURL ?? "http://…/"
        let url: String = base + "v1/"
        return shop.words.callIt("mac.api_where", ["url": .string(url)])
    }

    var body: some View {
        Section(shop.words.callIt("api.section")) {
            Text(shop.words.callIt("api.hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(whereLine)
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if rows.isEmpty {
                Text(shop.words.callIt("api.none")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                ApiTokenLine(row: row, words: shop.words, canRevoke: shop.mayManageApiTokens) { revoking = row }
            }
            if shop.mayManageApiTokens {
                LabeledContent(shop.words.callIt("api.label")) {
                    TextField("", text: $label, prompt: Text(shop.words.callIt("api.label_ph")))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
                LabeledContent(shop.words.callIt("mac.api_scopes")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading) {
                        ForEach(scopes, id: \.self) { scope in
                            Toggle(isOn: Binding(get: { chosen.contains(scope) },
                                                 set: { on in if on { chosen.insert(scope) } else { chosen.remove(scope) } })) {
                                Text(verbatim: scope).font(.callout.monospaced())
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                HStack {
                    Button(shop.words.callIt("api.mint")) { Task { await mint() } }
                        .disabled(chosen.isEmpty)
                    if let note { Text(note).font(.callout).foregroundStyle(Khayt.done) }
                }
            } else {
                Text(shop.words.callIt("mac.api_owner_only")).font(.callout).foregroundStyle(.secondary)
            }
            if let problem = shop.apiTokenProblem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: shop.settingsValue) { await refresh() }
        .confirmationDialog(
            shop.words.callIt("api.revoke_q"),
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            presenting: revoking
        ) { row in
            Button(shop.words.callIt("api.revoke"), role: .destructive) {
                Task {
                    if await shop.revokeApiToken(row.id) { note = shop.words.callIt("api.revoked") }
                }
            }
            Button(shop.words.callIt("common.cancel"), role: .cancel) {}
        }
        .shopSheet(item: $shown) { shown in
            ApiTokenShownSheet(token: shown.token, words: shop.words) { self.shown = nil }
        }
    }

    private func refresh() async {
        guard let engine = shop.engine else { return }
        if scopes.isEmpty { scopes = (try? await engine.apiTokenScopes()) ?? [] }
        let stored = JSONValue.array(ApiTokens.records(in: shop.settingsDict))
        rows = ApiTokenRow.rows((try? await engine.apiTokensRedacted(stored)) ?? [])
    }

    private func mint() async {
        note = nil
        let ordered = scopes.filter { chosen.contains($0) }
        guard let token = await shop.mintApiToken(label: label, scopes: ordered) else { return }
        label = ""
        chosen = []
        shown = ShownToken(token: token)
    }
}

/// One stored token: its name, its scopes, the day it was made, and Revoke.
private struct ApiTokenLine: View {
    let row: ApiTokenRow
    let words: Words
    let canRevoke: Bool
    let revoke: () -> Void

    var body: some View {
        let name: String = row.label.isEmpty ? row.id : row.label
        let scopes: String = row.scopes.isEmpty ? "—" : row.scopes.joined(separator: ", ")
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).font(.callout.weight(.semibold))
                Text(verbatim: scopes).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.md)
            Text(verbatim: row.createdAt).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if canRevoke {
                Button(words.callIt("api.revoke"), role: .destructive, action: revoke)
            }
        }
    }
}

/// The token, ONCE. Closing this is the last time anybody sees it: only its
/// hash was stored.
private struct ApiTokenShownSheet: View {
    let token: String
    let words: Words
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(words.callIt("api.created")).font(.headline)
            Text(words.callIt("api.copy_now"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: token)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                Button(words.callIt("common.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token, forType: .string)
                    copied = true
                }
                if copied { Text(words.callIt("mac.copied")).font(.callout).foregroundStyle(Khayt.done) }
                Spacer()
                Button(words.callIt("common.done"), action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
