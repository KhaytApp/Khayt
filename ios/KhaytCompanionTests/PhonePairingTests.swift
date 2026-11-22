import CryptoKit
import XCTest
import KhaytCore
@testable import KhaytCompanion

/// Pairing by a number approved on the Mac (C1 + C9). The math is the
/// connector's reviewed v2 flow, so it is held to `docs/connector-pair.vectors.json`
/// with the connector's prefixes; the phone's variant is then exercised end to
/// end against a simulated Mac, including the offers it must refuse.
final class PhonePairingTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func hex(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return d
    }

    // MARK: The shared vectors (connector prefixes)

    private struct ConnectorCase: Decodable {
        let name, pluginPrivateHex, nonceHex, deviceId, identityPublic, serverPublic, pluginPublic, nonce: String
        let commit, offerMessage, sig, check: String
    }

    func testTheConnectorVectorsGiveTheSameMath() throws {
        struct V: Decodable { let cases: [ConnectorCase] }
        let v = try JSONDecoder().decode(V.self, from: Data(contentsOf: root.appending(path: "docs/connector-pair.vectors.json")))
        XCTAssertGreaterThanOrEqual(v.cases.count, 8)
        for c in v.cases {
            let pairing = CodePairing(variant: .connector, privateKey: hex(c.pluginPrivateHex), nonce: hex(c.nonceHex))
            XCTAssertEqual(pairing.publicKey, c.pluginPublic, c.name)
            XCTAssertEqual(pairing.nonce, c.nonce, c.name)
            XCTAssertEqual(pairing.commit, c.commit, c.name)
            XCTAssertEqual(String(decoding: PairCode.offerMessage(.connector, deviceId: c.deviceId, serverPublic: c.serverPublic,
                                                                  commit: c.commit), as: UTF8.self), c.offerMessage, c.name)
            let offer = PairOffer(pairId: "pair_SampleOffer01", pollSecret: "poll_SampleSecret01", deviceId: c.deviceId,
                                  publicKey: c.serverPublic, sig: c.sig, identity: c.identityPublic)
            XCTAssertEqual(pairing.accept(offer), .success(c.check), c.name)
        }
    }

    // MARK: The phone's variant, against a simulated Mac

    private struct Mac {
        let identity = Curve25519.Signing.PrivateKey()
        let server = Curve25519.KeyAgreement.PrivateKey()
        let deviceId = "dev_SamplePhone0000001"

        func offer(for commit: String, variant: PairCode.Variant = .phone, pairId: String = "pair_SampleOffer01") throws -> PairOffer {
            let pub = server.publicKey.rawRepresentation.base64EncodedString()
            let sig = try identity.signature(for: PairCode.offerMessage(variant, deviceId: deviceId, serverPublic: pub, commit: commit))
            return PairOffer(pairId: pairId, pollSecret: "poll_SampleSecret01", deviceId: deviceId, publicKey: pub,
                             sig: sig.base64EncodedString(), identity: identity.publicKey.rawRepresentation.base64EncodedString())
        }

        /// The number the Mac would show once the phone revealed.
        func check(phonePublic: String, nonce: String) -> String {
            PairCode.check(.phone, deviceId: deviceId, identity: identity.publicKey.rawRepresentation.base64EncodedString(),
                           serverPublic: server.publicKey.rawRepresentation.base64EncodedString(),
                           clientPublic: phonePublic, nonce: nonce)
        }
    }

    func testBothSidesShowTheSameNumberAndDeriveTheSameKey() throws {
        let mac = Mac()
        let phone = CodePairing()
        XCTAssertEqual(phone.nonceRaw.count, PairCode.minNonceBytes)
        let offer = try mac.offer(for: phone.commit)
        guard case .success(let shown) = phone.accept(offer) else { return XCTFail("a good offer") }
        XCTAssertEqual(shown, mac.check(phonePublic: phone.publicKey, nonce: phone.nonce))
        XCTAssertEqual(shown.count, 6)
        XCTAssertTrue(shown.allSatisfy(\.isNumber))
        XCTAssertEqual(PairCode.spaced("481207"), "481 207")

        let credential = try XCTUnwrap(phone.credential(offer))
        XCTAssertEqual(credential.deviceId, mac.deviceId)
        XCTAssertEqual(credential.identityKey, offer.identity, "the identity that signed the offer is the one pinned")
        let macKey = try XCTUnwrap(DeviceKey.deriveKey(
            phonePrivate: mac.server, macPublic: phone.publicKey, deviceId: mac.deviceId))
        XCTAssertEqual(credential.key, macKey.withUnsafeBytes { Data($0) }.base64EncodedString(), "one key, never sent")

        // The phone's prefixes are not the connector's: a connector offer is no phone offer.
        XCTAssertNotEqual(PairCode.commit(.phone, publicKey: phone.publicKey, nonce: phone.nonce),
                          PairCode.commit(.connector, publicKey: phone.publicKey, nonce: phone.nonce))
    }

    func testOffersThePhoneMustRefuse() throws {
        let mac = Mac()
        let phone = CodePairing()
        // Signed over a connector's message (a cross-protocol replay).
        XCTAssertEqual(phone.accept(try mac.offer(for: phone.commit, variant: .connector)), .failure(.badSignature))
        // Signed over someone else's commit (a device in the middle swapping its own in).
        XCTAssertEqual(phone.accept(try mac.offer(for: CodePairing().commit)), .failure(.badSignature))
        // Signed by a different identity than the one sent.
        let good = try mac.offer(for: phone.commit)
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertEqual(phone.accept(PairOffer(pairId: good.pairId, pollSecret: good.pollSecret, deviceId: good.deviceId,
                                             publicKey: good.publicKey, sig: good.sig, identity: other)), .failure(.badSignature))
        // A pair id that would steer the next request elsewhere.
        XCTAssertEqual(phone.accept(try mac.offer(for: phone.commit, pairId: "../../api/store")), .failure(.malformed))
        XCTAssertEqual(phone.accept(PairOffer(pairId: good.pairId, pollSecret: "a b", deviceId: good.deviceId,
                                             publicKey: good.publicKey, sig: good.sig, identity: good.identity)), .failure(.malformed))
        XCTAssertEqual(phone.accept(PairOffer(pairId: good.pairId, pollSecret: good.pollSecret, deviceId: "admin",
                                             publicKey: good.publicKey, sig: good.sig, identity: good.identity)), .failure(.malformed))
        // A key that gives the all-zero secret, and one that is not a key.
        let zero = Data(count: 32).base64EncodedString()
        XCTAssertEqual(phone.accept(PairOffer(pairId: good.pairId, pollSecret: good.pollSecret, deviceId: good.deviceId,
                                             publicKey: zero, sig: good.sig, identity: good.identity)), .failure(.badKey))
        XCTAssertEqual(phone.accept(PairOffer(pairId: good.pairId, pollSecret: good.pollSecret, deviceId: good.deviceId,
                                             publicKey: "AAAA", sig: good.sig, identity: good.identity)), .failure(.badKey))
        XCTAssertNil(phone.credential(PairOffer(pairId: good.pairId, pollSecret: good.pollSecret, deviceId: good.deviceId,
                                               publicKey: zero, sig: good.sig, identity: good.identity)))
    }

    func testTheBodiesAndAnswers() throws {
        let phone = CodePairing()
        let start = phone.startBody(name: String(repeating: "n", count: 90), version: "4.12")
        XCTAssertEqual(start["v"], .number(2))
        XCTAssertEqual(start["commit"], .string(phone.commit))
        XCTAssertEqual(start["app"], .string("Khayt iPhone"))
        XCTAssertEqual(start["name"], .string(String(repeating: "n", count: 60)))
        XCTAssertNil(start["publicKey"], "the key is never sent before the Mac commits to its own")
        XCTAssertEqual(phone.revealBody["publicKey"], .string(phone.publicKey))
        for (body, want) in [(#"{"state":"waiting"}"#, KhaytAPIClient.CodePairState.waiting),
                             (#"{"state":"approved"}"#, .approved), (#"{"state":"denied"}"#, .denied),
                             (#"{"state":"expired","reason":"bad-reveal"}"#, .expired), (#"{"state":"new"}"#, .unknown)] {
            XCTAssertEqual(KhaytAPIClient.pairState(Data(body.utf8)), want, body)
        }
        XCTAssertNil(KhaytAPIClient.pairState(Data("[]".utf8)))
    }

    // MARK: Roles (lib/device-roles.js, #2625)

    private struct RoleVectors: Decodable {
        let roles: [String]
        let scopesFor: [String: [String]]
        let roleOf: [RoleOf]
        struct RoleOf: Decodable { let device: JSONValue?; let want: String }
    }

    func testTheRoleRulesMatchTheSharedVectors() throws {
        let v = try JSONDecoder().decode(RoleVectors.self,
                                         from: Data(contentsOf: root.appending(path: "test/fixtures/device-roles-vectors.json")))
        XCTAssertEqual(v.roles, DeviceRole.ladder)
        for role in v.roles {
            XCTAssertEqual(DeviceRole.mayHoldBook(role), v.scopesFor[role]?.contains("book:read") == true,
                           "\(role): the book is book:read")
        }
        // roleOf for a PHONE record: no kind. A device with a kind (a connector)
        // is not this phone, and a non-object is never a stored role.
        var checked = 0
        for c in v.roleOf {
            guard case .object(let d)? = c.device, d["kind"] == nil || d["kind"] == .null else { continue }
            var role: String?
            var unread = false
            switch d["role"] {
            case .string(let s)?: role = s
            case nil, .null?: role = nil
            default: unread = true                  // a role that is not text: never a role
            }
            let byCode = d["rolesVersion"] != nil
            let got = unread ? DeviceRole.effective(role: "?", pairedByCode: byCode)
                             : DeviceRole.effective(role: role, pairedByCode: byCode)
            XCTAssertEqual(got, c.want, "\(d)")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 5)
        XCTAssertEqual(DeviceRole.effective(role: nil, pairedByCode: true), "viewer", "code-paired is never the owner by default")
        XCTAssertEqual(DeviceRole.effective(role: "admin", pairedByCode: false), "viewer", "an unknown role")
    }

    func testARoleScopeRefusalIsRead() {
        XCTAssertEqual(DeviceRole.refusedScope(status: 403, body: Data(#"{"reason":"role-scope","required":"book:read"}"#.utf8)),
                       "book:read")
        XCTAssertNil(DeviceRole.refusedScope(status: 403, body: Data(#"{"reason":"connector-scope"}"#.utf8)))
        XCTAssertNil(DeviceRole.refusedScope(status: 401, body: Data(#"{"reason":"role-scope","required":"book:read"}"#.utf8)))
    }
}
