import XCTest
import KhaytCore
@testable import KhaytCompanion

/// An owner's phone flipping the shop's "Make no internet calls" through the
/// Mac (`POST /api/network/switch`, Mac #2677; iPhone frames 1A/1B). Sample
/// data only: the request the phone builds, how it reads each answer, when
/// the owner's control shows, and what the page says.
@MainActor
final class NetworkSwitchTests: XCTestCase {

    private func json(_ data: Data) throws -> [String: JSONValue] {
        guard case .object(let o) = try JSONDecoder().decode(JSONValue.self, from: data) else { throw XCTSkip("not an object") }
        return o
    }

    // MARK: - The request

    func testTheRequestSaysWhatThePhoneWasShowing() throws {
        let showing = ShopNetwork(offline: true, keep: ["cloud", "email"], changedAt: "2026-11-22T14:12:00.000Z")
        let o = try json(NetworkSwitch.body(offline: false, showing: showing))
        XCTAssertEqual(o["offline"], .bool(false))
        XCTAssertEqual(o["seen"], .string("2026-11-22T14:12:00.000Z"))
        XCTAssertEqual(o["seenKeep"], .array([.string("cloud"), .string("email")]), "the keep list the person confirmed against")
        XCTAssertNil(o["keep"], "the phone never edits the list: leaving it out leaves the shop's as it is")
        XCTAssertLessThan(NetworkSwitch.body(offline: false, showing: showing).count, 4096)
    }

    func testAPhoneThatHasSeenNoStampSendsNone() throws {
        let never = try json(NetworkSwitch.body(offline: true, showing: nil))
        XCTAssertEqual(never["offline"], .bool(true))
        XCTAssertNil(never["seen"])
        XCTAssertEqual(never["seenKeep"], .array([]), "nothing shown as kept")
        let unstamped = try json(NetworkSwitch.body(offline: true, showing: ShopNetwork(offline: false, keep: ["cloud"])))
        XCTAssertNil(unstamped["seen"])
        XCTAssertEqual(unstamped["seenKeep"], .array([.string("cloud")]))
    }

    // MARK: - The book's value

    func testTheSwitchIsReadFromTheBooksSettings() {
        let network: JSONValue = .object(["offline": .bool(true), "keep": .array([.string("cloud"), .number(3)]),
                                          "changedAt": .string("2026-11-22T14:12:00.000Z"), "changedBy": .string("Sample iPhone")])
        let got = ShopNetwork.current(.settings(.object(["network": network])))
        XCTAssertEqual(got, ShopNetwork(offline: true, keep: ["cloud"], changedAt: "2026-11-22T14:12:00.000Z", changedBy: "Sample iPhone"))
        XCTAssertNil(ShopNetwork.current(.settings(.object([:]))), "never set")
        XCTAssertNil(ShopNetwork.current(.none))
        XCTAssertNil(ShopNetwork.current(.unread))
        XCTAssertNil(ShopNetwork(.object(["offline": .string("yes")])), "a malformed switch is not something the phone saw")
    }

    // MARK: - The Mac's answers

    private func answer(_ status: Int, _ body: String, verified: Bool = true) -> NetworkSwitch.Outcome {
        NetworkSwitch.outcome(status: status, body: Data(body.utf8), verified: verified)
    }

    func testEachAnswerTheRouteGives() {
        let net = #"{"offline":true,"keep":["cloud"],"changedAt":"2026-11-24T09:00:00.000Z","changedBy":"Sample iPhone"}"#
        let value = ShopNetwork(offline: true, keep: ["cloud"], changedAt: "2026-11-24T09:00:00.000Z", changedBy: "Sample iPhone")
        XCTAssertEqual(answer(200, #"{"ok":true,"network":\#(net)}"#), .done(value))
        XCTAssertEqual(answer(409, #"{"ok":false,"reason":"changed","network":\#(net)}"#), .changed(value))
        XCTAssertEqual(answer(409, #"{"ok":false,"reason":"not-saved","network":\#(net)}"#), .notSaved(value))
        XCTAssertEqual(answer(409, #"{"ok":false,"reason":"read-only"}"#), .readOnly)
        XCTAssertEqual(answer(503, #"{"ok":false,"reason":"busy"}"#), .busy)
        XCTAssertEqual(answer(403, #"{"reason":"role-scope","required":"owner"}"#), .notOwner)
        XCTAssertEqual(answer(400, #"{"ok":false,"reason":"bad-keep"}"#), .failed)
        XCTAssertEqual(answer(403, #"{"ok":false,"reason":"device-key-required"}"#), .failed)
        XCTAssertEqual(answer(200, #"{"ok":true}"#), .failed, "done without the value is not done")
        XCTAssertEqual(answer(200, #"{"ok":false,"network":\#(net)}"#), .failed)
        XCTAssertEqual(answer(200, "not json"), .failed)
    }

    /// "Done" only when the Mac signed the answer: nothing an unsigned body
    /// says is believed. A 404 is an older computer, which signs nothing.
    func testAnUnsignedAnswerIsNeverDone() {
        let net = #"{"ok":true,"network":{"offline":false,"keep":[]}}"#
        XCTAssertEqual(answer(200, net, verified: false), .unverified)
        XCTAssertEqual(answer(409, #"{"ok":false,"reason":"changed"}"#, verified: false), .unverified)
        XCTAssertEqual(answer(403, #"{"reason":"role-scope"}"#, verified: false), .unverified)
        XCTAssertEqual(answer(404, "", verified: false), .unsupported)
        XCTAssertEqual(answer(404, "", verified: true), .unsupported)
    }

    /// The reply MAC the client checks is the one `/api/devices/self` uses:
    /// over this request's nonce, the status and the body.
    func testTheReplyMacBindsNonceStatusAndBody() throws {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let device = DeviceKey.Credential(deviceId: "dev_sample", key: key, identityKey: "sample-identity")
        let body = Data(#"{"ok":true,"network":{"offline":true,"keep":[]}}"#.utf8)
        let mac = try XCTUnwrap(DeviceKey.replyMac(key: key, nonce: "n-1", status: 200, body: body))
        XCTAssertTrue(DeviceKey.replyVerifies(device, nonce: "n-1", status: 200, body: body, header: mac))
        XCTAssertFalse(DeviceKey.replyVerifies(device, nonce: "n-2", status: 200, body: body, header: mac), "another request's answer")
        XCTAssertFalse(DeviceKey.replyVerifies(device, nonce: "n-1", status: 409, body: body, header: mac))
        XCTAssertFalse(DeviceKey.replyVerifies(device, nonce: "n-1", status: 200, body: Data("{}".utf8), header: mac))
        XCTAssertFalse(DeviceKey.replyVerifies(device, nonce: "n-1", status: 200, body: body, header: nil))
    }

    func testEveryOutcomeButDoneHasWords() {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        XCTAssertNil(NetworkSwitch.words(.done(ShopNetwork(offline: true))), "the switch itself says it")
        for outcome: NetworkSwitch.Outcome in [.changed(nil), .notSaved(nil), .readOnly, .busy, .notOwner, .unsupported, .unverified, .failed] {
            let words = NetworkSwitch.words(outcome) ?? ""
            XCTAssertFalse(words.isEmpty || words.hasPrefix("internet."), "\(outcome)")
        }
        XCTAssertEqual(NetworkSwitch.words(.unverified), NetworkSwitch.words(.failed), "never 'done', never a different promise")
    }

    // MARK: - When the owner's control shows

    func testCanIsReadFromTheMacsAnswer() {
        XCTAssertEqual(NetworkSwitch.can(.object(["role": .string("owner"), "can": .array([.string("network-switch")])])), ["network-switch"])
        XCTAssertEqual(NetworkSwitch.can(.object(["can": .array([.string("network-switch"), .number(1), .string("later-thing")])])),
                       ["network-switch", "later-thing"])
        XCTAssertEqual(NetworkSwitch.can(.object(["role": .string("owner")])), [], "an older Mac sends no list")
        XCTAssertEqual(NetworkSwitch.can(.object(["can": .string("network-switch")])), [], "not a list")
        XCTAssertEqual(NetworkSwitch.can(nil), [])
    }

    func testTheControlShowsOnlyForAnOwnerInReachOfAMacThatServesIt() {
        let can: Set<String> = [NetworkSwitch.capability]
        XCTAssertTrue(NetworkSwitch.mayChange(role: "owner", can: can, macInReach: true, sampleShop: false))
        for role in ["manager", "operator", "viewer", ""] {
            XCTAssertFalse(NetworkSwitch.mayChange(role: role, can: can, macInReach: true, sampleShop: false), role)
        }
        XCTAssertFalse(NetworkSwitch.mayChange(role: "owner", can: [], macInReach: true, sampleShop: false), "the Mac did not say so")
        XCTAssertFalse(NetworkSwitch.mayChange(role: "owner", can: ["something-else"], macInReach: true, sampleShop: false))
        XCTAssertFalse(NetworkSwitch.mayChange(role: "owner", can: can, macInReach: false, sampleShop: false), "the route is the shop's Wi-Fi only")
        XCTAssertFalse(NetworkSwitch.mayChange(role: "owner", can: can, macInReach: true, sampleShop: true))
    }

    // MARK: - What the page shows (the gate's own answers)

    private func model(_ network: JSONValue?, blocked: [OutboundPurpose: OutboundGate.Blocked] = [:],
                       countInstall: Bool = false, countReady: Bool = true) -> InternetUseModel {
        let gate = OutboundGate()
        var settings: [String: JSONValue] = [:]
        if let network { settings["network"] = network }
        gate.update(book: .settings(.object(settings)))
        gate.update(local: .init(offline: false, installCountOff: !countInstall))
        return InternetUseModel.make(shopOffline: gate.isShopOffline, rows: gate.rows(), blocked: blocked,
                                     countInstall: countInstall, countReady: countReady, clock: { _ in "14:12" })
    }

    func testFrame1ATheSwitchOnWithKhaytCloudKept() {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        let m = model(.object(["offline": .bool(true), "keep": .array([.string("cloud")])]),
                      blocked: [.lookups: .init(count: 2, last: Date(timeIntervalSince1970: 1_795_000_000))])
        XCTAssertTrue(m.switchOn)
        XCTAssertEqual(m.lines.map(\.id), ["cloud", "lookups", "install-count"])
        XCTAssertEqual(m.lines[0].state, .kept)
        XCTAssertEqual(m.lines[0].title, "Khayt Cloud")
        XCTAssertEqual(m.lines[0].sub, "Kept on the Mac: photos and sync keep working.")
        XCTAssertEqual(m.lines[1].state, .blocked)
        XCTAssertEqual(m.lines[1].sub, "Blocked 2 times, last at 14:12")
        XCTAssertEqual(m.lines[2].state, .off)
        XCTAssertEqual(m.lines[2].sub, "This phone's own setting. Anyone can turn it off; only the owner can turn it on.")
    }

    func testTheSwitchOffEverythingIsAllowed() {
        let m = model(.object(["offline": .bool(false)]), countInstall: true)
        XCTAssertFalse(m.switchOn)
        XCTAssertEqual(m.lines.map(\.state), [.allowed, .allowed, .on])
        XCTAssertEqual(model(nil).switchOn, false, "never set is off")
    }

    func testTheSwitchOnWithNothingKeptBlocksBoth() {
        let m = model(.object(["offline": .bool(true)]))
        XCTAssertEqual(m.lines.prefix(2).map(\.state), [.blocked, .blocked])
        XCTAssertFalse(m.lines[1].sub.contains("%"), "no count yet: the plain sentence")
    }

    /// A malformed switch reads as ON, as the rule reads it: the page never
    /// shows a shop as online on a value it could not read.
    func testAMalformedSwitchShowsOn() {
        XCTAssertTrue(model(.string("yes")).switchOn)
        XCTAssertEqual(model(.string("yes")).lines.first?.state, .blocked)
    }

    func testTheInstallCountLineOnlyWhenThePhoneCountsAtAll() {
        XCTAssertEqual(model(.object(["offline": .bool(false)]), countReady: false).lines.map(\.id), ["cloud", "lookups"])
    }

    // MARK: - Words

    func testEveryWordIsInAllNineLanguages() throws {
        let keys = ["internet.title", "internet.switch", "internet.switch.hint", "internet.foot.readonly", "internet.foot.owner",
                    "internet.uses", "internet.cloud.kept", "internet.cloud.allowed", "internet.cloud.blocked", "internet.lookups",
                    "internet.lookups.sub", "internet.lookups.blocked", "internet.blocked_times", "internet.install",
                    "internet.install.sub", "internet.state.allowed", "internet.state.kept", "internet.state.blocked",
                    "internet.state.on", "internet.state.off", "internet.confirm.eyebrow", "internet.confirm.off.title",
                    "internet.confirm.off.body", "internet.confirm.on.title", "internet.confirm.on.body", "internet.turn_off",
                    "internet.turn_on", "internet.result.changed", "internet.result.not_saved", "internet.result.read_only",
                    "internet.result.busy", "internet.result.not_owner", "internet.result.failed"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for lang in ["en", "ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            let url = root.appending(path: "KhaytCompanion/Resources/\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
            for key in keys {
                let value = table[key] ?? ""
                XCTAssertFalse(value.isEmpty, "\(lang): \(key)")
            }
            let times = table["internet.blocked_times"] ?? ""
            XCTAssertTrue(times.contains("%d") && times.contains("%@"), "\(lang): the count and the time")
            XCTAssertLessThan(times.range(of: "%d")!.lowerBound, times.range(of: "%@")!.lowerBound, "\(lang): count first")
        }
    }

    /// The index row leads to the page, in the Shop group, and a search finds it.
    func testSettingsHasTheRow() {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        XCTAssertEqual(SettingsRoute.internet.group, .shop)
        XCTAssertEqual(SettingsRoute.internet.destination, .page)
        XCTAssertEqual(L10n.tr(SettingsRoute.internet.titleKey), "Internet use")
        XCTAssertTrue(SettingsRoute.internet.searchLabels().contains("Make no internet calls"))
    }
}
