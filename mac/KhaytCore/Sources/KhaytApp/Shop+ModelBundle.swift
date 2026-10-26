import AppKit
import Foundation
import KhaytCore
import UniformTypeIdentifiers

/// ── A MODEL BUNDLE, OUT AND BACK IN ─────────────────────────────────────
///
/// File ▸ Export Model Bundle… writes one library model as a `.khaytbundle`:
/// a zip (`ZipWrite`, the writer a converted 3MF is packed with) holding
///
///   model/     the model file, and any other parts the record names
///   pictures/  its thumbnail and the shop's photo of the print
///   settings/  the papers and slicer profiles in its folder
///   manifest.json   `ModelBundle.manifest`: an ALLOWLIST of record fields —
///              never a customer's name, a bought licence's code, a path on
///              this Mac or the sync bookkeeping — and a price only when the
///              shop ticks Include Price.
///
/// File ▸ Import Model Bundle… opens one through `Zip` (the reader every 3MF
/// goes through): the listing is judged first (`ModelBundle.verdict` — no
/// traversal, no symlink, nothing encrypted, sizes capped by what the zip says
/// and again as it inflates), the members are written to a scratch folder
/// under names the bundle cannot choose, and the model goes in through the
/// library's own import (`LibraryImport.add`): hashed, refused if the library
/// already has those bytes, measured, filed. The manifest's notes then fill
/// only what the import left empty, in one undoable edit.
extension Shop {

    /// The bundle's type, for the panels: a zip with Khayt's extension.
    static var bundleType: UTType {
        UTType(filenameExtension: ModelBundle.fileExtension, conformingTo: .zip) ?? .zip
    }

    /// Slicer profiles kept beside a model, which travel in `settings/`.
    nonisolated static let settingsKinds: Set<String> = ["ini", "json", "cfg", "config", "toml", "xml"]

    // MARK: - Out

    /// What one bundle holds, worked out before anything is packed.
    struct BundleContents {
        var model: [(path: String, url: URL)] = []
        var pictures: [(path: String, data: Data)] = []
        var settings: [(path: String, url: URL)] = []
    }

    /// The files to pack for `file`, nil when its model is not on this Mac.
    func bundleContents(_ file: LibraryFile) -> BundleContents? {
        guard let primary = modelFile(for: file) else { return nil }
        var out = BundleContents()
        var taken: Set<String> = []
        out.model.append((ModelBundle.memberPath(file.sourceFile?.originalName ?? file.originalName
                                                 ?? primary.lastPathComponent, in: .model, taken: &taken), primary))
        let dir = directory(for: file)
        if let dir, case .object(let r)? = row(for: file.id), case .array(let parts)? = r["files"] {
            for case .object(let part) in parts {
                guard case .string(let name)? = part["filename"], !name.isEmpty, !name.contains("/"),
                      name != primary.lastPathComponent else { continue }
                let url = dir.appending(path: name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                var leaf = name
                if case .string(let o)? = part["originalName"], !o.isEmpty { leaf = o }
                out.model.append((ModelBundle.memberPath(leaf, in: .model, taken: &taken), url))
            }
        }
        if case .file(let shown)? = cachedThumbnail(for: file),
           case let thumb = URL(fileURLWithPath: shown.path), let data = try? Data(contentsOf: thumb) {
            out.pictures.append((ModelBundle.memberPath(thumb.lastPathComponent, in: .pictures, taken: &taken), data))
        }
        if let uri = file.userPhoto, let data = Self.dataURIBytes(uri) {
            out.pictures.append((ModelBundle.memberPath("photo.jpg", in: .pictures, taken: &taken), data))
        }
        if let dir, !file.isLinked,
           let found = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles]) {
            for url in found.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let ext = url.pathExtension.lowercased()
                guard ArchiveImport.documentKinds.contains(ext) || Self.settingsKinds.contains(ext) else { continue }
                out.settings.append((ModelBundle.memberPath(url.lastPathComponent, in: .settings, taken: &taken), url))
            }
        }
        return out
    }

    /// The bundle's bytes: every member, then the manifest. Nil when the
    /// model is not on this Mac or the files are over the caps.
    func modelBundle(_ file: LibraryFile, includePrice: Bool) throws -> Data? {
        guard let contents = bundleContents(file), case .object(let record)? = row(for: file.id) else { return nil }
        var members: [ZipWrite.Member] = []
        var listed: [ModelBundle.Member] = []
        var total = 0
        func add(_ path: String, _ data: Data, _ role: ModelBundle.Folder) throws {
            guard data.count <= ModelBundle.maxMemberBytes else { throw BundleFailure.tooBig }
            total += data.count
            guard total <= ModelBundle.maxTotalBytes, members.count < ModelBundle.maxMembers - 1
            else { throw BundleFailure.tooBig }
            members.append(ZipWrite.Member(path, data))
            listed.append(ModelBundle.Member(path: path, role: role, size: data.count))
        }
        for (path, url) in contents.model {
            try add(path, try Data(contentsOf: url, options: .mappedIfSafe), .model)
        }
        for (path, data) in contents.pictures { try add(path, data, .pictures) }
        for (path, url) in contents.settings { try add(path, try Data(contentsOf: url, options: .mappedIfSafe), .settings) }
        let facts = libraryFacts(file)
        let price: (amount: Double, currency: String)? = includePrice ? facts.price.map { ($0, currency) } : nil
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        let manifest = ModelBundle.manifest(record: record, group: file.groupName, members: listed, price: price,
                                            exportedAt: StoreWriter.iso(Date()), app: "Khayt Mac " + version)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        members.append(ZipWrite.Member(ModelBundle.manifestName, try encoder.encode(manifest)))
        return try ZipWrite.archive(members)
    }

    enum BundleFailure: Error { case tooBig }

    /// File ▸ Export Model Bundle…: the one selected model, to a file the
    /// shop names. The panel asks first and holds the Include Price box; the
    /// bundle is built only once there is somewhere to put it.
    func exportModelBundle() async {
        clearLastOutcome()
        guard let file = selectedFile else { return }
        guard permitted("inventory", "view") else { importProblem = moveProblem; return }
        guard modelFile(for: file) != nil else {
            importProblem = words.callIt("mac.mb_not_here", ["name": .string(file.title)]); return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.bundleType]
        panel.nameFieldStringValue = ModelBundle.safeLeaf(file.title).isEmpty ? "model" : ModelBundle.safeLeaf(file.title)
        panel.message = words.callIt("mac.mb_export_says")
        let box = NSButton(checkboxWithTitle: words.callIt("mac.mb_include_price"), target: nil, action: nil)
        box.state = .off
        box.isEnabled = libraryFacts(file).price != nil
        panel.accessoryView = box
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let includePrice = box.state == .on
        do {
            guard let data = try modelBundle(file, includePrice: includePrice) else {
                importProblem = words.callIt("mac.mb_not_here", ["name": .string(file.title)]); return
            }
            try data.write(to: url, options: .atomic)
            importNote = words.callIt("mac.mb_exported", ["name": .string(url.lastPathComponent)])
        } catch BundleFailure.tooBig {
            importProblem = words.callIt("mac.mb_too_big")
        } catch {
            importProblem = words.callIt("mac.mb_export_failed", ["why": .string(self.said(error))])
        }
    }

    // MARK: - In

    /// What a bundle unpacked to, in a scratch folder.
    struct OpenedBundle: Sendable {
        let scratch: URL
        let model: URL
        let others: [URL]
        let pictures: [URL]
        let manifest: ModelBundle.Opened
    }

    /// Judge, then unpack, a bundle into a fresh scratch folder. Member names
    /// are never used as paths: each is written as its own safe leaf under
    /// its folder, and the inflated size is held to the cap as it goes.
    nonisolated static func unpackBundle(_ url: URL) throws -> OpenedBundle {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        let entries = try Zip.entries(of: url)
        let files: [Zip.Entry]
        switch ModelBundle.verdict(entries, bundleBytes: bytes) {
        case .success(let ok): files = ok
        case .failure(let refusal): throw refusal
        }
        guard let manifestEntry = files.first(where: { $0.name == ModelBundle.manifestName }),
              let opened = ModelBundle.open(manifest: try Zip.data(of: manifestEntry, in: url,
                                                                   limit: ModelBundle.maxManifestBytes))
        else { throw ModelBundle.Refusal.badManifest }
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "khayt-bundle-scratch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var total = 0
        var model: URL?
        var others: [URL] = [], pictures: [URL] = []
        do {
            for entry in files where entry.name != ModelBundle.manifestName {
                let parts = entry.name.split(separator: "/").map(String.init)
                guard parts.count == 2, let folder = ModelBundle.Folder(rawValue: parts[0]) else { continue }
                let dir = scratch.appending(path: folder.rawValue)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let leaf = ModelBundle.safeLeaf(parts[1])
                guard !leaf.isEmpty else { throw ModelBundle.Refusal.badName(entry.name) }
                let out = dir.appending(path: leaf)
                // Inside the scratch folder, whatever the name said.
                guard out.standardizedFileURL.path.hasPrefix(scratch.standardizedFileURL.path + "/")
                else { throw ModelBundle.Refusal.badName(entry.name) }
                FileManager.default.createFile(atPath: out.path, contents: nil)
                let handle = try FileHandle(forWritingTo: out)
                defer { try? handle.close() }
                var wrote = 0
                try Zip.stream(entry, in: url, totalLimit: ModelBundle.maxMemberBytes) { chunk in
                    wrote += chunk.count
                    guard total + wrote <= ModelBundle.maxTotalBytes else { return false }
                    handle.write(Data(chunk))
                    return true
                }
                total += wrote
                guard total <= ModelBundle.maxTotalBytes else { throw ModelBundle.Refusal.tooBig }
                switch folder {
                case .model:
                    if model == nil, LibraryImport.kinds.contains(out.pathExtension.lowercased()) { model = out }
                    else { others.append(out) }
                case .pictures: pictures.append(out)
                case .settings: others.append(out)
                }
            }
            guard let model else { throw ModelBundle.Refusal.noModel }
            return OpenedBundle(scratch: scratch, model: model, others: others, pictures: pictures, manifest: opened)
        } catch {
            // The scratch copy of a bundle that was refused.
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    /// The words for a refusal.
    func said(_ refusal: ModelBundle.Refusal) -> String {
        switch refusal {
        case .notABundle, .noManifest, .badManifest: words.callIt("mac.mb_not_bundle")
        case .tooBig, .tooMany: words.callIt("mac.mb_too_big")
        case .badName(let name): words.callIt("mac.mb_bad_name", ["name": .string(name)])
        case .encrypted(let name): words.callIt("mac.mb_encrypted", ["name": .string(name)])
        case .noModel: words.callIt("mac.mb_no_model")
        }
    }

    /// File ▸ Import Model Bundle…: ask for the file, then `importModelBundle`.
    func chooseModelBundle() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.bundleType]
        panel.allowsMultipleSelection = false
        panel.message = words.callIt("mac.mb_import_says")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await importModelBundle(url)
    }

    /// One bundle in as one new model. Gated like every import; the model is
    /// refused when its bytes are already in the library, as any import is.
    func importModelBundle(_ url: URL) async {
        clearLastOutcome()
        guard permitted("inventory", "create") else { importProblem = moveProblem; return }
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            importProblem = LibraryImport.Failure.notOurs.said(words); return
        }
        guard let roots = libraryRoots else { importProblem = LibraryImport.Failure.noLibrary.said(words); return }
        guard let engine else { importProblem = words.callIt("mac.mb_not_bundle"); return }
        let opened: OpenedBundle
        do {
            opened = try await LibraryImport.offMain { Result { try Self.unpackBundle(url) } }.get()
        } catch let refusal as ModelBundle.Refusal {
            importProblem = said(refusal); return
        } catch {
            importProblem = words.callIt("mac.mb_not_bundle"); return
        }
        // The scratch folder, whatever happens next.
        defer { try? FileManager.default.removeItem(at: opened.scratch) }
        importing = true
        defer { importing = false }
        let known = Set(files.compactMap(\.contentHash))
        let titles = Dictionary(files.compactMap { f in f.contentHash.map { ($0, f.title) } },
                                uniquingKeysWith: { a, _ in a })
        do {
            let added = try await LibraryImport.add(
                opened.model, storeURL: build.storeURL, libraryRoot: URL(fileURLWithPath: roots.primary),
                knownHashes: known, nameOfExisting: { titles[$0] }, engine: engine,
                keepOriginal: true, group: opened.manifest.group, documents: opened.others,
                title: opened.manifest.title, tags: opened.manifest.tags, photos: opened.pictures.filter {
                    $0.lastPathComponent.lowercased().hasPrefix("photo")
                },
                analyseRisk: analysesRiskAtImport,
                owns: { StoreLock.weOwnIt(build) }, whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) })
            await load(source)
            let fields = opened.manifest.fields
            if !fields.isEmpty {
                editFiles([added.id], named: words.callIt("mac.mb_import")) { record in
                    ModelBundle.fill(&record, from: fields)
                }
            }
            importNote = words.callIt("mac.mb_imported", ["name": .string(added.name)])
        } catch let failure as LibraryImport.Failure {
            importProblem = failure.said(words)
        } catch {
            importProblem = self.said(error)
        }
    }
}
