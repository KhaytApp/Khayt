import Foundation
import KhaytCore

/// Where this computer keeps the printers its scans found
/// (`lib/found-printers.js` is the rule; this is only the file).
///
/// ── THIS COMPUTER'S, NEVER THE BOOK'S ────────────────────────────────────
///
/// `found-printers.json` beside the book, in the app's own folder. It is the
/// SAME file and the same shape the Windows/Linux app keeps
/// (`lib/main/printer-discovery.js`), so on a Mac that runs both, a printer
/// either app found is in the list. It is not in the book: it never syncs,
/// is never handed to a phone, and holds nothing but what unauthenticated
/// devices on the LAN announced about themselves (the rule bounds every
/// string and keeps no TXT dump).
///
/// A file that is missing, cut off or not that shape reads as an empty list: the
/// rule cleans whatever it is given, and the worst a bad file can do is
/// forget.
enum FoundPrintersStore {
    static let fileName = "found-printers.json"
    /// A list of forty bounded entries is a few kilobytes. Anything far
    /// larger is not this file, and is not read into memory.
    static let maxBytes = 512 * 1024

    static func url(_ build: StoreReader.Build) -> URL {
        build.supportFolder.appending(path: "\(build.rawValue)/\(fileName)")
    }

    static func read(_ build: StoreReader.Build) -> JSONValue { readWithBytes(build).list }

    /// The list, and the bytes it was read from: what `rememberFound` compares
    /// just before it writes, to see whether the other app wrote meanwhile.
    static func readWithBytes(_ build: StoreReader.Build) -> (list: JSONValue, bytes: Data?) {
        let file = url(build)
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBytes,
              let data = try? Data(contentsOf: file) else { return (.array([]), nil) }
        return (list(in: data), data)
    }

    private static func list(in data: Data) -> JSONValue {
        guard
              case .object(let file)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let printers)? = file["printers"] else { return .array([]) }
        return .array(printers)
    }

    /// TESTS ONLY: runs between the merge and the write, where the other
    /// app's write can land.
    nonisolated(unsafe) static var beforeWriteForTests: (() -> Void)?
    /// How many times a write that found the file changed starts again.
    static let tries = 4

    /// Whole-file, atomic: a reader never sees half a list.
    static func write(_ list: [JSONValue], _ build: StoreReader.Build) throws {
        // `{ version: 1, printers: [...] }`, as the other app writes it.
        let data = try JSONEncoder().encode(JSONValue.object(["version": .number(1), "printers": .array(list)]))
        try data.write(to: url(build), options: .atomic)
    }

    /// "Forget": the file goes. Nothing to forget is not a failure.
    static func forget(_ build: StoreReader.Build) {
        try? FileManager.default.removeItem(at: url(build))
    }
}

extension Shop {

    /// Add what a scan just saw to this computer's list. Best-effort and
    /// silent: the scan's own result is what the sheet shows, and a list that
    /// could not be saved only means the next scan starts from less.
    func rememberFound(_ found: [KhaytEngine.FoundPrinter], source: String = "mdns", now: Date = Date()) async {
        // lock: system — a note of what a scan the owner started just saw, kept on this computer outside the book; nothing in the book is written.
        guard !found.isEmpty, let engine, let build = source_build else { return }
        let rows: [JSONValue] = found.compactMap { printer in
            guard let data = try? JSONEncoder().encode(printer) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }
        // ── TWO APPS WRITE THIS FILE ──────────────────────────────────────
        //
        // The Windows/Linux app keeps the same list in the same file. Read,
        // merge, and then look again just before writing: if the file is not
        // the bytes that were merged, the other app wrote meanwhile, and the
        // merge is done again on what is there now. Never "mine is newer, so
        // mine replaces yours". The write is a temp file renamed into place,
        // so neither app ever reads half a list. After `tries` rounds of
        // being overtaken this scan is simply not remembered: the next one is.
        let nowMs = (now.timeIntervalSince1970 * 1000).rounded()
        for _ in 0..<FoundPrintersStore.tries {
            let (was, bytes) = FoundPrintersStore.readWithBytes(build)
            guard let list = try? await engine.rememberFound(list: was, found: rows, nowMs: nowMs,
                                                             source: source) else { return }
            FoundPrintersStore.beforeWriteForTests?()
            // No suspension between this check and the write.
            guard FoundPrintersStore.readWithBytes(build).bytes == bytes else { continue }
            try? FoundPrintersStore.write(list, build)
            return
        }
    }

    /// What this computer's scans found in the last few days, most recently
    /// seen first. Empty on the sample book, which scans nothing.
    func rememberedPrinters(now: Date = Date()) async -> [JSONValue] {
        guard let engine, let build = source_build else { return [] }
        return (try? await engine.recentFound(list: FoundPrintersStore.read(build),
                                              nowMs: (now.timeIntervalSince1970 * 1000).rounded())) ?? []
    }

    /// Forget every printer this computer's scans remembered.
    func forgetFoundPrinters() {
        // lock: system — clears this computer's own note of what its scans saw; nothing in the book is written.
        guard let build = source_build else { return }
        FoundPrintersStore.forget(build)
    }

    /// The real book's build, nil on the sample.
    private var source_build: StoreReader.Build? { source.build }
}
