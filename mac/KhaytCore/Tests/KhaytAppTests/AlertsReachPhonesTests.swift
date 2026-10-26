import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A printer alert reaches the shop's phone — through Telegram and ntfy — and a
/// spool running out is an alert at all.
///
/// The Mac raised printer alerts as notifications on the Mac only. Its
/// Telegram switches for printer error, offline and stalled were saved and
/// never read, and the fixed set it asked `printer-alerts` for had no RUNOUT,
/// so an empty spool mid-print raised nothing. `lib/alert-routes.js` decides
/// now; `test/alert-routes.test.js` holds it.
@MainActor
struct AlertsReachPhonesTests {

    static func engine() throws -> KhaytEngine { try KhaytEngine() }

    @Test("a runout is computed, and a stall only when a channel asked for it")
    func whatIsComputed() async throws {
        let e = try Self.engine()
        let none = try await e.alertEnable(settings: [:])
        #expect(none == .init(error: true, offline: true, stall: false, runout: true))
        let stall = try await e.alertEnable(settings: ["telegram": .object([
            "botToken": .string("x"), "chatId": .string("-1"), "notifyPrinterStall": .bool(true)])])
        #expect(stall.stall, "a stall the shop asked Telegram for was never computed")
    }

    @Test("each alert goes where the shop's switches say")
    func routes() async throws {
        let e = try Self.engine()
        let s: [String: JSONValue] = [
            "telegram": .object(["botToken": .string("x"), "chatId": .string("-1"), "notifyPrinterOffline": .bool(false)]),
            "ntfy": .object(["enabled": .bool(true), "topic": .string("khayt-abc")]),
        ]
        func both(_ t: String) async throws -> [Bool] {
            let r = try await e.alertRoutes(type: t, settings: s)
            return [r.telegram, r.ntfy]
        }
        #expect(try await both("error") == [true, true])
        #expect(try await both("offline") == [false, true], "the offline switch on Telegram was ignored")
        #expect(try await both("stall") == [false, false])
    }

    final class Caught: @unchecked Sendable { var request: URLRequest? }

    @Test("the ntfy push is a POST to the topic, with its title, priority and tag — and a token only when set")
    func ntfyRequest() async throws {
        let e = try Self.engine()
        let req = try #require(try await e.ntfyRequest(type: "runout", title: "U1 ran out of filament",
                                                       body: "Dragon.gcode · 62%",
                                                       settings: ["ntfy": .object(["enabled": .bool(true), "topic": .string("khayt-abc")])]))
        let caught = Caught()
        let stub: (URLRequest) async throws -> (Data, URLResponse) = { r in
            caught.request = r
            return (Data(), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
        }
        try await Ntfy.send(req, token: "", fetch: stub)
        let sent = try #require(caught.request)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://ntfy.sh/khayt-abc")
        #expect(sent.value(forHTTPHeaderField: "Title") == "U1 ran out of filament")
        #expect(sent.value(forHTTPHeaderField: "Priority") == "high")
        #expect(sent.value(forHTTPHeaderField: "Tags") == "warning")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil, "a token was sent that the shop never set")
        #expect(String(decoding: sent.httpBody ?? Data(), as: UTF8.self) == "Dragon.gcode · 62%")
        try await Ntfy.send(req, token: "tk_123", fetch: stub)
        #expect(caught.request?.value(forHTTPHeaderField: "Authorization") == "Bearer tk_123")
    }

    @Test("a refusal is reported, not swallowed")
    func refused() async throws {
        let req = KhaytEngine.NtfyRequest(url: "https://ntfy.sh/x", headers: [:], body: "b")
        await #expect(throws: Ntfy.Failure.refused(403)) {
            try await Ntfy.send(req, token: "", fetch: { r in
                (Data(), HTTPURLResponse(url: r.url!, statusCode: 403, httpVersion: nil, headerFields: [:])!)
            })
        }
    }

    @Test("the poll asks what to compute, and sends every alert on to the phone")
    func wired() {
        let watch = MenuCoverageTests.source("PrinterWatch.swift")
        #expect(watch.contains("try? await engine.alertEnable(settings: shop.settingsDict)"))
        #expect(!watch.contains("enable: KhaytEngine.Alerting.sensible) else {"),
                "the fixed set is back, so runouts and requested stalls are lost again")
        #expect(watch.contains("await shop.sendAlert(type: alert.type, title: title, body: bare, namedBody: body,"),
                "a fault alert reaches the phones, and its file name only where the shop asked for names")
        #expect(watch.contains("withFile: false"))
        #expect(MenuCoverageTests.source("Integrations.swift").contains("NtfySettings(shop: shop)"))
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytCore/KhaytEngine.swift")
        #expect(((try? String(contentsOf: engine, encoding: .utf8)) ?? "")
            .contains("\"runout\": .bool(enable.runout)"), "runout is not passed to printer-alerts")
    }

    // MARK: The print's own news (beta.8)

    @Test("finished, failed and paused are OPT-IN per channel, and name the job and file only when ticked")
    func printNoticesReachPhones() async throws {
        let engine = try KhaytEngine()
        let both: [String: JSONValue] = [
            "telegram": .object(["botToken": .string("__enc__x"), "chatId": .string("-100")]),
            "ntfy": .object(["enabled": .bool(true), "topic": .string("athar-printers")]),
        ]
        // A channel set up for faults is not told about prints.
        for kind in PrintNoticeKind.allCases {
            #expect(try await engine.alertRoutes(type: kind.rawValue, settings: both) == .init(telegram: false, ntfy: false),
                    "\(kind.rawValue) went out to a channel that never asked")
        }
        // Switched on in each pane: the panes' own forms are what the book holds.
        var tgDraft = TelegramSettings.Draft(); tgDraft.chatId = "-100"; tgDraft.printNotices = true
        var ntDraft = NtfySettings.Draft(); ntDraft.enabled = true; ntDraft.topic = "athar-printers"; ntDraft.printNotices = true
        var tg = TelegramSettings.form(tgDraft); tg["botToken"] = .string("__enc__x")
        let on: [String: JSONValue] = ["telegram": .object(tg), "ntfy": .object(NtfySettings.form(ntDraft))]
        for kind in PrintNoticeKind.allCases {
            #expect(try await engine.alertRoutes(type: kind.rawValue, settings: on) == .init(telegram: true, ntfy: true),
                    "\(kind.rawValue)")
            let none = try await engine.alertRoutes(type: kind.rawValue, settings: [:])
            #expect(none == .init(telegram: false, ntfy: false))
            let req = try #require(try await engine.ntfyRequest(type: kind.rawValue, title: "t", body: "b", settings: on))
            #expect(req.url.hasSuffix("/athar-printers"))
        }
        #expect(TelegramSettings.Draft.read(on).printNotices && NtfySettings.Draft.read(on).printNotices,
                "a pane reads back what it saved")
        // Names: off unless ticked, per channel.
        #expect(try await engine.alertNoticeNames(settings: on) == .init(telegram: false, ntfy: false))
        ntDraft.printNames = true
        let named: [String: JSONValue] = ["telegram": .object(tg), "ntfy": .object(NtfySettings.form(ntDraft))]
        #expect(try await engine.alertNoticeNames(settings: named) == .init(telegram: false, ntfy: true))
        #expect(NtfySettings.Draft.read(named).printNames)
        // Wired: both seams send, after the Mac's own switch and the ledger;
        // the phone's copy is the bare one unless the channel took names.
        let notices = MenuCoverageTests.source("PrintNotices.swift")
        #expect(notices.components(separatedBy: "sendPrintNotice(kind, notice,").count - 1 == 2,
                "the pause watch and the finish seam each send once")
        #expect(notices.contains("await sendAlert(type: kind.rawValue, title: notice.title, body: bare, namedBody: notice.body)"))
        #expect(MenuCoverageTests.source("Shop.swift").contains("let ntfyBody = names.ntfy ? (namedBody ?? body) : body"))
    }

    @Test("a fault already told as Print failed is not sent again on a channel that took it")
    func noDoubleSend() {
        let took = KhaytEngine.AlertRoutes(telegram: true, ntfy: false)
        #expect(Shop.routesNotSentAlready(.init(telegram: true, ntfy: true), took: took) == .init(telegram: false, ntfy: true))
        #expect(Shop.routesNotSentAlready(.init(telegram: true, ntfy: true), took: .init(telegram: false, ntfy: false))
                == .init(telegram: true, ntfy: true))
        #expect(MenuCoverageTests.source("PrinterWatch.swift")
            .contains("unlessSentAs: toldAsFailed && PrintNoticeKind.failed.wanted"))
    }
}
