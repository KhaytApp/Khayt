import Foundation
import KhaytCore

/// Reading again the colours an older reader wrote.
///
/// Until reader 2 (#2500, Nov 16 2026) an unsliced 3MF's colours were the
/// printer's LOADED spools: Turki's vegueta stores eight dots and prints in
/// five, his Tororo stores four and prints in three. A record names the
/// reader that wrote its colours (`coloursReader`); one below today's is read
/// again here, once per book per launch, where its file is on this Mac. The
/// desktop does the same (`renderer/printfiles.js sweepColours`), and both
/// put the read on the record by one rule, `KhaytThumb.applyColours`: a read
/// that cannot name the slots stamps the reader and leaves the colours, so a
/// re-read never empties what was there.
///
/// A file that is not here (a vault on another Mac, a linked Drive model not
/// downloaded) is left exactly as it was and read when it is here: reading it
/// would be downloading it.
enum ColoursReread {

    static func is3MF(_ file: LibraryFile) -> Bool {
        (file.sourceFile?.ext ?? "").lowercased() == "3mf"
    }

    /// The 3MFs whose colours an older reader wrote, or none it can name.
    static func due(_ files: [LibraryFile], reader: Int) -> [LibraryFile] {
        files.filter { is3MF($0) && ($0.coloursReader ?? 0) < reader }
    }

    /// The four fields a colour read may change. Only these are written, onto
    /// the record as read inside the write, so an edit that landed meanwhile
    /// is kept.
    static let fields = ["colors", "swapCount", "coloursReader", "swapsKnown"]

    /// `rows` with each id in `patches` given its patched colour fields.
    /// Records not in `patches` are untouched.
    nonisolated static func apply(_ patches: [String: [String: JSONValue]],
                                  to rows: [JSONValue]) -> [JSONValue] {
        rows.map { row in
            guard case .object(var o) = row, case .string(let id)? = o["id"],
                  let patch = patches[id] else { return row }
            for k in fields {
                if let v = patch[k] { o[k] = v } else { o.removeValue(forKey: k) }
            }
            return .object(o)
        }
    }
}

extension Shop {

    /// Read again, once per book per launch, the 3MFs whose colours an older
    /// reader wrote. Started from `remeasureIfDue`, beside the geometry
    /// re-read, on the same terms: background, one write at the end, nothing
    /// for the sample book.
    func rereadColoursIfDue(build: StoreReader.Build, engine: KhaytEngine) {
        let files = self.files
        let rows = libraryShownRows
        Task(priority: .utility) { [weak self] in
            guard let reader = try? await engine.coloursReader() else { return }
            let due = ColoursReread.due(files, reader: reader)
            guard !due.isEmpty, let self else { return }
            var raw: [String: [String: JSONValue]] = [:]
            for case .object(let o) in rows { if case .string(let id)? = o["id"] { raw[id] = o } }
            var patches: [String: [String: JSONValue]] = [:]
            for file in due {
                guard let url = self.modelFile(for: file), let record = raw[file.id] else { continue }
                if file.isLinked, LinkedCloud.isOnlineOnly(url) { continue }
                guard FileManager.default.fileExists(atPath: url.path),
                      let entries = await PinWork.run({ try? Zip.entries(of: url) }),
                      let read = await ColourRead.colours(url, entries: entries, engine: engine),
                      let applied = try? await engine.applyColours(record, read: read),
                      applied.changed else { continue }
                var patch: [String: JSONValue] = [:]
                for k in ColoursReread.fields { if let v = applied.record[k] { patch[k] = v } }
                patches[file.id] = patch
            }
            guard !patches.isEmpty else { return }
            let sending = patches
            do {
                // lock: system — background: colours re-read because the colour rule changed (reader 2).
                try await StoreWriter.updateOffMain(
                    storeURL: build.storeURL,
                    owns: { StoreLock.weOwnIt(build) },
                    whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
                ) { root in
                    guard case .array(let rows)? = root["printFiles"] else { return }
                    root["printFiles"] = .array(ColoursReread.apply(sending, to: rows))
                }
            } catch {
                // Not ours, or the disk refused: nothing was stamped, so the
                // same files are due at the next launch.
                return
            }
            await self.load(self.source)
        }
    }
}
