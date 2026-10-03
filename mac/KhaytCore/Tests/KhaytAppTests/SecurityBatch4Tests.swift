import Foundation
import Testing
@testable import KhaytApp
@testable import KhaytCore

/// The September scan's fourth batch: what reaches the book over the network,
/// what a camera is handed, what a Bambu is trusted with.
struct SecurityBatch4Tests {

    @Test("only an address, localhost or a .local name may reach the PIN-gated book (DNS rebinding)")
    func hostHeader() {
        for ok in ["192.168.1.20:3219", "192.168.1.20", "localhost:3219", "127.0.0.1", "[::1]:3219",
                   "[fe80::1]", "Khayt-Mac.local:3219", "shop-mac.local.", nil, ""] as [String?] {
            #expect(LanServer.hostIsLocal(ok), "\(ok ?? "nil")")
        }
        for bad in ["evil.example:3219", "evil.example", "192.168.1.20.evil.example", "local", "[evil]:1",
                    "localhost.evil.example"] {
            #expect(!LanServer.hostIsLocal(bad), "\(bad)")
        }
    }

    @Test("a wrong PIN counts against the IPv6 /64, not the single address")
    func throttleKeys() {
        #expect(LanServer.throttleKey("192.168.1.5") == "192.168.1.5")
        let a = LanServer.throttleKey("2001:db8:1:2:aaaa::1")
        let b = LanServer.throttleKey("2001:db8:1:2:bbbb::9%en0")
        let c = LanServer.throttleKey("2001:db8:1:3::1")
        #expect(a == b, "two addresses in one /64 are one attacker")
        #expect(a != c)
        #expect(LanServer.throttleKey("::ffff:192.168.1.5") == "192.168.1.5")
    }

    @Test("the whole server's wrong-PIN budget is the shared rule's: 50 a minute, then a cooldown")
    func globalThrottle() async throws {
        let engine = try KhaytEngine()
        var state = KhaytEngine.LanThrottle()
        let now = Date()
        var blocked = false
        for _ in 0..<50 {
            let r = try await engine.lanGlobalThrottle(state, now: now, failed: true)
            state = r.state; blocked = r.blocked
        }
        #expect(blocked, "the fiftieth failure starts the cooldown")
        #expect(try await engine.lanGlobalThrottle(state, now: now, failed: false).blocked,
                "a RIGHT PIN during the cooldown is refused too — that is the point of it")
        #expect(try await !engine.lanGlobalThrottle(state, now: now.addingTimeInterval(61), failed: false).blocked)
    }

    @Test("an upload inflates to at most its budget, whatever sizes it claims")
    func inflateBudget() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bomb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 20 << 20).write(to: dir.appending(path: "zeros.bin"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q", "bomb.zip", "zeros.bin"]
        p.currentDirectoryURL = dir
        try p.run(); p.waitUntilExit()
        let zip = dir.appending(path: "bomb.zip")
        let size = try Data(contentsOf: zip).count
        let entry = try #require(try Zip.entries(of: zip).first)
        var seen = 0
        #expect(throws: (any Error).self) {
            try Zip.$inflateBudget.withValue(size * 250) {
                try Zip.stream(entry, in: zip) { seen += $0.count; return true }
            }
        }
        #expect(seen <= size * 250 + (1 << 20), "it stopped at the budget, not at 20 MB")
        seen = 0
        try Zip.stream(entry, in: zip) { seen += $0.count; return true }
        #expect(seen == 20 << 20, "without a budget — the shop's own files — it reads to the end")
    }

    @Test("a camera gets the printer's credential only when it IS the printer")
    func cameraCredential() {
        let api: JSONValue = .object(["type": .string("octoprint"), "host": .string("192.168.1.40:5000"), "apiKey": .string("k")])
        #expect(Camera.samePrinterHost(URL(string: "http://192.168.1.40/webcam/?action=snapshot")!, printerApi: api))
        #expect(Camera.samePrinterHost(URL(string: "http://192.168.1.40:8080/snap.jpg")!, printerApi: api))
        #expect(!Camera.samePrinterHost(URL(string: "http://192.168.1.41/snap.jpg")!, printerApi: api))
        #expect(!Camera.samePrinterHost(URL(string: "http://192.168.1.40.nip.io/snap.jpg")!, printerApi: api))
        #expect(!Camera.samePrinterHost(URL(string: "http://192.168.1.40/")!, printerApi: .object([:])))
    }

    @Test("a Bambu's certificate is kept the first time and a different one refused, until re-trusted")
    func bambuPin() {
        let key = BambuPin.key(serial: "TEST-\(UUID().uuidString)", host: "192.168.1.50")
        let store = BambuPin.Store.memory()
        #expect(BambuPin.accept("aaaa", key: key, in: store), "first sight: trusted and remembered")
        #expect(BambuPin.accept("aaaa", key: key, in: store))
        #expect(!BambuPin.accept("bbbb", key: key, in: store), "somebody else answering for the printer")
        store.remove(key)                                        // what saving the access code does
        #expect(BambuPin.accept("bbbb", key: key, in: store))
    }

    @Test("the pin is kept in the Keychain when there is one")
    func bambuPinInKeychain() {
        let key = BambuPin.key(serial: "TEST-\(UUID().uuidString)", host: "192.168.1.50")
        defer { BambuPin.Store.keychain.remove(key) }
        // A CI runner has no login Keychain; there the store falls back to
        // defaults, which `bambuPinMigratesOnce` covers.
        guard BambuPin.Store.keychainWrite(key, "probe") else { return }
        BambuPin.Store.keychain.remove(key)
        BambuPin.Store.keychain.write(key, "pinned")
        #expect(BambuPin.Store.keychainRead(key) == "pinned")
        #expect(UserDefaults.standard.string(forKey: key) == nil,
                "the pin went to a plist any process of this user can rewrite")
        #expect(!BambuPin.accept("other", key: key, in: .keychain))
    }

    @Test("an MQTT packet longer than the cap is refused, not buffered toward")
    func bambuPacketCap() throws {
        // A header claiming 200 MB: type byte, then a four-byte remaining length.
        let huge = 200 * 1024 * 1024
        var claim: [UInt8] = [0x30]
        var n = huge
        repeat {
            var b = UInt8(n % 128); n /= 128
            if n > 0 { b |= 0x80 }
            claim.append(b)
        } while n > 0
        #expect(throws: BambuMqtt.Trouble.malformed) { _ = try BambuMqtt.packets(from: claim + [0, 1, 2]) }
        // A real-sized one still waits for the rest of itself.
        let ok = BambuMqtt.publish(topic: "device/x/report", payload: String(repeating: "a", count: 70_000))
        let half = try BambuMqtt.packets(from: Array(ok.prefix(1000)))
        #expect(half.packets.isEmpty && half.rest.count == 1000)
        #expect(try BambuMqtt.packets(from: ok).packets.count == 1)
    }

    @Test("an ntfy token is never sent over plain HTTP")
    @MainActor
    func ntfyToken() async throws {
        let req = KhaytEngine.NtfyRequest(url: "http://ntfy.example/topic", headers: [:], body: "x")
        await #expect(throws: Ntfy.Failure.tokenNeedsHTTPS) {
            try await Ntfy.send(req, token: "secret", fetch: { _ in Issue.record("it was sent"); throw URLError(.badURL) })
        }
    }

    @Test("a new LAN PIN must be at least eight characters; a blank one keeps the stored PIN")
    func pinLength() {
        var d = OnlinePane.Draft()
        d.pin = "1234"; #expect(d.pinTooShort)
        d.pin = "12345678"; #expect(!d.pinTooShort)
        d.pin = "  "; #expect(!d.pinTooShort)
    }
}
