import Foundation
import KhaytCore

/// Getting a model onto a printer from the Mac: slicing it and sending the
/// result, and converting a 3MF with the desktop converter's options.
///
/// The desktop slices with `runSlice` in `main.js` and converts through
/// `hub:mf-convert`. Every decision in either is a shared rule —
/// `lib/slicers.js` builds the slicer's command line, `lib/printer-upload.js`
/// decides what a printer may be sent, `lib/mf-convert.js` and
/// `lib/printer-profiles.js` decide what a conversion does — and this file only
/// sequences them, with the file work off the main thread.
extension Shop {

    // MARK: - Slice and send

    /// A file a printer cannot run until it is sliced: a model, by the shared
    /// upload rule's own answer (`not_sliced`), not by a list of extensions
    /// kept here.
    func needsSlicing(_ file: URL, for machine: Machine) async -> Bool {
        guard let engine, let type = machine.printerApi?.type, !type.isEmpty else { return false }
        let fit = try? await engine.printerUploadCheck(type: type, fileName: file.lastPathComponent)
        return fit?.ok == false && fit?.code == "not_sliced"
    }

    /// The models of a job, for the Send sheet to offer beside its sliced
    /// files: what the shop slices when nothing has been sliced yet.
    func modelFiles(for job: Order) -> [URL] {
        var out: [URL] = []
        for part in job.parts {
            guard let id = part.printFileId, let file = libraryFile(id: id),
                  let url = modelFile(for: file), !out.contains(url) else { continue }
            out.append(url)
        }
        return out
    }

    /// Slice `model` with the shop's default slicer and send the G-code to
    /// `machineId`, starting it if asked — the desktop's `hub:slice-and-print`.
    ///
    /// The printer is asked first whether it can take G-code at all, so a
    /// three-minute slice is never spent on a send that was always going to be
    /// refused. The slice runs on `SlicerRun.queue`, never on the main thread
    /// nor the cooperative pool, and its scratch folder is removed afterwards
    /// whatever happened. While it runs, `slicingFor` names the machine and
    /// `sendNote` says so.
    func sliceAndSend(_ model: URL, machineId: String, startPrint: Bool, jobId: String? = nil) async {
        guard let engine else { return }
        guard let machine = sendablePrinters.first(where: { $0.id == machineId }) else {
            if let gone = machines.first(where: { $0.id == machineId }) {
                moveProblem = words.callIt("mac.life_send_refused", ["name": .string(gone.name)])
            }
            return
        }
        guard permitted("orders", "edit") else { printerProblem[machine.id] = moveProblem; return }
        guard let type = machine.printerApi?.type, !type.isEmpty else { return }
        // Can this printer run what the slicer will write?
        let stem = model.deletingPathExtension().lastPathComponent
        let fit = try? await engine.printerUploadCheck(type: type, fileName: stem + ".gcode")
        guard fit?.ok == true, type != "bambu" else {
            sendNote = words.callIt(type == "bambu" ? "mac.send_unsupported" : "mac.send_wrong_kind",
                                    ["kind": .string("gcode")])
            return
        }
        guard let slicer = defaultSlicer,
              (try? await engine.mayLaunchAsSlicer(path: slicer.path)) == true else {
            sendNote = words.callIt("slicer.no_config"); return
        }
        guard let dir = try? SlicerRun.scratch() else { return }
        defer { try? FileManager.default.removeItem(at: dir) }

        sendNote = words.callIt("slicer.sending")
        printerProblem[machine.id] = nil
        slicingFor = machine.id
        defer { slicingFor = nil }

        let output = dir.appending(path: "out.gcode")
        // A bare mesh sliced by an Orca fork needs the fork's own presets (#1778).
        let presets = await SlicerRun.bareModelPresets(engine: engine, slicer: slicer, template: slicer.args,
                                                       model: model, outDir: dir)
        guard let argv = try? await engine.sliceArgv(template: slicer.args, model: model.path,
                                                     output: output.path, outdir: dir.path,
                                                     slicer: slicer.path, presets: presets.presets) else {
            sendNote = words.callIt("slicer.fail"); return
        }
        let sliced: Result<URL, SlicerRun.Failure> = await withCheckedContinuation { done in
            SlicerRun.queue.async {
                do {
                    try SlicerRun.slice(model, with: slicer, argv: argv, allowed: true)
                    guard let gcode = SlicerRun.gcode(in: dir, expected: output) else {
                        done.resume(returning: .failure(.producedNothing(presets.problem ?? ""))); return
                    }
                    // Named after the model: the printer lists it, and the job
                    // records the file it ran (`recordPrintRun`).
                    let named = dir.appending(path: Self.slicedName(stem))
                    if (try? FileManager.default.moveItem(at: gcode, to: named)) != nil {
                        done.resume(returning: .success(named))
                    } else {
                        done.resume(returning: .success(gcode))
                    }
                } catch let failure as SlicerRun.Failure {
                    done.resume(returning: .failure(failure))
                } catch {
                    done.resume(returning: .failure(.failed(ErrorText.plain(error))))
                }
            }
        }
        switch sliced {
        case .failure(let failure):
            let said = words.callIt("slicer.fail") + " " + failure.description
            printerProblem[machine.id] = said
            sendNote = said
        case .success(let gcode):
            await sendToPrinter(gcode, machineId: machine.id, startPrint: startPrint, jobId: jobId)
        }
    }

    /// `Dragon.3mf` → `Dragon.gcode`, kept to the characters a printer's own
    /// file list shows (the upload rule names the remote copy on top of this).
    nonisolated static func slicedName(_ stem: String) -> String {
        let cleaned = String(stem.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || "-_. ".unicodeScalars.contains($0) ? Character($0) : "_"
        }).trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "model" : String(cleaned.prefix(80))) + ".gcode"
    }

    // MARK: - The converter sheet

    struct ConvertRequest: Identifiable {
        let file: LibraryFile
        /// The printer the sheet opens on; nil for a standard 3MF.
        let targetId: String?
        var id: String { file.id }
    }

    /// Open the converter on a model, aimed at `targetId`. Converting adds a
    /// model to the library, so it asks what an import asks.
    func openConverter(_ file: LibraryFile, targetId: String?) {
        guard permitted("inventory", "create") else { return }
        clearLastOutcome()
        pendingConvert = ConvertRequest(file: file, targetId: targetId)
    }

    /// One of the shop's own printers as the desktop's manager wrote it
    /// (`settings.customPrinters`), for the converter's `targetProfile`. Its
    /// `id` is set to the one the shared rule listed it under, so the rule
    /// reads back the same printer.
    func customPrinterSpec(_ id: String) -> JSONValue? {
        guard printerProfiles.first(where: { $0.id == id })?.custom == true,
              case .array(let own)? = settingsDict["customPrinters"] else { return nil }
        for case .object(var spec) in own {
            let name = SettingsReader(settings: spec).text("name").trimmingCharacters(in: .whitespaces)
            let given = SettingsReader(settings: spec).text("id").trimmingCharacters(in: .whitespaces)
            let derived = String(("custom-" + name.lowercased()
                .replacing(/[^a-z0-9]+/, with: "-")).prefix(40))
            if given == id || (given.isEmpty && derived == id) {
                spec["id"] = .string(id)
                return .object(spec)
            }
        }
        return nil
    }

    /// The target as `convertMembers` and `convertPreview` take it.
    func convertTarget(_ id: String?) -> [String: JSONValue] {
        guard let id, !id.isEmpty else { return [:] }
        var out: [String: JSONValue] = ["targetId": .string(id)]
        if let spec = customPrinterSpec(id) { out["targetProfile"] = spec }
        return out
    }

    // MARK: - Converting several at once

    struct BatchConvertRequest: Identifiable {
        let files: [LibraryFile]
        let targetId: String?
        let id = UUID()
    }

    func openBatchConverter(_ files: [LibraryFile], targetId: String?) {
        guard permitted("inventory", "create") else { return }
        let threeMFs = files.filter { ($0.sourceFile?.ext ?? "").lowercased() == "3mf" }
        guard !threeMFs.isEmpty else { return }
        clearLastOutcome()
        pendingBatchConvert = BatchConvertRequest(files: threeMFs, targetId: targetId)
    }

    /// Convert every file for one target into `folder`, and into the library —
    /// the desktop's `runBatch`, rule for rule. `colourMode` is `merge`, `fs`,
    /// `band`, or empty for a printer that does not mix. Returns how many
    /// converted; `each` hears every file's outcome as it lands.
    func convertBatch(_ files: [LibraryFile], targetId: String?, colourMode: String, into folder: URL,
                      each: (String, Bool) -> Void) async -> Int {
        guard permitted("inventory", "create"), let engine else { return 0 }
        converting = true
        defer { converting = false }
        let target = convertTarget(targetId)
        let tag = String((targetId ?? "generic").filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(14))
        var ok = 0
        var whyNot: String?
        for file in files {
            guard let source = modelFile(for: file) else { each(file.id, false); continue }
            var options = target
            if targetId == nil {
                options["mode"] = .string("normalize")
            } else if let p = try? await Converter.preview(source, target: target, bounds: nil, plans: false, engine: engine), p.ok {
                if p.cross == true {
                    // Another ecosystem: a Generic 3MF, never a retarget into
                    // settings the file cannot hold.
                    options = ["targetId": .string(targetId ?? ""), "mode": .string("normalize")]
                } else if p.fullSpectrumCapable == true {
                    // More colours than heads on a printer that mixes: the
                    // shop's choice. A file that fits its heads needs none.
                    switch colourMode {
                    case "fs": options["fullSpectrum"] = .bool(true)
                    case "band": options["bandSwap"] = .bool(true)
                    case "merge": options["mergeToSlots"] = .bool(true)
                    default: break
                    }
                }
            }
            let base = source.deletingPathExtension().lastPathComponent
            let destination = folder.appending(path: base + "-" + (tag.isEmpty ? "out" : tag) + ".3mf")
            do {
                _ = try await Converter.convert(source, into: destination, options: options, engine: engine)
                _ = try? await LibraryImport.add(destination, shop: self, keepOriginal: true)
                ok += 1
                each(file.id, true)
            } catch let refusal as Converter.Failure {
                whyNot = refusal.said(words)
                each(file.id, false)
            } catch {
                whyNot = said(error)
                each(file.id, false)
            }
        }
        convertNote = words.callIt("conv.batch_done", [
            "ok": .string(Money.quantity(Double(ok), decimals: 0)),
            "total": .string(Money.quantity(Double(files.count), decimals: 0))])
        if ok < files.count, let whyNot { convertProblem = whyNot }
        return ok
    }

    /// The machines that say what they have loaded — reported by the printer,
    /// or entered by hand — for "Match to loaded spools".
    var machinesWithLoadedSpools: [Machine] {
        machines.filter { !loadedSlots(for: $0.id).isEmpty }
    }
}
