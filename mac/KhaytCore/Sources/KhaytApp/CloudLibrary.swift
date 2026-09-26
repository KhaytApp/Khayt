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

    /// Where the library's remote copy is, as the book describes it, with
    /// its secrets opened for this use only. Nil when none is set up.
    struct Config {
        var remote: LibraryRemote
        /// Put in front of every key — the bucket's folder; empty for Drive.
        var prefix: String
        /// New models are backed up as they come in (`enabled` on whichever
        /// remote this is).
        var backsUp: Bool
        /// What the sidecar records as where it went.
        var provider: String
        /// `settings.printLibrary.tier`, as the shared rule reads it.
        var tier: JSONValue
        var tierEnabled: Bool
        var isDrive: Bool { if case .drive = remote { true } else { false } }
    }

    /// The bucket when it is switched on, else Google Drive when that is,
    /// else a bucket that is set up but not backing up (so moved models can
    /// still be brought back) — `printLibRemote()` in the other app, which
    /// prefers the bucket when both are on.
    static func config(settings: [String: JSONValue], build: StoreReader.Build?) async -> Config? {
        guard case .object(let library)? = settings["printLibrary"] else { return nil }
        let tier = library["tier"] ?? .object([:])
        var tierOn = false
        if case .object(let t) = tier, case .bool(true)? = t["enabled"] { tierOn = true }

        var bucket: Config?
        if let c = await libraryBucket(settings: settings, build: build) {
            bucket = Config(remote: .bucket(c), prefix: c.prefix, backsUp: on(section(library, "s3")),
                            provider: c.endpoint, tier: tier, tierEnabled: tierOn)
        }
        if let bucket, bucket.backsUp { return bucket }

        if on(section(library, "gdrive")), let d = await libraryDrive(settings: settings, build: build) {
            return Config(remote: .drive(DriveClient(d.config, fetch: fetch)), prefix: d.prefix,
                          backsUp: true, provider: "gdrive", tier: tier, tierEnabled: tierOn)
        }
        return bucket
    }

    /// The library's bucket, set up and with its secret opened — whether or
    /// not the library is backing up to it. Nil when it is not set up, or its
    /// secret will not open on this Mac. The off-site backup reuses it.
    static func libraryBucket(settings: [String: JSONValue], build: StoreReader.Build?) async -> S3Config? {
        guard case .object(let library)? = settings["printLibrary"] else { return nil }
        let s3 = section(library, "s3")
        guard let secret = await open(text(s3, "secretAccessKey"), build: build) else { return nil }
        let c = S3Config(endpoint: text(s3, "endpoint"), bucket: text(s3, "bucket"), region: text(s3, "region"),
                         accessKeyId: text(s3, "accessKeyId"), secretAccessKey: secret, prefix: text(s3, "prefix"))
        return c.isConfigured ? c : nil
    }

    /// The library's Google Drive sign-in, whether or not the library is
    /// using it. Nil when there is none on this book.
    static func libraryDrive(settings: [String: JSONValue],
                             build: StoreReader.Build?) async -> (config: DriveClient.Config, prefix: String)? {
        guard case .object(let library)? = settings["printLibrary"] else { return nil }
        let gd = section(library, "gdrive")
        guard let refresh = await open(text(gd, "refreshToken"), build: build),
              let secret = await open(text(gd, "clientSecret"), build: build) else { return nil }
        let d = DriveClient.Config(clientId: text(gd, "clientId"), clientSecret: secret,
                                   refreshToken: refresh, folderName: text(gd, "folderName"))
        return d.isConfigured ? (d, text(gd, "prefix")) : nil
    }

    private static func open(_ value: String, build: StoreReader.Build?) async -> String? {
        guard value.hasPrefix(SafeStorage.marker) else { return value }
        guard let build else { return nil }
        return try? await Secrets.open(value, for: build)
    }
    private static func section(_ library: [String: JSONValue], _ key: String) -> [String: JSONValue] {
        if case .object(let o)? = library[key] { return o } else { return [:] }
    }
    private static func text(_ o: [String: JSONValue], _ key: String) -> String {
        if case .string(let v)? = o[key] { return v.trimmingCharacters(in: .whitespaces) }
        return ""
    }
    private static func on(_ o: [String: JSONValue]) -> Bool {
        if case .bool(true)? = o["enabled"] { true } else { false }
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

    /// What went wrong, said in the shop's language by `Shop.cloudSay`.
    enum Failure: Error, Equatable {
        case notThere
        case wrongSize(there: Int, here: Int)
        case hashMismatch
        case readBackDiffers
        case noSidecar
        case bucketLostIt
        /// The shared rule's own reason (`verifyRehydrate`).
        case badDownload(String)
    }

    /// Make sure the bucket holds exactly this file under `key`: skip the
    /// upload when it already does, and PROVE it afterwards with a second,
    /// separate request. `lib/print-library-tier.js etagVerdict` decides what
    /// an etag proves; an unusable one is checked by downloading and hashing.
    @discardableResult
    static func ensureInBucket(_ c: LibraryRemote, key: String, file: URL,
                               engine: KhaytEngine) async throws -> (sha256: String, size: Int) {
        let local = try await Task.detached { try Self.digests(of: file) }.value
        if let there = try await c.head(key, fetch: fetch), there.size == local.size,
           try await engine.etagVerdict(etag: there.etag, md5: local.md5) == "match" {
            return (local.sha256, local.size)
        }
        let data = try await Task.detached { try Data(contentsOf: file, options: .mappedIfSafe) }.value
        try await c.put(key, data: data, fetch: fetch)
        guard let after = try await c.head(key, fetch: fetch) else {
            throw Failure.notThere
        }
        guard after.size == local.size else {
            throw Failure.wrongSize(there: after.size, here: local.size)
        }
        switch try await engine.etagVerdict(etag: after.etag, md5: local.md5) {
        case "match": break
        case "mismatch": throw Failure.hashMismatch
        default:
            guard let back = try await c.get(key, fetch: fetch),
                  S3.sha256Hex(back) == local.sha256 else {
                throw Failure.readBackDiffers
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
        guard let data = try await config.remote.get(side.key, fetch: fetch) else {
            throw Failure.bucketLostIt
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
            cloudLibraryProblem = words.callIt("mac.cloudlib_not_set_up"); return
        }
        cloudLibraryBusy = true
        defer { cloudLibraryBusy = false }
        let key = S3.objectKey(prefix: config.prefix, id: "_khayt-check",
                               filename: "probe-\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)).bin")
        let probe = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        do {
            try await config.remote.put(key, data: probe, fetch: CloudLibrary.fetch)
            let back = try await config.remote.get(key, fetch: CloudLibrary.fetch)
            try await config.remote.delete(key, fetch: CloudLibrary.fetch)
            guard back == probe else { cloudLibraryProblem = words.callIt("mac.cloudlib_test_mismatch"); return }
            cloudLibraryNote = words.callIt("mac.cloudlib_test_ok")
        } catch {
            cloudLibraryProblem = words.callIt("mac.cloudlib_test_failed") + " " + cloudSay(error)
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
            let key = S3.objectKey(prefix: config.prefix, id: LibraryLocation.itemDirName(file.id),
                                   filename: url.lastPathComponent)
            do { try await CloudLibrary.ensureInBucket(config.remote, key: key, file: url, engine: engine) }
            catch { failed += 1 }
        }
        if failed > 0 { cloudLibraryProblem = words.callIt("mac.cloudlib_backup_some_failed", ["n": .number(Double(failed))]) }
    }

    /// Every model on this Mac, into the bucket — what the other app does only
    /// for new models, done for the library that was already here.
    func backUpWholeLibrary() async {
        cloudLibraryProblem = nil
        cloudLibraryNote = nil
        guard let engine, let config = await cloudConfig(), let roots = libraryRoots else {
            cloudLibraryProblem = words.callIt("mac.cloudlib_not_set_up"); return
        }
        cloudLibraryBusy = true
        defer { cloudLibraryBusy = false; cloudProgress = nil }
        let all = await Task.detached { CloudLibrary.libraryFiles(root: roots.primary) }.value
            .filter { !$0.filename.hasSuffix(".cloud") }
        var done = 0, failed = 0
        for file in all {
            cloudProgress = (done: done, total: all.count, name: file.filename)
            let key = S3.objectKey(prefix: config.prefix, id: file.id ?? "", filename: file.filename)
            do { try await CloudLibrary.ensureInBucket(config.remote, key: key, file: URL(fileURLWithPath: file.fullPath), engine: engine) }
            catch { failed += 1 }
            done += 1
        }
        cloudLibraryNote = words.callIt("mac.cloudlib_backed_up_all", ["n": .number(Double(done - failed)),
                                                              "total": .number(Double(all.count))])
        if failed > 0 { cloudLibraryProblem = words.callIt("mac.cloudlib_backup_some_failed", ["n": .number(Double(failed))]) }
    }

    /// Move the models nobody has used for a while to the cloud, freeing this
    /// Mac's disk. Each is proved to be in the bucket before its local copy
    /// goes; see `CloudLibrary.ensureInBucket`.
    func freeUpSpace() async {
        cloudLibraryProblem = nil
        cloudLibraryNote = nil
        guard let engine, let config = await cloudConfig(), let roots = libraryRoots else {
            cloudLibraryProblem = words.callIt("mac.cloudlib_not_set_up"); return
        }
        guard config.tierEnabled else { cloudLibraryProblem = words.callIt("mac.cloudlib_tier_off"); return }
        cloudLibraryBusy = true
        defer { cloudLibraryBusy = false; cloudProgress = nil }
        let all = await Task.detached { CloudLibrary.libraryFiles(root: roots.primary) }.value
        guard let plan = try? await engine.tierPlan(all, policy: config.tier, now: Date()) else { return }
        var moved = 0, freed = 0.0
        var failures: [String] = []
        for (i, file) in plan.candidates.enumerated() {
            cloudProgress = (done: i, total: plan.candidates.count, name: file.filename)
            let url = URL(fileURLWithPath: file.fullPath)
            let key = S3.objectKey(prefix: config.prefix, id: file.id ?? "", filename: file.filename)
            do {
                let proved = try await CloudLibrary.ensureInBucket(config.remote, key: key, file: url, engine: engine)
                // The sidecar FIRST, then the file: a crash between the two
                // leaves both, which is a model that is here and also noted as
                // in the cloud — never one that is neither.
                let text = try await engine.sidecarText(size: proved.size, sha256: proved.sha256, key: key,
                                                        provider: config.provider,
                                                        at: ISO8601DateFormatter().string(from: Date()))
                try Data(text.utf8).write(to: CloudLibrary.sidecar(for: url), options: .atomic)
                try FileManager.default.removeItem(at: url)
                moved += 1
                freed += Double(proved.size)
            } catch {
                failures.append(file.filename + ": " + cloudSay(error))
            }
        }
        let human = (try? await engine.formatBytes(freed)) ?? ""
        cloudLibraryNote = words.callIt("mac.cloudlib_freed", ["n": .number(Double(moved)),
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
            catch { cloudLibraryProblem = words.callIt("mac.cloudlib_bring_back_failed") + " " + cloudSay(error) }
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
            catch { failures.append(model.lastPathComponent + ": " + cloudSay(error)) }
        }
        cloudLibraryNote = words.callIt("mac.cloudlib_brought_back", ["n": .number(Double(back))])
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

    // MARK: - Google Drive

    /// Write `printLibrary.gdrive`, merged over what is there — as the other
    /// app's `savePrintLibGDrive` does. `nil` leaves a field alone; secrets are
    /// sealed on the way in.
    private func writeDrive(clientId: String? = nil, clientSecret: String? = nil, refreshToken: String? = nil,
                            folderName: String? = nil, enabled: Bool? = nil, bucketOff: Bool = false) async throws {
        guard let build = source.build else { throw S3.Failure.notConfigured }
        var sealedSecret: String?
        if let clientSecret { sealedSecret = clientSecret.isEmpty ? "" : try await Secrets.seal(clientSecret, for: build) }
        var sealedToken: String?
        if let refreshToken { sealedToken = refreshToken.isEmpty ? "" : try await Secrets.seal(refreshToken, for: build) }
        try StoreWriter.update(build) { root in
            var settings = Self.settings(root)
            var library: [String: JSONValue] = [:]
            if case .object(let l)? = settings["printLibrary"] { library = l }
            var gd: [String: JSONValue] = [:]
            if case .object(let o)? = library["gdrive"] { gd = o }
            if let clientId { gd["clientId"] = .string(clientId.trimmingCharacters(in: .whitespaces)) }
            if let sealedSecret { gd["clientSecret"] = .string(sealedSecret) }
            if let sealedToken { gd["refreshToken"] = .string(sealedToken); gd["folderId"] = .string("") }
            if let folderName {
                let n = folderName.trimmingCharacters(in: .whitespaces)
                gd["folderName"] = .string(n.isEmpty ? "Khayt print library" : n)
            }
            if let enabled { gd["enabled"] = .bool(enabled) }
            library["gdrive"] = .object(gd)
            // Drive chosen: the bucket stops backing up, or it would win.
            if bucketOff, case .object(var s3)? = library["s3"] {
                s3["enabled"] = .bool(false); library["s3"] = .object(s3)
            }
            settings["printLibrary"] = .object(library)
            root["settings"] = .object(settings)
        }
        await load(source)
    }

    /// Sign in to Google in the browser and keep what comes back. The client
    /// id is saved FIRST, as the other app does, so the sign-in is for the id
    /// on the screen.
    /// Khayt's own Google client, built into this copy of the app (see
    /// make-app.sh), or nil in a build without one.
    static var builtInGoogleClient: (id: String, secret: String)? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "KhaytGoogleClientID") as? String,
              !id.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let secret = Bundle.main.object(forInfoDictionaryKey: "KhaytGoogleClientSecret") as? String ?? ""
        return (id, secret)
    }

    func connectGoogleDrive(clientId: String, typedSecret: String, folderName: String) async {
        cloudLibraryProblem = nil
        cloudLibraryNote = nil
        // No client typed: Khayt's own, when this build carries one. One
        // click, as a shop expects from "Connect Google Drive".
        var clientId = clientId, typedSecret = typedSecret
        if clientId.trimmingCharacters(in: .whitespaces).isEmpty, let own = Self.builtInGoogleClient {
            clientId = own.id; typedSecret = own.secret
        }
        let id = clientId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { cloudLibraryProblem = words.callIt("mac.gdrive_need_client"); return }
        guard !cloudLibraryBusy else { return }
        cloudLibraryBusy = true
        cloudLibraryNote = words.callIt("mac.gdrive_waiting")
        defer { cloudLibraryBusy = false }
        do {
            let typed = typedSecret.trimmingCharacters(in: .whitespaces)
            try await writeDrive(clientId: id, clientSecret: typed.isEmpty ? nil : typed, folderName: folderName)
            // The secret as stored — typed now, or kept from before.
            var secret = typed
            if secret.isEmpty, case .object(let l)? = settingsDict["printLibrary"],
               case .object(let gd)? = l["gdrive"], case .string(let stored)? = gd["clientSecret"], !stored.isEmpty,
               let build = source.build {
                secret = (try? await Secrets.open(stored, for: build)) ?? ""
            }
            let refresh = try await GoogleSignIn.run(clientId: id, clientSecret: secret, words: words,
                                                     fetch: CloudLibrary.fetch)
            try await writeDrive(refreshToken: refresh, enabled: true, bucketOff: true)
            cloudLibraryNote = words.callIt("mac.gdrive_connected")
        } catch {
            cloudLibraryNote = nil
            cloudLibraryProblem = cloudSay(error)
        }
    }

    /// Save Drive's folder and the free-up-space rule, with Drive as the
    /// remote: the bucket's backing up is switched off, since the bucket wins
    /// whenever it is on.
    func saveDriveLibrary(folderName: String, tierOn: Bool, keepDays: Int,
                          clientId: String = "", typedSecret: String = "") async {
        cloudLibraryProblem = nil
        cloudLibraryNote = nil
        guard let build = source.build else { cloudLibraryProblem = words.callIt("mac.settings_sample"); return }
        do {
            // THE CLIENT ID IS KEPT. Save used to write only the folder and the
            // tier rule, then reload the form from the book — so the client id
            // and secret the shop had just typed vanished, Connect (which needs
            // an id) went grey, and the only answer on screen was "Saved".
            // Reported by the shop: "all I got was saved and nothing else".
            let id = clientId.trimmingCharacters(in: .whitespaces)
            if !id.isEmpty {
                let typed = typedSecret.trimmingCharacters(in: .whitespaces)
                try await writeDrive(clientId: id, clientSecret: typed.isEmpty ? nil : typed, folderName: folderName)
            }
            try StoreWriter.update(build) { root in
                var settings = Self.settings(root)
                var library: [String: JSONValue] = [:]
                if case .object(let l)? = settings["printLibrary"] { library = l }
                var gd: [String: JSONValue] = [:]
                if case .object(let o)? = library["gdrive"] { gd = o }
                let n = folderName.trimmingCharacters(in: .whitespaces)
                gd["folderName"] = .string(n.isEmpty ? "Khayt print library" : n)
                library["gdrive"] = .object(gd)
                if case .object(var s3)? = library["s3"] { s3["enabled"] = .bool(false); library["s3"] = .object(s3) }
                var tier: [String: JSONValue] = [:]
                if case .object(let t)? = library["tier"] { tier = t }
                tier["enabled"] = .bool(tierOn)
                tier["keepDays"] = .number(Double(max(1, keepDays)))
                library["tier"] = .object(tier)
                settings["printLibrary"] = .object(library)
                root["settings"] = .object(settings)
            }
            await load(source)
            // Saved is not connected: say what is left to do.
            var connected = false
            if case .object(let l)? = settingsDict["printLibrary"], case .object(let gd)? = l["gdrive"],
               case .string(let t)? = gd["refreshToken"] { connected = !t.isEmpty }
            cloudLibraryNote = words.callIt(connected ? "mac.cloudlib_saved" : "mac.gdrive_saved_connect")
        } catch {
            cloudLibraryProblem = cloudSay(error)
        }
    }

    /// Forget the account here. Only Google can withdraw the access itself,
    /// and the note says so rather than overstating what this did.
    func disconnectGoogleDrive() async {
        cloudLibraryProblem = nil
        do {
            try await writeDrive(refreshToken: "", enabled: false)
            cloudLibraryNote = words.callIt("mac.gdrive_disconnected")
        } catch {
            cloudLibraryProblem = cloudSay(error)
        }
    }

    /// Who is connected and how full their Drive is — asked of Google, not
    /// read off the settings: a revoked grant looks like a working one there.
    func googleDriveStatus() async -> (email: String, used: String, limit: String?)? {
        guard let engine, let config = await cloudConfig(), case .drive(let drive) = config.remote else { return nil }
        do {
            let about = try await drive.about()
            let used = (try? await engine.formatBytes(about.usage)) ?? ""
            var limit: String?
            if let l = about.limit { limit = try? await engine.formatBytes(l) }
            return (about.email, used, limit)
        } catch {
            cloudLibraryProblem = cloudSay(error)
            return nil
        }
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
            catch { cloudLibraryProblem = cloudSay(error); return }
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
            cloudLibraryNote = words.callIt("mac.cloudlib_saved")
        } catch {
            cloudLibraryProblem = cloudSay(error)
        }
    }

    /// An error from the bucket, in the shop's language when it is one of
    /// ours; the system's own description otherwise.
    func cloudSay(_ error: Error) -> String {
        if let g = error as? GoogleSignIn.Failure {
            switch g {
            case .google(let said): return words.callIt("mac.gdrive_page_google_said") + " " + said
            case .wrongState: return words.callIt("mac.gdrive_page_wrong_state")
            case .noCode: return words.callIt("mac.gdrive_page_no_code")
            case .noRefreshToken: return words.callIt("mac.gdrive_no_refresh")
            case .timedOut: return words.callIt("mac.gdrive_timed_out")
            case .listener(let why): return words.callIt("mac.gdrive_no_listener") + " " + why
            }
        }
        if let d = error as? DriveClient.Failure {
            switch d {
            case .google(let said): return words.callIt("mac.gdrive_page_google_said") + " " + said
            case .http(let what, let code): return words.callIt("mac.gdrive_http", ["what": .string(what), "code": .number(Double(code))])
            case .noAccessToken, .noUploadURL, .noFolder: return words.callIt("mac.gdrive_refused")
            }
        }
        guard let f = error as? CloudLibrary.Failure else {
            return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        switch f {
        case .notThere: return words.callIt("mac.cloudlib_not_there")
        case .wrongSize(let there, let here):
            return words.callIt("mac.cloudlib_wrong_size", ["there": .number(Double(there)), "here": .number(Double(here))])
        case .hashMismatch: return words.callIt("mac.cloudlib_hash_mismatch")
        case .readBackDiffers: return words.callIt("mac.cloudlib_read_back_differs")
        case .noSidecar: return words.callIt("mac.cloudlib_no_sidecar")
        case .bucketLostIt: return words.callIt("mac.cloudlib_bucket_lost_it")
        case .badDownload(let why): return words.callIt("mac.cloudlib_bad_download") + " " + why
        }
    }
}
