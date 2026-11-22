import Foundation
import KhaytCore

/// A paired phone pausing, resuming or stopping a print.
///
/// The phone already shows the printer's camera and whether it is paused
/// (`/api/machines/live`), and could do nothing about what it saw. This is the
/// card's own path, `PrinterControl.send`, reached from `LanServer`'s
/// `POST /api/printer/{machineId}/{pause|resume|stop}`, so the phone sends the
/// printer exactly what the Mac's button would: the same command table
/// (`lib/printer-commands.js`), the same host allowlist, the same MQTT
/// session for a Bambu.
///
/// The route takes a SIGNED, enrolled phone only (`LanServer`): this moves a
/// machine. The Mac's staff lock is about the person at THIS Mac and is not
/// asked; the phone is the owner's, enrolled with the owner PIN.
extension Shop {
    /// The phone's answer: an HTTP status and a JSON body,
    /// `{"ok":true,"state":…}` or `{"ok":false,"reason":…,"message":…}`.
    func phonePrinterCommand(_ machineId: String, _ verb: PrinterVerb) async -> (Int, String) {
        // lock: system — a paired phone's printer command; the LAN route takes a signed enrolled device only, and the cloud relay a sealed command from a write-role member holding the shop key.
        func refuse(_ status: Int, _ reason: String, _ message: String? = nil) -> (Int, String) {
            var body: [String: JSONValue] = ["ok": .bool(false), "reason": .string(reason)]
            if let message { body["message"] = .string(message) }
            return (status, Self.json(body))
        }
        guard let engine else { return refuse(503, "busy") }
        guard let machine = machinesInUse.first(where: { $0.id == machineId }) else {
            return refuse(404, "not-found")
        }
        if let why = PrinterWatch.notWatched(machine) {
            return refuse(409, why == .noConnection ? "not-connected" : "not-watched")
        }
        let type = machine.printerApi?.type ?? ""
        await learnPrinterVerbs(type)
        guard PrinterControl.offers(verb, printerVerbs[type]) else {
            return refuse(409, "unsupported")
        }
        printerBusy.insert(machine.id)
        defer { printerBusy.remove(machine.id) }
        do {
            try await PrinterControl.send(verb, to: machine, engine: engine, build: source.build)
        } catch PrinterControl.Failure.noJob {
            return refuse(409, "no-job")
        } catch PrinterControl.Failure.unsupported(let why) {
            return refuse(409, "unsupported", why)
        } catch {
            let said = PrinterWatch.problem(error, words)
            printerProblem[machine.id] = said
            return refuse(502, "refused", said)
        }
        printerProblem[machine.id] = nil
        // Asked straight away, as the card does, so the phone's answer carries
        // what the printer says now rather than what it said before.
        await printers.refresh(machine, shop: self)
        let state = printers.readings[machine.id]?.status?.state
        return (200, Self.json(["ok": .bool(true), "state": state.map(JSONValue.string) ?? .null]))
    }

    private static func json(_ object: [String: JSONValue]) -> String {
        (try? String(decoding: JSONEncoder().encode(JSONValue.object(object)), as: UTF8.self))
            ?? #"{"ok":false,"reason":"encode"}"#
    }
}

extension LanServer {
    /// `/api/printer/{machineId}/{verb}` → the machine and the verb. `stop` is
    /// the phone's word for `cancel`, which is also accepted. Nil for any other
    /// shape, so the route falls through to 404.
    nonisolated static func printerPath(_ path: String) -> (id: String, verb: PrinterVerb)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].isEmpty, parts[1] == "api", parts[2] == "printer",
              let id = String(parts[3]).removingPercentEncoding, !id.isEmpty else { return nil }
        switch parts[4] {
        case "pause": return (id, .pause)
        case "resume": return (id, .resume)
        case "stop", "cancel": return (id, .cancel)
        default: return nil
        }
    }
}
