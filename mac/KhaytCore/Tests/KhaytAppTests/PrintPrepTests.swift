import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Slice-and-send, and the converter sheet (`Shop+PrintPrep.swift`,
/// `ConvertSheet`, `KhaytEngine.convertPreview` / `spoolMatch`).
///
/// The decisions are the shared rules' and are tested where they live
/// (`test/convert-target-rules.test.js`, `test/spool-match.test.js`). What is
/// tested here is that this app asks them with what the desktop asks them
/// with, and gets the desktop's answers back.
@Suite(.serialized) @MainActor struct PrintPrepTests {

    static func preview(_ url: URL, target: [String: JSONValue], bounds: [String: JSONValue]? = nil,
                        plans: Bool = false) async throws -> KhaytEngine.ConvertPreview {
        let engine = try KhaytEngine()
        return try await Converter.preview(url, target: target, bounds: bounds, plans: plans, engine: engine)
    }

    @Test("a six-colour file aimed at a U1 is offered Full Spectrum, and the plan is read with the meshes")
    func fullSpectrumOffered() async throws {
        let dir = ConverterTests.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "painted.3mf")
        try ConverterTests.paintedMF(at: url)

        let quick = try await Self.preview(url, target: ["targetId": .string("snapmaker-u1")])
        #expect(quick.ok)
        #expect(quick.filaments?.count == 6)
        #expect(quick.maxColors == 4)
        #expect(quick.generic == false)
        #expect(quick.cross == false)
        #expect(quick.fullSpectrumCapable == true)
        #expect(quick.fullSpectrum == nil, "the plan is not worked out without the meshes")

        let full = try await Self.preview(url, target: ["targetId": .string("snapmaker-u1")], plans: true)
        #expect(full.fullSpectrum?.available == true)
        #expect(full.fullSpectrum?.heads?.count == 4, "four heads load physically on a U1")
        // The mesh reader runs here at all: it used to throw on `Buffer`, which
        // JavaScriptCore does not have, and band-swap read as unavailable.
        #expect(full.bands?.available == true, "the band analysis ran")
    }

    @Test("a standard 3MF is the generic target, and another ecosystem is said to be one")
    func genericAndCross() async throws {
        let dir = ConverterTests.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "painted.3mf")
        try ConverterTests.paintedMF(at: url)

        let plain = try await Self.preview(url, target: [:])
        #expect(plain.generic == true)
        #expect(plain.fullSpectrumCapable == false)

        let prusa = try await Self.preview(url, target: ["targetId": .string("prusa-mk4-mmu3")])
        #expect(prusa.flavour == "bambu")
        #expect(prusa.cross == true, "a Bambu project on a Prusa is saved as a Generic 3MF")
    }

    @Test("the bed check is the shared rule's, on the size the library measured")
    func bedFit() async throws {
        let dir = ConverterTests.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "model.3mf")
        try ConverterTests.paintedMF(at: url)
        let big: [String: JSONValue] = ["x": .number(400), "y": .number(100), "z": .number(50)]
        let small: [String: JSONValue] = ["x": .number(100), "y": .number(100), "z": .number(50)]
        let over = try await Self.preview(url, target: ["targetId": .string("snapmaker-u1")], bounds: big)
        #expect(over.fitWarnings?.isEmpty == false)
        let fine = try await Self.preview(url, target: ["targetId": .string("snapmaker-u1")], bounds: small)
        #expect(fine.fitWarnings?.isEmpty == true)
    }

    @Test("matching to loaded spools sends each colour to the spool most like it, as the desktop does")
    func spoolMatch() async throws {
        let engine = try KhaytEngine()
        let loaded = [KhaytEngine.LoadedSlot(slot: 0, hex: "#0000FF", material: "PLA"),
                      KhaytEngine.LoadedSlot(slot: 1, hex: "#FF0000", material: "PLA")]
        let cols: [[String: JSONValue]] = [["hex": .string("#FE0000"), "material": .string("PLA")],
                                           ["hex": .string("#0000FE"), "material": .string("PLA")]]
        let m = try await engine.spoolMatch(colours: cols, loaded: loaded, slotCount: 4, flavour: "bambu")
        #expect(m.ok)
        #expect(m.map == [1, 0])
        #expect(m.kind == "slotMap")
        #expect(m.usable == [0, 1])
        guard case .object(let options)? = m.options else { Issue.record("no options"); return }
        #expect(options["slotMap"] == .array([.number(1), .number(0)]))
        #expect(options["spoolStrict"] == .bool(true), "a match the converter cannot apply whole is refused")

        // The shop's own edit wins, as long as it names a loaded slot.
        let edited = try await engine.spoolMatch(colours: cols, loaded: loaded, slotCount: 4,
                                                 flavour: "bambu", map: [1, 1])
        #expect(edited.map == [1, 1])
    }

    @Test("a material that disagrees is warned, never re-routed")
    func materialWarning() async throws {
        let engine = try KhaytEngine()
        let m = try await engine.spoolMatch(
            colours: [["hex": .string("#FF0000"), "material": .string("PETG")]],
            loaded: [KhaytEngine.LoadedSlot(slot: 0, hex: "#FF0000", material: "PLA")],
            slotCount: 4, flavour: "bambu")
        #expect(m.rows.first?.materialMismatch == true)
        #expect(m.warnings.contains { $0.code == "material" })
    }

    @Test("the shop's own printers come first, converted for by profile")
    func customPrinters() async throws {
        let engine = try KhaytEngine()
        let mine: JSONValue = .object(["id": .string("cp1"), "name": .string("Workshop Voron"),
                                       "flavour": .string("prusa"), "maxColors": .number(1),
                                       "bed": .object(["x": .number(300), "y": .number(300), "z": .number(280)])])
        let all = try await engine.printerProfiles(custom: [mine, .object(["name": .string("")])])
        #expect(all.first?.id == "cp1")
        #expect(all.first?.custom == true)
        #expect(all.filter { $0.custom == true }.count == 1, "a printer with no name is left out")
        #expect(all.contains { $0.id == "snapmaker-u1" && $0.custom != true && $0.supportsMixedFilament == true })
        #expect(all.first?.supportsMixedFilament == false)
    }

    @Test("a batch converts every 3MF for one printer into the folder, and into the library")
    func batch() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let src = MenuCoverageTests.source("Shop+PrintPrep.swift")
        #expect(src.contains("options = [\"targetId\": .string(targetId ?? \"\"), \"mode\": .string(\"normalize\")]"),
                "a file from another ecosystem would be retargeted into settings it cannot hold")
        #expect(src.contains("LibraryImport.add(destination, shop: self, keepOriginal: true)"))
        let window = MenuCoverageTests.source("ShopWindow.swift")
        #expect(window.contains(".shopSheet(item: $shop.pendingBatchConvert) { BatchConvertSheet("))
        #expect(MenuCoverageTests.source("FileActions.swift").contains("shop.openBatchConverter(batch, targetId: profile.id)"))
        // Nothing but 3MFs is taken into a batch.
        shop.openBatchConverter(shop.files.filter { ($0.sourceFile?.ext ?? "").lowercased() != "3mf" }, targetId: nil)
        #expect(shop.pendingBatchConvert == nil)
    }

    @Test("a sliced file is named after its model")
    func slicedName() {
        #expect(Shop.slicedName("Dragon") == "Dragon.gcode")
        #expect(Shop.slicedName("a/b:c") == "a_b_c.gcode")
        #expect(Shop.slicedName("") == "model.gcode")
    }

    @Test("every word slice-and-send and the converter added has English and Arabic, and none shadows one")
    func words() {
        for (key, langs) in PrintPrepWords.table {
            #expect(langs["en"]?.isEmpty == false, "\(key) has no English")
            #expect(langs["ar"]?.isEmpty == false, "\(key) has no Arabic")
            #expect(Words.own[key] == langs, "\(key) is shadowed by Words.base")
        }
        let base = MenuCoverageTests.source("Words.swift")
        for key in PrintPrepWords.table.keys {
            #expect(!base.contains("\"\(key)\":"), "\(key) is in both tables")
        }
        for key in ["conv.fs_toggle", "conv.spool_title", "slicer.send_title", "slicer.no_config"] {
            #expect(Words.borrowed.contains(key), "\(key) is used and not declared borrowed")
        }
    }

    @Test("the menus open the converter sheet, and the Send sheet slices a model first")
    func wiring() {
        let window = MenuCoverageTests.source("ShopWindow.swift")
        #expect(window.contains(".shopSheet(item: $shop.pendingConvert) { ConvertSheet("))
        let actions = MenuCoverageTests.source("FileActions.swift")
        #expect(actions.contains("shop.openConverter(file, targetId: profile.id)"))
        #expect(!actions.contains("await shop.convertModel(file, targetId: profile.id)"),
                "the context menu still converts without the sheet")
        let menus = MenuCoverageTests.source("Menus.swift")
        #expect(menus.contains("shop.openConverter(file, targetId: profile.id)"))
        let send = MenuCoverageTests.source("SendToPrinterSheet.swift")
        #expect(send.contains("shop.sliceAndSend(file, machineId: id, startPrint: go, jobId: jobId)"))
        #expect(send.contains("shop.modelFiles(for: job)"), "the job's models are not offered")
        // Slicing is a three-minute blocking call: on its own queue, never the
        // main thread nor the cooperative pool.
        let prep = MenuCoverageTests.source("Shop+PrintPrep.swift")
        #expect(prep.contains("SlicerRun.queue.async"))
        #expect(!prep.contains("Task.detached"))
    }
}
