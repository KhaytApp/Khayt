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
                                "tempNozzle", "tempBed", "error", "lastUpdated", "apiType"], "the desktop's keys, no more")
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
        let ok = try await bench.get("/api/machines/live", headers: ["x-khayt-pin": "2468"])
        #expect(ok.status == 200)
        #expect((try? JSONSerialization.jsonObject(with: ok.body)) is [Any])
    }
}
