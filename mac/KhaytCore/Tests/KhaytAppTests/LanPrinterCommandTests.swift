import CryptoKit
import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// `POST /api/printer/{machineId}/{pause|resume|stop}` — a paired phone
/// telling a printer what to do. It moves a machine mid-print, so a bare PIN
/// is not enough: only a signed, enrolled phone reaches the hook.
@MainActor
@Suite(.serialized)
struct LanPrinterCommandTests {

    @Test("the path names one machine and one of three verbs; stop is cancel")
    func paths() {
        #expect(LanServer.printerPath("/api/printer/M1/pause")! == ("M1", .pause))
        #expect(LanServer.printerPath("/api/printer/M1/resume")! == ("M1", .resume))
        #expect(LanServer.printerPath("/api/printer/M1/stop")! == ("M1", .cancel))
        #expect(LanServer.printerPath("/api/printer/M1/cancel")! == ("M1", .cancel))
        #expect(LanServer.printerPath("/api/printer/M%201/pause")! == ("M 1", .pause))
        for bad in ["/api/printer/M1/explode", "/api/printer//pause", "/api/printer/M1",
                    "/api/printer/M1/pause/extra", "/api/printers/M1/pause", "api/printer/M1/pause"] {
            #expect(LanServer.printerPath(bad) == nil, "\(bad)")
        }
    }

    @Test("the PIN alone is refused, nothing alone is refused, and neither reaches the printer")
    func pinIsNotEnough() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        let withPin = try await bench.post("/api/printer/M1/stop", json: "",
                                           headers: ["x-khayt-pin": LanDeviceKeysTests.pin])
        #expect(withPin.status == 403 && withPin.text.contains("device-key-required"))
        let bare = try await bench.post("/api/printer/M1/stop", json: "")
        #expect(bare.status == 401)
        let wrong = try await bench.post("/api/printer/M1/stop", json: "", headers: ["x-khayt-pin": "00000000"])
        #expect(wrong.status == 401)
        #expect(bench.printerCalls.calls.isEmpty)
        // A GET of the same path is not a command.
        let get = try await bench.get("/api/printer/M1/pause", headers: ["x-khayt-pin": LanDeviceKeysTests.pin])
        #expect(get.status == 404)
        #expect(bench.printerCalls.calls.isEmpty)
    }

    @Test("a signed, enrolled phone reaches the printer, once per request")
    func signedPhone() async throws {
        let identity = Curve25519.Signing.PrivateKey()
        let bench = try await LanServerTests.Bench(identity: identity)
        defer { bench.stop() }
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let phonePublic = phone.publicKey.rawRepresentation.base64EncodedString()
        bench.pairing.open()
        let reply = try await bench.post("/api/devices", json: #"{"publicKey":"\#(phonePublic)","name":"Bench"}"#,
                                         headers: ["x-khayt-pin": LanDeviceKeysTests.pin])
        #expect(reply.status == 200)
        let body = try #require(try JSONSerialization.jsonObject(with: reply.body) as? [String: String])
        let id = try #require(body["deviceId"]), serverPublic = try #require(body["publicKey"])
        let key = try #require(LanDevices.derive(
            phone, try Curve25519.KeyAgreement.PublicKey(rawRepresentation: LanDeviceKeysTests.d(serverPublic)),
            deviceId: id))
        let now = Int(LanServerTests.Bench.start.timeIntervalSince1970)
        func signed(_ target: String, nonce: String) -> [String: String] {
            let c = LanDevices.canonical(method: "POST", target: target, time: String(now), nonce: nonce,
                                         body: Data())
            return LanDeviceKeysTests.signed(id, mac: LanDevices.mac(key: key, canonical: c).base64EncodedString(),
                                             nonce: nonce, time: now)
        }
        let target = "/api/printer/M1/pause"
        let nonce = String(repeating: "ab", count: 16)
        let ok = try await bench.post(target, json: "", headers: signed(target, nonce: nonce))
        #expect(ok.status == 200 && ok.text.contains(#""ok":true"#))
        #expect(bench.printerCalls.calls == ["M1 pause"])
        // The same signed request again is a replay, and stops nothing twice.
        let replay = try await bench.post(target, json: "", headers: signed(target, nonce: nonce))
        #expect(replay.status == 401)
        #expect(bench.printerCalls.calls == ["M1 pause"])
    }
}
