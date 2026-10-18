import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A customer's data, exported and erased on the Mac (`Shop+Privacy.swift`).
///
/// The RULE is `lib/privacy.js`, tested in Node where it lives. What is tested
/// here: that this app hands it the right collections, that the export is
/// this customer's alone, and that the erase — one `StoreWriter` write on a
/// book on disk — does what the plan says and nothing more, and Undo puts it
/// back.
@MainActor
struct CustomerPrivacyTests {

    static func book() -> [String: JSONValue] {
        func o(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }
        return [
            "clients": .array([
                o(["id": .string("C1"), "nameEn": .string("Nouf"), "email": .string("nouf@example.com"),
                   "phone": .string("0501111111"),
                   "commLog": .array([o(["kind": .string("call"), "note": .string("asked for a quote")]),
                                      o(["kind": .string("email"), "note": .string("sent it")])])]),
                o(["id": .string("C2"), "nameEn": .string("Hind"), "email": .string("hind@example.com"),
                   "phone": .string("0502222222")]),
            ]),
            "printLog": .array([
                // Nouf's: a quote (may lose the name), an invoiced job and a paid one (keep it).
                o(["id": .string("J-QUOTE"), "status": .string("quote"), "client": .string("Nouf"),
                   "clientId": .string("C1"), "project": .string("Vase")]),
                o(["id": .string("J-INV"), "status": .string("completed"), "client": .string("Nouf"),
                   "clientId": .string("C1"), "invoiceNum": .string("INV-2026-0007")]),
                o(["id": .string("J-PAID"), "status": .string("printing"), "client": .string("Nouf"),
                   "clientId": .string("C1"), "paidAmount": .number(40)]),
                // Hind's.
                o(["id": .string("J-HIND"), "status": .string("quote"), "client": .string("Hind"),
                   "clientId": .string("C2"), "project": .string("Lamp")]),
            ]),
            "waitingList": .array([
                o(["id": .string("W-LINK"), "clientId": .string("C1"), "name": .string("Nouf")]),
                o(["id": .string("W-MAIL"), "name": .string("N."), "email": .string(" NOUF@example.com ")]),
                o(["id": .string("W-PHONE"), "name": .string("N"), "phone": .string("0501111111")]),
                // Hind's row, carrying Nouf's email: the link wins, it is never Nouf's.
                o(["id": .string("W-OTHER"), "clientId": .string("C2"), "email": .string("nouf@example.com")]),
                // Only a name in common: never matched.
                o(["id": .string("W-NAME"), "name": .string("Nouf")]),
            ]),
            "waitingListHistory": .array([
                o(["id": .string("H-LINK"), "clientId": .string("C1")]),
                o(["id": .string("H-HIND"), "clientId": .string("C2"), "phone": .string("0501111111")]),
            ]),
            "settings": .object(["shopName": .string("Secret shop setting")]),
        ]
    }

    static func ids(_ root: [String: JSONValue], _ c: String) -> [String] {
        MoveJobTests.rows(root, c).compactMap { MoveJobTests.string($0["id"]) }
    }

    static func erase(_ clientId: String, full: Bool, at url: URL) async throws -> ErasedCustomer? {
        let engine = try KhaytEngine()
        var out: ErasedCustomer?
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            out = try await Shop.applyCustomerErase(to: &root, clientId: clientId, full: full, engine: engine)
        }
        return out
    }

    static func job(_ root: [String: JSONValue], _ id: String) throws -> [String: JSONValue] {
        try #require(MoveJobTests.row(root, "printLog", id))
    }

    // MARK: - Access

    @Test("the export holds this customer's data and nobody else's")
    func exportIsTheirsAlone() async throws {
        let engine = try KhaytEngine()
        let payload = try await engine.clientDataExport(clientId: "C1",
                                                        collections: Shop.privacyCollections(Self.book()),
                                                        nowIso: "2026-10-18T09:00:00.000Z")
        guard case .object(let out) = payload else { Issue.record("not an object"); return }
        guard case .object(let subject)? = out["subject"] else { Issue.record("no subject"); return }
        #expect(subject["id"] == .string("C1"))
        #expect(out["exportedAt"] == .string("2026-10-18T09:00:00.000Z"))
        func idsIn(_ key: String) -> [String] {
            guard case .array(let rows)? = out[key] else { return [] }
            return rows.compactMap { if case .object(let o) = $0 { MoveJobTests.string(o["id"]) } else { nil } }
        }
        #expect(idsIn("orders") == ["J-QUOTE", "J-INV", "J-PAID"])
        #expect(Set(idsIn("intakeSubmissions")) == ["W-LINK", "W-MAIL", "W-PHONE"])
        #expect(idsIn("intakeHistory") == ["H-LINK"])
        if case .array(let comms)? = out["communications"] { #expect(comms.count == 2) }
        else { Issue.record("no communications") }
        // Nothing of Hind's, and nothing of the shop's.
        let text = String(decoding: try Shop.customerDataJSON(payload), as: UTF8.self)
        #expect(!text.contains("Hind") && !text.contains("hind@") && !text.contains("0502222222"))
        #expect(!text.contains("J-HIND") && !text.contains("W-OTHER") && !text.contains("W-NAME"))
        #expect(!text.contains("Secret shop setting"))
        // Pretty-printed, as the desktop writes it.
        #expect(text.contains("\n  \""))
    }

    @Test("the file is named as the desktop names it")
    func exportFileName() {
        var parts = DateComponents()
        parts.calendar = .book; parts.year = 2026; parts.month = 10; parts.day = 18; parts.hour = 12
        let noon = Calendar.book.date(from: parts)!
        #expect(Shop.customerDataFilename(name: "Nouf / Al-Dossari!", clientId: "C1", now: noon)
                == "khayt-customer-data-Nouf  Al-Dossari-2026-10-18.json")
        #expect(Shop.customerDataFilename(name: "نوف", clientId: "C1", now: noon)
                == "khayt-customer-data-نوف-2026-10-18.json")
        #expect(Shop.customerDataFilename(name: "???", clientId: "C1", now: noon)
                == "khayt-customer-data-C1-2026-10-18.json")
    }

    // MARK: - Erasure

    @Test("the plan states the counts the sheet shows")
    func planCounts() async throws {
        let engine = try KhaytEngine()
        let plan = try await engine.planClientErasure(clientId: "C1",
                                                      collections: Shop.privacyCollections(Self.book()), full: true)
        #expect(plan.counts.orders == 3)
        #expect(plan.counts.keptNames == 2)
        #expect(plan.counts.intake == 4)
        #expect(plan.counts.communications == 2)
        #expect(plan.blankNameOrderIds == ["J-QUOTE"])
        #expect(Set(plan.keepNameOrderIds) == ["J-INV", "J-PAID"])
    }

    @Test("unlink keeps every job, unlinked and named, and every intake row")
    func unlinkKeepsTheJobs() async throws {
        let url = try DeleteJobsAndCustomersTests.scratch(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let erased = try #require(try await Self.erase("C1", full: false, at: url))
        #expect(erased.jobs.map(\.id) == ["J-QUOTE", "J-INV", "J-PAID"])
        #expect(erased.jobs.allSatisfy { $0.blankedName == nil })

        let after = try DeleteJobsAndCustomersTests.onDisk(url)
        #expect(Self.ids(after, "clients") == ["C2"])
        #expect(Self.ids(after, "printLog") == ["J-QUOTE", "J-INV", "J-PAID", "J-HIND"])
        for id in ["J-QUOTE", "J-INV", "J-PAID"] {
            let job = try Self.job(after, id)
            #expect(job["clientId"] == .null, "\(id) is still linked")
            #expect(job["client"] == .string("Nouf"), "\(id) lost its name on an unlink")
        }
        #expect(try Self.job(after, "J-HIND")["clientId"] == .string("C2"))
        #expect(Self.ids(after, "waitingList") == ["W-LINK", "W-MAIL", "W-PHONE", "W-OTHER", "W-NAME"])
        #expect(Self.ids(after, "waitingListHistory") == ["H-LINK", "H-HIND"])
    }

    @Test("full erase blanks the name only where there is no invoice and no payment")
    func fullEraseKeepsBuyersOnInvoices() async throws {
        let url = try DeleteJobsAndCustomersTests.scratch(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        _ = try #require(try await Self.erase("C1", full: true, at: url))
        let after = try DeleteJobsAndCustomersTests.onDisk(url)
        #expect(Self.ids(after, "clients") == ["C2"], "the record (and its log) stayed")
        #expect(Self.ids(after, "printLog") == ["J-QUOTE", "J-INV", "J-PAID", "J-HIND"], "a job was removed")
        #expect(try Self.job(after, "J-QUOTE")["client"] == .string(""))
        #expect(try Self.job(after, "J-INV")["client"] == .string("Nouf"), "an invoice lost its buyer")
        #expect(try Self.job(after, "J-PAID")["client"] == .string("Nouf"), "a paid job lost its buyer")
        for id in ["J-QUOTE", "J-INV", "J-PAID"] { #expect(try Self.job(after, id)["clientId"] == .null) }
        let hind = try Self.job(after, "J-HIND")
        #expect(hind["client"] == .string("Hind") && hind["clientId"] == .string("C2"))
    }

    @Test("full erase purges intake by link, email or phone, and never another customer's rows")
    func fullErasePurgesOnlyTheirIntake() async throws {
        let url = try DeleteJobsAndCustomersTests.scratch(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let erased = try #require(try await Self.erase("C1", full: true, at: url))
        #expect(Set(erased.intake.compactMap { Shop.asObject($0).flatMap { MoveJobTests.string($0["id"]) } })
                == ["W-LINK", "W-MAIL", "W-PHONE"])
        let after = try DeleteJobsAndCustomersTests.onDisk(url)
        #expect(Self.ids(after, "waitingList") == ["W-OTHER", "W-NAME"])
        #expect(Self.ids(after, "waitingListHistory") == ["H-HIND"])
        // Hind's client record is whole.
        let hind = try #require(MoveJobTests.row(after, "clients", "C2"))
        #expect(hind["email"] == .string("hind@example.com"))
    }

    @Test("a second erase finds nobody and changes nothing")
    func eraseTwice() async throws {
        let url = try DeleteJobsAndCustomersTests.scratch(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try await Self.erase("C1", full: true, at: url)
        let once = try DeleteJobsAndCustomersTests.onDisk(url)
        #expect(try await Self.erase("C1", full: true, at: url) == nil)
        #expect(Self.ids(try DeleteJobsAndCustomersTests.onDisk(url), "printLog") == Self.ids(once, "printLog"))
    }

    @Test("Undo puts the record, the links, the names and the intake rows back")
    func undoPutsItBack() async throws {
        let url = try DeleteJobsAndCustomersTests.scratch(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let erased = try #require(try await Self.erase("C1", full: true, at: url))
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            Shop.applyCustomerUnerase(to: &root, erased)
        }
        let after = try DeleteJobsAndCustomersTests.onDisk(url)
        // Back under a fresh id (a delete is final to sync), with the links moved to it.
        let clients = MoveJobTests.rows(after, "clients")
        #expect(clients.count == 2)
        let back = try #require(clients.first { $0["nameEn"] == .string("Nouf") })
        let newId = try #require(MoveJobTests.string(back["id"]))
        for id in ["J-QUOTE", "J-INV", "J-PAID"] {
            let job = try Self.job(after, id)
            #expect(job["clientId"] == .string(newId), "\(id) was not relinked")
            #expect(job["client"] == .string("Nouf"), "\(id) did not get its name back")
        }
        #expect(Self.ids(after, "waitingList").count == 5)
        #expect(Self.ids(after, "waitingListHistory").count == 2)
    }

    // MARK: - The lock and the words

    @Test("the erase and the export ask the lock, and the erase asks what Delete asks")
    func gated() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/Shop+Privacy.swift")
        let src = WritersAreGatedTests.parse("Shop+Privacy.swift", try String(contentsOf: file, encoding: .utf8))
        func body(_ name: String) throws -> String { try #require(src.functions.first { $0.name == name }).text }
        #expect(try body("eraseCustomer").contains("permitted(\"clients\", \"delete\")"))
        #expect(try body("askToEraseCustomer").contains("permitted(\"clients\", \"delete\")"))
        #expect(try body("exportCustomerData").contains("permitted(\"clients\", \"edit\")"))
        #expect(try body("putBackErasedCustomer").contains("permitted(\"clients\", \"edit\")"))
        #expect(try body("eraseCustomer").contains("StoreWriter.updateAsync("))
    }

    static let keys = ["priv.section", "priv.export_data", "priv.exported", "priv.erase_title",
                       "priv.erase_summary", "priv.erase_keeps_invoiced", "priv.mode_unlink",
                       "priv.mode_unlink_hint", "priv.mode_full", "priv.mode_full_hint",
                       "priv.erased_full", "ce.deleted", "mac.erase_customer", "mac.undo_after"]

    @Test("every word the feature shows is there in English and Arabic", arguments: Words.supported)
    func wordsInBothLanguages(_ language: String) async throws {
        let words = try await WordsResolveTests.words(language)
        #expect(words.callIt("common.save") != "common.save", "the \(language) catalogue did not load")
        for key in Self.keys { #expect(words.callIt(key) != key, "\(key) is missing in \(language)") }
        let english = try await WordsResolveTests.words("en")
        if language == "ar" {
            for key in Self.keys { #expect(words.callIt(key) != english.callIt(key), "\(key) is English in Arabic") }
        }
        #expect(Words.own["mac.erase_customer"]?["ar"]?.isEmpty == false)
    }
}

/// An erased or deleted customer leaves Khayt Cloud's customer-records copy
/// at once, not on the next ten-minute look.
@MainActor
struct CustomerChangesReachTheCloudTests {
    @Test("erase, delete and both Undos republish customer records straight away")
    func wired() throws {
        let privacy = try QuoteSheetStatusTests.source("Shop+Privacy.swift")
        let delete = try QuoteSheetStatusTests.source("Shop+Delete.swift")
        #expect(privacy.components(separatedBy: "customersChangedOnCloud()").count - 1 >= 3,
                "erase and its Undo, plus the definition")
        #expect(delete.components(separatedBy: "customersChangedOnCloud()").count - 1 >= 2,
                "delete and its Undo")
        #expect(privacy.contains("await publishCustomerRecords(urgent: true)"))
    }

    @Test("with no cloud, the republish is a no-op, not an error")
    func quietWithoutCloud() async {
        let shop = Shop()
        await shop.load(.sample)
        shop.stopPublishingCustomerRecords()
        await shop.customersChangedOnCloud()
        #expect(shop.customerRecordsProblem == false)
    }
}
