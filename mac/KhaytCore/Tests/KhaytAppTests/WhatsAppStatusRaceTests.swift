import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A delivery report is not an edit (Oct 2026 review): stamped, a "read"
/// could beat the shop's own change to that customer on another device.
@MainActor
struct WhatsAppStatusRaceTests {
    static func item(_ id: String, _ status: String, at: String) -> JSONValue {
        .object(["messageId": .string(id), "status": .string(status), "at": .string(at)])
    }

    @Test("what this Mac was told is kept: the highest report per message, never a lower one after it")
    func keptForward() throws {
        let defaults = try #require(UserDefaults(suiteName: "wa-kept-\(UUID().uuidString)"))
        WhatsAppReports.keep([Self.item("w1", "delivered", at: "2026-10-19T10:00:00Z"),
                              Self.item("w2", "sent", at: "2026-10-19T10:01:00Z")], "s1", defaults)
        WhatsAppReports.keep([Self.item("w1", "sent", at: "2026-10-19T09:00:00Z"),
                              Self.item("w2", "read", at: "2026-10-19T10:05:00Z")], "s1", defaults)
        let kept = WhatsAppReports.kept("s1", defaults)
        func status(_ id: String) -> String? {
            for case .object(let o) in kept where o["messageId"] == .string(id) {
                if case .string(let s)? = o["status"] { return s }
            }
            return nil
        }
        #expect(status("w1") == "delivered" && status("w2") == "read")
        #expect(WhatsAppReports.kept("other", defaults).isEmpty, "kept per shop")
    }

    @Test("a merge that took a report back off is put right, and the write never stamps the customer")
    func reappliedUnstamped() async throws {
        let engine = try KhaytEngine()
        // The copy a merge brought back: the shop's edit (rev 7), the line still "sent".
        let client: JSONValue = .object(["id": .string("c1"), "rev": .number(7), "phone": .string("+966500000001"),
                                         "commLog": .array([.object(["messageId": .string("w1"), "status": .string("sent")])])])
        let applied = try await engine.applyWhatsAppStatuses(
            clients: [client], items: [Self.item("w1", "read", at: "2026-10-19T10:05:00Z")])
        #expect(applied.changed == 1)
        guard case .object(let o)? = applied.clients.first else { Issue.record("no client"); return }
        #expect(o["rev"] == .number(7) && o["phone"] == .string("+966500000001"), "the person's edit is untouched")
        let source = try LockRound3Tests.source("WhatsAppReports.swift")
        #expect(source.contains("recordingDeletes: false"), "written unstamped, so it never wins a merge")
        #expect(source.contains("let items = WhatsAppReports.kept(connection.shopId)"), "laid over on every poll")
    }

    @Test("only what the rule reads is kept, and taking the hook down or signing out forgets it")
    func keptSlimAndForgotten() throws {
        let defaults = try #require(UserDefaults(suiteName: "wa-slim-\(UUID().uuidString)"))
        WhatsAppReports.keep([.object([
            "messageId": .string("w1"), "status": .string("failed"), "at": .string("2026-10-19T10:00:00Z"),
            "errorCode": .number(131026), "errorTitle": .string(String(repeating: "x", count: 500)),
            "recipient_id": .string("966500000001"),
        ])], "s1", defaults)
        WhatsAppReports.remember(42, "s1", defaults)
        guard case .object(let o)? = WhatsAppReports.kept("s1", defaults).first else { Issue.record("nothing kept"); return }
        #expect(Set(o.keys) == ["messageId", "status", "at", "errorCode", "errorTitle"], "\(o.keys)")
        if case .string(let t)? = o["errorTitle"] { #expect(t.count == 200) }
        WhatsAppReports.forget("s1", defaults)
        #expect(WhatsAppReports.kept("s1", defaults).isEmpty)
        #expect(WhatsAppReports.since("s1", defaults) == nil)
        let cloud = try LockRound3Tests.source("Shop+Cloud.swift")
        #expect(cloud.contains("WhatsAppReports.forget(shopId)"), "signing out of the cloud forgets them")
        #expect(try LockRound3Tests.source("WhatsAppReports.swift").contains("WhatsAppReports.forget(connection.shopId)"))
    }
}
