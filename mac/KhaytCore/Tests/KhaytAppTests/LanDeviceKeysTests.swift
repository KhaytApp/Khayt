import Foundation
import Testing
import CryptoKit
@testable import KhaytApp

/// A phone that enrolled signs its requests, so the PIN crosses the Wi-Fi once.
/// The values are `docs/lan-device-keys.vectors.json`, shared with the phone.
@MainActor
struct LanDeviceKeysTests {

    enum V {
        static let phonePrivate = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
        static let phonePublic = "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw="
        static let macPrivate = "QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8="
        static let macPublic = "eaYx7t4b+cmPEgMs3q3Q56B5OY/HhriMyEbsia+FpRo="
        static let shared = "rkRAzI1/rdsolBcreOPXRcr6AJi8wQ1+4P2gj6hami4="
        static let deviceId = "dev_k7Qm2xLp9Rt4"
        static let key = "e8D9m4rfuYvAJUCq66wJ6jCNdvATl9RfHOvTZScho7k="
        static let patchBody = #"{"status":"printing"}"#
        static let patchCanonical = "khayt-req-v1\nPATCH\n/api/orders/o_123?x=1%202\n1792396800\n00112233445566778899aabbccddeeff\n598f25910a269f61ae91d2ae3e7bf10cba09a67a071554a5fe042fb513daa94d"
        static let patchMac = "tohMsmM7rbZN5aRy1D1bRM/NfYBJ2PziYlr4ltKm+ME="
        static let getCanonical = "khayt-req-v1\nGET\n/api/store\n1792396800\nffeeddccbbaa99887766554433221100\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        static let getMac = "j6O0aPwkfxlpTkgs/2m7avHkP0IWhX+tcxX9bIgFob0="
        static let identitySeed = "gIGCg4SFhoeIiYqLjI2Oj5CRkpOUlZaXmJmam5ydnp8="
        static let identityPublic = "zRSzf5VulTGU/3+3Oz2B3MVh1hp1OAlLfD4aZD7l86o="
        static let enrolMessage = "khayt-enrol:dev_k7Qm2xLp9Rt4:eaYx7t4b+cmPEgMs3q3Q56B5OY/HhriMyEbsia+FpRo=:B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw="
        static let enrolSig = "yBVEX1IwNYvW5Uw9ksi71TeZwIm9iAm0o7PvyF/fptCQAmwhZhl7Ofb1TP7e15r3WwYKvMU9fGbV0ixNUEssDA=="
    }
    static func d(_ s: String) -> Data { Data(base64Encoded: s)! }
    static let pin = "24682468"
    static let at = Date(timeIntervalSince1970: 1_792_396_800)

    @Test("the shared vectors file, when it is here, says what this test says")
    func vectorsFileAgrees() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/lan-device-keys.vectors.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let v = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(v["phonePublic"] as? String == V.phonePublic)
        #expect(v["macPublic"] as? String == V.macPublic)
        #expect(v["shared"] as? String == V.shared)
        #expect(v["deviceId"] as? String == V.deviceId)
        #expect(v["key"] as? String == V.key)
        let patch = v["patch"] as? [String: String], get = v["get"] as? [String: String]
        #expect(patch?["mac"] == V.patchMac && patch?["canonical"] == V.patchCanonical && patch?["body"] == V.patchBody)
        #expect(get?["mac"] == V.getMac && get?["canonical"] == V.getCanonical)
        let enrol = v["enrol"] as? [String: String]
        #expect(enrol?["sig"] == V.enrolSig && enrol?["message"] == V.enrolMessage
                && enrol?["identityPublic"] == V.identityPublic)
    }

    @Test("every value in the vectors: the keys, the shared secret, the derived key, both MACs, the enrolment")
    func vectors() throws {
        let phone = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.d(V.phonePrivate))
        let mac = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.d(V.macPrivate))
        #expect(phone.publicKey.rawRepresentation.base64EncodedString() == V.phonePublic)
        #expect(mac.publicKey.rawRepresentation.base64EncodedString() == V.macPublic)
        let shared = try mac.sharedSecretFromKeyAgreement(with: phone.publicKey)
        #expect(shared.withUnsafeBytes { Data($0) }.base64EncodedString() == V.shared)
        let key = try #require(LanDevices.derive(mac, phone.publicKey, deviceId: V.deviceId))
        #expect(key.base64EncodedString() == V.key)
        #expect(LanDevices.derive(phone, mac.publicKey, deviceId: V.deviceId) == key, "both sides agree")

        let patch = LanDevices.canonical(method: "patch", target: "/api/orders/o_123?x=1%202", time: "1792396800",
                                         nonce: "00112233445566778899aabbccddeeff", body: Data(V.patchBody.utf8))
        #expect(patch == V.patchCanonical)
        #expect(LanDevices.mac(key: key, canonical: patch).base64EncodedString() == V.patchMac)
        let get = LanDevices.canonical(method: "GET", target: "/api/store", time: "1792396800",
                                       nonce: "ffeeddccbbaa99887766554433221100", body: Data())
        #expect(get == V.getCanonical)
        #expect(LanDevices.mac(key: key, canonical: get).base64EncodedString() == V.getMac)

        let identity = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.d(V.identitySeed))
        #expect(identity.publicKey.rawRepresentation.base64EncodedString() == V.identityPublic)
        let store = LanDevices.inMemory()
        let enrolled = try store.enrol(phonePublic: V.phonePublic, name: "Turki's iPhone", pin: Self.pin,
                                       identity: identity, now: Self.at, serverKey: mac, deviceId: V.deviceId)
        #expect(enrolled.publicKey == V.macPublic)
        #expect(LanDevices.enrolMessage(deviceId: V.deviceId, serverPublic: V.macPublic, phonePublic: V.phonePublic)
                == Data(V.enrolMessage.utf8))
        // Ed25519 here is randomised, so the bytes differ run to run; both verify.
        #expect(identity.publicKey.isValidSignature(Self.d(enrolled.sig), for: Data(V.enrolMessage.utf8)))
        #expect(identity.publicKey.isValidSignature(Self.d(V.enrolSig), for: Data(V.enrolMessage.utf8)))

        // And the stored key is the one the vectors name: the PATCH passes.
        #expect(store.verify(headers: Self.signed(V.deviceId, mac: V.patchMac, nonce: "00112233445566778899aabbccddeeff"),
                             method: "PATCH", target: "/api/orders/o_123?x=1%202", body: Data(V.patchBody.utf8),
                             pin: Self.pin, now: Self.at) == .pass)
    }

    static func signed(_ id: String, mac: String, nonce: String, time: Int = 1_792_396_800) -> [String: String] {
        ["x-khayt-device": id, "x-khayt-time": String(time), "x-khayt-nonce": nonce, "x-khayt-mac": mac]
    }

    /// A store with the vector device enrolled, and a way to sign for it.
    static func enrolled() throws -> (LanDevices, (String, String, Data, String, Int) -> [String: String]) {
        let store = LanDevices.inMemory()
        let mac = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d(V.macPrivate))
        _ = try store.enrol(phonePublic: V.phonePublic, name: "p", pin: pin, identity: .init(), now: at,
                            serverKey: mac, deviceId: V.deviceId)
        let key = d(V.key)
        return (store, { method, target, body, nonce, time in
            let c = LanDevices.canonical(method: method, target: target, time: String(time), nonce: nonce, body: body)
            return signed(V.deviceId, mac: LanDevices.mac(key: key, canonical: c).base64EncodedString(),
                          nonce: nonce, time: time)
        })
    }

    @Test("refusals: replay, clock, a changed body or target, malformed headers, an unknown device")
    func refusals() throws {
        let (store, sign) = try Self.enrolled()
        let t = 1_792_396_800
        let n1 = String(repeating: "a1", count: 16)
        let ok = sign("GET", "/api/store", Data(), n1, t)
        #expect(store.verify(headers: ok, method: "GET", target: "/api/store", body: Data(), pin: Self.pin, now: Self.at) == .pass)
        #expect(store.verify(headers: ok, method: "GET", target: "/api/store", body: Data(), pin: Self.pin,
                             now: Self.at.addingTimeInterval(60)) == .refused("device-replay", now: nil),
                "the same nonce inside five minutes")

        let n2 = String(repeating: "b2", count: 16)
        let late = sign("GET", "/api/store", Data(), n2, t - 121)
        #expect(store.verify(headers: late, method: "GET", target: "/api/store", body: Data(), pin: Self.pin, now: Self.at)
                == .refused("device-clock", now: t))
        let edge = sign("GET", "/api/store", Data(), n2, t - 120)
        #expect(store.verify(headers: edge, method: "GET", target: "/api/store", body: Data(), pin: Self.pin, now: Self.at) == .pass)

        let n3 = String(repeating: "c3", count: 16)
        let patch = sign("PATCH", "/api/orders/x", Data("{}".utf8), n3, t)
        #expect(store.verify(headers: patch, method: "PATCH", target: "/api/orders/x", body: Data("{ }".utf8),
                             pin: Self.pin, now: Self.at) == .refused("device-auth", now: nil), "another body")
        #expect(store.verify(headers: patch, method: "PATCH", target: "/api/orders/y", body: Data("{}".utf8),
                             pin: Self.pin, now: Self.at) == .refused("device-auth", now: nil), "another target")
        #expect(store.verify(headers: patch, method: "DELETE", target: "/api/orders/x", body: Data("{}".utf8),
                             pin: Self.pin, now: Self.at) == .refused("device-auth", now: nil), "another method")

        var bad = sign("GET", "/api/store", Data(), String(repeating: "d4", count: 16), t)
        bad["x-khayt-nonce"] = String(repeating: "D4", count: 16)
        #expect(store.verify(headers: bad, method: "GET", target: "/api/store", body: Data(), pin: Self.pin, now: Self.at)
                == .refused("device-auth", now: nil), "upper-case nonce")
        bad = sign("GET", "/api/store", Data(), String(repeating: "e5", count: 16), t)
        bad["x-khayt-time"] = "1792396800.0"
        #expect(store.verify(headers: bad, method: "GET", target: "/api/store", body: Data(), pin: Self.pin, now: Self.at)
                == .refused("device-auth", now: nil), "time not an integer")
        bad = sign("GET", "/api/store", Data(), String(repeating: "f6", count: 16), t)
        bad["x-khayt-device"] = "dev_nobodyEnrolled"
        #expect(store.verify(headers: bad, method: "GET", target: "/api/store", body: Data(), pin: Self.pin, now: Self.at)
                == .refused("device-unknown", now: nil))
    }

    @Test("a new PIN signs every phone out, whoever changed it")
    func pinChange() throws {
        let (store, sign) = try Self.enrolled()
        let h = sign("GET", "/api/store", Data(), String(repeating: "a1", count: 16), 1_792_396_800)
        #expect(store.verify(headers: h, method: "GET", target: "/api/store", body: Data(), pin: "13571357", now: Self.at)
                == .refused("device-unknown", now: nil))
        #expect(store.count == 0, "removed, not merely refused")
        #expect(store.verify(headers: h, method: "GET", target: "/api/store", body: Data(), pin: Self.pin, now: Self.at)
                == .refused("device-unknown", now: nil), "and the old PIN coming back does not revive it")
    }

    @Test("at most 32 devices: the 33rd replaces the one seen longest ago; a name is cut to 60")
    func ceiling() throws {
        let store = LanDevices.inMemory()
        let identity = Curve25519.Signing.PrivateKey()
        var first = ""
        for i in 0..<33 {
            let phone = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
            let e = try store.enrol(phonePublic: phone, name: String(repeating: "x", count: 80), pin: Self.pin,
                                    identity: identity, now: Self.at.addingTimeInterval(Double(i)))
            if i == 0 { first = e.deviceId }
            #expect(LanDevices.plausibleId(e.deviceId))
        }
        #expect(store.count == 32)
        let h = Self.signed(first, mac: Data(count: 32).base64EncodedString(), nonce: String(repeating: "0", count: 32))
        #expect(store.verify(headers: h, method: "GET", target: "/", body: Data(), pin: Self.pin, now: Self.at)
                == .refused("device-unknown", now: nil), "the oldest went")
        #expect(throws: LanDevices.EnrolError.badKey) {
            try store.enrol(phonePublic: Data(count: 32).base64EncodedString(), name: "", pin: Self.pin,
                            identity: identity, now: Self.at)
        }
        #expect(throws: LanDevices.EnrolError.badKey) {
            try store.enrol(phonePublic: "short", name: "", pin: Self.pin, identity: identity, now: Self.at)
        }
    }

    final class Writes: @unchecked Sendable { var n = 0 }
    final class Kept: @unchecked Sendable { var data: Data? }

    @Test("signing one phone out: listed without its key, refused device-revoked, the others kept, remembered")
    func signOutOne() throws {
        let saved = Kept()
        let store = LanDevices(loaded: nil, persist: { saved.data = $0 })
        let mac = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.d(V.macPrivate))
        _ = try store.enrol(phonePublic: V.phonePublic, name: "Lost phone", pin: Self.pin, identity: .init(),
                            now: Self.at, serverKey: mac, deviceId: V.deviceId)
        let other = try store.enrol(phonePublic: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
                                        .base64EncodedString(),
                                    name: "Desk iPad", pin: Self.pin, identity: .init(), now: Self.at.addingTimeInterval(10))
        #expect(store.list().map(\.name) == ["Desk iPad", "Lost phone"], "the one seen most recently first")

        #expect(store.remove(V.deviceId))
        #expect(!store.remove(V.deviceId), "already gone")
        #expect(store.list().map(\.id) == [other.deviceId], "the other phone stays signed in")
        let key = Self.d(V.key)
        let n = String(repeating: "a1", count: 16)
        let c = LanDevices.canonical(method: "GET", target: "/api/store", time: "1792396800", nonce: n, body: Data())
        let h = Self.signed(V.deviceId, mac: LanDevices.mac(key: key, canonical: c).base64EncodedString(), nonce: n)
        #expect(store.verify(headers: h, method: "GET", target: "/api/store", body: Data(), pin: Self.pin, now: Self.at)
                == .refused("device-revoked", now: nil),
                "revoked, not unknown: the phone must not quietly enrol again with the PIN it kept")

        // Kept across a relaunch, and a store saved before `revoked` existed still reads.
        let reread = LanDevices(loaded: saved.data, persist: nil)
        #expect(reread.verify(headers: h, method: "GET", target: "/api/store", body: Data(), pin: Self.pin, now: Self.at)
                == .refused("device-revoked", now: nil))
        let old = try JSONSerialization.data(withJSONObject: ["salt": Data(count: 32).base64EncodedString(), "devices": []])
        #expect(LanDevices(loaded: old, persist: { _ in }).keeps, "an older store decodes")
    }

    @Test("what is stored but unreadable is never written over; nothing stored starts a list that is kept")
    func unreadableIsKept() throws {
        let writes = Writes()
        let garbled = LanDevices(loaded: Data("not json".utf8), persist: { _ in writes.n += 1 })
        #expect(!garbled.keeps)
        _ = try garbled.enrol(phonePublic: V.phonePublic, name: "p", pin: Self.pin, identity: .init(), now: Self.at)
        #expect(writes.n == 0, "an empty list must not replace phones this build could not read")
        #expect(garbled.count == 1, "the phone still works for this run")

        let fresh = LanDevices(loaded: nil, persist: { _ in writes.n += 1 })
        #expect(fresh.keeps)
        _ = try fresh.enrol(phonePublic: V.phonePublic, name: "p", pin: Self.pin, identity: .init(), now: Self.at)
        #expect(writes.n == 1)
    }

    @Test("over the wire: enrol with the PIN, then sign instead of sending it")
    func overTheWire() async throws {
        let identity = Curve25519.Signing.PrivateKey()
        let bench = try await LanServerTests.Bench(identity: identity)
        defer { bench.stop() }
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let phonePublic = phone.publicKey.rawRepresentation.base64EncodedString()
        let ask = #"{"publicKey":"\#(phonePublic)","name":"Bench phone"}"#

        #expect(try await bench.post("/api/devices", json: ask).status == 401, "enrolment needs the PIN")
        let reply = try await bench.post("/api/devices", json: ask, headers: ["x-khayt-pin": Self.pin])
        #expect(reply.status == 200)
        let body = try #require(try JSONSerialization.jsonObject(with: reply.body) as? [String: String])
        let id = try #require(body["deviceId"]), serverPublic = try #require(body["publicKey"])
        let sig = try #require(body["sig"].flatMap { Data(base64Encoded: $0) })
        #expect(identity.publicKey.isValidSignature(
            sig, for: LanDevices.enrolMessage(deviceId: id, serverPublic: serverPublic, phonePublic: phonePublic)))
        let key = try #require(LanDevices.derive(
            phone, try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Self.d(serverPublic)), deviceId: id))

        let now = Int(LanServerTests.Bench.start.timeIntervalSince1970)
        func signed(_ method: String, _ target: String, _ body: Data, nonce: String, time: Int? = nil) -> [String: String] {
            let t = time ?? now
            let c = LanDevices.canonical(method: method, target: target, time: String(t), nonce: nonce, body: body)
            return Self.signed(id, mac: LanDevices.mac(key: key, canonical: c).base64EncodedString(), nonce: nonce, time: t)
        }
        let n = String(repeating: "ab", count: 16)
        let target = "/api/identity?x=1%202"
        #expect(try await bench.get(target, headers: signed("GET", target, Data(), nonce: n)).status == 200,
                "a signed request opens what the PIN opens")
        let again = try await bench.get(target, headers: signed("GET", target, Data(), nonce: n))
        #expect(again.status == 401 && again.text.contains("device-replay"))
        let skewed = try await bench.get("/api/queue", headers: signed("GET", "/api/queue", Data(),
                                                                        nonce: String(repeating: "cd", count: 16), time: now - 500))
        #expect(skewed.status == 401 && skewed.text.contains(#""now":\#(now)"#))
        var both = signed("GET", "/api/queue", Data(), nonce: String(repeating: "ef", count: 16))
        both["x-khayt-mac"] = Data(count: 32).base64EncodedString()
        both["x-khayt-pin"] = Self.pin
        let judged = try await bench.get("/api/queue", headers: both)
        #expect(judged.status == 401 && judged.text.contains("device-auth"),
                "with both, the device headers alone decide")

        let deltas = Data(#"{"x":1}"#.utf8)
        let post = try await bench.post("/api/store/deltas", json: #"{"x":1}"#,
                                        headers: signed("POST", "/api/store/deltas", deltas, nonce: String(repeating: "12", count: 16)))
        #expect(post.status != 401, "a body is signed as sent")
    }
}
