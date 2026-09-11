import Foundation
import Network

/// Enough MQTT 3.1.1 to ask a Bambu printer what it is doing.
///
/// ── WHY THIS IS SWIFT AND NOT A SHARED MODULE ─────────────────────────────
///
/// Every other protocol this app speaks is HTTP, so the request is `URLSession`
/// and the MEANING is a shared `lib/` module. Bambu has no HTTP at all: it
/// speaks MQTT over TLS on 8883 and FTPS on 990, and nothing else on the LAN.
///
/// The other app hand-rolls the same small slice of MQTT in `lib/bambu.js`,
/// over Node's `Buffer` and `node:tls` — which is why that file cannot be
/// loaded here at all: `Buffer` is in its module scope from the first line, so
/// it throws before a single function is reachable. The part that decides what
/// a shop SEES was lifted out to `lib/bambu-report.js` and both apps run it.
/// This is the transport underneath, and a transport is each app's own.
///
/// `BambuCodecParityTests` checks these bytes against the ones `lib/bambu.js`
/// writes, packet for packet. Two hand-rolled codecs that agree by inspection
/// are two codecs that will diverge; ones that agree by test are one codec.
///
/// ── TWO SWITCHES ON THE PRINTER, AND THE SECOND IS USUALLY OFF ────────────
///
/// LAN-only Mode is what the guides say to turn on and it is not enough. Bambu
/// gates MQTT behind a separate **Developer Mode** in the same menu. With LAN
/// on and Developer off the printer accepts the TLS connection AND the CONNACK
/// and then never speaks — nothing is refused, so there is no error to report
/// and the attempt simply runs out its clock. That is why the timeout message
/// names Developer Mode first: any message naming IP, access code and LAN mode
/// would be listing three things that are all correct.
enum BambuMqtt {

    static let defaultPort: UInt16 = 8883

    // MARK: - The wire codec

    /// MQTT's variable-byte "Remaining Length".
    static func remainingLength(_ n: Int) -> [UInt8] {
        precondition(n >= 0)
        var value = n
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value % 128)
            value /= 128
            if value > 0 { byte |= 0x80 }
            out.append(byte)
        } while value > 0
        return out
    }

    /// Decode one, from `offset`. Nil when the buffer does not hold it yet —
    /// which is the normal case on a stream, not an error.
    static func readRemainingLength(_ buf: [UInt8], at offset: Int) throws -> (value: Int, bytes: Int)? {
        var multiplier = 1, value = 0, bytes = 0
        while true {
            guard offset + bytes < buf.count else { return nil }
            let b = buf[offset + bytes]
            value += Int(b & 0x7f) * multiplier
            bytes += 1
            if b & 0x80 == 0 { break }
            multiplier *= 128
            if multiplier > 128 * 128 * 128 { throw Trouble.malformed }
        }
        return (value, bytes)
    }

    /// A length-prefixed UTF-8 string: two big-endian bytes, then the bytes.
    static func string(_ s: String) -> [UInt8] {
        let bytes = Array(s.utf8)
        return [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)] + bytes
    }

    static func packet(_ typeFlags: UInt8, _ body: [UInt8]) -> [UInt8] {
        [typeFlags] + remainingLength(body.count) + body
    }

    /// CONNECT. The username is always `bblp`; the password is the printer's
    /// LAN access code, from its own screen.
    static func connect(clientId: String, username: String, password: String,
                        keepalive: UInt16 = 60) -> [UInt8] {
        var body = string("MQTT")
        body.append(0x04)                                   // protocol level 4 = 3.1.1
        body.append(0xC2)                                   // username + password + clean session
        body.append(UInt8(keepalive >> 8))
        body.append(UInt8(keepalive & 0xff))
        body += string(clientId)
        body += string(username)
        body += string(password)
        return packet(0x10, body)
    }

    static func subscribe(packetId: UInt16, topic: String) -> [UInt8] {
        var body: [UInt8] = [UInt8(packetId >> 8), UInt8(packetId & 0xff)]
        body += string(topic)
        body.append(0x00)                                   // QoS 0
        return packet(0x82, body)                           // SUBSCRIBE requires flags 0b0010
    }

    static func publish(topic: String, payload: String) -> [UInt8] {
        packet(0x30, string(topic) + Array(payload.utf8))   // QoS 0, so no packet id
    }

    static let pingreq: [UInt8] = [0xC0, 0x00]
    static let disconnect: [UInt8] = [0xE0, 0x00]

    struct Packet: Equatable {
        let type: UInt8
        let body: [UInt8]
    }

    /// Split whole packets off the front of a stream, returning what is left.
    /// A TLS read is not a message boundary — a report arrives in pieces and
    /// two small ones arrive together.
    static func packets(from buf: [UInt8]) throws -> (packets: [Packet], rest: [UInt8]) {
        var out: [Packet] = []
        var at = 0
        while at < buf.count {
            guard let length = try readRemainingLength(buf, at: at + 1) else { break }
            let start = at + 1 + length.bytes
            let end = start + length.value
            guard end <= buf.count else { break }
            out.append(Packet(type: buf[at] >> 4, body: Array(buf[start..<end])))
            at = end
        }
        return (out, Array(buf[at...]))
    }

    /// The topic and payload of a QoS-0 PUBLISH.
    static func decodePublish(_ body: [UInt8]) -> (topic: String, payload: String)? {
        guard body.count >= 2 else { return nil }
        let length = Int(body[0]) << 8 | Int(body[1])
        guard body.count >= 2 + length else { return nil }
        let topic = String(decoding: body[2..<(2 + length)], as: UTF8.self)
        let payload = String(decoding: body[(2 + length)...], as: UTF8.self)
        return (topic, payload)
    }

    // MARK: - What can go wrong

    /// A typed failure and NO prose.
    ///
    /// The words a shop reads live in `PrinterWatch.say`, with every other
    /// printer diagnostic — a transport that owns user-facing copy is a
    /// transport that has to be opened to change a sentence, and the message
    /// about Developer Mode is one somebody will want to reword.
    enum Trouble: Error, Equatable {
        case malformed
        /// The printer turned the access code down. The CONNACK code it gave.
        case refused(UInt8)
        /// It accepted the connection and then said nothing. This is what
        /// Developer Mode being off looks like, and ONLY that: a wrong access
        /// code is refused with a CONNACK and a wrong address never connects.
        case silent
        case closed(String)
    }
}

// MARK: - The live connection

/// One conversation with a Bambu printer: connect, subscribe, ask, take the
/// first real answer, hang up.
///
/// An actor because the thing it guards is a socket and a buffer of bytes that
/// arrive on the network queue while the caller waits on a continuation.
///
/// ── SELF-SIGNED, AND WHY THAT IS NOT A HOLE HERE ──────────────────────────
///
/// A Bambu printer presents a certificate it signed itself, for a name that is
/// not its LAN address, and there is no way to obtain a real one for a device
/// on a home network. So the certificate is not checked — the same thing the
/// other app does, and the only thing that can be done.
///
/// What makes that acceptable is what is sent: the access code goes only to the
/// address the shop typed, the channel is still encrypted against a passive
/// listener, and the printer is on the shop's own LAN. What would NOT be
/// acceptable is following the printer somewhere else — which is the camera bug
/// this app already fixed — and MQTT has no redirect to follow.
actor BambuConversation {
    private let host: String
    private let port: UInt16
    private let accessCode: String
    private let serial: String
    private let timeout: Duration

    init(host: String, port: UInt16, accessCode: String, serial: String,
         timeout: Duration = .seconds(8)) {
        self.host = host
        self.port = port == 0 ? BambuMqtt.defaultPort : port
        self.accessCode = accessCode
        self.serial = serial
        self.timeout = timeout
    }

    /// Ask for a full snapshot and return the first report that carries one.
    ///
    /// `pushall` rather than waiting: a Bambu pushes small deltas continuously
    /// and a full state only when asked. Waiting for one to arrive by itself
    /// means waiting for a change, so an idle printer would time out — which
    /// looks exactly like Developer Mode being off and is not.
    func status() async throws -> String {
        try await run(
            ask: { BambuMqtt.publish(topic: "device/\(self.serial)/request",
                                     payload: #"{"pushing":{"sequence_id":"0","command":"pushall"}}"#) },
            take: { payload in
                // A delta is not an answer. The shared module returns nil for
                // one, and taking the first message regardless would report a
                // printer as Idle because the delta it happened to send carried
                // no state at all.
                payload.contains("gcode_state") || payload.contains("mc_percent")
                    || payload.contains("subtask_name") ? payload : nil
            })
    }

    /// Start a file already on the printer. The upload is FTPS and is not this.
    func startPrint(fileName: String) async throws -> String {
        let command: [String: Any] = ["print": [
            "sequence_id": "0", "command": "project_file",
            "param": "Metadata/plate_1.gcode",
            "url": "file:///sdcard/\(fileName)", "subtask_name": fileName,
            "use_ams": false, "timelapse": false, "bed_leveling": true,
            "flow_cali": false, "vibration_cali": false, "layer_inspect": false,
        ]]
        let body = String(decoding: try JSONSerialization.data(withJSONObject: command),
                          as: UTF8.self)
        return try await run(
            ask: { BambuMqtt.publish(topic: "device/\(self.serial)/request", payload: body) },
            take: { $0.contains("\"print\"") ? $0 : nil })
    }

    private func run(ask: @escaping @Sendable () -> [UInt8],
                     take: @escaping @Sendable (String) -> String?) async throws -> String {
        let options = NWProtocolTLS.Options()
        // See the note on this type. There is no certificate to verify against.
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, _, complete in complete(true) },
            DispatchQueue.global(qos: .userInitiated))

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 8883),
            using: NWParameters(tls: options))

        let box = Mailbox()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let id = "khayt-" + String(Int(Date().timeIntervalSince1970) % 10_000_000, radix: 36)
                connection.send(content: Data(BambuMqtt.connect(
                    clientId: id, username: "bblp",
                    password: self.accessCode)), completion: .idempotent)
            case .failed(let error):
                Task { await box.fail(BambuMqtt.Trouble.closed(error.localizedDescription)) }
            case .cancelled:
                Task { await box.fail(BambuMqtt.Trouble.closed("cancelled")) }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        defer {
            connection.send(content: Data(BambuMqtt.disconnect), completion: .idempotent)
            connection.cancel()
        }

        receive(on: connection, into: box, ask: ask, take: take)

        // The clock runs from here rather than from `.ready`, so a printer that
        // never finishes its handshake is bounded too.
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await box.wait() }
            group.addTask {
                try await Task.sleep(for: self.timeout)
                throw BambuMqtt.Trouble.silent
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Drain the socket, feeding whole packets through the state machine.
    private nonisolated func receive(on connection: NWConnection, into box: Mailbox,
                                     ask: @escaping @Sendable () -> [UInt8],
                                     take: @escaping @Sendable (String) -> String?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
            if let error {
                Task { await box.fail(BambuMqtt.Trouble.closed(error.localizedDescription)) }
                return
            }
            if let data, !data.isEmpty {
                Task {
                    do {
                        for packet in try await box.take(Array(data)) {
                            switch packet.type {
                            case 2:     // CONNACK
                                let code = packet.body.count >= 2 ? packet.body[1] : 0xff
                                guard code == 0 else {
                                    await box.fail(BambuMqtt.Trouble.refused(code)); return
                                }
                                connection.send(content: Data(BambuMqtt.subscribe(
                                    packetId: 1, topic: "device/\(self.serial)/report")),
                                                completion: .idempotent)
                            case 9:     // SUBACK — the printer is listening
                                connection.send(content: Data(ask()), completion: .idempotent)
                            case 3:     // PUBLISH
                                if let decoded = BambuMqtt.decodePublish(packet.body),
                                   let answer = take(decoded.payload) {
                                    await box.deliver(answer)
                                }
                            default:
                                break
                            }
                        }
                    } catch {
                        await box.fail(error)
                    }
                }
            }
            if done {
                Task { await box.fail(BambuMqtt.Trouble.closed("hungUp")) }
                return
            }
            self.receive(on: connection, into: box, ask: ask, take: take)
        }
    }

    /// The answer, the bytes still waiting for the rest of themselves, and
    /// whoever is waiting on either.
    private actor Mailbox {
        private var pending: [UInt8] = []
        private var answer: Result<String, Error>?
        private var waiting: CheckedContinuation<String, Error>?

        func take(_ chunk: [UInt8]) throws -> [BambuMqtt.Packet] {
            pending += chunk
            let read = try BambuMqtt.packets(from: pending)
            pending = read.rest
            return read.packets
        }

        func deliver(_ value: String) { settle(.success(value)) }
        func fail(_ error: Error) { settle(.failure(error)) }

        private func settle(_ result: Result<String, Error>) {
            guard answer == nil else { return }
            answer = result
            if let waiting { self.waiting = nil; waiting.resume(with: result) }
        }

        func wait() async throws -> String {
            if let answer { return try answer.get() }
            return try await withCheckedThrowingContinuation { continuation in
                if let answer { continuation.resume(with: answer) }
                else { waiting = continuation }
            }
        }
    }
}
