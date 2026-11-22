import Foundation
import CryptoKit
import Network
import KhaytCore

/// ONE held MQTT connection per Bambu, instead of a new one every ten seconds.
///
/// ── WHAT WAS WRONG ────────────────────────────────────────────────────────
///
/// `PrinterWatch` polls every machine every 10 s, and for a Bambu every poll
/// was a fresh TLS + MQTT connection that sent `pushall`, took the first full
/// report and hung up. OpenBambuAPI `mqtt.md` (`pushing.pushall`): "refrain from
/// executing this command at intervals less than 5 minutes on the P1P, as it
/// may cause lag due to its hardware limitations" — this was 30× that, on the
/// cheapest and most numerous machine in the line. And the P1 is reported to
/// serve only one local MQTT client properly (ha-bambulab #174,
/// BambuStudio #2404), so a reconnect every 10 s could evict Bambu Studio or
/// Handy, or be evicted by them. `docs/PRINTER-PROTOCOL-AUDIT.md` recorded it
/// in August and left it for a fix with a source to stand on.
///
/// ── THE SHAPE, AND WHERE IT COMES FROM ────────────────────────────────────
///
/// ha-bambulab (`custom_components/bambu_lab/pybambu/bambu_client.py`), the
/// client that runs against more Bambus than any other:
///
///   - one connection, subscribed to `device/<serial>/report`, `pushall` sent
///     on connect (`subscribe_and_request_info`);
///   - every report folded into a held device state (`models.py`
///     `print_update`: a field the message does not mention keeps its value),
///     because a P1 sends only what changed — `BambuReport.merge`, held to
///     `lib/bambu-report.js` `mergeReport` by a parity test;
///   - a watchdog that fires after 60 s with no message (`WATCHDOG_TIMER = 60`)
///     and marks the printer offline;
///   - MQTT keepalive 30 s; reconnect attempts 5 s apart.
///
/// Two deliberate differences. On the watchdog ha-bambulab publishes
/// `pushing.start` on the SAME connection; here the connection is dropped and
/// re-made with growing backoff (5 s doubling to 5 min), because a socket that
/// has been silent for a minute on a LAN is far more often dead than merely
/// quiet, and NWConnection does not always say so. And `pushall` is held to
/// the documented 5-minute minimum PER PRINTER across reconnects
/// (`PushallLedger`): a reconnect inside that window re-subscribes and waits
/// for deltas over the state it already holds.
///
/// ── WHAT THE SWEEP DOES NOW ───────────────────────────────────────────────
///
/// Reads the held state. Nothing is dialled on the 10 s clock. A held state is
/// only answered while it is fresh (a message within the watchdog window), so
/// a printer that goes away still counts toward the offline alert exactly as a
/// failed poll did.
///
/// ── THE ACCESS CODE ───────────────────────────────────────────────────────
///
/// Still opened from the sealed field by the caller at the moment of use and
/// never displayed or logged. What changes is lifetime: a held connection has
/// to reconnect without asking the book again, so the opened code lives in
/// this actor's memory for as long as the session does. Sessions are compared
/// by a SHA-256 of it (`Config.codeDigest`), never by the code itself.
actor BambuSession {

    /// Where a session points. Two sessions are the same session only if all
    /// of this is the same — a changed access code is a new session.
    struct Config: Equatable, Sendable {
        let host: String
        let port: UInt16
        let serial: String
        let codeDigest: String

        init(host: String, port: UInt16, serial: String, accessCode: String) {
            self.host = host
            self.port = port == 0 ? BambuMqtt.defaultPort : port
            self.serial = serial
            self.codeDigest = SHA256.hash(data: Data(accessCode.utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: Timing — every figure has a source

    /// ha-bambulab `WatchdogThread.WATCHDOG_TIMER = 60`.
    static let watchdog: TimeInterval = 60
    /// OpenBambuAPI: no `pushall` more often than every 5 minutes on a P1P.
    static let pushallGap: TimeInterval = 5 * 60
    /// ha-bambulab connects with `keepalive=30`; the CONNECT here says 60 and
    /// a PINGREQ goes out after 30 s of not sending, well inside it.
    static let pingAfter: TimeInterval = 30
    static let keepalive: UInt16 = 60
    /// ha-bambulab waits 5 s between attempts. Here that is the first step,
    /// doubling to five minutes while the printer stays away.
    static let firstBackoff: TimeInterval = 5
    static let maxBackoff: TimeInterval = 5 * 60
    /// How often the session looks at its own clock.
    static let tickEvery: Duration = .seconds(5)

    let config: Config
    private let accessCode: String
    private let makeLink: @Sendable (Config) -> BambuLink
    private let now: @Sendable () -> Date
    private let ledger: PushallLedger

    init(config: Config, accessCode: String,
         makeLink: @escaping @Sendable (Config) -> BambuLink,
         now: @escaping @Sendable () -> Date = { Date() },
         ledger: PushallLedger = .shared,
         carrying held: JSONValue? = nil) {
        self.config = config
        self.accessCode = accessCode
        self.makeLink = makeLink
        self.now = now
        self.ledger = ledger
        self.nextAttempt = .distantPast
        // A replaced session for the SAME printer starts from the state the
        // old one held: the shared ledger refuses pushall for five minutes,
        // so a blank start would have no full report to lay deltas over.
        // `heardAt` stays nil, so it is not "fresh" until the printer speaks.
        self.held = held
    }

    // MARK: State

    enum Phase: Equatable, Sendable { case down, connecting, subscribed }

    private(set) var phase: Phase = .down
    private var link: BambuLink?
    /// Bumped on every new link, so a late event from a dropped one is ignored.
    private(set) var generation = 0
    private var buffer: [UInt8] = []
    private var linkStartedAt: Date?
    private var lastSent: Date?
    private(set) var held: JSONValue?
    /// The last PUBLISH on the report topic. PINGRESP does not count — the
    /// watchdog, like ha-bambulab's, is about the printer, not the broker.
    private(set) var heardAt: Date?
    private var everHeard = false
    private(set) var backoff: TimeInterval = BambuSession.firstBackoff
    private(set) var nextAttempt: Date
    private(set) var trouble: BambuMqtt.Trouble?
    /// How the printer's certificate was trusted on the latest connection:
    /// true by Bambu Lab's CAs, false by the first-use pin only.
    private(set) var verifiedByBambu: Bool?
    private(set) var stopped = false
    private var loop: Task<Void, Never>?
    private var consumer: Task<Void, Never>?
    private var events: AsyncStream<BambuLinkEvent>.Continuation?
    private var sequence = 0
    /// Lock-held copy of the link, so the app can hang up synchronously on quit.
    private nonisolated let box = LinkBox()

    private var stateWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var commandWaiters: [String: (command: String, section: String, resume: CheckedContinuation<Result<Void, BambuMqtt.Trouble>, Never>)] = [:]

    // MARK: Lifecycle

    /// Start connecting, and keep the clock running. Idempotent.
    func begin() {
        guard loop == nil, !stopped else { return }
        tick()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: BambuSession.tickEvery)
                if Task.isCancelled { return }
                await self?.tick()
            }
        }
    }

    /// Hang up for good: the machine was removed, changed, or the book closed.
    func stop() {
        guard !stopped else { return }
        stopped = true
        loop?.cancel()
        loop = nil
        drop(as: .closed("cancelled"), reconnect: false)
        phase = .down
        wakeStateWaiters()
    }

    /// The same, from anywhere and synchronously — for app quit, where there
    /// is no later. Sends MQTT DISCONNECT and closes the socket.
    nonisolated func hangUp() {
        guard let link = box.take() else { return }
        link.send(BambuMqtt.disconnect)
        link.close()
    }

    // MARK: The clock

    /// Everything time-driven: connecting when due, the watchdog, keepalive,
    /// and a `pushall` that was deferred by the rate limit.
    func tick() {
        guard !stopped else { return }
        let t = now()
        guard link != nil else {
            if t >= nextAttempt { connect() }
            return
        }
        // From the later of the last message and this link's start: a link
        // made a minute after the last message gets its own full minute.
        let since = [heardAt, linkStartedAt].compactMap { $0 }.max() ?? t
        if t.timeIntervalSince(since) > Self.watchdog {
            // A printer that has spoken before has proved Developer Mode is on,
            // so its silence is not the Developer Mode message.
            drop(as: everHeard ? .wentQuiet : .silent, reconnect: true)
            return
        }
        if phase == .subscribed {
            if let sent = lastSent, t.timeIntervalSince(sent) >= Self.pingAfter {
                send(BambuMqtt.pingreq)
            }
            if !holdsFullReport { pushallIfAllowed() }
        }
    }

    private func connect() {
        generation += 1
        let gen = generation
        buffer = []
        phase = .connecting
        linkStartedAt = now()
        lastSent = nil
        let link = makeLink(config)
        self.link = link
        box.set(link)
        // IN ORDER. A Task per event would let two chunks of one report be
        // handled out of sequence; one consumer over a stream cannot.
        let (stream, sink) = AsyncStream.makeStream(of: BambuLinkEvent.self)
        events?.finish()
        events = sink
        consumer?.cancel()
        consumer = Task { [weak self] in
            for await event in stream { await self?.receive(event, generation: gen) }
        }
        link.start { event in sink.yield(event) }
    }

    /// Drop the link, remember why, and (unless stopping) book the next try.
    private func drop(as why: BambuMqtt.Trouble, reconnect: Bool) {
        if let link {
            if phase != .down { link.send(BambuMqtt.disconnect) }
            link.close()
        }
        link = nil
        _ = box.take()
        events?.finish()
        events = nil
        phase = .down
        buffer = []
        trouble = why
        failCommands(why == .closed("cancelled") ? why : .unconfirmed)
        if reconnect {
            nextAttempt = now().addingTimeInterval(backoff)
            backoff = min(backoff * 2, Self.maxBackoff)
        }
        wakeStateWaiters()
    }

    // MARK: Events off the link

    /// One event from the link with this generation. Events from a link that
    /// has since been dropped are ignored. Internal so a test can drive it.
    func receive(_ event: BambuLinkEvent, generation gen: Int) {
        guard gen == generation, link != nil, !stopped else { return }
        switch event {
        case .ready:
            if let v = link?.verifiedByBambu { verifiedByBambu = v }
            send(BambuMqtt.connect(clientId: Self.clientId(), username: "bblp",
                                   password: accessCode, keepalive: Self.keepalive))
        case .failed(let error):
            drop(as: (error as? BambuMqtt.Trouble) ?? .closed((error as NSError).localizedDescription),
                 reconnect: true)
        case .bytes(let chunk):
            buffer += chunk
            let read: (packets: [BambuMqtt.Packet], rest: [UInt8])
            do { read = try BambuMqtt.packets(from: buffer) }
            catch { drop(as: .malformed, reconnect: true); return }
            buffer = read.rest
            for packet in read.packets {
                handle(packet)
                if link == nil { return }
            }
        }
    }

    /// The same, for the CURRENT link — what a test's fake link feeds.
    func feed(_ event: BambuLinkEvent) { receive(event, generation: generation) }

    private func handle(_ packet: BambuMqtt.Packet) {
        switch packet.type {
        case 2:     // CONNACK
            let code = packet.body.count >= 2 ? packet.body[1] : 0xff
            guard code == 0 else { drop(as: .refused(code), reconnect: true); return }
            send(BambuMqtt.subscribe(packetId: 1, topic: "device/\(config.serial)/report"))
        case 9:     // SUBACK — the printer is listening
            phase = .subscribed
            pushallIfAllowed()
            wakeStateWaiters()
        case 3:     // PUBLISH
            guard let decoded = BambuMqtt.decodePublish(packet.body),
                  decoded.topic == "device/\(config.serial)/report" else { return }
            heardAt = now()
            everHeard = true
            backoff = Self.firstBackoff
            trouble = nil
            held = BambuReport.merge(held, decoded.payload)
            answerCommand(decoded.payload)
            wakeStateWaiters()
        default:    // PINGRESP and anything else
            break
        }
    }

    // MARK: pushall, rate-limited

    private var holdsFullReport: Bool {
        held.flatMap { BambuReport.parse(value: $0) } != nil
    }

    /// Ask for the full state — at most once per `pushallGap` per printer,
    /// across reconnects and session replacement. True when sent.
    @discardableResult
    private func pushallIfAllowed() -> Bool {
        guard phase == .subscribed, ledger.claim(config.serial, at: now(), gap: Self.pushallGap)
        else { return false }
        send(BambuMqtt.publish(topic: "device/\(config.serial)/request", payload: BambuMqtt.pushall))
        return true
    }

    private func send(_ bytes: [UInt8]) {
        link?.send(bytes)
        lastSent = now()
    }

    private static func clientId() -> String {
        "khayt-" + String(UInt32.random(in: 0...UInt32.max), radix: 36)
    }

    // MARK: Reading

    /// The held state, when it is a full report and fresh.
    ///
    /// `wait` is how long to wait for one when there is none yet — the first
    /// poll after a session starts, or the Test button. Otherwise the answer
    /// is immediate: a sweep must not stall on one machine.
    func status(wait: Duration = .zero) async throws -> JSONValue {
        if stopped { throw BambuMqtt.Trouble.closed("cancelled") }
        if let ready = freshReport() { return ready }
        if wait > .zero, !stopped {
            await waitForChange(upTo: wait) { freshReport() != nil || stopped }
            if let ready = freshReport() { return ready }
        }
        throw stopped ? BambuMqtt.Trouble.closed("cancelled") : (trouble ?? .silent)
    }

    private func freshReport() -> JSONValue? {
        guard let held, holdsFullReport, let heardAt,
              now().timeIntervalSince(heardAt) <= Self.watchdog else { return nil }
        return held
    }

    // MARK: Commands

    /// The next `sequence_id`. OpenBambuAPI: "Incremented by 1 on each
    /// command"; the printer echoes it, which is how its reply is matched.
    func nextSequence() -> Int {
        sequence += 1
        return sequence
    }

    /// Publish a command (already built by `lib/printer-commands.js`) and wait
    /// for the printer's reply naming it.
    ///
    /// QoS 0, as ha-bambulab publishes (`client.publish` with paho's default);
    /// OpenBambuAPI notes Bambu's own clients use QoS 1 for these. The REPLY
    /// is the confirmation either way, and it is what this waits for:
    /// `result: "success"` returns, `"fail"` throws `commandRefused` with the
    /// printer's reason, and no reply throws `unconfirmed` — the command may
    /// have happened, and the shop is told to look rather than told it failed.
    func command(payload: String, command: String, sequenceId: String, section: String = "print",
                 timeout: Duration = .seconds(8)) async throws {
        if stopped { throw BambuMqtt.Trouble.closed("cancelled") }
        if phase != .subscribed {
            if link == nil { nextAttempt = .distantPast; tick() }
            await waitForChange(upTo: timeout) { phase == .subscribed || stopped }
            guard phase == .subscribed else { throw trouble ?? .silent }
        }
        let result: Result<Void, BambuMqtt.Trouble> = await withCheckedContinuation { resume in
            commandWaiters[sequenceId] = (command, section, resume)
            send(BambuMqtt.publish(topic: "device/\(config.serial)/request", payload: payload))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.settleCommand(sequenceId, .failure(.unconfirmed))
            }
        }
        try result.get()
    }

    private func settleCommand(_ id: String, _ result: Result<Void, BambuMqtt.Trouble>) {
        guard let waiter = commandWaiters.removeValue(forKey: id) else { return }
        waiter.resume.resume(returning: result)
    }

    private func failCommands(_ why: BambuMqtt.Trouble) {
        for id in Array(commandWaiters.keys) { settleCommand(id, .failure(why)) }
    }

    /// Is this report the reply to a command waiting here? OpenBambuAPI's
    /// report structure: the same `command` and `sequence_id` as the request,
    /// and `result` "success" — "Case insensitive!" — or not, with `reason`.
    private func answerCommand(_ payload: String) {
        guard !commandWaiters.isEmpty,
              let data = payload.data(using: .utf8),
              case .object(let report)? = try? JSONValue.decode(JSONValue.self, from: data) else { return }
        // `print` for job verbs and speed, `system` for the light.
        for section in Set(commandWaiters.values.map(\.section)) {
            if case .object(let p)? = report[section] { answer(p, in: section) }
        }
    }

    private func answer(_ p: [String: JSONValue], in section: String) {
        guard case .string(let command)? = p["command"],
              case .string(let result)? = p["result"] else { return }
        let seq: String? = {
            switch p["sequence_id"] {
            case .string(let s)?: return s
            case .number(let n)?: return n.isFinite ? String(Int(exactly: n.rounded()) ?? -1) : nil
            default: return nil
            }
        }()
        // By sequence; a reply with none is matched by its verb alone.
        let id: String?
        if let seq { id = commandWaiters[seq] != nil ? seq : nil }
        else { id = commandWaiters.first(where: { $0.value.command == command && $0.value.section == section })?.key }
        guard let id, let waiter = commandWaiters[id], waiter.command == command,
              waiter.section == section else { return }
        if result.lowercased() == "success" {
            settleCommand(id, .success(()))
        } else {
            var reason = ""
            if case .string(let r)? = p["reason"] { reason = r }
            settleCommand(id, .failure(.commandRefused(reason)))
        }
    }

    // MARK: Waiting

    private func waitForChange(upTo limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if done() { return }
            let id = UUID()
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                stateWaiters[id] = resume
                Task { [weak self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    await self?.wake(id)
                }
            }
        }
    }

    private func wake(_ id: UUID) {
        stateWaiters.removeValue(forKey: id)?.resume()
    }

    private func wakeStateWaiters() {
        let all = stateWaiters
        stateWaiters = [:]
        for (_, w) in all { w.resume() }
    }
}

// MARK: - The link underneath

enum BambuLinkEvent: Sendable {
    case ready
    case bytes([UInt8])
    case failed(Error)
}

/// A byte pipe to a printer. A seam: the session is tested against a fake,
/// because no Bambu answers on this Mac's network and none can be made to.
protocol BambuLink: AnyObject, Sendable {
    /// After `.ready`: did Bambu Lab's CAs vouch for the printer (true), or
    /// was it let in by the first-use pin (false)? Nil when not known.
    var verifiedByBambu: Bool? { get }
    /// Begin connecting; events arrive on `handler`, in order.
    func start(_ handler: @escaping @Sendable (BambuLinkEvent) -> Void)
    func send(_ bytes: [UInt8])
    /// Flush what was sent, then close. Safe to call more than once.
    func close()
}

/// The real one: TLS on 8883, the certificate pinned on first use.
final class NetworkBambuLink: BambuLink, @unchecked Sendable {
    private let connection: NWConnection
    private let verdict = PinVerdict()
    private let queue = DispatchQueue(label: "khayt.bambu.link")
    private let lock = NSLock()
    private var closed = false
    /// Events are delivered on one serial queue, so in order.
    private var handler: (@Sendable (BambuLinkEvent) -> Void)?

    var verifiedByBambu: Bool? { verdict.byBambu }

    init(_ config: BambuSession.Config) {
        connection = BambuMqtt.connection(host: config.host, port: config.port,
                                          serial: config.serial, verdict: verdict)
    }

    func start(_ handler: @escaping @Sendable (BambuLinkEvent) -> Void) {
        lock.withLock { self.handler = handler }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.emit(.ready)
                self.receive()
            case .failed(let error):
                self.emit(.failed(self.verdict.refused ?? BambuMqtt.Trouble.closed(error.localizedDescription)))
            case .waiting(let error):
                // Unreachable for now. Said, and left to the session's backoff
                // rather than NWConnection's own retry, so there is one clock.
                self.emit(.failed(self.verdict.refused ?? BambuMqtt.Trouble.closed(error.localizedDescription)))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func emit(_ event: BambuLinkEvent) {
        let h: (@Sendable (BambuLinkEvent) -> Void)? = lock.withLock { closed ? nil : handler }
        h?(event)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let error { self.emit(.failed(BambuMqtt.Trouble.closed(error.localizedDescription))); return }
            if let data, !data.isEmpty { self.emit(.bytes(Array(data))) }
            if done { self.emit(.failed(BambuMqtt.Trouble.closed("hungUp"))); return }
            self.receive()
        }
    }

    func send(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .idempotent)
    }

    func close() {
        let first: Bool = lock.withLock {
            defer { closed = true; handler = nil }
            return !closed
        }
        guard first else { return }
        // After anything already queued (the DISCONNECT), then cancel.
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [connection] _ in connection.cancel() })
        queue.asyncAfter(deadline: .now() + 2) { [connection] in connection.cancel() }
    }
}

/// When each printer was last sent `pushall`, by serial — so the 5-minute
/// minimum holds across reconnects and across a session being replaced.
final class PushallLedger: @unchecked Sendable {
    static let shared = PushallLedger()
    private let lock = NSLock()
    private var sent: [String: Date] = [:]

    /// True, and recorded, when a `pushall` may go now.
    func claim(_ serial: String, at now: Date, gap: TimeInterval) -> Bool {
        lock.withLock {
            if let last = sent[serial], now.timeIntervalSince(last) < gap { return false }
            sent[serial] = now
            return true
        }
    }

    func last(_ serial: String) -> Date? { lock.withLock { sent[serial] } }
}

/// A link held under a lock, for the synchronous hang-up on quit.
final class LinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var link: BambuLink?
    func set(_ l: BambuLink?) { lock.withLock { link = l } }
    func take() -> BambuLink? { lock.withLock { defer { link = nil }; return link } }
}

// MARK: - One session per machine

/// Every held Bambu connection this app has, by machine id.
///
/// The sweep asks it for a machine's state; a machine whose address, serial
/// or access code changed gets a new session (the old one hangs up); one that
/// left the watched set — deleted, retired, under service — is hung up on the
/// next sweep (`retain`); closing the book and quitting the app hang up all.
@MainActor
final class BambuWatch {
    static let shared = BambuWatch()

    /// A seam: tests stand up sessions over a fake link.
    var makeLink: @Sendable (BambuSession.Config) -> BambuLink = { NetworkBambuLink($0) }
    var now: @Sendable () -> Date = { Date() }
    var ledger: PushallLedger = .shared

    private(set) var sessions: [String: BambuSession] = [:]
    /// Machines whose printer was let in by the first-use pin and not by
    /// Bambu Lab's CAs. The machine sheet notes it.
    private(set) var unverified: Set<String> = []

    init() {}

    func noteTrust(_ id: String, verifiedByBambu: Bool?) {
        if verifiedByBambu == false { unverified.insert(id) } else if verifiedByBambu == true { unverified.remove(id) }
    }

    /// The session for this machine, started if new, replaced if its config
    /// changed.
    ///
    /// Every `await` here lets another caller in, so the slot is re-read after
    /// each one: a session another caller stored meanwhile is returned when it
    /// matches and stopped when it does not — never overwritten while still
    /// connected (a second MQTT client for one printer). A session replaced
    /// for the same printer (new code, host or port) hands its held state on.
    func session(for id: String, config: BambuSession.Config, accessCode: String) async -> BambuSession {
        var carried: JSONValue?
        while let current = sessions[id] {
            if current.config == config { return current }
            sessions[id] = nil
            if carried == nil, current.config.serial == config.serial { carried = await current.held }
            await current.stop()
        }
        let s = BambuSession(config: config, accessCode: accessCode,
                             makeLink: makeLink, now: now, ledger: ledger, carrying: carried)
        sessions[id] = s
        await s.begin()
        return s
    }

    /// The live session for this machine, only if it points where `config`
    /// does. The Test button reads one rather than dialling a second client.
    func existing(_ id: String, config: BambuSession.Config) -> BambuSession? {
        guard let s = sessions[id], s.config == config else { return nil }
        return s
    }

    /// Hang up on every machine not in `ids`.
    func retain(_ ids: Set<String>) async {
        for (id, s) in sessions where !ids.contains(id) {
            sessions[id] = nil
            unverified.remove(id)
            await s.stop()
        }
    }

    func stopAll() async {
        let all = sessions.values
        sessions = [:]
        for s in all { await s.stop() }
    }

    /// Synchronously, for app quit.
    func hangUpAll() {
        for s in sessions.values { s.hangUp() }
        sessions = [:]
    }
}
