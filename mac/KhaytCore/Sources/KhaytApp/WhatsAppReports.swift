import AppKit
import Foundation
import KhaytCore
import SwiftUI

/// WhatsApp delivery reports, by way of Khayt Cloud.
///
/// Meta tells a public HTTPS address what happened to each message the shop
/// sent — sent, delivered, read, failed — and the Mac's LAN server is not one.
/// So the cloud takes Meta's webhook and the Mac polls it
/// (khayt-cloud docs/api-contract.md, "WhatsApp delivery reports"). The cloud
/// sends nothing: every message leaves from this Mac, with the shop's token.
///
/// Setup, once: the owner or a manager hands the cloud the Meta app's secret
/// and is given a `url` and a `verifyToken` to paste into Meta (WhatsApp →
/// Configuration → Webhook, subscribed to `messages`).
///
/// Polled every two minutes while a hook is configured. Each report moves the
/// commLog line carrying its `messageId` forward (`lib/whatsapp-status.js`).
/// Where to read from next (`seq`) is this Mac's own memory, per shop.
@MainActor
enum WhatsAppReports {
    struct Hook: Decodable, Equatable, Sendable {
        let configured: Bool
        let url: String?
        let verifyToken: String?
        let lastReportAt: String?
    }

    struct Page: Decodable, Sendable {
        let items: [JSONValue]
        let nextSince: JSONValue?
    }

    enum Failure: Error, LocalizedError, Equatable {
        case unauthorised, notAllowed, notOffered, badSecret
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .unauthorised: "Khayt Cloud did not accept this shop's token."
            case .notAllowed: "Only the shop's owner or a manager can set this up."
            case .notOffered: "Khayt Cloud does not take WhatsApp reports yet."
            case .badSecret: "That is not a Meta app secret (16 to 128 letters and digits)."
            case .http(let code, let body): "Khayt Cloud answered \(code)" + (body.isEmpty ? "" : ": \(body)")
            }
        }

        /// The same, in the shop's words.
        @MainActor func said(_ words: Words) -> String {
            switch self {
            case .unauthorised: words.callIt("mac.wa_err_unauthorised")
            case .notAllowed: words.callIt("mac.wa_hook_owner_only")
            case .notOffered: words.callIt("mac.wa_err_not_offered")
            case .badSecret: words.callIt("mac.wa_err_bad_secret")
            case .http(let code, _): words.callIt("mac.cloud_err_http", ["code": .string(String(code))])
            }
        }
    }

    /// A failure as the pane says it: ours in the shop's words, the
    /// system's (offline, timed out) as the system says it.
    @MainActor static func said(_ error: Error, _ words: Words) -> String {
        (error as? Failure)?.said(words) ?? error.localizedDescription
    }

    static let every: Duration = .seconds(120)

    /// An ISO instant the cloud wrote, with or without its milliseconds.
    nonisolated static func instant(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// What the cloud's app-secret rule accepts, checked before sending so a
    /// typo is said here and not as a 400.
    static func plausibleSecret(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return (16...128).contains(t.count) && t.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// GET, PUT `{appSecret}` or DELETE the shop's hook.
    static func hook(_ connection: CloudReader.Connection, token: String, method: String,
                     appSecret: String? = nil,
                     fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws -> Hook {
        var request = try CloudReader.request(connection, token: token, method: method, tail: "/whatsapp-webhook")
        if let appSecret {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["appSecret": appSecret.trimmingCharacters(in: .whitespaces)])
        }
        let (data, response) = try await fetch(request)
        try check(data, response)
        if method == "DELETE" { return Hook(configured: false, url: nil, verifyToken: nil, lastReportAt: nil) }
        return try JSONDecoder().decode(Hook.self, from: data)
    }

    /// One page of reports after `since`.
    static func statuses(_ connection: CloudReader.Connection, token: String, since: Int?,
                         fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws -> Page {
        let tail = "/whatsapp-statuses" + (since.map { "?since=\($0)" } ?? "")
        let request = try CloudReader.request(connection, token: token, method: "GET", tail: tail)
        let (data, response) = try await fetch(request)
        // A 400 here is the cursor, not the secret.
        try check(data, response, badRequest: .http(400, ""))
        return try JSONDecoder().decode(Page.self, from: data)
    }

    private static func check(_ data: Data, _ response: URLResponse,
                              badRequest: Failure = .badSecret) throws {
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200, 204: return
        case 400: throw badRequest
        case 401: throw Failure.unauthorised
        case 403: throw Failure.notAllowed
        case 404, 405: throw Failure.notOffered
        case let code: throw Failure.http(code, String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    /// `nextSince` as a number, whichever way the cloud spelt it.
    static func seq(_ v: JSONValue?) -> Int? {
        switch v {
        // `exactly`: a fraction or a 1e300 is not a place in the stream, and
        // `Int(1e300)` traps.
        case .number(let n)?: return Int(exactly: n)
        case .string(let s)?: return Int(s)
        default: return nil
        }
    }

    // MARK: - This Mac's place in the stream

    static func key(_ shopId: String) -> String { "khayt.whatsappReports.since." + shopId }

    static func since(_ shopId: String, _ defaults: UserDefaults = .standard) -> Int? {
        defaults.object(forKey: key(shopId)) as? Int
    }

    static func remember(_ since: Int?, _ shopId: String, _ defaults: UserDefaults = .standard) {
        if let since { defaults.set(since, forKey: key(shopId)) } else { defaults.removeObject(forKey: key(shopId)) }
    }
}

extension Shop {
    private func cloudToken() async throws -> (CloudReader.Connection, String) {
        guard let build = source.build else { throw CloudReader.Failure.notConnected }
        let connection = try CloudReader.connection(settingsDict)
        let token = try await Secrets.open(connection.storedToken, for: build)
        guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }
        return (connection, token)
    }

    /// Ask the cloud whether this shop's hook is set up. Quiet when there is
    /// no cloud: most shops have none.
    ///
    /// `whatsAppHookFor` is set only once the cloud has answered for that
    /// shop, so a Mac that opened offline, or hit a cloud error, asks again
    /// on the next poll instead of never polling that session; and a book
    /// switched to another shop is asked about afresh.
    func refreshWhatsAppHook() async {
        let connection: CloudReader.Connection
        let token: String
        do {
            (connection, token) = try await cloudToken()
        } catch CloudReader.Failure.notConnected {
            whatsAppHook = nil
            whatsAppHookFor = nil
            whatsAppReportsAsStaff = false
            return
        } catch {
            // A locked keychain or a token gone: said, and the hook as last
            // known stays on screen.
            whatsAppHookFor = nil
            whatsAppHookProblem = WhatsAppReports.said(error, words)
            return
        }
        do {
            let session = CloudReader.session
            whatsAppHook = try await WhatsAppReports.hook(connection, token: token, method: "GET") {
                try await session.data(for: $0)
            }
            whatsAppHookProblem = nil
            whatsAppReportsAsStaff = false
            whatsAppHookFor = connection.shopId
        } catch WhatsAppReports.Failure.notAllowed {
            // A staff sign-in: the pane says who can set it up, not that it
            // failed — and it still reads the reports, which staff may.
            whatsAppHook = nil
            whatsAppHookProblem = words.callIt("mac.wa_hook_owner_only")
            whatsAppReportsAsStaff = true
            whatsAppHookFor = connection.shopId
        } catch {
            whatsAppHookFor = nil
            whatsAppHookProblem = WhatsAppReports.said(error, words)
        }
    }

    /// Hand the cloud the Meta app secret, or take the hook down with nil.
    func setWhatsAppHook(appSecret: String?) async {
        guard lockAllows("settings", "edit") else {
            whatsAppHookProblem = words.callIt(needsSignIn ? "mac.lock_sign_in_first" : "mac.lock_not_allowed")
            return
        }
        do {
            let (connection, token) = try await cloudToken()
            let session = CloudReader.session
            whatsAppHook = try await WhatsAppReports.hook(
                connection, token: token, method: appSecret == nil ? "DELETE" : "PUT", appSecret: appSecret
            ) { try await session.data(for: $0) }
            if appSecret == nil { WhatsAppReports.remember(nil, connection.shopId) }
            whatsAppHookProblem = nil
            whatsAppHookFor = connection.shopId
            startPollingWhatsAppReports()
        } catch {
            whatsAppHookProblem = WhatsAppReports.said(error, words)
        }
    }

    func startPollingWhatsAppReports() {
        guard whatsAppReportsTask == nil else { return }
        whatsAppReportsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollWhatsAppReports()
                try? await Task.sleep(for: WhatsAppReports.every)
            }
        }
    }

    func stopPollingWhatsAppReports() {
        whatsAppReportsTask?.cancel()
        whatsAppReportsTask = nil
    }

    /// Read every report after this Mac's place and move the lines they name.
    func pollWhatsAppReports() async {
        // lock: system — Meta's own delivery reports, moving lines this shop already sent; no person acts here.
        guard let engine, let build = source.build else { return }
        do {
            let (connection, token) = try await cloudToken()
            if whatsAppHookFor != connection.shopId { await refreshWhatsAppHook() }
            guard whatsAppHook?.configured == true || whatsAppReportsAsStaff else { return }
            let session = CloudReader.session
            var since = WhatsAppReports.since(connection.shopId)
            // Pages of up to 500; a Mac back from a week away reads them all.
            for _ in 0..<20 {
                let page = try await WhatsAppReports.statuses(connection, token: token, since: since) {
                    try await session.data(for: $0)
                }
                // Tried on the book in memory first: a page that moves nothing
                // (most of them, until this Mac sends through Meta) must not
                // rewrite the whole book.
                if !page.items.isEmpty,
                   try await engine.applyWhatsAppStatuses(clients: clientRows, items: page.items).changed > 0 {
                    let items = page.items
                    var moved = 0
                    try await StoreWriter.update(
                        storeURL: build.storeURL,
                        owns: { StoreLock.weOwnIt(build) },
                        whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
                    ) { root in
                        guard case .array(let clients)? = root["clients"] else { return }
                        let applied = try await engine.applyWhatsAppStatuses(clients: clients, items: items)
                        moved = applied.changed
                        if applied.changed > 0 { root["clients"] = .array(applied.clients) }
                    }
                    if moved > 0 { await load(source) }
                }
                let next = WhatsAppReports.seq(page.nextSince)
                if let next { WhatsAppReports.remember(next, connection.shopId) }
                guard let next, next != since, page.items.count >= 500 else { break }
                since = next
            }
            if !whatsAppReportsAsStaff { whatsAppHookProblem = nil }
        } catch CloudReader.Failure.notConnected {
            return
        } catch WhatsAppReports.Failure.notAllowed {
            // A viewer: not theirs to read. Asked again only on another book.
            whatsAppReportsAsStaff = false
        } catch {
            whatsAppHookProblem = WhatsAppReports.said(error, words)
        }
    }
}

/// The Online pane's WhatsApp delivery reports: the app secret in, the two
/// values for Meta out.
struct WhatsAppReportsSection: View {
    let shop: Shop
    @State private var secret = ""
    @State private var busy = false

    var body: some View {
        Section(shop.words.callIt("mac.wa_hook_title")) {
            Text(shop.words.callIt("mac.wa_hook_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !Shop.cloudConnected(shop.settingsDict) {
                Label(shop.words.callIt("mac.cr_needs_cloud"), systemImage: "icloud.slash")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent(shop.words.callIt("mac.wa_app_secret")) {
                    HStack {
                        SecureField(shop.whatsAppHook?.configured == true
                                    ? shop.words.callIt("common.secret_unchanged") : "", text: $secret)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                        Button(shop.words.callIt("mac.wa_hook_connect")) {
                            busy = true
                            Task { await shop.setWhatsAppHook(appSecret: secret); secret = ""; busy = false }
                        }
                        .disabled(busy || !WhatsAppReports.plausibleSecret(secret))
                    }
                }
                if let hook = shop.whatsAppHook, hook.configured {
                    if let url = hook.url { copyRow("mac.wa_hook_url", url) }
                    if let verify = hook.verifyToken { copyRow("mac.wa_hook_verify", verify) }
                    HStack {
                        Text(hook.lastReportAt.flatMap(WhatsAppReports.instant).map {
                            shop.words.callIt("mac.wa_hook_last", ["at": .string(
                                shop.words.say($0, Date.FormatStyle(date: .abbreviated, time: .shortened)))])
                        } ?? shop.words.callIt("mac.wa_hook_none_yet"))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(shop.words.callIt("mac.wa_hook_remove"), role: .destructive) {
                            busy = true
                            Task { await shop.setWhatsAppHook(appSecret: nil); busy = false }
                        }
                        .disabled(busy)
                    }
                }
                if let problem = shop.whatsAppHookProblem {
                    Text(problem).font(.caption).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func copyRow(_ key: String, _ value: String) -> some View {
        LabeledContent(shop.words.callIt(key)) {
            HStack {
                Text(value).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help(shop.words.callIt("mac.ik_copy"))
            }
        }
    }
}
