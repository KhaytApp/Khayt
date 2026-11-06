import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "Split into plates (one file each)" on the Mac: `Converter.convertPlates`.
///
/// The rule is `lib/plate-split.js` and is tested there (test/plate-split.test.js).
/// What is tested here is this app's two ends: that every plate becomes a file
/// in the folder, named as `plateFileName` names it, carrying only its own
/// colours — and that a member the rule RENAMED (a plate's thumbnail) is copied
/// from the source member it came from, not from the one it is now named after.
@MainActor
struct SplitPlatesTests {

    /// Two plates, six colours: plate 1 prints with filaments 4 and 5, plate 2
    /// with filament 6 alone. Bambu's production layout, each object in a file
    /// of its own, and a thumbnail per plate.
    static func sixColours(at url: URL) throws {
        let colours = ["#FFFFFF", "#000000", "#FF0000", "#00FF00", "#0000FF", "#FFFF00"]
        let quoted = colours.map { "\"\($0)\"" }.joined(separator: ",")
        let settings = """
            {"printer_model":"Bambu Lab X1 Carbon","nozzle_diameter":["0.4"],\
            "printable_area":["0x0","256x0","256x256","0x256"],\
            "filament_colour":[\(quoted)],\
            "filament_type":["PLA","PLA","PLA","PLA","PLA","PLA"]}
            """
        let ms = """
            <?xml version="1.0" encoding="UTF-8"?>
            <config>
              <object id="2">
                <metadata key="name" value="A"/>
                <metadata key="extruder" value="4"/>
                <part id="1" subtype="normal_part"><metadata key="extruder" value="5"/></part>
              </object>
              <object id="4">
                <metadata key="name" value="B"/>
                <metadata key="extruder" value="6"/>
                <part id="3" subtype="normal_part"><metadata key="extruder" value="6"/></part>
              </object>
              <plate>
                <metadata key="plater_id" value="1"/>
                <metadata key="thumbnail_file" value="Metadata/plate_1.png"/>
                <model_instance><metadata key="object_id" value="2"/><metadata key="instance_id" value="0"/></model_instance>
              </plate>
              <plate>
                <metadata key="plater_id" value="2"/>
                <metadata key="thumbnail_file" value="Metadata/plate_2.png"/>
                <model_instance><metadata key="object_id" value="4"/><metadata key="instance_id" value="0"/></model_instance>
              </plate>
            </config>
            """
        let root = """
            <?xml version="1.0" encoding="UTF-8"?>
            <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" \
            xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" requiredextensions="p">
             <metadata name="Application">BambuStudio-01.10.02.76</metadata>
             <resources>
              <object id="2" type="model"><components><component p:path="/3D/Objects/object_1.model" objectid="1"/></components></object>
              <object id="4" type="model"><components><component p:path="/3D/Objects/object_2.model" objectid="3"/></components></object>
             </resources>
             <build>
              <item objectid="2" transform="1 0 0 0 1 0 0 0 1 128 128 0" printable="1"/>
              <item objectid="4" transform="1 0 0 0 1 0 0 0 1 435.2 128 0" printable="1"/>
             </build>
            </model>
            """
        func part(_ id: Int) -> Data {
            let xml = """
                <?xml version="1.0"?><model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">\
                <resources><object id="\(id)" type="model"><mesh><vertices>\
                <vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/>\
                </vertices><triangles><triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="1" v3="3"/>\
                <triangle v1="1" v2="2" v3="3"/><triangle v1="0" v2="3" v3="2"/></triangles></mesh></object>\
                </resources><build/></model>
                """
            return Data(xml.utf8)
        }
        // Not PNGs, and not UTF-8 either: they cross by name, as a real picture does.
        let thumb1 = Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0x01])
        let thumb2 = Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0x02])
        try ZipWrite.archive([
            .init("[Content_Types].xml", Data("<?xml version=\"1.0\"?><Types/>".utf8)),
            .init("3D/3dmodel.model", Data(root.utf8)),
            .init("3D/Objects/object_1.model", part(1)),
            .init("3D/Objects/object_2.model", part(3)),
            .init("Metadata/project_settings.config", Data(settings.utf8)),
            .init("Metadata/model_settings.config", Data(ms.utf8)),
            .init("Metadata/plate_1.png", thumb1),
            .init("Metadata/plate_2.png", thumb2),
        ]).write(to: url)
    }

    private func member(_ name: String, in url: URL) throws -> Data {
        let entry = try #require(try Zip.entries(of: url).first { $0.name == name })
        return try Zip.data(of: entry, in: url, limit: .max)
    }

    @Test("every plate is its own file, with only its own colours, and its own thumbnail")
    func splitsEveryPlate() async throws {
        let dir = ConverterTests.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "statue.3mf")
        try Self.sixColours(at: source)
        let out = dir.appending(path: "out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let results = try await Converter.convertPlates(source, into: out,
                                                        options: ["targetId": .string("snapmaker-u1")],
                                                        bindMeshes: true, engine: try ConverterTests.engine())
        #expect(results.map(\.error) == [nil, nil])
        #expect(results.compactMap { $0.url?.lastPathComponent } == ["statue-plate1.3mf", "statue-plate2.3mf"])

        func colours(_ url: URL) throws -> [String] {
            let cfg = try JSONSerialization.jsonObject(with: try member("Metadata/project_settings.config", in: url))
            return ((cfg as? [String: Any])?["filament_colour"] as? [String]) ?? []
        }
        let one = out.appending(path: "statue-plate1.3mf"), two = out.appending(path: "statue-plate2.3mf")
        #expect(try colours(one) == ["#00FF00", "#0000FF"], "plate 1: filaments 4 and 5, now slots 1 and 2")
        #expect(try colours(two) == ["#FFFF00"], "plate 2: filament 6, now slot 1")
        let ms2 = String(decoding: try member("Metadata/model_settings.config", in: two), as: UTF8.self)
        #expect(ms2.contains("key=\"extruder\" value=\"1\""))
        #expect(!ms2.contains("key=\"extruder\" value=\"6\""), "the extruder did not follow its colour")

        // Plate 2's own picture, renamed to plate 1's name — not plate 1's picture.
        #expect(try member("Metadata/plate_1.png", in: two) == Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0x02]))
        // And the geometry it keeps is the source's, byte for byte.
        #expect(try member("3D/Objects/object_2.model", in: two) == (try member("3D/Objects/object_2.model", in: source)))
        #expect(!(try Zip.entries(of: two)).contains { $0.name == "3D/Objects/object_1.model" },
                "another plate's geometry came along")
    }

    @Test("the preview says how many plates a split would make, and whether the file has variable layer height")
    func previewCountsPlates() async throws {
        let dir = ConverterTests.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "statue.3mf")
        try Self.sixColours(at: source)
        let p = try await Converter.preview(source, target: ["targetId": .string("snapmaker-u1")], bounds: nil,
                                            plans: false, engine: try ConverterTests.engine())
        #expect(p.plates == 2)
        #expect(p.variableLayerHeight == false)
    }
}
