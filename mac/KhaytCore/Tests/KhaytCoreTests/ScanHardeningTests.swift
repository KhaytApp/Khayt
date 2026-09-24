import Foundation
import Testing
@testable import KhaytCore

/// Findings from the September 2026 security and bug scan, pinned.
struct ScanHardeningTests {

    /// `call2` pasted each argument's JSON into the script, then scanned the
    /// result again for the next placeholder — so text in one argument became
    /// part of another, or part of the program.
    @Test("an argument that mentions a placeholder is data, not script")
    func placeholdersInDataStayData() throws {
        let runtime = try JSRuntime(modules: [])
        let out = try runtime.call2("[ARG0, ARG1]", [.string("see ARG1"), .string("ARG0 twice ARG0")],
                                    as: [String].self)
        #expect(out == ["see ARG1", "ARG0 twice ARG0"])
        // A string built to close its own quotes and run: it must come back as text.
        let crafted = "\"+(globalThis.__scanPwned=1)+\""
        let echoed = try runtime.call2("[ARG1, ARG0]", [.string("ARG1"), .string(crafted)], as: [String].self)
        #expect(echoed == [crafted, "ARG1"])
        let pwned = try runtime.call2("typeof globalThis.__scanPwned", [], as: String.self)
        #expect(pwned == "undefined", "data from the book ran as code")
        // ARG10 is its own argument, not ARG1 followed by 0.
        let many = (0...10).map { JSONValue.number(Double($0)) }
        #expect(try runtime.call2("ARG10", many, as: Double.self) == 10)
        // And nothing is left bound afterwards.
        #expect(try runtime.call2("typeof __karg0", [], as: String.self) == "undefined")
    }

    static func write(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "scan-\(UUID().uuidString).zip")
        try Data(bytes).write(to: url)
        return url
    }

    static func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }

    /// A zip64 locator pointing near Int.max: `recordAt + 56` overflowed and
    /// trapped, from a file anyone on the shop's Wi-Fi can upload.
    @Test("a zip whose offsets are near Int.max is refused, not a crash")
    func overflowingOffsets() throws {
        var bytes: [UInt8] = []
        // zip64 end-of-central-directory LOCATOR (20 bytes)
        let le = Self.le
        bytes += le(0x0706_4b50, 4) + le(0, 4) + le(0x7FFF_FFFF_FFFF_FFF0, 8) + le(1, 4)
        // end of central directory (22 bytes), zip64 markers set
        bytes += le(0x0605_4b50, 4) + le(0, 2) + le(0, 2) + le(0xFFFF, 2) + le(0xFFFF, 2)
            + le(0xFFFF_FFFF, 4) + le(0xFFFF_FFFF, 4) + le(0, 2)
        let url = try Self.write(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { _ = try Zip.entries(of: url) }
    }

    /// A few bytes claiming to unpack to 2^40 bytes: the buffer was allocated
    /// from the claim.
    @Test("a member claiming more than DEFLATE can hold is refused before allocating")
    func inflateBomb() {
        #expect(throws: (any Error).self) {
            _ = try Zip.inflate(Data([0x03, 0x00]), to: 1 << 40, name: "bomb.model")
        }
    }
}
