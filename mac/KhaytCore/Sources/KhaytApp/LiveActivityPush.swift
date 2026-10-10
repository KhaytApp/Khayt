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
/// ── WHAT IT NEVER DOES ───────────────────────────────────────────────────
///
/// - No book write. The memory of what was sent is this run's alone.
/// - Nothing for a shop that is not connected to Khayt Cloud, or whose
///   connection is view-only (the route needs the write role).
/// - No alarm. A failure is retried on a later reading and never shown: this
///   runs every few seconds, and a banner per poll would be noise.
/// - Not gated by the staff lock: no person does this — it is the shop's own
///   printers reporting, like the printer polling it rides on, and it changes
///   nothing a lock protects.
///
/// THE PRIVACY NOTE IS THE CONTRACT'S: these pushes are readable by Khayt
/// Cloud and Apple (iOS decodes the content itself). The shop owner chose
/// that, and `/privacy` on khaytapp.com says so — a Mac release carrying this
/// waits for that page.
enum LiveActivityPush {

    enum Outcome: Equatable {
        case sent
        /// 403: a viewer's connection. Nothing this Mac sends will be taken.
        case readOnly
        /// 404: a cloud that does not offer the route yet.
        case notOffered
        /// 429: inside the 15-second floor. Tried again on a later reading.
        case rateLimited
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
                     fetch: (URLRequest) async throws -> URLResponse) async throws -> Outcome {
        var request = try CloudReader.request(connection, token: token, method: "POST", tail: "/live-activity")
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body(step, now: now)))
        switch (try await fetch(request) as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return .sent
        case 403: return .readOnly
        case 404: return .notOffered
        case 429: return .rateLimited
        case let code: return .failed(code)
        }
    }

    /// The real transport: the cloud's own session (same-origin redirects
    /// only), and the response's STATUS — the body is never read, so a
    /// misbehaving server cannot hand this a large one.
    static func liveFetch(_ request: URLRequest) async throws -> URLResponse {
        let (bytes, response) = try await CloudReader.session.bytes(for: request)
        bytes.task.cancel()
        return response
    }

    /// What this run has sent, per machine. Not the book's: a Mac that
    /// restarts mid-print sends a `start` again, and the cloud does not wake a
    /// phone already showing that machine.
    @MainActor final class Memory {
        var shopId = ""
        var running: [String: LiveActivityPlan.State] = [:]
        var lastSent: [String: Date] = [:]
        var inFlight: Set<String> = []
        /// A 403 or 404 stops sending until then, rather than asking every poll.
        var quietUntil: Date?
    }
}

extension Shop {

    /// One printer answered: tell the phones what changed, if anything.
    ///
    /// Called from `PrinterWatch.poll` after a reading is recorded. A poll that
    /// got no answer does not call this — a machine nobody heard from has not
    /// ended, as the phone's rule says.
    func liveActivityHeard(_ machine: Machine, status: KhaytEngine.PrinterStatus, now: Date = Date()) {
        guard Self.cloudConnected(settingsDict), cloudRoleCanWrite else { return }
        var cloud: [String: JSONValue] = [:]
        if case .object(let c)? = settingsDict["cloud"] { cloud = c }
        let shopId = Self.plainString(cloud["shopId"]) ?? ""
        let memory = liveActivities
        if memory.shopId != shopId {
            // Another shop's connection: nothing it was told applies here.
            memory.shopId = shopId; memory.running = [:]; memory.lastSent = [:]; memory.quietUntil = nil
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
                return   // tried again on a later reading
            }
            self.liveActivityRecord(step, outcome: outcome, now: now)
        }
    }

    /// What a reply means for the memory. Separate so a test can drive it.
    func liveActivityRecord(_ step: LiveActivityPlan.Step, outcome: LiveActivityPush.Outcome, now: Date) {
        let memory = liveActivities
        switch outcome {
        case .sent:
            memory.lastSent[step.machineId] = now
            switch step {
            case let .start(id, _, s), let .update(id, s): memory.running[id] = s
            case let .end(id, _): memory.running[id] = nil
            }
        case .rateLimited:
            // Inside the floor: wait it out, then the next reading tries again.
            memory.lastSent[step.machineId] = now
        case .readOnly, .notOffered:
            memory.quietUntil = now.addingTimeInterval(3600)
        case .failed:
            break   // nothing recorded, so the next reading tries again
        }
    }
}
