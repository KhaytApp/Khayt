import Foundation
import KhaytCore

/// A Snapmaker U1's camera, kept awake while somebody is looking at it, and
/// its chamber light.
///
/// ── WHY THE CAMERA FALLS ASLEEP ──────────────────────────────────────────
///
/// The U1 rewrites `monitor.jpg` only while one of Snapmaker's own clients
/// asks it to, and lets it stop a few minutes after the last one goes. So a
/// shop that opened Khayt after a print started saw the plate as it was when
/// the touchscreen was last touched, drawn (correctly) as paused. The printer's
/// own clients ask with Moonraker's `camera.start_monitor`, and Snapmaker's
/// repeater registers that method with `transports = all & ~HTTP`: it can be
/// called over the WebSocket and nowhere else.
///
/// The approach — the method, `domain: lan`, renewing once a minute, never
/// sending a stop, short deadlines — was learned from
/// lanwen/orca-snapmaker-u1-camera-plugin (MIT). Thank you.
///
/// ── WHAT THIS FILE DOES NOT DECIDE ───────────────────────────────────────
///
/// Every rule is `lib/webcam.js`: which machine needs this, the socket's
/// address, the one frame, which reply counts, the two light lines. The
/// frame and the script are checked against the lib's gates
/// (`wsMethodAllowed`, `scriptAllowed`) before they are written, because the
/// same socket also carries Snapmaker's firmware-upgrade methods. Like
/// `SdcpSocket`: one question, then hang up.
///
/// ── THE SAME HOST RULES AS A STILL ───────────────────────────────────────
///
/// The address is the printer's own, checked by `assertWebcamHost`, then
/// `PrinterWatch.pinned` (this network, and dialled at the address that was
/// checked), and redirects are refused — exactly what `Camera.fetch` does
/// before it sends the printer's credential.
enum U1Camera {
    /// What one renewal came to.
    enum Outcome: String, Equatable, Sendable {
        case ok, error, timeout, failed, refused
    }

    /// One exchange on the socket: send `frame`, return the first reply the
    /// lib counts (`ok` / `error`), or why there was none. A seam for tests.
    typealias Exchange = @Sendable (_ request: URLRequest, _ frame: String, _ id: Int,
                                    _ deadline: Duration, _ engine: KhaytEngine) async -> Outcome

    /// A plain HTTP call to the printer, for the light. A seam for tests.
    typealias Get = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The machine as the shared rules want it: the printer's own record and
    /// the camera on it. The key travels sealed and is opened only here.
    @MainActor
    static func record(_ machine: Machine, shop: Shop) async -> (row: JSONValue, api: JSONValue)? {
        guard let api = await shop.printerApiRow(machine) else { return nil }
        var cam: [String: JSONValue] = ["enabled": .bool(machine.hasCamera)]
        if let still = machine.webcam?.snapshotUrl { cam["snapshotUrl"] = .string(still) }
        if let feed = machine.webcam?.streamUrl { cam["streamUrl"] = .string(feed) }
        return (.object(["printerApi": api, "webcam": .object(cam)]), api)
    }

    /// The http(s) address `url` was built from, checked and aimed by the
    /// still's rules; nil when any of them says no.
    static func aimed(_ url: String, api: JSONValue, engine: KhaytEngine,
                      lookUp: @escaping @Sendable (String) async -> [String]) async -> URL? {
        guard (try? await engine.assertWebcamHost(url, printerApi: api)) != nil,
              let parsed = URL(string: url) else { return nil }
        return await PrinterWatch.pinned(parsed, engine: engine, lookUp: lookUp)
    }

    /// Ask the printer to keep its camera going for another minute.
    ///
    /// Returns how long until the next renewal, or nil when this machine's
    /// camera needs no keeping (so the caller stops asking). A renewal that
    /// failed still returns the interval: the printer may be back next time.
    @MainActor
    static func keepAwake(_ machine: Machine, shop: Shop,
                          exchange: Exchange? = nil,
                          lookUp: @escaping @Sendable (String) async -> [String] = { await WebhookClient.addresses(of: $0) })
    async -> (renew: Duration, outcome: Outcome)? {
        guard let engine = shop.engine, machine.hasCamera, machine.inService,
              let rec = await record(machine, shop: shop),
              let plan = try? await engine.keepAwake(machine: rec.row) else { return nil }
        let renew = Duration.milliseconds(Int(plan.renewMs))
        let deadline = Duration.milliseconds(Int(plan.deadlineMs))

        // The socket's address, as http(s) for the host rules, then back.
        let http = plan.wsUrl.replacingOccurrences(of: "^ws", with: "http", options: .regularExpression)
        guard let target = await aimed(http, api: rec.api, engine: engine, lookUp: lookUp),
              var parts = URLComponents(url: target, resolvingAgainstBaseURL: false) else {
            return (renew, .refused)
        }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        guard let url = parts.url else { return (renew, .refused) }

        // The one frame, and the gate on it.
        let id = Int.random(in: 1...999_999)
        guard let frame = try? await engine.keepAwakeRequest(id: id),
              await frameAllowed(frame, id: id, engine: engine) else {
            return (renew, .refused)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Double(plan.deadlineMs) / 1000
        for (name, value) in plan.headers { request.setValue(value, forHTTPHeaderField: name) }
        let outcome = await (exchange ?? live)(request, frame, id, deadline, engine)
        return (renew, outcome)
    }

    private struct Frame: Decodable { let method: String }

    /// The gate every frame passes before it is written: it must be EXACTLY
    /// the frame the lib builds for this id (not merely carry an allowed
    /// method — extra params would ride along otherwise), and its method must
    /// be on the lib's allow-list. The socket also carries Snapmaker's
    /// firmware methods; nothing else is ever written to it.
    static func frameAllowed(_ frame: String, id: Int, engine: KhaytEngine) async -> Bool {
        guard let built = try? await engine.keepAwakeRequest(id: id), built == frame,
              let method = (try? JSONDecoder().decode(Frame.self, from: Data(frame.utf8)))?.method,
              (try? await engine.wsMethodAllowed(method)) == true else { return false }
        return true
    }

    /// The real socket: open, send, read until our reply, hang up. Gated
    /// again here, so no caller can hand it a frame the lib did not build.
    static let live: Exchange = { request, frame, id, deadline, engine in
        guard await frameAllowed(frame, id: id, engine: engine) else { return .refused }
        let session = URLSession(configuration: .ephemeral, delegate: RefuseRedirects.shared,
                                 delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do { try await task.send(.string(frame)) } catch { return .failed }
                while true {
                    let message: URLSessionWebSocketTask.Message
                    do { message = try await task.receive() } catch { return .failed }
                    let text: String
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(decoding: d, as: UTF8.self)
                    @unknown default: continue
                    }
                    switch (try? await engine.keepAwakeReply(text, id: id)) ?? "other" {
                    case "ok": return .ok
                    case "error": return .error
                    default: continue
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return .timeout
            }
            let first = await group.next() ?? .failed
            task.cancel(with: .goingAway, reason: nil)
            group.cancelAll()
            return first
        }
    }

    // MARK: - The chamber light

    /// Read the light: true on, false off, nil when this printer has none (or
    /// could not be asked — the row then says nothing rather than guessing).
    @MainActor
    static func readLight(_ machine: Machine, shop: Shop, get: Get? = nil,
                          lookUp: @escaping @Sendable (String) async -> [String] = { await WebhookClient.addresses(of: $0) })
    async -> Bool? {
        guard let engine = shop.engine,
              let rec = await record(machine, shop: shop),
              let plan = try? await engine.chamberLight(machine: rec.row),
              let url = await aimed(plan.queryUrl, api: rec.api, engine: engine, lookUp: lookUp) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (name, value) in plan.headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await (get ?? httpGet)(request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= lightReplyCap,
              let body = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return try? await engine.chamberLightState(body)
    }

    /// Switch the light, then read it back. Returns what the printer says now
    /// (nil if it could not be asked). The script is the lib's, gated by it.
    @MainActor
    static func setLight(_ machine: Machine, on: Bool, shop: Shop, get: Get? = nil,
                         lookUp: @escaping @Sendable (String) async -> [String] = { await WebhookClient.addresses(of: $0) })
    async -> Bool? {
        guard let engine = shop.engine,
              let rec = await record(machine, shop: shop),
              let plan = try? await engine.chamberLight(machine: rec.row),
              let script = try? await engine.chamberLightScript(on: on),
              (try? await engine.scriptAllowed(script)) == true,
              let url = await aimed(plan.scriptUrl, api: rec.api, engine: engine, lookUp: lookUp) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in plan.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try? JSONEncoder().encode(["script": script])
        _ = try? await (get ?? httpGet)(request)
        return await readLight(machine, shop: shop, get: get, lookUp: lookUp)
    }

    /// The light's reply is a few hundred bytes; anything past this is not
    /// the printer's answer, and is not read into memory.
    static let lightReplyCap = 64 * 1024

    /// Thrown when a reply runs past its cap.
    struct TooLarge: Error {}

    /// A call to the printer that STREAMS its reply and stops at the cap,
    /// rather than buffering whatever the other end sends and checking after.
    static let httpGet: Get = { request in
        let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: RefuseRedirects.shared)
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > lightReplyCap { throw TooLarge() }
        }
        return (data, response)
    }
}

// MARK: - Keeping it awake while a tile is on screen

extension Camera {
    /// What the light row shows.
    enum Light: Equatable {
        case on, off
        /// Asked to switch; the switch is held until the printer says.
        case switching(to: Bool)
        /// The switch did not take. `was` is what the printer still says.
        case failed(was: Bool)
    }

    /// A tile showing this machine came on screen. The first watcher starts
    /// the renewals; the camera is asked again at once so the picture wakes
    /// with it, instead of after the paused minute.
    func watch(_ machine: Machine, shop: Shop) {
        watchers[machine.id, default: 0] += 1
        guard watchers[machine.id] == 1 else { return }
        let id = machine.id
        waking[id] = Task { [weak self, weak shop] in
            while !Task.isCancelled {
                guard let self, let shop,
                      let current = shop.machines.first(where: { $0.id == id }),
                      let step = await U1Camera.keepAwake(current, shop: shop) else { break }
                if step.outcome == .ok { self.askSoon(id) }
                try? await Task.sleep(for: step.renew)
            }
            // Stopped by itself (not a camera that needs keeping, or the
            // machine went): forget this machine, so a tile that appears later
            // starts afresh instead of finding a count with no renewal behind it.
            if !Task.isCancelled { self?.stoppedWaking(id) }
        }
    }

    /// The renewal ended on its own: no count is left without a task.
    func stoppedWaking(_ id: String) {
        watchers[id] = nil
        waking[id] = nil
    }

    /// The tile went away. The last one stops the renewals — and sends no
    /// stop: the printer lets the monitor lapse by itself, and someone else
    /// may still be watching.
    func unwatch(_ id: String) {
        guard let n = watchers[id] else { return }
        if n > 1 { watchers[id] = n - 1; return }
        watchers[id] = nil
        waking[id]?.cancel()
        waking[id] = nil
    }

    /// Read the light for a sheet or card that is showing it.
    func readLight(_ machine: Machine, shop: Shop) async {
        if case .switching = lights[machine.id] { return }
        let state = await U1Camera.readLight(machine, shop: shop)
        lights[machine.id] = state.map { $0 ? .on : .off }
    }

    /// Switch it. Gated like every other printer control (`orders`/`edit`,
    /// see `Shop.control`), and never while a switch is already on its way.
    func setLight(_ machine: Machine, on: Bool, shop: Shop) async {
        guard shop.permittedPrinter("control") else { return }
        if case .switching = lights[machine.id] { return }
        let was: Bool
        switch lights[machine.id] {
        case .on?: was = true
        case .off?: was = false
        case .failed(let w)?: was = w
        default: return     // nothing known: no switch is drawn
        }
        lights[machine.id] = .switching(to: on)
        let now = await U1Camera.setLight(machine, on: on, shop: shop)
        if now == on { lights[machine.id] = on ? .on : .off }
        else { lights[machine.id] = .failed(was: now ?? was) }
    }
}
