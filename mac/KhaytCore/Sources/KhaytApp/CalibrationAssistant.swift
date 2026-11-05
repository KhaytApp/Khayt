import SwiftUI
import AppKit
import KhaytCore

/// The Calibration Assistant: pick a test and a material, save a real test
/// model to print, log what won, and turn the measurements into a tuned
/// filament preset in the slicer — Bed Ready's `renderer/calibration.js`.
///
/// The tests, their steps and the STL are `lib/calibration-models.js`
/// (held to the renderer's own byte for byte by
/// `test/calibration-models.test.js`). The steps are in English on the Mac as
/// they are on the desktop: they are the tests' own technical text, which the
/// desktop never put in the catalogue. The screen around them is translated.
///
/// The result log is `settings.calibrationLog`, newest first, rows of
/// `{id, test, material, result, date}` — what the desktop writes, so a result
/// logged on either machine shows on both.
struct CalibrationAssistant: View {
    @Bindable var shop: Shop

    @State private var tests: [String] = []
    @State private var materials: [String] = []
    @State private var test = "temp"
    @State private var material = "PLA"
    @State private var shown: StudioEngine.CalibrationTest?
    @State private var result = ""
    @State private var note: String?

    // The tuned profile.
    @State private var slicers: [OrcaFolders.Found] = []
    @State private var slicerId = ""
    @State private var bases: [StudioEngine.UserFilament] = []
    @State private var baseFile = ""
    @State private var printerLabel = ""
    @State private var newName = ""
    @State private var values = Measured()
    @State private var asking = false
    @State private var saveNote: String?

    struct Measured: Equatable {
        var nozzleTemp = "", flowRatio = "", pressureAdvance = "", retractionLength = "", maxVolSpeed = ""
        var asValues: [String: String] {
            var v: [String: String] = [:]
            for (k, s) in [("nozzleTemp", nozzleTemp), ("flowRatio", flowRatio), ("pressureAdvance", pressureAdvance),
                           ("retractionLength", retractionLength), ("maxVolSpeed", maxVolSpeed)] {
                let t = s.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { v[k] = t }
            }
            return v
        }
    }

    private var words: Words { shop.words }
    private var slicer: OrcaFolders.Found? { slicers.first { $0.id == slicerId } ?? slicers.first }
    private var base: StudioEngine.UserFilament? { bases.first { $0.file == baseFile } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                testCard
                logCard
                profileCard
            }
            .padding(16)
        }
        .task { await start() }
        .onChange(of: test) { Task { await describe() } }
        .onChange(of: material) { Task { await describe() } }
        .alert(words.callIt("mac.cal_save_q"), isPresented: $asking) {
            Button(words.callIt("mac.cal_save_profile")) { Task { await writeTunedProfile() } }
            Button(words.callIt("common.cancel"), role: .cancel) {}
        } message: {
            Text(words.callIt("mac.cal_save_body", ["slicer": .string(slicer?.slicer.label ?? "")]))
        }
    }

    // MARK: The test

    private var testCard: some View {
        GroupBox(words.callIt("mac.cal_test")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker(words.callIt("mac.cal_test"), selection: $test) {
                        ForEach(tests, id: \.self) { t in Text(words.callIt("mac.cal_t_" + t)).tag(t) }
                    }
                    Picker(words.callIt("mac.cal_material"), selection: $material) {
                        ForEach(materials, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 220)
                }
                if let shown {
                    Text(shown.blurb).font(.callout)
                    Text(shown.sweep).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(shown.steps.enumerated()), id: \.offset) { i, step in
                            Text(words.callIt("mac.cal_step", ["n": .number(Double(i + 1)), "text": .string(step)]))
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                HStack {
                    Button(words.callIt("mac.cal_save_model") + "\u{2026}") { Task { await writeTestModel() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(shown == nil)
                    Button(words.callIt("mac.cal_copy_plan")) {
                        if let plan = shown?.plan {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(plan, forType: .string)
                            note = words.callIt("mac.cal_plan_copied")
                        }
                    }
                    .disabled(shown == nil)
                    Spacer()
                    if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func start() async {
        guard let engine = await Studio.engine() else { return }
        tests = (try? await engine.calibrationTests()) ?? []
        materials = (try? await engine.calibrationMaterials()) ?? []
        await describe()
        await findSlicers()
    }

    private func describe() async {
        guard let engine = await Studio.engine() else { return }
        shown = try? await engine.describeCalibration(test: test, material: material)
    }

    private func writeTestModel() async {
        guard let shown, let engine = await Studio.engine(),
              let stl = try? await engine.calibrationModel(test: test, material: material),
              let url = Studio.askWhereToSave(shown.fileName, type: "stl") else { return }
        do {
            try await Studio.offMain { try Data(stl.utf8).write(to: url, options: .atomic) }
            note = words.callIt("cal.model_saved")
        } catch {
            note = words.callIt("mac.hf_export_failed")
        }
    }

    // MARK: The result log

    /// `settings.calibrationLog`, newest first, as the desktop keeps it.
    private var log: [[String: JSONValue]] {
        guard case .object(let s) = shop.settingsValue, case .array(let rows)? = s["calibrationLog"] else { return [] }
        return rows.compactMap { if case .object(let o) = $0 { o } else { nil } }
    }

    private var canLog: Bool { shop.canWrite && shop.permitted("settings", "edit") }

    private var logCard: some View {
        GroupBox(words.callIt("mac.cal_log")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField(words.callIt("mac.cal_result_ph"), text: $result).textFieldStyle(.roundedBorder)
                    Button(words.callIt("mac.cal_log_result")) { Task { await logResult() } }
                        .disabled(!canLog || result.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if log.isEmpty {
                    Text(words.callIt("mac.cal_log_empty")).font(.callout).foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        ForEach(Array(log.prefix(8).enumerated()), id: \.offset) { _, row in
                            GridRow {
                                Text(Self.text(row["test"])).fontWeight(.medium)
                                Text(Self.text(row["material"])).foregroundStyle(.secondary)
                                Text(Self.text(row["result"]))
                                Text(String(Self.text(row["date"]).prefix(10))).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func text(_ v: JSONValue?) -> String {
        if case .string(let s)? = v { return s }
        return ""
    }

    private func logResult() async {
        let said = result.trimmingCharacters(in: .whitespaces)
        guard canLog, !said.isEmpty, let engine = await Studio.engine(),
              let row = try? await engine.calibrationLogEntry(test: test, material: material, result: said, now: Date())
        else { return }
        await shop.write(as: .person("settings", "edit")) { root in
            Self.prependLog(row, into: &root)
        }
        if shop.writeProblem == nil {
            result = ""
            note = words.callIt("cal.result_saved")
        }
    }

    /// Put one row at the head of `settings.calibrationLog`, every other
    /// setting as it was read inside the write chain.
    nonisolated static func prependLog(_ row: JSONValue, into root: inout [String: JSONValue]) {
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }
        var rows: [JSONValue] = []
        if case .array(let r)? = settings["calibrationLog"] { rows = r }
        rows.insert(row, at: 0)
        settings["calibrationLog"] = .array(rows)
        root["settings"] = .object(settings)
    }

    // MARK: The tuned profile

    private var profileCard: some View {
        GroupBox(words.callIt("mac.cal_profile")) {
            VStack(alignment: .leading, spacing: 10) {
                if slicers.isEmpty {
                    Text(words.callIt("mac.cal_no_slicer")).font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(words.callIt("mac.cal_profile_hint")).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Picker(words.callIt("mac.of_slicer"), selection: $slicerId) {
                            ForEach(slicers) { s in Text(s.slicer.label).tag(s.id) }
                        }
                        Picker(words.callIt("mac.cal_base"), selection: $baseFile) {
                            if bases.isEmpty { Text(words.callIt("mac.cal_no_bases")).tag("") }
                            ForEach(bases) { b in Text(b.name).tag(b.file) }
                        }
                    }
                    HStack {
                        Picker(words.callIt("mac.of_printer"), selection: $printerLabel) {
                            Text(words.callIt("mac.cal_any_printer")).tag("")
                            ForEach(slicer?.printers ?? []) { p in Text(p.label).tag(p.label) }
                        }
                        TextField(words.callIt("mac.cal_new_name"), text: $newName,
                                  prompt: Text(base.map { words.callIt("mac.cal_tuned_name", ["name": .string($0.name)]) } ?? ""))
                    }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        GridRow {
                            field("mac.cal_v_temp", $values.nozzleTemp, base?.current.nozzleTemp)
                            field("mac.cal_v_flow", $values.flowRatio, base?.current.flowRatio)
                            field("mac.cal_v_pa", $values.pressureAdvance, base?.current.pressureAdvance)
                        }
                        GridRow {
                            field("mac.cal_v_retract", $values.retractionLength, base?.current.retractionLength)
                            field("mac.cal_v_mvs", $values.maxVolSpeed, base?.current.maxVolSpeed)
                        }
                    }
                    HStack {
                        Button(words.callIt("mac.cal_save_profile") + "\u{2026}") { asking = true }
                            .disabled(baseFile.isEmpty || values.asValues.isEmpty || !shop.permitted("settings", "edit"))
                        if let saveNote { Text(saveNote).font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: slicerId) { Task { await loadBases() } }
    }

    private func field(_ key: String, _ text: Binding<String>, _ current: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(words.callIt(key)).font(.caption).foregroundStyle(.secondary)
            TextField(words.callIt(key), text: text, prompt: Text(current ?? ""))
                .textFieldStyle(.roundedBorder).frame(width: 130)
        }
    }

    private func findSlicers() async {
        guard let engine = await Studio.engine() else { return }
        slicers = await OrcaFolders.detect(engine)
        if let first = slicers.first(where: { $0.id == "snapmaker" }) ?? slicers.first {
            slicerId = first.id
            await loadBases()
        }
    }

    private func loadBases() async {
        guard let s = slicer, let engine = await Studio.engine() else { bases = []; return }
        bases = await OrcaFolders.userFilaments(s, engine)
        if !bases.contains(where: { $0.file == baseFile }) { baseFile = bases.first?.file ?? "" }
        if printerLabel.isEmpty || !(s.printers.contains { $0.label == printerLabel }) {
            printerLabel = s.defaultPrinter ?? ""
        }
        values = Measured()
    }

    /// `saveCalibratedProfile`: the base read off disk, the shared rule makes
    /// the tuned preset, and it is written into the same folder.
    private func writeTunedProfile() async {
        guard shop.permitted("settings", "edit"), let s = slicer, !baseFile.isEmpty,
              let engine = await Studio.engine() else { return }
        let file = (baseFile as NSString).lastPathComponent    // confined to the folder
        guard let preset = OrcaFolders.readJson(s.filamentDir.appending(path: file)) else {
            saveNote = words.callIt("mac.cal_base_unreadable"); return
        }
        let printer = s.printers.first { $0.label == printerLabel }
        let version = await OrcaFolders.version(for: s, engine)
        do {
            let tuned = try await engine.tunedPreset(base: preset, values: values.asValues, name: newName,
                                                     printer: printer, version: version)
            guard tuned.ok, let text = tuned.text, let name = tuned.name else {
                saveNote = tuned.error ?? words.callIt("mac.of_failed"); return
            }
            let fileBase = try await engine.safeFileBase(name)
            _ = try await Studio.offMain { try OrcaFolders.write(text, named: fileBase, into: s) }
            saveNote = words.callIt("mac.cal_profile_saved", ["name": .string(name), "slicer": .string(s.slicer.label)])
            await loadBases()
        } catch {
            saveNote = words.callIt("mac.of_failed")
        }
    }
}
