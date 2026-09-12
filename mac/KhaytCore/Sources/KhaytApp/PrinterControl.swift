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
enum PrinterControl {

    /// What a shop asked for.
    enum Verb: String, CaseIterable, Sendable {
        case pause, resume, cancel

        /// Everything except pausing changes what the machine is doing in a way
        /// a person cannot take back by pressing the other button.
        var isDestructive: Bool { self == .cancel }
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
                     build: StoreReader.Build?) async throws {
        let type = machine.printerApi?.type ?? ""
        let base = try await PrinterWatch.baseURL(machine, engine: engine)
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
        try await perform(request, base: base, key: key, type: type)
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
    private static func key(for machine: Machine, build: StoreReader.Build?) async -> String {
        guard let sealed = machine.printerApi?.apiKey, !sealed.isEmpty, let build else { return "" }
        return (try? await Secrets.open(sealed, for: build)) ?? ""
    }

    private static func perform(_ request: KhaytEngine.PrinterRequest, base: URL,
                                key: String, type: String) async throws {
        // A protocol that cannot do this says so, and that sentence goes to the
        // shop unchanged: "Bambu requires Bambu Connect for remote job control"
        // is something to act on, unlike a request that fails obscurely.
        if let why = request.unsupported { throw Failure.unsupported(why) }
        guard let method = request.method, let path = request.path else {
            throw Failure.refused("The printer's command could not be built.")
        }
        _ = try await PrinterWatch.send(base, path: path, method: method,
                                        body: request.body,
                                        contentType: request.contentType,
                                        key: key, type: type)
    }
}
