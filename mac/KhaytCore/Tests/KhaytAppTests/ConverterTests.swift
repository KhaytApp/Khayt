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

    /// Said plainly rather than half-done. Full Spectrum and band-swap rewrite
    /// the paint codec inside the mesh, which means the mesh would have to
    /// cross into the engine — the one thing this design exists to avoid.
    @Test("a colour plan that needs the mesh is refused before anything is read")
    func refusesPaintPlans() async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "in.3mf")
        try Self.threeMF(at: source)

        for option in ["fullSpectrum", "bandSwap"] {
            await #expect(throws: Converter.Failure.needsTheMesh) {
                _ = try await Converter.convert(
                    source, into: dir.appending(path: "out.3mf"),
                    options: ["targetId": .string("snapmaker-u1"), option: .bool(true)],
                    engine: try Self.engine())
            }
        }
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
