import Testing
import Foundation
@testable import KhaytApp

/// The half of RTSP that is bytes rather than a socket.
///
/// Everything here runs without a camera on the bench, which is the point of the
/// split: the parsing is where the mistakes are, and a mistake in it is
/// invisible from the outside — a session that connects, plays, and produces a
/// grey rectangle forever.
struct RtspTests {

    // MARK: - The response head

    @Test func readsTheStatusLine() {
        #expect(Rtsp.status(of: "RTSP/1.0 200 OK\r\nCSeq: 1") == 200)
        #expect(Rtsp.status(of: "RTSP/1.0 404 Stream Not Found\r\nCSeq: 2") == 404)
        #expect(Rtsp.status(of: "RTSP/1.0 401 Unauthorized") == 401)
        #expect(Rtsp.status(of: "HTTP/1.1 200 OK") == nil, "an HTTP server is not an RTSP camera")
        #expect(Rtsp.status(of: "") == nil)
    }

    @Test func headersAreCaseInsensitiveAndTrimmed() {
        let head = "RTSP/1.0 200 OK\r\nCSeq: 3\r\nContent-Length:  147 \r\nSession: 12345678;timeout=60"
        #expect(Rtsp.header("content-length", in: head) == "147")
        #expect(Rtsp.header("CSeq", in: head) == "3")
        #expect(Rtsp.header("Session", in: head) == "12345678;timeout=60")
        #expect(Rtsp.header("Transport", in: head) == nil)
    }

    @Test func theStatusLineIsNeverReadAsAHeader() {
        // "RTSP/1.0 200 OK" contains a colon in neither half, but a camera that
        // answered "RTSP/1.0 200 OK: fine" would — and the first line is a
        // status, not a header, whatever is in it.
        #expect(Rtsp.header("RTSP/1.0 200 OK", in: "RTSP/1.0 200 OK\r\nCSeq: 1") == nil)
    }

    // MARK: - SDP

    /// A description of the shape these cameras send: one video track, H.264,
    /// with its parameter sets inline.
    private let sdp = """
    v=0
    o=- 0 0 IN IP4 192.168.68.71
    s=Live
    m=video 0 RTP/AVP 96
    a=rtpmap:96 H264/90000
    a=fmtp:96 packetization-mode=1;profile-level-id=42001f;sprop-parameter-sets=Z0IAH6tAWA0IAAADAAgAAAMBlCA=,aM48gA==
    a=control:trackID=0
    """

    @Test func findsTheVideoTrackAndItsParameterSets() throws {
        let d = try #require(Rtsp.describe(sdp: sdp, base: "rtsp://192.168.68.71/live"))
        #expect(d.control == "rtsp://192.168.68.71/live/trackID=0")
        #expect(!d.sps.isEmpty && !d.pps.isEmpty)
        // An SPS begins with a NAL header whose type is 7; a PPS, 8. If these
        // are the wrong way round the decoder produces nothing and says nothing.
        #expect((d.sps[d.sps.startIndex] & 0x1F) == 7)
        #expect((d.pps[d.pps.startIndex] & 0x1F) == 8)
    }

    @Test func theAudioTracksControlIsNotUsed() throws {
        // A camera with a microphone puts its own a=control in the audio
        // section. Aiming SETUP at that gives a session that plays perfectly and
        // never produces a picture — which looks like a decoder bug for hours.
        let withAudio = """
        v=0
        m=audio 0 RTP/AVP 8
        a=control:trackID=1
        m=video 0 RTP/AVP 96
        a=fmtp:96 sprop-parameter-sets=Z0IAH6tAWA0IAAADAAgAAAMBlCA=,aM48gA==
        a=control:trackID=0
        """
        let d = try #require(Rtsp.describe(sdp: withAudio, base: "rtsp://cam/live"))
        #expect(d.control.hasSuffix("trackID=0"))
    }

    @Test func aDescriptionWithNoVideoIsRefusedRatherThanGuessed() {
        #expect(Rtsp.describe(sdp: "v=0\r\nm=audio 0 RTP/AVP 8\r\na=control:trackID=1", base: "rtsp://cam/") == nil)
        #expect(Rtsp.describe(sdp: "", base: "rtsp://cam/") == nil)
        // Video, but no parameter sets: there is nothing to build a decoder from
        // and pretending otherwise gives a green frame.
        #expect(Rtsp.describe(sdp: "m=video 0 RTP/AVP 96\r\na=fmtp:96 packetization-mode=1", base: "rtsp://cam/") == nil)
    }

    @Test func controlUrlsComeInAllThreeShapes() {
        #expect(Rtsp.absolute("trackID=0", against: "rtsp://cam/live") == "rtsp://cam/live/trackID=0")
        #expect(Rtsp.absolute("trackID=0", against: "rtsp://cam/live/") == "rtsp://cam/live/trackID=0")
        #expect(Rtsp.absolute("rtsp://cam/live/track1", against: "rtsp://cam/live") == "rtsp://cam/live/track1")
        #expect(Rtsp.absolute("*", against: "rtsp://cam/live") == "rtsp://cam/live")
        #expect(Rtsp.absolute("", against: "rtsp://cam/live") == "rtsp://cam/live")
    }

    // MARK: - RTP

    private func rtp(payload: [UInt8], marker: Bool = false, csrcs: Int = 0,
                     padding: [UInt8] = []) -> Data {
        var p: [UInt8] = [0x80 | UInt8(csrcs), marker ? 0xE0 : 0x60, 0, 1,  0, 0, 0, 1,  0, 0, 0, 2]
        if !padding.isEmpty { p[0] |= 0x20 }
        p[0] |= UInt8(csrcs)
        p.append(contentsOf: Array(repeating: 0, count: csrcs * 4))
        p.append(contentsOf: payload)
        p.append(contentsOf: padding)
        return Data(p)
    }

    @Test func stripsTheRtpHeaderIncludingCsrcsAndPadding() throws {
        let plain = try #require(Rtsp.rtpPayload(rtp(payload: [0x65, 0xAA, 0xBB])))
        #expect(Array(plain) == [0x65, 0xAA, 0xBB])

        let withCsrc = try #require(Rtsp.rtpPayload(rtp(payload: [0x65, 0x01], csrcs: 2)))
        #expect(Array(withCsrc) == [0x65, 0x01], "two CSRCs are eight more bytes of header")

        // Padding: the last byte says how many bytes to drop, itself included.
        let padded = try #require(Rtsp.rtpPayload(rtp(payload: [0x65, 0x01], padding: [0, 0, 3])))
        #expect(Array(padded) == [0x65, 0x01])

        #expect(Rtsp.rtpPayload(Data([0x80, 0x60])) == nil, "too short to be a packet")
        #expect(Rtsp.rtpPayload(Data(repeating: 0, count: 20)) == nil, "version must be 2")
    }

    @Test func aWholeNalInOnePacket() {
        var fragment = Data()
        let out = Rtsp.nals(fromRtpPayload: Data([0x65, 1, 2, 3]), fragment: &fragment)
        #expect(out.count == 1)
        #expect(Array(out[0]) == [0x65, 1, 2, 3])
    }

    @Test func stapAUnpacksSeveralNalsFromOnePacket() {
        // How a camera usually sends SPS and PPS: aggregated ahead of the IDR.
        var fragment = Data()
        let packet = Data([0x78,            // STAP-A header
                           0, 3, 0x67, 1, 2, // SPS, 3 bytes
                           0, 2, 0x68, 9])   // PPS, 2 bytes
        let out = Rtsp.nals(fromRtpPayload: packet, fragment: &fragment)
        #expect(out.count == 2)
        #expect(Array(out[0]) == [0x67, 1, 2])
        #expect(Array(out[1]) == [0x68, 9])
    }

    @Test func stapAWithATruncatedSizeStopsRatherThanReadingPastTheEnd() {
        var fragment = Data()
        // Says 9 bytes and supplies 2.
        let out = Rtsp.nals(fromRtpPayload: Data([0x78, 0, 9, 0x67, 1]), fragment: &fragment)
        #expect(out.isEmpty)
    }

    @Test func fuAReassemblesAKeyframeAcrossPackets() {
        // A keyframe is tens of packets and the picture only exists once the
        // last has arrived. Start bit, then middles, then end bit.
        var fragment = Data()
        let start = Data([0x7C, 0x85, 0xAA])       // FU-A, S=1, type 5 (IDR)
        let middle = Data([0x7C, 0x05, 0xBB])
        let end = Data([0x7C, 0x45, 0xCC])         // E=1

        #expect(Rtsp.nals(fromRtpPayload: start, fragment: &fragment).isEmpty)
        #expect(Rtsp.nals(fromRtpPayload: middle, fragment: &fragment).isEmpty)
        let out = Rtsp.nals(fromRtpPayload: end, fragment: &fragment)

        #expect(out.count == 1)
        // The rebuilt NAL header keeps F and NRI from the indicator and takes
        // its TYPE from the FU header — 0x7C's top bits with type 5 is 0x65.
        #expect(Array(out[0]) == [0x65, 0xAA, 0xBB, 0xCC])
        #expect(fragment.isEmpty, "the buffer is cleared for the next picture")
    }

    @Test func aFragmentJoinedInTheMiddleIsDiscarded() {
        // Khayt opens the session mid-stream, so the first packets it sees are
        // very often the tail of a picture whose start it never had. Appending
        // them to nothing produces a NAL with no header and a decoder that
        // fails in a way nobody can read.
        var fragment = Data()
        let middle = Data([0x7C, 0x05, 0xBB])
        let end = Data([0x7C, 0x45, 0xCC])
        #expect(Rtsp.nals(fromRtpPayload: middle, fragment: &fragment).isEmpty)
        #expect(Rtsp.nals(fromRtpPayload: end, fragment: &fragment).isEmpty)
    }

    @Test func typesThatCarryADecodingOrderNumberAreIgnored() {
        // 25–27 and 29 are STAP-B, MTAP16, MTAP24 and FU-B. No camera of this
        // kind emits them, and mis-parsing one is worse than skipping it.
        var fragment = Data()
        for type: UInt8 in [25, 26, 27, 29, 30, 31, 0] {
            #expect(Rtsp.nals(fromRtpPayload: Data([type, 1, 2, 3]), fragment: &fragment).isEmpty)
        }
    }

    @Test func knowsAKeyframeFromTheRest() {
        #expect(Rtsp.isKeyframe(Data([0x65, 1])) == true)   // IDR
        #expect(Rtsp.isKeyframe(Data([0x41, 1])) == false)  // a later picture
        #expect(Rtsp.isKeyframe(Data([0x67, 1])) == false)  // SPS
        #expect(Rtsp.isKeyframe(Data()) == false)
    }

    // MARK: - The address

    @Test func onlyAnRtspAddressOpensASession() async {
        for bad in ["http://192.168.68.71/live", "192.168.68.71", "", "rtsp://", "not a url"] {
            #expect(throws: (any Error).self) { try RtspSession(url: bad) }
        }
        #expect(throws: Never.self) { try RtspSession(url: "rtsp://192.168.68.71/live") }
        #expect(throws: Never.self) { try RtspSession(url: "rtsp://192.168.68.71:8554/live") }
    }
}
