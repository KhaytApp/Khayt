import CryptoKit
import Foundation
import KhaytCore
import SwiftUI

/// The shop's customers, published for its own storefront — or deleted.
///
/// khayt-cloud's `/v1/shops/{id}/customers` (docs/api-contract.md, "Customer
/// records"). A PLAINTEXT copy of each customer with an email: name, phone,
/// and the jobs linked to them. OFF by default; `lib/customer-records.js`
/// decides what goes in it, whether the switch may be on at all (`READY`), and
/// when to send. This file only carries it.
///
/// ── WHEN ──────────────────────────────────────────────────────────────────
///
/// Asked every ten minutes. The module answers `put` when the set has changed
/// since this Mac last sent it, or when that send is a day old (the cloud
/// deletes a set nobody refreshes for 30 days); `delete` once after the shop
/// turns it off; otherwise nothing. Ten minutes is "after a change" without a
/// hook in every write path, and at most six uploads an hour against the
/// route's thirty.
///
/// What this Mac last sent is kept in UserDefaults per shop, not in the book:
/// it is this Mac's memory of its own sends, and a synced book would hand one
/// Mac's memory to another that never sent anything.
@MainActor
enum CustomerRecordsPublisher {
    enum Failure: Error, LocalizedError, Equatable {
        case unauthorised, readOnly, notOffered, tooLarge
        /// 409 `disabled`: somebody turned customer records off for the
        /// whole shop on another Mac (khayt-cloud #122).
        case offElsewhere
        case limited(retryAfter: TimeInterval?)
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .unauthorised: "Khayt Cloud did not accept this shop's token for customer records."
            case .readOnly: "This sign-in can read this shop but not publish its customers."
            case .notOffered: "Khayt Cloud does not take customer records yet."
            case .tooLarge: "More customers than Khayt Cloud keeps (5,000 or 4 MB)."
            case .offElsewhere: "Customer records were turned off for this shop on another Mac."
            case .limited: "Khayt Cloud asked for fewer uploads; trying again later."
            case .http(let code, let body): "Khayt Cloud answered \(code) to customer records" + (body.isEmpty ? "" : ": \(body)")
            }
        }

        /// The same, in the shop's words — the pane is read in Arabic too.
        /// The cloud's own text after a status code stays out: it is English.
        @MainActor func said(_ words: Words) -> String {
            switch self {
            case .unauthorised: words.callIt("mac.cr_err_unauthorised")
            case .readOnly: words.callIt("mac.cr_err_read_only")
            case .notOffered: words.callIt("mac.cr_err_not_offered")
            case .tooLarge: words.callIt("mac.cr_err_too_large")
            case .offElsewhere: words.callIt("mac.cr_off_elsewhere")
            case .limited: words.callIt("mac.cr_err_limited")
            case .http(let code, _): words.callIt("mac.cloud_err_http", ["code": .string(String(code))])
            }
        }
    }

    /// A `Retry-After` the cloud sent, held to between a second and a day:
    /// `inf` parses as a number, and would have stopped every send, the
    /// switch's delete included, until the app was quit.
    nonisolated static func retryAfter(_ header: String?) -> TimeInterval? {
        guard let header, let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite else { return nil }
        return min(max(seconds, 1), 86_400)
    }

    static let every: Duration = .seconds(600)
    static let first: Duration = .seconds(120)

    /// Send the whole set (`body`), or delete it with nil.
    ///
    /// ── WHO SAID IT: A PERSON, OR THE LOOP ───────────────────────────────
    ///
    /// The switch is in each Mac's own settings, which never sync, so "off"
    /// on one Mac used to stop that Mac only: a second one with its switch
    /// on put the copy straight back. khayt-cloud #122 keeps the decision for
    /// the shop. `byPerson` marks the two sends only a person's press may
    /// make: off with `?scope=shop`, which marks the shop off for every Mac,
    /// and on with `enable: true`, which clears that mark. The ten-minute
    /// loop never sends either, so it can never undo what a person decided
    /// on another Mac. A cloud without #122 ignores both.
    static func publish(_ connection: CloudReader.Connection, token: String, body: JSONValue?,
                        byPerson: Bool = false,
                        fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws {
        let tail = body == nil && byPerson ? "/customers?scope=shop" : "/customers"
        var request = try CloudReader.request(connection, token: token,
                                              method: body == nil ? "DELETE" : "PUT", tail: tail)
        if var body {
            if byPerson, case .object(var o) = body { o["enable"] = .bool(true); body = .object(o) }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await fetch(request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200, 204: return
        case 401: throw Failure.unauthorised
        case 403: throw Failure.readOnly
        case 404, 405: throw Failure.notOffered
        case 409 where body != nil: throw Failure.offElsewhere
        case 413: throw Failure.tooLarge
        case 429: throw Failure.limited(retryAfter: retryAfter(http?.value(forHTTPHeaderField: "Retry-After")))
        case let code: throw Failure.http(code, String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    /// What a body is, for "has it changed since I sent it": a SHA-256 of its
    /// JSON with sorted keys, so the same set always hashes the same.
    static func fingerprint(_ body: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(body))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - This Mac's memory of its sends

    struct Memory: Codable, Equatable { var fingerprint: String; var at: String }

    static func key(_ shopId: String) -> String { "khayt.customerRecords.sent." + shopId }

    static func memory(_ shopId: String, _ defaults: UserDefaults = .standard) -> Memory? {
        defaults.data(forKey: key(shopId)).flatMap { try? JSONDecoder().decode(Memory.self, from: $0) }
    }

    static func remember(_ memory: Memory?, _ shopId: String, _ defaults: UserDefaults = .standard) {
        if let memory, let data = try? JSONEncoder().encode(memory) {
            defaults.set(data, forKey: key(shopId))
        } else {
            defaults.removeObject(forKey: key(shopId))
        }
    }
}

extension Shop {
    func startPublishingCustomerRecords() {
        guard customerRecordsTask == nil else { return }
        customerRecordsTask = Task { [weak self] in
            try? await Task.sleep(for: CustomerRecordsPublisher.first)
            while !Task.isCancelled {
                await self?.publishCustomerRecords()
                try? await Task.sleep(for: CustomerRecordsPublisher.every)
            }
        }
    }

    func stopPublishingCustomerRecords() {
        customerRecordsTask?.cancel()
        customerRecordsTask = nil
    }

    /// One look: put, delete or nothing, as the module decides.
    ///
    /// `delete` is the switch going off: the copy is deleted whatever this
    /// Mac remembers sending, because another Mac may have sent it and "off
    /// deletes it" is what the pane promises.
    /// `byPerson` is the switch being pressed, on or off — see
    /// `CustomerRecordsPublisher.publish`. The loop never passes it.
    func publishCustomerRecords(now: Date = Date(), delete: Bool = false, byPerson: Bool = false) async {
        guard let engine, let build = source.build else { return }
        if let notBefore = customerRecordsNotBefore, now < notBefore { return }
        do {
            let connection = try CloudReader.connection(settingsDict)
            let state = try await engine.customerRecordsState(settings: settingsDict)
            customerRecordsReady = state.ready
            let memory = CustomerRecordsPublisher.memory(connection.shopId)
            // Off, and nothing of this Mac's out there: the usual case, and
            // not worth reading every customer for.
            if !state.on, memory == nil, !delete { return }
            let built = try await engine.customerRecords(clients: clientRows, printLog: orderRows,
                                                          settings: settingsDict)
            let fingerprint = try CustomerRecordsPublisher.fingerprint(built.body)
            let action: String
            if delete && !state.on {
                action = "delete"
            } else if byPerson && state.on {
                // Turned on by hand: sent now, whatever this Mac remembers,
                // because the send is what lifts an off made on another Mac.
                action = "put"
            } else {
                action = try await engine.customerRecordsNext(
                    on: state.on, fingerprint: fingerprint,
                    memory: memory.map { ($0.fingerprint, $0.at) }, now: Self.isoNow(now))
            }
            guard action != "none" else { return }

            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }
            let session = CloudReader.session
            try await CustomerRecordsPublisher.publish(connection, token: token,
                                                       body: action == "put" ? built.body : nil,
                                                       byPerson: byPerson) {
                try await session.data(for: $0)
            }
            // Switched off while this PUT was on its way: the switch's DELETE
            // may have landed first, so the copy just sent goes too.
            if action == "put", !customerRecordsOn {
                try await CustomerRecordsPublisher.publish(connection, token: token, body: nil) {
                    try await session.data(for: $0)
                }
                CustomerRecordsPublisher.remember(nil, connection.shopId)
                customerRecordsSaid = words.callIt("mac.cr_deleted")
                customerRecordsProblem = false
                return
            }
            CustomerRecordsPublisher.remember(
                action == "put" ? .init(fingerprint: fingerprint, at: Self.isoNow(now)) : nil,
                connection.shopId)
            customerRecordsSaid = action == "put"
                ? words.callIt("mac.cr_published", ["count": .string(Money.quantity(Double(built.published), decimals: 0))])
                : words.callIt("mac.cr_deleted")
            // Said, not hidden: a storefront missing a customer's old orders
            // should have a reason the shop can read.
            if action == "put", built.trimmed.orders + built.trimmed.people > 0 {
                customerRecordsSaid = (customerRecordsSaid ?? "") + " " + words.callIt("mac.cr_trimmed", [
                    "orders": .string(Money.quantity(Double(built.trimmed.orders), decimals: 0)),
                    "people": .string(Money.quantity(Double(built.trimmed.people), decimals: 0))])
            }
            customerRecordsProblem = false
        } catch CloudReader.Failure.notConnected {
            customerRecordsSaid = nil
        } catch CustomerRecordsPublisher.Failure.offElsewhere {
            // Turned off for the whole shop on another Mac: this one follows,
            // so it stops trying, and the pane says why it is off.
            await switchCustomerRecordsOffHere()
            customerRecordsSaid = CustomerRecordsPublisher.Failure.offElsewhere.said(words)
            customerRecordsProblem = false
        } catch CustomerRecordsPublisher.Failure.limited(let after) {
            customerRecordsNotBefore = now.addingTimeInterval(after ?? 3600)
        } catch let failure as CustomerRecordsPublisher.Failure {
            customerRecordsSaid = failure.said(words)
            customerRecordsProblem = true
        } catch {
            customerRecordsSaid = words.callIt("mac.cr_failed") + " " + error.localizedDescription
            customerRecordsProblem = true
        }
    }
}

extension Shop {
    /// Turn the copy on or off, at once. Off deletes it on the next look —
    /// made straight away here, so "off" is never "off in ten minutes".
    ///
    /// Written into the book directly rather than through the Settings form:
    /// the switch saves itself, like online storage beside it, and the form
    /// rule (`settings-form.js`) has no field for it.
    func setCustomerRecords(_ on: Bool) async {
        guard lockAllows("settings", "edit") else {
            customerRecordsSaid = words.callIt(needsSignIn ? "mac.lock_sign_in_first" : "mac.lock_not_allowed")
            customerRecordsProblem = true
            return
        }
        guard let build = source.build else { return }
        do {
            let changedAt = Self.isoNow()
            try await StoreWriter.updateOffMain(build) { root in
                var settings: [String: JSONValue] = [:]
                if case .object(let had)? = root["settings"] { settings = had }
                settings["customerRecords"] = .object(["enabled": .bool(on),
                                                       "changedAt": .string(changedAt)])
                root["settings"] = .object(settings)
            }
            await load(source)
            customerRecordsNotBefore = nil
            await publishCustomerRecords(delete: !on, byPerson: true)
        } catch {
            customerRecordsSaid = words.callIt("mac.cr_failed") + " " + String(describing: error)
            customerRecordsProblem = true
        }
    }

    /// This Mac's switch off, as the cloud says the shop decided, without
    /// sending anything: the copy is already down, and a delete from here
    /// would be one more request saying what the cloud already knows.
    func switchCustomerRecordsOffHere() async {
        guard let build = source.build else { return }
        let at = Self.isoNow()
        try? await StoreWriter.updateOffMain(build) { root in
            var settings: [String: JSONValue] = [:]
            if case .object(let had)? = root["settings"] { settings = had }
            settings["customerRecords"] = .object(["enabled": .bool(false), "changedAt": .string(at),
                                                   "offElsewhere": .bool(true)])
            root["settings"] = .object(settings)
        }
        if let connection = try? CloudReader.connection(settingsDict) {
            CustomerRecordsPublisher.remember(nil, connection.shopId)
        }
        await load(source)
    }

    /// Whether the book has the switch on, as written — the pane's toggle.
    /// `customerRecordsReady` says whether this build lets it count.
    var customerRecordsOn: Bool {
        guard case .object(let s)? = settingsDict["customerRecords"] else { return false }
        return s["enabled"] == .bool(true)
    }

    /// Ask the module whether this build lets the switch be on.
    func refreshCustomerRecordsReady() async {
        customerRecordsReady = (try? await engine?.customerRecordsState(settings: settingsDict))?.ready ?? false
    }
}


/// The Online pane's switch for the copy. Saves itself as it is flipped,
/// like online storage at the top of the pane; the Save bar is not its
/// business. Shut, with the reason, while the module holds it.
struct CustomerRecordsSection: View {
    let shop: Shop
    @State private var busy = false

    var body: some View {
        Section(shop.words.callIt("mac.cr_title")) {
            Toggle(shop.words.callIt("mac.cr_enable"), isOn: Binding(
                // As the book has it, ready or not: a book holding "on" from
                // elsewhere shows on, so the one press it allows turns it off.
                get: { shop.customerRecordsOn },
                set: { on in
                    busy = true
                    Task { await shop.setCustomerRecords(on); busy = false }
                }))
                // Off may always be pressed — a book that has it on from a
                // build that allowed it must be able to take it back.
                .disabled(busy || shop.source.build == nil
                          || (!shop.customerRecordsReady && !shop.customerRecordsOn))
            Text(shop.words.callIt("mac.cr_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !shop.customerRecordsReady {
                Label(shop.words.callIt("mac.cr_held"), systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if shop.customerRecordsOn && !Shop.cloudConnected(shop.settingsDict) {
                Label(shop.words.callIt("mac.cr_needs_cloud"), systemImage: "icloud.slash")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let said = shop.customerRecordsSaid {
                Text(said)
                    .font(.caption)
                    .foregroundStyle(shop.customerRecordsProblem
                                     ? AnyShapeStyle(Khayt.attention) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
