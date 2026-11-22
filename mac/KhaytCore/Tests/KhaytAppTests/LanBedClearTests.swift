import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// `POST /api/printer/{machineId}/bed-clear`: a paired phone's "Bed is clear"
/// and "Taken off". It changes what the dispatcher may offer, so it takes a
/// signed phone whose ROLE allows `machines:control`, and nothing less.
@MainActor
@Suite(.serialized)
struct LanBedClearTests {

    @Test("the path names one machine and nothing else")
    func paths() {
        #expect(LanServer.bedClearPath("/api/printer/M1/bed-clear") == "M1")
        #expect(LanServer.bedClearPath("/api/printer/M%201/bed-clear") == "M 1")
        for bad in ["/api/printer//bed-clear", "/api/printer/M1/bed-clear/x", "/api/printer/M1/bedclear",
                    "/api/printers/M1/bed-clear", "/api/printer/M1", "api/printer/M1/bed-clear"] {
            #expect(LanServer.bedClearPath(bad) == nil, "\(bad)")
        }
        // Not a printer command, and a command is not this.
        #expect(LanServer.printerPath("/api/printer/M1/bed-clear") == nil)
        #expect(LanServer.bedClearPath("/api/printer/M1/pause") == nil)
    }

    @Test("the PIN alone is refused, and so is nothing at all; neither reaches the book")
    func pinIsNotEnough() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        let withPin = try await bench.post("/api/printer/M1/bed-clear", json: "",
                                           headers: ["x-khayt-pin": LanDeviceKeysTests.pin])
        #expect(withPin.status == 403 && withPin.text.contains("device-key-required"))
        #expect(try await bench.post("/api/printer/M1/bed-clear", json: "").status == 401)
        let get = try await bench.get("/api/printer/M1/bed-clear", headers: ["x-khayt-pin": LanDeviceKeysTests.pin])
        #expect(get.status == 404)
        #expect(bench.bedCalls.calls.isEmpty)
    }

    @Test("a viewer's phone is refused with the scope it lacked")
    func viewer() async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let phone = try PhoneRolesTests.codePaired(bench.devices, role: "viewer", name: "V")
        let (status, json) = try await PhoneRolesTests.status(bench, phone, "POST", "/api/printer/M1/bed-clear")
        #expect(status == 403)
        #expect(json["reason"] as? String == "role-scope")
        #expect(json["required"] as? String == "machines:control")
        #expect(bench.bedCalls.calls.isEmpty)
    }

    @Test("an operator's phone may say it")
    func `operator`() async throws { try await allowed("operator") }

    @Test("a manager's phone may say it")
    func manager() async throws { try await allowed("manager") }

    @Test("the owner's phone may say it")
    func owner() async throws { try await allowed("owner") }

    @Test("a phone paired with the owner PIN before roles is the owner, and may say it")
    func legacy() async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let phone = try LanConnectorRoutesTests.enrol(bench, kind: nil, name: "Legacy")
        #expect(try await PhoneRolesTests.status(bench, phone, "POST", "/api/printer/M1/bed-clear").0 == 200)
        #expect(bench.bedCalls.calls == ["M1"])
    }

    @Test("a paired slicer cannot say it")
    func slicer() async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let slicer = try LanConnectorRoutesTests.enrol(bench)
        let (status, _) = try await PhoneRolesTests.status(bench, slicer, "POST", "/api/printer/M1/bed-clear")
        #expect(status == 401 || status == 403, "\(status)")
        #expect(bench.bedCalls.calls.isEmpty)
    }

    func allowed(_ role: String) async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let phone = try PhoneRolesTests.codePaired(bench.devices, role: role, name: role)
        let (status, json) = try await PhoneRolesTests.status(bench, phone, "POST", "/api/printer/M1/bed-clear")
        #expect(status == 200, Comment(rawValue: role))
        #expect(json["ok"] as? Bool == true)
        #expect(json["bedClearedAt"] as? String != nil)
        #expect(bench.bedCalls.calls == ["M1"], Comment(rawValue: role))
    }

    @Test("the rule itself names the scope, in the bundled copy the server asks")
    func rule() async throws {
        let engine = OperatorLockTests.sharedEngine
        for (role, ok) in [("viewer", false), ("operator", true), ("manager", true), ("owner", true)] {
            let answer = try await engine.deviceAllows(.object(["role": .string(role), "rolesVersion": .number(1)]),
                                                       path: "/api/printer/m1/bed-clear", method: "POST")
            #expect(answer.ok == ok && answer.required == "machines:control", Comment(rawValue: role))
        }
        let read = try await engine.deviceAllows(.object(["role": .string("manager"), "rolesVersion": .number(1)]),
                                                 path: "/api/printer/m1/bed-clear", method: "GET")
        #expect(!read.ok && read.required == "owner")
    }

    @Test("the sample book is not written to, and the phone is told")
    func sample() async throws {
        // Before the app has started there is no answer yet: busy, not "no such printer".
        let starting = Shop()
        if starting.engine == nil {
            let (status, body) = await starting.phoneBedClear("anything")
            #expect(status == 503 && body.contains("busy"))
        }
        let shop = Shop()
        shop.useEngine(OperatorLockTests.sharedEngine)
        await shop.load(.sample)
        let machine = try #require(shop.machinesInUse.first)
        let (status, body) = await shop.phoneBedClear(machine.id)
        #expect(status == 409 && body.contains("read-only"))
        let (missing, said) = await shop.phoneBedClear("no-such-machine")
        #expect(missing == 404 && said.contains("not-found"))
        // The route in the real server is this function, not only the bench's stub.
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let server = try String(contentsOf: app.appending(path: "LanServer.swift"), encoding: .utf8)
        #expect(server.contains("await self?.phoneBedClear(id)"))
    }
}
