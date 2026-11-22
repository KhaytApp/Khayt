import CryptoKit
import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// `POST /api/orders/{id}/photos` — a paired phone adding a photo to a job.
/// The body is the JPEG itself, so like the printer route it takes a SIGNED,
/// enrolled phone only: the PIN alone, an API token, or nothing are refused,
/// and a body over a megabyte is judged from its head before it is read.
@MainActor
@Suite(.serialized)
struct LanJobPhotoTests {

    @Test("the path names one job; nothing else is the photo route")
    func paths() {
        #expect(LanServer.jobPhotoPath("/api/orders/J1/photos") == "J1")
        for bad in ["/api/orders/J1/photo", "/api/orders//photos", "/api/orders/photos",
                    "/api/orders/J1/photos/extra", "/api/order/J1/photos", "api/orders/J1/photos"] {
            #expect(LanServer.jobPhotoPath(bad) == nil, "\(bad)")
        }
        #expect(LanServer.isJobPhotoUpload(method: "POST", target: "/api/orders/J1/photos"))
        #expect(LanServer.isJobPhotoUpload(method: "POST", target: "/v1/orders/J1/photos?x=1"))
        #expect(!LanServer.isJobPhotoUpload(method: "GET", target: "/api/orders/J1/photos"))
        #expect(!LanServer.isJobPhotoUpload(method: "POST", target: "/api/orders/J1"))
    }

    @Test("the PIN alone is refused, nothing alone is refused, and neither reaches the job")
    func pinIsNotEnough() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        let small = OrderPhotoTests.image(64, 48)
        let withPin = try await bench.send("POST", "/api/orders/J1/photos", body: small,
                                           headers: ["x-khayt-pin": LanDeviceKeysTests.pin])
        #expect(withPin.status == 403 && withPin.text.contains("device-key-required"))
        let bare = try await bench.send("POST", "/api/orders/J1/photos", body: small)
        #expect(bare.status == 401)
        // Over a megabyte: refused from the head, before a byte of body is
        // read — sent as a head alone, as the estimate route's guard does.
        let port = bench.port, pin = LanDeviceKeysTests.pin
        let bigPin = await offPool {
            Alpha58SecurityTests.headOnly(port: port, path: "/api/orders/J1/photos", length: 1_500_000,
                                          extra: "X-Khayt-Pin: \(pin)\r\n")
        }
        #expect(bigPin.hasPrefix("HTTP/1.1 403") && bigPin.contains("device-key-required"), Comment(rawValue: bigPin))
        #expect(bench.photoCalls.calls.isEmpty)
    }

    @Test("a signed, enrolled phone's photo reaches the job, past a megabyte, once per request")
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
        func signed(_ target: String, _ payload: Data, nonce: String) -> [String: String] {
            let c = LanDevices.canonical(method: "POST", target: target, time: String(now), nonce: nonce,
                                         body: payload)
            return LanDeviceKeysTests.signed(id, mac: LanDevices.mac(key: key, canonical: c).base64EncodedString(),
                                             nonce: nonce, time: now)
        }
        let target = "/api/orders/J1/photos"
        // A phone camera's JPEG is usually over the 1 MB every other body is held to.
        let photo = Data(count: 1_500_000)
        let nonce = String(repeating: "cd", count: 16)
        let ok = try await bench.send("POST", target, body: photo, headers: signed(target, photo, nonce: nonce))
        #expect(ok.status == 201 && ok.text.contains(#""ok":true"#), "\(ok.status) \(ok.text)")
        #expect(bench.photoCalls.calls == ["J1 1500000"])
        // The same signed request again is a replay, and files nothing twice.
        let replay = try await bench.send("POST", target, body: photo, headers: signed(target, photo, nonce: nonce))
        #expect(replay.status == 401)
        // Over the photo cap: refused before it is read, whoever sent it.
        let port = bench.port
        let tooBig = await offPool {
            Alpha58SecurityTests.headOnly(port: port, path: target, length: OrderPhoto.maxBytes + 1)
        }
        #expect(tooBig.hasPrefix("HTTP/1.1 413"), Comment(rawValue: tooBig))
        #expect(bench.photoCalls.calls == ["J1 1500000"])
    }
}
