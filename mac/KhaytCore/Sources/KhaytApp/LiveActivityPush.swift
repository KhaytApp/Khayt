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
    ///
    /// `jobTitle` is the job's name when the book can say which job the file
    /// belongs to; the printer's file name otherwise. The phone showed
    /// `plate_1.gcode.3mf` where the shop expects "Museum replica" (push
    /// review M5).
    static func body(_ step: LiveActivityPlan.Step, now: Date, jobTitle: String? = nil) -> [String: JSONValue] {
        func stamp(_ d: Date) -> JSONValue { .string(Date.ISO8601FormatStyle().format(d)) }
        func state(_ s: LiveActivityPlan.State) -> JSONValue {
            var o: [String: JSONValue] = [
                "phase": .string(s.phase.rawValue),
                "progress": .number(Double(min(100, max(0, s.progress)))),
            ]
            let title = (jobTitle?.isEmpty == false ? jobTitle : nil) ?? s.job
            if let job = title, !job.isEmpty { o["job"] = .string(String(job.prefix(120))) }
            if let at = s.startedAt { o["startedAt"] = stamp(at) }
            if let at = s.endsAt { o["endsAt"] = stamp(at) }
            return .object(o)
        }
        // `at`: when this happened on the Mac, in Unix seconds, so the cloud
        // orders what it hears by when it happened rather than when it
        // arrived (push review C3). Added to every event below.
        let at: JSONValue = .number(now.timeIntervalSince1970.rounded(.down))
        return body(step, now: now, at: at, stamp: stamp, state: state)
    }

    private static func body(_ step: LiveActivityPlan.Step, now: Date, at: JSONValue,
                             stamp: (Date) -> JSONValue,
                             state: (LiveActivityPlan.State) -> JSONValue) -> [String: JSONValue] {
        var b = bodyWithoutTime(step, now: now, stamp: stamp, state: state)
        b["at"] = at
        return b
    }

    private static func bodyWithoutTime(_ step: LiveActivityPlan.Step, now: Date, stamp: (Date) -> JSONValue,
                                        state: (LiveActivityPlan.State) -> JSONValue) -> [String: JSONValue] {
        switch step {
        case let .start(id, name, s):
            // ALWAYS a stale time, the printer's finish or five minutes from
            // now: a stream that stops goes stale on the phone instead of
            // showing its last percent for hours (push review M1).
            return ["event": .string("start"), "machineId": .string(id),
                    "machineName": .string(String(name.prefix(80))), "state": state(s),
                    "staleAt": stamp(LiveActivityPlan.staleAt(s, now: now))]
        case let .update(id, s):
            return ["event": .string("update"), "machineId": .string(id), "state": state(s),
                    "staleAt": stamp(LiveActivityPlan.staleAt(s, now: now))]
        case let .end(id, s):
            // Left on the Lock Screen half an hour, as the phone does, so the
            // result is seen.
            return ["event": .string("end"), "machineId": .string(id), "state": state(s),
                    "dismissAt": stamp(now.addingTimeInterval(30 * 60))]
        }
    }

    @MainActor static func send(_ connection: CloudReader.Connection, token: String, step: LiveActivityPlan.Step,
                     now: Date, jobTitle: String? = nil,
                     fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws -> Outcome {
        var request = try CloudReader.request(connection, token: token, method: "POST", tail: "/live-activity")
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body(step, now: now, jobTitle: jobTitle)))
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
        guard case .object(let o)? = try? JSONValue.decode(JSONValue.self, from: data),
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
        /// A 401, 403 or 404 stops sending for the whole shop until then:
        /// those are about the connection, not about one printer.
        var quietUntil: Date?
        /// A failed post backs off THAT printer only (push review M2: one
        /// failure used to silence every printer for up to half an hour).
        var quietFor: [String: Date] = [:]
        var failuresFor: [String: Int] = [:]
        /// An end is never held behind a backoff; it is tried again on the
        /// next reading at most every `endRetry`.
        var lastEndTry: [String: Date] = [:]
        /// The last 200 said no phone is registered; when it was asked.
        var noPhonesSince: Date?
        /// The job's name for a printer's file, once looked up.
        var titles: [String: String] = [:]
    }

    /// How soon an end that did not go through is tried again.
    static let endRetry: TimeInterval = 15

    // ── WHAT IS RUNNING SURVIVES A RELAUNCH ────────────────────────────────
    //
    // A Mac relaunched mid-print started with nothing remembered, so when
    // that print finished there was no "was" to end and the END was never
    // sent: the phone kept "printing" for hours (push review M1). The running
    // states are kept in this Mac's UserDefaults, per shop, and read back the
    // first time the shop is seen. Never in the book: this is this Mac's
    // conversation with the phones, like the opt-in.

    static let runningKey = "mac.liveActivityRunning"

    private struct Kept: Codable {
        var shopId: String
        var machines: [String: Saved]
        struct Saved: Codable {
            var phase: String; var job: String?; var progress: Int
            var startedAt: Date?; var endsAt: Date?
        }
    }

    /// The running states kept for `shopId`, or none. A state from more than
    /// a day ago is not a print any more.
    static func restore(shopId: String, now: Date = Date(), defaults: UserDefaults = .standard)
        -> [String: LiveActivityPlan.State] {
        guard let data = defaults.data(forKey: runningKey),
              let kept = try? JSONDecoder().decode(Kept.self, from: data), kept.shopId == shopId else { return [:] }
        var out: [String: LiveActivityPlan.State] = [:]
        for (id, s) in kept.machines {
            guard let phase = LiveActivityPlan.Phase(rawValue: s.phase) else { continue }
            if let started = s.startedAt, now.timeIntervalSince(started) > 24 * 3600 { continue }
            out[id] = LiveActivityPlan.State(phase: phase, job: s.job, progress: s.progress,
                                             startedAt: s.startedAt, endsAt: s.endsAt)
        }
        return out
    }

    static func keep(_ running: [String: LiveActivityPlan.State], shopId: String,
                     defaults: UserDefaults = .standard) {
        let kept = Kept(shopId: shopId, machines: running.mapValues {
            .init(phase: $0.phase.rawValue, job: $0.job, progress: $0.progress,
                  startedAt: $0.startedAt, endsAt: $0.endsAt)
        })
        if let data = try? JSONEncoder().encode(kept) { defaults.set(data, forKey: runningKey) }
    }
}

extension Shop {

    /// One printer answered: tell the phones what changed, if anything.
    ///
    /// Called from `PrinterWatch.poll` after a reading is recorded. A poll that
    /// got no answer does not call this — a machine nobody heard from has not
    /// ended, as the phone's rule says.
    func liveActivityHeard(_ machine: Machine, status: KhaytEngine.PrinterStatus, now: Date = Date()) {
        // A retired or under-service printer is not polled, but a one-off
        // refresh can still hear it; nothing about it belongs on a phone's
        // Lock Screen (`lib/machine-status.js`).
        guard machine.inService else { return }
        guard liveActivitiesOptedIn(), Self.cloudConnected(settingsDict), cloudRoleCanWrite else { return }
        var cloud: [String: JSONValue] = [:]
        if case .object(let c)? = settingsDict["cloud"] { cloud = c }
        let shopId = Self.plainString(cloud["shopId"]) ?? ""
        let memory = liveActivityMemory(shopId: shopId, now: now)
        if let quiet = memory.quietUntil, now < quiet { return }
        guard !memory.inFlight.contains(machine.id) else { return }

        let remaining = status.timeRemaining.flatMap { $0.isFinite && $0 > 0 ? Int(min($0, 1e9).rounded()) : nil }
        let reading = LiveActivityPlan.Reading(
            name: machine.name, state: status.state, progress: status.progress,
            filename: status.filename.isEmpty ? nil : status.filename,
            timeRemaining: remaining, error: nil)
        let steps = LiveActivityPlan.steps(readings: [machine.id: reading],
                                           running: memory.running.filter { $0.key == machine.id }, now: now)
        guard var step = steps.first ?? LiveActivityPlan.refresh(machineId: machine.id, reading: reading,
                                                                 running: memory.running, lastSent: memory.lastSent,
                                                                 now: now),
              LiveActivityPlan.due(step, running: memory.running, lastSent: memory.lastSent, now: now) else { return }
        // An end heard late (the Mac slept through it, or was quit and
        // relaunched) carries the finish the printer last predicted, not the
        // moment it was heard.
        if case let .end(id, s) = step, let was = memory.running[id] {
            var ended = s; ended.endsAt = LiveActivityPlan.endedAt(was, now: now)
            step = .end(machineId: id, ended)
        }
        guard liveActivityMayTry(step, memory: memory, now: now) else { return }
        // No phone to tell: the plan still moves, so the next print is seen
        // as a start, but only a start asks the cloud again — and not within
        // ten minutes of the last time it said nobody was listening.
        if let since = memory.noPhonesSince {
            let probe: Bool
            if case .start = step { probe = now.timeIntervalSince(since) >= LiveActivityPush.noPhonesProbe } else { probe = false }
            guard probe else { liveActivityRecord(step, outcome: .sent, now: now, quietly: true); return }
        }

        liveActivityPost(step, cloud: cloud, shopId: shopId, now: now)
    }

    /// A machine the poller no longer asks — put under service, retired, or
    /// its connection removed. Its phone's Live Activity would otherwise stay
    /// on the Lock Screen: nothing it says is heard again, and only a heard
    /// reading ever ends one. Ended as cancelled, the one phase that does not
    /// claim the print finished or failed when nobody saw how it went.
    func liveActivityUnwatched(_ machineId: String, now: Date = Date()) {
        guard liveActivitiesOptedIn(), Self.cloudConnected(settingsDict), cloudRoleCanWrite else { return }
        var cloud: [String: JSONValue] = [:]
        if case .object(let c)? = settingsDict["cloud"] { cloud = c }
        let shopId = Self.plainString(cloud["shopId"]) ?? ""
        let memory = liveActivityMemory(shopId: shopId, now: now)
        guard let was = memory.running[machineId], !memory.inFlight.contains(machineId) else { return }
        if let quiet = memory.quietUntil, now < quiet { return }
        let step = LiveActivityPlan.Step.end(machineId: machineId, LiveActivityPlan.State(
            phase: .cancelled, job: was.job, progress: was.progress, startedAt: was.startedAt, endsAt: now))
        guard liveActivityMayTry(step, memory: memory, now: now) else { return }
        if memory.noPhonesSince != nil {
            liveActivityRecord(step, outcome: .sent, now: now, quietly: true); return
        }
        liveActivityPost(step, cloud: cloud, shopId: shopId, now: now)
    }

    /// Post one step on its own task and record the reply.
    private func liveActivityPost(_ step: LiveActivityPlan.Step, cloud: [String: JSONValue],
                                  shopId: String, now: Date) {
        let memory = liveActivities
        let machineId = step.machineId
        let connection = CloudReader.Connection(url: Self.plainString(cloud["url"]) ?? "", shopId: shopId,
                                                storedToken: Self.plainString(cloud["token"]) ?? "")
        let book = source
        memory.inFlight.insert(machineId)
        if case .end = step { memory.lastEndTry[machineId] = now }
        Task { @MainActor [weak self] in
            defer { memory.inFlight.remove(machineId) }
            guard let self else { return }
            let outcome: LiveActivityPush.Outcome
            do {
                let token = try await Secrets.open(connection.storedToken, for: book)
                let title = await self.liveActivityJobTitle(step)
                outcome = try await LiveActivityPush.send(connection, token: token, step: step, now: now,
                                                          jobTitle: title, fetch: self.liveActivityFetch)
            } catch {
                outcome = .failed(0)   // no answer: backed off like any failure
            }
            self.liveActivityRecord(step, outcome: outcome, now: now)
        }
    }

    /// The memory for this shop: another shop's connection starts clean, and
    /// the first look at a shop reads back what was running before a relaunch.
    func liveActivityMemory(shopId: String, now: Date) -> LiveActivityPush.Memory {
        let memory = liveActivities
        if memory.shopId != shopId {
            memory.shopId = shopId
            // Only a real book's: the sample is every test's book, and one
            // test's printer must not be running in the next one.
            memory.running = source.build == nil ? [:] : LiveActivityPush.restore(shopId: shopId, now: now)
            memory.lastSent = [:]; memory.quietUntil = nil; memory.quietFor = [:]; memory.failuresFor = [:]
            memory.lastEndTry = [:]; memory.noPhonesSince = nil; memory.titles = [:]
        }
        return memory
    }

    /// May this step be tried now? An end (and a print that just failed)
    /// is never held behind a printer's backoff, only spaced by `endRetry`;
    /// anything else waits out that printer's own backoff.
    func liveActivityMayTry(_ step: LiveActivityPlan.Step, memory: LiveActivityPush.Memory, now: Date) -> Bool {
        let id = step.machineId
        let urgent: Bool
        switch step {
        case .end: urgent = true
        case let .update(_, s): urgent = s.phase == .failed
        case .start: urgent = false
        }
        if urgent {
            guard let last = memory.lastEndTry[id] else { return true }
            return now.timeIntervalSince(last) >= LiveActivityPush.endRetry
        }
        if let quiet = memory.quietFor[id], now < quiet { return false }
        return true
    }

    /// The job's name for the file a printer is printing, when the book can
    /// say which job without guessing (the finish photo's own rule,
    /// `print-finish-photo.jobFor`); nil otherwise, and the file name is sent.
    func liveActivityJobTitle(_ step: LiveActivityPlan.Step) async -> String? {
        let state: LiveActivityPlan.State
        switch step { case let .start(_, _, s), let .update(_, s), let .end(_, s): state = s }
        guard let file = state.job, !file.isEmpty, let engine else { return nil }
        let key = step.machineId + "|" + file
        if let known = liveActivities.titles[key] { return known.isEmpty ? nil : known }
        let id = (try? await engine.printFinishJob(printLog: orderRows, machineId: step.machineId,
                                                     filename: file)) ?? nil
        let order = id.flatMap { id in orders.first { $0.id == id } }
        let title = order.map { $0.project.isEmpty ? $0.id : $0.project } ?? ""
        liveActivities.titles[key] = title
        return title.isEmpty ? nil : title
    }

    /// What a reply means for the memory. Separate so a test can drive it.
    /// `quietly`: the step was not posted (nobody to tell) but the plan moves
    /// on as if it had been, so the ongoing print is not taken for a new one.
    func liveActivityRecord(_ step: LiveActivityPlan.Step, outcome: LiveActivityPush.Outcome, now: Date,
                            quietly: Bool = false) {
        let memory = liveActivities
        let id = step.machineId
        func moved() {
            switch step {
            case let .start(id, _, s), let .update(id, s): memory.running[id] = s
            case let .end(id, _): memory.running[id] = nil; memory.lastEndTry[id] = nil
            }
            if source.build != nil { LiveActivityPush.keep(memory.running, shopId: memory.shopId) }
        }
        switch outcome {
        case .sent:
            if !quietly {
                memory.lastSent[id] = now
                memory.failuresFor[id] = nil; memory.quietFor[id] = nil
                memory.noPhonesSince = nil
                // One per print: the start, not every update after it.
                if case .start = step { Telemetry.feature(.liveActivitySent, in: self) }
            }
            moved()
        case .noPhones:
            memory.lastSent[id] = now
            memory.failuresFor[id] = nil; memory.quietFor[id] = nil
            memory.noPhonesSince = now
            moved()
        case .rateLimited:
            // Inside the floor: wait it out, then the next reading tries again.
            memory.lastSent[id] = now
        case .readOnly, .notOffered, .unauthorised:
            memory.quietUntil = now.addingTimeInterval(3600)
        case .failed:
            // Nothing recorded, so a later reading tries again. THIS printer
            // waits, longer with each failure in a row; the others do not.
            // An end is not held at all: `lastEndTry` spaces its retries.
            if case .end = step { break }
            let n = (memory.failuresFor[id] ?? 0) + 1
            memory.failuresFor[id] = n
            memory.quietFor[id] = now.addingTimeInterval(LiveActivityPush.backoff(n))
        }
    }
}
