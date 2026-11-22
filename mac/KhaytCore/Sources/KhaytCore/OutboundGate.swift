import Foundation

/// The purposes an internet call can serve: `lib/outbound.js` `PURPOSES`,
/// held equal to the rule by `OutboundTests.purposesAreTheRules`.
public enum OutboundPurpose: String, CaseIterable, Sendable, Codable {
    case updates
    case installCount = "install-count"
    case crashReports = "crash-reports"
    case usageStats = "usage-stats"
    case cloud
    case makerrun
    case catalogues
    case storage
    case messaging
    case webhooks
    case payments
    case storefront
    case ai
    case taxAuthority = "tax-authority"
    case exchangeRates = "exchange-rates"
    case lookups
    /// The desktop's public tunnel. The Mac has none and never asks for it;
    /// the case exists so this list equals the rule's.
    case tunnel
    /// The one call an offline computer keeps when the switch came through
    /// Khayt Cloud: a GET of its network-switch route, only to hear the switch
    /// turned off. Kept by the rule's own test (`settings.network.via` is
    /// `cloud` and the row is not unticked), never by a Keep tick.
    case switchSync = "switch-sync"
    /// Printers, cameras and phones on the shop's own network: never blocked,
    /// but only at a private address while the switch is on.
    case lan
}

/// A call the switch refused. One distinct error, so retry and backoff code
/// can tell it from a network failure and does not grow its delay, and so a
/// person's action can say why in words (`reason`), never "network error".
public struct OutboundBlocked: Error, Equatable, Sendable, CustomStringConvertible {
    public let purpose: OutboundPurpose
    /// One of the rule's `REASONS`: `offline`, `offline-here`, `opted-out`,
    /// `settings-unknown`, `lan-host-public`, `lan-host-missing`.
    public let reason: String
    /// The address a refused `lan` call was going to.
    public let host: String?
    public init(purpose: OutboundPurpose, reason: String, host: String? = nil) {
        self.purpose = purpose; self.reason = reason; self.host = host
    }
    public var description: String { "outbound blocked: \(purpose.rawValue) (\(reason))" }
}

/// May Khayt make this internet call? ("Make no internet calls", P8.)
///
/// ── SWIFT ASKS; THE RULE DECIDES ─────────────────────────────────────────
///
/// Every answer is `lib/outbound.js allowed(settings, purpose, ctx)`, run in
/// a small JavaScript context of this type's own that holds that one file, so
/// a call site anywhere (a poll, a socket, a sender in KhaytCore) can ask
/// synchronously, without the engine's actor and before the engine exists.
/// Nothing here decides: no purpose table, no address ranges, no order of
/// checks.
///
/// ── WHAT IT IS TOLD ──────────────────────────────────────────────────────
///
/// The app tells it two things (`update`): the shop's settings, and what THIS
/// Mac says for itself (its own switch, and its install-count switch). The
/// app's first act at launch is to say the book is `.unread`: from then until
/// the settings are read, every call but `lan` is refused
/// (`settings-unknown`), so a shop that turned the switch on does not leak
/// one call at each launch. A process that never says anything (a test, a
/// tool) has no book, `.none`, which is today's behaviour.
///
/// A refused call is counted per purpose (`blocked`), so the Settings list can
/// say "Blocked 2 times, last at 14:12" without anything being announced.
public final class OutboundGate: @unchecked Sendable {

    /// The app's one gate.
    public static let app = OutboundGate()

    /// A gate for this task and its children only: how a test turns the
    /// switch on for the code it calls without blocking every other suite
    /// running beside it through the app's gate.
    @TaskLocal public static var scoped: OutboundGate?

    /// ── THE OWNER'S ANSWER READS THE SWITCH ONCE ─────────────────────────────
    ///
    /// A person's answer ("Use the newer setting", when the other computer's
    /// value is not held) makes ONE `switch-sync` call even while the shop's
    /// switch is on here. The rule for that is the shared one
    /// (`lib/outbound.js` `answerToken` / `spend`, the same on the desktop):
    /// the gate makes a token when the person answers, hands it to the rule
    /// with the clock, and on the rule's `once: true` keeps the spent token in
    /// its place. So it opens only `switch-sync`, only against the SHOP's
    /// switch (never this Mac's own, never an unread book), once, and for
    /// `ANSWER_MS` at most.
    ///
    /// A token cannot be forged: it has no initialiser a caller can reach,
    /// and is never read from a request, a file or another process. It CAN
    /// be asked for by any code in the app (`answerToken()` is public, since
    /// the app is another module): nothing here ties it to a button. The one
    /// place that asks is the handler of the owner's answer
    /// (`Shop.readNewerSetting`), and `NetworkSwitchWiringTests` holds the
    /// app to that one call site.
    public final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var token: JSONValue
        fileprivate init(_ token: JSONValue) { self.token = token }
        fileprivate var current: JSONValue {
            lock.lock(); defer { lock.unlock() }
            return token
        }
        /// Read the token, ask, and keep what `use` hands back, as ONE step:
        /// two gates asked at the same moment cannot both find it unused.
        fileprivate func using<T>(_ use: (JSONValue) -> (T, JSONValue?)) -> T {
            lock.lock(); defer { lock.unlock() }
            let (result, next) = use(token)
            if let next { token = next }
            return result
        }
    }

    /// The answer this task's ONE `switch-sync` call carries, if a person
    /// just gave one. Set only around that call.
    @TaskLocal public static var answer: Answer?

    /// A token for the answer a person gave just now.
    public func answerToken() -> Answer? {
        lock.lock(); defer { lock.unlock() }
        guard let rule = rule(),
              let token = try? rule.call2("KhaytOutbound.answerToken(ARG0)", [nowMs], as: JSONValue.self) else { return nil }
        return Answer(token)
    }

    /// Whether an answer would still let one call through now: for a test.
    public func answerLive(_ answer: Answer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let rule = rule() else { return false }
        return (try? rule.call2("KhaytOutbound.answerLive(ARG0, ARG1)", [answer.current, nowMs], as: Bool.self)) ?? false
    }

    private var nowMs: JSONValue { .number((clock().timeIntervalSince1970 * 1000).rounded()) }

    /// The gate a call site asks: the task's own when a test gave it one,
    /// else the app's.
    public static var shared: OutboundGate { scoped ?? app }

    /// What the app knows of the shop's settings.
    public enum Book: Sendable, Equatable {
        /// A book exists and has not been read yet: everything but `lan` waits.
        case unread
        /// No book (first run, nothing chosen): as if every setting were absent.
        case none
        /// The book's `settings`.
        case settings(JSONValue)
    }

    /// What this Mac says for itself. It can only be stricter than the shop.
    public struct Local: Sendable, Equatable {
        public var offline: Bool
        public var installCountOff: Bool
        public init(offline: Bool = false, installCountOff: Bool = false) {
            self.offline = offline; self.installCountOff = installCountOff
        }
    }

    /// The rule's answer for one call.
    public struct Verdict: Decodable, Sendable, Equatable {
        public let allowed: Bool
        public let reason: String
        /// The rule let this one call through on a person's answer, and the
        /// answer is now used: only ever set by `require`.
        public var once: Bool? = nil
        public init(allowed: Bool, reason: String, once: Bool? = nil) {
            self.allowed = allowed; self.reason = reason; self.once = once
        }
    }

    /// One row of the Settings list (`describe`).
    public struct Row: Decodable, Sendable, Equatable, Identifiable {
        public let purpose: String
        public let allowed: Bool
        public let reason: String
        public let kept: Bool
        public let automatic: Bool
        public let owner: String
        public var id: String { purpose }
    }

    /// How often a purpose was refused since launch, and when last.
    public struct Blocked: Sendable, Equatable {
        public var count: Int
        public var last: Date
        public init(count: Int, last: Date) { self.count = count; self.last = last }
    }

    private let lock = NSLock()
    private var runtime: JSRuntime?
    private var book: Book = .none
    private var local = Local()
    private var counts: [OutboundPurpose: Blocked] = [:]
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    /// The rule's file, loaded on first use. If it cannot be loaded nothing is
    /// allowed: a gate that cannot ask its rule fails closed.
    private func rule() -> JSRuntime? {
        if let runtime { return runtime }
        runtime = try? JSRuntime(modules: ["outbound"])
        return runtime
    }

    // MARK: - Told by the app

    /// The only settings the rule reads. The gate is asked on every printer
    /// poll, and a shop's settings can carry megabytes (its logo, the
    /// library), so only these are kept and handed to the rule.
    public static let settingsRead = ["network", "telemetry"]

    public func update(book: Book) {
        var kept = book
        if case .settings(.object(let all)) = book {
            kept = .settings(.object(all.filter { Self.settingsRead.contains($0.key) }))
        }
        lock.lock(); defer { lock.unlock() }
        self.book = kept
    }

    public func update(local: Local) {
        lock.lock(); defer { lock.unlock() }
        self.local = local
    }

    public var currentLocal: Local {
        lock.lock(); defer { lock.unlock() }
        return local
    }

    public var currentBook: Book {
        lock.lock(); defer { lock.unlock() }
        return book
    }

    // MARK: - Asked by a call site

    private var settingsArgument: JSONValue {
        switch book {
        case .unread: .null
        case .none: .object([:])
        case .settings(let s): s
        }
    }

    private func context(host: String?) -> JSONValue {
        var ctx: [String: JSONValue] = ["local": .object(["offline": .bool(local.offline),
                                                         "installCountOff": .bool(local.installCountOff)])]
        if let host { ctx["host"] = .string(host) }
        return .object(ctx)
    }

    /// The rule's answer, without counting it: for a screen that only asks.
    public func verdict(_ purpose: OutboundPurpose, host: String? = nil) -> Verdict {
        lock.lock(); defer { lock.unlock() }
        return unlockedVerdict(purpose, host: host)
    }

    /// `answer`: a person's token, handed to the rule only by `require` and
    /// only for `switch-sync`. When the rule says `once`, the token is spent
    /// here, before the lock is given up, so a second call cannot use it.
    private func unlockedVerdict(_ purpose: OutboundPurpose, host: String?, answer: Answer? = nil) -> Verdict {
        guard let rule = rule() else { return Verdict(allowed: false, reason: "settings-unknown") }
        func ask(_ token: JSONValue?) -> Verdict? {
            var ctx = context(host: host)
            if let token, case .object(var o) = ctx {
                o["answer"] = token
                o["now"] = nowMs
                ctx = .object(o)
            }
            return try? rule.call2("KhaytOutbound.allowed(ARG0, ARG1, ARG2)",
                                   [settingsArgument, .string(purpose.rawValue), ctx], as: Verdict.self)
        }
        guard let answer else { return ask(nil) ?? Verdict(allowed: false, reason: "settings-unknown") }
        return answer.using { token in
            guard let verdict = ask(token) else { return (Verdict(allowed: false, reason: "settings-unknown"), nil) }
            guard verdict.allowed, verdict.once == true else { return (verdict, nil) }
            // If the token cannot be marked used, the call is refused: an
            // answer that could be used twice is worse than one not used.
            guard let spent = try? rule.call2("KhaytOutbound.spend(ARG0)", [token], as: JSONValue.self) else {
                return (Verdict(allowed: false, reason: "settings-unknown"), nil)
            }
            return (verdict, spent)
        }
    }

    /// Ask before a call. Throws `OutboundBlocked` when the switch refuses it,
    /// and counts the refusal on its purpose. `host` is where a `lan` call
    /// goes (a name or address, with or without a scheme and port).
    public func require(_ purpose: OutboundPurpose, host: String? = nil) throws {
        lock.lock()
        let answer = unlockedVerdict(purpose, host: host, answer: purpose == .switchSync ? Self.answer : nil)
        if !answer.allowed {
            var entry = counts[purpose] ?? Blocked(count: 0, last: clock())
            entry.count += 1
            entry.last = clock()
            counts[purpose] = entry
        }
        lock.unlock()
        if !answer.allowed { throw OutboundBlocked(purpose: purpose, reason: answer.reason, host: host) }
    }

    /// The same question as a yes or no, counted the same: for a sender that
    /// drops what it would have sent (telemetry) and has nothing to throw to.
    public func allows(_ purpose: OutboundPurpose, host: String? = nil) -> Bool {
        (try? require(purpose, host: host)) != nil
    }

    /// Ask for the host a URL names: the gate for a call to an address the
    /// shop typed (a printer, a camera, a plug).
    public func require(_ purpose: OutboundPurpose, url: URL) throws {
        try require(purpose, host: url.host())
    }

    /// For a service the shop may host itself (ntfy, an SMTP relay): allowed
    /// when its purpose is, and otherwise still allowed when its address is
    /// on the shop's own network, which the switch never blocks. A public
    /// address is refused as `lan-host-public`, so the sentence can say the
    /// address "is not on your shop's network" (frame D).
    public func require(_ purpose: OutboundPurpose, orLanHost host: String?) throws {
        if verdict(purpose).allowed { return }
        do { try require(.lan, host: host) }
        catch let blocked as OutboundBlocked {
            throw OutboundBlocked(purpose: purpose, reason: blocked.reason, host: host)
        }
    }

    public func require(_ purpose: OutboundPurpose, orLan url: URL) throws {
        try require(purpose, orLanHost: url.host())
    }

    // MARK: - For the Settings list

    /// One row per purpose, in the rule's order (`describe`).
    public func rows() -> [Row] {
        lock.lock(); defer { lock.unlock() }
        guard let rule = rule() else { return [] }
        return (try? rule.call2("KhaytOutbound.describe(ARG0, ARG1)", [settingsArgument, context(host: nil)], as: [Row].self)) ?? []
    }

    /// Whether this Mac makes no internet calls now: the shop's switch, or its own.
    /// The SHOP's switch alone, as the rule reads the book (a malformed
    /// `settings.network` is on; `offline: null` is not), whatever this
    /// computer's own switch says.
    public var isShopOffline: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let rule = rule() else { return true }
        let ctx: JSONValue = .object(["local": .object(["offline": .bool(false)])])
        return (try? rule.call2("KhaytOutbound.isOffline(ARG0, ARG1)", [settingsArgument, ctx], as: Bool.self)) ?? true
    }

    public var isOffline: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let rule = rule() else { return true }
        return (try? rule.call2("KhaytOutbound.isOffline(ARG0, ARG1)", [settingsArgument, context(host: nil)], as: Bool.self)) ?? true
    }

    /// The rule's own list of purposes, for the test that holds the enum to it.
    public func rulePurposes() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let rule = rule() else { return [] }
        return (try? rule.call2("KhaytOutbound.PURPOSES", [], as: [String].self)) ?? []
    }

    public func blocked(_ purpose: OutboundPurpose) -> Blocked? {
        lock.lock(); defer { lock.unlock() }
        return counts[purpose]
    }

    public func blockedCounts() -> [OutboundPurpose: Blocked] {
        lock.lock(); defer { lock.unlock() }
        return counts
    }

    /// Forget the counts: the switch was turned off, so nothing is being blocked.
    public func clearCounts() {
        lock.lock(); defer { lock.unlock() }
        counts = [:]
    }
}
