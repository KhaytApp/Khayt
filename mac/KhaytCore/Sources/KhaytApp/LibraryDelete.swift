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
                if name.hasSuffix(Shop.onlineExt) { marker = true; keys.append("bucket:" + key) }
                else { keys.append(remoteTag + key) }
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
            plan.online[file.id] = keys
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
    static func deleteOnlineCopies(_ plan: LibraryDeletePlan, ids: [String],
                                   remote: LibraryRemote?, bucket: LibraryRemote?,
                                   remoteTag: String, fetch: @escaping S3.Fetch) async -> (done: [String], failed: [String: String]) {
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

    /// Work out what deleting these would do, for the question. Kept until
    /// the question closes; `nil` while the remote is being asked.
    func planDeletes(_ chosen: [LibraryFile]) async {
        deletePlan = nil
        guard !chosen.isEmpty, let engine, let roots = libraryRoots else { return }
        let r = await deleteRemotes()
        let plan = await Self.planDelete(chosen, roots: roots.roots, remote: r.remote, prefix: r.prefix,
                                         remoteTag: r.tag, engine: engine, fetch: CloudLibrary.fetch,
                                         modelFile: { [weak self] in self?.modelFile(for: $0) })
        // Still the question on screen?
        let open = pendingLibraryDelete.map { [$0.id] } ?? pendingLibraryDeletes.map(\.id)
        if open == plan.ids { deletePlan = plan }
    }

    /// The lines the question adds under the names: what stays online, what
    /// goes for good, what is the shop's own file.
    static func deletePlanLines(_ plan: LibraryDeletePlan, words: Words) -> [String] {
        var lines: [String] = []
        func n(_ v: Int) -> [String: JSONValue] { ["n": .number(Double(v))] }
        let kept = plan.keptOnline.count + plan.cloudOnly.count
        if kept > 0 { lines.append(words.callIt("mac.delete_kept_online", n(kept))) }
        if !plan.onlyHere.isEmpty {
            lines.append(words.callIt("mac.delete_only_here", ["n": .number(Double(plan.onlyHere.count)),
                                                               "total": .number(Double(plan.ids.count))]))
        }
        if !plan.inPlace.isEmpty { lines.append(words.callIt("mac.delete_in_place", n(plan.inPlace.count))) }
        if plan.onlineCount > 0 {
            lines.append(words.callIt("mac.delete_completely_says", n(plan.onlineCount)))
            if !plan.handPlaced.isEmpty {
                lines.append(words.callIt("mac.delete_hand_placed", n(plan.handPlaced.count)))
            }
        }
        return lines
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
        let result = await Self.deleteOnlineCopies(plan, ids: plan.ids, remote: r.remote, bucket: r.bucket,
                                                   remoteTag: r.tag, fetch: CloudLibrary.fetch)
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
