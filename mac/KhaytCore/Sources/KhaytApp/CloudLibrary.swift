import Foundation
import CryptoKit
import KhaytCore

/// The print library in a bucket: a backup copy of every model, and room on
/// this Mac for a library bigger than its disk.
///
/// ── THE OTHER APP'S DESIGN, NOT A SECOND ONE ──────────────────────────────
///
/// Asked for by the shop (Sep 2026): "do we have the feature of storing files
/// online? if no we must add it". The other app had it — `lib/s3-client.js`,
/// `lib/print-library-tier.js`, `main.js` — and the Mac had none. This is that
/// design on the Mac, deliberately identical where the two meet, so one bucket
/// serves both apps:
///
/// * the same settings (`settings.printLibrary.s3` / `.tier`), the secret
///   sealed the same way;
/// * the same object key, `[prefix]/print-files/<id>/<filename>`, for the
///   backup copy and the moved-out copy alike;
/// * the same `<model>.cloud` sidecar, written by the same JavaScript, so a
///   model moved out by either app is brought back by either.
///
/// ── THE ONE DESTRUCTIVE THING HERE ────────────────────────────────────────
///
/// Freeing space deletes the local copy of a customer's model. It happens
/// only after the bucket has been asked AGAIN, in a separate request, and has
/// answered with the right size and a content hash that matches — never on
/// the strength of the upload having returned 200. That rule is the other
/// app's (`printLibEnsureInBucket`) and it is kept exactly.
@MainActor
enum CloudLibrary {

    /// The bucket as the book describes it, with its secret opened for this
    /// use only. Nil when none is set up.
    struct Config {
        var s3: S3Config
        /// `s3.enabled`: new models are backed up to the bucket.
        var backsUp: Bool
        var provider: String
        /// `settings.printLibrary.tier`, as the shared rule reads it.
        var tier: JSONValue
        var tierEnabled: Bool
    }

    static func config(settings: [String: JSONValue], build: StoreReader.Build?) async -> Config? {
        guard case .object(let library)? = settings["printLibrary"],
              case .object(let s3)? = library["s3"] else { return nil }
        func text(_ key: String) -> String {
            if case .string(let v)? = s3[key] { return v.trimmingCharacters(in: .whitespaces) }
            return ""
        }
        var secret = text("secretAccessKey")
        if secret.hasPrefix(SafeStorage.marker) {
            guard let build else { return nil }
            secret = (try? await Secrets.open(secret, for: build)) ?? ""
        }
        let config = S3Config(endpoint: text("endpoint"), bucket: text("bucket"), region: text("region"),
                              accessKeyId: text("accessKeyId"), secretAccessKey: secret, prefix: text("prefix"))
        guard config.isConfigured else { return nil }
        let tier = library["tier"] ?? .object([:])
        var tierOn = false
        if case .object(let t) = tier, case .bool(true)? = t["enabled"] { tierOn = true }
        var backsUp = false
        if case .bool(true)? = s3["enabled"] { backsUp = true }
        return Config(s3: config, backsUp: backsUp, provider: text("provider"), tier: tier, tierEnabled: tierOn)
    }

    /// Requests to a bucket. No redirects: a signed request followed somewhere
    /// else would carry its Authorization there. A `var` so the tests can put
    /// a bucket that lies in its place.
    static var fetch: S3.Fetch = { request in
        try await URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
            .data(for: request)
    }

    final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// SHA-256 and MD5 in one pass, four megabytes at a time — a model can be
    /// a gigabyte and is never read into memory whole for this.
    nonisolated static func digests(of url: URL) throws -> (sha256: String, md5: String, size: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256()
        var md5 = Insecure.MD5()
        var size = 0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            sha.update(data: chunk); md5.update(data: chunk); size += chunk.count
        }
        let hex = { (d: any Sequence<UInt8>) in d.map { String(format: "%02x", $0) }.joined() }
        return (hex(sha.finalize()), hex(md5.finalize()), size)
    }

    enum Failure: Error, LocalizedError {
        case notVerified(String)
        case noSidecar
        case badDownload(String)
        var errorDescription: String? {
            switch self {
            case .notVerified(let why): "the bucket did not confirm the upload: \(why)"
            case .noSidecar: "this model is not in the cloud"
            case .badDownload(let why): "the download did not match: \(why)"
            }
        }
    }

    /// Make sure the bucket holds exactly this file under `key`: skip the
    /// upload when it already does, and PROVE it afterwards with a second,
    /// separate request. `lib/print-library-tier.js etagVerdict` decides what
    /// an etag proves; an unusable one is checked by downloading and hashing.
    @discardableResult
    static func ensureInBucket(_ c: S3Config, key: String, file: URL,
                               engine: KhaytEngine) async throws -> (sha256: String, size: Int) {
        let local = try await Task.detached { try Self.digests(of: file) }.value
        if let there = try await S3.head(c, key: key, fetch: fetch), there.size == local.size,
           try await engine.etagVerdict(etag: there.etag, md5: local.md5) == "match" {
            return (local.sha256, local.size)
        }
        let data = try await Task.detached { try Data(contentsOf: file, options: .mappedIfSafe) }.value
        try await S3.put(c, key: key, data: data, fetch: fetch)
        guard let after = try await S3.head(c, key: key, fetch: fetch) else {
            throw Failure.notVerified("it is not there")
        }
        guard after.size == local.size else {
            throw Failure.notVerified("\(after.size) bytes, not \(local.size)")
        }
        switch try await engine.etagVerdict(etag: after.etag, md5: local.md5) {
        case "match": break
        case "mismatch": throw Failure.notVerified("its content hash does not match")
        default:
            guard let back = try await S3.get(c, key: key, fetch: fetch),
                  S3.sha256Hex(back) == local.sha256 else {
                throw Failure.notVerified("what came back is not what went up")
            }
        }
        return (local.sha256, local.size)
    }

    /// `<model>.cloud`, beside where the model was.
    nonisolated static func sidecar(for model: URL) -> URL {
        model.deletingLastPathComponent().appending(path: model.lastPathComponent + ".cloud")
    }

    /// Bring a model that was moved to the cloud back to where it was. A model
    /// that is here already is left alone. Size then SHA-256 must match what
    /// the sidecar recorded, or nothing is written.
    static func bringBack(_ model: URL, config: Config?, engine: KhaytEngine) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: model.path) { return }
        let sideURL = sidecar(for: model)
        guard let text = try? String(contentsOf: sideURL, encoding: .utf8),
              let side = try await engine.parseSidecar(text) else { throw Failure.noSidecar }
        guard let config else { throw S3.Failure.notConfigured }
        // The key the SIDECAR recorded, not one rebuilt from today's prefix.
        guard let data = try await S3.get(config.s3, key: side.key, fetch: fetch) else {
            throw Failure.badDownload("the bucket no longer has it")
        }
        let verdict = try await engine.verifyRehydrate(side, size: data.count, sha256: S3.sha256Hex(data))
        guard verdict.ok else { throw Failure.badDownload(verdict.error) }
        let part = model.deletingLastPathComponent()
            .appending(path: model.lastPathComponent + ".part-\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: part, options: .atomic)
        if rename(part.path, model.path) != 0 {
            try? fm.removeItem(at: part)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try? fm.removeItem(at: sideURL)
    }

    /// The model files in the library, one level down (`<root>/<item>/<file>`)
    /// as the other app scans it — sidecars, pictures and notes left out by the
    /// shared rule, not here.
    nonisolated static func libraryFiles(root: String) -> [KhaytEngine.TierFile] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        let items = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        var out: [KhaytEngine.TierFile] = []
        for item in items {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let files = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys:
                            [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            for file in files {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
                guard values?.isDirectory != true else { continue }
                out.append(.init(filename: file.lastPathComponent, fullPath: file.path,
                                 size: Double(values?.fileSize ?? 0),
                                 mtimeMs: (values?.contentModificationDate ?? Date()).timeIntervalSince1970 * 1000,
                                 id: item.lastPathComponent))
            }
        }
        return out
    }
}

// MARK: - What the shop does with it

extension Shop {

    /// The bucket, opened for one use. Nil when none is set up.
    func cloudConfig() async -> CloudLibrary.Config? {
        await CloudLibrary.config(settings: settingsDict, build: source.build)
    }

    /// Is this model's file in the cloud rather than on this Mac?
    func isInCloudOnly(_ file: LibraryFile) -> Bool {
        guard modelFile(for: file) == nil, let dir = directory(for: file) else { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return contents.contains { $0.hasSuffix(".cloud") }
    }

    /// Put a test file in the bucket, read it back, and take it away again —
    /// the other app's Test button, the same probe key.
    func testCloudLibrary() async {
        cloudLibraryProblem = nil
        cloudLibraryNote = nil
        guard let config = await cloudConfig() else {
            cloudLibraryProblem = words.callIt("cl.not_set_up"); return
        }
        cloudLibraryBusy = true
        defer { cloudLibraryBusy = false }
        let key = S3.objectKey(prefix: config.s3.prefix, id: "_khayt-check",
                               filename: "probe-\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)).bin")
        let probe = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        do {
            try await S3.put(config.s3, key: key, data: probe, fetch: CloudLibrary.fetch)
            let back = try await S3.get(config.s3, key: key, fetch: CloudLibrary.fetch)
            try await S3.delete(config.s3, key: key, fetch: CloudLibrary.fetch)
            guard back == probe else { cloudLibraryProblem = words.callIt("cl.test_mismatch"); return }
            cloudLibraryNote = words.callIt("cl.test_ok")
        } catch {
            cloudLibraryProblem = words.callIt("cl.test_failed") + " " + Self.cloudSay(error)
        }
    }

    /// Back up these models to the bucket — after an import, when backing up
    /// is on. Best effort, like the other app's: a failure is said, never a
    /// reason to undo the import.
    func backUpToCloud(ids: [String]) async {
        guard let engine, let config = await cloudConfig(), config.backsUp else { return }
        var failed = 0
        for file in files where ids.contains(file.id) {
            guard let url = modelFile(for: file) else { continue }
            let key = S3.objectKey(prefix: config.s3.prefix, id: LibraryLocation.itemDirName(file.id),
                                   filename: url.lastPathComponent)
            do { try await CloudLibrary.ensureInBucket(config.s3, key: key, file: url, engine: engine) }
            catch { failed += 1 }
        }
        if failed > 0 { cloudLibraryProblem = words.callIt("cl.backup_some_failed", ["n": .number(Double(failed))]) }
    }

    /// Every model on this Mac, into the bucket — what the other app does only
    /// for new models, done for the library that was already here.
    func backUpWholeLibrary() async {
        cloudLibraryProblem = nil
        cloudLibraryNote = nil
        guard let engine, let config = await cloudConfig(), let roots = libraryRoots else {
            cloudLibraryProblem = words.callIt("cl.not_set_up"); return
        }
        cloudLibraryBusy = true
        defer { cloudLibraryBusy = false; cloudProgress = nil }
        let all = await Task.detached { CloudLibrary.libraryFiles(root: roots.primary) }.value
            .filter { !$0.filename.hasSuffix(".cloud") }
        var done = 0, failed = 0
        for file in all {
            cloudProgress = (done: done, total: all.count, name: file.filename)
            let key = S3.objectKey(prefix: config.s3.prefix, id: file.id ?? "", filename: file.filename)
            do { try await CloudLibrary.ensureInBucket(config.s3, key: key, file: URL(fileURLWithPath: file.fullPath), engine: engine) }
            catch { failed += 1 }
            done += 1
        }
        cloudLibraryNote = words.callIt("cl.backed_up_all", ["n": .number(Double(done - failed)),
                                                              "total": .number(Double(all.count))])
        if failed > 0 { cloudLibraryProblem = words.callIt("cl.backup_some_failed", ["n": .number(Double(failed))]) }
    }

    /// Move the models nobody has used for a while to the cloud, freeing this
    /// Mac's disk. Each is proved to be in the bucket before its local copy
    /// goes; see `CloudLibrary.ensureInBucket`.
    func freeUpSpace() async {
        cloudLibraryProblem = nil
        cloudLibraryNote = nil
        guard let engine, let config = await cloudConfig(), let roots = libraryRoots else {
            cloudLibraryProblem = words.callIt("cl.not_set_up"); return
        }
        guard config.tierEnabled else { cloudLibraryProblem = words.callIt("cl.tier_off"); return }
        cloudLibraryBusy = true
        defer { cloudLibraryBusy = false; cloudProgress = nil }
        let all = await Task.detached { CloudLibrary.libraryFiles(root: roots.primary) }.value
        guard let plan = try? await engine.tierPlan(all, policy: config.tier, now: Date()) else { return }
        var moved = 0, freed = 0.0
        var failures: [String] = []
        for (i, file) in plan.candidates.enumerated() {
            cloudProgress = (done: i, total: plan.candidates.count, name: file.filename)
            let url = URL(fileURLWithPath: file.fullPath)
            let key = S3.objectKey(prefix: config.s3.prefix, id: file.id ?? "", filename: file.filename)
            do {
                let proved = try await CloudLibrary.ensureInBucket(config.s3, key: key, file: url, engine: engine)
                // The sidecar FIRST, then the file: a crash between the two
                // leaves both, which is a model that is here and also noted as
                // in the cloud — never one that is neither.
                let text = try await engine.sidecarText(size: proved.size, sha256: proved.sha256, key: key,
                                                        provider: config.s3.endpoint,
                                                        at: ISO8601DateFormatter().string(from: Date()))
                try Data(text.utf8).write(to: CloudLibrary.sidecar(for: url), options: .atomic)
                try FileManager.default.removeItem(at: url)
                moved += 1
                freed += Double(proved.size)
            } catch {
                failures.append(file.filename + ": " + Self.cloudSay(error))
            }
        }
        let human = (try? await engine.formatBytes(freed)) ?? "\(Int(freed)) B"
        cloudLibraryNote = words.callIt("cl.freed", ["n": .number(Double(moved)),
                                                     "total": .number(Double(plan.candidates.count)),
                                                     "size": .string(human)])
        if !failures.isEmpty { cloudLibraryProblem = failures.prefix(3).joined(separator: "\n") }
        await load(source)
    }

    /// Bring one model back from the cloud, for a shop about to use it.
    func bringBack(_ file: LibraryFile) async {
        cloudLibraryProblem = nil
        guard let engine, let dir = directory(for: file) else { return }
        let sidecars = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".cloud") }
        cloudLibraryBusy = true
        defer { cloudLibraryBusy = false }
        let config = await cloudConfig()
        for name in sidecars {
            let model = dir.appending(path: String(name.dropLast(".cloud".count)))
            do { try await CloudLibrary.bringBack(model, config: config, engine: engine) }
            catch { cloudLibraryProblem = words.callIt("cl.bring_back_failed") + " " + Self.cloudSay(error) }
        }
        await load(source)
    }

    /// Every model that was moved to the cloud, back onto this Mac.
    func bringEverythingBack() async {
        cloudLibraryProblem = nil
        cloudLibraryNote = nil
        guard let engine, let roots = libraryRoots else { return }
        let config = await cloudConfig()
        cloudLibraryBusy = true
        defer { cloudLibraryBusy = false; cloudProgress = nil }
        let sidecars = await Task.detached { CloudLibrary.libraryFiles(root: roots.primary) }.value
            .filter { $0.filename.hasSuffix(".cloud") }
        var back = 0
        var failures: [String] = []
        for (i, side) in sidecars.enumerated() {
            cloudProgress = (done: i, total: sidecars.count, name: side.filename)
            let model = URL(fileURLWithPath: String(side.fullPath.dropLast(".cloud".count)))
            do { try await CloudLibrary.bringBack(model, config: config, engine: engine); back += 1 }
            catch { failures.append(model.lastPathComponent + ": " + Self.cloudSay(error)) }
        }
        cloudLibraryNote = words.callIt("cl.brought_back", ["n": .number(Double(back))])
        if !failures.isEmpty { cloudLibraryProblem = failures.prefix(3).joined(separator: "\n") }
        await load(source)
    }

    /// What the settings pane shows before anything is pressed: how many
    /// models could move, and how much that frees.
    func cloudTierSummary() async -> (count: Int, size: String, inCloud: Int)? {
        guard let engine, let roots = libraryRoots, let config = await cloudConfig() else { return nil }
        let all = await Task.detached { CloudLibrary.libraryFiles(root: roots.primary) }.value
        let inCloud = all.filter { $0.filename.hasSuffix(".cloud") }.count
        guard let plan = try? await engine.tierPlan(all, policy: config.tier, now: Date()) else { return nil }
        return (plan.candidates.count, (try? await engine.formatBytes(plan.bytes)) ?? "", inCloud)
    }

    /// Save the bucket, as the other app's settings page writes it: the whole
    /// `printLibrary.s3` and `.tier` objects, the secret sealed, a blank secret
    /// keeping the one that is stored.
    func saveCloudLibrary(provider: String, endpoint: String, bucket: String, region: String,
                          prefix: String, accessKeyId: String, typedSecret: String,
                          backsUp: Bool, tierOn: Bool, keepDays: Int) async {
        cloudLibraryProblem = nil
        cloudLibraryNote = nil
        guard let build = source.build else { cloudLibraryProblem = words.callIt("mac.settings_sample"); return }
        var sealed: String?
        if !typedSecret.isEmpty {
            do { sealed = try await Secrets.seal(typedSecret, for: build) }
            catch { cloudLibraryProblem = Self.cloudSay(error); return }
        }
        do {
            try StoreWriter.update(build) { root in
                var settings = Self.settings(root)
                var library: [String: JSONValue] = [:]
                if case .object(let l)? = settings["printLibrary"] { library = l }
                var s3: [String: JSONValue] = [:]
                if case .object(let o)? = library["s3"] { s3 = o }
                s3["enabled"] = .bool(backsUp)
                s3["provider"] = .string(provider)
                s3["endpoint"] = .string(endpoint.trimmingCharacters(in: .whitespaces))
                s3["bucket"] = .string(bucket.trimmingCharacters(in: .whitespaces))
                s3["region"] = .string(region.trimmingCharacters(in: .whitespaces).isEmpty ? "auto" : region)
                s3["prefix"] = .string(prefix.trimmingCharacters(in: .whitespaces))
                s3["accessKeyId"] = .string(accessKeyId.trimmingCharacters(in: .whitespaces))
                if let sealed { s3["secretAccessKey"] = .string(sealed) }
                library["s3"] = .object(s3)
                var tier: [String: JSONValue] = [:]
                if case .object(let t)? = library["tier"] { tier = t }
                tier["enabled"] = .bool(tierOn)
                tier["keepDays"] = .number(Double(max(1, keepDays)))
                library["tier"] = .object(tier)
                settings["printLibrary"] = .object(library)
                root["settings"] = .object(settings)
            }
            await load(source)
            cloudLibraryNote = words.callIt("cl.saved")
        } catch {
            cloudLibraryProblem = Self.cloudSay(error)
        }
    }

    nonisolated static func cloudSay(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
