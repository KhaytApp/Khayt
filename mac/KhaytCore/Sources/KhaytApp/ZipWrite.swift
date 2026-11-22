import Foundation
import Compression
import KhaytCore

/// Writing a zip, which is what a 3MF is.
///
/// The counterpart to `Zip`, and the thing that stood between this app and the
/// converter: `Zip` can inflate, so the Mac can READ a 3MF — it measures meshes
/// and pulls thumbnails out of them already — and had no way to put one back
/// together. `lib/zip-write.js` does it in Node and cannot be loaded here,
/// because it is built on `zlib`.
///
/// ── IT MATCHES THE OTHER WRITER BYTE FOR BYTE ─────────────────────────────
///
/// The same choices as `lib/zip-write.js`, deliberately, so a 3MF repacked on
/// the Mac is the same shape as one repacked in Electron: classic 32-bit zip,
/// local header + central directory + EOCD, UTF-8 names flagged, a fixed
/// 1980-01-01 stamp so the same input gives the same bytes, and STORE-or-DEFLATE
/// chosen per member by whichever is smaller. A PNG thumbnail is already
/// compressed; deflating it again makes it bigger, and both writers keep the
/// original in that case.
///
/// No zip64 and no encryption. A member over 4 GB cannot be written and says so
/// rather than silently truncating a field — which is the failure that produces
/// an archive every tool opens and finds empty.
enum ZipWrite {

    enum Failure: Error, CustomStringConvertible, Equatable {
        case tooBig(String)
        case tooMany(Int)
        case noName

        var description: String {
            switch self {
            case .tooBig(let name): return "\(name) is too large for a 32-bit zip."
            case .tooMany(let n): return "\(n) members is more than a 32-bit zip can index."
            case .noName: return "A zip member must have a name."
            }
        }
    }

    /// What goes in. `store` forces the member in uncompressed — the caller's
    /// answer for bytes it knows are already compressed.
    struct Member {
        let name: String
        let data: Data
        var store = false

        init(_ name: String, _ data: Data, store: Bool = false) {
            self.name = name
            self.data = data
            self.store = store
        }
    }

    private static let sigLocal: UInt32 = 0x04034b50
    private static let sigCentral: UInt32 = 0x02014b50
    private static let sigEnd: UInt32 = 0x06054b50
    /// 1980-01-01, the epoch of the DOS stamp a zip carries. Fixed rather than
    /// "now", so repacking the same members twice gives the same bytes and a
    /// content hash means something.
    private static let dosDate: UInt16 = 0x21
    private static let limit = Int(UInt32.max)

    static func archive(_ members: [Member]) throws -> Data {
        guard members.count <= Int(UInt16.max) else { throw Failure.tooMany(members.count) }

        var out = Data()
        var central = Data()

        for member in members {
            let name = Array(member.name.utf8)
            guard !name.isEmpty else { throw Failure.noName }
            guard member.data.count <= limit, name.count <= Int(UInt16.max) else {
                throw Failure.tooBig(member.name)
            }

            let offset = out.count
            let crc = crc32(member.data)
            let (method, body) = squeeze(member)
            guard body.count <= limit else { throw Failure.tooBig(member.name) }

            var local = Data()
            local.append(u32: sigLocal)
            local.append(u16: 20)                    // version needed
            local.append(u16: 0x0800)                // UTF-8 name
            local.append(u16: method)
            local.append(u16: 0)                     // mod time
            local.append(u16: dosDate)
            local.append(u32: crc)
            local.append(u32: UInt32(body.count))
            local.append(u32: UInt32(member.data.count))
            local.append(u16: UInt16(name.count))
            local.append(u16: 0)                     // no extra field
            out.append(local)
            out.append(contentsOf: name)
            out.append(body)

            central.append(u32: sigCentral)
            central.append(u16: 20)                  // version made by
            central.append(u16: 20)                  // version needed
            central.append(u16: 0x0800)
            central.append(u16: method)
            central.append(u16: 0)
            central.append(u16: dosDate)
            central.append(u32: crc)
            central.append(u32: UInt32(body.count))
            central.append(u32: UInt32(member.data.count))
            central.append(u16: UInt16(name.count))
            central.append(u16: 0)                   // extra
            central.append(u16: 0)                   // comment
            central.append(u16: 0)                   // disk
            central.append(u16: 0)                   // internal attrs
            central.append(u32: 0)                   // external attrs
            central.append(u32: UInt32(offset))
            central.append(contentsOf: name)
        }

        guard out.count + central.count <= limit else {
            throw Failure.tooBig("the archive")
        }
        let centralOffset = out.count
        out.append(central)

        var end = Data()
        end.append(u32: sigEnd)
        end.append(u16: 0)                           // this disk
        end.append(u16: 0)                           // disk with the directory
        end.append(u16: UInt16(members.count))
        end.append(u16: UInt16(members.count))
        end.append(u32: UInt32(central.count))
        end.append(u32: UInt32(centralOffset))
        end.append(u16: 0)                           // no comment
        out.append(end)
        return out
    }

    /// Deflate, unless it does not help.
    ///
    /// A 3MF's thumbnail is a PNG and its meshes are XML: one is incompressible
    /// and the other compresses ten to one, so the choice has to be per member.
    /// Deflating an already-compressed member makes it BIGGER, and a repack that
    /// grew the file would be a repack a shop notices.
    static func squeeze(_ member: Member) -> (method: UInt16, body: Data) {
        guard !member.store, !member.data.isEmpty else { return (0, member.data) }
        guard let deflated = deflate(member.data), deflated.count < member.data.count else {
            return (0, member.data)
        }
        return (8, deflated)
    }

    /// Raw DEFLATE — no zlib header, which is what a zip member is.
    ///
    /// `COMPRESSION_ZLIB` in Apple's framework IS the raw stream despite the
    /// name, as `Zip.inflate` says at greater length on the way back in.
    static func deflate(_ raw: Data) -> Data? {
        // The destination has to be big enough for the case where deflate makes
        // it bigger — incompressible bytes cost a few per 64 kB block — or the
        // encode returns 0 and reads as a failure.
        let capacity = raw.count + (raw.count / 100) + 128
        var out = Data(count: capacity)
        let written: Int = out.withUnsafeMutableBytes { destination in
            raw.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    /// CRC-32 (IEEE 802.3), the one a zip carries. Table built once.
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffffffff
        for byte in data { c = (c >> 8) ^ table[Int((c ^ UInt32(byte)) & 0xff)] }
        return c ^ 0xffffffff
    }
}

private extension Data {
    mutating func append(u16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
    }
    mutating func append(u32 value: UInt32) {
        append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
                            UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)])
    }
}
