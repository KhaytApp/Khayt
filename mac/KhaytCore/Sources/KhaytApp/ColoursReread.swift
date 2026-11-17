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
/// Thrown from inside a write that turns out to have nothing to write, so the
/// book is not rewritten (and its rollback copy not rolled) for nothing. A
/// StoreWriter write always rewrites the file once its closure returns.
struct NothingToWrite: Error {}

enum ColoursReread {

    static func is3MF(_ file: LibraryFile) -> Bool {
        (file.sourceFile?.ext ?? "").lowercased() == "3mf"
    }

    /// The 3MFs whose colours an older reader wrote, or none it can name; and
    /// those a Mac with a SMALLER paint budget could not read (`budget` is
    /// this Mac's, `Converter.paintInlineLimit`). A file refused here is not
    /// tried again here at every launch; a Mac that can hold it tries it.
    static func due(_ files: [LibraryFile], reader: Int,
                    budget: Int = Converter.paintInlineLimit) -> [LibraryFile] {
        files.filter { f in
            guard is3MF(f) else { return false }
            if (f.coloursReader ?? 0) < reader { return true }
            if let refused = f.coloursUnreadBudget { return refused < budget }
            return false
        }
    }

    /// The five fields a colour read may change. Only these are written, onto
    /// the record as read inside the write, so an edit that landed meanwhile
    /// is kept.
    static let fields = ["colors", "swapCount", "coloursReader", "swapsKnown", "coloursUnreadBudget"]

    /// Records read before what has been read is written (and so survives a
    /// launch cut short). Each write is the whole book (and rolls `.prev`),
    /// so not too often: ten was a whole-book write every few seconds of a
    /// painted library (beta.40 full review).
    static let batch = 100
    /// Between two records, so a book of painted models never runs the CPU flat.
    static let pause: Duration = .milliseconds(150)

    /// One record's re-read: its four colour fields as they were when the
    /// file was read (`was`) and as the rule left them (`now`).
    struct Patch: Sendable {
        var was: [String: JSONValue]
        var now: [String: JSONValue]
    }

    /// A completed read's colour fields, with the budget mark set where the
    /// paint was past this Mac's budget and cleared where the slots were
    /// named. A paint unread for any other reason (no engine, a throw) is not
    /// a read at all: nil, and the record stays due.
    nonisolated static func marked(_ applied: [String: JSONValue], read: ColourRead.Read) -> [String: JSONValue]? {
        var now = colourFields(applied)
        if read.paintUnread {
            guard let budget = read.overBudget else { return nil }
            now["coloursUnreadBudget"] = .number(Double(budget))
        } else {
            now.removeValue(forKey: "coloursUnreadBudget")
        }
        return now
    }

    /// The colour fields of a record, those it has.
    nonisolated static func colourFields(_ o: [String: JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for k in fields { if let v = o[k] { out[k] = v } }
        return out
    }

    /// `rows` with each patched record given its new colour fields, ONLY
    /// where those fields are still what they were when the file was read.
    /// A record whose colours changed meanwhile (a slice's figures read the
    /// same launch, another machine's copy pulled in) is left as it is, and
    /// is due again next launch if its reader is still old. Compare-and-set,
    /// because the re-read takes seconds a file and the book does not wait
    /// (beta.38 review). Returns the rows and how many were written.
    nonisolated static func apply(_ patches: [String: Patch],
                                  to rows: [JSONValue]) -> (rows: [JSONValue], written: Int) {
        var written = 0
        let out = rows.map { row -> JSONValue in
            guard case .object(var o) = row, case .string(let id)? = o["id"],
                  let patch = patches[id], colourFields(o) == patch.was else { return row }
            for k in fields {
                if let v = patch.now[k] { o[k] = v } else { o.removeValue(forKey: k) }
            }
            written += 1
            return .object(o)
        }
        return (out, written)
    }


}

extension Shop {

    /// Read again, once per book per launch, the 3MFs whose colours an older
    /// reader wrote. Started from `remeasureIfDue`, beside the geometry
    /// re-read, on the same terms: background, nothing for the sample book.
    ///
    /// ── NEVER IN THE WAY ─────────────────────────────────────────────────
    ///
    /// A painted mesh takes seconds to decode (the desktop measured up to
    /// ~7 s), and a book can hold hundreds of them. So: one record at a time;
    /// the zip on a dispatch queue (`PinWork`, `Converter.readQueue`) and the
    /// paint on the STUDIO's engine (`StudioEngine.paintSlots`), never the
    /// main thread or the shop's engine that every screen's rules wait on; a
    /// pause between records; and what has been read is written every
    /// `batch` records, each stamped with its reader, so a launch cut short
    /// resumes where it stopped instead of starting again. The screen is
    /// reloaded once, at the end.
    func rereadColoursIfDue(build: StoreReader.Build, engine: KhaytEngine) {
        let files = self.files
        let rows = libraryShownRows
        let roots = libraryRoots?.roots
        let source = self.source
        coloursRereading?.cancel()
        coloursRereading = Task(priority: .utility) { [weak self] in
            guard let reader = try? await engine.coloursReader() else { return }
            let due = ColoursReread.due(files, reader: reader)
            guard !due.isEmpty else { return }
            // ITS OWN studio engine. On the shared one, every Studio window,
            // the 3D viewer and calibration waited behind each painted file
            // for up to a minute while the re-read ran (beta.40 full review).
            // One for the whole pass, let go when it ends.
            guard let studio = await PinWork.run({ try? StudioEngine() }) else { return }
            var raw: [String: [String: JSONValue]] = [:]
            for case .object(let o) in rows { if case .string(let id)? = o["id"] { raw[id] = o } }
            var pending: [String: ColoursReread.Patch] = [:]
            var wroteAny = false
            func writeReadColours() async -> Bool {
                guard !pending.isEmpty else { return true }
                let sending = pending
                do {
                    // lock: system — background: colours re-read because the colour reader changed (reader 4).
                    // NOT STAMPED (`recordingDeletes: false`): what a file is
                    // printed in is read from the file, not an edit, and a
                    // stamped re-read would beat another machine's real edit
                    // to the same record that has not been pulled yet. The
                    // other derived re-reads write the same way (Shop+Library).
                    // NOT ANNOUNCED: nothing here is for another machine, so
                    // the write does not start a sync.
                    try await StoreWriter.updateOffMain(
                        storeURL: build.storeURL,
                        owns: { StoreLock.weOwnIt(build) },
                        whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
                        recordingDeletes: false,
                        announce: false
                    ) { root in
                        guard case .array(let rows)? = root["printFiles"] else { throw NothingToWrite() }
                        let done = ColoursReread.apply(sending, to: rows)
                        guard done.written > 0 else { throw NothingToWrite() }
                        root["printFiles"] = .array(done.rows)
                    }
                } catch is NothingToWrite {
                    pending = [:]
                    return true
                } catch {
                    // Not ours, or the disk refused: what was not written is
                    // still due at the next launch.
                    return false
                }
                pending = [:]
                wroteAny = true
                return true
            }
            /// Still the book this pass began on: a switch of book cancels the
            /// pass (above), and this stops one that is mid-file.
            @MainActor func stillHere() -> Bool {
                guard !Task.isCancelled, let now = self?.source else { return false }
                return now == source
            }
            for file in due {
                guard stillHere() else { break }
                guard let record = raw[file.id] else { continue }
                // Off the main actor: each is a stat per root, a folder listing,
                // and for a linked model an iCloud question (beta.40 full review).
                let linked = file.isLinked
                guard let url = await PinWork.run({ () -> URL? in
                    guard let url = Shop.modelFile(for: file, roots: roots) else { return nil }
                    if linked, LinkedCloud.isOnlineOnly(url) { return nil }
                    return FileManager.default.fileExists(atPath: url.path) ? url : nil
                }) else { continue }
                guard let entries = await PinWork.run({ try? Zip.entries(of: url) }),
                      var read = await ColourRead.read(url, entries: entries, engine: engine, studio: studio)
                else { continue }
                // A completed read is stamped with TODAY's reader, whatever path
                // the rule took: a file whose project settings are not JSON
                // falls to the old loaded-spools answer marked reader 1, and
                // stamped 1 it was due again at every launch, forever (beta.38
                // review). It was read by this reader; that is what the number says.
                if (read.colours.reader ?? 0) < reader { read.colours.reader = reader }
                guard let applied = try? await engine.applyColours(record, read: read.colours),
                      let now = ColoursReread.marked(applied.record, read: read) else { continue }
                let was = ColoursReread.colourFields(record)
                guard now != was else { continue }
                pending[file.id] = ColoursReread.Patch(was: was, now: now)
                if pending.count >= ColoursReread.batch, !(await writeReadColours()) { return }
                try? await Task.sleep(for: ColoursReread.pause)
            }
            // What was read is kept even when the pass was cut short: each
            // record's write is compare-and-set, so a book switched meanwhile
            // is not this one and nothing in it matches.
            guard await writeReadColours(), wroteAny, let self else { return }
            let now = self.source
            guard now == source else { return }
            await self.load(now)
        }
    }
}
