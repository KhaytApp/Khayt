import Foundation
import Testing
@testable import KhaytCore

/// khayt-cloud #143: a vault over its plan after a move down. The `lapse`
/// block on billing/me, vault/usage and the plan move; the display state in
/// the book's calendar; and 402 vault-over on the routes that make or change
/// what the cloud serves, with deleting still allowed.
struct VaultLapseTests {

    typealias Bench = VaultClientTests.Bench

    /// Riyadh, Gregorian, POSIX — `Calendar.book` on the shop's Mac, pinned
    /// so the day counts do not move with the machine running the test.
    static let riyadh: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Riyadh")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    static func at(_ iso: String) -> Date { Calendar.instant(iso)! }

    static func lapse(_ json: String) throws -> CloudPlans.Lapse {
        try JSONDecoder().decode(CloudPlans.Lapse.self, from: Data(json.utf8))
    }

    // MARK: - Decoding

    @Test("billing/me: an older cloud without lapse reads as not over; the block reads; a broken one loses nothing else")
    func mineDecodes() throws {
        let old = try JSONDecoder().decode(CloudPlans.Mine.self, from: Data(#"{"plan":"maker","active":true}"#.utf8))
        #expect(old.lapse == nil && old.plan == "maker")
        #expect(old.lapse.map { $0.display() } ?? .notOver == .notOver)

        let over = try JSONDecoder().decode(CloudPlans.Mine.self, from: Data("""
        {"plan":"free","active":true,"lapse":{"over":true,"overBytes":5368709120,
         "readOnlySince":"2026-10-20T09:00:00.000Z","deleteAfter":"2027-01-18T09:00:00.000Z","deleting":true}}
        """.utf8))
        #expect(over.lapse == CloudPlans.Lapse(over: true, overBytes: 5_368_709_120,
                                              readOnlySince: "2026-10-20T09:00:00.000Z",
                                              deleteAfter: "2027-01-18T09:00:00.000Z", deleting: true))

        let odd = try JSONDecoder().decode(CloudPlans.Mine.self, from: Data(#"{"plan":"free","lapse":"soon"}"#.utf8))
        #expect(odd.plan == "free" && odd.lapse == nil, "a lapse this app cannot read is not a lost plan")

        let partial = try Self.lapse(#"{"over":true,"overBytes":"lots","deleteAfter":7}"#)
        #expect(partial == CloudPlans.Lapse(over: true, overBytes: 0, readOnlySince: nil, deleteAfter: nil, deleting: false))
        #expect(try Self.lapse(#"{"over":false,"overBytes":0,"readOnlySince":null,"deleteAfter":null,"deleting":false}"#)
                == .notOver)
    }

    @Test("the plan move's answer carries lapse too")
    func chooseCarriesLapse() async throws {
        let m = try await CloudPlans.choose("free", CloudPlansTests.connection, token: "tok",
                                            fetch: CloudPlansTests.answering(200, """
        {"plan":"free","active":true,"lapse":{"over":true,"overBytes":1024,"readOnlySince":null,"deleteAfter":null,"deleting":false}}
        """))
        #expect(m.lapse?.over == true && m.lapse?.overBytes == 1024)
    }

    @Test("vault/usage: lapse when the cloud sends it, nil when it does not")
    func usageDecodes() async throws {
        let b = Bench()
        #expect(try await b.stub.client().usage().lapse == nil)
        b.stub.lapse = ["over": true, "overBytes": 2048, "readOnlySince": "2026-10-24T08:00:00Z",
                        "deleteAfter": NSNull(), "deleting": false]
        let u = try await b.stub.client().usage()
        #expect(u.lapse?.over == true && u.lapse?.overBytes == 2048 && u.lapse?.deleteAfter == nil)
        #expect(u.limits.maxVaultBytes == b.stub.limitBytes)
    }

    // MARK: - What the shop is shown

    @Test("display: not over, read-only with and without a since, deleting with a whole-day count")
    func display() throws {
        let noon = Self.at("2026-10-25T09:00:00Z")   // 12:00 in Riyadh
        let cal = Self.riyadh
        #expect(CloudPlans.Lapse.notOver.display(now: noon, calendar: cal) == .notOver)
        #expect(!CloudPlans.Lapse.notOver.display(now: noon, calendar: cal).isOver)

        // The first hour: over, no since yet, no date.
        let fresh = try Self.lapse(#"{"over":true,"overBytes":100,"readOnlySince":null,"deleteAfter":null,"deleting":false}"#)
        #expect(fresh.display(now: noon, calendar: cal) == .readOnly(overBytes: 100, since: nil))

        let since = try Self.lapse(#"{"over":true,"overBytes":100,"readOnlySince":"2026-10-20T09:00:00.000Z","deleteAfter":null,"deleting":false}"#)
        #expect(since.display(now: noon, calendar: cal) == .readOnly(overBytes: 100, since: Self.at("2026-10-20T09:00:00Z")))

        // A date while deleting is false is not shown: read-only, no date.
        let early = try Self.lapse(#"{"over":true,"overBytes":100,"readOnlySince":null,"deleteAfter":"2026-11-01T00:00:00Z","deleting":false}"#)
        guard case .readOnly = early.display(now: noon, calendar: cal) else { Issue.record("showed a date with deleting off"); return }

        // Deleting, but no readable date: still read-only, never a made-up day.
        let noDate = try Self.lapse(#"{"over":true,"overBytes":100,"readOnlySince":null,"deleteAfter":"soon","deleting":true}"#)
        #expect(noDate.display(now: noon, calendar: cal) == .readOnly(overBytes: 100, since: nil))

        // 90 days out, counted between local midnights.
        let end = "2027-01-23T09:00:00Z"
        let deleting = try Self.lapse(#"{"over":true,"overBytes":100,"readOnlySince":"2026-10-25T09:00:00Z","deleteAfter":"\#(end)","deleting":true}"#)
        #expect(deleting.display(now: noon, calendar: cal) == .deleting(overBytes: 100, deleteAfter: Self.at(end), daysLeft: 90, since: Self.at("2026-10-25T09:00:00Z")))
        // Late in the evening it is still 90, not 89 and a bit.
        #expect(deleting.display(now: Self.at("2026-10-25T20:30:00Z"), calendar: cal)
                == .deleting(overBytes: 100, deleteAfter: Self.at(end), daysLeft: 90, since: Self.at("2026-10-25T09:00:00Z")),
                "20:30Z is 23:30 in Riyadh, still the 25th")
        // Tomorrow's 02:00 local (the UTC day is still yesterday) counts from the local day.
        let tomorrow = Self.at("2026-10-25T23:00:00Z")   // 02:00 on the 26th in Riyadh
        #expect(deleting.display(now: tomorrow, calendar: cal) == .deleting(overBytes: 100, deleteAfter: Self.at(end), daysLeft: 89, since: Self.at("2026-10-25T09:00:00Z")))
        // A date already passed is 0, never negative.
        #expect(deleting.display(now: Self.at("2027-02-01T09:00:00Z"), calendar: cal)
                == .deleting(overBytes: 100, deleteAfter: Self.at(end), daysLeft: 0, since: Self.at("2026-10-25T09:00:00Z")))
    }

    @Test("display counts Gregorian days even when handed a Hijri calendar's clock")
    func bookCalendarIsGregorian() throws {
        #expect(Calendar.book.identifier == .gregorian)
        let d = try Self.lapse(#"{"over":true,"overBytes":1,"deleteAfter":"2027-01-23T09:00:00Z","deleting":true}"#)
        guard case .deleting(_, _, let days, _) = d.display(now: Self.at("2026-10-25T09:00:00Z")) else {
            Issue.record("not deleting"); return
        }
        #expect((89...90).contains(days), "the book calendar in this Mac's zone")
    }

    // MARK: - 402 vault-over

    @Test("402 vault-over reads as its own failure, from the client and from products")
    func failureReads() throws {
        let body = Data(#"{"error":"over","reason":"vault-over","used":300,"limit":200}"#.utf8)
        #expect(VaultClient.failure(402, body) == .vaultOver(used: 300, limit: 200))
        #expect(VaultProducts.failure(402, body) as? VaultClient.Failure == .vaultOver(used: 300, limit: 200))
        // Uploads keep their own reasons.
        #expect(VaultClient.failure(402, Data(#"{"reason":"vault-full","used":1,"limit":2}"#.utf8)) == .vaultFull(used: 1, limit: 2))
        #expect(VaultClient.failure(402, Data(#"{"reason":"no-vault"}"#.utf8)) == .noVault)
    }

    @Test("over the plan: new links, new products, edits, previews and releases are refused; removing is not")
    func gatedRoutes() async throws {
        let b = Bench()
        let src = try await VaultProductsTests().uploaded(b, 2)
        let p = VaultProducts(client: b.stub.client(), keys: b.keys)
        let made = try await p.create(VaultProductsTests().draft(src.map(\.row.fileId)))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let kept = try await p.addPreview(made.productId, image: png, mime: "image/png")
        b.stub.vaultOver = true

        func refused(_ what: String, _ body: () async throws -> Void) async {
            do { try await body(); Issue.record("\(what) went through over the plan") }
            catch let f as VaultClient.Failure {
                guard case .vaultOver = f else { Issue.record("\(what): \(f)"); return }
            } catch { Issue.record("\(what): \(error)") }
        }
        await refused("a new link") {
            _ = try await VaultLinksTests().links(b).create(src, options: .init())
        }
        await refused("a new product") { _ = try await p.create(VaultProductsTests().draft(src.map(\.row.fileId))) }
        await refused("an edit") { _ = try await p.update(made.productId, VaultProducts.Draft(made)) }
        await refused("a preview") { _ = try await p.addPreview(made.productId, image: png + Data([9]), mime: "image/png") }
        await refused("a release") { _ = try await p.release(made.productId, files: src) }

        // What brings the vault back under its limit still works.
        try await p.removePreview(made.productId, hash: kept.hash)
        try await p.remove(made.productId)
        let c = b.stub.client()
        try await c.trash(fileId: src[0].row.fileId)
        try await c.restore(fileId: src[0].row.fileId)
        try await c.purge(fileId: src[1].row.fileId)
    }
}
