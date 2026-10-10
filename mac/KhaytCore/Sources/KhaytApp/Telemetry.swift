import Foundation
import KhaytCore

/// Opt-in crash reports and usage counts, on the Mac (#1789).
///
/// ── WHAT THIS IS, AND THE RULES IT KEEPS ──────────────────────────────────
///
/// `docs/KHAYT-3.0-TELEMETRY-SPEC.md`, ported. The Mac had no sender and no
/// consent at all, so when it failed in a shop nobody learned of it.
///
/// - **Off by default.** Two separate consents in the book,
///   `settings.telemetry { crashOptIn, usageOptIn, installId, consentAt }` —
///   Electron's fields, so one book means the same thing in both apps.
/// - **Scrubbed by the shared rule.** Every event is built by
///   `lib/telemetry-scrub.js` in JavaScriptCore at the one place an event is
///   queued (`enqueue`), and a scrubber that throws DROPS the event. There is
///   no Swift copy of the scrubber to drift from Electron's.
/// - **Sent by the shared policy.** What a 422, 429 or 404 means for the queue
///   is `lib/telemetry-sender.js`'s `interpret`, and what goes in a batch is its
///   `planFlush`, which checks each stream's consent again at send time.
/// - **Never in anybody's way.** Nothing here throws into the app, shows an
///   error, or blocks: the network is `URLSession`'s async API and the queue
///   file is a few kilobytes.
///
/// The crash feed is `EngineFaults` — the shared rules' failures, which the app
/// otherwise swallows with `try?` — and the note `LastWords` leaves when AppKit
/// kills the app. Usage is one counter, `app_launch`, with the shop's coarse
/// switches (mode, VAT, ZATCA, online, LAN) — counts and enums, never content.
struct TelemetryConsent: Equatable, Sendable {
    var crash = false
    var usage = false
    var installId = ""
    var consentAt = ""

    var any: Bool { crash || usage }

    init(crash: Bool = false, usage: Bool = false, installId: String = "", consentAt: String = "") {
        self.crash = crash; self.usage = usage; self.installId = installId; self.consentAt = consentAt
    }

    /// Read off the book's settings. Anything but a literal `true` is off.
    init(settings: [String: JSONValue]) {
        guard case .object(let t)? = settings["telemetry"] else { return }
        crash = t["crashOptIn"] == .bool(true)
        usage = t["usageOptIn"] == .bool(true)
        if case .string(let s)? = t["installId"] { installId = s }
        if case .string(let s)? = t["consentAt"] { consentAt = s }
    }

    /// The consent after the shop chooses `crash` and `usage` — Electron's
    /// `persist` in `renderer/settings.js`, rule for rule: an install id is made
    /// on the first opt-in and kept while either stream is on; the consent time
    /// is the FIRST opt-in's; with both off, both are cleared.
    static func choosing(crash: Bool, usage: Bool, over was: TelemetryConsent, now: Date,
                         newId: () -> String = { UUID().uuidString.lowercased() }) -> TelemetryConsent {
        guard crash || usage else { return TelemetryConsent() }
        return TelemetryConsent(crash: crash, usage: usage,
                                installId: was.installId.isEmpty ? newId() : was.installId,
                                consentAt: was.consentAt.isEmpty ? Telemetry.stamp(now) : was.consentAt)
    }

    /// Written over whatever `settings.telemetry` held, keeping any key this
    /// build does not know — a newer app's field is not this one's to drop.
    func written(over old: JSONValue?) -> JSONValue {
        var t: [String: JSONValue] = [:]
        if case .object(let o)? = old { t = o }
        t["crashOptIn"] = .bool(crash)
        t["usageOptIn"] = .bool(usage)
        t["installId"] = .string(installId)
        t["consentAt"] = .string(consentAt)
        return .object(t)
    }
}

/// The local queue: `{kind, payload, at}` records, scrubber output only.
///
/// Beside the book, where Electron keeps its own — but in a file of its own
/// (`telemetry-queue-mac.json`), because both apps can be open on one book and
/// two writers of one file lose each other's events.
struct TelemetryQueueFile: Sendable {
    let url: URL

    static let name = "telemetry-queue-mac.json"
    /// Electron's, beside the same book. Only ever deleted from here: opting
    /// out on the Mac is opting the BOOK out, and the spec's promise is that
    /// opting out deletes what is queued.
    static let electronName = "telemetry-queue.json"

    init(url: URL) { self.url = url }
    init(besideStore store: URL) {
        url = store.deletingLastPathComponent().appending(path: Self.name)
    }

    func read() -> [JSONValue] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([JSONValue].self, from: data) else { return [] }
        return list
    }

    func write(_ queue: [JSONValue]) {
        guard !queue.isEmpty else { delete(); return }
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Opting out, or a queue sent to nothing.
    func delete() {
        // lock: system — the app's own diagnostics queue, never a shop's file; deleting it is what opting out promises.
        try? FileManager.default.removeItem(at: url)
    }

    /// Both apps' queues beside this book, for a full opt-out.
    func deleteBoth() {
        delete()
        TelemetryQueueFile(url: url.deletingLastPathComponent().appending(path: Self.electronName)).delete()
    }
}

/// The raw events, before the scrubber. Nothing here is trusted to be clean —
/// that is the scrubber's job — but nothing here reaches for shop data either.
enum TelemetryRaw {

    /// What every event says about where it came from.
    struct Context: Equatable, Sendable {
        var appVersion: String
        var locale: String
        var osMajor: String
        var day: String
        var channel: String { Telemetry.channel(forVersion: appVersion) }
    }

    /// A rule that failed. Not a crash — the app swallowed it with `try?` — so
    /// its type is the scrubber's `unknown` rather than a crash type it is not.
    /// The name is JavaScriptCore's (`TypeError: …` → `TypeError`), and the
    /// "stack" is the SHAPE of the call, which `EngineFaults` already keeps
    /// free of arguments.
    static func crash(problem: String, call: String, _ c: Context) -> [String: JSONValue] {
        var name = "Error"
        if let colon = problem.firstIndex(of: ":") {
            let head = String(problem[..<colon])
            if head.hasSuffix("Error"), head.allSatisfy({ $0.isLetter }) { name = head }
        }
        return common(c).merging([
            "type": .string("unknown"),
            "name": .string(name),
            "message": .string(problem),
            "stack": .string("at " + call),
            "process": .string("main"),
        ]) { _, new in new }
    }

    /// The note `LastWords` left when an uncaught exception killed the app —
    /// which IS a crash, and the kind that arrives with no reason attached.
    /// Nil when the note is not one this app wrote.
    static func crash(note: String, _ c: Context) -> [String: JSONValue]? {
        let lines = note.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func field(_ key: String) -> String? {
            lines.first { $0.hasPrefix(key + ":") }
                .map { String($0.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        guard let what = field("what"), !what.isEmpty else { return nil }
        var frames: [String] = []
        if let at = lines.firstIndex(of: "where:") {
            for line in lines[(at + 1)...] {
                if line.isEmpty || line.hasPrefix("rules that failed") { break }
                frames.append(line)
            }
        }
        return common(c).merging([
            "type": .string("uncaughtException"),
            "name": .string(what),
            "message": .string(field("why") ?? ""),
            "stack": .string(frames.joined(separator: "\n")),
            "process": .string("main"),
        ]) { _, new in new }
    }

    /// A usage counter: the feature, today's running count, and the shop's
    /// coarse switches. The scrubber keeps only its enums and booleans.
    static func usage(feature: String, count: Int, settings: [String: JSONValue], mode: String,
                      _ c: Context) -> [String: JSONValue] {
        func on(_ v: JSONValue?) -> Bool { v == .bool(true) }
        func inner(_ key: String) -> [String: JSONValue] {
            if case .object(let o)? = settings[key] { return o }
            return [:]
        }
        return common(c).merging([
            "feature": .string(feature),
            "count": .number(Double(count)),
            "sessions": .number(Double(count)),
            "mode": .string(mode),
            "businessType": settings["businessType"] ?? .null,
            "vatEnabled": .bool(on(settings["enableVat"])),
            "zatcaEnabled": .bool(on(inner("zatcaPhase2")["enabled"])),
            "onlineEnabled": .bool(on(settings["onlineEnabled"])),
            "lanEnabled": .bool(on(inner("lanApi")["enabled"])),
        ]) { _, new in new }
    }

    private static func common(_ c: Context) -> [String: JSONValue] {
        ["appVersion": .string(c.appVersion), "electronVersion": .string(""),
         "osFamily": .string("macOS"), "osMajor": .string(c.osMajor),
         "locale": .string(c.locale), "channel": .string(c.channel), "at": .string(c.day)]
    }
}

/// The sender, and the one-time ask's memory.
@MainActor @Observable
final class Telemetry {

    static let shared = Telemetry()

    enum Kind: String, Sendable { case crash, usage }

    /// The network, injectable so no test ever reaches the real one.
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    @ObservationIgnored var fetch: Fetch = { try await URLSession.shared.data(for: $0) }
    let defaults: UserDefaults
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var appVersion: String = Feedback.appVersion().version
    /// A `swift run` build has no version and no business filling the shop's
    /// reports with development noise. Tests switch it on.
    @ObservationIgnored var sendsFromThisBuild = Bundle.main.bundleIdentifier != nil

    /// Whether the card has been answered ON THIS MAC — either way. Kept on
    /// the Mac rather than in the book because the store's `telemetry` object
    /// is Electron's four fields and nothing else; "Not now" means this Mac
    /// does not ask again, and the Settings toggles stay the way to change it.
    private(set) var asked: Bool

    static let askedKey = "telemetry.asked"
    static let crashNoteKey = "telemetry.reportedCrashNote"
    static let tallyKey = "telemetry.usageTally"
    static let keep = 200
    static let firstFlush: TimeInterval = 60
    static let flushEvery: TimeInterval = 3600
    static let tickEvery: Duration = .seconds(60)

    @ObservationIgnored private(set) var backoffMs = 0.0
    @ObservationIgnored private(set) var nextAttemptAtMs = 0.0
    @ObservationIgnored private var nextFlushAt = Date.distantFuture
    @ObservationIgnored private var faultCursor = Date.distantPast
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        asked = defaults.bool(forKey: Self.askedKey)
    }

    // MARK: Small facts

    /// The channel the ingest knows: `stable`, `beta` or `alpha` (khayt-cloud
    /// #114 added `alpha`; anything else is a 422 and the batch is dropped).
    /// A version naming `alpha` is the 4.0 alpha lane; any other pre-release,
    /// or a development build with no version, is `beta`.
    nonisolated static func channel(forVersion v: String) -> String {
        if v.isEmpty || !(v.first?.isNumber ?? false) { return "beta" }
        if let dash = v.firstIndex(of: "-") {
            return v[dash...].lowercased().contains("alpha") ? "alpha" : "beta"
        }
        return "stable"
    }

    /// A UTC timestamp, Gregorian whatever the Mac's own calendar is.
    nonisolated static func stamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    nonisolated static func day(_ d: Date) -> String { String(stamp(d).prefix(10)) }

    func context(language: String) -> TelemetryRaw.Context {
        TelemetryRaw.Context(appVersion: appVersion,
                             locale: language,
                             osMajor: String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
                             day: Self.day(now()))
    }

    func markAsked() {
        asked = true
        defaults.set(true, forKey: Self.askedKey)
    }

    // MARK: The one choke point

    /// Scrub and queue one event — only with that stream's consent, only as
    /// the scrubber built it, and not at all if the scrubber throws.
    @discardableResult
    func enqueue(_ kind: Kind, _ raw: [String: JSONValue], consent: TelemetryConsent,
                 engine: KhaytEngine, file: TelemetryQueueFile) async -> Bool {
        guard kind == .crash ? consent.crash : consent.usage else { return false }
        var raw = raw
        raw["installId"] = .string(consent.installId)
        let payload: [String: JSONValue]?
        do {
            payload = kind == .crash ? try await engine.telemetryCrashReport(raw)
                                     : try await engine.telemetryUsageEvent(raw)
        } catch {
            return false   // fail closed
        }
        guard let payload else { return false }
        var queue = file.read()
        // A usage counter carries the DAY'S RUNNING COUNT, and the ingest keeps
        // the larger of two for one day and feature. So the newer one replaces
        // any still queued rather than sitting beside it.
        if kind == .usage {
            queue.removeAll { Self.sameCounter($0, payload) }
        }
        queue.append(.object(["kind": .string(kind.rawValue), "payload": .object(payload),
                              "at": .string(Self.stamp(now()))]))
        guard let tidy = try? await engine.telemetryTidy(queue, keep: Self.keep) else { return false }
        file.write(tidy)
        return true
    }

    private static func sameCounter(_ e: JSONValue, _ p: [String: JSONValue]) -> Bool {
        guard case .object(let o) = e, o["kind"] == .string("usage"),
              case .object(let q)? = o["payload"] else { return false }
        return q["feature"] == p["feature"] && q["at"] == p["at"] && q["appVersion"] == p["appVersion"]
    }

    /// Today's running count for `feature` on this Mac, after this one.
    func tally(_ feature: String) -> Int {
        let today = Self.day(now())
        var all = (defaults.dictionary(forKey: Self.tallyKey) as? [String: Int]) ?? [:]
        all = all.filter { $0.key.hasPrefix(today + "|") }   // yesterday is gone
        let key = today + "|" + feature
        let n = (all[key] ?? 0) + 1
        all[key] = n
        defaults.set(all, forKey: Self.tallyKey)
        return n
    }

    // MARK: Sending

    /// One flush: the shared plan, one POST, the shared verdict. Returns the
    /// reason, for a test and for nothing else — telemetry never says anything
    /// on screen about itself.
    @discardableResult
    func flush(consent: TelemetryConsent, engine: KhaytEngine, file: TelemetryQueueFile) async -> String {
        guard sendsFromThisBuild else { return "development-build" }
        let nowMs = now().timeIntervalSince1970 * 1000
        guard let plan = try? await engine.telemetryPlan(queue: file.read(), crash: consent.crash,
                                                         usage: consent.usage, nowMs: nowMs,
                                                         nextAttemptAtMs: nextAttemptAtMs)
        else { return "unplanned" }
        guard plan.send, let batch = plan.batch, !batch.isEmpty else { return plan.reason ?? "empty" }
        guard let endpoint = try? await engine.telemetryEndpoint(), let url = URL(string: endpoint)
        else { return "unplanned" }

        // `{kind, payload}` only — the queue's own `at` is when it was queued,
        // which the ingest has no field for.
        let events: [JSONValue] = batch.map { e in
            guard case .object(let o) = e else { return .null }
            return .object(["kind": o["kind"] ?? .null, "payload": o["payload"] ?? .null])
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Not identity: so an operator reading access logs can tell Khayt's own
        // traffic from whatever else finds an open POST route.
        request.setValue("Khayt/\(appVersion) (Mac)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONEncoder().encode(JSONValue.object(["events": .array(events)]))

        let status: Int
        var retryAfter: Double?
        do {
            let (_, response) = try await fetch(request)
            let http = response as? HTTPURLResponse
            status = http?.statusCode ?? 0
            retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        } catch {
            // Offline, DNS, TLS, a captive portal: keep everything, wait longer.
            status = 0
        }
        guard let verdict = try? await engine.telemetryVerdict(status: status, retryAfterSec: retryAfter,
                                                               backoffMs: backoffMs)
        else { return "unplanned" }
        if verdict.drop {
            // Exactly what was sent, from the queue as it is NOW — something
            // may have been queued while the request was out.
            var queue = file.read()
            for sent in batch {
                if let i = queue.firstIndex(of: sent) { queue.remove(at: i) }
            }
            file.write(queue)
        }
        backoffMs = verdict.backoffMs
        nextAttemptAtMs = verdict.backoffMs > 0 ? nowMs + verdict.backoffMs : 0
        return status == 0 ? "unreachable" : verdict.reason
    }

    // MARK: Consent changing

    /// The book's consent changed. A stream switched off takes its queued
    /// events with it at once; both off deletes the queue (both apps'). A
    /// stream switched on gets a flush a minute from now, so opting in shows
    /// up in the cloud's report today rather than in an hour.
    func consentChanged(to consent: TelemetryConsent, from was: TelemetryConsent, file: TelemetryQueueFile) {
        if !consent.any {
            file.deleteBoth()
            backoffMs = 0; nextAttemptAtMs = 0
            return
        }
        if !consent.crash || !consent.usage {
            let kept = file.read().filter { e in
                guard case .object(let o) = e, case .string(let k)? = o["kind"] else { return false }
                return k == "crash" ? consent.crash : consent.usage
            }
            file.write(kept)
        }
        if (consent.crash && !was.crash) || (consent.usage && !was.usage) {
            nextFlushAt = min(nextFlushAt, now().addingTimeInterval(Self.firstFlush))
        }
    }

    /// The queue as it would be sent, for "View what's collected".
    func pending(file: TelemetryQueueFile) -> String? {
        let events: [JSONValue] = file.read().compactMap { e in
            guard case .object(let o) = e else { return nil }
            return .object(["kind": o["kind"] ?? .null, "payload": o["payload"] ?? .null])
        }
        guard !events.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(events)).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: The shop's side

    /// The queue beside the book the shop has open. Nil for the sample.
    static func file(for shop: Shop) -> TelemetryQueueFile? {
        shop.source.build.map { TelemetryQueueFile(besideStore: $0.storeURL) }
    }

    /// Begin: count this launch, report a crash the last run left behind, then
    /// look once a minute — collect new faults, and flush when one is due: a
    /// minute in, then hourly. Everything on the main actor with `await`s that
    /// suspend; nothing blocks a thread, so nothing here can starve a pool.
    func start(shop: Shop) {
        guard loop == nil else { return }
        nextFlushAt = now().addingTimeInterval(Self.firstFlush)
        loop = Task { [weak self, weak shop] in
            guard let self, let shop else { return }
            await self.recordLaunch(shop)
            await self.collect(shop)
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickEvery)
                await self.tick(shop)
            }
        }
    }

    private func tick(_ shop: Shop) async {
        await collect(shop)
        guard now() >= nextFlushAt, let engine = shop.engine, let file = Self.file(for: shop) else { return }
        nextFlushAt = now().addingTimeInterval(Self.flushEvery)
        await flush(consent: shop.telemetryConsent, engine: engine, file: file)
    }

    /// One `app_launch`, with today's running count.
    func recordLaunch(_ shop: Shop) async {
        let consent = shop.telemetryConsent
        guard consent.usage, let engine = shop.engine, let file = Self.file(for: shop) else { return }
        let raw = TelemetryRaw.usage(feature: "app_launch", count: tally("app_launch"),
                                     settings: shop.settingsDict, mode: shop.mode,
                                     context(language: shop.words.language))
        await enqueue(.usage, raw, consent: consent, engine: engine, file: file)
    }

    /// The rules' failures since the last look, and the last run's crash note.
    func collect(_ shop: Shop) async {
        let consent = shop.telemetryConsent
        let faults = EngineFaults.recent().filter { $0.at > faultCursor }
        faultCursor = faults.last?.at ?? faultCursor
        guard consent.crash, let engine = shop.engine, let file = Self.file(for: shop) else { return }
        let c = context(language: shop.words.language)
        if let note = shop.lastCrash, defaults.string(forKey: Self.crashNoteKey) != Self.noteId(note) {
            defaults.set(Self.noteId(note), forKey: Self.crashNoteKey)
            if let raw = TelemetryRaw.crash(note: note, c) {
                await enqueue(.crash, raw, consent: consent, engine: engine, file: file)
            }
        }
        for fault in faults.suffix(20) {
            await enqueue(.crash, TelemetryRaw.crash(problem: fault.problem, call: fault.call, c), consent: consent, engine: engine, file: file)
        }
        // A fault the scrubbing itself raised is not news, and reporting it
        // would only raise another: the cursor moves past everything up to now.
        faultCursor = max(faultCursor, now())
    }

    /// Which note this is — its `when:` line, which `LastWords` writes first.
    static func noteId(_ note: String) -> String {
        note.components(separatedBy: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("when:") }
            ?? String(note.prefix(120))
    }

    // MARK: The card

    /// Whether to put the one-time card up now: on the shop's own book, to
    /// somebody allowed to change its settings, never asked on this Mac, with
    /// nothing already on — and not over the new-shop setup.
    func shouldAsk(_ shop: Shop) -> Bool {
        !asked && shop.source.isReal && shop.canWrite && !shop.settingUpShop
            && !shop.telemetryConsent.any && shop.lockAllows("settings", "edit")
    }
}

extension Shop {

    var telemetryConsent: TelemetryConsent { TelemetryConsent(settings: settingsDict) }

    /// Choose the two consents — the card's buttons and the Settings toggles.
    /// The staff lock decides, as for every other setting.
    @discardableResult
    func setTelemetry(crash: Bool, usage: Bool) async -> Bool {
        writeProblem = nil
        guard source.isReal else { writeProblem = words.callIt("mac.move_sample"); return false }
        guard permitted("settings", "edit") else { return false }
        guard let build = source.build else { return false }
        let was = telemetryConsent
        var chosen = was
        do {
            try StoreWriter.update(build) { root in
                var settings = Self.settings(root)
                let stored = TelemetryConsent(settings: settings)
                chosen = TelemetryConsent.choosing(crash: crash, usage: usage, over: stored, now: Date())
                settings["telemetry"] = chosen.written(over: settings["telemetry"])
                root["settings"] = .object(settings)
            }
        } catch {
            writeProblem = String(describing: error)
            return false
        }
        // Any choice answers the one-time ask, wherever it was made.
        Telemetry.shared.markAsked()
        if let file = Telemetry.file(for: self) {
            Telemetry.shared.consentChanged(to: chosen, from: was, file: file)
        }
        await load(source)
        // Turned on mid-session: this launch counts.
        if chosen.usage && !was.usage { await Telemetry.shared.recordLaunch(self) }
        return true
    }
}
