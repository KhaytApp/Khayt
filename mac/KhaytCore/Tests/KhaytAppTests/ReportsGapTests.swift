import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The reports the Mac could not draw.
///
/// Each rule was written and tested while fixing a real arithmetic fault in the
/// Electron screen it belongs to, and each stayed behind because this app had
/// no screen to put it on. A rule the other app has and this one does not is
/// the gap that turns two apps into two answers.
///
/// These drive the ENGINE, not the module: what is being checked is that the
/// binding hands the rule what it needs and reads back what it returns — the
/// arithmetic already has its own tests in `test/`.
@MainActor
struct ReportsGapTests {



    @Test("two overlapping windows are 72 hours out of action, not 96")
    func downtimeIsTheUnion() async throws {
        let engine = try KhaytEngine()
        // A belt change Monday to Wednesday, and "waiting for the part"
        // Tuesday to Thursday. Both true, both recorded, and the machine is
        // unavailable for one stretch of 72 hours.
        let day = 86_400.0
        let monday = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01
        func iso(_ d: Date) -> String {
            let f = ISO8601DateFormatter()
            return f.string(from: d)
        }
        let machines: [JSONValue] = [.object([
            "id": .string("m1"), "name": .string("X1C"),
            "downtimeBlocks": .array([
                .object(["from": .string(iso(monday)), "to": .string(iso(monday + 2 * day))]),
                .object(["from": .string(iso(monday + day)), "to": .string(iso(monday + 3 * day))]),
            ]),
        ])]
        let rows = try await engine.downtimeHours(
            machines: machines, months: [(from: monday - day, to: monday + 10 * day)])
        let row = try #require(rows.first)
        #expect(abs(row.total - 72) < 0.001,
                Comment(rawValue: "summing the windows gives 96; got \(row.total)"))
        #expect(row.name == "X1C")
    }

    @Test("a machine that never went down is not a row of zeros")
    func downtimeSkipsHealthyMachines() async throws {
        let engine = try KhaytEngine()
        let machines: [JSONValue] = [
            .object(["id": .string("fine"), "name": .string("Never down")]),
            .object(["id": .string("m1"), "name": .string("Down once"),
                     "downtimeBlocks": .array([.object([
                        "from": .string("2026-01-01T00:00:00Z"),
                        "to": .string("2026-01-01T06:00:00Z")])])]),
        ]
        let rows = try await engine.downtimeHours(
            machines: machines,
            months: [(from: Date(timeIntervalSince1970: 1_767_225_600),
                      to: Date(timeIntervalSince1970: 1_767_225_600 + 86_400 * 31))])
        #expect(rows.count == 1, "a machine with nothing to say got a row anyway")
        #expect(rows[0].machineId == "m1")
        #expect(abs(rows[0].total - 6) < 0.001)
    }

    @Test("maintenance comes from the book's own list, for the year asked")
    func maintenanceCost() async throws {
        let engine = try KhaytEngine()
        let machines: [JSONValue] = [.object(["id": .string("m1"), "name": .string("U1")])]
        // The shape the book stores, which is one flat list — NOT a property
        // on the machine, which is what the other app's chart read and which
        // nothing has ever written.
        let log: [JSONValue] = [
            .object(["machineId": .string("m1"), "date": .string("2026-02-10"), "cost": .number(40)]),
            .object(["machineId": .string("m1"), "date": .string("2026-06-01"), "cost": .number(25)]),
            .object(["machineId": .string("m1"), "date": .string("2025-11-02"), "cost": .number(500)]),
            // A machine sold since. The money still left the shop.
            .object(["machineId": .string("gone"), "date": .string("2026-03-03"), "cost": .number(90)]),
        ]
        let rows = try await engine.maintenanceCost(machines: machines, entries: log, year: 2026)
        let u1 = try #require(rows.first { $0.machineId == "m1" })
        #expect(u1.total == 65, "last year's overhaul was charged against this year")
        #expect(u1.name == "U1")
        #expect(!u1.orphan)
        let sold = try #require(rows.first { $0.machineId == "gone" })
        #expect(sold.total == 90, "a sold machine's servicing vanished from the total")
        #expect(sold.orphan)
    }

    @Test("a date is bucketed by its own text, not by the reader's timezone")
    func maintenanceYearIsNotTimezoneShifted() async throws {
        let engine = try KhaytEngine()
        let machines: [JSONValue] = [.object(["id": .string("m1"), "name": .string("U1")])]
        // Midnight UTC on new year's day. Parsed as a date and read back with
        // getFullYear(), a shop west of UTC sees 31 December of the year
        // before — so its new year's servicing lands in the wrong year.
        let log: [JSONValue] = [
            .object(["machineId": .string("m1"), "date": .string("2026-01-01"), "cost": .number(70)]),
        ]
        #expect(try await engine.maintenanceCost(machines: machines, entries: log, year: 2026)
                    .first?.total == 70)
        #expect(try await engine.maintenanceCost(machines: machines, entries: log, year: 2025)
                    .isEmpty)
    }

    @Test("the rating trend covers the months asked, not all of history")
    func ratingTrend() async throws {
        let engine = try KhaytEngine()
        func rated(_ month: String, _ n: Double) -> JSONValue {
            .object(["status": .string("completed"),
                     "completedAt": .string("\(month)-15T12:00:00.000Z"),
                     "survey": .object(["rating": .number(n)])])
        }
        // Three ones from two years ago, three fives in the window.
        let orders = [rated("2024-03", 1), rated("2024-04", 1), rated("2024-05", 1),
                      rated("2026-05", 5), rated("2026-06", 5), rated("2026-07", 5)]
        let months = ["2026-04", "2026-05", "2026-06", "2026-07", "2026-08", "2026-09"]
        let trend = try await engine.ratingTrend(orders: orders, months: months)
        #expect(trend.responses == 3, "the caption counted every rating ever collected")
        #expect(trend.average == 5)
        #expect(trend.allTimeResponses == 6, "the older three are still counted, separately")
        #expect(trend.points.count == 6)
        #expect(trend.enough)
    }

    @Test("a customer from the intake form is not lost, and a void is not revenue")
    func clientSources() async throws {
        let engine = try KhaytEngine()
        let clients: [JSONValue] = [
            // What the intake import stamps. The Electron chart drew six
            // sources and this was not one of them.
            .object(["id": .string("c1"), "source": .string("online")]),
            .object(["id": .string("c2"), "source": .string("instagram")]),
        ]
        let orders: [JSONValue] = [
            .object(["id": .string("a"), "clientId": .string("c1"),
                     "status": .string("completed"), "price": .number(500)]),
            .object(["id": .string("b"), "clientId": .string("c2"),
                     "status": .string("completed"), "price": .number(100)]),
            .object(["id": .string("c"), "clientId": .string("c2"),
                     "status": .string("completed"), "price": .number(900),
                     "voidedAt": .string("2026-01-02")]),
        ]
        let rows = try await engine.clientSources(clients: clients, orders: orders,
                                                  settings: ["currency": .string("SAR")])
        let online = try #require(rows.rows.first { $0.source == "online" })
        #expect(online.count == 1)
        #expect(online.revenue == 500, "the intake customer's money went nowhere")
        let insta = try #require(rows.rows.first { $0.source == "instagram" })
        #expect(insta.revenue == 100, "a voided order counted as money a source brought in")
        #expect(rows.totalClients == 2)
        #expect(rows.totalRevenue == 600, "the void is out of the total too")
    }

    @Test("expenses by category net the reclaimable tax when the shop reclaims it")
    func expenseCategories() async throws {
        let engine = try KhaytEngine()
        let expenses: [JSONValue] = [
            .object(["category": .string("Filament"), "amount": .number(115),
                     "vatAmount": .number(15)]),
            .object(["category": .string("Rent"), "amount": .number(1000)]),
        ]
        let gross = try await engine.expenseCategories(expenses, reclaimsTax: false)
        let net = try await engine.expenseCategories(expenses, reclaimsTax: true)
        let filamentGross = try #require(gross.rows.first { $0.category == "Filament" })
        let filamentNet = try #require(net.rows.first { $0.category == "Filament" })
        #expect(filamentGross.amount == 115)
        #expect(filamentNet.amount == 100, "a registered shop bore 100, not 115")
        #expect(filamentNet.reclaimed == 15)
        // Rent carried no tax either way.
        #expect(net.rows.first { $0.category == "Rent" }?.amount == 1000)
        // The total is the rule's, not the screen's: 1100 borne, 15 claimed back.
        #expect(net.total == 1100)
        #expect(net.reclaimed == 15)
        #expect(gross.total == 1115, "an unregistered shop bore the tax too")
    }

}

/// The customer's lead source, which the Mac could not set.
///
/// The chart was only half the gap: a report counting customers by source is
/// a report of "Other" for every shop whose only app is this one. These cover
/// the field, and the two ways a field like it has broken before.
@MainActor
struct ClientSourceFieldTests {

    @Test("the picker offers the RULE's list, not a copy of it")
    func listComesFromTheRule() async throws {
        let engine = try KhaytEngine()
        let names = try await engine.clientSourceNames()
        // The seventh is the whole point: `online` is stamped by the intake
        // form and is not on any editor's list of choices, which is how the
        // Electron chart came to drop every customer who arrived that way.
        #expect(names.contains("online"))
        #expect(names.count == 7, Comment(rawValue: "got \(names)"))
        #expect(names.last == "other", "the fallback sorts last, after the real choices")
    }

    @Test("every source the picker can offer has a name in both languages")
    func everySourceIsTranslated() async throws {
        let engine = try KhaytEngine()
        let names = try await engine.clientSourceNames()
        for language in ["en", "ar"] {
            let words = Words()
            await words.load(language, engine: engine)
            for source in names {
                let key = "cl.source_" + source
                let said = words.callIt(key)
                // A missing key renders as the key itself — a customer row
                // reading "cl.source_online" is exactly how this last broke.
                #expect(said != key,
                        Comment(rawValue: "\(key) has no \(language) translation"))
                #expect(!said.isEmpty)
            }
        }
    }

    @Test("editing any other field does not wipe the source")
    func sourceSurvivesAnEdit() {
        // `with` rebuilds the whole record through the memberwise initialiser,
        // where `source` defaults to "". A field added to the model and not to
        // this copier is silently cleared the first time anyone retypes a
        // phone number — which is how a catalogue lost its part costs once.
        let client = Client(id: "C1", nameEn: "Acme", phone: "0500", source: "referral")
        let renamed = client.with(\.nameEn, "Acme Co")
        #expect(renamed.source == "referral")
        let repriced = client.replacing(priceList: [])
        #expect(repriced.source == "referral")
        let rescheduled = client.replacing(recurring: nil)
        #expect(rescheduled.source == "referral")
    }

    @Test("a source this build does not know is kept, not folded to other")
    func unknownSourceIsKept() throws {
        // A newer Khayt may write a source this build has never heard of. The
        // model stores it verbatim; only the REPORT folds it onto "other" when
        // it counts. Normalising on the way in would rewrite the shop's data
        // to "other" the first time somebody opened the sheet.
        let raw = #"{"id":"C1","source":"tiktok"}"#.data(using: .utf8)!
        let client = try JSONDecoder().decode(Client.self, from: raw)
        #expect(client.source == "tiktok")
        #expect(client.record["source"] == .string("tiktok"))
    }

    @Test("a customer with no source is not the same as one filed under other")
    func unsetIsNotOther() throws {
        let raw = #"{"id":"C1"}"#.data(using: .utf8)!
        let client = try JSONDecoder().decode(Client.self, from: raw)
        #expect(client.source == "")
    }
}
