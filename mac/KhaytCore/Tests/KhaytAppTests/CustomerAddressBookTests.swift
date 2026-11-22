import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A customer's address book, as the desktop keeps it — `addresses: [{ id,
/// label, address }]`, the first the default — written on the Mac too
/// (Nov 10: no Mac user could give a customer an address, so nothing could be
/// shipped through Lamha). Desktop's rows, extra fields and the legacy single
/// `address` field all survive a Mac save.
@MainActor
struct CustomerAddressBookTests {

    static let desktop: [String: JSONValue] = [
        "id": .string("C1"), "nameEn": .string("Acme"),
        "address": .string("Old single line"),
        "addresses": .array([
            .object(["id": .string("ADDR-1"), "label": .string("Office"), "address": .string("King Fahd Rd, Riyadh"),
                     "zip": .string("12271")]),
            .object(["id": .string("ADDR-2"), "label": .string("Home"), "address": .string("Olaya, Riyadh")]),
        ]),
    ]

    @Test("the desktop's rows are read in order, each kept whole")
    func reads() throws {
        let c = try #require(Client.decoding(Self.desktop))
        #expect(c.addresses.map(\.label) == ["Office", "Home"])
        #expect(c.addresses.first?.address == "King Fahd Rd, Riyadh")
        #expect(c.addresses.first?.raw["zip"] == .string("12271"), "a field this app does not know stays on the row")
        // Not a list, or rows that are not objects: no addresses, never a lost customer.
        for bad: JSONValue in [.string("x"), .null, .array([.string("x"), .number(1)])] {
            let odd = try #require(Client.decoding(["id": .string("C2"), "addresses": bad]))
            #expect(odd.addresses.isEmpty)
        }
    }

    @Test("an untouched save leaves the address book and the old address field byte for byte")
    func untouched() throws {
        let c = try #require(Client.decoding(Self.desktop))
        let saved = Shop.customerRecord(saving: CustomerSheet.saving(CustomerSheet.opening(c)), over: Self.desktop, opened: c)
        #expect(saved["addresses"] == Self.desktop["addresses"])
        #expect(saved["address"] == .string("Old single line"))
        // A customer with no address book gets no key from an untouched save.
        let bare: [String: JSONValue] = ["id": .string("C3"), "nameEn": .string("B")]
        let b = try #require(Client.decoding(bare))
        #expect(Shop.customerRecord(saving: b, over: bare, opened: b)["addresses"] == nil)
    }

    @Test("adding, editing, and removing rows is what is saved; blank rows are dropped")
    func edits() throws {
        let c = try #require(Client.decoding(Self.desktop))
        var opened = CustomerSheet.opening(c)
        opened.addresses[1].address = "Al Malqa, Riyadh"
        opened.addresses.append(ClientAddress(label: "Warehouse", address: "Exit 18"))
        opened.addresses.append(ClientAddress())   // added and left blank
        let saved = Shop.customerRecord(saving: CustomerSheet.saving(opened), over: Self.desktop, opened: c)
        guard case .array(let rows)? = saved["addresses"] else { Issue.record("no addresses"); return }
        #expect(rows.count == 3)
        #expect(rows.first == Self.desktop["addresses"].flatMap { if case .array(let a) = $0 { a.first } else { nil } },
                "the untouched first row is as it was, its extra field included")
        guard case .object(let added) = rows[2] else { Issue.record("not an object"); return }
        #expect(added["label"] == .string("Warehouse"))
        if case .string(let id)? = added["id"] { #expect(id.hasPrefix("ADDR-"), "an id the desktop's way") }
        else { Issue.record("a new row has no id") }
        #expect(saved["address"] == .string("Old single line"), "the legacy field is never stripped")

        // Taking every address off can be saved.
        var none = CustomerSheet.opening(c); none.addresses = []
        #expect(Shop.customerRecord(saving: CustomerSheet.saving(none), over: Self.desktop, opened: c)["addresses"] == .array([]))
    }

    @Test("every other edit keeps the address book")
    func editsKeepIt() throws {
        let c = try #require(Client.decoding(Self.desktop))
        let n = c.addresses.count
        #expect(c.marketed(false).addresses.count == n)
        #expect(c.with(\.phone, "0500").addresses.count == n)
        #expect(c.onTerms(30).addresses.count == n)
        #expect(c.limited(to: 10).addresses.count == n)
        #expect(c.inCurrency("EUR").addresses.count == n)
        #expect(c.replacing(priceList: []).addresses.count == n)
        #expect(c.replacing(recurring: nil).addresses.count == n)
        #expect(c.optedIntoWhatsApp(true, how: "asked", at: Date()).addresses.count == n)
        #expect(c.optedIntoWhatsAppOffers(true, how: "asked", at: Date()).addresses.count == n)
    }

    @Test("the first address is what a courier connector sends as the customer's address")
    func reachesConnector() async throws {
        let shop = await ConnectorInstallTests.shop()
        let engine = try #require(shop.engine)
        let manifest = try JSONValue.decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "plugins/samples/lamha-shipping.json")))
        let customer = JSONValue.object(Self.desktop.filter { $0.key != "address" })   // only the address book
        // Every required setting filled, the carrier one of Lamha's own.
        guard case .array(let settings)? = Shop.object(manifest)["settings"] else { Issue.record("no settings"); return }
        var config: [String: JSONValue] = [:]
        for st in settings {
            let o = Shop.object(st)
            guard let key = Shop.plainString(o["key"]) else { continue }
            if case .array(let options)? = o["options"], let first = options.first {
                config[key] = Shop.object(first)["value"] ?? .null
            } else {
                config[key] = .string("x")
            }
        }
        let order: JSONValue = .object(["id": .string("J-1"), "invoiceNumber": .string("1001"), "price": .number(100), "qty": .number(1)])
        let payload = try await engine.pluginPayload(manifest, trigger: .object(["action": .string("record")]),
                                                     context: .object(["order": order, "customer": customer,
                                                                       "config": .object(config), "secrets": .object([:])]))
        let body = Shop.plainString(Shop.object(payload)["body"]) ?? ""
        #expect(body.contains("King Fahd Rd, Riyadh"), Comment(rawValue: String(body.prefix(400))))
    }
}
