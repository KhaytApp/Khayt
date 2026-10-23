import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The held Bambu connection (S2) and its job commands (S11), over a fake link.
///
/// No Bambu is on this bench and none can be put on this Mac's network, so the
/// fixture is the documents: OpenBambuAPI `mqtt.md` for the request and report
/// shapes and the P1's "pushall no more than every 5 minutes", ha-bambulab's
/// `pybambu/bambu_client.py` for the 60 s watchdog. What is checked is every
/// decision the session makes about those bytes — which it sends, when, and
/// what it believes afterwards.
@MainActor
struct BambuSessionTests {

    // MARK: Fixtures

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    }

    final class FakeLink: BambuLink, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [[UInt8]] = []
        private var _closed = false
        var sent: [[UInt8]] { lock.withLock { _sent } }
        var closed: Bool { lock.withLock { _closed } }
        var verifiedByBambu: Bool? { nil }
        func start(_ handler: @escaping @Sendable (BambuLinkEvent) -> Void) {}
        func send(_ bytes: [UInt8]) { lock.withLock { _sent.append(bytes) } }
        func close() { lock.withLock { _closed = true } }
        /// Payloads of every PUBLISH this link carried.
        var published: [String] {
            sent.compactMap { bytes in
                guard bytes.first == 0x30, let p = try? BambuMqtt.packets(from: bytes).packets.first,
                      let d = BambuMqtt.decodePublish(p.body) else { return nil }
                return d.payload
            }
        }
    }

    final class Links: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [FakeLink] = []
        var made: [FakeLink] { lock.withLock { all } }
        func make() -> FakeLink { let l = FakeLink(); lock.withLock { all.append(l) }; return l }
    }

    static let serial = "01P00A000000000"
    static let config = BambuSession.Config(host: "192.168.68.70", port: 8883, serial: serial,
                                            accessCode: "12345678")
    static let full = #"{"print":{"gcode_state":"RUNNING","mc_percent":42,"subtask_name":"bracket.3mf","mc_remaining_time":87,"nozzle_temper":219.5,"bed_temper":60,"layer_num":134,"total_layer_num":318,"command":"push_status"}}"#

    static func session(_ clock: Clock, _ links: Links, ledger: PushallLedger = PushallLedger())
        -> BambuSession {
        BambuSession(config: config, accessCode: "12345678",
                     makeLink: { _ in links.make() }, now: { clock.now }, ledger: ledger)
    }

    static let connack: [UInt8] = [0x20, 0x02, 0x00, 0x00]
    static let suback: [UInt8] = [0x90, 0x03, 0x00, 0x01, 0x00]
    static func report(_ payload: String) -> [UInt8] {
        BambuMqtt.publish(topic: "device/\(serial)/report", payload: payload)
    }

    /// Drive a fresh link through CONNECT → CONNACK → SUBACK.
    static func handshake(_ s: BambuSession) async {
        await s.feed(.ready)
        await s.feed(.bytes(connack))
        await s.feed(.bytes(suback))
    }

    // MARK: S2 — one connection, deltas merged

    @Test("one connection: CONNECT with the access code, SUBSCRIBE to the report topic, then pushall")
    func connectSubscribePushall() async throws {
        let clock = Clock(), links = Links()
        let s = Self.session(clock, links)
        await s.tick()
        #expect(links.made.count == 1)
        await Self.handshake(s)
        let sent = links.made[0].sent
        #expect(sent.count == 3)
        #expect(sent[0].first == 0x10, "CONNECT first")
        #expect(sent[1] == BambuMqtt.subscribe(packetId: 1, topic: "device/\(Self.serial)/report"))
        #expect(sent[2] == BambuMqtt.publish(topic: "device/\(Self.serial)/request",
                                             payload: #"{"pushing":{"sequence_id":"0","command":"pushall"}}"#))
        #expect(await s.phase == .subscribed)
    }

    @Test("deltas lay over the full report, and the sweep reads the merged state")
    func deltaMerge() async throws {
        let clock = Clock(), links = Links()
        let s = Self.session(clock, links)
        await s.tick()
        await Self.handshake(s)
        // A delta before any full report is not a status.
        await s.feed(.bytes(Self.report(#"{"print":{"nozzle_temper":200}}"#)))
        await #expect(throws: (any Error).self) { _ = try await s.status() }

        await s.feed(.bytes(Self.report(Self.full)))
        // P1-style deltas: only what changed, and two arriving in one read.
        await s.feed(.bytes(Self.report(#"{"print":{"mc_percent":43,"layer_num":135}}"#)
                            + Self.report(#"{"print":{"nozzle_temper":221}}"#)))
        let engine = try KhaytEngine()
        let merged = try await s.status()
        let read = try await engine.bambuStatus(held: merged)
        let status = try #require(read)
        #expect(status.progress == 43)
        #expect(status.state == "Printing")
        #expect(status.filename == "bracket.3mf")
        #expect(status.tempNozzle == 221)
        #expect(status.tempBed == 60)
        #expect(status.timeRemaining == Double(87 * 60))
        #expect(status.fault == nil)
        // A report split across two reads is reassembled, not dropped.
        let whole = Self.report(#"{"print":{"mc_percent":44}}"#)
        await s.feed(.bytes(Array(whole.prefix(7))))
        await s.feed(.bytes(Array(whole.dropFirst(7))))
        let after = try await s.status()
        let reread = try await engine.bambuStatus(held: after)
        #expect(reread?.progress == 44)
    }

    @Test("a report on another printer's topic is not this printer's")
    func otherTopicIgnored() async throws {
        let clock = Clock(), links = Links()
        let s = Self.session(clock, links)
        await s.tick()
        await Self.handshake(s)
        await s.feed(.bytes(BambuMqtt.publish(topic: "device/OTHER/report", payload: Self.full)))
        #expect(await s.held == nil)
    }

    // MARK: S2 — the pushall rate limit

    @Test("pushall goes once on connect and not again inside five minutes, even across reconnects")
    func pushallRateLimit() async throws {
        let clock = Clock(), links = Links(), ledger = PushallLedger()
        let s = Self.session(clock, links, ledger: ledger)
        let pushall = #"{"pushing":{"sequence_id":"0","command":"pushall"}}"#
        await s.tick()
        await Self.handshake(s)
        await s.feed(.bytes(Self.report(Self.full)))
        #expect(links.made[0].published == [pushall])

        // Silence → watchdog → reconnect at ~66 s. Re-subscribed, NO pushall:
        // the state held from before is still the state, and deltas follow.
        clock.advance(61); await s.tick()
        clock.advance(5); await s.tick()
        #expect(links.made.count == 2)
        await Self.handshake(s)
        #expect(links.made[1].published.isEmpty, "pushall again 66 s after the last one")

        // Kept alive by deltas, with the held state full: no pushall on any tick.
        for _ in 0..<4 {
            clock.advance(50)
            await s.feed(.bytes(Self.report(#"{"print":{"mc_percent":43}}"#)))
            await s.tick()
        }
        clock.advance(50); await s.tick()
        #expect(links.made.count == 2)
        #expect(links.made[1].published.isEmpty, "pushall while the held state was full")

        // Past five minutes since the last one, a reconnect may ask again.
        clock.advance(61); await s.tick()        // watchdog
        clock.advance(5); await s.tick()         // the deltas reset the backoff to 5 s
        let third = try #require(links.made.last)
        #expect(links.made.count == 3)
        await Self.handshake(s)
        #expect(third.published == [pushall])
        // And the ledger is per printer, so a replacement session obeys it too.
        let again = Self.session(clock, links, ledger: ledger)
        await again.tick()
        await Self.handshake(again)
        #expect(links.made.last?.published.isEmpty == true)
    }

    @Test("a deferred pushall is sent by the tick once the five minutes are up and there is still no state")
    func deferredPushall() async throws {
        let clock = Clock(), links = Links(), ledger = PushallLedger()
        _ = ledger.claim(Self.serial, at: clock.now, gap: BambuSession.pushallGap)
        let s = Self.session(clock, links, ledger: ledger)
        await s.tick()
        await Self.handshake(s)
        #expect(links.made[0].published.isEmpty)
        // Keep the link alive with a delta (no full state yet).
        for _ in 0..<6 {
            clock.advance(50)
            await s.feed(.bytes(Self.report(#"{"print":{"nozzle_temper":200}}"#)))
            await s.tick()
        }
        #expect(links.made.count == 1)
        #expect(links.made[0].published.filter { $0.contains("pushall") }.count == 1)
    }

    // MARK: S2 — the watchdog

    @Test("60 s with no message drops the link and reconnects with doubling backoff")
    func watchdogReconnects() async throws {
        let clock = Clock(), links = Links()
        let s = Self.session(clock, links)
        await s.tick()
        await Self.handshake(s)
        await s.feed(.bytes(Self.report(Self.full)))

        clock.advance(59); await s.tick()
        #expect(links.made.count == 1)
        #expect(!links.made[0].closed, "dropped inside the watchdog window")
        // Keepalive went out meanwhile (nothing sent for 30 s).
        #expect(links.made[0].sent.contains(BambuMqtt.pingreq))

        clock.advance(2); await s.tick()
        #expect(links.made[0].closed)
        #expect(links.made[0].sent.last == BambuMqtt.disconnect, "hung up without DISCONNECT")
        #expect(await s.trouble == .wentQuiet, "a printer that HAD spoken is not blamed on Developer Mode")
        // The held state is not served once it is stale: the offline count runs.
        await #expect(throws: BambuMqtt.Trouble.wentQuiet) { _ = try await s.status() }

        clock.advance(4); await s.tick()
        #expect(links.made.count == 1, "reconnected before the backoff")
        clock.advance(1); await s.tick()
        #expect(links.made.count == 2)
        // Nothing again: the next wait is twice as long.
        clock.advance(61); await s.tick()
        clock.advance(9); await s.tick()
        #expect(links.made.count == 2)
        clock.advance(1); await s.tick()
        #expect(links.made.count == 3)
        #expect(await s.backoff == 20)
        // A message resets it.
        await Self.handshake(s)
        await s.feed(.bytes(Self.report(Self.full)))
        #expect(await s.backoff == BambuSession.firstBackoff)
        let back = try await s.status()
        #expect(back != .null)
    }

    @Test("a printer that never spoke is still the Developer Mode message")
    func silentFromTheStart() async throws {
        let clock = Clock(), links = Links()
        let s = Self.session(clock, links)
        await s.tick()
        await Self.handshake(s)
        clock.advance(61); await s.tick()
        #expect(await s.trouble == .silent)
    }

    @Test("a refused access code and a broken link are said as themselves, and retried later")
    func refusalsAndFailures() async throws {
        let clock = Clock(), links = Links()
        let s = Self.session(clock, links)
        await s.tick()
        await s.feed(.ready)
        await s.feed(.bytes([0x20, 0x02, 0x00, 0x05]))
        #expect(await s.trouble == .refused(5))
        #expect(links.made[0].closed)
        await #expect(throws: BambuMqtt.Trouble.refused(5)) { _ = try await s.status() }
        clock.advance(5); await s.tick()
        #expect(links.made.count == 2)
        await s.feed(.failed(BambuMqtt.Trouble.certificateChanged))
        #expect(await s.trouble == .certificateChanged)
        // An event from a link already dropped changes nothing.
        await s.receive(.bytes(Self.report(Self.full)), generation: 1)
        #expect(await s.held == nil)
    }

    // MARK: S2 — teardown

    @Test("stop hangs up cleanly and stays down")
    func teardown() async throws {
        let clock = Clock(), links = Links()
        let s = Self.session(clock, links)
        await s.tick()
        await Self.handshake(s)
        await s.feed(.bytes(Self.report(Self.full)))
        await s.stop()
        #expect(links.made[0].closed)
        #expect(links.made[0].sent.last == BambuMqtt.disconnect)
        await #expect(throws: BambuMqtt.Trouble.closed("cancelled")) { _ = try await s.status() }
        clock.advance(600); await s.tick()
        #expect(links.made.count == 1, "a stopped session reconnected")
        await #expect(throws: BambuMqtt.Trouble.closed("cancelled")) {
            try await s.command(payload: "{}", command: "pause", sequenceId: "1")
        }
    }

    @Test("the registry: one session per machine, replaced on a new code, dropped when the machine goes")
    func registry() async throws {
        let clock = Clock(), links = Links()
        let watch = BambuWatch()
        watch.makeLink = { _ in links.make() }
        watch.now = { clock.now }
        watch.ledger = PushallLedger()
        let a = await watch.session(for: "M-1", config: Self.config, accessCode: "12345678")
        let same = await watch.session(for: "M-1", config: Self.config, accessCode: "12345678")
        #expect(a === same)
        #expect(links.made.count == 1, "begin() connects at once")

        let changed = BambuSession.Config(host: "192.168.68.70", port: 8883, serial: Self.serial,
                                          accessCode: "87654321")
        #expect(changed != Self.config, "a new access code is a new session")
        #expect(watch.existing("M-1", config: changed) == nil)
        let b = await watch.session(for: "M-1", config: changed, accessCode: "87654321")
        #expect(a !== b)
        #expect(links.made[0].closed)
        #expect(await a.stopped)

        _ = await watch.session(for: "M-2", config: Self.config, accessCode: "12345678")
        await watch.retain(["M-2"])
        #expect(watch.sessions["M-1"] == nil)
        #expect(await b.stopped)
        await watch.stopAll()
        #expect(watch.sessions.isEmpty)
        #expect(links.made.allSatisfy { $0.closed })
    }

    @Test("the access code is never what a session is compared or keyed by")
    func codeIsDigested() {
        #expect(!Self.config.codeDigest.contains("12345678"))
        #expect(Self.config.codeDigest.count == 64)
        #expect(!String(describing: Self.config).contains("12345678"))
    }

    // MARK: S11 — Bambu commands

    @Test("pause / resume / cancel publish OpenBambuAPI's print.pause / resume / stop, byte for byte")
    func bambuCommandBytes() async throws {
        let engine = try KhaytEngine()
        for (verb, wire, seq) in [("pause", "pause", 1), ("resume", "resume", 2), ("cancel", "stop", 3)] {
            let r = try await engine.printerCommand(type: "bambu", command: verb, sequenceId: seq)
            let mqtt = try #require(r.mqtt, "\(verb) built no MQTT command")
            #expect(r.unsupported == nil)
            #expect(r.method == nil && r.path == nil)
            #expect(mqtt.payload == #"{"print":{"sequence_id":"\#(seq)","command":"\#(wire)","param":""}}"#)
            #expect(mqtt.command == wire)
            #expect(mqtt.sequenceId == String(seq))
            // And the PUBLISH packet itself: QoS 0, topic, then the payload.
            let packet = BambuMqtt.publish(topic: "device/\(Self.serial)/request", payload: mqtt.payload)
            let topic = Array("device/\(Self.serial)/request".utf8)
            let body = [UInt8(topic.count >> 8), UInt8(topic.count & 0xff)] + topic + Array(mqtt.payload.utf8)
            #expect(packet == [0x30] + BambuMqtt.remainingLength(body.count) + body)
        }
        let plain = try await engine.printerCommand(type: "bambu", command: "pause")
        #expect(plain.unsupported == nil, "the Mac speaks MQTT and must not be refused")
    }

    @Test("a command waits for the printer's reply naming its sequence")
    func bambuCommandSucceeds() async throws {
        let clock = Clock(), links = Links()
        let s = Self.session(clock, links)
        await s.tick()
        await Self.handshake(s)
        let seq = await s.nextSequence()
        let payload = #"{"print":{"sequence_id":"\#(seq)","command":"pause","param":""}}"#
        // A long timeout: the full suite runs hundreds of tests in parallel,
        // and the reply below is fed only once the publish is seen.
        let sent = Task { try await s.command(payload: payload, command: "pause", sequenceId: String(seq),
                                              timeout: .seconds(120)) }
        try await Self.eventually { links.made[0].published.contains(payload) }
        // Another command's reply, then the printer's own push, then ours.
        await s.feed(.bytes(Self.report(#"{"print":{"command":"pause","sequence_id":"999","result":"fail"}}"#)))
        await s.feed(.bytes(Self.report(Self.full)))
        await s.feed(.bytes(Self.report(#"{"print":{"command":"pause","sequence_id":"\#(seq)","result":"SUCCESS"}}"#)))
        try await sent.value
    }

    @Test("the printer's refusal is reported in its words; no reply is unconfirmed, not failed")
    func bambuCommandRefusedOrUnconfirmed() async throws {
        let clock = Clock(), links = Links()
        let s = Self.session(clock, links)
        await s.tick()
        await Self.handshake(s)
        let refused = Task { try await s.command(payload: "{}", command: "stop", sequenceId: "5",
                                                 timeout: .seconds(120)) }
        try await Self.eventually { links.made[0].published.contains("{}") }
        await s.feed(.bytes(Self.report(#"{"print":{"command":"stop","sequence_id":"5","result":"fail","reason":"no permission"}}"#)))
        await #expect(throws: BambuMqtt.Trouble.commandRefused("no permission")) { try await refused.value }

        await #expect(throws: BambuMqtt.Trouble.unconfirmed) {
            try await s.command(payload: "{}", command: "pause", sequenceId: "6", timeout: .milliseconds(50))
        }
        #expect(PrinterWatch.say(BambuMqtt.Trouble.commandRefused("no permission")).contains("no permission"))
        #expect(!PrinterWatch.say(BambuMqtt.Trouble.commandRefused("x")).contains("Bambu Connect"))
        #expect(PrinterWatch.say(BambuMqtt.Trouble.unconfirmed).lowercased().contains("check the printer"))
    }

    // MARK: S8 — faults in the status

    @Test("print_error and HMS notices reach the status as words, never as `error`")
    func faultsInStatus() async throws {
        let engine = try KhaytEngine()
        var held = BambuReport.merge(nil, Self.full)
        held = BambuReport.merge(held, #"{"print":{"gcode_state":"PAUSE","print_error":117473297,"hms":[{"attr":50331904,"code":65543}]}}"#)
        let pausedHeld = try #require(held)
        let pausedRead = try await engine.bambuStatus(held: pausedHeld)
        let status = try #require(pausedRead)
        let fault = try #require(status.fault)
        // 117473297 = 0x07008011, "AMS filament ran out"; the HMS is fatal and leads.
        #expect(fault.hasPrefix("The heatbed temperature is abnormal"))
        #expect(fault.contains("HMS_0300_0100_0001_0007"))
        #expect(fault.hasSuffix("(+1 more)"))
        // Cleared: the printer sends an empty list and a zero.
        held = BambuReport.merge(held, #"{"print":{"gcode_state":"RUNNING","print_error":0,"hms":[]}}"#)
        let clearedHeld = try #require(held)
        let cleared = try await engine.bambuStatus(held: clearedHeld)
        #expect(cleared?.fault == nil)
        // The cache the alert rules read has no `error` for a printer that answered.
        let entry = PrinterWatch.cacheEntry(status, at: Date())
        #expect(entry["error"] == nil)
    }

    // MARK: S11 — SDCP

    @Test("SDCP pause / stop / continue are Cmd 129 / 130 / 131 in the spec envelope")
    func sdcpCommandBytes() async throws {
        let engine = try KhaytEngine()
        for (verb, cmd) in [("pause", 129), ("cancel", 130), ("resume", 131)] {
            let r = try await engine.printerCommand(type: "sdcp", command: verb, mainboardId: "ffffffff",
                                                    requestId: "000000000001d354", timestamp: 1687069655)
            let frame = try #require(r.sdcp)
            #expect(frame.cmd == cmd)
            #expect(frame.requestId == "000000000001d354")
            #expect(frame.frame == #"{"Id":"","Data":{"Cmd":\#(cmd),"Data":{},"RequestID":"000000000001d354","MainboardID":"ffffffff","TimeStamp":1687069655,"From":0},"Topic":"sdcp/request/ffffffff"}"#)
        }
        let noBoard = try await engine.printerCommand(type: "sdcp", command: "pause")
        #expect(noBoard.unsupported?.contains("mainboard ID") == true)
    }

    @Test("an SDCP Ack is matched on its command and request, and a refusal is the printer's")
    func sdcpAck() async throws {
        let engine = try KhaytEngine()
        func reply(_ cmd: Int, _ req: String, _ ack: Int) -> String {
            #"{"Id":"x","Data":{"Cmd":\#(cmd),"Data":{"Ack":\#(ack)},"RequestID":"\#(req)","MainboardID":"ffffffff","TimeStamp":1},"Topic":"sdcp/response/ffffffff"}"#
        }
        func ack(_ frame: String) async throws -> KhaytEngine.SdcpAck? {
            try await engine.sdcpAck(frame: frame, mainboardId: "ffffffff", cmd: 129, requestId: "r1")
        }
        let ok = try await ack(reply(129, "r1", 0))
        let busy = try await ack(reply(129, "r1", 1))
        let otherCmd = try await ack(reply(130, "r1", 0))
        let otherReq = try await ack(reply(129, "r2", 0))
        let junk = try await ack("not json")
        #expect(ok == .ok)
        #expect(busy == .refused("Busy"))
        #expect(otherCmd == nil)
        #expect(otherReq == nil)
        #expect(junk == nil)
        #expect(PrinterWatch.say(SdcpSocket.Trouble.unconfirmed).lowercased().contains("did not confirm"))
    }

    // MARK: Helpers

    static func eventually(_ what: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while ContinuousClock.now < deadline {
            if what() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting")
    }
}

/// beta.5 review: replacing a Bambu session keeps what the old one held, and
/// two racing callers never leave a second MQTT client behind.
@MainActor
struct BambuSessionReplaceTests {
    typealias F = BambuSessionTests

    static func watch(_ clock: F.Clock, _ links: F.Links) -> BambuWatch {
        let w = BambuWatch()
        w.makeLink = { _ in links.make() }
        w.now = { clock.now }
        w.ledger = PushallLedger()
        return w
    }

    @Test("a new code for the same printer carries the held state over; the deltas lay over it at once")
    func replacementCarriesHeld() async throws {
        let clock = F.Clock(), links = F.Links()
        let watch = Self.watch(clock, links)
        let a = await watch.session(for: "M-1", config: F.config, accessCode: "12345678")
        await F.handshake(a)
        await a.feed(.bytes(F.report(F.full)))
        let before = try #require(await a.held)

        let changed = BambuSession.Config(host: "192.168.68.71", port: 8883, serial: F.serial,
                                          accessCode: "87654321")
        let b = await watch.session(for: "M-1", config: changed, accessCode: "87654321")
        #expect(a !== b)
        #expect(await b.held == before, "the old session's state, not nil")
        await F.handshake(b)
        #expect(links.made.last?.published.isEmpty == true, "the ledger still refuses pushall")
        await #expect(throws: (any Error).self, "not fresh until the printer speaks") { _ = try await b.status() }
        await b.feed(.bytes(F.report(#"{"print":{"mc_percent":45}}"#)))
        let engine = try KhaytEngine()
        let read = try await engine.bambuStatus(held: try await b.status())
        #expect(read?.progress == 45)
        #expect(read?.filename == "bracket.3mf", "the delta laid over the carried full report")

        // Another printer behind the same machine is a blank start.
        let other = BambuSession.Config(host: "192.168.68.71", port: 8883, serial: "01P00A999999999",
                                        accessCode: "87654321")
        let c = await watch.session(for: "M-1", config: other, accessCode: "87654321")
        #expect(await c.held == nil)
        await watch.stopAll()
    }

    @Test("two callers racing a replacement end with ONE live session, the other stopped")
    func racingReplacementLeavesOneClient() async throws {
        let clock = F.Clock(), links = F.Links()
        let watch = Self.watch(clock, links)
        let a = await watch.session(for: "M-1", config: F.config, accessCode: "12345678")
        let changed = BambuSession.Config(host: "192.168.68.71", port: 8883, serial: F.serial,
                                          accessCode: "87654321")
        async let x = watch.session(for: "M-1", config: changed, accessCode: "87654321")
        async let y = watch.session(for: "M-1", config: changed, accessCode: "87654321")
        let (sx, sy) = await (x, y)
        #expect(sx === sy, "both callers got the one stored session")
        #expect(watch.sessions["M-1"] === sx)
        #expect(await a.stopped)
        #expect(await sx.stopped == false)
        #expect(links.made.filter { !$0.closed }.count == 1, "exactly one MQTT client still open")

        // Racing callers that disagree: the slot ends with one session, the loser stopped.
        let third = BambuSession.Config(host: "192.168.68.72", port: 8883, serial: F.serial,
                                        accessCode: "11112222")
        async let p = watch.session(for: "M-1", config: third, accessCode: "11112222")
        async let q = watch.session(for: "M-1", config: F.config, accessCode: "12345678")
        let (sp, sq) = await (p, q)
        let live = try #require(watch.sessions["M-1"])
        let loser = live === sp ? sq : sp
        #expect(live !== loser)
        #expect(await loser.stopped)
        #expect(links.made.filter { !$0.closed }.count == 1)
        await watch.stopAll()
    }
}
