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
        /// New models are backed up as they come in (`backUpNew` on whichever
        /// remote this is — see `bucketBacksUp` / `driveBacksUp`).
        var backsUp: Bool
        /// What the sidecar records as where it went.
        var provider: String
        /// `settings.printLibrary.tier`, as the shared rule reads it.
        var tier: JSONValue
        var tierEnabled: Bool
        var isDrive: Bool { if case .drive = remote { true } else { false } }
    }

    /// The bucket when it is switched on, else Google Drive when that is,
    /// else a bucket that is set up but switched off (so moved models can
    /// still be brought back) — `printLibRemote()` in the other app, which
    /// prefers the bucket when both are on. The order is `pick`, shared with
    /// `remoteInUse` so the settings pane and the library cannot disagree.
    static func config(settings: [String: JSONValue], build: StoreReader.Build?) async -> Config? {
        guard case .object(let library)? = settings["printLibrary"] else { return nil }
        let tier = library["tier"] ?? .object([:])
        var tierOn = false
        if case .object(let t) = tier, case .bool(true)? = t["enabled"] { tierOn = true }

        let bucket = await libraryBucket(settings: settings, build: build)
        let drive = await libraryDrive(settings: settings, build: build)
        switch pick(library, bucketUsable: bucket != nil, driveUsable: drive != nil) {
        case .bucket:
            guard let c = bucket else { return nil }
            return Config(remote: .bucket(c), prefix: c.prefix, backsUp: bucketBacksUp(section(library, "s3")),
                          provider: c.endpoint, tier: tier, tierEnabled: tierOn)
        case .drive:
            guard let d = drive else { return nil }
            return Config(remote: .drive(DriveClient(d.config, fetch: fetch)), prefix: d.prefix,
                          backsUp: driveBacksUp(section(library, "gdrive")), provider: "gdrive",
                          tier: tier, tierEnabled: tierOn)
        case .none:
            return nil
        }
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

    /// THE order, for `config` and `remoteInUse` alike: a bucket switched on,
    /// else Drive switched on, else a bucket kept but switched off. "Usable"
    /// is the caller's: whether the credentials OPEN (`config`, the async
    /// `remoteInUse`) or are merely stored (the first frame of the pane).
    ///
    /// `enabled` is WHICH REMOTE, never whether new models are copied: that is
    /// `backUpNew` on each (see `bucketBacksUp`). Once it meant both, and
    /// turning the bucket's copy off switched the library to Google Drive.
    static func pick(_ library: [String: JSONValue], bucketUsable: Bool, driveUsable: Bool) -> Remote {
        if bucketUsable, on(section(library, "s3")) { return .bucket }
        if driveUsable, on(section(library, "gdrive")) { return .drive }
        return bucketUsable ? .bucket : .none
    }

    /// Read off the stored settings alone, without opening a secret — for
    /// the pane's first frame, which must not wait. A secret sealed on
    /// another Mac counts here and not in `config`; the pane corrects itself
    /// with the async form below as soon as it can.
    static func remoteInUse(_ settings: [String: JSONValue]) -> Remote {
        guard case .object(let library)? = settings["printLibrary"] else { return .none }
        let s3 = section(library, "s3"), gd = section(library, "gdrive")
        let bucketStored = ["endpoint", "bucket", "accessKeyId", "secretAccessKey"].allSatisfy { !text(s3, $0).isEmpty }
        let driveStored = !text(gd, "clientId").isEmpty && !text(gd, "refreshToken").isEmpty
        return pick(library, bucketUsable: bucketStored, driveUsable: driveStored)
    }

    /// The remote `config` will actually use on this Mac: the same `pick`,
    /// with the same test of each credential — that it opens here.
    static func remoteInUse(_ settings: [String: JSONValue], build: StoreReader.Build?) async -> Remote {
        guard case .object(let library)? = settings["printLibrary"] else { return .none }
        let bucket = await libraryBucket(settings: settings, build: build) != nil
        let drive = await libraryDrive(settings: settings, build: build) != nil
        return pick(library, bucketUsable: bucket, driveUsable: drive)
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

    /// New models are copied to the bucket: its own `backUpNew` when the
    /// shop has set it, else `enabled` — what the switch meant before the two
    /// were separated, so a book written then reads exactly as it did. The
    /// other app does not read `backUpNew`: it copies whenever the bucket is
    /// switched on, as it does for Drive.
    static func bucketBacksUp(_ s3: [String: JSONValue]) -> Bool {
        if case .bool(let b)? = s3["backUpNew"] { return b }
        return on(s3)
    }

    /// Make `remote` the library's remote in a `printLibrary` block, leaving
    /// each one's copy switch as it was. Switching to the other one and back
    /// is therefore not a way to lose "keep a copy: off" — and a bucket whose
    /// switch was only ever `enabled` has it written down as `backUpNew`
    /// before `enabled` is taken for the choice.
    static func choose(_ remote: Remote, in library: inout [String: JSONValue]) {
        var s3 = section(library, "s3"), gd = section(library, "gdrive")
        let bucketExisted = ["endpoint", "bucket", "accessKeyId"].contains { !text(s3, $0).isEmpty }
        if bucketExisted, s3["backUpNew"] == nil { s3["backUpNew"] = .bool(on(s3)) }
        switch remote {
        case .bucket:
            s3["enabled"] = .bool(true)
            if !gd.isEmpty { gd["enabled"] = .bool(false) }
        case .drive:
            gd["enabled"] = .bool(true)
            if !s3.isEmpty { s3["enabled"] = .bool(false) }
        case .none:
            break
        }
        if !s3.isEmpty { library["s3"] = .object(s3) }
        if !gd.isEmpty { library["gdrive"] = .object(gd) }
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

    /// `using` is the remote in use, as `remoteInUse(_:build:)` found it;
    /// left out, it is read off the stored settings.
    static func options(_ settings: [String: JSONValue], using: Remote? = nil) -> Options {
        var o = Options()
        guard case .object(let library)? = settings["printLibrary"] else { return o }
        switch using ?? remoteInUse(settings) {
        case .bucket: o.backsUp = bucketBacksUp(section(library, "s3"))
        case .drive, .none: o.backsUp = driveBacksUp(section(library, "gdrive"))
        }
        let t = section(library, "tier")
        o.tierOn = on(t)
        if case .number(let n)? = t["keepDays"], n >= 1 { o.keepDays = Int(n) }
        return o
    }

    /// The bucket's form, as typed.
    struct BucketForm: Equatable, Sendable {
        var provider, endpoint, bucket, region, prefix, accessKeyId: String
    }

    /// Write the bucket's form into a `printLibrary` block and choose it as
    /// the remote (it wins over Drive, as in the other app). Its copy switch
    /// is KEPT: saving a new key does not turn back on a backup the shop
    /// turned off. A bucket saved for the first time copies (absent is on).
    static func saveBucket(_ f: BucketForm, sealedSecret: String?, in library: inout [String: JSONValue]) {
        choose(.bucket, in: &library)
        var s3 = section(library, "s3")
        s3["provider"] = .string(f.provider)
        s3["endpoint"] = .string(f.endpoint.trimmingCharacters(in: .whitespaces))
        s3["bucket"] = .string(f.bucket.trimmingCharacters(in: .whitespaces))
        s3["region"] = .string(f.region.trimmingCharacters(in: .whitespaces).isEmpty ? "auto" : f.region)
        s3["prefix"] = .string(f.prefix.trimmingCharacters(in: .whitespaces))
        s3["accessKeyId"] = .string(f.accessKeyId.trimmingCharacters(in: .whitespaces))
        if let sealedSecret { s3["secretAccessKey"] = .string(sealedSecret) }
        library["s3"] = .object(s3)
    }

    /// Write the options into a book, for whichever remote is in use: that
    /// remote's own `backUpNew`. `enabled` is NOT touched — it chooses the
    /// remote, and writing the copy switch into it is how "Keep a copy" off
    /// once moved a shop's models to Google Drive. Everything else in
    /// `printLibrary` is left as it was.
    static func applyOptions(_ o: Options, using: Remote? = nil, to root: inout [String: JSONValue]) {
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }
        let using = using ?? remoteInUse(settings)
        var library: [String: JSONValue] = [:]
        if case .object(let l)? = settings["printLibrary"] { library = l }
        if using == .bucket {
            var s3 = section(library, "s3"); s3["backUpNew"] = .bool(o.backsUp); library["s3"] = .object(s3)
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
    ///
    /// The one remote it is given, whatever the sidecar says — kept for the
    /// callers that have only one. The shop's own path is `remotes:` below.
    static func bringBack(_ model: URL, config: Config?, engine: KhaytEngine) async throws {
        try await bringBack(model, remotes: { _ in config.map { [$0.remote] } ?? [] }, engine: engine)
    }

    /// The same, asking `remotes` WHERE the sidecar says the model went.
    ///
    /// ── THE SIDECAR NAMES ITS PROVIDER ─────────────────────────────────────
    ///
    /// It used to fetch from whichever remote is in use TODAY. A model moved
    /// to a bucket, then the library switched to Google Drive: every bring-back
    /// asked Drive, Drive had nothing, and the shop was told the cloud had lost
    /// a model that was sitting in the bucket the whole time. The sidecar's
    /// `provider` is asked first now (`remoteOrder`), then the other one — the
    /// other app writes the BUCKET's endpoint there even for a Drive move, so
    /// the field is a first guess, not a promise. Trying the second is safe:
    /// the hash below refuses anything that is not these exact bytes.
    static func bringBack(_ model: URL, remotes: (KhaytEngine.Sidecar) async -> [LibraryRemote],
        // lock: system — removes only its own half-written .part download.
                          engine: KhaytEngine) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: model.path) { return }
        let sideURL = sidecar(for: model)
        guard let text = try? String(contentsOf: sideURL, encoding: .utf8),
              let side = try await engine.parseSidecar(text) else { throw Failure.noSidecar }
        let candidates = await remotes(side)
        guard !candidates.isEmpty else { throw S3.Failure.notConfigured }
        var problem: Error?
        for remote in candidates {
            do {
                // The key the SIDECAR recorded, not one rebuilt from today's prefix.
                guard let data = try await remote.get(side.key, fetch: fetch) else { continue }
                let verdict = try await engine.verifyRehydrate(side, size: data.count, sha256: S3.sha256Hex(data))
                guard verdict.ok else { problem = Failure.badDownload(verdict.error); continue }
                let part = model.deletingLastPathComponent()
                    .appending(path: model.lastPathComponent + ".part-\(ProcessInfo.processInfo.processIdentifier)")
                try data.write(to: part, options: .atomic)
                if rename(part.path, model.path) != 0 {
                    try? fm.removeItem(at: part)
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try? fm.removeItem(at: sideURL)
                return
            } catch let e as POSIXError {
                throw e
            } catch {
                problem = error
            }
        }
        throw problem ?? Failure.bucketLostIt
    }

    /// Which remote a sidecar's `provider` names: `gdrive` is Drive; any other
    /// non-empty value is a bucket's endpoint; empty says nothing (nil).
    nonisolated static func route(provider: String?) -> Remote? {
        let p = (provider ?? "").trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return nil }
        return p == "gdrive" ? .drive : .bucket
    }

    /// The remotes to ask for a moved model, in order: the one its sidecar
    /// names (else the one in use), then the other.
    nonisolated static func remoteOrder(provider: String?, current: Remote) -> [Remote] {
        let first = route(provider: provider) ?? (current == .drive ? .drive : .bucket)
        return first == .drive ? [.drive, .bucket] : [.bucket, .drive]
    }

    /// How many moved models switching to `target` would leave on the OTHER
    /// remote — the ones whose sidecar names a remote that is not `target`.
    /// A sidecar that names none is counted as the remote in use.
    nonisolated static func stranded(switchingTo target: Remote, providers: [String?], current: Remote) -> Int {
        guard target != .none else { return 0 }
        return providers.filter { remoteOrder(provider: $0, current: current).first != target }.count
    }

    // MARK: - How long since a model was last needed

    /// The listing with what the book knows folded in: the import date, the
    /// last print, the jobs that name each model and whether one is still
    /// open.
    ///
    /// ── WHY NOT THE FILE'S MTIME ─────────────────────────────────────────
    ///
    /// `copyItem` keeps the original's modification time, so a model the shop
    /// downloaded in 2024 and imported last week read as two years unused:
    /// 113 of one shop's 328 models (1.39 GB), all imported in Sep 2026, were
    /// offered for "Free up space now". The record's own date, its last print
    /// and the jobs that name it are what "used" means; the mtime is only one
    /// more vote (`lib/print-library-tier.js evictable`, the newest wins).
    ///
    /// ── ONE RULE, NOT TWO ────────────────────────────────────────────────
    ///
    /// This was a Swift copy of the rule (#1706) beside the Electron app's
    /// (#1716) — the "tested copy vs shipped copy" shape. Both apps now call
    /// `usageFromBook` and `annotate` in `lib/print-library-tier.js`, over the
    /// book's raw `printFiles` and `printLog`; `TierUsageParityTests` runs the
    /// module under node and through the engine on the same book.
    static func annotated(_ listed: [KhaytEngine.TierFile], engine: KhaytEngine,
                          printFiles: [JSONValue], orders: [JSONValue]) async throws -> [KhaytEngine.TierFile] {
        try await engine.tierAnnotate(listed, printFiles: printFiles, orders: orders,
                                      dirNames: dirNames(printFiles: printFiles, orders: orders))
    }

    /// Every record id the book names — in the library and on a job's part —
    /// mapped to its item folder.
    nonisolated static func dirNames(printFiles: [JSONValue], orders: [JSONValue]) -> [String: String] {
        var ids: [String] = []
        for case .object(let f) in printFiles { if case .string(let id)? = f["id"] { ids.append(id) } }
        for case .object(let o) in orders {
            guard case .array(let parts)? = o["parts"] else { continue }
            for case .object(let p) in parts { if case .string(let id)? = p["printFileId"] { ids.append(id) } }
        }
        var out: [String: String] = [:]
        for id in ids where !id.isEmpty { out[id] = LibraryLocation.itemDirName(id) }
        return out
    }

    /// "a, b, c and 4 more" — the first few names in a confirmation.
    nonisolated static func firstNames(_ names: [String], shown: Int = 5, more: (Int) -> String) -> String {
        let head = names.prefix(shown).joined(separator: ", ")
        return names.count > shown ? head + " " + more(names.count - shown) : head
    }

    /// The model files in the library, one level down (`<root>/<item>/<file>`)
    /// as the other app scans it — sidecars, pictures and notes left out by the
    /// shared rule, not here.
    nonisolated static func libraryFiles(root: String) -> [KhaytEngine.TierFile] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        let rootReal = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let items = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        var out: [KhaytEngine.TierFile] = []
        for item in items {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey,
                                             .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            let files = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: Array(keys),
                                                     options: [.skipsHiddenFiles])) ?? []
            for file in files {
                let values = try? file.resourceValues(forKeys: keys)
                // Regular files only, and really inside the library. A symlink
                // in a vault folder points somewhere else on this Mac, and
                // tiering it would upload whatever that is to the shop's bucket.
                guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                      file.resolvingSymlinksInPath().standardizedFileURL.path
                        .hasPrefix(rootReal.hasSuffix("/") ? rootReal : rootReal + "/") else { continue }
                // When the file landed in its folder — the import, for a copy
                // whose mtime is still the download's. See `annotated`.
                let added = values?.addedToDirectoryDate.map { $0.timeIntervalSince1970 * 1000 }
                out.append(.init(filename: file.lastPathComponent, fullPath: file.path,
                                 size: Double(values?.fileSize ?? 0),
                                 mtimeMs: (values?.contentModificationDate ?? Date()).timeIntervalSince1970 * 1000,
                                 id: item.lastPathComponent, lastUsedMs: added))
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

    /// What the shared rule plans, with what the book knows folded in: the
    /// import date, the last print, the jobs still open — see
    /// `CloudLibrary.annotated`. No plan at all when the book's use cannot be
    /// read: planning on the mtimes alone would offer a model an open job
    /// still needs.
    private func tierPlan(engine: KhaytEngine, config: CloudLibrary.Config,
                          roots: LibraryLocation.Roots) async -> KhaytEngine.TierPlan? {
        let listed = await Task.detached { CloudLibrary.libraryFiles(root: roots.primary) }.value
        guard let all = try? await CloudLibrary.annotated(listed, engine: engine,
                                                          printFiles: fileRows, orders: orderRows) else { return nil }
        return try? await engine.tierPlan(all, policy: config.tier, now: Date())
    }

    /// What "Free up space now" would do, for the shop to confirm FIRST: how
    /// many models, how much, and the first few by name. Nil when nothing is
    /// set up; a preview with no paths when nothing qualifies.
    struct FreeUpPreview: Equatable, Sendable {
        var count: Int
        var size: String
        var names: [String]
        /// Exactly these, and no others, are moved when the shop says yes.
        var paths: Set<String>
        var destination: String
    }

    func freeUpSpacePreview() async -> FreeUpPreview? {
        cloudLibraryProblem = nil
        cloudLibraryNote = nil
        guard let engine, let config = await cloudConfig(), let roots = libraryRoots else {
            cloudLibraryProblem = words.callIt("mac.cloudlib_not_set_up"); return nil
        }
        guard config.tierEnabled else { cloudLibraryProblem = words.callIt("mac.cloudlib_tier_off"); return nil }
        guard let plan = await tierPlan(engine: engine, config: config, roots: roots) else { return nil }
        let titles = Dictionary(files.map { (LibraryLocation.itemDirName($0.id), $0.title) },
                                uniquingKeysWith: { a, _ in a })
        return FreeUpPreview(count: plan.candidates.count,
                             size: (try? await engine.formatBytes(plan.bytes)) ?? "",
                             names: plan.candidates.map { titles[$0.id ?? ""] ?? $0.filename },
                             paths: Set(plan.candidates.map(\.fullPath)),
                             destination: words.callIt(config.isDrive ? "mac.cloudlib_where_drive" : "mac.cloudlib_where_bucket"))
    }

    /// Move the models nobody has used for a while to the cloud, freeing this
    /// Mac's disk. Each is proved to be in the bucket before its local copy
    /// goes; see `CloudLibrary.ensureInBucket`.
    ///
    /// Only the models the shop CONFIRMED (`only`, from `freeUpSpacePreview`),
    /// and of those only the ones the rule still picks now — a job opened
    /// since the preview keeps its model.
    func freeUpSpace(only confirmed: Set<String>) async {
        cloudLibraryProblem = nil
        cloudLibraryNote = nil
        // Deleting this Mac's copies of the library's files is the storage
        // setting's business (the staff lock): it went unasked.
        guard permitted("settings", "edit") else { cloudLibraryProblem = moveProblem; return }
        guard let engine, let config = await cloudConfig(), let roots = libraryRoots else {
            cloudLibraryProblem = words.callIt("mac.cloudlib_not_set_up"); return
        }
        guard config.tierEnabled else { cloudLibraryProblem = words.callIt("mac.cloudlib_tier_off"); return }
        cloudLibraryBusy = true
        defer { cloudLibraryBusy = false; cloudProgress = nil }
        guard let plan = await tierPlan(engine: engine, config: config, roots: roots) else { return }
        let candidates = plan.candidates.filter { confirmed.contains($0.fullPath) }
        var moved = 0, freed = 0.0
        var failures: [String] = []
        for (i, file) in candidates.enumerated() {
            cloudProgress = (done: i, total: candidates.count, name: file.filename)
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
                                                     "total": .number(Double(candidates.count)),
                                                     "size": .string(human)])
        if !failures.isEmpty { cloudLibraryProblem = failures.prefix(3).joined(separator: "\n") }
        await load(source)
    }

    /// The remotes a moved model may be on, the one its sidecar names first
    /// — see `CloudLibrary.bringBack(_:remotes:engine:)`. Each is opened
    /// whether or not it is the one in use: a bucket switched off still
    /// holds what was moved to it.
    func cloudRemotes(for side: KhaytEngine.Sidecar) async -> [LibraryRemote] {
        let settings = settingsDict, build = source.build
        let current = await CloudLibrary.remoteInUse(settings, build: build)
        var out: [LibraryRemote] = []
        for r in CloudLibrary.remoteOrder(provider: side.provider, current: current) {
            switch r {
            case .bucket:
                if let c = await CloudLibrary.libraryBucket(settings: settings, build: build) { out.append(.bucket(c)) }
            case .drive:
                if let d = await CloudLibrary.libraryDrive(settings: settings, build: build) {
                    out.append(.drive(DriveClient(d.config, fetch: CloudLibrary.fetch)))
                }
            case .none: break
            }
        }
        return out
    }

    /// Bring one model back from the cloud, for a shop about to use it.
    func bringBack(_ file: LibraryFile) async {
        cloudLibraryProblem = nil
        guard let engine, let dir = directory(for: file) else { return }
        let sidecars = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".cloud") }
        cloudLibraryBusy = true
        defer { cloudLibraryBusy = false }
        for name in sidecars {
            let model = dir.appending(path: String(name.dropLast(".cloud".count)))
            do { try await CloudLibrary.bringBack(model, remotes: { await self.cloudRemotes(for: $0) }, engine: engine) }
            catch { cloudLibraryProblem = words.callIt("mac.cloudlib_bring_back_failed") + " " + cloudSay(error) }
        }
        await load(source)
    }

    /// Every model that was moved to the cloud, back onto this Mac.
    func bringEverythingBack() async {
        cloudLibraryProblem = nil
        cloudLibraryNote = nil
        guard let engine, let roots = libraryRoots else { return }
        cloudLibraryBusy = true
        defer { cloudLibraryBusy = false; cloudProgress = nil }
        let sidecars = await Task.detached { CloudLibrary.libraryFiles(root: roots.primary) }.value
            .filter { $0.filename.hasSuffix(".cloud") }
        var back = 0
        var failures: [String] = []
        for (i, side) in sidecars.enumerated() {
            cloudProgress = (done: i, total: sidecars.count, name: side.filename)
            let model = URL(fileURLWithPath: String(side.fullPath.dropLast(".cloud".count)))
            do {
                try await CloudLibrary.bringBack(model, remotes: { await self.cloudRemotes(for: $0) }, engine: engine)
                back += 1
            } catch { failures.append(model.lastPathComponent + ": " + cloudSay(error)) }
        }
        cloudLibraryNote = words.callIt("mac.cloudlib_brought_back", ["n": .number(Double(back))])
        if !failures.isEmpty { cloudLibraryProblem = failures.prefix(3).joined(separator: "\n") }
        await load(source)
        await verifyCloudCopies()
    }

    /// What the settings pane shows before anything is pressed: how many
    /// models could move, and how much that frees.
    func cloudTierSummary() async -> (count: Int, size: String, inCloud: Int)? {
        guard let engine, let roots = libraryRoots, let config = await cloudConfig() else { return nil }
        let all = await Task.detached { CloudLibrary.libraryFiles(root: roots.primary) }.value
        let inCloud = all.filter { $0.filename.hasSuffix(".cloud") }.count
        guard let plan = await tierPlan(engine: engine, config: config, roots: roots) else { return nil }
        return (plan.candidates.count, (try? await engine.formatBytes(plan.bytes)) ?? "", inCloud)
    }

    // MARK: - Is every moved model still there?

    /// One moved model whose online copy did not answer.
    struct MissingCopy: Identifiable, Equatable, Sendable {
        /// Where the model was on this Mac.
        var id: String
        var name: String
        var key: String
        /// In Drive's Trash: it can be restored from there.
        var inTrash: Bool
    }

    /// The sidecars under the library, read: where each model went.
    private func movedModels(engine: KhaytEngine, roots: LibraryLocation.Roots) async
        -> [(model: URL, side: KhaytEngine.Sidecar)] {
        let listed = await Task.detached { CloudLibrary.libraryFiles(root: roots.primary) }.value
            .filter { $0.filename.hasSuffix(".cloud") }
        var out: [(URL, KhaytEngine.Sidecar)] = []
        for s in listed {
            guard let text = try? String(contentsOfFile: s.fullPath, encoding: .utf8),
                  let side = try? await engine.parseSidecar(text) else { continue }
            out.append((URL(fileURLWithPath: String(s.fullPath.dropLast(".cloud".count))), side))
        }
        return out
    }

    /// Ask the cloud, for every model moved off this Mac, whether it still
    /// holds it — at the size the sidecar recorded.
    ///
    /// ── AFTER A MOVE, THE CLOUD IS THE ONLY COPY ─────────────────────────
    ///
    /// Freeing space proves the copy before it deletes the local one, and then
    /// nothing ever looked again. A Drive file trashed by hand, a bucket
    /// lifecycle rule, a prefix changed — the model is gone and the library
    /// still shows it as "In the cloud" until the day a job needs it. Asked
    /// on launch and once a day after (`verifyCloudCopiesIfDue`), and said on
    /// every screen (`MoveBanners`) until it is dealt with.
    ///
    /// A remote that cannot be asked (offline, a sign-in that has lapsed) is
    /// NOT "missing": only an answer of "not there" or "wrong size" is.
    func verifyCloudCopies() async {
        guard source.build != nil, let engine, let roots = libraryRoots else { return }
        let moved = await movedModels(engine: engine, roots: roots)
        var missing: [MissingCopy] = []
        let titles = Dictionary(files.map { (LibraryLocation.itemDirName($0.id), $0.title) },
                                uniquingKeysWith: { a, _ in a })
        for (model, side) in moved {
            let remotes = await cloudRemotes(for: side)
            guard !remotes.isEmpty else { continue }
            var found = false, unasked = false, inTrash = false
            for remote in remotes {
                do {
                    if let head = try await remote.head(side.key, fetch: CloudLibrary.fetch),
                       Double(head.size) == side.size {
                        found = true; break
                    }
                    if try await remote.trashedCopy(side.key, fetch: CloudLibrary.fetch) != nil { inTrash = true }
                } catch {
                    unasked = true
                }
            }
            // Missing only when EVERY remote answered and none has it.
            guard !found, !unasked else { continue }
            let dir = model.deletingLastPathComponent().lastPathComponent
            missing.append(MissingCopy(id: model.path, name: titles[dir] ?? model.lastPathComponent,
                                       key: side.key, inTrash: inTrash))
        }
        cloudMissing = missing
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cloudCheckedKey)
    }

    static let cloudCheckedKey = "cloudLibraryCopiesCheckedAt"

    /// `verifyCloudCopies`, when a day has passed since the last time — on
    /// launch, and from the loop the window keeps while it is open.
    func verifyCloudCopiesIfDue(now: Date = Date()) async {
        let last = UserDefaults.standard.double(forKey: Self.cloudCheckedKey)
        guard now.timeIntervalSince1970 - last >= 86_400 || !cloudMissing.isEmpty else { return }
        await verifyCloudCopies()
    }

    /// Take every missing model that is in Drive's Trash back out of it, then
    /// look again.
    func restoreMissingFromDriveTrash() async {
        cloudLibraryProblem = nil
        guard let d = await CloudLibrary.libraryDrive(settings: settingsDict, build: source.build) else {
            cloudLibraryProblem = words.callIt("mac.cloudlib_not_set_up"); return
        }
        let drive = LibraryRemote.drive(DriveClient(d.config, fetch: CloudLibrary.fetch))
        cloudLibraryBusy = true
        defer { cloudLibraryBusy = false }
        var restored = 0
        for m in cloudMissing where m.inTrash {
            do { if try await drive.restoreFromTrash(m.key, fetch: CloudLibrary.fetch) { restored += 1 } }
            catch { cloudLibraryProblem = cloudSay(error) }
        }
        cloudLibraryNote = words.callIt("mac.cloudlib_restored_from_trash", ["n": .number(Double(restored))])
        await verifyCloudCopies()
    }

    /// Moved models whose sidecar names a remote other than `target` — what
    /// switching to it would leave behind.
    func cloudStranded(switchingTo target: CloudLibrary.Remote) async -> Int {
        guard let engine, let roots = libraryRoots else { return 0 }
        let current = await CloudLibrary.remoteInUse(settingsDict, build: source.build)
        guard target != current else { return 0 }
        let providers = await movedModels(engine: engine, roots: roots).map { $0.side.provider }
        return CloudLibrary.stranded(switchingTo: target, providers: providers, current: current)
    }

    /// Refuse a switch that would leave moved models on the remote being left:
    /// says why, and what to press first. True when the switch may go ahead.
    private func maySwitchRemote(to target: CloudLibrary.Remote) async -> Bool {
        let n = await cloudStranded(switchingTo: target)
        guard n > 0 else { return true }
        cloudLibraryProblem = words.callIt("mac.cloudlib_switch_blocked", ["n": .number(Double(n))])
        return false
    }

    // MARK: - Google Drive

    /// Write `printLibrary.gdrive`, merged over what is there — as the other
    /// app's `savePrintLibGDrive` does. `nil` leaves a field alone; secrets are
    /// sealed on the way in.
    private func writeDrive(clientId: String? = nil, clientSecret: String? = nil, refreshToken: String? = nil,
                            folderName: String? = nil, enabled: Bool? = nil, bucketOff: Bool = false) async throws {
        guard permitted("settings", "edit") else { throw Shop.MoveRefused(sentence: moveProblem ?? "") }
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
            // Drive chosen: the bucket is switched off, or it would win — its
            // own copy switch kept, for the day the shop goes back to it.
            if bucketOff { CloudLibrary.choose(.drive, in: &library) }
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
                FileHandle.standardError.write(Data("khayt: could not open the browser — \(RedactedError.describe(error))\n".utf8))
            }
        }
    }

    /// Connect, as a task the Settings pane can cancel. Held on the shop,
    /// not the pane, so a Cancel still works after the pane was closed and
    /// opened again mid-sign-in.
    @discardableResult
    func startGoogleSignIn(clientId: String, typedSecret: String, folderName: String) -> Task<Void, Never> {
        googleSignInTask?.cancel()
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.connectGoogleDrive(clientId: clientId, typedSecret: typedSecret, folderName: folderName)
        }
        googleSignInTask = task
        return task
    }

    /// Stop waiting for Google. Cancelling the task stops the loopback wait
    /// (`GoogleSignIn.Loopback.nextCallback`), which closes the port; the
    /// waiting screen is cleared at once rather than when that lands.
    func cancelGoogleSignIn() {
        googleSignInTask?.cancel()
        googleSignInTask = nil
        googleSignInURL = nil
        cloudLibraryNote = nil
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
        // Connecting chooses Drive — see `chooseLibraryRemote`.
        guard await maySwitchRemote(to: .drive) else { return }
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
            try Task.checkCancellation()
            try await writeDrive(refreshToken: refresh, enabled: true, bucketOff: true)
            cloudLibraryNote = words.callIt("mac.gdrive_connected")
            googleSignInTask = nil
        } catch {
            googleSignInURL = nil
            cloudLibraryNote = nil
            // A Cancel the shop pressed is not a problem to report.
            if !(error is CancellationError) { cloudLibraryProblem = cloudSay(error) }
            if !Task.isCancelled { googleSignInTask = nil }
        }
    }

    /// Switch the library to the bucket or to Google Drive — "Use a storage
    /// bucket" / "Use Google Drive instead" with the other one ready. Each
    /// one's copy switch stays as the shop left it.
    func chooseLibraryRemote(_ remote: CloudLibrary.Remote) async {
        guard permitted("settings", "edit") else { return }
        cloudLibraryProblem = nil
        guard let build = source.build else { cloudLibraryProblem = words.callIt("mac.settings_sample"); return }
        // Models moved to the remote being left would be stranded there:
        // nothing checks them, and it is the remote a shop then disconnects.
        guard await maySwitchRemote(to: remote) else { return }
        do {
            try StoreWriter.update(build) { root in
                var settings = Self.settings(root)
                var library: [String: JSONValue] = [:]
                if case .object(let l)? = settings["printLibrary"] { library = l }
                CloudLibrary.choose(remote, in: &library)
                settings["printLibrary"] = .object(library)
                root["settings"] = .object(settings)
            }
            await load(source)
        } catch {
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
        guard permitted("settings", "edit") else { return }
        cloudLibraryProblem = nil
        guard let build = source.build else { cloudLibraryProblem = words.callIt("mac.settings_sample"); return }
        do {
            let using = await CloudLibrary.remoteInUse(settingsDict, build: source.build)
            try StoreWriter.update(build) { root in CloudLibrary.applyOptions(options, using: using, to: &root) }
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
    /// Saving the bucket is CHOOSING it: see `CloudLibrary.saveBucket`. The
    /// two options — backing up, freeing space — are the status area's
    /// switches and are left as they are; see `setLibraryOptions`.
    func saveCloudLibrary(provider: String, endpoint: String, bucket: String, region: String,
                          prefix: String, accessKeyId: String, typedSecret: String) async {
        guard permitted("settings", "edit") else { return }
        cloudLibraryProblem = nil
        cloudLibraryNote = nil
        guard let build = source.build else { cloudLibraryProblem = words.callIt("mac.settings_sample"); return }
        // Saving the bucket chooses it — see `chooseLibraryRemote`.
        guard await maySwitchRemote(to: .bucket) else { return }
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
                CloudLibrary.saveBucket(.init(provider: provider, endpoint: endpoint, bucket: bucket, region: region,
                                              prefix: prefix, accessKeyId: accessKeyId),
                                        sealedSecret: sealed, in: &library)
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
