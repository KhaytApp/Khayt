import Foundation
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// Opt-in crash reports and usage counts on the Mac (#1789).
///
/// No test here reaches the network: every send goes through an injected
/// `fetch`, which records the request and answers with a chosen status. The
/// scrubbing is the REAL `lib/telemetry-scrub.js`, run in JavaScriptCore,
/// because the point of the design is that there is no second scrubber to
/// test instead.
@Suite(.serialized) @MainActor
struct TelemetryTests {

    static let engine: KhaytEngine = try! KhaytEngine()

    /// A sender with its own defaults, its own queue file, a pinned clock and
    /// a fetch that answers `status` and records what it was given.
    final class Rig {
        let telemetry: Telemetry
        let file: TelemetryQueueFile
        let dir: URL
        var requests: [URLRequest] = []
        var status = 200
        var fails = false

        @MainActor init() {
            dir = FileManager.default.temporaryDirectory.appending(path: "khayt-tel-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            file = TelemetryQueueFile(besideStore: dir.appending(path: "khayt-store.json"))
            telemetry = Telemetry(defaults: UserDefaults(suiteName: "khayt.tel.test.\(UUID().uuidString)")!)
            telemetry.sendsFromThisBuild = true
            telemetry.appVersion = "4.0.0-alpha.64"
            telemetry.now = { Date(timeIntervalSince1970: 1_791_000_000) }   // 2026-10-03
            let box = Box(rig: self)
            telemetry.fetch = { request in
                try await box.answer(request)
            }
        }

        /// The fetch closure is `@Sendable`; the rig is main-actor state.
        final class Box: @unchecked Sendable {
            weak var rig: Rig?
            init(rig: Rig) { self.rig = rig }
            func answer(_ request: URLRequest) async throws -> (Data, URLResponse) {
                try await MainActor.run {
                    guard let rig else { throw URLError(.cancelled) }
                    rig.requests.append(request)
                    if rig.fails { throw URLError(.notConnectedToInternet) }
                    return (Data(#"{"ok":true}"#.utf8),
                            HTTPURLResponse(url: request.url!, statusCode: rig.status,
                                            httpVersion: nil, headerFields: nil)!)
                }
            }
        }

        func sentEvents(_ i: Int = 0) throws -> [[String: Any]] {
            let body = try #require(requests[i].httpBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try #require(json["events"] as? [[String: Any]])
        }
    }

    static let both = TelemetryConsent(crash: true, usage: true, installId: "0f1e2d3c-aaaa-bbbb-cccc-1234567890ab",
                                       consentAt: "2026-10-01T09:00:00.000Z")
    static let context = TelemetryRaw.Context(appVersion: "4.0.0-alpha.64", locale: "ar", osMajor: "26",
                                              day: "2026-10-03")

    static func fault(_ problem: String) -> [String: JSONValue] {
        TelemetryRaw.crash(problem: problem, call: "KhaytTax.profile(…)", context)
    }

    // MARK: Consent

    @Test("off by default: a book with no telemetry object, or a partial one, consents to nothing")
    func offByDefault() {
        #expect(!TelemetryConsent(settings: [:]).any)
        #expect(!TelemetryConsent(settings: ["telemetry": .object([:])]).any)
        #expect(!TelemetryConsent(settings: ["telemetry": .object(["crashOptIn": .string("yes")])]).any)
    }

    @Test("choosing follows Electron's persist: id and time on opt-in, kept while on, cleared when both off")
    func choosing() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let first = TelemetryConsent.choosing(crash: true, usage: false, over: TelemetryConsent(), now: now,
                                              newId: { "11111111-2222-3333-4444-555555555555" })
        #expect(first.crash && !first.usage)
        #expect(first.installId == "11111111-2222-3333-4444-555555555555")
        #expect(first.consentAt.hasPrefix("2026-10-0"))
        let more = TelemetryConsent.choosing(crash: true, usage: true, over: first, now: now.addingTimeInterval(9_999),
                                             newId: { "should-not-be-used" })
        #expect(more.installId == first.installId && more.consentAt == first.consentAt)
        let off = TelemetryConsent.choosing(crash: false, usage: false, over: more, now: now)
        #expect(off == TelemetryConsent())
        // A real id is a UUID the scrubber and the ingest both accept.
        let real = TelemetryConsent.choosing(crash: true, usage: false, over: TelemetryConsent(), now: now)
        #expect(real.installId.wholeMatch(of: /[a-f0-9-]{36}/) != nil)
    }

    @Test("the book keeps Electron's four fields and any it does not know")
    func writtenShape() {
        let out = Self.both.written(over: .object(["futureField": .number(1)]))
        guard case .object(let o) = out else { Issue.record("not an object"); return }
        #expect(Set(o.keys) == ["crashOptIn", "usageOptIn", "installId", "consentAt", "futureField"])
        #expect(TelemetryConsent(settings: ["telemetry": out]) == Self.both)
    }

    // MARK: Scrubbing through the shared rule

    @Test("a fault is scrubbed by lib/telemetry-scrub.js: no email, phone, IBAN or path survives")
    func faultIsScrubbed() async throws {
        let problem = "TypeError: cannot read 'x' of sara.noor@example.com +966501234567 "
            + "SA0380000000608010167519 at /Users/turki/Library/Application Support/Khayt/khayt-store.json"
        let raw = Self.fault(problem)
        let report = try await Self.engine.telemetryCrashReport(raw.merging(["installId": .string(Self.both.installId)]) { _, n in n })
        let text = String(describing: report)
        for leak in ["sara.noor", "966501234567", "SA0380000000608010167519", "/Users/turki", "turki"] {
            #expect(!text.contains(leak), "\(leak) survived scrubbing")
        }
        #expect(report["name"] == .string("TypeError"))
        #expect(report["osFamily"] == .string("macOS"))
        #expect(report["channel"] == .string("alpha"))
        #expect(report["locale"] == .string("ar"))
        #expect(Set(report.keys) == Set(["type", "name", "message", "stack", "process", "appVersion",
                                         "electronVersion", "osFamily", "osMajor", "locale", "channel",
                                         "installId", "at"]))
    }

    @Test("a field nobody allowed never survives the allowlist")
    func allowlist() async throws {
        var raw = Self.fault("Error: x")
        raw["customer"] = .string("Najd Architects")
        raw["settings"] = .object(["smtpPassword": .string("hunter2")])
        let report = try await Self.engine.telemetryCrashReport(raw)
        #expect(report["customer"] == nil && report["settings"] == nil)
        #expect(!String(describing: report).contains("hunter2"))
    }

    @Test("the last crash note becomes an uncaught-exception report")
    func crashNote() {
        let note = """
            Khayt for Mac stopped unexpectedly.

            when:   2026-10-02T08:00:00Z
            what:   NSGenericException
            why:    The window has been marked as needing another Update Constraints in Window pass

            where:
            0   CoreFoundation   0x0000000186a2 __exceptionPreprocess + 164
            1   libobjc.A.dylib  0x00000001861e objc_exception_throw + 60

            rules that failed before this (newest last):
            (none)
            """
        let raw = try! #require(TelemetryRaw.crash(note: note, Self.context))
        #expect(raw["type"] == .string("uncaughtException"))
        #expect(raw["name"] == .string("NSGenericException"))
        #expect(raw["message"] == .string("The window has been marked as needing another Update Constraints in Window pass"))
        guard case .string(let stack)? = raw["stack"] else { Issue.record("no stack"); return }
        #expect(stack.components(separatedBy: "\n").count == 2)
        #expect(!stack.contains("rules that failed"))
        #expect(TelemetryRaw.crash(note: "something else entirely", Self.context) == nil)
    }

    @Test("usage carries counts and switches, never content")
    func usageShape() async throws {
        let settings: [String: JSONValue] = ["enableVat": .bool(true), "businessType": .string("shop"),
                                             "zatcaPhase2": .object(["enabled": .bool(true), "csid": .string("SECRET")]),
                                             "shopName": .string("Najd Prints")]
        let raw = TelemetryRaw.usage(feature: "app_launch", count: 3, settings: settings, mode: "professional",
                                     Self.context)
        let event = try #require(try await Self.engine.telemetryUsageEvent(raw))
        #expect(event["count"] == .number(3) && event["vatEnabled"] == .bool(true))
        #expect(event["zatcaEnabled"] == .bool(true) && event["businessType"] == .string("shop"))
        #expect(!String(describing: event).contains("Najd") && !String(describing: event).contains("SECRET"))
    }

    // MARK: The queue

    @Test("nothing is queued for a stream without its consent")
    func enqueueNeedsConsent() async {
        let rig = Rig()
        let raw = Self.fault("Error: x")
        #expect(!(await rig.telemetry.enqueue(.crash, raw, consent: TelemetryConsent(), engine: Self.engine, file: rig.file)))
        let usageOnly = TelemetryConsent(crash: false, usage: true, installId: Self.both.installId)
        #expect(!(await rig.telemetry.enqueue(.crash, raw, consent: usageOnly, engine: Self.engine, file: rig.file)))
        #expect(rig.file.read().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rig.file.url.path))
    }

    @Test("a usage counter carries the day's running count and replaces the one still queued")
    func runningCount() async {
        let rig = Rig()
        for _ in 0..<3 {
            let n = rig.telemetry.tally("app_launch")
            let raw = TelemetryRaw.usage(feature: "app_launch", count: n, settings: [:], mode: "simple", Self.context)
            await rig.telemetry.enqueue(.usage, raw, consent: Self.both, engine: Self.engine, file: rig.file)
        }
        let queue = rig.file.read()
        #expect(queue.count == 1)
        guard case .object(let e)? = queue.first, case .object(let p)? = e["payload"] else {
            Issue.record("no event"); return
        }
        #expect(p["count"] == .number(3))
        #expect(p["installId"] == .string(Self.both.installId))
    }

    @Test("the same crash twice is queued once")
    func crashesDedupe() async {
        let rig = Rig()
        let raw = Self.fault("Error: same")
        await rig.telemetry.enqueue(.crash, raw, consent: Self.both, engine: Self.engine, file: rig.file)
        await rig.telemetry.enqueue(.crash, raw, consent: Self.both, engine: Self.engine, file: rig.file)
        #expect(rig.file.read().count == 1)
    }

    // MARK: Sending

    @Test("with both streams off, nothing is ever sent")
    func noConsentNoRequest() async {
        let rig = Rig()
        await rig.telemetry.enqueue(.crash, Self.fault("Error: x"),
                                    consent: Self.both, engine: Self.engine, file: rig.file)
        let reason = await rig.telemetry.flush(consent: TelemetryConsent(), engine: Self.engine, file: rig.file)
        #expect(reason == "no-consent")
        #expect(rig.requests.isEmpty)
    }

    @Test("a development build sends nothing even with consent")
    func devBuildIsQuiet() async {
        let rig = Rig()
        rig.telemetry.sendsFromThisBuild = false
        await rig.telemetry.enqueue(.crash, Self.fault("Error: x"),
                                    consent: Self.both, engine: Self.engine, file: rig.file)
        _ = await rig.telemetry.flush(consent: Self.both, engine: Self.engine, file: rig.file)
        #expect(rig.requests.isEmpty)
    }

    @Test("a 200 POSTs {events:[{kind,payload}]} to Khayt's ingest and empties the queue")
    func accepted() async throws {
        let rig = Rig()
        await rig.telemetry.enqueue(.crash, Self.fault("Error: x"),
                                    consent: Self.both, engine: Self.engine, file: rig.file)
        let reason = await rig.telemetry.flush(consent: Self.both, engine: Self.engine, file: rig.file)
        #expect(reason == "accepted")
        let request = try #require(rig.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://cloud.khaytapp.com/v1/telemetry")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let events = try rig.sentEvents()
        #expect(events.count == 1)
        #expect(Set(events[0].keys) == ["kind", "payload"])
        #expect(events[0]["kind"] as? String == "crash")
        #expect(rig.file.read().isEmpty)
    }

    @Test("a 422 drops the batch rather than retrying it forever")
    func refusedIsDropped() async {
        let rig = Rig()
        rig.status = 422
        await rig.telemetry.enqueue(.crash, Self.fault("Error: x"),
                                    consent: Self.both, engine: Self.engine, file: rig.file)
        let reason = await rig.telemetry.flush(consent: Self.both, engine: Self.engine, file: rig.file)
        #expect(reason == "refused")
        #expect(rig.file.read().isEmpty)
    }

    @Test("a 404 keeps the queue and backs off a long way; the next flush inside it sends nothing")
    func dormantIngestBacksOff() async {
        let rig = Rig()
        rig.status = 404
        await rig.telemetry.enqueue(.crash, Self.fault("Error: x"),
                                    consent: Self.both, engine: Self.engine, file: rig.file)
        #expect(await rig.telemetry.flush(consent: Self.both, engine: Self.engine, file: rig.file) == "not-enabled")
        #expect(rig.file.read().count == 1)
        #expect(rig.telemetry.backoffMs == 12 * 60 * 60 * 1000)
        #expect(await rig.telemetry.flush(consent: Self.both, engine: Self.engine, file: rig.file) == "backoff")
        #expect(rig.requests.count == 1)
    }

    @Test("offline keeps everything and waits")
    func offline() async {
        let rig = Rig()
        rig.fails = true
        await rig.telemetry.enqueue(.crash, Self.fault("Error: x"),
                                    consent: Self.both, engine: Self.engine, file: rig.file)
        #expect(await rig.telemetry.flush(consent: Self.both, engine: Self.engine, file: rig.file) == "unreachable")
        #expect(rig.file.read().count == 1)
        #expect(rig.telemetry.backoffMs > 0)
    }

    @Test("consent is checked again at send time: crash only sends no usage")
    func perStreamAtSend() async throws {
        let rig = Rig()
        await rig.telemetry.enqueue(.crash, Self.fault("Error: x"),
                                    consent: Self.both, engine: Self.engine, file: rig.file)
        await rig.telemetry.enqueue(.usage, TelemetryRaw.usage(feature: "app_launch", count: 1, settings: [:],
                                                               mode: "simple", Self.context),
                                    consent: Self.both, engine: Self.engine, file: rig.file)
        let crashOnly = TelemetryConsent(crash: true, usage: false, installId: Self.both.installId)
        _ = await rig.telemetry.flush(consent: crashOnly, engine: Self.engine, file: rig.file)
        let events = try rig.sentEvents()
        #expect(events.map { $0["kind"] as? String } == ["crash"])
    }

    // MARK: Opting out

    @Test("switching a stream off deletes its queued events; both off deletes both apps' queues")
    func optOutPurges() async {
        let rig = Rig()
        await rig.telemetry.enqueue(.crash, Self.fault("Error: x"),
                                    consent: Self.both, engine: Self.engine, file: rig.file)
        await rig.telemetry.enqueue(.usage, TelemetryRaw.usage(feature: "app_launch", count: 1, settings: [:],
                                                               mode: "simple", Self.context),
                                    consent: Self.both, engine: Self.engine, file: rig.file)
        let crashOnly = TelemetryConsent(crash: true, usage: false, installId: Self.both.installId)
        rig.telemetry.consentChanged(to: crashOnly, from: Self.both, file: rig.file)
        #expect(rig.file.read().count == 1)

        let electron = rig.dir.appending(path: TelemetryQueueFile.electronName)
        try? Data("[]".utf8).write(to: electron)
        rig.telemetry.consentChanged(to: TelemetryConsent(), from: crashOnly, file: rig.file)
        #expect(!FileManager.default.fileExists(atPath: rig.file.url.path))
        #expect(!FileManager.default.fileExists(atPath: electron.path))
    }

    @Test("the sample book cannot be opted in, and nothing is written")
    func sampleRefuses() async {
        let shop = Shop()
        shop.useEngine(Self.engine)
        await shop.load(.sample)
        #expect(!(await shop.setTelemetry(crash: true, usage: true)))
        #expect(!shop.telemetryConsent.any)
        #expect(!Telemetry.shared.shouldAsk(shop))
    }

    // MARK: Small facts

    @Test("the Mac's alpha lane reports as beta; a release as stable")
    func channels() {
        #expect(Telemetry.channel(forVersion: "4.0.0-alpha.63") == "alpha")
        #expect(Telemetry.channel(forVersion: "4.0.0-beta.1") == "beta")
        #expect(Telemetry.channel(forVersion: "4.0.0") == "stable")
        #expect(Telemetry.channel(forVersion: "development build") == "beta")
    }

    @Test("the day is Gregorian UTC whatever the Mac's calendar")
    func dayIsGregorian() {
        #expect(Telemetry.day(Date(timeIntervalSince1970: 1_791_000_000)) == "2026-10-03")
    }

    @Test("\"Not now\" is remembered on this Mac")
    func notNowRemembered() {
        let defaults = UserDefaults(suiteName: "khayt.tel.ask.\(UUID().uuidString)")!
        let first = Telemetry(defaults: defaults)
        #expect(!first.asked)
        first.markAsked()
        #expect(Telemetry(defaults: defaults).asked)
    }

    // MARK: Words

    @Test("the card's words are in both languages, Western digits, and collide with nothing")
    func words() async throws {
        let base = Words.own.filter { TelemetryWords.table[$0.key] == nil }
        for (key, langs) in TelemetryWords.table {
            #expect(!(langs["en"] ?? "").isEmpty && !(langs["ar"] ?? "").isEmpty, "\(key)")
            #expect((langs["ar"] ?? "").range(of: "[٠-٩]", options: .regularExpression) == nil, "\(key)")
            #expect(Words.own[key] == langs, "\(key) is shadowed by another table")
            #expect(base[key] == nil)
        }
        // The Settings switches borrow Khayt's own words, in both languages.
        for language in ["en", "ar"] {
            let khayt = try await Self.engine.translations(language: language)
            for key in ["tel.section", "tel.hint", "tel.crash", "tel.crash_hint", "tel.usage",
                        "tel.usage_hint", "tel.view", "tel.view_hint", "tel.nothing"] {
                #expect(!(khayt[key] ?? "").isEmpty, "\(key) missing in \(language)")
            }
        }
    }

    // MARK: Pictures

    /// The card at the narrowest content width the window allows (900pt less
    /// the sidebar) and a wide one, light and dark. Run with `KHAYT_LANG=ar`
    /// for the right-to-left set. Only with `KHAYT_SNAPSHOT_DIR` set.
    @Test("the card and the Settings switches, light and dark, narrow and wide")
    func pictures() async throws {
        guard SnapshotTests.outputDir != nil else { return }
        let shop = Shop()
        shop.useEngine(Self.engine)
        await shop.load(.sample)
        let lang = Direction.shopLanguage()
        for width: CGFloat in [520, 680, 1100] {
            let card = TelemetryCard(shop: shop, shown: true).frame(width: width)
            try SnapshotTests().render(card.background(Khayt.ground), "tel-card-\(Int(width))-\(lang)-light",
                                       size: CGSize(width: width, height: 240))
            try SnapshotTests().renderDark(card, "tel-card-\(Int(width))-\(lang)-dark",
                                           size: CGSize(width: width, height: 240))
        }
        // `ImageRenderer` cannot host a `Form`, so the section is drawn in a
        // stack — the same rows, without the grouped background.
        let settings = VStack(alignment: .leading, spacing: 10) { TelemetrySettings(shop: shop) }
            .padding(16).frame(width: 560, alignment: .leading)
        try SnapshotTests().render(settings.background(Khayt.ground), "tel-settings-\(lang)-light",
                                   size: CGSize(width: 560, height: 300))
        try SnapshotTests().renderDark(settings, "tel-settings-\(lang)-dark", size: CGSize(width: 560, height: 300))
    }
}
