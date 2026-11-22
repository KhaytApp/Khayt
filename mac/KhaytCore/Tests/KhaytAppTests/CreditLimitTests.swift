import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A credit limit per customer, as the desktop keeps it (`creditLimit` on the
/// client, 0 for none; `renderer/clients.js` flags an outstanding balance over
/// it). The Mac reads it leniently, writes it back, carries it through every
/// other edit, and says when a customer is over it.
@MainActor
struct CreditLimitTests {

    @Test("a stored limit is read leniently and written back as a number")
    func readsAndWrites() throws {
        let typed = try #require(Client.decoding(["id": .string("C1"), "creditLimit": .string(" 5000 ")]))
        #expect(typed.creditLimit == 5000, "a hand-typed \"5000\" counts")
        #expect(typed.record["creditLimit"] == .number(5000))
        for bad: JSONValue in [.number(-10), .string("lots"), .null, .bool(true)] {
            let c = try #require(Client.decoding(["id": .string("C2"), "creditLimit": bad]))
            #expect(c.creditLimit == 0, "\(bad) is no limit")
        }
        let none = try #require(Client.decoding(["id": .string("C3")]))
        #expect(none.creditLimit == 0)
        #expect(none.limited(to: 750).creditLimit == 750)
        #expect(none.limited(to: -5).creditLimit == 0)
        #expect(none.limited(to: .infinity).creditLimit == 0)
    }

    @Test("every other edit keeps the limit")
    func editsKeepIt() throws {
        let c = try #require(Client.decoding(["id": .string("C1")])).limited(to: 2000)
        #expect(c.marketed(false).creditLimit == 2000)
        #expect(c.with(\.phone, "0500").creditLimit == 2000)
        #expect(c.onTerms(30).creditLimit == 2000)
        #expect(c.replacing(priceList: []).creditLimit == 2000)
        #expect(c.replacing(recurring: nil).creditLimit == 2000)
        #expect(c.optedIntoWhatsApp(true, how: "asked", at: Date()).creditLimit == 2000)
        #expect(c.optedIntoWhatsAppOffers(true, how: "asked", at: Date()).creditLimit == 2000)
    }

    @Test("an untouched save writes no limit onto a customer that had none; taking one off writes 0")
    func untouchedSave() throws {
        let was: [String: JSONValue] = ["id": .string("C1"), "nameEn": .string("Acme")]
        let client = try #require(Client.decoding(was))
        #expect(Shop.customerRecord(saving: client, over: was, opened: client)["creditLimit"] == nil)
        let had: [String: JSONValue] = ["id": .string("C1"), "nameEn": .string("Acme"), "creditLimit": .string("900")]
        let h = try #require(Client.decoding(had))
        #expect(Shop.customerRecord(saving: h, over: had, opened: h)["creditLimit"] == .string("900"),
                "kept as the other app typed it")
        #expect(Shop.customerRecord(saving: h.limited(to: 0), over: had, opened: h)["creditLimit"] == .number(0))
    }

    @Test("a customer owing more than their limit is over it; at or under it, or with none, is not")
    func overLimit() throws {
        func person(limit: Double, owing: [Double]) throws -> Customer {
            let orders = try owing.enumerated().map { i, amount in
                try JSONDecoder().decode(Order.self, from: JSONEncoder().encode([
                    "id": JSONValue.string("J\(i)"), "date": .string("2026-10-01"), "status": .string("completed"),
                    "project": .string("P"), "client": .string("Acme"), "clientId": .string("C1"),
                    "price": .number(amount), "paidAmount": .number(0), "paymentStatus": .string("unpaid"),
                    "printTime": .number(1), "priority": .bool(false), "notes": .string(""),
                ] as [String: JSONValue]))
            }
            let c = Client(id: "C1", nameEn: "Acme", creditLimit: limit)
            return try #require(Customer.from(orders, clients: [c]).first)
        }
        #expect(try person(limit: 500, owing: [300, 300]).isOverLimit)
        #expect(!(try person(limit: 600, owing: [300, 300]).isOverLimit), "at the limit is not over it")
        #expect(!(try person(limit: 0, owing: [9_000]).isOverLimit), "0 is no limit")
        #expect(try person(limit: 500, owing: [300, 300]).creditLimit == 500)
    }
}
