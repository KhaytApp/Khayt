import Foundation
import KhaytCore

/// Asking the shop's printers what they are doing.
///
/// The one thing this app could not answer without the Electron app running:
/// "is it printing, and how far along". A shop that has to open a second app to
/// look at its own machine has not stopped using the second app.
///
/// **It reads, and it reads only.** No pause, no resume, no cancel and no
/// upload. Those are commands, and a command sent to the wrong machine — or to
/// something that is not a machine — costs a shop a print, so they belong
/// behind a deliberate piece of work rather than arriving with a status card.
///
/// **Moonraker only, for now, and it says so.** Khayt speaks seven protocols;
/// there is one printer on this bench and it is a Klipper toolchanger, so it is
/// the one that could be verified against a machine rather than against a
/// document. A machine on any other protocol is told plainly that this app does
/// not poll it yet — a card that silently shows nothing looks broken, and a
/// shop would go back to the other app without knowing why.
///
/// **The reading is `lib/moonraker.js`'s.** Four corrections live in there, each
/// found on a real printer, and none of them is re-decided in Swift. What is
/// Swift is the socket and the clock.
@MainActor
@Observable
final class PrinterWatch {

    /// What a machine last said, and when.
    struct Reading: Sendable, Equatable {
        var status: KhaytEngine.PrinterStatus?
        /// Why there is no status. A sentence a shop can act on, not a socket's
        /// vocabulary — `explainPrinterHttp` exists for the same reason.
        var problem: String?
        var at: Date
        /// How many polls in a row have failed.
        ///
        /// `attention.machineState` reads exactly this and calls a machine
        /// `reconnecting` until it reaches three, then `offline` — and only
        /// `offline` reaches the dashboard, by design. Without the count a
        /// printer unreachable all day stayed "reconnecting" for ever and the
        /// one screen a shop leaves open never mentioned it.
        var consecutiveFailures: Int = 0
    }

    /// Is this printer laying plastic right now?
    ///
    /// The one place that decides. It lived on a private view in `ShopFloor`,
    /// which is fine while the only thing asking is a card on that screen — and
    /// the band asks too, from `Shop`, because an IDLE printer answers a poll
    /// perfectly well with `progress: 0`. A job still marked printing in the
    /// book against an idle machine would then be drawn as starting now and
    /// running its whole estimate: a confident picture of something that is not
    /// happening.
    static func isPrinting(_ raw: String) -> Bool { raw.lowercased() == "printing" }

    /// Why a machine is not being polled at all, which is different from a poll
    /// that failed.
    enum NotWatched: Equatable {
        case noConnection
        case otherProtocol(String)
    }

    private(set) var readings: [Machine.ID: Reading] = [:]

    /// What has gone wrong, and what to remember about it.
    let notices = PrinterNotice()
    /// The cache as it was at the previous sweep, and the module's own
    /// bookkeeping. Both are handed straight back to it; neither is read here.
    private var previous: [String: JSONValue] = [:]
    private var alertState: JSONValue = .object([:])

    /// What the printers last said, in the shape `dashboard-facts` reads —
    /// the same `{ [machineId]: { state, … } }` main.js keeps. A machine that
    /// has not answered is absent rather than present-and-blank, because the
    /// module treats an absent one as "not counted" and a blank one as live.
    var statusCache: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (id, seen) in readings {
            if let status = seen.status {
                var entry: [String: JSONValue] = [
                    "state": .string(status.state),
                    "progress": .number(Double(status.progress)),
                    "filename": .string(status.filename),
                    "lastUpdated": .number(seen.at.timeIntervalSince1970 * 1000),
                ]
                // SECONDS LEFT, when the printer gave one — and the delivery
                // promise is what needs it. `lead-time-publish` reads exactly
                // this field to decide between "this lane is busy for 3.5
                // hours" and "this lane is busy and nobody can say for how
                // long", and the second answer drops the lane out of the
                // shop's capacity altogether.
                //
                // Leaving it out was not neutral. Every printing machine fell
                // into the second case, so a shop with one busy printer
                // published a promise computed against no printers at all. It
                // errs late rather than early, which is why it would never have
                // been reported — main.js keeps the whole status object in its
                // cache and has always had the number.
                //
                // Absent, not zero, when the printer did not say: Klipper
                // reports no usable estimate for the first ~1% of a job, and a
                // zero there would read as "finishing now".
                if let left = status.timeRemaining { entry["timeRemaining"] = .number(left) }
                out[id] = .object(entry)
            } else if seen.problem != nil {
                // A machine that did not answer is offline, which is a fact the
                // fleet tile has to count — not an absence.
                // `error` is what `isFailedPoll` reads, and the offline alert
                // counts consecutive failed polls. Without this field a printer
                // that had been unreachable for an hour raised nothing at all.
                out[id] = .object([
                    "state": .string("offline"),
                    "error": .string(seen.problem ?? "no answer"),
                    // `machineState` reads this and says "reconnecting" until
                    // it reaches three. One bad poll is a wifi hiccup; three is
                    // a printer somebody has to walk over to.
                    "consecutiveFailures": .number(Double(seen.consecutiveFailures)),
                    "lastUpdated": .number(seen.at.timeIntervalSince1970 * 1000),
                ])
            }
        }
        return out
    }
    private var task: Task<Void, Never>?

    /// How often. Khayt's own poller runs on ten seconds; a printer answers in
    /// milliseconds on a LAN and this is one small request per machine.
    static let every: Duration = .seconds(10)

    /// Long enough for a printer waking its wifi, short enough that a machine
    /// that is off does not hold the loop. Khayt uses the same five seconds.
    static let timeout: TimeInterval = 5

    /// The protocols whose whole conversation this app knows.
    ///
    /// Moonraker was first because it is the one with a machine on the bench.
    /// OctoPrint and PrusaLink joined it once their READING became a module
    /// with its own tests, and once opening an API key was settled — both send
    /// one, and it is `__enc__` on disk.
    ///
    /// Duet and Repetier are deliberately absent although they have modules
    /// too: both need a session handshake before the first read, and building a
    /// handshake against a machine nobody can point at is how a poller ships
    /// that has never once been answered. Bambu and Elegoo are not HTTP at all.
    static let spoken: Set<String> = ["moonraker", "octoprint", "prusalink"]

    /// Is this a machine this app can ask? Nil when it can.
    static func notWatched(_ machine: Machine) -> NotWatched? {
        let type = machine.printerApi?.type ?? ""
        if type.isEmpty || type == "none" { return .noConnection }
        return spoken.contains(type) ? nil : .otherProtocol(type)
    }

    /// The default port for a protocol, when the record does not say.
    static func defaultPort(_ type: String) -> Int {
        switch type {
        case "octoprint": return 80
        case "prusalink": return 80
        default: return 7125          // Moonraker
        }
    }

    func start(shop: Shop) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sweep(shop: shop)
                try? await Task.sleep(for: Self.every)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        // The bookkeeping goes with it. A book closed and reopened has not been
        // offline for an hour, and carrying a stall clock across that would
        // raise an alert about a print that finished yesterday.
        previous = [:]
        alertState = .object([:])
    }


    // ── FREEZING WHAT A FINISHED JOB USED ────────────────────────────────────
    //
    // A printer's filament and duration counters are per-JOB and reset when the
    // next print starts, so the only moment they are true is the edge out of
    // printing. Khayt has captured them there for a while and persisted them
    // under `printerCompletions`; this app read that cache and could not fill
    // it, so a shop running only the Mac never saw a measured figure on the
    // sheet that asks what a job took.

    /// Each machine's cache entry, in the shape `printer-poll-cache` keeps.
    /// Live status included — only the completions are ever written to disk.
    private var pollCache: [String: JSONValue] = [:]

    /// Fold one answered poll in, and write the book only if a job just ended.
    private func capture(_ machineId: String, status: KhaytEngine.PrinterStatus,
                         shop: Shop) async {
        guard let engine = shop.engine else { return }
        // Through JSON rather than by hand: `PrinterStatus` is `Codable` for
        // exactly this, and a status assembled field by field here would drop
        // whatever somebody adds to it next without anything saying so.
        guard let data = try? JSONEncoder().encode(status),
              let row = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        let before = pollCache[machineId] ?? .object([:])
        guard let after = try? await engine.mergePoll(previous: before, status: row, now: Date())
        else { return }
        pollCache[machineId] = after
        // A WRITE PER POLL WOULD BE A WRITE EVERY TEN SECONDS, per machine, for
        // a cache that changes when a print ENDS. The module answers "did a job
        // just finish" itself, so the book is touched at most once per job.
        guard (try? await engine.completionIsNew(before: before, after: after)) == true else { return }
        await persistCompletions(shop: shop, engine: engine)
    }

    /// Write the finished jobs to the shop's book.
    ///
    /// ── ONLY A BOOK THIS APP HOLDS ────────────────────────────────────────
    ///
    /// `StoreWriter.update` refuses unless this Mac owns the store, which is
    /// the right answer rather than an obstacle: a Khayt that owns the book is
    /// polling these printers itself and writing the same cache, and two
    /// writers would each overwrite the other's completions. The sample is not
    /// a book at all and is never written.
    ///
    /// Read-modify-write INSIDE the chain, for the reason main.js gives at its
    /// own `persistCompletions`: building the write from a long-lived in-memory
    /// copy is how a save made seconds ago is overwritten by a snapshot taken
    /// before it.
    private func persistCompletions(shop: Shop, engine: KhaytEngine) async {
        guard let build = shop.source.build else { return }
        guard let saved = try? await engine.completionsToPersist(.object(pollCache)) else { return }
        do {
            try StoreWriter.update(build) { root in
                root["printerCompletions"] = saved
            }
        } catch {
            // NOT SAID OUT LOUD. A shop cannot act on it, the measurement is
            // still in memory for this session's sheets, and the ordinary
            // reason is the one that is not a fault: Khayt has the book open
            // and is keeping this cache itself.
            return
        }
    }

    /// Ask every machine once, one after another.
    ///
    /// Serially rather than all at once: a shop has a handful of printers, and
    /// a burst of simultaneous requests to a Klipper host is a way to find out
    /// what its request queue does under load, on somebody's live print.
    private func sweep(shop: Shop) async {
        var asked = false
        for machine in shop.machines where Self.notWatched(machine) == nil {
            if Task.isCancelled { return }
            await poll(machine, shop: shop)
            asked = true
        }
        // The fleet tile is `dashboard-facts`'s answer and it reads this cache,
        // so a dashboard computed before the first poll says every machine is
        // neither live nor offline — it read 0/1 with the machine beside it
        // demonstrably printing.
        if asked {
            await shop.printersAnswered()
            await raiseAlerts(shop: shop)
        }
    }

    /// Ask the shared module what has just gone wrong, and say it.
    ///
    /// The thresholds, the cooldowns and the stall clock are all
    /// `lib/printer-alerts.js`'s. What this adds is the sentence: the module's
    /// own message is English, and a shop keeping its book in Arabic should not
    /// be told about its printer in another language.
    private func raiseAlerts(shop: Shop) async {
        guard let engine = shop.engine else { return }
        let current = statusCache
        guard let found = try? await engine.printerAlerts(
            was: previous, now: current, settings: shop.settingsDict,
            machines: shop.machineRows, state: alertState,
            enable: KhaytEngine.Alerting.sensible) else {
            previous = current
            return
        }
        previous = current
        alertState = found.state
        for alert in found.alerts {
            let name = shop.machines.first { $0.id == alert.machineId }?.name ?? alert.machineId
            notices.raise(PrinterNotice.Notice(
                machineId: alert.machineId, machine: name, kind: alert.type,
                title: Self.title(alert.type, machine: name, shop: shop),
                body: Self.body(alert, machine: name, shop: shop),
                at: Date()))
        }
    }

    static func title(_ kind: String, machine: String, shop: Shop) -> String {
        switch kind {
        case "offline": return shop.words.callIt("mac.alert_offline", ["machine": .string(machine)])
        case "stall":   return shop.words.callIt("mac.alert_stalled", ["machine": .string(machine)])
        default:        return shop.words.callIt("mac.alert_error", ["machine": .string(machine)])
        }
    }

    static func body(_ alert: KhaytEngine.PrinterAlerts.Alert, machine: String, shop: Shop) -> String {
        // The file it was making, and how far it had got. A shop deciding
        // whether to walk over needs both, and "Printer error" alone needs a
        // second look at the app to mean anything.
        var parts: [String] = []
        if !alert.filename.isEmpty { parts.append(alert.filename) }
        if alert.progress > 0 { parts.append("\(Int(alert.progress))%") }
        if parts.isEmpty { parts.append(alert.state) }
        return parts.joined(separator: " · ")
    }

    private func poll(_ machine: Machine, shop: Shop) async {
        let engine = shop.engine
        guard let engine else { return }
        do {
            let base = try await Self.baseURL(machine, engine: engine)
            // The API key, opened at the moment it is sent and never held.
            // Moonraker in trusted-client mode needs none; the other two always
            // do, and an unset one must be sent as NOTHING rather than as the
            // string "undefined" — which is the mistake main.js records having
            // made.
            var key = ""
            if let sealed = machine.printerApi?.apiKey, !sealed.isEmpty, let build = source {
                key = (try? await Secrets.open(sealed, for: build)) ?? ""
            }
            let status = try await Self.read(machine, engine: engine, base: base, key: key) { request in
                try await Self.session.data(for: request)
            }
            readings[machine.id] = Reading(status: status, problem: nil, at: Date(),
                                           consecutiveFailures: 0)
            // AFTER the reading is recorded, because a shop looking at the
            // screen should not wait on a store write to see its printer's
            // progress move. This is the only thing that notices a job ending.
            await capture(machine.id, status: status, shop: shop)
        } catch {
            let before = readings[machine.id]?.consecutiveFailures ?? 0
            readings[machine.id] = Reading(status: nil, problem: Self.say(error), at: Date(),
                                           consecutiveFailures: before + 1)
        }
    }

    /// Which book this watch belongs to, so a credential can be opened.
    var source: StoreReader.Build?

    // MARK: - The conversations

    /// One machine's whole exchange, whichever protocol it speaks.
    ///
    /// `fetch` is a seam: the orchestration — which endpoints are asked for and
    /// which failures may be survived — is where the 2026-08-27 audit found its
    /// defects, and it is the half that cannot be tested by driving a parser.
    static func read(_ machine: Machine, engine: KhaytEngine, base: URL, key: String,
                     fetch: @escaping (URLRequest) async throws -> (Data, URLResponse))
        async throws -> KhaytEngine.PrinterStatus {
        let type = machine.printerApi?.type ?? ""
        let get: (String) async throws -> [String: JSONValue] = { path in
            try await Self.get(base, path: path, key: key, type: type, fetch: fetch)
        }

        switch type {
        case "octoprint":
            // `/api/printer` is guarded by `abort(409, "Printer is not
            // operational")` in server/api/printer.py, 1.11 and 2.0 alike, and
            // that is OctoPrint running with the printer switched off — most of
            // any working day. `/api/job` carries no such guard and its `state`
            // reads "Offline" from the connection's own string. So the job is
            // asked for unconditionally and the printer TOLERANTLY; any other
            // status is still a fault.
            let job = try await get("/api/job")
            var printer: [String: JSONValue]?
            do { printer = try await get("/api/printer") }
            catch Refusal.http(409, _) { printer = nil }
            return try await engine.octoprintStatus(printer: printer, job: job)

        case "prusalink":
            // `/api/v1/status` carries no file information at any firmware
            // version, so the name comes from `/api/v1/job` — which answers 204
            // when nothing is printing. That second request is allowed to fail
            // entirely: a missing name must not cost the temperatures and the
            // progress the first one returned.
            let status = try await get("/api/v1/status")
            let job = try? await get("/api/v1/job")
            return try await engine.prusalinkStatus(status: status, job: job)

        default:
            let query = try await engine.moonrakerQuery()
            let reply = try await get("/printer/objects/query?" + query)
            // Only the machines that need it pay for the second request, and a
            // failure there keeps toolhead zero's reading rather than nothing.
            var hot: [String: JSONValue]?
            let hotName = try await engine.moonrakerActiveExtruder(reply)
            // Klipper names a toolchanger's heads `extruder1`, `extruder2`…
            // but a hand-written config may use `_`, and escaping it would ask
            // for an object the printer does not have.
            if let hotName {
                hot = try? await get("/printer/objects/query?" + hotName.uriComponent)
            }
            return try await engine.moonrakerStatus(reply, hot: hot, hotName: hotName)
        }
    }

    // MARK: - The socket

    enum Refusal: Error, CustomStringConvertible {
        case noHost
        case notALanAddress(String)
        case badPort(Int)
        case redirected
        case http(Int, String)
        case notJSON
        case noHistoryKept(String)

        var description: String {
            switch self {
            case .noHost:
                return "This machine has no address yet."
            case .notALanAddress(let host):
                return "\(host) is not an address on this network. A printer is a machine "
                     + "in the workshop, so only the private ranges are allowed."
            case .badPort(let port):
                return "\(port) is not a port."
            case .redirected:
                return "The printer sent this request somewhere else, so it was dropped."
            case .http(let code, let body):
                return "The printer's server answered \(code)"
                     + (body.isEmpty ? "." : ": \(body).")
            case .noHistoryKept(let type):
                return "A \(type.isEmpty ? "printer of this kind" : type) printer does not keep a "
                     + "job history Khayt can read. Klipper (Moonraker) is the only one of the three "
                     + "that does — the rest answer nothing at all, which arrives as a 404. Khayt "
                     + "counts this machine's wear from the jobs in your own book instead."
            case .notJSON:
                return "The printer's answer was not JSON."
            }
        }
    }

    /// Where to reach a machine, refused unless it is on this network.
    ///
    /// The guard is `lib/printer-host.js`'s, not a Swift opinion. A public
    /// address here is server-side request forgery with a printer card as the
    /// pretext, and the spellings that matter are the numeric ones —
    /// `2130706433` and `127.1` are loopback and neither looks like an address.
    static func baseURL(_ machine: Machine, engine: KhaytEngine) async throws -> URL {
        let raw = machine.printerApi?.host ?? ""
        let host = try await engine.printerHost(raw)
        guard !host.isEmpty else { throw Refusal.noHost }
        guard try await engine.printerHostAllowed(host) else { throw Refusal.notALanAddress(host) }
        let port = machine.printerApi?.port ?? defaultPort(machine.printerApi?.type ?? "")
        guard port > 0, port <= 65535 else { throw Refusal.badPort(port) }
        guard let url = URL(string: "http://\(host):\(port)") else { throw Refusal.noHost }
        return url
    }

    /// One GET, with the redirect refused.
    ///
    /// A misconfigured or compromised printer host must not be able to 302 this
    /// off the address that was checked and onto loopback or a metadata
    /// endpoint — the check above would then have guarded nothing.
    static func get(_ base: URL, path: String, key: String = "", type: String = "",
                    timeout seconds: TimeInterval = timeout,
                    fetch: ((URLRequest) async throws -> (Data, URLResponse))? = nil)
        async throws -> [String: JSONValue] {
        guard let url = URL(string: base.absoluteString + path) else { throw Refusal.noHost }
        var request = URLRequest(url: url)
        request.timeoutInterval = seconds
        request.httpMethod = "GET"
        // Guarded on a non-empty key: an unset one previously sent the literal
        // string "undefined" as the header value in the Electron app, and
        // Moonraker in trusted-client mode needs no key at all — so sending a
        // junk one is worse than sending none.
        if !key.isEmpty, ["octoprint", "prusalink", "moonraker"].contains(type) {
            request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        }
        let (data, response) = try await (fetch ?? { try await Self.session.data(for: $0) })(request)
        if let http = response as? HTTPURLResponse {
            if (300..<400).contains(http.statusCode) { throw Refusal.redirected }
            guard (200..<300).contains(http.statusCode) else {
                throw Refusal.http(http.statusCode, String(decoding: data.prefix(200), as: UTF8.self))
            }
            // 204 No Content is a legitimate answer, not an empty body to parse
            // — PrusaLink sends it when nothing is printing.
            if http.statusCode == 204 { return [:] }
        }
        guard let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw Refusal.notJSON
        }
        return decoded
    }

    /// A session that does not follow redirects and keeps nothing.
    ///
    /// No cache: a printer's status is the one thing that must never come from
    /// one, and a poll every ten seconds would otherwise fill a cache with
    /// answers that were already stale when they were written.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        return URLSession(configuration: config, delegate: NoRedirects.shared, delegateQueue: nil)
    }()

    /// `redirect: 'manual'`, in AppKit's vocabulary.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        static let shared = NoRedirects()
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)   // hand back the 3xx; `get` refuses it
        }
    }

    /// Put a reading in place, for a test that has no printer to ask.
    func setReadingForTesting(_ id: Machine.ID, _ reading: Reading) { readings[id] = reading }

    // MARK: - What the machine itself remembers

    /// How many of its own jobs to ask a printer for.
    ///
    /// The same 500 Khayt asks for. It is a history, not a feed: 133 jobs is
    /// what the machine on this bench has, and a shop that has run more than
    /// five hundred wants the recent ones.
    static let historyLimit = 500

    /// The machine's own job history, mapped by the shared module.
    ///
    /// A LONGER TIMEOUT than a status poll. Five hundred jobs with their
    /// metadata is a real reply, and a printer that is also printing builds it
    /// slowly — Khayt allows thirty seconds for the same request.
    /// Which printers keep a job history this app can read.
    ///
    /// ── THE COMMENT WAS RIGHT AND THE CONDITION WAS NOT ───────────────────
    ///
    /// The machine card said, in as many words, "Klipper keeps one; the other
    /// six protocols do not expose one Khayt can read" — and then offered the
    /// menu item whenever `notWatched(machine) == nil`, which is true for all
    /// three protocols this app speaks. So a shop that linked a Prusa was
    /// offered "Read history", and `/server/history/list` — Moonraker's path,
    /// asked of a PrusaLink box — came back 404 with no explanation of why an
    /// action the app had just offered could not work.
    ///
    /// Reported by a shop the day it linked its CORE One.
    static func keepsHistory(_ machine: Machine) -> Bool {
        (machine.printerApi?.type ?? "") == "moonraker"
    }

    static func history(_ machine: Machine, engine: KhaytEngine) async throws -> [JSONValue] {
        guard notWatched(machine) == nil else {
            throw Refusal.notALanAddress(machine.printerApi?.host ?? "")
        }
        guard keepsHistory(machine) else {
            throw Refusal.noHistoryKept(machine.printerApi?.type ?? "")
        }
        let base = try await baseURL(machine, engine: engine)
        let raw = try await get(base, path: "/server/history/list?limit=\(historyLimit)",
                                timeout: 30)
        guard case .object(let result)? = raw["result"] else { throw Refusal.notJSON }
        return try await engine.printerHistoryJobs(result)
    }

    // MARK: - Saying it

    /// `2h 14m`, or `14m`. Not a countdown to the second: the estimate is
    /// extrapolated from progress and does not deserve that much precision.
    static func spell(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    static func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }

    /// A failure in the vocabulary of the person who has to fix it.
    static func say(_ error: any Error) -> String {
        if let refusal = error as? Refusal { return refusal.description }
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorTimedOut:
            return "The printer did not answer in time. It may be asleep or off the network."
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
            return "Nothing answered at that address. Check the printer is on and on this network."
        case NSURLErrorCannotFindHost:
            return "That name did not resolve to anything on this network."
        default:
            return ns.localizedDescription
        }
    }
}
