import Foundation
import Testing
@testable import KhaytApp

/// Every Bonjour service type the app advertises or browses is declared.
///
/// mDNSResponder refuses a type that is not in the app's `NSBonjourServices`,
/// and when the refused one is an ADVERT the listener goes down with it. That
/// is exactly what shipped in alpha.37: `LanServer` advertised `_khayt._tcp`,
/// `make-app.sh` listed only the printer types, and on the shop's Mac —
/// "App Info.plist(NSBonjourServices) does not allow '_khayt._tcp'", then
/// "failed (DNS Error: NoAuth)" — nothing listened and nothing said so. A debug
/// build never showed it: `swift run` has no Info.plist to be refused by.
///
/// So the check is on the SOURCE: every `"_x._tcp"` / `"_x._udp"` literal
/// anywhere in the app must appear in the list `make-app.sh` writes.
@MainActor
struct LanBonjourDeclaredTests {

    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("every service type in the source is in NSBonjourServices")
    func declared() throws {
        let script = try String(contentsOf: Self.root.appending(path: "../make-app.sh"), encoding: .utf8)
        guard let open = script.range(of: "<key>NSBonjourServices</key>"),
              let close = script.range(of: "</array>", range: open.upperBound..<script.endIndex) else {
            Issue.record("make-app.sh no longer writes NSBonjourServices"); return
        }
        let list = String(script[open.upperBound..<close.lowerBound])
        let pattern = try NSRegularExpression(pattern: #""(_[a-z0-9-]+\._(?:tcp|udp))""#)
        var used = Set<String>()
        let sources = Self.root.appending(path: "Sources")
        let walk = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = walk?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) { used.insert(String(text[r])) }
            }
        }
        #expect(used.contains("_khayt._tcp"), "the scan found nothing it should have — the pattern or paths moved")
        let missing = used.filter { !list.contains("<string>\($0)</string>") }.sorted()
        #expect(missing.isEmpty, Comment(rawValue:
            "used in the app, not declared in make-app.sh's NSBonjourServices — mDNSResponder refuses these "
            + "(an advert takes the listener down): \(missing)"))
    }

    @Test("a listener that fails after it was up is noticed, not ignored")
    func failureAfterReadyHandled() {
        let src = MenuCoverageTests.source("LanServer.swift")
        #expect(src.contains("else { Task { @MainActor [weak self] in self?.failedAfterReady(error) } }"),
                "a `.failed` after `.ready` is ignored again, so a dead server reads as running")
        #expect(src.contains("_ = try await self.start(port: was.port, bind: was.bind, advertise: false)"),
                "a refused advert no longer falls back to listening without it")
        #expect(src.contains("host.failed = { [weak self] said in"), "the app does not hear about it")
    }

    @Test("when it falls back and cannot, the shop is told")
    func toldWhenItCannot() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        final class Said: @unchecked Sendable { var text: String? }
        let said = Said()
        var host = LanServer.Host(store: { [:] }, pin: "", engine: engine)
        host.failed = { said.text = $0 }
        let server = LanServer(host: host)
        // Never started: nothing to fall back to, so it must say so.
        server.failedAfterReady(CocoaError(.fileReadUnknown))
        #expect(said.text != nil, "a failure with nothing to fall back to was swallowed")
        #expect(!server.running)
    }
}
