import Testing
import Foundation
@testable import KhaytCore

/// The rule crossing the bridge.
///
/// `test/print-facts.test.js` proves the rule under Node. This proves the part
/// Node cannot see: that what `lib/print-facts.js` returns decodes into
/// `KhaytEngine.PrintFacts` under JavaScriptCore — every optional that arrives
/// as `null`, a count that arrives as a JavaScript number and has to land in an
/// `Int`, and an array of strings. A field renamed on one side of that boundary
/// compiles perfectly and throws at run time inside a panel.
struct PrintFactsBridgeTests {

    static let orca = """
    {"printer_model": "Snapmaker U1", "layer_height": "0.12",
     "nozzle_diameter": ["0.4","0.4","0.4","0.4"],
     "filament_type": ["PLA","PLA","PLA","PLA"],
     "sparse_infill_density": "15%", "enable_support": "0",
     "support_type": "tree(auto)"}
    """

    static let model = """
    <?xml version="1.0" encoding="UTF-8"?>
    <config>
      <object id="2">
        <metadata key="name" value="a king"/>
        <metadata key="sparse_infill_density" value="100%"/>
        <part id="1" subtype="normal_part">
          <metadata key="name" value="a king"/>
        </part>
      </object>
    </config>
    """

    @Test func theRuleAnswersThroughTheEngine() async throws {
        let engine = try KhaytEngine()
        let f = try await engine.printFacts(projectSettings: Self.orca,
                                            modelSettings: Self.model, prusa: "")
        #expect(f.printer == "Snapmaker U1")
        #expect(f.layerHeight == 0.12)
        #expect(f.nozzle == 0.4)
        #expect(f.nozzleVaries == false)
        #expect(f.materials == ["PLA"])
        // The object's 100% beats the project's 15% — the real case, and the
        // one that proves the model settings crossed too.
        #expect(f.infill == "100%")
        #expect(f.support == false)
        #expect(f.supportStyle == nil)
        #expect(f.objects == 1)
        #expect(f.source == "orca")
        #expect(!f.isEmpty)
    }

    @Test func everyOptionalSurvivesBeingNull() async throws {
        // A 3MF a CAD program wrote: the rule returns null for all of it, and
        // `PrintFacts` has to decode that rather than throw. This is the case a
        // non-optional field would fail on, in front of a shop, on the file
        // least likely to be tested against.
        let engine = try KhaytEngine()
        let f = try await engine.printFacts(projectSettings: "", modelSettings: "", prusa: "")
        #expect(f.printer == nil)
        #expect(f.layerHeight == nil)
        #expect(f.nozzle == nil)
        #expect(f.materials.isEmpty)
        #expect(f.infill == nil)
        #expect(f.support == nil)
        #expect(f.objects == nil)
        #expect(f.source == nil)
        #expect(f.isEmpty)
    }

    @Test func aPrusaFileAnswersToo() async throws {
        let engine = try KhaytEngine()
        let f = try await engine.printFacts(
            projectSettings: "", modelSettings: "",
            prusa: "layer_height = 0.2\nfill_density = 10%\nsupport_material = 1\n"
                 + "support_material_style = snug\nnozzle_diameter = 0.4\n"
                 + "printer_model = COREONE\nfilament_type = PETG\n")
        #expect(f.source == "prusa")
        #expect(f.printer == "COREONE")
        #expect(f.infill == "10%")
        #expect(f.supportStyle == "snug")
    }

    /// A real file off this shop's disk, when there is one to hand.
    ///
    /// Skipped rather than failed when the library is not on this machine: the
    /// rule is covered above either way, and a test that fails on a colleague's
    /// Mac for want of somebody's models teaches people to ignore red.
    @Test func aRealFileFromTheLibrary() async throws {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "dev")
        let models = (try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "3mf" } ?? []
        guard let file = models.sorted(by: { $0.path < $1.path }).first else { return }
        let entries = try Zip.entries(of: file)
        func text(_ name: String) -> String {
            guard let e = entries.first(where: { $0.name.lowercased() == name.lowercased() }),
                  let d = try? Zip.data(of: e, in: file) else { return "" }
            return String(decoding: d, as: UTF8.self)
        }
        let project = text("Metadata/project_settings.config")
        guard !project.isEmpty else { return }
        let engine = try KhaytEngine()
        let f = try await engine.printFacts(
            projectSettings: project,
            modelSettings: text("Metadata/model_settings.config"), prusa: "")
        #expect(f.source == "orca")
        #expect(f.printer?.isEmpty == false)
        #expect((f.layerHeight ?? 0) > 0)
    }
}
