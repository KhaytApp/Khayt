import XCTest
import KhaytCore
@testable import KhaytCompanion

/**
 * "No live connection", under a printer that has one.
 *
 * `hasPrinterApi` is derived, not stored. `lib/lan-server.js` computes it on the
 * way out — `!!(m.printerApi?.type && m.printerApi.type !== 'none')` — and a
 * machine in the book has only the `printerApi` object it is derived from.
 *
 * That stopped being harmless when the screens began reading the book instead of
 * the wire: a raw record decoded to nil, `MachinesView` read nil as false, and
 * every machine in the shop was labelled "No live connection" — including the
 * ones with a printer plugged in and reporting.
 *
 * ── WHY THE SAMPLE BOOK CANNOT TEST THIS ──────────────────────────────────
 *
 * Not one of the five machines in `sample-shop.json` has a `printerApi`
 * configured, so both paths agree on false and the gap is invisible to it.
 * These fixtures are written by hand for that reason, and the fact is worth
 * knowing: a guard measured only against the sample book would have passed this
 * bug through, exactly as the wire fixture passed `priority` through.
 */
final class LiveConnectionTests: XCTestCase {

    private func decode(_ raw: String) throws -> MachineInfo {
        try JSONDecoder().decode(MachineInfo.self, from: Data(raw.utf8))
    }

    func testAPrinterWithAnApiIsLiveWhicheverWayItArrives() throws {
        // As the wire sends it: the boolean, already computed.
        let fromWire = try decode(#"{"id":"m1","name":"Bambu X1C","hasPrinterApi":true}"#)
        XCTAssertEqual(fromWire.hasPrinterApi, true)

        // As the book holds it: the object the boolean is derived from. This is
        // the one that used to come back nil and print "No live connection".
        let fromBook = try decode(#"{"id":"m1","name":"Bambu X1C","printerApi":{"type":"bambu","host":"192.168.1.9"}}"#)
        XCTAssertEqual(fromBook.hasPrinterApi, true,
                       "a connected printer reads as having no live connection when read from the book")
    }

    func testAMachineWithNoPrinterIsNotLive() throws {
        let none = try decode(#"{"id":"m2","name":"Ruida 1390"}"#)
        XCTAssertNotEqual(none.hasPrinterApi, true)

        // "none" is a configured absence, not a connection — the desktop's own
        // rule excludes it explicitly.
        let configuredOff = try decode(#"{"id":"m3","name":"Old Prusa","printerApi":{"type":"none"}}"#)
        XCTAssertEqual(configuredOff.hasPrinterApi, false)

        let blank = try decode(#"{"id":"m4","name":"Half-set-up","printerApi":{"type":""}}"#)
        XCTAssertEqual(blank.hasPrinterApi, false)
    }

    func testTheWireStillWins() throws {
        // If the server sent the boolean, that is the answer — it computed it
        // against the store it owns, and the phone does not second-guess it.
        let disagreeing = try decode(#"{"id":"m5","hasPrinterApi":false,"printerApi":{"type":"bambu"}}"#)
        XCTAssertEqual(disagreeing.hasPrinterApi, false)
    }

    func testTheShopsRealMachinesStillDecode() throws {
        // The sample book's machines have no printerApi at all. They must decode
        // and come back not-live, rather than throwing on the missing key.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "mac/KhaytCore/Sources/KhaytApp/Resources/sample-shop.json")
        let store = try JSONDecoder().decode([String: JSONValue].self, from: try Data(contentsOf: url))
        guard case .array(let rows)? = store["machines"] else { return XCTFail("no machines") }
        let data = try JSONEncoder().encode(JSONValue.array(rows))
        let machines = try JSONDecoder().decode([MachineInfo].self, from: data)

        XCTAssertEqual(machines.count, 5)
        XCTAssertNotNil(machines.first(where: { $0.name == "Bambu X1C" }))
        for machine in machines {
            XCTAssertNotEqual(machine.hasPrinterApi, true,
                              "\(machine.id) claims a live connection it has not been given")
        }
    }
}
