import CryptoKit
import XCTest
import KhaytCore
@testable import KhaytCompanion

/// Pairing by a number approved on the Mac (C1 + C9). The math is the
/// connector's reviewed v2 flow, so it is held to `docs/connector-pair.vectors.json`
/// with the connector's prefixes; the phone's variant is then exercised end to
/// end against a simulated Mac, including the offers it must refuse.
@MainActor
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

    // MARK: The phone's own vectors (#2625, docs/phone-pair.vectors.json)

    private struct PhoneCase: Decodable {
        let name, pluginPrivateHex, nonceHex, deviceId, identityPublic, serverPublic, pluginPublic, nonce: String
        let commit, offerMessage, sig, check, derivedKey: String
    }
    private struct PhoneRefusal: Decodable {
        let name, refusedBy, why: String
        let deviceId, identityPublic, serverPublic, commit, offerMessage, sig: String?
    }
    private struct PhoneVectors: Decodable {
        struct Prefixes: Decodable, Equatable { let commit, offer, check: String }
        let prefixes: Prefixes
        let cases: [PhoneCase]
        let refuse: [PhoneRefusal]
    }

    private func phoneVectors() throws -> PhoneVectors {
        try JSONDecoder().decode(PhoneVectors.self, from: Data(contentsOf: root.appending(path: "docs/phone-pair.vectors.json")))
    }

    /// The HARD-CODED `.phone` variant is held to the file the Mac and the
    /// desktop are generated from. The variant is never built from the file
    /// (that would prove nothing): a typo in one of the phone's prefixes fails
    /// here, not only against a real Mac. The simulated-Mac tests below use
    /// `.phone` on both sides, so they cannot catch it.
    func testThePhoneVariantIsTheSharedOne() throws {
        let v = try phoneVectors()
        let phone = PairCode.Variant.phone
        XCTAssertEqual(PhoneVectors.Prefixes(commit: phone.commit, offer: phone.offer, check: phone.check), v.prefixes)
        XCTAssertNotEqual(phone, PairCode.Variant.connector)
    }

    func testThePhoneVectorsGiveTheSameMath() throws {
        let v = try phoneVectors()
        XCTAssertGreaterThanOrEqual(v.cases.count, 9)
        for c in v.cases {
            let pairing = CodePairing(variant: .phone, privateKey: hex(c.pluginPrivateHex), nonce: hex(c.nonceHex))
            XCTAssertEqual(pairing.publicKey, c.pluginPublic, c.name)
            XCTAssertEqual(pairing.nonce, c.nonce, c.name)
            XCTAssertEqual(pairing.commit, c.commit, c.name)
            XCTAssertEqual(String(decoding: PairCode.offerMessage(.phone, deviceId: c.deviceId, serverPublic: c.serverPublic,
                                                                  commit: c.commit), as: UTF8.self), c.offerMessage, c.name)
            let offer = PairOffer(pairId: "pair_SampleOffer01", pollSecret: "poll_SampleSecret01", deviceId: c.deviceId,
                                  publicKey: c.serverPublic, sig: c.sig, identity: c.identityPublic)
            XCTAssertEqual(pairing.accept(offer), .success(c.check), c.name)
            let key = try XCTUnwrap(pairing.privateKey.flatMap {
                DeviceKey.deriveKey(phonePrivate: $0, macPublic: c.serverPublic, deviceId: c.deviceId)
            }, c.name)
            XCTAssertEqual(key.withUnsafeBytes { Data($0) }.base64EncodedString(), c.derivedKey, c.name)
            XCTAssertEqual(pairing.credential(offer)?.key, c.derivedKey, c.name)
        }
    }

    /// Every offer the file says the PHONE must refuse, from the first case's
    /// phone (its key and nonce), each refused with no number and no
    /// credential. The `mac` rows are the Mac's to refuse.
    func testThePhoneRefusesEveryOfferTheFileSaysItMust() throws {
        let v = try phoneVectors()
        let first = try XCTUnwrap(v.cases.first { $0.name == "first" })
        let pairing = CodePairing(variant: .phone, privateKey: hex(first.pluginPrivateHex), nonce: hex(first.nonceHex))
        let phoneRows = v.refuse.filter { $0.refusedBy == "phone" }
        XCTAssertEqual(phoneRows.count, 6, "six offers the phone must refuse")
        XCTAssertEqual(v.refuse.filter { $0.refusedBy == "mac" }.count, 3)
        for r in phoneRows {
            let offer = PairOffer(pairId: "pair_SampleOffer01", pollSecret: "poll_SampleSecret01",
                                  deviceId: try XCTUnwrap(r.deviceId, r.name), publicKey: try XCTUnwrap(r.serverPublic, r.name),
                                  sig: try XCTUnwrap(r.sig, r.name), identity: try XCTUnwrap(r.identityPublic, r.name))
            guard case .failure = pairing.accept(offer) else {
                XCTFail("\(r.name): accepted, but \(r.why)"); continue
            }
            XCTAssertNil(pairing.credential(offer), "\(r.name): no credential")
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
            // The vectors list the owner by omission: the owner holds every scope.
            let holds = role == "owner" ? (v.scopesFor[role]?.contains("book:read") ?? true)
                                        : v.scopesFor[role]?.contains("book:read") == true
            XCTAssertEqual(DeviceRole.mayHoldBook(role), holds, "\(role): the book is book:read")
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

    // MARK: End to end, against a stand-in Mac

    private var saved: (host: String, port: Int, pin: String, paired: Bool, sample: Bool, identity: String,
                        device: DeviceKey.Credential?, role: String?, byCode: Bool)?

    override func setUp() {
        let s = ConnectionSettings()
        saved = (s.host, s.port, s.pin, s.isPaired, s.isSampleShop, s.macIdentityKey, s.device, s.deviceRole, s.pairedByCode)
        StubPairMac.reset()
    }

    override func tearDown() {
        guard let saved else { return }
        let s = ConnectionSettings()
        s.host = saved.host; s.port = saved.port; s.pin = saved.pin; s.isPaired = saved.paired; s.isSampleShop = saved.sample
        s.macIdentityKey = saved.identity; s.device = saved.device; s.deviceRole = saved.role; s.pairedByCode = saved.byCode
        s.signedOutByMac = false; s.needsPairAgain = false
        StubPairMac.reset()
    }

    private func freshSettings() -> ConnectionSettings {
        let s = ConnectionSettings()
        s.host = "khayt-pair-stub.invalid"; s.port = 3219; s.isSampleShop = false; s.isPaired = false
        s.macIdentityKey = ""; s.device = nil; s.deviceRole = nil; s.pairedByCode = false
        // Digits typed on the PIN screen before choosing the number instead:
        // they must not throw the new enrolment away (review of #2630).
        s.pin = "1234"
        return s
    }

    func testPairingByNumberEndToEnd() async throws {
        let s = freshSettings()
        StubPairMac.role = "operator"
        let api = KhaytAPIClient(settings: s, protocols: [StubPairMac.self], withBook: false)
        guard case .number(let ticket) = await api.startCodePairing(name: "Workshop iPhone", version: "4.12") else {
            return XCTFail("a number to show")
        }
        XCTAssertEqual(ticket.check, StubPairMac.check, "the phone and the Mac show the same number")
        XCTAssertNil(StubPairMac.sentPin, "no PIN crosses the Wi-Fi")
        let first = await api.pollCodePairing(ticket)
        XCTAssertEqual(first, .waiting)
        StubPairMac.approved = true
        let second = await api.pollCodePairing(ticket)
        XCTAssertEqual(second, .approved)
        let done = await api.finishCodePairing(ticket)
        XCTAssertTrue(done)
        XCTAssertNotNil(s.device)
        XCTAssertEqual(s.device?.deviceId, StubPairMac.deviceId)
        XCTAssertEqual(s.macIdentityKey, StubPairMac.identity.publicKey.rawRepresentation.base64EncodedString())
        XCTAssertEqual(s.pin, "", "no PIN kept")
        XCTAssertTrue(s.isPaired)
        XCTAssertTrue(s.pairedByCode)
        XCTAssertEqual(s.deviceRole, "operator")
        XCTAssertFalse(s.mayHoldBook, "an operator phone is a floor phone")
        XCTAssertTrue(StubPairMac.selfSigned, "the approval was proved with a signed request")
    }

    func testAnApprovalThatIsNotProvedChangesNothing() async throws {
        let s = freshSettings()
        let api = KhaytAPIClient(settings: s, protocols: [StubPairMac.self], withBook: false)
        guard case .number(let ticket) = await api.startCodePairing(name: "x", version: "1") else { return XCTFail() }
        StubPairMac.approved = true
        StubPairMac.enrols = false              // "approved", but no such device on the Mac
        let done = await api.finishCodePairing(ticket)
        XCTAssertFalse(done)
        XCTAssertNil(s.device)
        XCTAssertFalse(s.pairedByCode)
        XCTAssertEqual(s.pin, "1234", "nothing changed")
    }

    /// The role is believed only from an answer the Mac signed: an unsigned
    /// one, or one whose MAC is over other words, pairs nothing.
    func testARoleAnswerTheMacDidNotSignIsNotBelieved() async throws {
        for signing in [StubPairMac.ReplySigning.unsigned, .forged] {
            StubPairMac.reset()
            StubPairMac.replySigning = signing
            StubPairMac.role = "owner"
            let s = freshSettings()
            let api = KhaytAPIClient(settings: s, protocols: [StubPairMac.self], withBook: false)
            guard case .number(let ticket) = await api.startCodePairing(name: "x", version: "1") else { return XCTFail() }
            StubPairMac.approved = true
            let done = await api.finishCodePairing(ticket)
            XCTAssertFalse(done, "\(signing)")
            XCTAssertNil(s.device, "\(signing)")
            XCTAssertNil(s.deviceRole, "\(signing)")
        }
    }

    /// #2631's answers to DELETE /api/devices/pair/<pairId>, as LAN_API.md writes them.
    func testTheCancelAnswersAreRead() {
        func a(_ status: Int, _ body: String) -> KhaytAPIClient.CodePairCancel {
            KhaytAPIClient.cancelAnswer(status: status, body: Data(body.utf8))
        }
        XCTAssertEqual(a(200, #"{"state":"cancelled"}"#), .cancelled)
        XCTAssertEqual(a(409, #"{"state":"approved"}"#), .approved)
        XCTAssertEqual(a(409, #"{"state":"denied"}"#), .denied)
        XCTAssertEqual(a(409, #"{"state":"expired"}"#), .expired)
        XCTAssertEqual(a(404, #"{"state":"unknown"}"#), .unknown)
        XCTAssertEqual(a(200, #"{"state":"approved"}"#), .unknown, "approved is only believed as the 409 the route sends")
        XCTAssertEqual(a(409, "[]"), .unknown)
        XCTAssertEqual(a(500, ""), .unknown)
    }

    /// Cancel while the number is up: the Mac drops it, and a later poll
    /// reads it as run out. A second cancel finds nothing to give up.
    func testCancellingTheNumberTellsTheMac() async throws {
        let s = freshSettings()
        let api = KhaytAPIClient(settings: s, protocols: [StubPairMac.self], withBook: false)
        guard case .number(let ticket) = await api.startCodePairing(name: "x", version: "1") else { return XCTFail() }
        let cancelled = await api.cancelCodePairing(ticket)
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertTrue(StubPairMac.cancelled)
        let after = await api.pollCodePairing(ticket)
        XCTAssertEqual(after, .expired)
        let again = await api.cancelCodePairing(ticket)
        XCTAssertEqual(again, .expired)
        XCTAssertNil(s.device, "a cancel pairs nothing")
        XCTAssertFalse(s.isPaired)
    }

    /// Too late: the Mac had approved. The cancel says so and the approval
    /// stands, so the phone finishes it (signed, proved) rather than leaving
    /// an enrolment on the Mac that no phone holds.
    func testACancelAfterTheMacApprovedFinishesThePairing() async throws {
        let s = freshSettings()
        StubPairMac.role = "viewer"
        let api = KhaytAPIClient(settings: s, protocols: [StubPairMac.self], withBook: false)
        guard case .number(let ticket) = await api.startCodePairing(name: "x", version: "1") else { return XCTFail() }
        StubPairMac.approved = true
        let answer = await api.cancelCodePairing(ticket)
        XCTAssertEqual(answer, .approved)
        let done = await api.finishCodePairing(ticket, markPaired: true)
        XCTAssertTrue(done)
        XCTAssertEqual(s.device?.deviceId, StubPairMac.deviceId)
        XCTAssertEqual(s.deviceRole, "viewer")
        XCTAssertTrue(StubPairMac.selfSigned)
    }

    /// A cancel that comes back "approved" is taken only when the person has
    /// not moved on (review of #2635): never over the PIN step, a PIN pairing
    /// in progress or a newer attempt.
    func testALateApprovalNeverTakesOverAnotherChoice() {
        let may = PairingView.mayFinishAfterCancel
        XCTAssertTrue(may(false, .find, false, true), "Cancel, back on Find: the approval is shown")
        XCTAssertTrue(may(false, .code, false, false), "the screen went away: finished, shown at the next open")
        XCTAssertFalse(may(false, .pin, false, true), "the person chose the PIN")
        XCTAssertFalse(may(false, .find, true, true), "a PIN pairing is running")
        XCTAssertFalse(may(true, .find, false, true), "a newer attempt started")
        XCTAssertFalse(may(true, .code, false, true), "a new number is up")
        XCTAssertFalse(may(false, .manual, false, true), "typing another address")
    }

    /// A wrong secret is the route's 404: nothing is given up, nothing changes.
    func testACancelWithAWrongSecretIsUnknown() async throws {
        let s = freshSettings()
        let api = KhaytAPIClient(settings: s, protocols: [StubPairMac.self], withBook: false)
        guard case .number(let ticket) = await api.startCodePairing(name: "x", version: "1") else { return XCTFail() }
        let forged = KhaytAPIClient.CodePairTicket(
            pairing: ticket.pairing,
            offer: try JSONDecoder().decode(PairOffer.self, from: JSONSerialization.data(withJSONObject: [
                "pairId": ticket.offer.pairId, "pollSecret": "pollsecret9999999999999999999999",
                "deviceId": ticket.offer.deviceId, "publicKey": ticket.offer.publicKey,
                "sig": ticket.offer.sig, "identity": ticket.offer.identity])),
            check: ticket.check)
        let answer = await api.cancelCodePairing(forged)
        XCTAssertEqual(answer, .unknown)
        XCTAssertFalse(StubPairMac.cancelled)
    }

    func testAnOlderMacFallsBackToThePin() async {
        let s = freshSettings()
        StubPairMac.hasRoute = false
        let api = KhaytAPIClient(settings: s, protocols: [StubPairMac.self], withBook: false)
        let older = await api.startCodePairing(name: "x", version: "1")
        XCTAssertEqual(older, .unsupported)
        StubPairMac.hasRoute = true
        StubPairMac.closed = true
        let shut = await api.startCodePairing(name: "x", version: "1")
        XCTAssertEqual(shut, .closed)
    }

    func testAPinPhoneIsTheOwnerWhateverAReplySays() async {
        let s = freshSettings()
        s.deviceRole = nil; s.pairedByCode = false
        let api = KhaytAPIClient(settings: s, protocols: [StubPairMac.self], withBook: false)
        StubPairMac.role = "viewer"
        await api.refreshDeviceRole()
        XCTAssertNil(s.deviceRole)
        XCTAssertEqual(s.effectiveRole, "owner")
        XCTAssertTrue(s.mayHoldBook)
    }
}

/// A Mac with `POST /api/devices/pair` (phone prefixes), its reveal and poll,
/// and a signed `GET /api/devices/self`.
final class StubPairMac: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var hasRoute = true
    nonisolated(unsafe) static var closed = false
    nonisolated(unsafe) static var approved = false
    nonisolated(unsafe) static var enrols = true
    nonisolated(unsafe) static var role: String? = "operator"
    nonisolated(unsafe) static var commit = ""
    nonisolated(unsafe) static var check = ""
    nonisolated(unsafe) static var key: SymmetricKey?
    nonisolated(unsafe) static var sentPin: String?
    nonisolated(unsafe) static var selfSigned = false
    nonisolated(unsafe) static var cancelled = false
    /// How the Mac signs its role answer: as #2631 does, not at all, or with
    /// a MAC that is not over this answer (a forgery).
    enum ReplySigning { case signed, unsigned, forged }
    nonisolated(unsafe) static var replySigning = ReplySigning.signed
    static let identity = Curve25519.Signing.PrivateKey()
    nonisolated(unsafe) static var server = Curve25519.KeyAgreement.PrivateKey()
    static let deviceId = "dev_stubCodePhone01"
    static let pairId = "pairid000001"
    static let poll = "pollsecret0000000000000000000001"

    static func reset() {
        hasRoute = true; closed = false; approved = false; enrols = true; role = "operator"; commit = ""; check = ""
        key = nil; sentPin = nil; selfSigned = false; server = Curve25519.KeyAgreement.PrivateKey()
        replySigning = .signed; cancelled = false
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "khayt-pair-stub.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let b = request.httpBody { return b }
        guard let s = request.httpBodyStream else { return nil }
        s.open(); defer { s.close() }
        var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
        return d
    }

    override func startLoading() {
        let url = request.url!
        let path = url.path()
        let body = Self.body(of: request)
        if let pin = request.value(forHTTPHeaderField: "x-khayt-pin") { Self.sentPin = pin }
        let obj = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let serverPub = Self.server.publicKey.rawRepresentation.base64EncodedString()
        let idPub = Self.identity.publicKey.rawRepresentation.base64EncodedString()
        var answer: (Int, Any) = (404, ["error": "not found"])
        var replyMacFor: (SymmetricKey, String)?
        switch (request.httpMethod ?? "GET", path) {
        case ("POST", "/api/devices/pair") where Self.hasRoute:
            if Self.closed { answer = (403, ["reason": "pairing-closed"]); break }
            Self.commit = obj["commit"] as? String ?? ""
            let sig = try! Self.identity.signature(for: PairCode.offerMessage(.phone, deviceId: Self.deviceId,
                                                                               serverPublic: serverPub, commit: Self.commit))
            answer = (200, ["pairId": Self.pairId, "pollSecret": Self.poll, "deviceId": Self.deviceId,
                            "publicKey": serverPub, "sig": sig.base64EncodedString(), "identity": idPub])
        case ("POST", "/api/devices/pair/\(Self.pairId)/reveal") where request.value(forHTTPHeaderField: "x-khayt-poll") == Self.poll:
            let pub = obj["publicKey"] as? String ?? "", nonce = obj["nonce"] as? String ?? ""
            guard PairCode.commit(.phone, publicKey: pub, nonce: nonce) == Self.commit,
                  let raw = Data(base64Encoded: pub),
                  let phonePub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw),
                  let shared = try? Self.server.sharedSecretFromKeyAgreement(with: phonePub) else {
                answer = (403, ["state": "expired", "reason": "bad-reveal"]); break
            }
            Self.check = PairCode.check(.phone, deviceId: Self.deviceId, identity: idPub, serverPublic: serverPub,
                                        clientPublic: pub, nonce: nonce)
            Self.key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: DeviceKey.salt,
                                                      sharedInfo: Data(Self.deviceId.utf8), outputByteCount: 32)
            answer = (200, ["state": "waiting"])
        case ("GET", "/api/devices/pair/\(Self.pairId)") where request.value(forHTTPHeaderField: "x-khayt-poll") == Self.poll:
            answer = (200, ["state": Self.cancelled ? "expired" : Self.approved ? "approved" : "waiting"])
        // #2631: the phone gives its own request up; an approval is not undone.
        case ("DELETE", "/api/devices/pair/\(Self.pairId)") where request.value(forHTTPHeaderField: "x-khayt-poll") == Self.poll:
            if Self.approved { answer = (409, ["state": "approved"]) }
            else if Self.cancelled { answer = (409, ["state": "expired"]) }
            else { Self.cancelled = true; answer = (200, ["state": "cancelled"]) }
        case ("DELETE", _) where path.hasPrefix("/api/devices/pair/"):
            answer = (404, ["state": "unknown"])
        case ("GET", "/api/devices/self"):
            guard Self.enrols, let key = Self.key, request.value(forHTTPHeaderField: "x-khayt-device") == Self.deviceId else {
                answer = (401, ["reason": "device-unknown"]); break
            }
            let canonical = DeviceKey.canonical(method: "GET", target: DeviceKey.requestTarget(url),
                                                time: Int(request.value(forHTTPHeaderField: "x-khayt-time") ?? "") ?? 0,
                                                nonce: request.value(forHTTPHeaderField: "x-khayt-nonce") ?? "", body: body)
            let expected = Data(HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)).base64EncodedString()
            guard expected == request.value(forHTTPHeaderField: "x-khayt-mac") else { answer = (401, ["reason": "device-auth"]); break }
            Self.selfSigned = true
            answer = (200, ["deviceId": Self.deviceId, "role": Self.role.map { $0 as Any } ?? NSNull()])
            replyMacFor = (key, request.value(forHTTPHeaderField: "x-khayt-nonce") ?? "")
        default: break
        }
        let data = try! JSONSerialization.data(withJSONObject: answer.1)
        var fields = ["Content-Type": "application/json"]
        // The reply MAC as docs/LAN_API.md writes it, worked out here on its
        // own rather than with the phone's DeviceKey.replyMac.
        if let (key, nonce) = replyMacFor, Self.replySigning != .unsigned {
            let signedBody = Self.replySigning == .forged ? Data(#"{"role":"owner"}"#.utf8) : data
            let hex = SHA256.hash(data: signedBody).map { String(format: "%02x", $0) }.joined()
            let text = "khayt-reply-v1\n\(nonce)\n\(answer.0)\n\(hex)"
            fields["x-khayt-reply-mac"] = Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key))
                .base64EncodedString()
        }
        let response = HTTPURLResponse(url: url, statusCode: answer.0, httpVersion: "HTTP/1.1",
                                       headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
