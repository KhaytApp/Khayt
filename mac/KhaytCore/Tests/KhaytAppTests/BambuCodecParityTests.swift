import Foundation
import Testing
@testable import KhaytApp

/// The bytes this app puts on the wire, against the bytes the other one does.
///
/// Bambu is the one protocol with no shared transport: `lib/bambu.js` hand-rolls
/// MQTT 3.1.1 over Node's `Buffer`, which cannot be loaded in JavaScriptCore, so
/// `BambuMqtt` hand-rolls it again in Swift. Two hand-rolled codecs that agree
/// by inspection are two codecs that will diverge.
///
/// So these are the EXACT packets `lib/bambu.js` emits for the same inputs,
/// captured from it. `test/bambu.test.js` asserts the same hex from the other
/// side and names this file, so a change to either codec fails on both and says
/// where the other one is.
@Suite struct BambuCodecParityTests {

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    @Test("CONNECT is byte-for-byte what the other app sends")
    func connectMatches() {
        #expect(Self.hex(BambuMqtt.connect(clientId: "khayt-abc123",
                                           username: "bblp", password: "12345678"))
                == "102800044d51545404c2003c000c6b686179742d616263313233000462626c7000083132333435363738")
    }

    @Test("SUBSCRIBE is byte-for-byte what the other app sends")
    func subscribeMatches() {
        #expect(Self.hex(BambuMqtt.subscribe(packetId: 1, topic: "device/01P00A000000000/report"))
                == "82220001001d6465766963652f3031503030413030303030303030302f7265706f727400")
    }

    @Test("PUBLISH is byte-for-byte what the other app sends")
    func publishMatches() {
        let payload = #"{"pushing":{"sequence_id":"0","command":"pushall"}}"#
        #expect(Self.hex(BambuMqtt.publish(topic: "device/01P00A000000000/request", payload: payload))
                == "3053001e6465766963652f3031503030413030303030303030302f726571756573747b2270757368696e67223a7b2273657175656e63655f6964223a2230222c22636f6d6d616e64223a2270757368616c6c227d7d")
    }

    /// The variable-byte integer, at each boundary where it grows a byte. Off
    /// by one here and a long report is read as two short ones.
    @Test("Remaining Length agrees at every boundary")
    func remainingLengthMatches() {
        #expect(Self.hex(BambuMqtt.remainingLength(0)) == "00")
        #expect(Self.hex(BambuMqtt.remainingLength(127)) == "7f")
        #expect(Self.hex(BambuMqtt.remainingLength(128)) == "8001")
        #expect(Self.hex(BambuMqtt.remainingLength(16383)) == "ff7f")
        #expect(Self.hex(BambuMqtt.remainingLength(2097152)) == "80808001")
    }

    @Test("PINGREQ and DISCONNECT are the same two bytes")
    func keepaliveMatches() {
        #expect(Self.hex(BambuMqtt.pingreq) == "c000")
        #expect(Self.hex(BambuMqtt.disconnect) == "e000")
    }

    @Test("what was encoded reads back")
    func itRoundTrips() throws {
        let topic = "device/01P00A000000000/report"
        let payload = #"{"print":{"gcode_state":"RUNNING"}}"#
        let wire = BambuMqtt.publish(topic: topic, payload: payload)
        let read = try BambuMqtt.packets(from: wire)
        #expect(read.rest.isEmpty)
        #expect(read.packets.count == 1)
        #expect(read.packets[0].type == 3)
        let decoded = try #require(BambuMqtt.decodePublish(read.packets[0].body))
        #expect(decoded.topic == topic)
        #expect(decoded.payload == payload)
    }

    /// A TLS read is not a message boundary, and this is the half that a codec
    /// written against a single tidy fixture gets wrong.
    @Test("a stream split anywhere yields the same packets")
    func itSurvivesFragmentation() throws {
        let a = BambuMqtt.publish(topic: "device/X/report", payload: #"{"print":{"mc_percent":41}}"#)
        let b = BambuMqtt.publish(topic: "device/X/report", payload: #"{"print":{"mc_percent":42}}"#)
        let whole = a + b

        for cut in 1..<whole.count {
            var pending = Array(whole[0..<cut])
            var seen: [BambuMqtt.Packet] = []
            var read = try BambuMqtt.packets(from: pending)
            seen += read.packets
            pending = read.rest + Array(whole[cut...])
            read = try BambuMqtt.packets(from: pending)
            seen += read.packets
            #expect(read.rest.isEmpty, "bytes left over when split at \(cut)")
            #expect(seen.count == 2, "lost a packet when split at \(cut)")
        }
    }

    /// A packet whose declared length has not arrived is not an error and must
    /// not be consumed — the rest of it is in the next read.
    @Test("a half-arrived packet is kept, not dropped")
    func aPartialPacketWaits() throws {
        let whole = BambuMqtt.publish(topic: "device/X/report", payload: #"{"print":{"mc_percent":41}}"#)
        let read = try BambuMqtt.packets(from: Array(whole.dropLast(5)))
        #expect(read.packets.isEmpty)
        #expect(read.rest.count == whole.count - 5)
    }
}
