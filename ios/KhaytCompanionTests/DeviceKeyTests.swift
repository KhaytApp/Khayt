import CryptoKit
import XCTest
@testable import KhaytCompanion

/// The phone's half of `POST /api/devices` and signed requests. The fixed
/// values come from `docs/lan-device-keys.vectors.json`, which the Mac's and
/// the desktop's tests reproduce too: if one side drifts, its own suite says so.
@MainActor
final class DeviceKeyTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Request: Decodable { let body: String?; let canonical: String; let mac: String }
        struct Enrol: Decodable { let identitySeed, identityPublic, message, sig: String }
        let phonePrivate, phonePublic, macPrivate, macPublic, deviceId, key: String
        let patch, get: Request
        let enrol: Enrol
    }

    private func vectors() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // KhaytCompanionTests
            .deletingLastPathComponent()      // ios
            .deletingLastPathComponent()      // repo root
            .appending(path: "docs/lan-device-keys.vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private func phoneKey(_ v: Vectors) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: XCTUnwrap(Data(base64Encoded: v.phonePrivate)))
    }

    // MARK: - The shared values

    func testTheDerivedKeyMatchesTheVectors() throws {
        let v = try vectors()
        let phone = try phoneKey(v)
        XCTAssertEqual(phone.publicKey.rawRepresentation.base64EncodedString(), v.phonePublic)
        let key = try XCTUnwrap(DeviceKey.deriveKey(phonePrivate: phone, macPublic: v.macPublic, deviceId: v.deviceId))
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }.base64EncodedString(), v.key)
    }

    func testTheSignedRequestsMatchTheVectors() throws {
        let v = try vectors()
        let patchURL = try XCTUnwrap(URL(string: "http://192.168.1.5:3219/api/orders/o_123?x=1%202"))
        XCTAssertEqual(DeviceKey.requestTarget(patchURL), "/api/orders/o_123?x=1%202", "still percent-encoded")
        let patch = DeviceKey.canonical(method: "patch", target: DeviceKey.requestTarget(patchURL), time: 1_792_396_800,
                                        nonce: "00112233445566778899aabbccddeeff",
                                        body: Data(try XCTUnwrap(v.patch.body).utf8))
        XCTAssertEqual(patch, v.patch.canonical)
        XCTAssertEqual(DeviceKey.mac(key: v.key, canonical: patch), v.patch.mac)

        let getURL = try XCTUnwrap(URL(string: "http://192.168.1.5:3219/api/store"))
        let get = DeviceKey.canonical(method: "GET", target: DeviceKey.requestTarget(getURL), time: 1_792_396_800,
                                      nonce: "ffeeddccbbaa99887766554433221100", body: nil)
        XCTAssertEqual(get, v.get.canonical, "no body hashes as the empty string")
        XCTAssertEqual(DeviceKey.mac(key: v.key, canonical: get), v.get.mac)
    }

    func testTheEnrolmentSignatureMatchesTheVectors() throws {
        let v = try vectors()
        XCTAssertEqual(String(decoding: DeviceKey.enrolmentMessage(deviceId: v.deviceId, macPublic: v.macPublic,
                                                                   phonePublic: v.phonePublic), as: UTF8.self),
                       v.enrol.message)
        let credential = try XCTUnwrap(DeviceKey.credential(deviceId: v.deviceId, macPublic: v.macPublic, sig: v.enrol.sig,
                                                            phonePrivate: phoneKey(v), identityKey: v.enrol.identityPublic))
        XCTAssertEqual(credential, .init(deviceId: v.deviceId, key: v.key, identityKey: v.enrol.identityPublic))
    }

    func testAnEnrolmentNotSignedByThePinnedKeyIsRefused() throws {
        let v = try vectors()
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertNil(DeviceKey.credential(deviceId: v.deviceId, macPublic: v.macPublic, sig: v.enrol.sig,
                                          phonePrivate: try phoneKey(v), identityKey: other))
        // Someone in the middle swapping in their own X25519 key.
        let swapped = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertNil(DeviceKey.credential(deviceId: v.deviceId, macPublic: swapped, sig: v.enrol.sig,
                                          phonePrivate: try phoneKey(v), identityKey: v.enrol.identityPublic))
        XCTAssertNil(DeviceKey.credential(deviceId: "dev_x", macPublic: v.macPublic, sig: v.enrol.sig,
                                          phonePrivate: try phoneKey(v), identityKey: v.enrol.identityPublic))
    }

    func testDeviceIds() {
        XCTAssertTrue(DeviceKey.isDeviceId("dev_k7Qm2xLp9Rt4"))
        XCTAssertTrue(DeviceKey.isDeviceId("dev_" + String(repeating: "a", count: 40)))
        XCTAssertFalse(DeviceKey.isDeviceId("dev_" + String(repeating: "a", count: 41)))
        XCTAssertFalse(DeviceKey.isDeviceId("dev_short"))
        XCTAssertFalse(DeviceKey.isDeviceId("k7Qm2xLp9Rt4abcd"))
        XCTAssertFalse(DeviceKey.isDeviceId("dev_k7Qm2xLp9Rt4/../x"))
    }

    func testRefusals() {
        func r(_ s: String) -> DeviceKey.Refusal? { DeviceKey.refusal(Data(s.utf8)) }
        XCTAssertEqual(r(#"{"reason":"device-unknown"}"#), .unknown)
        XCTAssertEqual(r(#"{"reason":"device-auth"}"#), .unknown, "keys that disagree will not agree on a retry")
        XCTAssertEqual(r(#"{"reason":"device-clock","now":1792396800}"#), .clock(now: 1_792_396_800))
        XCTAssertNil(r(#"{"reason":"device-clock"}"#))
        XCTAssertEqual(r(#"{"reason":"device-replay"}"#), .replay)
        XCTAssertEqual(r(#"{"reason":"device-revoked"}"#), .revoked)
        XCTAssertNil(r(#"{"reason":"pin-too-short"}"#), "a PIN refusal is not a device one")
        XCTAssertNil(r("not json"))
    }

    // MARK: - End to end, against a stand-in Mac

    private var saved: (host: String, port: Int, pin: String, paired: Bool, sample: Bool, identity: String, device: DeviceKey.Credential?)?

    override func setUp() {
        let s = ConnectionSettings()
        saved = (s.host, s.port, s.pin, s.isPaired, s.isSampleShop, s.macIdentityKey, s.device)
        StubMac.reset()
    }

    override func tearDown() {
        guard let saved else { return }
        let s = ConnectionSettings()
        s.host = saved.host; s.port = saved.port; s.pin = saved.pin; s.isPaired = saved.paired; s.isSampleShop = saved.sample
        s.macIdentityKey = saved.identity; s.device = saved.device; s.signedOutByMac = false
        StubMac.reset()
    }

    private func pairedSettings() -> ConnectionSettings {
        let s = ConnectionSettings()
        s.host = "khayt-stub.invalid"; s.port = 3219; s.pin = "12345678"; s.isPaired = true; s.isSampleShop = false
        s.macIdentityKey = StubMac.identity.publicKey.rawRepresentation.base64EncodedString()
        return s
    }

    func testThePhoneEnrolsOnceThenSignsInsteadOfSendingThePin() async throws {
        let s = pairedSettings()
        let api = KhaytAPIClient(settings: s, protocols: [StubMac.self])
        XCTAssertTrue(api.wantsEnrolment())
        let result = await api.enrolDevice(name: "Test iPhone")
        XCTAssertEqual(result, .enrolled)
        XCTAssertEqual(s.device?.deviceId, StubMac.deviceId)
        XCTAssertFalse(api.wantsEnrolment())
        XCTAssertEqual(StubMac.seen.last?.pin, "12345678", "the enrolment itself carries the PIN")

        let key = await api.fetchIdentityKey()
        XCTAssertNotNil(key)
        let signed = try XCTUnwrap(StubMac.seen.last)
        XCTAssertNil(signed.pin, "a signed request carries no PIN")
        XCTAssertTrue(signed.signedOK)
        XCTAssertEqual(ConnectionSettings().device, s.device, "kept in the Keychain across launches")
    }

    func testAMacThatForgotThePhoneGetsThePinAndAFreshEnrolment() async throws {
        let s = pairedSettings()
        let api = KhaytAPIClient(settings: s, protocols: [StubMac.self])
        _ = await api.enrolDevice(name: "Test iPhone")
        StubMac.knowsDevice = false
        let fetched = await api.fetchIdentityKey()
        XCTAssertNotNil(fetched, "the request still succeeds, with the PIN")
        XCTAssertEqual(StubMac.seen.suffix(2).map { $0.pin != nil }, [false, true])
        XCTAssertNil(s.device)
        XCTAssertTrue(api.wantsEnrolment())
    }

    func testAPhoneSignedOutOnTheMacForgetsThePinAndDoesNotComeBackByItself() async throws {
        let s = pairedSettings()
        let api = KhaytAPIClient(settings: s, protocols: [StubMac.self])
        _ = await api.enrolDevice(name: "Test iPhone")
        StubMac.revoked = true
        let before = StubMac.seen.count
        let fetched = await api.fetchIdentityKey()
        XCTAssertNil(fetched)
        XCTAssertEqual(StubMac.seen.count, before + 1, "no second try with the PIN")
        XCTAssertNil(StubMac.seen.last?.pin)
        XCTAssertEqual(s.pin, "")
        XCTAssertNil(s.device)
        XCTAssertEqual(s.macIdentityKey, "")
        XCTAssertTrue(s.signedOutByMac)
        XCTAssertEqual(s.isPaired, api.cloud != nil, "without a cloud sign-in there is no shop left")
        XCTAssertEqual(ConnectionSettings().pin, "", "gone from the Keychain too")
        XCTAssertFalse(api.wantsEnrolment(), "nothing enrols without a PIN")
        s.pin = "12345678"
        XCTAssertFalse(s.signedOutByMac, "typing the PIN again clears the note")
    }

    func testAMacWithAnotherClockIsBelievedOnce() async throws {
        let s = pairedSettings()
        let api = KhaytAPIClient(settings: s, protocols: [StubMac.self])
        _ = await api.enrolDevice(name: "Test iPhone")
        StubMac.clockAhead = 600
        let fetched = await api.fetchIdentityKey()
        XCTAssertNotNil(fetched)
        let last = try XCTUnwrap(StubMac.seen.last)
        XCTAssertTrue(last.signedOK)
        XCTAssertNil(last.pin, "a clock difference is not a reason to send the PIN")
    }

    func testAComputerWithoutTheRouteKeepsThePinAndIsAskedADayLater() async {
        let s = pairedSettings()
        let api = KhaytAPIClient(settings: s, protocols: [StubMac.self])
        StubMac.hasRoute = false
        let now = Date()
        let result = await api.enrolDevice(name: "Test iPhone", now: now)
        XCTAssertEqual(result, .unsupported)
        XCTAssertNil(s.device)
        XCTAssertFalse(api.wantsEnrolment(now: now.addingTimeInterval(3600)))
        XCTAssertTrue(api.wantsEnrolment(now: now.addingTimeInterval(86_401)))
        let fetched = await api.fetchIdentityKey()
        XCTAssertNotNil(fetched)
        XCTAssertEqual(StubMac.seen.last?.pin, "12345678")
    }

    func testANewPinOrIdentityDropsTheEnrolment() async {
        let s = pairedSettings()
        let api = KhaytAPIClient(settings: s, protocols: [StubMac.self])
        _ = await api.enrolDevice(name: "Test iPhone")
        XCTAssertNotNil(s.device)
        s.macIdentityKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertNil(s.device, "signed for another identity")
        s.macIdentityKey = StubMac.identity.publicKey.rawRepresentation.base64EncodedString()
        _ = await api.enrolDevice(name: "Test iPhone")
        XCTAssertNotNil(s.device)
        s.pin = "87654321"
        XCTAssertNil(s.device, "a new PIN may be a new Mac")
    }
}

/// A Mac that speaks `/api/devices` and checks signatures, per `docs/LAN_API.md`.
final class StubMac: URLProtocol, @unchecked Sendable {
    struct Seen { let path: String; let pin: String?; let signedOK: Bool }

    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var hasRoute = true
    nonisolated(unsafe) static var knowsDevice = true
    nonisolated(unsafe) static var revoked = false
    nonisolated(unsafe) static var clockAhead: TimeInterval = 0
    nonisolated(unsafe) static var key: SymmetricKey?
    static let identity = Curve25519.Signing.PrivateKey()
    static let deviceId = "dev_stubPhone0001"

    static func reset() {
        seen = []; hasRoute = true; knowsDevice = true; revoked = false; clockAhead = 0; key = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "khayt-stub.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let body = Self.body(of: request)
        let pin = request.value(forHTTPHeaderField: "x-khayt-pin")
        let now = Date().timeIntervalSince1970 + Self.clockAhead
        var signedOK = false
        var answer: (Int, Any) = (404, ["error": "not found"])

        if let device = request.value(forHTTPHeaderField: "x-khayt-device") {
            let time = Int(request.value(forHTTPHeaderField: "x-khayt-time") ?? "") ?? 0
            let nonce = request.value(forHTTPHeaderField: "x-khayt-nonce") ?? ""
            let mac = request.value(forHTTPHeaderField: "x-khayt-mac") ?? ""
            if Self.revoked && device == Self.deviceId {
                answer = (401, ["reason": "device-revoked"])
            } else if !Self.knowsDevice || device != Self.deviceId || Self.key == nil {
                answer = (401, ["reason": "device-unknown"])
            } else if abs(now - TimeInterval(time)) > 120 {
                answer = (401, ["reason": "device-clock", "now": Int(now)])
            } else {
                let canonical = DeviceKey.canonical(method: request.httpMethod ?? "GET", target: DeviceKey.requestTarget(url),
                                                    time: time, nonce: nonce, body: body)
                let expected = Data(HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: Self.key!)).base64EncodedString()
                signedOK = expected == mac
                answer = signedOK ? self.route(url.path(), body: body) : (401, ["reason": "device-auth"])
            }
        } else if pin == "12345678" {
            answer = route(url.path(), body: body)
        } else {
            answer = (401, ["error": "unauthorized"])
        }
        Self.seen.append(Seen(path: url.path(), pin: pin, signedOK: signedOK))

        let data = try! JSONSerialization.data(withJSONObject: answer.1)
        let response = HTTPURLResponse(url: url, statusCode: answer.0, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func route(_ path: String, body: Data?) -> (Int, Any) {
        switch path {
        case "/api/identity":
            return (200, ["alg": "ed25519", "publicKey": Self.identity.publicKey.rawRepresentation.base64EncodedString()])
        case "/api/devices" where Self.hasRoute:
            guard let body, let ask = try? JSONSerialization.jsonObject(with: body) as? [String: String],
                  let phonePublic = ask["publicKey"], let raw = Data(base64Encoded: phonePublic),
                  let phone = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else { return (400, ["error": "bad"]) }
            let mine = Curve25519.KeyAgreement.PrivateKey()
            let macPublic = mine.publicKey.rawRepresentation.base64EncodedString()
            let shared = try! mine.sharedSecretFromKeyAgreement(with: phone)
            Self.key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("khayt-device-v1".utf8),
                                                      sharedInfo: Data(Self.deviceId.utf8), outputByteCount: 32)
            let sig = try! Self.identity.signature(for: Data("khayt-enrol:\(Self.deviceId):\(macPublic):\(phonePublic)".utf8))
            return (200, ["deviceId": Self.deviceId, "publicKey": macPublic, "sig": sig.base64EncodedString()])
        default:
            return (404, ["error": "not found"])
        }
    }

    /// URLSession hands a URL protocol the body as a stream, not `httpBody`.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
