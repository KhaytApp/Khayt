import Foundation
import CoreMedia
import VideoToolbox
import AppKit

/// One still, out of an RTSP camera.
///
/// ── WHY THIS EXISTS ──────────────────────────────────────────────────────────
///
/// `Camera.swift` fetches a JPEG over HTTP, which is what every camera Khayt had
/// met until now speaks. The Buddy3D beside a Prusa CORE One does not: measured
/// on this shop's floor, it has RTSP on 554, a proprietary service on 9000, and
/// NO HTTP SERVER AT ALL. There is no snapshot URL to point at, and the printer
/// cannot help — the camera is a separate Wi-Fi device and the printer never
/// sees its frames.
///
/// So the choice was a still out of RTSP, or no picture. This is the still.
///
/// ── A FRAME, NOT A PLAYER ────────────────────────────────────────────────────
///
/// The whole session is opened, one keyframe is decoded, and it is torn down.
/// That is deliberate and it is the same decision `Camera.swift` already made
/// about MJPEG: a shop floor with five machines is five permanent connections
/// for a picture that changes every few seconds anyway. Holding an RTSP session
/// open would additionally mean answering keepalives and owning a decoder per
/// machine, for a tile 120 points tall.
///
/// The cost is that each still waits for the camera's next IDR. Cameras of this
/// kind send one every second or two, which is well inside the five seconds
/// between sweeps.
///
/// ── TCP INTERLEAVED, NOT UDP ─────────────────────────────────────────────────
///
/// `Transport: RTP/AVP/TCP;interleaved=0-1` puts the RTP packets down the same
/// socket as the control messages. UDP would mean binding two ports, hoping the
/// shop's network lets them through, and handling loss — for a single keyframe
/// that is all cost and no benefit.
enum Rtsp {

    // MARK: - What a camera answered

    /// The parts of an SDP description this needs to decode a frame.
    struct Described: Equatable {
        /// Where PLAY and SETUP are aimed. Absolute, resolved against the base.
        let control: String
        /// H.264 parameter sets, out of `sprop-parameter-sets`. Without these a
        /// keyframe cannot be turned into a picture: they carry the resolution
        /// and the profile, and they are NOT repeated in the stream by every
        /// camera.
        let sps: Data
        let pps: Data
    }

    enum Failure: Error, CustomStringConvertible {
        case notRtsp
        case refused(Int)
        case noVideoTrack
        case noParameterSets
        case timedOut
        case cannotDecode

        var description: String {
            switch self {
            case .notRtsp:          "not an rtsp address"
            case .refused(let s):   "rtsp \(s)"
            case .noVideoTrack:     "no video track"
            case .noParameterSets:  "no parameter sets"
            case .timedOut:         "timed out"
            case .cannotDecode:     "cannot decode"
            }
        }
    }

    // MARK: - The text half, which is all testable without a camera

    /// The status code from an RTSP response head, or nil if it is not one.
    static func status(of head: String) -> Int? {
        guard let first = head.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, parts[0].uppercased().hasPrefix("RTSP/") else { return nil }
        return Int(parts[1])
    }

    /// One header's value, case-insensitively, or nil.
    static func header(_ name: String, in head: String) -> String? {
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(name) == .orderedSame {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The video track and its parameter sets, out of an SDP body.
    ///
    /// Only the `m=video` section is read. A camera that also offers audio puts
    /// its own `a=control:` in that section, and aiming SETUP at the audio track
    /// is how you end up with a session that plays perfectly and never produces
    /// a picture.
    static func describe(sdp: String, base: String) -> Described? {
        var inVideo = false
        var control: String?
        var fmtp: String?
        for raw in sdp.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                inVideo = line.hasPrefix("m=video")
                continue
            }
            guard inVideo else { continue }
            if line.hasPrefix("a=control:") { control = String(line.dropFirst("a=control:".count)) }
            if line.hasPrefix("a=fmtp:") { fmtp = line }
        }
        guard let fmtp, let sets = spropParameterSets(in: fmtp) else { return nil }
        return Described(control: absolute(control ?? "", against: base), sps: sets.0, pps: sets.1)
    }

    /// `sprop-parameter-sets=<base64 SPS>,<base64 PPS>` out of an `a=fmtp:` line.
    static func spropParameterSets(in fmtp: String) -> (Data, Data)? {
        guard let range = fmtp.range(of: "sprop-parameter-sets=", options: .caseInsensitive) else { return nil }
        // The parameter list is semicolon separated; the value runs to the next
        // one or to the end of the line.
        let rest = fmtp[range.upperBound...]
        let value = rest.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
        let halves = value.split(separator: ",", omittingEmptySubsequences: false)
        guard halves.count >= 2,
              let sps = Data(base64Encoded: String(halves[0])), !sps.isEmpty,
              let pps = Data(base64Encoded: String(halves[1])), !pps.isEmpty else { return nil }
        return (sps, pps)
    }

    /// An SDP `a=control` value resolved against the address it came from.
    ///
    /// `*` means "the stream you asked about"; a relative value hangs off the
    /// base; an absolute one is used as it stands. Cameras of this kind use all
    /// three, sometimes in the same firmware line.
    static func absolute(_ control: String, against base: String) -> String {
        let c = control.trimmingCharacters(in: .whitespaces)
        if c.isEmpty || c == "*" { return base }
        if c.lowercased().hasPrefix("rtsp://") { return c }
        return base.hasSuffix("/") ? base + c : base + "/" + c
    }

    // MARK: - The bytes half

    /// H.264 NAL units out of one RTP payload, per RFC 6184.
    ///
    /// `fragment` carries a FU-A across calls: a keyframe from a camera of this
    /// kind is tens of packets, and the picture only exists once the last one
    /// has arrived. Returns whatever became complete during this call.
    static func nals(fromRtpPayload payload: Data, fragment: inout Data) -> [Data] {
        guard let first = payload.first else { return [] }
        let type = first & 0x1F
        switch type {
        case 1...23:
            // A whole NAL in one packet.
            return [payload]
        case 24:
            // STAP-A: [1-byte header][2-byte size][NAL]…
            var out: [Data] = []
            var i = payload.index(after: payload.startIndex)
            while payload.distance(from: i, to: payload.endIndex) >= 2 {
                let size = Int(payload[i]) << 8 | Int(payload[payload.index(after: i)])
                let start = payload.index(i, offsetBy: 2)
                guard size > 0, payload.distance(from: start, to: payload.endIndex) >= size else { break }
                out.append(Data(payload[start..<payload.index(start, offsetBy: size)]))
                i = payload.index(start, offsetBy: size)
            }
            return out
        case 28:
            // FU-A: [FU indicator][FU header][fragment]
            guard payload.count > 2 else { return [] }
            let indicator = payload[payload.startIndex]
            let fuHeader = payload[payload.index(after: payload.startIndex)]
            let startBit = (fuHeader & 0x80) != 0
            let endBit = (fuHeader & 0x40) != 0
            let body = payload[payload.index(payload.startIndex, offsetBy: 2)...]
            if startBit {
                // Rebuild the original NAL header: F and NRI from the indicator,
                // type from the FU header.
                fragment = Data([(indicator & 0xE0) | (fuHeader & 0x1F)])
            }
            guard !fragment.isEmpty else { return [] }   // joined mid-fragment
            fragment.append(contentsOf: body)
            if endBit {
                let done = fragment
                fragment = Data()
                return [done]
            }
            return []
        default:
            // 25–27 (STAP-B, MTAP) and 29 (FU-B) carry a DON and no camera of
            // this kind emits them. Ignored rather than mis-parsed.
            return []
        }
    }

    /// Strip the 12-byte RTP header (plus any CSRCs and extension) off a packet.
    static func rtpPayload(_ packet: Data) -> Data? {
        guard packet.count > 12 else { return nil }
        let b0 = packet[packet.startIndex]
        guard (b0 >> 6) == 2 else { return nil }                  // version 2
        let csrcCount = Int(b0 & 0x0F)
        var offset = 12 + csrcCount * 4
        if (b0 & 0x10) != 0 {                                      // extension present
            guard packet.count >= offset + 4 else { return nil }
            let lenWords = Int(packet[packet.index(packet.startIndex, offsetBy: offset + 2)]) << 8
                         | Int(packet[packet.index(packet.startIndex, offsetBy: offset + 3)])
            offset += 4 + lenWords * 4
        }
        guard packet.count > offset else { return nil }
        var body = Data(packet[packet.index(packet.startIndex, offsetBy: offset)...])
        if (b0 & 0x20) != 0, let pad = body.last {                 // padding
            guard body.count > Int(pad) else { return nil }
            body.removeLast(Int(pad))
        }
        return body
    }

    /// Is this NAL a picture the decoder can start from on its own?
    static func isKeyframe(_ nal: Data) -> Bool {
        guard let first = nal.first else { return false }
        return (first & 0x1F) == 5           // IDR
    }

    // MARK: - Turning NALs into a picture

    /// Decode one access unit — SPS, PPS and an IDR — into PNG bytes.
    ///
    /// The NALs are handed to VideoToolbox in AVCC form (4-byte lengths), which
    /// is what `CMBlockBuffer` wants; the Annex-B start codes an RTSP stream
    /// never carries in the first place are not involved.
    static func picture(sps: Data, pps: Data, idr: [Data]) -> Data? {
        var format: CMVideoFormatDescription?
        let made: OSStatus = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                guard let sp = s.bindMemory(to: UInt8.self).baseAddress,
                      let pp = p.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                var pointers = [sp, pp]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard made == noErr, let format else { return nil }

        var avcc = Data()
        for nal in idr {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        // ── THE BLOCK BUFFER OWNS ITS BYTES, AND MUST ─────────────────────
        //
        // This used to hand `&bytes` — a Swift `[UInt8]` — straight in, with a
        // null block allocator. That combination means the buffer neither
        // COPIES the bytes nor takes ownership of them: it keeps the pointer.
        // But `&` on an Array is only guaranteed for the duration of the one
        // call it appears in; the compiler may pass a temporary and write it
        // back afterwards. Everything that actually READS the memory —
        // `CMSampleBufferCreateReady` and the decode below — runs after that
        // guarantee has lapsed.
        //
        // It worked, which is the uncomfortable part: the array was still in
        // scope and its storage address happened to be stable. Undefined
        // behaviour that works is the kind that stops working when an optimiser
        // changes its mind, and this is the one place in the app parsing H.264
        // that arrived over the network.
        //
        // So the bytes are malloc'd and handed over with `kCFAllocatorMalloc`:
        // the buffer owns them for as long as it lives and frees them with
        // `free` when it is released. A failed create never took ownership, so
        // that path frees them here.
        let length = avcc.count
        guard length > 0, let owned = malloc(length) else { return nil }
        avcc.copyBytes(to: owned.assumingMemoryBound(to: UInt8.self), count: length)

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: owned, blockLength: length,
                blockAllocator: kCFAllocatorMalloc, customBlockSource: nil,
                offsetToData: 0, dataLength: length, flags: 0,
                blockBufferOut: &block) == noErr, let block
        else { free(owned); return nil }

        var sample: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &sample) == noErr, let sample else { return nil }

        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault, formatDescription: format,
                decoderSpecification: nil,
                imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String:
                                          kCVPixelFormatType_32BGRA] as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &session) == noErr,
              let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }

        var out: CVImageBuffer?
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample,
            flags: [._EnableTemporalProcessing], infoFlagsOut: nil) { _, _, image, _, _ in
                if out == nil { out = image }
            }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard status == noErr, let pixels = out else { return nil }

        let ci = CIImage(cvImageBuffer: pixels)
        let rep = NSCIImageRep(ciImage: ci)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
