import Foundation

/// Khayt Cloud's weekly owner digest and paid-plan checkout — khayt-cloud
/// `docs/api-contract.md` "Weekly owner digest" and "Checkout".
///
/// ── THE PAYMENT IS THE BROWSER'S, NOT THIS APP'S ──────────────────────────
///
/// The app never sees a card. `POST /v1/billing/checkout` makes a hosted
/// payment page; the app opens its `url` in the default browser and asks the
/// cloud, now and then, how the attempt ended. Nothing is charged
/// automatically and nothing here knows a price: the amount comes back from
/// the cloud with the checkout. Mac only — the iPhone app shows no upgrade
/// or pay buttons.
///
/// The provider is dormant until the cloud has its key: the POST answers 409
/// `billing-provider-off`. The pay button then goes away for the rest of the
/// session (`Gate`), and is found out lazily — by the first tap, never by a
/// probe, because a POST makes a row.
public enum CloudCheckout {

    // MARK: - Digest

    public struct Digest: Equatable, Sendable {
        /// The owner's own choice.
        public var enabled: Bool
        /// The cloud's switch. False: nothing is sent yet, whatever `enabled` says.
        public var serverEnabled: Bool
        /// The Sunday the last digest covered, `YYYY-MM-DD`.
        public var lastSentWeek: String?
        public init(enabled: Bool, serverEnabled: Bool, lastSentWeek: String?) {
            self.enabled = enabled; self.serverEnabled = serverEnabled; self.lastSentWeek = lastSentWeek
        }
    }

    public static func digest(_ connection: CloudReader.Connection, token: String,
                              fetch: S3.Fetch) async throws -> Digest {
        let request = try CloudReader.request(connection, token: token, method: "GET", tail: "/digest")
        return try await readDigest(request, fetch)
    }

    public static func setDigest(_ enabled: Bool, _ connection: CloudReader.Connection, token: String,
                                 fetch: S3.Fetch) async throws -> Digest {
        var request = try CloudReader.request(connection, token: token, method: "PUT", tail: "/digest")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await readDigest(request, fetch)
    }

    private static func readDigest(_ request: URLRequest, _ fetch: S3.Fetch) async throws -> Digest {
        let (data, response) = try await fetch(request)
        try CloudPlans.check(S3.status(response), data)
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let enabled = o["enabled"] as? Bool else { throw VaultClient.Failure.badReply("digest") }
        return Digest(enabled: enabled, serverEnabled: (o["serverEnabled"] as? Bool) ?? false,
                      lastSentWeek: o["lastSentWeek"] as? String)
    }

    // MARK: - Checkout

    public enum Period: String, Sendable, CaseIterable { case month, year }

    public struct Started: Equatable, Sendable {
        public let id: String
        public let url: URL
        public let plan: String
        public let period: String
        public let amountSar: String
        public let currency: String
    }

    public enum State: String, Sendable { case pending, paid, failed, mismatch, error }

    public struct Status: Equatable, Sendable {
        public let state: State
        public let periodEnd: String?
        public let receiptNo: String?
    }

    /// How an attempt ended, for the sheet to say.
    public enum Outcome: Equatable, Sendable {
        /// Paid; `mine` is `GET /v1/billing/me` read afterwards (nil if that read failed).
        case paid(periodEnd: String?, mine: CloudPlans.Mine?)
        case failed
        /// Paid at another amount or for another checkout: nothing granted, review by hand.
        case mismatch(id: String)
        /// The cloud has no payment provider yet: hide the pay button.
        case providerOff
        /// `billing-off` / `not-for-sale` / `no-account`, or any other refusal.
        case refused(CloudPlans.Refusal)
        /// The browser would not open.
        case couldNotOpen
        /// Still pending when the app stopped asking.
        case timedOut(id: String)
        case cancelled
        /// The cloud could not be reached.
        case unreachable
    }

    /// Whether the pay button is on offer. Starts true; one 409
    /// The 409 reasons that hide the pay button until the app is quit: no
    /// payment provider, or the beta still running (khayt-cloud #163).
    public static let hidesPay: Set<String> = ["billing-provider-off", "beta-running"]

    /// `billing-provider-off` turns it off until the app is quit.
    public final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var off = false
        public init() {}
        public var providerOff: Bool { lock.withLock { off } }
        public func noteProviderOff() { lock.withLock { off = true } }
        /// The one gate the Mac app uses.
        public static let shared = Gate()
    }

    /// When to ask again: quickly at first (the payer has the page open), then
    /// every five seconds — the cloud asks Tap itself no more than every ten
    /// — for about ten minutes in all.
    public static let defaultDelays: [Duration] = [.seconds(3), .seconds(3), .seconds(4)]
        + Array(repeating: .seconds(5), count: 117)

    public static func start(plan: String, period: Period, _ connection: CloudReader.Connection,
                             token: String, fetch: S3.Fetch) async throws -> Started {
        var request = try CloudPlans.plain(connection.url, "/v1/billing/checkout")
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject:
            ["shopId": connection.shopId, "plan": plan, "period": period.rawValue])
        let (data, response) = try await fetch(request)
        try CloudPlans.check(S3.status(response), data)
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = o["id"] as? String, let text = o["url"] as? String,
              let url = URL(string: text), url.scheme == "https" else {
            throw VaultClient.Failure.badReply("checkout")
        }
        return Started(id: id, url: url, plan: (o["plan"] as? String) ?? plan,
                       period: (o["period"] as? String) ?? period.rawValue,
                       amountSar: (o["amountSar"] as? String) ?? "", currency: (o["currency"] as? String) ?? "SAR")
    }

    public static func status(id: String, _ connection: CloudReader.Connection, token: String,
                              fetch: S3.Fetch) async throws -> Status {
        var request = try CloudPlans.plain(connection.url, "/v1/billing/checkout/" + id.uriComponent
                                           + "?shopId=" + connection.shopId.uriComponent)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await fetch(request)
        try CloudPlans.check(S3.status(response), data)
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let s = o["status"] as? String else { throw VaultClient.Failure.badReply("checkout") }
        return Status(state: State(rawValue: s) ?? .pending, periodEnd: o["periodEnd"] as? String,
                      receiptNo: o["receiptNo"] as? String)
    }

    /// The whole attempt: start, open the page, ask until it ends, then read
    /// `billing/me`. `open` and `sleep` are injected so a test needs no browser
    /// and no waiting; `sleep` throws when the sheet's task is cancelled.
    public static func run(plan: String, period: Period, _ connection: CloudReader.Connection,
                           token: String, fetch: @escaping S3.Fetch, gate: Gate = .shared,
                           delays: [Duration] = defaultDelays,
                           open: @Sendable (URL) async -> Bool,
                           sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                           opened: @Sendable (Started) async -> Void = { _ in }) async -> Outcome {
        if gate.providerOff { return .providerOff }
        let started: Started
        do {
            started = try await start(plan: plan, period: period, connection, token: token, fetch: fetch)
        } catch let r as CloudPlans.Refusal {
            if r.status == 409, Self.hidesPay.contains(r.reason ?? "") { gate.noteProviderOff(); return .providerOff }
            return .refused(r)
        } catch {
            return Task.isCancelled ? .cancelled : .unreachable
        }
        guard await open(started.url) else { return .couldNotOpen }
        await opened(started)

        var misses = 0
        for delay in delays {
            do { try await sleep(delay) } catch { return .cancelled }
            if Task.isCancelled { return .cancelled }
            do {
                let s = try await status(id: started.id, connection, token: token, fetch: fetch)
                misses = 0
                switch s.state {
                case .pending: continue
                case .paid:
                    let mine = try? await CloudPlans.mine(connection, token: token, fetch: fetch)
                    return .paid(periodEnd: s.periodEnd, mine: mine)
                case .failed, .error: return .failed
                case .mismatch: return .mismatch(id: started.id)
                }
            } catch let r as CloudPlans.Refusal {
                // 401/403/404 will not get better by asking again.
                if [401, 403, 404].contains(r.status) { return .refused(r) }
                misses += 1
            } catch {
                misses += 1
            }
            if misses >= 8 { return .unreachable }
        }
        return .timedOut(id: started.id)
    }
}
