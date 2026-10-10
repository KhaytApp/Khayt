import Foundation
import KhaytCore

/// The Mac's half of the phone's Live Activities: what the printers are doing,
/// posted to Khayt Cloud, which pushes it to the phones (khayt-cloud
/// `docs/api-contract.md`, "Live Activities").
///
/// A phone can move its own Live Activity only while its app is open. Closed,
/// only a push can — and the Mac is the one that hears the printers. So after
/// every poll that got an answer, the shared rule (`LiveActivityPlan`, the
/// phone's own plan) decides what changed, and the change goes up.
///
/// ── OFF UNTIL THE SHOP TURNS IT ON, ON THIS MAC ───────────────────────────
///
/// Nothing is posted unless "Send print progress to my iPhone" is on in
/// Settings → Integrations (`optInKey`, default OFF). It is this Mac's own
/// choice, in UserDefaults and never in the book: a shop with two Macs
/// decides on each, and syncing a book never turns it on anywhere. A shop
/// that never asked for Live Activities was posting its printers' progress
/// and job names to the cloud on every change (alpha.63 review).
///
/// ── WHAT IT NEVER DOES ───────────────────────────────────────────────────
///
/// - No book write. The memory of what was sent is this run's alone.
/// - Nothing for a shop that is not connected to Khayt Cloud, or whose
///   connection is view-only (the route needs the write role).
/// - No alarm. A failure is retried on a later reading and never shown: this
///   runs every few seconds, and a banner per poll would be noise. Retried
///   with a growing wait (`backoff`), never on every poll.
/// - No posts to nobody. A 200 that says no phone is registered (`tokens: 0`)
///   goes quiet: only a print's START asks again, at most every ten minutes.
/// - Not gated by the staff lock: no person does this — it is the shop's own
///   printers reporting, like the printer polling it rides on, and it changes
///   nothing a lock protects.
///
/// THE PRIVACY NOTE IS THE CONTRACT'S: these pushes are readable by Khayt
/// Cloud and Apple (iOS decodes the content itself). The shop owner chose
/// that, and `/privacy` on khaytapp.com says so — a Mac release carrying this
/// waits for that page.
enum LiveActivityPush {

    /// The UserDefaults key of the opt-in. Absent is OFF.
    static let optInKey = "mac.liveActivities"

    /// How long a 200 with no phones keeps this Mac quiet before a print's
    /// start may ask again.
    static let noPhonesProbe: TimeInterval = 10 * 60

    /// The wait after `failures` failures in a row: 30 s, doubling, at most
    /// half an hour.
    static func backoff(_ failures: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(0, failures - 1))), 30 * 60)
    }

    enum Outcome: Equatable {
        case sent
        /// 200, and no phone is registered for it (`tokens: 0`).
        case noPhones
        /// 401: the shop token is not taken. Quiet for an hour, like 403.
        case unauthorised
        /// 403: a viewer's connection. Nothing this Mac sends will be taken.
        case readOnly
        /// 404: a cloud that does not offer the route yet.
        case notOffered
        /// 429: inside the 15-second floor. Tried again on a later reading.
        case rateLimited
        /// Any other answer (400, 413, 5xx), or 0 for no answer at all.
        case failed(Int)
    }

    /// The body the route takes. Dates as ISO 8601 (the cloud converts them
    /// for Apple); progress as a whole number; `job` and the dates LEFT OUT
    /// when there is none, never null.
    static func body(_ step: LiveActivityPlan.Step, now: Date) -> [String: JSONValue] {
        func stamp(_ d: Date) -> JSONValue { .string(Date.ISO8601FormatStyle().format(d)) }
        func state(_ s: LiveActivityPlan.State) -> JSONValue {
            var o: [String: JSONValue] = [
                "phase": .string(s.phase.rawValue),
                "progress": .number(Double(min(100, max(0, s.progress)))),
            ]
            if let job = s.job, !job.isEmpty { o["job"] = .string(String(job.prefix(120))) }
            if let at = s.startedAt { o["startedAt"] = stamp(at) }
            if let at = s.endsAt { o["endsAt"] = stamp(at) }
            return .object(o)
        }
        switch step {
        case let .start(id, name, s):
            var b: [String: JSONValue] = ["event": .string("start"), "machineId": .string(id),
                                          "machineName": .string(String(name.prefix(80))), "state": state(s)]
            if let ends = s.endsAt { b["staleAt"] = stamp(ends) }
            return b
        case let .update(id, s):
            var b: [String: JSONValue] = ["event": .string("update"), "machineId": .string(id), "state": state(s)]
            if let ends = s.endsAt { b["staleAt"] = stamp(ends) }
            return b
        case let .end(id, s):
            // Left on the Lock Screen half an hour, as the phone does, so the
            // result is seen.
            return ["event": .string("end"), "machineId": .string(id), "state": state(s),
                    "dismissAt": stamp(now.addingTimeInterval(30 * 60))]
        }
    }

    @MainActor static func send(_ connection: CloudReader.Connection, token: String, step: LiveActivityPlan.Step,
                     now: Date,
                     fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws -> Outcome {
        var request = try CloudReader.request(connection, token: token, method: "POST", tail: "/live-activity")
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body(step, now: now)))
        let (data, response) = try await fetch(request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return tokens(in: data) == 0 ? .noPhones : .sent
        case 401: return .unauthorised
        case 403: return .readOnly
        case 404: return .notOffered
        case 429: return .rateLimited
        case let code: return .failed(code)
        }
    }

    /// `tokens` out of the 200's `{ ok, tokens, … }`: how many phones the post
    /// was meant for. Nil when the reply does not say (an older cloud), which
    /// is read as sent.
    static func tokens(in data: Data) -> Int? {
        guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .number(let n)? = o["tokens"], n.isFinite else { return nil }
        return Int(max(0, min(n, 1e9)))
    }

    /// The most of a reply that is read: the 200 is a handful of counts.
    static let maxReply = 4096

    /// The real transport: the cloud's own session (same-origin redirects
    /// only), and at most `maxReply` bytes of the answer, so a misbehaving
    /// server cannot hand this a large one.
    static func liveFetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await CloudReader.session.bytes(for: request)
        defer { bytes.task.cancel() }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= maxReply { break }
        }
        return (data, response)
    }

    /// What this run has sent, per machine. Not the book's: a Mac that
    /// restarts mid-print sends a `start` again, and the cloud does not wake a
    /// phone already showing that machine.
    @MainActor final class Memory {
        var shopId = ""
        var running: [String: LiveActivityPlan.State] = [:]
        var lastSent: [String: Date] = [:]
        var inFlight: Set<String> = []
        /// A 401, 403 or 404 stops sending until then, rather than asking
        /// every poll; so does a failure, for `backoff(failures)`.
        var quietUntil: Date?
        /// Failures in a row, for the backoff. A send that is taken resets it.
        var failures = 0
        /// The last 200 said no phone is registered; when it was asked.
        var noPhonesSince: Date?
    }
}

extension Shop {

    /// One printer answered: tell the phones what changed, if anything.
    ///
    /// Called from `PrinterWatch.poll` after a reading is recorded. A poll that
    /// got no answer does not call this — a machine nobody heard from has not
    /// ended, as the phone's rule says.
    func liveActivityHeard(_ machine: Machine, status: KhaytEngine.PrinterStatus, now: Date = Date()) {
        guard liveActivitiesOptedIn(), Self.cloudConnected(settingsDict), cloudRoleCanWrite else { return }
        var cloud: [String: JSONValue] = [:]
        if case .object(let c)? = settingsDict["cloud"] { cloud = c }
        let shopId = Self.plainString(cloud["shopId"]) ?? ""
        let memory = liveActivities
        if memory.shopId != shopId {
            // Another shop's connection: nothing it was told applies here.
            memory.shopId = shopId; memory.running = [:]; memory.lastSent = [:]; memory.quietUntil = nil
            memory.failures = 0; memory.noPhonesSince = nil
        }
        if let quiet = memory.quietUntil, now < quiet { return }
        guard !memory.inFlight.contains(machine.id) else { return }

        let remaining = status.timeRemaining.flatMap { $0.isFinite && $0 > 0 ? Int(min($0, 1e9).rounded()) : nil }
        let reading = LiveActivityPlan.Reading(
            name: machine.name, state: status.state, progress: status.progress,
            filename: status.filename.isEmpty ? nil : status.filename,
            timeRemaining: remaining, error: nil)
        let steps = LiveActivityPlan.steps(readings: [machine.id: reading],
                                           running: memory.running.filter { $0.key == machine.id }, now: now)
        guard let step = steps.first,
              LiveActivityPlan.due(step, running: memory.running, lastSent: memory.lastSent, now: now) else { return }
        // No phone to tell: the plan still moves, so the next print is seen
        // as a start, but only a start asks the cloud again — and not within
        // ten minutes of the last time it said nobody was listening.
        if let since = memory.noPhonesSince {
            let probe: Bool
            if case .start = step { probe = now.timeIntervalSince(since) >= LiveActivityPush.noPhonesProbe } else { probe = false }
            guard probe else { liveActivityRecord(step, outcome: .sent, now: now, quietly: true); return }
        }

        let connection = CloudReader.Connection(url: Self.plainString(cloud["url"]) ?? "", shopId: shopId,
                                                storedToken: Self.plainString(cloud["token"]) ?? "")
        let book = source
        memory.inFlight.insert(machine.id)
        Task { @MainActor [weak self] in
            defer { memory.inFlight.remove(machine.id) }
            guard let self else { return }
            let outcome: LiveActivityPush.Outcome
            do {
                let token = try await Secrets.open(connection.storedToken, for: book)
                outcome = try await LiveActivityPush.send(connection, token: token, step: step, now: now,
                                                          fetch: self.liveActivityFetch)
            } catch {
                outcome = .failed(0)   // no answer: backed off like any failure
            }
            self.liveActivityRecord(step, outcome: outcome, now: now)
        }
    }

    /// What a reply means for the memory. Separate so a test can drive it.
    /// `quietly`: the step was not posted (nobody to tell) but the plan moves
    /// on as if it had been, so the ongoing print is not taken for a new one.
    func liveActivityRecord(_ step: LiveActivityPlan.Step, outcome: LiveActivityPush.Outcome, now: Date,
                            quietly: Bool = false) {
        let memory = liveActivities
        func moved() {
            switch step {
            case let .start(id, _, s), let .update(id, s): memory.running[id] = s
            case let .end(id, _): memory.running[id] = nil
            }
        }
        switch outcome {
        case .sent:
            if !quietly {
                memory.lastSent[step.machineId] = now
                memory.failures = 0
                memory.noPhonesSince = nil
            }
            moved()
        case .noPhones:
            memory.lastSent[step.machineId] = now
            memory.failures = 0
            memory.noPhonesSince = now
            moved()
        case .rateLimited:
            // Inside the floor: wait it out, then the next reading tries again.
            memory.lastSent[step.machineId] = now
        case .readOnly, .notOffered, .unauthorised:
            memory.quietUntil = now.addingTimeInterval(3600)
        case .failed:
            // Nothing recorded, so a later reading tries again — after a wait
            // that grows with each failure in a row.
            memory.failures += 1
            memory.quietUntil = now.addingTimeInterval(LiveActivityPush.backoff(memory.failures))
        }
    }
}
