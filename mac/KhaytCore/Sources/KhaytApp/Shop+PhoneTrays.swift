import Foundation
import KhaytCore

/// A paired phone reading the spool tags on a printer's heads and saying
/// which of the shop's spools is in one (iPhone frame 7a; the Windows/Linux
/// app's "Which spool is in head N", `renderer/machines.js openHeadLink`).
///
///     GET  /api/printer/{machineId}/trays
///     POST /api/printer/{machineId}/trays/{head}/spool
///
/// Only the Mac holds the printer, so the phone asks and the Mac reads: one
/// GET of `filament_detect`, the same read-only call `HeadActuals` makes
/// after a print. NOTHING IS SENT TO THE PRINTER BUT THAT GET. No G-code, no
/// motion, no setting.
///
/// WHAT THE POST WRITES, and nothing else:
///   - `machines[].headSpools[head]` = the spool's id: the record the other
///     app writes, keyed from zero as it keys it, so the two agree.
///   - with `"create": true`, one new spool, filled in from the tag by the
///     shared rule (`spoolMatch`'s prefill, `lib/spool-edit.js newSpool`),
///     with no price: its price is the shop's to set.
/// AN EXISTING SPOOL IS NEVER CHANGED. Not its weight, not its colour, not
/// its name: linking is a note on the machine.
///
/// WHO MAY. The route takes a SIGNED, enrolled phone, and its ROLE decides
/// (`lib/device-roles.js`): reading needs `inventory:read`, writing
/// `inventory:write`, which an operator holds. That is the Mac's and the
/// other app's own rule for the same two acts: adding a spool is
/// inventory/create and linking is printers/edit, both of which an operator
/// has (`lib/rbac.js`) and a viewer has not.
extension Shop {

    /// What a read of the printer came to.
    enum TrayRead {
        /// One row per head (`KhaytEngine.phoneTrays`).
        case trays([JSONValue])
        /// This printer has no tags to read: not a Moonraker printer, not
        /// connected, or one whose firmware has no `filament_detect`.
        case none
        /// It was asked and did not answer.
        case unreachable(String)
    }

    /// The book the routes read: the raw `machines` and `inventory` records.
    private var trayBook: [String: JSONValue] { trayBookForTests ?? lanRestBook }

    private func trayMachine(_ id: String) -> (raw: [String: JSONValue], machine: Machine)? {
        for row in Self.rows(trayBook, "machines") {
            guard case .object(let o) = row, Self.recordId(row) == id,
                  let data = try? JSONEncoder().encode(row),
                  let machine = try? JSONDecoder().decode(Machine.self, from: data) else { continue }
            return (o, machine)
        }
        return nil
    }

    /// Ask the printer what its heads read, and match each against the shelf.
    func readTrays(_ found: (raw: [String: JSONValue], machine: Machine), engine: KhaytEngine) async -> TrayRead {
        // lock: callers — phoneTrays, phoneLinkTray
        let machine = found.machine
        guard !machine.isRetired, machine.printerApi?.type == "moonraker", PrinterWatch.notWatched(machine) == nil else { return .none }
        let answer: [String: JSONValue]
        do {
            let base: URL
            if let stand = trayBaseForTests { base = stand } else { base = try await PrinterWatch.baseURL(machine, engine: engine) }
            var key = machine.printerApi?.apiKey ?? ""
            if let build = source.build { key = (try? await Secrets.open(key, for: build)) ?? "" }
            answer = try await PrinterWatch.get(base, path: "/printer/objects/query?filament_detect", key: key,
                                                type: "moonraker", timeout: 10, fetch: trayFetchForTests)
        } catch {
            return .unreachable(PrinterWatch.problem(error, words))
        }
        guard let detect = HeadActuals.filamentDetect(in: answer) else { return .none }
        guard let rows = try? await engine.phoneTrays(filamentDetect: detect, spools: Self.rows(trayBook, "inventory"),
                                                      linked: found.raw["headSpools"] ?? .null), !rows.isEmpty else { return .none }
        return .trays(rows)
    }

    /// `GET /api/printer/{machineId}/trays`.
    /// `{"ok":true,"trays":[…]}`, or `{"ok":true}` with no `trays` for a
    /// printer that has none to read (the phone then shows nothing).
    func phoneTrays(_ machineId: String) async -> (Int, String) {
        // lock: system — a paired phone reading a printer's spool tags; the LAN route takes a signed enrolled device whose role allows inventory:read, and nothing is written.
        guard let engine else { return Self.trayAnswer(503, ["ok": .bool(false), "reason": .string("busy")]) }
        guard let found = trayMachine(machineId) else { return Self.trayAnswer(404, ["ok": .bool(false), "reason": .string("not-found")]) }
        switch await readTrays(found, engine: engine) {
        case .trays(let rows): return Self.trayAnswer(200, ["ok": .bool(true), "trays": .array(rows)])
        case .none: return Self.trayAnswer(200, ["ok": .bool(true)])
        case .unreachable(let said):
            return Self.trayAnswer(502, ["ok": .bool(false), "reason": .string("printer-unreachable"), "message": .string(said)])
        }
    }

    /// What the phone asked for, read strictly: exactly one of a spool to
    /// link or "add it from the tag", and the tag it was showing.
    enum TrayChoice: Equatable { case link(String), create }

    nonisolated static func trayRequest(_ body: Data) -> (choice: TrayChoice, seen: String)? {
        guard body.count <= 4096, case .object(let asked)? = try? JSONDecoder().decode(JSONValue.self, from: body),
              case .string(let seen)? = asked["seen"], !seen.isEmpty, seen.count <= 2000 else { return nil }
        let allowed: Set<String> = ["seen", "spoolId", "create"]
        guard asked.keys.allSatisfy(allowed.contains) else { return nil }
        switch (asked["spoolId"], asked["create"]) {
        case (.string(let id)?, nil) where !id.isEmpty && id.count <= 128: return (.link(id), seen)
        case (nil, .bool(true)?): return (.create, seen)
        default: return nil
        }
    }

    /// `POST /api/printer/{machineId}/trays/{head}/spool`, with
    /// `{"seen": key, "spoolId": "…"}` or `{"seen": key, "create": true}`.
    /// `head` counts from one, as the answer to the GET does.
    func phoneLinkTray(_ machineId: String, head: Int, body: Data) async -> (Int, String) {
        // lock: system — a paired phone saying which spool is in a head; the LAN route takes a signed enrolled device whose role allows inventory:write (an operator up: the Mac's own inventory/create and printers/edit), and no existing spool is changed.
        func refuse(_ status: Int, _ reason: String, _ more: [String: JSONValue] = [:]) -> (Int, String) {
            Self.trayAnswer(status, ["ok": .bool(false), "reason": .string(reason)].merging(more) { a, _ in a })
        }
        guard let asked = Self.trayRequest(body) else { return refuse(400, "bad-body") }
        guard let engine else { return refuse(503, "busy") }
        guard let found = trayMachine(machineId) else { return refuse(404, "not-found") }
        // The sample book has nowhere to write.
        guard source.build != nil || trayBookForTests != nil else { return refuse(409, "read-only") }

        // What the head reads NOW, not what the phone read a minute ago.
        let rows: [JSONValue]
        switch await readTrays(found, engine: engine) {
        case .trays(let now): rows = now
        case .none: return refuse(409, "no-trays")
        case .unreachable(let said): return refuse(502, "printer-unreachable", ["message": .string(said)])
        }
        guard let row = rows.compactMap({ row -> [String: JSONValue]? in
            if case .object(let o) = row, case .number(let n)? = o["head"], Int(n) == head { return o }; return nil
        }).first else { return refuse(404, "no-head") }
        // The spool was taken out, or swapped, since the phone looked: it is
        // shown what is there now and asks again. Nothing is linked blind.
        guard case .string(let key)? = row["key"], !key.isEmpty, key == asked.seen else {
            return refuse(409, "changed", ["trays": .array(rows)])
        }
        var prefill: [String: JSONValue] = [:]
        if case .object(let p)? = row["prefill"] { prefill = p }

        let outcome: TrayLinked
        do {
            if var book = trayBookForTests {
                outcome = try await Self.linkTray(into: &book, machineId: machineId, head: head, choice: asked.choice, prefill: prefill,
                                                  engine: engine, newId: Self.uid("INV"), today: Self.today())
                trayBookForTests = book
            } else if let build = source.build {
                var done: TrayLinked?
                try await StoreWriter.update(
                    storeURL: build.storeURL,
                    owns: { StoreLock.weOwnIt(build) },
                    whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
                ) { root in
                    // The book moved and this runs again: one spool, not two.
                    done = try await Self.linkTray(into: &root, machineId: machineId, head: head, choice: asked.choice, prefill: prefill,
                                                   engine: engine, newId: Self.uid("INV"), today: Self.today())
                }
                guard let done else { return refuse(500, "not-saved") }
                outcome = done
                await load(source)
            } else { return refuse(409, "read-only") }
        } catch let refused as TrayRefused {
            return refuse(refused.status, refused.reason)
        } catch {
            return refuse(500, "not-saved", ["message": .string(said(error))])
        }
        return Self.trayAnswer(outcome.created ? 201 : 200, [
            "ok": .bool(true), "head": .number(Double(head)), "spoolId": .string(outcome.spoolId),
            "created": .bool(outcome.created), "spool": .object(outcome.spool),
        ])
    }

    struct TrayLinked { let spoolId: String; let created: Bool; let spool: [String: JSONValue] }
    struct TrayRefused: Error { let status: Int; let reason: String }

    /// The write itself, on a book: the machine's `headSpools`, and one new
    /// spool when asked. Throws `TrayRefused` and changes nothing when the
    /// machine or the spool is not in THIS book (another computer removed it).
    static func linkTray(into root: inout [String: JSONValue], machineId: String, head: Int, choice: TrayChoice,
                                     prefill: [String: JSONValue], engine: KhaytEngine, newId: String, today: String) async throws -> TrayLinked {
        var machines = rows(root, "machines")
        guard (1...16).contains(head), let at = machines.firstIndex(where: { recordId($0) == machineId }),
              case .object(var machine) = machines[at] else { throw TrayRefused(status: 404, reason: "not-found") }
        var work = root
        let spoolId: String
        let created: Bool
        switch choice {
        case .link(let id):
            guard rows(work, "inventory").contains(where: {
                if case .object(let s) = $0, recordId($0) == id, s["deleted"] != .bool(true) { return true }; return false
            }) else { throw TrayRefused(status: 404, reason: "no-spool") }
            spoolId = id
            created = false
        case .create:
            // As the other app adds it: the tag's material, weight and colour,
            // no price. A tag with no material is not a spool.
            var input: [String: JSONValue] = ["cost": .string(""), "materialType": .string("fdm")]
            input["material"] = prefill["material"] ?? .string("")
            if case .number(let w)? = prefill["weight"], w > 0 { input["weight"] = .number(w) } else { input["weight"] = .string("") }
            if case .string(let c)? = prefill["color"] { input["color"] = .string(c) } else { input["color"] = .string("") }
            guard try await writeNewSpool(into: &work, input: input, engine: engine, newId: newId, today: today) else {
                throw TrayRefused(status: 409, reason: "tag-unusable")
            }
            var shelf = rows(work, "inventory")
            if case .string(let brand)? = prefill["brand"], !brand.isEmpty,
               let i = shelf.lastIndex(where: { recordId($0) == newId }), case .object(var made) = shelf[i] {
                made["brand"] = .string(brand)
                shelf[i] = .object(made)
                work["inventory"] = .array(shelf)
            }
            spoolId = newId
            created = true
        }
        var held: [String: JSONValue] = [:]
        if case .object(let h)? = machine["headSpools"] { held = h }
        held[String(head - 1)] = .string(spoolId)
        machine["headSpools"] = .object(held)
        StoreWriter.stamp(&machine)
        machines[at] = .object(machine)
        work["machines"] = .array(machines)
        root = work
        var spool: [String: JSONValue] = ["id": .string(spoolId)]
        if case .object(let s)? = rows(root, "inventory").last(where: { recordId($0) == spoolId }) {
            for k in ["material", "color", "brand", "weight", "colourVariant"] { if let v = s[k] { spool[k] = v } }
        }
        return TrayLinked(spoolId: spoolId, created: created, spool: spool)
    }

    nonisolated private static func trayAnswer(_ status: Int, _ object: [String: JSONValue]) -> (Int, String) {
        (status, (try? String(decoding: JSONEncoder().encode(JSONValue.object(object)), as: UTF8.self)) ?? #"{"ok":false,"reason":"encode"}"#)
    }
}

extension LanServer {
    /// `/api/printer/{machineId}/trays` → the machine, head nil;
    /// `/api/printer/{machineId}/trays/{head}/spool` → the machine and the
    /// head (1 to 16, digits only). Nil for any other shape.
    nonisolated static func trayPath(_ path: String) -> (id: String, head: Int?)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5 || parts.count == 7, parts[0].isEmpty, parts[1] == "api", parts[2] == "printer", parts[4] == "trays",
              let id = String(parts[3]).removingPercentEncoding, !id.isEmpty else { return nil }
        if parts.count == 5 { return (id, nil) }
        guard parts[6] == "spool", parts[5].count <= 2, parts[5].allSatisfy({ $0.isASCII && $0.isNumber }),
              let head = Int(parts[5]), (1...16).contains(head) else { return nil }
        return (id, head)
    }
}
