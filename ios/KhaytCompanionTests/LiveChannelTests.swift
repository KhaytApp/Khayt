import XCTest
@testable import KhaytCompanion

/// The live stream's framing, and what its events may and may not change.
@MainActor
final class LiveChannelTests: XCTestCase {

    private func events(_ text: String) -> ([SSEEvent], SSEParser) {
        var parser = SSEParser()
        var out: [SSEEvent] = []
        for line in text.components(separatedBy: "\n") {
            if let e = parser.feed(line) { out.append(e) }
        }
        return (out, parser)
    }

    func testTheCloudsFramingReadsAsItsEvents() {
        let (got, parser) = events("""
        retry: 5000

        event: hello
        data: {"rev":12,"printersAt":null}

        : ping

        event: store
        data: {"rev":13}

        event: printers\r
        data: {"at":"x",\r
        data: "receivedAt":"y"}\r
        \r

        """)
        XCTAssertEqual(got.map(\.name), ["hello", "store", "printers"], "a ping is not an event")
        XCTAssertEqual(got[1].data, #"{"rev":13}"#)
        XCTAssertEqual(got[2].data, "{\"at\":\"x\",\n\"receivedAt\":\"y\"}", "data lines join with a newline; CRLF is read")
        XCTAssertEqual(parser.retryMs, 5000)
    }

    func testAnEventNotYetReadIsStillAnEventNotAnError() {
        let (got, _) = events("event: intake\ndata: {\"id\":\"W-9\"}\n\n")
        XCTAssertEqual(got, [SSEEvent(name: "intake", data: #"{"id":"W-9"}"#)])
    }

    private func snap(_ progress: Int, source: LiveSnapshot.Source, reportedAt: Date?) -> LiveSnapshot {
        LiveSnapshot(printers: [MachineLiveStatus(id: "M1", name: "M1", hasPrinterApi: true, state: "printing",
                                                  progress: progress, filename: nil, timeRemaining: nil,
                                                  tempNozzle: nil, tempBed: nil, error: nil, lastUpdated: nil,
                                                  apiType: nil)],
                     source: source, reportedAt: reportedAt)
    }

    /// Straight from the Mac on the shop's Wi-Fi is fresher than anything the
    /// cloud relays, so a pushed snapshot does not overwrite it.
    func testARelayedSnapshotDoesNotOverwriteTheShopsOwnFreshAnswer() async {
        let live = LivePrinters { self.snap(80, source: .shop, reportedAt: nil) }
        await live.refresh()
        live.ingest(snap(40, source: .cloud, reportedAt: Date()))
        XCTAssertEqual(live.reading(for: "M1")?.progress, 80)
        XCTAssertEqual(live.source, .shop)
    }

    func testAwayFromTheShopAPushedSnapshotIsTaken() {
        let live = LivePrinters { throw URLError(.cannotConnectToHost) }
        live.ingest(snap(40, source: .cloud, reportedAt: Date()))
        XCTAssertTrue(live.isLive)
        XCTAssertEqual(live.reading(for: "M1")?.progress, 40)
        XCTAssertEqual(live.source, .cloud)
    }
}
