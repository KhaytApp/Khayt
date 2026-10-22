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

    @Test("closed by the owner, by a pairing, or by too many wrong PINs, and said which")
    func windowCloses() {
        let window = LanPairingWindow()
        window.open(); window.close()
        #expect(!window.isOpen() && window.lastClosed == .byOwner)
        window.open(); window.paired(name: "Turki's iPhone")
        #expect(!window.isOpen() && window.lastClosed == .paired(name: "Turki's iPhone"))
        window.open()
        for _ in 1..<LanPairingWindow.maxWrong { #expect(!window.noteWrong()) }
        #expect(window.isOpen())
        #expect(window.noteWrong())
        #expect(!window.isOpen() && window.lastClosed == .tooManyWrong)
        window.open()
        #expect(window.wrong == 0, "a new window starts its own count")
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
                    "mac.pair_timed_out", "mac.pair_too_many"] {
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

    @Test("too many wrong PINs inside the window close it, rather than hand out guesses")
    func wrongInsideCloses() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        bench.pairing.open()
        for _ in 0..<LanPairingWindow.maxWrong {
            #expect(try await Self.enrol(bench, pin: "00000000").status == 401)
        }
        #expect(bench.pairing.lastClosed == .tooManyWrong)
        #expect(try await Self.enrol(bench).status == 403)
        #expect(bench.devices.count == 0)
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
