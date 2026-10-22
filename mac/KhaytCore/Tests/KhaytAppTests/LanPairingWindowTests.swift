import Foundation
import Testing
import CryptoKit
import KhaytWidgetData
@testable import KhaytApp

/// A phone enrols only while the owner has opened "Pair a phone" on the Mac,
/// so a stranger guessing the PIN on the Wi-Fi cannot hold a new phone out
/// (beta.1 security review, Oct 2026). See `LanPairingWindow`.
@MainActor
struct LanPairingWindowTests {

    static let pin = "24682468"

    static func ask() -> (Curve25519.KeyAgreement.PrivateKey, String) {
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let key = phone.publicKey.rawRepresentation.base64EncodedString()
        return (phone, #"{"publicKey":"\#(key)","name":"Bench phone"}"#)
    }

    static func enrol(_ bench: LanServerTests.Bench, pin: String = LanPairingWindowTests.pin) async throws
        -> LanServerTests.Bench.Reply {
        try await bench.post("/api/devices", json: ask().1, headers: ["x-khayt-pin": pin])
    }

    // MARK: - The window alone, on its own clock

    @Test("the window opens for two minutes, counts down, and shuts by itself on time")
    func windowClock() {
        let box = LanServerTests.ClockBox(Date(timeIntervalSince1970: 1_800_000_000))
        let window = LanPairingWindow(now: { box.now })
        #expect(!window.isOpen() && window.remaining() == nil && window.lastClosed == nil, "closed until opened")
        window.open()
        #expect(window.isOpen())
        #expect(window.remaining() == 120)
        box.now = box.now.addingTimeInterval(119.5)
        #expect(window.isOpen() && window.remaining() == 1)
        box.now = box.now.addingTimeInterval(0.5)
        #expect(!window.isOpen(), "shut at the deadline, not a tick after")
        #expect(window.lastClosed == .timedOut && window.until == nil)
    }

    @Test("closed by the owner, by a pairing, or by many wrong PINs from many addresses, and said which")
    func windowCloses() {
        let window = LanPairingWindow()
        window.open(); window.close()
        #expect(!window.isOpen() && window.lastClosed == .byOwner)
        window.open(); window.paired(name: "Turki's iPhone")
        #expect(!window.isOpen() && window.lastClosed == .paired(name: "Turki's iPhone"))

        window.open()
        for _ in 0..<(LanPairingWindow.perAddress * 4) { #expect(!window.noteWrong(from: "192.168.1.66")) }
        #expect(window.isOpen(), "one address, however many guesses, never closes it")
        #expect(window.lockedOut("192.168.1.66") && !window.lockedOut("192.168.1.20"))
        #expect(window.lockedAddresses == 1)
        window.open()
        #expect(window.wrong == 0 && !window.lockedOut("192.168.1.66"), "a new window starts its own count")

        var closed = false
        for i in 0..<LanPairingWindow.maxWrong { closed = window.noteWrong(from: "10.0.0.\(i % 10)") }
        #expect(closed && !window.isOpen() && window.lastClosed == .tooManyWrong)
    }

    @Test("the numbers: five an address, fifty in all, and that bounds a guesser at 1 in 2 million a window")
    func theNumbers() {
        #expect(LanPairingWindow.perAddress == 5 && LanPairingWindow.maxWrong == 50)
        #expect(LanPairingWindow.maxWrong / LanPairingWindow.perAddress == 10, "addresses needed to close it")
        let pins = pow(10, Double(LanServer.minimumPin))
        #expect(Double(LanPairingWindow.maxWrong) / pins <= 5e-7)
    }

    @Test("the countdown is in Western digits for Arabic, and each ending is worded")
    func shownToTheShop() {
        let ar = Digits.locale(language: "ar", followsMac: false)
        #expect(PairAPhone.clock(105, locale: ar) == "1:45")
        #expect(PairAPhone.clock(-3, locale: ar) == "0:00")
        let words = Words()
        #expect(PairAPhone.outcome(nil, words: words) == nil)
        #expect(PairAPhone.outcome(.byOwner, words: words) == nil)
        #expect(PairAPhone.outcome(.paired(name: "Bench"), words: words)?.text.contains("Bench") == true)
        #expect(PairAPhone.outcome(.tooManyWrong, words: words)?.warn == true)
        for key in ["mac.pair_open", "mac.pair_waiting", "mac.pair_open_hint", "mac.pair_done",
                    "mac.pair_timed_out", "mac.pair_too_many", "mac.pair_locked_some"] {
            #expect(Words.own[key]?["en"]?.isEmpty == false && Words.own[key]?["ar"]?.isEmpty == false, "\(key)")
        }
    }

    // MARK: - Over the wire

    @Test("outside the window: refused at once, the same answer for a right PIN and a wrong one, and nothing counted")
    func refusedOutside() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        let right = try await Self.enrol(bench)
        let wrong = try await Self.enrol(bench, pin: "00000000")
        let none = try await bench.post("/api/devices", json: Self.ask().1)
        for reply in [right, wrong, none] {
            #expect(reply.status == 403)
            #expect(reply.text.contains(#""reason":"pairing-closed""#))
        }
        #expect(right.text == wrong.text && wrong.text == none.text, "the answer says nothing about the PIN")
        // Far past the lockout: none of it was counted.
        for _ in 0..<20 { _ = try await Self.enrol(bench, pin: "00000000") }
        #expect(try await bench.get("/api/queue", headers: ["x-khayt-pin": Self.pin]).status == 200)
        #expect(bench.devices.count == 0)
    }

    @Test("inside the window: the PIN enrols the phone, and the window closes behind it")
    func acceptedInsideThenCloses() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        bench.pairing.open()
        #expect(try await bench.post("/api/devices", json: Self.ask().1).status == 401, "still needs the PIN")
        let reply = try await Self.enrol(bench)
        #expect(reply.status == 200)
        #expect(bench.devices.count == 1)
        #expect(bench.pairing.lastClosed == .paired(name: "Bench phone"))
        let second = try await Self.enrol(bench)
        #expect(second.status == 403 && second.text.contains("pairing-closed"), "one phone per window")
        #expect(bench.devices.count == 1)
    }

    @Test("the window times out on the server's clock, and the owner can close it early")
    func timesOutAndClosesEarly() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        bench.pairing.open()
        bench.advance(seconds: LanPairingWindow.length + 1)
        let late = try await Self.enrol(bench)
        #expect(late.status == 403 && late.text.contains("pairing-closed"))
        #expect(bench.pairing.lastClosed == .timedOut)

        bench.pairing.open()
        bench.pairing.close()
        #expect(try await Self.enrol(bench).status == 403)
        #expect(bench.pairing.lastClosed == .byOwner)
        #expect(bench.devices.count == 0)
    }

    @Test("guesses made outside the window do not lock out the phone paired inside it")
    func outsideGuessesDoNotLockOut() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        for _ in 0..<12 { _ = try await bench.get("/api/queue", headers: ["x-khayt-pin": "00000000"]) }
        #expect(try await bench.get("/api/queue", headers: ["x-khayt-pin": Self.pin]).status == 429,
                "the guesser has locked the PIN out")
        bench.pairing.open()
        // The phone's whole pairing: its PIN check, the Mac's key, its enrolment.
        #expect(try await bench.get("/api/queue", headers: ["x-khayt-pin": Self.pin]).status == 200)
        #expect(try await bench.get("/api/identity", headers: ["x-khayt-pin": Self.pin]).status == 200)
        #expect(try await Self.enrol(bench).status == 200)
        #expect(bench.devices.count == 1)
    }

    @Test("five wrong PINs shut one address out of the window, and the window stays open")
    func oneAddressLockedOut() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        bench.pairing.open()
        for _ in 0..<LanPairingWindow.perAddress {
            #expect(try await Self.enrol(bench, pin: "00000000").status == 401)
        }
        let locked = try await Self.enrol(bench)
        #expect(locked.status == 429)
        #expect(locked.text == LanPairingWindow.lockedBody, "the right PIN is not even looked at")
        #expect(bench.pairing.isOpen())
        #expect(bench.devices.count == 0)
    }

    // MARK: - Several addresses, straight into the router

    static func server(_ window: LanPairingWindow) async throws -> (LanServer, LanDevices) {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let store = shop.lanBook
        let devices = LanDevices.inMemory()
        var host = LanServer.Host(store: { store }, pin: pin, engine: engine)
        host.devices = devices
        host.pairing = window
        let identity = Curve25519.Signing.PrivateKey()
        host.identity = { identity }
        return (LanServer(host: host), devices)
    }

    static func enrol(_ server: LanServer, from remote: String, pin: String) async -> LanServer.Response {
        await server.respond(to: LanServer.Request(
            method: "POST", path: "/api/devices", query: [:],
            headers: ["host": "192.168.1.20:3219", "content-type": "application/json", "x-khayt-pin": pin],
            body: Data(ask().1.utf8), remote: remote))
    }

    @Test("one address guessing five times and more does not stop a second address pairing in the same window")
    func guesserDoesNotBlockAnotherAddress() async throws {
        let window = LanPairingWindow()
        let (server, devices) = try await Self.server(window)
        window.open()
        for i in 0..<(LanPairingWindow.perAddress + 3) {
            _ = await Self.enrol(server, from: "192.168.1.66", pin: "guess-\(i)00")
        }
        let guesser = await Self.enrol(server, from: "192.168.1.66", pin: Self.pin)
        #expect(guesser.status == 429, "the guesser is out of this window, even with the right PIN")
        #expect(window.isOpen())
        let phone = await Self.enrol(server, from: "192.168.1.31", pin: Self.pin)
        #expect(phone.status == 200, "the shop's phone, on its own address, pairs")
        #expect(devices.count == 1)
        #expect(window.lastClosed == .paired(name: "Bench phone"))
    }

    @Test("only fifty wrong PINs from ten addresses close the window for everyone")
    func manyAddressesClose() async throws {
        let window = LanPairingWindow()
        let (server, devices) = try await Self.server(window)
        window.open()
        for i in 0..<(LanPairingWindow.maxWrong - 1) {
            _ = await Self.enrol(server, from: "10.0.0.\(i % 10 + 1)", pin: "guess-\(i)00")
        }
        #expect(window.isOpen(), "forty-nine is not yet fifty")
        _ = await Self.enrol(server, from: "10.0.0.11", pin: "guess-last")
        #expect(!window.isOpen() && window.lastClosed == .tooManyWrong)
        let phone = await Self.enrol(server, from: "192.168.1.31", pin: Self.pin)
        #expect(phone.status == 403 && String(decoding: phone.body, as: UTF8.self).contains("pairing-closed"))
        #expect(devices.count == 0)
    }

    @Test("a phone that already enrolled keeps working with the window closed")
    func enrolledPhoneUnaffected() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        bench.pairing.open()
        let (phone, ask) = Self.ask()
        let reply = try await bench.post("/api/devices", json: ask, headers: ["x-khayt-pin": Self.pin])
        let body = try #require(try JSONSerialization.jsonObject(with: reply.body) as? [String: String])
        let id = try #require(body["deviceId"]), serverPublic = try #require(body["publicKey"])
        let key = try #require(LanDevices.derive(
            phone, try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(base64Encoded: serverPublic)!),
            deviceId: id))
        #expect(!bench.pairing.isOpen())
        let now = Int(LanServerTests.Bench.start.timeIntervalSince1970)
        let nonce = String(repeating: "ab", count: 16)
        let c = LanDevices.canonical(method: "GET", target: "/api/queue", time: String(now), nonce: nonce, body: Data())
        let headers = LanDeviceKeysTests.signed(id, mac: LanDevices.mac(key: key, canonical: c).base64EncodedString(),
                                                nonce: nonce, time: now)
        #expect(try await bench.get("/api/queue", headers: headers).status == 200)
    }
}
