import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "Read the printer's history" must only be offered where there IS one.
///
/// ── REPORTED BY A SHOP THE DAY IT LINKED ITS PRUSA ────────────────────────
///
/// The machine card's comment said "Klipper keeps one; the other six protocols
/// do not expose one Khayt can read, and a menu item that always answers 'not
/// this printer' is an item that teaches people to ignore the menu" — and then
/// gated the item on `notWatched(machine) == nil`, which is true for every
/// protocol this app speaks. So the item appeared for a PrusaLink printer,
/// asked it for `/server/history/list` (Moonraker's path), and handed back a
/// bare 404.
///
/// A comment that states the rule is not the rule. This asks the predicate.
@MainActor
struct PrinterHistoryOfferTests {

    private func machine(_ type: String) -> Machine {
        let record: JSONValue = .object([
            "id": .string("M1"), "name": .string("A printer"),
            "printerApi": .object([
                "type": .string(type), "host": .string("192.168.1.40"), "port": .number(80),
            ]),
        ])
        let data = try! JSONEncoder().encode(record)
        return try! JSONDecoder().decode(Machine.self, from: data)
    }

    @Test("only Moonraker keeps a history this app can read")
    func onlyMoonraker() {
        #expect(PrinterWatch.keepsHistory(machine("moonraker")))
        #expect(!PrinterWatch.keepsHistory(machine("prusalink")))
        #expect(!PrinterWatch.keepsHistory(machine("octoprint")))
    }

    @Test("every protocol this app speaks is decided one way or the other")
    func everySpokenProtocolIsDecided() {
        // The point is that the set is CONSIDERED. A fourth protocol added to
        // `spoken` without a thought about its history would otherwise inherit
        // whatever this predicate happens to say.
        for type in PrinterWatch.spoken {
            let keeps = PrinterWatch.keepsHistory(machine(type))
            #expect(keeps == (type == "moonraker"),
                    "\(type): if this protocol grew a readable history, say so here and in history()")
        }
    }

    @Test("a printer with no connection at all is never offered it")
    func unlinkedIsNotOffered() {
        let bare: JSONValue = .object(["id": .string("M2"), "name": .string("Unlinked")])
        let data = try! JSONEncoder().encode(bare)
        let machine = try! JSONDecoder().decode(Machine.self, from: data)
        #expect(!PrinterWatch.keepsHistory(machine))
    }

    @Test("the refusal says why, rather than showing a shop a bare 404")
    func theRefusalExplains() {
        let said = String(describing: PrinterWatch.Refusal.noHistoryKept("prusalink"))
        #expect(said.contains("prusalink"))
        #expect(said.contains("404"), "the shop has already seen the 404; connect it to a reason")
        #expect(said.contains("your own book"), "and say what Khayt does instead")
    }
}
