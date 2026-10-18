import Foundation
import UniformTypeIdentifiers
import AppKit
import Observation
import KhaytCore

extension Shop {

    // MARK: - Finding a printer

    /// Ask the network what is on it. Owner-initiated, time-boxed, never a timer.
    func findPrinters() async -> [KhaytEngine.FoundPrinter] {
        guard let engine else { return [] }
        return await finder.find(engine: engine)
    }

    // MARK: - A printer that changed address

    /// True when this machine has gone quiet for long enough to be worth asking.
    ///
    /// The same three-strike rule the status badge uses, so the button appears
    /// exactly when the screen already says something is wrong.
    func looksUnreachable(_ machineId: String) -> Bool {
        guard case .object(let entry)? = printers.statusCache[machineId],
              case .string(let err)? = entry["error"], !err.isEmpty,
              case .number(let n)? = entry["consecutiveFailures"] else { return false }
        return n >= 3
    }

    /// Ask the network where the quiet machines went.
    ///
    /// Owner-initiated and time-boxed, like `findPrinters` — never a timer. A
    /// shop whose router reboots should not have Khayt sweeping its LAN on a
    /// schedule for the rest of the day.
    func findMovedPrinters() async {
        relocateProblem = nil
        relocateNote = nil
        guard let engine else { return }
        lookingForMoved = true
        defer { lookingForMoved = false }

        let found = await findPrinters()
        // Back through JSON rather than hand-copied: `planRelocations` reads
        // `serial`, `model`, `firmware` and `port`, and a Swift struct that
        // named only some of them is exactly how the serial went missing in the
        // first place.
        let discovered: [JSONValue] = found.compactMap { printer in
            guard let data = try? JSONEncoder().encode(printer),
                  let value = try? JSONValue.decode(JSONValue.self, from: data)
            else { return nil }
            return value
        }
        relocations = (try? await engine.planRelocations(
            machines: machineRows,
            discovered: discovered,
            statusCache: printers.statusCache)) ?? []

        // ── AND IF NOTHING ANNOUNCED ITSELF, ASK ──────────────────────────
        //
        // mDNS only finds a printer that talks. A Snapmaker U1 advertises
        // neither `_moonraker._tcp` nor `_octoprint._tcp` — browsed on the LAN
        // it was printing on, the answer was nothing at all — so the shop was
        // told "no printers on the network" while the printer sat two
        // addresses away answering every question put to it directly.
        //
        // So when the announcement turns up nothing that matches, the subnets
        // of the machines that are actually offline get asked. Only then: a
        // sweep is the expensive, noisy way to find something mDNS hands over
        // for free, and it is never the first thing tried.
        if relocations.isEmpty {
            let offline = offlineMachineHosts()
            if !offline.isEmpty {
                sweeping = true
                let swept = await PrinterSweep.look(from: offline, engine: engine)
                sweeping = false
                if !swept.isEmpty {
                    relocations = (try? await engine.planRelocations(
                        machines: machineRows,
                        discovered: discovered + swept,
                        statusCache: printers.statusCache)) ?? []
                }
            }
        }

        if relocations.isEmpty {
            relocateNote = words.callIt(found.isEmpty ? "mac.moved_none_on_network"
                                                      : "mac.moved_none_matched")
        }
    }

    /// The last-known addresses of the machines that are not answering.
    ///
    /// Only those: sweeping the subnet of a printer that is replying perfectly
    /// well asks two hundred and fifty questions to learn something already
    /// known. A machine with no address configured has no subnet to sweep.
    func offlineMachineHosts() -> [String] {
        var out: [String] = []
        for row in machineRows {
            guard case .object(let m) = row,
                  case .string(let id)? = m["id"],
                  case .object(let api)? = m["printerApi"],
                  case .string(let host)? = api["host"] else { continue }
            // `looksUnreachable` and not a test written here: it is the same
            // three-strike rule the status badge uses, so this asks about
            // exactly the machines the screen already says are in trouble.
            guard looksUnreachable(id) else { continue }
            let bare = host.split(separator: ":").first.map(String.init) ?? host
            if !bare.isEmpty { out.append(bare) }
        }
        return out
    }

    /// Point a machine at the address the printer is actually on.
    ///
    /// A WRITE, and the write is what the app will later send commands through
    /// — so an identity match (a MAC or a serial, neither of which moves with a
    /// DHCP lease) is applied on one confirmation, and a guess is only ever
    /// offered. `lib/printer-relocate.js` draws that line and this does not
    /// redraw it.
    func applyRelocation(_ move: KhaytEngine.Relocation) async {
        guard permitted("orders", "edit") else { return }
        relocateProblem = nil
        guard let engine, let build = source.build else {
            relocateProblem = words.callIt("mac.move_sample"); return
        }
        guard let row = machineRows.first(where: { row in
            guard case .object(let m) = row, case .string(let id)? = m["id"] else { return false }
            return id == move.machineId
        }) else { relocateProblem = words.callIt("mac.not_found"); return }

        guard let updated = try? await engine.applyRelocation(row, move),
              case .object(let record) = updated else {
            relocateProblem = words.callIt("mac.moved_failed"); return
        }
        do {
            let machineId = move.machineId
            try await StoreWriter.updateOffMain(build) { root in
                guard case .array(var rows)? = root["machines"] else { return }
                for i in rows.indices {
                    guard case .object(let m) = rows[i],
                          case .string(let id)? = m["id"], id == machineId else { continue }
                    var next = record
                    StoreWriter.stamp(&next)
                    rows[i] = .object(next)
                }
                root["machines"] = .array(rows)
            }
            relocations.removeAll { $0.machineId == move.machineId }
            relocateNote = words.callIt("mac.moved_done",
                                        ["name": .string(move.machineName),
                                         "host": .string(move.to)])
            await load(source)
        } catch {
            relocateProblem = String(describing: error)
        }
    }

    /// Write a found printer down as a machine.
    ///
    /// Its name, address and port, and the connection type the shared rule
    /// chose — and the catalog entry when it recognised the model, which is
    /// what fills in the bed, the nozzle and what it costs to run.
    func addFound(_ printer: KhaytEngine.FoundPrinter) async {
        guard permitted("inventory", "create") else { return }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        let id = Self.uid("MCH")
        var added = false
        do {
            var record: [String: JSONValue] = [
                "id": .string(id),
                "name": .string(printer.name),
                "status": .string("idle"),
                "createdAt": .string(Self.localDay()),
                "printerApi": .object([
                    // '' for a printer the finder could not name a protocol
                    // for — not "none", which the machine sheet's picker has
                    // no tag for and which read as linked everywhere else.
                    "type": .string(Self.connectionType(printer.connection)),
                    "host": .string(printer.host),
                    "port": .number(Double(printer.port ?? 0)),
                ]),
            ]
            // What the catalog knows about this model, when it recognised one.
            if let catalogId = printer.catalogId, !catalogId.isEmpty, let engine {
                var settings: [String: JSONValue] = [:]
                if case .object(let held) = settingsValue { settings = held }
                let written = try? await engine.applyPrinterModel(
                    .object(record), catalogId: catalogId, settings: settings)
                if case .object(let filled)? = written?.machine { record = filled }
            }
            let host = printer.host, adding = record
            added = try await StoreWriter.updateOffMain(build) { root -> Bool in
                var fleet = Self.rows(root, "machines")
                // A printer already written down at this address is the same
                // printer. Adding it twice gives a shop two cards that disagree.
                guard !fleet.contains(where: { row in
                    guard case .object(let m) = row,
                          case .object(let api)? = m["printerApi"],
                          case .string(let had)? = api["host"] else { return false }
                    return had == host
                }) else { return false }
                var stamped = adding
                StoreWriter.stamp(&stamped)
                fleet.append(.object(stamped))
                root["machines"] = .array(fleet)
                return true
            }
            if added, Self.linksPrinter(record, over: nil) { Telemetry.feature(.printerLinked, in: self) }
            await load(source)
        } catch {
            moveProblem = String(describing: error)
        }
    }

    // MARK: - Telling a printer what to do

    func tell(_ machine: Machine, _ verb: PrinterControl.Verb) async {
        // A printer is told what to do by somebody running the floor —
        // `orders`/`edit` in lib/rbac.js, which an operator has and a viewer
        // does not (alpha.62 re-check: pause, cancel, send, drop and power
        // asked nothing).
        guard permitted("orders", "edit") else { printerProblem[machine.id] = moveProblem; return }
        guard let engine else { return }
        printerProblem[machine.id] = nil
        printerBusy.insert(machine.id)
        defer { printerBusy.remove(machine.id) }
        do {
            try await PrinterControl.send(verb, to: machine, engine: engine, build: source.build)
            // Ask straight away rather than waiting for the next poll: a button
            // that appears to do nothing for ten seconds gets pressed again.
            await printers.refresh(machine, shop: self)
        } catch {
            printerProblem[machine.id] = PrinterWatch.problem(error, words)
        }
    }

    // MARK: - Sending a file to a printer

    /// The machines a file can be sent to: every one with a printer
    /// connection. A type that cannot be sent to yet is still listed — the
    /// sheet says why rather than hiding the shop's own printer.
    ///
    /// "Has a connection" is `PrinterWatch.notWatched`'s answer, not a
    /// non-empty type: the Electron machine form writes `type: "none"` for a
    /// printer with no link, and that was offered "Send to printer".
    var sendablePrinters: [Machine] {
        machines.filter { PrinterWatch.notWatched($0) != .noConnection }
    }

    /// A connection type as this app stores and shows it: `""` for none.
    ///
    /// Electron's machine form (`renderer/machines.js`) and the old finder
    /// both wrote `"none"`; the machine sheet's picker has a tag for `""`
    /// only, so `"none"` drew a blank picker over an address, a key field and
    /// a Test button for a printer that was not linked at all.
    nonisolated static func connectionType(_ raw: String?) -> String {
        let type = (raw ?? "").trimmingCharacters(in: .whitespaces)
        return type == "none" ? "" : type
    }

    /// The sliced files beside a job's models, newest first. Read off the
    /// disk, like a model's guides: a plate sliced into the model's folder is
    /// offered by being there, with nothing to record.
    func slicedFiles(for job: Order) -> [URL] {
        var out: [URL] = []
        for part in job.parts {
            guard let id = part.printFileId, let file = files.first(where: { $0.id == id }),
                  let dir = directory(for: file) else { continue }
            for url in PrinterSend.slicedFiles(in: dir) where !out.contains(url) { out.append(url) }
        }
        return out
    }

    /// Send a sliced file to a machine, and start it if asked. The key is
    /// opened now and dropped when this returns.
    ///
    /// `jobId` is the job the file is FOR. Once the printer has taken it, the
    /// job records the machine (`recordPrintRun`) — so its hours, wear and
    /// depreciation go to the printer that ran it, with nobody picking it by
    /// hand. A send that failed records nothing.
    func sendToPrinter(_ file: URL, machineId: String, startPrint: Bool, jobId: String? = nil) async {
        guard let engine, let machine = machines.first(where: { $0.id == machineId }) else { return }
        guard permitted("orders", "edit") else { printerProblem[machine.id] = moveProblem; return }
        sendNote = nil
        printerProblem[machine.id] = nil
        printerBusy.insert(machine.id)
        defer { printerBusy.remove(machine.id) }
        do {
            let key = await PrinterControl.key(for: machine, build: source.build)
            let sent = try await PrinterSend.send(file, to: machine, key: key, startPrint: startPrint, engine: engine)
            sendNote = words.callIt(sent.started ? "mac.send_started" : "mac.send_uploaded",
                                    ["name": .string(machine.name)])
            Telemetry.feature(.printSent, in: self)
            if let jobId, !jobId.isEmpty {
                await recordPrintRun(jobId: jobId, machineId: machine.id, started: sent.started,
                                     file: file.lastPathComponent)
            }
            await printers.refresh(machine, shop: self)
        } catch {
            let said = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            printerProblem[machine.id] = said
            sendNote = said
        }
    }

    /// Write onto a job that it went to `machineId` — `lib/print-runs.js`
    /// decides the fields, against the record AS IT IS ON DISK, inside the
    /// write chain: a machine the shop picked since the sheet opened is read,
    /// kept as the plan, and never silently overwritten.
    func recordPrintRun(jobId: String, machineId: String, started: Bool, file: String,
                        now: Date = Date()) async {
        guard let engine, let build = source.build else { return }
        do {
            // lock: callers — sendToPrinter
            try await StoreWriter.updateAsync(build) { root in
                _ = try await Self.applyPrintRun(to: &root, jobId: jobId, machineId: machineId,
                                                 started: started, file: file,
                                                 at: StoreWriter.iso(now), engine: engine)
            }
            await load(source)
        } catch {
            // The print went; the record of it did not. Said, not swallowed:
            // a shop told nothing would trust a P&L that never heard of it.
            moveProblem = String(describing: error)
        }
    }

    /// The same, on a book handed in — pure, for the tests. Returns whether
    /// the job was changed (false: no such job, or one already finished).
    static func applyPrintRun(to root: inout [String: JSONValue], jobId: String, machineId: String,
                              started: Bool, file: String, at: String,
                              engine: KhaytEngine) async throws -> Bool {
        guard case .array(var rows)? = root["printLog"],
              let index = rows.firstIndex(where: { recordId($0) == jobId }),
              case .object(var record) = rows[index],
              let fields = try await engine.printRunFields(order: .object(record), machineId: machineId,
                                                           at: at, started: started, file: file)
        else { return false }
        for (key, value) in fields {
            if value == .null { record.removeValue(forKey: key) } else { record[key] = value }
        }
        rows[index] = .object(record)
        root["printLog"] = .array(rows)
        return true
    }

    /// Where a job was printed, for the inspector — nil for a job this app
    /// never sent anywhere.
    func printedOn(_ jobId: String) async -> KhaytEngine.PrintedOn? {
        guard let engine, let row = orderRows.first(where: { Self.recordId($0) == jobId }) else { return nil }
        return (try? await engine.printedOn(order: row)) ?? nil
    }

    /// What changes when a job's record does, so a view asking `printedOn`
    /// asks again after a send.
    func printRunsStamp(_ jobId: String) -> String {
        guard case .object(let o)? = orderRows.first(where: { Self.recordId($0) == jobId }) else { return jobId }
        let runs: Int = if case .array(let a)? = o["printRuns"] { a.count } else { 0 }
        return "\(jobId)|\(Self.plainString(o["machineId"]) ?? "")|\(Self.plainString(o["plannedMachineId"]) ?? "")|\(runs)"
    }

    /// What is on a machine's plate, for the sheet that offers to drop one.
    func plate(of machine: Machine) async -> KhaytEngine.Plate? {
        // lock: system — a READ: what is on the plate, asked of the printer;
        // dropping an object is `drop`, which asks the lock.
        guard let engine else { return nil }
        do { return try await PrinterControl.plate(of: machine, engine: engine, build: source.build) }
        catch { printerProblem[machine.id] = PrinterWatch.problem(error, words); return nil }
    }

    /// Drop one object from a running print. NOT UNDOABLE — the caller has
    /// already asked; see `lib/exclude-object.js`.
    func drop(_ object: String, on machine: Machine) async {
        guard permitted("orders", "edit") else { printerProblem[machine.id] = moveProblem; return }
        guard let engine else { return }
        printerProblem[machine.id] = nil
        printerBusy.insert(machine.id)
        defer { printerBusy.remove(machine.id) }
        do {
            try await PrinterControl.drop(object, on: machine, engine: engine, build: source.build)
        } catch {
            printerProblem[machine.id] = PrinterWatch.problem(error, words)
        }
    }

    // MARK: - What the printers are doing

    /// Read the machine's own job history and keep it, for the nozzle counter.
    ///
    /// THE PRINTER IS THE GROUND TRUTH FOR WEAR, and the order log is a sample
    /// of it. `nozzle-wear` counts completed ORDERS, so the U1 on this bench —
    /// which has extruded twelve kilos across a hundred and thirty-three jobs
    /// while nineteen of them were customer orders — reported a fraction of its
    /// real wear, and the replacement warning would fire late, in the direction
    /// that ruins parts.
    ///
    /// It REPLACES the order log for wear specifically and is ignored
    /// everywhere else; mixing the two would double-count every job that is
    /// both an order and a print. That rule is `lib/moonraker-history.js`'s and
    /// is not restated here.
    func importPrinterHistory(_ machine: Machine) async {
        guard permitted("orders", "create") else { return }
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            spendProblem = words.callIt("mac.move_no_engine"); return
        }
        importingHistory = machine.id
        defer { importingHistory = nil }
        do {
            let incoming = try await PrinterWatch.history(machine, engine: engine)
            var kept = 0
            var added = 0
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var floor = Self.rows(root, "machines")
                guard let at = floor.firstIndex(where: { Self.recordId($0) == machine.id }),
                      case .object(var fields) = floor[at] else {
                    throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                }
                var before: [JSONValue] = []
                if case .object(let held)? = fields["printerHistory"],
                   case .array(let jobs)? = held["jobs"] { before = jobs }
                let merged = try await engine.mergePrinterHistory(before, incoming)
                kept = merged.count
                added = merged.count - before.count
                fields["printerHistory"] = .object([
                    "source": .string("moonraker"),
                    "importedAt": .string(StoreWriter.iso(Date())),
                    "jobs": .array(merged),
                ])
                StoreWriter.stamp(&fields)
                floor[at] = .object(fields)
                root["machines"] = .array(floor)
            }
            await load(source)
            // What it actually found, in the shop's own units. "Imported" alone
            // says nothing about whether the number that matters moved.
            let totals = try? await engine.printerHistoryTotals(incoming, since: "")
            var line = words.callIt("mac.history_read") + " \(kept)"
            if added > 0 { line += " (+\(added))" }
            if let totals {
                line += " · \(Int(saturating: totals.grams)) \(words.callIt("common.grams"))"
                line += " · \(Int(saturating: totals.hours)) \(words.callIt("common.hours"))"
            }
            spendNote = line
        } catch {
            spendProblem = words.callIt("mac.history_failed") + " " + PrinterWatch.say(error, words)
        }
    }

    /// The live poll. Started when a book is opened and stopped with it, so a
    /// window showing the sample shop is not knocking on a shop's printers.

    // MARK: - Smart plugs

    func energyMeter() -> EnergyMeter? {
        guard let url = source.build?.storeURL else { return nil }
        if let (book, meter) = meterForBook, book == url { return meter }
        let meter = EnergyMeter.defaults(book: url)
        meterForBook = (url, meter)
        return meter
    }

    /// A machine's wattage from what its plug measured over recent prints —
    /// nil below three metered prints. The machine sheet offers it; nothing
    /// applies it for the shop.
    func measuredPowerDraw(_ machineId: String) async -> KhaytEngine.PowerSuggestion? {
        guard let engine else { return nil }
        return (try? await engine.suggestPowerDraw(printLog: orderRows, machineId: machineId)) ?? nil
    }

    /// The end of a print: its metered energy goes on the job it belongs to.
    ///
    /// The job is the finish seam's — the photo's rule — and nil means the
    /// book could not name one without guessing, so the reading is dropped
    /// rather than put on a job it may not belong to. A FINISHED print writes
    /// `actualEnergyWh` beside its actual time; a failed or cancelled one is
    /// kept for the waste entry the shop logs against it, because the job
    /// goes back to be printed again and its own actuals belong to the print
    /// that succeeds.
    func settleEnergy(_ ended: FinishCamera.Ended, meter: EnergyMeter? = nil,
                      now: Date = Date()) async {
        guard let engine, let meter = meter ?? energyMeter(),
              let reading = await meter.take(ended.machineId, engine: engine) else { return }
        guard ended.outcome == "finished" else {
            meter.remember(ended.machineId, .init(orderId: ended.orderId, reading: reading, at: now))
            return
        }
        guard let jobId = ended.orderId, let build = source.build, canWrite,
              let fields = try? await engine.energyJobFields(reading, at: Self.isoNow(now)),
              !fields.isEmpty else { return }
        do {
            // lock: system — background: a finished print's energy, measured by the meter or camera.
            // On the write chain: a print ending is not a click, and the
            // window must not stop while the book is written.
            try await StoreWriter.updateRecordOffMain(build, collection: "printLog", id: jobId) { record in
                for (key, value) in fields { record[key] = value }
            }
            await load(source)
        } catch {
            FileHandle.standardError.write(Data("khayt: energy not written — \(error)\n".utf8))
        }
    }

    /// The machine's record with its plug's secrets OPENED, for building one
    /// request — never kept, never written back.
    private func plugRecord(_ machineId: String) async -> JSONValue? {
        guard let build = source.build,
              let raw = machineRows.first(where: {
                  if case .object(let o) = $0, case .string(let id)? = o["id"] { return id == machineId }
                  return false
              }),
              case .object(var record) = raw,
              case .object(var plug)? = record["smartPlug"] else { return nil }
        for key in ["token", "password"] {
            if case .string(let sealed)? = plug[key], !sealed.isEmpty {
                plug[key] = .string((try? await Secrets.open(sealed, for: build)) ?? "")
            }
        }
        record["smartPlug"] = .object(plug)
        return .object(record)
    }

    /// Ask a plug whether it is on.
    func readPlug(_ machine: Machine) async {
        // lock: system — a READ: whether the plug is on; switching it is
        // `switchPlug`, which asks the lock.
        guard let engine, let record = await plugRecord(machine.id),
              let request = try? await engine.plugRequest(machine: record, action: "status") else { return }
        do {
            let answer = try await SmartPlug.send(request, engine: engine)
            plugStates[machine.id] = try await engine.plugAnswer(machine: record, answer: answer)
        } catch {
            plugStates[machine.id] = KhaytEngine.PlugState(on: nil, watts: nil)
        }
    }

    /// Switch a machine's plug. Off goes through the shared rule, every time:
    /// power is never cut while the printer is printing, paused, silent or hot.
    func switchPlug(_ machine: Machine, on: Bool) async {
        guard permitted("orders", "edit") else { plugProblem[machine.id] = moveProblem; return }
        await performPlugSwitch(machine, on: on)
    }

    /// The switch itself, with no lock: `switchPlug` asks for a person, and
    /// `plugTick` calls this for the shop's own auto-off rule — which is the
    /// owner's standing choice and must run whoever is signed in. Gating it
    /// refused the minute's auto-off with the lock on and nobody at the Mac,
    /// and said "sign in first" every minute (alpha.62 re-check, round 3).
    func performPlugSwitch(_ machine: Machine, on: Bool) async {
        // lock: system — the shop's own auto-off rule (plugTick), or a person
        // already let through by switchPlug.
        guard let engine, let record = await plugRecord(machine.id) else { return }
        plugProblem[machine.id] = nil
        if !on {
            let verdict = try? await engine.plugCanTurnOff(live: printers.statusCache[machine.id])
            guard verdict?.ok == true else {
                plugProblem[machine.id] = words.callIt(verdict?.reason ?? "plug.no_reading")
                return
            }
        }
        guard let request = try? await engine.plugRequest(machine: record, action: on ? "on" : "off") else { return }
        do {
            let answer = try await SmartPlug.send(request, engine: engine)
            let state = try await engine.plugAnswer(machine: record, answer: answer)
            // Home Assistant answers a switch with what changed, which can be
            // nothing yet; ask again rather than trusting an empty answer.
            if state.on == nil { await readPlug(machine) } else { plugStates[machine.id] = state }
        } catch {
            plugProblem[machine.id] = words.callIt("plug.unreachable") + " "
                + ((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    /// Every minute: what each plug says, whether a print just ended, and
    /// whether an automatic switch-off is due.
    func startWatchingPlugs() {
        guard plugTask == nil else { return }
        plugTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.plugTick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stopWatchingPlugs() {
        plugTask?.cancel()
        plugTask = nil
    }

    private func plugTick() async {
        guard let engine else { return }
        let now = Date()
        // A plug that feeds two printers reads their sum, and a sum cannot be
        // split: those machines are never metered (`lib/print-energy.js`).
        let sharedPlugs = Set((try? await engine.sharedPlugIds(machines: machineRows)) ?? [])
        let meter = energyMeter()
        for machine in machines where machine.smartPlug?.usable == true {
            let live = printers.statusCache[machine.id]
            // A print ending is the edge from printing to anything else.
            if case .object(let o)? = live, case .string(let state)? = o["state"] {
                // Paused is still mid-print: only leaving printing AND paused is an end.
                let busy: (String) -> Bool = { ["printing", "paused", "pausing"].contains($0.lowercased()) }
                let was = lastPrinterState[machine.id] ?? ""
                if busy(was), !busy(state) { printEndedAt[machine.id] = now }
                lastPrinterState[machine.id] = state
            }
            await readPlug(machine)
            // WHAT THE PRINT IS DRAWING, added to its meter while the printer
            // says it is in a job. A plug that gives no watts adds nothing.
            await meter?.observe(machine.id, watts: plugStates[machine.id]?.watts,
                                 live: printers.statusCache[machine.id],
                                 shared: sharedPlugs.contains(machine.id), now: now, engine: engine)
            guard plugStates[machine.id]?.on == true,
                  let record = await plugRecord(machine.id),
                  (try? await engine.plugAutoOffDue(machine: record, live: live,
                                                    finishedAt: printEndedAt[machine.id], now: now)) == true
            else { continue }
            await performPlugSwitch(machine, on: false)
            if plugStates[machine.id]?.on == false {
                // Once per print: the next one sets a new end.
                printEndedAt[machine.id] = nil
                moveNotices.append(words.callIt("plug.auto_off_done", ["name": .string(machine.name)]))
            }
        }
    }

    func startPublishingLeadTime() {
        guard leadTimeTask == nil else { return }
        leadTimeTask = Task { [weak self] in
            try? await Task.sleep(for: Shop.leadTimeFirst)
            while !Task.isCancelled {
                await self?.publishLeadTime()
                // Beside it, on the same timer: the storefront's pricing inputs.
                await self?.publishQuoteSheet()
                try? await Task.sleep(for: Shop.leadTimeEvery)
            }
        }
    }

    func stopPublishingLeadTime() {
        leadTimeTask?.cancel()
        leadTimeTask = nil
    }

    /// Build this shop's promise and send it — or withdraw the last one.
    ///
    /// ── WHY IT WAITS FOR THE PRINTERS ─────────────────────────────────────
    ///
    /// `lead-time-publish` asks the status cache what each machine is doing. A
    /// machine it finds nothing about is a machine with nothing on it, so a
    /// publish made before the first poll lands prices the shop's capacity as
    /// though every printer were free — and it would overwrite a snapshot the
    /// Electron app had published from a cache that DID know. Two apps, one
    /// shop, and the one with less information wins by being later.
    ///
    /// So a shop with machines this app can watch publishes nothing until at
    /// least one of them has answered. A shop with none publishes immediately:
    /// there is nothing to wait for, and waiting for ever is how a feature
    /// silently does nothing.
    func publishLeadTime() async {
        guard let engine, source.build != nil else { return note("no book open") }
        let watchable = machines.contains { PrinterWatch.notWatched($0) == nil }
        let cache = printers.statusCache
        if watchable && cache.isEmpty { return note("waiting for the printers to answer") }

        do {
            let connection = try CloudReader.connection(settingsDict)
            let snapshot = try await engine.leadTimeSnapshot(
                settings: settingsDict, printLog: orderRows, machines: machineRows,
                today: LeadTimePublisher.localDay(), nowIso: Self.isoNow(), statusCache: cache)

            // Nothing to say and nothing said: a shop that has never turned
            // this on must not be sent a withdrawal every six hours for ever.
            if snapshot == nil, leadTimePublished == nil { return }

            guard let build = source.build else { return }
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }
            let session = CloudReader.session
            try await LeadTimePublisher.publish(connection, token: token, snapshot: snapshot) {
                try await session.data(for: $0)
            }
            leadTimePublished = .some(snapshot)
            leadTimeProblem = nil
            note(snapshot == nil ? "withdrawn" : "published")
        } catch CloudReader.Failure.notConnected {
            // Not an error. Most shops have no cloud, and saying so every six
            // hours would fill a diagnostic pane with the absence of a feature.
            leadTimeProblem = nil
            note("this shop has no cloud")
        } catch {
            leadTimeProblem = String(describing: error)
            note(String(describing: error))
        }
    }

    /// Build the shop's quote sheet from the pricing book and send it — or
    /// withdraw the last one. `lib/quote-sheet.js` decides what is in it.
    func publishQuoteSheet() async {
        guard let engine, let build = source.build else { return }
        do {
            let connection = try CloudReader.connection(settingsDict)
            let sheet = try await engine.quoteSheet(store: .object(pricingBook), now: Date(),
                                                    staleAfterHours: QuoteSheetPublisher.staleAfterHours)
            if sheet == nil, quoteSheetPublished == nil { return }
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }
            let session = CloudReader.session
            try await QuoteSheetPublisher.publish(connection, token: token, sheet: sheet) {
                try await session.data(for: $0)
            }
            quoteSheetPublished = .some(sheet)
            quoteSheetSaid = words.callIt(sheet == nil ? "mac.qs_withdrawn" : "mac.qs_published")
            quoteSheetProblem = false
        } catch CloudReader.Failure.notConnected {
            // Not a fault: the pane says to sign in instead.
            quoteSheetSaid = nil
        } catch QuoteSheetPublisher.Failure.notOffered {
            // Khayt Cloud has not shipped the endpoint yet. Not a fault here.
            quoteSheetSaid = words.callIt("mac.qs_not_offered")
            quoteSheetProblem = false
        } catch {
            quoteSheetSaid = words.callIt("mac.qs_failed") + " "
                + ((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            quoteSheetProblem = true
        }
        if let said = quoteSheetSaid {
            quoteSheetAt = Date()
            FileHandle.standardError.write(Data("khayt: quote sheet — \(said)\n".utf8))
        }
    }

    /// The only trace this leaves.
    ///
    /// It runs on a timer, in the background, and writes nothing to the book —
    /// so when it silently does nothing there is otherwise no way to tell
    /// whether it never ran, refused, or was refused. That was the first
    /// question asked of it and it could not be answered.
    ///
    /// `log stream --predicate 'process == "Khayt"'`, or run the binary
    /// directly and read stderr.
    private func note(_ what: String) {
        FileHandle.standardError.write(Data("khayt: lead time — \(what)\n".utf8))
        leadTimeSaid = what
        leadTimeAt = Date()
    }

    /// The injected clock, in the shape `lib/lead-time.js` records.
    static func isoNow(_ now: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: now)
    }

    // MARK: - The machines

    func readCatalog() async {
        guard let engine else { return }
        if catalog.isEmpty { catalog = (try? await engine.printerCatalog()) ?? [] }
        if nozzleMaterials.isEmpty { nozzleMaterials = (try? await engine.nozzleMaterials()) ?? [] }
    }

    /// Put a machine on the floor, or correct one.
    ///
    /// `catalogId` applies a printer model FIRST, the way Khayt's picker does
    /// on the change — the bed, the colours, the power and what the nozzle is
    /// made of, arriving together rather than as eight fields to type.
    /// The camera block through `sanitizeWebcam`, as the shared rule wants it
    /// — for the save and for the form as it opened alike. A camera the rule
    /// cannot make sense of is left out, which the rule reads as "leave the
    /// stored one alone".
    static func sanitisingWebcam(_ input: [String: JSONValue],
                                 engine: KhaytEngine?) async -> [String: JSONValue] {
        var out = input
        guard let cam = input["webcam"] else { return out }
        if let engine,
           let clean = try? await engine.sanitizeWebcam(cam, printerApi: input["printerApi"] ?? .object([:])) {
            out["webcam"] = clean
        } else {
            out.removeValue(forKey: "webcam")
        }
        return out
    }

    /// A machine edited by the shared rule, keeping what the shop did not
    /// touch — see `keptEdit`. `record` is the machine with any picked
    /// printer model already applied; `stored` the machine as the book has it.
    static func editedMachine(_ stored: JSONValue, record: JSONValue,
                              input: [String: JSONValue], opened: [String: JSONValue]?,
                              settings: [String: JSONValue],
                              engine: KhaytEngine) async throws -> MachineWritten {
        let edited = try await engine.editMachine(record, input: input, settings: settings)
        guard let opened, edited.refused == nil else { return edited }
        let base = try await engine.editMachine(stored, input: opened, settings: settings)
        return MachineWritten(machine: keptEdit(stored, written: edited.machine, baseline: base.machine),
                              refused: nil)
    }

    /// `opened` is the sheet's `MachineSheet.Form.input()` for the machine as
    /// it opened — nil for a new one.
    ///
    /// True once the book has the machine. The sheet closes on true and only
    /// on true, and reads `spendProblem` (or `moveProblem`, for the lock) for
    /// what to say otherwise.
    @discardableResult
    func saveMachine(_ input: [String: JSONValue], id: Machine.ID?, catalogId: String?,
                     opened: [String: JSONValue]?) async -> Bool {
        guard permitted("inventory", "edit") else { return false }
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return false
        }
        guard let engine else {
            spendProblem = words.callIt("mac.move_no_engine"); return false
        }
        var undo: [ChangedRecord] = []
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                do {
                    if let was = try await Self.writeMachine(into: &root, input: input, id: id,
                                                             catalogId: catalogId, opened: opened,
                                                             engine: engine, newId: Self.uid("MACH")),
                       let id {
                        undo.append(ChangedRecord(collection: "machines", id: id, was: was))
                        Self.sealUndo(&undo, in: root)
                    }
                } catch let refused as MachineRefused {
                    throw MoveRefused(sentence: self.words.callIt(refused == .gone ? "mac.move_gone"
                                                                                    : "mach.need_name"))
                }
            }
            if !undo.isEmpty { registerMoveUndo(undo, named: words.callIt("mach.edit")) }
            if Self.linksPrinter(input, over: opened) { Telemetry.feature(.printerLinked, in: self) }
            editingMachine = nil
            addingMachine = false
            await load(source)
            spendNote = words.callIt("mach.saved")
            return true
        } catch let refusal as MoveRefused {
            spendProblem = refusal.sentence
        } catch {
            spendProblem = String(describing: error)
        }
        return false
    }

    /// Why a machine write was refused, before it has words.
    enum MachineRefused: Error { case gone, needName }

    /// Whether a machine save connects a printer that was not connected —
    /// a connection type now, where the record as opened had none. Saving an
    /// already-linked machine again is not another link.
    static func linksPrinter(_ input: [String: JSONValue], over opened: [String: JSONValue]?) -> Bool {
        func type(_ record: [String: JSONValue]?) -> String {
            guard case .object(let api)? = record?["printerApi"],
                  case .string(let t)? = api["type"] else { return "" }
            return t == "none" ? "" : t
        }
        return !type(input).isEmpty && type(opened).isEmpty
    }

    /// The machine write itself, against the book as it is ON DISK — the one
    /// path a machine reaches the book by, whether the Machine sheet sent it or
    /// the first-run setup did (`ShopSetup`). Static and taking `root` so it
    /// runs inside the write and can be held to a record in a test.
    ///
    /// A catalogue model is applied FIRST, the way Khayt's picker does on the
    /// change, then `lib/machine-edit.js` takes what was typed — keeping every
    /// field the shop did not touch as the book spells it (`opened`, see
    /// `editedMachine`). A new machine has nothing opened. Returns the record
    /// as it was when an existing machine was corrected, for undo.
    @discardableResult
    static func writeMachine(into root: inout [String: JSONValue], input: [String: JSONValue],
                             id: Machine.ID?, catalogId: String?, opened: [String: JSONValue]?,
                             engine: KhaytEngine, newId: String) async throws -> [String: JSONValue]? {
        var floor = Self.rows(root, "machines")
        let bookSettings = Self.settings(root)
        var record: JSONValue
        var at: Int?
        var was: [String: JSONValue]?
        if let id {
            guard let found = floor.firstIndex(where: { Self.recordId($0) == id }),
                  case .object(let old) = floor[found] else { throw MachineRefused.gone }
            was = old
            record = floor[found]
            at = found
        } else {
            let made = try await engine.newMachine(input, id: newId, count: floor.count)
            guard let fresh = made.machine else { throw MachineRefused.needName }
            record = fresh
        }
        let stored = record
        var wasOpened: [String: JSONValue]?
        if at != nil, let opened { wasOpened = await Self.sanitisingWebcam(opened, engine: engine) }
        if let catalogId, !catalogId.isEmpty {
            record = try await engine.applyPrinterModel(record, catalogId: catalogId,
                                                        settings: bookSettings).machine ?? record
        }
        let edited = try await Self.editedMachine(
            stored, record: record,
            input: await Self.sanitisingWebcam(input, engine: engine),
            opened: wasOpened,
            settings: bookSettings, engine: engine)
        if edited.refused != nil { throw MachineRefused.needName }
        guard case .object(var fields)? = edited.machine else { return was }
        if let at {
            StoreWriter.stamp(&fields)
            floor[at] = .object(fields)
        } else {
            floor.append(.object(fields))
        }
        root["machines"] = .array(floor)
        return was
    }

    // MARK: - What is likely to go wrong with this print

    /// True when an import should walk the mesh as each file lands.
    var analysesRiskAtImport: Bool { riskWhen == "import" }

    /// Look at one model's mesh and keep the answer.
    ///
    /// STORES THE MEASUREMENT AND NOT THE VERDICT, which is the whole reason
    /// this is worth storing at all. `assessModel`'s thresholds are applied to
    /// the shop's own nozzle and support angle, and a shop changes those — a
    /// stored verdict would go stale silently and be read as current. Ninety-one
    /// buckets and a handful of scalars re-judge in microseconds; re-reading a
    /// hundred-megabyte mesh is the part that takes seconds.
    func analyseRisk(_ file: LibraryFile) async {
        guard let engine, !riskRunning.contains(file.id) else { return }
        guard let url = modelFile(for: file) else {
            riskProblem = words.callIt("mac.not_found"); return
        }
        riskRunning.insert(file.id)
        riskProblem = nil
        defer { riskRunning.remove(file.id) }

        // OFF THE MAIN ACTOR. This is seconds of arithmetic on a real file and
        // it is the thread drawing the app — the same mistake that made the
        // library screen hang while it measured.
        let walked = await Task.detached(priority: .userInitiated) {
            try? Mesh.overhangs(of: url)
        }.value
        guard let analysis = walked else {
            riskProblem = words.callIt("risk.unreadable")
            return
        }

        await judge(analysis, for: file, engine: engine)
        await store(analysis, for: file.id, hash: file.contentHash)
    }

    /// Turn a stored or fresh summary into findings, using this shop's numbers.
    func judge(_ analysis: [String: JSONValue], for file: LibraryFile,
                       engine: KhaytEngine) async {
        let mesh = file.mesh
        // NO BED, deliberately, and it is not an omission.
        //
        // `shop.fits` already answers "does it go on a plate you own" properly
        // — per machine, through `lib/print-fit.js` — and the inspector prints
        // that answer three lines above this section. Passing a bed here made
        // the risk report say it a second time in different words: the Mesh
        // section read "Too big for every machine you have" and this one read
        // "It does not fit: 1435×1057×185 mm against …". One fact, two
        // sentences, and a reader left wondering whether they are the same one.
        //
        // The engine still takes a bed, and `PrintRiskTests` covers it, for a
        // caller with no fit line of its own.
        let report = try? await engine.assessModel(
            analysis: analysis,
            nozzleDiameter: nozzleForRisk,
            bbox: mesh.map { (x: $0.x, y: $0.y, z: $0.z) })
        if let report { risks[file.id] = report }
    }

    // Every model with a stored summary is judged again on every load — a
    // settings change reloads — because both move the answer: a shop that
    // fits a 0.6 mm nozzle stops having thin-wall warnings on half its
    // library, and it should not have to re-read a single file to find out.
    // That is `LoadFigures`, in batches, with the same input as `judge`.

    /// The nozzle to judge against: the widest any machine has, or nil.
    ///
    /// The WIDEST rather than an average, because a thin wall is only a problem
    /// on a nozzle too fat to lay it — reporting against the finest nozzle in
    /// the shop would warn about walls the shop can print. Nil when no machine
    /// records one, and the shared rule's own 0.4 default then applies.
    var nozzleForRisk: Double? {
        var widest: Double?
        for row in machineRows {
            guard case .object(let m) = row, case .number(let d)? = m["nozzleDiameter"], d > 0
            else { continue }
            widest = max(widest ?? 0, d)
        }
        return widest
    }

    /// Keep the summary on the record so the mesh is walked once, not once a look.
    private func store(_ analysis: [String: JSONValue], for id: String, hash: String?) async {
        guard let build = source.build else { return }
        do {
            // lock: system — a file's measured analysis cached on its record; nothing a person typed.
            try await StoreWriter.updateOffMain(build) { root in
                Self.edit(&root, ids: [id]) { record in
                    var held: [String: JSONValue] = ["analysis": .object(analysis)]
                    // The hash it was measured from. A record whose file has
                    // been replaced has a summary describing the OLD mesh, and
                    // a stale answer presented as current is worse than none.
                    if let hash { held["contentHash"] = .string(hash) }
                    held["at"] = .number(Date().timeIntervalSince1970 * 1000)
                    record["printRisk"] = .object(held)
                }
            }
            // NOT an undoable edit. A measurement is not a change the shop
            // made, and putting it on the undo stack would mean Cmd-Z after
            // asking a question un-asks it and leaves the shop's own last edit
            // one step further away.
            Task { await load(source) }
        } catch {
            riskProblem = String(describing: error)
        }
    }

    /// Change some print-file records in place, stamping each.
    nonisolated private static func edit(_ root: inout [String: JSONValue], ids: Set<LibraryFile.ID>,
                             change: (inout [String: JSONValue]) -> Void) {
        guard case .array(var rows)? = root["printFiles"] else { return }
        for i in rows.indices {
            guard case .object(var record) = rows[i],
                  case .string(let id)? = record["id"], ids.contains(id) else { continue }
            change(&record)
            StoreWriter.stamp(&record)
            rows[i] = .object(record)
        }
        root["printFiles"] = .array(rows)
    }

    /// The customers, skipping any row without an id.
    ///
    /// A client with no id cannot be pointed at by a job, so it is not a client
    /// this app can offer — every other field is optional, because a customer
    /// written down in a hurry has a name and nothing else.
    static func decodeClients(_ root: [String: JSONValue]) -> [Client] {
        guard case .array(let rows)? = root["clients"] else { return [] }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        return rows.compactMap { try? decoder.decode(Client.self, from: encoder.encode($0)) }
    }

    static func decodeOrders(_ root: [String: JSONValue]) throws -> (items: [Order], skipped: [String]) {
        guard case .array(let rows)? = root["printLog"] else { return ([], []) }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var items: [Order] = [], skipped: [String] = []
        for row in rows {
            do { items.append(try decoder.decode(Order.self, from: try encoder.encode(row))) }
            catch {
                var id = "(no id)"
                if case .object(let o) = row, case .string(let s)? = o["id"] { id = s }
                skipped.append(id)
            }
        }
        return (items, skipped)
    }

    nonisolated static func decodeFiles(_ root: [String: JSONValue]) -> (items: [LibraryFile], skipped: [String]) {
        guard case .array(let rows)? = root["printFiles"] else { return ([], []) }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var items: [LibraryFile] = [], skipped: [String] = []
        for row in rows {
            do { items.append(try decoder.decode(LibraryFile.self, from: try encoder.encode(row))) }
            catch {
                var id = "(no id)"
                if case .object(let o) = row, case .string(let s)? = o["id"] { id = s }
                skipped.append(id)
            }
        }
        return (items, skipped)
    }

    /// Decode one collection, skipping records that do not fit rather than
    /// losing the collection. Same reasoning as the orders and the library: a
    /// newer build will put fields here this app has never heard of.
    static func decode<T: Decodable>(_ root: [String: JSONValue], _ key: String,
                                             as type: T.Type) -> [T] {
        guard case .array(let rows)? = root[key] else { return [] }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        return rows.compactMap { row in
            guard let data = try? encoder.encode(row) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }
    }

    static func librarySettings(_ root: [String: JSONValue]) -> JSONValue? {
        guard case .object(let settings)? = root["settings"] else { return nil }
        return settings["printLibrary"]
    }

    /// Read the shop's tax setup through the shared engine rather than the
    /// settings dictionary. `lib/tax.js` is what decides whether a shop is
    /// registered, at what rate, and whether its prices include the tax — and
    /// the answer differs by country, which is exactly the sort of thing a
    /// second implementation gets subtly wrong.
    func describeTax(_ settings: JSONValue?) async -> String? {
        guard case .object(let dict)? = settings, let engine else { return nil }
        guard let profile = try? await engine.taxProfile(settings: dict), profile.isRegistered else { return nil }
        // `name` is the tax's own label from `lib/tax.js` — VAT, GST, what the
        // shop's invoices say — so it is not translated here. The sentence
        // around it is, and used not to be: this line sits in the sidebar
        // footer on every screen, and an Arabic shop read its tax name in
        // Arabic followed by "included in the price" in English.
        let key = profile.mode == .inclusive ? "mac.tax_inclusive" : "mac.tax_exclusive"
        return words.callIt(key, ["name": .string(profile.name),
                                  "pct": .string(Money.figure(profile.totalPercent))])
    }

    /// The registered tax's name as a LABEL, in the app's language.
    ///
    /// The job inspector labelled its tax line by cutting `taxSummary` at the
    /// first digit — "VAT 15% شامل السعر" → "VAT" — so an Arabic shop read
    /// English in the middle of its own money. VAT is the name nearly every
    /// country in `lib/tax.js` carries, and the shared catalogue already says
    /// it in Arabic (`an.pnl_vat`, «ضريبة القيمة المضافة»); any other name is
    /// the shop's own word and stays as written.
    func nameTax(_ settings: JSONValue?) async -> String? {
        guard case .object(let dict)? = settings, let engine else { return nil }
        guard let profile = try? await engine.taxProfile(settings: dict), profile.isRegistered else { return nil }
        return Self.taxLabel(profile.name, words: words)
    }

    static func taxLabel(_ name: String, words: Words) -> String {
        name.uppercased() == "VAT" ? words.callIt("an.pnl_vat") : name
    }

    /// A price split into what the shop keeps and what it is only holding for
    /// the tax authority. Computed by `lib/tax.js`, not here.
    func taxSplit(_ amount: Double) async -> TaxSplit? {
        guard let engine, case .object(let dict) = settingsValue else { return nil }
        guard let profile = try? await engine.taxProfile(settings: dict), profile.isRegistered else { return nil }
        return try? await engine.computeTax(amount, profile: profile)
    }
}
