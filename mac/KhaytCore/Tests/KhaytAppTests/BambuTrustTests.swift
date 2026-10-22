import Foundation
import Security
import Testing
import KhaytCore
@testable import KhaytApp

/// Who a Bambu's certificate must be from, and the speed and light controls.
///
/// No Bambu is on the bench, so no genuine leaf can be presented here. What
/// is checked: the bundle is the eight Bambu Lab certificates from
/// rolottr/bambu-bar; a certificate outside it is NOT verified, even when it
/// carries the right serial (anyone can type a serial into openssl), and
/// falls to the first-use pin;
/// the name rule; and the bytes of the two new controls.
@MainActor
struct BambuTrustTests {

    /// Self-signed, CN = the serial below. Made with openssl for this test.
    static let impostor = """
        -----BEGIN CERTIFICATE-----
        MIIDFTCCAf2gAwIBAgIUQyiLpk2dUHu3fV7m8wXYwh1OvrswDQYJKoZIhvcNAQEL
        BQAwGjEYMBYGA1UEAwwPMDFQMDBBMDAwMDAwMDAwMB4XDTI2MTAyMjE2MzM1M1oX
        DTM2MTAxOTE2MzM1M1owGjEYMBYGA1UEAwwPMDFQMDBBMDAwMDAwMDAwMIIBIjAN
        BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoYCT3S5z+A0DN39o2o3vS0OOF1gs
        NhHKkjKJ9Dl5VWRZeqsLy1WIPr+nu92yv9ye4BRkbBPSYBfqfd/v6zp1XIjbOSFz
        eXoo6G1+epbQWAGU4VT6dhWWqtx+ZXfFVKkKJT9j78hL0OwL1wXiWavZmjJpV5/g
        /eZhjdP2/FlPQ+hj/A6XWiCJRh+Txl/XbWJcGDEfMP3Y6dwPW453+Bhn6CLCoB6Q
        68+d0LBWN8Q3yoS5NiZMxiQq801xTeZocfJL4Z3qEjJTZYdp2MwTbbhv7S3XrRvw
        STUy4t82TShI8KA7UJGXSKUBERCDj70RPlOx7XjgrzNw4/ELnwsPzN0amwIDAQAB
        o1MwUTAdBgNVHQ4EFgQU13FB4PAwHtW2DmefJbMKlJ9yYygwHwYDVR0jBBgwFoAU
        13FB4PAwHtW2DmefJbMKlJ9yYygwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0B
        AQsFAAOCAQEASvhselE+jcZ6SIVxS8vAV/Jg6CJTsIF2QYmWAVfTJm8hCA8M9BNz
        8M6vflqWEFYkpP7RRudlLw25UzaRSMdeBXjvNi2I0jbAFCy66ssktW7yF1Wk7lTV
        wk0R8uLrslbhAiaUD4piuTY0W32yDt3q3PU/DJeihbBl0mvHeNBvcLP1KviKAoNq
        K4ulf9QCsFnWMsRAGdj5Mc9KgkvTMiMvQswYet4QgoNkb+DC6e0HsRCYbbCEugjS
        DFfRGKekcw1jVby+6WwN/HTy4OlHw6Kcf8e6DpXGZPvzSZ1t4pwDsOBpzwRjeLJ2
        7qa57q49f7HTdbxhSygYlUuIwvTasKSJYQ==
        -----END CERTIFICATE-----
        """

    @Test("the bundle is Bambu Lab's CAs, all eight, and parses")
    func anchorsParse() {
        let names = BambuTrust.anchors.compactMap { cert -> String? in
            var cn: CFString?
            SecCertificateCopyCommonName(cert, &cn)
            return cn as String?
        }
        #expect(names.count == 8)
        for want in ["BBL CA", "BBL CA2 RSA", "BBL CA2 ECC", "BBL Device CA N6-V2",
                     "BBL Device CA N7-V2", "BBL Device CA O1C2-V2"] {
            #expect(names.contains(want), "missing \(want)")
        }
    }

    @Test("a certificate that does not chain to Bambu is not verified, even named after the serial")
    func impostorRefused() throws {
        let certs = BambuTrust.certificates(fromPEM: Self.impostor)
        let leaf = try #require(certs.first)
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(leaf, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let verdict = BambuTrust.evaluate(try #require(trust), serial: "01P00A000000000")
        guard case .notBambu(let why) = verdict else {
            Issue.record("an openssl certificate was trusted: \(verdict)"); return
        }
        #expect(!why.isEmpty)
        // And the shop is told what happened, not "connection failed".
        let said = PrinterWatch.say(BambuMqtt.Trouble.notBambu(why))
        #expect(said.contains("Bambu Lab certificate"))
        #expect(said.contains("access code was not sent"))
    }

    /// No Bambu here proves every model and firmware chains to the bundled
    /// CAs, so only a verified chain naming ANOTHER serial is a hard refusal;
    /// an unverified chain falls back to the first-use pin.
    @Test("verified + this serial: in; verified + other serial: out; unverified: the pin decides")
    func trustDecision() {
        let pins = BambuPin.Store.memory()
        let key = BambuPin.key(serial: "01P00A000000000", host: "192.168.68.70")

        let ok = PinVerdict()
        #expect(BambuMqtt.trustDecision(.trusted, fingerprint: { "aa" }, pinKey: key, verdict: ok, pins: pins))
        #expect(ok.byBambu == true)
        #expect(pins.read(key) == "aa", "a verified printer is pinned, so an unverified impostor cannot take its place")
        let impostor = PinVerdict()
        #expect(!BambuMqtt.trustDecision(.notBambu("self-signed"), fingerprint: { "zz" },
                                         pinKey: key, verdict: impostor, pins: pins))
        #expect(impostor.refused == .certificateChanged)

        let other = PinVerdict()
        #expect(!BambuMqtt.trustDecision(.otherPrinter("01P00A000000001"), fingerprint: { "aa" },
                                         pinKey: key, verdict: other, pins: pins))
        #expect(other.refused == .otherPrinter("01P00A000000001"))

        let first = PinVerdict()
        #expect(BambuMqtt.trustDecision(.notBambu("untrusted"), fingerprint: { "aa" },
                                        pinKey: key, verdict: first, pins: pins))
        #expect(first.byBambu == false, "an unverified printer must be marked so the sheet can say it")
        let same = PinVerdict()
        #expect(BambuMqtt.trustDecision(.notBambu("untrusted"), fingerprint: { "aa" },
                                        pinKey: key, verdict: same, pins: pins))
        let changed = PinVerdict()
        #expect(!BambuMqtt.trustDecision(.notBambu("untrusted"), fingerprint: { "bb" },
                                         pinKey: key, verdict: changed, pins: pins))
        #expect(changed.refused == .certificateChanged)
        let blank = PinVerdict()
        #expect(!BambuMqtt.trustDecision(.notBambu("x"), fingerprint: { nil },
                                         pinKey: key, verdict: blank, pins: pins))
        #expect(blank.refused == .notBambu("x"))
    }

    @Test("the registry remembers which machines were let in unverified")
    func unverifiedNoted() {
        let watch = BambuWatch()
        watch.noteTrust("M-1", verifiedByBambu: false)
        #expect(watch.unverified.contains("M-1"))
        watch.noteTrust("M-1", verifiedByBambu: nil)
        #expect(watch.unverified.contains("M-1"), "unknown is not a verdict")
        watch.noteTrust("M-1", verifiedByBambu: true)
        #expect(!watch.unverified.contains("M-1"))
    }

    @Test("the name must be this machine's serial")
    func nameRule() {
        #expect(BambuTrust.nameMatches("01P00A000000000", serial: "01P00A000000000"))
        #expect(BambuTrust.nameMatches("01p00a000000000", serial: " 01P00A000000000 "))
        #expect(!BambuTrust.nameMatches("01P00A000000001", serial: "01P00A000000000"))
        #expect(!BambuTrust.nameMatches(nil, serial: "01P00A000000000"))
        #expect(!BambuTrust.nameMatches("", serial: ""))
        let said = PrinterWatch.say(BambuMqtt.Trouble.otherPrinter("01P00A000000001"))
        #expect(said.contains("01P00A000000001"))
        #expect(said.lowercased().contains("different bambu printer"))
    }

    @Test("speed presets and the chamber light, byte for byte, from the shared module")
    func controlBytes() async throws {
        let engine = try KhaytEngine()
        for level in 1...4 {
            let r = try await engine.printerControl(type: "bambu", control: "speed",
                                                    value: .number(Double(level)), sequenceId: 3)
            let mqtt = try #require(r.mqtt)
            #expect(mqtt.payload == #"{"print":{"sequence_id":"3","command":"print_speed","param":"\#(level)"}}"#)
            #expect(mqtt.section == "print")
        }
        let light = try await engine.printerControl(type: "bambu", control: "light",
                                                    value: .string("on"), sequenceId: 4)
        let mqtt = try #require(light.mqtt)
        #expect(mqtt.payload == #"{"system":{"sequence_id":"4","command":"ledctrl","led_node":"chamber_light","led_mode":"on","led_on_time":500,"led_off_time":500,"loop_times":0,"interval_time":0}}"#)
        #expect(mqtt.section == "system")
        let bad = try await engine.printerControl(type: "bambu", control: "speed",
                                                  value: .number(9), sequenceId: 5)
        #expect(bad.unsupported != nil)
        let other = try await engine.printerControl(type: "moonraker", control: "light",
                                                    value: .string("on"), sequenceId: 5)
        #expect(other.unsupported != nil)
    }

    @Test("the light's reply comes back under system, and is matched there")
    func lightReplyMatched() async throws {
        let clock = BambuSessionTests.Clock(), links = BambuSessionTests.Links()
        let s = BambuSessionTests.session(clock, links)
        await s.tick()
        await BambuSessionTests.handshake(s)
        let sent = Task {
            try await s.command(payload: "{}", command: "ledctrl", sequenceId: "7", section: "system",
                                timeout: .seconds(120))
        }
        try await BambuSessionTests.eventually { links.made[0].published.contains("{}") }
        // A print-section reply with the same number is not it.
        await s.feed(.bytes(BambuSessionTests.report(#"{"print":{"command":"ledctrl","sequence_id":"7","result":"fail"}}"#)))
        await s.feed(.bytes(BambuSessionTests.report(#"{"system":{"command":"ledctrl","sequence_id":"7","result":"success","led_node":"chamber_light","led_mode":"on"}}"#)))
        try await sent.value
    }
}
