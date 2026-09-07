import Foundation
import AppKit
import KhaytCore

/// `Khayt --import <path>…` — the library import without the window.
///
/// ── WHY A COMMAND AND NOT JUST THE MENU ───────────────────────────────────
///
/// A shop's models arrive as a downloads folder with three thousand files in
/// it. The File menu can take that folder now, but a run that long wants to be
/// startable from a script, repeatable, and above all REHEARSABLE — `--dry-run`
/// says exactly what would move before anything does, which is the difference
/// between an import a shop can check and one it has to trust.
///
/// It shares `LibraryImport.addMany` with the menu, so the two cannot drift on
/// what counts as a model, what counts as a duplicate, or when an original is
/// removed. What lives here is only the shape of a terminal: arguments in,
/// lines out, an exit code at the end.
///
/// ── IT TAKES THE BOOK ─────────────────────────────────────────────────────
///
/// The same lock the window takes, for the same reason: two processes writing
/// the store is how a shop loses a day's work. If Khayt is open, this refuses
/// and says which app has it rather than waiting or forcing.
@MainActor
enum ImportCommand {

    /// What was asked for. Parsed away from everything else so the argument
    /// handling can be tested without a book, a lock, or a library folder.
    struct Options: Equatable {
        var paths: [String] = []
        var keepOriginals = false
        var dryRun = false
        /// Draw the missing previews in a library that already exists, rather
        /// than import anything. For the models that came in before the app
        /// could draw them.
        var previewsOnly = false
    }

    enum Parsed: Equatable {
        case run(Options)
        /// `--import` was not asked for; this is an ordinary launch.
        case notAsked
        case usage(String)
    }

    static let usage = """
        Khayt --import <path>… [--keep-originals] [--dry-run]

          <path>             a model, or a folder to walk for models
          --keep-originals   copy them in; the default is to MOVE
          --dry-run          say what would happen and change nothing
          --previews         draw the missing previews and record the missing
                             measurements in the library that is already there;
                             imports nothing, and needs no path
        """

    static func parse(_ arguments: [String]) -> Parsed {
        var rest = Array(arguments.dropFirst())
        guard let flag = rest.firstIndex(of: "--import") else { return .notAsked }
        rest.remove(at: flag)

        var options = Options()
        for argument in rest {
            switch argument {
            case "--keep-originals": options.keepOriginals = true
            case "--dry-run": options.dryRun = true
            case "--previews": options.previewsOnly = true
            // AppKit puts its own arguments on a launched bundle — `-NSDocument…`,
            // and `-psn_…` when Finder opens it. Passing those to the walker
            // would report each as a path that is not there.
            case let other where other.hasPrefix("-"):
                if other.hasPrefix("-psn_") || other.hasPrefix("-NS") { continue }
                return .usage("Khayt does not know the option \(other).\n\n\(usage)")
            case let path: options.paths.append(path)
            }
        }
        // `--previews` works on the library that is already there, so it is
        // the one form that needs no path.
        guard !options.paths.isEmpty || options.previewsOnly else {
            return .usage("--import needs at least one file or folder.\n\n\(usage)")
        }
        return .run(options)
    }

    // MARK: - Running it

    private static func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static func complain(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Returns the process's exit code: 0 when everything asked for arrived.
    static func run(_ options: Options) async -> Int32 {
        guard let source = Shop.available.first(where: \.isReal),
              let build = source.build else {
            complain("There is no Khayt book on this Mac to import into.")
            return 2
        }

        // Read-only until the last moment. A dry run never takes the lock,
        // so it can be done while the app is open.
        let shop = Shop()
        await shop.load(source)
        guard let engine = shop.engine else {
            complain("The shared rules did not load; nothing was imported.")
            return 2
        }
        guard let roots = shop.libraryRoots else {
            complain(LibraryImport.Failure.noLibrary.description)
            return 2
        }

        if options.previewsOnly {
            return await drawMissingPreviews(shop: shop, build: build,
                                             root: roots.primary, dryRun: options.dryRun,
                                             engine: engine)
        }

        let chosen = options.paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let missing = chosen.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else {
            complain("Not there: " + missing.map(\.path).joined(separator: ", "))
            return 2
        }

        let files = Shop.modelsUnder(chosen, skipping: roots.primary)
        guard !files.isEmpty else {
            complain("Nothing there Khayt can read.")
            return 1
        }

        let bytes = files.reduce(0) { total, file in
            total + ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0)
        }
        say("book:    \(build.storeURL.path)")
        say("library: \(roots.primary)")
        say("found:   \(files.count) models, \(Self.size(bytes))")
        say(options.keepOriginals ? "mode:    copy, leaving the originals"
                                  : "mode:    MOVE, taking the originals in")

        if options.dryRun {
            // The whole point of a rehearsal is seeing the list, so it is
            // printed rather than counted. A shop about to move three thousand
            // files is entitled to read them first.
            say("")
            for file in files { say("  would import  \(file.path)") }
            say("")
            say("dry run: nothing was moved, copied or written.")
            return 0
        }

        guard let claim = StoreLock.take(for: build) else {
            let who = StoreLock.held(StoreLock.verdict(for: build))
            complain("\(who?.app ?? "Another app") has this book open. Close it and try again.")
            return 3
        }
        defer { StoreLock.release(claim, for: build) }

        let titles = Dictionary(shop.files.compactMap { f in
            f.contentHash.map { ($0, f.title) }
        }, uniquingKeysWith: { a, _ in a })

        say("")
        let started = Date()
        let report = await LibraryImport.addMany(
            files,
            storeURL: build.storeURL,
            libraryRoot: URL(fileURLWithPath: roots.primary),
            knownHashes: Set(shop.files.compactMap(\.contentHash)),
            nameOfExisting: { titles[$0] },
            engine: engine,
            keepOriginal: options.keepOriginals,
            owns: { StoreLock.weOwnIt(build) },
            whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
            progress: { done, total, file in
                // Numbered, so a run that stops halfway says where it got to.
                say("[\(done + 1)/\(total)] \(file.lastPathComponent)")
            })

        say("")
        say("moved in:   \(report.moved)")
        say("already in: \(report.duplicates)")
        say("failed:     \(report.failures.count)")
        for failure in report.failures { complain("  \(failure)") }
        say(String(format: "took %.0f s", Date().timeIntervalSince(started)))
        return report.failures.isEmpty ? 0 : 1
    }

    /// A model that came in before the app could do everything to it.
    ///
    /// EITHER, not both: until the CR-LF fix, fifteen of this shop's models
    /// were missing both — a text STL written on Windows read as no triangles,
    /// so it drew nothing AND measured as nothing. The picture is what a person
    /// notices; the measurement is what "will it fit on my printer" needs, and
    /// a model without one is quietly left out of that answer rather than
    /// reported as too big.
    ///
    /// Only STL. A 3MF brings its own picture and is measured on the way in,
    /// and nothing here reads an OBJ's triangles yet — offering to catch those
    /// up would be a promise this cannot keep.
    static func needsCatchingUp(_ file: LibraryFile) -> Bool {
        guard (file.sourceFile?.ext ?? "").lowercased() == "stl" else { return false }
        return (file.thumbFile ?? "").isEmpty || (file.geometryKey ?? "").isEmpty
    }

    /// Draw a preview for every model in the library that has none.
    ///
    /// For the library that was imported before the app could draw one — 445
    /// models on the book this was written against, every one of them a grey
    /// cube on the library screen. A model that already has a picture is left
    /// alone, so this is safe to run twice and costs nothing the second time.
    private static func drawMissingPreviews(shop: Shop, build: StoreReader.Build,
                                            root: String, dryRun: Bool,
                                            engine: KhaytEngine) async -> Int32 {
        let vault = URL(fileURLWithPath: root)
        // A MODEL CAN BE MISSING EITHER, and until the CR-LF fix fifteen of
        // this shop's were missing both: a text STL written on Windows read as
        // no triangles, so it drew nothing AND measured as nothing. The picture
        // is what a person notices; the measurement is what "will it fit on my
        // printer" needs, and a model with no key is silently left out of that
        // answer rather than reported as too big.
        let wanted = shop.files.filter(needsCatchingUp)
        say("library: \(root)")
        say("models missing a picture or a measurement: \(wanted.count) of \(shop.files.count)")
        guard !wanted.isEmpty else { return 0 }
        if dryRun {
            say("")
            for file in wanted { say("  would draw  \(file.title)") }
            say("")
            say("dry run: nothing was drawn or written.")
            return 0
        }

        guard let claim = StoreLock.take(for: build) else {
            let who = StoreLock.held(StoreLock.verdict(for: build))
            complain("\(who?.app ?? "Another app") has this book open. Close it and try again.")
            return 3
        }
        defer { StoreLock.release(claim, for: build) }

        var drawn: [String: String] = [:]
        var measured: [String: String] = [:]
        var failures: [String] = []
        let started = Date()
        for (i, file) in wanted.enumerated() {
            guard let name = file.sourceFile?.filename else { continue }
            let model = vault.appending(path: LibraryLocation.itemDirName(file.id))
                             .appending(path: name)
            say("[\(i + 1)/\(wanted.count)] \(file.title)")

            if (file.geometryKey ?? "").isEmpty,
               let box = try? Mesh.measureSTL(model), box.triangleCount > 0,
               let key = try? await engine.geometryKey(triangleCount: box.triangleCount,
                                                       volumeMm3: box.volumeMm3,
                                                       x: box.x, y: box.y, z: box.z) {
                measured[file.id] = key
            }

            guard (file.thumbFile ?? "").isEmpty else { continue }
            do {
                guard let png = try MeshPreview.png(of: model) else {
                    failures.append("\(file.title): nothing to draw"); continue
                }
                try png.write(to: model.deletingLastPathComponent().appending(path: "thumb.png"))
                drawn[file.id] = "thumb.png"
            } catch {
                failures.append("\(file.title): \(error)")
            }
        }

        // ONE WRITE, at the end. Four hundred and forty-five separate updates
        // of a one-megabyte book is four hundred and forty-five rewrites of it.
        if !drawn.isEmpty || !measured.isEmpty {
            do {
                try StoreWriter.update(storeURL: build.storeURL,
                                       owns: { StoreLock.weOwnIt(build) },
                                       whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }) { root in
                    guard case .array(let rows)? = root["printFiles"] else { return }
                    root["printFiles"] = .array(rows.map { row in
                        guard case .object(var o) = row, case .string(let id)? = o["id"] else {
                            return row
                        }
                        guard drawn[id] != nil || measured[id] != nil else { return row }
                        if let name = drawn[id] {
                            o["thumbFile"] = .string(name)
                            o["thumbSource"] = .string("mesh")
                        }
                        if let key = measured[id] { o["geometryKey"] = .string(key) }
                        return .object(o)
                    })
                }
            } catch {
                complain("The book refused the write: \(error)")
                return 2
            }
        }

        say("")
        say("drawn:    \(drawn.count)")
        say("measured: \(measured.count)")
        say("skipped:  \(failures.count)")
        for failure in failures.prefix(10) { complain("  \(failure)") }
        say(String(format: "took %.0f s", Date().timeIntervalSince(started)))
        return failures.isEmpty ? 0 : 1
    }

    private static func size(_ bytes: Int) -> String {
        let units = ["B", "kB", "MB", "GB", "TB"]
        var value = Double(bytes), i = 0
        while value >= 1000, i < units.count - 1 { value /= 1000; i += 1 }
        return String(format: i == 0 ? "%.0f %@" : "%.1f %@", value, units[i])
    }
}
