import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A customer who asks not to be marketed to can be recorded as such HERE.
///
/// ── WHY THIS IS ITS OWN SUITE ─────────────────────────────────────────────
///
/// `lib/campaigns.js` has always refused to put an opted-out customer on a
/// list, whatever the segment says — `CampaignTests` proves that end of it.
/// What was missing is the other end: this app could send a campaign and could
/// not record the reply to one. A shop reading "please stop emailing me" had to
/// open the other app to honour it, which is sending in one place and recording
/// consent in another.
///
/// The asymmetry is the bug. A field that is only READ is a rule the app obeys
/// and cannot be asked to apply.
@MainActor
struct OptOutTests {

    @Test("the flag survives a round trip through the record the sheet saves")
    func itRoundTrips() throws {
        let asked = Client(id: "C1", nameEn: "Acme").marketed(false)
        #expect(asked.marketingOptOut)
        #expect(asked.record["marketingOptOut"] == .bool(true))

        let decoded = try JSONDecoder().decode(
            Client.self, from: JSONEncoder().encode(JSONValue.object(asked.record)))
        #expect(decoded.marketingOptOut, "the flag was lost writing it down and reading it back")
    }

    @Test("a false is WRITTEN, so consent can be taken back as well as given")
    func falseIsWrittenDown() throws {
        // `saveCustomer` carries through every key the record omits — which is
        // what protects the comms log. Omitting a `false` here would use that
        // same mechanism to put a stored `true` back, so a shop that ticked the
        // box and then unticked it could never undo it. Consent has to be
        // writable in both directions.
        let willing = Client(id: "C2", nameEn: "Acme").marketed(true)
        #expect(willing.record["marketingOptOut"] == .bool(false),
                "a customer who was un-excluded writes nothing, so the old true stands")
    }

    @Test("a customer this app opts out is then refused by the shared rule")
    func theRuleThenRefusesThem() async throws {
        // End to end, through the bridge: what this app WRITES is what the rule
        // READS. A test that only checked the Swift flag would pass with a
        // field name the rule has never heard of.
        let engine = try KhaytEngine()
        let asked = Client(id: "C3", nameEn: "Acme", email: "a@example.com").marketed(false)
        let willing = Client(id: "C4", nameEn: "Beta", email: "b@example.com").marketed(true)
        let orders: [JSONValue] = [
            .object(["id": .string("O1"), "clientId": .string("C3"),
                     "status": .string("completed"), "price": .number(500),
                     "date": .string("2026-01-01")]),
            .object(["id": .string("O2"), "clientId": .string("C4"),
                     "status": .string("completed"), "price": .number(500),
                     "date": .string("2026-01-01")]),
        ]
        let reached = try await engine.campaignRecipients(
            clients: [.object(asked.record), .object(willing.record)],
            orders: orders, criteria: [:], channel: "email", tiers: [:], now: Date())
        #expect(reached.count == 1, Comment(rawValue:
            "\(reached.count) customers reached — the one this app excluded is on the list, "
            + "so the field it writes is not the field the rule reads"))
        #expect(reached.first?.contact == "b@example.com")
    }

    @Test("the sheet offers it, in the other app's words")
    func theSheetOffersIt() throws {
        let sheet = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/CustomerSheet.swift"), encoding: .utf8)
        #expect(sheet.contains("camp.opt_out"),
                "there is no way to record a customer asking not to be marketed to")
        #expect(sheet.contains("marketed("),
                "the sheet draws the box and does not write what it is set to")
    }
}
