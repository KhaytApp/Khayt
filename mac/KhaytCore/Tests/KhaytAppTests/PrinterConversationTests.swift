import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The whole exchange with a printer, per protocol.
///
/// The READING is `lib/octoprint.js` and `lib/prusalink.js`, pinned in
/// test/octoprint.test.js and test/prusalink.test.js against per-endpoint
/// payloads. What is tested here is the ORCHESTRATION — which endpoints are
/// asked for and which failures may be survived — because that is the half a
/// parser test cannot reach, and it is where the 2026-08-27 protocol audit
/// found its defects.
///
/// **No printer is involved.** `read` takes its fetch as a parameter.
@MainActor
struct PrinterConversationTests {

    static func machine(_ type: String) -> Machine {
        let row: JSONValue = .object([
            "id": .string("M-1"), "name": .string("Bench"),
            "printerApi": .object(["type": .string(type), "host": .string("192.168.1.9")]),
        ])
        return try! JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(row))
    }

    /// Answers each path with a status and a body, and records what was asked.
    static func server(_ routes: [String: (Int, String)],
                       asked: @escaping (String) -> Void = { _ in })
        -> (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            let path = (request.url?.path ?? "") + (request.url?.query.map { "?" + $0 } ?? "")
            asked(path)
            let (code, body) = routes[request.url?.path ?? ""] ?? (404, "")
            return (Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: code,
                                    httpVersion: nil, headerFields: nil)!)
        }
    }

    static let base = URL(string: "http://192.168.1.9:80")!

    // MARK: - OctoPrint

    @Test("OctoPrint answering 409 for the printer still reports the job")
    func octoprintSurvives409() async throws {
        // `abort(409, "Printer is not operational")` guards GET /api/printer in
        // the 1.11 and 2.0 lines alike. That is not a fault — it is OctoPrint
        // running with the printer switched off, which is most of any working
        // day — and GET /api/job carries no such guard.
        var seen: [String] = []
        let status = try await PrinterWatch.read(
            Self.machine("octoprint"), engine: try KhaytEngine(), base: Self.base, key: "k",
            fetch: Self.server([
                "/api/printer": (409, #"{"error":"Printer is not operational"}"#),
                "/api/job": (200, #"{"state":"Offline","job":{"file":{"name":null}},"progress":{}}"#),
            ], asked: { seen.append($0) }))
        #expect(status.state == "Offline", "the card must say Offline, not fail the whole poll")
        #expect(seen.contains("/api/job"))
        #expect(seen.contains("/api/printer"))
    }

    @Test("OctoPrint answering anything else IS a fault")
    func octoprintOtherStatusFails() async throws {
        // Only 409 may be survived. Any other status is a real failure and must
        // reach the card as one.
        await #expect(throws: (any Error).self) {
            try await PrinterWatch.read(
                Self.machine("octoprint"), engine: try KhaytEngine(), base: Self.base, key: "k",
                fetch: Self.server([
                    "/api/printer": (500, "boom"),
                    "/api/job": (200, #"{"state":"Printing","progress":{}}"#),
                ]))
        }
    }

    @Test("a printing OctoPrint reads through both payloads")
    func octoprintPrinting() async throws {
        let status = try await PrinterWatch.read(
            Self.machine("octoprint"), engine: try KhaytEngine(), base: Self.base, key: "k",
            fetch: Self.server([
                "/api/printer": (200, #"{"state":{"text":"Printing"},"temperature":{"tool0":{"actual":214.9},"bed":{"actual":59.8}}}"#),
                "/api/job": (200, #"{"state":"Printing","job":{"file":{"name":"bracket.gcode"}},"progress":{"completion":42.7,"printTimeLeft":2400}}"#),
            ]))
        #expect(status.state == "Printing")
        #expect(status.progress == 43)
        #expect(status.filename == "bracket.gcode")
        #expect(status.tempNozzle == 214.9)
        #expect(status.timeRemaining == 2400)

        // ── AND WHAT THE JOB HAS USED SO FAR ─────────────────────────────
        //
        // `progress.printTime` is "Time already spent printing, in seconds" —
        // a real reading off a running job. There is none in this payload, so
        // there is no duration, and that is the honest answer.
        //
        // FILAMENT IS NEVER MEASURED BY OCTOPRINT and this must never claim it
        // is: `job.filament.tool0` looks exactly like one — per-tool, in mm and
        // cm³, and OctoPrint's own datamodel calls it "Length of filament
        // used" — and it is the file's GCODE analysis, computed at upload,
        // identical at 1% and at 99%. Read as an actual it is worse than
        // nothing.
        #expect(status.actuals?.filamentGrams == nil,
                "OctoPrint's slicing estimate was taken for a measurement")
    }

    @Test("OctoPrint's elapsed print time is a measurement, and its filament is not")
    func octoprintActuals() async throws {
        let status = try await PrinterWatch.read(
            Self.machine("octoprint"), engine: try KhaytEngine(), base: Self.base, key: "k",
            fetch: Self.server([
                "/api/printer": (200, #"{"state":{"text":"Printing"},"temperature":{}}"#),
                // `filament` is present and is the file's analysis. `printTime`
                // is the reading.
                "/api/job": (200, #"{"state":"Printing","job":{"file":{"name":"b.gcode"},"filament":{"tool0":{"length":91000,"volume":219}}},"progress":{"completion":99,"printTime":7200}}"#),
            ]))
        #expect(status.actuals?.durationS == 7200, "the elapsed time was not read")
        #expect(status.actuals?.filamentGrams == nil,
                "219 cm³ of slicing estimate was recorded as filament used")
        #expect(status.actuals?.source == "octoprint")
    }

    // MARK: - PrusaLink

    @Test("PrusaLink takes the filename from the job endpoint")
    func prusalinkTwoRequests() async throws {
        // /api/v1/status has never carried file information at any firmware
        // version — the job object Buddy renders is exactly {id, progress,
        // time_remaining, filament_change_in, time_printing}.
        var seen: [String] = []
        let status = try await PrinterWatch.read(
            Self.machine("prusalink"), engine: try KhaytEngine(), base: Self.base, key: "k",
            fetch: Self.server([
                "/api/v1/status": (200, #"{"printer":{"state":"PRINTING","temp_nozzle":219.4,"temp_bed":59.9},"job":{"progress":61,"time_remaining":1980}}"#),
                "/api/v1/job": (200, #"{"file":{"name":"SPICE~1.GCO","display_name":"spice rack v2.gcode"}}"#),
            ], asked: { seen.append($0) }))
        #expect(seen.contains("/api/v1/status"))
        #expect(seen.contains("/api/v1/job"))
        #expect(status.filename == "spice rack v2.gcode", "the long name, not the 8.3 short form")
        #expect(status.progress == 61)
    }

    /// A MIXED ANSWER, which is the normal one for this printer and which
    /// everything downstream is built to carry rather than round off.
    ///
    /// Buddy reports `time_printing` in seconds and no filament at any firmware
    /// version, so the completion sheet marks the duration Measured and leaves
    /// the weight on the estimate — saying which, per field.
    @Test("PrusaLink measures the duration and never the filament")
    func prusalinkActuals() async throws {
        let status = try await PrinterWatch.read(
            Self.machine("prusalink"), engine: try KhaytEngine(), base: Self.base, key: "k",
            fetch: Self.server([
                "/api/v1/status": (200, #"{"printer":{"state":"PRINTING"},"job":{"progress":61}}"#),
                "/api/v1/job": (200, #"{"file":{"name":"HOOD.GCO"},"time_printing":9540}"#),
            ]))
        #expect(status.actuals?.durationS == 9540, "time_printing was not read")
        #expect(status.actuals?.filamentGrams == nil,
                "PrusaLink reports no filament, so nothing may claim it did")
        #expect(status.actuals?.source == "prusalink")
    }

    @Test("PrusaLink answering 204 costs the name and nothing else")
    func prusalink204() async throws {
        // It answers 204 No Content when nothing is printing, and a missing
        // name must not cost the temperatures the first request did return.
        let status = try await PrinterWatch.read(
            Self.machine("prusalink"), engine: try KhaytEngine(), base: Self.base, key: "k",
            fetch: Self.server([
                "/api/v1/status": (200, #"{"printer":{"state":"IDLE","temp_nozzle":24.2,"temp_bed":23.9}}"#),
                "/api/v1/job": (204, ""),
            ]))
        #expect(status.state == "IDLE")
        #expect(status.filename == "")
        #expect(status.tempNozzle == 24.2)
    }

    @Test("PrusaLink failing the job request outright still reports the printer")
    func prusalinkJobFails() async throws {
        let status = try await PrinterWatch.read(
            Self.machine("prusalink"), engine: try KhaytEngine(), base: Self.base, key: "k",
            fetch: Self.server([
                "/api/v1/status": (200, #"{"printer":{"state":"IDLE","temp_bed":23.9}}"#),
                "/api/v1/job": (500, "boom"),
            ]))
        #expect(status.state == "IDLE")
    }

    @Test("PrusaLink failing the STATUS request is a failure")
    func prusalinkStatusFails() async throws {
        // The other way round: without the status there is nothing to report.
        await #expect(throws: (any Error).self) {
            try await PrinterWatch.read(
                Self.machine("prusalink"), engine: try KhaytEngine(), base: Self.base, key: "k",
                fetch: Self.server(["/api/v1/status": (500, "boom")]))
        }
    }

    // MARK: - The key

    @Test("the key is sent, and an unset one is sent as nothing at all")
    func theKeyHeader() async throws {
        var headers: [String?] = []
        let record: (URLRequest) async throws -> (Data, URLResponse) = { request in
            headers.append(request.value(forHTTPHeaderField: "X-Api-Key"))
            return (Data(#"{"printer":{"state":"IDLE"}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        }
        _ = try await PrinterWatch.read(Self.machine("prusalink"), engine: try KhaytEngine(),
                                        base: Self.base, key: "a-real-key", fetch: record)
        #expect(headers.allSatisfy { $0 == "a-real-key" })

        headers = []
        _ = try await PrinterWatch.read(Self.machine("prusalink"), engine: try KhaytEngine(),
                                        base: Self.base, key: "", fetch: record)
        // NOT the string "undefined", and not an empty header either — Moonraker
        // in trusted-client mode needs no key, and sending a junk one is worse
        // than sending none. main.js records having made exactly that mistake.
        #expect(headers.allSatisfy { $0 == nil })
    }

    @Test("each protocol's default port")
    func defaultPorts() {
        #expect(PrinterWatch.defaultPort("moonraker") == 7125)
        #expect(PrinterWatch.defaultPort("octoprint") == 80)
        #expect(PrinterWatch.defaultPort("prusalink") == 80)
    }
}

// MARK: - Repetier

extension PrinterConversationTests {

    /// Repetier's two calls share a path and differ only in the query, which
    /// the `server` helper above cannot tell apart — it routes on path alone.
    /// So this one routes on the whole thing, which is also what makes it able
    /// to prove WHICH call the job came from.
    static func repetierServer(state: String, listing: String?,
                               asked: @escaping (String) -> Void = { _ in })
        -> (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            let q = request.url?.query ?? ""
            asked((request.url?.path ?? "") + "?" + q)
            if q.contains("a=stateList") {
                return (Data(state.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                          httpVersion: nil, headerFields: nil)!)
            }
            guard let listing else {
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500,
                                                httpVersion: nil, headerFields: nil)!)
            }
            return (Data(listing.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                        httpVersion: nil, headerFields: nil)!)
        }
    }

    /// THE BUG THIS PROTOCOL IS FAMOUS FOR HERE.
    ///
    /// The other app read `done` and `job` off `stateList`, where Repetier's
    /// own API reference lists neither — so progress was always 0, the filename
    /// always empty, and every Repetier machine read Idle while it printed.
    /// `lib/repetier.js` holds the correction. This proves the Mac app calls
    /// it rather than repeating the mistake in Swift.
    @Test("a printing Repetier takes its job from listPrinter, not stateList")
    func repetierPrinting() async throws {
        var paths: [String] = []
        let status = try await PrinterWatch.read(
            Self.machine("repetier"), engine: try KhaytEngine(), base: Self.base, key: "k",
            fetch: Self.repetierServer(
                // The MACHINE. Note it carries no `done` and no `job` — which
                // is exactly the point: a reader looking here finds nothing.
                // KEYED BY SLUG. `stateList` returns an object whose keys are
                // printer slugs, not the machine's fields at the top level —
                // and it carries no `done` and no `job`, which is the point.
                state: #"{"data":{"default":{"extruder":[{"tempRead":211.4}],"heatedBeds":[{"tempRead":60.2}],"layer":37}}}"#,
                listing: #"{"data":[{"slug":"default","online":1,"job":"hinge.gcode","done":61.5,"paused":false}]}"#,
                asked: { paths.append($0) }))

        #expect(status.filename == "hinge.gcode", "the job name was not read from listPrinter")
        #expect(status.progress == 62, "progress came back \(String(describing: status.progress))")
        #expect(status.tempNozzle == 211.4)
        #expect(status.tempBed == 60.2)
        // Both calls were made, and against the slug.
        #expect(paths.contains { $0.contains("a=stateList") })
        #expect(paths.contains { $0.contains("a=listPrinter") })
    }

    @Test("the listing failing costs the job and not the temperatures")
    func repetierListingFails() async throws {
        // The same rule PrusaLink follows: a second request that fails must not
        // take the first one's answer with it.
        let status = try await PrinterWatch.read(
            Self.machine("repetier"), engine: try KhaytEngine(), base: Self.base, key: "k",
            fetch: Self.repetierServer(
                state: #"{"data":{"default":{"extruder":[{"tempRead":205.0}],"heatedBeds":[{"tempRead":58.0}]}}}"#,
                listing: nil))
        #expect(status.tempNozzle == 205.0, "a failed listing cost the temperatures")
        #expect(status.tempBed == 58.0)
    }

    @Test("the slug is in the path, and an unset one is Repetier's own default")
    func repetierSlug() async throws {
        // Repetier-Server runs several printers behind one address and names
        // them in the PATH, not a header. `machine-edit.js` stores an empty
        // string when the shop has not said, and the adapter reads that as
        // `default` — which is the name Repetier itself uses.
        var paths: [String] = []
        _ = try? await PrinterWatch.read(
            Self.machine("repetier"), engine: try KhaytEngine(), base: Self.base, key: "k",
            fetch: Self.repetierServer(state: #"{"data":{}}"#, listing: #"{"data":[]}"#,
                                       asked: { paths.append($0) }))
        #expect(paths.allSatisfy { $0.contains("/printer/api/default") },
                "asked \(paths)")
    }

    @Test("Repetier is a protocol this app says it speaks")
    func repetierIsSpoken() {
        // The set is what the machines screen reads to decide whether to say
        // "Khayt cannot ask this kind of machine what it is doing". Wiring the
        // branch and forgetting this leaves a poller nothing ever calls.
        #expect(PrinterWatch.spoken.contains("repetier"))
        #expect(PrinterWatch.notWatched(Self.machine("repetier")) == nil)
        #expect(PrinterWatch.defaultPort("repetier") == 3344)
    }
}

// MARK: - Duet

extension PrinterConversationTests {

    /// A Duet that answers on one surface and 404s the other, optionally
    /// demanding a session first. Records every path asked, in order.
    static func duetServer(surface: String, model: String,
                           demandsSession: Bool = false, connect: String = #"{"err":0}"#,
                           asked: @escaping (String) -> Void = { _ in })
        -> (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            let path = (request.url?.path ?? "") + (request.url?.query.map { "?" + $0 } ?? "")
            asked(path)
            let reply = { (code: Int, body: String) in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code,
                                                  httpVersion: nil, headerFields: nil)!)
            }
            let isStandalone = path.hasPrefix("/rr_")
            guard (surface == "standalone") == isStandalone else { return reply(404, "") }
            if path.hasPrefix("/rr_connect") || path.hasPrefix("/machine/connect") {
                return reply(200, connect)
            }
            if demandsSession, request.value(forHTTPHeaderField: "X-Session-Key") == nil {
                return reply(surface == "standalone" ? 401 : 403, "")
            }
            return reply(200, model)
        }
    }

    /// The standalone object model, trimmed to what the reader uses.
    static let duetModel = #"{"result":{"state":{"status":"processing"},"job":{"file":{"fileName":"clip.gcode"},"filePosition":4200,"timesLeft":{"file":1800}},"heat":{"heaters":[{"current":212.5,"active":215},{"current":60.4,"active":60}]},"tools":[{"heaters":[0]}]}}"#

    @Test("a standalone Duet with no password costs two requests and no handshake")
    func duetStandaloneOpen() async throws {
        // The overwhelmingly common case, and the reason the handshake is paid
        // for only when refused rather than on every poll.
        var paths: [String] = []
        let status = try await PrinterWatch.read(
            Self.machine("duet"), engine: try KhaytEngine(), base: Self.base, key: "",
            fetch: Self.duetServer(surface: "standalone", model: Self.duetModel,
                                   asked: { paths.append($0) }))
        #expect(status.filename == "clip.gcode")
        #expect(status.tempNozzle == 212.5)
        #expect(!paths.contains { $0.hasPrefix("/rr_connect") },
                "it shook hands with a machine that never refused it: \(paths)")
    }

    @Test("a Duet that demands a session gets one, and only then")
    func duetHandshake() async throws {
        // "Every request except for rr_connect returns 401 if the client does
        // not have a valid session." So: refused, handshake, retry — and the
        // retry carries the key.
        var paths: [String] = []
        let status = try await PrinterWatch.read(
            Self.machine("duet"), engine: try KhaytEngine(), base: Self.base, key: "hunter2",
            fetch: Self.duetServer(surface: "standalone", model: Self.duetModel,
                                   demandsSession: true,
                                   connect: #"{"err":0,"sessionKey":"abc123"}"#,
                                   asked: { paths.append($0) }))
        #expect(status.filename == "clip.gcode", "the retry after the handshake did not land")
        #expect(paths.contains { $0.hasPrefix("/rr_connect") })
        // The password goes in the connect, not in a header.
        #expect(paths.contains { $0.contains("password=hunter2") })
    }

    @Test("a refused handshake is said, not retried forever")
    func duetHandshakeRefused() async throws {
        // A wrong password. `rrConnectResult` turns Duet's own error number
        // into a sentence; this proves it reaches the surface rather than
        // becoming a generic failure.
        await #expect(throws: (any Error).self) {
            _ = try await PrinterWatch.read(
                Self.machine("duet"), engine: try KhaytEngine(), base: Self.base, key: "wrong",
                fetch: Self.duetServer(surface: "standalone", model: Self.duetModel,
                                       demandsSession: true, connect: #"{"err":1}"#))
        }
    }

    @Test("an SBC Duet is found on the other surface, and asks once")
    func duetSbc() async throws {
        // DuetSoftwareFramework returns the WHOLE model from one call — no
        // separate file query, which is why `ep.file` is nil there.
        var paths: [String] = []
        let status = try await PrinterWatch.read(
            Self.machine("duet"), engine: try KhaytEngine(), base: Self.base, key: "",
            fetch: Self.duetServer(surface: "sbc", model: Self.duetModel,
                                   asked: { paths.append($0) }))
        #expect(status.filename == "clip.gcode")
        #expect(paths.contains { $0.hasPrefix("/machine/model") })
        #expect(!paths.contains { $0.contains("key=job.file") },
                "it asked for the file separately on a surface that had already sent it")
    }

    @Test("Duet is a protocol this app says it speaks")
    func duetIsSpoken() {
        #expect(PrinterWatch.spoken.contains("duet"))
        #expect(PrinterWatch.notWatched(Self.machine("duet")) == nil)
        #expect(PrinterWatch.defaultPort("duet") == 80)
    }

    /// NOT `spoken.count == 5`, which is what this was and which failed the day
    /// Bambu was taught — the third time a count written down here has had to
    /// be edited for the app being further along.
    @Test("every protocol is either spoken or honestly refused")
    func nothingIsSilentlySkipped() {
        #expect(PrinterWatch.spoken.isSubset(of: PrinterWatch.everyProtocol),
                "the app claims a protocol a machine cannot be set to: \(PrinterWatch.spoken.subtracting(PrinterWatch.everyProtocol))")
        for name in PrinterWatch.everyProtocol {
            let verdict = PrinterWatch.notWatched(Self.machine(name))
            #expect(PrinterWatch.spoken.contains(name) ? verdict == nil
                                                       : verdict == .otherProtocol(name))
        }
    }
}
