import Foundation
import Testing
@testable import KhaytCore

/// Reading an Elegoo resin printer, through the engine.
///
/// `test/sdcp.test.js` pins the framing and the status mapping; those modules
/// are loaded here unchanged, so what this checks is that the Mac app asks them
/// the same questions — the address, the request, and which frame counts as the
/// answer.
@Suite struct SdcpStatusTests {

    static let board = "ABC123"

    static func frame(topic: String, body: String) -> String {
        #"{"Topic":"sdcp/\#(topic)/\#(Self.board)","MainboardID":"\#(Self.board)",\#(body)}"#
    }

    static let printing = frame(topic: "status", body: #""Status":{"CurrentStatus":1,"PrintInfo":{"Status":3,"CurrentLayer":12,"TotalLayer":100,"Filename":"ring.ctb"}}"#)

    @Test("the address is the shared module's, not one written in Swift")
    func theAddressIsShared() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.sdcpWebsocketUrl("192.168.1.9") == "ws://192.168.1.9:3030/websocket")
    }

    @Test("the question is a STATUS_REFRESH addressed to one mainboard")
    func theRequestIsAddressed() async throws {
        let engine = try KhaytEngine()
        let request = try await engine.sdcpStatusRequest(mainboardId: Self.board)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        #expect(json["Topic"] as? String == "sdcp/request/\(Self.board)")
        let data = try #require(json["Data"] as? [String: Any])
        #expect(data["Cmd"] as? Int == 0, "STATUS_REFRESH is command 0")
        #expect(data["MainboardID"] as? String == Self.board)
    }

    @Test("a status frame reads as a status")
    func aStatusReads() async throws {
        let engine = try KhaytEngine()
        let frame = try await engine.sdcpRead(frame: Self.printing, mainboardId: Self.board)
        guard case .status(let status)? = frame else {
            Issue.record("a status frame did not read as a status"); return
        }
        #expect(status.type == "sdcp")
        #expect(status.filename == "ring.ctb")
        #expect(status.progress == 12)
        #expect(status.progressSource == "layers")
    }

    /// A mainboard pushes on its own schedule as well as answering, so most of
    /// what arrives on the socket is not the answer. Taking the first frame
    /// would report whatever the printer happened to be saying.
    @Test("the printer's own chatter is not mistaken for an answer")
    func chatterIsSkipped() async throws {
        let engine = try KhaytEngine()
        for noise in [
            Self.frame(topic: "notice", body: #""Data":{"Message":"hello"}"#),
            Self.frame(topic: "attributes", body: #""Attributes":{"Name":"Saturn"}"#),
            "not json at all",
            "",
            #"{"Topic":"sdcp/status/OTHERBOARD","MainboardID":"OTHERBOARD","Status":{"CurrentStatus":1}}"#,
        ] {
            #expect(try await engine.sdcpRead(frame: noise, mainboardId: Self.board) == nil,
                    "took a frame that was not the answer: \(noise.prefix(40))")
        }
    }

    /// An error frame is the printer ANSWERING. Skipping it would let the
    /// request run out its clock and report a printer that replied as
    /// unreachable, which is the opposite of what happened.
    @Test("an error frame is an answer, not silence")
    func anErrorIsAnAnswer() async throws {
        let engine = try KhaytEngine()
        let frame = try await engine.sdcpRead(
            frame: Self.frame(topic: "error", body: #""Data":{"ErrorMessage":"resin low"}"#),
            mainboardId: Self.board)
        guard case .refused(let why)? = frame else {
            Issue.record("an error frame did not read as a refusal"); return
        }
        #expect(why == "resin low")
    }

    /// The spec's own example shows `"CurrentStatus":[0,1,2,3]` — a machine
    /// doing several things at once. Printing wins, because that is what a shop
    /// needs to see.
    @Test("a machine doing several things at once is reported as printing")
    func anArrayOfStatesPrefersPrinting() async throws {
        let engine = try KhaytEngine()
        let frame = try await engine.sdcpRead(
            frame: Self.frame(topic: "status",
                              body: #""Status":{"CurrentStatus":[0,1,2,3],"PrintInfo":{"Status":3}}"#),
            mainboardId: Self.board)
        guard case .status(let status)? = frame else {
            Issue.record("not read as a status"); return
        }
        #expect(status.state != "idle")
    }
}
