import XCTest
@testable import KhaytCompanion

/**
 * NFCParser reads bytes off a physical tag that Khayt did not write.
 *
 * It is the only place in the companion that parses untrusted binary: three tag
 * formats, an NDEF TLV walker, and a hand-rolled CBOR decoder — all driven by
 * length fields taken from the tag itself. A wrong bound here is a crash in the
 * user's hand while they are holding a phone against a spool, and until now none
 * of it had a single test.
 *
 * The hostile cases matter more than the happy one: a tag can be blank,
 * truncated, from another vendor, or simply damaged, and every one of those has
 * to come back as a `.failure`, never a trap.
 */
final class NFCParserTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: - OpenSpool (raw JSON, no NDEF wrapper)

    func testParsesAnOpenSpoolTag() throws {
        // ##"…"## rather than #"…"#: a hex colour puts `"#` in the payload, which
        // closes a single-hash raw string early.
        let json = ##"{"protocol":"openspool","type":"PLA","subtype":"Matte","brand":"Prusament","color_hex":"#1A1A1A","weight":1000,"max_temp":215,"bed_max_temp":60}"##
        guard case .success(let tag) = NFCParser.parse(bytes: bytes(json)) else {
            return XCTFail("a well-formed OpenSpool tag must parse")
        }
        XCTAssertEqual(tag.standard, "OpenSpool")
        XCTAssertEqual(tag.manufacturer, "Prusament")
        XCTAssertEqual(tag.material, "PLA Matte", "type and subtype are joined")
        XCTAssertEqual(tag.hex, "#1a1a1a", "hex is normalised to lowercase with a leading #")
        XCTAssertEqual(tag.weight, 1000)
        XCTAssertEqual(tag.printTemp, 215)
        XCTAssertEqual(tag.bedTemp, 60)
    }

    func testFallsBackToMinTempsWhenMaxIsAbsent() throws {
        let json = #"{"protocol":"openspool","type":"PETG","min_temp":230,"bed_min_temp":75}"#
        guard case .success(let tag) = NFCParser.parse(bytes: bytes(json)) else {
            return XCTFail("min-only temperatures are valid")
        }
        XCTAssertEqual(tag.printTemp, 230)
        XCTAssertEqual(tag.bedTemp, 75)
    }

    func testNumericFieldsSentAsStringsAreAccepted() throws {
        // Tags in the wild are written by many different tools; some quote numbers.
        let json = #"{"protocol":"openspool","type":"ABS","weight":"750","max_temp":"245"}"#
        guard case .success(let tag) = NFCParser.parse(bytes: bytes(json)) else {
            return XCTFail("quoted numbers are common on real tags")
        }
        XCTAssertEqual(tag.weight, 750)
        XCTAssertEqual(tag.printTemp, 245)
    }

    func testNonsensicalWeightIsDroppedRatherThanShown() throws {
        // A zero or negative weight is meaningless; surfacing it as "0 g remaining"
        // would be worse than showing nothing.
        let json = #"{"protocol":"openspool","type":"PLA","weight":0,"max_temp":-5}"#
        guard case .success(let tag) = NFCParser.parse(bytes: bytes(json)) else {
            return XCTFail("the tag is otherwise valid")
        }
        XCTAssertNil(tag.weight)
        XCTAssertNil(tag.printTemp)
    }

    func testMalformedHexIsIgnoredNotGuessed() throws {
        let json = #"{"protocol":"openspool","type":"PLA","color_hex":"nope"}"#
        guard case .success(let tag) = NFCParser.parse(bytes: bytes(json)) else {
            return XCTFail("a bad colour must not fail the whole tag")
        }
        XCTAssertNil(tag.hex, "six characters or nothing — a partial hex is not rendered")
    }

    func testAnOpenSpoolTagWithNeitherTypeNorBrandIsRejected() {
        // Otherwise the user gets an empty row they cannot act on.
        let json = #"{"protocol":"openspool","weight":1000}"#
        guard case .failure = NFCParser.parse(bytes: bytes(json)) else {
            return XCTFail("a tag with no identifying fields is not usable")
        }
    }

    // MARK: - Hostile input

    func testTooShortIsRejectedWithoutReadingPastTheEnd() {
        for count in 0...9 {
            guard case .failure = NFCParser.parse(bytes: [UInt8](repeating: 0x04, count: count)) else {
                return XCTFail("\(count) bytes cannot be a tag")
            }
        }
    }

    func testRandomBytesFailCleanly() {
        // A tag from another vendor, or a damaged one. It must not trap.
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let n = Int.random(in: 10...300, using: &rng)
            let junk = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            if case .success(let tag) = NFCParser.parse(bytes: junk) {
                // Vanishingly unlikely, but if random bytes DO parse the result
                // must still be coherent rather than half-populated garbage.
                XCTAssertFalse(tag.standard.isEmpty)
            }
        }
    }

    func testALongLengthCutOffAtTheEndDoesNotOverread() {
        // A TLV whose length says "three bytes follow" (0xFF) with only one
        // left. The random-bytes test above hit this only now and then
        // and trapped the app; this is that tag, every time, at each length
        // where the cut can land.
        for count in 10...20 {
            var bytes = [UInt8](repeating: 0x00, count: count)
            bytes[count - 3] = 0x03
            bytes[count - 2] = 0xFF
            bytes[count - 1] = 0x01
            guard case .failure = NFCParser.parse(bytes: bytes) else {
                return XCTFail("\(count) bytes: a cut-off TLV cannot be a tag")
            }
        }
    }

    func testAnNDEFLengthPointingPastTheBufferDoesNotOverread() {
        // TLV type 0x03, declared length 0xFE, but only a few bytes follow. The
        // walker must clamp instead of slicing past the end.
        var tag: [UInt8] = [0x03, 0xFE, 0xD1, 0x02]
        tag.append(contentsOf: [UInt8](repeating: 0x41, count: 8))
        guard case .failure = NFCParser.parse(bytes: tag) else {
            return XCTFail("a truncated NDEF record has nothing to parse")
        }
    }

    func testAnNDEFShortRecordWithAnOversizedPayloadLengthIsRejected() {
        // flags 0xD2 (SR|MB|ME, TNF=2 mime), typeLen 16, payloadLen 200 — far more
        // than the record actually carries.
        let mime = Array("application/json".utf8)
        var tlv: [UInt8] = [0xD2, UInt8(mime.count), 200]
        tlv.append(contentsOf: mime)
        tlv.append(contentsOf: Array(#"{"protocol":"openspool"}"#.utf8))
        var tag: [UInt8] = [0x03, UInt8(tlv.count)]
        tag.append(contentsOf: tlv)
        tag.append(0xFE)
        guard case .failure = NFCParser.parse(bytes: tag) else {
            return XCTFail("the declared payload runs past the record")
        }
    }

    func testDeeplyNestedCBORIsBoundedRatherThanRecursingForever() {
        // 200 nested single-element arrays (0x81). The decoder caps depth at 12;
        // without that cap this is a stack overflow from a hostile tag.
        var payload = [UInt8](repeating: 0x81, count: 200)
        payload.append(0x01)
        let mime = Array("application/opentag3d".utf8)
        var tlv: [UInt8] = [0xD2, UInt8(mime.count), UInt8(payload.count)]
        tlv.append(contentsOf: mime)
        tlv.append(contentsOf: payload)
        var tag: [UInt8] = [0x03, 0xFF, UInt8(tlv.count >> 8), UInt8(tlv.count & 0xFF)]
        tag.append(contentsOf: tlv)
        tag.append(0xFE)
        _ = NFCParser.parse(bytes: tag)   // must return, not blow the stack
    }

    func testAnAllZeroTagIsRejected() {
        // A blank NTAG reads as zeros. Common, and must not look like a match.
        guard case .failure = NFCParser.parse(bytes: [UInt8](repeating: 0, count: 144)) else {
            return XCTFail("a blank tag is not a filament tag")
        }
    }

    func testAnNDEFWrappedOpenSpoolTagIsFound() throws {
        // The realistic shape: the JSON arrives inside a mime record inside a TLV.
        let json = Array(#"{"protocol":"openspool","type":"PLA","brand":"Generic"}"#.utf8)
        let mime = Array("application/json".utf8)
        var tlv: [UInt8] = [0xD2, UInt8(mime.count), UInt8(json.count)]
        tlv.append(contentsOf: mime)
        tlv.append(contentsOf: json)
        var tag: [UInt8] = [0x03, UInt8(tlv.count)]
        tag.append(contentsOf: tlv)
        tag.append(0xFE)

        guard case .success(let parsed) = NFCParser.parse(bytes: tag) else {
            return XCTFail("an NDEF-wrapped OpenSpool tag is the normal case")
        }
        XCTAssertEqual(parsed.manufacturer, "Generic")
        XCTAssertEqual(parsed.material, "PLA")
    }
}
