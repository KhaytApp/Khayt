import Foundation
import Testing
import KhaytCore

/// The calculator's part, shared by the Mac and the phone (Oct 2026).
@Suite struct CalculatorPartTests {

    private let red = CalculatorPart.Spool(id: "S1", material: "PLA", cost: 100, spoolWeight: 1000, color: "#FF0000")
    private let blue = CalculatorPart.Spool(id: "S2", material: "PETG", cost: 200, spoolWeight: 1000, color: "#0000FF")

    private func obj(_ v: JSONValue) -> [String: JSONValue] {
        if case .object(let o) = v { return o }
        return [:]
    }

    @Test("one spool: the measured fields, the spool's price, and the purge charged as support")
    func single() {
        let part = obj(CalculatorPart.input(lines: [.init(spool: red, grams: 50)], purge: 5, hours: 2, qty: 3))
        #expect(part["printWeight"] == .number(50))
        #expect(part["printTime"] == .number(2))
        #expect(part["qty"] == .number(3))
        #expect(part["spoolCost"] == .number(100))
        #expect(part["spoolWeight"] == .number(1000))
        #expect(part["supportWeight"] == .number(5))
        #expect(part["colours"] == nil)
    }

    @Test("several colours: purge shared by weight, each spool priced per gram")
    func colours() {
        let part = obj(CalculatorPart.input(lines: [.init(spool: red, grams: 30), .init(spool: blue, grams: 10)],
                                            purge: 8, hours: 1, qty: 1))
        // 30 g + 6 g purge at 0.1/g, 10 g + 2 g purge at 0.2/g.
        #expect(part["printWeight"] == .number(48))
        #expect(part["spoolCost"] == .number(3.6 + 2.4))
        #expect(part["filamentId"] == .string("S1"))
        #expect(part["material"] == .string("PLA + PETG"))
        #expect(part["purgeGrams"] == .number(8))
        guard case .array(let c)? = part["colours"] else { Issue.record("no colours"); return }
        #expect(c.count == 2)
    }

    @Test("a consumable row carries its unit cost and never a non-finite count")
    func pieces() {
        let rows = CalculatorPart.consumableRows([("M", 4), ("X", .infinity), ("", 1)],
                                                 shelf: [.init(id: "M", name: "Magnet", cost: 0.5)])
        #expect(rows == [.object(["consumableId": .string("M"), "qty": .number(4),
                                  "unitCost": .number(0.5), "name": .string("Magnet")])])
    }

    @Test("rush takes the shop's own percentage, or twenty-five")
    func rush() {
        #expect(CalculatorPart.quoteInput(baseCost: 10, margin: 30, discountPct: 0, rush: true,
                                          settings: [:])["rushPct"] == .number(25))
        #expect(CalculatorPart.quoteInput(baseCost: 10, margin: 30, discountPct: 0, rush: true,
                                          settings: ["rushFeePct": .number(40)])["rushPct"] == .number(40))
        #expect(CalculatorPart.quoteInput(baseCost: 10, margin: 30, discountPct: 0, rush: false,
                                          settings: [:])["rushPct"] == nil)
    }
}

/// What a spool costs a job (`CalculatorPart.netCost`) is
/// `KhaytSpoolEdit.netCost`, which Electron, the LAN quote and the AI quote
/// cost with: the Mac charged the reclaimable tax to every job.
@Suite struct SpoolNetCostTests {

    @Test("a 115 spool holding 15 of tax costs a reclaiming shop 100, and a 200 g part 20.00")
    func reclaimed() {
        #expect(CalculatorPart.netCost(paid: 115, vatAmount: 15, reclaims: true) == 100)
        #expect(CalculatorPart.netCost(paid: 115, vatAmount: 15, reclaims: false) == 115,
                "a shop that reclaims nothing pays every riyal")
        #expect(CalculatorPart.netCost(paid: 115, vatAmount: nil, reclaims: true) == 115,
                "no tax is invented on a receipt nobody described")
        let spool = CalculatorPart.Spool(id: "S", material: "PLA",
                                         cost: CalculatorPart.netCost(paid: 115, vatAmount: 15, reclaims: true),
                                         spoolWeight: 1000, color: nil)
        guard case .object(let part) = CalculatorPart.single(spool: spool, grams: 200, hours: 1, qty: 1),
              case .number(let cost)? = part["spoolCost"], case .number(let weight)? = part["spoolWeight"] else {
            Issue.record("no part"); return
        }
        #expect(abs(cost / weight * 200 - 20) < 1e-9)
    }

    @Test("it agrees with KhaytSpoolEdit.netCost, awkward figures included")
    func parity() throws {
        let context = try Parity.context(loading: ["spool-edit"])
        let figures: [Double?] = [nil, 0, -5, 15, 115, 200, 0.005, 1.005, 1e20]
        for paid in figures {
            for vat in figures {
                for reclaims in [true, false] {
                    let js = try Parity.run(context, "KhaytSpoolEdit.netCost(ARG0, ARG1)", [
                        .object(["cost": paid.map(JSONValue.number) ?? .null,
                                 "vatAmount": vat.map(JSONValue.number) ?? .null]),
                        .bool(reclaims),
                    ])
                    let swift = CalculatorPart.netCost(paid: paid, vatAmount: vat, reclaims: reclaims)
                    #expect(js == .number(swift), "paid \(String(describing: paid)) vat \(String(describing: vat)) \(reclaims)")
                }
            }
        }
    }
}
