import XCTest
@testable import KhaytCompanion

/// Print alerts: what counts as a print ending, and which button it gets.
final class PrintAlertsTests: XCTestCase {

    private func r(_ state: String?, error: String? = nil, file: String? = "bracket.3mf") -> MachineLiveStatus {
        MachineLiveStatus(id: "M1", name: "X1C", hasPrinterApi: true, state: state, progress: nil, filename: file,
                          timeRemaining: nil, tempNozzle: nil, tempBed: nil, error: error, lastUpdated: nil,
                          apiType: nil)
    }

    func testAPrintSeenRunningAndThenNotIsAnEnding() {
        var d = FinishDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(d.observe(["M1": r("Printing")], now: t0).isEmpty)
        let ended = d.observe(["M1": r("Operational")], now: t0.addingTimeInterval(3_600))
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.outcome, .finished)
        XCTAssertEqual(ended.first?.durationS, 3_600)
        XCTAssertEqual(ended.first?.filename, "bracket.3mf")
        XCTAssertTrue(d.observe(["M1": r("Operational")]).isEmpty, "said once, not on every reading after")
    }

    func testAMachineFirstSeenIdleIsNotAFinishedPrint() {
        var d = FinishDetector()
        XCTAssertTrue(d.observe(["M1": r("Operational")]).isEmpty, "the phone was not looking while it ran")
    }

    func testAFaultOrACancelIsSaidAsOne() {
        var d = FinishDetector()
        _ = d.observe(["M1": r("Printing")])
        XCTAssertEqual(d.observe(["M1": r("Error", error: "Nozzle clog")]).first?.outcome, .failed)
        _ = d.observe(["M1": r("Printing")])
        XCTAssertEqual(d.observe(["M1": r("Cancelled")]).first?.outcome, .cancelled)
    }

    private func event(_ outcome: PrintFinished.Outcome, order: String? = "INV-1", advancedTo: String? = nil) -> PrintFinished {
        PrintFinished(at: "2026-09-26T10:00:00Z", machineId: "M1", machineName: "X1C", orderId: order,
                      project: "Bracket", client: nil, filename: nil, durationS: 11_520, outcome: outcome,
                      advancedTo: advancedTo)
    }

    /// The Mac lane's rules, one by one.
    func testEachEndingOffersTheOneMoveThatFits() {
        XCTAssertEqual(PrintAlertAction.offered(for: event(.finished), orderStatus: "printing"), .moveToPost)
        XCTAssertEqual(PrintAlertAction.offered(for: event(.failed), orderStatus: "printing"), .reprint)
        XCTAssertEqual(PrintAlertAction.offered(for: event(.cancelled), orderStatus: "printing"), .reprint)
        XCTAssertEqual(PrintAlertAction.offered(for: event(.finished), orderStatus: "completed"), .markShipped)
        XCTAssertNil(PrintAlertAction.offered(for: event(.finished, order: nil), orderStatus: "printing"),
                     "no job bound to the machine, no button on a guess")
        XCTAssertNil(PrintAlertAction.offered(for: event(.finished, advancedTo: "post"), orderStatus: "printing"),
                     "the Mac already moved it; the phone does not move it twice")
        XCTAssertNil(PrintAlertAction.offered(for: event(.finished), orderStatus: "qc"), "moved by hand since")
    }

    func testTheAlertSaysWhatAndWhereAndCarriesItsButton() {
        let c = PrintAlertCenter.content(for: event(.finished), orderStatus: "printing")
        XCTAssertTrue(c.body.contains("Bracket"))
        XCTAssertTrue(c.body.contains("X1C"))
        XCTAssertEqual(c.categoryIdentifier, PrintAlertAction.moveToPost.category)
        XCTAssertEqual(c.userInfo["orderId"] as? String, "INV-1")
    }

    /// The Mac's event decodes as the phone's own.
    func testTheMacsPayloadDecodes() throws {
        let json = #"{"v":1,"kind":"print-finished","at":"2026-09-26T10:00:00Z","machineId":"M1","machineName":"X1C","orderId":null,"project":null,"client":null,"filename":"b.3mf","durationS":3600,"outcome":"failed","photo":true,"advancedTo":null}"#
        let e = try JSONDecoder().decode(PrintFinished.self, from: Data(json.utf8))
        XCTAssertEqual(e.outcome, .failed)
        XCTAssertTrue(e.photo)
        XCTAssertNil(e.advancedTo)
    }
}
