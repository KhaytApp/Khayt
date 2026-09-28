import SwiftUI
import KhaytCore

/// The shop's order-import key, managed from Integrations.
///
/// ── WHY A KEY AT ALL ─────────────────────────────────────────────────────
///
/// The import link carries the shop id, and the shop id is printed in every
/// import and feed link, so it is not a secret. Khayt Cloud therefore drops
/// `paid`, `paymentStatus` and prices from an import that cannot prove it came
/// from the shop's own store — and without `paid` a web-store order waits for a
/// person instead of becoming a job by itself. The key is that proof: the
/// generated Medusa subscriber sends it as `X-Khayt-Import-Key`, read from
/// `KHAYT_IMPORT_KEY` in the Medusa server's environment.
///
/// ── WHERE THE KEY LIVES, AND WHERE IT DOES NOT ───────────────────────────
///
/// In the shop's Medusa environment, and nowhere else. The server keeps only
/// its SHA-256 and shows the key exactly once, in the answer to `POST`. This
/// app shows that answer once and holds it in view state only: it is never
/// written to the book, the keychain, preferences or a log. A lost key is
/// replaced, not recovered. `ImportKeyTests` pins that by reading this file.
///
/// Contract: khayt-cloud `docs/api-contract.md`,
/// "GET | POST | DELETE /v1/shops/{shopId}/import-key" (owner or manager).
@MainActor
enum ImportKeyClient {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    /// Whether the shop has a key, and since when. The key itself never comes back.
    struct Status: Equatable, Sendable {
        let set: Bool
        let createdAt: Date?
    }

    /// A new key, the only time it is ever shown.
    struct Created: Equatable, Sendable {
        let key: String
        let createdAt: Date?
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        /// 401: the shop's sign-in was not accepted.
        case unauthorised
        /// 403: signed in, but not as the owner or a manager.
        case notManager
        /// 404: this Khayt Cloud has no import-key route yet.
        case notOffered
        case malformed
        case http(Int, String)

        var description: String {
            switch self {
            case .unauthorised: "Khayt Cloud did not accept this shop's token for the import key."
            case .notManager: "Only the owner or a manager can manage the import key."
            case .notOffered: "Khayt Cloud does not offer an import key yet."
            case .malformed: "Khayt Cloud's answer about the import key was not the expected shape."
            case .http(let code, let body): "Khayt Cloud answered \(code) about the import key" + (body.isEmpty ? "" : ": \(body)")
            }
        }
    }

    static let tail = "/import-key"

    static func status(_ connection: CloudReader.Connection, token: String,
                       fetch: Fetch) async throws -> Status {
        let data = try await send(connection, token: token, method: "GET", fetch: fetch)
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let set = body["set"] as? Bool else { throw Failure.malformed }
        return Status(set: set, createdAt: (body["createdAt"] as? String).flatMap(date))
    }

    /// Make a key, replacing any old one. Links carrying the old one stop at once.
    static func create(_ connection: CloudReader.Connection, token: String,
                       fetch: Fetch) async throws -> Created {
        let data = try await send(connection, token: token, method: "POST", fetch: fetch)
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = body["key"] as? String, !key.isEmpty else { throw Failure.malformed }
        return Created(key: key, createdAt: (body["createdAt"] as? String).flatMap(date))
    }

    /// No key: the import link accepts orders from anyone again.
    static func remove(_ connection: CloudReader.Connection, token: String,
                       fetch: Fetch) async throws {
        _ = try await send(connection, token: token, method: "DELETE", fetch: fetch)
    }

    private static func send(_ connection: CloudReader.Connection, token: String, method: String,
                             fetch: Fetch) async throws -> Data {
        // Built by CloudReader.request like every other cloud call, for the
        // Bearer token and the x-delta-capable header — a call that forgot the
        // header would close the shop's delta gate.
        var request = try CloudReader.request(connection, token: token, method: method, tail: tail)
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        let (data, response) = try await fetch(request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200, 204: return data
        case 401: throw Failure.unauthorised
        case 403: throw Failure.notManager
        case 404: throw Failure.notOffered
        case let code: throw Failure.http(code, String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    /// ISO with or without fractions (Node backend), or MySQL's UTC form (PHP).
    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: text) { return d }
        if let d = ISO8601DateFormatter().date(from: text) { return d }
        let sql = DateFormatter()
        sql.locale = Locale(identifier: "en_US_POSIX")
        sql.timeZone = TimeZone(identifier: "UTC")
        sql.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return sql.date(from: text)
    }

    /// What to tell the shop when a call fails, in its own words.
    static func said(_ error: Error, words: Words) -> String {
        switch error {
        case Failure.notManager: return words.callIt("mac.ik_err_role")
        case Failure.unauthorised: return words.callIt("mac.ws_err_token")
        case Failure.notOffered: return words.callIt("mac.ik_err_not_offered")
        case Failure.http(let code, _): return words.callIt("mac.ws_err_http", ["code": .number(Double(code))])
        default: return words.callIt("mac.ik_err_generic")
        }
    }
}

extension Shop {
    /// The connection and the opened token for one import-key call.
    ///
    /// Opened at the moment of the call and handed straight back, as every
    /// other cloud call here does; nothing is kept.
    func importKeyAccess() async throws -> (CloudReader.Connection, String) {
        let connection = try CloudReader.connection(settingsDict)
        guard let build = source.build else { throw CloudReader.Failure.notConnected }
        let token = try await Secrets.open(connection.storedToken, for: build)
        guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }
        return (connection, token)
    }
}

/// The Import key row on the Integrations pane.
struct ImportKeySection: View {
    let shop: Shop

    @State private var status: ImportKeyClient.Status?
    /// The key the server just made. Shown once, and gone when the pane is.
    @State private var fresh: ImportKeyClient.Created?
    @State private var problem: String?
    @State private var busy = false
    @State private var confirming: Confirm?
    @State private var copied = false

    enum Confirm: Identifiable { case create, replace, remove; var id: Self { self } }

    var body: some View {
        Section(shop.words.callIt("mac.ik_title")) {
            Text(shop.words.callIt("mac.ik_explain"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline) {
                Text(stateLine).font(.callout)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if let status, !busy {
                    if status.set {
                        Button(shop.words.callIt("mac.ik_replace")) { confirming = .replace }
                        Button(shop.words.callIt("mac.ik_remove"), role: .destructive) { confirming = .remove }
                    } else {
                        Button(shop.words.callIt("mac.ik_create")) { confirming = .create }
                    }
                }
            }

            if let fresh {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(verbatim: fresh.key)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(shop.words.callIt(copied ? "mac.ik_copied" : "mac.ik_copy")) {
                            SecretPasteboard.copy(fresh.key)
                            copied = true
                        }
                    }
                    Text(shop.words.callIt("mac.ik_shown_once"))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text(shop.words.callIt("mac.ik_other_links"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(Khayt.attention.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load() }
        .onDisappear { fresh = nil; copied = false }
        .confirmationDialog(confirmTitle,
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { which in
            Button(confirmButton(which), role: which == .create ? nil : .destructive) {
                Task { await act(which) }
            }
            Button(shop.words.callIt("common.cancel"), role: .cancel) { confirming = nil }
        } message: { which in
            Text(confirmBody(which))
        }
    }

    private var stateLine: String {
        guard let status else { return shop.words.callIt(problem == nil ? "mac.ik_checking" : "mac.ik_unknown") }
        guard status.set else { return shop.words.callIt("mac.ik_none") }
        guard let at = status.createdAt else { return shop.words.callIt("mac.ik_set") }
        return shop.words.callIt("mac.ik_set_since",
                                 ["date": .string(shop.words.say(at, .dateTime.day().month(.abbreviated).year()))])
    }

    private var confirmTitle: String {
        switch confirming {
        case .remove: shop.words.callIt("mac.ik_remove_title")
        case .replace: shop.words.callIt("mac.ik_replace_title")
        default: shop.words.callIt("mac.ik_create_title")
        }
    }

    private func confirmButton(_ which: Confirm) -> String {
        switch which {
        case .create: shop.words.callIt("mac.ik_create")
        case .replace: shop.words.callIt("mac.ik_replace")
        case .remove: shop.words.callIt("mac.ik_remove")
        }
    }

    private func confirmBody(_ which: Confirm) -> String {
        switch which {
        case .create: shop.words.callIt("mac.ik_create_body")
        case .replace: shop.words.callIt("mac.ik_replace_body")
        case .remove: shop.words.callIt("mac.ik_remove_body")
        }
    }

    private func load() async {
        busy = true; defer { busy = false }
        do {
            let (connection, token) = try await shop.importKeyAccess()
            let session = CloudReader.session
            status = try await ImportKeyClient.status(connection, token: token) { try await session.data(for: $0) }
            problem = nil
        } catch {
            status = nil
            problem = ImportKeyClient.said(error, words: shop.words)
        }
    }

    private func act(_ which: Confirm) async {
        confirming = nil
        busy = true; defer { busy = false }
        do {
            let (connection, token) = try await shop.importKeyAccess()
            let session = CloudReader.session
            let fetch: ImportKeyClient.Fetch = { try await session.data(for: $0) }
            switch which {
            case .create, .replace:
                let made = try await ImportKeyClient.create(connection, token: token, fetch: fetch)
                fresh = made
                copied = false
                status = .init(set: true, createdAt: made.createdAt ?? Date())
            case .remove:
                try await ImportKeyClient.remove(connection, token: token, fetch: fetch)
                fresh = nil
                status = .init(set: false, createdAt: nil)
            }
            problem = nil
        } catch {
            problem = ImportKeyClient.said(error, words: shop.words)
        }
    }
}
