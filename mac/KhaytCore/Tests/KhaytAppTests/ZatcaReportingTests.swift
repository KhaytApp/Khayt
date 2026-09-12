import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Whether an invoice has been reported to the tax authority, crossing into the
/// engine and back.
///
/// The rules are `lib/zatca-submit.js`, pinned by `test/zatca-submit.test.js`.
/// These are about the CROSSING, and one of them is about a number that must
/// not be invented: with Phase 2 switched off, nothing is overdue, and an app
/// reporting "14 unreported invoices" to a shop that has not opted into Phase 2
/// would be raising an alarm about a rule that does not apply to it.
@MainActor
struct ZatcaReportingTests {

    static func settings(on: Bool, certificate: Bool = true) -> [String: JSONValue] {
        var z2: [String: JSONValue] = ["enabled": .bool(on)]
        if certificate { z2["pcsid"] = .string("cert-blob") }
        return ["enableZatca": .bool(on), "zatcaPhase2": .object(z2)]
    }

    static func order(_ id: String, status: String = "completed",
                      voided: Bool = false, submission: [String: JSONValue]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "status": .string(status)]
        if voided { o["voidedAt"] = .string("2026-09-01T00:00:00.000Z") }
        if let submission { o["zatcaSubmission"] = .object(submission) }
        return .object(o)
    }

    static func read(_ orders: [JSONValue],
                     on: Bool = true, certificate: Bool = true) async throws
        -> KhaytEngine.ZatcaReporting {
        try await KhaytEngine().zatcaReporting(
            settings: Self.settings(on: on, certificate: certificate), orders: orders)
    }

    @Test("a completed invoice nobody has submitted is unreported")
    func pending() async throws {
        let out = try await Self.read([Self.order("A")])
        #expect(out.configured)
        #expect(out.invoices.first?.status == "pending")
        #expect(out.invoices.first?.eligible == true)
        #expect(out.unreported == 1)
    }

    @Test("an accepted invoice is not owed")
    func accepted() async throws {
        let out = try await Self.read([
            Self.order("A", submission: [
                "status": .string("accepted"), "icv": .number(7),
                "at": .string("2026-09-02T10:00:00.000Z"), "message": .string("OK"),
            ]),
        ])
        let inv = try #require(out.invoices.first)
        #expect(inv.status == "accepted")
        #expect(inv.icv == 7, "the counter the authority requires to be unbroken must cross")
        #expect(inv.at != nil)
        #expect(out.unreported == 0)
    }

    @Test("a rejected invoice is still owed, and says why")
    func rejected() async throws {
        // Rejected is not done. An invoice the authority refused is exactly as
        // unreported as one never sent, and the message is what tells a shop
        // which it is.
        let out = try await Self.read([
            Self.order("A", submission: [
                "status": .string("rejected"),
                "message": .string("Invalid VAT number"),
            ]),
        ])
        #expect(out.invoices.first?.status == "rejected")
        #expect(out.invoices.first?.message == "Invalid VAT number")
        #expect(out.unreported == 1)
    }

    @Test("a job still on the bench is not late to be reported")
    func notEligible() async throws {
        // Eligibility is the rule's, not a guess here: pending and printing
        // jobs have no invoice to report yet.
        let out = try await Self.read([
            Self.order("A", status: "pending"),
            Self.order("B", status: "printing"),
            Self.order("C", status: "delivered"),
        ])
        #expect(out.invoices.filter(\.eligible).map(\.id) == ["C"])
        #expect(out.unreported == 1, "only the delivered one is owed")
    }

    @Test("a voided invoice is not owed")
    func voided() async throws {
        let out = try await Self.read([Self.order("A", voided: true)])
        #expect(out.invoices.first?.eligible == false)
        #expect(out.unreported == 0)
    }

    @Test("with Phase 2 switched off, nothing is overdue")
    func notConfigured() async throws {
        // The alarm has to be paired with having opted in. Telling a shop that
        // has not enabled Phase 2 it has fourteen unreported invoices is
        // raising an alarm about a rule that does not apply to it.
        let out = try await Self.read([Self.order("A"), Self.order("B")], on: false)
        #expect(out.configured == false)
        #expect(out.invoices.allSatisfy { $0.status == "notConfigured" })
        #expect(out.unreported == 0)
    }

    @Test("Phase 2 switched on without a certificate is not configured")
    func noCertificate() async throws {
        // Enabled but never onboarded cannot submit anything, so nothing is
        // owed yet — the shop's next step is onboarding, not chasing invoices.
        let out = try await Self.read([Self.order("A")], on: true, certificate: false)
        #expect(out.configured == false)
        #expect(out.unreported == 0)
    }

    @Test("an empty book is an answer, not a throw")
    func empty() async throws {
        let out = try await Self.read([])
        #expect(out.invoices.isEmpty)
        #expect(out.unreported == 0)
    }
}
