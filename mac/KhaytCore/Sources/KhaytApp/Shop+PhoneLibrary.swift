import Foundation
import KhaytCore

/// The library, as the paired phone asks for it over the LAN: a page of it, a
/// model's picture, and a model's price (docs/LAN_API.md, "GET /api/library").
///
/// ── WHY THE MAC ANSWERS AND THE PHONE DOES NOT KEEP A COPY ─────────────────
///
/// `printFiles` is a quarter of a real book (10,176 models in 823 folders on
/// the shop's), so it stays out of the phone's working set, and the files
/// themselves are on this Mac's disk. A shop owner asked for a price at the
/// counter could not give one from the phone. Now the phone searches here and
/// is priced here.
///
/// ── ONE PRICE, THE MAC'S ───────────────────────────────────────────────────
///
/// A model is priced through `calculator(for:plate:)`, the same path as the
/// library's "Quote this model…" and the calculator's "From a model…": the
/// shop's spools, rates, margin and rounding, with the slicer's figures where
/// there are some and the measured mesh where there are not. The phone is
/// shown the number this Mac would show, not the public intake form's figure,
/// which follows the customer quote settings and is off on a shop that has not
/// opened quoting to customers.
extension Shop {

    /// The readers a library file can be measured with when nothing has
    /// sliced it.
    nonisolated static let phoneMeasurable: Set<String> = ["stl", "obj", "3mf"]
    /// The largest library file measured on a phone's request. Reading the
    /// geometry streams, but a model this size takes long enough that the
    /// phone would give up first.
    nonisolated static let phoneMeasureLimit = 150 * 1024 * 1024

    /// A folder path as the library files it: trimmed components, no empties.
    nonisolated static func folderPath(_ raw: String?) -> String {
        (raw ?? "").split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    /// Which models a page shows, and the folders beside them. Pure, so the
    /// search and the folder counts are tested without a server.
    nonisolated static func libraryPage(_ files: [LibraryFile], q: String, folder: String,
                                        offset: Int, limit: Int)
        -> (total: Int, files: [LibraryFile], folders: [(path: String, name: String, count: Int)]) {
        let live = files.filter { !$0.isArchived }
        let words = SearchText.fold(q).split(whereSeparator: \.isWhitespace).map(String.init)
        let here = folderPath(folder)
        var chosen: [LibraryFile]
        var folders: [(path: String, name: String, count: Int)] = []
        if !words.isEmpty {
            chosen = live.filter { file in
                let fields = file.searchFields + [file.groupName ?? "", file.category ?? ""]
                return words.allSatisfy { w in fields.contains { !$0.isEmpty && SearchText.containsFolded($0, w) } }
            }
        } else {
            chosen = live.filter { folderPath($0.groupName) == here }
            var counts: [String: Int] = [:]
            let prefix = here.isEmpty ? "" : here + "/"
            for file in live {
                let path = folderPath(file.groupName)
                guard !path.isEmpty, path.hasPrefix(prefix), path != here else { continue }
                let child = path.dropFirst(prefix.count).split(separator: "/").first.map(String.init) ?? ""
                if !child.isEmpty { counts[child, default: 0] += 1 }
            }
            folders = counts.map { (path: prefix + $0.key, name: $0.key, count: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        chosen.sort { a, b in
            if a.isFavourite != b.isFavourite { return a.isFavourite }
            let order = a.title.localizedStandardCompare(b.title)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
        let start = min(max(0, offset), chosen.count)
        let end = min(chosen.count, start + max(1, min(200, limit)))
        return (chosen.count, Array(chosen[start..<end]), folders)
    }

    /// The file in the library folder, when it is on this Mac's disk now.
    func libraryFileOnDisk(_ file: LibraryFile) -> URL? {
        if let path = file.externalPath, !path.isEmpty {
            // Only under a folder this book links or keeps its library in:
            // `externalPath` arrives by sync, and a path anywhere else on this
            // Mac is not read for a phone (as `fillNowLocal`, `OnlineMeasure`).
            let places = linkedFolders + (libraryRoots.map { $0.roots + [$0.primary] } ?? [])
            guard places.contains(where: { !$0.isEmpty && LibraryMove.under(path, $0) }) else { return nil }
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        guard let roots = libraryRoots, let name = file.sourceFile?.filename, !name.isEmpty,
              let dir = LibraryLocation.directory(for: file.id, roots: roots.roots) else { return nil }
        let url = dir.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated static func libraryExt(_ file: LibraryFile) -> String {
        let named = file.sourceFile?.ext ?? (file.sourceFile?.filename as NSString?)?.pathExtension
            ?? (file.externalPath as NSString?)?.pathExtension ?? ""
        return named.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// `GET /api/library`'s answer.
    func phoneLibrary(q: String, folder: String, offset: Int, limit: Int) -> JSONValue {
        let page = Self.libraryPage(files, q: q, folder: folder, offset: offset, limit: limit)
        let items: [JSONValue] = page.files.map { file in
            var o: [String: JSONValue] = [
                "id": .string(file.id), "name": .string(file.title),
                "folder": .string(Self.folderPath(file.groupName)),
                "favorite": .bool(file.isFavourite),
                "thumb": .bool(thumbnail(for: file) != nil),
            ]
            if let c = file.category, !c.isEmpty { o["category"] = .string(c) }
            if let t = file.tags, !t.isEmpty { o["tags"] = .array(t.map(JSONValue.string)) }
            if let m = file.material ?? file.parsed?.filamentType, !m.isEmpty { o["material"] = .string(m) }
            let ext = Self.libraryExt(file)
            if !ext.isEmpty { o["ext"] = .string(ext) }
            if let size = file.sourceFile?.size, size > 0 { o["size"] = .number(size) }
            if let n = file.timesPrinted { o["timesPrinted"] = .number(Double(n)) }
            if let d = file.lastPrinted, !d.isEmpty { o["lastPrinted"] = .string(d) }
            if let notes = file.testedNotes, !notes.isEmpty { o["testedNotes"] = .string(notes) }
            let mins = file.parsed?.printTimeMins ?? 0, grams = file.parsed?.filamentGrams ?? 0
            o["printTimeMins"] = mins > 0 ? .number(mins) : .null
            o["grams"] = grams > 0 ? .number(grams) : .null
            let plates = plates(of: file)
            if plates.count > 1 {
                o["plates"] = .array(plates.map { p in
                    var row: [String: JSONValue] = ["index": .number(Double(p.index)),
                                                    "printTimeMins": .number(p.minutes), "grams": .number(p.grams)]
                    if let name = p.name, !name.isEmpty { row["name"] = .string(name) }
                    return .object(row)
                })
            }
            let colours: [JSONValue] = file.palette.compactMap { c in
                guard let hex = c.hex, !hex.isEmpty else { return nil }
                var row: [String: JSONValue] = ["hex": .string(hex)]
                if let g = c.grams, g > 0 { row["grams"] = .number(g) }
                return .object(row)
            }
            if !colours.isEmpty { o["colors"] = .array(colours) }
            let measurable = Self.phoneMeasurable.contains(ext)
            o["estimable"] = .bool((mins > 0 && grams > 0) || estimates[file.id] != nil
                                   || (measurable && libraryFileOnDisk(file) != nil))
            return .object(o)
        }
        return .object([
            "total": .number(Double(page.total)), "offset": .number(Double(max(0, offset))),
            "folders": .array(page.folders.map {
                .object(["path": .string($0.path), "name": .string($0.name), "count": .number(Double($0.count))])
            }),
            "items": .array(items),
        ])
    }

    /// `GET /api/library/{id}/thumb`: the picture's bytes and type, or nil.
    func phoneLibraryThumb(_ id: String) async -> (Data, String)? {
        guard let file = files.first(where: { $0.id == id }), let source = thumbnail(for: file) else { return nil }
        switch source {
        case .inlineData(let uri):
            // `data:image/jpeg;base64,…`
            guard let comma = uri.firstIndex(of: ","), uri.hasPrefix("data:") else { return nil }
            let head = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma]
            let mime = head.split(separator: ";").first.map(String.init) ?? "image/jpeg"
            guard let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else { return nil }
            return (data, mime)
        case .file(let url):
            let data: Data? = await withCheckedContinuation { done in
                LanServer.measureQueue.async { done.resume(returning: try? Data(contentsOf: url)) }
            }
            guard let data else { return nil }
            let mime = switch url.pathExtension.lowercased() {
            case "png": "image/png"
            case "webp": "image/webp"
            default: "image/jpeg"
            }
            return (data, mime)
        }
    }

    /// `POST /api/library/{id}/estimate`: the status and body.
    func phoneLibraryEstimate(_ id: String, plate: Int?, qty: Int) async -> (Int, String) {
        func refuse(_ status: Int, _ reason: String) -> (Int, String) {
            (status, #"{"ok":false,"reason":"\#(reason)"}"#)
        }
        guard let file = files.first(where: { $0.id == id && !$0.isArchived }) else { return refuse(404, "not-found") }
        if let plate, !plates(of: file).contains(where: { $0.index == plate }) { return refuse(404, "not-found") }
        // The calculator path says what went wrong on the window. A phone's
        // question is not the shop's screen: put back what it showed.
        let shown = productProblem
        defer { productProblem = shown }

        var calc = await calculator(for: file, plate: plate)
        if calc == nil, plate == nil, estimates[file.id] == nil {
            // Nothing sliced it and nothing has measured it: measure the file
            // in the library folder, as the intake form measures an upload.
            let ext = Self.libraryExt(file)
            guard let url = libraryFileOnDisk(file) else { return refuse(409, "no-file") }
            guard Self.phoneMeasurable.contains(ext) else { return refuse(415, "unsupported") }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.phoneMeasureLimit else { return refuse(413, "too-large") }
            // Asked BEFORE the read below, which is what makes a drive fetch it.
            let wasOnline = linkedIsOnline(url)
            // Handed back to the drive here unless `rememberMeasured` took the
            // file on — whatever went wrong between, a price asked from the
            // phone does not leave a drive's model downloaded (alpha.84 review).
            var handedOn = false
            let evict = linkedEvict
            defer { if wasOnline, !handedOn { Task { await PinWork.run { evict(url) } } } }
            let measured: (volume: Double, area: Double, x: Double, y: Double, z: Double)? =
                await withCheckedContinuation { done in
                    LanServer.measureQueue.async {
                        let m = try? Zip.$inflateBudget.withValue(LanServer.maxInflate) {
                            try Mesh.readGeometry(url, ext: ext)
                        }
                        guard let m, m.volumeMm3 > 0 else { done.resume(returning: nil); return }
                        var area = 0.0
                        if size <= LanServer.maxRiskBytes, let walked = try? Mesh.overhangs(of: url),
                           case .number(let a)? = walked["totalAreaMm2"], a > 0 { area = a }
                        done.resume(returning: (m.volumeMm3, area, m.x, m.y, m.z))
                    }
                }
            guard let measured, let engine else { return refuse(200, "no-numbers") }
            let input = KhaytEngine.MeshInput(volumeMm3: measured.volume, areaMm2: measured.area,
                                              bbox: (x: measured.x, y: measured.y, z: measured.z))
            if let estimate = (try? await engine.estimateMeshes([input], settings: settingsDict,
                                                                orders: orderRows))?.first ?? nil {
                // The library shows this figure too, until the next load works
                // the figures out again: it is the one the Mac would measure.
                estimates[file.id] = estimate
                calc = await calculator(for: file, plate: plate)
                if rememberMeasured(file, at: url, wasOnline: wasOnline) { handedOn = true }
            }
        }
        guard let calc else {
            return libraryFileOnDisk(file) == nil && estimates[file.id] == nil
                ? refuse(409, "no-file") : refuse(200, "no-numbers")
        }
        calc.qty = max(1, min(1000, qty))
        await calc.recompute(self)
        guard let total = calc.quoted?.total, total > 0 else { return refuse(200, "no-price") }
        let source = calc.filled?.source ?? .estimated
        let answer: [String: JSONValue] = [
            "ok": .bool(true), "price": .number(total), "currency": .string(currency),
            "qty": .number(Double(calc.qty)),
            "grams": .number(calc.gramsValue), "hours": .number(calc.hoursValue),
            "exact": .bool(source == .sliced),
            // A slice is always stood behind; a measured mesh only when the
            // estimator says its shell model describes it.
            "reliable": .bool(source == .sliced || !(estimates[file.id]?.shellUnreliable ?? false)),
        ]
        let body = (try? String(decoding: JSONEncoder().encode(JSONValue.object(answer)), as: UTF8.self)) ?? "{}"
        return (200, body)
    }

    /// The phone's measurement, kept: written to the book the way a model
    /// brought down by hand is (`fillDownloaded`), so a model is fetched and
    /// measured once rather than on every price asked — and handed back to
    /// its drive when it was online only, so pricing from the phone leaves
    /// the disk as it found it (`OnlineMeasure`). Best-effort, in the
    /// background: the phone has its answer already.
    /// True when it took the file on (and will hand it back to its drive).
    /// One at a time: a write still going means this model is measured again
    /// the next time it is priced, not that a second whole read runs beside it.
    @discardableResult
    func rememberMeasured(_ file: LibraryFile, at url: URL, wasOnline: Bool) -> Bool {
        guard (file.geometryKey ?? "").isEmpty, phoneMeasureWriting == false, let build = source.build,
              StoreLock.weOwnIt(build), let engine, let roots = libraryRoots else { return false }
        // A linked model's picture goes in its vault folder, never the shop's.
        let pictures = file.externalPath.map { _ in Self.vaultFolder(file.id, roots: roots) }
        let evict = linkedEvict
        phoneMeasureWriting = true
        phoneMeasureWrite = Task {
            defer { phoneMeasureWriting = false }
            if let pictures { try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true) }
            // lock: system — a model the library already lists, measured for a phone's price.
            _ = try? await Self.fillDownloaded(id: file.id, file: url, pictures: pictures, storeURL: build.storeURL,
                                               engine: engine, owns: { StoreLock.weOwnIt(build) },
                                               whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) })
            if wasOnline { await PinWork.run { evict(url) } }
        }
        return true
    }
}
