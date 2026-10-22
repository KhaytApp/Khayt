import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A spool running out on a Klipper machine reaches the Mac's alerts — and the
/// richer card and honest buttons that came with it.
///
/// UNTIL OCT 2026 IT COULD NOT. `moonrakerStatus` passed `null` for the sensor
/// names ("this app does not discover them yet"), `PrinterStatus` had no
/// `filamentOut`, and `statusCache` never wrote one — so `printer-alerts.js`,
/// which raises a runout only on `filamentOut === true`, never saw one, and the
/// Mac's `runout` switch (on by default) did nothing.
///
/// The fixtures are the Snapmaker U1's own replies, read with GETs from the
/// bench printer on 2026-10-22 and kept in `test/fixtures/` where the JS tests
/// read them too: `u1-objects-list.json` (four `filament_motion_sensor
/// eN_filament`) and `u1-status-query.json`. A runout cannot be produced by
/// reading a printer, so the runout cases flip ONE field of a copy of the real
/// reply and say so.
@MainActor
struct PrinterRunoutTests {

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "test/fixtures")

    static func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixtures.appending(path: name), encoding: .utf8)
    }

    /// The U1's query reply with one head's sensor saying it has no filament.
    static func queryWith(emptyHead sensor: String?) throws -> String {
        let raw = try fixture("u1-status-query.json")
        guard let sensor else { return raw }
        guard var root = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              var result = root["result"] as? [String: Any],
              var status = result["status"] as? [String: Any],
              var head = status[sensor] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        head["filament_detected"] = false
        status[sensor] = head
        result["status"] = status
        root["result"] = result
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    /// A Moonraker machine with an id of its own, because discovery is held
    /// per machine in a static and these tests run side by side.
    static func machine(_ id: String) -> Machine {
        let row: JSONValue = .object([
            "id": .string(id), "name": .string("U1"),
            "printerApi": .object(["type": .string("moonraker"), "host": .string("192.168.68.56")]),
        ])
        return try! JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(row))
    }

    static let base = URL(string: "http://192.168.68.56:7125")!

    /// Answers by path (the query string is ignored), and records each request.
    static func u1(query: String, list: String?, asked: @escaping (String) -> Void)
        -> (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            let path = request.url?.path ?? ""
            asked(path + (request.url?.query(percentEncoded: true).map { "?" + $0 } ?? ""))
            let body: String?
            switch path {
            case "/printer/objects/list": body = list
            case "/printer/objects/query": body = query
            default: body = nil
            }
            return (Data((body ?? "").utf8),
                    HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200,
                                    httpVersion: nil, headerFields: nil)!)
        }
    }

    // MARK: - Runout, end to end

    @Test("the U1's sensors are discovered once, asked for, and a runout on the live head reaches the alert")
    func runoutReachesTheAlert() async throws {
        let engine = try KhaytEngine()
        let machine = Self.machine("runout-\(UUID().uuidString)")
        var asked: [String] = []
        // Head 1 is the live head on this reply (`toolhead.extruder`).
        let fetch = Self.u1(query: try Self.queryWith(emptyHead: "filament_motion_sensor e1_filament"),
                            list: try Self.fixture("u1-objects-list.json")) { asked.append($0) }

        let status = try await PrinterWatch.read(machine, engine: engine, base: Self.base, key: "", fetch: fetch)
        #expect(status.filamentOut == true)

        // The query carried the four sensors the list named — the shared
        // reader cannot judge a sensor it was never sent.
        let query = try #require(asked.first { $0.hasPrefix("/printer/objects/query?print_stats") })
        for n in 0..<4 { #expect(query.contains("filament_motion_sensor%20e\(n)_filament")) }
        #expect(query.contains("temperature_sensor%20cavity"))

        // A second poll does not ask for the list again.
        _ = try await PrinterWatch.read(machine, engine: engine, base: Self.base, key: "", fetch: fetch)
        #expect(asked.filter { $0 == "/printer/objects/list" }.count == 1)

        // The cache carries it, and the shared rule raises it.
        let watch = PrinterWatch()
        watch.setReadingForTesting(machine.id, .init(status: status, problem: nil, at: Date()))
        guard case .object(let row)? = watch.statusCache[machine.id] else { Issue.record("no row"); return }
        #expect(row["filamentOut"] == .bool(true))
        #expect(PrinterWatch.cacheEntry(status, at: Date())["filamentOut"] == .bool(true))

        let out = try await engine.printerAlerts(
            was: [:], now: watch.statusCache, settings: [:],
            machines: [.object(["id": .string(machine.id), "name": .string("U1")])],
            state: .object([:]), enable: .sensible)
        #expect(out.alerts.map(\.type) == ["runout"])
    }

    @Test("all four heads loaded, as the U1 really reported, is not a runout")
    func loadedIsQuiet() async throws {
        let engine = try KhaytEngine()
        let fetch = Self.u1(query: try Self.queryWith(emptyHead: nil),
                            list: try Self.fixture("u1-objects-list.json")) { _ in }
        let status = try await PrinterWatch.read(Self.machine("loaded-\(UUID().uuidString)"), engine: engine,
                                                 base: Self.base, key: "", fetch: fetch)
        #expect(status.filamentOut == false)
    }

    @Test("an empty SPARE head is an empty slot, not a runout")
    func spareHeadIsQuiet() async throws {
        let engine = try KhaytEngine()
        let fetch = Self.u1(query: try Self.queryWith(emptyHead: "filament_motion_sensor e3_filament"),
                            list: try Self.fixture("u1-objects-list.json")) { _ in }
        let status = try await PrinterWatch.read(Self.machine("spare-\(UUID().uuidString)"), engine: engine,
                                                 base: Self.base, key: "", fetch: fetch)
        #expect(status.filamentOut == false)
    }

    @Test("a failed discovery is 'cannot say', the poll still answers, and it is asked again later — not every poll")
    func failedDiscoveryRetriesLater() async throws {
        let engine = try KhaytEngine()
        let machine = Self.machine("nolist-\(UUID().uuidString)")
        let fetch = Self.u1(query: try Self.queryWith(emptyHead: "filament_motion_sensor e1_filament"),
                            list: nil) { _ in }
        let status = try await PrinterWatch.read(machine, engine: engine, base: Self.base, key: "", fetch: fetch)
        #expect(status.filamentOut == nil, "no sensors known is not 'filament fine'")

        // The clock is the test's, not the wall's: on a loaded runner two real
        // polls can be minutes apart, which is how this once read as a retry.
        let failedAt = try #require(PrinterWatch.discovered[PrinterWatch.discoveryKey(machine, base: Self.base)]).at
        var asked = 0
        let list = try JSONValue.decode([String: JSONValue].self,
                                        from: Data(try Self.fixture("u1-objects-list.json").utf8))
        let soon = await PrinterWatch.watching(machine, base: Self.base, engine: engine,
                                               get: { _ in asked += 1; return list },
                                               now: failedAt.addingTimeInterval(10))
        #expect(asked == 0, "a failing list is not re-asked every ten seconds")
        #expect(soon.sensors.isEmpty)

        // Past the retry window it is asked again, and this time it answers.
        let later = await PrinterWatch.watching(machine, base: Self.base, engine: engine,
                                                get: { _ in asked += 1; return list },
                                                now: failedAt.addingTimeInterval(PrinterWatch.rediscoverAfter + 1))
        #expect(asked == 1)
        #expect(later.sensors.count == 4)
    }

    // MARK: - The richer card

    @Test("the U1's own reply reads every richer field through the shared reader")
    func richerFieldsFromTheU1() async throws {
        let engine = try KhaytEngine()
        let list = try JSONValue.decode([String: JSONValue].self, from: Data(try Self.fixture("u1-objects-list.json").utf8))
        let watching = try await engine.moonrakerDiscover(list)
        #expect(watching.chamber == "temperature_sensor cavity")
        #expect(watching.headFans == ["fan_generic e1_fan", "fan_generic e2_fan", "fan_generic e3_fan"])
        let reply = try JSONValue.decode([String: JSONValue].self, from: Data(try Self.fixture("u1-status-query.json").utf8))
        let hot = try JSONValue.decode([String: JSONValue].self, from: Data(try Self.fixture("u1-status-hot.json").utf8))
        let s = try await engine.moonrakerStatus(reply, hot: hot, hotName: "extruder1", watching: watching)
        #expect(s.layers?.current == 750 && s.layers?.total == 750)
        #expect(s.tempNozzle == 35 && s.targetNozzle == 0)
        #expect(s.tempBed == 32 && s.targetBed == 0)
        #expect(s.tempChamber == 34 && s.targetChamber == nil)
        #expect(s.speedFactor == 100 && s.flowFactor == 100)
        #expect(s.message == nil, "\"Printer is ready\" is not news")
    }

    @Test("a heater reads 'now/target' only while it holds one")
    func heatShowsTheTarget() {
        #expect(PrinterWatch.heat(212.4, target: 220) == "212/220°")
        #expect(PrinterWatch.heat(34, target: 0) == "34°", "target 0 is a heater that is off")
        #expect(PrinterWatch.heat(34, target: nil) == "34°")
        #expect(PrinterWatch.heat(34, target: .nan) == "34°")
    }

    @Test("fan, speed and flow: only while printing, and speed/flow only when changed")
    func tuningRow() {
        var s = KhaytEngine.PrinterStatus(state: "printing", progress: 40, progressSource: nil, filename: "",
                                          timeRemaining: nil, tempNozzle: nil, tempBed: nil, type: "moonraker")
        s.fanPart = 60; s.speedFactor = 100; s.flowFactor = 95
        #expect(PrinterWatch.tuning(s, running: true).map(\.key) == ["mac.part_fan", "mac.flow_factor"])
        #expect(PrinterWatch.tuning(s, running: false).isEmpty)
        s.speedFactor = .infinity; s.fanPart = 250
        #expect(PrinterWatch.tuning(s, running: true).first?.percent == 100, "a fan cannot be past full")
        #expect(!PrinterWatch.tuning(s, running: true).contains { $0.key == "mac.speed_factor" })
    }

    @Test("every new card word has English and Arabic")
    func cardWords() async {
        for key in ["mac.chamber_temp", "mac.part_fan", "mac.speed_factor", "mac.flow_factor",
                    "mac.layer_of", "mac.filament_out", "mac.printer_says", "mac.printer_no_control"] {
            #expect(Words.own[key]?["en"]?.isEmpty == false, "\(key) en")
            #expect(Words.own[key]?["ar"]?.isEmpty == false, "\(key) ar")
        }
        // Arabic keeps Western digits in the layer count.
        let ar = Words()
        await ar.load("ar", engine: nil)
        let line = ar.callIt("mac.layer_of", ["layer": .string(ar.numeral(412)), "total": .string(ar.numeral(750))])
        #expect(line.contains("412") && line.contains("750"), "\(line)")
        #expect(line.hasPrefix("الطبقة"))
    }

    // MARK: - Honest buttons

    @Test("the card offers only the verbs the shared table can build, per protocol")
    func buttonsMatchTheTable() async throws {
        let engine = try KhaytEngine()
        let all = Set(PrinterControl.Verb.allCases)
        for type in PrinterWatch.everyProtocol {
            let verbs = await PrinterControl.verbs(for: type, engine: engine)
            switch type {
            case "bambu", "sdcp": #expect(verbs.isEmpty, "\(type) drew Pause and Cancel that failed on press")
            case "repetier": #expect(verbs == [.resume, .cancel])
            default: #expect(verbs == all, "\(type)")
            }
            // And the predicate agrees with what a press would build.
            for verb in PrinterControl.Verb.allCases {
                let built = try await engine.printerCommand(type: type, command: verb.rawValue,
                                                            jobId: type == "prusalink" ? "7" : nil)
                #expect(PrinterControl.offers(verb, verbs) == (built.unsupported == nil), "\(type) \(verb)")
            }
        }
        #expect(!PrinterControl.offers(.pause, nil), "not asked yet draws nothing")
    }
}
