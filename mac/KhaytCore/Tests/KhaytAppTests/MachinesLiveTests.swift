import Foundation
import Testing
@testable import KhaytApp
import KhaytCore

/// `/api/machines/live` — the phone's live printer view, as `lib/lan-server.js`
/// answers it.
struct MachinesLiveTests {
    @Test("a printer's reading, in the desktop's shape, integers rounded")
    func row() throws {
        let status = try JSONDecoder().decode(KhaytEngine.PrinterStatus.self, from: Data("""
        {"state":"printing","progress":42,"filename":"dragon.gcode","timeRemaining":3599.6,
         "tempNozzle":214.6,"tempBed":59.4,"type":"moonraker"}
        """.utf8))
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let row = LanServer.liveRow(id: "M-1", name: "U1", apiType: "moonraker",
                                    reading: .init(status: status, problem: nil, at: at))
        guard case .object(let o) = row else { Issue.record("not an object"); return }
        #expect(o["id"] == .string("M-1") && o["name"] == .string("U1"))
        #expect(o["hasPrinterApi"] == .bool(true))
        #expect(o["state"] == .string("printing") && o["progress"] == .number(42))
        #expect(o["filename"] == .string("dragon.gcode"))
        #expect(o["timeRemaining"] == .number(3600) && o["tempNozzle"] == .number(215) && o["tempBed"] == .number(59))
        #expect(o["error"] == .null)
        #expect(o["lastUpdated"] == .string(StoreWriter.iso(at)))
        #expect(o["apiType"] == .string("moonraker"))
        #expect(Set(o.keys) == ["id", "name", "hasPrinterApi", "state", "progress", "filename", "timeRemaining",
                                "tempNozzle", "tempBed", "error", "lastUpdated", "apiType",
                                "lastOkAt", "errorCode", "httpStatus",
                                "problems", "waiting"], "the desktop's keys, plus what the printer needs")
        #expect(o["problems"] == .array([]) && o["waiting"] == .array([]), "nothing needed is two empty lists")
    }

    @Test("a live row says when the printer last answered, and why it is not answering in a word no language changes")
    func lastOkAndCode() {
        func row(_ r: PrinterWatch.Reading?) -> [String: JSONValue] {
            guard case .object(let o) = LanServer.liveRow(id: "M-9", name: "U1", apiType: "moonraker", reading: r) else { return [:] }
            return o
        }
        let ok = Date(timeIntervalSince1970: 1_795_000_000), later = ok.addingTimeInterval(90)
        // Answering: no code, and both stamps are the same instant.
        let fine = row(.init(status: nil, problem: nil, at: ok, lastOkAt: ok))
        #expect(fine["lastOkAt"] == .string(StoreWriter.iso(ok)) && fine["errorCode"] == .null && fine["httpStatus"] == .null)
        // Refused since: asked later, last answered earlier, and a word to match on.
        let refused = row(.init(status: nil, problem: "تم رفض الوصول", at: later, consecutiveFailures: 2,
                                lastOkAt: ok, problemCode: "access-refused", httpStatus: 401))
        #expect(refused["lastUpdated"] == .string(StoreWriter.iso(later)))
        #expect(refused["lastOkAt"] == .string(StoreWriter.iso(ok)))
        #expect(refused["errorCode"] == .string("access-refused") && refused["httpStatus"] == .number(401))
        #expect(refused["error"] == .string("تم رفض الوصول"), "the sentence stays, in the shop's language")
        // Never answered: null, not a made-up time. A problem with no code is unreachable.
        let never = row(.init(status: nil, problem: "x", at: later, consecutiveFailures: 5))
        #expect(never["lastOkAt"] == .null && never["errorCode"] == .string("unreachable") && never["httpStatus"] == .null)
        // Never heard from at all.
        let none = row(nil)
        #expect(none["lastOkAt"] == .null && none["errorCode"] == .null && none["httpStatus"] == .null)
    }

    @Test("every failure has a word, and a refusal is told from silence whatever the protocol")
    func failureWords() {
        func said(_ error: any Error) -> String {
            let f = PrinterWatch.failure(error)
            return f.code + " " + (f.http.map { String($0) } ?? "-")
        }
        #expect(said(PrinterWatch.Refusal.http(401, "")) == "access-refused 401")
        #expect(said(PrinterWatch.Refusal.http(403, "Forbidden")) == "access-refused 403")
        #expect(said(PrinterWatch.Refusal.http(503, "")) == "http 503")
        #expect(said(PrinterWatch.Refusal.handshakeRefused("no")) == "access-refused -")
        #expect(said(PrinterWatch.Refusal.noHost) == "not-set-up -")
        #expect(said(PrinterWatch.Refusal.notJSON) == "unreadable -")
        #expect(said(BambuMqtt.Trouble.refused(5)) == "access-refused -")
        #expect(said(BambuMqtt.Trouble.certificateChanged) == "certificate -")
        #expect(said(BambuMqtt.Trouble.silent) == "unreachable -")
        #expect(said(SdcpSocket.Trouble.refused("no")) == "access-refused -")
        #expect(said(URLError(.timedOut)) == "unreachable -")
        // The words the doc lists are the only ones.
        let doc = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/LAN_API.md"), encoding: .utf8)) ?? ""
        for word in ["access-refused", "http", "not-set-up", "certificate", "unreadable", "unreachable"] {
            #expect(doc.contains("| `\(word)` |"), Comment(rawValue: word))
        }
        #expect(doc.contains("`lastOkAt`") && doc.contains("`errorCode`") && doc.contains("`httpStatus`"))
    }

    @Test("a machine never heard from: id, name and whether it has a printer, the rest null")
    func unheard() {
        guard case .object(let o) = LanServer.liveRow(id: "M-2", name: "Shelf", apiType: "none", reading: nil) else {
            Issue.record("shape"); return
        }
        #expect(o["hasPrinterApi"] == .bool(false))
        for key in ["state", "progress", "filename", "timeRemaining", "tempNozzle", "tempBed", "error", "lastUpdated"] {
            #expect(o[key] == .null, "\(key)")
        }
        #expect(o["apiType"] == .string("none"))
    }

    @Test("a printer that is not answering says why, and keeps when it was last heard")
    func problem() {
        let at = Date()
        guard case .object(let o) = LanServer.liveRow(id: "M-3", name: "CORE One", apiType: "prusalink",
                                                       reading: .init(status: nil, problem: "not answering", at: at)) else {
            Issue.record("shape"); return
        }
        #expect(o["error"] == .string("not answering") && o["state"] == .null)
        #expect(o["lastUpdated"] == .string(StoreWriter.iso(at)))
    }

    @Test("the route is behind the owner PIN, and answers a JSON array")
    @MainActor
    func route() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        #expect(try await bench.get("/api/machines/live").status == 401)
        let ok = try await bench.get("/api/machines/live", headers: ["x-khayt-pin": "24682468"])
        #expect(ok.status == 200)
        #expect((try? JSONSerialization.jsonObject(with: ok.body)) is [Any])
    }
}
