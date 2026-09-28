import Foundation
import AppKit
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
                          backsUp: driveBacksUp(section(library, "gdrive")), provider: "gdrive",
                          tier: tier, tierEnabled: tierOn)
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

    // MARK: - What the settings say, without opening a secret

    /// Which remote the library is using, read off the settings alone — the
    /// same order as `config`, with "set up" meaning its credentials are
    /// stored rather than that they open. The settings pane asks this.
    ///
    /// ── THE FLIP THIS REPLACES ────────────────────────────────────────────
    ///
    /// The pane used to work it out as `gdrive.enabled && !backsUp`, where
    /// `backsUp` was the bucket form's own default — `true` — whenever the
    /// book had NO `s3` block at all. So a shop with only Google Drive, just
    /// connected, was shown "A storage bucket": the missing bucket counted as
    /// a bucket that was backing up. Reported on alpha.54.
    enum Remote: Equatable, Sendable { case none, drive, bucket }

    static func remoteInUse(_ settings: [String: JSONValue]) -> Remote {
        guard case .object(let library)? = settings["printLibrary"] else { return .none }
        let s3 = section(library, "s3"), gd = section(library, "gdrive")
        let bucketSetUp = ["endpoint", "bucket", "accessKeyId", "secretAccessKey"].allSatisfy { !text(s3, $0).isEmpty }
        if bucketSetUp, on(s3) { return .bucket }
        if on(gd), driveConnected(settings) { return .drive }
        return bucketSetUp ? .bucket : .none
    }

    /// A Google account is signed in on this book: a refresh token is kept.
    static func driveConnected(_ settings: [String: JSONValue]) -> Bool {
        guard case .object(let library)? = settings["printLibrary"] else { return false }
        return !text(section(library, "gdrive"), "refreshToken").isEmpty
    }

    /// The folder in the shop's Drive: the one it named, or Khayt's own.
    static let defaultDriveFolder = "Khayt print library"
    static func driveFolder(_ settings: [String: JSONValue]) -> String {
        guard case .object(let library)? = settings["printLibrary"] else { return defaultDriveFolder }
        let n = text(section(library, "gdrive"), "folderName")
        return n.isEmpty ? defaultDriveFolder : n
    }

    /// The folder name to write at Connect: what was typed; else the name the
    /// shop already has (never overwritten by a blank field); else Khayt's.
    static func folderToWrite(typed: String, stored: JSONValue?) -> String {
        let t = typed.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
        if case .string(let s)? = stored, !s.trimmingCharacters(in: .whitespaces).isEmpty {
            return s.trimmingCharacters(in: .whitespaces)
        }
        return defaultDriveFolder
    }

    /// New models are copied to Drive as they come in unless the shop said
    /// not to (`backUpNew: false`). Absent is on: Drive has always backed up
    /// new models, here and in the other app — which does not read this
    /// switch, and keeps copying when it is the one importing.
    static func driveBacksUp(_ gd: [String: JSONValue]) -> Bool {
        if case .bool(false)? = gd["backUpNew"] { return false }
        return true
    }

    /// Who is signed in to Drive and how full it is, said for the status card.
    struct DriveStatus: Equatable, Sendable {
        var email: String
        var used: String
        var limit: String?
        /// Used over limit, 0…1, for the bar; nil for an unlimited Drive.
        var fraction: Double?
    }

    /// The two options under the status card, as the settings say them now.
    struct Options: Equatable, Sendable {
        var backsUp = true
        var tierOn = false
        var keepDays = 90
    }

    static func options(_ settings: [String: JSONValue]) -> Options {
        var o = Options()
        guard case .object(let library)? = settings["printLibrary"] else { return o }
        switch remoteInUse(settings) {
        case .bucket: o.backsUp = on(section(library, "s3"))
        case .drive, .none: o.backsUp = driveBacksUp(section(library, "gdrive"))
        }
        let t = section(library, "tier")
        o.tierOn = on(t)
        if case .number(let n)? = t["keepDays"], n >= 1 { o.keepDays = Int(n) }
        return o
    }

    /// Write the options into a book, for whichever remote is in use: the
    /// bucket's `enabled` when it is the bucket, Drive's `backUpNew`
    /// otherwise. Everything else in `printLibrary` is left as it was.
    static func applyOptions(_ o: Options, to root: inout [String: JSONValue]) {
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }
        let using = remoteInUse(settings)
        var library: [String: JSONValue] = [:]
        if case .object(let l)? = settings["printLibrary"] { library = l }
        if using == .bucket {
            var s3 = section(library, "s3"); s3["enabled"] = .bool(o.backsUp); library["s3"] = .object(s3)
        } else {
            var gd = section(library, "gdrive"); gd["backUpNew"] = .bool(o.backsUp); library["gdrive"] = .object(gd)
        }
        var tier = section(library, "tier")
        tier["enabled"] = .bool(o.tierOn)
        tier["keepDays"] = .number(Double(max(1, o.keepDays)))
        library["tier"] = .object(tier)
        settings["printLibrary"] = .object(library)
        root["settings"] = .object(settings)
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
                gd["folderName"] = .string(CloudLibrary.folderToWrite(typed: folderName, stored: gd["folderName"]))
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

    /// Open a page in the shop's default browser and bring the browser forward.
    static func openInBrowser(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(url, configuration: config) { _, error in
            if let error {
                FileHandle.standardError.write(Data("khayt: could not open the browser — \(error)\n".utf8))
            }
        }
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
            // THE PAGE IS OPENED HERE, on the main actor, and kept on screen.
            // The default opener ran off the main thread inside the sign-in
            // and its failure was silent: the shop saw "Waiting for the
            // sign-in in your browser" with no browser page anywhere ("nothing
            // opened"). Now the link is held for the pane to offer, and the
            // browser is asked to come to the front.
            let refresh = try await GoogleSignIn.run(clientId: id, clientSecret: secret, words: words,
                                                     fetch: CloudLibrary.fetch,
                                                     open: { url in
                                                         Task { @MainActor in
                                                             self.googleSignInURL = url
                                                             Self.openInBrowser(url)
                                                         }
                                                     })
            googleSignInURL = nil
            try await writeDrive(refreshToken: refresh, enabled: true, bucketOff: true)
            cloudLibraryNote = words.callIt("mac.gdrive_connected")
        } catch {
            googleSignInURL = nil
            cloudLibraryNote = nil
            cloudLibraryProblem = cloudSay(error)
        }
    }

    /// The options under the status card, written as soon as they change —
    /// there is no Save to forget. A book that cannot be written (the
    /// sample) says so.
    ///
    /// This replaces Drive's Save, which wrote the folder and the tier rule
    /// together and was the one button on the Drive screen a shop had to
    /// find. The folder is given at Connect now, and the client id with it,
    /// so nothing typed can be lost between the two (the "all I got was
    /// saved" report that Save once caused).
    func setLibraryOptions(_ options: CloudLibrary.Options) async {
        cloudLibraryProblem = nil
        guard let build = source.build else { cloudLibraryProblem = words.callIt("mac.settings_sample"); return }
        do {
            try StoreWriter.update(build) { root in CloudLibrary.applyOptions(options, to: &root) }
            await load(source)
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
    /// The signed-in account, whichever remote the library is using — the
    /// status card asks for it even while a bucket takes the models.
    func googleDriveStatus() async -> CloudLibrary.DriveStatus? {
        guard let engine, let d = await CloudLibrary.libraryDrive(settings: settingsDict, build: source.build) else {
            return nil
        }
        do {
            let about = try await DriveClient(d.config, fetch: CloudLibrary.fetch).about()
            let used = (try? await engine.formatBytes(about.usage)) ?? ""
            var limit: String?
            if let l = about.limit { limit = try? await engine.formatBytes(l) }
            return .init(email: about.email, used: used, limit: limit,
                         fraction: about.limit.flatMap { $0 > 0 ? min(1, about.usage / $0) : nil })
        } catch {
            cloudLibraryProblem = cloudSay(error)
            return nil
        }
    }

    /// Save the bucket, as the other app's settings page writes it: the whole
    /// `printLibrary.s3` and `.tier` objects, the secret sealed, a blank secret
    /// keeping the one that is stored.
    ///
    /// Saving the bucket is CHOOSING it: `enabled` goes on, so the bucket is
    /// the library's remote from here (it wins over Drive, as in the other
    /// app). The two options — backing up, freeing space — are the status
    /// area's switches and are left as they are; see `setLibraryOptions`.
    func saveCloudLibrary(provider: String, endpoint: String, bucket: String, region: String,
                          prefix: String, accessKeyId: String, typedSecret: String) async {
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
                s3["enabled"] = .bool(true)
                s3["provider"] = .string(provider)
                s3["endpoint"] = .string(endpoint.trimmingCharacters(in: .whitespaces))
                s3["bucket"] = .string(bucket.trimmingCharacters(in: .whitespaces))
                s3["region"] = .string(region.trimmingCharacters(in: .whitespaces).isEmpty ? "auto" : region)
                s3["prefix"] = .string(prefix.trimmingCharacters(in: .whitespaces))
                s3["accessKeyId"] = .string(accessKeyId.trimmingCharacters(in: .whitespaces))
                if let sealed { s3["secretAccessKey"] = .string(sealed) }
                library["s3"] = .object(s3)
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
