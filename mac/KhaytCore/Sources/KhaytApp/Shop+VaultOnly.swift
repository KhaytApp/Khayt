import SwiftUI
import KhaytCore

/// ── THE MODELS ONLY THE VAULT HOLDS ───────────────────────────────────────
///
/// While the vault is over its plan, files over the limit are deleted on the
/// cloud's `deleteAfter` (khayt-cloud #143). A model Free Up Space moved to
/// the vault has only a `.cloud` sidecar here: once the vault deletes it,
/// nothing is left. The cloud cannot name these files (it holds ciphertext);
/// this Mac can, so it counts them and offers to bring exactly those back —
/// downloads keep working while the vault is read-only.
///
/// Before deletion: `vaultOnlyIds`, counted off the disk, and
/// `bringBackVaultOnly`, which runs the existing verified Bring Back
/// (`CloudLibrary.bringBack`) for those models in batches, with progress.
/// After deletion: Library Health's "deleted from the vault by the plan
/// limit" (`VaultOnlyCopies.deletedByPlan`, `healthPresence`).
extension Shop {

    /// What one model's own folder holds, read for `VaultOnlyCopies`: each
    /// `.cloud` sidecar, the provider it names, and whether the model's bytes
    /// are beside it. Read off the main actor by the callers.
    nonisolated static func vaultFindings(in dir: URL) -> [VaultOnlyCopies.Found] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let here = Set(names)
        return names.filter { $0.hasSuffix(".cloud") }.map { side in
            let model = String(side.dropLast(".cloud".count))
            // A sidecar is a few hundred bytes; anything large is not one.
            let url = dir.appending(path: side)
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
            let data = size > 0 && size < 64 * 1024 ? (try? Data(contentsOf: url)) : nil
            return .init(name: model, provider: data.flatMap(VaultOnlyCopies.sidecarProvider),
                         bytesHere: here.contains(model))
        }
    }

    /// The models among `files` whose only copy is the vault's, in the
    /// library's order. Only Khayt's own folders: a linked model, a member of
    /// a compressed file and a page saved from the web are never moved there.
    ///
    /// A model the SHOP archived counts: archived is put aside, not deleted,
    /// and its record was kept on purpose (beta.8 review M4). One archived by
    /// the vault's own Trash (`vaultArchived`) was deleted elsewhere: not.
    nonisolated static func vaultOnlyModels(_ files: [LibraryFile], roots: [String]) -> [String] {
        files.compactMap { file in
            guard !file.isLinked, file.archivePath == nil, !file.isWebOnly, file.vaultArchived != true,
                  let dir = LibraryLocation.directory(for: file.id, roots: roots) else { return nil }
            let found = vaultFindings(in: dir)
            return VaultOnlyCopies.onlyInVault(found, own: file.sourceFile?.filename) ? file.id : nil
        }
    }

    /// Count them again, off the main actor. Only while the vault is over:
    /// otherwise there is nothing to warn about, and the count is cleared.
    func countVaultOnlyModels() async {
        guard vaultLapseDisplay.isOver else {
            if !vaultOnlyIds.isEmpty { vaultOnlyIds = [] }
            return
        }
        // No library folder (the sample): nothing on disk to count.
        guard let roots = libraryRoots?.roots else { return }
        let files = self.files
        let ids = await PinWork.run { Shop.vaultOnlyModels(files, roots: roots) }
        if ids != vaultOnlyIds { vaultOnlyIds = ids }
    }

    /// What the warning offers now, if anything.
    var vaultOnlyOffer: VaultOnlyCopies.Offer? {
        VaultOnlyCopies.offer(vaultLapseDisplay, count: vaultOnlyIds.count)
    }

    /// "Bring back N models before {date}" — or, with no date yet, "…while
    /// the vault is read-only". Nil when there is nothing to offer.
    /// `compact`: the library banner, whose sentence already says the date,
    /// says only "Bring Back N Models" (beta.8 UI review LOW-4).
    static func vaultOnlyButton(_ offer: VaultOnlyCopies.Offer?, count: Int, _ words: Words,
                                compact: Bool = false) -> String? {
        guard let offer else { return nil }
        let models = words.counting(count, "mac.n_models")
        if compact { return words.callIt("mac.lapse_bring_back", ["models": .string(models)]) }
        switch offer {
        case .before(let end):
            return words.callIt("mac.lapse_bring_back_before", ["models": .string(models), "date": .string(day(end, words))])
        case .whileReadOnly:
            return words.callIt("mac.lapse_bring_back_read_only", ["models": .string(models)])
        }
    }

    /// The sentence above the button: why these models matter.
    static func vaultOnlyWarning(count: Int, _ words: Words) -> String? {
        guard count > 0 else { return nil }
        return words.callIt("mac.lapse_vault_only", ["models": .string(words.counting(count, "mac.n_models"))])
    }

    /// Bring back exactly the models whose only copy is the vault's: each
    /// verified against its sidecar (`CloudLibrary.bringBack`), a batch at a
    /// time (`VaultOnlyCopies.batches`), the folders read off the main actor,
    /// one sync-index write per batch and one reload at the end.
    ///
    /// Behind the staff lock: it writes the library's files. Nothing is
    /// uploaded — downloads are what still work while the vault is read-only.
    func bringBackVaultOnly() async {
        guard !cloudLibraryBusy else { cloudLibraryProblem = words.callIt("mac.storage_busy"); return }
        guard permitted("inventory", "edit") else { cloudLibraryProblem = moveProblem; return }
        guard let engine, let roots = libraryRoots?.roots else {
            cloudLibraryProblem = words.callIt("mac.cloudlib_not_set_up"); return
        }
        cloudLibraryProblem = nil
        cloudLibraryNote = nil
        await countVaultOnlyModels()
        let ids = vaultOnlyIds
        guard !ids.isEmpty else { return }
        cloudLibraryBusy = true
        vaultBringBack = (0, ids.count)
        defer { cloudLibraryBusy = false; vaultBringBack = nil }
        let byId = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let settings = settingsDict
        var back = 0, done = 0
        var failures: [String] = []
        for batch in VaultOnlyCopies.batches(ids) {
            if Task.isCancelled { break }
            let chosen = batch.compactMap { byId[$0] }
            // Which sidecars, read off the main actor: only the vault's, and
            // only where the bytes are not here.
            let work = await PinWork.run { () -> [(id: String, dir: URL, names: [String])] in
                chosen.compactMap { file in
                    guard let dir = LibraryLocation.directory(for: file.id, roots: roots) else { return nil }
                    let names = Shop.vaultFindings(in: dir)
                        .filter { $0.provider == VaultOnlyCopies.vaultProvider && !$0.bytesHere }.map(\.name)
                    return (file.id, dir, names)
                }
            }
            var sync: FileStates = [:]
            for item in work {
                var ok = true
                for name in item.names {
                    let model = item.dir.appending(path: name)
                    do {
                        if let from = try await CloudLibrary.bringBack(model, remotes: { await self.cloudRemotes(for: $0) },
                                                                       engine: engine) {
                            sync[item.id, default: [:]][name] =
                                LibrarySyncIndex.backedUp(model, remote: CloudLibrary.remoteIdentity(of: from, settings: settings))
                        }
                    } catch {
                        ok = false
                        failures.append((byId[item.id]?.title ?? name) + ": " + cloudSay(error))
                    }
                }
                if ok { back += 1 }
                done += 1
                vaultBringBack = (done, ids.count)
            }
            recordSync(sync)
        }
        cloudLibraryNote = words.callIt("mac.cloudlib_brought_back", ["n": .number(Double(back))])
        if !failures.isEmpty { cloudLibraryProblem = failures.prefix(3).joined(separator: "\n") }
        await load(source)
        await countVaultOnlyModels()
    }
}

/// The warning and its one button, under the lapse notice and in the
/// library's banner: how many models only the vault holds, and Bring Back
/// for exactly those. Draws nothing when there is nothing to offer.
struct VaultOnlyOffer: View {
    let shop: Shop
    /// The banner's short form: the button alone, beside the sentence.
    var compact = false

    var body: some View {
        let count = shop.vaultOnlyIds.count
        if let label = Shop.vaultOnlyButton(shop.vaultOnlyOffer, count: count, shop.words, compact: compact) {
            VStack(alignment: .leading, spacing: 5) {
                if !compact, let warning = Shop.vaultOnlyWarning(count: count, shop.words) {
                    Text(warning).font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(label) { Task { await shop.bringBackVaultOnly() } }
                        .controlSize(.small)
                        .disabled(!shop.canWrite || shop.cloudLibraryBusy)
                    if let p = shop.vaultBringBack {
                        ProgressView(value: Double(p.done), total: Double(max(1, p.total)))
                            .frame(width: 80)
                            .accessibilityHidden(true)
                        Text(shop.words.callIt("mac.lapse_bringing_back",
                                               ["done": .string(shop.words.numeral(p.done)),
                                                "total": .string(shop.words.numeral(p.total))]))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !compact, shop.vaultBringBack == nil, let problem = shop.cloudLibraryProblem {
                    Text(problem).font(.caption).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
