import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Who the shop's customers are.
///
/// This app derived them from the names denormalised onto orders and never
/// opened the `clients` collection — so a customer with no jobs did not exist
/// here, nobody's phone number was ever shown, and, worst of all, the id it
/// gave each one was their NAME lowercased.
///
/// That last one is not cosmetic. A job's `clientId` points at a row in
/// `clients`, and everything that follows a customer through Khayt reads it. A
/// job created against `"acme"` looks linked and is not.
@MainActor
struct CustomerTests {

    static func order(_ id: String, client: String, clientId: String? = nil) throws -> Order {
        var row: [String: JSONValue] = [
            "id": .string(id), "date": .string("2026-09-01"), "status": .string("pending"),
            "project": .string("P"), "client": .string(client), "price": .number(100),
            "paidAmount": .number(0), "paymentStatus": .string("unpaid"),
            "printTime": .number(1), "priority": .bool(false), "notes": .string(""),
        ]
        if let clientId { row["clientId"] = .string(clientId) }
        return try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(row))
    }

    @Test("a customer the shop wrote down keeps the id a job can point at")
    func writtenDownCustomersKeepTheirId() throws {
        let clients = [Client(id: "CLI-1", nameEn: "Acme")]
        let orders = [try Self.order("J1", client: "Acme", clientId: "CLI-1")]
        let people = Customer.from(orders, clients: clients)

        #expect(people.count == 1)
        #expect(people[0].clientId == "CLI-1", "and NOT the name lowercased")
        #expect(people[0].record?.nameEn == "Acme")
        #expect(people[0].jobCount == 1)
    }

    @Test("a customer with no jobs yet still exists")
    func customersWithNoJobs() throws {
        let people = Customer.from([], clients: [Client(id: "CLI-1", nameEn: "Acme")])
        #expect(people.count == 1)
        #expect(people[0].jobCount == 0, "somebody written down before their first job")
    }

    /// A shop that has never used the customer screen has the name on the order
    /// and no `clientId` at all — which is exactly this Mac's own book.
    @Test("an established customer whose jobs predate their record keeps their history")
    func matchesOnNameWhenTheJobsCarryNoId() throws {
        let clients = [Client(id: "CLI-1", nameEn: "Acme")]
        let orders = [try Self.order("J1", client: "Acme"), try Self.order("J2", client: "acme")]
        let people = Customer.from(orders, clients: clients)

        #expect(people.count == 1, "not one written-down customer and one name-only ghost")
        #expect(people[0].jobCount == 2)
        #expect(people[0].clientId == "CLI-1")
    }

    @Test("a name on an old job is still a customer, and has no id to give")
    func nameOnlyCustomers() throws {
        let orders = [try Self.order("J1", client: "Someone Else")]
        let people = Customer.from(orders, clients: [Client(id: "CLI-1", nameEn: "Acme")])

        let ghost = try #require(people.first { $0.name == "Someone Else" })
        #expect(ghost.clientId == nil, "a job pointed at an invented id looks linked and is not")
        #expect(ghost.record == nil)
        #expect(people.count == 2, "dropping them would hide most of a shop's history")
    }

    @Test("a job is never attributed to two people")
    func noDoubleCounting() throws {
        let clients = [Client(id: "CLI-1", nameEn: "Acme"), Client(id: "CLI-2", nameEn: "Acme")]
        let orders = [try Self.order("J1", client: "Acme")]
        let people = Customer.from(orders, clients: clients)
        let total = people.reduce(0) { $0 + $1.jobCount }
        #expect(total == 1, "two records with one name must not each claim the job")
    }

    @Test("a client row with no id is not a customer this app can offer")
    func clientsNeedAnId() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let withId: [String: JSONValue] = ["id": .string("CLI-1"), "nameEn": .string("Acme")]
        let without: [String: JSONValue] = ["nameEn": .string("Acme")]
        #expect((try? decoder.decode(Client.self, from: encoder.encode(withId))) != nil)
        #expect((try? decoder.decode(Client.self, from: encoder.encode(without))) == nil,
                "a client no job can point at is not one to put in the picker")
    }

    @Test("a customer written down in a hurry has a name and nothing else")
    func everythingButTheIdIsOptional() throws {
        let bare: [String: JSONValue] = ["id": .string("CLI-1"), "nameAr": .string("شركة")]
        let client = try JSONDecoder().decode(Client.self, from: JSONEncoder().encode(bare))
        #expect(client.nameEn.isEmpty)
        #expect(client.anyName == "شركة", "the name they have, not the one they have not")
        #expect(client.phone.isEmpty)
        #expect(client.defaultDiscount == 0)
    }

    @Test("the id is minted in Khayt's own shape")
    func idShape() {
        let client = Shop.newCustomer()
        #expect(client.id.hasPrefix("CLI-"))
        #expect(client.createdAt?.count == 10, "a local day, the way localDateStr writes it")
    }

    /// The screen shows six fields; the record has more. A shop's price list,
    /// recurring schedule and communications log are not this app's to lose.
    @Test("saving from a six-field screen does not delete the other ten")
    func savePreservesUnknownFields() throws {
        let existing: [String: JSONValue] = [
            "id": .string("CLI-1"), "nameEn": .string("Acme"),
            "priceList": .array([.object(["sku": .string("A")])]),
            "recurring": .object(["enabled": .bool(true)]),
            "commLog": .array([.object(["note": .string("called")])]),
        ]
        var edited = Client(id: "CLI-1", nameEn: "Acme Ltd").record
        // The merge `saveCustomer` performs, in the same order.
        guard case .object(let was) = JSONValue.object(existing) else { return }
        for (key, value) in was where edited[key] == nil { edited[key] = value }

        #expect(edited["nameEn"] == .string("Acme Ltd"), "the edit landed")
        #expect(edited["recurring"] != nil)
        #expect(edited["commLog"] != nil, "the log is never the sheet's to write, so the merge keeps it")
        // The sheet edits the price list now, so a record that came from the
        // book carries the book's rows through its own `record` — including
        // a field this app has never heard of.
        let fromBook = try JSONDecoder().decode(Client.self, from: JSONEncoder().encode(JSONValue.object(existing)))
        #expect(fromBook.record["priceList"] == .array([.object(["sku": .string("A")])]))
    }
}

/// What the shop calls its customers.
///
/// THE DEFECT THIS EXISTS FOR: the customers table spelled names itself, with
/// `Client.anyName` — English first, then Arabic, then the id. That is exactly
/// the shape `test/content-languages.test.js` forbids in JavaScript, written in
/// Swift where that guard cannot see it. `customerName` and `customerAltName`
/// were on the engine, correct, and called by nothing.
///
/// Photographed to find it: an Arabic run listed "Tuwaiq Makerspace" on the
/// Customers screen and "مساحة طويق للصناع" on the Best page — same shop, same
/// record, two screens, two names.
@MainActor
struct CustomerNameTests {

    static let clients: [JSONValue] = [
        .object(["id": .string("C-1"), "nameEn": .string("Tuwaiq Makerspace"),
                 "nameAr": .string("مساحة طويق للصناع")]),
        .object(["id": .string("C-2"), "nameEn": .string("Hail Motors")]),
    ]

    @Test("an Arabic shop is given its Arabic names")
    func arabicShop() async throws {
        let names = try await KhaytEngine().customerNames(
            Self.clients, language: "ar", settings: ["contentLangs": .array([.string("ar"), .string("en")])])
        #expect(names["C-1"]?.name == "مساحة طويق للصناع")
        // …and one with no Arabic name still has a name, rather than an id.
        #expect(names["C-2"]?.name == "Hail Motors")
    }

    @Test("an English shop is given its English names")
    func englishShop() async throws {
        let names = try await KhaytEngine().customerNames(
            Self.clients, language: "en", settings: ["contentLangs": .array([.string("en")])])
        #expect(names["C-1"]?.name == "Tuwaiq Makerspace")
    }

    @Test("the other language goes on the second line, and only when there is one")
    func altName() async throws {
        let names = try await KhaytEngine().customerNames(
            Self.clients, language: "ar", settings: ["contentLangs": .array([.string("ar"), .string("en")])])
        #expect(names["C-1"]?.alt == "Tuwaiq Makerspace")
        // `readAlt` returns the SAME string for a record with one name filled
        // in — the fallback has already put that field in both, and the
        // renderer does not dedupe either. `customerNames` blanks it, so a
        // second line can be rendered without checking.
        #expect(names["C-2"]?.alt == "", "the only name would have been printed twice")
    }

    @Test("the table shows the resolved name, not the English one")
    func theTableUsesIt() throws {
        let client = try JSONDecoder().decode(Client.self, from: JSONEncoder().encode(Self.clients[0]))
        let resolved: [String: KhaytEngine.Named] = ["C-1": .init(name: "مساحة طويق للصناع", alt: "Tuwaiq Makerspace")]
        let rows = Customer.from([], clients: [client], names: resolved)
        #expect(rows.first?.name == "مساحة طويق للصناع")
    }

    @Test("with no engine the list still has names, and says which it used")
    func fallsBackOnlyWhenItMust() throws {
        // A dead engine is silent — that lesson cost a day. The list must still
        // show something, and `anyName` is the last resort rather than the
        // first: nothing else in the app is allowed to reach for it.
        let client = try JSONDecoder().decode(Client.self, from: JSONEncoder().encode(Self.clients[0]))
        let rows = Customer.from([], clients: [client], names: [:])
        #expect(rows.first?.name == "Tuwaiq Makerspace")
    }

    @Test("a resolved name that is empty does not blank the row")
    func emptyResolvedIsNotAName() throws {
        let client = try JSONDecoder().decode(Client.self, from: JSONEncoder().encode(Self.clients[0]))
        let rows = Customer.from([], clients: [client], names: ["C-1": .init(name: "", alt: "")])
        #expect(rows.first?.name == "Tuwaiq Makerspace")
    }

    @Test("the screen is wired to the resolved names")
    func theScreenIsWired() throws {
        // A source guard: `customers` is a computed property on an @Observable
        // model and there is no seam. What it catches is the exact regression —
        // dropping the argument and going back to spelling names in Swift.
        let shop = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift"), encoding: .utf8)
        #expect(shop.contains("Customer.from(orders, clients: clients, names: clientNames)"))
        #expect(shop.contains("engine?.customerNames("),
                "the names must be resolved when the book loads")
    }
}
