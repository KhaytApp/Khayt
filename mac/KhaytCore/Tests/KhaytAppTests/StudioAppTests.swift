import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import KhaytApp
@testable import KhaytCore

/// The Mac side of the Bed Ready tools: the photo read, the zip written, the
/// slicer folder walked, the result log appended — and the menu that reaches
/// them. Structure only for HueForge (bedready#91 is still moving its output).
@MainActor
struct StudioAppTests {

    static func pngFile(width: Int, height: Int) throws -> URL {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try #require(ctx.makeImage())
        let url = FileManager.default.temporaryDirectory.appending(path: "studio-\(UUID().uuidString).png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test("a photo is read at the desktop's 640 pixels, as opaque RGBA")
    func photoRead() throws {
        let url = try Self.pngFile(width: 1600, height: 900)
        defer { try? FileManager.default.removeItem(at: url) }
        let picture = try HueForgeModel.decode(url)
        #expect(picture.width == 640 && picture.height == 360)
        #expect(picture.rgba.count == 640 * 360 * 4)
        #expect(picture.rgba[3] == 255)
        let small = try Self.pngFile(width: 200, height: 100)
        defer { try? FileManager.default.removeItem(at: small) }
        let kept = try HueForgeModel.decode(small)
        #expect(kept.width == 200 && kept.height == 100, "never scaled up")
    }

    @Test("an exported relief is a zip Orca can open, thumbnails stored")
    func exportIsAValidZip() async throws {
        let engine = try StudioEngine()
        try await engine.setPicture(StudioEngine.Picture(width: 40, height: 30,
                                                         rgba: Data((0..<(40 * 30)).flatMap { i in [UInt8(i % 256), 80, 160, 255] })))
        let fils = try await engine.suggest(owned: [], maxColors: 2)
        let s = StudioEngine.ReliefSettings()
        _ = try #require(try await engine.planRelief(fils, s))
        let piece = try #require(try await engine.reliefPieces(name: "z", settings: s, thumbnail: true).first)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let data = try HueForgeModel.archive(piece, big: png, small: png)
        let url = FileManager.default.temporaryDirectory.appending(path: "studio-\(UUID().uuidString).3mf")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let entries = try Zip.entries(of: url)
        #expect(entries.map(\.name) == piece.members.map(\.name))
        let thumb = try #require(entries.first { $0.name == "Metadata/plate_1.png" })
        #expect(thumb.method == 0, "a PNG is stored, not deflated")
        #expect(try Zip.data(of: thumb, in: url) == png)
        let ranges = try #require(entries.first { $0.name == "Metadata/layer_config_ranges.xml" })
        #expect(String(decoding: try Zip.data(of: ranges, in: url), as: UTF8.self).contains("<range"))
    }

    /// A fake Orca-family config tree, as the desktop's own tests build one.
    static func fakeSlicer(_ dir: String = "OrcaSlicer") throws -> URL {
        let base = FileManager.default.temporaryDirectory.appending(path: "orca-\(UUID().uuidString)")
        let machine = base.appending(path: "\(dir)/system/Vendor/machine")
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
        for m in ["Foo 0.4 nozzle", "Foo 0.2 nozzle", "fdm_base", "MyKlipper"] {
            try Data("{\"type\":\"machine\"}".utf8).write(to: machine.appending(path: m + ".json"))
        }
        let fil = base.appending(path: "\(dir)/user/default/filament")
        try FileManager.default.createDirectory(at: fil, withIntermediateDirectories: true)
        try Data(#"{"type":"filament","name":"My PLA","nozzle_temperature":["205"],"version":"1.2"}"#.utf8)
            .write(to: fil.appending(path: "My PLA.json"))
        return base
    }

    @Test("the slicer folder is found and read the way the desktop reads it")
    func detect() async throws {
        let base = try Self.fakeSlicer()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = try StudioEngine()
        let found = await OrcaFolders.detect(engine, base: base)
        let one = try #require(found.first)
        #expect(found.count == 1 && one.id == "orcaslicer")
        #expect(one.printers.map(\.label) == ["Foo"])
        #expect(one.printers.first?.machines == ["Foo 0.2 nozzle", "Foo 0.4 nozzle"])
        #expect(one.filamentDir.path.hasSuffix("OrcaSlicer/user/default/filament"))
        #expect(await OrcaFolders.version(for: one, engine) == "1.2")
        #expect(OrcaFolders.installedNames(one) == ["My PLA"])
        let bases = await OrcaFolders.userFilaments(one, engine)
        #expect(bases.map(\.name) == ["My PLA"] && bases.first?.current.nozzleTemp == "205")
        let written = try OrcaFolders.write("{}", named: "New One", into: one)
        #expect(written.lastPathComponent == "New One.json")
        #expect(OrcaFolders.installedNames(one).contains("New One"))
    }

    @Test("a logged result goes on top of settings.calibrationLog, and nothing else moves")
    func logPrepends() {
        var root: [String: JSONValue] = ["settings": .object([
            "currency": .string("SAR"),
            "calibrationLog": .array([.object(["id": .string("CAL1")])]),
        ])]
        CalibrationAssistant.prependLog(.object(["id": .string("CAL2")]), into: &root)
        guard case .object(let s)? = root["settings"], case .array(let rows)? = s["calibrationLog"] else {
            Issue.record("no log"); return
        }
        #expect(rows.count == 2 && rows.first == .object(["id": .string("CAL2")]))
        #expect(s["currency"] == .string("SAR"))
        var empty: [String: JSONValue] = [:]
        CalibrationAssistant.prependLog(.object(["id": .string("CAL3")]), into: &empty)
        guard case .object(let e)? = empty["settings"], case .array(let one)? = e["calibrationLog"] else {
            Issue.record("no log made"); return
        }
        #expect(one.count == 1)
    }

    @Test("the Tools menu opens the studio window, and the lock disables it")
    func wiring() {
        let menus = EmptyStateTests.source("Menus.swift")
        #expect(menus.contains("CommandMenu(Text(Words.upfront(\"mac.menu_tools\"))) { ToolsMenu().environment(shop).disabled(shop.needsSignIn) }"))
        let app = EmptyStateTests.source("KhaytApp.swift")
        #expect(app.contains("id: StudioWindow.id"))
        let window = EmptyStateTests.source("StudioWindow.swift")
        for tool in ["HueForgeStudio(shop: shop)", "CalibrationAssistant(shop: shop)", "OrcaFilamentProfiles(shop: shop)"] {
            #expect(window.contains(tool), "\(tool) is not in the window")
        }
        #expect(Words.upfront("mac.menu_tools") != "mac.menu_tools")
    }

    @Test("the export's file name follows the desktop's rule")
    func exportName() {
        let model = HueForgeModel()
        #expect(model.stem == "hueforge")
        model.pictureName = "My Photo (1).jpeg"
        #expect(model.stem == "My Photo (1)")
        #expect(model.safeStem == "My_Photo_1_")
    }
}
