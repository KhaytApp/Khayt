import Foundation

/// Khayt Cloud's plans: the public catalogue, this shop's plan, and the
/// owner's move between them — khayt-cloud `docs/api-contract.md` "Billing"
/// (`GET /v1/plans`, `POST /v1/shops/{id}/plan`, `GET /v1/billing/me`).
///
/// ── NOTHING HERE TAKES MONEY ───────────────────────────────────────────────
///
/// During the beta an owner moves up for free; the cloud records the plan and
/// charges nothing. What the shop is told before it moves is the published
/// terms' own rule (khaytapp.com/terms §4 "Plans during the beta"): when the
/// beta ends it has the grace period to start paying, or it moves back to
/// Free, and nothing is deleted.
///
/// The catalogue is the source of truth for names, prices and limits. This
/// file carries no ladder of its own, so a price Turki changes on the server
/// is the price the Mac shows.
public enum CloudPlans {

    // MARK: - Shapes

    public struct Limits: Decodable, Sendable, Equatable {
        /// 0 means the server's default cap, not zero — never shown.
        public let maxStoreBytes: Int?
        public let maxVaultBytes: Int?
        public let maxActiveLinks: Int?
        public let publishing: Bool?
        /// Display only: the server does not enforce it.
        public let maxSeats: Int?
        public init(maxStoreBytes: Int? = nil, maxVaultBytes: Int? = nil, maxActiveLinks: Int? = nil,
                    publishing: Bool? = nil, maxSeats: Int? = nil) {
            self.maxStoreBytes = maxStoreBytes; self.maxVaultBytes = maxVaultBytes
            self.maxActiveLinks = maxActiveLinks; self.publishing = publishing; self.maxSeats = maxSeats
        }
    }

    public struct Plan: Decodable, Sendable, Equatable, Identifiable {
        public let name: String
        public let label: String
        /// VAT included (`pricesInclusive`). nil when the plan has no price.
        public let priceSar: Double?
        public let priceUsd: Double?
        public let annualSar: Double?
        public let annualUsd: Double?
        /// `month`, `year`, or nil.
        public let period: String?
        public let limits: Limits
        public var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name, label, priceSar, priceUsd, annualSar, annualUsd, period, limits
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil ?? name
            priceSar = (try? c.decodeIfPresent(Double.self, forKey: .priceSar)) ?? nil
            priceUsd = (try? c.decodeIfPresent(Double.self, forKey: .priceUsd)) ?? nil
            annualSar = (try? c.decodeIfPresent(Double.self, forKey: .annualSar)) ?? nil
            annualUsd = (try? c.decodeIfPresent(Double.self, forKey: .annualUsd)) ?? nil
            period = (try? c.decodeIfPresent(String.self, forKey: .period)) ?? nil
            limits = (try? c.decodeIfPresent(Limits.self, forKey: .limits)) ?? nil ?? Limits()
        }
    }

    public struct Beta: Decodable, Sendable, Equatable {
        /// Whether an owner can move up for free right now.
        public let freeUpgrades: Bool?
        public let endsAt: String?
        public let graceDays: Int?
    }

    public struct Catalogue: Decodable, Sendable, Equatable {
        public let plans: [Plan]
        public let defaultPlan: String?
        public let pricesInclusive: Bool?
        public let beta: Beta?

        public var freePlan: String { defaultPlan ?? "free" }
    }

    /// `GET /v1/billing/me` — this shop's plan.
    public struct Mine: Decodable, Sendable, Equatable {
        public struct Beta: Decodable, Sendable, Equatable {
            /// This shop is on a free beta upgrade. Stays true after the grace
            /// ends (with `active` false and `plan` free), so the app can say why.
            public let upgrade: Bool?
            public let endsAt: String?
            public let graceEndsAt: String?
            public let graceDays: Int?
        }
        public let billingEnabled: Bool?
        public let plan: String?
        public let label: String?
        public let status: String?
        public let active: Bool?
        public let until: String?
        public let beta: Beta?
        /// Over the plan's vault after a move down. Absent from an older
        /// cloud, which means not over.
        public let lapse: Lapse?
        public var onFreeUpgrade: Bool { beta?.upgrade == true }

        enum CodingKeys: String, CodingKey { case billingEnabled, plan, label, status, active, until, beta, lapse }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            billingEnabled = try c.decodeIfPresent(Bool.self, forKey: .billingEnabled)
            plan = try c.decodeIfPresent(String.self, forKey: .plan)
            label = try c.decodeIfPresent(String.self, forKey: .label)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            active = try c.decodeIfPresent(Bool.self, forKey: .active)
            until = try c.decodeIfPresent(String.self, forKey: .until)
            beta = try c.decodeIfPresent(Beta.self, forKey: .beta)
            // A lapse this app cannot read is no reason to lose the plan.
            lapse = (try? c.decodeIfPresent(Lapse.self, forKey: .lapse)) ?? nil
        }
    }

    /// `lapse` on `GET /v1/billing/me`, `GET …/vault/usage` and the plan
    /// move's answer (khayt-cloud #143): a vault over its plan's limit after a
    /// move down is READ-ONLY for 90 days and then trimmed until it fits —
    /// Trash first, then old versions, files in no product, product files with
    /// no buyers, and buyer-held files last, least recently changed first in
    /// each. `readOnlySince` can be nil for up to an hour after going over,
    /// and `deleteAfter` is nil while `deleting` is false.
    ///
    /// Every field is read leniently: a missing or odd value is "not over" for
    /// `over`, 0 for `overBytes`, nil for the dates.
    public struct Lapse: Codable, Sendable, Equatable {
        public let over: Bool
        public let overBytes: Int
        public let readOnlySince: String?
        public let deleteAfter: String?
        public let deleting: Bool

        public static let notOver = Lapse(over: false, overBytes: 0, readOnlySince: nil, deleteAfter: nil, deleting: false)

        public init(over: Bool, overBytes: Int, readOnlySince: String?, deleteAfter: String?, deleting: Bool) {
            self.over = over; self.overBytes = overBytes; self.readOnlySince = readOnlySince
            self.deleteAfter = deleteAfter; self.deleting = deleting
        }

        enum CodingKeys: String, CodingKey { case over, overBytes, readOnlySince, deleteAfter, deleting }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            over = (try? c.decodeIfPresent(Bool.self, forKey: .over)) ?? nil ?? false
            let bytes = (try? c.decodeIfPresent(Double.self, forKey: .overBytes)) ?? nil ?? 0
            overBytes = bytes.isFinite && bytes > 0 ? Int(min(bytes, Double(Int.max / 2))) : 0
            readOnlySince = (try? c.decodeIfPresent(String.self, forKey: .readOnlySince)) ?? nil
            deleteAfter = (try? c.decodeIfPresent(String.self, forKey: .deleteAfter)) ?? nil
            deleting = (try? c.decodeIfPresent(Bool.self, forKey: .deleting)) ?? nil ?? false
        }

        /// What the shop is shown.
        public enum Display: Equatable, Sendable {
            case notOver
            /// Over, read-only, no deletion date set. `since` is nil in the
            /// first hour.
            case readOnly(overBytes: Int, since: Date?)
            /// Over, and files over the limit will be deleted on
            /// `deleteAfter` — `daysLeft` whole book-calendar days from today,
            /// never below 0. `since` as for read-only.
            case deleting(overBytes: Int, deleteAfter: Date, daysLeft: Int, since: Date?)

            public var isOver: Bool { self != .notOver }
        }

        /// The display state, in the BOOK's calendar (never `Calendar.current`:
        /// a Mac on Umm al-Qura would count Hijri days). Days are counted
        /// between local midnights, so "in 3 days" does not turn into 2 at
        /// 14:00 the way a count of 24-hour spans would.
        public func display(now: Date = Date(), calendar: Calendar = .book) -> Display {
            guard over else { return .notOver }
            let since = readOnlySince.flatMap(Calendar.instant)
            // A date with deleting false is not a date the contract gives;
            // deleting without a readable date is said as read-only.
            guard deleting, let end = deleteAfter.flatMap(Calendar.instant) else {
                return .readOnly(overBytes: overBytes, since: since)
            }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                               to: calendar.startOfDay(for: end)).day ?? 0
            return .deleting(overBytes: overBytes, deleteAfter: end, daysLeft: max(0, days), since: since)
        }
    }

    /// A refusal the cloud named: `owner-only`, `billing-off`, `unknown-plan`,
    /// `no-account`, `paid-plan`, `upgrades-closed`, `beta-over`.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let status: Int
        public let reason: String
        public let error: String
        public var description: String {
            "Khayt Cloud refused (\(status) \(reason.isEmpty ? error : reason))"
        }
    }

    // MARK: - Requests

    /// The public catalogue. No token: it is the same for everyone.
    public static func catalogue(baseURL: String, fetch: S3.Fetch) async throws -> Catalogue {
        let request = try plain(baseURL, "/v1/plans")
        let (data, response) = try await fetch(request)
        try check(S3.status(response), data)
        return try decode(Catalogue.self, data)
    }

    public static func mine(_ connection: CloudReader.Connection, token: String,
                            fetch: S3.Fetch) async throws -> Mine {
        var request = try plain(connection.url, "/v1/billing/me?shopId=" + connection.shopId.uriComponent)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await fetch(request)
        try check(S3.status(response), data)
        return try decode(Mine.self, data)
    }

    /// Move the shop to `plan`. Owner only; answers what `mine` answers.
    public static func choose(_ plan: String, _ connection: CloudReader.Connection, token: String,
                              fetch: S3.Fetch) async throws -> Mine {
        var request = try CloudReader.request(connection, token: token, method: "POST", tail: "/plan")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["plan": plan])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await fetch(request)
        try check(S3.status(response), data)
        return try decode(Mine.self, data)
    }

    // MARK: - Reading a plan

    /// The price to show: riyals for a shop working in SAR, dollars otherwise
    /// when the plan has a dollar price, else riyals. nil for a plan with no price.
    public static func price(_ plan: Plan, currency: String) -> (amount: Double, currency: String)? {
        if currency.uppercased() != "SAR", let usd = plan.priceUsd { return (usd, "USD") }
        if let sar = plan.priceSar { return (sar, "SAR") }
        if let usd = plan.priceUsd { return (usd, "USD") }
        return nil
    }

    /// Whether moving from `current` to `plan` is a move up, by price.
    public static func isUpgrade(_ plan: Plan, from current: Plan?) -> Bool {
        (plan.priceSar ?? 0) > (current?.priceSar ?? 0)
    }

    // MARK: - Plumbing

    static func plain(_ base: String, _ path: String) throws -> URLRequest {
        guard let b = URL(string: base), b.scheme == "https",
              let url = URL(string: (b.absoluteString.hasSuffix("/") ? String(b.absoluteString.dropLast()) : b.absoluteString) + path) else {
            throw CloudReader.Failure.badAddress(base)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        return request
    }

    static func check(_ code: Int, _ data: Data) throws {
        guard !(200..<300).contains(code) else { return }
        let o = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        throw Refusal(status: code, reason: (o["reason"] as? String) ?? "", error: (o["error"] as? String) ?? "")
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw VaultClient.Failure.badReply("plans") }
    }
}
