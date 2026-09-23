import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Pausing, resuming and cancelling a Duet from the Mac.
///
/// The Mac could WATCH a Duet — the poller speaks both firmware lines and does
/// the session handshake — and three separate faults stopped it telling one
/// anything:
///
///   1. a cancel is two calls (M25 then M0), and the Mac's request type had no
///      `sequence`, so it decoded as nothing and was refused as "could not be
///      built" — on every Duet;
///   2. on an SBC the G-code is a `text/plain` BODY, and `send` only sent
///      object bodies, so pause and resume went out empty;
///   3. a Duet with a password refuses every command without a session, and
///      the session key was the poller's alone.
///
/// No Duet is on the bench, so these are held to the shared rule
/// (`lib/printer-commands.js`, `lib/duet.js`) and to the Duet docs quoted in
/// `lib/duet.js`, with every request caught before it leaves.
@MainActor
struct DuetControlTests {

    static func machine(port: Int) throws -> Machine {
        let json: JSONValue = .object(["id": .string("D1"), "name": .string("Duet"),
            "printerApi": .object(["type": .string("duet"), "host": .string("192.168.68.90"),
                                   "port": .number(Double(port))])])
        return try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(json))
    }

    final class Log: @unchecked Sendable { var requests: [URLRequest] = [] }

    /// Answers `status` to the first `refuseFirst` G-code requests, 200 after,
    /// and a good session to a connect.
    static func printer(_ log: Log, refuseFirst: Int = 0, status: Int = 401, connectOK: Bool = true)
        -> (URLRequest) async throws -> (Data, URLResponse) {
        var refused = 0
        return { request in
            log.requests.append(request)
            let path = request.url!.path
            let body: String
            var code = 200
            if path.contains("connect") {
                body = connectOK ? #"{"err":0,"sessionKey":12345,"sessionTimeout":8000}"# : #"{"err":1}"#
            } else {
                body = "{}"
                if refused < refuseFirst { refused += 1; code = status }
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: [:])!)
        }
    }

    @Test("cancel is a pause and then a stop, in that order")
    func cancelIsTwoCalls() async throws {
        let engine = try KhaytEngine()
        let machine = try Self.machine(port: 8001)
        PrinterWatch.duetFlavours["http://192.168.68.90:8001"] = "standalone"
        let log = Log()
        try await PrinterControl.send(.cancel, to: machine, engine: engine, build: nil, fetch: Self.printer(log))
        let codes = log.requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "gcode" }?.value }
        #expect(codes == ["M25", "M0"], "a Duet cancel did not send pause then stop")
    }

    @Test("on an SBC the G-code is the text body, not an empty one")
    func sbcSendsTheCode() async throws {
        let engine = try KhaytEngine()
        let machine = try Self.machine(port: 8002)
        PrinterWatch.duetFlavours["http://192.168.68.90:8002"] = "sbc"
        let log = Log()
        try await PrinterControl.send(.pause, to: machine, engine: engine, build: nil, fetch: Self.printer(log))
        let req = try #require(log.requests.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/machine/code")
        #expect(String(decoding: req.httpBody ?? Data(), as: UTF8.self) == "M25", "the G-code went out empty")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "text/plain")
    }

    @Test("a Duet with a password gets a handshake, and the command again with the session key")
    func handshake() async throws {
        let engine = try KhaytEngine()
        let machine = try Self.machine(port: 8003)
        PrinterWatch.duetFlavours["http://192.168.68.90:8003"] = "standalone"
        let log = Log()
        try await PrinterControl.send(.resume, to: machine, engine: engine, build: nil,
                                      fetch: Self.printer(log, refuseFirst: 1, status: 401))
        #expect(log.requests.count == 3, "expected: refused, connect, the command again")
        #expect(log.requests[1].url?.path == "/rr_connect")
        #expect(log.requests[2].value(forHTTPHeaderField: "X-Session-Key") == "12345",
                "the retry did not carry the session the Duet handed out")
    }

    @Test("a password the Duet refuses is said, not retried for ever")
    func refusedPassword() async throws {
        let engine = try KhaytEngine()
        let machine = try Self.machine(port: 8004)
        PrinterWatch.duetFlavours["http://192.168.68.90:8004"] = "standalone"
        let log = Log()
        await #expect(throws: (any Error).self) {
            try await PrinterControl.send(.pause, to: machine, engine: engine, build: nil,
                                          fetch: Self.printer(log, refuseFirst: 5, status: 401, connectOK: false))
        }
        #expect(log.requests.count == 2, "a refused handshake was followed by more attempts")
    }
}
