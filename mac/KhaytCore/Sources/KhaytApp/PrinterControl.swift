import Foundation
import KhaytCore

/// Telling a printer what to do.
///
/// The Mac app could watch seven protocols and touch none of them. It knew a
/// print was failing, it knew which machine, and pausing it meant walking to
/// the printer or opening the other app — which is the wrong way round for the
/// app a shop is meant to run on.
///
/// ── THE SHAPES ARE NOT DECIDED HERE ───────────────────────────────────────
///
/// `lib/printer-commands.js` says which verb, which path and which body each
/// protocol wants, and it carries corrections that were each found on a real
/// machine: OctoPrint TOGGLES when the action is omitted, so "pause" and
/// "resume" become the same button; PrusaLink keys its endpoints by the running
/// job's id and 404s on a stale one; Duet changes shape between its two
/// firmware lines. A second copy of that in Swift would be a second answer
/// about what to send a printer that is mid-job.
///
/// What IS here: the socket, and the guards around it.
/// What a shop asked a printer to do.
enum PrinterVerb: String, CaseIterable, Sendable {
    case pause, resume, cancel

    /// Everything except pausing changes what the machine is doing in a way
    /// a person cannot take back by pressing the other button.
    var isDestructive: Bool { self == .cancel }
}

@MainActor
enum PrinterControl {

    /// What a shop asked for. Declared at the top level as `PrinterVerb` so
    /// state can hold a set of them without naming this enum.
    typealias Verb = PrinterVerb

    /// Which verbs this protocol can take at all, from `lib/printer-commands.js`.
    ///
    /// Asked of the shared module rather than listed here: the module is what
    /// `send` builds requests from, so a list in Swift would be a second answer
    /// that drifts the first time a protocol learns a verb. A bridge failure is
    /// "none", which hides the buttons — the safe direction for a command.
    static func verbs(for type: String, engine: KhaytEngine) async -> Set<Verb> {
        var out: Set<Verb> = []
        for verb in Verb.allCases where (try? await engine.printerSupports(type: type, command: verb.rawValue)) == true {
            out.insert(verb)
        }
        return out
    }

    /// May the card draw this verb? Only when it is known AND the protocol
    /// has it. `known` nil means "not asked yet", and that draws nothing too:
    /// a button that appears and then vanishes is worse than one that appears
    /// a moment late.
    static func offers(_ verb: Verb, _ known: Set<Verb>?) -> Bool {
        known?.contains(verb) == true
    }

    enum Failure: Error, CustomStringConvertible {
        case unsupported(String)
        case noJob
        case refused(String)

        var description: String {
            switch self {
            case .unsupported(let why): return why
            case .noJob: return "No job is running on this printer."
            case .refused(let why): return why
            }
        }
    }

    /// Send one command.
    ///
    /// Goes through `PrinterWatch.baseURL`, so the shared host allowlist and
    /// the port check apply exactly as they do to polling — this reaches a LAN
    /// device on the shop's behalf and must not be steerable off the address
    /// that was checked, any more than the poller is.
    static func send(_ verb: Verb, to machine: Machine, engine: KhaytEngine,
                     build: StoreReader.Build?,
                     fetch: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws {
        let type = machine.printerApi?.type ?? ""
        let base = try await PrinterWatch.baseURL(machine, engine: engine)

        // NOT HTTP (S11). Same host guard (`baseURL`, above), same confirm
        // flow in the UI — only the wire differs.
        if type == "bambu" { return try await sendBambu(verb, to: machine, base: base, engine: engine, build: build) }
        if type == "sdcp" { return try await sendSdcp(verb, to: machine, base: base, engine: engine) }

        let key = await self.key(for: machine, build: build)

        // PrusaLink first: its endpoints are keyed by the running job's id, and
        // a cached one is a 404. Read now rather than trusted from a screen.
        var jobId: String?
        if try await engine.printerCommandNeedsJobId(type: type) {
            let reply = try await PrinterWatch.get(base, path: "/api/v1/job",
                                                   key: key, type: type)
            // `Int(someDouble)` traps on an infinity or a NaN, and JSON will
            // happily carry 1e30 — so a printer, or anything else answering on
            // that port, could crash the app by reporting a silly job id.
            guard case .number(let id)? = reply["id"],
                  let whole = Int(exactly: id.rounded(.towardZero)) else { throw Failure.noJob }
            jobId = String(whole)
        }

        let request = try await engine.printerCommand(
            type: type, command: verb.rawValue, jobId: jobId,
            // Which Duet firmware answered last. The poller learns it and
            // remembers it; asking again here would cost a request to find out
            // something this process already knows.
            duetFlavour: PrinterWatch.knownDuetFlavour(for: base),
            printerSlug: machine.printerApi?.printerSlug ?? "")
        try await perform(request, base: base, key: key, type: type, engine: engine, fetch: fetch)
    }

    /// A Bambu: `print.pause` / `print.resume` / `print.stop` over the
    /// machine's held MQTT connection (`BambuSession`), the one the poller
    /// already keeps open — so a command is not a second client dialling in.
    ///
    /// Developer Mode is what Khayt needs to read a Bambu at all, and Bambu's
    /// wiki says it opens the MQTT channel for "full control". So the command
    /// is sent, and only the printer's own `result: "fail"` is reported as a
    /// refusal (`BambuMqtt.Trouble.commandRefused`), in its words.
    private static func sendBambu(_ verb: Verb, to machine: Machine, base: URL,
                                  engine: KhaytEngine, build: StoreReader.Build?) async throws {
        // The access code, opened at the moment of use exactly as the poller
        // opens it — never displayed, never held by this file.
        var code = ""
        if let sealed = machine.printerApi?.accessCode, !sealed.isEmpty, let build {
            code = (try? await Secrets.open(sealed, for: build)) ?? ""
        }
        let config = try PrinterWatch.bambuConfig(machine, base: base, accessCode: code)
        let session = await BambuWatch.shared.session(for: machine.id, config: config, accessCode: code)
        let seq = await session.nextSequence()
        let request = try await engine.printerCommand(type: "bambu", command: verb.rawValue,
                                                      sequenceId: seq)
        if let why = request.unsupported { throw Failure.unsupported(why) }
        guard let mqtt = request.mqtt else { throw Failure.refused("The printer's command could not be built.") }
        try await session.command(payload: mqtt.payload, command: mqtt.command,
                                  sequenceId: mqtt.sequenceId)
    }

    /// A Bambu control beyond the job verbs. Speed needs LAN/Developer Mode
    /// like every MQTT command; the light is harmless and goes straight
    /// through from the UI. Speed is confirmed there while printing.
    enum Control: Equatable, Sendable {
        case speed(Int)          // 1 silent · 2 standard · 3 sport · 4 ludicrous
        case light(Bool)
    }

    static func control(_ control: Control, to machine: Machine, engine: KhaytEngine,
                        build: StoreReader.Build?) async throws {
        guard machine.printerApi?.type == "bambu" else {
            throw Failure.unsupported("This printer type has no such control.")
        }
        let base = try await PrinterWatch.baseURL(machine, engine: engine)
        var code = ""
        if let sealed = machine.printerApi?.accessCode, !sealed.isEmpty, let build {
            code = (try? await Secrets.open(sealed, for: build)) ?? ""
        }
        let config = try PrinterWatch.bambuConfig(machine, base: base, accessCode: code)
        let session = await BambuWatch.shared.session(for: machine.id, config: config, accessCode: code)
        let seq = await session.nextSequence()
        let request: KhaytEngine.PrinterRequest
        switch control {
        case .speed(let level):
            request = try await engine.printerControl(type: "bambu", control: "speed",
                                                      value: .number(Double(level)), sequenceId: seq)
        case .light(let on):
            request = try await engine.printerControl(type: "bambu", control: "light",
                                                      value: .string(on ? "on" : "off"), sequenceId: seq)
        }
        if let why = request.unsupported { throw Failure.unsupported(why) }
        guard let mqtt = request.mqtt else { throw Failure.refused("The printer's command could not be built.") }
        try await session.command(payload: mqtt.payload, command: mqtt.command,
                                  sequenceId: mqtt.sequenceId, section: mqtt.section ?? "print")
    }

    /// An Elegoo resin printer: one SDCP frame, Cmd 129 / 131 / 130, and its Ack.
    private static func sendSdcp(_ verb: Verb, to machine: Machine, base: URL,
                                 engine: KhaytEngine) async throws {
        let board = (machine.printerApi?.serial ?? machine.printerApi?.printerSlug ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !board.isEmpty else { throw PrinterWatch.Refusal.needsMainboardId }
        guard let host = base.host(),
              let url = URL(string: try await engine.sdcpWebsocketUrl(host)) else {
            throw PrinterWatch.Refusal.noHost
        }
        // Unique per command, so this command's Ack is told from any other's.
        let requestId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let request = try await engine.printerCommand(
            type: "sdcp", command: verb.rawValue, mainboardId: board, requestId: requestId,
            timestamp: Int(Date().timeIntervalSince1970))
        if let why = request.unsupported { throw Failure.unsupported(why) }
        guard let frame = request.sdcp else { throw Failure.refused("The printer's command could not be built.") }
        try await SdcpSocket(url: url, mainboardId: board)
            .command(frame: frame.frame, cmd: frame.cmd, requestId: frame.requestId, engine: engine)
    }

    /// What is on a Klipper plate right now.
    static func plate(of machine: Machine, engine: KhaytEngine,
                      build: StoreReader.Build?) async throws -> KhaytEngine.Plate {
        let base = try await PrinterWatch.baseURL(machine, engine: engine)
        let reply = try await PrinterWatch.get(
            base, path: "/printer/objects/query?exclude_object",
            key: await key(for: machine, build: build), type: machine.printerApi?.type ?? "")
        return try await engine.plate(reply)
    }

    /// Drop one object from a running print.
    ///
    /// THE PLATE IS RE-READ HERE, not passed in. A list a screen is holding is
    /// a list from some seconds ago and the object it names may have finished —
    /// and more importantly, checking the name against a plate read in THIS
    /// call is the only reason that name is safe to put inside a G-code script.
    /// See `lib/exclude-object.js`.
    static func drop(_ object: String, on machine: Machine, engine: KhaytEngine,
                     build: StoreReader.Build?) async throws {
        let type = machine.printerApi?.type ?? ""
        let base = try await PrinterWatch.baseURL(machine, engine: engine)
        let key = await self.key(for: machine, build: build)
        let reply = try await PrinterWatch.get(
            base, path: "/printer/objects/query?exclude_object", key: key, type: type)
        let request = try await engine.excludeObject(object, plate: reply)
        try await perform(request, base: base, key: key, type: type)
    }

    /// The API key, opened at the moment it is sent and never held.
    ///
    /// The same rule the poller follows: an unset key is sent as NOTHING rather
    /// than as the string "undefined", and Moonraker in trusted-client mode
    /// needs none at all.
    static func key(for machine: Machine, build: StoreReader.Build?) async -> String {
        guard let sealed = machine.printerApi?.apiKey, !sealed.isEmpty, let build else { return "" }
        return (try? await Secrets.open(sealed, for: build)) ?? ""
    }

    private static func perform(_ request: KhaytEngine.PrinterRequest, base: URL,
                                key: String, type: String, engine: KhaytEngine? = nil,
                                fetch: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws {
        // A protocol that cannot do this says so, and that sentence goes to the
        // shop unchanged: "Pausing a Repetier print is not supported yet" is
        // something to act on, unlike a request that fails obscurely.
        if let why = request.unsupported { throw Failure.unsupported(why) }
        // MORE THAN ONE CALL: in order, and the first refusal stops it. A Duet
        // cancel is a pause and then a stop; stopping without the pause having
        // landed is not the command the shop pressed.
        if let steps = request.sequence {
            guard !steps.isEmpty else { throw Failure.refused("The printer's command could not be built.") }
            for step in steps {
                try await perform(step, base: base, key: key, type: type, engine: engine, fetch: fetch)
            }
            return
        }
        guard let method = request.method, let path = request.path else {
            throw Failure.refused("The printer's command could not be built.")
        }
        do {
            _ = try await PrinterWatch.send(base, path: path, method: method, body: request.body,
                                            contentType: request.contentType, key: key, type: type,
                                            fetch: fetch)
        } catch PrinterWatch.Refusal.http(let code, _) where type == "duet" && (code == 401 || code == 403) {
            // A DUET WITH A PASSWORD refuses every command without a session —
            // 401 standalone, 403 on an SBC — and the poller's session key was
            // its own, so the Mac could watch such a printer and never pause
            // it. Shake hands the way the poller does, then send once more.
            guard let engine else { throw PrinterWatch.Refusal.http(code, "") }
            let headers = try await duetSession(base: base, key: key, engine: engine, fetch: fetch)
            _ = try await PrinterWatch.send(base, path: path, method: method, body: request.body,
                                            contentType: request.contentType, key: key, type: type,
                                            headers: headers, fetch: fetch)
        }
    }

    /// The session header a Duet hands out on connect, for the firmware the
    /// poller last heard answer here (standalone when it has heard nothing).
    private static func duetSession(base: URL, key: String, engine: KhaytEngine,
                                    fetch: ((URLRequest) async throws -> (Data, URLResponse))?) async throws
        -> [String: String] {
        let known = await PrinterWatch.knownDuetFlavour(for: base)
        let flavour = known.isEmpty ? "standalone" : known
        let ep = try await engine.duetEndpoints(flavour: flavour, password: key)
        let raw = try await PrinterWatch.get(base, path: ep.connect, key: key, type: "duet", fetch: fetch)
        let answer = try await engine.duetConnect(flavour: flavour, raw: raw)
        guard answer.ok else { throw Failure.refused("The Duet refused the password: \(answer.error ?? "no reason given")") }
        return answer.sessionKey.map { ["X-Session-Key": $0] } ?? [:]
    }
}
