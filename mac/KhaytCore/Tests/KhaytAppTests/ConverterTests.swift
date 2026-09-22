import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Converting a 3MF without Electron.
///
/// The decisions are `lib/mf-convert.js` and are tested where they live. What
/// is tested here is the two ends this app supplies — that it reads a container,
/// hands the rule only what a rule needs, and writes back a file whose geometry
/// is the geometry it was given.
/// SERIALIZED because `refusesAMeshTooBig` lowers `Converter.paintInlineLimit`
/// and puts it back. That is one shared static for the whole process, so a
/// neighbour converting a real file beside it would see the lowered limit and
/// fail for a reason that has nothing to do with it — which is what
/// `SharedStateIsSerializedTests` exists to prevent, and it caught this.
@Suite(.serialized)
@MainActor
struct ConverterTests {

    /// A conversion has to END somewhere the shop can find it.
    ///
    /// It used to end at a file in a folder. The shop then had to go and import
    /// the thing it had just made — in the one app whose whole job is knowing
    /// what models it has — so the converted file was the only model in the
    /// building Khayt did not know about.
    ///
    /// Read as source because the conversion opens an NSSavePanel, which a test
    /// cannot answer. What is checked is the three things that would each have
    /// left the feature half-done: that the import is called at all, that it
    /// does not take the file away from the folder the shop just chose, and
    /// that a failed import does not report itself as a failed conversion.
    @Test("a converted file is put into the library, not only into a folder")
    func conversionReachesTheLibrary() {
        let shop = MenuCoverageTests.source("Shop.swift")
        #expect(!shop.isEmpty, "Shop.swift moved")

        #expect(shop.contains("LibraryImport.add(destination, shop: self, keepOriginal: true)"),
                "a conversion still ends at a file nothing in the app knows about")
        #expect(shop.contains("mac.converted_into_library"),
                "the shop is not told the library has it")
        // The save panel put the file where the shop asked. An import that moves
        // it would take it away again.
        #expect(!shop.contains("LibraryImport.add(destination, shop: self)"),
                "the import would MOVE the converted file out of the folder the shop chose")
    }

    /// Replacing the original PUTS IT ASIDE. It does not delete it.
    ///
    /// A job printed six months ago was printed from the original's bytes.
    /// Deleting them so the converted file could take the record's place would
    /// make that job appear to have been printed from a file it never saw, and
    /// a book that misreports its own history is worse than a library with one
    /// extra thing in it.
    @Test("replacing the original archives it rather than deleting it")
    func replacingArchives() {
        let shop = MenuCoverageTests.source("Shop.swift")
        #expect(shop.contains("func supersede("), "there is no way to put a model aside")
        #expect(shop.contains("record[\"archivedAt\"] = .string(now)"))
        #expect(shop.contains("record[\"supersededBy\"] = .string(replacement)"),
                "a put-aside model does not say what replaced it")
        // Nothing removes the record or the file.
        #expect(!shop.contains("removeItem(at: source)"),
                "replacing an original must not delete anything")
        // And it can be undone.
        #expect(shop.contains("func unarchive("), "a one-way door")
    }

    @Test("a model is only put aside once its replacement is really in the library")
    func asideOnlyAfterTheReplacementLands() {
        let shop = MenuCoverageTests.source("Shop.swift")
        #expect(shop.contains("if replaceOriginal, landed,"),
                "the original could be put aside for a file the library does not have")
    }

    @Test("a put-aside model leaves the library list but not the book")
    func archivedIsHiddenNotGone() {
        let shop = MenuCoverageTests.source("Shop.swift")
        #expect(shop.contains("if !libraryShowArchived { rows = rows.filter { !$0.isArchived } }"),
                "the library still offers a model that has been replaced")
        // `files` itself keeps them: the import dedupe, the product links and
        // the job records all read it, and a model vanishing from there would
        // let the same bytes be imported again as a new model.
        #expect(shop.contains("private(set) var files: [LibraryFile] = []"))
        #expect(shop.contains("var archivedCount: Int"),
                "nothing can tell the shop where a model went")
    }

    @Test("the choice is made before the work, not after")
    func askedInTheSavePanel() {
        let shop = MenuCoverageTests.source("Shop.swift")
        #expect(shop.contains("panel.accessoryView = holder"),
                "the question is asked somewhere other than the panel that asks where it goes")
        #expect(shop.contains("replace.state = .off"),
                "replacing must not be the default; keeping both is what loses nothing")
    }

    @Test("a failed import is not reported as a failed conversion")
    func aFailedImportIsItsOwnSentence() {
        let shop = MenuCoverageTests.source("Shop.swift")
        // The note is chosen by whether the import landed, so a conversion that
        // saved and failed to import cannot claim the library has it.
        #expect(shop.contains("words.callIt(landed ? \"mac.converted_into_library\" : \"mac.converted\""),
                "a conversion that saved but did not import says the wrong thing")
    }

    static let model = "<?xml version=\"1.0\"?><model unit=\"millimeter\">"
        + "<resources><object id=\"1\"/></resources></model>"

    static func temp() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-conv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A 3MF with a Prusa config, which is what a retarget rewrites.
    static func threeMF(at url: URL, meshPadding: Int = 0) throws {
        let settings = """
            {"printer_model":"Original Prusa MK4","printer_settings_id":"MK4",\
            "filament_colour":["#FF0000","#00FF00"]}
            """
        // Padding makes the mesh big enough to be passed by name rather than by
        // content, which is the path a real model takes.
        let mesh = model + String(repeating: " ", count: meshPadding)
        try ZipWrite.archive([
            .init("[Content_Types].xml", Data("<Types/>".utf8)),
            .init("_rels/.rels", Data("<Relationships/>".utf8)),
            .init("3D/3dmodel.model", Data(mesh.utf8)),
            .init("Metadata/project_settings.config", Data(settings.utf8)),
        ]).write(to: url)
    }

    /// A Bambu-family 3MF whose triangles carry paint codes, which is what a
    /// colour plan is for.
    static func paintedMF(at url: URL) throws {
        let settings = """
            {"printer_model":"X1C","nozzle_diameter":["0.4"],\
            "filament_colour":["#FF0000","#00FF00","#0000FF","#FFFF00","#FF00FF","#00FFFF"],\
            "filament_type":["PLA","PLA","PLA","PLA","PLA","PLA"]}
            """
        var triangles = ""
        for i in 0..<60 {
            triangles += "<triangle v1=\"\(i)\" v2=\"\(i + 1)\" v3=\"\(i + 2)\" "
                + "paint_color=\"\(String(i % 6 + 1, radix: 16))\"/>"
        }
        var vertices = ""
        for i in 0..<64 { vertices += "<vertex x=\"\(i)\" y=\"\(i * 2)\" z=\"0\"/>" }
        let mesh = "<?xml version=\"1.0\"?><model unit=\"millimeter\"><resources>"
            + "<object id=\"1\" type=\"model\"><mesh><vertices>\(vertices)</vertices>"
            + "<triangles>\(triangles)</triangles></mesh></object></resources>"
            + "<build><item objectid=\"1\" transform=\"1 0 0 0 1 0 0 0 1 128 128 0\"/></build></model>"
        try ZipWrite.archive([
            .init("[Content_Types].xml", Data("<Types/>".utf8)),
            .init("3D/3dmodel.model", Data(mesh.utf8)),
            .init("Metadata/project_settings.config", Data(settings.utf8)),
        ]).write(to: url)
    }

    static func engine() throws -> KhaytEngine { try KhaytEngine() }

    @Test("a 3MF converts, and comes back a readable 3MF")
    func roundTrip() async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "in.3mf")
        let out = dir.appending(path: "out.3mf")
        try Self.threeMF(at: source)

        let result = try await Converter.convert(
            source, into: out,
            options: ["targetId": .string("snapmaker-u1")], engine: try Self.engine())
        #expect(FileManager.default.fileExists(atPath: result.url.path))

        let entries = try Zip.entries(of: out)
        #expect(entries.contains { $0.name == "3D/3dmodel.model" })
        #expect(entries.contains { $0.name == "[Content_Types].xml" })
    }

    /// THE GUARANTEE. A conversion rewrites metadata and nothing else; the mesh
    /// that comes out is the mesh that went in, to the byte. A converted file
    /// that prints something other than the model chosen is the one failure
    /// this whole design is arranged around.
    @Test("the geometry is byte-identical, and never crosses into the engine")
    func geometryUntouched() async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "in.3mf")
        let out = dir.appending(path: "out.3mf")
        // Bigger than the inline limit, so it is passed by name — the path a
        // real mesh takes, and the one where a mistake would lose it.
        try Self.threeMF(at: source, meshPadding: Converter.inlineLimit + 1024)

        _ = try await Converter.convert(source, into: out,
                                        options: ["targetId": .string("snapmaker-u1")],
                                        engine: try Self.engine())

        // EVERY member that is not a config, not just the one named
        // `3D/3dmodel.model`. On a real file that one is the CONTAINER — 1,544
        // bytes of a six-megabyte model — and it references the actual meshes
        // beside it, so checking it alone checks almost nothing. Run against
        // the shop's own Forest Dragon this walks twelve members and 44 MB.
        let written = try Zip.entries(of: out)
        var checked = 0
        for entry in try Zip.entries(of: source)
        where !entry.name.lowercased().hasSuffix(".config") {
            let after = try #require(written.first { $0.name == entry.name },
                                     "\(entry.name) is missing from the converted file")
            let a = try Zip.data(of: entry, in: source, limit: .max)
            let b = try Zip.data(of: after, in: out, limit: .max)
            #expect(a == b, "\(entry.name) changed: \(a.count) bytes in, \(b.count) out")
            checked += 1
        }
        #expect(checked >= 3, "only \(checked) member(s) were compared")
    }

    /// The config IS rewritten, or nothing was converted and the test above
    /// would pass on a file that was merely copied.
    @Test("the config is rewritten for the target")
    func configRewritten() async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "in.3mf")
        let out = dir.appending(path: "out.3mf")
        try Self.threeMF(at: source)

        _ = try await Converter.convert(source, into: out,
                                        options: ["targetId": .string("snapmaker-u1")],
                                        engine: try Self.engine())
        let entry = try #require(try Zip.entries(of: out)
            .first { $0.name == "Metadata/project_settings.config" })
        let text = String(decoding: try Zip.data(of: entry, in: out), as: UTF8.self)
        #expect(!text.contains("Original Prusa MK4"), "the source printer survived the retarget")
    }

    /// A colour plan rewrites the paint codec inside the mesh, so for those
    /// two options the `.model` members come in with their bytes. This used to
    /// be refused outright and the shop sent to the other app.
    @Test("a colour plan runs here now, on a mesh small enough to bring in")
    func runsPaintPlans() async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "in.3mf")
        try Self.threeMF(at: source)

        for option in ["fullSpectrum", "bandSwap"] {
            let out = dir.appending(path: "out-\(option).3mf")
            _ = try await Converter.convert(
                source, into: out,
                options: ["targetId": .string("snapmaker-u1"), option: .bool(true)],
                engine: try Self.engine())
            #expect(FileManager.default.fileExists(atPath: out.path),
                    "\(option) produced no file")
        }
    }

    /// AND IT IS STILL REFUSED WHEN IT HAS TO BE — by size, with the size said.
    ///
    /// "Too large" on its own is a wall. A shop told which member and how big
    /// it is can see that a plain retarget of the same file still works, which
    /// is true and is the next thing it would want.
    @Test("a mesh past the colour-plan limit is refused by name and by size")
    func refusesAMeshTooBig() async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "huge.3mf")
        // Lowered rather than met: proving the gate does not require writing a
        // quarter of a gigabyte to disk on every run.
        let real = Converter.paintInlineLimit
        Converter.paintInlineLimit = 64 << 10
        defer { Converter.paintInlineLimit = real }
        try Self.threeMF(at: source, meshPadding: 128 << 10)

        await #expect(throws: Converter.Failure.self) {
            _ = try await Converter.convert(
                source, into: dir.appending(path: "out.3mf"),
                options: ["targetId": .string("snapmaker-u1"), "fullSpectrum": .bool(true)],
                engine: try Self.engine())
        }
        // The same file, without a colour plan, still converts — which is what
        // the refusal tells the shop to do.
        let plain = dir.appending(path: "plain.3mf")
        _ = try await Converter.convert(source, into: plain,
                                        options: ["targetId": .string("snapmaker-u1")],
                                        engine: try Self.engine())
        #expect(FileManager.default.fileExists(atPath: plain.path),
                "the advice in the refusal does not work")
    }

    /// A COLOUR PLAN REWRITES THE PAINT AND NOTHING ELSE.
    ///
    /// This is the guarantee that replaces "the mesh never crosses". It has
    /// to: a colour plan exists to change `paint_color`, so the old promise —
    /// the model comes out byte-identical — cannot hold for these two
    /// options. What must still hold is that EVERYTHING ELSE in the mesh is
    /// untouched: the same vertices, the same triangles, in the same order.
    ///
    /// Proven by taking the paint attributes out of both sides and requiring
    /// what is left to match exactly. A conversion that dropped a triangle,
    /// reordered the vertices or rewrote a coordinate fails here even though
    /// the file would still open.
    @Test("a colour plan changes the paint and leaves the geometry alone")
    func paintOnlyTouchesPaint() async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "painted.3mf")
        let out = dir.appending(path: "out.3mf")
        try Self.paintedMF(at: source)

        _ = try await Converter.convert(
            source, into: out,
            options: ["targetId": .string("snapmaker-u1"), "fullSpectrum": .bool(true)],
            engine: try Self.engine())

        func modelText(_ url: URL) throws -> String {
            let entry = try #require(try Zip.entries(of: url).first { $0.name == "3D/3dmodel.model" })
            return String(decoding: try Zip.data(of: entry, in: url, limit: .max), as: UTF8.self)
        }
        let before = try modelText(source), after = try modelText(out)

        // The paint really moved — otherwise everything below passes on a copy.
        #expect(before != after, "the colour plan changed nothing at all")

        let strip = { (t: String) in
            t.replacingOccurrences(of: #"\s*paint_color="[0-9A-Fa-f]+""#,
                                   with: "", options: .regularExpression)
        }
        #expect(strip(before) == strip(after),
                "the colour plan changed something other than the paint")
    }

    /// The message says the megabytes, and says the same number the limit is.
    @Test("the refusal quotes the real limit")
    func refusalQuotesTheLimit() {
        let said = Converter.Failure.meshTooBig("3D/3dmodel.model", bytes: 64 << 20).description
        #expect(said.contains("3D/3dmodel.model"), "it does not say which member")
        #expect(said.contains("64 MB"), "it does not say how big: \(said)")
        #expect(said.contains("\(Converter.paintLimitMB) MB"), "it does not say the limit: \(said)")
    }

    // ── THE PLATES, AND THE ONE PART OF THE MESH THAT IS A DECISION ───────
    //
    // A multi-plate file lays its objects out in one world grid built from the
    // SOURCE bed. Converted for a bed of another size, that grid no longer
    // matches and the plates drift — so the rule re-places each item, which
    // means reading the `<build>` block inside the root model.
    //
    // That member is the mesh, and the mesh is passed by name. The rule read
    // its bytes anyway and the conversion died with "undefined is not an
    // object" — for every same-family retarget to a different bed, whether or
    // not the file had a second plate. Nothing here caught it because this
    // file's fixture declares no `printable_area`, so the source bed was
    // unknown and the re-tile was never reached.

    /// Two plates, a declared bed, and a mesh big enough to be passed by name.
    static func multiPlate(at url: URL, meshPadding: Int) throws {
        let settings = """
            {"printer_model":"X1C","nozzle_diameter":["0.4"],\
            "printable_area":["0x0","256x0","256x256","0x256"],\
            "filament_colour":["#FF0000"],"filament_type":["PLA"]}
            """
        let plates = """
            <?xml version="1.0"?><config>
            <plate><metadata key="plater_id" value="1"/><model_instance>\
            <metadata key="object_id" value="2"/></model_instance></plate>
            <plate><metadata key="plater_id" value="2"/><model_instance>\
            <metadata key="object_id" value="4"/></model_instance></plate>
            </config>
            """
        // The padding stands in for triangles: it is what makes this member too
        // big to inline, which is the whole point of the test.
        let mesh = "<?xml version=\"1.0\"?><model unit=\"millimeter\"><resources>"
            + "<object id=\"2\"/><object id=\"4\"/>"
            + String(repeating: " ", count: meshPadding)
            + "</resources><build>"
            + "<item objectid=\"2\" transform=\"1 0 0 0 1 0 0 0 1 128 128 0\"/>"
            + "<item objectid=\"4\" transform=\"1 0 0 0 1 0 0 0 1 435 128 0\"/>"
            + "</build></model>"
        try ZipWrite.archive([
            .init("[Content_Types].xml", Data("<Types/>".utf8)),
            .init("3D/3dmodel.model", Data(mesh.utf8)),
            .init("Metadata/project_settings.config", Data(settings.utf8)),
            .init("Metadata/model_settings.config", Data(plates.utf8)),
        ]).write(to: url)
    }

    @Test("a multi-plate file converts for a different bed, mesh and all")
    func plateLayoutIsRetiled() async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "plates.3mf")
        let out = dir.appending(path: "out.3mf")
        try Self.multiPlate(at: source, meshPadding: Converter.inlineLimit + 1024)

        // It ran at all. Before, this threw the engine's TypeError.
        _ = try await Converter.convert(source, into: out,
                                        options: ["targetId": .string("snapmaker-u1")],
                                        engine: try Self.engine())

        let entry = try #require(try Zip.entries(of: out).first { $0.name == "3D/3dmodel.model" })
        let after = try Zip.data(of: entry, in: out, limit: .max)
        let text = String(decoding: after, as: UTF8.self)

        // The layout moved: 128 was the source bed's centre and is not the
        // target's. A file copied through unchanged passes nothing here.
        #expect(!text.contains("transform=\"1 0 0 0 1 0 0 0 1 128 128 0\""),
                "the plates were left on the source bed's grid")
        #expect(text.contains("<item objectid=\"2\""), "an item went missing from the build")
        #expect(text.contains("<item objectid=\"4\""), "an item went missing from the build")

        // AND THE MESH SURVIVED. The block is spliced back into the original
        // bytes, so everything either side of it must be what it was — this is
        // the guarantee the whole design is arranged around, and a splice at
        // the wrong offset would quietly cut the model in half.
        let before = try Zip.data(
            of: try #require(try Zip.entries(of: source).first { $0.name == "3D/3dmodel.model" }),
            in: source, limit: .max)
        let head = try #require(Converter.buildBlockRange(in: before))
        let tail = try #require(Converter.buildBlockRange(in: after))
        #expect(before[..<head.lowerBound] == after[..<tail.lowerBound],
                "the bytes before the layout changed")
        #expect(Data(before[head.upperBound...]) == Data(after[tail.upperBound...]),
                "the bytes after the layout changed")
    }

    @Test("the build block is found by its own name, not by a prefix")
    func buildBlockIsNotAPrefixMatch() {
        // `<buildinfo` is not `<build`, and a range taken from it would splice
        // a rewritten layout over the wrong bytes.
        let decoy = Data("<buildinfo who=\"orca\"/><build><item/></build>".utf8)
        let range = try? #require(Converter.buildBlockRange(in: decoy))
        let found = String(decoding: decoy[range!], as: UTF8.self)
        #expect(found == "<build><item/></build>", "found \(found)")

        // A file with no build block at all is a file with no layout, not a
        // failure: nil, and the conversion goes on without re-tiling.
        #expect(Converter.buildBlockRange(in: Data("<model><build/></model>".utf8)) == nil)
    }

    @Test("something that is not a 3MF is refused, not written")
    func refusesRubbish() async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "notes.3mf")
        let out = dir.appending(path: "out.3mf")
        try Data("this is not a container".utf8).write(to: source)

        await #expect(throws: Converter.Failure.self) {
            _ = try await Converter.convert(source, into: out,
                                            options: ["targetId": .string("snapmaker-u1")],
                                            engine: try Self.engine())
        }
        #expect(!FileManager.default.fileExists(atPath: out.path), "it wrote a file anyway")
    }
}
