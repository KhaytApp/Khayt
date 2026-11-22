import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The feature counters (`TelemetryFeature`, `Telemetry.feature`): which
/// names can be counted, that nothing is counted without consent, how the
/// day's tally moves, and that every name is counted SOMEWHERE — a counter
/// declared and never wired reports a feature nobody uses.
///
/// The scrubbing is the real `lib/telemetry-scrub.js` in JavaScriptCore, as
/// in `TelemetryTests`, and the sender is that suite's `Rig`: no network.
@Suite(.serialized) @MainActor
struct TelemetryFeatureTests {

    typealias Rig = TelemetryTests.Rig
    static var engine: KhaytEngine { TelemetryTests.engine }
    static let both = TelemetryTests.both

    /// Count `feature` through the test seam and wait for it to be queued.
    @discardableResult
    static func count(_ feature: TelemetryFeature, _ rig: Rig,
                      consent: TelemetryConsent = both) async -> Bool {
        guard let task = rig.telemetry.feature(feature, consent: consent, engine: engine, file: rig.file,
                                               settings: [:], mode: "simple", language: "en")
        else { return false }
        return await task.value
    }

    static func queued(_ rig: Rig) -> [[String: JSONValue]] {
        rig.file.read().compactMap { e in
            guard case .object(let o) = e, case .object(let p)? = o["payload"] else { return nil }
            return p
        }
    }

    // MARK: Names

    @Test("every feature name passes the shared scrubber unchanged")
    func namesPassTheScrubber() async throws {
        #expect(TelemetryFeature.allCases.count >= 15)
        for feature in TelemetryFeature.allCases {
            let name = feature.rawValue
            #expect(name.wholeMatch(of: /[a-z0-9_]+/) != nil, "\(name)")
            #expect(name.count <= 40, "\(name)")
            let raw = TelemetryRaw.usage(feature: name, count: 1, settings: [:], mode: "simple",
                                         TelemetryTests.context)
            let event = try await Self.engine.telemetryUsageEvent(raw)
            #expect(event?["feature"] == .string(name), "the scrubber dropped or changed \(name)")
        }
        #expect(Set(TelemetryFeature.allCases.map(\.rawValue)).count == TelemetryFeature.allCases.count)
        #expect(!TelemetryFeature.allCases.map(\.rawValue).contains("app_launch"),
                "app_launch is the launch counter's, not a feature's")
    }

    /// The privacy page names these three as examples of what is counted.
    @Test("the counters /privacy names exist")
    func privacyExamples() {
        let names = Set(TelemetryFeature.allCases.map(\.rawValue))
        for name in ["quote_created", "invoice_exported", "library_import"] {
            #expect(names.contains(name), "\(name)")
        }
    }

    // MARK: Consent

    @Test("without usage consent nothing is tallied, queued or started")
    func noConsentNoTally() async {
        let rig = Rig()
        let crashOnly = TelemetryConsent(crash: true, usage: false, installId: Self.both.installId)
        for consent in [TelemetryConsent(), crashOnly] {
            #expect(rig.telemetry.feature(.quoteCreated, consent: consent, engine: Self.engine, file: rig.file,
                                          settings: [:], mode: "simple", language: "en") == nil)
        }
        #expect(rig.telemetry.defaults.dictionary(forKey: Telemetry.tallyKey) == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.file.url.path))
    }

    @Test("the sample book counts nothing, consent or not")
    func sampleCountsNothing() async {
        let shop = Shop()
        shop.useEngine(Self.engine)
        await shop.load(.sample)
        #expect(Telemetry.feature(.orderCreated, in: shop) == nil)
        #expect(Telemetry.feature(.orderCreated, in: nil) == nil)
    }

    // MARK: The tally and the queue

    @Test("the tally counts up within a day and starts again on the next")
    func tallyPerDay() async {
        let rig = Rig()
        var clock = Date(timeIntervalSince1970: 1_791_000_000)   // 2026-10-03
        rig.telemetry.now = { clock }
        await Self.count(.orderMoved, rig)
        await Self.count(.orderMoved, rig)
        await Self.count(.orderMoved, rig)
        #expect(Self.queued(rig).first { $0["feature"] == .string("order_moved") }?["count"] == .number(3))

        clock = clock.addingTimeInterval(86_400)                     // 2026-10-04
        await Self.count(.orderMoved, rig)
        let tally = rig.telemetry.defaults.dictionary(forKey: Telemetry.tallyKey) as? [String: Int]
        #expect(tally == ["2026-10-04|order_moved": 1], "yesterday's tally was kept")
        // Yesterday's counter is still queued beside today's: one per day.
        let moved = Self.queued(rig).filter { $0["feature"] == .string("order_moved") }
        #expect(moved.map { $0["at"] } == [.string("2026-10-03"), .string("2026-10-04")])
        #expect(moved.map { $0["count"] } == [.number(3), .number(1)])
    }

    @Test("the queue keeps one counter per day and feature, the running count")
    func oneEventPerDayAndFeature() async {
        let rig = Rig()
        for _ in 0..<4 { await Self.count(.quoteCreated, rig) }
        for _ in 0..<2 { await Self.count(.invoiceExported, rig) }
        let events = Self.queued(rig)
        #expect(events.count == 2)
        #expect(events.first { $0["feature"] == .string("quote_created") }?["count"] == .number(4))
        #expect(events.first { $0["feature"] == .string("invoice_exported") }?["count"] == .number(2))
    }

    /// Counters fire from anywhere and are not awaited: two read-modify-writes
    /// of the queue at once used to keep only the later one's view.
    @Test("counters fired together are all queued")
    func overlappingCounters() async {
        let rig = Rig()
        let features: [TelemetryFeature] = [.quoteCreated, .orderMoved, .paymentRecorded, .libraryImport,
                                            .printSent, .orderMoved]
        let tasks = features.compactMap {
            rig.telemetry.feature($0, consent: Self.both, engine: Self.engine, file: rig.file,
                                  settings: [:], mode: "simple", language: "en")
        }
        for task in tasks { _ = await task.value }
        let events = Self.queued(rig)
        #expect(Set(events.compactMap { e -> String? in
            if case .string(let f)? = e["feature"] { return f } else { return nil }
        }) == ["quote_created", "order_moved", "payment_recorded", "library_import", "print_sent"])
        #expect(events.first { $0["feature"] == .string("order_moved") }?["count"] == .number(2))
    }

    /// "View what's collected" shows the queue; the flush sends the queue.
    @Test("what Settings shows is exactly what is sent")
    func viewMatchesSend() async throws {
        let rig = Rig()
        await Self.count(.quoteCreated, rig)
        await Self.count(.backupRun, rig)
        let shown = try #require(rig.telemetry.pending(file: rig.file))
        _ = await rig.telemetry.flush(consent: Self.both, engine: Self.engine, file: rig.file)
        let body = try #require(rig.requests.first?.httpBody)
        let sent = try JSONDecoder().decode([String: [JSONValue]].self, from: body)["events"]
        let view = try JSONDecoder().decode([JSONValue].self, from: Data(shown.utf8))
        #expect(sent == view)
        #expect(view.count == 2)
    }

    // MARK: Updates

    @Test("an update is a new version running, not the first launch or a dev build")
    func versionChanged() {
        let defaults = UserDefaults(suiteName: "khayt.tel.ver.\(UUID().uuidString)")!
        let t = Telemetry(defaults: defaults)
        t.appVersion = "4.0.0-alpha.64"
        #expect(!t.versionChanged(), "the first launch counted as an update")
        #expect(!t.versionChanged())
        t.appVersion = "4.0.0-alpha.65"
        #expect(t.versionChanged())
        #expect(!t.versionChanged())
        t.appVersion = ""
        #expect(!t.versionChanged())
        #expect(defaults.string(forKey: Telemetry.lastVersionKey) == "4.0.0-alpha.65")
    }

    // MARK: Printer links

    @Test("a machine save links a printer only when it was not linked before")
    func linksPrinter() {
        let linked: [String: JSONValue] = ["printerApi": .object(["type": .string("moonraker")])]
        let none: [String: JSONValue] = ["printerApi": .object(["type": .string("none")])]
        #expect(Shop.linksPrinter(linked, over: nil))
        #expect(Shop.linksPrinter(linked, over: none))
        #expect(!Shop.linksPrinter(linked, over: linked))
        #expect(!Shop.linksPrinter(none, over: nil))
        #expect(!Shop.linksPrinter([:], over: nil))
    }

    // MARK: Wiring

    /// Every case has a call site in the app's sources: a line that calls
    /// `feature(` and names the case. The enum's own `case` lines call
    /// nothing, so they never count as a use of themselves.
    @Test("every feature is counted somewhere in the app")
    func everyFeatureIsWired() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let lines = try files.flatMap { url in
            try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        }.filter { $0.contains("feature(") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(!lines.isEmpty)
        for feature in TelemetryFeature.allCases {
            let name = String(describing: feature)
            let wired = lines.contains { line in
                line.range(of: "\\.\(name)(?![A-Za-z0-9_])", options: .regularExpression) != nil
            }
            #expect(wired, "TelemetryFeature.\(name) (\(feature.rawValue)) has no call site")
        }
    }
}
