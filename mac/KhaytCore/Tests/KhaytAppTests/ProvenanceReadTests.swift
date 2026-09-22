import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A model knows who made it, and this app never asked.
///
/// ── MEASURED ON THIS SHOP'S OWN VAULT ─────────────────────────────────────
///
/// Ninety 3MF files. Every one carries `<metadata>`; twenty-one carry a
/// designer or a licence somebody typed at the other end; THREE are BY-NC-SA,
/// which `lib/model-licence.js` exists to say cannot be sold. Khayt recorded a
/// licence only when a person opened a menu, so all of that sat unread in a
/// library the shop sells prints from.
///
/// These tests run on FIXTURES built here rather than on that vault — a test
/// that reads a folder on one Mac is a test that passes on one Mac — but the
/// fixtures are the exact shapes the vault turned out to hold.
@MainActor
struct ProvenanceReadTests {

    /// A 3MF is a zip with the model part at a fixed path. Built by hand so
    /// the fixture is the file format and not a library's idea of it.
    static func make3MF(metadata: String, in folder: URL, named: String) throws -> URL {
        let part = """
            <?xml version="1.0" encoding="UTF-8"?>
            <model unit="millimeter" xml:lang="en-US">
            \(metadata)
             <resources>
              <object id="1" type="model"><mesh><vertices/><triangles/></mesh></object>
             </resources>
             <build><item objectid="1"/></build>
            </model>
            """
        let staging = folder.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: staging.appending(path: "3D"), withIntermediateDirectories: true)
        try part.write(to: staging.appending(path: "3D/3dmodel.model"),
                       atomically: true, encoding: .utf8)
        let out = folder.appending(path: named)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", out.path, "3D"]
        zip.currentDirectoryURL = staging
        try zip.run(); zip.waitUntilExit()
        return out
    }

    static func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a model that names its designer and licence is read")
    func readsWhatTheFileSays() throws {
        let dir = try Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.make3MF(metadata: """
             <metadata name="Title">Flexi Spiky Koi Fish</metadata>
             <metadata name="Designer">OverdoseCreative</metadata>
             <metadata name="License">BY-NC-SA</metadata>
             <metadata name="Application">BambuStudio-01.10.02.76</metadata>
            """, in: dir, named: "koi.3mf")
        let said = try #require(Mesh.provenance(of: url))
        #expect(said.title == "Flexi Spiky Koi Fish")
        #expect(said.designer == "OverdoseCreative")
        #expect(said.licence == "BY-NC-SA")
        #expect(said.application == "BambuStudio-01.10.02.76")
    }

    /// SIXTY-EIGHT of the vault's files carry `<metadata name="Copyright">[]`.
    /// That is an exporter writing an empty array, not a claim, and putting it
    /// in the book would fill a shop's library with the word "[]".
    @Test("an exporter's empty array is not a fact")
    func emptyArraysAreNotKept() throws {
        let dir = try Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.make3MF(metadata: """
             <metadata name="Designer">[]</metadata>
             <metadata name="License"></metadata>
             <metadata name="Title">   </metadata>
            """, in: dir, named: "empty.3mf")
        #expect(Mesh.provenance(of: url) == nil,
                "a file saying nothing produced a record saying something")
    }

    @Test("the five XML entities come back as characters")
    func escapesAreUndone() throws {
        let dir = try Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.make3MF(metadata: """
             <metadata name="Designer">Tom &amp; Jerry</metadata>
             <metadata name="Title">&quot;Bracket&quot; &lt;v2&gt;</metadata>
            """, in: dir, named: "escaped.3mf")
        let said = try #require(Mesh.provenance(of: url))
        #expect(said.designer == "Tom & Jerry", "the escape reached the book: \(said.designer)")
        #expect(said.title == "\"Bracket\" <v2>")
    }

    /// Not a 3MF, and a 3MF that is not a zip. Neither may throw: this runs
    /// over every file a shop drags in.
    @Test("anything that is not a 3MF is simply nothing")
    func rubbishIsNil() throws {
        let dir = try Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stl = dir.appending(path: "part.stl")
        try Data("solid x\nendsolid x\n".utf8).write(to: stl)
        #expect(Mesh.provenance(of: stl) == nil)
        let fake = dir.appending(path: "broken.3mf")
        try Data("not a zip at all".utf8).write(to: fake)
        #expect(Mesh.provenance(of: fake) == nil)
        #expect(Mesh.provenance(of: dir.appending(path: "missing.3mf")) == nil)
    }
}
