import Foundation
import KhaytCore

/// Deleting a model: from THIS MAC by default, from everywhere when asked.
///
/// Asked for by the shop (Oct 2026): "when deleting the default is to delete
/// the files on the computer and not online, with an option to do a complete
/// delete from library".
///
/// ── REMOVE FROM THIS MAC (the default) ───────────────────────────────────
///
/// * A model with a VERIFIED online copy loses only its local file: the record
///   stays, as an online model with Bring Back. This is Free Up Space for the
///   chosen models — the same `ensureInBucket` asking the remote again in a
///   separate request before anything local goes, the same `.cloud` sidecar —
///   except the file goes to the Trash rather than away.
/// * A model already online-only stays exactly as it is.
/// * A model held where the shop keeps it (a linked folder, or adopted in
///   place) loses its library ENTRY only — never the shop's file.
/// * A model with NO online copy is not touched unless the person confirms,
///   with the count in front of them: deleting it removes it for good. Then it
///   gets the delete there has always been (`deleteLibraryFiles`).
///
/// ── DELETE COMPLETELY ─────────────────────────────────────────────────────
///
/// The record, the local files (to the Trash), AND every online copy: the
/// backup under `print-files/<id>/`, the object a `.cloud` sidecar names, and
/// — for a model the shop put in the bucket by hand — that object too. Still
/// never a file in the shop's own folder. The online copies go FIRST, and a
/// model whose online copy would not go keeps its record and its files: a
/// record is never left pointing at nothing, and the shop is told which.
///
/// Counted from exactly the models chosen — the selection holds only models
/// drawn on screen (`askToDeleteFromLibrary`), the lesson of 27 Sep 2026.
struct LibraryDeletePlan: Equatable, Sendable {
    /// Every model it was made for, in order.
    var ids: [String] = []
    /// A local file and a verified online copy: the file goes, the record stays.
    var keptOnline: [String] = []
    /// Online only already: nothing on this Mac to remove.
    var cloudOnly: [String] = []
    /// The file is the shop's own, in its own folder: the entry goes, not the file.
    var inPlace: [String] = []
    /// No online copy: deleting it from this Mac deletes it for good.
    var onlyHere: [String] = []
    /// Of `cloudOnly`, the ones the shop put in the bucket itself.
    var handPlaced: [String] = []
    /// The online objects a complete delete removes, per model — keyed by
    /// remote: `bucket:` + key for the library's bucket, `drive:` + key for Drive.
    var online: [String: [String]] = [:]
    /// For each model kept online, the file to remove and the key it is proved at.
    var local: [String: LocalCopy] = [:]
    /// For a hand-placed object (`.online` marker), the bucket its marker
    /// names, by tagged key: a complete delete goes to THAT bucket or nowhere.
    var markerBuckets: [String: String] = [:]

    struct LocalCopy: Equatable, Sendable { var model: URL; var key: String }

    var onlineCount: Int { online.values.filter { !$0.isEmpty }.count }
}

extension Shop {

    /// What deleting each model means, before anyone is asked.
    ///
    /// - Parameters:
    ///   - remote: the library's remote in use (bucket or Drive), nil when none.
    ///   - prefix: its key prefix.
    ///   - markerTag: how a hand-placed object's key is written in `online`.
    static func planDelete(_ files: [LibraryFile], roots: [String], remote: LibraryRemote?, prefix: String,
                           remoteTag: String, engine: KhaytEngine, fetch: @escaping S3.Fetch,
                           modelFile: (LibraryFile) -> URL?) async -> LibraryDeletePlan {
        var plan = LibraryDeletePlan()
        let fm = FileManager.default
        for file in files {
            plan.ids.append(file.id)
            let dir = LibraryLocation.directory(for: file.id, roots: roots)
            let names = dir.map { (try? fm.contentsOfDirectory(atPath: $0.path)) ?? [] } ?? []
            var keys: [String] = []
            var marker = false
            for name in names where name.hasSuffix(".cloud") || name.hasSuffix(Shop.onlineExt) {
                guard let dir, let data = fm.contents(atPath: dir.appending(path: name).path),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let key = o["key"] as? String, !key.isEmpty else { continue }
                if name.hasSuffix(Shop.onlineExt) {
                    marker = true
                    keys.append("bucket:" + key)
                    if let b = o["bucket"] as? String, !b.isEmpty { plan.markerBuckets["bucket:" + key] = b }
                } else { keys.append(remoteTag + key) }
            }
            let model = modelFile(file)
            // The library's own backup of the file, where it would be.
            var proved = false
            var backupKey: String?
            if let model, let remote {
                let key = S3.objectKey(prefix: prefix, id: LibraryLocation.itemDirName(file.id),
                                       filename: model.lastPathComponent)
                if let head = try? await remote.head(key, fetch: fetch) {
                    backupKey = key
                    keys.append(remoteTag + key)
                    if let local = await PinWork.run({ try? CloudLibrary.digests(of: model) }),
                       head.size == local.size,
                       (try? await engine.etagVerdict(etag: head.etag, md5: local.md5)) == "match" {
                        proved = true
                    }
                }
            }
            // Once each: a `.cloud` sidecar names the backup key the HEAD
            // above found too.
            var once = Set<String>()
            plan.online[file.id] = keys.filter { once.insert($0).inserted }
            if file.isLinked {
                plan.inPlace.append(file.id)
            } else if model == nil {
                if keys.isEmpty { plan.onlyHere.append(file.id) } else { plan.cloudOnly.append(file.id) }
                if marker { plan.handPlaced.append(file.id) }
            } else if proved, let model, let backupKey {
                plan.keptOnline.append(file.id)
                plan.local[file.id] = .init(model: model, key: backupKey)
            } else {
                plan.onlyHere.append(file.id)
            }
        }
        return plan
    }

    /// One model's local file, removed once its online copy is proved — in a
    /// separate request, again, at the moment of removal (`ensureInBucket`,
    /// which uploads nothing when the copy is there and right). The sidecar
    /// is written FIRST, then the file goes to the Trash: a crash between the
    /// two leaves a model that is here and noted as online, never neither.
    static func removeLocalCopy(_ copy: LibraryDeletePlan.LocalCopy, remote: LibraryRemote, provider: String,
                                engine: KhaytEngine, fetch: @escaping S3.Fetch) async throws {
        // lock: callers — removeFromThisMac
        let proved = try await CloudLibrary.ensureInBucket(remote, key: copy.key, file: copy.model,
                                                           engine: engine, fetch: fetch)
        let text = try await engine.sidecarText(size: proved.size, sha256: proved.sha256, key: copy.key,
                                                provider: provider, at: ISO8601DateFormatter().string(from: Date()))
        try Data(text.utf8).write(to: CloudLibrary.sidecar(for: copy.model), options: .atomic)
        try Shop.trash(copy.model)
    }

    /// Every online copy of each model, deleted — per model, so one that fails
    /// is named and KEPT whole while the others go.
    ///
    /// - Returns: the ids whose online copies are all gone (or had none), and
    ///   a sentence for each one that failed.
    ///
    /// - Parameter keptFor: keys a model NOT being deleted still names (its
    ///   `.cloud` sidecar or `.online` marker) — never deleted: the object is
    ///   that model's too. Two Macs adopting one bucket object at once make two
    ///   records of it, and deleting one must not strand the other.
    static func deleteOnlineCopies(_ plan: LibraryDeletePlan, ids: [String],
                                   remote: LibraryRemote?, bucket: LibraryRemote?,
                                   remoteTag: String, keptFor: Set<String> = [],
                                   fetch: @escaping S3.Fetch) async -> (done: [String], failed: [String: String]) {
        // lock: callers — deleteCompletely
        var done: [String] = []
        var failed: [String: String] = [:]
        for id in ids {
            var problem: String?
            for tagged in plan.online[id] ?? [] {
                // `drive:` is Drive, which is only ever the remote in use;
                // `bucket:` is the library's bucket, in use or not.
                let target: LibraryRemote?, key: String
                if tagged.hasPrefix("drive:") {
                    target = remoteTag == "drive:" ? remote : nil; key = String(tagged.dropFirst("drive:".count))
                } else {
                    target = bucket ?? (remoteTag == "bucket:" ? remote : nil)
                    key = String(tagged.dropFirst("bucket:".count))
                }
                guard let target else { problem = "no online storage is set up to delete \(key) from"; break }
                if keptFor.contains(key) { continue }
                // An empty segment is dropped by the request (`S3.request`),
                // which would then name a different object.
                if key.split(separator: "/", omittingEmptySubsequences: false).contains(where: \.isEmpty) {
                    problem = "\(key) is not a key this app can address safely"; break
                }
                // The bucket the marker was written for, or none: a bucket
                // switched since may hold an unrelated object at the same key.
                if let want = plan.markerBuckets[tagged] {
                    guard case .bucket(let c) = target, c.bucket == want else {
                        problem = "\(key) is in the bucket \(want), which is not the one set up now"; break
                    }
                }
                do { try await target.delete(key, fetch: fetch) }
                catch { problem = (error as? LocalizedError)?.errorDescription ?? String(describing: error); break }
            }
            if let problem { failed[id] = problem } else { done.append(id) }
        }
        return (done, failed)
    }

    // MARK: - The shop's side

    /// The remote in use, how its keys are tagged, and its prefix and provider.
    private func deleteRemotes() async -> (remote: LibraryRemote?, bucket: LibraryRemote?, tag: String,
                                           prefix: String, provider: String) {
        let config = await cloudConfig()
        let bucket = await CloudLibrary.libraryBucket(settings: settingsDict, build: source.build).map(LibraryRemote.bucket)
        let tag = config?.isDrive == true ? "drive:" : "bucket:"
        return (config?.remote, bucket, tag, config?.prefix ?? "", config?.provider ?? "")
    }

    /// ── THE QUESTION OPENS ONLY ONCE THIS IS DONE ────────────────────────
    ///
    /// A macOS confirmation dialog is drawn once, when it opens, and never
    /// redrawn: opened before the plan, it said "Checking…" over a lone Cancel
    /// for good and no model could be deleted at all (alpha.65 review,
    /// measured in the snapshot run). `WindowSheets` presents it only when
    /// `deletePlan` is set; this runs from a `.task` on the window.
    ///
    /// Work out what deleting these would do, for the question. Kept until
    /// the question closes; `nil` while the remote is being asked.
    func planDeletes(_ chosen: [LibraryFile]) async {
        // The snapshot run sets each variant's plan itself, before the question.
        if ProcessInfo.processInfo.environment["KHAYT_SNAPSHOT_DELETE"] == "1",
           ProcessInfo.processInfo.environment["KHAYT_SNAPSHOT_DIR"] != nil,
           deletePlan?.ids == chosen.map(\.id) { return }
        deletePlan = nil
        guard !chosen.isEmpty else { return }
        // No library on disk (the sample shop) or no engine: nothing can be
        // online or in place, and the question must still have its answer
        // rather than "Checking…" over a lone Cancel for ever.
        guard let engine, let roots = libraryRoots else {
            deletePlan = LibraryDeletePlan(ids: chosen.map(\.id), onlyHere: chosen.map(\.id))
            return
        }
        // The question opens only once this is done (see `WindowSheets`), so
        // the wait is said where the shop is looking, and each request is
        // bounded: an unreachable endpoint must not hold the question back for
        // URLSession's minute per model.
        let checking = words.callIt("mac.delete_checking")
        importNote = checking
        defer { if importNote == checking { importNote = nil } }
        let quick: S3.Fetch = { request in
            var r = request
            r.timeoutInterval = 15
            return try await CloudLibrary.fetch(r)
        }
        let r = await deleteRemotes()
        let plan = await Self.planDelete(chosen, roots: roots.roots, remote: r.remote, prefix: r.prefix,
                                         remoteTag: r.tag, engine: engine, fetch: quick,
                                         modelFile: { [weak self] in self?.modelFile(for: $0) })
        // Still the question on screen?
        let open = pendingLibraryDelete.map { [$0.id] } ?? pendingLibraryDeletes.map(\.id)
        if open == plan.ids { deletePlan = plan }
    }

    /// The SECOND LOCK, as `confirmLibraryDeletes` has it: the question's
    /// answer acts only on the models the question was asked about, and —
    /// for several from the library screen — only while every one of them is
    /// still drawn there (27 Sep 2026). Refuses, and says so, otherwise.
    ///
    /// Asked SYNCHRONOUSLY in the button's action, before its `Task`: the
    /// dialog clears `pendingLibraryDeletes` as it closes, which is before
    /// any task the button started gets to run.
    func stillTheQuestion(_ plan: LibraryDeletePlan) -> Bool {
        if !pendingLibraryDeletes.isEmpty {
            let hidden = notOnScreen(pendingLibraryDeletes)
            guard hidden.isEmpty, pendingLibraryDeletes.map(\.id) == plan.ids else {
                pendingLibraryDeletes = []
                deletePlan = nil
                importProblem = words.counting(max(hidden.count, 1), "mac.delete_not_on_screen")
                return false
            }
            return true
        }
        guard let one = pendingLibraryDelete, [one.id] == plan.ids else {
            pendingLibraryDelete = nil
            deletePlan = nil
            return false
        }
        return true
    }

    /// The lines the question adds under the names: what stays online, what
    /// goes for good, what is the shop's own file.
    static func deletePlanLines(_ plan: LibraryDeletePlan, words: Words) -> [String] {
        var lines: [String] = []
        let single = plan.ids.count == 1
        func line(_ key: String, _ n: Int) -> String {
            single ? words.callIt(key + "_single") : say(words, key, n, ["total": .number(Double(plan.ids.count))])
        }
        if !plan.keptOnline.isEmpty { lines.append(line("mac.delete_kept_online", plan.keptOnline.count)) }
        if !plan.cloudOnly.isEmpty { lines.append(line("mac.delete_cloud_only", plan.cloudOnly.count)) }
        if !plan.onlyHere.isEmpty {
            lines.append(!single && plan.onlyHere.count == plan.ids.count
                         ? words.callIt("mac.delete_only_here_all")
                         : line("mac.delete_only_here", plan.onlyHere.count))
        }
        if !plan.inPlace.isEmpty { lines.append(line("mac.delete_in_place", plan.inPlace.count)) }
        if plan.onlineCount > 0 {
            lines.append(line("mac.delete_completely_says", plan.onlineCount))
            if !plan.handPlaced.isEmpty { lines.append(line("mac.delete_hand_placed", plan.handPlaced.count)) }
        }
        return lines
    }

    /// A counted sentence: `key_n1` for one, Arabic's dual `key_n2` for two,
    /// else `key` — each placing its own `{n}` (or saying the number in words).
    /// Not `Words.counting`, which puts a numeral in FRONT of a `_one` that has
    /// no `{n}` of its own: "1 One has an online copy" — hence its own
    /// suffixes, which `counting` (and `CountedOneTests`) leave alone.
    static func say(_ words: Words, _ key: String, _ n: Int, _ more: [String: JSONValue] = [:]) -> String {
        var pick = key
        if n == 1, words.callIt(key + "_n1") != key + "_n1" { pick = key + "_n1" }
        if n == 2, words.language == "ar", words.callIt(key + "_n2") != key + "_n2" { pick = key + "_n2" }
        var params = more
        params["n"] = .number(Double(n))
        return words.callIt(pick, params)
    }

    /// "Remove from this Mac": local files of models kept online, entries of
    /// models in the shop's own folders, and — only when the person said so —
    /// the models that are only here.
    func removeFromThisMac(_ plan: LibraryDeletePlan, includingOnlyHere: Bool) async {
        guard permitted("inventory", "delete") else { return }
        clearLastOutcome()
        pendingLibraryDelete = nil
        pendingLibraryDeletes = []
        deletePlan = nil
        guard let engine else { return }
        var failures: [String] = []
        var removed = 0
        if !plan.keptOnline.isEmpty {
            let r = await deleteRemotes()
            for id in plan.keptOnline {
                guard let copy = plan.local[id], let remote = r.remote else { continue }
                do {
                    try await Self.removeLocalCopy(copy, remote: remote, provider: r.provider, engine: engine,
                                                   fetch: CloudLibrary.fetch)
                    removed += 1
                } catch {
                    failures.append(copy.model.lastPathComponent + ": " + cloudSay(error))
                }
            }
        }
        let gone = Set(plan.inPlace + (includingOnlyHere ? plan.onlyHere : []))
        let records = files.filter { gone.contains($0.id) }
        if !records.isEmpty { await deleteLibraryFiles(records) } else { await load(source) }
        importNote = words.callIt("mac.delete_local_done", ["n": .number(Double(removed)),
                                                            "gone": .number(Double(records.count))])
        if !failures.isEmpty { importProblem = failures.prefix(5).joined(separator: "\n") }
    }

    /// "Delete completely from library": the online copies first, then the
    /// record and its local files — for each model whose online copies went.
    func deleteCompletely(_ plan: LibraryDeletePlan) async {
        guard permitted("inventory", "delete") else { return }
        clearLastOutcome()
        pendingLibraryDelete = nil
        pendingLibraryDeletes = []
        deletePlan = nil
        let r = await deleteRemotes()
        let chosen = Set(plan.ids.map(LibraryLocation.itemDirName))
        let roots = libraryRoots?.roots ?? []
        let keptFor = await PinWork.run { Shop.keysNamedOnDisk(roots: roots, except: chosen) }
        let result = await Self.deleteOnlineCopies(plan, ids: plan.ids, remote: r.remote, bucket: r.bucket,
                                                   remoteTag: r.tag, keptFor: keptFor, fetch: CloudLibrary.fetch)
        let done = Set(result.done)
        let records = files.filter { done.contains($0.id) }
        if !records.isEmpty { await deleteLibraryFiles(records) }
        let titles = Dictionary(files.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        if !result.failed.isEmpty {
            importProblem = words.callIt("mac.delete_online_failed", ["n": .number(Double(result.failed.count))])
                + "\n" + result.failed.sorted { $0.key < $1.key }.prefix(5)
                    .map { (titles[$0.key] ?? $0.key) + ": " + $0.value }.joined(separator: "\n")
        }
    }
}
