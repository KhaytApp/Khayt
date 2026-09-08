import Foundation
import Compression

/// Reading named members out of a zip, without opening the whole file.
///
/// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
///
/// A 3MF is a zip, and adding a model to the library means reading two things
/// out of one: the embedded preview and the slicer's configs. Khayt does that
/// with `lib/zip-read.js`, whose own header says **"Pure Node (uses Buffer +
/// zlib) — main-process only"**. Neither exists in JavaScriptCore, so that
/// module is the one part of the import path that cannot be shared, and this is
/// the smallest thing that replaces it.
///
/// The *rules* stay shared. This does the mechanics — find the members, inflate
/// the small ones — and hands the bytes to `lib/thumbnail-extract.js`, which
/// still decides which preview wins and what the colours are.
///
/// ── IT NEVER READS THE WHOLE FILE ────────────────────────────────────────
///
/// Measured on this shop's own library: `KING-Saud-ART-200mm-U1.3mf` is 46 MB
/// on disk and its `3D/Objects/object_1.model` member is **436 MB
/// uncompressed** — a ten-to-one ratio that is ordinary for a mesh and fatal to
/// read by accident. So nothing here loads a file into memory: the central
/// directory is read from the end, and a member is read by seeking to it.
///
/// Every read is capped. The two things this is for — a PNG preview and a
/// config file — are measured in kilobytes on the same shop's files (154 KB and
/// 28 KB), and an entry claiming more than `limit` is refused rather than
/// inflated. That is the whole defence against a zip built to exhaust memory,
/// and it is a cap rather than a heuristic because the honest bound is known.
public enum Zip {

    /// English, and technical. A shop never reads "the archive is damaged: a
    /// member's name runs past the directory" — whoever is working out why a
    /// file would not open does. See the note on `Mesh.Failure`.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notAZip
        case unreadable(String)
        case tooBig(name: String, size: Int, limit: Int)
        case unsupported(name: String, method: UInt16)
        case corrupt(String)

        public var description: String {
            switch self {
            case .notAZip: return "That file is not a zip archive."
            case .unreadable(let why): return "Could not read the archive: \(why)"
            case .tooBig(let name, let size, let limit):
                return "\(name) claims \(size) bytes, past the \(limit) this reads."
            case .unsupported(let name, let method):
                return "\(name) uses compression method \(method), which this does not read."
            case .corrupt(let what): return "The archive is damaged: \(what)"
            }
        }
    }

    /// One member, as the central directory describes it.
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let compressedSize: Int
        public let size: Int
        /// 0 stored, 8 deflate. A 3MF's previews are usually stored — already
        /// PNG, so there is nothing left to squeeze — and its XML is deflated.
        public let method: UInt16
        /// Where the LOCAL header sits. The central directory's copy of the
        /// name and sizes is authoritative; the local header is read only for
        /// its two length fields, because they say where the data starts.
        public let offset: Int
    }

    /// The most a single member may weigh. Generous for a preview or a config
    /// and far under any mesh, which is the point.
    public static let defaultLimit = 8 * 1024 * 1024

    // MARK: - Reading

    /// Every member, without decompressing any of them.
    public static func entries(of url: URL) throws -> [Entry] {
        let handle = try open(url)
        defer { try? handle.close() }
        let fileSize = Int(try handle.seekToEnd())
        guard fileSize > 22 else { throw Failure.notAZip }

        // The end-of-central-directory record is last, but a zip may carry a
        // comment after it, so it is searched for backwards through the most a
        // comment may be (65,535) plus the record itself.
        let tailLength = min(fileSize, 65_535 + 22)
        let tail = try read(handle, at: fileSize - tailLength, count: tailLength)
        guard let eocd = lastIndex(of: 0x0605_4b50, in: tail) else { throw Failure.notAZip }

        let count = Int(u16(tail, eocd + 10))
        let directorySize = Int(u32(tail, eocd + 12))
        let directoryAt = Int(u32(tail, eocd + 16))
        // Zip64 writes 0xFFFF/0xFFFFFFFF here and puts the real values in its
        // own record. Refused rather than guessed at: a misread offset is a
        // read of arbitrary bytes, and no 3MF this reads is near 4 GB.
        guard count != 0xFFFF, directoryAt != 0xFFFF_FFFF, directorySize != 0xFFFF_FFFF else {
            throw Failure.unsupported(name: "the archive", method: 64)
        }
        guard directoryAt >= 0, directorySize >= 0,
              directoryAt + directorySize <= fileSize else {
            throw Failure.corrupt("the directory is outside the file")
        }

        let directory = try read(handle, at: directoryAt, count: directorySize)
        var out: [Entry] = []
        var at = 0
        while at + 46 <= directory.count, out.count < count {
            guard u32(directory, at) == 0x0201_4b50 else { break }
            let method = u16(directory, at + 10)
            let compressed = Int(u32(directory, at + 20))
            let uncompressed = Int(u32(directory, at + 24))
            let nameLength = Int(u16(directory, at + 28))
            let extraLength = Int(u16(directory, at + 30))
            let commentLength = Int(u16(directory, at + 32))
            let localAt = Int(u32(directory, at + 42))
            let nameAt = at + 46
            guard nameAt + nameLength <= directory.count else {
                throw Failure.corrupt("a member's name runs past the directory")
            }
            let name = String(decoding: directory[nameAt..<(nameAt + nameLength)], as: UTF8.self)
            out.append(Entry(name: name, compressedSize: compressed, size: uncompressed,
                             method: method, offset: localAt))
            at = nameAt + nameLength + extraLength + commentLength
        }
        return out
    }

    /// One member's bytes, inflated if it needs it.
    ///
    /// `limit` is checked BEFORE anything is read or decompressed, against the
    /// size the directory claims — so a member that says it is 436 MB costs a
    /// comparison rather than 436 MB.
    public static func data(of entry: Entry, in url: URL, limit: Int = defaultLimit) throws -> Data {
        guard entry.size <= limit, entry.compressedSize <= limit else {
            throw Failure.tooBig(name: entry.name, size: max(entry.size, entry.compressedSize),
                                 limit: limit)
        }
        guard entry.method == 0 || entry.method == 8 else {
            throw Failure.unsupported(name: entry.name, method: entry.method)
        }

        let handle = try open(url)
        defer { try? handle.close() }

        // The local header repeats the name and carries its own extra field,
        // and the two lengths differ from the central directory's often enough
        // that using the central copy reads from the wrong place. So they are
        // read from the local header, and only they.
        let header = try read(handle, at: entry.offset, count: 30)
        guard header.count == 30, u32(header, 0) == 0x0403_4b50 else {
            throw Failure.corrupt("\(entry.name) has no local header where the directory says")
        }
        let nameLength = Int(u16(header, 26))
        let extraLength = Int(u16(header, 28))
        let dataAt = entry.offset + 30 + nameLength + extraLength

        let raw = try read(handle, at: dataAt, count: entry.compressedSize)
        guard raw.count == entry.compressedSize else {
            throw Failure.corrupt("\(entry.name) is shorter than the directory claims")
        }
        if entry.method == 0 { return raw }
        return try inflate(raw, to: entry.size, name: entry.name)
    }

    /// Raw DEFLATE — no zlib header, which is what a zip member is.
    ///
    /// `COMPRESSION_ZLIB` in Apple's framework IS the raw stream despite the
    /// name; the header-and-checksum form is what a `.zz` file has and what a
    /// zip member does not.
    public static func inflate(_ raw: Data, to size: Int, name: String) throws -> Data {
        // A stated size of zero is a real answer for an empty member, and would
        // otherwise become a zero-length destination buffer and a crash.
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let written: Int = out.withUnsafeMutableBytes { destination in
            raw.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw Failure.corrupt("\(name) did not decompress") }
        // Short is not fatal — some writers overstate — but the bytes beyond
        // what was written are zeros this did not read and must not hand back.
        return written == size ? out : out.prefix(written)
    }

    /// Read a member in pieces, without ever holding it whole.
    ///
    /// `data(of:in:)` above refuses anything past a cap, and that is right for a
    /// preview or a config. A 3MF's mesh is the other case: this shop's is 436 MB
    /// of XML uncompressed, it genuinely has to be read, and none of it has to be
    /// resident. `onChunk` sees it a megabyte at a time as it inflates.
    ///
    /// The cap here is on the TOTAL, not on what is held, and it exists to stop
    /// a stream that never ends rather than to bound memory. Returning false
    /// from `onChunk` stops the read.
    public static func stream(_ entry: Entry, in url: URL, totalLimit: Int = 4 << 30,
                       onChunk: (UnsafeRawBufferPointer) -> Bool) throws {
        guard entry.method == 0 || entry.method == 8 else {
            throw Failure.unsupported(name: entry.name, method: entry.method)
        }
        let handle = try open(url)
        defer { try? handle.close() }

        let header = try read(handle, at: entry.offset, count: 30)
        guard header.count == 30, u32(header, 0) == 0x0403_4b50 else {
            throw Failure.corrupt("\(entry.name) has no local header where the directory says")
        }
        var at = entry.offset + 30 + Int(u16(header, 26)) + Int(u16(header, 28))
        var left = entry.compressedSize

        if entry.method == 0 {
            // Stored: the bytes are the bytes.
            while left > 0 {
                let want = min(1 << 20, left)
                let chunk = try read(handle, at: at, count: want)
                if chunk.isEmpty { break }
                var keepGoing = true
                chunk.withUnsafeBytes { keepGoing = onChunk($0) }
                if !keepGoing { return }
                at += chunk.count
                left -= chunk.count
            }
            return
        }

        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                                        dst_size: 0, src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                                        src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else {
            throw Failure.corrupt("could not start decompressing \(entry.name)")
        }
        defer { compression_stream_destroy(&stream) }

        let outSize = 1 << 20
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: outSize)
        defer { out.deallocate() }
        var produced = 0

        while true {
            let want = min(1 << 20, left)
            let input = want > 0 ? try read(handle, at: at, count: want) : Data()
            at += input.count
            left -= input.count
            let lastPiece = left <= 0 || input.isEmpty

            var stop = false
            try input.withUnsafeBytes { raw -> Void in
                stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress
                    ?? UnsafePointer<UInt8>(bitPattern: 1)!
                stream.src_size = input.count
                // KEEP CALLING UNTIL IT SAYS END, not until the input is
                // consumed.
                //
                // The decoder holds output of its own, and on the final piece it
                // has more to give after the last byte of input has gone in. A
                // loop that stopped at `src_size == 0` returned before that
                // flush and lost the tail — 8,912,896 bytes of a 9,192,705-byte
                // member, which is a truncation that looks like a smaller file
                // rather than like an error. Found by streaming a member out and
                // comparing it with what went in.
                while true {
                    stream.dst_ptr = out
                    stream.dst_size = outSize
                    let flags = lastPiece ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    let status = compression_stream_process(&stream, flags)
                    let got = outSize - stream.dst_size
                    if got > 0 {
                        produced += got
                        guard produced <= totalLimit else {
                            throw Failure.tooBig(name: entry.name, size: produced, limit: totalLimit)
                        }
                        if !onChunk(UnsafeRawBufferPointer(start: out, count: got)) { stop = true; return }
                    }
                    if status == COMPRESSION_STATUS_ERROR {
                        throw Failure.corrupt("\(entry.name) did not decompress")
                    }
                    if status == COMPRESSION_STATUS_END { stop = true; return }
                    // Nothing taken and nothing given: it wants the next piece.
                    // Without this the loop above would spin on a stream that
                    // is simply waiting for more input.
                    if got == 0 && stream.src_size == 0 { return }
                }
            }
            if stop || lastPiece { break }
        }
    }

    // MARK: - The bytes

    private static func open(_ url: URL) throws -> FileHandle {
        do { return try FileHandle(forReadingFrom: url) }
        catch { throw Failure.unreadable(error.localizedDescription) }
    }

    private static func read(_ handle: FileHandle, at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0 else { throw Failure.corrupt("a negative offset") }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
    }

    private static func u16(_ d: Data, _ at: Int) -> UInt16 {
        guard at + 2 <= d.count else { return 0 }
        let i = d.startIndex + at
        return UInt16(d[i]) | UInt16(d[i + 1]) << 8
    }

    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        guard at + 4 <= d.count else { return 0 }
        let i = d.startIndex + at
        return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }

    /// The LAST match, not the first: a member's own bytes can contain the
    /// end-of-directory signature, and a zip is defined by its last one.
    private static func lastIndex(of signature: UInt32, in d: Data) -> Int? {
        guard d.count >= 4 else { return nil }
        var at = d.count - 4
        while at >= 0 {
            if u32(d, at) == signature { return at }
            at -= 1
        }
        return nil
    }
}
