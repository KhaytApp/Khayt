import Foundation
import Network

/// The conversation with an RTSP camera: DESCRIBE, SETUP, PLAY, one keyframe,
/// TEARDOWN.
///
/// Separate from `Rtsp` because everything in there is a pure function over
/// bytes and can be tested without a camera on the bench; everything in here is
/// a socket and cannot. That split is the same one `PrinterWatch` makes, and for
/// the same reason: the parsing is where the bugs are cheap to find and the
/// transport is where they are expensive.
actor RtspSession {

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let url: String
    private var connection: NWConnection?
    private var cseq = 0
    private var buffer = Data()
    /// Some cameras want the session id on every message after SETUP.
    private var session: String?

    /// Fails early on anything that is not `rtsp://host[:port]/path`.
    init(url raw: String) throws {
        guard let parsed = URL(string: raw),
              parsed.scheme?.lowercased() == "rtsp",
              let h = parsed.host, !h.isEmpty else { throw Rtsp.Failure.notRtsp }
        self.url = raw
        self.host = NWEndpoint.Host(h)
        self.port = NWEndpoint.Port(rawValue: UInt16(parsed.port ?? 554)) ?? 554
    }

    /// One still, as PNG bytes.
    ///
    /// `deadline` covers the whole conversation. A camera that is switched on
    /// but has not been told to publish a local stream answers DESCRIBE with
    /// `404 Stream Not Found` immediately — which is a fast, clear failure and
    /// the state a Buddy3D is in until "RTSP stream on local network" is turned
    /// on in the Prusa app.
    func still(within deadline: Duration = .seconds(12)) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.run() }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw Rtsp.Failure.timedOut
            }
            guard let first = try await group.next() else { throw Rtsp.Failure.timedOut }
            group.cancelAll()
            return first
        }
    }

    private func run() async throws -> Data {
        try await connect()
        defer { close() }

        let described = try await describe()
        try await setup(track: described.control)
        try await play()

        // Collect until a complete IDR arrives. SPS and PPS came from the SDP,
        // but a camera that also sends them in-band is believed over the SDP:
        // a mid-stream parameter change is exactly when the SDP goes stale.
        var sps = described.sps
        var pps = described.pps
        var fragment = Data()
        var picture: [Data] = []

        while true {
            let packet = try await nextInterleaved()
            guard let payload = Rtsp.rtpPayload(packet) else { continue }
            for nal in Rtsp.nals(fromRtpPayload: payload, fragment: &fragment) {
                switch nal.first.map({ $0 & 0x1F }) {
                case 7: sps = nal
                case 8: pps = nal
                case 5:
                    picture.append(nal)
                    if let png = Rtsp.picture(sps: sps, pps: pps, idr: picture) {
                        try? await teardown()
                        return png
                    }
                    picture.removeAll()
                default: break
                }
            }
        }
    }

    // MARK: - The socket

    /// A continuation must be resumed exactly once, and `stateUpdateHandler` is
    /// called repeatedly from a queue that is not this actor. A captured `var`
    /// cannot be the latch — Swift 6 refuses it, correctly, because two state
    /// changes can race and resuming twice is a crash rather than a bug you get
    /// to read about later.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        /// True exactly once, to whichever caller gets there first.
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }

    private func connect() async throws {
        let c = NWConnection(host: host, port: port, using: .tcp)
        connection = c
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let once = Once()
            c.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { k.resume() }
                case .failed(let e): if once.claim() { k.resume(throwing: e) }
                case .cancelled: if once.claim() { k.resume(throwing: Rtsp.Failure.timedOut) }
                default: break
                }
            }
            c.start(queue: .global(qos: .userInitiated))
        }
    }

    private func close() {
        connection?.cancel()
        connection = nil
    }

    private func send(_ text: String) async throws {
        guard let c = connection else { throw Rtsp.Failure.timedOut }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            c.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { k.resume(throwing: error) } else { k.resume() }
            })
        }
    }

    /// Read more bytes onto `buffer`. Returns false at end of stream.
    @discardableResult
    private func fill() async throws -> Bool {
        guard let c = connection else { return false }
        let chunk: Data? = try await withCheckedThrowingContinuation { k in
            c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
                if let error { k.resume(throwing: error) }
                else if let data, !data.isEmpty { k.resume(returning: data) }
                else { k.resume(returning: done ? nil : Data()) }
            }
        }
        guard let chunk else { return false }
        buffer.append(chunk)
        return true
    }

    // MARK: - The messages

    private func request(_ verb: String, _ target: String, extra: [String: String] = [:]) async throws -> (head: String, body: String) {
        cseq += 1
        var lines = ["\(verb) \(target) RTSP/1.0", "CSeq: \(cseq)", "User-Agent: Khayt"]
        if let session { lines.append("Session: \(session)") }
        for (k, v) in extra.sorted(by: { $0.key < $1.key }) { lines.append("\(k): \(v)") }
        try await send(lines.joined(separator: "\r\n") + "\r\n\r\n")

        // Head first. Interleaved data can arrive before a response once PLAY is
        // running, so anything starting with `$` is set aside rather than
        // mistaken for a header.
        while true {
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                let length = Rtsp.header("Content-Length", in: head).flatMap(Int.init) ?? 0
                while buffer.count < length { guard try await fill() else { break } }
                let body = String(decoding: buffer.prefix(length), as: UTF8.self)
                buffer.removeFirst(min(length, buffer.count))
                guard let code = Rtsp.status(of: head) else { throw Rtsp.Failure.notRtsp }
                guard code == 200 else { throw Rtsp.Failure.refused(code) }
                if let s = Rtsp.header("Session", in: head) {
                    session = s.split(separator: ";").first.map(String.init)
                }
                return (head, body)
            }
            guard try await fill() else { throw Rtsp.Failure.timedOut }
        }
    }

    private func describe() async throws -> Rtsp.Described {
        let (_, body) = try await request("DESCRIBE", url, extra: ["Accept": "application/sdp"])
        guard let d = Rtsp.describe(sdp: body, base: url) else { throw Rtsp.Failure.noVideoTrack }
        guard !d.sps.isEmpty, !d.pps.isEmpty else { throw Rtsp.Failure.noParameterSets }
        return d
    }

    private func setup(track: String) async throws {
        _ = try await request("SETUP", track,
                              extra: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"])
    }

    private func play() async throws {
        _ = try await request("PLAY", url, extra: ["Range": "npt=0.000-"])
    }

    private func teardown() async throws {
        _ = try? await request("TEARDOWN", url)
    }

    /// The next RTP packet off the interleaved channel.
    ///
    /// Framing is `$` then a one-byte channel then a two-byte big-endian length.
    /// Channel 1 is RTCP on the transport asked for above and is skipped.
    private func nextInterleaved() async throws -> Data {
        while true {
            while buffer.count < 4 { guard try await fill() else { throw Rtsp.Failure.timedOut } }
            guard buffer[buffer.startIndex] == 0x24 else {
                // Not interleaved data — an announcement or a stray response.
                // Drop one byte and resynchronise rather than reading a length
                // out of the middle of a header.
                buffer.removeFirst()
                continue
            }
            let channel = buffer[buffer.index(buffer.startIndex, offsetBy: 1)]
            let length = Int(buffer[buffer.index(buffer.startIndex, offsetBy: 2)]) << 8
                       | Int(buffer[buffer.index(buffer.startIndex, offsetBy: 3)])
            while buffer.count < 4 + length { guard try await fill() else { throw Rtsp.Failure.timedOut } }
            let packet = Data(buffer[buffer.index(buffer.startIndex, offsetBy: 4)..<buffer.index(buffer.startIndex, offsetBy: 4 + length)])
            buffer.removeFirst(4 + length)
            if channel == 0 { return packet }
        }
    }
}
