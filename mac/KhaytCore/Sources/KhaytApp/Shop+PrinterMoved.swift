import Foundation
import KhaytCore

/// A printer that answers at a new address, found and offered by itself.
///
/// ── WHY THIS RUNS WITHOUT A BUTTON ────────────────────────────────────────
///
/// "Find it on the network" (Shop+Printers.swift) repairs a machine whose
/// DHCP lease moved it, but only when somebody presses it, and the shop that
/// needs it is the one that does not know its printer moved: the card just
/// says "not answering", the same as a printer switched off. The shop's own
/// Snapmaker U1, "Baby U1", went that way in Nov 2026.
///
/// So the poller starts it: after a round, when a machine has been quiet for
/// three polls and the last search was more than ten minutes ago
/// (`lib/printer-relocate.js shouldScan`).
///
/// ── IDENTITY BEFORE ANY KEY ────────────────────────────────────────────────
///
/// The risk in this feature is not a wrong badge. It is sending a printer's
/// API key to a different device. So:
///
///   1. While a printer ANSWERS at its address, Khayt asks it who it is, once,
///      and writes that down: its product serial and network card
///      (`lib/printer-sweep.js readIdentity`). Never the hostname: two U1s on
///      the shop's LAN both call themselves "lava".
///   2. When it goes quiet, every candidate on the network is asked the same
///      question WITHOUT credentials (`PrinterSweep.request` carries none).
///   3. Only a candidate that reports the recorded serial or network card is
///      offered, and only as a question on the machine's card. Nothing is
///      switched by itself. A resemblance (same model, same protocol) is
///      never offered here.
///   4. "Point Khayt at it" writes the new host through the relocation rule;
///      the sealed key is not touched. "Not now" is remembered for that
///      address until the printer turns up somewhere else.
extension Shop {

    /// Learn who the answering printers are, and look for the quiet ones.
    /// Started by the poller after a round; never waited for.
    func watchForMovedPrinters() {
        // Only a real book. The sample book is every test's book, and a test
        // has no business asking a network anything.
        guard source.build != nil, engine != nil, !movedSearching else { return }
        movedSearching = true
        Task { @MainActor in
            defer { movedSearching = false }
            await learnPrinterIdentities()
            await searchForMovedPrinters()
        }
    }

    // MARK: - Who each printer is, while it answers

    /// Machines worth asking who they are: answering at their address now,
    /// nothing recorded yet, and not asked already since launch.
    static func needsIdentity(_ machine: Machine, answering: Bool, asked: Set<String>) -> Bool {
        guard answering, !asked.contains(machine.id), machine.inService,
              let api = machine.printerApi, let host = api.host,
              !host.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let serial = (api.serial ?? "").trimmingCharacters(in: .whitespaces)
        let mac = (api.mac ?? "").trimmingCharacters(in: .whitespaces)
        return serial.isEmpty && mac.isEmpty
    }

    func learnPrinterIdentities() async {
        guard let engine, let build = source.build else { return }
        for machine in machinesInUse {
            let answering = printers.heard(machine.id) != nil
            guard Self.needsIdentity(machine, answering: answering, asked: identityAsked) else { continue }
            // Asked once per launch whatever the answer, including "this
            // protocol has no identity question" (Bambu, OctoPrint…): that was
            // a call into the engine for every such printer after every poll
            // (beta.35 pre-release review).
            identityAsked.insert(machine.id)
            guard let api = machine.printerApi, let type = api.type,
                  let path = try? await engine.identityPath(type: type),
                  let rawHost = api.host else { continue }
            let host = rawHost.split(separator: ":").first.map(String.init) ?? rawHost
            guard (try? await engine.printerHostAllowed(host)) == true,
                  let probe = try? await engine.sweepProbes().first(where: { $0.type == type }),
                  let (_, _, status, data) = await PrinterSweep.ask(host, port: api.port ?? probe.port,
                                                                  path: path, type: type),
                  status == 200,
                  let body = try? JSONValue.decode(JSONValue.self, from: data),
                  let id = try? await engine.readSweepIdentity(type: type, body: body), !id.isEmpty
            else { continue }
            let machineId = machine.id
            // lock: system — no person acts: Khayt writes down what the printer
            // at the machine's own address said about itself, so a later move
            // can be recognised. Only where nothing is recorded, and only while
            // the address is still the one that was asked.
            try? await StoreWriter.updateOffMain(build) { root in
                guard case .array(var rows)? = root["machines"] else { return }
                for i in rows.indices {
                    guard case .object(var m) = rows[i], case .string(let mid)? = m["id"], mid == machineId,
                          case .object(var p)? = m["printerApi"], case .string(let h)? = p["host"], h == rawHost
                    else { continue }
                    let has: (String) -> Bool = { key in
                        if case .string(let v)? = p[key] { return !v.trimmingCharacters(in: .whitespaces).isEmpty }
                        return false
                    }
                    guard !has("serial"), !has("mac") else { return }
                    if !id.serial.isEmpty { p["serial"] = .string(id.serial) }
                    if !id.mac.isEmpty { p["mac"] = .string(id.mac) }
                    m["printerApi"] = .object(p)
                    StoreWriter.stamp(&m)
                    rows[i] = .object(m)
                }
                root["machines"] = .array(rows)
            }
        }
    }

    // MARK: - Where the quiet ones went

    /// What may be offered: identity matches only, less what the shop said
    /// "Not now" to.
    static func offerable(_ moves: [KhaytEngine.Relocation], dismissed: Set<String>) -> [KhaytEngine.Relocation] {
        moves.filter { $0.isIdentity && !dismissed.contains($0.id) }
    }

    func searchForMovedPrinters(now: Date = Date()) async {
        guard let engine, source.build != nil else { return }
        guard (try? await engine.shouldSearchForMoved(machines: machineRowsInUse,
                                                      statusCache: printers.statusCache,
                                                      lastScanAt: movedSearchedAt, now: now)) == true
        else { return }
        movedSearchedAt = now
        let quiet = machinesInUse.filter { looksUnreachable($0.id) }.map(\.id)
        let offline = offlineMachineHosts()
        guard !offline.isEmpty else { return }

        // Announced first, then asked for; every candidate asked who it is,
        // without credentials, before anything is matched.
        var discovered: [JSONValue] = []
        for printer in await findPrinters() {
            guard let data = try? JSONEncoder().encode(printer),
                  let value = try? JSONValue.decode(JSONValue.self, from: data),
                  (try? await engine.printerHostAllowed(printer.host)) == true else { continue }
            discovered.append(await PrinterSweep.identified(value, type: printer.connection ?? "",
                                                            host: printer.host, engine: engine))
        }
        discovered += await PrinterSweep.look(from: offline, engine: engine)

        let moves = (try? await engine.planRelocations(machines: machineRowsInUse, discovered: discovered,
                                                       statusCache: printers.statusCache)) ?? []
        let offers = Self.offerable(moves, dismissed: Self.movedNotNow)
        for offer in offers where !relocations.contains(where: { $0.machineId == offer.machineId }) {
            relocations.append(offer)
        }
        movedNotFound = Set(quiet).subtracting(offers.map(\.machineId))
    }

    // MARK: - "Not now"

    static let movedNotNowKey = "mac.movedNotNow"

    /// Moves the shop declined, by `Relocation.id` (machine and address).
    /// Mac-local: a declined question on this Mac is not a decision about the
    /// printer, and the other computer may want to ask it.
    static var movedNotNow: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: movedNotNowKey) ?? [])
    }

    /// Not now: the question goes, and does not come back for this address.
    /// A move to a DIFFERENT address is a new question.
    func declineRelocation(_ move: KhaytEngine.Relocation) {
        var declined = Self.movedNotNow
        declined.insert(move.id)
        UserDefaults.standard.set(Array(declined).sorted(), forKey: Self.movedNotNowKey)
        relocations.removeAll { $0.id == move.id }
    }
}
