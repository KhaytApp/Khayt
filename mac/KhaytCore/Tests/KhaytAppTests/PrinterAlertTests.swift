import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Telling somebody a print has gone wrong.
///
/// The thresholds, the cooldowns and the stall clock are
/// `lib/printer-alerts.js`'s and are pinned in `test/printer-alerts.test.js`.
/// What is tested here is what this app hands that module and what it does with
/// the answer — because the two ways to get this wrong are silent: a cache the
/// module cannot read as a failed poll, and a gate that only opens for a
/// transport this app does not use.
@MainActor
struct PrinterAlertTests {

    static let machines: [JSONValue] = [.object(["id": .string("M-1"), "name": .string("Bench")])]

    @Test("a printer that stops answering raises an alert without a Telegram bot")
    func offlineWithoutTelegram() async throws {
        // The module gates every alert on `settings.telegram` existing, because
        // that is its transport. This app's transport is a notification on the
        // machine the shop is sitting at, so a shop with no bot must still be
        // told its printer went quiet at two in the morning.
        let engine = try KhaytEngine()
        let down: [String: JSONValue] = ["M-1": .object([
            "state": .string("offline"), "error": .string("did not answer"),
        ])]
        var state: JSONValue = .object([:])
        var raised = 0
        // Three consecutive failed polls is the module's own threshold.
        for _ in 0..<3 {
            let out = try await engine.printerAlerts(
                was: [:], now: down, settings: [:], machines: Self.machines,
                state: state, enable: .sensible)
            state = out.state
            raised += out.alerts.count
        }
        #expect(raised == 1, "a printer that had been unreachable for an hour said nothing")
    }

    @Test("a failed poll must carry `error`, or nothing is ever raised")
    func theCacheShapeMatters() {
        // `isFailedPoll` reads exactly that field. A cache that said only
        // `state: "offline"` counted as a healthy poll, and the offline alert —
        // which counts CONSECUTIVE failed polls — never left zero.
        let watch = PrinterWatch()
        watch.setReadingForTesting("M-1", .init(status: nil, problem: "did not answer", at: Date()))
        guard case .object(let row)? = watch.statusCache["M-1"] else { Issue.record("no row"); return }
        #expect(row["error"] != nil)
        #expect(row["state"] == .string("offline"))
    }

    @Test("a machine that is printing normally raises nothing")
    func quietWhenAllIsWell() async throws {
        let engine = try KhaytEngine()
        let fine: [String: JSONValue] = ["M-1": .object([
            "state": .string("printing"), "progress": .number(30), "filename": .string("lid.gcode"),
        ])]
        let out = try await engine.printerAlerts(
            was: fine, now: fine, settings: [:], machines: Self.machines,
            state: .object([:]), enable: .sensible)
        #expect(out.alerts.isEmpty)
    }

    @Test("a stall is not raised unless it was asked for")
    func stallIsOptIn() async throws {
        // A print that has not moved might just be a long layer. The default
        // says errors and silence are worth interrupting somebody for and a
        // stall is not — which is the module's own default too.
        #expect(KhaytEngine.Alerting.sensible.stall == false)
        #expect(KhaytEngine.Alerting.sensible.error && KhaytEngine.Alerting.sensible.offline)
    }

    @Test("the sentence is in the shop's language, not the module's")
    func speaksTheShopsLanguage() async throws {
        // The module builds "Printer offline: Bench (3 failed checks)" in
        // English because it goes to Telegram. This one is read by the person
        // in the workshop.
        let shop = Shop()
        await shop.load(.sample)
        let english = PrinterWatch.title("offline", machine: "Bench", shop: shop)
        #expect(english.contains("Bench"))
        #expect(!english.contains("{machine}"), "the placeholder was never filled")
    }

    @Test("the body says what it was making and how far it had got")
    func bodyIsActionable() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let alert = try JSONDecoder().decode(
            KhaytEngine.PrinterAlerts.Alert.self,
            from: Data(#"{"machineId":"M-1","type":"error","message":"x","state":"error","filename":"lid.gcode","progress":42}"#.utf8))
        let body = PrinterWatch.body(alert, machine: "Bench", shop: shop)
        #expect(body.contains("lid.gcode"))
        #expect(body.contains("42%"))
    }

    @Test("a development run records the alert and does not try to deliver it")
    func noBundleNoDelivery() {
        // `UNUserNotificationCenter.current()` traps without a bundle
        // identifier, which `swift run` has none of — so delivering would take
        // the whole app down, snapshot harness included, for a notification
        // nobody would see.
        #expect(PrinterNotice.canDeliver == (Bundle.main.bundleIdentifier != nil))
        let notices = PrinterNotice()
        notices.raise(.init(machineId: "M-1", machine: "Bench", kind: "offline",
                            title: "Bench stopped answering", body: "lid.gcode · 42%", at: Date()))
        #expect(notices.raised.count == 1)
    }

    @Test("the log is observable, or the screen never shows it")
    func theLogIsObservable() {
        // It is held by `PrinterWatch` as a `let`, and an @Observable watch does
        // NOT make a plain class inside it observable. The section rendered
        // nothing at all — no error, no empty state, no section — until this
        // said so, and the only way to notice was to photograph it.
        #expect((PrinterNotice() as Any) is any Observable)
    }

    @Test("the log is a session's worth, not a log nobody reads")
    func keepsTwenty() {
        let notices = PrinterNotice()
        for i in 0..<30 {
            notices.raise(.init(machineId: "M-1", machine: "Bench", kind: "offline",
                                title: "\(i)", body: "", at: Date()))
        }
        #expect(notices.raised.count == 20)
        #expect(notices.raised.first?.title == "29", "newest first")
    }
}
