import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Three kinds of customer, and the middle one was missing.
///
/// There is the customer nobody has written down, the one written down with a
/// phone number, and the one written down as a name and nothing else. That last
/// is ordinary — the decoder exists so a row "written down in a hurry" still
/// reads — and it printed a CLIENT heading with nothing beneath it, which reads
/// as a screen that failed to load.
///
/// Sending it down the other branch instead would say "Not written down yet"
/// about somebody who is, so the answer is a third state and not a swapped
/// condition. This is the test that tells the two mistakes apart.
struct CustomerRecordTests {

    static func client(_ json: String) throws -> Client {
        try JSONDecoder().decode(Client.self, from: Data(json.utf8))
    }

    @Test("a name and nothing else has nothing to put under a heading")
    func aNameOnly() throws {
        let bare = try Self.client(#"{"id":"C1","nameEn":"Najd Architects"}"#)
        #expect(bare.nameEn == "Najd Architects", "and it is still a real record")
        #expect(!bare.hasContactDetails)
    }

    @Test("any one of the five is enough to draw the section")
    func anyFieldCounts() throws {
        let fields = ["phone": "+966 50 123 4567", "email": "a@b.example",
                      "cr": "1010000000", "vat": "300000000000003", "notes": "Pays late"]
        for (key, value) in fields {
            let one = try Self.client(#"{"id":"C1","nameEn":"Najd","\#(key)":"\#(value)"}"#)
            #expect(one.hasContactDetails, "\(key) alone should be enough")
        }
    }

    /// The name is the title of the pane, said above the section. Counting it
    /// would bring the empty heading straight back.
    @Test("the name is not one of the details")
    func theNameDoesNotCount() throws {
        let bilingual = try Self.client(#"{"id":"C1","nameEn":"Najd","nameAr":"نجد"}"#)
        #expect(!bilingual.hasContactDetails)
    }

    /// A field present and empty is a field that is not there. The decoder
    /// turns every missing string into "", so these are the same case.
    @Test("an empty string is not a detail")
    func emptyIsAbsent() throws {
        let blank = try Self.client(#"{"id":"C1","nameEn":"Najd","phone":"","email":"","notes":""}"#)
        #expect(!blank.hasContactDetails)
    }
}

/// The three things that follow a customer, as the record holds them.
///
/// Two apps write this record. The Mac reads what the other app wrote — in
/// BOTH shapes the log comes in — keeps every field it has no opinion about,
/// and writes back only what its screens edit.
struct CustomerTermsTests {

    static func client(_ json: String) throws -> Client {
        try JSONDecoder().decode(Client.self, from: Data(json.utf8))
    }

    @Test("a price list, a schedule and a log are read, with their unknown fields")
    func termsAreRead() throws {
        let c = try Self.client(#"""
        {"id":"C1","nameEn":"KAUST",
         "priceList":[{"product":"bracket","price":45,"note":"2026"},{"product":"","price":0,"note":""}, 7],
         "recurring":{"enabled":true,"interval":"monthly","nextDue":"2026-07-15","paused":false,
                      "endDate":null,"leadDays":3,"templateOrderId":"ORD-9","cloneStatus":"printing"},
         "commLog":[{"id":"CMM-1","type":"whatsapp","note":"slot?","at":"2026-09-02T14:12:00.000Z"},
                    {"channel":"phone","note":"called","at":"2026-08-31T09:40:00.000Z","quick":true},
                    "not an entry"]}
        """#)
        #expect(c.priceList.count == 2, "a non-object entry is ignored, a blank one is kept for the sheet")
        #expect(c.priceList[0].product == "bracket")
        #expect(c.priceList[0].price == 45)
        #expect(c.priceList[1].isBlank)
        let rec = try #require(c.recurring)
        #expect(rec.enabled && rec.interval == "monthly" && rec.nextDue == "2026-07-15")
        #expect(rec.leadDays == 3)
        #expect(rec.templateOrderId == "ORD-9")
        #expect(rec.raw["cloneStatus"] == .string("printing"), "a field this app does not edit is still carried")
        #expect(c.standingOrder != nil)
        #expect(c.commLog.count == 2)
        #expect(c.commLog[0].kind == "whatsapp" && c.commLog[0].wordKey == "ce.comm_wa")
        #expect(c.commLog[1].kind == "call", "the quick note's `channel: phone` is the editor's `type: call`")
        #expect(c.commLog[1].day == "2026-08-31")
        #expect(c.commLog[1].raw["quick"] == .bool(true))
    }

    @Test("a record without them, or with them null, is a customer with none")
    func absentIsEmpty() throws {
        let bare = try Self.client(#"{"id":"C1","nameEn":"Najd"}"#)
        #expect(bare.priceList.isEmpty && bare.recurring == nil && bare.commLog.isEmpty)
        let nulled = try Self.client(#"{"id":"C1","nameEn":"Najd","priceList":null,"recurring":null,"commLog":null}"#)
        #expect(nulled.priceList.isEmpty && nulled.recurring == nil && nulled.commLog.isEmpty)
        // Set up and switched off is not "none": the record keeps the dates.
        let off = try Self.client(#"{"id":"C1","nameEn":"Najd","recurring":{"enabled":false,"interval":"quarterly","nextDue":"2026-10-01"}}"#)
        #expect(off.recurring != nil && off.standingOrder == nil)
    }

    @Test("the sheet's record carries the price list and the schedule, and NOT the log")
    func recordShape() throws {
        let c = try Self.client(#"""
        {"id":"C1","nameEn":"KAUST",
         "priceList":[{"product":"bracket","price":45,"note":"2026","extra":"kept"}],
         "recurring":{"enabled":true,"interval":"monthly","nextDue":"2026-07-15","leadDays":3},
         "commLog":[{"id":"CMM-1","type":"note","note":"x","at":"2026-09-02T14:12:00.000Z"}]}
        """#)
        let record = c.record
        #expect(record["priceList"] == .array([.object([
            "product": .string("bracket"), "price": .number(45), "note": .string("2026"), "extra": .string("kept"),
        ])]), "every field of the row survives, edited or not")
        #expect(record["recurring"] == .object([
            "enabled": .bool(true), "interval": .string("monthly"), "nextDue": .string("2026-07-15"), "leadDays": .number(3),
        ]))
        #expect(record["commLog"] == nil, "the log is written the moment a line is added, never by the sheet")
        // Editing keeps the rest.
        var next = c.recurring!
        next.paused = true
        next.nextDue = nil
        let edited = c.replacing(recurring: next).record
        #expect(edited["recurring"] == .object([
            "enabled": .bool(true), "interval": .string("monthly"), "nextDue": .null,
            "leadDays": .number(3), "paused": .bool(true),
        ]))
        #expect(c.with(\.phone, "1").recurring == c.recurring, "a text edit carries the terms along")
        #expect(c.with(\.phone, "1").commLog == c.commLog)
    }

    @Test("a new log line is written in the editor's shape, and a day is a day")
    func newLine() {
        let at = Date(timeIntervalSince1970: 1_789_000_000)
        let line = CommEntry(id: "CMM-X", kind: "call", note: "Rang back", at: at)
        #expect(line.raw["type"] == .string("call"))
        #expect(line.raw["id"] == .string("CMM-X"))
        #expect(line.at == StoreWriter.iso(at))
        #expect(line.day == String(StoreWriter.iso(at).prefix(10)))
        #expect(Recurring.day("2026-07-15").map(Recurring.string) == "2026-07-15")
        #expect(Recurring.day("garbage") == nil)
        #expect(Recurring.fresh.enabled == false && Recurring.fresh.interval == "monthly" && Recurring.fresh.nextDue == nil)
    }
}
