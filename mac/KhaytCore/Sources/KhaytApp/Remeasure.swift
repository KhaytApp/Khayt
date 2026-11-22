import Foundation
import KhaytCore

/// Measuring the library's 3MFs again, under the reader as it is now.
///
/// A key is written once, on import, and nothing re-reads a file that has
/// one. Right for the ordinary case — and exactly what strands a book when a
/// reader fault is fixed: every record the old reader wrote keeps the number
/// the shop was shown, and that number was wrong. So each record names the
/// reader that measured it (`lib/geometry-key.js` READER, on the record as
/// `geometryReader`), and a record below that is due. The app runs this once
/// per book after it opens (`Shop.remeasureIfDue`) for the due files only;
/// `Khayt --import --remeasure` runs it for every 3MF, on demand.
///
/// Both write the same thing: the keys that changed, and the reader's number
/// on everything that was read — so a due file that turns out to have been
/// right is not read again either. A file that is not in the library folder
/// is left exactly as it was: absent is not unreadable, and a share that is
/// not mounted tonight may be tomorrow.
enum Remeasure {
    struct Change: Sendable {
        let file: LibraryFile
        let was: String
        let now: String
    }

    struct Report: Sendable {
        /// Record ids that were read — with or without a mesh coming back.
        var measured: [String] = []
        var changed: [Change] = []
        /// Titles: on disk, but no mesh could be read from them.
        var unreadable: [String] = []
        /// Titles: not in the library folder at all.
        var missing: [String] = []

        var keys: [String: String] {
            Dictionary(changed.map { ($0.file.id, $0.now) }, uniquingKeysWith: { _, last in last })
        }
    }

    static func is3MF(_ file: LibraryFile) -> Bool {
        (file.sourceFile?.ext ?? "").lowercased() == "3mf"
    }

    /// The 3MFs the app reads again on its own: measured by an older reader,
    /// or by none the record can name.
    static func due(_ files: [LibraryFile], engine: KhaytEngine) async -> [LibraryFile] {
        var out: [LibraryFile] = []
        for file in files where is3MF(file) {
            if (try? await engine.needsRemeasure(reader: file.geometryReader)) ?? false {
                out.append(file)
            }
        }
        return out
    }

    /// Reads every file in `wanted` from `vault` and says what would change.
    /// Writes nothing; `apply` is the write.
    static func measure(_ wanted: [LibraryFile], vault: URL, engine: KhaytEngine,
                        progress: (@MainActor (Int, Int, LibraryFile) -> Void)? = nil) async -> Report {
        var report = Report()
        for (i, file) in wanted.enumerated() {
            guard let name = file.sourceFile?.filename else { continue }
            let model = vault.appending(path: LibraryLocation.itemDirName(file.id))
                             .appending(path: name)
            await progress?(i + 1, wanted.count, file)
            guard FileManager.default.fileExists(atPath: model.path) else {
                report.missing.append(file.title); continue
            }
            report.measured.append(file.id)
            guard let box = try? Mesh.measure3MF(model), box.triangleCount > 0,
                  let key = try? await engine.geometryKey(triangleCount: box.triangleCount,
                                                          volumeMm3: box.volumeMm3,
                                                          x: box.x, y: box.y, z: box.z) else {
                report.unreadable.append(file.title); continue
            }
            let was = file.geometryKey ?? ""
            if was != key { report.changed.append(Change(file: file, was: was, now: key)) }
        }
        return report
    }

    /// The write: a changed key replaces the old one and the record is
    /// stamped, so the correction reaches the shop's other devices; every
    /// record that was read gets the reader's number, stamped or not. Records
    /// that were not read are not touched.
    static func apply(_ report: Report, reader: Int, to root: inout [String: JSONValue]) {
        guard case .array(let rows)? = root["printFiles"] else { return }
        let keys = report.keys
        let read = Set(report.measured)
        root["printFiles"] = .array(rows.map { row in
            guard case .object(var o) = row, case .string(let id)? = o["id"], read.contains(id) else {
                return row
            }
            if let key = keys[id] {
                o["geometryKey"] = .string(key)
                StoreWriter.stamp(&o)
            }
            o["geometryReader"] = .number(Double(reader))
            return .object(o)
        })
    }
}
