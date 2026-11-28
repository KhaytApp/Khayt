import Foundation
import KhaytCore

/// A model with no settings of its own, made into a project 3MF before an Orca
/// fork slices it (`lib/slicer-project.js`).
///
/// ── WHY ─────────────────────────────────────────────────────────────────────
///
/// Snapmaker Orca 2.4.1's command line segfaults whenever presets are handed to
/// it by flag (`--load-settings`, with or without `--load-filaments`), its own
/// bundled presets included: exit 139 in under a second, no G-code. That was
/// every U1 slice of an STL from Khayt (a shop saw "signal 11", Nov 27 2026),
/// and it was ours: the same slicer slices a project 3MF that carries its own
/// settings. So a model that needs presets is never sliced with preset flags.
/// It becomes a project here, and the slice runs with the plain `--slice 0`.
///
/// The rule decides what to do and builds the settings (`plan`,
/// `projectSettingsJson`, `bedCentre`/`offsetFor`). The MESH is written here,
/// streamed, because a binary STL can be hundreds of megabytes and must not be
/// carried into JavaScript to be rewritten. `SlicerProjectParityTests` holds
/// this writer's XML to the rule's `modelXml`, character for character.
enum SlicerProject {

    /// What the slice runs on, and why not, when it cannot.
    struct Prepared: Equatable {
        /// The file to slice: the model itself, or the project made from it.
        var model: URL
        /// Said to the shop when no project could be made (the slice is still
        /// attempted on the model, as before).
        var problem: String?
    }

    // MARK: - The mesh, as the rule writes it

    /// The rule's `num`: JavaScript's `Math.round` (half up), four decimals,
    /// no trailing zeros, no "-0".
    nonisolated static func num(_ v: Double) -> String {
        let r = (v * 10000 + 0.5).rounded(.down) / 10000
        var s = String(format: "%.4f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    /// The rule's `meshWriter`: fed one triangle at a time, shared vertices
    /// written once, a triangle that collapses after rounding dropped (adding
    /// no vertex).
    final class MeshWriter {
        private let d: (Double, Double, Double)
        private var index: [String: Int32] = [:]
        private var verts: [String] = []
        private var faces: [Int32] = []

        init(offset: [Double]) {
            d = (offset.count > 0 ? offset[0] : 0, offset.count > 1 ? offset[1] : 0, offset.count > 2 ? offset[2] : 0)
        }

        var vertexCount: Int { verts.count }
        var triangleCount: Int { faces.count / 3 }

        private func key(_ x: Double, _ y: Double, _ z: Double) -> String {
            SlicerProject.num(x + d.0) + " " + SlicerProject.num(y + d.1) + " " + SlicerProject.num(z + d.2)
        }

        @discardableResult
        func add(_ ax: Double, _ ay: Double, _ az: Double, _ bx: Double, _ by: Double, _ bz: Double,
                 _ cx: Double, _ cy: Double, _ cz: Double) -> Bool {
            let k = [key(ax, ay, az), key(bx, by, bz), key(cx, cy, cz)]
            if k[0] == k[1] || k[1] == k[2] || k[0] == k[2] { return false }
            for s in k {
                if let i = index[s] { faces.append(i); continue }
                let i = Int32(verts.count)
                index[s] = i
                verts.append(s)
                faces.append(i)
            }
            return true
        }

        /// The whole model member. `head` and `tail` are the rule's own.
        func xml(head: String, tail: String) -> Data {
            var out = Data()
            out.reserveCapacity(verts.count * 48 + faces.count * 14 + 1024)
            out.append(Data(head.utf8))
            out.append(Data("<vertices>\n".utf8))
            for s in verts {
                let p = s.split(separator: " ")
                out.append(Data("<vertex x=\"\(p[0])\" y=\"\(p[1])\" z=\"\(p[2])\"/>\n".utf8))
            }
            out.append(Data("</vertices>\n<triangles>\n".utf8))
            var i = 0
            while i + 2 < faces.count {
                out.append(Data("<triangle v1=\"\(faces[i])\" v2=\"\(faces[i + 1])\" v3=\"\(faces[i + 2])\"/>\n".utf8))
                i += 3
            }
            out.append(Data("</triangles>\n".utf8))
            out.append(Data(tail.utf8))
            return out
        }
    }

    // MARK: - The project

    /// The biggest STL made into a project, like the other print-file budgets
    /// (a mesh this size takes minutes to slice in any case).
    nonisolated static let stlLimit = 150 << 20

    /// A model that needs presets, as a project 3MF in `outDir` with the
    /// shop's chosen presets inside; or the model as it is, with the reason
    /// when nothing could be done. `presets` is the rule's choice
    /// (`choosePresets`: machine, process, filament).
    static func prepare(_ model: URL, plan: String, machine: JSONValue, process: JSONValue, filament: JSONValue,
                        engine: KhaytEngine, outDir: URL) async -> Prepared {
        let settings: String
        do { settings = try await engine.projectSettingsJson(machine: machine, process: process, filament: filament) }
        catch { return Prepared(model: model, problem: nil) }
        let out = outDir.appending(path: "khayt-project.3mf")
        do {
            switch plan {
            case "add-config":
                try addConfig(to: model, settings: settings, writing: out)
            case "stl":
                guard let size = (try? FileManager.default.attributesOfItem(atPath: model.path))?[.size] as? Int,
                      size <= stlLimit else {
                    return Prepared(model: model, problem: "This STL is too large to slice from Khayt. Open it in the slicer itself.")
                }
                try await stlProject(model, settings: settings, machine: machine, engine: engine, writing: out)
            default:
                return Prepared(model: model, problem: plan == "unsupported"
                                ? "Khayt can slice an STL or a 3MF with this slicer. Open this file in the slicer itself." : nil)
            }
        } catch {
            return Prepared(model: model, problem: "Khayt could not prepare this model for the slicer: \(ErrorText.plain(error))")
        }
        return Prepared(model: out, problem: nil)
    }

    /// A 3MF with no project settings: the same members, byte for byte, and the settings added.
    static func addConfig(to model: URL, settings: String, writing out: URL, limit: Int = 512 << 20) throws {
        var members: [ZipWrite.Member] = []
        var total = 0
        for entry in try Zip.entries(of: model) {
            let name = entry.name
            guard !name.contains(".."), !name.hasPrefix("/") else { continue }
            guard name.caseInsensitiveCompare(configMember) != .orderedSame else { continue }
            total += entry.size
            guard total <= limit else { throw SlicerRun.Failure.missingModel }
            members.append(ZipWrite.Member(name, try Zip.data(of: entry, in: model, limit: limit)))
        }
        members.append(ZipWrite.Member(configMember, Data(settings.utf8)))
        try ZipWrite.archive(members).write(to: out, options: .atomic)
    }

    /// An STL as a project: measured, then streamed into the writer, standing on the bed.
    static func stlProject(_ model: URL, settings: String, machine: JSONValue, engine: KhaytEngine,
                           writing out: URL) async throws {
        guard let m = try Mesh.measureSTL(model), m.triangleCount > 0 else { throw SlicerRun.Failure.missingModel }
        let offset = try await engine.slicerProjectOffset(min: [m.minX, m.minY, m.minZ], max: [m.maxX, m.maxY, m.maxZ],
                                                         machine: machine)
        let writer = MeshWriter(offset: offset)
        let add: (Double, Double, Double, Double, Double, Double, Double, Double, Double) -> Void = { ax, ay, az, bx, by, bz, cx, cy, cz in
            writer.add(ax, ay, az, bx, by, bz, cx, cy, cz)
        }
        if try !Mesh.eachSTLTriangle(model, add) {
            var reader = Mesh.AsciiSTLReader()
            guard Mesh.eachLine(of: model, { line in reader.line(line, add) }) else { throw SlicerRun.Failure.missingModel }
        }
        guard writer.triangleCount > 0 else { throw SlicerRun.Failure.missingModel }
        let members = [
            ZipWrite.Member("[Content_Types].xml", Data(contentTypes.utf8)),
            ZipWrite.Member("_rels/.rels", Data(rels.utf8)),
            ZipWrite.Member("3D/3dmodel.model", writer.xml(head: modelHead, tail: modelTail)),
            ZipWrite.Member(configMember, Data(settings.utf8)),
        ]
        try ZipWrite.archive(members).write(to: out, options: .atomic)
    }

    // The rule's fixed texts (`lib/slicer-project.js`). `SlicerProjectParityTests`
    // reads the rule's values and fails when these drift.
    nonisolated static let configMember = "Metadata/project_settings.config"
    nonisolated static let contentTypes = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        + "<Default Extension=\"model\" ContentType=\"application/vnd.ms-package.3dmanufacturing-3dmodel+xml\"/>"
        + "</Types>"
    nonisolated static let rels = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        + "<Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/>"
        + "</Relationships>"
    nonisolated static let modelHead = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        + "<model unit=\"millimeter\" xml:lang=\"en-US\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">\n"
        + "<resources>\n<object id=\"1\" type=\"model\">\n<mesh>\n"
    nonisolated static let modelTail = "</mesh>\n</object>\n</resources>\n<build>\n<item objectid=\"1\"/>\n</build>\n</model>\n"
}
